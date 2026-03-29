// VAPShaders.metal
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

#include <metal_stdlib>
using namespace metal;

// MARK: - Shared structs

struct ColorParameters {
    float3x3 colorMatrix;
    float3   colorOffset;
};

struct VAPHWDVertex {
    float4 position      [[attribute(0)]];
    float2 rgbTexCoord   [[attribute(1)]];
    float2 alphaTexCoord [[attribute(2)]];
};

struct VAPHWDRasterizerData {
    float4 position [[position]];
    float2 rgbTexCoord;
    float2 alphaTexCoord;
};

struct VAPAttachmentVertex {
    float4 position  [[attribute(0)]];
    float2 texCoord  [[attribute(1)]];
    float2 maskCoord [[attribute(2)]];
};

struct VAPAttachmentRasterizerData {
    float4 position [[position]];
    float2 texCoord;
    float2 maskCoord;
};

// MARK: - HWD path: alpha-split YUV video

vertex VAPHWDRasterizerData
hwd_vertexShader(uint vertexID [[vertex_id]],
                 constant VAPHWDVertex *vertices [[buffer(0)]]) {
    VAPHWDRasterizerData out;
    out.position      = vertices[vertexID].position;
    out.rgbTexCoord   = vertices[vertexID].rgbTexCoord;
    out.alphaTexCoord = vertices[vertexID].alphaTexCoord;
    return out;
}

fragment float4
hwd_yuvFragmentShader(VAPHWDRasterizerData   in        [[stage_in]],
                      texture2d<float>        yTexture  [[texture(0)]],
                      texture2d<float>        uvTexture [[texture(1)]],
                      constant ColorParameters &params  [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);

    float  y  = yTexture.sample(texSampler,  in.rgbTexCoord).r;
    float2 uv = uvTexture.sample(texSampler, in.rgbTexCoord).rg;
    float  cb = uv.r;
    float  cr = uv.g;

    float3 yuv = float3(y, cb, cr);
    float3 rgb = params.colorMatrix * yuv + params.colorOffset;
    rgb = clamp(rgb, 0.0, 1.0);

    // Alpha is extracted from the Y channel of the alpha-side region
    float alpha = yTexture.sample(texSampler, in.alphaTexCoord).r;
    alpha = clamp(alpha, 0.0, 1.0);

    return float4(rgb * alpha, alpha);
}

// MARK: - VAP path: YUV base video (alpha split from same video frame)

struct VAPSimpleVertex {
    float4 position      [[attribute(0)]];
    float2 texCoord      [[attribute(1)]];
    float2 alphaTexCoord [[attribute(2)]];
};

struct VAPSimpleRasterizerData {
    float4 position [[position]];
    float2 texCoord;
    float2 alphaTexCoord;
};

vertex VAPSimpleRasterizerData
vap_vertexShader(uint vertexID [[vertex_id]],
                 constant VAPSimpleVertex *vertices [[buffer(0)]]) {
    VAPSimpleRasterizerData out;
    out.position      = vertices[vertexID].position;
    out.texCoord      = vertices[vertexID].texCoord;
    out.alphaTexCoord = vertices[vertexID].alphaTexCoord;
    return out;
}

fragment float4
vap_yuvFragmentShader(VAPSimpleRasterizerData  in        [[stage_in]],
                      texture2d<float>          yTexture  [[texture(0)]],
                      texture2d<float>          uvTexture [[texture(1)]],
                      constant ColorParameters  &params   [[buffer(0)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);

    float  y  = yTexture.sample(texSampler,  in.texCoord).r;
    float2 uv = uvTexture.sample(texSampler, in.texCoord).rg;
    float  cb = uv.r;
    float  cr = uv.g;

    float3 yuv = float3(y, cb, cr);
    float3 rgb = params.colorMatrix * yuv + params.colorOffset;
    rgb = clamp(rgb, 0.0, 1.0);

    // Alpha is extracted from the Y channel of the alpha-side region of the same video frame
    float alpha = yTexture.sample(texSampler, in.alphaTexCoord).r;
    alpha = clamp(alpha, 0.0, 1.0);

    return float4(rgb * alpha, alpha);
}

// MARK: - VAP attachment path

vertex VAPAttachmentRasterizerData
vapAttachment_VertexShader(uint vertexID [[vertex_id]],
                            constant VAPAttachmentVertex *vertices [[buffer(0)]]) {
    VAPAttachmentRasterizerData out;
    out.position = vertices[vertexID].position;
    out.texCoord = vertices[vertexID].texCoord;
    out.maskCoord = vertices[vertexID].maskCoord;
    return out;
}

fragment float4
vapAttachment_FragmentShader(VAPAttachmentRasterizerData in         [[stage_in]],
                              texture2d<float>            attachTex  [[texture(0)]],
                              texture2d<float>            maskTex    [[texture(1)]]) {
    constexpr sampler texSampler(mag_filter::linear, min_filter::linear);

    float4 color = attachTex.sample(texSampler, in.texCoord);
    float  mask  = maskTex.sample(texSampler,   in.maskCoord).r;
    mask = clamp(mask, 0.0, 1.0);

    return float4(color.rgb * mask, color.a * mask);
}
