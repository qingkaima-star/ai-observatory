//
//  AixTable.swift
//  AIObservatoryCLI
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  人读表格渲染。**空值与「拿不到」在视觉上必须不同**（约束 3）：
//  `nil` 渲染成 `—`，空字符串渲染成 `‹空›` —— 两者搞混过一次就又是一次「0 当成没有」。
//

import Foundation
import AIObservatoryCore

public enum AixTable {
    /// `nil` 的占位符。与导出层 `MarkdownReportExporter.noValue` 同字，避免同一产品在两处各写一个符号。
    public static let noValue = "—"
    /// 字段存在但值为空串的占位符（区别于 `nil`）。
    public static let emptyValue = "‹空›"

    /// 可选字符串：nil ⇒ `—`，空串 ⇒ `‹空›`，其余原样。
    public static func text(_ value: String?) -> String {
        guard let value else { return noValue }
        return value.isEmpty ? emptyValue : value
    }

    /// 可选值统一入口。
    public static func value<T>(_ value: T?) -> String {
        guard let value else { return noValue }
        return String(describing: value)
    }

    /// 列宽按实际内容算，最后一列不右侧补空格（管道/终端都干净）。
    public static func render(headers: [String], rows: [[String]]) -> String {
        guard !headers.isEmpty else { return "" }
        var widths = headers.map(\.count)
        for row in rows {
            for (index, cell) in row.enumerated() where index < widths.count {
                widths[index] = max(widths[index], cell.count)
            }
        }
        var lines: [String] = []
        lines.append(joined(headers, widths: widths, padLast: false))
        lines.append(widths.map { String(repeating: "-", count: max(1, $0)) }.joined(separator: "  "))
        for row in rows {
            lines.append(joined(row, widths: widths, padLast: false))
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func joined(_ cells: [String], widths: [Int], padLast: Bool) -> String {
        var parts: [String] = []
        for (index, cell) in cells.enumerated() where index < widths.count {
            let isLast = index == min(cells.count, widths.count) - 1
            parts.append(isLast && !padLast ? cell : cell.padding(toLength: widths[index], withPad: " ", startingAt: 0))
        }
        return parts.joined(separator: "  ").trimmingCharacters(in: .whitespaces)
    }
}

/// 时间 / 字节 / 时长的人类可读写法。全部固定 POSIX 区域与本地时区，
/// 这样同一份数据在同一台机器上每次输出逐字相同（用例可以断字面量）。
public enum AixFormat {
    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    public static func date(_ date: Date?) -> String {
        guard let date else { return AixTable.noValue }
        return stamp.string(from: date)
    }

    public static func duration(_ seconds: Double?) -> String {
        guard let seconds else { return AixTable.noValue }
        if seconds < 60 { return String(format: "%.0fs", seconds) }
        if seconds < 3600 { return String(format: "%.0fm%02.0fs", seconds / 60, seconds.truncatingRemainder(dividingBy: 60)) }
        return String(format: "%.0fh%02.0fm", seconds / 3600, (seconds / 60).truncatingRemainder(dividingBy: 60))
    }

    public static func bytes(_ count: UInt64) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var value = Double(count)
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        return index == 0 ? "\(count) B" : String(format: "%.1f %@", value, units[index])
    }

    /// `nil` 与 0 必须分得开：0 是「测到 0」，nil 是「没这个数」。
    public static func optionalBytes(_ count: UInt64?) -> String {
        guard let count else { return AixTable.noValue }
        return bytes(count)
    }

    public static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}
