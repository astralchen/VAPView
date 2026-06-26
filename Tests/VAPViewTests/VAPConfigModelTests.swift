// VAPConfigModelTests.swift
import Testing
@testable import VAPView
import Foundation

@Suite("VAPConfigModel")
struct VAPConfigModelTests {

    private static let sampleJSON = """
    {
      "info": {
        "w": 375, "h": 667, "fps": 25,
        "videoW": 750, "videoH": 667, "orien": 1
      },
      "src": [
        { "srcId": "avatar", "srcType": "img", "loadType": "net",
          "fitType": "centerFull", "w": 80, "h": 80 },
        { "srcId": "name", "srcType": "txtStr",
          "txtColor": "#FFFFFF", "txtFontSize": 14 }
      ],
      "frame": [
        { "i": 0, "obj": [
            { "srcId": "avatar", "x": 10, "y": 20, "w": 80, "h": 80, "z": 1 }
        ]}
      ]
    }
    """

    private func decode() throws -> VAPConfig {
        try JSONDecoder().decode(VAPConfig.self, from: Data(Self.sampleJSON.utf8))
    }

    @Test func decodeInfo() throws {
        let config = try decode()
        #expect(config.info.w == 375)
        #expect(config.info.h == 667)
        #expect(config.info.fps == 25)
        #expect(config.info.videoW == 750)
        #expect(config.info.videoH == 667)
        #expect(config.info.orientation == .portrait)
    }

    @Test func decodeSources() throws {
        let config = try decode()
        #expect(config.src?.count == 2)

        let avatar = config.src?[0]
        #expect(avatar?.srcId == "avatar")
        #expect(avatar?.attachmentSourceType == .image)
        #expect(avatar?.attachmentLoadType == .network)
        #expect(avatar?.attachmentLoadType?.publicLocation == .remote)
        #expect(avatar?.attachmentFitType == .centerFull)
        #expect(avatar?.attachmentFitType.publicContentMode == .centerFill)
        #expect(avatar?.w == 80)

        let name = config.src?[1]
        #expect(name?.srcId == "name")
        #expect(name?.attachmentSourceType == .textString)
        #expect(name?.txtColor == "#FFFFFF")
        #expect(name?.txtFontSize == 14)
    }

    @Test func decodeFrames() throws {
        let config = try decode()
        #expect(config.frame?.count == 1)
        let frame = config.frame?[0]
        #expect(frame?.i == 0)
        #expect(frame?.obj?.count == 1)
        let item = frame?.obj?[0]
        #expect(item?.srcId == "avatar")
        #expect(item?.x == 10)
        #expect(item?.y == 20)
        #expect(item?.w == 80)
        #expect(item?.h == 80)
        #expect(item?.z == 1)
    }

    @Test func sourceDisplayItemFrame() throws {
        let config = try decode()
        let item = config.frame?[0].obj?[0]
        #expect(item?.frame == CGRect(x: 10, y: 20, width: 80, height: 80))
    }

    @Test func orientationNone() throws {
        let json = "{\"info\":{\"w\":100,\"h\":100,\"fps\":25,\"videoW\":200,\"videoH\":100,\"orien\":0}}"
        let config = try JSONDecoder().decode(VAPConfig.self, from: Data(json.utf8))
        #expect(config.info.orientation == .none)
    }

    @Test func orientationLandscape() throws {
        let json = "{\"info\":{\"w\":100,\"h\":100,\"fps\":25,\"videoW\":200,\"videoH\":100,\"orien\":2}}"
        let config = try JSONDecoder().decode(VAPConfig.self, from: Data(json.utf8))
        #expect(config.info.orientation == .landscape)
    }

    @Test func missingOptionalFields() throws {
        let json = "{\"info\":{\"w\":100,\"h\":100,\"fps\":25,\"videoW\":100,\"videoH\":100,\"orien\":0}}"
        let config = try JSONDecoder().decode(VAPConfig.self, from: Data(json.utf8))
        #expect(config.src == nil)
        #expect(config.frame == nil)
    }

    @Test func invalidJSON() {
        let bad = Data("not json".utf8)
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(VAPConfig.self, from: bad)
        }
    }
}
