// VAPTypes.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import UIKit

// MARK: - Alpha blend position in video frame
public enum VAPTextureBlendMode: Int, Sendable {
    case alphaLeft   = 0
    case alphaRight  = 1
    case alphaTop    = 2
    case alphaBottom = 3
}

// MARK: - Video orientation
public enum VAPOrientation: Int, Sendable {
    case none      = 0
    case portrait  = 1
    case landscape = 2
}

// MARK: - Background behaviour
public enum VAPBackgroundPolicy: Sendable {
    /// Stop playback when app enters background
    case stop
    /// Pause on background, resume on foreground (requires key-frame seek on resume)
    case pauseAndResume
    /// Do nothing — caller manages pause/resume
    case doNothing
}

// MARK: - Content mode
public enum VAPContentMode: Sendable {
    case scaleToFill
    case aspectFit
    case aspectFill
}

// MARK: - Attachment source types
public enum VAPAttachmentSourceType: String, Sendable {
    case text    = "txt"
    case textStr = "txtStr"
    case image   = "img"
    case imageURL = "imgUrl"
}

public enum VAPAttachmentLoadType: String, Sendable {
    case local = "local"
    case network = "net"
}

public enum VAPAttachmentFitType: String, Sendable {
    /// Scale to fit specified size
    case fitXY       = "fitXY"
    /// Default: use natural size; if smaller than mask, scale to fill
    case centerFull  = "centerFull"
}

// MARK: - Error codes
public enum VAPError: Error, Sendable {
    case fileNotFound(String)
    /// URL scheme 不被允许（例如拒绝明文 http://）
    case unsupportedURLScheme(String)
    case invalidMP4File
    case cannotGetStreamInfo
    case cannotGetStream
    case failedToCreateVTBDesc
    case failedToCreateVTBSession
    case incompatibleVersion(Int)
    case missingVAPConfig
    case metalUnavailable
    case decodeFailed(Error)
    case unknown(String)
}

// MARK: - Constants
public let kVAPDefaultFPS: Int = 25
public let kVAPMinFPS: Int = 1
public let kVAPMaxFPS: Int = 60
public let kVAPMaxCompatibleVersion: Int = 2

// MARK: - External mask overlay
///
/// Mirrors ObjC `QGVAPMaskInfo`. Supply raw 0/1 byte-per-pixel mask data that gets
/// uploaded as an R8Unorm Metal texture and composited over every rendered frame.
/// Only effective on the VAP (attachment) renderer path.
public struct VAPMaskInfo: Sendable {
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
        self.data        = data
        self.dataSize    = dataSize
        self.sampleRect  = sampleRect
        self.blurLength  = blurLength
    }
}

// MARK: - Attachment source value

/// Typed value for a single attachment slot in `VAPPlayConfig.attachmentSources`.
/// Replaces the untyped `[String: any Sendable]` dictionary values.
public enum VAPAttachmentSource: @unchecked Sendable {
    /// A pre-loaded image — composited directly without calling the imageLoader.
    case image(UIImage)
    /// A URL string (local path or network URL) — passed to the imageLoader for loading.
    case url(String)
    /// A plain text string — rendered to a texture using the slot's font/color settings.
    case text(String)
}

// MARK: - Image loader context
/// Describes the attachment slot that triggered an image load request.
public struct VAPImageContext: Sendable {
    /// The attachment identifier from the vapc config (`srcId`).
    public let srcId: String
    /// How the loaded image should be fitted into its destination rect.
    public let fitType: VAPAttachmentFitType
    /// The destination size in canvas points (nil when not specified in config).
    public let targetSize: CGSize?
    /// Whether the URL should be loaded from the network or local storage.
    public let loadType: VAPAttachmentLoadType?
}

// MARK: - Image loader injection (replaces delegate-based loading)
public typealias VAPImageLoader =
    @Sendable (_ url: URL, _ context: VAPImageContext) async throws -> UIImage
