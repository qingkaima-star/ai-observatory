//
//  ExportSchema.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（主代理 · 共享脊柱，子代理只读）
//
//  字段选择的唯一真相：CSV 表头、Markdown 列、字段名校验全部来自这里。
//  约定：
//   · 枚举输出 rawValue（ASCII、稳定），布尔输出 true/false，数值走 ExportText；
//   · 字符串列**不做脱敏**，由导出器在写出前统一过 ExportRedactor（避免双份实现漂移）；
//   · 所有取值必须是记录自身的纯函数 —— 不得读 Date()、文件系统、环境变量。
//

import Foundation
import AIObservatoryCore

/// 一个可导出的列。相等性只看 `name`/`title`（闭包不参与比较）。
public struct ExportColumn: Sendable, Hashable {
    public let name: String
    public let title: String
    public let isDateValue: Bool
    public let value: @Sendable (ExportRecord) -> String

    public init(name: String, title: String, isDateValue: Bool = false,
                value: @escaping @Sendable (ExportRecord) -> String) {
        self.name = name
        self.title = title
        self.isDateValue = isDateValue
        self.value = value
    }

    public static func == (lhs: ExportColumn, rhs: ExportColumn) -> Bool {
        lhs.name == rhs.name && lhs.title == rhs.title && lhs.isDateValue == rhs.isDateValue
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(name)
        hasher.combine(title)
        hasher.combine(isDateValue)
    }
}

/// 各记录 kind 的列定义与字段选择。
public enum ExportSchema {
    /// 承载记录的 kind（不含 `.report`）。
    public static let allRecordKinds: [ExportKind] = [.sessions, .timeline, .fileChanges, .commands, .riskEvents]

    /// 该 kind 的全部列（顺序即 CSV 表头顺序）。
    ///
    /// - Parameter referenceDate: 计算「运行中会话」时长用的注入时刻（一般是 `request.generatedAt`）。
    ///   传 `nil` 时运行中会话的 `duration_seconds` 留空 —— 导出层绝不读墙钟。
    public static func columns(for kind: ExportKind, referenceDate: Date? = nil) throws -> [ExportColumn] {
        switch kind {
        case .sessions:     return sessionColumns(referenceDate: referenceDate)
        case .timeline:     return eventColumns
        case .fileChanges:  return fileChangeColumns
        case .commands:     return commandColumns
        case .riskEvents:   return riskColumns
        case .report:       throw ExportError.unsupportedFieldSelection(kind: .report)
        }
    }

    public static func fieldNames(for kind: ExportKind) throws -> [String] {
        try columns(for: kind).map(\.name)
    }

    /// 按 `names` 选择列，**保持定义顺序**；未知名抛 `ExportError.unknownFieldName`。
    /// `names == nil` 等价于全字段；`names == []` 视为非法请求。
    public static func columns(for kind: ExportKind, selected names: [String]?,
                              referenceDate: Date? = nil) throws -> [ExportColumn] {
        guard let names else { return try columns(for: kind, referenceDate: referenceDate) }
        guard !names.isEmpty else { throw ExportError.invalidRequest(ExportCopy.reasonEmptyFieldSelection.text()) }
        let available = try columns(for: kind, referenceDate: referenceDate)
        let wanted = Set(names)
        guard let unknown = names.first(where: { name in !available.contains { $0.name == name } }) else {
            return available.filter { wanted.contains($0.name) }
        }
        throw ExportError.unknownFieldName(field: unknown, kind: kind)
    }

    // MARK: - Factories

    private static func text(_ name: String, _ title: String,
                             _ get: @escaping @Sendable (ExportRecord) -> String) -> ExportColumn {
        ExportColumn(name: name, title: title) { record in get(record) }
    }

    private static func optionalText(_ name: String, _ title: String,
                                     _ get: @escaping @Sendable (ExportRecord) -> String?) -> ExportColumn {
        ExportColumn(name: name, title: title) { record in get(record) ?? ExportConstants.missingValue }
    }

    private static func date(_ name: String, _ title: String,
                             _ get: @escaping @Sendable (ExportRecord) -> Date?) -> ExportColumn {
        let encoder = ExportDateEncoder()
        return ExportColumn(name: name, title: title, isDateValue: true) { record in
            encoder.string(get(record))
        }
    }

    private static func int(_ name: String, _ title: String,
                            _ get: @escaping @Sendable (ExportRecord) -> Int) -> ExportColumn {
        ExportColumn(name: name, title: title) { record in ExportText.integer(get(record)) }
    }

    private static func optionalInt(_ name: String, _ title: String,
                                    _ get: @escaping @Sendable (ExportRecord) -> Int?) -> ExportColumn {
        ExportColumn(name: name, title: title) { record in ExportText.integer(get(record)) }
    }

    private static func decimal(_ name: String, _ title: String, digits: Int = 3,
                                _ get: @escaping @Sendable (ExportRecord) -> Double?) -> ExportColumn {
        ExportColumn(name: name, title: title) { record in ExportText.double(get(record), fractionDigits: digits) }
    }

    private static func integer64(_ name: String, _ title: String,
                                  _ get: @escaping @Sendable (ExportRecord) -> UInt64) -> ExportColumn {
        ExportColumn(name: name, title: title) { record in ExportText.bytes(get(record)) }
    }

    private static func optionalInteger64(_ name: String, _ title: String,
                                          _ get: @escaping @Sendable (ExportRecord) -> UInt64?) -> ExportColumn {
        ExportColumn(name: name, title: title) { record in ExportText.bytes(get(record)) }
    }

    private static func bool(_ name: String, _ title: String,
                             _ get: @escaping @Sendable (ExportRecord) -> Bool) -> ExportColumn {
        ExportColumn(name: name, title: title) { record in ExportText.boolean(get(record)) }
    }

    // MARK: - Sessions

    private static func sessionColumns(referenceDate: Date?) -> [ExportColumn] {
        [
            text("session_id", "Session ID") { $0.session?.id.uuidString ?? ExportConstants.missingValue },
            int("display_index", "Index") { $0.session?.displayIndex ?? 0 },
            text("agent_kind", "Agent Kind") { $0.agentKind.rawValue },
            text("title", "Title") { $0.session?.title ?? ExportConstants.missingValue },
            optionalText("project_path", "Project Path") { $0.session?.projectPath },
            date("started_at", "Started At") { $0.session?.startedAt },
            date("ended_at", "Ended At") { $0.session?.endedAt },
            // 运行中会话的时长只在调用方注入 referenceDate 时才写（契约的 duration(until:) 语义），
            // 绝不读墙钟 —— 否则「同输入同字节」不成立。
            decimal("duration_seconds", "Duration (s)", digits: 1) { record in
                guard let session = record.session else { return nil }
                if let endedAt = session.endedAt { return endedAt.timeIntervalSince(session.startedAt) }
                guard let referenceDate else { return nil }
                return session.duration(until: referenceDate)
            },
            text("outcome", "Outcome") { $0.session?.outcome.rawValue ?? ExportConstants.missingValue },
            int("modified_files", "Modified Files") { $0.session?.modifiedFileCount ?? 0 },
            int("created_files", "Created Files") { $0.session?.createdFileCount ?? 0 },
            int("deleted_files", "Deleted Files") { $0.session?.deletedFileCount ?? 0 },
            int("commands", "Commands") { $0.session?.commandCount ?? 0 },
            int("failed_commands", "Failed Commands") { $0.session?.failedCommandCount ?? 0 },
            decimal("cpu_seconds", "CPU Seconds") { $0.session?.cpuSeconds },
            decimal("peak_cpu_percent", "Peak CPU %", digits: 1) { $0.session?.peakCPUPercent },
            integer64("peak_memory_bytes", "Peak Memory Bytes") { $0.session?.peakMemoryBytes ?? 0 },
            int("estimated_tokens", "Estimated Tokens") { $0.session?.estimatedTokens ?? 0 },
            int("risk_events", "Risk Events") { $0.session?.riskEventCount ?? 0 }
        ]
    }

    // MARK: - Timeline

    private static var eventColumns: [ExportColumn] {
        [
            text("event_id", "Event ID") { $0.event?.id.uuidString ?? ExportConstants.missingValue },
            date("timestamp", "Timestamp") { $0.event?.timestamp },
            optionalText("session_id", "Session ID") { $0.event?.sessionID?.uuidString },
            text("agent_kind", "Agent Kind") { $0.agentKind.rawValue },
            text("operation_kind", "Operation") { $0.event?.kind.rawValue ?? ExportConstants.missingValue },
            text("title", "Title") { $0.event?.title ?? ExportConstants.missingValue },
            text("summary", "Summary") { $0.event?.summary ?? ExportConstants.missingValue },
            optionalText("file_path", "File Path") { $0.event?.filePath },
            optionalText("command", "Command") { $0.event?.command },
            optionalInt("exit_code", "Exit Code") { $0.event?.exitCode.map(Int.init) },
            decimal("duration_seconds", "Duration (s)", digits: 1) { $0.event?.durationSeconds },
            text("risk_level", "Risk") { $0.event?.riskLevel.rawValue ?? ExportConstants.missingValue },
            optionalText("project_path", "Project Path") { $0.event?.projectPath },
            decimal("cpu_seconds", "CPU Seconds") { $0.event?.cost.cpuSeconds },
            integer64("memory_bytes", "Memory Bytes") { $0.event?.cost.memoryBytes ?? 0 },
            integer64("bytes_read", "Bytes Read") { $0.event?.cost.bytesRead ?? 0 },
            integer64("bytes_written", "Bytes Written") { $0.event?.cost.bytesWritten ?? 0 }
        ]
    }

    // MARK: - File Changes

    private static var fileChangeColumns: [ExportColumn] {
        [
            text("change_id", "Change ID") { $0.fileChange?.id.uuidString ?? ExportConstants.missingValue },
            date("timestamp", "Timestamp") { $0.fileChange?.timestamp },
            text("path", "Path") { $0.fileChange?.path ?? ExportConstants.missingValue },
            optionalText("previous_path", "Previous Path") { $0.fileChange?.previousPath },
            text("change_kind", "Change Kind") { $0.fileChange?.kind.rawValue ?? ExportConstants.missingValue },
            text("agent_kind", "Agent Kind") { $0.agentKind.rawValue },
            optionalText("session_id", "Session ID") { $0.fileChange?.sessionID?.uuidString },
            integer64("size_bytes", "Size Bytes") { $0.fileChange?.sizeBytes ?? 0 },
            optionalInteger64("previous_size_bytes", "Previous Size Bytes") { $0.fileChange?.previousSizeBytes },
            bool("is_text", "Is Text") { $0.fileChange?.isText ?? false },
            int("lines_added", "Lines Added") { $0.fileChange?.linesAdded ?? 0 },
            int("lines_removed", "Lines Removed") { $0.fileChange?.linesRemoved ?? 0 },
            text("risk_level", "Risk") { $0.fileChange?.riskLevel.rawValue ?? ExportConstants.missingValue },
            optionalText("project_path", "Project Path") { $0.fileChange?.projectPath }
        ]
    }

    // MARK: - Commands

    private static var commandColumns: [ExportColumn] {
        [
            text("command_id", "Command ID") { $0.command?.id.uuidString ?? ExportConstants.missingValue },
            date("started_at", "Started At") { $0.command?.startedAt },
            date("ended_at", "Ended At") { $0.command?.endedAt },
            text("executable", "Executable") { $0.command?.executable ?? ExportConstants.missingValue },
            text("arguments", "Arguments") { record in
                ExportText.list(record.command?.arguments ?? [])
            },
            text("command_line", "Command Line") { $0.command?.commandLine ?? ExportConstants.missingValue },
            optionalText("working_directory", "Working Directory") { $0.command?.workingDirectory },
            text("agent_kind", "Agent Kind") { $0.agentKind.rawValue },
            optionalText("session_id", "Session ID") { $0.command?.sessionID?.uuidString },
            optionalInt("exit_code", "Exit Code") { $0.command?.exitCode.map(Int.init) },
            text("outcome", "Outcome") { $0.command?.outcome.rawValue ?? ExportConstants.missingValue },
            bool("is_destructive", "Destructive") { $0.command?.isDestructive ?? false },
            bool("requires_confirmation", "Requires Confirmation") { $0.command?.requiresConfirmation ?? false },
            text("risk_level", "Risk") { $0.command?.riskLevel.rawValue ?? ExportConstants.missingValue },
            optionalText("project_path", "Project Path") { $0.command?.projectPath }
        ]
    }

    // MARK: - Risk Events

    private static var riskColumns: [ExportColumn] {
        [
            text("risk_id", "Risk ID") { $0.riskEvent?.id.uuidString ?? ExportConstants.missingValue },
            date("timestamp", "Timestamp") { $0.riskEvent?.timestamp },
            text("level", "Level") { $0.riskEvent?.level.rawValue ?? ExportConstants.missingValue },
            text("category", "Category") { $0.riskEvent?.category.rawValue ?? ExportConstants.missingValue },
            text("title", "Title") { $0.riskEvent?.title ?? ExportConstants.missingValue },
            text("detail", "Detail") { $0.riskEvent?.detail ?? ExportConstants.missingValue },
            text("agent_kind", "Agent Kind") { $0.agentKind.rawValue },
            optionalText("session_id", "Session ID") { $0.riskEvent?.sessionID?.uuidString },
            optionalText("command", "Command") { $0.riskEvent?.command },
            text("file_paths", "File Paths") { record in
                ExportText.list(record.riskEvent?.filePaths ?? [])
            },
            bool("requires_confirmation", "Requires Confirmation") { $0.riskEvent?.requiresConfirmation ?? false },
            bool("is_acknowledged", "Acknowledged") { $0.riskEvent?.isAcknowledged ?? false },
            optionalText("matched_rule_id", "Matched Rule ID") { $0.riskEvent?.matchedRuleID }
        ]
    }
}
