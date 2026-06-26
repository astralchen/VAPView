// VAPView.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// QGVAPWrapView 的 UIView 替代实现。
// 内部嵌入 VAPMetalView，并驱动 VAPPlayer 播放。

import UIKit

@MainActor
public final class VAPView: UIView {

    // MARK: - 公开属性

    /// 播放完成后是否自动销毁播放器。
    /// 默认值为 false；会保留 Metal 对象，方便列表等场景高效复用。
    public var automaticallyDestroysPlayerAfterPlayback: Bool = false

    /// 覆盖播放帧率（0 表示使用 MP4 头信息中的值）。
    public var preferredFramesPerSecond: Int = 0

    /// 为 true 时静音。
    public var isMuted: Bool = false {
        didSet { player?.setMuted(isMuted) }
    }

    /// 播放开始前调用；返回 false 可取消播放。
    public var shouldStartPlayback: ((VAPPlaybackConfiguration) -> Bool)?

    /// 用于将远程 HTTPS URL 解析为本地文件路径的资源加载器。
    /// 默认值为 `VAPDiskCache.shared`。可以替换为自定义实现来控制下载和缓存行为。
    /// 自定义加载器可以支持其他 scheme，但默认磁盘缓存会拒绝明文 HTTP URL。
    public var resourceLoader: VAPResourceLoader = VAPDiskCache.shared

    // MARK: - 私有状态

    private var player: VAPPlayer?
    private var playTask: Task<Void, Never>?
    private var playbackGeneration: Int = 0
    private var gestureHandlers: [(gesture: UIGestureRecognizer, handler: (UIGestureRecognizer) -> Void)] = []

    // MARK: - 初始化

    public override init(frame: CGRect) {
        super.init(frame: frame)
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: - 手势 API

    /// 在 Metal 视图上添加点击手势；每次点击都会触发处理闭包。
    /// 手势会在重复播放周期中保留，只会在调用 `teardown()` 时移除。
    public func addTapGesture(_ handler: @escaping (UITapGestureRecognizer) -> Void) {
        let tap = UITapGestureRecognizer()
        addGesture(tap) { gesture in
            guard let tap = gesture as? UITapGestureRecognizer else { return }
            handler(tap)
        }
    }

    /// 在 Metal 视图上添加任意 UIGestureRecognizer。
    /// 手势会在重复播放周期中保留，只会在调用 `teardown()` 时移除。
    public func addGesture(_ gesture: UIGestureRecognizer,
                           handler: @escaping (UIGestureRecognizer) -> Void) {
        gestureHandlers.append((gesture, handler))
        gesture.addTarget(self, action: #selector(handleGesture(_:)))
        // 如果 metalView 已创建则立即挂载，否则在下次播放时挂载。
        player?.metalView.addGestureRecognizer(gesture)
    }

    /// 移除已注册的手势，并从 Metal 视图上解除挂载。
    public func removeGesture(_ gesture: UIGestureRecognizer) {
        gestureHandlers.removeAll { $0.gesture === gesture }
        gesture.removeTarget(self, action: #selector(handleGesture(_:)))
        player?.metalView.removeGestureRecognizer(gesture)
    }

    /// VAPView 自身不处理手势；请使用 addTapGesture / addGesture。
    @available(*, unavailable, message: "Use addTapGesture or addGesture(_:handler:) instead.")
    override public func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
        super.addGestureRecognizer(gestureRecognizer)
    }

    @objc private func handleGesture(_ sender: UIGestureRecognizer) {
        for (gesture, handler) in gestureHandlers where gesture === sender { handler(sender) }
    }

    // MARK: - 公开 API

    /// 异步下载并缓存 VAP 资源。
    ///
    /// 可在创建视图前使用该方法预热磁盘缓存。通过同一个 `VAPDiskCache` 实例
    /// 并发请求同一个 URL 时会共用一次下载，并且每个调用方都会收到进度更新。
    ///
    /// - Parameters:
    ///   - source: 资源的本地文件路径或 HTTPS URL。本地路径会原样返回。
    ///   - resourceLoader: 用于解析 source 的对象。默认值为 `VAPDiskCache.shared`。
    ///   - progressHandler: 加载器回调的进度闭包，取值范围为 `0...1`。
    /// - Returns: 可用于播放的本地文件路径。
    @discardableResult
    @concurrent public nonisolated static func prefetch(
        source: String,
        using resourceLoader: VAPResourceLoader = VAPDiskCache.shared,
        progressHandler: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> String {
        let handler: @MainActor @Sendable (Double) -> Void = progressHandler ?? { _ in }
        return try await resourceLoader.resolveLocalPath(for: source, progressHandler: handler)
    }

    /// 查询远程资源当前的缓存/下载状态。
    ///
    /// 默认查询 ``VAPDiskCache/shared``。如果业务替换了资源缓存，也可以传入自定义状态提供者。
    @concurrent public nonisolated static func cacheStatus(
        source: String,
        using statusProvider: VAPResourceCacheStatusProviding = VAPDiskCache.shared
    ) async -> VAPCacheStatus {
        await statusProvider.cacheStatus(for: source)
    }

    /// 播放 VAP/HWD 动画文件。
    ///
    /// 渲染器会根据 MP4 内容自动选择合适的渲染管线：
    /// - **VAP 路径**：如果 MP4 包含 `vapc` box，渲染器会读取其中的 `rgbFrame`/`aFrame`
    ///   来确定精确的 RGB 和 Alpha 区域。此时会忽略 `configuration.alphaPlacement`。
    /// - **HWD 路径**：如果没有 `vapc` box，渲染器使用 `configuration.alphaPlacement`
    ///   判断 Alpha 通道位置（左/右/上/下 50% 分割）。
    ///
    /// ## VAPPlaybackConfiguration 属性
    ///
    /// | 属性 | 说明 |
    /// |---|---|
    /// | `source` | 本地文件路径或 HTTPS URL。远程 URL 会先通过 ``VAPDiskCache`` 下载，本地化进度通过 `.downloading` 事件上报。默认加载器会拒绝明文 HTTP URL。 |
    /// | `alphaPlacement` | Alpha 通道位置（`.left`/`.right`/`.top`/`.bottom`）。**仅用于 HWD 路径**；当 MP4 的 `vapc` box 包含 `rgbFrame`/`aFrame` 时会被忽略。默认值：`.right`。 |
    /// | `backgroundPolicy` | App 进入后台时的行为：`.stop`（默认）、`.pauseAndResume` 或 `.ignore`。 |
    /// | `contentMode` | 显示缩放方式：`.scaleToFill`（默认）、`.aspectFit` 或 `.aspectFill`。 |
    /// | `attachmentSources` | 将 `srcId` 映射到 ``VAPAttachmentSource``（`.image`、`.imageURL`、`.text`），用于 `vapc` 配置中的 VAP 挂件槽位。 |
    /// | `imageLoader` | `.imageURL` 类型挂件的自定义异步图片加载器。使用 `.imageURL` 挂件资源时必填。 |
    /// | `frameBufferCapacity` | 解码帧缓冲深度。默认值：3。 |
    /// | `preferredFramesPerSecond` | 覆盖播放帧率。0（默认）表示使用 MP4 头信息中的值。 |
    /// | `playsAudio` | 如果存在音轨，是否播放音频。默认值：`true`。 |
    /// | `mask` | 可选的外部 Alpha 蒙版，会叠加到每一帧（仅 VAP 路径）。 |
    /// | `loopCount` | 播放重复次数。1 = 播放一次（默认），0 = 无限循环，N = 播放 N 次。为 `0` 时不会发出 `.didFinish`，需要显式调用 `stop()`。 |
    ///
    /// ## 示例
    ///
    /// **基础用法：播放本地文件（HWD 路径，alphaPlacement 生效）：**
    /// ```swift
    /// let playbackConfiguration = VAPPlaybackConfiguration(
    ///     source: Bundle.main.path(forResource: "animation", ofType: "mp4")!,
    ///     alphaPlacement: .right
    /// )
    /// vapView.play(playbackConfiguration)
    /// ```
    ///
    /// **远程 URL：带进度和事件处理：**
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
    ///         print("下载中：\(Int(progress * 100))%")
    ///     case .didStart:
    ///         print("播放已开始")
    ///     case .didPlayFrame(let index):
    ///         break // 每帧都会调用
    ///     case .didLoopFinish(let loop, let totalFrames):
    ///         print("第 \(loop) 次循环完成，共 \(totalFrames) 帧")
    ///     case .didFinish(let totalFrames):
    ///         print("播放完成，共 \(totalFrames) 帧")
    ///     case .didStop(let lastFrame):
    ///         print("已停止在第 \(lastFrame) 帧")
    ///     case .didFail(let error):
    ///         print("错误：\(error)")
    ///     }
    /// }
    /// ```
    ///
    /// **VAP 路径：动态挂件（图片、文本叠加）：**
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
    ///         // 为 .imageURL 挂件自定义异步图片加载
    ///         let (data, _) = try await URLSession.shared.data(from: url)
    ///         return UIImage(data: data) ?? UIImage()
    ///     }
    /// )
    /// vapView.play(playbackConfiguration)
    /// ```
    ///
    /// **外部蒙版叠加（仅 VAP 路径）：**
    /// ```swift
    /// let maskData = Data(repeating: 0xFF, count: 200 * 200) // R8 灰度
    /// let playbackConfiguration = VAPPlaybackConfiguration(
    ///     source: "path/to/animation.mp4",
    ///     mask: VAPMaskConfiguration(data: maskData, dataSize: CGSize(width: 200, height: 200))
    /// )
    /// vapView.play(playbackConfiguration)
    /// ```
    ///
    /// - Parameters:
    ///   - configuration: 完整播放配置。参见上方属性表。
    ///   - eventHandler: 每个 ``VAPEvent`` 触发时调用的可选闭包。
    public func play(_ configuration: VAPPlaybackConfiguration,
                     eventHandler: ((VAPEvent) -> Void)? = nil) {
        var playbackConfiguration = configuration
        playbackConfiguration.preferredFramesPerSecond = preferredFramesPerSecond > 0
            ? preferredFramesPerSecond
            : configuration.preferredFramesPerSecond

        // shouldStartPlayback 播放门禁。
        if let shouldStartPlayback, !shouldStartPlayback(playbackConfiguration) { return }

        // 停止已有播放，但保留 player/metalView 以便复用。
        playbackGeneration &+= 1
        let generation = playbackGeneration
        playTask?.cancel()
        playTask = nil
        player?.stopForReplacement()

        ensurePlayer()
        guard let p = player else { return }

        // 包装调用方的 eventHandler，用于在内部处理自动销毁。
        let wrappedEventHandler: ((VAPEvent) -> Void)? = { [weak self] event in
            guard let self, self.playbackGeneration == generation else { return }
            eventHandler?(event)
            switch event {
            case .didFinish, .didStop:
                if self.automaticallyDestroysPlayerAfterPlayback { self.teardown() }
            default:
                break
            }
        }

        let isRemote = playbackConfiguration.source.hasPrefix("http://") || playbackConfiguration.source.hasPrefix("https://")
        if isRemote {
            let loader = resourceLoader
            let remoteConfiguration = playbackConfiguration
            playTask = Task { @MainActor [weak self] in
                do {
                    let localPath = try await loader.resolveLocalPath(for: remoteConfiguration.source) { progress in
                        guard let self, self.playbackGeneration == generation else { return }
                        wrappedEventHandler?(.downloading(progress: progress))
                    }
                    guard let self, !Task.isCancelled, self.playbackGeneration == generation else { return }
                    var localConfiguration = remoteConfiguration
                    localConfiguration.source = localPath
                    self.player?.play(localConfiguration, eventHandler: wrappedEventHandler)
                    self.player?.setMuted(self.isMuted)
                } catch is CancellationError {
                    return
                } catch {
                    guard let self, !Task.isCancelled, self.playbackGeneration == generation else { return }
                    let vapErr = error as? VAPError ?? .unknown(error.localizedDescription)
                    wrappedEventHandler?(.didFail(vapErr))
                }
            }
        } else {
            p.play(playbackConfiguration, eventHandler: wrappedEventHandler)
            p.setMuted(isMuted)
        }
    }

    /// 接收独立参数的便利重载。
    public func play(source: String,
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
        let configuration = VAPPlaybackConfiguration(
            source: source,
            alphaPlacement: alphaPlacement,
            backgroundPolicy: backgroundPolicy,
            contentMode: contentMode,
            attachmentSources: attachmentSources,
            imageLoader: imageLoader,
            frameBufferCapacity: frameBufferCapacity,
            preferredFramesPerSecond: preferredFramesPerSecond,
            playsAudio: playsAudio,
            mask: mask,
            loopCount: loopCount
        )
        play(configuration, eventHandler: eventHandler)
    }

    public func stop() {
        let generationBeforeStop = playbackGeneration
        playTask?.cancel()
        playTask = nil
        player?.stop()
        guard playbackGeneration == generationBeforeStop else { return }
        playbackGeneration &+= 1
        teardown()
    }

    public func pause() {
        player?.pause()
    }

    public func resume() {
        player?.resume()
    }

    // MARK: - 布局

    public override func layoutSubviews() {
        super.layoutSubviews()
        player?.metalView.frame = bounds
    }

    // MARK: - 私有方法

    private func ensurePlayer() {
        guard player == nil else { return }
        let p = VAPPlayer(frame: bounds)
        p.metalView.frame = bounds
        p.metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(p.metalView)
        // 将预先注册的手势挂载到新的 metalView。
        for (gesture, _) in gestureHandlers {
            p.metalView.addGestureRecognizer(gesture)
        }
        player = p
    }

    private func teardown() {
        playTask?.cancel()
        playTask = nil
        // 移除 metalView 前先解除手势，便于后续重新挂载。
        if let metalView = player?.metalView {
            for (gesture, _) in gestureHandlers { metalView.removeGestureRecognizer(gesture) }
            metalView.removeFromSuperview()
        }
        player = nil
    }
}
