// VAPResourceLoader.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

/// Resolves a file path or remote URL string to a local readable file path.
///
/// - For local paths the implementation should return the path unchanged.
/// - For remote `http(s)://` URLs the implementation should download the file
///   to a local cache and return the cached path.
///
/// The default implementation is `VAPDiskCache.shared`.
public protocol VAPResourceLoader: AnyObject, Sendable {
    /// Returns a local file path for the given `filePath`.
    ///
    /// - Parameters:
    ///   - filePath: A local file path or a remote `http(s)://` URL string.
    ///   - onProgress: Called on the main actor with download progress in `[0, 1]`.
    ///                 Only invoked for remote URLs that are not yet cached.
    /// - Returns: An absolute local file path ready for playback.
    @concurrent func localPath(for filePath: String,
                               onProgress: @escaping @MainActor @Sendable (Double) -> Void) async throws -> String

    /// Removes all files from the local cache managed by this loader.
    func clearCache() throws
}
