// VAPPlayer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import UIKit
import Metal
import AVFoundation

// MARK: - 播放配置

public struct VAPPlaybackConfiguration: Sendable {
    /// 源文件路径或 URL 字符串。
    public var source: String
    /// 视频帧中的 Alpha 通道位置。
    ///
    /// 仅在 MP4 **不包含** 带 `rgbFrame`/`aFrame` 字段的 `vapc` box 时生效。
    /// 当这些字段存在时，渲染器会从配置中读取精确的 RGB 与 Alpha 区域，并忽略该值。
    public var alphaPlacement: VAPAlphaPlacement
    /// 后台生命周期行为。
    public var backgroundPolicy: VAPBackgroundPlaybackPolicy
    /// 内容缩放模式。
    public var contentMode: VAPContentMode
    /// 挂件资源：srcId -> 强类型值（图片、URL 字符串或文本）。
    public var attachmentSources: [String: VAPAttachmentSource]
    /// 网络/本地 URL 挂件的可选图片加载器。
    public var imageLoader: VAPAttachmentImageLoader?
    /// 解码缓冲深度（默认 3）。
    public var frameBufferCapacity: Int
    /// 覆盖播放帧率（0 表示使用 MP4 头信息中的值）。
    public var preferredFramesPerSecond: Int
    /// 如果存在音轨，是否播放音频。
    public var playsAudio: Bool
    /// 可选外部蒙版，会叠加到每一帧（仅 VAP 渲染路径）。
    public var mask: VAPMaskConfiguration?
    /// 播放次数。1 = 播放一次（默认），0 = 无限循环，N = 播放 N 次。
    /// 循环由播放器内部处理；循环之间不会销毁 Metal/纹理对象。
    ///
    /// - Important: 当 `loopCount == 0`（无限循环）时，播放不会发出 `.didFinish`。
    ///   必须显式调用 `stop()` 或 `pause()` 结束播放，否则内部 Task 会持续运行，
    ///   并一直持有相关资源（Metal 纹理、解码器、音频播放器），直到 `VAPPlayer` 释放。
    public var loopCount: Int

    public init(source: String,
                alphaPlacement: VAPAlphaPlacement = .right,
                backgroundPolicy: VAPBackgroundPlaybackPolicy = .stop,
                contentMode: VAPContentMode = .scaleToFill,
                attachmentSources: [String: VAPAttachmentSource] = [:],
                imageLoader: VAPAttachmentImageLoader? = nil,
                frameBufferCapacity: Int = 3,
                preferredFramesPerSecond: Int = 0,
                playsAudio: Bool = true,
                mask: VAPMaskConfiguration? = nil,
                loopCount: Int = 1) {
        self.source                   = source
        self.alphaPlacement           = alphaPlacement
        self.backgroundPolicy         = backgroundPolicy
        self.contentMode              = contentMode
        self.attachmentSources        = attachmentSources
        self.imageLoader              = imageLoader
        self.frameBufferCapacity      = frameBufferCapacity
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.playsAudio               = playsAudio
        self.mask                     = mask
        self.loopCount                = loopCount
    }
}

// MARK: - 播放器

@MainActor
public final class VAPPlayer {

    // MARK: 公开属性

    public let metalView: VAPMetalView

    /// 播放生命周期事件流，会在调用方上下文中产出事件。
    /// - Important: 该事件流仅支持一个并发消费者。
    ///   在同一个 `VAPPlayer` 实例上启动第二个 `for await` 循环时，不会收到事件。
    public var events: AsyncStream<VAPEvent> { _eventStream }

    // MARK: 私有状态

    private let _eventStream: AsyncStream<VAPEvent>
    private let _eventContinuation: AsyncStream<VAPEvent>.Continuation

    private var playbackTask: Task<Void, Never>?
    private var audioPlayer: AVAudioPlayer?
    private var backgroundObserver: NSObjectProtocol?
    private var foregroundObserver: NSObjectProtocol?

    private var currentConfiguration: VAPPlaybackConfiguration?
    private var currentFrameIndex: Int = 0
    private let metalDevice: MTLDevice?
    private var eventHandler: ((VAPEvent) -> Void)?
    private var playbackGeneration: Int = 0

    // MARK: - 初始化

    public init(frame: CGRect = .zero) {
        self.metalView = VAPMetalView(frame: frame)
        self.metalDevice = MTLCreateSystemDefaultDevice()
        var cont: AsyncStream<VAPEvent>.Continuation!
        self._eventStream = AsyncStream { cont = $0 }
        self._eventContinuation = cont
    }

    deinit {
        _eventContinuation.finish()
    }

    // MARK: - 公开 API

    public func play(_ configuration: VAPPlaybackConfiguration, eventHandler: ((VAPEvent) -> Void)? = nil) {
        stop(emitEvent: false)
        playbackGeneration &+= 1
        currentConfiguration = configuration
        currentFrameIndex = 0
        self.eventHandler = eventHandler
        metalView.renderContentMode = configuration.contentMode
        installBackgroundObservers(for: configuration.backgroundPolicy)
        let generation = playbackGeneration
        playbackTask = Task { [weak self] in
            await self?.runPlayback(configuration: configuration, startFrame: 0, generation: generation)
        }
    }

    public func stop() {
        stop(emitEvent: true)
    }

    func stopForReplacement() {
        stop(emitEvent: false)
    }

    private func stop(emitEvent shouldEmitStop: Bool) {
        let lastFrame = currentFrameIndex
        let hasActivePlayback = playbackTask != nil || currentConfiguration != nil
        let handler = eventHandler

        playbackGeneration &+= 1
        playbackTask?.cancel()
        playbackTask = nil
        stopAudio()
        removeLifecycleObservers()
        currentConfiguration = nil
        currentFrameIndex = 0
        eventHandler = nil

        if shouldEmitStop && hasActivePlayback {
            deliverEvent(.didStop(lastFrame: lastFrame), to: handler)
        }
    }

    private func deliverEvent(_ event: VAPEvent) {
        _eventContinuation.yield(event)
        eventHandler?(event)
    }

    private func deliverEvent(_ event: VAPEvent, to handler: ((VAPEvent) -> Void)?) {
        _eventContinuation.yield(event)
        handler?(event)
    }

    private func emitEvent(_ event: VAPEvent, generation: Int) {
        guard generation == self.playbackGeneration else { return }
        deliverEvent(event)
    }

    private func completePlayback(with event: VAPEvent, generation: Int) {
        guard generation == playbackGeneration else { return }
        let handler = eventHandler

        playbackTask = nil
        stopAudio()
        removeLifecycleObservers()
        currentConfiguration = nil
        currentFrameIndex = 0
        eventHandler = nil

        deliverEvent(event, to: handler)
    }

    public func pause() {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.pause()
    }

    public func resume() {
        guard let configuration = currentConfiguration else { return }
        audioPlayer?.play()
        let startFrame = currentFrameIndex
        let generation = playbackGeneration
        playbackTask = Task { [weak self] in
            await self?.runPlayback(configuration: configuration, startFrame: startFrame, generation: generation)
        }
    }

    public func setMuted(_ isMuted: Bool) {
        audioPlayer?.volume = isMuted ? 0 : 1
    }

    // MARK: - 播放循环

    private func runPlayback(configuration: VAPPlaybackConfiguration, startFrame: Int = 0, generation: Int) async {
        do {
            playerLog.debug("runPlayback start source=\(Self.logSourceDescription(configuration.source))")
            // 1. 在后台线程解析 MP4。
            let info: VAPMP4Info = try await Task.detached(priority: .userInitiated) {
                try VAPMP4Parser.parse(localFilePath: configuration.source)
            }.value
            playerLog.debug("parsed: frames=\(info.frameCount) fps=\(info.fps) size=\(info.width)x\(info.height) hasAudio=\(info.hasAudioTrack) vapc=\(info.vapcJSON != nil)")
            playerLog.debug("configuration: alphaPlacement=\(configuration.alphaPlacement.rawValue) contentMode=\(configuration.contentMode) loopCount=\(configuration.loopCount)")

            // 2. 校验 VAP 版本。
            if let jsonData = info.vapcJSON {
                let cfg = try? JSONDecoder().decode(VAPConfig.self, from: jsonData)
                if let v = cfg?.info.version, v > VAPPlaybackDefaults.maximumCompatibleConfigVersion {
                    throw VAPError.incompatibleVersion(v)
                }
            }

            // 3. Metal 设备（初始化时缓存）+ 渲染器（所有循环周期复用）。
            guard let device = metalDevice else {
                playerLog.error("Metal device unavailable")
                throw VAPError.metalUnavailable
            }
            playerLog.debug("Metal device: \(device.name)")

            let usesAttachmentRenderer = info.vapcJSON != nil
            let splitAlphaRenderer = usesAttachmentRenderer ? nil : try VAPHWDRenderer(device: device)
            let attachmentRenderer = usesAttachmentRenderer ? try VAPRenderer(device: device) : nil
            playerLog.debug("usesAttachmentRenderer=\(usesAttachmentRenderer) splitAlphaRenderer=\(splitAlphaRenderer != nil) attachmentRenderer=\(attachmentRenderer != nil)")

            // 4. 加载挂件配置（VAP 路径，所有循环周期复用）。
            var attachmentResources: VAPAttachmentResources?
            if usesAttachmentRenderer, let jsonData = info.vapcJSON {
                let attachmentDevice = device
                let attachmentImageLoader = configuration.imageLoader
                let attachmentSources = configuration.attachmentSources
                attachmentResources = try await Task.detached(priority: .userInitiated) {
                    let configManager = VAPConfigManager(device: attachmentDevice, imageLoader: attachmentImageLoader)
                    return try await configManager.load(vapcJSON: jsonData, sources: attachmentSources)
                }.value
                playerLog.debug("attachmentResources loaded")
            }

            // 4b. 外部蒙版覆盖（VAPMaskConfiguration -> MTLTexture，所有循环周期复用）。
            let externalMaskTexture: MTLTexture? = configuration.mask.flatMap {
                Self.makeTexture(from: $0, device: device)
            }

            // 循环状态。
            let loopCount = configuration.loopCount  // 0 表示无限循环
            var loopIndex = 0

            // 5. 创建解码器（循环之间只重置，不重新创建）。
            let reorderBufferDepth = Self.requiredBufferDepth(for: info.videoSamples)
            let frameBufferCapacity = max(max(1, configuration.frameBufferCapacity), reorderBufferDepth)
            let decoder     = VAPVideoDecoder(info: info, bufferCapacity: frameBufferCapacity)
            try await decoder.prepare()
            playerLog.debug("decoder prepared frameBufferCapacity=\(frameBufferCapacity) totalFrames=\(info.frameCount)")

            let fps = configuration.preferredFramesPerSecond > 0
                ? configuration.preferredFramesPerSecond
                : max(
                    VAPPlaybackDefaults.minimumFramesPerSecond,
                    min(info.fps, VAPPlaybackDefaults.maximumFramesPerSecond)
                )
            let frameDuration = 1.0 / Double(fps)
            let totalFrames   = info.frameCount
            playerLog.debug("fps=\(fps) frameDuration=\(frameDuration)")

            // 音频只创建一次，并在所有循环周期中复用。
            if configuration.playsAudio && info.hasAudioTrack {
                setupAudio(localFilePath: configuration.source)
            }

            // 6. 外层循环；Metal/纹理/音频对象在所有周期中复用。
            var didFinishPlayback = false
            repeat {
                // 第一轮之后的周期需要重置解码器。
                if loopIndex > 0 {
                    try await decoder.reset()
                    // 将音频 seek 回起点。
                    audioPlayer?.currentTime = 0
                }

                let cycleStartFrame = loopIndex == 0 ? startFrame : 0
                let initialDecodeEndFrame = min(cycleStartFrame + frameBufferCapacity, totalFrames)
                for i in cycleStartFrame..<initialDecodeEndFrame {
                    guard !Task.isCancelled else {
                        await decoder.invalidate()
                        return
                    }
                    try await decoder.decodeFrame(at: i)
                }
                let decodeProducerTask = Self.startDecodeProducer(decoder: decoder,
                                                                  startIndex: initialDecodeEndFrame,
                                                                  totalFrames: totalFrames)

                do {
                    audioPlayer?.play()
                    playerLog.debug("didStart loop=\(loopIndex)")
                    emitEvent(.didStart, generation: generation)

                    var frameIndex = cycleStartFrame

                    // 内层渲染循环。
                    while frameIndex < totalFrames {
                        if Task.isCancelled {
                            decodeProducerTask.cancel()
                            await decodeProducerTask.value
                            stopAudio()
                            await decoder.invalidate()
                            return
                        }

                        let frameStart = CACurrentMediaTime()

                        // 弹出精确的展示帧；最多等待一个完整帧时长，超时后跳帧。
                        // 每次重试休眠 2 ms；最多约重试 frameDuration / 0.002 次。
                        var decodedFrame: VAPDecodedFrame?
                        let maxRetries = max(10, Int(frameDuration / 0.002))
                        for _ in 0..<maxRetries {
                            decodedFrame = await decoder.popFrame(at: frameIndex)
                            if decodedFrame != nil { break }
                            try await Task.sleep(nanoseconds: 2_000_000)
                        }
                        guard let frame = decodedFrame else {
                            // 解码器停顿超过一帧预算；跳帧以维持节奏。
                            playerLog.debug("frame \(frameIndex) stalled; skipping")
                            frameIndex += 1
                            continue
                        }

                        // 渲染。
                        if frameIndex == 0 { playerLog.debug("rendering first frame via \(usesAttachmentRenderer ? "VAP" : "HWD") path") }
                        if let splitAlphaRenderer {
                            splitAlphaRenderer.render(pixelBuffer: frame.pixelBuffer,
                                                      into: metalView,
                                                      alphaPlacement: configuration.alphaPlacement)
                        } else if let attachmentRenderer {
                            attachmentRenderer.render(pixelBuffer: frame.pixelBuffer,
                                                      into: metalView,
                                                      alphaPlacement: configuration.alphaPlacement,
                                                      config: attachmentResources?.config,
                                                      attachmentTextures: attachmentResources?.textures ?? [:],
                                                      maskTexture: externalMaskTexture ?? attachmentResources?.maskTexture,
                                                      frameIndex: frame.frameIndex)
                        }

                        emitEvent(.didPlayFrame(index: frame.frameIndex), generation: generation)

                        frameIndex = frame.frameIndex + 1
                        currentFrameIndex = frameIndex

                        // 帧节奏控制。
                        let elapsed = CACurrentMediaTime() - frameStart
                        let remaining = frameDuration - elapsed
                        if remaining > 0.001 {
                            try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                        }
                    }
                    decodeProducerTask.cancel()
                    await decodeProducerTask.value
                } catch {
                    decodeProducerTask.cancel()
                    await decodeProducerTask.value
                    stopAudio()
                    await decoder.invalidate()
                    throw error
                }

                stopAudio()

                loopIndex += 1
                let isLastCycle = loopCount != 0 && loopIndex >= loopCount
                if isLastCycle {
                    playerLog.debug("didFinish totalFrames=\(totalFrames)")
                    didFinishPlayback = true
                } else {
                    playerLog.debug("didLoopFinish loop=\(loopIndex) totalFrames=\(totalFrames)")
                    emitEvent(.didLoopFinish(loop: loopIndex, totalFrames: totalFrames), generation: generation)
                }

            } while loopCount == 0 || loopIndex < loopCount

            await decoder.invalidate()
            if didFinishPlayback {
                completePlayback(with: .didFinish(totalFrames: totalFrames), generation: generation)
            }

        } catch let error as VAPError {
            playerLog.error("VAPError: \(Self.logDescription(for: error))")
            completePlayback(with: .didFail(error), generation: generation)
        } catch {
            if !Task.isCancelled {
                playerLog.error("Unknown error: \(Self.logDescription(for: error))")
                completePlayback(with: .didFail(.unknown(error.localizedDescription)), generation: generation)
            }
        }
    }

    private nonisolated static func logSourceDescription(_ source: String) -> String {
        guard let url = URL(string: source), let scheme = url.scheme, !scheme.isEmpty else {
            return "local-file"
        }
        switch scheme.lowercased() {
        case "http", "https":
            return "\(scheme)://\(url.host ?? "<unknown-host>")"
        default:
            return "\(scheme)://"
        }
    }

    private nonisolated static func logDescription(for error: VAPError) -> String {
        switch error {
        case .fileNotFound:
            return "fileNotFound(<redacted-path>)"
        case .unsupportedURLScheme(let scheme):
            return "unsupportedURLScheme(\(scheme))"
        case .invalidMP4File:
            return "invalidMP4File"
        case .streamInfoUnavailable:
            return "streamInfoUnavailable"
        case .streamUnavailable:
            return "streamUnavailable"
        case .videoToolboxDescriptionCreationFailed:
            return "videoToolboxDescriptionCreationFailed"
        case .videoToolboxSessionCreationFailed:
            return "videoToolboxSessionCreationFailed"
        case .incompatibleVersion(let version):
            return "incompatibleVersion(\(version))"
        case .missingVAPConfig:
            return "missingVAPConfig"
        case .metalUnavailable:
            return "metalUnavailable"
        case .decodeFailed(let underlying):
            let nsError = underlying as NSError
            return "decodeFailed(domain=\(nsError.domain) code=\(nsError.code))"
        case .unknown:
            return "unknown"
        }
    }

    private nonisolated static func logDescription(for error: any Error) -> String {
        let nsError = error as NSError
        return "domain=\(nsError.domain) code=\(nsError.code)"
    }

    private nonisolated static func startDecodeProducer(decoder: VAPVideoDecoder,
                                                        startIndex: Int,
                                                        totalFrames: Int) -> Task<Void, Never> {
        Task.detached(priority: .userInitiated) {
            var index = startIndex
            while index < totalFrames {
                do {
                    try Task.checkCancellation()
                    try await decoder.waitUntilBufferHasSpace()
                    try Task.checkCancellation()
                    try await decoder.decodeFrame(at: index)
                    index += 1
                } catch is CancellationError {
                    return
                } catch {
                    decoderLog.error("decode producer failed index=\(index): \(Self.logDescription(for: error))")
                    return
                }
            }
        }
    }

    private nonisolated static func requiredBufferDepth(for samples: [VAPMP4Sample]) -> Int {
        guard !samples.isEmpty else { return 1 }

        var sampleIndexForPresentation = [Int](repeating: 0, count: samples.count)
        for (sampleIndex, sample) in samples.enumerated()
            where sample.presentationIndex >= 0 && sample.presentationIndex < samples.count {
            sampleIndexForPresentation[sample.presentationIndex] = sampleIndex
        }

        var depth = 1
        for (presentationIndex, sampleIndex) in sampleIndexForPresentation.enumerated() {
            depth = max(depth, sampleIndex - presentationIndex + 1)
        }
        return depth
    }

    // MARK: - 音频

    private func setupAudio(localFilePath: String) {
        // AVAudioPlayer 不支持网络 URL；远程文件跳过音频初始化。
        guard !localFilePath.hasPrefix("http://"), !localFilePath.hasPrefix("https://") else { return }
        let url = URL(fileURLWithPath: localFilePath)
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - 后台处理

    private func installBackgroundObservers(for policy: VAPBackgroundPlaybackPolicy) {
        guard policy != .ignore else { return }
        let nc = NotificationCenter.default
        backgroundObserver = nc.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                switch policy {
                case .stop:
                    self.stop()
                case .pauseAndResume:
                    self.pause()
                case .ignore:
                    break
                }
            }
        }
        if policy == .pauseAndResume {
            foregroundObserver = nc.addObserver(
                forName: UIApplication.willEnterForegroundNotification,
                object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                Task { @MainActor in self.resume() }
            }
        }
    }

    private func removeLifecycleObservers() {
        if let obs = backgroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver  { NotificationCenter.default.removeObserver(obs) }
        backgroundObserver = nil
        foregroundObserver  = nil
    }

    // MARK: - 蒙版纹理工厂

    private static func makeTexture(from mask: VAPMaskConfiguration, device: MTLDevice) -> MTLTexture? {
        let w = Int(mask.dataSize.width)
        let h = Int(mask.dataSize.height)
        guard w > 0, h > 0, mask.data.count >= w * h else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        mask.data.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: w)
        }
        return texture
    }
}
