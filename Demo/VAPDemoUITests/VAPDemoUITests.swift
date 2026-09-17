import XCTest

final class VAPDemoUITests: XCTestCase {
    @MainActor
    func testLaunchLoadsGiftListAndIdleControls() {
        let app = launchDemo()

        XCTAssertTrue(app.navigationBars["Gift Effects"].exists)
        XCTAssertTrue(app.collectionViews["giftList"].cells.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["selectedGiftName"].label.isEmpty)
        XCTAssertTrue(app.buttons["prefetchButton"].exists)
        XCTAssertFalse(app.buttons["pauseResumeButton"].isEnabled)
        XCTAssertFalse(app.buttons["stopButton"].isEnabled)
        XCTAssertTrue(app.buttons["clearCacheButton"].isEnabled)
    }

    @MainActor
    func testClearCacheKeepsGiftSelectionAndEnablesPrefetch() {
        let app = launchDemo()
        let selectedGift = app.staticTexts["selectedGiftName"].label

        app.buttons["clearCacheButton"].tap()

        let status = app.staticTexts["playbackStatus"]
        let cleared = NSPredicate(format: "label == %@", "Cache cleared")
        expectation(for: cleared, evaluatedWith: status)
        waitForExpectations(timeout: 5)
        XCTAssertEqual(app.staticTexts["selectedGiftName"].label, selectedGift)
        XCTAssertTrue(app.buttons["prefetchButton"].isEnabled)
        XCTAssertFalse(app.buttons["pauseResumeButton"].isEnabled)
        XCTAssertFalse(app.buttons["stopButton"].isEnabled)
    }

    @MainActor
    private func launchDemo() -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launch()
        let status = app.staticTexts["playbackStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 10))
        XCTAssertEqual(status.label, "Ready - 145 gifts")
        return app
    }
}
