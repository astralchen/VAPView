// VAPMP4ParserTests.swift
import Testing
import Foundation
@testable import VAPPlayer

@Suite("VAPMP4Parser")
struct VAPMP4ParserTests {

    // MARK: - Byte utilities

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

    // MARK: - Box tree helpers

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

    // MARK: - Payload pattern matching

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

    // Verify that vapc at top level (outside moov) is found
    @Test func topLevelVapcIsFound() {
        // Build a minimal MP4 with vapc outside moov
        var data = Data()

        // ftyp box (minimal)
        let ftyp = Data([
            0x00, 0x00, 0x00, 0x14,  // size = 20
            0x66, 0x74, 0x79, 0x70,  // "ftyp"
            0x69, 0x73, 0x6F, 0x6D,  // "isom"
            0x00, 0x00, 0x02, 0x00,  // version
            0x69, 0x73, 0x6F, 0x6D,  // compatible brand
        ])
        data.append(ftyp)

        // Empty moov box (no vapc inside)
        let moovBody = Data([
            // mvhd (minimal, version 0, 96 bytes after header)
            0x00, 0x00, 0x00, 0x6C, // size = 108
            0x6D, 0x76, 0x68, 0x64, // "mvhd"
        ] + [UInt8](repeating: 0, count: 100))
        var moovHeader = Data()
        let moovSize = UInt32(moovBody.count + 8)
        moovHeader.append(contentsOf: withUnsafeBytes(of: moovSize.bigEndian) { Array($0) })
        moovHeader.append("moov".data(using: .ascii)!)
        data.append(moovHeader)
        data.append(moovBody)

        // vapc box at top level (outside moov)
        let vapcJSON = Data(#"{"info":{"v":2,"w":750,"h":1334,"fps":30,"videoW":1136,"videoH":1344,"orien":0,"rgbFrame":[0,0,750,1334],"aFrame":[754,0,375,667]}}"#.utf8)
        let vapcSize = UInt32(vapcJSON.count + 8)
        var vapcBox = Data()
        vapcBox.append(contentsOf: withUnsafeBytes(of: vapcSize.bigEndian) { Array($0) })
        vapcBox.append("vapc".data(using: .ascii)!)
        vapcBox.append(vapcJSON)
        data.append(vapcBox)

        // Write to temp file and parse
        let tmpPath = NSTemporaryDirectory() + "test_toplevel_vapc.mp4"
        try! data.write(to: URL(fileURLWithPath: tmpPath))
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }

        // Parser will fail to find video track, but we can check vapcJSON
        // by trying to parse and catching the error, then checking the box structure
        // Instead, let's test the box parsing directly
        let handle = FileHandle(forReadingAtPath: tmpPath)!
        defer { try? handle.close() }
        let boxes = try! VAPMP4Parser.parseBoxes(handle: handle, offset: 0, length: nil)

        // Verify vapc is a top-level box
        let vapc = boxes.first(where: { $0.type == "vapc" })
        #expect(vapc != nil, "vapc should be found at top level")

        // Verify it's NOT inside moov
        let moov = boxes.first(where: { $0.type == "moov" })
        #expect(moov != nil)
        let vapcInMoov = moov?.bfsFirst(type: "vapc")
        #expect(vapcInMoov == nil, "vapc should NOT be inside moov")

        // Verify payload
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
            try VAPMP4Parser.parse(filePath: "/nonexistent/file.mp4")
        }
    }
}
