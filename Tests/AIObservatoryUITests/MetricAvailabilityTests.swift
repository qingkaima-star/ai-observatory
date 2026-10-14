//
//  MetricAvailabilityTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-Perf
//
//  钉住性能页空态口径：一条样本都没有 ≠ 这台机器给不出这个指标 ≠ 读数是 0。
//

import Foundation
import Testing
@testable import AIObservatoryUI

@Suite("UI：指标空态口径", .timeLimit(.minutes(1)))
struct MetricAvailabilityTests {

    @Test("有读数就是 measured，不看有没有样本")
    func readingWins() {
        #expect(MetricAvailability.resolve(hasSamples: true, reading: 0) == .measured)
        #expect(MetricAvailability.resolve(hasSamples: false, reading: 42) == .measured)
    }

    @Test("一条样本都没有：是「等待首次采样」，不是「这台机器拿不到」")
    func noSamplesAwaitsFirstSample() {
        #expect(MetricAvailability.resolve(hasSamples: false, reading: nil) == .awaitingSample)
        #expect(MetricAvailability.resolve(hasSamples: false, reading: nil)
            .caption(metric: "温度", .chineseSimplified) == "等待首次采样")
    }

    @Test("已有样本但该指标为 nil：这台机器拿不到，不能继续挂着「等一下就有」的口吻")
    func samplesWithoutReadingAreUnavailable() {
        #expect(MetricAvailability.resolve(hasSamples: true, reading: nil) == .unavailableOnThisMachine)
        #expect(MetricAvailability.resolve(hasSamples: true, reading: nil)
            .caption(metric: "功耗", .chineseSimplified) == "这台机器拿不到功耗")
    }

    @Test("0 读数不得退化成空态：GPU 空闲与 GPU 采不到是两件事")
    func zeroIsNotMissing() {
        let availability = MetricAvailability.resolve(hasSamples: true, reading: 0)
        #expect(availability == .measured)
        #expect(availability.caption(metric: "GPU 活动", .chineseSimplified).isEmpty, "有数就不给空态文案")
    }
}
