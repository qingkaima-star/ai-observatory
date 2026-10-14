//
//  SessionPerformanceAggregationTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-ProcScan（工单 #23）
//
//  会话性能样本 = **同一时刻**「Agent ∪ 归属它的子孙进程」之和。
//
//  钉两件事，第二件是本次真正的风险：
//   1. 只报父进程会让会话读数系统性低报（Agent 的活在子进程里）；
//   2. 「各进程峰值之和」不是会话峰值——它把从未同时发生过的数字拼在一起
//      （t1 父 10% + t2 子 20% ⇒ 30%，而任一时刻都没到过 30%）。
//  所以断言全部用字面量，并且专门有一条「错算法必红」的对齐用例。
//

import Testing
import Foundation
import os
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore

/// 按 pid 给值的采样器：聚合的输入必须完全由测试决定。
final class ScriptedMetrics: SystemMetricsSampling, Sendable {
    private let lock = OSAllocatedUnfairLock<[Int32: ProcessSample]>(initialState: [:])

    /// 写入这一 tick 每个 pid 的读数；没列出的 pid 视为「读不到」（缺席，不是 0）。
    func set(_ values: [Int32: (cpu: Double, memory: UInt64)]) {
        lock.withLock { state in
            var next: [Int32: ProcessSample] = [:]
            for (pid, value) in values {
                next[pid] = ProcessSample(
                    pid: pid, cpuPercent: value.cpu, memoryBytes: value.memory
                )
            }
            state = next
        }
    }

    func sampleSystem() async -> SystemPerformanceSample {
        SystemPerformanceSample(cpuTotalPercent: 1, memoryUsedBytes: 1, memoryTotalBytes: 2)
    }

    func sampleProcesses(pids: [Int32]) async -> [Int32: ProcessSample] {
        let all = lock.withLock { $0 }
        var result: [Int32: ProcessSample] = [:]
        for pid in pids { if let hit = all[pid] { result[pid] = hit } }
        return result
    }
}

private func makeEngine(agents: [AgentInstance], metrics: ScriptedMetrics) async throws
    -> (ObservatoryEngine, ObservatoryStore) {
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let engine = ObservatoryEngine(
        settings: ObservatorySettings(processScanIntervalSeconds: 3_600),
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: StubDetector(agents: agents),
            processInspector: StubProcessSource(),
            metrics: metrics,
            commandAuditor: StubAuditor(),
            fileObserver: StubFileObserver(),
            snapshotter: StubSnapshotter(),
            differ: StubDiffer()
        )
    )
    return (engine, store)
}

private func agentInstance(_ id: UUID, _ pid: Int32, children: [Int32], kind: AgentKind = .claudeCode) -> AgentInstance {
    let started = Date(timeIntervalSince1970: 1_900_600_000)
    return AgentInstance(
        id: id, kind: kind, pid: pid, parentPID: 1,
        displayName: kind.displayName, executablePath: "/usr/local/bin/agent",
        startedAt: started, lastSeenAt: started,
        childPIDs: children, detectedVia: .processName
    )
}

/// 每个 Agent 的会话样本，按 agentID 归组。
private func rowsByAgent(_ engine: ObservatoryEngine) async throws -> [UUID: [PerformanceSample]] {
    let sessions = try await engine.sessions(matching: .all).items
    var grouped: [UUID: [PerformanceSample]] = [:]
    for session in sessions {
        guard let agentID = session.agentID else { continue }
        grouped[agentID] = try await engine.performanceSamples(sessionID: session.id)
    }
    return grouped
}

@Suite("会话性能样本：Agent ∪ 子孙在同一时刻求和", .timeLimit(.minutes(1)))
struct SessionPerformanceAggregationTests {

    @Test("会话读数 = 父 + 各子在同一时刻之和（2 + 30 + 5 = 37）")
    func sumsAgentAndChildren() async throws {
        let id = UUID()
        let metrics = ScriptedMetrics()
        metrics.set([
            100: (2, 1_000), 101: (30, 2_000), 102: (5, 3_000),
        ])
        let (engine, store) = try await makeEngine(
            agents: [agentInstance(id, 100, children: [101, 102])], metrics: metrics
        )
        await engine.rescanNow()
        await store.flush()

        let rows = try #require(try await rowsByAgent(engine)[id])
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        // 只报父进程的话这里是 2%——那正是 #23 的病症。
        #expect(row.cpuPercent == 37)
        #expect(row.memoryBytes == 6_000)
    }

    /// 错算法（各进程峰值再相加）会得到 CPU 30 / 内存 13，而这个会话任一时刻都没到过那里。
    @Test("峰值取「逐时刻之和的最大值」，不是「各进程峰值之和」")
    func peakUsesTimeAlignedSums() async throws {
        let id = UUID()
        let metrics = ScriptedMetrics()
        let (engine, store) = try await makeEngine(
            agents: [agentInstance(id, 100, children: [101])], metrics: metrics
        )

        metrics.set([100: (10, 5), 101: (0, 0)])
        await engine.rescanNow()
        metrics.set([100: (0, 0), 101: (20, 8)])
        await engine.rescanNow()
        await store.flush()

        let rows = try await rowsByAgent(engine)[id] ?? []
        #expect(rows.map(\.cpuPercent) == [10, 20])
        let session = try #require(try await engine.sessions(matching: .all).items.first)
        #expect(session.peakCPUPercent == 20)
        #expect(session.peakMemoryBytes == 8)
    }

    @Test("嵌套 Agent：一个进程只记给最近的主人，总量不被算两遍")
    func nestedAgentsBillEachProcessOnce() async throws {
        let idA = UUID()
        let idC = UUID()
        let metrics = ScriptedMetrics()
        // A(100) 拉起 101 与另一个 Agent C(150)；C 又拉起 151。
        metrics.set([100: (1, 10), 101: (2, 20), 150: (3, 30), 151: (4, 40)])
        let (engine, store) = try await makeEngine(
            agents: [
                agentInstance(idA, 100, children: [101, 150, 151]),
                agentInstance(idC, 150, children: [151], kind: .geminiCLI),
            ],
            metrics: metrics
        )
        await engine.rescanNow()
        await store.flush()

        let grouped = try await rowsByAgent(engine)
        let rowA = try #require(grouped[idA]?.first)
        let rowC = try #require(grouped[idC]?.first)
        #expect(rowA.cpuPercent == 3)   // 100 + 101；150/151 归 C
        #expect(rowC.cpuPercent == 7)   // 150 + 151
        #expect(rowA.cpuPercent + rowC.cpuPercent == 10)   // 恰好等于四个进程之和 ⇒ 无双计
        #expect(rowA.memoryBytes + rowC.memoryBytes == 100)
    }

    @Test("没有子进程时与旧行为逐字相等（修 A 不许弄坏 B）")
    func singleProcessUnchanged() async throws {
        let id = UUID()
        let metrics = ScriptedMetrics()
        metrics.set([100: (40, 512 * 1024 * 1024)])
        let (engine, store) = try await makeEngine(
            agents: [agentInstance(id, 100, children: [])], metrics: metrics
        )
        await engine.rescanNow()
        await store.flush()

        let row = try #require(try await rowsByAgent(engine)[id]?.first)
        #expect(row.cpuPercent == 40)
        #expect(row.memoryBytes == 512 * 1024 * 1024)
        #expect(row.agentID == id)
    }

    /// 锚点读不到 ⇒ 整条不落。带上子孙之后更要钉住：不能因为「别的进程有数」就
    /// 造出一条只含子进程的半截会话读数。
    @Test("Agent 自身读不到时不落任何样本行，即使子进程有数")
    func missingAnchorWritesNoRow() async throws {
        let id = UUID()
        let metrics = ScriptedMetrics()
        metrics.set([101: (30, 2_000)])          // 100 缺席（读不到）
        let (engine, store) = try await makeEngine(
            agents: [agentInstance(id, 100, children: [101])], metrics: metrics
        )
        await engine.rescanNow()
        await store.flush()

        let grouped = try await rowsByAgent(engine)
        #expect((grouped[id] ?? []).isEmpty)
    }
}
