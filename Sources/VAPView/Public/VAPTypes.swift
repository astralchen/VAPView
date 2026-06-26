// VAPTypes.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import UIKit

// MARK: - Alpha placement in video frame
public enum VAPAlphaPlacement: Int, Sendable {
    case left = 0
    case right = 1
    case top = 2
    case bottom = 3
}

// MARK: - Background behaviour
public enum VAPBackgroundPlaybackPolicy: Sendable {
    /// Stop playback when app enters background
    case stop
    /// Pause on background, resume on foreground (requires key-frame seek on resume)
    case pauseAndResume
    /// Do nothing; caller manages pause/resume
    case ignore
}

// MARK: - Content mode
public enum VAPContentMode: Sendable {
    case scaleToFill
    case aspectFit
    case aspectFill
}

// MARK: - Attachment image options
public enum VAPAttachmentImageContentMode: Sendable {
    case scaleToFill
    case centerFill
}

public enum VAPAttachmentLoadLocation: Sendable {
    case local
    case remote
}

// MARK: - Error codes
public enum VAPError: Error, Sendable {
    case fileNotFound(String)
    /// URL scheme 不被允许（例如拒绝明文 http://）
    case unsupportedURLScheme(String)
    case invalidMP4File
    case streamInfoUnavailable
    case streamUnavailable
    case videoToolboxDescriptionCreationFailed
    case videoToolboxSessionCreationFailed
    case incompatibleVersion(Int)
    case missingVAPConfig
    case metalUnavailable
    case decodeFailed(Error)
    case unknown(String)
}

// MARK: - Playback defaults
public struct VAPPlaybackDefaults: Sendable {
    public static let defaultFramesPerSecond: Int = 25
    public static let minimumFramesPerSecond: Int = 1
    public static let maximumFramesPerSecond: Int = 60
    public static let maximumCompatibleConfigVersion: Int = 2

    private init() {}
}

// MARK: - External mask overlay
///
/// Mirrors ObjC `QGVAPMaskInfo`. Supply raw 0/1 byte-per-pixel mask data that gets
/// uploaded as an R8Unorm Metal texture and composited over every rendered frame.
/// Only effective on the VAP (attachment) renderer path.
public struct VAPMaskConfiguration: Sendable {
    /// Raw mask bytes — one byte per pixel, value 0 (transparent) or 1 (opaque).
    /// Row-major, top-to-bottom. Must contain at least `dataSize.width * dataSize.height` bytes.
    public let data: Data
    /// Pixel dimensions of `data`.
    public let dataSize: CGSize
    /// Sampling region within `data` (same pixel units). Use `.zero` to sample the whole texture.
    public let sampleRect: CGRect
    /// Edge-blur radius in pixels (0 = no blur, not yet implemented — reserved for future use).
    public let blurLength: Int

    public init(data: Data,
                dataSize: CGSize,
                sampleRect: CGRect = .zero,
                blurLength: Int = 0) {
        self.data = data
        self.dataSize = dataSize
        self.sampleRect = sampleRect
        self.blurLength = blurLength
    }
}

// MARK: - Attachment source value

/// Typed value for a single attachment slot in `VAPPlaybackConfiguration.attachmentSources`.
/// Replaces the untyped `[String: any Sendable]` dictionary values.
public enum VAPAttachmentSource: @unchecked Sendable {
    /// A pre-loaded image — composited directly without calling the imageLoader.
    case image(UIImage)
    /// A URL string (local path or network URL) — passed to the imageLoader for loading.
    case imageURL(String)
    /// A plain text string — rendered to a texture using the slot's font/color settings.
    case text(String)
}

// MARK: - Image loader context
/// Describes the attachment slot that triggered an image load request.
public struct VAPAttachmentImageContext: Sendable {
    /// The attachment identifier from the vapc config (`srcId`).
    public let sourceID: String
    /// How the loaded image should be fitted into its destination rect.
    public let contentMode: VAPAttachmentImageContentMode
    /// The destination size in canvas points (nil when not specified in config).
    public let targetSize: CGSize?
    /// Whether the URL should be loaded from the network or local storage.
    public let loadLocation: VAPAttachmentLoadLocation?

    public init(sourceID: String,
                contentMode: VAPAttachmentImageContentMode,
                targetSize: CGSize?,
                loadLocation: VAPAttachmentLoadLocation?) {
        self.sourceID = sourceID
        self.contentMode = contentMode
        self.targetSize = targetSize
        self.loadLocation = loadLocation
    }
}

// MARK: - Image loader injection (replaces delegate-based loading)
public typealias VAPAttachmentImageLoader =
    @Sendable (_ url: URL, _ context: VAPAttachmentImageContext) async throws -> UIImage
