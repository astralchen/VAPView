# VAPView

用于在 iOS 上播放 **VAP（Video Alpha Protocol）** 动画的 Swift 包。VAP 格式将 RGB 内容与 Alpha 通道蒙版编码在同一个 H.264/H.265 MP4 文件中，通过 Metal 在渲染时实时合成透明动画。

[English Documentation](README.md)

---

## 环境要求

| | |
|---|---|
| 平台 | iOS 14+ |
| Swift | Swift 6 |
| Xcode | 16+ |

---

## 安装

### Swift Package Manager

在 Xcode 中选择 **File › Add Package Dependencies**，输入本仓库地址；或在 `Package.swift` 中添加：

```swift
dependencies: [
    .package(url: "https://github.com/astralchen/VAPPlayerSwift.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["VAPView"]
    )
]
```

---

## 快速开始

### 基础播放

```swift
import VAPView
import UIKit

class ViewController: UIViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        let vapView = VAPView(frame: view.bounds)
        view.addSubview(vapView)

        vapView.play(
            source: "path/to/animation.mp4",
            alphaPlacement: .right,
            eventHandler: { event in
                print(event)
            }
        )
    }
}
```

### 远程 URL 播放（带下载进度）

```swift
let config = VAPPlaybackConfiguration(
    source: "https://example.com/animation.mp4",
    backgroundPolicy: .pauseAndResume,
    contentMode: .aspectFit,
    loopCount: 3
)

vapView.play(config) { event in
    switch event {
    case .downloading(let progress):
        print(progress)
    default:
        break
    }
}
```

### 图片与文字叠加（Attachment）

VAP 支持通过内嵌的 `vapc` JSON 配置定义每帧的挂件槽，按 `srcId` 提供内容：

```swift
let config = VAPPlaybackConfiguration(
    source: "path/to/animation.mp4",
    alphaPlacement: .right,
    attachmentSources: [
        "avatar":   .image(UIImage(named: "avatar")!),
        "username": .text("你好，VAP!"),
        "banner":   .imageURL("https://example.com/banner.png"),
    ],
    imageLoader: { url, context in
        // 自定义异步图片加载实现
        return try await MyImageLoader.load(url)
    },
    loopCount: 3
)
vapView.play(config)
```

---

## VAP 格式说明

每帧视频在空间上被分为两个半区：一个承载 RGB 内容，另一个承载 Alpha 蒙版。Metal 着色器将二者合成为带透明通道的 BGRA 帧。对于没有内嵌 `vapc` 帧区域信息的视频，使用 `VAPAlphaPlacement` 指定 Alpha 半区。

| `VAPAlphaPlacement` | Alpha 半区位置 |
|---|---|
| `.left` | 左 |
| `.right` | 右（默认）|
| `.top` | 上 |
| `.bottom` | 下 |

---

## API 参考

### `VAPView`

| 属性 / 方法 | 说明 |
|---|---|
| `VAPView.prefetch(source:using:progressHandler:)` | 在没有视图实例时预下载/缓存资源 |
| `VAPPlayer.play(_:eventHandler:)` / `VAPView.play(_:eventHandler:)` | 使用 `VAPPlaybackConfiguration` 开始播放 |
| `VAPView.play(source:alphaPlacement:backgroundPolicy:contentMode:attachmentSources:imageLoader:frameBufferCapacity:mask:playsAudio:loopCount:eventHandler:)` | 使用独立参数开始播放 |
| `stop()` | 停止并释放资源 |
| `pause()` | 暂停播放 |
| `resume()` | 恢复播放 |
| `resourceLoader` | 自定义下载/缓存器（默认：`VAPDiskCache.shared`）|
| `automaticallyDestroysPlayerAfterPlayback` | 播放完成后自动释放 Metal 对象 |
| `preferredFramesPerSecond` | 覆盖播放帧率；`0` 表示使用 MP4 头信息 |
| `isMuted` | 静音或取消静音 |
| `shouldStartPlayback` | 播放前调用，返回 `false` 可取消播放 |

### `VAPPlaybackConfiguration`

| 属性 | 说明 |
|---|---|
| `source` | 本地文件路径或 HTTPS 远程 URL |
| `alphaPlacement` | 没有 `vapc` 帧区域信息时的 Alpha 通道位置 |
| `loopCount` | `1` = 播放一次，`0` = 无限循环，`N` = 播放 N 次 |
| `backgroundPolicy` | `.stop` / `.pauseAndResume` / `.ignore` |
| `contentMode` | `.scaleToFill` / `.aspectFit` / `.aspectFill` |
| `attachmentSources` | `[srcId: VAPAttachmentSource]`，支持图片、图片 URL、文本 |
| `imageLoader` | 用于加载 URL 类型挂件的异步闭包 |
| `preferredFramesPerSecond` | 覆盖播放帧率；`0` 表示使用 MP4 头信息 |
| `playsAudio` | 是否播放视频音轨 |
| `frameBufferCapacity` | 解码缓冲深度（默认：`3`）|
| `mask` | 可选外部 Alpha 蒙版，仅用于 VAP 渲染路径 |

### `VAPEvent`

```swift
case didStart                                    // 开始播放（首帧已显示）
case didPlayFrame(index: Int)                    // 渲染了一帧
case didLoopFinish(loop: Int, totalFrames: Int)  // 一次循环完成
case didFinish(totalFrames: Int)                 // 全部循环完成
case didStop(lastFrame: Int)                     // 被外部停止
case downloading(progress: Double)               // 远程资源下载进度
case didFail(VAPError)                           // 发生错误
```

---

## 日志

VAPView 默认使用 Apple unified logging。Release 构建默认只输出错误日志；如需更多信息，由宿主 App 显式配置。Debug 构建也可以通过 `VAP_DEBUG_LOGS=1` 环境变量开启 debug 日志。

```swift
VAPLogging.configure(
    VAPLogConfiguration(
        level: .info,
        enabledModules: [.player, .decoder],
        handler: { record in
            // 如有需要，可将脱敏后的日志转发到业务日志系统。
            print("[\(record.module.rawValue)] \(record.message)")
        }
    )
)
```

设置 `level: .off` 可关闭 SDK 日志。日志内容默认会脱敏；只有在明确的本地调试场景下才建议传入 `redactSensitiveValues: false`。

---

## 自定义资源加载器

默认的 `VAPDiskCache` 以 URL 的 SHA-256 为文件名，将下载文件缓存至 `<Caches>/com.vap/resources/`。可替换为自定义的 `VAPResourceLoader` 实现：

也可以在创建视图前预热缓存：

```swift
try await VAPView.prefetch(source: "https://example.com/gift.mp4") { progress in
    print(progress)
}
```

通过同一个 `VAPDiskCache` 实例请求同一个 URL 时，并发请求会共用一次网络下载。例如 `VAPView.prefetch(...)` 和 `vapView.play(...)` 同时加载同一个 URL，播放会等待共享下载完成，不会再发起第二个请求，并且两个调用方都会收到进度回调。

```swift
public protocol VAPResourceLoader: AnyObject, Sendable {
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String
}

public protocol VAPResourceCacheCleaning: AnyObject {
    func removeAllCachedResources() throws
}

final class CustomResourceLoader: VAPResourceLoader {
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        source
    }
}

// 在调用 play 前赋值：
vapView.resourceLoader = CustomResourceLoader()
```

---

## 许可证

MIT License. Copyright (C) 2026 astralchen.
