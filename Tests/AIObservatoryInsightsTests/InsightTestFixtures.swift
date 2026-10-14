//
//  InsightTestFixtures.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  确定性夹具：所有时间都由 `epoch` 偏移得到，测试绝不依赖运行时刻。
//

import Foundation
import AIObservatoryCore

/// 浮点近似比较（Swift Testing 没有内置 accuracy 断言写法，统一用绝对误差）。
func aixClose(_ lhs: Double, _ rhs: Double, tolerance: Double = 1e-9) -> Bool {
    if lhs.isNaN || rhs.isNaN { return lhs.isNaN && rhs.isNaN }
    return abs(lhs - rhs) < tolerance
}

func aixOptionalClose(_ lhs: Double?, _ rhs: Double?, tolerance: Double = 1e-9) -> Bool {
    switch (lhs, rhs) {
    case (.none, .none): return true
    case let (.some(a), .some(b)): return aixClose(a, b, tolerance: tolerance)
    default: return false
    }
}

enum InsightFixtures {
    /// 2026-01-01T00:00:00Z。
    static let epoch = Date(timeIntervalSince1970: 1_767_225_600)
    static let day: TimeInterval = 86_400
    static let hour: TimeInterval = 3_600

    static func at(_ seconds: TimeInterval) -> Date { epoch.addingTimeInterval(seconds) }
    static func days(_ n: Double) -> Date { epoch.addingTimeInterval(n * day) }
    static func hours(_ n: Double) -> Date { epoch.addingTimeInterval(n * hour) }
    static func minutes(_ n: Double) -> Date { epoch.addingTimeInterval(n * 60) }

    static func change(
        _ path: String,
        at date: Date,
        agent: AgentKind = .claudeCode,
        kind: FileChangeKind = .modified,
        added: Int = 0,
        removed: Int = 0,
        isText: Bool = true
    ) -> FileChange {
        FileChange(
            path: path,
            kind: kind,
            timestamp: date,
            agentKind: agent,
            isText: isText,
            linesAdded: added,
            linesRemoved: removed
        )
    }

    static func command(
        _ executable: String = "git",
        startedAt: Date,
        endedAt: Date? = nil,
        outcome: CommandOutcome = .success,
        exitCode: Int32? = 0,
        agent: AgentKind = .claudeCode,
        destructive: Bool = false
    ) -> CommandRecord {
        CommandRecord(
            executable: executable,
            agentKind: agent,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: exitCode,
            outcome: outcome,
            isDestructive: destructive
        )
    }

    static func event(
        at date: Date,
        agent: AgentKind = .claudeCode,
        kind: OperationKind = .fileModified
    ) -> TimelineEvent {
        TimelineEvent(timestamp: date, agentKind: agent, kind: kind, title: "fixture")
    }

    static func session(
        _ agent: AgentKind,
        startedAt: Date,
        endedAt: Date?,
        cpuSeconds: Double = 0,
        commandCount: Int = 0,
        failedCommandCount: Int = 0
    ) -> AgentSession {
        AgentSession(
            kind: agent,
            startedAt: startedAt,
            endedAt: endedAt,
            commandCount: commandCount,
            failedCommandCount: failedCommandCount,
            cpuSeconds: cpuSeconds
        )
    }

    static func sample(at date: Date, cpu: Double) -> SystemPerformanceSample {
        SystemPerformanceSample(timestamp: date, cpuTotalPercent: cpu)
    }

    static func risk(_ level: RiskLevel = .high) -> RiskEvent {
        RiskEvent(timestamp: epoch, level: level, category: .unknown, title: "fixture")
    }

    /// 生成 `count` 条改动，路径为 `prefix<i>.<ext>`（**每条一个不同文件**），时间从 `start` 起每 `step` 秒一条。
    static func changes(
        count: Int,
        pathPrefix: String = "f",
        ext: String = "swift",
        start: Date,
        step: TimeInterval,
        agent: AgentKind = .claudeCode,
        added: Int = 1,
        removed: Int = 0
    ) -> [FileChange] {
        (0..<count).map { index in
            change(
                "\(pathPrefix)\(index).\(ext)",
                at: start.addingTimeInterval(Double(index) * step),
                agent: agent,
                added: added,
                removed: removed
            )
        }
    }

    /// **同一个文件**的 `count` 次改动：测「重复修改衰减 / 多 Agent 触碰」时必须用它，
    /// 用 `changes(count:)` 会得到 N 个不同文件、每个 1 次改动，语义完全不同。
    static func editsToFile(
        path: String,
        count: Int,
        start: Date,
        step: TimeInterval,
        agents: [AgentKind] = [.claudeCode]
    ) -> [FileChange] {
        (0..<count).map { index in
            change(path, at: start.addingTimeInterval(Double(index) * step), agent: agents[index % agents.count])
        }
    }
}
