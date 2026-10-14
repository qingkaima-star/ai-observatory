//
//  HotFileScorerTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  核心验收：给定 6 条变更，热度排序与得分必须与手算结论一致。
//  期望值由 `01-架构/分析层接口.md` §2.1 的公式独立算出（不是从实现反推）。
//

import Testing
import Foundation
import AIObservatoryCore
@testable import AIObservatoryInsights

@Suite("文件热度评分", .timeLimit(.minutes(1)))
struct HotFileScorerTests {

    private let reference = InsightFixtures.days(20)

    /// A：改得多 + 多 Agent + 10 天没动；B：改得少 + 单 Agent + 刚刚动过。
    private var twoFileCorpus: [FileChange] {
        [
            InsightFixtures.change("A.swift", at: InsightFixtures.days(7), agent: .claudeCode),
            InsightFixtures.change("A.swift", at: InsightFixtures.days(8), agent: .claudeCode),
            InsightFixtures.change("A.swift", at: InsightFixtures.days(9), agent: .openAICodex),
            InsightFixtures.change("A.swift", at: InsightFixtures.days(10), agent: .openAICodex),
            InsightFixtures.change("B.swift", at: InsightFixtures.days(19), agent: .claudeCode),
            InsightFixtures.change("B.swift", at: InsightFixtures.days(20), agent: .claudeCode)
        ]
    }

    @Test("6 条变更 / 4 文件：排序 A > B > D > C，且四个分数逐位命中手算值")
    func sixChangesAcrossFourFilesRankAsHandComputed() {
        let corpus = [
            InsightFixtures.change("A.swift", at: InsightFixtures.days(1), agent: .claudeCode),
            InsightFixtures.change("A.swift", at: InsightFixtures.days(2), agent: .openAICodex),
            InsightFixtures.change("B.swift", at: InsightFixtures.days(0), agent: .claudeCode),
            InsightFixtures.change("B.swift", at: InsightFixtures.days(3), agent: .claudeCode),
            InsightFixtures.change("C.swift", at: InsightFixtures.days(0), agent: .openAICodex),
            InsightFixtures.change("D.swift", at: InsightFixtures.days(10), agent: .openAICodex)
        ]
        #expect(corpus.count == 6)
        // 人工结论：A（改 2 次 + 2 个 Agent）第一；B 同为 2 次但只有 1 个 Agent、也没 A 新；
        // D 只改 1 次但刚刚发生，应压过 10 天没动的 C。
        let scores = FileHotnessScorer.score(changes: corpus, referenceDate: InsightFixtures.days(10))
        #expect(scores.map(\.path) == ["A.swift", "B.swift", "D.swift", "C.swift"])
        #expect(scores.count == 4)
        let byPath = Dictionary(uniqueKeysWithValues: scores.map { ($0.path, $0.score) })
        #expect(aixClose(byPath["A.swift"] ?? -1, 0.835_858_549_639_586))
        #expect(aixClose(byPath["B.swift"] ?? -1, 0.75))
        #expect(aixClose(byPath["D.swift"] ?? -1, 0.668_75))
        #expect(aixClose(byPath["C.swift"] ?? -1, 0.480_199_571_685_271_16))
    }

    @Test("因子明细可解释：原始量与归一化量都命中手算值")
    func factorBreakdownMatchesHandComputation() {
        let scores = FileHotnessScorer.score(changes: twoFileCorpus, referenceDate: reference)
        let a = scores.first { $0.path == "A.swift" }
        let b = scores.first { $0.path == "B.swift" }
        #expect(a?.factors.changeCount == 4)
        #expect(a?.factors.distinctAgentCount == 2)
        #expect(a?.factors.ageSeconds == 864_000)
        #expect(aixClose(a?.factors.effectiveEditCount ?? -1, 2.176))
        // A 是频次/重复/广度上界 → 归一化 1.0；活跃度 0.5^(10/7)
        #expect(aixClose(a?.factors.normalizedFrequency ?? -1, 1))
        #expect(aixClose(a?.factors.normalizedRepetition ?? -1, 1))
        #expect(aixClose(a?.factors.normalizedBreadth ?? -1, 1))
        #expect(aixClose(a?.factors.normalizedRecency ?? -1, 0.371_498_572_284_237_1))
        // B 刚好相反
        #expect(aixClose(b?.factors.normalizedFrequency ?? -1, 0.5))
        #expect(aixClose(b?.factors.normalizedRepetition ?? -1, 0.735_294_117_647_058_8))
        #expect(aixClose(b?.factors.normalizedBreadth ?? -1, 0.5))
        #expect(aixClose(b?.factors.normalizedRecency ?? -1, 1))
    }

    @Test("综合分命中手算值，且排序为 A > B")
    func weightedScoreMatches() {
        let scores = FileHotnessScorer.score(changes: twoFileCorpus, referenceDate: reference)
        #expect(scores.first?.path == "A.swift")
        #expect(aixClose(scores[0].score, 0.811_449_571_685_271_1))
        #expect(aixClose(scores[1].score, 0.685_294_117_647_058_8))
        #expect(scores.allSatisfy { (0...1).contains($0.score) })
    }

    @Test("单文件语料：所有因子都是自身上界 → 综合分恰为 1.0，但样本极少所以置信度 low")
    func singleFileCorpusSaturatesAtOne() {
        let scores = FileHotnessScorer.score(
            changes: [InsightFixtures.change("only.swift", at: reference, agent: .cursorAgent)],
            referenceDate: reference
        )
        #expect(scores.count == 1)
        #expect(aixClose(scores[0].score, 1))
        #expect(scores[0].confidence == .low)
        #expect(scores[0].basis.isEmpty == false)
    }

    @Test("空输入返回空数组，不是崩或假数据")
    func emptyCorpus() {
        #expect(FileHotnessScorer.score(changes: [], referenceDate: reference).isEmpty)
        #expect(FileHotnessScorer.topHotFiles([], limit: 5).isEmpty)
    }

    @Test("topHotFiles：limit 非正取空，超出总数取全部")
    func topNIsBounded() {
        let scores = FileHotnessScorer.score(changes: twoFileCorpus, referenceDate: reference)
        #expect(FileHotnessScorer.topHotFiles(scores, limit: 0).isEmpty)
        #expect(FileHotnessScorer.topHotFiles(scores, limit: -3).isEmpty)
        #expect(FileHotnessScorer.topHotFiles(scores, limit: 1).map(\.path) == ["A.swift"])
        #expect(FileHotnessScorer.topHotFiles(scores, limit: 99).count == 2)
    }

    @Test("归属不明的改动拉低该文件置信度（缺失比例参与判级）")
    func unknownAttributionLowersConfidence() {
        let scoringReference = InsightFixtures.at(9_000)
        let attributed = InsightFixtures.editsToFile(path: "known.swift", count: 12, start: InsightFixtures.epoch, step: 600)
        let unattributed = InsightFixtures.editsToFile(path: "ghost.swift", count: 12, start: InsightFixtures.epoch, step: 600, agents: [.unknown])
        let attributedScore = FileHotnessScorer.score(changes: attributed, referenceDate: scoringReference).first
        let ghostScore = FileHotnessScorer.score(changes: unattributed, referenceDate: scoringReference).first
        // 同一批样本量（12 次改动、跨 6600s），唯一差别是归属是否缺失
        #expect(attributedScore?.confidence == .medium)
        #expect(ghostScore?.confidence == .low)
    }

    @Test("重复改动边际递减：同一文件第 5 次的权重低于第 1 次（有效改动数 < 原始次数）")
    func repetitionDecays() {
        let five = InsightFixtures.editsToFile(path: "same.swift", count: 5, start: reference, step: 0)
        let scores = FileHotnessScorer.score(changes: five, referenceDate: reference)
        #expect(scores.count == 1)
        // 1 + .6 + .36 + .216 + .1296 = 2.3056，明显低于 5
        #expect(aixClose(scores[0].factors.effectiveEditCount, 2.3056))
        #expect(scores[0].factors.changeCount == 5)
        #expect(scores[0].score == 1)
    }
}
