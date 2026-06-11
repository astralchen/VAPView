# VAPPlayerSwift

A Swift package for playing **VAP (Video Alpha Protocol)** animations on iOS. VAP encodes transparent video by embedding both the RGB content and alpha channel mask within a single H.264/H.265 MP4 file, composited at render time via Metal.

[中文文档](README_CN.md)

---

## Requirements

| | |
|---|---|
| Platform | iOS 14+ |
| Swift | Swift 6 |
| Xcode | 16+ |

---

## Installation

### Swift Package Manager

In Xcode choose **File › Add Package Dependencies** and enter this repository URL, or add to your `Package.swift`:

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

## Quick Start

### Basic playback

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
                case .didStart:            print("started")
                case .didFinish:           print("finished")
                case .didFail(let error):  print("error:", error)
                default: break
                }
            }
        )
    }
}
```

### Remote URL with download progress

```swift
vapView.play(
    filePath: "https://example.com/animation.mp4",
    blendMode: .alphaRight,
    loopCount: 0,   // 0 = infinite loop
    onEvent: { event in
        if case .downloading(let progress) = event {
            print("download progress:", progress)
        }
    }
)
```

### Image & text attachments

VAP supports per-frame attachment slots defined in the embedded `vapc` JSON config. Supply sources by `srcId`:

```swift
let config = VAPPlayConfig(
    filePath: "path/to/animation.mp4",
    blendMode: .alphaRight,
    attachmentSources: [
        "avatar":   .image(UIImage(named: "avatar")!),
        "username": .text("Hello, VAP!"),
        "banner":   .url("https://example.com/banner.png"),
    ],
    imageLoader: { url, context in
        // Your async image loading implementation
        return try await MyImageLoader.load(url)
    },
    loopCount: 3
)
vapView.play(config: config, onEvent: nil)
```

---

## VAP Format

Each video frame is split spatially into two halves — one carries RGB content, the other the alpha mask. The Metal shader composites them into a transparent BGRA frame.

| `VAPTextureBlendMode` | Alpha half position |
|---|---|
| `.alphaLeft` | Left |
| `.alphaRight` | Right (default) |
| `.alphaTop` | Top |
| `.alphaBottom` | Bottom |

---

## API Reference

### `VAPView`

| Property / Method | Description |
|---|---|
| `play(config:onEvent:)` | Start playback |
| `stop()` | Stop and release resources |
| `pause()` | Pause playback |
| `resume()` | Resume playback |
| `resourceLoader` | Custom download/cache handler (default: `VAPDiskCache.shared`) |
| `autoDestroyAfterFinish` | Release Metal objects after playback finishes |
| `shouldStartPlay` | Callback invoked before playback; return `false` to cancel |

### `VAPPlayConfig`

| Property | Description |
|---|---|
| `filePath` | Local file path or `http(s)://` URL |
| `blendMode` | Alpha channel position in the frame |
| `loopCount` | `1` = play once, `0` = infinite, `N` = N times |
| `backgroundPolicy` | `.stop` / `.pauseAndResume` / `.doNothing` |
| `contentMode` | `.scaleToFill` / `.aspectFit` / `.aspectFill` |
| `attachmentSources` | `[srcId: VAPAttachmentSource]` — image, URL, or text |
| `imageLoader` | Async closure for loading URL-based attachments |
| `playAudio` | Whether to play the audio track |
| `bufferCount` | Decode buffer depth (default: `3`) |

### `VAPEvent`

```swift
case didStart
case didPlayFrame(index: Int)
case didLoopFinish(loop: Int, totalFrames: Int)
case didFinish(totalFrames: Int)
case didStop(lastFrame: Int)
case downloading(progress: Double)
case didFail(VAPError)
```

---

## Logging

VAPPlayer uses Apple's unified logging by default. Release builds log only errors unless the host app opts into a different level. Debug builds can also enable debug logs with the `VAP_DEBUG_LOGS=1` environment variable.

```swift
VAPLogging.configure(
    VAPLogConfiguration(
        level: .info,
        enabledModules: [.player, .decoder],
        handler: { record in
            // Forward sanitized records to your own logger if needed.
            print("[\(record.module.rawValue)] \(record.message)")
        }
    )
)
```

Set `level: .off` to disable SDK logs. Messages are sanitized by default; pass `redactSensitiveValues: false` only for explicit local debugging sessions.

---

## Custom Resource Loader

The default `VAPDiskCache` downloads remote files to `<Caches>/com.tencent.vap/resources/`, keyed by SHA-256 of the URL. Replace it with your own `VAPResourceLoader` implementation:

```swift
public protocol VAPResourceLoader: Sendable {
    func localPath(for filePath: String,
                   onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String
}

// Assign before calling play:
vapView.resourceLoader = MyCustomLoader()
```

---

## License

MIT License. Copyright (C) 2026 astralchen.
