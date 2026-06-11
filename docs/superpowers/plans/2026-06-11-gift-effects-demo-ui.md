# Gift Effects Demo UI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build a comprehensive UIKit demo UI that loads `gift_effects_mp4.json`, lets users select gift effects, and plays the selected VAP MP4 with status and debug controls.

**Architecture:** Keep the change demo-scoped. `ViewController` owns local UI state, decodes a small `GiftEffect` model from the app bundle, renders a `UICollectionView` grid, and sends selected URLs into `VAPView.play`. The Xcode project must bundle `gift_effects_mp4.json` so runtime bundle loading works.

**Tech Stack:** UIKit, Auto Layout, `UICollectionView`, Swift `Decodable`, `VAPPlayer`, SwiftPM XCTest for fixture/project validation, Xcode project resources.

---

## File Structure

- Modify `Demo/VAPDemoApp/ViewController.swift`: replace the single hard-coded URL demo with the combined player, status, gift grid, and controls.
- Modify `Demo/VAPDemo.xcodeproj/project.pbxproj`: add `gift_effects_mp4.json` to the app group and resources build phase.
- Create `Tests/VAPPlayerTests/GiftEffectsFixtureTests.swift`: document the JSON fixture and project resource expectations for environments that can run the iOS package tests.

## Task 1: Add Fixture And Project Resource Tests

**Files:**
- Create: `Tests/VAPPlayerTests/GiftEffectsFixtureTests.swift`

- [ ] **Step 1: Write the failing resource test**

```swift
import XCTest

final class GiftEffectsFixtureTests: XCTestCase {
    private struct GiftEffect: Decodable {
        let name: String
        let url: String
    }

    func testGiftEffectsFixtureDecodesNamedRemoteMP4Entries() throws {
        let data = try Data(contentsOf: giftEffectsURL())
        let effects = try JSONDecoder().decode([GiftEffect].self, from: data)

        XCTAssertEqual(effects.count, 145)
        XCTAssertTrue(effects.allSatisfy { !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertTrue(effects.allSatisfy { $0.url.hasPrefix("https://") })
        XCTAssertTrue(effects.allSatisfy { $0.url.hasSuffix(".mp4") })
    }

    func testDemoProjectBundlesGiftEffectsFixture() throws {
        let projectText = try String(contentsOf: demoProjectURL(), encoding: .utf8)

        XCTAssertTrue(projectText.contains("gift_effects_mp4.json"))
        XCTAssertTrue(projectText.contains("gift_effects_mp4.json in Resources"))
    }

    private func giftEffectsURL() throws -> URL {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let url = root.appendingPathComponent("Demo/VAPDemoApp/gift_effects_mp4.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    private func demoProjectURL() -> URL {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Demo/VAPDemo.xcodeproj/project.pbxproj")
    }
}
```

- [ ] **Step 2: Run the focused resource assertion and confirm RED**

Run:

```bash
ruby -e 'text = File.read("Demo/VAPDemo.xcodeproj/project.pbxproj"); abort("missing gift_effects_mp4.json resource") unless text.include?("gift_effects_mp4.json") && text.include?("gift_effects_mp4.json in Resources")'
```

Expected: FAIL because `project.pbxproj` does not yet contain `gift_effects_mp4.json`.

## Task 2: Bundle The JSON Fixture

**Files:**
- Modify: `Demo/VAPDemo.xcodeproj/project.pbxproj`

- [ ] **Step 1: Add JSON file reference and resource build file**

Add a `PBXFileReference` for `gift_effects_mp4.json`, a `PBXBuildFile` named `gift_effects_mp4.json in Resources`, include the file in the `VAPDemoApp` group, and include the build file in `PBXResourcesBuildPhase.files`.

- [ ] **Step 2: Run the focused resource assertion and confirm GREEN**

Run:

```bash
ruby -e 'text = File.read("Demo/VAPDemo.xcodeproj/project.pbxproj"); abort("missing gift_effects_mp4.json resource") unless text.include?("gift_effects_mp4.json") && text.include?("gift_effects_mp4.json in Resources"); puts "project resource ok"'
```

Expected: PASS.

- [ ] **Step 3: Run the fixture decoding assertion**

Run:

```bash
ruby -rjson -e 'data = JSON.parse(File.read("Demo/VAPDemoApp/gift_effects_mp4.json")); abort("expected 145") unless data.length == 145; abort("bad names") unless data.all? { |e| e["name"].to_s.strip != "" }; abort("bad urls") unless data.all? { |e| e["url"].to_s.start_with?("https://") && e["url"].to_s.end_with?(".mp4") }; puts "gift fixture ok: #{data.length}"'
```

Expected: PASS with 145 entries.

## Task 3: Replace Demo View Controller With Combined UI

**Files:**
- Modify: `Demo/VAPDemoApp/ViewController.swift`

- [ ] **Step 1: Add local model and state**

Add:

```swift
private struct GiftEffect: Decodable, Hashable {
    let name: String
    let url: String
}

private var giftEffects: [GiftEffect] = []
private var selectedGiftIndex: Int?
private var selectedBlendMode: VAPTextureBlendMode = .alphaRight
```

- [ ] **Step 2: Add player, title/status/progress, collection view, and controls**

Use `VAPView`, two compact labels, a hidden `UIProgressView`, a two-column `UICollectionView`, and the existing four playback/cache buttons.

- [ ] **Step 3: Add bundle JSON loading**

Implement `loadGiftEffects()` using:

```swift
guard let url = Bundle.main.url(forResource: "gift_effects_mp4", withExtension: "json") else {
    setStatus("Gift list not found")
    return
}
giftEffects = try JSONDecoder().decode([GiftEffect].self, from: Data(contentsOf: url))
```

Select the first item by default and update labels without autoplay.

- [ ] **Step 4: Add collection view data source and delegate**

Render gift names in a reusable `GiftCell`. Tapping a cell updates `selectedGiftIndex`, reloads selection highlighting, and calls `startPlay(effect:blendMode:)`.

- [ ] **Step 5: Add playback wiring**

Create `startSelectedGift()`, `startPlay(effect:blendMode:)`, `playLeftTapped()`, `playRightTapped()`, `stopTapped()`, and `clearCacheTapped()` so existing controls still work against the selected gift.

- [ ] **Step 6: Add event callback UI updates**

In the `vapView.play` callback, dispatch to the main queue and handle `.downloading`, `.didStart`, `.didPlayFrame`, `.didLoopFinish`, `.didFinish`, `.didStop`, and `.didFail`.

## Task 4: Verify Build And Tests

**Files:**
- No source edits unless verification exposes a compiler or test failure.

- [ ] **Step 1: Run package tests when the environment supports iOS package testing**

Run: `swift test`

Expected in this local environment: `swift test` may fail before tests execute because SwiftPM compiles this iOS-only package against the macOS SDK and cannot resolve `UIKit`. Treat the Xcode app build below as the compile verification for this demo change.

- [ ] **Step 2: Build the demo app**

Run:

```bash
xcodebuild -project Demo/VAPDemo.xcodeproj -scheme VAPDemo -destination 'generic/platform=iOS Simulator' -derivedDataPath /tmp/VAPDemoDerivedData CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=15.0 build
```

Expected: build exits 0. The command-line iOS 15 deployment override is only for this Xcode beta, whose simulator SDK no longer supports deployment target 14.0; do not change the project minimum version for this UI task.

- [ ] **Step 3: Review final diff**

Run: `git diff -- Demo/VAPDemoApp/ViewController.swift Demo/VAPDemo.xcodeproj/project.pbxproj Tests/VAPPlayerTests/GiftEffectsFixtureTests.swift`

Expected: diff is limited to the demo UI, JSON resource registration, and fixture tests.

## Task 5: Commit Implementation

**Files:**
- Stage all implementation and test files from this plan.

- [ ] **Step 1: Check status**

Run: `git status --short`

Expected: only planned files are modified or added.

- [ ] **Step 2: Commit**

Run:

```bash
git add Demo/VAPDemoApp/ViewController.swift Demo/VAPDemo.xcodeproj/project.pbxproj Tests/VAPPlayerTests/GiftEffectsFixtureTests.swift docs/superpowers/plans/2026-06-11-gift-effects-demo-ui.md
git commit -m "Build gift effects demo UI"
```

Expected: commit succeeds on `codex/gift-effects-demo-ui`.
