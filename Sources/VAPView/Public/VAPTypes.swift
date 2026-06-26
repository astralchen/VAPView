// VAPTypes.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import UIKit

// MARK: - 视频帧内的 Alpha 位置
public enum VAPAlphaPlacement: Int, Sendable {
    case left = 0
    case right = 1
    case top = 2
    case bottom = 3
}

// MARK: - 后台播放策略
public enum VAPBackgroundPlaybackPolicy: Sendable {
    /// 进入后台时停止播放。
    case stop
    /// 进入后台时暂停，回到前台后恢复播放（恢复时需要关键帧 seek）。
    case pauseAndResume
    /// 不自动处理；由调用方管理暂停和恢复。
    case ignore
}

// MARK: - 内容显示模式
public enum VAPContentMode: Sendable {
    case scaleToFill
    case aspectFit
    case aspectFill
}

// MARK: - 挂件图片选项
public enum VAPAttachmentImageContentMode: Sendable {
    case scaleToFill
    case centerFill
}

public enum VAPAttachmentLoadLocation: Sendable {
    case local
    case remote
}

// MARK: - 错误码
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

// MARK: - 播放默认值
public struct VAPPlaybackDefaults: Sendable {
    public static let defaultFramesPerSecond: Int = 25
    public static let minimumFramesPerSecond: Int = 1
    public static let maximumFramesPerSecond: Int = 60
    public static let maximumCompatibleConfigVersion: Int = 2

    private init() {}
}

// MARK: - 外部蒙版叠加
///
/// 提供每像素 0/1 字节的原始蒙版数据。
/// 数据会上传为 R8Unorm Metal 纹理，并叠加到每一帧渲染结果上。
/// 仅在 VAP（挂件）渲染路径生效。
public struct VAPMaskConfiguration: Sendable {
    /// 原始蒙版字节；每像素一个字节，取值 0（透明）或 1（不透明）。
    /// 按行优先、从上到下排列，至少需要包含 `dataSize.width * dataSize.height` 个字节。
    public let data: Data
    /// `data` 对应的像素尺寸。
    public let dataSize: CGSize
    /// `data` 内的采样区域（同样使用像素单位）。传 `.zero` 表示采样整张纹理。
    public let sampleRect: CGRect
    /// 边缘模糊半径，单位为像素（0 表示不模糊；当前暂未实现，预留给后续能力）。
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

// MARK: - 挂件资源值

/// `VAPPlaybackConfiguration.attachmentSources` 中单个挂件槽位的强类型值。
/// 用于替代无类型的 `[String: any Sendable]` 字典值。
public enum VAPAttachmentSource: @unchecked Sendable {
    /// 已加载的图片；直接参与合成，不会调用 imageLoader。
    case image(UIImage)
    /// URL 字符串（本地路径或网络 URL）；会传给 imageLoader 加载。
    case imageURL(String)
    /// 纯文本；使用槽位中的字体和颜色配置渲染成纹理。
    case text(String)
}

// MARK: - 图片加载上下文
/// 描述触发图片加载请求的挂件槽位。
public struct VAPAttachmentImageContext: Sendable {
    /// vapc 配置中的挂件标识（`srcId`）。
    public let sourceID: String
    /// 加载后的图片在目标区域内的填充方式。
    public let contentMode: VAPAttachmentImageContentMode
    /// 画布坐标系中的目标尺寸；配置未指定时为 nil。
    public let targetSize: CGSize?
    /// URL 应从网络还是本地存储加载。
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

// MARK: - 图片加载注入（替代代理式加载）
public typealias VAPAttachmentImageLoader =
    @Sendable (_ url: URL, _ context: VAPAttachmentImageContext) async throws -> UIImage
