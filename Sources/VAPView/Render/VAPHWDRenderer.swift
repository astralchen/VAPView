// VAPHWDRenderer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// 使用 HWD Metal 管线渲染 alpha 分割的 YUV 视频帧。

import Metal
import MetalKit
import CoreVideo
import simd

@MainActor
final class VAPHWDRenderer {

    // MARK: - Metal 对象
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var colorParams: VAPColorParameters = .bt601Full
    private var textureCache: CVMetalTextureCache?

    // MARK: - 初始化

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw VAPError.metalUnavailable
        }
        self.commandQueue = queue
        self.pipelineState = try Self.makePipeline(device: device)
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
    }

    // MARK: - 渲染

    /// 将一帧已解码画面渲染到 `metalView`。
    /// `alphaPlacement` 决定帧的哪一半包含 Alpha 通道。
    func render(pixelBuffer: CVPixelBuffer,
                into metalView: VAPMetalView,
                alphaPlacement: VAPAlphaPlacement) {
        if metalView.metalLayer.device == nil {
            metalView.metalLayer.device = device
            rendererLog.debug("HWD: set metalLayer.device")
        }
        let layerSize = metalView.metalLayer.drawableSize
        rendererLog.debug("HWD: drawableSize=\(layerSize.width)x\(layerSize.height) bounds=\(metalView.bounds.width)x\(metalView.bounds.height)")
        guard let drawable = metalView.metalLayer.nextDrawable() else {
            rendererLog.debug("HWD: nextDrawable() returned nil")
            return
        }

        colorParams = vapColorParameters(from: pixelBuffer)
        let textures = vapMakeYUVTextures(from: pixelBuffer, device: device, textureCache: textureCache)
        guard textures.count == 2 else {
            rendererLog.debug("HWD: failed to create YUV textures, frame skipped")
            return
        }

        let videoWidth  = CVPixelBufferGetWidth(pixelBuffer)
        let videoHeight = CVPixelBufferGetHeight(pixelBuffer)
        let vertices = makeVertices(alphaPlacement: alphaPlacement,
                                   videoSize: CGSize(width: videoWidth, height: videoHeight),
                                   viewRect: metalView.vertexRect(
                                       videoSize: rgbContentSize(alphaPlacement: alphaPlacement,
                                                                 videoWidth: videoWidth,
                                                                 videoHeight: videoHeight)))

        guard let buffer = device.makeBuffer(bytes: vertices,
                                             length: vertices.count * MemoryLayout<VAPHWDVertex>.stride,
                                             options: .storageModeShared) else { return }

        var params = colorParams
        guard let paramsBuffer = device.makeBuffer(bytes: &params,
                                                   length: MemoryLayout<VAPColorParameters>.stride,
                                                   options: .storageModeShared) else { return }

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture    = drawable.texture
        desc.colorAttachments[0].loadAction  = .clear
        desc.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        desc.colorAttachments[0].storeAction = .store

        guard let cmdBuffer  = commandQueue.makeCommandBuffer(),
              let encoder    = cmdBuffer.makeRenderCommandEncoder(descriptor: desc) else { return }

        encoder.setRenderPipelineState(pipelineState)
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setFragmentTexture(textures[0], index: 0)  // Y plane (R8Unorm)
        encoder.setFragmentTexture(textures[1], index: 1)  // UV plane (RG8Unorm)
        encoder.setFragmentBuffer(paramsBuffer, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - 管线

    private static func makePipeline(device: MTLDevice) throws -> MTLRenderPipelineState {
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            throw VAPError.metalUnavailable
        }
        let desc = MTLRenderPipelineDescriptor()
        desc.label                           = "VAPHWDPipeline"
        desc.vertexFunction                  = library.makeFunction(name: "hwd_vertexShader")
        desc.fragmentFunction                = library.makeFunction(name: "hwd_yuvFragmentShader")
        desc.colorAttachments[0].pixelFormat = .bgra8Unorm
        desc.colorAttachments[0].isBlendingEnabled             = true
        desc.colorAttachments[0].rgbBlendOperation             = .add
        desc.colorAttachments[0].alphaBlendOperation           = .add
        desc.colorAttachments[0].sourceRGBBlendFactor          = .one
        desc.colorAttachments[0].sourceAlphaBlendFactor        = .one
        desc.colorAttachments[0].destinationRGBBlendFactor     = .oneMinusSourceAlpha
        desc.colorAttachments[0].destinationAlphaBlendFactor   = .oneMinusSourceAlpha
        return try device.makeRenderPipelineState(descriptor: desc)
    }

    // MARK: - 顶点辅助方法

    private func makeVertices(alphaPlacement: VAPAlphaPlacement,
                              videoSize: CGSize,
                              viewRect: CGRect) -> [VAPHWDVertex] {
        let l = Float(viewRect.minX), r = Float(viewRect.maxX)
        let b = Float(viewRect.minY), t = Float(viewRect.maxY)
        // 归一化纹理坐标取决于 alphaPlacement。
        let (rgbTL, rgbBR, alphaTL, alphaBR) = Self.texCoords(alphaPlacement: alphaPlacement)
        // 4 个顶点：TL、TR、BL、BR（三角带）。
        return [
            VAPHWDVertex(position: SIMD4(l, t, 0, 1),
                         rgbTexCoord:   SIMD2(rgbTL.x,   rgbTL.y),
                         alphaTexCoord: SIMD2(alphaTL.x, alphaTL.y)),
            VAPHWDVertex(position: SIMD4(r, t, 0, 1),
                         rgbTexCoord:   SIMD2(rgbBR.x,   rgbTL.y),
                         alphaTexCoord: SIMD2(alphaBR.x, alphaTL.y)),
            VAPHWDVertex(position: SIMD4(l, b, 0, 1),
                         rgbTexCoord:   SIMD2(rgbTL.x,   rgbBR.y),
                         alphaTexCoord: SIMD2(alphaTL.x, alphaBR.y)),
            VAPHWDVertex(position: SIMD4(r, b, 0, 1),
                         rgbTexCoord:   SIMD2(rgbBR.x,   rgbBR.y),
                         alphaTexCoord: SIMD2(alphaBR.x, alphaBR.y))
        ]
    }

    /// 返回归一化 UV 空间 [0,1] 中的
    /// (rgbTopLeft, rgbBottomRight, alphaTopLeft, alphaBottomRight)。
    static func texCoords(alphaPlacement: VAPAlphaPlacement)
        -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        switch alphaPlacement {
        case .right:
            return (SIMD2(0, 0), SIMD2(0.5, 1),
                    SIMD2(0.5, 0), SIMD2(1, 1))
        case .left:
            return (SIMD2(0.5, 0), SIMD2(1, 1),
                    SIMD2(0, 0),   SIMD2(0.5, 1))
        case .bottom:
            return (SIMD2(0, 0), SIMD2(1, 0.5),
                    SIMD2(0, 0.5), SIMD2(1, 1))
        case .top:
            return (SIMD2(0, 0.5), SIMD2(1, 1),
                    SIMD2(0, 0),   SIMD2(1, 0.5))
        }
    }
}
