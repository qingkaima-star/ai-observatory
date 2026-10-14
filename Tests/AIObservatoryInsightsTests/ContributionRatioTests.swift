//
//  ContributionRatioTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  核心可信性验收：**没有人工基线时必须明写「不可估计」**，不能编一个人工占比。
//

import Testing
import Foundation
import AIObservatoryCore
@testable import AIObservatoryInsights

@Suite("Agent 参与占比", .timeLimit(.minutes(1)))
struct ContributionRatioTests {

    /// claude 5 · codex 3 · 归属不明 2，时间跨度 7200s。
    private var mixedTen: [FileChange] {
        var rows: [FileChange] = []
        for index in 0..<5 {
            rows.append(InsightFixtures.change("c\(index).swift", at: InsightFixtures.at(Double(index) * 800), agent: .claudeCode))
        }
        for index in 0..<3 {
            rows.append(InsightFixtures.change("x\(index).swift", at: InsightFixtures.at(Double(5 + index) * 800), agent: .openAICodex))
        }
        for index in 0..<2 {
            rows.append(InsightFixtures.change("u\(index).swift", at: InsightFixtures.at(Double(8 + index) * 800), agent: .unknown))
        }
        return rows
    }

    @Test("无人工基线：Agent 占比命中手算值，人工占比必须为 nil 并说明原因")
    func withoutHumanBaseline() {
        let result = ContributionRatioAnalyzer.analyze(
            agentChanges: mixedTen,
            humanChanges: nil,
            referenceDate: InsightFixtures.at(7_200)
        )
        #expect(result.agentShares.map(\.agentKind) == [.claudeCode, .openAICodex])
        #expect(aixClose(result.agentShares[0].share, 0.5))
        #expect(aixClose(result.agentShares[1].share, 0.3))
        #expect(aixClose(result.unattributedShare, 0.2))
        #expect(result.humanShare == nil)
        #expect(result.isHumanShareEstimable == false)
        #expect(result.basis.contains("未提供人工基线"))
        #expect(aixClose(result.shareTotal, 1))
        #expect(result.totalChangeCount == 10)
        #expect(result.agentChangeCount == 8)
        #expect(result.unattributedChangeCount == 2)
        // n=10、覆盖 7200s、缺失 0.2 → MEDIUM
        #expect(result.confidence == .medium)
    }

    @Test("给出人工基线：四类占比之和为 1，人工占比按总数分摊")
    func withHumanBaseline() {
        let human = (0..<6).map {
            InsightFixtures.change("h\($0).swift", at: InsightFixtures.at(Double($0) * 300), agent: .unknown)
        }
        let result = ContributionRatioAnalyzer.analyze(
            agentChanges: mixedTen,
            humanChanges: human,
            referenceDate: InsightFixtures.at(7_200)
        )
        #expect(result.totalChangeCount == 16)
        #expect(result.humanChangeCount == 6)
        #expect(aixOptionalClose(result.humanShare, 0.375))
        #expect(result.isHumanShareEstimable == true)
        let byKind = Dictionary(uniqueKeysWithValues: result.agentShares.map { ($0.agentKind, $0.share) })
        #expect(aixClose(byKind[.claudeCode] ?? -1, 0.3125))
        #expect(aixClose(byKind[.openAICodex] ?? -1, 0.1875))
        #expect(aixClose(result.unattributedShare, 0.125))
        #expect(aixClose(result.shareTotal, 1))
    }

    @Test("行数随占比一起汇总，供 UI 展示「谁写得多」")
    func linesAreAggregatedPerKind() {
        let rows = [
            InsightFixtures.change("a.swift", at: InsightFixtures.at(0), agent: .cursorAgent, added: 10, removed: 4),
            InsightFixtures.change("b.swift", at: InsightFixtures.at(60), agent: .cursorAgent, added: 5, removed: 1),
            InsightFixtures.change("c.swift", at: InsightFixtures.at(120), agent: .windsurf, added: 2, removed: 0)
        ]
        let result = ContributionRatioAnalyzer.analyze(
            agentChanges: rows, humanChanges: nil, referenceDate: InsightFixtures.at(120)
        )
        let cursor = result.agentShares.first { $0.agentKind == .cursorAgent }
        #expect(cursor?.changeCount == 2)
        #expect(cursor?.linesAdded == 15)
        #expect(cursor?.linesRemoved == 5)
        #expect(aixClose(cursor?.share ?? -1, 2.0 / 3.0))
    }

    @Test("全部归属不明：不给出任何 Agent 份额，置信度降为 low")
    func allUnattributed() {
        let rows = InsightFixtures.changes(count: 10, pathPrefix: "g", start: InsightFixtures.at(0), step: 600, agent: .unknown)
        let result = ContributionRatioAnalyzer.analyze(
            agentChanges: rows, humanChanges: nil, referenceDate: InsightFixtures.at(5_400)
        )
        #expect(result.agentShares.isEmpty)
        #expect(aixClose(result.unattributedShare, 1))
        #expect(result.humanShare == nil)
        #expect(result.confidence == .low)
    }

    @Test("空输入：全零 + 不可估计，而不是 0% 的假结论")
    func emptyInput() {
        let result = ContributionRatioAnalyzer.analyze(
            agentChanges: [], humanChanges: nil, referenceDate: InsightFixtures.epoch
        )
        #expect(result.totalChangeCount == 0)
        #expect(result.shareTotal == 0)
        #expect(result.humanShare == nil)
        #expect(result.isHumanShareEstimable == false)
        #expect(result.confidence == .low)
        #expect(result.basis.contains("不可估计"))
    }

    @Test("样本减半 → 置信度严格下降")
    func confidenceDropsWhenDataHalved() {
        let full = InsightFixtures.changes(count: 40, pathPrefix: "k", start: InsightFixtures.at(0), step: 200)
        let reference = InsightFixtures.at(7_800)
        let before = ContributionRatioAnalyzer.analyze(
            agentChanges: full, humanChanges: nil, referenceDate: reference
        )
        let after = ContributionRatioAnalyzer.analyze(
            agentChanges: Array(full.prefix(20)), humanChanges: nil, referenceDate: reference
        )
        #expect(before.confidence == .high)
        #expect(after.confidence < before.confidence)
    }
}
