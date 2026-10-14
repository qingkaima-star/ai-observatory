//
//  ExportKind.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（主代理 · 共享脊柱，子代理只读）
//

import Foundation
import AIObservatoryCore

/// 导出文件格式。
public enum ExportFormat: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case json
    case csv
    case markdown

    public var id: String { rawValue }

    /// 文件扩展名（不含点）。
    public var fileExtension: String {
        switch self {
        case .json:     return "json"
        case .csv:      return "csv"
        case .markdown: return "md"
        }
    }
}

/// 可导出的记录集合类型。`.report` 只代表人读报告，不承载记录。
public enum ExportKind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
    case sessions
    case timeline
    case fileChanges
    case commands
    case riskEvents
    case report

    public var id: String { rawValue }

    /// 类别的显示名。**显示时**按进程语言取（不落库，所以切语言立刻生效）。
    ///
    /// ⚠️ 当前全仓**没有消费者**读它（CSV 表头走 `ExportColumn.title`）；登记进 ``ExportCopy``
    /// 是为了 B3 接界面选择器时不会再退回裸字面量。这条「声明了但没人用」的事实写进了交付块。
    public var title: String {
        switch self {
        case .sessions:      return ExportCopy.kindSessions.text()
        case .timeline:      return ExportCopy.kindTimeline.text()
        case .fileChanges:   return ExportCopy.kindFileChanges.text()
        case .commands:      return ExportCopy.kindCommands.text()
        case .riskEvents:    return ExportCopy.kindRiskEvents.text()
        case .report:        return ExportCopy.kindReport.text()
        }
    }

    /// 默认文件名（不含时间戳与扩展名）。
    public var defaultFileName: String { rawValue }

    public var isRecordKind: Bool { self != .report }

    public var supportedFormats: [ExportFormat] {
        switch self {
        case .report: return [.markdown]
        default:      return [.json, .csv]
        }
    }

    /// `.report` 的概览所依赖的记录类别。
    ///
    /// 单独列出来是因为**"这次要写成哪些文件"与"报告要扫哪些数据"是两件事**：
    /// Markdown 导出的 kinds 只有 `.report`（其余 kind 不支持 markdown 编码），
    /// 若协调器只按 kinds 收集，报告就会拿着一份空记录算概览，
    /// 产出「0 会话 / 0 事件 / 0 风险」的空壳——见 `ExportCoordinator.run(_:service:)`。
    public static let reportSourceKinds: [ExportKind] = [
        .sessions, .timeline, .fileChanges, .commands, .riskEvents
    ]

    /// 该 kind 对应的 Core 模型说明，用于诊断信息。
    public var modelName: String {
        switch self {
        case .sessions:      return "AgentSession"
        case .timeline:      return "TimelineEvent"
        case .fileChanges:   return "FileChange"
        case .commands:      return "CommandRecord"
        case .riskEvents:    return "RiskEvent"
        case .report:        return "Report"
        }
    }
}

/// 导出层统一记录包装：所有导出器只面对 `ExportRecord`，避免为每个模型写一套流水线。
public enum ExportRecord: Sendable, Hashable {
    case session(AgentSession)
    case event(TimelineEvent)
    case fileChange(FileChange)
    case command(CommandRecord)
    case riskEvent(RiskEvent)

    public var kind: ExportKind {
        switch self {
        case .session:    return .sessions
        case .event:      return .timeline
        case .fileChange: return .fileChanges
        case .command:    return .commands
        case .riskEvent:  return .riskEvents
        }
    }

    /// 用于时间范围过滤与确定性排序的规范时间。
    public var timestamp: Date {
        switch self {
        case let .session(v):      return v.startedAt
        case let .event(v):        return v.timestamp
        case let .fileChange(v):   return v.timestamp
        case let .command(v):      return v.startedAt
        case let .riskEvent(v):    return v.timestamp
        }
    }

    /// 稳定标识（UUID 字符串 / 项目路径），用于同时间戳下的确定性排序。
    public var stableIdentifier: String {
        switch self {
        case let .session(v):      return v.id.uuidString
        case let .event(v):        return v.id.uuidString
        case let .fileChange(v):   return v.id.uuidString
        case let .command(v):      return v.id.uuidString
        case let .riskEvent(v):    return v.id.uuidString
        }
    }

    public var projectPath: String? {
        switch self {
        case let .session(v):      return v.projectPath
        case let .event(v):        return v.projectPath
        case let .fileChange(v):   return v.projectPath
        case let .command(v):      return v.projectPath
        case .riskEvent:           return nil
        }
    }

    public var agentKind: AgentKind {
        switch self {
        case let .session(v):      return v.kind
        case let .event(v):        return v.agentKind
        case let .fileChange(v):   return v.agentKind
        case let .command(v):      return v.agentKind
        case let .riskEvent(v):    return v.agentKind
        }
    }

    /// 风险等级；会话与命令记录以自身字段/事件语义映射。
    public var riskLevel: RiskLevel {
        switch self {
        case let .event(v):        return v.riskLevel
        case let .fileChange(v):   return v.riskLevel
        case let .command(v):      return v.riskLevel
        case let .riskEvent(v):    return v.level
        case .session:             return .low
        }
    }
    public var session: AgentSession? { if case let .session(v) = self { return v }; return nil }
    public var event: TimelineEvent? { if case let .event(v) = self { return v }; return nil }
    public var fileChange: FileChange? { if case let .fileChange(v) = self { return v }; return nil }
    public var command: CommandRecord? { if case let .command(v) = self { return v }; return nil }
    public var riskEvent: RiskEvent? { if case let .riskEvent(v) = self { return v }; return nil }
}

/// 导出层跨文件共享的常量：单一真相，保证 JSON/CSV/Markdown 输出一致。
public enum ExportConstants {
    /// JSON 顶层 `schemaVersion`。契约变更时递增。
    public static let schemaVersion: Int = 1
    /// 机器可读 schema 标识。
    public static let schemaVersionKey: String = "aiobservatory.export.v1"
    /// 顶层 `exportedBy`。
    // 显示名。改名只动这里；下面那条 `schemaVersionKey` 是**机器可读标识**，
    // 改了会让已导出的文件与新版本对不上 schema，属于契约变更而不是改名。
    public static let exportedBy: String = "AiX (local)"
    /// 脱敏占位符前后缀，形如 `‹redacted:openai_key›`。
    public static let redactionPrefix: String = "‹redacted:"
    public static let redactionSuffix: String = "›"
    /// 字段缺失时的 CSV 单元值。
    public static let missingValue: String = ""
    /// 布尔值的确定输出。
    public static let trueValue: String = "true"
    public static let falseValue: String = "false"
    /// 流式写入默认缓冲阈值。
    public static let defaultChunkThresholdBytes: Int = 16 * 1024
    /// 报告默认 Top N。
    public static let reportTopFiles: Int = 10
    public static let reportDangerousCommands: Int = 50
}
