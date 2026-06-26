# VAPView API Naming Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean up VAPView public API names, resource-loading call style, and event semantics before the first release.

**Architecture:** This is a pre-release breaking cleanup, so replace current names directly instead of carrying deprecated compatibility wrappers. Keep playback resources represented as `String` because the existing parser consumes local file paths, but use `source` in public APIs because the value can be a local path or HTTPS URL. Split resource loading from cache management, and make `stop()` emit `.didStop` synchronously so cancellation internals do not leak into the event API.

**Tech Stack:** Swift 6, iOS 14+, UIKit, Metal, AVFoundation, Swift Testing, Xcode `xcodebuild` test runner.

---

## File Structure

- Modify: `Sources/VAPView/Public/VAPTypes.swift`
  - Public SDK-facing types: alpha placement, background policy, attachment source/context, mask configuration, playback defaults, errors.
  - Move raw vapc JSON enums out of the public API surface.
- Modify: `Sources/VAPView/Public/VAPPlayer.swift`
  - Rename `VAPPlayConfig` to `VAPPlaybackConfiguration`.
  - Rename callback and internal event state to `eventHandler`.
  - Fix `stop()` / cancellation event semantics.
  - Clean local variable names in the playback loop.
- Modify: `Sources/VAPView/Public/VAPView.swift`
  - Rename view-level properties, gesture API, `prefetch`, and `play` overloads.
  - Remove dead `onEvent` state.
- Modify: `Sources/VAPView/Network/VAPResourceLoader.swift`
  - Rename resource-loading protocol method.
  - Split cache cleanup into a separate protocol.
- Modify: `Sources/VAPView/Network/VAPDiskCache.swift`
  - Adopt renamed protocols and methods.
  - Keep request coalescing behavior intact.
- Modify: `Sources/VAPView/Config/VAPConfigModel.swift`
  - Rename raw JSON enums to internal config-specific names.
- Modify: `Sources/VAPView/Config/VAPConfigManager.swift`
  - Convert raw config enums to public attachment image context values.
- Modify: `Sources/VAPView/Render/VAPRenderUtils.swift`
  - Rename alpha-placement parameters and helper names.
- Modify: `Sources/VAPView/Render/VAPHWDRenderer.swift`
  - Use `VAPAlphaPlacement` and clearer renderer-local names.
- Modify: `Sources/VAPView/Render/VAPRenderer.swift`
  - Use `VAPAlphaPlacement` and clearer attachment renderer names.
- Modify: `Sources/VAPView/Render/VAPMetalView.swift`
  - Rename `vapContentMode` to `contentMode`.
- Modify: `Sources/VAPView/Parser/VAPMP4Parser.swift`
  - Rename true local path parameters to `localFilePath`.
  - Replace global `kVAP...` constants with `VAPPlaybackDefaults`.
- Modify: `Sources/VAPView/Decode/VAPVideoDecoder.swift`
  - Follow parser `localFilePath` rename.
- Modify: `Sources/VAPView/Public/VAPEvent.swift`
  - Update documentation from `filePaths` to `sources`.
- Modify: `Tests/VAPViewTests/VAPTypesTests.swift`
  - Update public type tests.
- Modify: `Tests/VAPViewTests/VAPDiskCacheTests.swift`
  - Update loader/cache method names.
- Modify: `Tests/VAPViewTests/VAPViewPrefetchTests.swift`
  - Update prefetch API and custom loader.
- Create: `Tests/VAPViewTests/VAPPlayerEventTests.swift`
  - Add stop-event regression tests.
- Create: `Tests/VAPViewTests/VAPViewAPITests.swift`
  - Add compile-time API style tests for VAPView call sites.
- Modify: `Tests/VAPViewTests/VAPMP4ParserTests.swift`
  - Update parser local-path method name.
- Modify: `README.md`
  - Update public examples and API tables.
- Modify: `README_CN.md`
  - Update Chinese examples and API tables.

## Target Public API Snapshot

Use these public names as the final source of truth:

```swift
public enum VAPAlphaPlacement: Int, Sendable {
    case left = 0
    case right = 1
    case top = 2
    case bottom = 3
}

public enum VAPBackgroundPlaybackPolicy: Sendable {
    case stop
    case pauseAndResume
    case ignore
}

public enum VAPAttachmentImageContentMode: Sendable {
    case scaleToFill
    case centerFill
}

public enum VAPAttachmentLoadLocation: Sendable {
    case local
    case remote
}

public struct VAPPlaybackDefaults: Sendable {
    public static let defaultFramesPerSecond: Int = 25
    public static let minimumFramesPerSecond: Int = 1
    public static let maximumFramesPerSecond: Int = 60
    public static let maximumCompatibleConfigVersion: Int = 2

    private init() {}
}

public struct VAPMaskConfiguration: Sendable {
    public let data: Data
    public let dataSize: CGSize
    public let sampleRect: CGRect
    public let blurLength: Int
}

public enum VAPAttachmentSource: @unchecked Sendable {
    case image(UIImage)
    case imageURL(String)
    case text(String)
}

public struct VAPAttachmentImageContext: Sendable {
    public let sourceID: String
    public let contentMode: VAPAttachmentImageContentMode
    public let targetSize: CGSize?
    public let loadLocation: VAPAttachmentLoadLocation?
}

public typealias VAPAttachmentImageLoader =
    @Sendable (_ url: URL, _ context: VAPAttachmentImageContext) async throws -> UIImage
```

```swift
public struct VAPPlaybackConfiguration: Sendable {
    public var source: String
    public var alphaPlacement: VAPAlphaPlacement
    public var backgroundPolicy: VAPBackgroundPlaybackPolicy
    public var contentMode: VAPContentMode
    public var attachmentSources: [String: VAPAttachmentSource]
    public var imageLoader: VAPAttachmentImageLoader?
    public var frameBufferCapacity: Int
    public var preferredFramesPerSecond: Int
    public var playsAudio: Bool
    public var mask: VAPMaskConfiguration?
    public var loopCount: Int
}
```

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
```

```swift
@MainActor
public final class VAPView: UIView {
    public var automaticallyDestroysPlayerAfterPlayback: Bool
    public var preferredFramesPerSecond: Int
    public var isMuted: Bool
    public var shouldStartPlayback: ((VAPPlaybackConfiguration) -> Bool)?
    public var resourceLoader: VAPResourceLoader

    @discardableResult
    @concurrent public nonisolated static func prefetch(
        source: String,
        using resourceLoader: VAPResourceLoader = VAPDiskCache.shared,
        progressHandler: (@MainActor @Sendable (Double) -> Void)? = nil
    ) async throws -> String

    public func addTapGesture(_ handler: @escaping (UITapGestureRecognizer) -> Void)
    public func addGesture(_ gesture: UIGestureRecognizer,
                           handler: @escaping (UIGestureRecognizer) -> Void)
    public func removeGesture(_ gesture: UIGestureRecognizer)

    public func play(_ configuration: VAPPlaybackConfiguration,
                     eventHandler: ((VAPEvent) -> Void)? = nil)

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
                     eventHandler: ((VAPEvent) -> Void)? = nil)
}
```

### Task 1: Rename Public Types And Raw Config Types

**Files:**
- Modify: `Sources/VAPView/Public/VAPTypes.swift`
- Modify: `Sources/VAPView/Config/VAPConfigModel.swift`
- Modify: `Sources/VAPView/Config/VAPConfigManager.swift`
- Modify: `Sources/VAPView/Render/VAPRenderUtils.swift`
- Modify: `Sources/VAPView/Render/VAPHWDRenderer.swift`
- Modify: `Sources/VAPView/Render/VAPRenderer.swift`
- Modify: `Sources/VAPView/Public/VAPPlayer.swift`
- Modify: `Sources/VAPView/Parser/VAPMP4Parser.swift`
- Modify: `Tests/VAPViewTests/VAPTypesTests.swift`
- Modify: `Tests/VAPViewTests/VAPConfigModelTests.swift`
- Modify: `Tests/VAPViewTests/VAPRendererTests.swift`

- [ ] **Step 1: Write the failing public type tests**

Replace the old blend mode, constants, mask, and image-context tests in `Tests/VAPViewTests/VAPTypesTests.swift` with this target shape:

```swift
@Test func alphaPlacementRawValues() {
    #expect(VAPAlphaPlacement.left.rawValue == 0)
    #expect(VAPAlphaPlacement.right.rawValue == 1)
    #expect(VAPAlphaPlacement.top.rawValue == 2)
    #expect(VAPAlphaPlacement.bottom.rawValue == 3)
}

@Test func playbackDefaults() {
    #expect(VAPPlaybackDefaults.defaultFramesPerSecond == 25)
    #expect(VAPPlaybackDefaults.minimumFramesPerSecond == 1)
    #expect(VAPPlaybackDefaults.maximumFramesPerSecond == 60)
    #expect(VAPPlaybackDefaults.maximumCompatibleConfigVersion == 2)
    #expect(VAPPlaybackDefaults.minimumFramesPerSecond < VAPPlaybackDefaults.defaultFramesPerSecond)
    #expect(VAPPlaybackDefaults.defaultFramesPerSecond < VAPPlaybackDefaults.maximumFramesPerSecond)
}

@Test func maskConfigurationDefaults() {
    let data = Data([0, 1, 0, 1])
    let mask = VAPMaskConfiguration(data: data, dataSize: CGSize(width: 2, height: 2))
    #expect(mask.data == data)
    #expect(mask.dataSize == CGSize(width: 2, height: 2))
    #expect(mask.sampleRect == .zero)
    #expect(mask.blurLength == 0)
}

@Test func attachmentSourceImageURL() {
    let source = VAPAttachmentSource.imageURL("https://example.com/img.png")
    guard case .imageURL(let value) = source else {
        Issue.record("wrong case")
        return
    }
    #expect(value == "https://example.com/img.png")
}

@Test func attachmentImageContextFields() {
    let context = VAPAttachmentImageContext(
        sourceID: "avatar",
        contentMode: .scaleToFill,
        targetSize: CGSize(width: 100, height: 50),
        loadLocation: .remote
    )
    #expect(context.sourceID == "avatar")
    #expect(context.contentMode == .scaleToFill)
    #expect(context.targetSize == CGSize(width: 100, height: 50))
    #expect(context.loadLocation == .remote)
}
```

- [ ] **Step 2: Run the failing type tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPTypesTests
```

Expected: FAIL because `VAPAlphaPlacement`, `VAPPlaybackDefaults`, `VAPMaskConfiguration`, and `VAPAttachmentImageContext` do not exist yet.

- [ ] **Step 3: Replace public type definitions**

In `Sources/VAPView/Public/VAPTypes.swift`, replace the old `VAPTextureBlendMode`, `VAPOrientation`, public attachment raw enums, `kVAP...` constants, `VAPMaskInfo`, `VAPImageContext`, and `VAPImageLoader` definitions with the snapshot in "Target Public API Snapshot". Keep `VAPContentMode` public as-is. Rename `VAPError` cases as follows:

```swift
public enum VAPError: Error, Sendable {
    case fileNotFound(String)
    case unsupportedURLScheme(String)
    case invalidMP4File
    case streamInfoUnavailable
    case streamUnavailable
    case videoToolboxDescriptionCreationFailed
    case videoToolboxSessionCreationFailed
    case incompatibleVersion(Int)
    case missingVAPConfig
    case metalUnavailable
    case decodeFailed(Error)
    case unknown(String)
}
```

- [ ] **Step 4: Move raw vapc JSON enums into config model**

In `Sources/VAPView/Config/VAPConfigModel.swift`, add internal raw enums and update the decoded model to use them:

```swift
enum VAPConfigOrientation: Int, Sendable {
    case none = 0
    case portrait = 1
    case landscape = 2
}

enum VAPConfigAttachmentSourceType: String, Sendable {
    case text = "txt"
    case textString = "txtStr"
    case image = "img"
    case imageURL = "imgUrl"
}

enum VAPConfigAttachmentLoadType: String, Sendable {
    case local = "local"
    case network = "net"
}

enum VAPConfigAttachmentFitType: String, Sendable {
    case fitXY = "fitXY"
    case centerFull = "centerFull"
}

extension VAPConfigAttachmentLoadType {
    var publicLocation: VAPAttachmentLoadLocation {
        switch self {
        case .local:
            return .local
        case .network:
            return .remote
        }
    }
}

extension VAPConfigAttachmentFitType {
    var publicContentMode: VAPAttachmentImageContentMode {
        switch self {
        case .fitXY:
            return .scaleToFill
        case .centerFull:
            return .centerFill
        }
    }
}
```

Update properties and computed properties that currently return `VAPOrientation`, `VAPAttachmentSourceType`, `VAPAttachmentLoadType`, and `VAPAttachmentFitType` to return these raw config enums instead.

- [ ] **Step 5: Update config manager context conversion**

In `Sources/VAPView/Config/VAPConfigManager.swift`, update the image context construction and attachment cases:

```swift
let context = VAPAttachmentImageContext(
    sourceID: sourceInfo.sourceID,
    contentMode: sourceInfo.attachmentFitType.publicContentMode,
    targetSize: sourceInfo.w.flatMap { width in
        sourceInfo.h.map { height in CGSize(width: width, height: height) }
    },
    loadLocation: sourceInfo.attachmentLoadType?.publicLocation
)

switch sources[sourceInfo.sourceID] {
case .image(let image):
    if let texture = makeTexture(from: image) {
        textures[sourceInfo.sourceID] = texture
    }
case .imageURL(let urlString):
    guard let url = URL(string: urlString),
          ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
        break
    }
    guard let loader = imageLoader else {
        throw VAPError.unknown("imageLoader is required for .imageURL attachment (sourceID: \(sourceInfo.sourceID))")
    }
    let image = try await loader(url, context)
    if let texture = makeTexture(from: image) {
        textures[sourceInfo.sourceID] = texture
    }
case .text, nil:
    break
}
```

- [ ] **Step 6: Update alpha-placement references**

Apply these exact renames across `Sources/VAPView` and tests:

```text
VAPTextureBlendMode -> VAPAlphaPlacement
.alphaLeft -> .left
.alphaRight -> .right
.alphaTop -> .top
.alphaBottom -> .bottom
blendMode -> alphaPlacement
vapRGBSize(blendMode: -> rgbContentSize(alphaPlacement:
```

In `Sources/VAPView/Render/VAPRenderUtils.swift`, rename the helper signature to:

```swift
func rgbContentSize(alphaPlacement: VAPAlphaPlacement,
                    videoWidth: Int,
                    videoHeight: Int) -> CGSize
```

- [ ] **Step 7: Replace global defaults and error cases**

Apply these exact renames:

```text
kVAPDefaultFPS -> VAPPlaybackDefaults.defaultFramesPerSecond
kVAPMinFPS -> VAPPlaybackDefaults.minimumFramesPerSecond
kVAPMaxFPS -> VAPPlaybackDefaults.maximumFramesPerSecond
kVAPMaxCompatibleVersion -> VAPPlaybackDefaults.maximumCompatibleConfigVersion
cannotGetStreamInfo -> streamInfoUnavailable
cannotGetStream -> streamUnavailable
failedToCreateVTBDesc -> videoToolboxDescriptionCreationFailed
failedToCreateVTBSession -> videoToolboxSessionCreationFailed
```

Update `VAPPlayer.logDescription(for:)` to switch over the renamed `VAPError` cases.

- [ ] **Step 8: Run type, config, renderer, and parser tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPTypesTests -only-testing:VAPViewTests/VAPConfigModelTests -only-testing:VAPViewTests/VAPRendererTests -only-testing:VAPViewTests/VAPMP4ParserTests
```

Expected: PASS for the selected suites.

- [ ] **Step 9: Commit Task 1**

```bash
git add Sources/VAPView/Public/VAPTypes.swift Sources/VAPView/Config/VAPConfigModel.swift Sources/VAPView/Config/VAPConfigManager.swift Sources/VAPView/Render/VAPRenderUtils.swift Sources/VAPView/Render/VAPHWDRenderer.swift Sources/VAPView/Render/VAPRenderer.swift Sources/VAPView/Public/VAPPlayer.swift Sources/VAPView/Parser/VAPMP4Parser.swift Tests/VAPViewTests/VAPTypesTests.swift Tests/VAPViewTests/VAPConfigModelTests.swift Tests/VAPViewTests/VAPRendererTests.swift
git commit -m "refactor: rename public VAP types"
```

### Task 2: Rename Playback Configuration And Player Call Style

**Files:**
- Modify: `Sources/VAPView/Public/VAPPlayer.swift`
- Modify: `Sources/VAPView/Public/VAPView.swift`
- Modify: `Sources/VAPView/Decode/VAPVideoDecoder.swift`
- Modify: `Sources/VAPView/Parser/VAPMP4Parser.swift`
- Modify: `Tests/VAPViewTests/VAPTypesTests.swift`
- Modify: `Tests/VAPViewTests/VAPMP4ParserTests.swift`

- [ ] **Step 1: Add playback configuration tests**

Append these tests to `Tests/VAPViewTests/VAPTypesTests.swift`:

```swift
@Test func playbackConfigurationStoresRenamedFields() {
    let maskData = Data([1, 1, 1, 1])
    let mask = VAPMaskConfiguration(data: maskData, dataSize: CGSize(width: 2, height: 2))
    let configuration = VAPPlaybackConfiguration(
        source: "https://example.com/gift.mp4",
        alphaPlacement: .left,
        backgroundPolicy: .pauseAndResume,
        contentMode: .aspectFit,
        attachmentSources: ["avatar": .imageURL("https://example.com/avatar.png")],
        imageLoader: nil,
        frameBufferCapacity: 5,
        preferredFramesPerSecond: 30,
        playsAudio: false,
        mask: mask,
        loopCount: 3
    )

    #expect(configuration.source == "https://example.com/gift.mp4")
    #expect(configuration.alphaPlacement == .left)
    #expect(configuration.backgroundPolicy == .pauseAndResume)
    #expect(configuration.contentMode == .aspectFit)
    #expect(configuration.frameBufferCapacity == 5)
    #expect(configuration.preferredFramesPerSecond == 30)
    #expect(configuration.playsAudio == false)
    #expect(configuration.mask?.data == maskData)
    #expect(configuration.loopCount == 3)
}
```

- [ ] **Step 2: Run the failing configuration test**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPTypesTests/playbackConfigurationStoresRenamedFields
```

Expected: FAIL because `VAPPlaybackConfiguration` does not exist yet.

- [ ] **Step 3: Replace `VAPPlayConfig` with `VAPPlaybackConfiguration`**

In `Sources/VAPView/Public/VAPPlayer.swift`, replace the config struct with:

```swift
public struct VAPPlaybackConfiguration: Sendable {
    public var source: String
    public var alphaPlacement: VAPAlphaPlacement
    public var backgroundPolicy: VAPBackgroundPlaybackPolicy
    public var contentMode: VAPContentMode
    public var attachmentSources: [String: VAPAttachmentSource]
    public var imageLoader: VAPAttachmentImageLoader?
    public var frameBufferCapacity: Int
    public var preferredFramesPerSecond: Int
    public var playsAudio: Bool
    public var mask: VAPMaskConfiguration?
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
        self.source = source
        self.alphaPlacement = alphaPlacement
        self.backgroundPolicy = backgroundPolicy
        self.contentMode = contentMode
        self.attachmentSources = attachmentSources
        self.imageLoader = imageLoader
        self.frameBufferCapacity = frameBufferCapacity
        self.preferredFramesPerSecond = preferredFramesPerSecond
        self.playsAudio = playsAudio
        self.mask = mask
        self.loopCount = loopCount
    }
}
```

- [ ] **Step 4: Rename player API and state**

In `Sources/VAPView/Public/VAPPlayer.swift`, apply these exact renames:

```text
currentConfig -> currentConfiguration
onEventCallback -> eventHandler
epoch -> playbackGeneration
myEpoch -> generation
mtlDevice -> metalDevice
setMute(_ mute: Bool) -> setMuted(_ isMuted: Bool)
play(config:onEvent:) -> play(_:eventHandler:)
runPlayback(config:startFrame:epoch:) -> runPlayback(configuration:startFrame:generation:)
emitEvent(_:epoch:) -> emitEvent(_:generation:)
```

Use this public method shape:

```swift
public func play(_ configuration: VAPPlaybackConfiguration,
                 eventHandler: ((VAPEvent) -> Void)? = nil) {
    stop(emitEvent: false)
    playbackGeneration &+= 1
    currentConfiguration = configuration
    currentFrameIndex = 0
    self.eventHandler = eventHandler
    metalView.contentMode = configuration.contentMode
    installBackgroundObservers(for: configuration.backgroundPolicy)
    let generation = playbackGeneration
    playbackTask = Task { [weak self] in
        await self?.runPlayback(configuration: configuration, startFrame: 0, generation: generation)
    }
}
```

- [ ] **Step 5: Update playback-loop field names**

Inside `runPlayback`, apply these exact field changes:

```text
configuration.filePath -> configuration.source
configuration.blendMode -> configuration.alphaPlacement
configuration.bufferCount -> configuration.frameBufferCapacity
configuration.fps -> configuration.preferredFramesPerSecond
configuration.playAudio -> configuration.playsAudio
configuration.maskInfo -> configuration.mask
```

Update parser and audio calls:

```swift
let info: VAPMP4Info = try await Task.detached(priority: .userInitiated) {
    try VAPMP4Parser.parse(localFilePath: configuration.source)
}.value

if configuration.playsAudio && info.hasAudioTrack {
    setupAudio(localFilePath: configuration.source)
}
```

- [ ] **Step 6: Rename parser local path API**

In `Sources/VAPView/Parser/VAPMP4Parser.swift`, rename:

```swift
static func parse(filePath: String) throws -> VAPMP4Info
```

to:

```swift
static func parse(localFilePath: String) throws -> VAPMP4Info
```

Rename `VAPMP4Info.filePath` to `localFilePath`, and update `Sources/VAPView/Decode/VAPVideoDecoder.swift`:

```swift
self.fileHandle = FileHandle(forReadingAtPath: info.localFilePath)
```

- [ ] **Step 7: Run playback configuration and parser tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPTypesTests -only-testing:VAPViewTests/VAPMP4ParserTests
```

Expected: PASS for selected suites.

- [ ] **Step 8: Commit Task 2**

```bash
git add Sources/VAPView/Public/VAPPlayer.swift Sources/VAPView/Public/VAPView.swift Sources/VAPView/Decode/VAPVideoDecoder.swift Sources/VAPView/Parser/VAPMP4Parser.swift Tests/VAPViewTests/VAPTypesTests.swift Tests/VAPViewTests/VAPMP4ParserTests.swift
git commit -m "refactor: rename playback configuration API"
```

### Task 3: Rename Resource Loader, Cache, And Prefetch API

**Files:**
- Modify: `Sources/VAPView/Network/VAPResourceLoader.swift`
- Modify: `Sources/VAPView/Network/VAPDiskCache.swift`
- Modify: `Sources/VAPView/Public/VAPView.swift`
- Modify: `Tests/VAPViewTests/VAPDiskCacheTests.swift`
- Modify: `Tests/VAPViewTests/VAPViewPrefetchTests.swift`

- [ ] **Step 1: Update prefetch test to the target API**

Replace `Tests/VAPViewTests/VAPViewPrefetchTests.swift` with:

```swift
import Testing
import Foundation
@testable import VAPView

private final class VAPPrefetchRecordingLoader: VAPResourceLoader, @unchecked Sendable {
    nonisolated(unsafe) private(set) var requestedSource: String?

    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        requestedSource = source
        await progressHandler(0.5)
        return "/tmp/prefetched.mp4"
    }
}

@Suite("VAPView prefetch")
struct VAPViewPrefetchTests {
    @Test @MainActor func prefetchUsesResourceLoaderWithoutViewInstance() async throws {
        let loader = VAPPrefetchRecordingLoader()
        var progressValues: [Double] = []

        let path = try await VAPView.prefetch(
            source: "https://example.com/prefetch.mp4",
            using: loader
        ) { progress in
            progressValues.append(progress)
        }

        #expect(path == "/tmp/prefetched.mp4")
        #expect(loader.requestedSource == "https://example.com/prefetch.mp4")
        #expect(progressValues == [0.5])
    }
}
```

- [ ] **Step 2: Update disk cache tests to target names**

In `Tests/VAPViewTests/VAPDiskCacheTests.swift`, apply these exact renames:

```text
localPath(for: -> resolveLocalPath(for:
onProgress: -> progressHandler:
clearCacheRemovesFiles -> removeAllCachedResourcesRemovesFiles
cache.clearCache() -> cache.removeAllCachedResources()
localPathReturnedUnchanged -> localSourceReturnedUnchanged
```

- [ ] **Step 3: Run failing resource tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPViewPrefetchTests -only-testing:VAPViewTests/VAPDiskCacheTests
```

Expected: FAIL because loader/cache APIs still expose old names.

- [ ] **Step 4: Replace resource loader protocols**

Replace `Sources/VAPView/Network/VAPResourceLoader.swift` with:

```swift
// VAPResourceLoader.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

/// Resolves a local path or remote URL string to a local readable file path.
///
/// The default implementation is `VAPDiskCache.shared`.
public protocol VAPResourceLoader: AnyObject, Sendable {
    /// Returns a local file path for the given source.
    ///
    /// - Parameters:
    ///   - source: A local file path or remote `https://` URL string.
    ///   - progressHandler: Called on the main actor with download progress in `0...1`.
    /// - Returns: An absolute local file path ready for playback.
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String
}

/// Provides cache-management operations for loaders that own local cached files.
public protocol VAPResourceCacheCleaning: AnyObject {
    /// Removes all files managed by the cache.
    func removeAllCachedResources() throws
}
```

- [ ] **Step 5: Update disk cache implementation**

In `Sources/VAPView/Network/VAPDiskCache.swift`, change the class declaration and public methods:

```swift
public final class VAPDiskCache: VAPResourceLoader, VAPResourceCacheCleaning {
    @concurrent public func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        guard source.hasPrefix("http://") || source.hasPrefix("https://") else {
            return source
        }
        guard source.hasPrefix("https://") else {
            throw VAPError.unsupportedURLScheme(source)
        }
        guard let url = URL(string: source) else {
            throw VAPError.fileNotFound(source)
        }
        let cacheKey = cacheFileName(for: source, pathExtension: url.pathExtension)
        let destination = cacheDirectory.appendingPathComponent(cacheKey)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.path
        }
        return try await download(url: url, destination: destination, progressHandler: progressHandler)
    }

    public func removeAllCachedResources() throws {
        let items = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        for item in items {
            try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(item))
        }
    }
}
```

Apply these internal renames in the same file:

```text
cacheDir -> cacheDirectory
dest -> destination
ext -> pathExtension
mgr -> sessionManager
isOwner -> ownsEntry
onProgress -> progressHandler
cb -> progressHandler
DownloadHandler -> DownloadRequest
```

- [ ] **Step 6: Update VAPView prefetch and playback resource resolution**

In `Sources/VAPView/Public/VAPView.swift`, update prefetch:

```swift
@discardableResult
@concurrent public nonisolated static func prefetch(
    source: String,
    using resourceLoader: VAPResourceLoader = VAPDiskCache.shared,
    progressHandler: (@MainActor @Sendable (Double) -> Void)? = nil
) async throws -> String {
    let handler: @MainActor @Sendable (Double) -> Void = progressHandler ?? { _ in }
    return try await resourceLoader.resolveLocalPath(for: source, progressHandler: handler)
}
```

Update remote playback resolution:

```swift
let localPath = try await loader.resolveLocalPath(for: configuration.source) { progress in
    wrappedEventHandler?(.downloading(progress: progress))
}
```

- [ ] **Step 7: Run resource tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPViewPrefetchTests -only-testing:VAPViewTests/VAPDiskCacheTests
```

Expected: PASS for selected suites. The real network suite may require network access; if it fails due connectivity, rerun without `VAPDiskCache_Network` and keep unit suites passing.

- [ ] **Step 8: Commit Task 3**

```bash
git add Sources/VAPView/Network/VAPResourceLoader.swift Sources/VAPView/Network/VAPDiskCache.swift Sources/VAPView/Public/VAPView.swift Tests/VAPViewTests/VAPDiskCacheTests.swift Tests/VAPViewTests/VAPViewPrefetchTests.swift
git commit -m "refactor: rename resource loading API"
```

### Task 4: Rename VAPView Surface API

**Files:**
- Modify: `Sources/VAPView/Public/VAPView.swift`
- Modify: `Sources/VAPView/Public/VAPPlayer.swift`
- Modify: `Sources/VAPView/Render/VAPMetalView.swift`
- Create: `Tests/VAPViewTests/VAPViewAPITests.swift`

- [ ] **Step 1: Add VAPView API style tests**

Create `Tests/VAPViewTests/VAPViewAPITests.swift`:

```swift
import Testing
import UIKit
@testable import VAPView

@Suite("VAPView API")
struct VAPViewAPITests {
    @Test @MainActor func gestureAPIUsesHandlerTerminology() {
        let view = VAPView()
        let gesture = UITapGestureRecognizer()
        var called = false

        view.addTapGesture { _ in called = true }
        view.addGesture(gesture) { _ in called = true }
        view.removeGesture(gesture)

        #expect(called == false)
    }

    @Test @MainActor func conveniencePlayAcceptsLoopCount() {
        let view = VAPView()
        view.shouldStartPlayback = { configuration in
            configuration.loopCount == 2
        }

        view.play(source: "/tmp/missing.mp4", loopCount: 2) { _ in }
        view.stop()
    }
}
```

- [ ] **Step 2: Run failing VAPView API tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPViewAPITests
```

Expected: FAIL because `shouldStartPlayback`, `addTapGesture`, `addGesture(_:handler:)`, `removeGesture`, and `play(source:loopCount:eventHandler:)` do not exist yet.

- [ ] **Step 3: Rename VAPView properties and gestures**

In `Sources/VAPView/Public/VAPView.swift`, apply these exact renames:

```text
autoDestroyAfterFinish -> automaticallyDestroysPlayerAfterPlayback
fps -> preferredFramesPerSecond
shouldStartPlay -> shouldStartPlayback
addVapTapGesture -> addTapGesture
addVapGesture(_:callback:) -> addGesture(_:handler:)
removeVapGesture -> removeGesture
handleVapGesture -> handleGesture
gestureHandlers callback tuple label -> handler
```

Remove this unused property:

```swift
private var onEvent: ((VAPEvent) -> Void)?
```

Update the unavailable override message:

```swift
@available(*, unavailable, message: "Use addTapGesture or addGesture(_:handler:) instead.")
override public func addGestureRecognizer(_ gestureRecognizer: UIGestureRecognizer) {
    super.addGestureRecognizer(gestureRecognizer)
}
```

- [ ] **Step 4: Rename VAPView playback calls**

Replace the main play method signature with:

```swift
public func play(_ configuration: VAPPlaybackConfiguration,
                 eventHandler: ((VAPEvent) -> Void)? = nil)
```

Inside the method use:

```swift
var playbackConfiguration = configuration
playbackConfiguration.preferredFramesPerSecond =
    preferredFramesPerSecond > 0
    ? preferredFramesPerSecond
    : configuration.preferredFramesPerSecond

if let shouldStartPlayback, !shouldStartPlayback(playbackConfiguration) {
    return
}
```

Replace the wrapped callback name with:

```swift
let wrappedEventHandler: ((VAPEvent) -> Void)? = { [weak self] event in
    guard let self else { return }
    eventHandler?(event)
    switch event {
    case .didFinish, .didStop:
        if self.automaticallyDestroysPlayerAfterPlayback {
            self.teardown()
        }
    default:
        break
    }
}
```

- [ ] **Step 5: Replace the convenience play overload**

Replace the old `play(filePath:...)` overload with:

```swift
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
```

- [ ] **Step 6: Rename Metal view content mode**

In `Sources/VAPView/Render/VAPMetalView.swift`, rename:

```text
vapContentMode -> contentMode
```

In `Sources/VAPView/Public/VAPPlayer.swift`, update:

```swift
metalView.contentMode = configuration.contentMode
```

- [ ] **Step 7: Run VAPView API tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPViewAPITests -only-testing:VAPViewTests/VAPViewPrefetchTests
```

Expected: PASS for selected suites.

- [ ] **Step 8: Commit Task 4**

```bash
git add Sources/VAPView/Public/VAPView.swift Sources/VAPView/Public/VAPPlayer.swift Sources/VAPView/Render/VAPMetalView.swift Tests/VAPViewTests/VAPViewAPITests.swift
git commit -m "refactor: rename VAPView public API"
```

### Task 5: Fix Stop Event Semantics

**Files:**
- Modify: `Sources/VAPView/Public/VAPPlayer.swift`
- Modify: `Sources/VAPView/Public/VAPView.swift`
- Create: `Tests/VAPViewTests/VAPPlayerEventTests.swift`

- [ ] **Step 1: Add stop event regression tests**

Create `Tests/VAPViewTests/VAPPlayerEventTests.swift`:

```swift
import Testing
import Foundation
@testable import VAPView

@Suite("VAPPlayer events")
struct VAPPlayerEventTests {
    @Test @MainActor func stopEmitsDidStopForActivePlayback() async throws {
        let player = VAPPlayer()
        var receivedEvents: [VAPEvent] = []

        player.play(VAPPlaybackConfiguration(source: "/tmp/missing-stop-test.mp4")) { event in
            receivedEvents.append(event)
        }
        player.stop()
        try await Task.sleep(nanoseconds: 50_000_000)

        let stopEvents = receivedEvents.compactMap { event -> Int? in
            guard case .didStop(let lastFrame) = event else { return nil }
            return lastFrame
        }
        #expect(stopEvents == [0])
    }

    @Test @MainActor func pauseDoesNotEmitDidStop() async throws {
        let player = VAPPlayer()
        var receivedStop = false

        player.play(VAPPlaybackConfiguration(source: "/tmp/missing-pause-test.mp4")) { event in
            if case .didStop = event {
                receivedStop = true
            }
        }
        player.pause()
        try await Task.sleep(nanoseconds: 50_000_000)

        #expect(receivedStop == false)
    }
}
```

- [ ] **Step 2: Run failing stop event tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPPlayerEventTests
```

Expected: FAIL because `stop()` currently clears the callback before `.didStop` can be delivered, and `pause()` cancellation can leak through the playback loop.

- [ ] **Step 3: Add explicit event delivery helper**

In `Sources/VAPView/Public/VAPPlayer.swift`, add:

```swift
private func deliverEvent(_ event: VAPEvent) {
    _eventContinuation.yield(event)
    eventHandler?(event)
}

private func emitEvent(_ event: VAPEvent, generation: Int) {
    guard generation == playbackGeneration else { return }
    deliverEvent(event)
}
```

- [ ] **Step 4: Replace public stop with controlled stop**

In `Sources/VAPView/Public/VAPPlayer.swift`, replace `stop()` with:

```swift
public func stop() {
    stop(emitEvent: true)
}

private func stop(emitEvent shouldEmitStop: Bool) {
    let lastFrame = currentFrameIndex
    let hasActivePlayback = playbackTask != nil

    playbackGeneration &+= 1
    playbackTask?.cancel()
    playbackTask = nil
    stopAudio()
    removeBackgroundObservers()
    currentConfiguration = nil
    currentFrameIndex = 0

    if shouldEmitStop && hasActivePlayback {
        deliverEvent(.didStop(lastFrame: lastFrame))
    }

    eventHandler = nil
}
```

Keep `play(_:, eventHandler:)` calling:

```swift
stop(emitEvent: false)
```

- [ ] **Step 5: Prevent cancellation branch from emitting stop**

In `runPlayback`, replace the cancellation branch with:

```swift
if Task.isCancelled {
    decodeProducer.cancel()
    stopAudio()
    await decoder.invalidate()
    return
}
```

In the initial decode loop, keep cancellation silent:

```swift
guard !Task.isCancelled else {
    await decoder.invalidate()
    return
}
```

- [ ] **Step 6: Update VAPView stop call**

In `Sources/VAPView/Public/VAPView.swift`, keep public view stop as:

```swift
public func stop() {
    playTask?.cancel()
    playTask = nil
    player?.stop()
    teardown()
}
```

This lets `VAPPlayer.stop()` deliver `.didStop` before the view tears down.

- [ ] **Step 7: Run event tests**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -only-testing:VAPViewTests/VAPPlayerEventTests
```

Expected: PASS for selected suite.

- [ ] **Step 8: Commit Task 5**

```bash
git add Sources/VAPView/Public/VAPPlayer.swift Sources/VAPView/Public/VAPView.swift Tests/VAPViewTests/VAPPlayerEventTests.swift
git commit -m "fix: make stop event delivery deterministic"
```

### Task 6: Clean Internal Naming And Call Flow

**Files:**
- Modify: `Sources/VAPView/Public/VAPPlayer.swift`
- Modify: `Sources/VAPView/Config/VAPConfigManager.swift`
- Modify: `Sources/VAPView/Network/VAPDiskCache.swift`
- Modify: `Sources/VAPView/Render/VAPRenderUtils.swift`
- Modify: `Sources/VAPView/Render/VAPHWDRenderer.swift`
- Modify: `Sources/VAPView/Render/VAPRenderer.swift`
- Modify: `Sources/VAPView/Utils/VAPLogger.swift`

- [ ] **Step 1: Search for remaining legacy names**

Run:

```bash
rg -n "VAPPlayConfig|VAPTextureBlendMode|VAPMaskInfo|VAPImageContext|VAPImageLoader|filePath|onEvent|callback|blendMode|fps|playAudio|bufferCount|maskInfo|kVAP|addVap|clearCache|localPath\\(|mtlDevice|useVAPPath|hwdRenderer|vapRenderer|attachResources|bufCount|_device|_loader|_sources|\\bmgr\\b|\\bcb\\b|\\bmv\\b" Sources/VAPView Tests README.md README_CN.md
```

Expected before this task: matches remain only in internal parser/logging terminology and documentation that has not been updated yet.

- [ ] **Step 2: Rename playback-loop locals**

In `Sources/VAPView/Public/VAPPlayer.swift`, apply these exact renames:

```text
useVAPPath -> usesAttachmentRenderer
hwdRenderer -> splitAlphaRenderer
vapRenderer -> attachmentRenderer
attachResources -> attachmentResources
bufCount -> frameBufferCapacity
decodeProducer -> decodeProducerTask
cycleStart -> cycleStartFrame
initialDecodeEnd -> initialDecodeEndFrame
```

Replace the detached config load capture block:

```swift
let attachmentDevice = device
let attachmentImageLoader = configuration.imageLoader
let attachmentSources = configuration.attachmentSources
attachmentResources = try await Task.detached(priority: .userInitiated) {
    let configManager = VAPConfigManager(device: attachmentDevice, imageLoader: attachmentImageLoader)
    return try await configManager.load(vapcJSON: jsonData, sources: attachmentSources)
}.value
```

- [ ] **Step 3: Rename lifecycle observer helpers**

In `Sources/VAPView/Public/VAPPlayer.swift`, apply:

```text
setupBackgroundObservers(policy:) -> installBackgroundObservers(for:)
removeBackgroundObservers() -> removeLifecycleObservers()
```

Update all call sites in `play(_:, eventHandler:)`, `stop(emitEvent:)`, and deinit-related cleanup.

- [ ] **Step 4: Rename logger path redaction terminology**

In `Sources/VAPView/Utils/VAPLogger.swift`, update the redaction regex to support the new `source` label while preserving existing `filePath` logs from lower-level parser code:

```swift
pattern: #"\b(filePath|localFilePath|path|source)=([^\s]+)"#
```

- [ ] **Step 5: Rename short locals in disk cache and config manager**

In `Sources/VAPView/Network/VAPDiskCache.swift`, apply:

```text
cont -> continuation
DownloadRequest.dest -> destination
DownloadRequest.onProgress -> progressHandler
handler.onProgress -> handler.progressHandler
```

In `Sources/VAPView/Config/VAPConfigManager.swift`, apply:

```text
srcInfo -> sourceInfo
srcType -> sourceType
img -> image
tex -> texture
ctx -> context
attrs -> attributes
str -> renderedText
```

- [ ] **Step 6: Run legacy-name scan again**

Run:

```bash
rg -n "VAPPlayConfig|VAPTextureBlendMode|VAPMaskInfo|VAPImageContext|VAPImageLoader|onEvent|callback|blendMode|playAudio|bufferCount|maskInfo|kVAP|addVap|clearCache|localPath\\(|mtlDevice|useVAPPath|hwdRenderer|vapRenderer|attachResources|bufCount|_device|_loader|_sources|\\bmgr\\b|\\bcb\\b|\\bmv\\b" Sources/VAPView Tests README.md README_CN.md
```

Expected: no matches except external `vapc` domain strings, shader names, comments that describe file-format details, and `filePath` inside parser/logging where the value is truly a local file path.

- [ ] **Step 7: Run focused build**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' build-for-testing
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 8: Commit Task 6**

```bash
git add Sources/VAPView/Public/VAPPlayer.swift Sources/VAPView/Config/VAPConfigManager.swift Sources/VAPView/Network/VAPDiskCache.swift Sources/VAPView/Render/VAPRenderUtils.swift Sources/VAPView/Render/VAPHWDRenderer.swift Sources/VAPView/Render/VAPRenderer.swift Sources/VAPView/Utils/VAPLogger.swift
git commit -m "refactor: clean internal VAP naming"
```

### Task 7: Update Documentation And Full Verification

**Files:**
- Modify: `README.md`
- Modify: `README_CN.md`
- Modify: `Tests/VAPViewTests/VAPLoggerTests.swift`

- [ ] **Step 1: Update README public API examples**

In `README.md`, replace old examples with this shape:

```swift
let vapView = VAPView(frame: view.bounds)
view.addSubview(vapView)

vapView.play(
    source: "path/to/animation.mp4",
    alphaPlacement: .right,
    eventHandler: { event in
        print(event)
    }
)
```

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

```swift
try await VAPView.prefetch(source: "https://example.com/gift.mp4") { progress in
    print(progress)
}
```

```swift
final class CustomResourceLoader: VAPResourceLoader {
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        source
    }
}
```

- [ ] **Step 2: Update README_CN public API examples**

In `README_CN.md`, use the same API names and Chinese descriptions:

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

Use these table names:

```text
VAPPlaybackConfiguration
source
alphaPlacement
preferredFramesPerSecond
playsAudio
frameBufferCapacity
mask
VAPView.prefetch(source:using:progressHandler:)
play(_:eventHandler:)
play(source:alphaPlacement:backgroundPolicy:contentMode:attachmentSources:imageLoader:frameBufferCapacity:mask:playsAudio:loopCount:eventHandler:)
```

- [ ] **Step 3: Update logger tests**

In `Tests/VAPViewTests/VAPLoggerTests.swift`, add a source-redaction assertion:

```swift
@Test func redactsSourceLabels() {
    let collector = VAPLogCollector()
    VAPLogging.configure(
        VAPLogConfiguration(
            level: .error,
            osLogEnabled: false,
            handler: { collector.append($0) }
        )
    )
    defer { VAPLogging.resetConfiguration() }

    VAPLogger(module: .player).error(
        "source=/Users/test/private.mp4 localFilePath=/Users/test/cache.mp4"
    )

    let message = collector.records.first?.message ?? ""
    #expect(message.contains("source=<redacted-path>"))
    #expect(message.contains("localFilePath=<redacted-path>"))
    #expect(!message.contains("/Users/test"))
}
```

- [ ] **Step 4: Run the stale-name scan across docs and sources**

Run:

```bash
rg -n "VAPPlayConfig|VAPTextureBlendMode|VAPMaskInfo|VAPImageContext|VAPImageLoader|filePath:|onEvent|callback:|blendMode|playAudio|bufferCount|maskInfo|kVAP|addVap|clearCache|localPath\\(" Sources/VAPView Tests README.md README_CN.md
```

Expected: no stale public API names remain. `filePath` may remain only as parser-local implementation terminology where the function explicitly handles a local file path.

- [ ] **Step 5: Run whitespace verification**

Run:

```bash
git diff --check
```

Expected: no output.

- [ ] **Step 6: Run build-for-testing**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' build-for-testing
```

Expected: BUILD SUCCEEDED.

- [ ] **Step 7: Run full simulator tests with known fixture skip**

Run:

```bash
xcodebuild -scheme VAPView -destination 'platform=iOS Simulator,id=49428834-37D6-4470-BF7F-951C0F3441D4' -enableCodeCoverage NO test -skip-testing:VAPViewTests/GiftEffectsFixtureTests
```

Expected: TEST SUCCEEDED. `GiftEffectsFixtureTests` is skipped because it reads Demo files using the simulator test process current directory.

- [ ] **Step 8: Document SwiftPM limitation**

Do not use `swift test` as the primary verification command in this repository. SwiftPM test execution targets macOS in this environment, while the package imports UIKit and is declared for iOS 14+.

- [ ] **Step 9: Commit Task 7**

```bash
git add README.md README_CN.md Tests/VAPViewTests/VAPLoggerTests.swift
git commit -m "docs: update VAPView API naming"
```

## Self-Review Checklist

- Spec coverage:
  - Viewless prefetch API is renamed and remains `@concurrent`.
  - Same-URL request coalescing remains in `VAPDiskCache`.
  - Public comments and README examples use iOS SDK style labels.
  - `@concurrent` remains on asynchronous resource-loading entry points.
  - Naming cleanup covers VAPView, VAPPlayer, resource loading, public types, parser-local path names, and internal playback-loop abbreviations.
  - Stop event behavior is fixed because it is part of the public event API call semantics.
- Placeholder scan:
  - The plan does not rely on open-ended implementation steps.
  - Every task lists exact files, exact target names, and exact verification commands.
- Type consistency:
  - `VAPPlaybackConfiguration.source` is used by VAPView and VAPPlayer.
  - `VAPAlphaPlacement` replaces `VAPTextureBlendMode`.
  - `VAPAttachmentImageLoader` receives `VAPAttachmentImageContext`.
  - `VAPResourceLoader.resolveLocalPath(for:progressHandler:)` is used by VAPDiskCache, VAPView prefetch, and remote playback.

## Execution Handoff

Plan complete and saved to `docs/superpowers/plans/2026-06-26-vapview-api-naming-cleanup.md`.

Two execution options:

1. Subagent-Driven (recommended) - Dispatch a fresh subagent per task, review between tasks, fast iteration.
2. Inline Execution - Execute tasks in this session using executing-plans, batch execution with checkpoints.
