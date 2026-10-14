//
//  Observability+Formatting.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 冻结契约。共享格式化工具，UI 与 Engine 均可使用。
//

import Foundation

// MARK: - Duration

public enum DurationFormat {
    /// "2小时15分钟" / "18分32秒" / "0.8秒"
    public static func humanReadable(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        if total == 0 { return seconds > 0 ? String(format: "%.1f秒", seconds) : "0秒" }
        let days = total / 86_400
        let hours = (total % 86_400) / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60

        var parts: [String] = []
        if days > 0 { parts.append("\(days)天") }
        if hours > 0 { parts.append("\(hours)小时") }
        if minutes > 0 && days == 0 { parts.append("\(minutes)分钟") }
        if secs > 0 && days == 0 && hours == 0 { parts.append("\(secs)秒") }
        return parts.isEmpty ? "0秒" : parts.joined()
    }

    /// "6h32m" 紧凑形式，用于 Dashboard 卡片。
    public static func compact(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "—" }
        let total = Int(seconds.rounded())
        let hours = total / 3_600
        let minutes = (total % 3_600) / 60
        let secs = total % 60
        if hours > 0 { return "\(hours)h\(minutes)m" }
        if minutes > 0 { return "\(minutes)m\(secs)s" }
        return "\(secs)s"
    }

    /// "14:22:01"
    public static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded()))
        return String(format: "%02d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
    }
}

// MARK: - Byte Format

public enum ByteFormat {
    private static let units = ["B", "KB", "MB", "GB", "TB", "PB"]

    /// "2.4 GB"
    public static func humanReadable(_ bytes: UInt64) -> String {
        humanReadable(Double(bytes))
    }

    public static func humanReadable(_ bytes: Double) -> String {
        guard bytes.isFinite, bytes >= 0 else { return "—" }
        var value = bytes
        var index = 0
        while value >= 1024, index < units.count - 1 {
            value /= 1024
            index += 1
        }
        if index == 0 { return String(format: "%.0f %@", value, units[index]) }
        return String(format: "%.1f %@", value, units[index])
    }

    /// "320MB/s"
    public static func rate(_ bytesPerSecond: Double) -> String {
        humanReadable(bytesPerSecond) + "/s"
    }
}

// MARK: - Date Format

public enum DateFormat {
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "HH:mm:ss"
        return f
    }()

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    public static func time(_ date: Date) -> String { timeFormatter.string(from: date) }
    public static func timestamp(_ date: Date) -> String { timestampFormatter.string(from: date) }
    public static func day(_ date: Date) -> String { dayFormatter.string(from: date) }
}

// MARK: - Percentage Format

public enum PercentFormat {
    /// "18%" 或 "18.4%"
    public static func short(_ value: Double, fractionDigits: Int = 0) -> String {
        guard value.isFinite else { return "—" }
        return String(format: "%.\(fractionDigits)f%%", value)
    }
}

// MARK: - Path Helpers

public enum PathHeuristics {
    /// 常见敏感目录前缀（供风险规则与 UI 分组使用）。
    public static let sensitivePrefixes: [String] = [
        "/etc", "/var", "/usr", "/bin", "/sbin", "/System", "/Library",
        "/private/etc", "/private/var",
        NSString(string: "~/.ssh").expandingTildeInPath,
        NSString(string: "~/.aws").expandingTildeInPath,
        NSString(string: "~/.gnupg").expandingTildeInPath,
        NSString(string: "~/.config").expandingTildeInPath,
        NSString(string: "~/Library/Keychains").expandingTildeInPath,
        NSString(string: "~/Library/Application Support").expandingTildeInPath
    ]

    public static func isSensitive(_ path: String) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        return sensitivePrefixes.contains { expanded == $0 || expanded.hasPrefix($0 + "/") }
    }

    /// 判定某个路径是否落在给定根目录集合内。
    public static func isDescendant(_ path: String, of roots: [String]) -> Bool {
        let expanded = NSString(string: path).expandingTildeInPath
        return roots.contains { root in
            let r = NSString(string: root).expandingTildeInPath
            return expanded == r || expanded.hasPrefix(r.hasSuffix("/") ? r : r + "/")
        }
    }

    /// 向上回溯，找到最接近的 git 仓库根（不执行 git 命令，纯文件探测）。
    public static func enclosingProjectRoot(for path: String, fileManager: FileManager = .default) -> String? {
        var url = URL(fileURLWithPath: NSString(string: path).expandingTildeInPath).deletingLastPathComponent()
        let home = fileManager.homeDirectoryForCurrentUser.path
        var guardCounter = 0
        while url.path != "/" && url.path != home && guardCounter < 64 {
            if fileManager.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return url.path
            }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { break }
            url = parent
            guardCounter += 1
        }
        return nil
    }
}

// MARK: - Glob-ish Pattern Matching

public enum PatternMatcher {
    /// 轻量通配符匹配，支持 `*` 与 `?`，用于忽略路径规则。
    public static func matches(pattern: String, path: String) -> Bool {
        guard !pattern.isEmpty else { return false }
        let expandedPattern = NSString(string: pattern).expandingTildeInPath
        let expandedPath = NSString(string: path).expandingTildeInPath
        return wildcardMatch(pattern: Array(expandedPattern), text: Array(expandedPath))
    }

    public static func matchesAny(patterns: [String], path: String) -> Bool {
        patterns.contains { matches(pattern: $0, path: path) }
    }

    private static func wildcardMatch(pattern: [Character], text: [Character]) -> Bool {
        var p = 0, t = 0
        var starIndex = -1, matchIndex = 0
        while t < text.count {
            if p < pattern.count && (pattern[p] == "?" || pattern[p] == text[t]) {
                p += 1; t += 1
            } else if p < pattern.count && pattern[p] == "*" {
                starIndex = p
                matchIndex = t
                p += 1
            } else if starIndex != -1 {
                p = starIndex + 1
                matchIndex += 1
                t = matchIndex
            } else {
                return false
            }
        }
        while p < pattern.count && pattern[p] == "*" { p += 1 }
        return p == pattern.count
    }
}
