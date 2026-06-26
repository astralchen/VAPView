// VAPMP4Box.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

// MARK: - 采样

struct VAPMP4Sample: Sendable {
    let index: Int
    let presentationIndex: Int
    let offset: UInt64
    let size: UInt32
    let pts: Double
    let dts: Double
    let isKeySample: Bool
}

// MARK: - 编码参数结构体

struct VAPAvcCData: Sendable {
    var sps: [Data] = []
    var pps: [Data] = []
}

struct VAPHvcCData: Sendable {
    var rawData: Data = Data()
    var vps: Data?
    var sps: Data?
    var pps: Data?
}

// MARK: - Box 载荷

enum VAPMP4Payload: Sendable {
    case container
    case mvhd(timeScale: UInt32, duration: UInt64)
    case mdhd(timeScale: UInt32, duration: UInt64, language: String)
    case hdlr(handlerType: String)
    case stts(entries: [SttsEntry])
    case ctts(entries: [CttsEntry])
    case stsc(entries: [StscEntry])
    case stco(offsets: [UInt32])
    case co64(offsets: [UInt64])
    case stsz(defaultSize: UInt32, sizes: [UInt32])
    case stss(sampleNumbers: [UInt32])
    case avcC(VAPAvcCData)
    case hvcC(VAPHvcCData)
    case vapc(jsonData: Data)
    case visualEntry(width: Int, height: Int)  // avc1/hvc1 VisualSampleEntry 尺寸
    case audio
    case unknown

    struct SttsEntry: Sendable { var count: UInt32; var delta: UInt32 }
    struct CttsEntry: Sendable { var count: UInt32; var offset: Int32 }
    struct StscEntry: Sendable { var firstChunk: UInt32; var samplesPerChunk: UInt32; var descIndex: UInt32 }
}
// MARK: - Box 节点

struct VAPMP4Box: Sendable {
    let type: String
    let payload: VAPMP4Payload
    var children: [VAPMP4Box]

    init(type: String, payload: VAPMP4Payload = .container, children: [VAPMP4Box] = []) {
        self.type = type
        self.payload = payload
        self.children = children
    }

    func firstChild(type: String) -> VAPMP4Box? {
        children.first { $0.type == type }
    }

    func allChildren(type: String) -> [VAPMP4Box] {
        children.filter { $0.type == type }
    }

    func bfsFirst(type: String) -> VAPMP4Box? {
        var queue = children
        while !queue.isEmpty {
            let cur = queue.removeFirst()
            if cur.type == type { return cur }
            queue.append(contentsOf: cur.children)
        }
        return nil
    }
}
