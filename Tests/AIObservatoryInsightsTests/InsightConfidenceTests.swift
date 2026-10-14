//
//  InsightConfidenceTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  置信度规则是本工作流的「可信」底线：阈值边界、缺失比例、组合取最弱都要钉死。
//

import Testing
import Foundation
@testable import AIObservatoryInsights

@Suite("Insights 基座：置信度与趋势", .timeLimit(.minutes(1)))
struct InsightConfidenceTests {

    @Test("HIGH 需要三项同时达标，任一项不足即降级")
    func highRequiresAllThree() {
        #expect(InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 30, coverageSeconds: 3_600, missingFieldRatio: 0.10)) == .high)
        // 样本量差 1
        #expect(InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 29, coverageSeconds: 3_600, missingFieldRatio: 0)) == .medium)
        // 覆盖时长差 1 秒
        #expect(InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 30, coverageSeconds: 3_599, missingFieldRatio: 0)) == .medium)
        // 缺失比例超标
        #expect(InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 30, coverageSeconds: 3_600, missingFieldRatio: 0.11)) == .medium)
    }

    @Test("MEDIUM 边界：n=8 且覆盖 600s 且缺失 35% 恰好达标，再差一点就是 LOW")
    func mediumBoundary() {
        #expect(InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 8, coverageSeconds: 600, missingFieldRatio: 0.35)) == .medium)
        #expect(InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 7, coverageSeconds: 6_000, missingFieldRatio: 0)) == .low)
        #expect(InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 30, coverageSeconds: 599, missingFieldRatio: 0)) == .low)
        #expect(InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 10, coverageSeconds: 7_200, missingFieldRatio: 0.5)) == .low)
        #expect(InsightConfidenceEvaluator.evaluate(.empty) == .low)
    }

    @Test("证据入参越界被夹住，不产生负数或 >100% 的缺失率")
    func evidenceClamping() {
        let evidence = InsightEvidence(observationCount: -5, coverageSeconds: -100, missingFieldRatio: 2)
        #expect(evidence.observationCount == 0)
        #expect(evidence.coverageSeconds == 0)
        #expect(evidence.missingFieldRatio == 1)
        #expect(InsightConfidenceEvaluator.evaluate(evidence) == .low)
    }

    @Test("数据减半 → 置信度严格下降（不许出现「样本少了结论更硬」）")
    func confidenceDropsWithLessData() {
        let plenty = InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 40, coverageSeconds: 7_200, missingFieldRatio: 0))
        let halved = InsightConfidenceEvaluator.evaluate(InsightEvidence(observationCount: 20, coverageSeconds: 3_600, missingFieldRatio: 0))
        #expect(plenty == .high)
        #expect(halved < plenty)
    }

    @Test("缺失字段比例：nil 计缺失，空序列按全缺失处理")
    func missingRatioFromOptionals() {
        let values: [Int?] = [1, nil, nil, 4]
        #expect(aixClose(InsightEvidence.missingRatio(of: values), 0.5))
        #expect(aixClose(InsightEvidence.missingRatio(of: [Int?]([1, 2])), 0))
        #expect(aixClose(InsightEvidence.missingRatio(of: [Double?]()), 1))
    }

    @Test("组合置信度取最弱一环，空集合返回 nil")
    func weakestTakesMinimum() {
        #expect(InsightConfidenceEvaluator.weakest([]) == nil)
        #expect(InsightConfidenceEvaluator.weakest([.high]) == .high)
        #expect(InsightConfidenceEvaluator.weakest([.high, .medium]) == .medium)
        #expect(InsightConfidenceEvaluator.weakest([.high, .low, .medium]) == .low)
    }

    @Test("置信度有序、可比较，LOW 标记为推测性结论")
    func orderingAndSpeculation() {
        #expect(InsightConfidence.low < InsightConfidence.medium)
        #expect(InsightConfidence.medium < InsightConfidence.high)
        #expect(InsightConfidence.low.isSpeculative)
        #expect(!InsightConfidence.high.isSpeculative)
        #expect(InsightConfidence(rawValue: "medium") == .medium)
        #expect(InsightConfidence.medium.displayName == "MEDIUM")
    }

    @Test("覆盖时长：空/单点为 0，乱序输入仍取真实跨度")
    func coverageSpan() {
        #expect(InsightConfidenceEvaluator.coverageSeconds(of: [Date]()) == 0)
        #expect(InsightConfidenceEvaluator.coverageSeconds(of: [InsightFixtures.epoch]) == 0)
        let dates = [InsightFixtures.hours(2), InsightFixtures.epoch, InsightFixtures.hours(1)]
        #expect(InsightConfidenceEvaluator.coverageSeconds(of: dates) == 7_200)
    }

    @Test("趋势判定：斜率不可计算时必须报 unknown 而不是 flat")
    func trendClassification() {
        #expect(InsightTrend.of(slope: nil, threshold: 1) == .unknown)
        #expect(InsightTrend.of(slope: 2, threshold: 0) == .unknown)
        #expect(InsightTrend.of(slope: .nan, threshold: 1) == .unknown)
        #expect(InsightTrend.of(slope: 2.5, threshold: 1) == .rising)
        #expect(InsightTrend.of(slope: -2.5, threshold: 1) == .falling)
        #expect(InsightTrend.of(slope: 0.5, threshold: 1) == .flat)
        #expect(InsightTrend.unknown.displayName == "样本不足")
    }
}
