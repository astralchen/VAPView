// VAPShaderTypes.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// Swift-side mirror of the Metal shader structs.
// These must stay in sync with the .metal files.

import simd
import Foundation

// MARK: - Vertex (VAP simple path — matches vap_vertexShader / VAPSimpleVertex in .metal)
struct VAPSimpleVertex {
    var position: SIMD4<Float>
    var texCoord: SIMD2<Float>
    var alphaTexCoord: SIMD2<Float>
}

// MARK: - Vertex (HWD alpha-split path)
struct VAPHWDVertex {
    var position: SIMD4<Float>   // x, y, z, w
    var rgbTexCoord: SIMD2<Float>
    var alphaTexCoord: SIMD2<Float>
}

// MARK: - Vertex (VAP attachment path)
struct VAPAttachmentVertex {
    var position: SIMD4<Float>
    var texCoord: SIMD2<Float>
    var maskCoord: SIMD2<Float>
}

// MARK: - YUV color parameters
struct VAPColorParameters {
    var colorMatrix: matrix_float3x3
    var colorOffset: SIMD3<Float>
}

// MARK: - Mask parameters
struct VAPMaskParameters {
    var maskTexCoord: SIMD4<Float>  // x, y, w, h in normalized texture coords
}

// MARK: - Attachment fragment parameters
struct VAPAttachmentFragmentParameter {
    var hasMask: Int32
}

// MARK: - YUV texture index enum (NV12 bi-planar: Y plane + UV interleaved plane)
enum VAPYUVTextureIndex: Int {
    case Y    = 0   // R8Unorm
    case UV   = 1   // RG8Unorm (Cb in .r, Cr in .g)
    case mask = 2   // R8Unorm (VAP path only)
}

// MARK: - Pre-computed YUV colour matrices (BT.601 / BT.709)
extension VAPColorParameters {
    // BT.601 limited range (most common for H.264)
    static let bt601: VAPColorParameters = {
        let m = matrix_float3x3(columns: (
            SIMD3<Float>( 1.164,  1.164,  1.164),
            SIMD3<Float>( 0.000, -0.392,  2.017),
            SIMD3<Float>( 1.596, -0.813,  0.000)
        ))
        return VAPColorParameters(colorMatrix: m,
                                  colorOffset: SIMD3<Float>(-0.87075, 0.52925, -1.08175))
    }()

    // BT.601 full range
    static let bt601Full: VAPColorParameters = {
        let m = matrix_float3x3(columns: (
            SIMD3<Float>(1.000,  1.000,  1.000),
            SIMD3<Float>(0.000, -0.344,  1.772),
            SIMD3<Float>(1.402, -0.714,  0.000)
        ))
        return VAPColorParameters(colorMatrix: m,
                                  colorOffset: SIMD3<Float>(-0.701, 0.529, -0.886))
    }()

    // BT.709 limited range
    static let bt709: VAPColorParameters = {
        let m = matrix_float3x3(columns: (
            SIMD3<Float>( 1.164,  1.164,  1.164),
            SIMD3<Float>( 0.000, -0.213,  2.112),
            SIMD3<Float>( 1.793, -0.533,  0.000)
        ))
        return VAPColorParameters(colorMatrix: m,
                                  colorOffset: SIMD3<Float>(-0.97275, 0.30135, -1.13348))
    }()

    // BT.709 full range
    static let bt709Full: VAPColorParameters = {
        let m = matrix_float3x3(columns: (
            SIMD3<Float>(1.000,  1.000,  1.000),
            SIMD3<Float>(0.000, -0.187,  1.856),
            SIMD3<Float>(1.575, -0.468,  0.000)
        ))
        return VAPColorParameters(colorMatrix: m,
                                  colorOffset: SIMD3<Float>(-0.7875, 0.3285, -0.9280))
    }()
}
