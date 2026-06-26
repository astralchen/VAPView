// VAPPlayer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import UIKit
import Metal
import AVFoundation

// MARK: - Configuration

public struct VAPPlaybackConfiguration: Sendable {
    /// Source file path or URL string
    public var source: String
    /// Alpha channel position in the video frame.
    ///
    /// Only takes effect when the MP4 does **not** contain a `vapc` box with
    /// `rgbFrame`/`aFrame` fields. When those fields are present, the renderer
    /// reads the exact RGB and alpha regions from the config and this value is ignored.
    public var alphaPlacement: VAPAlphaPlacement
    /// Background lifecycle behaviour
    public var backgroundPolicy: VAPBackgroundPlaybackPolicy
    /// Content scale mode
    public var contentMode: VAPContentMode
    /// Attachment sources: srcId -> typed value (image, URL string, or text)
    public var attachmentSources: [String: VAPAttachmentSource]
    /// Optional image loader for network/local URL attachments
    public var imageLoader: VAPAttachmentImageLoader?
    /// Decode buffer depth (default 3)
    public var frameBufferCapacity: Int
    /// Override FPS (0 = use MP4 header value)
    public var preferredFramesPerSecond: Int
    /// Whether to play audio track if present
    public var playsAudio: Bool
    /// Optional external mask applied over every frame (VAP renderer path only)
    public var mask: VAPMaskConfiguration?
    /// Number of times to play. 1 = once (default), 0 = infinite, N = N times.
    /// Loop is handled inside the player — no Metal/texture teardown between cycles.
    ///
    /// - Important: When `loopCount == 0` (infinite loop), playback never emits `.didFinish`.
    ///   You **must** call `stop()` or `pause()` explicitly to end playback, otherwise the
    ///   internal Task runs indefinitely and holds all associated resources (Metal textures,
    ///   decoder, audio player) until the `VAPPlayer` is deallocated.
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

// MARK: - Player

@MainActor
public final class VAPPlayer {

    // MARK: Public

    public let metalView: VAPMetalView

    /// Stream of playback lifecycle events. Yields on the caller's context.
    /// - Important: This stream supports only a single concurrent consumer.
    ///   Starting a second `for await` loop on the same `VAPPlayer` instance
    ///   will not receive any events.
    public var events: AsyncStream<VAPEvent> { _eventStream }

    // MARK: Private state

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

    // MARK: - Init

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

    // MARK: - Public API

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

    // MARK: - Playback loop

    private func runPlayback(configuration: VAPPlaybackConfiguration, startFrame: Int = 0, generation: Int) async {
        do {
            playerLog.debug("runPlayback start source=\(Self.logSourceDescription(configuration.source))")
            // 1. Parse MP4 on background thread
            let info: VAPMP4Info = try await Task.detached(priority: .userInitiated) {
                try VAPMP4Parser.parse(localFilePath: configuration.source)
            }.value
            playerLog.debug("parsed: frames=\(info.frameCount) fps=\(info.fps) size=\(info.width)x\(info.height) hasAudio=\(info.hasAudioTrack) vapc=\(info.vapcJSON != nil)")
            playerLog.debug("configuration: alphaPlacement=\(configuration.alphaPlacement.rawValue) contentMode=\(configuration.contentMode) loopCount=\(configuration.loopCount)")

            // 2. Validate VAP version
            if let jsonData = info.vapcJSON {
                let cfg = try? JSONDecoder().decode(VAPConfig.self, from: jsonData)
                if let v = cfg?.info.version, v > VAPPlaybackDefaults.maximumCompatibleConfigVersion {
                    throw VAPError.incompatibleVersion(v)
                }
            }

            // 3. Metal device (cached at init) + renderer (reused across all loop cycles)
            guard let device = metalDevice else {
                playerLog.error("Metal device unavailable")
                throw VAPError.metalUnavailable
            }
            playerLog.debug("Metal device: \(device.name)")

            let usesAttachmentRenderer = info.vapcJSON != nil
            let splitAlphaRenderer = usesAttachmentRenderer ? nil : try VAPHWDRenderer(device: device)
            let attachmentRenderer = usesAttachmentRenderer ? try VAPRenderer(device: device) : nil
            playerLog.debug("usesAttachmentRenderer=\(usesAttachmentRenderer) splitAlphaRenderer=\(splitAlphaRenderer != nil) attachmentRenderer=\(attachmentRenderer != nil)")

            // 4. Load attachment config (VAP path, reused across all loop cycles)
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

            // 4b. External mask override (VAPMaskConfiguration -> MTLTexture, reused across all loop cycles)
            let externalMaskTexture: MTLTexture? = configuration.mask.flatMap {
                Self.makeTexture(from: $0, device: device)
            }

            // Loop state
            let loopCount = configuration.loopCount  // 0 = infinite
            var loopIndex = 0

            // 5. Create decoder (reset between cycles, not recreated)
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

            // Audio — create once, reused across all loop cycles
            if configuration.playsAudio && info.hasAudioTrack {
                setupAudio(localFilePath: configuration.source)
            }

            // 6. Outer loop — Metal/texture/audio objects are reused across all cycles
            var didFinishPlayback = false
            repeat {
                // Reset decoder for cycles after the first
                if loopIndex > 0 {
                    try await decoder.reset()
                    // Seek audio back to start
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

                    // Inner render loop
                    while frameIndex < totalFrames {
                        if Task.isCancelled {
                            decodeProducerTask.cancel()
                            await decodeProducerTask.value
                            stopAudio()
                            await decoder.invalidate()
                            return
                        }

                        let frameStart = CACurrentMediaTime()

                        // Pop the exact presentation frame — wait up to one full frame duration before skipping.
                        // Each retry sleeps 2 ms; ~(frameDuration / 0.002) retries max.
                        var decodedFrame: VAPDecodedFrame?
                        let maxRetries = max(10, Int(frameDuration / 0.002))
                        for _ in 0..<maxRetries {
                            decodedFrame = await decoder.popFrame(at: frameIndex)
                            if decodedFrame != nil { break }
                            try await Task.sleep(nanoseconds: 2_000_000)
                        }
                        guard let frame = decodedFrame else {
                            // Decoder stalled beyond one frame budget — skip to keep timing.
                            playerLog.debug("frame \(frameIndex) stalled; skipping")
                            frameIndex += 1
                            continue
                        }

                        // Render
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

                        // Frame pacing
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

    // MARK: - Audio

    private func setupAudio(localFilePath: String) {
        // AVAudioPlayer does not support network URLs — skip for remote files.
        guard !localFilePath.hasPrefix("http://"), !localFilePath.hasPrefix("https://") else { return }
        let url = URL(fileURLWithPath: localFilePath)
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Background handling

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

    // MARK: - Mask texture factory

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
