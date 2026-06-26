// VAPConfigModel.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation
import CoreGraphics

enum VAPConfigOrientation: Int, Sendable {
    case none = 0
    case portrait = 1
    case landscape = 2
}

enum VAPConfigAttachmentSourceType: String, Sendable {
    case text = "txt"
    case textString = "txtStr"
    case image = "img"
    case imageURL = "imgUrl"
}

enum VAPConfigAttachmentLoadType: String, Sendable {
    case local = "local"
    case network = "net"
}

enum VAPConfigAttachmentFitType: String, Sendable {
    case fitXY = "fitXY"
    case centerFull = "centerFull"
}

extension VAPConfigAttachmentLoadType {
    var publicLocation: VAPAttachmentLoadLocation {
        switch self {
        case .local:
            return .local
        case .network:
            return .remote
        }
    }
}

extension VAPConfigAttachmentFitType {
    var publicContentMode: VAPAttachmentImageContentMode {
        switch self {
        case .fitXY:
            return .scaleToFill
        case .centerFull:
            return .centerFill
        }
    }
}

// MARK: - 顶层 VAP 配置（从 vapc JSON 解码）

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
    public let v: Int?  // vapc 版本字段（JSON key "v"）
    /// 视频帧内的 RGB 内容区域：[x, y, w, h]，单位为像素。
    public let rgbFrame: [CGFloat]?
    /// 视频帧内的 Alpha 内容区域：[x, y, w, h]，单位为像素。
    /// 出于空间优化考虑，可能是 rgbFrame 的半分辨率。
    public let aFrame: [CGFloat]?

    var orientation: VAPConfigOrientation { VAPConfigOrientation(rawValue: orien) ?? .none }
    var version: Int { v ?? 0 }

    /// 返回视频内的 RGB 区域；rgbFrame 缺失或无效时返回 nil。
    var rgbRect: CGRect? {
        guard let f = rgbFrame, f.count == 4,
              f[2] > 0, f[3] > 0, f[0] >= 0, f[1] >= 0 else { return nil }
        return CGRect(x: f[0], y: f[1], width: f[2], height: f[3])
    }

    /// 返回视频内的 Alpha 区域；aFrame 缺失或无效时返回 nil。
    var alphaRect: CGRect? {
        guard let f = aFrame, f.count == 4,
              f[2] > 0, f[3] > 0, f[0] >= 0, f[1] >= 0 else { return nil }
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

    var attachmentSourceType: VAPConfigAttachmentSourceType? {
        srcType.flatMap(VAPConfigAttachmentSourceType.init(rawValue:))
    }
    var attachmentLoadType: VAPConfigAttachmentLoadType? {
        loadType.flatMap(VAPConfigAttachmentLoadType.init(rawValue:))
    }
    var attachmentFitType: VAPConfigAttachmentFitType {
        fitType.flatMap(VAPConfigAttachmentFitType.init(rawValue:)) ?? .centerFull
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
