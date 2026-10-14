//
//  NetworkRateTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-Perf
//
//  整机网络速率差分的单元测试：回绕、接口消失、首轮无基线都必须给原因而不是 0。
//  最后两条跑真机内核计数器，证明这条链在这台机器上确实读得到数。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

private func totals(_ t: TimeInterval, _ pairs: (String, UInt64, UInt64)...) -> NetworkTotals {
    NetworkTotals(
        perInterface: Dictionary(uniqueKeysWithValues: pairs.map {
            ($0.0, NetworkInterfaceTotals(inBytes: $0.1, outBytes: $0.2))
        }),
        timestamp: Date(timeIntervalSinceReferenceDate: t)
    )
}

@Suite("Telemetry：整机网络速率差分", .timeLimit(.minutes(1)))
struct NetworkRateTests {

    @Test("首次采样没有基线：返回 awaitingFirstSample，不是 0 字节/秒")
    func firstSampleHasNoRate() {
        let outcome = NetworkCounters.rate(previous: nil, current: totals(100, ("en0", 5_000, 1_000)))
        #expect(outcome == .unavailable(.awaitingFirstSample))
        #expect(outcome.rate == nil, "「还没采到」绝不能被读成「真的没流量」")
    }

    @Test("两轮差分：只累加两侧都在的接口，除以真实时间差")
    func differentialSumsSharedInterfaces() {
        let previous = totals(100, ("en0", 1_000, 500), ("utun0", 200, 100))
        let current = totals(110, ("en0", 5_000, 1_500), ("utun0", 400, 200))
        let outcome = NetworkCounters.rate(previous: previous, current: current)
        guard case .available(let rate) = outcome else {
            Issue.record("期望拿到速率，实际 \(outcome)")
            return
        }
        // (4000 + 200) / 10s 收，(1000 + 100) / 10s 发
        #expect(rate.inputBytesPerSecond == 420)
        #expect(rate.outputBytesPerSecond == 110)
        #expect(rate.totalBytesPerSecond == 530)
    }

    @Test("counter 回绕（32 位计数器 / 驱动重载）：该轮判为不可信，不伪造峰值也不伪造 0")
    func counterRegressionIsReported() {
        let previous = totals(100, ("en0", 4_000_000_000, 1_000))
        // 回绕后计数值远小于上一轮
        let current = totals(110, ("en0", 12_000, 2_000))
        #expect(NetworkCounters.rate(previous: previous, current: current) == .unavailable(.counterRegression))
    }

    @Test("接口消失（拔网线 / 虚拟接口销毁）：该轮判为不可信")
    func removedInterfaceIsReported() {
        let previous = totals(100, ("en0", 1_000, 500), ("awdl0", 700, 300))
        let current = totals(110, ("en0", 2_000, 900))
        #expect(NetworkCounters.rate(previous: previous, current: current) == .unavailable(.interfaceRemoved))
    }

    @Test("新出现的接口本轮不计入：它的累计值含窗口之前的流量，计入就是虚高")
    func newlySeenInterfaceContributesNothing() {
        let previous = totals(100, ("en0", 1_000, 500))
        let current = totals(110, ("en0", 3_000, 1_500), ("utun9", 900_000, 800_000))
        let outcome = NetworkCounters.rate(previous: previous, current: current)
        guard case .available(let rate) = outcome else {
            Issue.record("期望拿到速率，实际 \(outcome)")
            return
        }
        #expect(rate.inputBytesPerSecond == 200)
        #expect(rate.outputBytesPerSecond == 100)
    }

    @Test("零流量：速率是真 0，与「采不到」可区分")
    func idleTrafficIsActualZero() {
        let previous = totals(100, ("en0", 1_000, 500))
        let current = totals(110, ("en0", 1_000, 500))
        let outcome = NetworkCounters.rate(previous: previous, current: current)
        guard case .available(let rate) = outcome else {
            Issue.record("期望拿到速率，实际 \(outcome)")
            return
        }
        #expect(rate.totalBytesPerSecond == 0)
    }

    @Test("时间差 ≤ 0（时钟回拨 / 同一时刻重复调用）：不给速率")
    func nonPositiveElapsedHasNoRate() {
        let previous = totals(100, ("en0", 1_000, 500))
        let same = totals(100, ("en0", 2_000, 900))
        #expect(NetworkCounters.rate(previous: previous, current: same) == .unavailable(.noElapsedTime))
        let backwards = totals(90, ("en0", 2_000, 900))
        #expect(NetworkCounters.rate(previous: previous, current: backwards) == .unavailable(.noElapsedTime))
    }

    @Test("没有任何可统计接口：这台机器拿不到，而不是等待首采")
    func emptySnapshotIsUnreadable() {
        let outcome = NetworkCounters.rate(previous: totals(100, ("en0", 1, 1)), current: totals(110))
        #expect(outcome == .unavailable(.countersUnreadable))
    }

    @Test("真机：getifaddrs 累计计数器读得到，且排除 lo0")
    func realCumulativeCountersAreReadable() throws {
        let snapshot = try #require(NetworkCounters().readCumulative(), "本机 getifaddrs 读不到任何非回环接口")
        #expect(!snapshot.perInterface.isEmpty)
        #expect(snapshot.perInterface["lo0"] == nil, "回环必须排除，否则本机自询会被算成流量")
        // 自开机以来的累计值，只要机器上过网就非零；为零说明读取路径坏了而不是没流量。
        #expect(snapshot.inBytes + snapshot.outBytes > 0)
        print("[真机网络] 接口 \(snapshot.perInterface.count) 个，累计 ↓\(snapshot.inBytes) B ↑\(snapshot.outBytes) B")
    }

    @Test("真机：连续两轮采样后拿到速率（首轮必为 awaitingFirstSample）")
    func realTwoRoundSamplingYieldsRate() async throws {
        let sampler = HostMetricsSampler(processInspector: StubProcessInspector(records: []))
        let first = sampler.sampleNetworkRate()
        #expect(first == .unavailable(.awaitingFirstSample))

        try await Task.sleep(for: .milliseconds(400))
        let second = sampler.sampleNetworkRate()
        guard case .available(let rate) = second else {
            Issue.record("第二轮仍拿不到速率：\(second)")
            return
        }
        #expect(rate.inputBytesPerSecond >= 0)
        #expect(rate.outputBytesPerSecond >= 0)
        print("[真机网络] ↓\(rate.inputBytesPerSecond) B/s ↑\(rate.outputBytesPerSecond) B/s")
    }
}

// MARK: - 落库字段（IFR-perf-coverage-2 第 3 步）

@Suite("Telemetry：整机采样的网络与 GPU 落库字段", .timeLimit(.minutes(1)))
struct SystemSampleTelemetryFieldsTests {

    @Test("速率与原因互斥：有速率时 availability 必为 nil，反之两个速率都为 nil")
    func rateAndAvailabilityAreMutuallyExclusive() {
        let previous = NetworkTotals(
            perInterface: ["en0": NetworkInterfaceTotals(inBytes: 1_000, outBytes: 500)],
            timestamp: Date(timeIntervalSinceReferenceDate: 100)
        )
        let measured = NetworkCounters.rate(
            previous: previous,
            current: NetworkTotals(
                perInterface: ["en0": NetworkInterfaceTotals(inBytes: 3_000, outBytes: 1_500)],
                timestamp: Date(timeIntervalSinceReferenceDate: 110)
            )
        )
        #expect(measured.rate != nil)
        #expect(measured.availability == nil)

        let pending = NetworkCounters.rate(previous: nil, current: previous)
        #expect(pending.rate == nil)
        #expect(pending.availability == .awaitingFirstSample)
    }

    @Test("真机首轮：网络字段是 nil + awaitingFirstSample，不是 0；GPU 落在 0…100 或 nil")
    func firstSystemSampleCarriesNoFakeNetwork() async {
        let sampler = HostMetricsSampler(processInspector: StubProcessInspector(records: []))
        let sample = await sampler.sampleSystem()
        #expect(sample.networkInBytesPerSecond == nil, "首轮没有基线，落 0 会被 UI 读成「没流量」")
        #expect(sample.networkOutBytesPerSecond == nil)
        #expect(sample.networkAvailability == .awaitingFirstSample)
        if let gpu = sample.gpuActivityPercent {
            #expect((0...100).contains(gpu), "越界的 GPU 值必须在 Platform 侧就判为不可得")
        }
    }

    @Test("真机第二轮：速率与原因不会再同时出现")
    func secondSystemSampleCarriesRates() async throws {
        let sampler = HostMetricsSampler(processInspector: StubProcessInspector(records: []))
        _ = await sampler.sampleSystem()
        try await Task.sleep(for: .milliseconds(400))
        let sample = await sampler.sampleSystem()

        let inbound = try #require(sample.networkInBytesPerSecond, "第二轮仍拿不到下行速率")
        let outbound = try #require(sample.networkOutBytesPerSecond, "第二轮仍拿不到上行速率")
        #expect(inbound >= 0 && outbound >= 0)
        #expect(sample.networkAvailability == nil)
        print("[真机落库] sampleSystem ↓\(inbound) ↑\(outbound) B/s，GPU \(String(describing: sample.gpuActivityPercent))%")
    }
}
