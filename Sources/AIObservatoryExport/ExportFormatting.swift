//
//  ExportFormatting.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（主代理 · 共享脊柱，子代理只读）
//
//  导出层的全部确定性格式化：字节可重现的前提是这里不依赖 Locale / 时区。
//

import Foundation
import AIObservatoryCore

/// ISO8601 与文件名时间戳编码器。
///
/// 无状态、可被 `@Sendable` 闭包捕获；formatter 在初始化后不再修改，共享一份即可。
public struct ExportDateEncoder: Sendable {
    /// `ISO8601DateFormatter` 在本 SDK 未标注 `Sendable`，但它在本文件里初始化后只读、
    /// `string(from:)` 无共享可变状态，故显式放行以避免每条记录重复构造。
    /// （对比：`DateFormatter` 已是 `Sendable`，再加 `nonisolated(unsafe)` 反而触发警告。）
    nonisolated(unsafe) private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    private static let fileStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        return formatter
    }()

    public init() {}

    /// `2026-09-19T15:40:26Z` —— 固定 UTC、无小数秒，保证同输入同字节。
    public func string(_ date: Date) -> String { Self.iso8601.string(from: date) }

    /// 可选时间；`nil` → 空串（CSV 与 JSON 的 null 由各自 DTO 处理）。
    public func string(_ date: Date?) -> String {
        guard let date else { return ExportConstants.missingValue }
        return Self.iso8601.string(from: date)
    }

    /// 文件名用的紧凑时间戳。
    public func fileStamp(_ date: Date) -> String { Self.fileStampFormatter.string(from: date) }
}

/// 导出文本格式化（ASCII 稳定、跨 Locale 一致）。
public enum ExportText {
    public static func integer(_ value: Int) -> String { String(value) }

    public static func integer(_ value: Int?) -> String {
        guard let value else { return ExportConstants.missingValue }
        return String(value)
    }

    /// 固定小数位。`%.Nf` 不会产生千位分隔符，仅需把个别 Locale 的逗号小数点归一化。
    public static func double(_ value: Double, fractionDigits: Int = 3) -> String {
        guard value.isFinite else { return ExportConstants.missingValue }
        let digits = max(0, min(9, fractionDigits))
        return String(format: "%.\(digits)f", value).replacingOccurrences(of: ",", with: ".")
    }

    public static func double(_ value: Double?, fractionDigits: Int = 3) -> String {
        guard let value else { return ExportConstants.missingValue }
        return double(value, fractionDigits: fractionDigits)
    }

    /// 字节数按整数输出（不缩写，便于表格计算）。
    public static func bytes(_ value: UInt64) -> String { String(value) }

    public static func bytes(_ value: UInt64?) -> String {
        guard let value else { return ExportConstants.missingValue }
        return String(value)
    }

    public static func bytes(_ value: Int) -> String { String(value) }

    public static func boolean(_ value: Bool) -> String {
        value ? ExportConstants.trueValue : ExportConstants.falseValue
    }

    public static func boolean(_ value: Bool?) -> String {
        guard let value else { return ExportConstants.missingValue }
        return boolean(value)
    }

    /// 列表型字段（如 `filePaths`）用竖线之外的稳定分隔符连接，避免与 CSV 逗号混淆。
    public static func list(_ values: [String]) -> String { values.joined(separator: "; ") }

    /// 折叠换行/制表/连续空白为单空格，供表格单元与摘要行使用。
    public static func oneLine(_ text: String) -> String {
        var result = ""
        result.reserveCapacity(text.count)
        var lastWasSpace = false
        for character in text {
            let isSpace = character == " " || character == "\n" || character == "\r"
                || character == "\t" || character == "\u{0B}" || character == "\u{0C}"
            if isSpace {
                if !lastWasSpace { result.append(" ") }
                lastWasSpace = true
            } else {
                result.append(character)
                lastWasSpace = false
            }
        }
        while result.hasSuffix(" ") { result.removeLast() }
        return result
    }

    /// Markdown 表格单元转义：`|` 与换行不能破坏表格结构。
    public static func markdownCell(_ text: String) -> String {
        oneLine(text).replacingOccurrences(of: "|", with: "\\|")
    }
}
