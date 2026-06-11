// VAPLogging.swift
// Copyright (C) 2020 Tencent. All rights reserved.
// Licensed under the MIT License: http://opensource.org/licenses/MIT

import Foundation

/// Runtime log verbosity for VAPPlayer.
///
/// The default configuration logs only errors in production. Debug logs are
/// available when explicitly configured, or in Debug builds when the
/// `VAP_DEBUG_LOGS=1` environment variable is present.
public enum VAPLogLevel: Int, Comparable, Sendable {
    case off = 0
    case error = 1
    case info = 2
    case debug = 3

    public static func < (lhs: VAPLogLevel, rhs: VAPLogLevel) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Logical logger categories used by VAPPlayer internals.
public enum VAPLogModule: String, CaseIterable, Hashable, Sendable {
    case common = "VAPCommon"
    case decoder = "VAPDecoder"
    case renderer = "VAPRenderer"
    case parser = "VAPParser"
    case config = "VAPConfig"
    case player = "VAPPlayer"
}

/// A sanitized log event delivered to a custom handler.
public struct VAPLogRecord: Sendable {
    public let level: VAPLogLevel
    public let module: VAPLogModule
    public let message: String
    public let file: String
    public let function: String
    public let line: UInt

    public init(level: VAPLogLevel,
                module: VAPLogModule,
                message: String,
                file: String,
                function: String,
                line: UInt) {
        self.level = level
        self.module = module
        self.message = message
        self.file = file
        self.function = function
        self.line = line
    }
}

/// Global logging configuration for VAPPlayer.
public struct VAPLogConfiguration: Sendable {
    public var level: VAPLogLevel
    public var enabledModules: Set<VAPLogModule>?
    public var redactSensitiveValues: Bool
    public var osLogEnabled: Bool
    public var handler: (@Sendable (VAPLogRecord) -> Void)?

    public init(level: VAPLogLevel = .error,
                enabledModules: Set<VAPLogModule>? = nil,
                redactSensitiveValues: Bool = true,
                osLogEnabled: Bool = true,
                handler: (@Sendable (VAPLogRecord) -> Void)? = nil) {
        self.level = level
        self.enabledModules = enabledModules
        self.redactSensitiveValues = redactSensitiveValues
        self.osLogEnabled = osLogEnabled
        self.handler = handler
    }

    public static var productionDefault: VAPLogConfiguration {
        #if DEBUG
        let defaultLevel: VAPLogLevel =
            ProcessInfo.processInfo.environment["VAP_DEBUG_LOGS"] == "1" ? .debug : .error
        #else
        let defaultLevel: VAPLogLevel = .error
        #endif
        return VAPLogConfiguration(level: defaultLevel)
    }

    func allows(level requestedLevel: VAPLogLevel, module: VAPLogModule) -> Bool {
        guard level != .off, requestedLevel.rawValue <= level.rawValue else { return false }
        guard let enabledModules else { return true }
        return enabledModules.contains(module)
    }
}

/// Public entry point for configuring VAPPlayer logging.
public enum VAPLogging {
    public static func configure(_ configuration: VAPLogConfiguration) {
        VAPLogState.shared.configure(configuration)
    }

    public static func resetConfiguration() {
        VAPLogState.shared.configure(.productionDefault)
    }

    public static var configuration: VAPLogConfiguration {
        VAPLogState.shared.configuration
    }
}

final class VAPLogState: @unchecked Sendable {
    static let shared = VAPLogState()

    private let lock = NSLock()
    private var currentConfiguration: VAPLogConfiguration = .productionDefault

    var configuration: VAPLogConfiguration {
        withLock { currentConfiguration }
    }

    func configure(_ configuration: VAPLogConfiguration) {
        withLock {
            currentConfiguration = configuration
        }
    }

    private func withLock<T>(_ work: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return work()
    }
}
