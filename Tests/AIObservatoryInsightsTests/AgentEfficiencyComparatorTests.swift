//
//  AgentEfficiencyComparatorTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  效率对比验收：派生比率命中手算值；没有对照组就不排名；
//  运行中会话的活跃时长必须由注入的 referenceDate 决定（绝不读墙钟）。
//

import Testing
import Foundation
import AIObservatoryCore
@testable import AIObservatoryInsights

@Suite("Agent 效率对比", .timeLimit(.minutes(1)))
struct AgentEfficiencyComparatorTests {

    private let start = InsightFixtures.epoch
    private let reference = InsightFixtures.hours(1)

    private var twoAgentSessions: [AgentSession] {
        [
            InsightFixtures.session(.claudeCode, startedAt: start, endedAt: start.addingTimeInterval(100), cpuSeconds: 20),
            InsightFixtures.session(.claudeCode, startedAt: start.addingTimeInterval(1_800), endedAt: start.addingTimeInterval(1_900), cpuSeconds: 20),
            InsightFixtures.session(.openAICodex, startedAt: start.addingTimeInterval(3_500), endedAt: start.addingTimeInterval(3_600), cpuSeconds: 30)
        ]
    }

    private var twoAgentChanges: [FileChange] {
        InsightFixtures.changes(count: 10, pathPrefix: "k", start: start, step: 60, agent: .claudeCode)
            + InsightFixtures.changes(count: 2, pathPrefix: "x", start: start, step: 60, agent: .openAICodex)
    }

    private var twoAgentCommands: [CommandRecord] {
        var rows: [CommandRecord] = []
        rows += (0..<18).map { _ in
            InsightFixtures.command("git", startedAt: start, endedAt: start.addingTimeInterval(1), outcome: .success, exitCode: 0, agent: .claudeCode)
        }
        rows += (0..<2).map { _ in
            InsightFixtures.command("rm", startedAt: start, endedAt: start.addingTimeInterval(1), outcome: .failure, exitCode: 1, agent: .claudeCode)
        }
        rows += (0..<4).map { _ in
            InsightFixtures.command("ls", startedAt: start, endedAt: start.addingTimeInterval(1), outcome: .success, exitCode: 0, agent: .openAICodex)
        }
        rows.append(
            InsightFixtures.command("cargo", startedAt: start, endedAt: start.addingTimeInterval(1), outcome: .failure, exitCode: 101, agent: .openAICodex)
        )
        return rows
    }

    private func compare(
        sessions: [AgentSession],
        changes: [FileChange],
        commands: [CommandRecord]
    ) -> AgentEfficiencyComparison {
        AgentEfficiencyComparator.compare(
            sessions: sessions, changes: changes, commands: commands, referenceDate: reference
        )
    }

    @Test("两 Agent 对比：比率命中手算值，Claude 既是产出最高也是单位成本最低")
    func twoAgentComparisonMatchesHandComputation() {
        let result = compare(sessions: twoAgentSessions, changes: twoAgentChanges, commands: twoAgentCommands)
        #expect(result.rows.map(\.agentKind) == [.claudeCode, .openAICodex])

        let claude = result.rows[0]
        #expect(claude.sessionCount == 2)
        #expect(claude.activeSeconds == 200)
        #expect(claude.cpuSeconds == 40)
        #expect(claude.changeCount == 10)
        #expect(claude.distinctFileCount == 10)
        #expect(claude.commandCount == 20)
        #expect(claude.failedCommandCount == 2)
        #expect(aixOptionalClose(claude.commandSuccessRate, 0.9))
        #expect(aixOptionalClose(claude.filesPerSecond, 0.05))
        #expect(aixOptionalClose(claude.cpuSecondsPerFile, 4))

        let codex = result.rows[1]
        #expect(codex.activeSeconds == 100)
        #expect(codex.distinctFileCount == 2)
        #expect(aixOptionalClose(codex.commandSuccessRate, 0.8))
        #expect(aixOptionalClose(codex.filesPerSecond, 0.02))
        #expect(aixOptionalClose(codex.cpuSecondsPerFile, 15))

        #expect(result.mostEfficientAgent == .claudeCode)
        #expect(result.cheapestAgent == .claudeCode)
        // 40 条观测 + 覆盖 3600s + 无未结束会话 → 足够下结论
        #expect(result.confidence == .high)
        #expect(result.basis.isEmpty == false)
    }

    @Test("只有一个 Agent：不给排名，basis 说明缺少对照组")
    func singleAgentGetsNoRanking() {
        let result = compare(
            sessions: [InsightFixtures.session(.claudeCode, startedAt: start, endedAt: start.addingTimeInterval(100), cpuSeconds: 10)],
            changes: InsightFixtures.changes(count: 5, start: start, step: 10),
            commands: []
        )
        #expect(result.rows.count == 1)
        #expect(result.mostEfficientAgent == nil)
        #expect(result.cheapestAgent == nil)
        #expect(result.basis.contains("对照"))
    }

    @Test("归属不明 Agent 进表但不参与排名（只剩它自己时不排名）")
    func unknownAgentNeverWins() {
        let result = compare(
            sessions: [
                InsightFixtures.session(.unknown, startedAt: start, endedAt: start.addingTimeInterval(10), cpuSeconds: 1),
                InsightFixtures.session(.claudeCode, startedAt: start, endedAt: start.addingTimeInterval(100), cpuSeconds: 10)
            ],
            changes: InsightFixtures.changes(count: 20, pathPrefix: "u", start: start, step: 10, agent: .unknown)
                + InsightFixtures.changes(count: 2, pathPrefix: "c", start: start, step: 10, agent: .claudeCode),
            commands: []
        )
        #expect(result.rows.map(\.agentKind) == [.claudeCode, .unknown])
        #expect(result.mostEfficientAgent == nil)
        #expect(result.cheapestAgent == nil)
    }

    @Test("运行中会话：活跃时长按注入的 referenceDate 计算，绝不读墙钟")
    func runningSessionUsesInjectedReference() {
        let sessions = [InsightFixtures.session(.cursorAgent, startedAt: start, endedAt: nil, cpuSeconds: 10)]
        let changes = InsightFixtures.changes(count: 1, pathPrefix: "r", start: start, step: 0, agent: .cursorAgent)
        let result = AgentEfficiencyComparator.compare(
            sessions: sessions,
            changes: changes,
            commands: [],
            referenceDate: start.addingTimeInterval(100)
        )
        // rows 按 rawValue 升序，显式取被验证的那一行，别依赖下标
        let row = result.rows.first { $0.agentKind == .cursorAgent }
        #expect(row?.sessionCount == 1)
        #expect(row?.activeSeconds == 100)
        #expect(aixOptionalClose(row?.filesPerSecond, 0.01))
        #expect(aixOptionalClose(row?.cpuSecondsPerFile, 10))
        // 会话未结束 → 活跃时长存疑，置信度必须被拉低
        #expect(result.confidence == .low)
    }

    @Test("零活跃时长：比率不可估计，返回 nil 而不是 inf/0")
    func zeroActiveSecondsYieldsNoRatio() {
        let result = compare(
            sessions: [InsightFixtures.session(.windsurf, startedAt: start, endedAt: start, cpuSeconds: 5)],
            changes: InsightFixtures.changes(count: 3, pathPrefix: "z", start: start, step: 0, agent: .windsurf),
            commands: []
        )
        let row = result.rows.first
        #expect(row?.activeSeconds == 0)
        #expect(row?.filesPerSecond == nil)
        #expect(row?.cpuSecondsPerFile.map { $0.isFinite } == true)
    }

    @Test("没有任何命令：成功率 nil（不等于 0% 成功）")
    func noCommandsMeansNoSuccessRate() {
        let result = compare(
            sessions: [InsightFixtures.session(.aiderCLI, startedAt: start, endedAt: start.addingTimeInterval(60), cpuSeconds: 3)],
            changes: InsightFixtures.changes(count: 2, pathPrefix: "n", start: start, step: 5),
            commands: []
        )
        #expect(result.rows.first?.commandSuccessRate == nil)
        #expect(result.rows.first?.commandCount == 0)
    }

    @Test("空输入：无行、无排名、置信度 low，不崩溃")
    func emptyInput() {
        let result = compare(sessions: [], changes: [], commands: [])
        #expect(result.rows.isEmpty)
        #expect(result.mostEfficientAgent == nil)
        #expect(result.cheapestAgent == nil)
        #expect(result.confidence == .low)
        #expect(result.basis.isEmpty == false)
    }

    @Test("样本减半 → 置信度下降")
    func confidenceDropsWithLessData() {
        let full = compare(sessions: twoAgentSessions, changes: twoAgentChanges, commands: twoAgentCommands)
        let halved = compare(
            sessions: [twoAgentSessions[0]],
            changes: Array(twoAgentChanges.prefix(6)),
            commands: Array(twoAgentCommands.prefix(12))
        )
        #expect(full.confidence == .high)
        #expect(halved.confidence < full.confidence)
    }
}
