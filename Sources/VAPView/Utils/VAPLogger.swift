// VAPLogger.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import os
import Foundation

struct VAPLogger: Sendable {
    private let logger: Logger
    private let module: VAPLogModule

    init(module: VAPLogModule) {
        self.module = module
        logger = Logger(subsystem: "com.vap", category: module.rawValue)
    }

    func info(_ message: @autoclosure () -> String,
              file: String = #fileID,
              function: String = #function,
              line: UInt = #line) {
        log(.info, message(), file: file, function: function, line: line)
    }

    func error(_ message: @autoclosure () -> String,
               file: String = #fileID,
               function: String = #function,
               line: UInt = #line) {
        log(.error, message(), file: file, function: function, line: line)
    }

    func debug(_ message: @autoclosure () -> String,
               file: String = #fileID,
               function: String = #function,
               line: UInt = #line) {
        log(.debug, message(), file: file, function: function, line: line)
    }

    private func log(_ level: VAPLogLevel,
                     _ message: @autoclosure () -> String,
                     file: String,
                     function: String,
                     line: UInt) {
        let configuration = VAPLogging.configuration
        guard configuration.allows(level: level, module: module) else { return }

        let value = VAPLogSanitizer.sanitize(
            message(),
            redactSensitiveValues: configuration.redactSensitiveValues
        )
        let record = VAPLogRecord(
            level: level,
            module: module,
            message: value,
            file: file,
            function: function,
            line: line
        )

        configuration.handler?(record)

        guard configuration.osLogEnabled else { return }
        switch level {
        case .off:
            break
        case .error:
            logger.error("\(value, privacy: .public)")
        case .info:
            logger.info("\(value, privacy: .public)")
        case .debug:
            logger.debug("\(value, privacy: .public)")
        }
    }
}

private enum VAPLogSanitizer {
    static func sanitize(_ message: String, redactSensitiveValues: Bool) -> String {
        guard redactSensitiveValues else { return message }
        return redactPaths(in: redactURLQueries(in: message))
    }

    private static func redactURLQueries(in message: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"https?://[^\s]+"#,
            options: [.caseInsensitive]
        ) else {
            return message
        }

        var result = message
        let matches = regex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )

        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let value = String(result[range])
            guard var components = URLComponents(string: value), components.query != nil else {
                continue
            }

            components.query = nil
            let redacted = (components.string ?? value) + "?<redacted-query>"
            result.replaceSubrange(range, with: redacted)
        }

        return result
    }

    private static func redactPaths(in message: String) -> String {
        guard let regex = try? NSRegularExpression(
            pattern: #"\b(filePath|path)=([^\s]+)"#,
            options: [.caseInsensitive]
        ) else {
            return message
        }

        var result = message
        let matches = regex.matches(
            in: result,
            range: NSRange(result.startIndex..., in: result)
        )

        for match in matches.reversed() where match.numberOfRanges == 3 {
            guard let matchRange = Range(match.range, in: result),
                  let labelRange = Range(match.range(at: 1), in: result) else {
                continue
            }

            let label = String(result[labelRange])
            result.replaceSubrange(matchRange, with: "\(label)=<redacted-path>")
        }

        return result
    }
}

// Module-level singletons

let vapLog = VAPLogger(module: .common)

let decoderLog = VAPLogger(module: .decoder)

let rendererLog = VAPLogger(module: .renderer)

let parserLog = VAPLogger(module: .parser)

let configLog = VAPLogger(module: .config)

let playerLog = VAPLogger(module: .player)
