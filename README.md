# VAPView

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
    .package(url: "https://github.com/astralchen/VAPView.git", from: "1.0.0")
],
targets: [
    .target(
        name: "YourTarget",
        dependencies: ["VAPView"]
    )
]
```

---

## Quick Start

### Basic playback

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

### Remote URL with download progress

```swift
let configuration = VAPPlaybackConfiguration(
    source: "https://example.com/animation.mp4",
    backgroundPolicy: .pauseAndResume,
    contentMode: .aspectFit,
    loopCount: 3
)

vapView.play(configuration) { event in
    if case .downloading(let progress) = event {
        print(progress)
    }
}
```

### Image & text attachments

VAP supports per-frame attachment slots defined in the embedded `vapc` JSON config. Supply sources by `srcId`:

```swift
let configuration = VAPPlaybackConfiguration(
    source: "path/to/animation.mp4",
    alphaPlacement: .right,
    attachmentSources: [
        "avatar":   .image(UIImage(named: "avatar")!),
        "username": .text("Hello, VAP!"),
        "banner":   .imageURL("https://example.com/banner.png"),
    ],
    imageLoader: { url, context in
        // Your async image loading implementation
        return try await MyImageLoader.load(url)
    },
    loopCount: 3
)
vapView.play(configuration)
```

---

## VAP Format

Each video frame is split spatially into two halves — one carries RGB content, the other the alpha mask. The Metal shader composites them into a transparent BGRA frame. For videos without embedded `vapc` frame-region metadata, choose the alpha half with `VAPAlphaPlacement`.

| `VAPAlphaPlacement` | Alpha half position |
|---|---|
| `.left` | Left |
| `.right` | Right (default) |
| `.top` | Top |
| `.bottom` | Bottom |

---

## API Reference

### `VAPView`

| Property / Method | Description |
|---|---|
| `VAPView.prefetch(source:using:progressHandler:)` | Download/cache a resource before any view exists |
| `play(_:eventHandler:)` | Start playback with a `VAPPlaybackConfiguration` |
| `play(source:alphaPlacement:backgroundPolicy:contentMode:attachmentSources:imageLoader:frameBufferCapacity:mask:playsAudio:loopCount:eventHandler:)` | Start playback with individual parameters |
| `stop()` | Stop and release resources |
| `pause()` | Pause playback |
| `resume()` | Resume playback |
| `resourceLoader` | Custom download/cache handler (default: `VAPDiskCache.shared`) |
| `automaticallyDestroysPlayerAfterPlayback` | Release Metal objects after playback finishes |
| `preferredFramesPerSecond` | Override playback FPS; `0` uses the MP4 header value |
| `isMuted` | Mute or unmute playback audio |
| `shouldStartPlayback` | Invoked before playback; return `false` to cancel |

### `VAPPlaybackConfiguration`

| Property | Description |
|---|---|
| `source` | Local file path or HTTPS URL |
| `alphaPlacement` | Alpha channel position in the frame for videos without `vapc` frame-region metadata |
| `loopCount` | `1` = play once, `0` = infinite, `N` = N times |
| `backgroundPolicy` | `.stop` / `.pauseAndResume` / `.ignore` |
| `contentMode` | `.scaleToFill` / `.aspectFit` / `.aspectFill` |
| `attachmentSources` | `[srcId: VAPAttachmentSource]` — image, image URL, or text |
| `imageLoader` | Async closure for loading URL-based attachments |
| `preferredFramesPerSecond` | Override playback FPS; `0` uses the MP4 header value |
| `playsAudio` | Whether to play the audio track |
| `frameBufferCapacity` | Decode buffer depth (default: `3`) |
| `mask` | Optional external alpha mask for the VAP renderer path |

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

VAPView uses Apple's unified logging by default. Release builds log only errors unless the host app opts into a different level. Debug builds can also enable debug logs with the `VAP_DEBUG_LOGS=1` environment variable.

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

The default `VAPDiskCache` downloads remote files to `<Caches>/com.vap/resources/`, keyed by SHA-256 of the URL. Replace it with your own `VAPResourceLoader` implementation:

You can also warm the cache before creating a view:

```swift
try await VAPView.prefetch(source: "https://example.com/gift.mp4") { progress in
    print(progress)
}
```

Concurrent requests for the same URL through the same `VAPDiskCache` instance share one network request. For example, if `VAPView.prefetch(...)` and `vapView.play(...)` are started with the same URL at the same time, playback waits for the shared download instead of starting another request, and both callers receive progress callbacks.

```swift
public protocol VAPResourceLoader: AnyObject, Sendable {
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String
}

final class CustomResourceLoader: VAPResourceLoader {
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        source
    }
}

// Assign before calling play:
vapView.resourceLoader = CustomResourceLoader()
```

---

## License

MIT License. Copyright (C) 2026 astralchen.
