// VAPMP4ParserTests.swift
import Testing
import Foundation
@testable import VAPView

@Suite("VAPMP4Parser")
struct VAPMP4ParserTests {

    // MARK: - 字节工具

    @Test func readU32BE_basic() {
        let data = Data([0x01, 0x02, 0x03, 0x04])
        #expect(VAPMP4Parser.readU32BE(data, offset: 0) == 0x01020304)
    }

    @Test func readU32BE_withOffset() {
        let data = Data([0x00, 0x00, 0xAB, 0xCD, 0xEF, 0x01])
        #expect(VAPMP4Parser.readU32BE(data, offset: 2) == 0xABCDEF01)
    }

    @Test func readU32BE_outOfBounds() {
        let data = Data([0x01, 0x02])
        #expect(VAPMP4Parser.readU32BE(data, offset: 0) == 0)
    }

    @Test func readU64BE_basic() {
        let data = Data([0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00])
        #expect(VAPMP4Parser.readU64BE(data, offset: 0) == 0x0000000100000000)
    }

    @Test func readU16BE_basic() {
        let data = Data([0x12, 0x34])
        #expect(VAPMP4Parser.readU16BE(data, offset: 0) == 0x1234)
    }

    // MARK: - Box 树辅助方法

    @Test func boxFirstChild_found() {
        let child1 = VAPMP4Box(type: "mdhd", payload: .unknown)
        let child2 = VAPMP4Box(type: "hdlr", payload: .unknown)
        let parent = VAPMP4Box(type: "mdia", payload: .container, children: [child1, child2])
        #expect(parent.firstChild(type: "hdlr")?.type == "hdlr")
    }

    @Test func boxFirstChild_notFound() {
        let parent = VAPMP4Box(type: "mdia", payload: .container)
        #expect(parent.firstChild(type: "stbl") == nil)
    }

    @Test func boxAllChildren_count() {
        let a = VAPMP4Box(type: "trak", payload: .container)
        let b = VAPMP4Box(type: "trak", payload: .container)
        let c = VAPMP4Box(type: "udta", payload: .container)
        let moov = VAPMP4Box(type: "moov", payload: .container, children: [a, b, c])
        #expect(moov.allChildren(type: "trak").count == 2)
        #expect(moov.allChildren(type: "udta").count == 1)
        #expect(moov.allChildren(type: "mdia").count == 0)
    }

    @Test func boxBfsFirst_deep() {
        let stbl = VAPMP4Box(type: "stbl", payload: .container)
        let minf = VAPMP4Box(type: "minf", payload: .container, children: [stbl])
        let mdia = VAPMP4Box(type: "mdia", payload: .container, children: [minf])
        let trak = VAPMP4Box(type: "trak", payload: .container, children: [mdia])
        #expect(trak.bfsFirst(type: "stbl")?.type == "stbl")
        #expect(trak.bfsFirst(type: "moov") == nil)
    }

    // MARK: - 载荷模式匹配

    @Test func mvhdPayload() {
        let box = VAPMP4Box(type: "mvhd", payload: .mvhd(timeScale: 1000, duration: 50000))
        guard case .mvhd(let ts, let dur) = box.payload else { Issue.record("wrong payload"); return }
        #expect(ts == 1000)
        #expect(dur == 50000)
    }

    @Test func hdlrPayload() {
        let box = VAPMP4Box(type: "hdlr", payload: .hdlr(handlerType: "vide"))
        guard case .hdlr(let ht) = box.payload else { Issue.record("wrong payload"); return }
        #expect(ht == "vide")
    }

    @Test func sttsPayload() {
        let entries = [VAPMP4Payload.SttsEntry(count: 100, delta: 512)]
        let box = VAPMP4Box(type: "stts", payload: .stts(entries: entries))
        guard case .stts(let e) = box.payload else { Issue.record("wrong payload"); return }
        #expect(e.count == 1)
        #expect(e[0].count == 100)
        #expect(e[0].delta == 512)
    }

    @Test func avcCPayload() {
        var avcC = VAPAvcCData()
        avcC.sps = [Data([0x67, 0x42])]
        avcC.pps = [Data([0x68, 0xCE])]
        let box = VAPMP4Box(type: "avcC", payload: .avcC(avcC))
        guard case .avcC(let d) = box.payload else { Issue.record("wrong payload"); return }
        #expect(d.sps.count == 1)
        #expect(d.pps.count == 1)
    }

    @Test func vapcPayload() {
        let json = Data("{\"test\":1}".utf8)
        let box = VAPMP4Box(type: "vapc", payload: .vapc(jsonData: json))
        guard case .vapc(let data) = box.payload else { Issue.record("wrong payload"); return }
        #expect(data == json)
    }

    @Test func presentationIndicesUsePtsOrderForBFrames() {
        let pts = [1024.0, 2560.0, 1536.0, 2048.0]
        let dts = [0.0, 512.0, 1024.0, 1536.0]

        let indices = VAPMP4Parser.presentationIndices(pts: pts, dts: dts)

        #expect(indices == [0, 3, 1, 2])
    }

    // 验证能找到顶层（moov 外部）的 vapc。
    @Test func topLevelVapcIsFound() {
        // 构造一个 vapc 位于 moov 外部的最小 MP4。
        var data = Data()

        // ftyp box（最小结构）
        let ftyp = Data([
            0x00, 0x00, 0x00, 0x14,  // size = 20
            0x66, 0x74, 0x79, 0x70,  // "ftyp"
            0x69, 0x73, 0x6F, 0x6D,  // "isom"
            0x00, 0x00, 0x02, 0x00,  // version
            0x69, 0x73, 0x6F, 0x6D,  // compatible brand
        ])
        data.append(ftyp)

        // 空 moov box（内部没有 vapc）。
        let moovBody = Data([
            // mvhd（最小结构，版本 0，header 后 96 字节）。
            0x00, 0x00, 0x00, 0x6C, // size = 108
            0x6D, 0x76, 0x68, 0x64, // "mvhd"
        ] + [UInt8](repeating: 0, count: 100))
        var moovHeader = Data()
        let moovSize = UInt32(moovBody.count + 8)
        moovHeader.append(contentsOf: withUnsafeBytes(of: moovSize.bigEndian) { Array($0) })
        moovHeader.append("moov".data(using: .ascii)!)
        data.append(moovHeader)
        data.append(moovBody)

        // 顶层 vapc box（位于 moov 外部）。
        let vapcJSON = Data(#"{"info":{"v":2,"w":750,"h":1334,"fps":30,"videoW":1136,"videoH":1344,"orien":0,"rgbFrame":[0,0,750,1334],"aFrame":[754,0,375,667]}}"#.utf8)
        let vapcSize = UInt32(vapcJSON.count + 8)
        var vapcBox = Data()
        vapcBox.append(contentsOf: withUnsafeBytes(of: vapcSize.bigEndian) { Array($0) })
        vapcBox.append("vapc".data(using: .ascii)!)
        vapcBox.append(vapcJSON)
        data.append(vapcBox)

        // 写入临时文件并解析。
        let tmpPath = NSTemporaryDirectory() + "test_toplevel_vapc.mp4"
        try! data.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // 完整解析会因为找不到视频轨而失败；这里直接解析 box 结构来检查 vapcJSON。
        let handle = FileHandle(forReadingAtPath: tmpPath)!
        defer { try? handle.close() }
        let boxes = try! VAPMP4Parser.parseBoxes(handle: handle, offset: 0, length: nil)

        // 验证 vapc 是顶层 box。
        let vapc = boxes.first(where: { $0.type == "vapc" })
        #expect(vapc != nil, "vapc should be found at top level")

        // 验证它不在 moov 内部。
        let moov = boxes.first(where: { $0.type == "moov" })
        #expect(moov != nil)
        let vapcInMoov = moov?.bfsFirst(type: "vapc")
        #expect(vapcInMoov == nil, "vapc should NOT be inside moov")

        // 验证载荷。
        if let vapc, case .vapc(let jsonData) = vapc.payload {
            let decoded = try! JSONDecoder().decode(VAPConfig.self, from: jsonData)
            #expect(decoded.info.w == 750)
            #expect(decoded.info.h == 1334)
            #expect(decoded.info.rgbFrame == [0, 0, 750, 1334])
            #expect(decoded.info.aFrame == [754, 0, 375, 667])
        } else {
            Issue.record("vapc payload not found")
        }
    }

    @Test func parseMissingFile() {
        #expect(throws: (any Error).self) {
            try VAPMP4Parser.parse(localFilePath: "/nonexistent/file.mp4")
        }
    }
}
