// VAPRenderer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// VAP-x 渲染器：使用蒙版合成 YUV 基础视频与图片/文本挂件。

import Metal
import MetalKit
import CoreVideo
import UIKit
import simd

@MainActor
final class VAPRenderer {

    // MARK: - Metal 对象
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let yuvPipelineState: MTLRenderPipelineState
    private let attachPipelineState: MTLRenderPipelineState
    private var colorParams: VAPColorParameters = .bt601Full
    private var textureCache: CVMetalTextureCache?
    /// 未提供蒙版时使用的 1x1 不透明白色兜底纹理。
    private let defaultMaskTexture: MTLTexture

    // MARK: - 初始化

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else {
            throw VAPError.metalUnavailable
        }
        self.commandQueue = queue
        let (yuv, attach) = try Self.makePipelines(device: device)
        self.yuvPipelineState    = yuv
        self.attachPipelineState = attach
        var cache: CVMetalTextureCache?
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &cache)
        self.textureCache = cache
        self.defaultMaskTexture = try Self.makeWhiteTexture(device: device)
    }

    // MARK: - 渲染

    func render(pixelBuffer: CVPixelBuffer,
                into metalView: VAPMetalView,
                alphaPlacement: VAPAlphaPlacement,
                config: VAPConfig?,
                attachmentTextures: [String: MTLTexture],
                maskTexture: MTLTexture?,
                frameIndex: Int) {
        if metalView.metalLayer.device == nil {
            metalView.metalLayer.device = device
        }
        guard let drawable = metalView.metalLayer.nextDrawable() else { return }
        rendererLog.debug("VAP render: alphaPlacement=\(alphaPlacement.rawValue) frame=\(frameIndex) hasConfig=\(config != nil) attachCount=\(attachmentTextures.count)")

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture     = drawable.texture
        desc.colorAttachments[0].loadAction  = .clear
        desc.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        desc.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = commandQueue.makeCommandBuffer() else { return }

        // 1. 绘制基础 YUV 层（可带蒙版）。
        if let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: desc) {
            drawYUVBase(pixelBuffer: pixelBuffer,
                        alphaPlacement: alphaPlacement,
                        config: config,
                        metalView: metalView,
                        encoder: encoder)
            encoder.endEncoding()
        }

        // 2. 在上方绘制挂件层。
        if let config, let frameInfo = config.frame?.first(where: { $0.i == frameIndex }) {
            for item in (frameInfo.obj ?? []) {
                guard let tex = attachmentTextures[item.srcId] else { continue }
                let loadDesc = MTLRenderPassDescriptor()
                loadDesc.colorAttachments[0].texture     = drawable.texture
                loadDesc.colorAttachments[0].loadAction  = .load
                loadDesc.colorAttachments[0].storeAction = .store
                if let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: loadDesc) {
                    drawAttachment(item: item,
                                   texture: tex,
                                   maskTexture: maskTexture,
                                   metalView: metalView,
                                   config: config,
                                   encoder: encoder)
                    encoder.endEncoding()
                }
            }
        }

        cmdBuffer.present(drawable)
        cmdBuffer.commit()
    }

    // MARK: - 绘制 YUV 基础层

    private func drawYUVBase(pixelBuffer: CVPixelBuffer,
                             alphaPlacement: VAPAlphaPlacement,
                             config: VAPConfig?,
                             metalView: VAPMetalView,
                             encoder: MTLRenderCommandEncoder) {
        colorParams = vapColorParameters(from: pixelBuffer)
        let textures = vapMakeYUVTextures(from: pixelBuffer, device: device, textureCache: textureCache)
        guard textures.count == 2 else {
            rendererLog.debug("VAP drawYUVBase: failed to create YUV textures, frame skipped")
            return
        }

        let vw = CVPixelBufferGetWidth(pixelBuffer)
        let vh = CVPixelBufferGetHeight(pixelBuffer)

        // 根据 vapc 配置或 alphaPlacement 确定显示尺寸和纹理坐标。
        let viewRect: CGRect
        let verts: [VAPSimpleVertex]
        if let info = config?.info,
           let rgbRect = info.rgbRect,
           let alphaRect = info.alphaRect,
           info.videoW > 0, info.videoH > 0 {
            // 使用画布尺寸（w, h）计算显示宽高比。
            let displaySize = CGSize(width: info.w, height: info.h)
            viewRect = metalView.vertexRect(videoSize: displaySize)
            verts = makeFullQuad(viewRect: viewRect,
                                rgbRect: rgbRect,
                                alphaRect: alphaRect,
                                videoWidth: CGFloat(info.videoW),
                                videoHeight: CGFloat(info.videoH))
            rendererLog.debug("VAP drawYUVBase: using vapc rgbFrame/aFrame (alphaPlacement ignored). video=\(vw)x\(vh) canvas=\(info.w)x\(info.h) rgbFrame=\(rgbRect) aFrame=\(alphaRect)")
        } else {
            let rgbVideoSize = rgbContentSize(alphaPlacement: alphaPlacement, videoWidth: vw, videoHeight: vh)
            viewRect = metalView.vertexRect(videoSize: rgbVideoSize)
            verts = makeFullQuad(viewRect: viewRect, alphaPlacement: alphaPlacement)
            rendererLog.debug("VAP drawYUVBase: full=\(vw)x\(vh) rgb=\(Int(rgbVideoSize.width))x\(Int(rgbVideoSize.height)) alphaPlacement=\(alphaPlacement.rawValue)")
        }
        rendererLog.debug("VAP drawYUVBase: viewRect=(\(viewRect.minX),\(viewRect.minY),\(viewRect.width),\(viewRect.height))")

        guard let vBuf = device.makeBuffer(bytes: verts,
                                           length: verts.count * MemoryLayout<VAPSimpleVertex>.stride,
                                           options: .storageModeShared) else { return }
        var params = colorParams
        guard let pBuf = device.makeBuffer(bytes: &params,
                                           length: MemoryLayout<VAPColorParameters>.stride,
                                           options: .storageModeShared) else { return }

        encoder.setRenderPipelineState(yuvPipelineState)
        encoder.setVertexBuffer(vBuf, offset: 0, index: 0)
        encoder.setFragmentTexture(textures[0], index: 0)  // Y plane (R8Unorm)
        encoder.setFragmentTexture(textures[1], index: 1)  // UV plane (RG8Unorm)
        encoder.setFragmentBuffer(pBuf, offset: 0, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - 绘制挂件

    private func drawAttachment(item: VAPSourceDisplayItem,
                                texture: MTLTexture,
                                maskTexture: MTLTexture?,
                                metalView: VAPMetalView,
                                config: VAPConfig,
                                encoder: MTLRenderCommandEncoder) {
        let viewSize  = metalView.bounds.size
        let canvasW   = CGFloat(config.info.w)
        let canvasH   = CGFloat(config.info.h)
        guard viewSize.width > 0, viewSize.height > 0, canvasW > 0, canvasH > 0 else { return }

        // 将画布矩形转换为 NDC。
        let scaleX = 2.0 / canvasW
        let scaleY = 2.0 / canvasH
        let ndcX = Float(item.x * scaleX - 1.0)
        let ndcY = Float(1.0 - (item.y + item.h) * scaleY)
        let ndcW = Float(item.w * scaleX)
        let ndcH = Float(item.h * scaleY)

        // 蒙版坐标（如果存在）。
        var mTL = SIMD2<Float>(0, 0)
        var mBR = SIMD2<Float>(1, 1)
        if let mf = item.mFrame {
            let videoW = Float(config.info.videoW)
            let videoH = Float(config.info.videoH)
            if videoW > 0, videoH > 0 {
                mTL = SIMD2(Float(mf.x) / videoW, Float(mf.y) / videoH)
                mBR = SIMD2(Float(mf.x + mf.w) / videoW, Float(mf.y + mf.h) / videoH)
            }
        }

        let vertices: [VAPAttachmentVertex] = [
            VAPAttachmentVertex(position: SIMD4(ndcX,        ndcY + ndcH, 0, 1),
                                texCoord: SIMD2(0, 0), maskCoord: SIMD2(mTL.x, mTL.y)),
            VAPAttachmentVertex(position: SIMD4(ndcX + ndcW, ndcY + ndcH, 0, 1),
                                texCoord: SIMD2(1, 0), maskCoord: SIMD2(mBR.x, mTL.y)),
            VAPAttachmentVertex(position: SIMD4(ndcX,        ndcY,        0, 1),
                                texCoord: SIMD2(0, 1), maskCoord: SIMD2(mTL.x, mBR.y)),
            VAPAttachmentVertex(position: SIMD4(ndcX + ndcW, ndcY,        0, 1),
                                texCoord: SIMD2(1, 1), maskCoord: SIMD2(mBR.x, mBR.y))
        ]

        guard let vBuf = device.makeBuffer(bytes: vertices,
                                           length: vertices.count * MemoryLayout<VAPAttachmentVertex>.stride,
                                           options: .storageModeShared) else { return }

        encoder.setRenderPipelineState(attachPipelineState)
        encoder.setVertexBuffer(vBuf, offset: 0, index: 0)
        encoder.setFragmentTexture(texture,                          index: 0)
        encoder.setFragmentTexture(maskTexture ?? defaultMaskTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - 辅助方法

    /// 创建 1x1 R8Unorm 白色纹理（alpha = 1.0），作为默认蒙版。
    private static func makeWhiteTexture(device: MTLDevice) throws -> MTLTexture {
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Unorm, width: 1, height: 1, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else {
            throw VAPError.metalUnavailable
        }
        var white: UInt8 = 0xFF
        tex.replace(region: MTLRegionMake2D(0, 0, 1, 1),
                    mipmapLevel: 0, withBytes: &white, bytesPerRow: 1)
        return tex
    }

    /// 使用 vapc 配置中的显式 RGB 和 Alpha 区域构建四边形。
    /// 区域坐标使用视频帧内的像素坐标。
    func makeFullQuad(viewRect: CGRect,
                      rgbRect: CGRect,
                      alphaRect: CGRect,
                      videoWidth: CGFloat,
                      videoHeight: CGFloat) -> [VAPSimpleVertex] {
        let l = Float(viewRect.minX), r = Float(viewRect.maxX)
        let b = Float(viewRect.minY), t = Float(viewRect.maxY)

        // 将像素矩形归一化为 [0,1] 纹理坐标。
        let rgbTL = SIMD2<Float>(Float(rgbRect.minX / videoWidth), Float(rgbRect.minY / videoHeight))
        let rgbBR = SIMD2<Float>(Float(rgbRect.maxX / videoWidth), Float(rgbRect.maxY / videoHeight))
        let alphaTL = SIMD2<Float>(Float(alphaRect.minX / videoWidth), Float(alphaRect.minY / videoHeight))
        let alphaBR = SIMD2<Float>(Float(alphaRect.maxX / videoWidth), Float(alphaRect.maxY / videoHeight))

        return [
            VAPSimpleVertex(position: SIMD4(l, t, 0, 1), texCoord: SIMD2(rgbTL.x, rgbTL.y),   alphaTexCoord: SIMD2(alphaTL.x, alphaTL.y)),
            VAPSimpleVertex(position: SIMD4(r, t, 0, 1), texCoord: SIMD2(rgbBR.x, rgbTL.y),   alphaTexCoord: SIMD2(alphaBR.x, alphaTL.y)),
            VAPSimpleVertex(position: SIMD4(l, b, 0, 1), texCoord: SIMD2(rgbTL.x, rgbBR.y),   alphaTexCoord: SIMD2(alphaTL.x, alphaBR.y)),
            VAPSimpleVertex(position: SIMD4(r, b, 0, 1), texCoord: SIMD2(rgbBR.x, rgbBR.y),   alphaTexCoord: SIMD2(alphaBR.x, alphaBR.y))
        ]
    }

    /// 使用简单的 alphaPlacement 分割构建四边形（左右或上下各 50%）。
    func makeFullQuad(viewRect: CGRect, alphaPlacement: VAPAlphaPlacement) -> [VAPSimpleVertex] {
        let l = Float(viewRect.minX), r = Float(viewRect.maxX)
        let b = Float(viewRect.minY), t = Float(viewRect.maxY)
        // 根据 alphaPlacement 将视频帧拆分为 RGB 半区和 Alpha 半区。
        let (rgbTL, rgbBR, alphaTL, alphaBR): (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
        switch alphaPlacement {
        case .right:
            (rgbTL, rgbBR, alphaTL, alphaBR) = (SIMD2(0, 0), SIMD2(0.5, 1), SIMD2(0.5, 0), SIMD2(1, 1))
        case .left:
            (rgbTL, rgbBR, alphaTL, alphaBR) = (SIMD2(0.5, 0), SIMD2(1, 1), SIMD2(0, 0), SIMD2(0.5, 1))
        case .bottom:
            (rgbTL, rgbBR, alphaTL, alphaBR) = (SIMD2(0, 0), SIMD2(1, 0.5), SIMD2(0, 0.5), SIMD2(1, 1))
        case .top:
            (rgbTL, rgbBR, alphaTL, alphaBR) = (SIMD2(0, 0.5), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0.5))
        }
        return [
            VAPSimpleVertex(position: SIMD4(l, t, 0, 1), texCoord: SIMD2(rgbTL.x, rgbTL.y),   alphaTexCoord: SIMD2(alphaTL.x, alphaTL.y)),
            VAPSimpleVertex(position: SIMD4(r, t, 0, 1), texCoord: SIMD2(rgbBR.x, rgbTL.y),   alphaTexCoord: SIMD2(alphaBR.x, alphaTL.y)),
            VAPSimpleVertex(position: SIMD4(l, b, 0, 1), texCoord: SIMD2(rgbTL.x, rgbBR.y),   alphaTexCoord: SIMD2(alphaTL.x, alphaBR.y)),
            VAPSimpleVertex(position: SIMD4(r, b, 0, 1), texCoord: SIMD2(rgbBR.x, rgbBR.y),   alphaTexCoord: SIMD2(alphaBR.x, alphaBR.y))
        ]
    }

    // MARK: - 管线工厂

    private static func makePipelines(device: MTLDevice)
        throws -> (MTLRenderPipelineState, MTLRenderPipelineState) {
        guard let library = try? device.makeDefaultLibrary(bundle: .module) else {
            throw VAPError.metalUnavailable
        }

        func blendedPipeline(vertex: String, fragment: String) throws -> MTLRenderPipelineState {
            let desc = MTLRenderPipelineDescriptor()
            desc.vertexFunction                = library.makeFunction(name: vertex)
            desc.fragmentFunction              = library.makeFunction(name: fragment)
            desc.colorAttachments[0].pixelFormat           = .bgra8Unorm
            desc.colorAttachments[0].isBlendingEnabled     = true
            desc.colorAttachments[0].rgbBlendOperation     = .add
            desc.colorAttachments[0].alphaBlendOperation   = .add
            desc.colorAttachments[0].sourceRGBBlendFactor  = .one
            desc.colorAttachments[0].sourceAlphaBlendFactor = .one
            desc.colorAttachments[0].destinationRGBBlendFactor   = .oneMinusSourceAlpha
            desc.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try device.makeRenderPipelineState(descriptor: desc)
        }

        let yuv    = try blendedPipeline(vertex: "vap_vertexShader",
                                         fragment: "vap_yuvFragmentShader")
        let attach = try blendedPipeline(vertex: "vapAttachment_VertexShader",
                                         fragment: "vapAttachment_FragmentShader")
        return (yuv, attach)
    }
}
