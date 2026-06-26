// VAPDiskCacheTests.swift
import Testing
import Foundation
import CryptoKit
@testable import VAPView

// MARK: - Mock URLProtocol

nonisolated(unsafe) private var mockResponseData: Data = Data()
nonisolated(unsafe) private var mockShouldFail: Bool = false
nonisolated(unsafe) private var mockError: Error = NSError(domain: "MockError", code: -1)

final class VAPMockURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        if mockShouldFail {
            client?.urlProtocol(self, didFailWithError: mockError)
            return
        }
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "\(mockResponseData.count)"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: mockResponseData)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

private final class VAPDelayedURLProtocolState: @unchecked Sendable {
    private let finish = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var _requestCount = 0
    private var didStart = false
    private var startedContinuation: CheckedContinuation<Void, Never>?

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _requestCount
    }

    func recordRequest() {
        let continuation: CheckedContinuation<Void, Never>?
        lock.lock()
        _requestCount += 1
        didStart = true
        continuation = startedContinuation
        startedContinuation = nil
        lock.unlock()
        continuation?.resume()
    }

    func waitUntilStarted() async {
        await withCheckedContinuation { continuation in
            registerStartedWaiter(continuation)
        }
    }

    func waitUntilReleased() {
        finish.wait()
    }

    func releaseResponse() {
        finish.signal()
    }

    private func registerStartedWaiter(_ continuation: CheckedContinuation<Void, Never>) {
        lock.lock()
        if didStart {
            lock.unlock()
            continuation.resume()
        } else {
            startedContinuation = continuation
            lock.unlock()
        }
    }
}

nonisolated(unsafe) private var delayedState = VAPDelayedURLProtocolState()

final class VAPDelayedURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        delayedState.recordRequest()

        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: ["Content-Length": "4096"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(repeating: 0xAB, count: 2048))

        delayedState.waitUntilReleased()

        client?.urlProtocol(self, didLoad: Data(repeating: 0xCD, count: 2048))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

// MARK: - Helper

private func makeMockCache(tmpDir: URL) -> VAPDiskCache {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [VAPMockURLProtocol.self]
    return VAPDiskCache(configuration: config, cacheDirectory: tmpDir)
}

private func makeDelayedCache(tmpDir: URL) -> VAPDiskCache {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [VAPDelayedURLProtocol.self]
    return VAPDiskCache(configuration: config, cacheDirectory: tmpDir)
}

private func tmpCacheDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString, isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

@MainActor
private func waitUntil(
    _ condition: @MainActor () -> Bool,
    timeoutNanoseconds: UInt64 = 1_000_000_000
) async {
    for _ in 0..<50 {
        if condition() { return }
        try? await Task.sleep(nanoseconds: timeoutNanoseconds / 50)
    }
}

// MARK: - VAPDiskCacheTests

// MARK: - Real network integration test

@Suite("VAPDiskCache_Network", .serialized)
struct VAPDiskCacheNetworkTests {

    private static let realURL = "https://qiniu-xbyy.yinyou.live/channel/gift/QFB6BC-1774343076586.mp4"

    @Test @MainActor func realDownloadWritesFileToDisk() async throws {
        let dir = tmpCacheDir()
        let cache = VAPDiskCache(configuration: .default, cacheDirectory: dir)
        var progressValues: [Double] = []
        let localPath = try await cache.resolveLocalPath(for: Self.realURL) { p in
            progressValues.append(p)
        }
        #expect(FileManager.default.fileExists(atPath: localPath))
        #expect(localPath.hasSuffix(".mp4"))
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: localPath)[.size] as? Int) ?? 0
        #expect(fileSize > 0)
        #expect(progressValues.last == 1.0)
    }

    @Test func realCacheHitSkipsDownload() async throws {
        let dir = tmpCacheDir()
        let cache = VAPDiskCache(configuration: .default, cacheDirectory: dir)
        let first = try await cache.resolveLocalPath(for: Self.realURL, progressHandler: { _ in })
        // Second call — file already on disk, no network request needed
        let second = try await cache.resolveLocalPath(for: Self.realURL, progressHandler: { _ in })
        #expect(first == second)
    }
}

@Suite("VAPDiskCache", .serialized)
struct VAPDiskCacheTests {

    // MARK: Local path passthrough

    @Test func localSourceReturnedUnchanged() async throws {
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        let path = "/local/some/animation.mp4"
        let result = try await cache.resolveLocalPath(for: path, progressHandler: { _ in })
        #expect(result == path)
    }

    // MARK: Invalid URL

    @Test func invalidURLThrows() async throws {
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        // String that starts with http:// but is not a valid URL
        let bad = "http://[invalid url]"
        await #expect(throws: VAPError.self) {
            _ = try await cache.resolveLocalPath(for: bad, progressHandler: { _ in })
        }
    }

    // MARK: Download success

    @Test func downloadWritesFileToDisk() async throws {
        mockShouldFail = false
        mockResponseData = Data("fake mp4 bytes".utf8)
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        let url = "https://example.com/test.mp4"
        let localPath = try await cache.resolveLocalPath(for: url, progressHandler: { _ in })
        #expect(FileManager.default.fileExists(atPath: localPath))
        #expect(localPath.hasSuffix(".mp4"))
    }

    // MARK: Cache hit

    @Test func cacheHitReturnsSamePathWithoutRedownload() async throws {
        mockShouldFail = false
        mockResponseData = Data("cached content".utf8)
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        let url = "https://example.com/cached.mp4"
        let first  = try await cache.resolveLocalPath(for: url, progressHandler: { _ in })
        // Replace mock data — second call must NOT download again
        mockResponseData = Data("new data".utf8)
        let second = try await cache.resolveLocalPath(for: url, progressHandler: { _ in })
        #expect(first == second)
        let content = try Data(contentsOf: URL(fileURLWithPath: first))
        #expect(content == Data("cached content".utf8))
    }

    @Test @MainActor func concurrentRequestsShareDownloadAndProgressCallbacks() async throws {
        delayedState = VAPDelayedURLProtocolState()
        let dir = tmpCacheDir()
        let cache = makeDelayedCache(tmpDir: dir)
        let url = "https://example.com/shared.mp4"
        var firstProgress: [Double] = []
        var secondProgress: [Double] = []

        let first = Task {
            try await cache.resolveLocalPath(for: url) { progress in
                firstProgress.append(progress)
            }
        }

        await delayedState.waitUntilStarted()
        await waitUntil { firstProgress == [0.5] }
        #expect(firstProgress == [0.5])

        let second = Task {
            try await cache.resolveLocalPath(for: url) { progress in
                secondProgress.append(progress)
            }
        }

        await waitUntil { secondProgress == [0.5] }
        #expect(secondProgress == [0.5])
        delayedState.releaseResponse()

        let firstPath = try await first.value
        let secondPath = try await second.value
        await waitUntil { firstProgress.last == 1.0 && secondProgress.last == 1.0 }

        #expect(firstPath == secondPath)
        #expect(delayedState.requestCount == 1)
        #expect(firstProgress.last == 1.0)
        #expect(secondProgress.last == 1.0)
    }

    // MARK: Progress handler

    @Test @MainActor func progressCallbackFired() async throws {
        mockShouldFail = false
        mockResponseData = Data(repeating: 0xAB, count: 1024)
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        var lastProgress: Double = -1
        _ = try await cache.resolveLocalPath(for: "https://example.com/progress.mp4") { p in
            lastProgress = p
        }
        // Final progress must be 1.0 (set by didFinishDownloadingTo)
        #expect(lastProgress == 1.0)
    }

    // MARK: Download failure

    @Test func downloadFailurePropagatesError() async throws {
        mockShouldFail = true
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        var threw = false
        do {
            _ = try await cache.resolveLocalPath(for: "https://example.com/fail.mp4", progressHandler: { _ in })
        } catch {
            threw = true
        }
        #expect(threw)
    }

    // MARK: removeAllCachedResources

    @Test func removeAllCachedResourcesRemovesFiles() async throws {
        mockShouldFail = false
        mockResponseData = Data("data".utf8)
        let dir = tmpCacheDir()
        let cache = makeMockCache(tmpDir: dir)
        _ = try await cache.resolveLocalPath(for: "https://example.com/a.mp4", progressHandler: { _ in })
        let beforeClear = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(!beforeClear.isEmpty)
        try cache.removeAllCachedResources()
        let afterClear = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(afterClear.isEmpty)
    }
}
