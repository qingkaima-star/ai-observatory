//
//  ProjectHealthSummaryTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  装配层验收：置信度取最弱一环、趋势在桶数不足时报 unknown、同样输入必须产出同样结果（纯函数）。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryInsights

@Suite("项目健康摘要装配", .timeLimit(.minutes(1)))
struct ProjectHealthSummaryTests {

    private let start = InsightFixtures.epoch
    private let oneHourEnd = InsightFixtures.hours(1)

    private func summary(
        changes: [FileChange],
        commands: [CommandRecord] = [],
        events: [TimelineEvent] = [],
        samples: [SystemPerformanceSample] = [],
        sessions: [AgentSession] = [],
        risks: [RiskEvent] = [],
        windowEnd: Date,
        bucketSeconds: Double = 3_600,
        topHotFileLimit: Int = 10
    ) -> ProjectHealthSummary {
        ProjectHealthAnalyzer.summarize(
            projectName: "AiX",
            projectPath: FixturePaths.projectRoot,
            changes: changes,
            commands: commands,
            events: events,
            systemSamples: samples,
            sessions: sessions,
            riskEvents: risks,
            windowStart: start,
            windowEnd: windowEnd,
            referenceDate: windowEnd,
            topHotFileLimit: topHotFileLimit,
            bucketSeconds: bucketSeconds
        )
    }

    @Test("小样本装配：热文件/风险计数/趋势/异常四份报告都到位，置信度只能是 low")
    func smallSampleAssembles() {
        let changes = [
            InsightFixtures.change("a.swift", at: start, added: 5),
            InsightFixtures.change("a.swift", at: InsightFixtures.minutes(10), added: 2, removed: 1),
            InsightFixtures.change("b.md", at: InsightFixtures.minutes(20), agent: .openAICodex, added: 3)
        ]
        let result = summary(
            changes: changes,
            commands: [InsightFixtures.command("git", startedAt: start, endedAt: InsightFixtures.minutes(1))],
            events: [InsightFixtures.event(at: start), InsightFixtures.event(at: InsightFixtures.minutes(5))],
            samples: [InsightFixtures.sample(at: start, cpu: 12)],
            sessions: [InsightFixtures.session(.claudeCode, startedAt: start, endedAt: InsightFixtures.minutes(30), cpuSeconds: 5)],
            risks: [InsightFixtures.risk(.high)],
            windowEnd: oneHourEnd
        )
        #expect(result.projectName == "AiX")
        #expect(result.fileChangeCount == 3)
        #expect(result.commandCount == 1)
        #expect(result.sessionCount == 1)
        #expect(result.topHotFiles.map(\.path) == ["a.swift", "b.md"])
        #expect(result.riskCounts.high == 1)
        #expect(result.riskCounts.total == 1)
        #expect(result.riskCounts.attentionCount == 1)
        // 单桶窗口既算不出增长趋势也判不出异常
        #expect(result.growthTrend == .unknown)
        #expect(result.activityTrend == .unknown)
        #expect(result.anomalies.count == 4)
        #expect(result.anomalies.allSatisfy { $0.anomalousObservations.isEmpty })
        #expect(result.anomalies.allSatisfy { $0.skippedReason != nil })
        #expect(result.confidence == .low)
        #expect(result.contribution.isHumanShareEstimable == false)
        #expect(result.basis.contains("整体置信度 LOW"))
    }

    @Test("分项置信度不齐时，摘要取最弱一环（不做平均掩盖短板）")
    func confidenceTakesWeakestPart() {
        // 40 条改动（充足）+ 1 条命令（严重不足）→ 摘要必须被命令那一侧拖到 low
        let changes = InsightFixtures.changes(count: 40, pathPrefix: "c", start: start, step: 100, added: 4, removed: 1)
        let result = summary(
            changes: changes,
            commands: [InsightFixtures.command("ls", startedAt: start, endedAt: InsightFixtures.minutes(1))],
            windowEnd: InsightFixtures.hours(2)
        )
        #expect(result.contribution.confidence == .high)
        #expect(result.throughput.confidence == .low)
        #expect(result.confidence == .low)
    }

    @Test("输入减半 → 摘要置信度严格下降")
    func halvingInputsLowersConfidence() {
        let changes = InsightFixtures.changes(count: 40, pathPrefix: "c", start: start, step: 180, added: 3)
        let commands = (0..<40).map {
            InsightFixtures.command(
                "git",
                startedAt: start.addingTimeInterval(Double($0) * 180),
                endedAt: start.addingTimeInterval(Double($0) * 180 + 1)
            )
        }
        let sessions = [
            InsightFixtures.session(.claudeCode, startedAt: start, endedAt: start.addingTimeInterval(100), cpuSeconds: 10),
            InsightFixtures.session(.claudeCode, startedAt: start.addingTimeInterval(1_200), endedAt: start.addingTimeInterval(1_300), cpuSeconds: 10),
            InsightFixtures.session(.openAICodex, startedAt: start.addingTimeInterval(2_400), endedAt: start.addingTimeInterval(2_500), cpuSeconds: 8),
            InsightFixtures.session(.openAICodex, startedAt: start.addingTimeInterval(3_600), endedAt: start.addingTimeInterval(3_700), cpuSeconds: 8)
        ]
        let full = summary(
            changes: changes,
            commands: commands,
            sessions: sessions,
            windowEnd: InsightFixtures.hours(2),
            bucketSeconds: 900
        )
        let halved = summary(
            changes: Array(changes.prefix(20)),
            commands: Array(commands.prefix(20)),
            sessions: Array(sessions.prefix(2)),
            windowEnd: InsightFixtures.hours(2),
            bucketSeconds: 900
        )
        #expect(full.confidence == .high)
        #expect(halved.confidence < full.confidence)
    }

    @Test("全空输入：结构仍然完整可渲染，各分项报「不可估计」而不是 0")
    func emptyProject() {
        let result = summary(changes: [], windowEnd: oneHourEnd)
        #expect(result.fileChangeCount == 0)
        #expect(result.topHotFiles.isEmpty)
        #expect(result.throughput.successRate == nil)
        #expect(result.contribution.humanShare == nil)
        #expect(result.codeGrowth.trend == .unknown)
        #expect(result.efficiency.rows.isEmpty)
        #expect(result.riskCounts.total == 0)
        #expect(result.growthTrend == .unknown)
        #expect(result.anomalies.allSatisfy { $0.anomalousObservations.isEmpty })
        #expect(result.confidence == .low)
        #expect(result.basis.isEmpty == false)
    }

    @Test("topHotFileLimit 生效：只要前 1 个热文件")
    func honoursTopLimit() {
        let changes = [
            InsightFixtures.change("hot.swift", at: start, agent: .claudeCode),
            InsightFixtures.change("hot.swift", at: InsightFixtures.minutes(30), agent: .openAICodex),
            InsightFixtures.change("cold.md", at: start, agent: .claudeCode)
        ]
        let result = summary(changes: changes, windowEnd: oneHourEnd, topHotFileLimit: 1)
        #expect(result.topHotFiles.count == 1)
        #expect(result.topHotFiles.first?.path == "hot.swift")
    }

    @Test("纯函数：同样的输入（含注入时间）两次调用结果完全相等")
    func isDeterministic() {
        let changes = [
            InsightFixtures.change("a.swift", at: start, added: 10),
            InsightFixtures.change("b.swift", at: InsightFixtures.minutes(20), agent: .openAICodex, added: 1, removed: 4)
        ]
        let first = summary(
            changes: changes,
            events: [InsightFixtures.event(at: start)],
            samples: [InsightFixtures.sample(at: start, cpu: 5)],
            sessions: [InsightFixtures.session(.claudeCode, startedAt: start, endedAt: InsightFixtures.minutes(10))],
            risks: [InsightFixtures.risk(.critical)],
            windowEnd: oneHourEnd
        )
        let second = summary(
            changes: changes,
            events: [InsightFixtures.event(at: start)],
            samples: [InsightFixtures.sample(at: start, cpu: 5)],
            sessions: [InsightFixtures.session(.claudeCode, startedAt: start, endedAt: InsightFixtures.minutes(10))],
            risks: [InsightFixtures.risk(.critical)],
            windowEnd: oneHourEnd
        )
        #expect(first == second)
    }

    @Test("风险计数按等级分桶，attentionCount 只算 high + critical")
    func riskTally() {
        let counts = ProjectHealthAnalyzer.riskCounts(from: [
            InsightFixtures.risk(.critical),
            InsightFixtures.risk(.high),
            InsightFixtures.risk(.high),
            InsightFixtures.risk(.medium),
            InsightFixtures.risk(.medium),
            InsightFixtures.risk(.medium),
            InsightFixtures.risk(.low)
        ])
        #expect(counts.critical == 1)
        #expect(counts.high == 2)
        #expect(counts.medium == 3)
        #expect(counts.low == 1)
        #expect(counts.total == 7)
        #expect(counts.attentionCount == 3)
        #expect(ProjectHealthAnalyzer.riskCounts(from: []).total == 0)
    }
}
