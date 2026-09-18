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

    /// 使用系统默认网络配置和缓存目录的共享实例。
    public static let shared = VAPDiskCache()

    private let cacheDirectory: URL
    private let sessionManager: VAPDownloadSessionManager
    private let requests = VAPSharedRequests<String>()

    /// 使用系统默认网络配置和应用缓存目录创建资源缓存。
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

    /// 解析本地资源路径，或下载并缓存远程资源。
    ///
    /// 缓存命中时直接返回已有路径；本地路径原样返回，不在此验证文件是否存在。
    /// 同一实例内的相同远程资源共享下载，但各次调用独立响应取消。
    ///
    /// - Parameters:
    ///   - source: 本地文件路径或 HTTPS URL 字符串。默认实现拒绝明文 HTTP。
    ///   - progressHandler: 在主 Actor 执行的下载进度回调，取值范围为 `0...1`。
    /// - Returns: 本地资源路径。
    /// - Throws: 取消时抛出 `CancellationError`；否则传播 URL、网络或文件系统错误。
    @concurrent public func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String {
        try Task.checkCancellation()
        guard source.hasPrefix("http://") || source.hasPrefix("https://") else {
            return source
        }
        // 默认加载器仅接受加密传输，避免远程 MP4 在传输途中被替换。
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

    /// 移除缓存目录中的文件。
    ///
    /// 此方法不取消正在进行的下载；仍在运行的下载可以再次写入缓存。
    ///
    /// - Throws: 读取缓存目录或删除文件时的文件系统错误。
    public func removeAllCachedResources() throws {
        let items = try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path)
        for item in items {
            try FileManager.default.removeItem(at: cacheDirectory.appendingPathComponent(item))
        }
    }

    /// 查询指定远程资源的缓存或下载状态。
    ///
    /// - Parameter source: 远程资源 URL 字符串。
    /// - Returns: 已提交文件的缓存状态、进行中请求的进度，或 `.missing`。
    @concurrent public func cacheStatus(for source: String) async -> VAPCacheStatus {
        guard let destination = cacheDestination(for: source) else {
            return .missing
        }
        if FileManager.default.fileExists(atPath: destination.path) {
            return .cached(localPath: destination.path)
        }
        let inflight = requests.status(for: destination.path)
        if inflight.isDownloading {
            return .downloading(progress: inflight.progress)
        }
        return .missing
    }

    /// 返回指定远程资源已缓存的本地路径。
    ///
    /// - Parameter source: 远程资源 URL 字符串。
    /// - Returns: 已缓存文件的路径；资源未缓存或 URL 无法解析时为 `nil`。
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
        return try await requests.value(for: destination.path, progress: { value, isActive in
            // 切换到主 Actor 期间订阅可能已取消，实际通知前必须再次检查。
            await MainActor.run {
                guard isActive() else { return }
                progressHandler(value)
            }
        }) { lease, progress in
            try lease.checkCancellation()
            if FileManager.default.fileExists(atPath: destination.path) { return destination.path }
            return try await sessionManager.download(url: url, destination: destination, lease: lease, progress: progress)
        }
    }
}

/// 将 URLSession 下载代理事件转换为可取消的异步文件加载。
///
/// 请求状态由 `stateQueue` 串行保护。已启动的下载在代理终态到达并清理暂存文件后
/// 才结束异步等待；发出取消请求不会提前报告底层工作已退出。
private final class VAPDownloadSessionManager: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession!
    private let stateQueue = DispatchQueue(label: "com.vap.download.state")
    private var handlers: [Int: Request] = [:]

    private final class Request: @unchecked Sendable {
        let destination: URL
        let staging: URL
        let lease: VAPWorkLease
        let progress: @Sendable (Double) async -> Void
        var task: URLSessionDownloadTask?
        var continuation: CheckedContinuation<String, Error>?
        var cancelled = false
        var fileResult: Result<Void, Error>?
        init(destination: URL, lease: VAPWorkLease, progress: @escaping @Sendable (Double) async -> Void) {
            self.destination = destination
            self.staging = destination.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)")
            self.lease = lease
            self.progress = progress
        }
    }

    init(configuration: URLSessionConfiguration = .default) {
        super.init()
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func download(url: URL, destination: URL, lease: VAPWorkLease,
                  progress: @escaping @Sendable (Double) async -> Void) async throws -> String {
        try Task.checkCancellation()
        let request = Request(destination: destination, lease: lease, progress: progress)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                stateQueue.sync {
                    guard !request.cancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    let task = session.downloadTask(with: url)
                    request.task = task
                    request.continuation = continuation
                    handlers[task.taskIdentifier] = request
                    task.resume()
                }
            }
        } onCancel: {
            let task = self.stateQueue.sync {
                request.cancelled = true
                return request.task
            }
            // URLSession 取消可能触发后续代理事件，不在状态队列内调用。
            task?.cancel()
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        stateQueue.sync {
            guard let request = handlers[downloadTask.taskIdentifier], !request.cancelled else { return }
            request.fileResult = Result {
                try request.lease.checkCancellation()
                // URLSession 临时文件只在本回调内有效，先移入本实例独占的暂存位置。
                try FileManager.default.moveItem(at: location, to: request.staging)
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let request = stateQueue.sync { handlers[downloadTask.taskIdentifier] }
        guard let request else { return }
        let value = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        Task { await request.progress(value) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let completion: (CheckedContinuation<String, Error>, Result<String, Error>)? = stateQueue.sync {
            guard let request = handlers.removeValue(forKey: task.taskIdentifier),
                  let continuation = request.continuation else { return nil }
            request.continuation = nil
            request.task = nil
            // 只清理本实例的暂存文件；清理结束后才在状态队列外恢复等待者。
            defer { try? FileManager.default.removeItem(at: request.staging) }
            let result = Result<String, Error> {
                if request.cancelled { throw CancellationError() }
                if let error { throw error }
                try request.fileResult?.get()
                return try request.lease.commit {
                    // 已提交的完整文件不被旧传输覆盖；租约保证取消不能插入本次提交。
                    if !FileManager.default.fileExists(atPath: request.destination.path) {
                        try FileManager.default.moveItem(at: request.staging, to: request.destination)
                    }
                    return request.destination.path
                }
            }
            return (continuation, result)
        }
        if let (continuation, result) = completion { continuation.resume(with: result) }
    }
}
