import Testing
import Foundation
import UIKit
@testable import VAPView

private final class VAPSuspendingResourceLoader: VAPResourceLoader, @unchecked Sendable {
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        try await Task.sleep(nanoseconds: 60_000_000_000)
        return source
    }
}

@Suite("VAPView API")
struct VAPViewAPITests {
    @Test @MainActor func gestureAPIUsesHandlerTerminologyAtCompileTime() {
        let view = VAPView()
        let gesture = UITapGestureRecognizer()
        var called = false

        view.addTapGesture { _ in called = true }
        view.addGesture(gesture) { _ in called = true }
        view.removeGesture(gesture)

        #expect(called == false)
    }

    @Test @MainActor func addGestureAttachesToCreatedPlayerSurface() {
        let view = VAPView()
        let gesture = UITapGestureRecognizer()
        view.resourceLoader = VAPSuspendingResourceLoader()

        view.addGesture(gesture) { _ in }
        view.play(source: "https://example.com/missing.mp4", eventHandler: { _ in })

        let metalView = view.subviews.first as? VAPMetalView
        #expect(metalView?.gestureRecognizers?.contains { $0 === gesture } == true)

        view.removeGesture(gesture)
        #expect(metalView?.gestureRecognizers?.contains { $0 === gesture } != true)

        view.stop()
    }

    @Test @MainActor func removeGestureIsStableWhenCalledRepeatedly() {
        let view = VAPView()
        let gesture = UITapGestureRecognizer()
        view.resourceLoader = VAPSuspendingResourceLoader()

        view.addGesture(gesture) { _ in }
        view.removeGesture(gesture)
        view.removeGesture(gesture)

        view.play(source: "https://example.com/missing.mp4", eventHandler: { _ in })

        let metalView = view.subviews.first as? VAPMetalView
        #expect(metalView?.gestureRecognizers?.contains { $0 === gesture } != true)

        view.stop()
    }

    @Test @MainActor func conveniencePlayPassesTransformedConfigurationToStartGate() {
        let view = VAPView()
        let mask = VAPMaskConfiguration(
            data: Data([1, 0, 1, 0]),
            dataSize: CGSize(width: 2, height: 2),
            sampleRect: CGRect(x: 0, y: 0, width: 1, height: 1),
            blurLength: 3
        )
        var gateCallCount = 0
        var capturedConfiguration: VAPPlaybackConfiguration?

        view.preferredFramesPerSecond = 48
        view.shouldStartPlayback = { configuration in
            gateCallCount += 1
            capturedConfiguration = configuration
            return false
        }

        view.play(
            source: "/tmp/missing.mp4",
            frameBufferCapacity: 5,
            mask: mask,
            playsAudio: false,
            loopCount: 2
        ) { _ in }
        view.stop()

        #expect(gateCallCount == 1)
        #expect(capturedConfiguration?.source == "/tmp/missing.mp4")
        #expect(capturedConfiguration?.loopCount == 2)
        #expect(capturedConfiguration?.preferredFramesPerSecond == 48)
        #expect(capturedConfiguration?.frameBufferCapacity == 5)
        #expect(capturedConfiguration?.playsAudio == false)
        #expect(capturedConfiguration?.mask?.data == mask.data)
        #expect(capturedConfiguration?.mask?.dataSize == mask.dataSize)
        #expect(capturedConfiguration?.mask?.sampleRect == mask.sampleRect)
        #expect(capturedConfiguration?.mask?.blurLength == mask.blurLength)
    }
}
