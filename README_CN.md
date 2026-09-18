# VAPView

用于在 iOS 上播放 **VAP（Video Alpha Protocol）** 动画的 Swift 包。VAP 格式将 RGB 内容与 Alpha 通道蒙版编码在同一个 H.264/H.265 MP4 文件中，通过 Metal 在渲染时实时合成透明动画。

[English Documentation](README.md)

---

## 环境要求

| | |
|---|---|
| 平台 | iOS 15+ |
| Swift | Swift 6.3+ |
| Xcode | 26.5+ (Swift 6.3) |

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

## 工作空间开发

打开仓库根目录的 `VAPView.xcworkspace`，统一管理本地 `VAPView` Swift 包与 `VAPDemo` 示例工程。选择 **VAPDemo** 运行示例，选择 **VAPView** 构建框架，选择 **VAPViewTests** 后按 ⌘U 运行单元测试。Demo 和框架 Scheme 也已关联测试 target。

```bash
open VAPView.xcworkspace
xcodebuild -workspace VAPView.xcworkspace -scheme VAPDemo -destination 'generic/platform=iOS Simulator' build
xcodebuild -workspace VAPView.xcworkspace -scheme VAPViewTests -destination 'generic/platform=iOS Simulator' build-for-testing
# 将 <SIMULATOR_UDID> 替换为 xcrun simctl list devices available 中的可用设备 ID。
xcodebuild -workspace VAPView.xcworkspace -scheme VAPViewTests -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' test
xcodebuild -workspace VAPView.xcworkspace -scheme VAPDemoUITests -destination 'platform=iOS Simulator,id=<SIMULATOR_UDID>' test
```

选择 **VAPDemoUITests** 后按 ⌘U 运行 Demo 的 UI 测试；**VAPDemo** Scheme 同时包含单元测试与 UI 测试 target。UI 测试源码位于 `Demo/VAPDemoUITests`，覆盖启动、初始按钮状态和清缓存操作，不依赖远程视频下载。缓存测试会清除所选模拟器中 Demo 的缓存。

Swift 包要求 6.3 工具链，框架与 Demo 均使用 Swift 6 语言模式（`SWIFT_VERSION = 6.0`）。若命令行当前选中 Command Line Tools，请在命令前添加 `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`。

`Demo/VAPDemo.xcodeproj` 中的原生 `VAPViewTests` target 复用 `Tests/VAPViewTests` 的测试源码，并将 Demo JSON 和工程文件打包为测试资源，无需宿主 App 或跳过测试。请使用 iOS 模拟器运行；`swift test` 面向 macOS，无法编译 UIKit。Swift 包仍保留自身的测试 target，供包开发使用。

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
| `VAPView.cacheStatus(source:using:)` | 查询远程资源当前是已缓存、下载中还是未缓存 |
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

### `VAPCacheStatus`

```swift
case cached(localPath: String)       // 已缓存，并返回本地文件路径
case downloading(progress: Double?)  // 正在下载；进度未知时为 nil
case missing                         // 未缓存，也没有进行中的下载
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

外部业务可以直接查询当前缓存状态：

```swift
switch await VAPView.cacheStatus(source: remoteURL) {
case .cached(let localPath):
    print("已缓存：\(localPath)")
case .downloading(let progress):
    print("下载中：\(progress ?? 0)")
case .missing:
    print("未缓存")
}
```

```swift
public protocol VAPResourceLoader: AnyObject, Sendable {
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String
}

public protocol VAPResourceCacheStatusProviding: AnyObject, Sendable {
    @concurrent func cacheStatus(for source: String) async -> VAPCacheStatus
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

### 取消预下载与共享加载

取消调用 `prefetch` 的 Swift `Task` 即可解除该调用的资源需求；不需要下载句柄或按 URL 取消接口。默认 `VAPDiskCache` 为同 URL 的每个调用维护独立订阅：还有其他预下载或播放订阅时，被取消的调用及时抛出 `CancellationError`，其他调用继续。最后一个订阅取消时，会调用底层 `URLSessionDownloadTask.cancel()`，等待下载退出并清理暂存文件后再返回取消结果。同 URL 的新调用会等待旧实例清理完成，再创建新实例。

```swift
let task = Task { try await VAPView.prefetch(source: url.absoluteString) }
task.cancel()
do { _ = try await task.value }
catch is CancellationError { /* 此次需求已释放 */ }
```

`VAPView.stop()` 和替换播放只释放该视图自己的加载订阅。取消生效后不会开始新的进度回调；已经进入执行的回调不强行中断。成功与取消以订阅者首先确定的终态为准。完整缓存文件提交后可复用；取消或失败的暂存文件不会作为缓存暴露。预取消也适用于本地路径和缓存命中。自定义 `VAPResourceLoader` 必须自行实现协作式取消；框架不能强制终止自定义加载器。
