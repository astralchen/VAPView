// VAPDiskCache.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation
import CryptoKit

/// Default `VAPResourceLoader` implementation.
///
/// - Cache directory: `<Caches>/com.tencent.vap/resources/`
/// - Cache key: SHA-256 hex of the URL string + original file extension
/// - Concurrent requests for the same URL are coalesced into a single download
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
        self.cacheDir = caches.appendingPathComponent("com.tencent.vap/resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.sessionManager = VAPDownloadSessionManager(configuration: configuration)
    }

    init(configuration: URLSessionConfiguration, cacheDirectory: URL) {
        self.cacheDir = cacheDirectory
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.sessionManager = VAPDownloadSessionManager(configuration: configuration)
    }

    // MARK: - VAPResourceLoader

    public func localPath(for filePath: String,
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

    private func download(url: URL,
                          dest: URL,
                          onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String {
        let mgr = sessionManager
        // [BUG-D2/D3] 原子 getOrCreate：检查与注册在同一 actor 调用内完成，消除 TOCTOU 竞争；
        // isOwner 标记由创建方负责清理，避免 defer+非结构化 Task 导致的误删新任务。
        let (task, isOwner) = await inflightActor.getOrCreate(for: dest.path) {
            Task { try await mgr.download(url: url, dest: dest, onProgress: onProgress) }
        }
        do {
            let result = try await task.value
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
    private var tasks: [String: Task<String, Error>] = [:]

    /// 原子 getOrCreate：若已有 inflight 任务则返回 (existing, isOwner=false)；
    /// 否则调用 make() 创建新任务，注册后返回 (new, isOwner=true)。
    /// isOwner == true 的调用方负责在任务结束后调用 remove(for:)。
    func getOrCreate(for key: String,
                     make: () -> Task<String, Error>) -> (Task<String, Error>, Bool) {
        if let existing = tasks[key] {
            return (existing, false)
        }
        let task = make()
        tasks[key] = task
        return (task, true)
    }

    func remove(for key: String) { tasks.removeValue(forKey: key) }
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
        let onProgress: @MainActor @Sendable (Double) -> Void
        let continuation: CheckedContinuation<String, Error>
    }

    func download(url: URL,
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
