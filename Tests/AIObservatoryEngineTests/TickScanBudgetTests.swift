//
//  TickScanBudgetTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-ProcScan
//
//  一个 tick 只允许有**一次**全表进程扫描。
//
//  为什么要专门钉这个数：`ingestPerformance` 要的是几个 Agent 的 CPU/内存，而它走的
//  `components.metrics.sampleProcesses(pids:)` 在真实装配里
//  （`Components.live` → `HostMetricsSampler` → `ProcessMetricsSampler`）
//  原本是「`scanProcesses()` 全表重扫一遍再按 pid 过滤」——每 tick 因此扫两次整机进程表
//  （真机 ~820 pid × 每 pid 5 次 proc 调用）。现在采集器额外实现 `ProcessMetricsReading`，
//  采样器按 pid 精确取数。
//
//  注入的 metrics 是**真实的** `HostMetricsSampler`：换成 `StubMetrics` 就测不到这条了
//  （它的 sampleProcesses 根本不碰 inspector，回归会静悄悄）。
//

import Testing
import Foundation
import os
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryPlatform

/// 记录自己被调用了几次全表扫描的进程源。
///
/// 同时实现 `ProcessMetricsReading`，与 `LibprocProcessInspector` 在生产的形状一致。
final class ScanCountingInspector: ProcessInspecting, ProcessMetricsReading, Sendable {
    private let lock = OSAllocatedUnfairLock<Int>(initialState: 0)
    let records: [ProcessRecord]

    init(records: [ProcessRecord]) {
        self.records = records
    }

    var scanCount: Int { lock.withLock { $0 } }

    func scanProcesses() async -> [ProcessRecord] {
        lock.withLock { $0 += 1 }
        return records
    }

    func metrics(for pids: [Int32]) -> [Int32: ProcessSample] {
        Dictionary(uniqueKeysWithValues: records.filter { pids.contains($0.pid) }.map {
            ($0.pid, ProcessSample(pid: $0.pid, cpuPercent: $0.cpuPercent, memoryBytes: $0.memoryBytes))
        })
    }
}

private let tickAgentPID: Int32 = 12345

/// 数值刻意取可识别的字面量：它们必须原样出现在落库的采样里，才能证明
/// 「按 pid 精确取数」没有把数值换成别的来源或补成 0。
private let tickRecords: [ProcessRecord] = [
    ProcessRecord(
        pid: tickAgentPID, parentPID: 1, name: "claude",
        startTime: Date(timeIntervalSince1970: 1_800_001_000),
        cpuPercent: 12.5, memoryBytes: 4_194_304
    ),
]

private func makeEngine(
    inspector: any ProcessInspecting,
    agents: [AgentInstance]
) async throws -> (ObservatoryEngine, ObservatoryStore) {
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let engine = ObservatoryEngine(
        settings: ObservatorySettings(processScanIntervalSeconds: 3_600),
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: StubDetector(agents: agents),
            processInspector: inspector,
            metrics: HostMetricsSampler(processInspector: inspector),
            commandAuditor: StubAuditor(),
            fileObserver: StubFileObserver(),
            snapshotter: StubSnapshotter(),
            differ: StubDiffer()
        )
    )
    return (engine, store)
}

@Suite("Engine：一个 tick 只扫一次全表", .timeLimit(.minutes(1)))
struct TickScanBudgetTests {

    @Test("rescanNow 一轮：全表扫描恰好一次，Agent 资源数值按 pid 取到")
    func oneFullScanPerTick() async throws {
        let inspector = ScanCountingInspector(records: tickRecords)
        let agent = AgentInstance(
            kind: .claudeCode, pid: tickAgentPID, parentPID: 1,
            displayName: "Claude", executablePath: "/usr/local/bin/claude",
            startedAt: Date(timeIntervalSince1970: 1_800_001_000),
            lastSeenAt: Date(), detectedVia: .processName
        )
        let (engine, store) = try await makeEngine(inspector: inspector, agents: [agent])

        await engine.rescanNow()
        await store.flush()

        #expect(inspector.scanCount == 1, "一个 tick 扫了 \(inspector.scanCount) 次全表")

        let session = try #require(try await engine.sessions(matching: .all).items.first)
        let samples = try await engine.performanceSamples(sessionID: session.id)
        #expect(samples.count == 1)
        let sample = try #require(samples.first)
        #expect(sample.cpuPercent == 12.5)
        #expect(sample.memoryBytes == 4_194_304)
    }

    /// 采集器没有精确取数能力时（桩、或第三方实现）退回全表：语义不变，代价照付。
    /// 钉住这条是为了让「退回全表」不是一句注释，而是可测的行为。
    @Test("采集器不支持按 pid 取数时退回全表，数值仍然拿到")
    func fallsBackToFullScanWithoutCapability() async throws {
        let agent = AgentInstance(
            kind: .claudeCode, pid: tickAgentPID, parentPID: 1,
            displayName: "Claude", executablePath: "/usr/local/bin/claude",
            startedAt: Date(timeIntervalSince1970: 1_800_001_000),
            lastSeenAt: Date(), detectedVia: .processName
        )
        let inspector = StubProcessSource(records: tickRecords)   // 不实现 ProcessMetricsReading
        let (engine, store) = try await makeEngine(inspector: inspector, agents: [agent])

        await engine.rescanNow()
        await store.flush()

        let session = try #require(try await engine.sessions(matching: .all).items.first)
        let samples = try await engine.performanceSamples(sessionID: session.id)
        #expect(samples.map(\.memoryBytes) == [4_194_304])
    }

    /// 没有 Agent 时不该产出采样行——但**扫描仍要发生**，否则新 Agent 永远发现不了。
    @Test("无 Agent 的 tick 依然扫描一次（不得为了省开销跳过扫描）")
    func scanStillHappensWithoutAgents() async throws {
        let inspector = ScanCountingInspector(records: [])
        let (engine, store) = try await makeEngine(inspector: inspector, agents: [])

        await engine.rescanNow()
        await store.flush()

        #expect(inspector.scanCount == 1)
        #expect(try await engine.sessions(matching: .all).items.isEmpty)
    }
}
