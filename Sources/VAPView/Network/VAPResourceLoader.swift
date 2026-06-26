// VAPResourceLoader.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

/// Resolves a local path or remote URL string to a local readable file path.
///
/// The default implementation is `VAPDiskCache.shared`.
public protocol VAPResourceLoader: AnyObject, Sendable {
    /// Returns a local file path for the given source.
    ///
    /// - Parameters:
    ///   - source: A local file path or remote `https://` URL string.
    ///   - progressHandler: Called on the main actor with download progress in `0...1`.
    /// - Returns: An absolute local file path ready for playback.
    @concurrent func resolveLocalPath(
        for source: String,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws -> String
}

/// Provides cache-management operations for loaders that own local cached files.
public protocol VAPResourceCacheCleaning: AnyObject {
    /// Removes all files managed by the cache.
    func removeAllCachedResources() throws
}
