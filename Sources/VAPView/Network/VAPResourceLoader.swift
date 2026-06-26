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
    /// 返回给定 source 对应的本地文件路径。
    ///
    /// - Parameters:
    ///   - source: 本地文件路径或远程 `https://` URL 字符串。
    ///   - progressHandler: 在主 actor 上回调下载进度，取值范围为 `0...1`。
    /// - Returns: 可直接用于播放的绝对本地文件路径。
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String
}

/// 为支持状态查询的资源缓存提供统一接口。
public protocol VAPResourceCacheStatusProviding: AnyObject, Sendable {
    /// 返回给定 source 当前的缓存/下载状态。
    @concurrent func cacheStatus(for source: String) async -> VAPCacheStatus
}

/// 为持有本地缓存文件的加载器提供缓存管理能力。
public protocol VAPResourceCacheCleaning: AnyObject {
    /// 移除缓存管理的所有文件。
    func removeAllCachedResources() throws
}
