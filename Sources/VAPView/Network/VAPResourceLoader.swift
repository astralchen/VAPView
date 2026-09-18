// VAPResourceLoader.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

/// 远程资源在默认缓存中的当前状态。
public enum VAPCacheStatus: Equatable, Sendable {
    /// 文件已存在于本地缓存。
    case cached(localPath: String)
    /// 文件正在下载；进度未知时为 nil。
    case downloading(progress: Double?)
    /// 没有可用缓存，也没有进行中的下载。
    case missing
}

/// 将本地路径或远程 URL 字符串解析为本地可读文件路径。
///
/// 默认实现为 `VAPDiskCache.shared`。
public protocol VAPResourceLoader: AnyObject, Sendable {
    /// 返回指定资源对应的本地文件路径。
    ///
    /// 自定义实现应在开始工作和阶段边界协作检查取消。共享加载只解除当前调用
    /// 的订阅；最后一个订阅取消后，应等待底层工作实际退出及清理，再结束异步调用。
    /// 取消生效后不得派发新的进度通知；已经进入执行的回调无需强行中断。
    /// 已确定的成功结果不应被迟到取消改写。
    ///
    /// - Parameters:
    ///   - source: 本地文件路径或远程 `https://` URL 字符串。
    ///   - progressHandler: 在主 actor 上回调下载进度，取值范围为 `0...1`。
    /// - Returns: 可直接用于播放的绝对本地文件路径。
    /// - Throws: 预取消或加载取消时抛出 `CancellationError`；其他加载错误保留原类型。
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String
}

/// 为支持状态查询的资源缓存提供统一接口。
public protocol VAPResourceCacheStatusProviding: AnyObject, Sendable {
    /// 查询指定资源当前的缓存或下载状态。
    ///
    /// - Parameter source: 要查询的资源来源。
    /// - Returns: 查询时的状态快照；此方法不触发下载。
    @concurrent func cacheStatus(for source: String) async -> VAPCacheStatus
}

/// 为持有本地缓存文件的加载器提供缓存管理能力。
public protocol VAPResourceCacheCleaning: AnyObject {
    /// 移除缓存管理的所有文件。
    func removeAllCachedResources() throws
}
