// VAPRendererTests.swift
import Testing
import Foundation
import UIKit
import simd
@testable import VAPView

@Suite("VAPRenderer")
struct VAPRendererTests {

    // MARK: - A. RGB 尺寸计算

    @Test func rgbSizeAlphaRight() {
        let size = rgbContentSize(alphaPlacement: .right, videoWidth: 1920, videoHeight: 1080)
        #expect(size == CGSize(width: 960, height: 1080))
    }

    @Test func rgbSizeAlphaLeft() {
        let size = rgbContentSize(alphaPlacement: .left, videoWidth: 1920, videoHeight: 1080)
        #expect(size == CGSize(width: 960, height: 1080))
    }

    @Test func rgbSizeAlphaBottom() {
        let size = rgbContentSize(alphaPlacement: .bottom, videoWidth: 960, videoHeight: 1080)
        #expect(size == CGSize(width: 960, height: 540))
    }

    @Test func rgbSizeAlphaTop() {
        let size = rgbContentSize(alphaPlacement: .top, videoWidth: 960, videoHeight: 1080)
        #expect(size == CGSize(width: 960, height: 540))
    }

    // MARK: - B. 顶点矩形

    @Test @MainActor func vertexRectScaleToFill() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.renderContentMode = .scaleToFill
        let rect = view.vertexRect(videoSize: CGSize(width: 1920, height: 1080))
        #expect(rect == CGRect(x: -1, y: -1, width: 2, height: 2))
    }

    @Test @MainActor func vertexRectAspectFitWiderVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.renderContentMode = .aspectFit
        // 16:9 视频显示在正方形视图中：应上下留黑（高度 < 2）。
        let rect = view.vertexRect(videoSize: CGSize(width: 1920, height: 1080))
        #expect(rect.width == 2.0)
        #expect(rect.height < 2.0)
    }

    @Test @MainActor func vertexRectAspectFitTallerVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.renderContentMode = .aspectFit
        // 9:16 视频显示在正方形视图中：应左右留黑（宽度 < 2）。
        let rect = view.vertexRect(videoSize: CGSize(width: 1080, height: 1920))
        #expect(rect.width < 2.0)
        #expect(rect.height == 2.0)
    }

    @Test @MainActor func vertexRectAspectFillWiderVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.renderContentMode = .aspectFill
        // 16:9 视频显示在正方形视图中：为填满视图，宽度超过 2，高度保持 2。
        let rect = view.vertexRect(videoSize: CGSize(width: 1920, height: 1080))
        #expect(rect.width > 2.0)
        #expect(abs(rect.height - 2.0) < 0.001)
    }

    @Test @MainActor func vertexRectZeroBounds() {
        let view = VAPMetalView(frame: .zero)
        let rect = view.vertexRect(videoSize: CGSize(width: 100, height: 100))
        #expect(rect == CGRect(x: -1, y: -1, width: 2, height: 2))
    }

    // MARK: - C. 纹理坐标拆分（HWD texCoords）

    @Test @MainActor func texCoordsAlphaRight() {
        let (rgbTL, rgbBR, alphaTL, alphaBR) = VAPHWDRenderer.texCoords(alphaPlacement: .right)
        // RGB：左半部分，Alpha：右半部分。
        #expect(rgbTL   == SIMD2<Float>(0, 0))
        #expect(rgbBR   == SIMD2<Float>(0.5, 1))
        #expect(alphaTL == SIMD2<Float>(0.5, 0))
        #expect(alphaBR == SIMD2<Float>(1, 1))
    }

    @Test @MainActor func texCoordsAlphaLeft() {
        let (rgbTL, rgbBR, alphaTL, alphaBR) = VAPHWDRenderer.texCoords(alphaPlacement: .left)
        // RGB：右半部分，Alpha：左半部分。
        #expect(rgbTL   == SIMD2<Float>(0.5, 0))
        #expect(rgbBR   == SIMD2<Float>(1, 1))
        #expect(alphaTL == SIMD2<Float>(0, 0))
        #expect(alphaBR == SIMD2<Float>(0.5, 1))
    }

    @Test @MainActor func texCoordsAlphaBottom() {
        let (rgbTL, rgbBR, alphaTL, alphaBR) = VAPHWDRenderer.texCoords(alphaPlacement: .bottom)
        // RGB：上半部分，Alpha：下半部分。
        #expect(rgbTL   == SIMD2<Float>(0, 0))
        #expect(rgbBR   == SIMD2<Float>(1, 0.5))
        #expect(alphaTL == SIMD2<Float>(0, 0.5))
        #expect(alphaBR == SIMD2<Float>(1, 1))
    }

    @Test @MainActor func texCoordsAlphaTop() {
        let (rgbTL, rgbBR, alphaTL, alphaBR) = VAPHWDRenderer.texCoords(alphaPlacement: .top)
        // RGB：下半部分，Alpha：上半部分。
        #expect(rgbTL   == SIMD2<Float>(0, 0.5))
        #expect(rgbBR   == SIMD2<Float>(1, 1))
        #expect(alphaTL == SIMD2<Float>(0, 0))
        #expect(alphaBR == SIMD2<Float>(1, 0.5))
    }

    // MARK: - D. 颜色矩阵验证

    @Test func bt601FullWhite() {
        // Y=1.0, Cb=0.5, Cr=0.5 -> 白色 (1, 1, 1)。
        let p = VAPColorParameters.bt601Full
        let yuv = SIMD3<Float>(1.0, 0.5, 0.5)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x - 1.0) < 0.02)
        #expect(abs(rgb.y - 1.0) < 0.02)
        #expect(abs(rgb.z - 1.0) < 0.02)
    }

    @Test func bt601FullBlack() {
        // Y=0.0, Cb=0.5, Cr=0.5 -> 黑色 (0, 0, 0)。
        let p = VAPColorParameters.bt601Full
        let yuv = SIMD3<Float>(0.0, 0.5, 0.5)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x) < 0.02)
        #expect(abs(rgb.y) < 0.02)
        #expect(abs(rgb.z) < 0.02)
    }

    @Test func bt709FullWhite() {
        let p = VAPColorParameters.bt709Full
        let yuv = SIMD3<Float>(1.0, 0.5, 0.5)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x - 1.0) < 0.02)
        #expect(abs(rgb.y - 1.0) < 0.02)
        #expect(abs(rgb.z - 1.0) < 0.02)
    }

    @Test func bt709FullBlack() {
        let p = VAPColorParameters.bt709Full
        let yuv = SIMD3<Float>(0.0, 0.5, 0.5)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x) < 0.02)
        #expect(abs(rgb.y) < 0.02)
        #expect(abs(rgb.z) < 0.02)
    }

    @Test func bt601LimitedWhite() {
        // Y=235/255, Cb=128/255, Cr=128/255 -> 白色。
        let p = VAPColorParameters.bt601
        let yuv = SIMD3<Float>(235.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x - 1.0) < 0.05)
        #expect(abs(rgb.y - 1.0) < 0.05)
        #expect(abs(rgb.z - 1.0) < 0.05)
    }

    @Test func bt601LimitedBlack() {
        // Y=16/255, Cb=128/255, Cr=128/255 -> 黑色。
        let p = VAPColorParameters.bt601
        let yuv = SIMD3<Float>(16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x) < 0.05)
        #expect(abs(rgb.y) < 0.05)
        #expect(abs(rgb.z) < 0.05)
    }

    @Test func bt709LimitedWhite() {
        let p = VAPColorParameters.bt709
        let yuv = SIMD3<Float>(235.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x - 1.0) < 0.05)
        #expect(abs(rgb.y - 1.0) < 0.05)
        #expect(abs(rgb.z - 1.0) < 0.05)
    }

    // MARK: - E. 回归：aspectFit 必须使用 RGB 尺寸，而不是完整视频尺寸

    @Test @MainActor func aspectFitUsesRGBSizeNotFullVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.renderContentMode = .aspectFit

        let fullSize = CGSize(width: 1920, height: 1080)
        let rgbSize = rgbContentSize(alphaPlacement: .right, videoWidth: 1920, videoHeight: 1080)

        let wrongRect = view.vertexRect(videoSize: fullSize)
        let correctRect = view.vertexRect(videoSize: rgbSize)

        // 二者必须不同：fullSize 是 16:9，rgbSize 是 8:9。
        #expect(wrongRect != correctRect)

        // rgbSize 为 960x1080（接近竖屏），在正方形视图中 aspectFit 应该变窄。
        #expect(correctRect.width < 2.0)
        #expect(abs(correctRect.height - 2.0) < 0.001)
    }

    @Test @MainActor func aspectFillUsesRGBSizeNotFullVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.renderContentMode = .aspectFill

        let fullSize = CGSize(width: 1920, height: 1080)
        let rgbSize = rgbContentSize(alphaPlacement: .right, videoWidth: 1920, videoHeight: 1080)

        let wrongRect = view.vertexRect(videoSize: fullSize)
        let correctRect = view.vertexRect(videoSize: rgbSize)

        #expect(wrongRect != correctRect)

        // rgbSize 为 960x1080（接近竖屏且更高），在正方形视图中 aspectFill 应该让高度溢出。
        #expect(abs(correctRect.width - 2.0) < 0.001)
        #expect(correctRect.height > 2.0)
    }

    // MARK: - F. 自定义帧区域（vapc 中的 rgbFrame/aFrame）

    @Test func vapcCommonInfoDecodesFrameRegions() throws {
        let json = """
        {"v":2,"f":356,"w":750,"h":1334,"fps":30,"videoW":1136,"videoH":1344,
         "aFrame":[754,0,375,667],"rgbFrame":[0,0,750,1334],"orien":0}
        """
        let info = try JSONDecoder().decode(VAPCommonInfo.self, from: json.data(using: .utf8)!)
        #expect(info.rgbFrame == [0, 0, 750, 1334])
        #expect(info.aFrame == [754, 0, 375, 667])
        let rgb = info.rgbRect!
        #expect(rgb == CGRect(x: 0, y: 0, width: 750, height: 1334))
        let alpha = info.alphaRect!
        #expect(alpha == CGRect(x: 754, y: 0, width: 375, height: 667))
    }

    @Test func vapcCommonInfoMissingFrameRegions() throws {
        let json = """
        {"v":2,"f":100,"w":750,"h":1334,"fps":30,"videoW":1500,"videoH":1334,"orien":0}
        """
        let info = try JSONDecoder().decode(VAPCommonInfo.self, from: json.data(using: .utf8)!)
        #expect(info.rgbFrame == nil)
        #expect(info.aFrame == nil)
        #expect(info.rgbRect == nil)
        #expect(info.alphaRect == nil)
    }

    @Test @MainActor func makeFullQuadWithCustomFrameRegions() throws {
        // 模拟真实 MP4：videoW=1136，videoH=1344。
        // rgbFrame=[0,0,750,1334]，aFrame=[754,0,375,667]。
        let device = MTLCreateSystemDefaultDevice()!
        let renderer = try VAPRenderer(device: device)

        let viewRect = CGRect(x: -1, y: -1, width: 2, height: 2)
        let rgbRect = CGRect(x: 0, y: 0, width: 750, height: 1334)
        let alphaRect = CGRect(x: 754, y: 0, width: 375, height: 667)
        let videoW: CGFloat = 1136
        let videoH: CGFloat = 1344

        let verts = renderer.makeFullQuad(viewRect: viewRect,
                                          rgbRect: rgbRect,
                                          alphaRect: alphaRect,
                                          videoWidth: videoW,
                                          videoHeight: videoH)
        #expect(verts.count == 4)

        // 预期归一化 RGB 坐标：(0/1136, 0/1344) 到 (750/1136, 1334/1344)。
        let rgbTLx = Float(0.0 / 1136.0)
        let rgbTLy = Float(0.0 / 1344.0)
        let rgbBRx = Float(750.0 / 1136.0)
        let rgbBRy = Float(1334.0 / 1344.0)

        // 预期归一化 Alpha 坐标：(754/1136, 0/1344) 到 (1129/1136, 667/1344)。
        let aTLx = Float(754.0 / 1136.0)
        let aTLy = Float(0.0 / 1344.0)
        let aBRx = Float(1129.0 / 1136.0)
        let aBRy = Float(667.0 / 1344.0)

        // 顶点 0（TL）：rgb=(rgbTL.x, rgbTL.y)，alpha=(aTL.x, aTL.y)。
        #expect(abs(verts[0].texCoord.x - rgbTLx) < 0.001)
        #expect(abs(verts[0].texCoord.y - rgbTLy) < 0.001)
        #expect(abs(verts[0].alphaTexCoord.x - aTLx) < 0.001)
        #expect(abs(verts[0].alphaTexCoord.y - aTLy) < 0.001)

        // 顶点 3（BR）：rgb=(rgbBR.x, rgbBR.y)，alpha=(aBR.x, aBR.y)。
        #expect(abs(verts[3].texCoord.x - rgbBRx) < 0.001)
        #expect(abs(verts[3].texCoord.y - rgbBRy) < 0.001)
        #expect(abs(verts[3].alphaTexCoord.x - aBRx) < 0.001)
        #expect(abs(verts[3].alphaTexCoord.y - aBRy) < 0.001)

        // RGB 不应是简单的 50% 分割。
        #expect(rgbBRx != 0.5, "RGB should not be a simple 50% split for this video")
    }

    @Test @MainActor func customFrameRegionsDifferFromAlphaPlacementSplit() throws {
        // 验证自定义帧区域与旧的 alpha placement 分割会得到不同结果。
        let device = MTLCreateSystemDefaultDevice()!
        let renderer = try VAPRenderer(device: device)
        let viewRect = CGRect(x: -1, y: -1, width: 2, height: 2)

        let alphaPlacementVerts = renderer.makeFullQuad(viewRect: viewRect, alphaPlacement: .right)
        let customVerts = renderer.makeFullQuad(viewRect: viewRect,
                                                rgbRect: CGRect(x: 0, y: 0, width: 750, height: 1334),
                                                alphaRect: CGRect(x: 754, y: 0, width: 375, height: 667),
                                                videoWidth: 1136, videoHeight: 1344)

        // 二者必须不同；旧分割假设 50/50，对于这个视频并不正确。
        // 比较具有最大 UV 坐标的 BR 顶点（索引 3）。
        #expect(alphaPlacementVerts[3].texCoord != customVerts[3].texCoord)
        #expect(alphaPlacementVerts[3].alphaTexCoord != customVerts[3].alphaTexCoord)
    }

    @Test @MainActor func scaleToFillUnaffectedByBug() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.renderContentMode = .scaleToFill

        let fullSize = CGSize(width: 1920, height: 1080)
        let rgbSize = rgbContentSize(alphaPlacement: .right, videoWidth: 1920, videoHeight: 1080)

        let rectFull = view.vertexRect(videoSize: fullSize)
        let rectRGB = view.vertexRect(videoSize: rgbSize)

        // 无论视频尺寸如何，scaleToFill 都返回同一个矩形。
        #expect(rectFull == rectRGB)
        #expect(rectFull == CGRect(x: -1, y: -1, width: 2, height: 2))
    }
}
