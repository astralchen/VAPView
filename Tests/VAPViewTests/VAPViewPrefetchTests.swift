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

private final class VAPCacheStatusRecordingProvider: VAPResourceCacheStatusProviding, @unchecked Sendable {
    nonisolated(unsafe) private(set) var requestedSource: String?

    @concurrent func cacheStatus(for source: String) async -> VAPCacheStatus {
        requestedSource = source
        return .downloading(progress: 0.25)
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

    @Test func cacheStatusUsesStatusProviderWithoutViewInstance() async {
        let provider = VAPCacheStatusRecordingProvider()

        let status = await VAPView.cacheStatus(
            source: "https://example.com/status.mp4",
            using: provider
        )

        #expect(status == .downloading(progress: 0.25))
        #expect(provider.requestedSource == "https://example.com/status.mp4")
    }
}
