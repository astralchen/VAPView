import Testing
import Foundation
@testable import VAPView

private final class VAPPrefetchRecordingLoader: VAPResourceLoader, @unchecked Sendable {
    nonisolated(unsafe) private(set) var requestedFilePath: String?

    @concurrent func localPath(for filePath: String,
                               onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        requestedFilePath = filePath
        await onProgress(0.5)
        return "/tmp/prefetched.mp4"
    }

    func clearCache() throws {}
}

@Suite("VAPView prefetch")
struct VAPViewPrefetchTests {
    @Test @MainActor func prefetchUsesResourceLoaderWithoutViewInstance() async throws {
        let loader = VAPPrefetchRecordingLoader()
        var progressValues: [Double] = []

        let path = try await VAPView.prefetch(filePath: "https://example.com/prefetch.mp4",
                                              resourceLoader: loader) { progress in
            progressValues.append(progress)
        }

        #expect(path == "/tmp/prefetched.mp4")
        #expect(loader.requestedFilePath == "https://example.com/prefetch.mp4")
        #expect(progressValues == [0.5])
    }
}
