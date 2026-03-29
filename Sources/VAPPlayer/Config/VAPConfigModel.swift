// VAPConfigModel.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation
import CoreGraphics

// MARK: - Top-level VAP config (decoded from vapc JSON)

public struct VAPConfig: Decodable, Sendable {
    public let info: VAPCommonInfo
    public let src: [VAPSourceInfo]?
    public let frame: [VAPFrameInfo]?
}

public struct VAPCommonInfo: Decodable, Sendable {
    public let w: Int
    public let h: Int
    public let fps: Int
    public let videoW: Int
    public let videoH: Int
    public let orien: Int
    public let v: Int?  // vapc version field (JSON key "v")
    /// RGB content region within the video frame: [x, y, w, h] in pixels.
    public let rgbFrame: [CGFloat]?
    /// Alpha content region within the video frame: [x, y, w, h] in pixels.
    /// May be half-resolution compared to rgbFrame (space optimization).
    public let aFrame: [CGFloat]?

    var orientation: VAPOrientation { VAPOrientation(rawValue: orien) ?? .none }
    var version: Int { v ?? 0 }

    /// Returns the RGB rect within the video, or nil if rgbFrame is absent/invalid.
    var rgbRect: CGRect? {
        guard let f = rgbFrame, f.count == 4 else { return nil }
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }

    /// Returns the alpha rect within the video, or nil if aFrame is absent/invalid.
    var alphaRect: CGRect? {
        guard let f = aFrame, f.count == 4 else { return nil }
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }
}

public struct VAPSourceInfo: Decodable, Sendable {
    public let srcId: String
    public let srcType: String?
    public let loadType: String?
    public let tag: String?
    public let w: CGFloat?
    public let h: CGFloat?
    public let fitType: String?
    public let txtColor: String?
    public let txtFontSize: CGFloat?

    var attachmentSourceType: VAPAttachmentSourceType? {
        srcType.flatMap(VAPAttachmentSourceType.init(rawValue:))
    }
    var attachmentLoadType: VAPAttachmentLoadType? {
        loadType.flatMap(VAPAttachmentLoadType.init(rawValue:))
    }
    var attachmentFitType: VAPAttachmentFitType {
        fitType.flatMap(VAPAttachmentFitType.init(rawValue:)) ?? .centerFull
    }
}

public struct VAPFrameInfo: Decodable, Sendable {
    public let i: Int
    public let obj: [VAPSourceDisplayItem]?
}

public struct VAPSourceDisplayItem: Decodable, Sendable {
    public let srcId: String
    public let z: Int?
    public let x: CGFloat
    public let y: CGFloat
    public let w: CGFloat
    public let h: CGFloat
    public let mt: String?
    public let mFrame: MaskFrame?

    var frame: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}

public struct MaskFrame: Decodable, Sendable {
    public let x: CGFloat
    public let y: CGFloat
    public let w: CGFloat
    public let h: CGFloat
    var rect: CGRect { CGRect(x: x, y: y, width: w, height: h) }
}
