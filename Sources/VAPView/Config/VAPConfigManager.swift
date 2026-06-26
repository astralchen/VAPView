// VAPConfigManager.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT
//
// 解析 vapc JSON 并加载挂件纹理。

import Foundation
import Metal
import UIKit

struct VAPAttachmentResources: @unchecked Sendable {
    let config: VAPConfig
    /// 图片/文本挂件的 srcId -> MTLTexture 映射。
    let textures: [String: MTLTexture]
    /// 从视频 Alpha 区域生成的蒙版纹理（仅 HWD 播放时为 nil）。
    let maskTexture: MTLTexture?
}

final class VAPConfigManager {

    private let device: MTLDevice
    private let imageLoader: VAPAttachmentImageLoader?

    init(device: MTLDevice, imageLoader: VAPAttachmentImageLoader?) {
        self.device      = device
        self.imageLoader = imageLoader
    }

    // MARK: - 加载

    func load(vapcJSON: Data,
              sources: [String: VAPAttachmentSource]) async throws -> VAPAttachmentResources {
        let config = try JSONDecoder().decode(VAPConfig.self, from: vapcJSON)
        var textures: [String: MTLTexture] = [:]

        for sourceInfo in config.src ?? [] {
            let sourceType = sourceInfo.attachmentSourceType
            switch sourceType {
            case .image, .imageURL:
                let context = VAPAttachmentImageContext(
                    sourceID: sourceInfo.srcId,
                    contentMode: sourceInfo.attachmentFitType.publicContentMode,
                    targetSize: sourceInfo.w.flatMap { w in sourceInfo.h.map { h in CGSize(width: w, height: h) } },
                    loadLocation: sourceInfo.attachmentLoadType?.publicLocation)
                switch sources[sourceInfo.srcId] {
                case .image(let image):
                    if let texture = makeTexture(from: image) {
                        textures[sourceInfo.srcId] = texture
                    }
                case .imageURL(let urlString):
                    // [M4] 只允许 https/http/file scheme，防止 SSRF 类攻击
                    guard let url = URL(string: urlString),
                          ["https", "http", "file"].contains(url.scheme?.lowercased() ?? "") else {
                        break
                    }
                    // [BUG-C2] imageLoader 为 nil 时明确报错，避免纹理缺失却无任何提示
                    guard let loader = imageLoader else {
                        throw VAPError.unknown("imageLoader is required for .imageURL attachment (sourceID: \(sourceInfo.srcId))")
                    }
                    let image = try await loader(url, context)
                    if let texture = makeTexture(from: image) {
                        textures[sourceInfo.srcId] = texture
                    }
                case .text, nil:
                    break
                }
            case .text, .textString:
                let text: String
                switch sources[sourceInfo.srcId] {
                case .text(let t): text = t
                case .imageURL(let s):  text = s
                default:           text = ""
                }
                let size = CGSize(width: sourceInfo.w ?? 100, height: sourceInfo.h ?? 40)
                let color = parseHexColor(sourceInfo.txtColor) ?? .white
                let fontSize = sourceInfo.txtFontSize ?? 14
                let image = await MainActor.run {
                    Self.renderTextImage(text: text, size: size, color: color, fontSize: fontSize)
                }
                if let texture = makeTexture(from: image) {
                    textures[sourceInfo.srcId] = texture
                }
            case nil:
                break
            }
        }

        return VAPAttachmentResources(config: config, textures: textures, maskTexture: nil)
    }

    // MARK: - 从 UIImage 创建纹理

    private func makeTexture(from image: UIImage) -> MTLTexture? {
        guard let cgImage = image.cgImage else { return nil }
        let width  = cgImage.width
        let height = cgImage.height
        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: width, height: height, mipmapped: false)
        desc.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: desc) else { return nil }
        let region = MTLRegionMake2D(0, 0, width, height)
        let bytesPerRow = 4 * width
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: &bytes,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: bytesPerRow,
                                      space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            return nil
        }
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
        texture.replace(region: region, mipmapLevel: 0, withBytes: &bytes, bytesPerRow: bytesPerRow)
        return texture
    }

    // MARK: - 文本渲染

    @MainActor
    private static func renderTextImage(text: String, size: CGSize,
                                         color: UIColor, fontSize: CGFloat) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { context in
            let attributes: [NSAttributedString.Key: Any] = [
                .foregroundColor: color,
                .font: UIFont.systemFont(ofSize: fontSize)
            ]
            let renderedText = text as NSString
            let textSize = renderedText.size(withAttributes: attributes)
            let origin = CGPoint(x: (size.width - textSize.width) / 2,
                                 y: (size.height - textSize.height) / 2)
            renderedText.draw(at: origin, withAttributes: attributes)
        }
    }

    // MARK: - 十六进制颜色

    private func parseHexColor(_ hex: String?) -> UIColor? {
        guard var hex = hex else { return nil }
        hex = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex = String(hex.dropFirst()) }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        if hex.count == 6 {
            let r = CGFloat((value >> 16) & 0xFF) / 255
            let g = CGFloat((value >>  8) & 0xFF) / 255
            let b = CGFloat( value        & 0xFF) / 255
            return UIColor(red: r, green: g, blue: b, alpha: 1)
        } else {
            let r = CGFloat((value >> 24) & 0xFF) / 255
            let g = CGFloat((value >> 16) & 0xFF) / 255
            let b = CGFloat((value >>  8) & 0xFF) / 255
            let a = CGFloat( value        & 0xFF) / 255
            return UIColor(red: r, green: g, blue: b, alpha: a)
        }
    }
}
