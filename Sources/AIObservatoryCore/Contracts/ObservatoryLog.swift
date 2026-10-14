//
//  ObservatoryLog.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 统一日志门面（OSLog）。
//

import Foundation
import OSLog

public enum ObservatoryLog {
    private static let subsystem = "com.aix.aiobservatory"

    public static let engine    = Logger(subsystem: subsystem, category: "engine")
    public static let detection = Logger(subsystem: subsystem, category: "agent-detection")
    public static let files     = Logger(subsystem: subsystem, category: "file-tracking")
    public static let telemetry = Logger(subsystem: subsystem, category: "telemetry")
    public static let security  = Logger(subsystem: subsystem, category: "security")
    public static let store     = Logger(subsystem: subsystem, category: "store")
    public static let ui        = Logger(subsystem: subsystem, category: "ui")
    public static let bootstrap = Logger(subsystem: subsystem, category: "bootstrap")
}
