// VAPTypesTests.swift
import Testing
import Foundation
import UIKit
@testable import VAPView

@Suite("VAPTypes")
struct VAPTypesTests {

    // MARK: - VAPAlphaPlacement

    @Test func alphaPlacementRawValues() {
        #expect(VAPAlphaPlacement.left.rawValue == 0)
        #expect(VAPAlphaPlacement.right.rawValue == 1)
        #expect(VAPAlphaPlacement.top.rawValue == 2)
        #expect(VAPAlphaPlacement.bottom.rawValue == 3)
    }

    // MARK: - VAPError

    @Test func errorFileNotFound() {
        let e = VAPError.fileNotFound("/some/path.mp4")
        guard case .fileNotFound(let path) = e else { Issue.record("wrong case"); return }
        #expect(path == "/some/path.mp4")
    }

    @Test func errorIncompatibleVersion() {
        let e = VAPError.incompatibleVersion(3)
        guard case .incompatibleVersion(let v) = e else { Issue.record("wrong case"); return }
        #expect(v == 3)
    }

    @Test func errorDecodeFailed() {
        let underlying = NSError(domain: "test", code: 42)
        let e = VAPError.decodeFailed(underlying)
        guard case .decodeFailed(let inner) = e else { Issue.record("wrong case"); return }
        #expect((inner as NSError).code == 42)
    }

    // MARK: - VAPPlaybackDefaults

    @Test func playbackDefaults() {
        #expect(VAPPlaybackDefaults.defaultFramesPerSecond == 25)
        #expect(VAPPlaybackDefaults.minimumFramesPerSecond == 1)
        #expect(VAPPlaybackDefaults.maximumFramesPerSecond == 60)
        #expect(VAPPlaybackDefaults.maximumCompatibleConfigVersion == 2)
        #expect(VAPPlaybackDefaults.minimumFramesPerSecond < VAPPlaybackDefaults.defaultFramesPerSecond)
        #expect(VAPPlaybackDefaults.defaultFramesPerSecond < VAPPlaybackDefaults.maximumFramesPerSecond)
    }

    // MARK: - VAPEvent

    @Test func eventDidPlayFrame() {
        let event = VAPEvent.didPlayFrame(index: 5)
        guard case .didPlayFrame(let idx) = event else { Issue.record("wrong case"); return }
        #expect(idx == 5)
    }

    @Test func eventDidFinish() {
        let event = VAPEvent.didFinish(totalFrames: 100)
        guard case .didFinish(let total) = event else { Issue.record("wrong case"); return }
        #expect(total == 100)
    }

    @Test func eventDidStop() {
        let event = VAPEvent.didStop(lastFrame: 42)
        guard case .didStop(let last) = event else { Issue.record("wrong case"); return }
        #expect(last == 42)
    }

    @Test func eventDidFail() {
        let event = VAPEvent.didFail(.metalUnavailable)
        guard case .didFail(let err) = event else { Issue.record("wrong case"); return }
        guard case .metalUnavailable = err else { Issue.record("wrong error"); return }
    }

    @Test func eventDidLoopFinish() {
        let event = VAPEvent.didLoopFinish(loop: 2, totalFrames: 60)
        guard case .didLoopFinish(let loop, let total) = event else { Issue.record("wrong case"); return }
        #expect(loop == 2)
        #expect(total == 60)
    }

    @Test func eventDownloading() {
        let event = VAPEvent.downloading(progress: 0.75)
        guard case .downloading(let p) = event else { Issue.record("wrong case"); return }
        #expect(p == 0.75)
    }

    // MARK: - VAPAttachmentSource

    @Test func attachmentSourceImage() {
        let img = UIImage()
        let src = VAPAttachmentSource.image(img)
        guard case .image(let i) = src else { Issue.record("wrong case"); return }
        #expect(i === img)
    }

    @Test func attachmentSourceImageURL() {
        let source = VAPAttachmentSource.imageURL("https://example.com/img.png")
        guard case .imageURL(let value) = source else {
            Issue.record("wrong case")
            return
        }
        #expect(value == "https://example.com/img.png")
    }

    @Test func attachmentSourceText() {
        let src = VAPAttachmentSource.text("Hello")
        guard case .text(let t) = src else { Issue.record("wrong case"); return }
        #expect(t == "Hello")
    }

    // MARK: - VAPMaskConfiguration

    @Test func maskConfigurationDefaults() {
        let data = Data([0, 1, 0, 1])
        let mask = VAPMaskConfiguration(data: data, dataSize: CGSize(width: 2, height: 2))
        #expect(mask.data == data)
        #expect(mask.dataSize == CGSize(width: 2, height: 2))
        #expect(mask.sampleRect == .zero)
        #expect(mask.blurLength == 0)
    }

    // MARK: - VAPAttachmentImageContext

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
}
