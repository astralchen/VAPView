// VAPLoggerTests.swift

import Foundation
import Testing
@testable import VAPView

@Suite("VAPLogger", .serialized)
struct VAPLoggerTests {

    @Test func configuredLevelFiltersDebugAndAvoidsMessageEvaluation() {
        let collector = VAPLogCollector()
        VAPLogging.configure(
            VAPLogConfiguration(
                level: .error,
                osLogEnabled: false,
                handler: { collector.append($0) }
            )
        )
        defer { VAPLogging.resetConfiguration() }

        var didEvaluateDebug = false
        let logger = VAPLogger(module: .player)

        logger.debug({ didEvaluateDebug = true; return "debug should stay lazy" }())
        logger.error("playback failed")

        let records = collector.records
        #expect(didEvaluateDebug == false)
        #expect(records.count == 1)
        #expect(records.first?.level == .error)
        #expect(records.first?.module == .player)
        #expect(records.first?.message == "playback failed")
    }

    @Test func configuredModulesFilterRecordsBeforeMessageEvaluation() {
        let collector = VAPLogCollector()
        VAPLogging.configure(
            VAPLogConfiguration(
                level: .debug,
                enabledModules: [.player],
                osLogEnabled: false,
                handler: { collector.append($0) }
            )
        )
        defer { VAPLogging.resetConfiguration() }

        var didEvaluateRenderer = false
        VAPLogger(module: .renderer).error({ didEvaluateRenderer = true; return "renderer frame failed" }())
        VAPLogger(module: .player).debug("player state changed")

        let records = collector.records
        #expect(didEvaluateRenderer == false)
        #expect(records.count == 1)
        #expect(records.first?.module == .player)
        #expect(records.first?.level == .debug)
        #expect(records.first?.message == "player state changed")
    }

    @Test func sanitizerRedactsPathsAndURLQueryValuesBeforeDispatch() {
        let collector = VAPLogCollector()
        VAPLogging.configure(
            VAPLogConfiguration(
                level: .error,
                osLogEnabled: false,
                handler: { collector.append($0) }
            )
        )
        defer { VAPLogging.resetConfiguration() }

        VAPLogger(module: .player).error(
            "filePath=/Users/sondra/Library/Caches/private.mp4 localFilePath=/private/tmp/local.mp4 path=/private/tmp/path.mp4 source=/private/tmp/source.mp4 url=https://example.com/video.mp4?token=secret"
        )

        let message = collector.records.first?.message ?? ""
        #expect(message.contains("filePath=<redacted-path>"))
        #expect(message.contains("localFilePath=<redacted-path>"))
        #expect(message.contains("path=<redacted-path>"))
        #expect(message.contains("source=<redacted-path>"))
        #expect(message.contains("https://example.com/video.mp4?<redacted-query>"))
        #expect(!message.contains("/Users/sondra"))
        #expect(!message.contains("/private/tmp"))
        #expect(!message.contains("token=secret"))
    }

    @Test func sanitizerCanBeDisabledForExplicitVerboseDebugSessions() {
        let collector = VAPLogCollector()
        VAPLogging.configure(
            VAPLogConfiguration(
                level: .debug,
                redactSensitiveValues: false,
                osLogEnabled: false,
                handler: { collector.append($0) }
            )
        )
        defer { VAPLogging.resetConfiguration() }

        let rawMessage = "filePath=/Users/sondra/Library/Caches/private.mp4"
        VAPLogger(module: .player).debug(rawMessage)

        #expect(collector.records.first?.message == rawMessage)
    }
}

private final class VAPLogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VAPLogRecord] = []

    func append(_ record: VAPLogRecord) {
        lock.lock()
        storage.append(record)
        lock.unlock()
    }

    var records: [VAPLogRecord] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}
