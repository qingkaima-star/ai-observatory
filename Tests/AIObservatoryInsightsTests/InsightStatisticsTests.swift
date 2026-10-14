//
//  InsightStatisticsTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  基座数学的手算校验：期望值全部由公式独立算出（分位数为 R type 7 线性插值），
//  不是从实现反推出来的。
//

import Testing
import Foundation
@testable import AIObservatoryInsights

@Suite("Insights 基座：统计数学", .timeLimit(.minutes(1)))
struct InsightStatisticsTests {

    // MARK: 均值与离散度

    @Test("均值：空序列返回 nil（区别于 0），正常序列手算 [2,4,6] → 4")
    func mean() {
        #expect(InsightStatistics.mean([]) == nil)
        #expect(aixOptionalClose(InsightStatistics.mean([2, 4, 6]), 4))
        #expect(aixOptionalClose(InsightStatistics.mean([-3, 3]), 0))
    }

    @Test("总体标准差：空 → nil，单点 → 0，[2,4,6] → sqrt(8/3)")
    func populationStdev() {
        #expect(InsightStatistics.populationStdev([]) == nil)
        #expect(aixOptionalClose(InsightStatistics.populationStdev([5]), 0))
        // 均值 4，偏差平方 (4+0+4)=8，÷3 → 方差 2.666666…，标准差 1.6329931618554523
        #expect(aixOptionalClose(InsightStatistics.populationStdev([2, 4, 6]), 1.632_993_161_855_452))
        #expect(aixOptionalClose(InsightStatistics.populationStdev([1, 1, 1, 1]), 0))
    }

    @Test("样本标准差：n<2 不可估计（返回 nil 而非 0）")
    func sampleStdev() {
        #expect(InsightStatistics.sampleStdev([]) == nil)
        #expect(InsightStatistics.sampleStdev([7]) == nil)
        // [1,3]：均值 2，平方和 2，÷(n-1)=2 → sqrt 2
        #expect(aixOptionalClose(InsightStatistics.sampleStdev([1, 3]), 1.414_213_562_373_0951))
    }

    @Test("z-score：标准差为 0 时返回 nil，绝不做除零")
    func zScore() {
        #expect(InsightStatistics.zScore(value: 10, mean: 4, stdev: 2).map { aixClose($0, 3) } == true)
        #expect(InsightStatistics.zScore(value: 10, mean: 4, stdev: 0) == nil)
        #expect(InsightStatistics.zScore(value: 10, mean: 4, stdev: -1) == nil)
    }

    // MARK: 分位数（空 / 单元素 / 奇偶长度都要覆盖）

    @Test("分位数：空集合 → nil，单元素 → 该元素（任意分位）")
    func percentileEmptyAndSingle() {
        #expect(InsightStatistics.percentile([], at: 0.5) == nil)
        #expect(aixOptionalClose(InsightStatistics.percentile([7], at: 0.5), 7))
        #expect(aixOptionalClose(InsightStatistics.percentile([7], at: 0.95), 7))
        #expect(aixOptionalClose(InsightStatistics.percentile([7], at: 0), 7))
    }

    @Test("分位数：奇数长度中位数取正中元素，偶数长度取两中点均值")
    func percentileMedian() {
        // 奇数 [1,2,3]：h=(3-1)*0.5=1 → 2
        #expect(aixOptionalClose(InsightStatistics.percentile([1, 2, 3], at: 0.5), 2))
        // 偶数 [1,2,3,4]：h=1.5 → 2 + 0.5*(3-2) = 2.5
        #expect(aixOptionalClose(InsightStatistics.percentile([1, 2, 3, 4], at: 0.5), 2.5))
        // 乱序输入必须与排序结果一致
        #expect(aixOptionalClose(InsightStatistics.percentile([4, 1, 3, 2], at: 0.5), 2.5))
    }

    @Test("分位数：p95 线性插值 [1..9] → 8.6，端点 p0/p1 取最值，p 越界被夹住")
    func percentileTails() {
        // h=(9-1)*0.95=7.6 → 8 + 0.6*(9-8) = 8.6
        #expect(aixOptionalClose(InsightStatistics.percentile([1, 2, 3, 4, 5, 6, 7, 8, 9], at: 0.95), 8.6))
        #expect(aixOptionalClose(InsightStatistics.percentile([3, 1, 2], at: 0), 1))
        #expect(aixOptionalClose(InsightStatistics.percentile([3, 1, 2], at: 1), 3))
        #expect(aixOptionalClose(InsightStatistics.percentile([3, 1, 2], at: 5), 3))
        #expect(aixOptionalClose(InsightStatistics.percentile([3, 1, 2], at: -5), 1))
    }

    // MARK: 衰减与归一化

    @Test("等比衰减累加：0.6^i 前缀和，n=0 → 0，decay=1 退化为计数")
    func decayedSum() {
        #expect(aixClose(InsightStatistics.decayedSum(count: 0, decay: 0.6), 0))
        #expect(aixClose(InsightStatistics.decayedSum(count: 1, decay: 0.6), 1))
        #expect(aixClose(InsightStatistics.decayedSum(count: 2, decay: 0.6), 1.6))
        #expect(aixClose(InsightStatistics.decayedSum(count: 3, decay: 0.6), 1.96))
        #expect(aixClose(InsightStatistics.decayedSum(count: 4, decay: 0.6), 2.176))
        #expect(aixClose(InsightStatistics.decayedSum(count: 6, decay: 0.6), 2.383_36))
        #expect(aixClose(InsightStatistics.decayedSum(count: 5, decay: 1), 5))
    }

    @Test("半衰期衰减：一个半衰期恰好 0.5，未来时刻记满 1，半衰期非正归 0")
    func recencyWeight() {
        #expect(aixClose(InsightStatistics.recencyWeight(ageSeconds: 0, halfLifeSeconds: 604_800), 1))
        #expect(aixClose(InsightStatistics.recencyWeight(ageSeconds: -50, halfLifeSeconds: 604_800), 1))
        #expect(aixClose(InsightStatistics.recencyWeight(ageSeconds: 604_800, halfLifeSeconds: 604_800), 0.5))
        // 10 天 / 半衰期 7 天 = 0.5^(10/7)
        #expect(aixClose(
            InsightStatistics.recencyWeight(ageSeconds: 864_000, halfLifeSeconds: 604_800),
            0.371_498_572_284_237_1
        ))
        #expect(aixClose(InsightStatistics.recencyWeight(ageSeconds: 100, halfLifeSeconds: 0), 0))
    }

    @Test("clamp01 与 ratio：越界夹住，除零与 nan 归 0")
    func clamping() {
        #expect(aixClose(InsightStatistics.clamp01(-2), 0))
        #expect(aixClose(InsightStatistics.clamp01(2), 1))
        #expect(aixClose(InsightStatistics.clamp01(.nan), 0))
        #expect(aixClose(InsightStatistics.clamp01(0.25), 0.25))
        #expect(aixClose(InsightStatistics.ratio(3, to: 4), 0.75))
        #expect(aixClose(InsightStatistics.ratio(3, to: 0), 0))
        #expect(aixClose(InsightStatistics.ratio(0, to: 0), 0))
    }

    // MARK: 斜率

    @Test("最小二乘斜率：完美直线 [1,3,5] → 2；样本不足或 x 无离散度 → nil")
    func linearSlope() {
        #expect(aixOptionalClose(InsightStatistics.linearSlope(xs: [0, 1, 2], ys: [1, 3, 5]), 2))
        #expect(aixOptionalClose(InsightStatistics.linearSlope(xs: [0, 1, 2], ys: [6, 6, 2]), -2))
        #expect(InsightStatistics.linearSlope(xs: [0], ys: [5]) == nil)
        #expect(InsightStatistics.linearSlope(xs: [0, 1], ys: [1]) == nil)
        // x 全相同 → 斜率不可定义，不能报 0（那是「持平」的假结论）
        #expect(InsightStatistics.linearSlope(xs: [1, 1, 1], ys: [1, 2, 3]) == nil)
    }

    // MARK: 分桶

    @Test("时间分桶计数：窗口 [0,3h) 每 1h 一桶，空桶记 0")
    func bucketCounts() {
        let start = InsightFixtures.epoch
        let end = InsightFixtures.hours(3)
        let stamps = [start, InsightFixtures.hours(2)]
        let counts = InsightStatistics.bucketCounts(
            timestamps: stamps, start: start, end: end, bucketSeconds: 3600
        )
        #expect(counts?.count == 3)
        #expect(counts == [1, 0, 1])
    }

    @Test("时间分桶累加：金额按桶求和；越界时间戳夹到边界桶")
    func bucketSums() {
        let start = InsightFixtures.epoch
        let sums = InsightStatistics.bucketSums(
            dated: [
                (InsightFixtures.at(0), 6.0),
                (InsightFixtures.at(1_800), 4.0),
                (InsightFixtures.at(3_600), 2.0),
                (InsightFixtures.at(-100), 1.0),
                (InsightFixtures.at(99_999), 5.0)
            ],
            start: start,
            end: InsightFixtures.hours(2),
            bucketSeconds: 3600
        )
        // 桶 0：6+4+1（负偏移夹进首桶）=11；桶 1：2+5（超出上界夹进末桶）=7
        #expect(sums == [11, 7])
    }

    @Test("非法窗口与桶宽：返回 nil / 空数组，而不是崩溃或假数据")
    func invalidBuckets() {
        let start = InsightFixtures.epoch
        #expect(InsightStatistics.bucketCounts(timestamps: [], start: start, end: start, bucketSeconds: 60) == nil)
        #expect(InsightStatistics.bucketCounts(timestamps: [], start: start, end: InsightFixtures.hours(1), bucketSeconds: 0) == nil)
        #expect(InsightStatistics.bucketCount(start: InsightFixtures.hours(1), end: start, bucketSeconds: 60) == nil)
        #expect(InsightStatistics.bucketStarts(start: start, count: 0, bucketSeconds: 60).isEmpty)
        #expect(InsightStatistics.bucketStarts(start: start, count: 3, bucketSeconds: 60).count == 3)
        #expect(InsightStatistics.bucketStarts(start: start, count: 2, bucketSeconds: 60)[1] == InsightFixtures.at(60))
    }
}
