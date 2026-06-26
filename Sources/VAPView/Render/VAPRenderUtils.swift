// VAPRenderUtils.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// VAPRenderer 和 VAPHWDRenderer 共用的工具方法。

import Metal
import CoreVideo

// MARK: - RGB 显示尺寸

/// 根据 alphaPlacement 计算可见 RGB 内容尺寸。
/// 左/右分割时宽度减半；上/下分割时高度减半。
func rgbContentSize(alphaPlacement: VAPAlphaPlacement,
                    videoWidth: Int,
                    videoHeight: Int) -> CGSize {
    switch alphaPlacement {
    case .left, .right:
        return CGSize(width: videoWidth / 2, height: videoHeight)
    case .top, .bottom:
        return CGSize(width: videoWidth, height: videoHeight / 2)
    }
}

// MARK: - 从像素缓冲区获取 YUV 颜色参数

/// 从已解码的像素缓冲区检测 YCbCr 矩阵和像素格式范围，
/// 并返回匹配的预计算颜色参数。
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

// MARK: - 从 NV12 CVPixelBuffer 创建 YUV 纹理

/// 为 NV12 像素缓冲区的 Y 和 UV 平面创建 Metal 纹理。
/// 真机上使用较快的 `CVMetalTextureCache` 路径；模拟器上如果像素缓冲区
/// 不是 IOSurface 后备存储，则回退到 CPU 拷贝。
func vapMakeYUVTextures(from pixelBuffer: CVPixelBuffer,
                        device: MTLDevice,
                        textureCache: CVMetalTextureCache?) -> [MTLTexture] {
    let yWidth   = CVPixelBufferGetWidthOfPlane(pixelBuffer, 0)
    let yHeight  = CVPixelBufferGetHeightOfPlane(pixelBuffer, 0)
    let uvWidth  = CVPixelBufferGetWidthOfPlane(pixelBuffer, 1)
    let uvHeight = CVPixelBufferGetHeightOfPlane(pixelBuffer, 1)

    // 快路径：IOSurface 后备缓冲区（真机）。
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

    // 慢路径：模拟器 CPU 拷贝（像素缓冲区不是 IOSurface 后备存储）。
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
