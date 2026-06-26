// VAPMetalView.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import UIKit
import Metal
import CoreVideo

/// 暴露 CAMetalLayer 用于渲染的轻量 UIView。
/// 所有 Metal 命令都由外部的 VAPHWDRenderer / VAPRenderer 提交。
@MainActor
public final class VAPMetalView: UIView {

    // MARK: - 公开属性

    public var renderContentMode: VAPContentMode = .scaleToFill

    /// 底层 CAMetalLayer。
    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // MARK: - 初始化

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - UIView 重写

    public override class var layerClass: AnyClass { CAMetalLayer.self }

    public override func layoutSubviews() {
        super.layoutSubviews()
        metalLayer.frame = bounds
        let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : UIScreen.main.scale
        let w = bounds.width * scale
        let h = bounds.height * scale
        if w > 0 && h > 0 {
            metalLayer.drawableSize = CGSize(width: w, height: h)
        }
    }

    // MARK: - 私有方法

    private func setup() {
        backgroundColor = .clear
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
    }

    /// 根据内容模式和视频尺寸返回归一化顶点矩形。
    func vertexRect(videoSize: CGSize) -> CGRect {
        let viewSize = bounds.size
        guard viewSize.width > 0, viewSize.height > 0,
              videoSize.width > 0, videoSize.height > 0 else {
            return CGRect(x: -1, y: -1, width: 2, height: 2)
        }
        switch renderContentMode {
        case .scaleToFill:
            return CGRect(x: -1, y: -1, width: 2, height: 2)
        case .aspectFit:
            let vAR = videoSize.width / videoSize.height
            let sAR = viewSize.width / viewSize.height
            if vAR > sAR {
                let h = 2 * sAR / vAR
                return CGRect(x: -1, y: -h / 2, width: 2, height: h)
            } else {
                let w = 2 * vAR / sAR
                return CGRect(x: -w / 2, y: -1, width: w, height: 2)
            }
        case .aspectFill:
            let vAR = videoSize.width / videoSize.height
            let sAR = viewSize.width / viewSize.height
            if vAR < sAR {
                let h = 2 * sAR / vAR
                return CGRect(x: -1, y: -h / 2, width: 2, height: h)
            } else {
                let w = 2 * vAR / sAR
                return CGRect(x: -w / 2, y: -1, width: w, height: 2)
            }
        }
    }
}
