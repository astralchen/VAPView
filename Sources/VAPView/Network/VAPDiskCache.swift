// VAPDiskCache.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation
import CryptoKit

private typealias VAPResourceProgressHandler = @MainActor @Sendable (Double) -> Void

/// Default `VAPResourceLoader` implementation.
///
/// - Cache directory: `<Caches>/com.vap/resources/`
/// - Cache key: SHA-256 hex of the URL string + original file extension
/// - Concurrent requests for the same URL share a single download.
public final class VAPDiskCache: VAPResourceLoader {

    public static let shared = VAPDiskCache()

    private let cacheDir: URL
    private let sessionManager: VAPDownloadSessionManager
    private let inflightActor = InflightActor()

    public convenience init() {
        self.init(configuration: .default)
    }

    init(configuration: URLSessionConfiguration) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDir = caches.appendingPathComponent("com.vap/resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.sessionManager = VAPDownloadSessionManager(configuration: configuration)
    }

    init(configuration: URLSessionConfiguration, cacheDirectory: URL) {
        self.cacheDir = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.sessionManager = VAPDownloadSessionManager(configuration: configuration)
    }

    // MARK: - VAPResourceLoader

    @concurrent public func localPath(for filePath: String,
                                      onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        guard filePath.hasPrefix("http://") || filePath.hasPrefix("https://") else {
            return filePath
        }
        // [H4] 拒绝明文 HTTP，防止中间人攻击替换 MP4 载荷
        guard filePath.hasPrefix("https://") else {
            throw VAPError.unsupportedURLScheme(filePath)
        }
        guard let url = URL(string: filePath) else {
            throw VAPError.fileNotFound(filePath)
        }
        let cacheKey = cacheFileName(for: filePath, ext: url.pathExtension)
        let dest = cacheDir.appendingPathComponent(cacheKey)
        if FileManager.default.fileExists(atPath: dest.path) {
            return dest.path
        }
        return try await download(url: url, dest: dest, onProgress: onProgress)
    }

    public func clearCache() throws {
        let items = try FileManager.default.contentsOfDirectory(atPath: cacheDir.path)
        for item in items {
            try FileManager.default.removeItem(at: cacheDir.appendingPathComponent(item))
        }
    }

    // MARK: - Private

    private func cacheFileName(for urlString: String, ext: String) -> String {
        let hash = SHA256.hash(data: Data(urlString.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        return ext.isEmpty ? hash : hash + "." + ext
    }

    @concurrent private func download(url: URL,
                                      dest: URL,
                                      onProgress: @escaping VAPResourceProgressHandler) async throws -> String {
        let mgr = sessionManager
        let (task, isOwner) = await inflightActor.getOrCreate(for: dest.path,
                                                              onProgress: onProgress) { progressRelay in
            Task { try await mgr.download(url: url, dest: dest, onProgress: progressRelay) }
        }
        do {
            let result = try await task.value
            await onProgress(1.0)
            if isOwner { await inflightActor.remove(for: dest.path) }
            return result
        } catch {
            if isOwner { await inflightActor.remove(for: dest.path) }
            throw error
        }
    }
}

// MARK: - Inflight coalescing actor

private actor InflightActor {
    private struct Entry {
        let task: Task<String, Error>
        var progressHandlers: [UUID: VAPResourceProgressHandler]
        var latestProgress: Double?
    }

    private var entries: [String: Entry] = [:]

    /// Returns an existing in-flight task for the specified key, or creates one.
    ///
    /// The owner of a newly created task is responsible for removing the entry when
    /// the task completes.
    func getOrCreate(for key: String,
                     onProgress: @escaping VAPResourceProgressHandler,
                     make: (@escaping VAPResourceProgressHandler) -> Task<String, Error>) -> (Task<String, Error>, Bool) {
        let subscriberID = UUID()
        if var existing = entries[key] {
            existing.progressHandlers[subscriberID] = onProgress
            if let latestProgress = existing.latestProgress {
                Task { await onProgress(latestProgress) }
            }
            entries[key] = existing
            return (existing.task, false)
        }
        let relay: VAPResourceProgressHandler = { progress in
            Task { await self.emitProgress(progress, for: key) }
        }
        let task = make(relay)
        entries[key] = Entry(task: task,
                             progressHandlers: [subscriberID: onProgress],
                             latestProgress: nil)
        return (task, true)
    }

    func remove(for key: String) { entries.removeValue(forKey: key) }

    private func emitProgress(_ progress: Double, for key: String) async {
        guard var entry = entries[key] else { return }
        entry.latestProgress = progress
        let handlers = Array(entry.progressHandlers.values)
        entries[key] = entry

        for handler in handlers {
            await handler(progress)
        }
    }
}

// MARK: - Session-level download manager (iOS 13+ compatible)

private final class VAPDownloadSessionManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private var session: URLSession!

    init(configuration: URLSessionConfiguration = .default) {
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private var handlers: [Int: DownloadHandler] = [:]
    private let lock = NSLock()

    struct DownloadHandler {
        let dest: URL
        let onProgress: VAPResourceProgressHandler
        let continuation: CheckedContinuation<String, Error>
    }

    @concurrent func download(url: URL,
                              dest: URL,
                              onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { cont in
            let task = session.downloadTask(with: url)
            lock.lock()
            handlers[task.taskIdentifier] = DownloadHandler(dest: dest,
                                                            onProgress: onProgress,
                                                            continuation: cont)
            lock.unlock()
            task.resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // [M1] 先移除 handler 再 resume，防止 didCompleteWithError 对同一 continuation 二次 resume
        lock.lock()
        let handler = handlers.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        guard let handler else { return }
        do {
            if FileManager.default.fileExists(atPath: handler.dest.path) {
                try FileManager.default.removeItem(at: handler.dest)
            }
            try FileManager.default.moveItem(at: location, to: handler.dest)
            let cb = handler.onProgress
            Task { await cb(1.0) }
            handler.continuation.resume(returning: handler.dest.path)
        } catch {
            handler.continuation.resume(throwing: error)
        }
    }

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        lock.lock()
        let handler = handlers[downloadTask.taskIdentifier]
        lock.unlock()
        guard let handler else { return }
        let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        let cb = handler.onProgress
        Task { await cb(progress) }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // [BUG-D4] 无论成功与否均摘除 handler，保持与 didFinishDownloadingTo 路径一致。
        // 成功完成时 didFinishDownloadingTo 已通过 resume(returning:) 结束 continuation，
        // 此处 handler 为 nil，removeValue 是空操作，无副作用。
        lock.lock()
        let handler = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let error {
            handler?.continuation.resume(throwing: error)
        }
    }
}
