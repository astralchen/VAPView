// VAPShaderTypes.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// Metal shader 结构体的 Swift 侧镜像。
// 必须与 .metal 文件保持同步。

import simd
import Foundation

// MARK: - 顶点（VAP 简单路径；对应 .metal 中的 vap_vertexShader / VAPSimpleVertex）
struct VAPSimpleVertex {
    var position: SIMD4<Float>
    var texCoord: SIMD2<Float>
    var alphaTexCoord: SIMD2<Float>
}

// MARK: - 顶点（HWD alpha 分割路径）
struct VAPHWDVertex {
    var position: SIMD4<Float>   // x、y、z、w
    var rgbTexCoord: SIMD2<Float>
    var alphaTexCoord: SIMD2<Float>
}

// MARK: - 顶点（VAP 挂件路径）
struct VAPAttachmentVertex {
    var position: SIMD4<Float>
    var texCoord: SIMD2<Float>
    var maskCoord: SIMD2<Float>
}

// MARK: - YUV 颜色参数
struct VAPColorParameters {
    var colorMatrix: matrix_float3x3
    var colorOffset: SIMD3<Float>
}

// MARK: - 蒙版参数
struct VAPMaskParameters {
    var maskTexCoord: SIMD4<Float>  // 归一化纹理坐标中的 x、y、w、h
}

// MARK: - 挂件片元参数
struct VAPAttachmentFragmentParameter {
    var hasMask: Int32
}

// MARK: - YUV 纹理索引枚举（NV12 双平面：Y 平面 + 交错 UV 平面）
enum VAPYUVTextureIndex: Int {
    case Y    = 0   // R8Unorm
    case UV   = 1   // RG8Unorm（Cb 在 .r，Cr 在 .g）
    case mask = 2   // R8Unorm（仅 VAP 路径）
}

// MARK: - 预计算 YUV 颜色矩阵（BT.601 / BT.709）
extension VAPColorParameters {
    // BT.601 有限范围（H.264 最常见）
    static let bt601: VAPColorParameters = {
        let m = matrix_float3x3(columns: (
            SIMD3<Float>( 1.164,  1.164,  1.164),
            SIMD3<Float>( 0.000, -0.392,  2.017),
            SIMD3<Float>( 1.596, -0.813,  0.000)
        ))
        return VAPColorParameters(colorMatrix: m,
                                  colorOffset: SIMD3<Float>(-0.87075, 0.52925, -1.08175))
    }()

    // BT.601 全范围
    static let bt601Full: VAPColorParameters = {
        let m = matrix_float3x3(columns: (
            SIMD3<Float>(1.000,  1.000,  1.000),
            SIMD3<Float>(0.000, -0.344,  1.772),
            SIMD3<Float>(1.402, -0.714,  0.000)
        ))
        return VAPColorParameters(colorMatrix: m,
                                  colorOffset: SIMD3<Float>(-0.701, 0.529, -0.886))
    }()

    // BT.709 有限范围
    static let bt709: VAPColorParameters = {
        let m = matrix_float3x3(columns: (
            SIMD3<Float>( 1.164,  1.164,  1.164),
            SIMD3<Float>( 0.000, -0.213,  2.112),
            SIMD3<Float>( 1.793, -0.533,  0.000)
        ))
        return VAPColorParameters(colorMatrix: m,
                                  colorOffset: SIMD3<Float>(-0.97275, 0.30135, -1.13348))
    }()

    // BT.709 全范围
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
