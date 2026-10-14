//
//  StoreValues.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine（由 ObservatoryStore.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import os
import AIObservatoryCore
// MARK: - 值转换助手

/// Swift 值 → SQLiteValue 的统一口径（日期 REAL、UInt64 bitPattern、Bool INTEGER 0/1）。
enum StoreValues {

    static func date(_ value: Date) -> SQLiteValue { .real(value.timeIntervalSinceReferenceDate) }

    static func optionalDate(_ value: Date?) -> SQLiteValue { value.map { date($0) } ?? .null }

    static func optionalText(_ value: String?) -> SQLiteValue { value.map { SQLiteValue.text($0) } ?? .null }

    static func optionalUUID(_ value: UUID?) -> SQLiteValue { value.map { SQLiteValue.text($0.uuidString) } ?? .null }

    static func uint64(_ value: UInt64) -> SQLiteValue { .integer(Int64(bitPattern: value)) }

    static func flag(_ value: Bool) -> SQLiteValue { .integer(value ? 1 : 0) }

    static func optionalInt32(_ value: Int32?) -> SQLiteValue { value.map { SQLiteValue.integer(Int64($0)) } ?? .null }
}

