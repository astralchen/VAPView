// VAPMetalView.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import UIKit
import Metal
import CoreVideo

/// Lightweight UIView that exposes a CAMetalLayer for rendering.
/// All Metal commands are submitted externally by VAPHWDRenderer / VAPRenderer.
@MainActor
public final class VAPMetalView: UIView {

    // MARK: - Public

    public var renderContentMode: VAPContentMode = .scaleToFill

    /// The underlying CAMetalLayer.
    public var metalLayer: CAMetalLayer { layer as! CAMetalLayer }

    // MARK: - Init

    public override init(frame: CGRect) {
        super.init(frame: frame)
        setup()
    }

    public required init?(coder: NSCoder) {
        super.init(coder: coder)
        setup()
    }

    // MARK: - UIView overrides

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

    // MARK: - Private

    private func setup() {
        backgroundColor = .clear
        metalLayer.isOpaque = false
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = true
        metalLayer.device = MTLCreateSystemDefaultDevice()
    }

    /// Returns normalized vertex rect for the given content mode and video size.
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
