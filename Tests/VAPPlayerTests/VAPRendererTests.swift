// VAPRendererTests.swift
import Testing
import Foundation
import UIKit
import simd
@testable import VAPPlayer

@Suite("VAPRenderer")
struct VAPRendererTests {

    // MARK: - A. RGB Size Computation

    @Test @MainActor func rgbSizeAlphaRight() {
        let size = VAPRenderer.rgbSize(blendMode: .alphaRight, videoWidth: 1920, videoHeight: 1080)
        #expect(size == CGSize(width: 960, height: 1080))
    }

    @Test @MainActor func rgbSizeAlphaLeft() {
        let size = VAPRenderer.rgbSize(blendMode: .alphaLeft, videoWidth: 1920, videoHeight: 1080)
        #expect(size == CGSize(width: 960, height: 1080))
    }

    @Test @MainActor func rgbSizeAlphaBottom() {
        let size = VAPRenderer.rgbSize(blendMode: .alphaBottom, videoWidth: 960, videoHeight: 1080)
        #expect(size == CGSize(width: 960, height: 540))
    }

    @Test @MainActor func rgbSizeAlphaTop() {
        let size = VAPRenderer.rgbSize(blendMode: .alphaTop, videoWidth: 960, videoHeight: 1080)
        #expect(size == CGSize(width: 960, height: 540))
    }

    // HWD renderer should agree
    @Test @MainActor func hwdRgbSizeMatchesVAPRenderer() {
        for mode in [VAPTextureBlendMode.alphaLeft, .alphaRight, .alphaTop, .alphaBottom] {
            let vap = VAPRenderer.rgbSize(blendMode: mode, videoWidth: 1920, videoHeight: 1080)
            let hwd = VAPHWDRenderer.rgbSize(blendMode: mode, videoWidth: 1920, videoHeight: 1080)
            #expect(vap == hwd, "rgbSize mismatch for \(mode)")
        }
    }

    // MARK: - B. Vertex Rect

    @Test @MainActor func vertexRectScaleToFill() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.vapContentMode = .scaleToFill
        let rect = view.vertexRect(videoSize: CGSize(width: 1920, height: 1080))
        #expect(rect == CGRect(x: -1, y: -1, width: 2, height: 2))
    }

    @Test @MainActor func vertexRectAspectFitWiderVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.vapContentMode = .aspectFit
        // 16:9 video in square view: should be letterboxed (height < 2)
        let rect = view.vertexRect(videoSize: CGSize(width: 1920, height: 1080))
        #expect(rect.width == 2.0)
        #expect(rect.height < 2.0)
    }

    @Test @MainActor func vertexRectAspectFitTallerVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.vapContentMode = .aspectFit
        // 9:16 video in square view: should be pillarboxed (width < 2)
        let rect = view.vertexRect(videoSize: CGSize(width: 1080, height: 1920))
        #expect(rect.width < 2.0)
        #expect(rect.height == 2.0)
    }

    @Test @MainActor func vertexRectAspectFillWiderVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.vapContentMode = .aspectFill
        // 16:9 video in square view: width exceeds 2 to fill, height stays 2
        let rect = view.vertexRect(videoSize: CGSize(width: 1920, height: 1080))
        #expect(rect.width > 2.0)
        #expect(abs(rect.height - 2.0) < 0.001)
    }

    @Test @MainActor func vertexRectZeroBounds() {
        let view = VAPMetalView(frame: .zero)
        let rect = view.vertexRect(videoSize: CGSize(width: 100, height: 100))
        #expect(rect == CGRect(x: -1, y: -1, width: 2, height: 2))
    }

    // MARK: - C. Texture Coordinate Splitting (HWD texCoords)

    @Test @MainActor func texCoordsAlphaRight() {
        let (rgbTL, rgbBR, alphaTL, alphaBR) = VAPHWDRenderer.texCoords(blendMode: .alphaRight)
        // RGB: left half, Alpha: right half
        #expect(rgbTL   == SIMD2<Float>(0, 0))
        #expect(rgbBR   == SIMD2<Float>(0.5, 1))
        #expect(alphaTL == SIMD2<Float>(0.5, 0))
        #expect(alphaBR == SIMD2<Float>(1, 1))
    }

    @Test @MainActor func texCoordsAlphaLeft() {
        let (rgbTL, rgbBR, alphaTL, alphaBR) = VAPHWDRenderer.texCoords(blendMode: .alphaLeft)
        // RGB: right half, Alpha: left half
        #expect(rgbTL   == SIMD2<Float>(0.5, 0))
        #expect(rgbBR   == SIMD2<Float>(1, 1))
        #expect(alphaTL == SIMD2<Float>(0, 0))
        #expect(alphaBR == SIMD2<Float>(0.5, 1))
    }

    @Test @MainActor func texCoordsAlphaBottom() {
        let (rgbTL, rgbBR, alphaTL, alphaBR) = VAPHWDRenderer.texCoords(blendMode: .alphaBottom)
        // RGB: top half, Alpha: bottom half
        #expect(rgbTL   == SIMD2<Float>(0, 0))
        #expect(rgbBR   == SIMD2<Float>(1, 0.5))
        #expect(alphaTL == SIMD2<Float>(0, 0.5))
        #expect(alphaBR == SIMD2<Float>(1, 1))
    }

    @Test @MainActor func texCoordsAlphaTop() {
        let (rgbTL, rgbBR, alphaTL, alphaBR) = VAPHWDRenderer.texCoords(blendMode: .alphaTop)
        // RGB: bottom half, Alpha: top half
        #expect(rgbTL   == SIMD2<Float>(0, 0.5))
        #expect(rgbBR   == SIMD2<Float>(1, 1))
        #expect(alphaTL == SIMD2<Float>(0, 0))
        #expect(alphaBR == SIMD2<Float>(1, 0.5))
    }

    // MARK: - D. Color Matrix Verification

    @Test func bt601FullWhite() {
        // Y=1.0, Cb=0.5, Cr=0.5 → white (1, 1, 1)
        let p = VAPColorParameters.bt601Full
        let yuv = SIMD3<Float>(1.0, 0.5, 0.5)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x - 1.0) < 0.02)
        #expect(abs(rgb.y - 1.0) < 0.02)
        #expect(abs(rgb.z - 1.0) < 0.02)
    }

    @Test func bt601FullBlack() {
        // Y=0.0, Cb=0.5, Cr=0.5 → black (0, 0, 0)
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
        // Y=235/255, Cb=128/255, Cr=128/255 → white
        let p = VAPColorParameters.bt601
        let yuv = SIMD3<Float>(235.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0)
        let rgb = p.colorMatrix * yuv + p.colorOffset
        #expect(abs(rgb.x - 1.0) < 0.05)
        #expect(abs(rgb.y - 1.0) < 0.05)
        #expect(abs(rgb.z - 1.0) < 0.05)
    }

    @Test func bt601LimitedBlack() {
        // Y=16/255, Cb=128/255, Cr=128/255 → black
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

    // MARK: - E. Regression: aspectFit must use RGB size, not full video size

    @Test @MainActor func aspectFitUsesRGBSizeNotFullVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.vapContentMode = .aspectFit

        let fullSize = CGSize(width: 1920, height: 1080)
        let rgbSize = VAPRenderer.rgbSize(blendMode: .alphaRight, videoWidth: 1920, videoHeight: 1080)

        let wrongRect = view.vertexRect(videoSize: fullSize)
        let correctRect = view.vertexRect(videoSize: rgbSize)

        // They must differ: fullSize is 16:9, rgbSize is 8:9
        #expect(wrongRect != correctRect)

        // rgbSize is 960x1080 (portrait-ish), in square view aspectFit should be narrow
        #expect(correctRect.width < 2.0)
        #expect(abs(correctRect.height - 2.0) < 0.001)
    }

    @Test @MainActor func aspectFillUsesRGBSizeNotFullVideo() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.vapContentMode = .aspectFill

        let fullSize = CGSize(width: 1920, height: 1080)
        let rgbSize = VAPRenderer.rgbSize(blendMode: .alphaRight, videoWidth: 1920, videoHeight: 1080)

        let wrongRect = view.vertexRect(videoSize: fullSize)
        let correctRect = view.vertexRect(videoSize: rgbSize)

        #expect(wrongRect != correctRect)

        // rgbSize is 960x1080 (portrait-ish / taller), in square view aspectFill should overflow height
        #expect(abs(correctRect.width - 2.0) < 0.001)
        #expect(correctRect.height > 2.0)
    }

    // MARK: - F. Custom frame regions (rgbFrame/aFrame from vapc)

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
        // Simulate the real MP4: videoW=1136, videoH=1344
        // rgbFrame=[0,0,750,1334], aFrame=[754,0,375,667]
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

        // Expected normalized RGB coords: (0/1136, 0/1344) to (750/1136, 1334/1344)
        let rgbTLx = Float(0.0 / 1136.0)
        let rgbTLy = Float(0.0 / 1344.0)
        let rgbBRx = Float(750.0 / 1136.0)
        let rgbBRy = Float(1334.0 / 1344.0)

        // Expected normalized alpha coords: (754/1136, 0/1344) to (1129/1136, 667/1344)
        let aTLx = Float(754.0 / 1136.0)
        let aTLy = Float(0.0 / 1344.0)
        let aBRx = Float(1129.0 / 1136.0)
        let aBRy = Float(667.0 / 1344.0)

        // Vertex 0 (TL): rgb=(rgbTL.x, rgbTL.y), alpha=(aTL.x, aTL.y)
        #expect(abs(verts[0].texCoord.x - rgbTLx) < 0.001)
        #expect(abs(verts[0].texCoord.y - rgbTLy) < 0.001)
        #expect(abs(verts[0].alphaTexCoord.x - aTLx) < 0.001)
        #expect(abs(verts[0].alphaTexCoord.y - aTLy) < 0.001)

        // Vertex 3 (BR): rgb=(rgbBR.x, rgbBR.y), alpha=(aBR.x, aBR.y)
        #expect(abs(verts[3].texCoord.x - rgbBRx) < 0.001)
        #expect(abs(verts[3].texCoord.y - rgbBRy) < 0.001)
        #expect(abs(verts[3].alphaTexCoord.x - aBRx) < 0.001)
        #expect(abs(verts[3].alphaTexCoord.y - aBRy) < 0.001)

        // RGB should NOT be a simple 50% split
        #expect(rgbBRx != 0.5, "RGB should not be a simple 50% split for this video")
    }

    @Test @MainActor func customFrameRegionsDifferFromBlendModeSplit() throws {
        // Verify that the custom frame region gives different results than the old blend mode split
        let device = MTLCreateSystemDefaultDevice()!
        let renderer = try VAPRenderer(device: device)
        let viewRect = CGRect(x: -1, y: -1, width: 2, height: 2)

        let blendModeVerts = renderer.makeFullQuad(viewRect: viewRect, blendMode: .alphaRight)
        let customVerts = renderer.makeFullQuad(viewRect: viewRect,
                                                rgbRect: CGRect(x: 0, y: 0, width: 750, height: 1334),
                                                alphaRect: CGRect(x: 754, y: 0, width: 375, height: 667),
                                                videoWidth: 1136, videoHeight: 1344)

        // They must differ — the old split assumes 50/50 which is wrong for this video
        // Compare BR vertex (index 3) which has the max UV coords
        #expect(blendModeVerts[3].texCoord != customVerts[3].texCoord)
        #expect(blendModeVerts[3].alphaTexCoord != customVerts[3].alphaTexCoord)
    }

    @Test @MainActor func scaleToFillUnaffectedByBug() {
        let view = VAPMetalView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        view.vapContentMode = .scaleToFill

        let fullSize = CGSize(width: 1920, height: 1080)
        let rgbSize = VAPRenderer.rgbSize(blendMode: .alphaRight, videoWidth: 1920, videoHeight: 1080)

        let rectFull = view.vertexRect(videoSize: fullSize)
        let rectRGB = view.vertexRect(videoSize: rgbSize)

        // scaleToFill always returns the same rect regardless of video size
        #expect(rectFull == rectRGB)
        #expect(rectFull == CGRect(x: -1, y: -1, width: 2, height: 2))
    }
}
