//
//  PerformanceDisplayTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-Perf
//
//  网络与 GPU 的显示口径用例。守的是同一类缺陷：把「没采到」显示成「没有」。
//  最后一条钉住「GPU / 网络不得渗进会话级视图」——那是整机量，归因到某个 Agent 就是假数。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

private let reference = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("UI：网络与 GPU 显示口径", .timeLimit(.minutes(1)))
struct PerformanceDisplayTests {

    @Test("真 0 流量与「采不到」必须是两种显示，0 不得退化成「—」")
    func zeroTrafficIsNotMissing() {
        #expect(PerformanceDisplay.networkValue(bytesPerSecond: 0) == "0 B/s")
        #expect(PerformanceDisplay.networkValue(bytesPerSecond: 1_048_576) == "1.0 MB/s")
        #expect(PerformanceDisplay.networkValue(bytesPerSecond: nil) == "—")
        #expect(PerformanceDisplay.networkCaption(
            bytesPerSecond: 0, peak: 0, availability: nil, hasSamples: true, .chineseSimplified
        ) == "本轮区间整机没有流量")
    }

    @Test("拿到速率时副标题说峰值，而不是继续挂着空态")
    func measuredCaptionReportsPeak() {
        let caption = PerformanceDisplay.networkCaption(
            bytesPerSecond: 2_048, peak: 1_048_576, availability: nil, hasSamples: true,
            .chineseSimplified
        )
        #expect(caption == "区间峰值 1.0 MB/s")
    }

    @Test("五种不可得各有说法，绝不共用一句「无数据」")
    func everyUnavailableReasonHasItsOwnWording() {
        let reasons: [NetworkRateAvailability] = [
            .awaitingFirstSample, .noElapsedTime, .counterRegression, .interfaceRemoved, .countersUnreadable,
        ]
        let captions = reasons.map {
            PerformanceDisplay.networkCaption(
                bytesPerSecond: nil, peak: nil, availability: $0, hasSamples: true, .chineseSimplified
            )
        }
        #expect(Set(captions).count == reasons.count, "文案撞车就等于把不同结论合并：\(captions)")
        #expect(captions[0] == "等待首次采样")
        #expect(captions[2].contains("回绕"))
        #expect(captions[4] == "这台机器拿不到网络速率")
    }

    @Test("首轮就知道读不到计数器时，不能让用户白等「首次采样」")
    func unreadableCountersDontWaitForSamples() {
        #expect(PerformanceDisplay.networkCaption(
            bytesPerSecond: nil, peak: nil, availability: .countersUnreadable, hasSamples: false,
            .chineseSimplified
        ) == "这台机器拿不到网络速率")
        #expect(PerformanceDisplay.networkCaption(
            bytesPerSecond: nil, peak: nil, availability: .awaitingFirstSample, hasSamples: false,
            .chineseSimplified
        ) == "等待首次采样")
    }

    @Test("v3 之前的老数据：既没速率也没原因，只能说「该行未记录」")
    func legacyRowWithoutAnyFieldSaysSo() {
        #expect(PerformanceDisplay.networkCaption(
            bytesPerSecond: nil, peak: nil, availability: nil, hasSamples: true, .chineseSimplified
        ) == "该行未记录网络速率")
    }

    @Test("GPU：0% 是合法读数，越界值按不可得而不是裁剪冒充")
    func gpuValueHandlesZeroAndOutOfRange() {
        #expect(PerformanceDisplay.gpuValue(percent: 0) == "0")
        #expect(PerformanceDisplay.gpuUnit(percent: 0) == "%")
        #expect(PerformanceDisplay.gpuValue(percent: 137) == "—")
        #expect(PerformanceDisplay.gpuValue(percent: -5) == "—")
        #expect(PerformanceDisplay.gpuUnit(percent: 137) == "")
        #expect(PerformanceDisplay.gpuCaption(percent: 137, hasSamples: true, .chineseSimplified)
                    == "这台机器拿不到GPU 活动")
    }

    @Test("GPU 有值时副标题必须自带「整机」口径，不让人误读成某个 Agent 的占用")
    func gpuCaptionStatesWholeMachineScope() {
        let caption = PerformanceDisplay.gpuCaption(percent: 42, hasSamples: true, .chineseSimplified)
        #expect(caption.contains("整机"))
        #expect(PerformanceDisplay.gpuValue(percent: 42) == "42")
    }

    @Test("会话级采样不得带出 GPU 与网络：引擎从不填的默认 0 不是读数")
    func sessionScopeCarriesNoWholeMachineMetrics() {
        let sessionSample = PerformanceSample(
            timestamp: reference,
            cpuPercent: 12,
            memoryBytes: 4_096,
            gpuPercent: 42,
            networkBytesIn: 999_999,
            networkBytesOut: 999_999
        )
        let point = PerformanceSeriesPoint(sessionSample)
        #expect(point.gpuActivityPercent == nil)
        #expect(point.networkInBytesPerSecond == nil)
        #expect(point.networkOutBytesPerSecond == nil)
        #expect(!point.hasNetworkReading)
    }

    @Test("整机两点才算可信读数：缺一方向不画点，免得半条假曲线")
    func partialNetworkReadingIsNotAReading() {
        let half = PerformanceSeriesPoint(SystemPerformanceSample(
            timestamp: reference, networkInBytesPerSecond: 1_000
        ))
        #expect(!half.hasNetworkReading)

        let whole = PerformanceSeriesPoint(SystemPerformanceSample(
            timestamp: reference,
            networkInBytesPerSecond: 1_000,
            networkOutBytesPerSecond: 2_000
        ))
        #expect(whole.hasNetworkReading)
        #expect(PerformanceSeriesPoint(SystemPerformanceSample(
            timestamp: reference,
            networkAvailability: .counterRegression
        )).hasNetworkReading == false)
    }
}
