// VAPPlayer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import UIKit
import Metal
import AVFoundation

// MARK: - Configuration

public struct VAPPlayConfig: Sendable {
    /// Source file path or URL string
    public var filePath: String
    /// Alpha channel position in the video frame.
    ///
    /// Only takes effect when the MP4 does **not** contain a `vapc` box with
    /// `rgbFrame`/`aFrame` fields. When those fields are present, the renderer
    /// reads the exact RGB and alpha regions from the config and this value is ignored.
    public var blendMode: VAPTextureBlendMode
    /// Background lifecycle behaviour
    public var backgroundPolicy: VAPBackgroundPolicy
    /// Content scale mode
    public var contentMode: VAPContentMode
    /// Attachment sources: srcId -> typed value (image, URL string, or text)
    public var attachmentSources: [String: VAPAttachmentSource]
    /// Optional image loader for network/local URL attachments
    public var imageLoader: VAPImageLoader?
    /// Decode buffer depth (default 3)
    public var bufferCount: Int
    /// Override FPS (0 = use MP4 header value)
    public var fps: Int
    /// Whether to play audio track if present
    public var playAudio: Bool
    /// Optional external mask applied over every frame (VAP renderer path only)
    public var maskInfo: VAPMaskInfo?
    /// Number of times to play. 1 = once (default), 0 = infinite, N = N times.
    /// Loop is handled inside the player — no Metal/texture teardown between cycles.
    ///
    /// - Important: When `loopCount == 0` (infinite loop), playback never emits `.didFinish`.
    ///   You **must** call `stop()` or `pause()` explicitly to end playback, otherwise the
    ///   internal Task runs indefinitely and holds all associated resources (Metal textures,
    ///   decoder, audio player) until the `VAPPlayer` is deallocated.
    public var loopCount: Int

    public init(filePath: String,
                blendMode: VAPTextureBlendMode = .alphaRight,
                backgroundPolicy: VAPBackgroundPolicy = .stop,
                contentMode: VAPContentMode = .scaleToFill,
                attachmentSources: [String: VAPAttachmentSource] = [:],
                imageLoader: VAPImageLoader? = nil,
                bufferCount: Int = 3,
                fps: Int = 0,
                playAudio: Bool = true,
                maskInfo: VAPMaskInfo? = nil,
                loopCount: Int = 1) {
        self.filePath          = filePath
        self.blendMode         = blendMode
        self.backgroundPolicy  = backgroundPolicy
        self.contentMode       = contentMode
        self.attachmentSources = attachmentSources
        self.imageLoader       = imageLoader
        self.bufferCount       = bufferCount
        self.fps               = fps
        self.playAudio         = playAudio
        self.maskInfo          = maskInfo
        self.loopCount         = loopCount
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

    private var currentConfig: VAPPlayConfig?
    private var currentFrameIndex: Int = 0
    private let mtlDevice: MTLDevice?
    private var onEventCallback: ((VAPEvent) -> Void)?
    private var epoch: Int = 0

    // MARK: - Init

    public init(frame: CGRect = .zero) {
        self.metalView = VAPMetalView(frame: frame)
        self.mtlDevice = MTLCreateSystemDefaultDevice()
        var cont: AsyncStream<VAPEvent>.Continuation!
        self._eventStream = AsyncStream { cont = $0 }
        self._eventContinuation = cont
    }

    deinit {
        _eventContinuation.finish()
    }

    // MARK: - Public API

    public func play(config: VAPPlayConfig, onEvent: ((VAPEvent) -> Void)? = nil) {
        stop()
        epoch &+= 1
        currentConfig = config
        currentFrameIndex = 0
        onEventCallback = onEvent
        metalView.vapContentMode = config.contentMode
        setupBackgroundObservers(policy: config.backgroundPolicy)
        let myEpoch = epoch
        playbackTask = Task { [weak self] in
            await self?.runPlayback(config: config, startFrame: 0, epoch: myEpoch)
        }
    }

    public func stop() {
        playbackTask?.cancel()
        playbackTask = nil
        currentFrameIndex = 0
        onEventCallback = nil
        stopAudio()
        removeBackgroundObservers()
        currentConfig = nil
    }

    private func emitEvent(_ event: VAPEvent, epoch: Int) {
        guard epoch == self.epoch else { return }
        _eventContinuation.yield(event)
        onEventCallback?(event)
    }

    public func pause() {
        playbackTask?.cancel()
        playbackTask = nil
        audioPlayer?.pause()
    }

    public func resume() {
        guard let config = currentConfig else { return }
        audioPlayer?.play()
        let startFrame = currentFrameIndex
        let myEpoch = epoch
        playbackTask = Task { [weak self] in
            await self?.runPlayback(config: config, startFrame: startFrame, epoch: myEpoch)
        }
    }

    public func setMute(_ mute: Bool) {
        audioPlayer?.volume = mute ? 0 : 1
    }

    // MARK: - Playback loop

    private func runPlayback(config: VAPPlayConfig, startFrame: Int = 0, epoch: Int) async {
        do {
            playerLog.debug("runPlayback start filePath=\(config.filePath)")
            // 1. Parse MP4 on background thread
            let info: VAPMP4Info = try await Task.detached(priority: .userInitiated) {
                try VAPMP4Parser.parse(filePath: config.filePath)
            }.value
            playerLog.debug("parsed: frames=\(info.frameCount) fps=\(info.fps) size=\(info.width)x\(info.height) hasAudio=\(info.hasAudioTrack) vapc=\(info.vapcJSON != nil)")
            playerLog.debug("config: blendMode=\(config.blendMode.rawValue) contentMode=\(config.contentMode) loopCount=\(config.loopCount)")

            // 2. Validate VAP version
            if let jsonData = info.vapcJSON {
                let cfg = try? JSONDecoder().decode(VAPConfig.self, from: jsonData)
                if let v = cfg?.info.version, v > kVAPMaxCompatibleVersion {
                    throw VAPError.incompatibleVersion(v)
                }
            }

            // 3. Metal device (cached at init) + renderer (reused across all loop cycles)
            guard let device = mtlDevice else {
                playerLog.error("Metal device unavailable")
                throw VAPError.metalUnavailable
            }
            playerLog.debug("Metal device: \(device.name)")

            let useVAPPath = info.vapcJSON != nil
            let hwdRenderer  = useVAPPath ? nil       : try VAPHWDRenderer(device: device)
            let vapRenderer  = useVAPPath ? try VAPRenderer(device: device) : nil
            playerLog.debug("useVAPPath=\(useVAPPath) hwdRenderer=\(hwdRenderer != nil) vapRenderer=\(vapRenderer != nil)")

            // 4. Load attachment config (VAP path, reused across all loop cycles)
            var attachResources: VAPAttachmentResources?
            if useVAPPath, let jsonData = info.vapcJSON {
                let _device = device
                let _loader = config.imageLoader
                let _sources = config.attachmentSources
                attachResources = try await Task.detached(priority: .userInitiated) {
                    let mgr = VAPConfigManager(device: _device, imageLoader: _loader)
                    return try await mgr.load(vapcJSON: jsonData, sources: _sources)
                }.value
                playerLog.debug("attachResources loaded")
            }

            // 4b. External mask override (VAPMaskInfo → MTLTexture, reused across all loop cycles)
            let externalMaskTexture: MTLTexture? = config.maskInfo.flatMap {
                Self.makeTexture(from: $0, device: device)
            }

            // Loop state
            let loopCount = config.loopCount  // 0 = infinite
            var loopIndex = 0

            // 5. Create decoder (reset between cycles, not recreated)
            let reorderBufferDepth = Self.requiredBufferDepth(for: info.videoSamples)
            let bufCount    = max(max(1, config.bufferCount), reorderBufferDepth)
            let decoder     = VAPVideoDecoder(info: info, bufferCapacity: bufCount)
            try await decoder.prepare()
            playerLog.debug("decoder prepared bufCount=\(bufCount) totalFrames=\(info.frameCount)")

            let fps           = config.fps > 0 ? config.fps : max(kVAPMinFPS, min(info.fps, kVAPMaxFPS))
            let frameDuration = 1.0 / Double(fps)
            let totalFrames   = info.frameCount
            playerLog.debug("fps=\(fps) frameDuration=\(frameDuration)")

            // Audio — create once, reused across all loop cycles
            if config.playAudio && info.hasAudioTrack {
                setupAudio(filePath: config.filePath)
            }

            // 6. Outer loop — Metal/texture/audio objects are reused across all cycles
            repeat {
                // Reset decoder for cycles after the first
                if loopIndex > 0 {
                    try await decoder.reset()
                    // Seek audio back to start
                    audioPlayer?.currentTime = 0
                }

                let cycleStart = loopIndex == 0 ? startFrame : 0
                let initialDecodeEnd = min(cycleStart + bufCount, totalFrames)
                for i in cycleStart..<initialDecodeEnd {
                    guard !Task.isCancelled else {
                        await decoder.invalidate()
                        return
                    }
                    try await decoder.decodeFrame(at: i)
                }
                let decodeProducer = Self.startDecodeProducer(decoder: decoder,
                                                               startIndex: initialDecodeEnd,
                                                               totalFrames: totalFrames)

                audioPlayer?.play()
                playerLog.debug("didStart loop=\(loopIndex)")
                emitEvent(.didStart, epoch: epoch)

                var frameIndex = cycleStart

                // Inner render loop
                while frameIndex < totalFrames {
                    if Task.isCancelled {
                        decodeProducer.cancel()
                        stopAudio()
                        playerLog.debug("didStop lastFrame=\(frameIndex)")
                        emitEvent(.didStop(lastFrame: frameIndex), epoch: epoch)
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
                        playerLog.error("frame \(frameIndex) stalled — skipping")
                        frameIndex += 1
                        continue
                    }

                    // Render
                    if frameIndex == 0 { playerLog.debug("rendering first frame via \(useVAPPath ? "VAP" : "HWD") path") }
                    if let hwd = hwdRenderer {
                        hwd.render(pixelBuffer: frame.pixelBuffer,
                                   into: metalView,
                                   blendMode: config.blendMode)
                    } else if let vap = vapRenderer {
                        vap.render(pixelBuffer: frame.pixelBuffer,
                                   into: metalView,
                                   blendMode: config.blendMode,
                                   config: attachResources?.config,
                                   attachmentTextures: attachResources?.textures ?? [:],
                                   maskTexture: externalMaskTexture ?? attachResources?.maskTexture,
                                   frameIndex: frame.frameIndex)
                    }

                    emitEvent(.didPlayFrame(index: frame.frameIndex), epoch: epoch)

                    frameIndex = frame.frameIndex + 1
                    currentFrameIndex = frameIndex

                    // Frame pacing
                    let elapsed = CACurrentMediaTime() - frameStart
                    let remaining = frameDuration - elapsed
                    if remaining > 0.001 {
                        try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
                    }
                }
                decodeProducer.cancel()
                await decodeProducer.value

                stopAudio()

                loopIndex += 1
                let isLastCycle = loopCount != 0 && loopIndex >= loopCount
                if isLastCycle {
                    playerLog.debug("didFinish totalFrames=\(totalFrames)")
                    emitEvent(.didFinish(totalFrames: totalFrames), epoch: epoch)
                } else {
                    playerLog.debug("didLoopFinish loop=\(loopIndex) totalFrames=\(totalFrames)")
                    emitEvent(.didLoopFinish(loop: loopIndex, totalFrames: totalFrames), epoch: epoch)
                }

            } while loopCount == 0 || loopIndex < loopCount

            await decoder.invalidate()

        } catch let error as VAPError {
            playerLog.error("VAPError: \(error)")
            emitEvent(.didFail(error), epoch: epoch)
        } catch {
            if !Task.isCancelled {
                playerLog.error("Unknown error: \(error)")
                emitEvent(.didFail(.unknown(error.localizedDescription)), epoch: epoch)
            }
        }
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
                    decoderLog.error("decode producer failed index=\(index): \(error)")
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

    private func setupAudio(filePath: String) {
        // AVAudioPlayer does not support network URLs — skip for remote files.
        guard !filePath.hasPrefix("http://"), !filePath.hasPrefix("https://") else { return }
        let url = URL(fileURLWithPath: filePath)
        audioPlayer = try? AVAudioPlayer(contentsOf: url)
        audioPlayer?.prepareToPlay()
    }

    private func stopAudio() {
        audioPlayer?.stop()
        audioPlayer = nil
    }

    // MARK: - Background handling

    private func setupBackgroundObservers(policy: VAPBackgroundPolicy) {
        guard policy != .doNothing else { return }
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
                case .doNothing:
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

    private func removeBackgroundObservers() {
        if let obs = backgroundObserver { NotificationCenter.default.removeObserver(obs) }
        if let obs = foregroundObserver  { NotificationCenter.default.removeObserver(obs) }
        backgroundObserver = nil
        foregroundObserver  = nil
    }

    // MARK: - Mask texture factory

    private static func makeTexture(from maskInfo: VAPMaskInfo, device: MTLDevice) -> MTLTexture? {
        let w = Int(maskInfo.dataSize.width)
        let h = Int(maskInfo.dataSize.height)
        guard w > 0, h > 0, maskInfo.data.count >= w * h else { return nil }
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: w, height: h, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        maskInfo.data.withUnsafeBytes { ptr in
            texture.replace(
                region: MTLRegionMake2D(0, 0, w, h),
                mipmapLevel: 0,
                withBytes: ptr.baseAddress!,
                bytesPerRow: w)
        }
        return texture
    }
}
