//
//  ProcessMetricsReadingTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-ProcScan
//
//  「按 pid 精确取资源数值」这条能力：真实采集器的行为，以及采样器是否真的走了它。
//
//  钉两件事：
//   1. 读不到的 pid **不出现在结果里**，而不是被补成 0 —— 0 会被下游当成
//      「这个 Agent 这一轮真的没占 CPU」，那是编造读数（本仓的「声明了但没人喂」缺陷族）。
//   2. `ProcessMetricsSampler` 在采集器具备能力时**不再全表扫描**。
//      只用真机耗时来证明这条会变成 flaky，所以用一个记录调用哪个入口的桩来钉。
//

import Testing
import Foundation
import os
@testable import AIObservatoryPlatform
import AIObservatoryCore

/// 记录自己被抓了几次全表扫描的真实采集器。
private final class ReadingSpyInspector: ProcessInspecting, ProcessMetricsReading, Sendable {
    private let lock = OSAllocatedUnfairLock<(scans: Int, metricCalls: Int)>(initialState: (0, 0))

    func scanProcesses() async -> [ProcessRecord] {
        lock.withLock { $0.scans += 1 }
        return []
    }

    func metrics(for pids: [Int32]) -> [Int32: ProcessSample] {
        lock.withLock { $0.metricCalls += 1 }
        return Dictionary(uniqueKeysWithValues: pids.map {
            ($0, ProcessSample(pid: $0, cpuPercent: 7.5, memoryBytes: 4096))
        })
    }

    var counts: (scans: Int, metricCalls: Int) { lock.withLock { $0 } }
}

/// 只有 `scanProcesses()` 的采集器（第三方实现/测试桩的常见形状）。
private struct ScanOnlyInspector: ProcessInspecting {
    var records: [ProcessRecord]
    func scanProcesses() async -> [ProcessRecord] { records }
}

@Suite("按 pid 精确取资源数值", .timeLimit(.minutes(1)))
struct ProcessMetricsReadingTests {

    /// 跑 `metrics(for:)` 之前先扫**两轮**：按 pid 取数走 `TickCPUClock`，
    /// 「上一 tick 没见过这个 pid」时它返回的是**无基线**而不是 0% ⇒ 第一轮扫完立刻问，
    /// 这个 pid 会正当缺席。两轮之后（第一轮的读数已成为基准）才谈得上「读得到」。
    @Test("真实采集器：自己的进程读得到 RSS，空入参不查任何 pid")
    func realInspectorReadsRequestedPIDs() async {
        let inspector = LibprocProcessInspector()
        #expect(inspector.metrics(for: []).isEmpty)

        let mine = Int32(ProcessInfo.processInfo.processIdentifier)
        _ = await inspector.scanProcesses()
        _ = await inspector.scanProcesses()
        let sample = inspector.metrics(for: [mine])
        #expect(sample.count == 1)
        #expect(sample[mine]?.pid == mine)
        // RSS 只断言「读到了正数」：它的真值取决于运行时，钉死数字会变成 flaky。
        #expect((sample[mine]?.memoryBytes ?? 0) > 0)
    }

    @Test("读不到的 pid 缺席，而不是被补成 0")
    func unreadablePIDIsAbsentNotZeroFilled() async {
        let inspector = LibprocProcessInspector()
        let bogus: Int32 = 999_999          // 超出 macOS pid 上限，proc_pidinfo 必失败
        let mine = Int32(ProcessInfo.processInfo.processIdentifier)
        _ = await inspector.scanProcesses()
        _ = await inspector.scanProcesses()   // 立基线，理由见上一条用例的注释
        let sample = inspector.metrics(for: [bogus, mine])
        #expect(sample[bogus] == nil, "读不到的 pid 被补成了 0/0")
        #expect(sample[mine] != nil)
    }

    @Test("采样器在采集器具备能力时走精确取数，一次全表都不扫")
    func samplerUsesCapabilityWhenAvailable() async {
        let spy = ReadingSpyInspector()
        let samples = await ProcessMetricsSampler(inspector: spy).sampleProcesses(pids: [4242, 4243])
        #expect(spy.counts.scans == 0, "为两个 pid 扫了 \(spy.counts.scans) 次全表")
        #expect(spy.counts.metricCalls == 1)
        #expect(Set(samples.keys) == [4242, 4243])
        #expect(samples[4242]?.cpuPercent == 7.5)
    }

    @Test("pids 为空仍是「采样全部」的老口径：退回全表")
    func emptyPIDsStillMeansAll() async {
        let spy = ReadingSpyInspector()
        let samples = await ProcessMetricsSampler(inspector: spy).sampleProcesses(pids: [])
        #expect(samples.isEmpty)          // 空快照 ⇒ 没有进程；但确实扫了
        #expect(spy.counts.scans == 1)
        #expect(spy.counts.metricCalls == 0)
    }

    /// 生产链路能不能走到精确取数，只取决于**真实**采集器有没有 conformance。
    /// 上面几条用的是自带能力的假人，删掉 `LibprocProcessInspector: ProcessMetricsReading`
    /// 它们照样全绿 —— 那就会留下一个「测试绿、生产静默退回每 tick 扫两遍全表」的假绿灯。
    /// 所以这条按存在类型（`any ProcessInspecting`）来验，装配漂移也会被抓到。
    @Test("真实采集器具备该能力（否则生产静默退回全表）")
    func realInspectorProvidesTheCapability() async throws {
        let inspector: any ProcessInspecting = LibprocProcessInspector()
        let reader = try #require(
            inspector as? any ProcessMetricsReading,
            "LibprocProcessInspector 不再实现 ProcessMetricsReading ⇒ ProcessMetricsSampler 每 tick 重扫全表"
        )
        let mine = Int32(ProcessInfo.processInfo.processIdentifier)
        // 两轮扫描立基线：本轮无基线的 pid 现在正当缺席（宁缺不造），
        // 单轮就问会让这条「装配没漂移」的证据退化成 nil。
        _ = await inspector.scanProcesses()
        _ = await inspector.scanProcesses()
        #expect(reader.metrics(for: [mine])[mine] != nil)
    }

    /// 钉的是「**本轮无基线必须表达成缺席，而不是 0%**」。
    ///
    /// 绑的口径：`cpuPercent` 是两次采样求差，而「上一 tick 没见过这个 pid」时根本没有
    /// 可比的上一轮——新出生的进程从 0 开始累计，把它报成 0% 会让「资源滥用」规则收到
    /// 一个它无法区分的读数（真的闲 vs 我们还没看过它）。这正是本仓主导缺陷类
    /// 「声明了但没人喂」的变体：契约上有个 `cpuPercent`，但没有生产者时它不该被填 0。
    ///
    /// 期望值是旁算的，不是从实现反推：
    /// - 刚 `init` 的采集器一条基准都没有 ⇒ 第一轮扫描后立刻按 pid 问，**必然**拿不到数；
    /// - 第二轮扫描开头 `beginTick()` 把第一轮的读数提交为基准 ⇒ 同一 pid 这轮**必然**有数。
    /// 把 `metrics(for:)` 里那条 `guard let cpuPercent = … else { continue }` 删掉，
    /// 前半会立刻变红（它塞回来的是 0/一个真实 RSS）；把 `TickCPUClock.beginTick()` 的
    /// 整表替换改成「只增不删」（改前 `cpuHistory` 的形状），后半与 pid 复用那条一起变红。
    @Test("本轮无基线的 pid 缺席；立过基准的下一轮才有数")
    func pidWithoutBaselineIsAbsentNotZeroFilled() async {
        let inspector = LibprocProcessInspector()
        let mine = Int32(ProcessInfo.processInfo.processIdentifier)

        _ = await inspector.scanProcesses()
        #expect(
            inspector.metrics(for: [mine])[mine] == nil,
            "第一轮没有任何基准 ⇒ 必须缺席，而不是给下游一个无法分辨的 0%"
        )

        _ = await inspector.scanProcesses()
        let second = inspector.metrics(for: [mine])[mine]
        #expect(second?.cpuPercent != nil, "第二轮基准已建立 ⇒ 同一个 pid 必须拿得到数（否则缺席成了万能挡箭牌）")
    }

    @Test("空 pid 集合得到空结果（不需要特判，也不能顺手扫全表）")
    func emptyPIDsYieldEmpty() {
        #expect(LibprocProcessInspector().metrics(for: []).isEmpty)
    }

    @Test("采集器不支持该能力时退回全表，数值照常拿到")
    func fallsBackToFullScan() async {
        let records = [
            ProcessRecord(pid: 4242, name: "claude", cpuPercent: 33, memoryBytes: 1024),
            ProcessRecord(pid: 4243, name: "node", cpuPercent: 7, memoryBytes: 2048),
        ]
        let sampler = ProcessMetricsSampler(inspector: ScanOnlyInspector(records: records))
        let samples = await sampler.sampleProcesses(pids: [4242])
        #expect(Array(samples.keys) == [4242])
        #expect(samples[4242]?.memoryBytes == 1024)
    }
}
