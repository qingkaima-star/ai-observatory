//
//  AnomalyDetectorTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  异常检测的价值全在「不乱报」：常量序列、全零序列、小样本必须一条异常都不出，
//  且不得除零、不得出现 nan/inf。尖峰/骤降则要给出手算得到的 z 值。
//

import Testing
import Foundation
import AIObservatoryCore
@testable import AIObservatoryInsights

@Suite("行为异常检测（z-score + 基线保护）", .timeLimit(.minutes(1)))
struct AnomalyDetectorTests {

    private func detect(_ values: [Double], threshold: Double = 3.0) -> AnomalyReport {
        AnomalyDetector.detect(
            values: values,
            metric: .eventRate,
            bucketStarts: nil,
            bucketSeconds: 60,
            threshold: threshold,
            minimumSampleSize: 8
        )
    }

    @Test("尖峰：mean 4.8 / stdev 8.4 / z = 3.0，恰好一个异常桶（第 9 桶）")
    func detectsSpike() {
        let report = detect([2, 2, 2, 2, 2, 2, 2, 2, 2, 30], threshold: 2.5)
        #expect(report.observations.count == 10)
        #expect(aixOptionalClose(report.baselineMean, 4.8))
        #expect(aixOptionalClose(report.baselineStdev, 8.4))
        #expect(report.isBaselineSufficient)
        #expect(report.skippedReason == nil)
        #expect(report.anomalousObservations.count == 1)
        let spike = report.anomalousObservations.first
        #expect(spike?.bucketIndex == 9)
        #expect(spike?.direction == .spike)
        #expect(aixOptionalClose(spike?.zScore ?? .nan, 3))
        // 其余 9 桶 z = (2-4.8)/8.4 = -0.3333…，不得被误报
        let quiet = report.observations.filter { $0.bucketIndex != 9 }
        #expect(quiet.count == 9)
        #expect(quiet.allSatisfy { $0.isAnomalous == false })
        #expect(quiet.allSatisfy { aixClose($0.zScore ?? .nan, -0.333_333_333_333_333_3) })
        #expect(report.confidence == .medium)
    }

    @Test("骤降：z = -3.0 判为 drop 方向")
    func detectsDrop() {
        let report = detect([10, 10, 10, 10, 10, 10, 10, 10, 10, 0], threshold: 2.5)
        #expect(report.anomalousObservations.count == 1)
        #expect(report.anomalousObservations.first?.bucketIndex == 9)
        #expect(report.anomalousObservations.first?.direction == .drop)
        #expect(aixOptionalClose(report.anomalousObservations.first?.zScore ?? .nan, -3))
    }

    @Test("常量序列：标准差为 0 → 一条异常都不报，且不除零（z 为 nil 而非 nan）")
    func constantSeriesIsNotAnomalous() {
        let report = detect([5, 5, 5, 5, 5, 5, 5, 5], threshold: 2.5)
        #expect(report.anomalousObservations.isEmpty)
        #expect(aixOptionalClose(report.baselineStdev, 0))
        #expect(report.isBaselineSufficient == false)
        #expect(report.skippedReason?.contains("标准差") == true)
        #expect(report.confidence == .low)
        #expect(report.observations.allSatisfy { $0.zScore == nil })
        #expect(report.observations.allSatisfy { $0.isAnomalous == false })
    }

    @Test("全零序列：与常量序列同等处理，绝不产出 nan/inf")
    func allZeroSeries() {
        let report = detect([0, 0, 0, 0, 0, 0, 0, 0, 0, 0], threshold: 2.5)
        #expect(report.anomalousObservations.isEmpty)
        #expect(report.observations.count == 10)
        #expect(report.observations.allSatisfy { $0.zScore == nil })
        #expect(report.baselineStdev == 0)
        #expect(report.confidence == .low)
    }

    @Test("n < 8 不做判定：哪怕最后一个值是 99 也只报「样本不足」")
    func refusesSmallSample() {
        let report = detect([1, 1, 1, 1, 1, 1, 99], threshold: 2.5)
        #expect(report.anomalousObservations.isEmpty)
        #expect(report.isBaselineSufficient == false)
        #expect(report.skippedReason?.contains("不足") == true)
        #expect(report.confidence == .low)
        #expect(report.observations.count == 7)
        #expect(report.observations.allSatisfy { $0.zScore == nil })
    }

    @Test("空序列：基线为 nil（不是 0），observations 为空")
    func emptySeries() {
        let report = detect([])
        #expect(report.observations.isEmpty)
        #expect(report.anomalousObservations.isEmpty)
        #expect(report.baselineMean == nil)
        #expect(report.baselineStdev == nil)
        #expect(report.skippedReason?.contains("无数据") == true)
        #expect(report.confidence == .low)
    }

    @Test("bucketStarts 数量不匹配时不崩溃，按 nil 处理")
    func mismatchedBucketStarts() {
        let report = AnomalyDetector.detect(
            values: [1, 2, 3, 4, 5, 6, 7, 8, 9, 40],
            metric: .cpuLoad,
            bucketStarts: [InsightFixtures.epoch],
            bucketSeconds: 60,
            threshold: 2.5,
            minimumSampleSize: 8
        )
        #expect(report.observations.count == 10)
        #expect(report.observations.allSatisfy { $0.bucketStart == nil })
        #expect(report.metric == .cpuLoad)
    }

    // MARK: 适配器

    @Test("事件密度适配器：60 个每分钟桶，第 30 桶 41 个事件 → 检出 spike")
    func eventRateAdapter() {
        let start = InsightFixtures.epoch
        var events: [TimelineEvent] = []
        for bucket in 0..<60 {
            events.append(InsightFixtures.event(at: start.addingTimeInterval(Double(bucket) * 60 + 10)))
        }
        for _ in 0..<40 {
            events.append(InsightFixtures.event(at: start.addingTimeInterval(30 * 60 + 20)))
        }
        let report = AnomalyDetector.detectEventRates(
            events: events,
            windowStart: start,
            windowEnd: start.addingTimeInterval(3_600),
            bucketSeconds: 60,
            threshold: 2.5
        )
        // 9 桶之外：59 桶各 1，第 30 桶 41，总 100 → mean 1.6667，stdev 5.1207，z(41) ≈ 7.68
        #expect(report.observations.count == 60)
        #expect(report.observations.map(\.value).reduce(0, +) == 100)
        #expect(report.anomalousObservations.map(\.bucketIndex) == [30])
        #expect(report.anomalousObservations.first?.direction == .spike)
        #expect(report.observations.first?.bucketStart == start)
    }

    @Test("事件密度适配器：完全均匀的流量 → 标准差为 0，一条异常都不报")
    func uniformTrafficIsNotAnomalous() {
        let start = InsightFixtures.epoch
        let events = (0..<30).map {
            InsightFixtures.event(at: start.addingTimeInterval(Double($0) * 60 + 10))
        }
        let report = AnomalyDetector.detectEventRates(
            events: events, windowStart: start, windowEnd: start.addingTimeInterval(1_800), bucketSeconds: 60
        )
        #expect(report.anomalousObservations.isEmpty)
        #expect(report.skippedReason?.contains("标准差") == true)
    }

    @Test("删除行数适配器：按桶累加 linesRemoved 而不是事件数")
    func deletionAdapterSumsRemovedLines() {
        let start = InsightFixtures.epoch
        let changes = [
            InsightFixtures.change("a.swift", at: start, removed: 7),
            InsightFixtures.change("b.swift", at: start.addingTimeInterval(30), removed: 3),
            InsightFixtures.change("c.swift", at: start.addingTimeInterval(120), removed: 5)
        ]
        let report = AnomalyDetector.detectDeletions(
            changes: changes, windowStart: start, windowEnd: start.addingTimeInterval(300), bucketSeconds: 60
        )
        #expect(report.metric == .deletionRate)
        #expect(report.observations.map(\.value) == [10, 0, 5, 0, 0])
    }

    @Test("命令密度适配器：非法窗口退化为「无数据」而不是崩溃")
    func commandAdapterInvalidWindow() {
        let start = InsightFixtures.epoch
        let report = AnomalyDetector.detectCommands(
            commands: [InsightFixtures.command("ls", startedAt: start)],
            windowStart: start,
            windowEnd: start
        )
        #expect(report.observations.isEmpty)
        #expect(report.skippedReason?.contains("无数据") == true)
        #expect(report.confidence == .low)
    }

    @Test("CPU 适配器：逐采样取值并把采样时刻带进 observation，乱序输入先稳定排序")
    func cpuAdapterUsesSampleTimestamps() {
        let start = InsightFixtures.epoch
        let ordered = (0..<9).map {
            InsightFixtures.sample(at: start.addingTimeInterval(Double($0) * 60), cpu: 2)
        } + [InsightFixtures.sample(at: start.addingTimeInterval(540), cpu: 30)]
        // 把尖峰采样放到最前，验证实现按 timestamp 排序而不是按数组下标
        let samples = [ordered[9]] + Array(ordered[0..<9])
        let report = AnomalyDetector.detectCPU(samples: samples, threshold: 2.5)
        #expect(report.metric == .cpuLoad)
        #expect(report.observations.count == 10)
        // 排序后与尖峰手算例同构：mean 4.8、stdev 8.4、z = 3.0
        #expect(aixOptionalClose(report.baselineMean, 4.8))
        #expect(aixOptionalClose(report.baselineStdev, 8.4))
        #expect(report.observations.first?.bucketStart == start)
        #expect(report.anomalousObservations.map(\.bucketIndex) == [9])
        #expect(report.observations.map(\.value).max() == 30)
    }

    @Test("无采样：CPU 适配器给出「无数据」")
    func cpuAdapterEmpty() {
        let report = AnomalyDetector.detectCPU(samples: [])
        #expect(report.observations.isEmpty)
        #expect(report.skippedReason?.contains("无数据") == true)
    }
}
