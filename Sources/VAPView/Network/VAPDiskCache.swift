// VAPDiskCache.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation
import CryptoKit

private typealias VAPResourceProgressHandler = @MainActor @Sendable (Double) -> Void

/// 默认的 `VAPResourceLoader` 实现。
///
/// - 缓存目录：`<Caches>/com.vap/resources/`
/// - 缓存 key：URL 字符串的 SHA-256 十六进制值 + 原始文件扩展名
/// - 同一个 URL 的并发请求会共享同一次下载。
public final class VAPDiskCache: VAPResourceLoader, VAPResourceCacheCleaning, VAPResourceCacheStatusProviding {

    public static let shared = VAPDiskCache()

    private let cacheDirectory: URL
    private let sessionManager: VAPDownloadSessionManager
    private let inflightActor = InflightActor()

    public convenience init() {
        self.init(configuration: .default)
    }

    init(configuration: URLSessionConfiguration) {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        self.cacheDirectory = caches.appendingPathComponent("com.vap/resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.sessionManager = VAPDownloadSessionManager(configuration: configuration)
    }

    init(configuration: URLSessionConfiguration, cacheDirectory: URL) {
        self.cacheDirectory = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        self.sessionManager = VAPDownloadSessionManager(configuration: configuration)
    }

    // MARK: - VAPResourceLoader

    @concurrent public func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        guard source.hasPrefix("http://") || source.hasPrefix("https://") else {
            return source
        }
        // [H4] 拒绝明文 HTTP，防止中间人攻击替换 MP4 载荷
        guard source.hasPrefix("https://") else {
            throw VAPError.unsupportedURLScheme(source)
        }
        guard let url = URL(string: source) else {
            throw VAPError.fileNotFound(source)
        }
        let destination = cacheDestination(for: source, url: url)
        if FileManager.default.fileExists(atPath: destination.path) {
            return destination.path
        }
        return try await download(url: url, destination: destination, progressHandler: progressHandler)
    }

    public func removeAllCachedResources() throws {
        let items = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        for item in items {
            try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(item))
        }
    }

    @concurrent public func cacheStatus(for source: String) async -> VAPCacheStatus {
        guard let destination = cacheDestination(for: source) else {
            return .missing
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            return .cached(localPath: destination.path)
        }
        let inflight = await inflightActor.status(for: destination.path)
        if inflight.isDownloading {
            return .downloading(progress: inflight.progress)
        }
        return .missing
    }

    /// 返回指定远程 URL 已缓存的本地文件路径；未缓存或 URL 不合法时返回 nil。
    public func cachedLocalPath(for source: String) -> String? {
        guard let destination = cacheDestination(for: source) else {
            return nil
        }
        return FileManager.default.fileExists(atPath: destination.path) ? destination.path : nil
    }

    // MARK: - 私有方法

    private func cacheDestination(for source: String) -> URL? {
        guard source.hasPrefix("http://") || source.hasPrefix("https://"),
              let url = URL(string: source) else {
            return nil
        }
        return cacheDestination(for: source, url: url)
    }

    private func cacheDestination(for source: String, url: URL) -> URL {
        let cacheKey = cacheFileName(for: source, pathExtension: url.pathExtension)
        return cacheDirectory.appendingPathComponent(cacheKey)
    }

    private func cacheFileName(for urlString: String, pathExtension: String) -> String {
        let hash = SHA256.hash(data: Data(urlString.utf8))
            .compactMap { String(format: "%02x", $0) }.joined()
        return pathExtension.isEmpty ? hash : hash + "." + pathExtension
    }

    @concurrent private func download(url: URL,
                                      destination: URL,
                                      progressHandler: @escaping VAPResourceProgressHandler) async throws -> String {
        let sessionManager = self.sessionManager
        let (task, ownsEntry) = await inflightActor.getOrCreate(for: destination.path,
                                                                progressHandler: progressHandler) { progressRelay in
            Task { try await sessionManager.download(url: url, destination: destination, progressHandler: progressRelay) }
        }
        do {
            let result = try await task.value
            await progressHandler(1.0)
            if ownsEntry { await inflightActor.remove(for: destination.path) }
            return result
        } catch {
            if ownsEntry { await inflightActor.remove(for: destination.path) }
            throw error
        }
    }
}

// MARK: - 进行中请求合并 actor

private actor InflightActor {
    private struct Entry {
        let task: Task<String, Error>
        var progressHandlers: [UUID: VAPResourceProgressHandler]
        var latestProgress: Double?
    }

    private var entries: [String: Entry] = [:]

    /// 返回指定 key 对应的进行中任务；不存在时创建新任务。
    ///
    /// 新建任务的拥有者需要在任务完成后移除条目。
    func getOrCreate(for key: String,
                     progressHandler: @escaping VAPResourceProgressHandler,
                     make: (@escaping VAPResourceProgressHandler) -> Task<String, Error>) -> (Task<String, Error>, Bool) {
        let subscriberID = UUID()
        if var existing = entries[key] {
            existing.progressHandlers[subscriberID] = progressHandler
            if let latestProgress = existing.latestProgress {
                Task { await progressHandler(latestProgress) }
            }
            entries[key] = existing
            return (existing.task, false)
        }
        let relay: VAPResourceProgressHandler = { progress in
            Task { await self.emitProgress(progress, for: key) }
        }
        let task = make(relay)
        entries[key] = Entry(task: task,
                             progressHandlers: [subscriberID: progressHandler],
                             latestProgress: nil)
        return (task, true)
    }

    func remove(for key: String) { entries.removeValue(forKey: key) }

    func status(for key: String) -> (isDownloading: Bool, progress: Double?) {
        guard let entry = entries[key] else {
            return (false, nil)
        }
        return (true, entry.latestProgress)
    }

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

// MARK: - 会话级下载管理器（兼容 iOS 13+）

private final class VAPDownloadSessionManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {

    private var session: URLSession!

    init(configuration: URLSessionConfiguration = .default) {
        super.init()
        self.session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    private var handlers: [Int: DownloadRequest] = [:]
    private let lock = NSLock()

    struct DownloadRequest {
        let destination: URL
        let progressHandler: VAPResourceProgressHandler
        let continuation: CheckedContinuation<String, Error>
    }

    @concurrent func download(url: URL,
                              destination: URL,
                              progressHandler: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            let task = session.downloadTask(with: url)
            lock.lock()
            handlers[task.taskIdentifier] = DownloadRequest(destination: destination,
                                                            progressHandler: progressHandler,
                                                            continuation: continuation)
            lock.unlock()
            task.resume()
        }
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ session: URLSession,
                    downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        // [M1] 先移除处理器再 resume，防止 didCompleteWithError 对同一 continuation 二次 resume
        lock.lock()
        let handler = handlers.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()
        guard let handler else { return }
        do {
            if FileManager.default.fileExists(atPath: handler.destination.path) {
                try FileManager.default.removeItem(at: handler.destination)
            }
            try FileManager.default.moveItem(at: location, to: handler.destination)
            let progressHandler = handler.progressHandler
            Task { await progressHandler(1.0) }
            handler.continuation.resume(returning: handler.destination.path)
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
        let progressHandler = handler.progressHandler
        Task { await progressHandler(progress) }
    }

    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    didCompleteWithError error: Error?) {
        // [BUG-D4] 无论成功与否均摘除处理器，保持与 didFinishDownloadingTo 路径一致。
        // 成功完成时 didFinishDownloadingTo 已通过 resume(returning:) 结束 continuation，
        // 此处处理器为 nil，removeValue 是空操作，无副作用。
        lock.lock()
        let handler = handlers.removeValue(forKey: task.taskIdentifier)
        lock.unlock()
        if let error {
            handler?.continuation.resume(throwing: error)
        }
    }
}
