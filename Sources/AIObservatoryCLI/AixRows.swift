//
//  AixRows.swift
//  AIObservatoryCLI
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  记录 → 人读表格的列。列的选择跟着「AI 自己来查」这个用途走：
//  先给能定位到具体一行的标识（会话号、路径、命令），再给量（时长、行数、等级）。
//  `nil` 一律 `—`、空串一律 `‹空›` —— 见 `AixTable` 的说明。
//

import Foundation
import AIObservatoryCore
import AIObservatoryExport

enum AixRows {
    static func table(kind: ExportKind, records: [ExportRecord]) -> (headers: [String], rows: [[String]]) {
        switch kind {
        case .sessions:
            let items = records.compactMap { record -> AgentSession? in
                if case .session(let value) = record { return value } else { return nil }
            }
            return (
                ["#", "Agent", "开始", "结束", "时长", "项目", "改/建/删", "命令", "风险", "结果"],
                items.map {
                    [String($0.displayIndex), $0.kind.displayName, AixFormat.date($0.startedAt),
                     AixFormat.date($0.endedAt), AixFormat.duration($0.endedAt?.timeIntervalSince($0.startedAt)),
                     AixTable.text($0.projectPath),
                     "\($0.modifiedFileCount)/\($0.createdFileCount)/\($0.deletedFileCount)",
                     "\($0.commandCount)", "\($0.riskEventCount)", $0.outcome.rawValue]
                }
            )
        case .timeline:
            let items = records.compactMap { record -> TimelineEvent? in
                if case .event(let value) = record { return value } else { return nil }
            }
            return (
                ["时间", "Agent", "类型", "标题", "风险", "时长", "文件/命令"],
                items.map {
                    [AixFormat.date($0.timestamp), $0.agentKind.displayName, $0.kind.rawValue, $0.title,
                     $0.riskLevel.rawValue, AixFormat.duration($0.durationSeconds),
                     AixTable.text($0.filePath ?? $0.command)]
                }
            )
        case .fileChanges:
            let items = records.compactMap { record -> FileChange? in
                if case .fileChange(let value) = record { return value } else { return nil }
            }
            return (
                ["时间", "变更", "Agent", "+/-", "大小", "风险", "路径", "归属"],
                items.map {
                    [AixFormat.date($0.timestamp), $0.kind.rawValue, $0.agentKind.displayName,
                     "+\($0.linesAdded)/-\($0.linesRemoved)", AixFormat.bytes($0.sizeBytes),
                     $0.riskLevel.rawValue, $0.path,
                     $0.agentID == nil ? "未归属" : "已归属"]
                }
            )
        case .commands:
            let items = records.compactMap { record -> CommandRecord? in
                if case .command(let value) = record { return value } else { return nil }
            }
            return (
                ["开始", "Agent", "退出码", "结果", "破坏性", "风险", "命令"],
                items.map {
                    [AixFormat.date($0.startedAt), $0.agentKind.displayName, AixTable.value($0.exitCode),
                     $0.outcome.rawValue, $0.isDestructive ? "是" : "否", $0.riskLevel.rawValue,
                     ($0.arguments.isEmpty ? $0.executable : $0.executable + " " + $0.arguments.joined(separator: " "))]
                }
            )
        case .riskEvents:
            let items = records.compactMap { record -> RiskEvent? in
                if case .riskEvent(let value) = record { return value } else { return nil }
            }
            return (
                ["时间", "等级", "类别", "标题", "Agent", "确认", "已阅", "规则"],
                items.map {
                    [AixFormat.date($0.timestamp), $0.level.rawValue, $0.category.rawValue, $0.title,
                     $0.agentKind.displayName, $0.requiresConfirmation ? "要" : "否",
                     $0.isAcknowledged ? "是" : "否", AixTable.text($0.matchedRuleID)]
                }
            )
        case .report:
            return ([], [])
        }
    }

    /// Agent 行单独一条：`activeAgents()` 给的是领域模型，不是 `ExportRecord`（导出层没有 agents 这个 kind）。
    static func agentTable(_ agents: [AgentInstance]) -> (headers: [String], rows: [[String]]) {
        (
            ["名称", "类型", "PID", "状态", "CPU%", "内存", "启动", "最近可见", "工作目录"],
            agents.map {
                [$0.displayName, $0.kind.displayName, String($0.pid), $0.state.rawValue,
                 String(format: "%.1f", $0.cpuPercent), AixFormat.bytes($0.memoryBytes),
                 AixFormat.date($0.startedAt), AixFormat.date($0.lastSeenAt), AixTable.text($0.workingDirectory)]
            }
        )
    }
}
