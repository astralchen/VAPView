// VAPHWDRenderer.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// Renders alpha-split YUV video frames using the HWD Metal pipeline.

import Metal
import MetalKit
import CoreVideo
import simd

@MainActor
final class VAPHWDRenderer {

    // MARK: - Metal objects
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let pipelineState: MTLRenderPipelineState
    private var colorParams: VAPColorParameters = .bt601Full
    private var textureCache: CVMetalTextureCache?

    // MARK: - Init

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

    // MARK: - Render

    /// Render one decoded frame into `metalView`.
    /// `blendMode` determines which half of the frame contains the alpha channel.
    func render(pixelBuffer: CVPixelBuffer,
                into metalView: VAPMetalView,
                blendMode: VAPTextureBlendMode) {
        if metalView.metalLayer.device == nil {
            metalView.metalLayer.device = device
            rendererLog.debug("HWD: set metalLayer.device")
        }
        let layerSize = metalView.metalLayer.drawableSize
        rendererLog.debug("HWD: drawableSize=\(layerSize.width)x\(layerSize.height) bounds=\(metalView.bounds.width)x\(metalView.bounds.height)")
        guard let drawable = metalView.metalLayer.nextDrawable() else {
            rendererLog.error("HWD: nextDrawable() returned nil")
            return
        }

        updateColorParams(from: pixelBuffer)
        let textures = makeYUVTextures(from: pixelBuffer)
        guard textures.count == 2 else { return }

        let videoWidth  = CVPixelBufferGetWidth(pixelBuffer)
        let videoHeight = CVPixelBufferGetHeight(pixelBuffer)
        let vertices = makeVertices(blendMode: blendMode,
                                   videoSize: CGSize(width: videoWidth, height: videoHeight),
                                   viewRect: metalView.vertexRect(
                                       videoSize: Self.rgbSize(blendMode: blendMode,
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

    // MARK: - Pipeline

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

    // MARK: - Texture creation from CVPixelBuffer (NV12 bi-planar)

    private func makeYUVTextures(from pixelBuffer: CVPixelBuffer) -> [MTLTexture] {
        let yWidth   = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
        let yHeight  = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
        let uvWidth  = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
        let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

        // Fast path: IOSurface-backed buffer (real device)
        if let cache = textureCache {
            CVMetalTextureCacheFlush(cache, 0)
            func planeTexture(plane: Int, width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
                var metalTexture: CVMetalTexture?
                let status = CVMetalTextureCacheCreateTextureFromImage(
                    kCFAllocatorDefault, cache, pixelBuffer, nil, format, width, height, plane, &metalTexture)
                guard status == kCVReturnSuccess, let mt = metalTexture else { return nil }
                return CVMetalTextureGetTexture(mt)
            }
            if let yTex  = planeTexture(plane: 0, width: yWidth,  height: yHeight,  format: .r8Unorm),
               let uvTex = planeTexture(plane: 1, width: uvWidth, height: uvHeight, format: .rg8Unorm) {
                return [yTex, uvTex]
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
        func makeTexture(plane: Int, width: Int, height: Int, format: MTLPixelFormat, bytesPerPixel: Int) -> MTLTexture? {
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
        guard let yTex  = makeTexture(plane: 0, width: yWidth,  height: yHeight,  format: .r8Unorm,  bytesPerPixel: 1),
              let uvTex = makeTexture(plane: 1, width: uvWidth, height: uvHeight, format: .rg8Unorm, bytesPerPixel: 2)
        else { return [] }
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

    // MARK: - Vertex helpers

    static func rgbSize(blendMode: VAPTextureBlendMode,
                        videoWidth: Int, videoHeight: Int) -> CGSize {
        switch blendMode {
        case .alphaLeft, .alphaRight:
            return CGSize(width: videoWidth / 2, height: videoHeight)
        case .alphaTop, .alphaBottom:
            return CGSize(width: videoWidth, height: videoHeight / 2)
        }
    }

    private func makeVertices(blendMode: VAPTextureBlendMode,
                              videoSize: CGSize,
                              viewRect: CGRect) -> [VAPHWDVertex] {
        let l = Float(viewRect.minX), r = Float(viewRect.maxX)
        let b = Float(viewRect.minY), t = Float(viewRect.maxY)
        // Normalized texture coordinates depend on blend mode
        let (rgbTL, rgbBR, alphaTL, alphaBR) = Self.texCoords(blendMode: blendMode)
        // 4 vertices: TL, TR, BL, BR (triangle strip)
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

    /// Returns (rgbTopLeft, rgbBottomRight, alphaTopLeft, alphaBottomRight)
    /// in normalized UV space [0,1].
    static func texCoords(blendMode: VAPTextureBlendMode)
        -> (SIMD2<Float>, SIMD2<Float>, SIMD2<Float>, SIMD2<Float>) {
        switch blendMode {
        case .alphaRight:
            return (SIMD2(0, 0), SIMD2(0.5, 1),
                    SIMD2(0.5, 0), SIMD2(1, 1))
        case .alphaLeft:
            return (SIMD2(0.5, 0), SIMD2(1, 1),
                    SIMD2(0, 0),   SIMD2(0.5, 1))
        case .alphaBottom:
            return (SIMD2(0, 0), SIMD2(1, 0.5),
                    SIMD2(0, 0.5), SIMD2(1, 1))
        case .alphaTop:
            return (SIMD2(0, 0.5), SIMD2(1, 1),
                    SIMD2(0, 0),   SIMD2(1, 0.5))
        }
    }
}
