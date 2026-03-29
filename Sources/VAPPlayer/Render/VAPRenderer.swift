// VAPRenderer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// VAP-x renderer: composites YUV base video + attachment images/text using mask.

import Metal
import MetalKit
import CoreVideo
import UIKit
import simd

@MainActor
final class VAPRenderer {

    // MARK: - Metal objects
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let yuvPipelineState: MTLRenderPipelineState
    private let attachPipelineState: MTLRenderPipelineState
    private var colorParams: VAPColorParameters = .bt601Full
    private var textureCache: CVMetalTextureCache?

    // MARK: - Init

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
    }

    // MARK: - Render

    func render(pixelBuffer: CVPixelBuffer,
                into metalView: VAPMetalView,
                blendMode: VAPTextureBlendMode,
                config: VAPConfig?,
                attachmentTextures: [String: MTLTexture],
                maskTexture: MTLTexture?,
                frameIndex: Int) {
        if metalView.metalLayer.device == nil {
            metalView.metalLayer.device = device
        }
        guard let drawable = metalView.metalLayer.nextDrawable() else { return }
        rendererLog.debug("VAP render: blendMode=\(blendMode.rawValue) frame=\(frameIndex) hasConfig=\(config != nil) attachCount=\(attachmentTextures.count)")

        let desc = MTLRenderPassDescriptor()
        desc.colorAttachments[0].texture     = drawable.texture
        desc.colorAttachments[0].loadAction  = .clear
        desc.colorAttachments[0].clearColor  = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        desc.colorAttachments[0].storeAction = .store

        guard let cmdBuffer = commandQueue.makeCommandBuffer() else { return }

        // 1. Draw base YUV layer (with optional mask)
        if let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: desc) {
            drawYUVBase(pixelBuffer: pixelBuffer,
                        blendMode: blendMode,
                        config: config,
                        metalView: metalView,
                        encoder: encoder)
            encoder.endEncoding()
        }

        // 2. Draw attachment layers on top
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

    // MARK: - Draw YUV base

    private func drawYUVBase(pixelBuffer: CVPixelBuffer,
                             blendMode: VAPTextureBlendMode,
                             config: VAPConfig?,
                             metalView: VAPMetalView,
                             encoder: MTLRenderCommandEncoder) {
        updateColorParams(from: pixelBuffer)
        let textures = makeYUVTextures(from: pixelBuffer)
        guard textures.count == 2 else { return }

        let vw = CVPixelBufferGetWidth(pixelBuffer)
        let vh = CVPixelBufferGetHeight(pixelBuffer)

        // Determine display size and texture coordinates from vapc config or blend mode
        let viewRect: CGRect
        let verts: [VAPSimpleVertex]
        if let info = config?.info,
           let rgbRect = info.rgbRect,
           let alphaRect = info.alphaRect,
           info.videoW > 0, info.videoH > 0 {
            // Use canvas size (w, h) for display aspect ratio
            let displaySize = CGSize(width: info.w, height: info.h)
            viewRect = metalView.vertexRect(videoSize: displaySize)
            verts = makeFullQuad(viewRect: viewRect,
                                rgbRect: rgbRect,
                                alphaRect: alphaRect,
                                videoWidth: CGFloat(info.videoW),
                                videoHeight: CGFloat(info.videoH))
            rendererLog.debug("VAP drawYUVBase: video=\(vw)x\(vh) canvas=\(info.w)x\(info.h) rgbFrame=\(rgbRect) aFrame=\(alphaRect)")
        } else {
            let rgbVideoSize = Self.rgbSize(blendMode: blendMode, videoWidth: vw, videoHeight: vh)
            viewRect = metalView.vertexRect(videoSize: rgbVideoSize)
            verts = makeFullQuad(viewRect: viewRect, blendMode: blendMode)
            rendererLog.debug("VAP drawYUVBase: full=\(vw)x\(vh) rgb=\(Int(rgbVideoSize.width))x\(Int(rgbVideoSize.height)) blendMode=\(blendMode.rawValue)")
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

    // MARK: - Draw attachment

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

        // Convert canvas rect -> NDC
        let scaleX = 2.0 / canvasW
        let scaleY = 2.0 / canvasH
        let ndcX = Float(item.x * scaleX - 1.0)
        let ndcY = Float(1.0 - (item.y + item.h) * scaleY)
        let ndcW = Float(item.w * scaleX)
        let ndcH = Float(item.h * scaleY)

        // Mask coords (if present)
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
        encoder.setFragmentTexture(texture,     index: 0)
        encoder.setFragmentTexture(maskTexture, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    // MARK: - Helpers

    static func rgbSize(blendMode: VAPTextureBlendMode,
                        videoWidth: Int, videoHeight: Int) -> CGSize {
        switch blendMode {
        case .alphaLeft, .alphaRight:
            return CGSize(width: videoWidth / 2, height: videoHeight)
        case .alphaTop, .alphaBottom:
            return CGSize(width: videoWidth, height: videoHeight / 2)
        }
    }

    /// Build a quad using explicit RGB and alpha regions from vapc config.
    /// Regions are in pixel coordinates within the video frame.
    func makeFullQuad(viewRect: CGRect,
                      rgbRect: CGRect,
                      alphaRect: CGRect,
                      videoWidth: CGFloat,
                      videoHeight: CGFloat) -> [VAPSimpleVertex] {
        let l = Float(viewRect.minX), r = Float(viewRect.maxX)
        let b = Float(viewRect.minY), t = Float(viewRect.maxY)

        // Normalize pixel rects to [0,1] texture coordinates
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

    /// Build a quad using simple blend mode split (50/50 left-right or top-bottom).
    func makeFullQuad(viewRect: CGRect, blendMode: VAPTextureBlendMode) -> [VAPSimpleVertex] {
        let l = Float(viewRect.minX), r = Float(viewRect.maxX)
        let b = Float(viewRect.minY), t = Float(viewRect.maxY)
        // Split the video frame into RGB half and alpha half based on blend mode
        let (rgbTL, rgbBR, alphaTL, alphaBR): (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>)
        switch blendMode {
        case .alphaRight:
            (rgbTL, rgbBR, alphaTL, alphaBR) = (SIMD2(0, 0), SIMD2(0.5, 1), SIMD2(0.5, 0), SIMD2(1, 1))
        case .alphaLeft:
            (rgbTL, rgbBR, alphaTL, alphaBR) = (SIMD2(0.5, 0), SIMD2(1, 1), SIMD2(0, 0), SIMD2(0.5, 1))
        case .alphaBottom:
            (rgbTL, rgbBR, alphaTL, alphaBR) = (SIMD2(0, 0), SIMD2(1, 0.5), SIMD2(0, 0.5), SIMD2(1, 1))
        case .alphaTop:
            (rgbTL, rgbBR, alphaTL, alphaBR) = (SIMD2(0, 0.5), SIMD2(1, 1), SIMD2(0, 0), SIMD2(1, 0.5))
        }
        return [
            VAPSimpleVertex(position: SIMD4(l, t, 0, 1), texCoord: SIMD2(rgbTL.x, rgbTL.y),   alphaTexCoord: SIMD2(alphaTL.x, alphaTL.y)),
            VAPSimpleVertex(position: SIMD4(r, t, 0, 1), texCoord: SIMD2(rgbBR.x, rgbTL.y),   alphaTexCoord: SIMD2(alphaBR.x, alphaTL.y)),
            VAPSimpleVertex(position: SIMD4(l, b, 0, 1), texCoord: SIMD2(rgbTL.x, rgbBR.y),   alphaTexCoord: SIMD2(alphaTL.x, alphaBR.y)),
            VAPSimpleVertex(position: SIMD4(r, b, 0, 1), texCoord: SIMD2(rgbBR.x, rgbBR.y),   alphaTexCoord: SIMD2(alphaBR.x, alphaBR.y))
        ]
    }

    private func makeYUVTextures(from pixelBuffer: CVPixelBuffer) -> [MTLTexture] {
        let yWidth   = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight  = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvWidth  = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        // Fast path: IOSurface-backed buffer (real device)
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
            func make(_ plane: Int, _ w: Int, _ h: Int, _ fmt: MTLPixelFormat) -> MTLTexture? {
                var mt: CVMetalTexture?
                guard CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, cache, pixelBuffer, nil, fmt, w, h, plane, &mt) == kCVReturnSuccess,
                      let mt else { return nil }
                return CVMetalTextureGetTexture(mt)
            }
            if let y  = make(0, yWidth,  yHeight,  .r8Unorm),
               let uv = make(1, uvWidth, uvHeight, .rg8Unorm) {
                return [y, uv]
            }
        }

        // Slow path: CPU copy for simulator (pixel buffers not IOSurface-backed)
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        return makeCPUTextures(pixelBuffer: pixelBuffer,
                               yWidth: yWidth, yHeight: yHeight,
                               uvWidth: uvWidth, uvHeight: uvHeight)
    }

    private func makeCPUTextures(pixelBuffer: CVPixelBuffer,
                                 yWidth: Int, yHeight: Int,
                                 uvWidth: Int, uvHeight: Int) -> [MTLTexture] {
        func makeTexture(plane: Int, width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
            guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: width, height: height, mipmapped: false)
            desc.usage = .shaderRead
            guard let tex = device.makeTexture(descriptor: desc) else { return nil }
            tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                        mipmapLevel: 0,
                        withBytes: baseAddr,
                        bytesPerRow: bytesPerRow)
            return tex
        }
        guard let yTex  = makeTexture(plane: 0, width: yWidth,  height: yHeight,  format: .r8Unorm),
              let uvTex = makeTexture(plane: 1, width: uvWidth, height: uvHeight, format: .rg8Unorm)
        else {
            rendererLog.error("VAP makeCPUTextures: failed to create textures")
            return []
        }
        return [yTex, uvTex]
    }

    private func updateColorParams(from pixelBuffer: CVPixelBuffer) {
        let matrix = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)?
            .takeUnretainedValue() as? String
        let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
        let isFullRange = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
            || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let is709 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        switch (is709, isFullRange) {
        case (true,  true):  colorParams = .bt709Full
        case (true,  false): colorParams = .bt709
        case (false, true):  colorParams = .bt601Full
        case (false, false): colorParams = .bt601
        }
    }

    // MARK: - Pipeline factory

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
