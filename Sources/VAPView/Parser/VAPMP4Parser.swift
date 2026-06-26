// VAPMP4Parser.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

// MARK: - Video codec

enum VAPVideoCodec: Sendable {
    case h264
    case h265
}

// MARK: - Parse result

struct VAPMP4Info: Sendable {
    let codec: VAPVideoCodec
    let width: Int
    let height: Int
    let fps: Int
    let duration: Double
    let videoSamples: [VAPMP4Sample]
    let avcC: VAPAvcCData?
    let hvcC: VAPHvcCData?
    let vapcJSON: Data?
    let hasAudioTrack: Bool
    let localFilePath: String

    var frameCount: Int { videoSamples.count }
}

// MARK: - Parser

struct VAPMP4Parser {

    // MARK: - 安全限制常量
    private static let kMaxBoxDepth    = 16          // 防止无限递归
    private static let kMaxBoxReadSize: UInt64 = 64 * 1_024 * 1_024  // 64 MB，防止巨型 box 分配
    private static let kMaxSampleCount = 100_000     // 防止无界 sampleOffsets 分配
    private static let kMaxTableEntries = 100_000    // stts/ctts/stsc/stco/stsz/stss 条目上限

    static func parse(localFilePath: String) throws -> VAPMP4Info {
        guard FileManager.default.fileExists(atPath: localFilePath) else {
            throw VAPError.fileNotFound(localFilePath)
        }
        guard let handle = FileHandle(forReadingAtPath: localFilePath) else {
            throw VAPError.invalidMP4File
        }
        defer { try? handle.close() }

        let root = try parseBoxes(handle: handle, offset: 0, length: nil)
        guard let moov = root.first(where: { $0.type == "moov" }) else {
            throw VAPError.invalidMP4File
        }
        // vapc — may be inside moov or at the top level (sibling of moov)
        var vapcJSON: Data?
        if let vapc = moov.bfsFirst(type: "vapc"),
           case .vapc(let jsonData) = vapc.payload {
            vapcJSON = jsonData
        } else if let vapc = root.first(where: { $0.type == "vapc" }),
                  case .vapc(let jsonData) = vapc.payload {
            vapcJSON = jsonData
            parserLog.debug("vapc found at top level (outside moov)")
        }

        let hasAudio = hasAudioTrack(in: moov)

        guard let videoTrak = findVideoTrak(in: moov) else {
            throw VAPError.streamUnavailable
        }

        let (codec, avcC, hvcC) = videoCodecInfo(trak: videoTrak)
        let (width, height) = videoDimensions(trak: videoTrak)

        var timeScale: Double = 1
        var mediaDuration: Double = 0
        if let mdhd = videoTrak.bfsFirst(type: "mdhd"),
           case .mdhd(let ts, let dur, _) = mdhd.payload {
            timeScale = Double(ts)
            mediaDuration = Double(dur)
        }
        let duration = timeScale > 0 ? mediaDuration / timeScale : 0

        let samples = try buildSamples(trak: videoTrak, timeScale: timeScale)
        let fps = computeFPS(samples: samples, duration: duration)

        return VAPMP4Info(
            codec: codec, width: width, height: height, fps: fps, duration: duration,
            videoSamples: samples, avcC: avcC, hvcC: hvcC,
            vapcJSON: vapcJSON, hasAudioTrack: hasAudio, localFilePath: localFilePath
        )
    }

    // MARK: - Box tree parsing

    static func parseBoxes(handle: FileHandle, offset: UInt64, length: UInt64?,
                                    depth: Int = 0) throws -> [VAPMP4Box] {
        // [M2] 限制递归深度，防止畸形 MP4 触发栈溢出
        guard depth < kMaxBoxDepth else { return [] }
        var boxes: [VAPMP4Box] = []
        var pos = offset
        let end: UInt64 = length.map { offset + $0 } ?? UInt64.max
        while pos < end {
            try handle.seek(toOffset: pos)
            guard let header = try? handle.read(upToCount: 8), header.count == 8 else { break }
            var boxSize = UInt64(readU32BE(header, offset: 0))
            let typeName = String(bytes: header[4..<8], encoding: .isoLatin1) ?? "????"
            var headerSize: UInt64 = 8
            if boxSize == 1 {
                guard let ext = try? handle.read(upToCount: 8), ext.count == 8 else { break }
                boxSize = readU64BE(ext, offset: 0)
                headerSize = 16
            } else if boxSize == 0 {
                let fileSize = (try? handle.seekToEnd()) ?? pos
                boxSize = fileSize - pos
                try handle.seek(toOffset: pos + headerSize)
            }
            if boxSize < headerSize { break }
            let bodySize = boxSize - headerSize
            let bodyOffset = pos + headerSize
            let box = try parseBox(type: typeName, handle: handle, bodyOffset: bodyOffset,
                                   bodySize: bodySize, depth: depth)
            boxes.append(box)
            // [H1] 防止 pos += boxSize 整数溢出
            let (newPos, overflow) = pos.addingReportingOverflow(boxSize)
            if overflow { break }
            pos = newPos
        }
        return boxes
    }

    private static func parseBox(type: String, handle: FileHandle,
                                  bodyOffset: UInt64, bodySize: UInt64,
                                  depth: Int = 0) throws -> VAPMP4Box {
        switch type {
        case "moov", "trak", "mdia", "minf", "stbl", "dinf", "edts", "udta":
            // [M2] 传递 depth+1 防止无限递归
            let children = try parseBoxes(handle: handle, offset: bodyOffset, length: bodySize, depth: depth + 1)
            return VAPMP4Box(type: type, payload: .container, children: children)
        case "stsd":
            let children = try parseBoxes(handle: handle, offset: bodyOffset + 8, length: bodySize > 8 ? bodySize - 8 : 0, depth: depth + 1)
            return VAPMP4Box(type: type, payload: .container, children: children)
        case "avc1", "hvc1", "hev1", "mp4v":
            // VisualSampleEntry: width at body+24 (2 bytes BE), height at body+26 (2 bytes BE)
            // ObjC reads at box.startIndex+32/34 (8-byte header + 24/26 body offset)
            try? handle.seek(toOffset: bodyOffset)
            let vseData = (try? handle.read(upToCount: 28)) ?? Data()
            let w = vseData.count >= 26 ? Int(readU16BE(vseData, offset: 24)) : 0
            let h = vseData.count >= 28 ? Int(readU16BE(vseData, offset: 26)) : 0
            let children = try parseBoxes(handle: handle, offset: bodyOffset + 78, length: bodySize > 78 ? bodySize - 78 : 0, depth: depth + 1)
            return VAPMP4Box(type: type, payload: .visualEntry(width: w, height: h), children: children)
        case "mvhd": return try VAPMP4Box(type: type, payload: parseMvhd(handle: handle, offset: bodyOffset))
        case "mdhd": return try VAPMP4Box(type: type, payload: parseMdhd(handle: handle, offset: bodyOffset))
        case "hdlr": return VAPMP4Box(type: type, payload: parseHdlr(handle: handle, offset: bodyOffset))
        case "stts": return VAPMP4Box(type: type, payload: parseStts(handle: handle, offset: bodyOffset))
        case "ctts": return VAPMP4Box(type: type, payload: parseCtts(handle: handle, offset: bodyOffset))
        case "stsc": return VAPMP4Box(type: type, payload: parseStsc(handle: handle, offset: bodyOffset))
        case "stco": return VAPMP4Box(type: type, payload: parseStco(handle: handle, offset: bodyOffset))
        case "co64": return VAPMP4Box(type: type, payload: parseCo64(handle: handle, offset: bodyOffset))
        case "stsz": return VAPMP4Box(type: type, payload: parseStsz(handle: handle, offset: bodyOffset))
        case "stss": return VAPMP4Box(type: type, payload: parseStss(handle: handle, offset: bodyOffset))
        case "avcC": return VAPMP4Box(type: type, payload: parseAvcC(handle: handle, offset: bodyOffset, size: bodySize))
        case "hvcC": return VAPMP4Box(type: type, payload: parseHvcC(handle: handle, offset: bodyOffset, size: bodySize))
        case "vapc": return VAPMP4Box(type: type, payload: parseVapc(handle: handle, offset: bodyOffset, size: bodySize))
        case "mp4a", "sowt", "twos", "lpcm": return VAPMP4Box(type: type, payload: .audio)
        default: return VAPMP4Box(type: type, payload: .unknown)
        }
    }

    // MARK: - Leaf box parsers

    private static func parseMvhd(handle: FileHandle, offset: UInt64) throws -> VAPMP4Payload {
        try handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: 32), data.count >= 20 else { return .unknown }
        let version = data[0]
        if version == 1 {
            return .mvhd(timeScale: readU32BE(data, offset: 20), duration: readU64BE(data, offset: 24))
        } else {
            return .mvhd(timeScale: readU32BE(data, offset: 12), duration: UInt64(readU32BE(data, offset: 16)))
        }
    }

    private static func parseMdhd(handle: FileHandle, offset: UInt64) throws -> VAPMP4Payload {
        try handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: 36), data.count >= 20 else { return .unknown }
        let version = data[0]
        if version == 1 {
            return .mdhd(timeScale: readU32BE(data, offset: 20), duration: readU64BE(data, offset: 24), language: "")
        } else {
            return .mdhd(timeScale: readU32BE(data, offset: 12), duration: UInt64(readU32BE(data, offset: 16)), language: "")
        }
    }

    private static func parseHdlr(handle: FileHandle, offset: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.read(upToCount: 12), data.count >= 12 else { return .unknown }
        let handlerType = String(bytes: data[8..<12], encoding: .isoLatin1) ?? ""
        return .hdlr(handlerType: handlerType)
    }

    private static func parseStts(handle: FileHandle, offset: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        guard let hdr = try? handle.read(upToCount: 8), hdr.count == 8 else { return .stts(entries: []) }
        let count = Int(readU32BE(hdr, offset: 4))
        // [H3] 防止无界内存分配
        guard count > 0, count <= kMaxTableEntries else { return .stts(entries: []) }
        guard let body = try? handle.read(upToCount: count * 8), body.count == count * 8 else { return .stts(entries: []) }
        let entries = (0..<count).map { VAPMP4Payload.SttsEntry(count: readU32BE(body, offset: $0*8), delta: readU32BE(body, offset: $0*8+4)) }
        return .stts(entries: entries)
    }

    private static func parseCtts(handle: FileHandle, offset: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        guard let hdr = try? handle.read(upToCount: 8), hdr.count == 8 else { return .ctts(entries: []) }
        let count = Int(readU32BE(hdr, offset: 4))
        // [H3] 防止无界内存分配
        guard count > 0, count <= kMaxTableEntries else { return .ctts(entries: []) }
        guard let body = try? handle.read(upToCount: count * 8), body.count == count * 8 else { return .ctts(entries: []) }
        let entries = (0..<count).map { VAPMP4Payload.CttsEntry(count: readU32BE(body, offset: $0*8), offset: Int32(bitPattern: readU32BE(body, offset: $0*8+4))) }
        return .ctts(entries: entries)
    }

    private static func parseStsc(handle: FileHandle, offset: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        guard let hdr = try? handle.read(upToCount: 8), hdr.count == 8 else { return .stsc(entries: []) }
        let count = Int(readU32BE(hdr, offset: 4))
        // [H3] 防止无界内存分配
        guard count > 0, count <= kMaxTableEntries else { return .stsc(entries: []) }
        guard let body = try? handle.read(upToCount: count * 12), body.count == count * 12 else { return .stsc(entries: []) }
        let entries = (0..<count).map { VAPMP4Payload.StscEntry(firstChunk: readU32BE(body, offset: $0*12), samplesPerChunk: readU32BE(body, offset: $0*12+4), descIndex: readU32BE(body, offset: $0*12+8)) }
        return .stsc(entries: entries)
    }

    private static func parseStco(handle: FileHandle, offset: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        guard let hdr = try? handle.read(upToCount: 8), hdr.count == 8 else { return .stco(offsets: []) }
        let count = Int(readU32BE(hdr, offset: 4))
        // [H3] 防止无界内存分配
        guard count > 0, count <= kMaxTableEntries else { return .stco(offsets: []) }
        guard let body = try? handle.read(upToCount: count * 4), body.count == count * 4 else { return .stco(offsets: []) }
        return .stco(offsets: (0..<count).map { readU32BE(body, offset: $0*4) })
    }

    private static func parseCo64(handle: FileHandle, offset: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        guard let hdr = try? handle.read(upToCount: 8), hdr.count == 8 else { return .co64(offsets: []) }
        let count = Int(readU32BE(hdr, offset: 4))
        // [H3] 防止无界内存分配
        guard count > 0, count <= kMaxTableEntries else { return .co64(offsets: []) }
        guard let body = try? handle.read(upToCount: count * 8), body.count == count * 8 else { return .co64(offsets: []) }
        return .co64(offsets: (0..<count).map { readU64BE(body, offset: $0*8) })
    }

    private static func parseStsz(handle: FileHandle, offset: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        // stsz is a FullBox: 4 bytes version/flags + 4 bytes sample_size + 4 bytes sample_count = 12 bytes header
        guard let hdr = try? handle.read(upToCount: 12), hdr.count == 12 else { return .stsz(defaultSize: 0, sizes: []) }
        let defaultSize = readU32BE(hdr, offset: 4)   // skip version/flags at offset 0
        let sampleCount = Int(readU32BE(hdr, offset: 8))
        if defaultSize > 0 { return .stsz(defaultSize: defaultSize, sizes: []) }
        // [H3] 防止无界内存分配
        guard sampleCount > 0, sampleCount <= kMaxTableEntries else { return .stsz(defaultSize: 0, sizes: []) }
        guard let body = try? handle.read(upToCount: sampleCount * 4), body.count == sampleCount * 4 else {
            return .stsz(defaultSize: 0, sizes: [])
        }
        return .stsz(defaultSize: 0, sizes: (0..<sampleCount).map { readU32BE(body, offset: $0*4) })
    }

    private static func parseStss(handle: FileHandle, offset: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        guard let hdr = try? handle.read(upToCount: 8), hdr.count == 8 else { return .stss(sampleNumbers: []) }
        let count = Int(readU32BE(hdr, offset: 4))
        // [H3] 防止无界内存分配
        guard count > 0, count <= kMaxTableEntries else { return .stss(sampleNumbers: []) }
        guard let body = try? handle.read(upToCount: count * 4), body.count == count * 4 else { return .stss(sampleNumbers: []) }
        return .stss(sampleNumbers: (0..<count).map { readU32BE(body, offset: $0*4) })
    }

    private static func parseAvcC(handle: FileHandle, offset: UInt64, size: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        // [H2] 防止 UInt64→Int 截断导致崩溃
        guard size >= 7, size <= kMaxBoxReadSize else { return .avcC(VAPAvcCData()) }
        guard let data = try? handle.read(upToCount: Int(size)), data.count >= 7 else { return .avcC(VAPAvcCData()) }
        var avcC = VAPAvcCData()
        let spsCount = Int(data[5] & 0x1F)
        var idx = 6
        for _ in 0..<spsCount {
            guard idx + 2 <= data.count else { break }
            let len = Int(readU16BE(data, offset: idx)); idx += 2
            guard idx + len <= data.count else { break }
            avcC.sps.append(data[idx..<(idx+len)]); idx += len
        }
        guard idx < data.count else { return .avcC(avcC) }
        let ppsCount = Int(data[idx]); idx += 1
        for _ in 0..<ppsCount {
            guard idx + 2 <= data.count else { break }
            let len = Int(readU16BE(data, offset: idx)); idx += 2
            guard idx + len <= data.count else { break }
            avcC.pps.append(data[idx..<(idx+len)]); idx += len
        }
        return .avcC(avcC)
    }

    private static func parseHvcC(handle: FileHandle, offset: UInt64, size: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        // [H2] 防止 UInt64→Int 截断导致崩溃
        guard size > 0, size <= kMaxBoxReadSize else { return .hvcC(VAPHvcCData()) }
        guard let data = try? handle.read(upToCount: Int(size)) else { return .hvcC(VAPHvcCData()) }
        var hvcC = VAPHvcCData(rawData: data)
        var idx = 22
        guard idx < data.count else { return .hvcC(hvcC) }
        let numArrays = Int(data[idx]); idx += 1
        for _ in 0..<numArrays {
            guard idx + 3 <= data.count else { break }
            let nalType = data[idx] & 0x3F; idx += 1
            let numNalus = Int(readU16BE(data, offset: idx)); idx += 2
            for _ in 0..<numNalus {
                guard idx + 2 <= data.count else { break }
                let len = Int(readU16BE(data, offset: idx)); idx += 2
                guard idx + len <= data.count else { break }
                let nalu = data[idx..<(idx+len)]
                switch nalType {
                case 32: hvcC.vps = nalu
                case 33: hvcC.sps = nalu
                case 34: hvcC.pps = nalu
                default: break
                }
                idx += len
            }
        }
        return .hvcC(hvcC)
    }

    private static func parseVapc(handle: FileHandle, offset: UInt64, size: UInt64) -> VAPMP4Payload {
        try? handle.seek(toOffset: offset)
        // [H2] 防止 UInt64→Int 截断导致崩溃
        guard size > 0, size <= kMaxBoxReadSize else { return .vapc(jsonData: Data()) }
        guard let data = try? handle.read(upToCount: Int(size)) else { return .vapc(jsonData: Data()) }
        return .vapc(jsonData: data)
    }

    // MARK: - Structure helpers

    private static func findVideoTrak(in moov: VAPMP4Box) -> VAPMP4Box? {
        for trak in moov.allChildren(type: "trak") {
            if let mdia = trak.firstChild(type: "mdia"),
               let hdlr = mdia.firstChild(type: "hdlr"),
               case .hdlr(let ht) = hdlr.payload, ht == "vide" {
                return trak
            }
        }
        return nil
    }

    private static func hasAudioTrack(in moov: VAPMP4Box) -> Bool {
        moov.allChildren(type: "trak").contains { trak in
            guard let mdia = trak.firstChild(type: "mdia"),
                  let hdlr = mdia.firstChild(type: "hdlr"),
                  case .hdlr(let ht) = hdlr.payload else { return false }
            return ht == "soun"
        }
    }

    private static func videoCodecInfo(trak: VAPMP4Box) -> (VAPVideoCodec, VAPAvcCData?, VAPHvcCData?) {
        guard let stbl = trak.bfsFirst(type: "stbl"),
              let stsd = stbl.firstChild(type: "stsd") else { return (.h264, nil, nil) }
        for entry in stsd.children {
            if let avcCBox = entry.firstChild(type: "avcC"),
               case .avcC(let data) = avcCBox.payload { return (.h264, data, nil) }
            if let hvcCBox = entry.firstChild(type: "hvcC"),
               case .hvcC(let data) = hvcCBox.payload { return (.h265, nil, data) }
        }
        return (.h264, nil, nil)
    }

    private static func videoDimensions(trak: VAPMP4Box) -> (Int, Int) {
        // Read from VisualSampleEntry (avc1/hvc1) payload parsed earlier
        for boxType in ["avc1", "hvc1", "hev1", "mp4v"] {
            if let entry = trak.bfsFirst(type: boxType),
               case .visualEntry(let w, let h) = entry.payload,
               w > 0, h > 0 {
                return (w, h)
            }
        }
        return (0, 0)
    }

    // MARK: - Sample table

    private static func buildSamples(trak: VAPMP4Box, timeScale: Double) throws -> [VAPMP4Sample] {
        guard let stbl = trak.bfsFirst(type: "stbl") else { throw VAPError.streamInfoUnavailable }

        guard let stscBox = stbl.firstChild(type: "stsc"),
              case .stsc(let stscEntries) = stscBox.payload,
              let stszBox = stbl.firstChild(type: "stsz"),
              case .stsz(let defaultSize, let sizes) = stszBox.payload else {
            throw VAPError.streamInfoUnavailable
        }

        var deltas: [UInt32] = []
        if let sttsBox = stbl.firstChild(type: "stts"), case .stts(let entries) = sttsBox.payload {
            for e in entries { for _ in 0..<e.count { deltas.append(e.delta) } }
        }

        var cttsOffsets: [Int32] = []
        if let cttsBox = stbl.firstChild(type: "ctts"), case .ctts(let entries) = cttsBox.payload {
            for e in entries { for _ in 0..<e.count { cttsOffsets.append(e.offset) } }
        }

        var keySet = Set<Int>()
        if let stssBox = stbl.firstChild(type: "stss"), case .stss(let nums) = stssBox.payload {
            keySet = Set(nums.map(Int.init))
        }

        let chunkOffsets: [UInt64]
        if let co64Box = stbl.firstChild(type: "co64"), case .co64(let offs) = co64Box.payload {
            chunkOffsets = offs
        } else if let stcoBox = stbl.firstChild(type: "stco"), case .stco(let offs) = stcoBox.payload {
            chunkOffsets = offs.map(UInt64.init)
        } else {
            throw VAPError.streamInfoUnavailable
        }

        let sampleCount = sizes.isEmpty ? deltas.count : sizes.count
        // [H3] 防止无界内存分配（恶意 stsz/stts 条目数）
        guard sampleCount <= kMaxSampleCount else { throw VAPError.invalidMP4File }
        var sampleOffsets = [UInt64](repeating: 0, count: sampleCount)
        var sampleIdx = 0
        for chunkIdx in 0..<chunkOffsets.count {
            let chunk1 = chunkIdx + 1
            var spc: UInt32 = 1
            for i in stride(from: stscEntries.count - 1, through: 0, by: -1) {
                if Int(stscEntries[i].firstChunk) <= chunk1 { spc = stscEntries[i].samplesPerChunk; break }
            }
            var off = chunkOffsets[chunkIdx]
            for _ in 0..<Int(spc) {
                if sampleIdx >= sampleCount { break }
                sampleOffsets[sampleIdx] = off
                let sz: UInt32 = defaultSize > 0 ? defaultSize : (sampleIdx < sizes.count ? sizes[sampleIdx] : 0)
                off += UInt64(sz)
                sampleIdx += 1
            }
        }

        var dts: Double = 0
        var samples: [VAPMP4Sample] = []
        samples.reserveCapacity(sampleCount)
        var samplePTS: [Double] = []
        samplePTS.reserveCapacity(sampleCount)
        var sampleDTS: [Double] = []
        sampleDTS.reserveCapacity(sampleCount)

        for i in 0..<sampleCount {
            let delta = i < deltas.count ? Double(deltas[i]) : 0
            let cttsOff = i < cttsOffsets.count ? Double(cttsOffsets[i]) : 0
            let pts = timeScale > 0 ? (dts + cttsOff) / timeScale : 0
            let dtsSec = timeScale > 0 ? dts / timeScale : 0
            let sz: UInt32 = defaultSize > 0 ? defaultSize : (i < sizes.count ? sizes[i] : 0)
            let s = VAPMP4Sample(index: i, presentationIndex: i,
                                 offset: sampleOffsets[i], size: sz, pts: pts, dts: dtsSec,
                                 isKeySample: keySet.isEmpty || keySet.contains(i + 1))
            samples.append(s)
            samplePTS.append(pts)
            sampleDTS.append(dtsSec)
            dts += delta
        }

        let presentation = presentationIndices(pts: samplePTS, dts: sampleDTS)
        return samples.enumerated().map { i, sample in
            VAPMP4Sample(index: sample.index,
                         presentationIndex: i < presentation.count ? presentation[i] : i,
                         offset: sample.offset,
                         size: sample.size,
                         pts: sample.pts,
                         dts: sample.dts,
                         isKeySample: sample.isKeySample)
        }
    }

    private static func computeFPS(samples: [VAPMP4Sample], duration: Double) -> Int {
        guard duration > 0 else { return VAPPlaybackDefaults.defaultFramesPerSecond }
        return max(
            VAPPlaybackDefaults.minimumFramesPerSecond,
            min(Int((Double(samples.count) / duration).rounded()), VAPPlaybackDefaults.maximumFramesPerSecond)
        )
    }

    static func presentationIndices(pts: [Double], dts: [Double]) -> [Int] {
        let count = pts.count
        guard count > 0 else { return [] }
        let presentationOrder = (0..<count).sorted {
            if pts[$0] != pts[$1] { return pts[$0] < pts[$1] }
            let lhsDTS = $0 < dts.count ? dts[$0] : 0
            let rhsDTS = $1 < dts.count ? dts[$1] : 0
            if lhsDTS != rhsDTS { return lhsDTS < rhsDTS }
            return $0 < $1
        }
        var indices = [Int](repeating: 0, count: count)
        for (presentationIndex, sampleIndex) in presentationOrder.enumerated() {
            indices[sampleIndex] = presentationIndex
        }
        return indices
    }

    // MARK: - Byte utilities

    static func readU32BE(_ data: Data, offset: Int) -> UInt32 {
        guard offset + 4 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let b = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return (UInt32(b[0]) << 24) | (UInt32(b[1]) << 16) | (UInt32(b[2]) << 8) | UInt32(b[3])
        }
    }

    static func readU64BE(_ data: Data, offset: Int) -> UInt64 {
        guard offset + 8 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let b = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return (UInt64(b[0]) << 56) | (UInt64(b[1]) << 48) | (UInt64(b[2]) << 40) | (UInt64(b[3]) << 32)
                 | (UInt64(b[4]) << 24) | (UInt64(b[5]) << 16) | (UInt64(b[6]) << 8)  | UInt64(b[7])
        }
    }

    static func readU16BE(_ data: Data, offset: Int) -> UInt16 {
        guard offset + 2 <= data.count else { return 0 }
        return data.withUnsafeBytes { ptr in
            let b = ptr.baseAddress!.advanced(by: offset).assumingMemoryBound(to: UInt8.self)
            return (UInt16(b[0]) << 8) | UInt16(b[1])
        }
    }
}
