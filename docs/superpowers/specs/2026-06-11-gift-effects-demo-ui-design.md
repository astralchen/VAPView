# Gift Effects Demo UI Design

## Context

The demo app currently plays one hard-coded remote VAP MP4 URL and exposes two alpha blend mode buttons plus stop and cache controls. The repository already includes `Demo/VAPDemoApp/gift_effects_mp4.json`, which contains 145 gift effect entries with a `name` and remote `url`.

This design updates only the UIKit demo app. The `VAPPlayer` package API, renderer, parser, cache implementation, and tests remain unchanged unless a demo integration issue exposes a genuine library bug.

## Goal

Create a comprehensive example UI that demonstrates selecting gift effects from `gift_effects_mp4.json`, playing the selected MP4 in `VAPView`, and observing basic playback state and download progress.

The demo should be useful both as a product-like sample and as a lightweight playback debugging surface.

## UI Structure

The screen remains a single `ViewController` built with UIKit and programmatic layout.

1. Player area
   - A prominent `VAPView` at the top of the screen.
   - Dark playback background to make transparent effects readable.
   - Stable aspect-ratio constraints so playback layout does not jump.

2. Current gift and status
   - A compact information area below the player.
   - Shows the selected gift name.
   - Shows playback state such as ready, downloading, playing, finished, stopped, or failed.
   - Shows `UIProgressView` only while remote resources are downloading.

3. Gift selector
   - A `UICollectionView` backed by the JSON data.
   - Uses a compact grid layout for scanning many gifts.
   - Displays gift names as selectable cells.
   - Highlights the selected gift.
   - Tapping a gift starts playback using the currently selected alpha mode.

4. Playback controls
   - Keeps the existing core controls: `Alpha Left`, `Alpha Right`, `Stop`, and `Clear Cache`.
   - Alpha buttons update the selected blend mode and replay the current gift when one is selected.
   - Stop stops playback and updates the status.
   - Clear cache calls `VAPDiskCache.shared.clearCache()` and reports success or failure.

## Data Flow

Introduce a small demo-only `GiftEffect` model:

```swift
private struct GiftEffect: Decodable, Hashable {
    let name: String
    let url: String
}
```

On `viewDidLoad`, the controller loads `gift_effects_mp4.json` from the app bundle and decodes `[GiftEffect]`.

State stays local to `ViewController`:

- `giftEffects: [GiftEffect]`
- `selectedGiftIndex: Int?`
- `selectedBlendMode: VAPTextureBlendMode`

Playback always goes through `startPlay(effect:blendMode:)`, which creates `VAPPlayConfig` with the selected gift URL, selected blend mode, `.pauseAndResume` background policy, `.aspectFit` content mode, and `loopCount: 1`.

## Event Handling

The `VAPView.play` event callback updates UI on the main queue:

- `.downloading(progress)` shows and updates the progress bar.
- `.didStart` hides progress and shows playing status.
- `.didPlayFrame(index)` may update frame status at a throttled interval.
- `.didLoopFinish(loop,totalFrames)` reports loop completion.
- `.didFinish(totalFrames)` reports finished.
- `.didStop(lastFrame)` reports stopped.
- `.didFail(error)` reports a readable error.

All status text should be short enough to fit on small iPhone widths.

## Error Handling

If the JSON file cannot be found or decoded, the collection view shows no items and the status area reports the load failure.

If the user taps playback before data is available, the action is ignored and the status explains that no gift is selected.

Playback failures should not crash the demo. They should update status and leave controls usable.

## Styling

The visual language should stay demo-focused and restrained:

- Dark background for playback clarity.
- Compact controls with 8 pt corner radius or less.
- Selected gift cells use a clear accent color and border.
- Avoid decorative gradients, floating section cards, or marketing-style hero content.

The UI should work on iPhone-sized portrait screens. The gift selector is the primary scrollable region so controls remain reachable.

## Implementation Scope

In scope:

- Update `Demo/VAPDemoApp/ViewController.swift`.
- Ensure `gift_effects_mp4.json` is included in the demo target bundle if needed.
- Keep UIKit and programmatic Auto Layout.
- Add local helper views or cell classes inside the demo app as needed.

Out of scope:

- Changes to `Sources/VAPPlayer`.
- Search, filtering, categories, thumbnails, or remote metadata.
- Persisting the selected gift between app launches.
- Adding new third-party dependencies.

## Verification

Build the demo project with Xcode command-line tools if the local environment permits:

```bash
xcodebuild -project Demo/VAPDemo.xcodeproj -scheme VAPDemo -destination 'generic/platform=iOS Simulator' build
```

Also verify the Swift package remains unaffected:

```bash
swift test
```

Manual verification in the simulator should cover:

- JSON list loads and displays many gifts.
- Tapping different gifts starts the corresponding remote MP4.
- Alpha Left and Alpha Right can replay the selected gift.
- Download progress appears while needed.
- Stop and Clear Cache still work.
