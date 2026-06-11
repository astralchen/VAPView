// VAPLogger.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import os
import Foundation

enum VAPModule: String {
    case common  = "VAPCommon"
    case decoder = "VAPDecoder"
    case renderer = "VAPRenderer"
    case parser  = "VAPParser"
    case config  = "VAPConfig"
    case player  = "VAPPlayer"
}


struct VAPLogger: Sendable {
    private let logger: Logger
    private static let debugLoggingEnabled: Bool = {
        #if DEBUG
        ProcessInfo.processInfo.environment["VAP_DEBUG_LOGS"] == "1"
        #else
        false
        #endif
    }()

    init(module: VAPModule) {
        logger = Logger(subsystem: "com.tencent.vap", category: module.rawValue)
    }

    func info(_ message: String) {
        logger.info("\(message, privacy: .public)")
    }

    func error(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    func debug(_ message: @autoclosure () -> String) {
        guard Self.debugLoggingEnabled else { return }
        let value = message()
        logger.debug("\(value, privacy: .public)")
    }
}

// Module-level singletons

let vapLog = VAPLogger(module: .common)

let decoderLog = VAPLogger(module: .decoder)

let rendererLog = VAPLogger(module: .renderer)

let parserLog = VAPLogger(module: .parser)

let configLog = VAPLogger(module: .config)

let playerLog = VAPLogger(module: .player)
