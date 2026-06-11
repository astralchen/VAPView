import Foundation
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
