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

private final class VAPControlledResourceLoader: VAPResourceLoader, @unchecked Sendable {
    private struct Request {
        let progressHandler: @MainActor @Sendable (Double) -> Void
        let continuation: CheckedContinuation<String, any Error>
    }

    private let lock = NSLock()
    private var requests: [String: Request] = [:]
    private var startWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            storeRequest(
                Request(progressHandler: progressHandler, continuation: continuation),
                for: source
            )
        }
    }

    func waitUntilStarted(_ source: String) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if requests[source] != nil {
                lock.unlock()
                continuation.resume()
            } else {
                startWaiters[source, default: []].append(continuation)
                lock.unlock()
            }
        }
    }

    @MainActor
    func emitProgress(_ progress: Double, for source: String) {
        request(for: source)?.progressHandler(progress)
    }

    func fail(_ error: any Error, for source: String) {
        takeRequest(for: source)?.continuation.resume(throwing: error)
    }

    func cancelAll() {
        let activeRequests: [Request]
        lock.lock()
        activeRequests = Array(requests.values)
        requests.removeAll()
        lock.unlock()

        for request in activeRequests {
            request.continuation.resume(throwing: CancellationError())
        }
    }

    private func storeRequest(_ request: Request, for source: String) {
        let waiters: [CheckedContinuation<Void, Never>]
        lock.lock()
        requests[source] = request
        waiters = startWaiters.removeValue(forKey: source) ?? []
        lock.unlock()

        for waiter in waiters {
            waiter.resume()
        }
    }

    private func request(for source: String) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        return requests[source]
    }

    private func takeRequest(for source: String) -> Request? {
        lock.lock()
        defer { lock.unlock() }
        return requests.removeValue(forKey: source)
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

    @Test @MainActor func stopSuppressesPendingRemoteProgressAndFailure() async {
        let view = VAPView()
        let loader = VAPControlledResourceLoader()
        let source = "https://example.com/stale-stop.mp4"
        var receivedEvents: [VAPEvent] = []

        view.resourceLoader = loader
        view.play(source: source, eventHandler: { event in
            receivedEvents.append(event)
        })

        await loader.waitUntilStarted(source)
        view.stop()

        loader.emitProgress(0.5, for: source)
        loader.fail(VAPError.fileNotFound(source), for: source)

        await Task.yield()

        #expect(receivedEvents.isEmpty)
    }

    @Test @MainActor func replacingRemotePlaybackSuppressesPreviousProgressAndFailure() async {
        let view = VAPView()
        let loader = VAPControlledResourceLoader()
        let firstSource = "https://example.com/stale-first.mp4"
        let secondSource = "https://example.com/stale-second.mp4"
        var firstPlaybackEvents: [VAPEvent] = []
        var secondPlaybackEvents: [VAPEvent] = []

        view.resourceLoader = loader
        view.play(source: firstSource, eventHandler: { event in
            firstPlaybackEvents.append(event)
        })
        await loader.waitUntilStarted(firstSource)

        view.play(source: secondSource, eventHandler: { event in
            secondPlaybackEvents.append(event)
        })
        await loader.waitUntilStarted(secondSource)

        loader.emitProgress(0.5, for: firstSource)
        loader.fail(VAPError.fileNotFound(firstSource), for: firstSource)

        await Task.yield()

        #expect(firstPlaybackEvents.isEmpty)
        #expect(secondPlaybackEvents.isEmpty)

        view.stop()
        loader.cancelAll()
    }
}
