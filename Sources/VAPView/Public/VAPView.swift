// VAPView.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// Drop-in UIView replacement for QGVAPWrapView.
// Embeds VAPMetalView and drives VAPPlayer internally.

import UIKit

@MainActor
public final class VAPView: UIView {

    // MARK: - Public properties

    /// Destroy the player automatically after playback finishes.
    /// Defaults to false — keeps Metal objects alive for efficient reuse (e.g. in lists).
    public var autoDestroyAfterFinish: Bool = false

    /// Override FPS (0 = use MP4 header value).
    public var fps: Int = 0

    /// Mutes audio when true.
    public var isMuted: Bool = false {
        didSet { player?.setMuted(isMuted) }
    }

    /// Called before playback starts. Return false to cancel playback.
    public var shouldStartPlay: ((VAPPlaybackConfiguration) -> Bool)?

    /// Resource loader used to resolve remote `http(s)://` URLs to local file paths.
    /// Defaults to `VAPDiskCache.shared`. Replace with a custom implementation to
    /// control download and caching behaviour.
    public var resourceLoader: VAPResourceLoader = VAPDiskCache.shared

    // MARK: - Private

    private var player: VAPPlayer?
    private var playTask: Task<Void, Never>?
    private var eventHandler: ((VAPEvent) -> Void)?
    private var gestureHandlers: [(UIGestureRecognizer, (UIGestureRecognizer) -> Void)] = []

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - Gesture API

    /// Add a tap gesture on the Metal view. The handler fires on each tap.
    /// The gesture persists across repeat cycles and is only removed when `teardown()` is called.
    public func addVapTapGesture(_ handler: @escaping (UITapGestureRecognizer) -> Void) {
        let tap = UITapGestureRecognizer()
        addVapGesture(tap) { gesture in
            guard let tap = gesture as? UITapGestureRecognizer else { return }
            handler(tap)
        }
    }

    /// Add any UIGestureRecognizer on the Metal view.
    /// The gesture persists across repeat cycles and is only removed when `teardown()` is called.
    public func addVapGesture(_ gesture: UIGestureRecognizer,
                               callback: @escaping (UIGestureRecognizer) -> Void) {
        gestureHandlers.append((gesture, callback))
        gesture.addTarget(self, action: #selector(handleVapGesture(_:)))
        // Attach to metalView if already created, otherwise attached on next play.
        player?.metalView.addGestureRecognizer(gesture)
    }

    /// Remove a previously registered gesture and detach it from the Metal view.
    public func removeVapGesture(_ gesture: UIGestureRecognizer) {
        gestureHandlers.removeAll { $0.0 === gesture }
        gesture.removeTarget(self, action: #selector(handleVapGesture(_:)))
        player?.metalView.removeGestureRecognizer(gesture)
    }

    /// VAPView itself does not handle gestures — use addVapTapGesture / addVapGesture.
    @available(*, unavailable, message: "Use addVapTapGesture or addVapGesture instead.")
    override public func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
    }

    @objc private func handleVapGesture(_ sender: UIGestureRecognizer) {
        for (g, cb) in gestureHandlers where g === sender { cb(sender) }
    }

    // MARK: - Public API

    /// Asynchronously downloads and caches a VAP resource.
    ///
    /// Use this method to warm the disk cache before creating a view. Concurrent
    /// requests for the same URL through the same `VAPDiskCache` instance share a
    /// single download, and each caller receives progress updates.
    ///
    /// - Parameters:
    ///   - filePath: The local file path or HTTPS URL of the resource. Local paths
    ///     are returned unchanged.
    ///   - resourceLoader: The object that resolves the resource. The default value
    ///     is `VAPDiskCache.shared`.
    ///   - onProgress: A closure the loader calls with progress values in the range
    ///     `0...1`.
    /// - Returns: A local file path suitable for playback.
    @discardableResult
    @concurrent public nonisolated static func prefetch(filePath: String,
                                                        resourceLoader: VAPResourceLoader = VAPDiskCache.shared,
                                                        onProgress: (@MainActor @Sendable (Double) -> Void)? = nil) async throws -> String {
        let progressHandler: @MainActor @Sendable (Double) -> Void = onProgress ?? { _ in }
        return try await resourceLoader.localPath(for: filePath, onProgress: progressHandler)
    }

    /// Play a VAP/HWD animation file.
    ///
    /// The renderer automatically selects the appropriate pipeline based on the MP4 content:
    /// - **VAP path**: If the MP4 contains a `vapc` box, the renderer reads `rgbFrame`/`aFrame`
    ///   from it to determine exact RGB and alpha regions. In this case `configuration.alphaPlacement` is ignored.
    /// - **HWD path**: If no `vapc` box is present, the renderer uses `configuration.alphaPlacement` to
    ///   determine the alpha channel position (left/right/top/bottom 50% split).
    ///
    /// ## VAPPlaybackConfiguration properties
    ///
    /// | Property | Description |
    /// |---|---|
    /// | `source` | Local file path or `http(s)://` URL. Remote URLs are downloaded via ``VAPDiskCache`` before playback; progress is reported through `.downloading` events. |
    /// | `alphaPlacement` | Alpha channel position (`.left`/`.right`/`.top`/`.bottom`). **Only used for HWD path** — ignored when the MP4 `vapc` box contains `rgbFrame`/`aFrame`. Default: `.right`. |
    /// | `backgroundPolicy` | Behavior when the app enters background: `.stop` (default), `.pauseAndResume`, or `.ignore`. |
    /// | `contentMode` | Display scaling: `.scaleToFill` (default), `.aspectFit`, or `.aspectFill`. |
    /// | `attachmentSources` | Maps `srcId` -> ``VAPAttachmentSource`` (`.image`, `.imageURL`, `.text`) for VAP attachment slots defined in the `vapc` config. |
    /// | `imageLoader` | Custom async image loader for `.imageURL` type attachments. Required when using `.imageURL` attachment sources. |
    /// | `frameBufferCapacity` | Decoded frame buffer depth. Default: 3. |
    /// | `preferredFramesPerSecond` | Override playback FPS. 0 (default) = use the value from MP4 header. |
    /// | `playsAudio` | Whether to play the audio track if present. Default: `true`. |
    /// | `mask` | Optional external alpha mask applied over every frame (VAP path only). |
    /// | `loopCount` | Playback repeat count. 1 = once (default), 0 = infinite, N = N times. When `0`, `.didFinish` is never emitted — call `stop()` explicitly. |
    ///
    /// ## Examples
    ///
    /// **Basic — play a local file (HWD path, alphaPlacement takes effect):**
    /// ```swift
    /// let playbackConfiguration = VAPPlaybackConfiguration(
    ///     source: Bundle.main.path(forResource: "animation", ofType: "mp4")!,
    ///     alphaPlacement: .right
    /// )
    /// vapView.play(playbackConfiguration)
    /// ```
    ///
    /// **Remote URL with progress and event handling:**
    /// ```swift
    /// let playbackConfiguration = VAPPlaybackConfiguration(
    ///     source: "https://example.com/gift.mp4",
    ///     backgroundPolicy: .pauseAndResume,
    ///     contentMode: .aspectFit,
    ///     loopCount: 3
    /// )
    /// vapView.play(playbackConfiguration) { event in
    ///     switch event {
    ///     case .downloading(let progress):
    ///         print("downloading: \(Int(progress * 100))%")
    ///     case .didStart:
    ///         print("playback started")
    ///     case .didPlayFrame(let index):
    ///         break // called every frame
    ///     case .didLoopFinish(let loop, let totalFrames):
    ///         print("loop \(loop) done, \(totalFrames) frames")
    ///     case .didFinish(let totalFrames):
    ///         print("finished, total frames: \(totalFrames)")
    ///     case .didStop(let lastFrame):
    ///         print("stopped at frame \(lastFrame)")
    ///     case .didFail(let error):
    ///         print("error: \(error)")
    ///     }
    /// }
    /// ```
    ///
    /// **VAP path with dynamic attachments (images, text overlays):**
    /// ```swift
    /// let playbackConfiguration = VAPPlaybackConfiguration(
    ///     source: "https://example.com/vapx_animation.mp4",
    ///     contentMode: .aspectFit,
    ///     attachmentSources: [
    ///         "avatar": .image(UIImage(named: "avatar")!),
    ///         "name":   .text("张三"),
    ///         "banner": .imageURL("https://example.com/banner.png"),
    ///     ],
    ///     imageLoader: { url, context in
    ///         // Custom async image loading for .imageURL attachments
    ///         let (data, _) = try await URLSession.shared.data(from: url)
    ///         return UIImage(data: data) ?? UIImage()
    ///     }
    /// )
    /// vapView.play(playbackConfiguration)
    /// ```
    ///
    /// **External mask overlay (VAP path only):**
    /// ```swift
    /// let maskData = Data(repeating: 0xFF, count: 200 * 200) // R8 grayscale
    /// let playbackConfiguration = VAPPlaybackConfiguration(
    ///     source: "path/to/animation.mp4",
    ///     mask: VAPMaskConfiguration(data: maskData, dataSize: CGSize(width: 200, height: 200))
    /// )
    /// vapView.play(playbackConfiguration)
    /// ```
    ///
    /// - Parameters:
    ///   - configuration: Full play configuration. See property table above.
    ///   - eventHandler: Optional closure called for each ``VAPEvent``.
    public func play(_ configuration: VAPPlaybackConfiguration, eventHandler: ((VAPEvent) -> Void)? = nil) {
        var activeConfiguration = configuration
        activeConfiguration.preferredFramesPerSecond = fps > 0
            ? fps
            : configuration.preferredFramesPerSecond

        // shouldStart gate
        if let gate = shouldStartPlay, !gate(activeConfiguration) { return }

        // Stop any existing playback but keep player/metalView alive for reuse.
        playTask?.cancel()
        playTask = nil
        player?.stop()
        self.eventHandler = eventHandler

        ensurePlayer()
        guard let p = player else { return }

        // Wrap caller's eventHandler to handle autoDestroyAfterFinish internally.
        let wrappedEventHandler: ((VAPEvent) -> Void)? = { [weak self] event in
            guard let self else { return }
            eventHandler?(event)
            switch event {
            case .didFinish, .didStop:
                if self.autoDestroyAfterFinish { self.teardown() }
            default:
                break
            }
        }

        let isRemote = activeConfiguration.source.hasPrefix("http://") || activeConfiguration.source.hasPrefix("https://")
        if isRemote {
            let loader = resourceLoader
            let remoteConfiguration = activeConfiguration
            playTask = Task { @MainActor [weak self] in
                do {
                    let localPath = try await loader.localPath(for: remoteConfiguration.source, onProgress: { progress in
                        wrappedEventHandler?(.downloading(progress: progress))
                    })
                    guard let self, !Task.isCancelled else { return }
                    var localConfiguration = remoteConfiguration
                    localConfiguration.source = localPath
                    self.player?.play(localConfiguration, eventHandler: wrappedEventHandler)
                    self.player?.setMuted(self.isMuted)
                } catch {
                    let vapErr = error as? VAPError ?? .unknown(error.localizedDescription)
                    wrappedEventHandler?(.didFail(vapErr))
                }
            }
        } else {
            p.play(activeConfiguration, eventHandler: wrappedEventHandler)
            p.setMuted(isMuted)
        }
    }

    /// Convenience overload accepting individual parameters.
    public func play(filePath: String,
                     alphaPlacement: VAPAlphaPlacement = .right,
                     backgroundPolicy: VAPBackgroundPlaybackPolicy = .stop,
                     contentMode: VAPContentMode = .scaleToFill,
                     attachmentSources: [String: VAPAttachmentSource] = [:],
                     imageLoader: VAPAttachmentImageLoader? = nil,
                     frameBufferCapacity: Int = 3,
                     mask: VAPMaskConfiguration? = nil,
                     playsAudio: Bool = true,
                     loopCount: Int = 1,
                     eventHandler: ((VAPEvent) -> Void)? = nil) {
        let playbackConfiguration = VAPPlaybackConfiguration(
            source: filePath,
            alphaPlacement: alphaPlacement,
            backgroundPolicy: backgroundPolicy,
            contentMode: contentMode,
            attachmentSources: attachmentSources,
            imageLoader: imageLoader,
            frameBufferCapacity: frameBufferCapacity,
            preferredFramesPerSecond: fps,
            playsAudio: playsAudio,
            mask: mask,
            loopCount: loopCount
        )
        play(playbackConfiguration, eventHandler: eventHandler)
    }

    public func stop() {
        playTask?.cancel()
        playTask = nil
        player?.stop()
        teardown()
    }

    public func pause() {
        player?.pause()
    }

    public func resume() {
        player?.resume()
    }

    // MARK: - Layout

    public override func layoutSubviews() {
        super.layoutSubviews()
        player?.metalView.frame = bounds
    }

    // MARK: - Private

    private func ensurePlayer() {
        guard player == nil else { return }
        let p = VAPPlayer(frame: bounds)
        p.metalView.frame = bounds
        p.metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(p.metalView)
        // Attach any pre-registered gestures to the new metalView.
        for (g, _) in gestureHandlers {
            p.metalView.addGestureRecognizer(g)
        }
        player = p
    }

    private func teardown() {
        playTask?.cancel()
        playTask = nil
        // Remove gestures before removing metalView so they can be re-attached later.
        if let mv = player?.metalView {
            for (g, _) in gestureHandlers { mv.removeGestureRecognizer(g) }
            mv.removeFromSuperview()
        }
        player = nil
    }
}
