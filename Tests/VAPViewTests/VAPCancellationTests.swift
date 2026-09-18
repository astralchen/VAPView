import Foundation
import Testing
@testable import VAPView

private actor Gate {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
    var isOpen: Bool { opened }
}

@Suite(.serialized)
struct VAPSharedCancellationTests {
    @Test func oneSubscriberCancelsWithoutWaitingForSharedWorker() async throws {
        let requests = VAPSharedRequests<Int>()
        let started = Gate(), release = Gate(), joined = Gate()
        let first = Task {
            try await requests.value(for: "shared", progress: { _, _ in }) { _, progress in
                await progress(0.5)
                await started.open()
                await release.wait()
                return 42
            }
        }
        await started.wait()
        let second = Task {
            try await requests.value(for: "shared", progress: { _, active in
                if active() { await joined.open() }
            }) { _, _ in Issue.record("Duplicate worker"); return -1 }
        }
        await joined.wait()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(await release.isOpen == false)
        await release.open()
        #expect(try await second.value == 42)
    }

    @Test func lastCancellationRetainsGenerationUntilCleanupAndRetryUsesNewWorker() async throws {
        let requests = VAPSharedRequests<Int>()
        let started = Gate(), cancelled = Gate(), cleanup = Gate(), nextStarted = Gate()
        let first = Task {
            try await requests.value(for: "same", progress: { _, _ in }) { lease, progress in
                await started.open()
                await withTaskCancellationHandler {
                    await cleanup.wait()
                } onCancel: { Task { await cancelled.open() } }
                await progress(0.9) // Late old progress must not reach the new subscriber.
                try lease.checkCancellation()
                return 1
            }
        }
        await started.wait()
        first.cancel()
        await cancelled.wait()
        let second = Task {
            try await requests.value(for: "same", progress: { value, active in
                if active() { #expect(value == 1) }
            }) { _, _ in await nextStarted.open(); return 2 }
        }
        #expect(await nextStarted.isOpen == false)
        #expect(requests.status(for: "same").isDownloading)
        await cleanup.open()
        await #expect(throws: CancellationError.self) { try await first.value }
        #expect(try await second.value == 2)
        #expect(!requests.status(for: "same").isDownloading)
    }

    @Test func preCancellationDoesNotStartOperation() async {
        let requests = VAPSharedRequests<Int>()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await requests.value(for: "pre", progress: { _, _ in }) { _, _ in
                Issue.record("Precancelled operation executed")
                return 1
            }
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func selectedSuccessSurvivesCancellationDuringFinalProgress() async throws {
        let requests = VAPSharedRequests<Int>()
        let completing = Gate(), release = Gate()
        let task = Task {
            try await requests.value(for: "done", progress: { _, active in
                if active() { await completing.open(); await release.wait() }
            }) { _, _ in 7 }
        }
        await completing.wait()
        task.cancel()
        await release.open()
        #expect(try await task.value == 7)
    }
}

/// Network events control response delivery; no sleep determines cancellation success.
private final class ControlledProtocol: URLProtocol, @unchecked Sendable {
    final class Control: @unchecked Sendable {
        let started = Gate(), stopped = Gate()
        let queue = DispatchQueue(label: "cancellation.protocol")
        var instance: ControlledProtocol?
        var starts = 0
        var stops = 0
        let payload: Data
        init(payload: Data) { self.payload = payload }
        func finish() {
            queue.async {
                guard let instance = self.instance else { return }
                instance.client?.urlProtocol(instance, didLoad: self.payload.suffix(self.payload.count - self.payload.count / 2))
                instance.client?.urlProtocolDidFinishLoading(instance)
                self.instance = nil
            }
        }
        var counts: (Int, Int) { queue.sync { (starts, stops) } }
    }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var controls: [URL: Control] = [:]
    static func install(_ control: Control) -> URL {
        let url = URL(string: "https://cancel.test/\(UUID().uuidString).mp4")!
        lock.lock(); controls[url] = control; lock.unlock()
        return url
    }
    private var control: Control? {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return request.url.flatMap { Self.controls[$0] }
    }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cancel.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let control else { return }
        control.queue.sync {
            control.instance = self
            control.starts += 1
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Length": "\(control.payload.count)"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: control.payload.prefix(control.payload.count / 2))
            Task { await control.started.open() }
        }
    }
    override func stopLoading() {
        guard let control else { return }
        control.queue.sync {
            control.stops += 1
            control.instance = nil
            Task { await control.stopped.open() }
        }
    }
}

@Suite(.serialized)
struct VAPNetworkCancellationTests {
    private func cache() -> (VAPDiskCache, URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledProtocol.self]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        return (VAPDiskCache(configuration: configuration, cacheDirectory: dir), dir)
    }
    @Test func lastCancellationStopsTransportLeavesNoCacheAndCanRetry() async throws {
        let (cache, dir) = cache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = ControlledProtocol.Control(payload: Data(repeating: 4, count: 4096))
        let url = ControlledProtocol.install(control)
        let task = Task { try await VAPView.prefetch(source: url.absoluteString, using: cache) }
        await control.started.wait()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        await control.stopped.wait()
        #expect(control.counts.1 == 1)
        #expect(await cache.cacheStatus(for: url.absoluteString) == .missing)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
        let progress = Gate()
        let retry = Task {
            try await VAPView.prefetch(source: url.absoluteString, using: cache) { value in
                if value == 0.5 { Task { await progress.open() } }
            }
        }
        await progress.wait()
        control.finish()
        let path = try await retry.value
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == control.payload)
        #expect(control.counts.0 == 2)
        let precancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await VAPView.prefetch(source: url.absoluteString, using: cache)
        }
        await #expect(throws: CancellationError.self) { try await precancelled.value }
        #expect(control.counts.0 == 2)
    }

    @Test func cancellingOneNetworkSubscriberPreservesOtherAndSuppressesProgress() async throws {
        let (cache, dir) = cache()
        defer { try? FileManager.default.removeItem(at: dir) }
        let control = ControlledProtocol.Control(payload: Data(repeating: 4, count: 4096))
        let url = ControlledProtocol.install(control)
        let joined = Gate()
        let first = Task { try await VAPView.prefetch(source: url.absoluteString, using: cache) }
        await control.started.wait()
        let second = Task {
            try await VAPView.prefetch(source: url.absoluteString, using: cache) { value in
                if value == 0.5 { Task { await joined.open() } }
                #expect(value != 1, "Cancelled subscriber received terminal progress")
            }
        }
        await joined.wait()
        second.cancel()
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(control.counts.1 == 0)
        control.finish()
        _ = try await first.value
        #expect(control.counts.0 == 1)
    }
}

@Suite(.serialized) @MainActor
struct VAPViewSharedCancellationTests {
    @Test(arguments: [true, false])
    func playbackAndPrefetchOwnSeparateSubscriptions(cancelPlayback: Bool) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ControlledProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = VAPDiskCache(configuration: configuration, cacheDirectory: directory)
        let control = ControlledProtocol.Control(payload: Data(repeating: 4, count: 4096))
        let url = ControlledProtocol.install(control)
        let prefetch = Task { try await VAPView.prefetch(source: url.absoluteString, using: cache) }
        await control.started.wait()
        let view = VAPView()
        view.resourceLoader = cache
        let joined = Gate(), decoded = Gate()
        view.play(source: url.absoluteString, eventHandler: { event in
            if case .downloading(let value) = event {
                if value == 0.5 { Task { await joined.open() } }

            }
            // The fixture is deliberately not an MP4: decode failure proves loading finished.
            if case .didFail = event { Task { await decoded.open() } }
        })
        await joined.wait()
        if cancelPlayback { view.stop() }
        else {
            prefetch.cancel()
            await #expect(throws: CancellationError.self) { try await prefetch.value }
        }
        #expect(control.counts.1 == 0)
        control.finish()
        if cancelPlayback { _ = try await prefetch.value }
        else { await decoded.wait() }
        #expect(cache.cachedLocalPath(for: url.absoluteString) != nil)
        #expect(control.counts.0 == 1)
        view.stop()
    }
}
