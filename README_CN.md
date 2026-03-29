# VAPPlayerSwift

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
        dependencies: ["VAPPlayer"]
    )
]
```

---

## 快速开始

### 基础播放

```swift
import VAPPlayer
import UIKit

class ViewController: UIViewController {

    let vapView = VAPView()

    override func viewDidLoad() {
        super.viewDidLoad()
        vapView.frame = view.bounds
        view.addSubview(vapView)

        vapView.play(
            filePath: "path/to/animation.mp4",
            blendMode: .alphaRight,
            loopCount: 1,
            onEvent: { event in
                switch event {
                case .didStart:           print("开始播放")
                case .didFinish:          print("播放完成")
                case .didFail(let error): print("错误:", error)
                default: break
                }
            }
        )
    }
}
```

### 远程 URL 播放（带下载进度）

```swift
vapView.play(
    filePath: "https://example.com/animation.mp4",
    blendMode: .alphaRight,
    loopCount: 0,   // 0 = 无限循环
    onEvent: { event in
        if case .downloading(let progress) = event {
            print("下载进度:", progress)
        }
    }
)
```

### 图片与文字叠加（Attachment）

VAP 支持通过内嵌的 `vapc` JSON 配置定义每帧的挂件槽，按 `srcId` 提供内容：

```swift
let config = VAPPlayConfig(
    filePath: "path/to/animation.mp4",
    blendMode: .alphaRight,
    attachmentSources: [
        "avatar":   .image(UIImage(named: "avatar")!),
        "username": .text("你好，VAP!"),
        "banner":   .url("https://example.com/banner.png"),
    ],
    imageLoader: { url, context in
        // 自定义异步图片加载实现
        return try await MyImageLoader.load(url)
    },
    loopCount: 3
)
vapView.play(config: config, onEvent: nil)
```

---

## VAP 格式说明

每帧视频在空间上被分为两个半区：一个承载 RGB 内容，另一个承载 Alpha 蒙版。Metal 着色器将二者合成为带透明通道的 BGRA 帧。

| `VAPTextureBlendMode` | Alpha 半区位置 |
|---|---|
| `.alphaLeft` | 左 |
| `.alphaRight` | 右（默认）|
| `.alphaTop` | 上 |
| `.alphaBottom` | 下 |

---

## API 参考

### `VAPView`

| 属性 / 方法 | 说明 |
|---|---|
| `play(config:onEvent:)` | 开始播放 |
| `stop()` | 停止并释放资源 |
| `pause()` | 暂停播放 |
| `resume()` | 恢复播放 |
| `resourceLoader` | 自定义下载/缓存器（默认：`VAPDiskCache.shared`）|
| `autoDestroyAfterFinish` | 播放完成后自动释放 Metal 对象 |
| `shouldStartPlay` | 播放前回调，返回 `false` 可取消播放 |

### `VAPPlayConfig`

| 属性 | 说明 |
|---|---|
| `filePath` | 本地文件路径或 `http(s)://` 远程 URL |
| `blendMode` | Alpha 通道在帧中的位置 |
| `loopCount` | `1` = 播放一次，`0` = 无限循环，`N` = 播放 N 次 |
| `backgroundPolicy` | `.stop` / `.pauseAndResume` / `.doNothing` |
| `contentMode` | `.scaleToFill` / `.aspectFit` / `.aspectFill` |
| `attachmentSources` | `[srcId: VAPAttachmentSource]`，支持图片、URL、文本 |
| `imageLoader` | 用于加载 URL 类型挂件的异步闭包 |
| `playAudio` | 是否播放视频音轨 |
| `bufferCount` | 解码缓冲深度（默认：`3`）|

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

## 自定义资源加载器

默认的 `VAPDiskCache` 以 URL 的 SHA-256 为文件名，将下载文件缓存至 `<Caches>/com.tencent.vap/resources/`。可替换为自定义的 `VAPResourceLoader` 实现：

```swift
public protocol VAPResourceLoader: Sendable {
    func localPath(for filePath: String,
                   onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String
}

// 在调用 play 前赋值：
vapView.resourceLoader = MyCustomLoader()
```

---

## 许可证

MIT License. Copyright (C) 2026 astralchen.
