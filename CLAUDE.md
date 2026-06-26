# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Commands

```bash
# Set this to an available iOS Simulator UDID from xcrun simctl list devices.
SIMULATOR_UDID=49428834-37D6-4470-BF7F-951C0F3441D4

# Build for iOS Simulator
xcodebuild -scheme VAPView -destination 'generic/platform=iOS Simulator' build-for-testing

# Run tests on a specific iOS Simulator
xcodebuild -scheme VAPView -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" -enableCodeCoverage NO test -skip-testing:VAPViewTests/GiftEffectsFixtureTests

# Build the standalone demo project
xcodebuild -project Demo/VAPDemo.xcodeproj -scheme VAPDemo -destination "platform=iOS Simulator,id=${SIMULATOR_UDID}" build
```

Do not use `swift test` as the primary verification command in this repository. SwiftPM test execution targets macOS in this environment, while the package imports UIKit and is declared for iOS 14+.

The `Demo/` directory is a standalone Xcode project and is not part of the Swift package; open it separately in Xcode or build it with `xcodebuild -project`.

## Package

- **Platform**: iOS 14+ only (no macOS/tvOS targets)
- **Swift**: tools-version 6.0, strict Swift 6 concurrency (`swiftLanguageMode(.v6)`)
- **No external dependencies** — links Metal, MetalKit, VideoToolbox, CoreVideo, CoreMedia, AVFoundation

## VAP Format

VAP (Video Alpha Protocol) encodes a transparent animation as a standard H.264/H.265 MP4 where one spatial half of each frame carries the RGB content and the other half carries the alpha channel mask. `VAPAlphaPlacement` (`.left/.right/.top/.bottom`) tells the Metal shader which half is the mask when the MP4 does not provide embedded `vapc` frame-region metadata. The MP4 may also embed a `vapc` box containing a JSON config that describes dynamic attachment slots (images, text overlays) composited per-frame using mask shapes.

## Architecture

### Public API surface

- **`VAPView: UIView`** (`@MainActor`) — the only integration point most callers need. Owns a `VAPPlayer` internally, exposes `VAPView.prefetch(source:using:progressHandler:)`, `VAPView.play(_:eventHandler:)`, `VAPView.play(source:...eventHandler:)`, `stop()`, `pause()`, and `resume()`. Playback events are delivered via the `eventHandler: ((VAPEvent) -> Void)?` closure passed to `play`.
- **`VAPPlayer`** (`@MainActor`) — lower-level playback engine. Public playback entry point is `VAPPlayer.play(_:eventHandler:)`.
- **`VAPPlaybackConfiguration`** — value type passed to `play(...)`. Carries `source` (local path or HTTPS URL), `alphaPlacement`, `loopCount`, `attachmentSources`, `imageLoader`, `backgroundPolicy`, `contentMode`, `preferredFramesPerSecond`, `playsAudio`, `frameBufferCapacity`, `mask`, etc.
- **`VAPEvent`** — `AsyncStream`-based enum: `.didStart`, `.didPlayFrame`, `.didLoopFinish`, `.didFinish`, `.didStop`, `.downloading`, `.didFail`.
- **`VAPResourceLoader` / `VAPResourceCacheCleaning` / `VAPDiskCache`** — resource loading and cache cleanup APIs. `VAPResourceLoader.resolveLocalPath(for:progressHandler:)` maps a source to a playable local path; `VAPResourceCacheCleaning.removeAllCachedResources()` clears cached resources. Concurrent requests for the same URL through the same `VAPDiskCache` instance, including `VAPView.prefetch(...)` plus `VAPView` playback, share one network download.

### Internal pipeline

```
VAPView (UIView, @MainActor)
  └─ VAPPlayer (@MainActor final class)
       ├─ VAPVideoDecoder (actor)          // VideoToolbox HW decode (H.264/H.265 → NV12 CVPixelBuffer)
       │    └─ VAPFrameBufferActor (actor) // ring-buffer between decoder and render loop
       ├─ VAPRenderer (@MainActor)         // Metal compositor
       │    ├─ yuvPipelineState            // vap_vertexShader + vap_yuvFragmentShader
       │    └─ attachPipelineState         // vapAttachment_VertexShader + vapAttachment_FragmentShader
       ├─ VAPHWDRenderer (@MainActor)      // alternate renderer path (hardware-decoded frames)
       ├─ VAPMetalView (CAMetalLayer-backed UIView)
       └─ VAPParser (VAPMP4Parser)         // reads MP4 boxes, extracts VAPMP4Info + vapc JSON
```

### Concurrency model

`VAPPlayer` is `@MainActor`. `VAPVideoDecoder` is an `actor` — decode work runs off the main thread via `withCheckedThrowingContinuation` into the VideoToolbox callback, then the decoded `CVPixelBuffer` is posted back to `VAPFrameBufferActor`. The render loop runs on `@MainActor`, pulling frames from the buffer and calling `VAPRenderer.render(...)` each display-link tick.

`CVPixelBuffer` is bridged across the actor boundary via the private `SendableCVPixelBuffer(@unchecked Sendable)` wrapper because `CVPixelBuffer` (a `CFTypeRef`) is thread-safe but not formally `Sendable` in Swift 6.

### Attachment system

The `vapc` JSON config (parsed by `VAPMP4Parser`) describes per-frame attachment slots with source IDs, fit types, and mask shapes. `VAPPlaybackConfiguration.attachmentSources` maps `srcId` → `VAPAttachmentSource` (`.image`, `.imageURL`, `.text`). The renderer composites attachment textures on top of the YUV base layer each frame using the `attachPipelineState`.

### Shaders

Metal shader source lives in `Sources/VAPView/Shaders/` and is bundled via `.process("Shaders")`. Loaded at runtime with `device.makeDefaultLibrary(bundle: .module)`.
