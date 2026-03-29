// VAPRenderUtils.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// Shared utilities for VAPRenderer and VAPHWDRenderer.

import Metal
import CoreVideo

// MARK: - RGB display size

/// Computes the visible RGB content size based on blend mode.
/// For left/right split the width is halved; for top/bottom the height is halved.
func vapRGBSize(blendMode: VAPTextureBlendMode,
                videoWidth: Int, videoHeight: Int) -> CGSize {
    switch blendMode {
    case .alphaLeft, .alphaRight:
        return CGSize(width: videoWidth / 2, height: videoHeight)
    case .alphaTop, .alphaBottom:
        return CGSize(width: videoWidth, height: videoHeight / 2)
    }
}

// MARK: - YUV color parameters from pixel buffer

/// Detects YCbCr matrix and pixel format range from a decoded pixel buffer
/// and returns the matching pre-computed color parameters.
func vapColorParameters(from pixelBuffer: CVPixelBuffer) -> VAPColorParameters {
    let matrix = CVBufferGetAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil)?
        .takeUnretainedValue() as? String
    let fmt = CVPixelBufferGetPixelFormatType(pixelBuffer)
    let isFullRange = fmt == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        || fmt == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    let is709 = matrix == (kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
    switch (is709, isFullRange) {
    case (true,  true):  return .bt709Full
    case (true,  false): return .bt709
    case (false, true):  return .bt601Full
    case (false, false): return .bt601
    }
}

// MARK: - YUV texture creation from NV12 CVPixelBuffer

/// Creates Metal textures for the Y and UV planes of an NV12 pixel buffer.
/// Uses the fast `CVMetalTextureCache` path on real devices and falls back to
/// CPU copy on the simulator where pixel buffers are not IOSurface-backed.
func vapMakeYUVTextures(from pixelBuffer: CVPixelBuffer,
                        device: MTLDevice,
                        textureCache: CVMetalTextureCache?) -> [MTLTexture] {
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

    func makeTexture(plane: Int, width: Int, height: Int, format: MTLPixelFormat) -> MTLTexture? {
        guard let baseAddr = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, plane) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, plane)
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        guard let tex = device.makeTexture(descriptor: desc) else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, width, height),
                    mipmapLevel: 0, withBytes: baseAddr, bytesPerRow: bytesPerRow)
        return tex
    }
    guard let yTex  = makeTexture(plane: 0, width: yWidth,  height: yHeight,  format: .r8Unorm),
          let uvTex = makeTexture(plane: 1, width: uvWidth, height: uvHeight, format: .rg8Unorm)
    else { return [] }
    return [yTex, uvTex]
}
