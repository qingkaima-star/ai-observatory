//
//  EngineTickAccountTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine（性能收尾线 ws/perfclose）
//  ─────────────────────────────────────────────────────────
//  AGENTS §6：「五个阶段各花多少 ms，加起来必须等于实测每 tick，对不上就是漏了项」。
//  本文件不判绝对值（那要静默窗），它判的是**这笔账能不能对上**：
//
//   1. `runTick()` 经过的九个阶段，每一段都必须被开启恰好一次——
//      这是"有没有漏项"的**确定性**判据。少打一个 `mark()` 不会让恒等式失效
//      （那段的 CPU 会被并进相邻段），只会让边界计数掉下来 ⇒ 当场红并点名。
//   2. 恒等式 `已入账 + 未归属 = 进程总量` 必须在真读数下成立。
//   3. 此前从没被量过的四段（storeReady / ingestAgents / ingestPerformance / syncProjects）
//      在真引擎上必须拿得到非零读数——它们正是 B10 记下「app 级 396 ms/tick 而链上
//      只拆出 ≈68 ms」那笔缺口所在。若哪天它们又变成 0，说明采集链被旁路了。
//
//  ⚠️ 这里**不**断言"每 tick ≤ 90 ms"。那是静默窗的判据（ADR-0009 裁定 5：CPU 那半
//  在非静默机器上判不得），把墙钟/绝对值写进常规套件就是一条只会制造红点的 flake。
//  绝对值由 `log show --predicate 'eventMessage CONTAINS "tick-account"'` 在产品里读，
//  或按下面的 `printsTheAccount` 在静默窗手动拉起来看。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryPlatform

private let accountAgentPID: Int32 = 23456

private let accountRecords: [ProcessRecord] = [
    ProcessRecord(
        pid: accountAgentPID, parentPID: 1, name: "claude",
        startTime: Date(timeIntervalSince1970: 1_800_002_000),
        cpuPercent: 7.5, memoryBytes: 2_097_152
    ),
]

private func makeEngineWithOneAgent() async throws -> ObservatoryEngine {
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let agent = AgentInstance(
        kind: .claudeCode, pid: accountAgentPID, parentPID: 1,
        displayName: "Claude", executablePath: "/usr/local/bin/claude",
        startedAt: Date(timeIntervalSince1970: 1_800_002_000),
        lastSeenAt: Date(), detectedVia: .processName
    )
    // 真实的 `HostMetricsSampler`：换桩就测不到 ingestPerformance 那段真有活（同 TickScanBudgetTests 的理由）。
    let inspector = StubProcessSource(records: accountRecords)
    return ObservatoryEngine(
        settings: ObservatorySettings(processScanIntervalSeconds: 3_600),
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: StubDetector(agents: [agent]),
            processInspector: inspector,
            metrics: HostMetricsSampler(processInspector: inspector),
            commandAuditor: StubAuditor(),
            fileObserver: StubFileObserver(),
            snapshotter: StubSnapshotter(),
            differ: StubDiffer()
        )
    )
}

@Suite("Engine：每-tick 阶段账本对得上（AGENTS §6 的可核对加总）", .timeLimit(.minutes(1)))
struct EngineTickAccountTests {

    /// 跑满 `ticks` 轮真采集（真 store、真采样器、真风险管线）。
    private func drivenAccount(ticks: Int) async throws -> TickAccount {
        let engine = try await makeEngineWithOneAgent()
        for _ in 0..<ticks { await engine.rescanNow() }
        let account = engine.tickAccount()
        await engine.stop()
        return account
    }

    @Test("九个阶段每轮各开启一次：无漏项（少一个 mark 即红）")
    func everyStageIsBoundedOncePerTick() async throws {
        let account = try await drivenAccount(ticks: 3)

        #expect(account.tickCount == 3)
        #expect(
            account.stagesWithWrongMarkCount.isEmpty,
            """
            漏项：\(account.stagesWithWrongMarkCount.map(\.rawValue).joined(separator: ", ")) 的边界次数不等于 tick 数 \
            ⇒ runTick 里有一段活没进账（AGENTS §6 的可核对加总当场失效）
            """
        )
        #expect(account.isStageCoverageComplete)
        for stage in TickStage.allCases {
            #expect(account.stageMarkCounts[stage] == 3, "\(stage.rawValue) 应每轮开启一次")
        }
    }

    @Test("恒等式成立：已入账 + 未归属 = 进程总量，且余额非负")
    func identityHoldsOnRealReadings() async throws {
        let account = try await drivenAccount(ticks: 3)

        #expect(account.processCPUMilliseconds > 0, "总量为 0 ⇒ 读数器没生效，本表无意义")
        #expect(!account.isClockInconsistent)
        #expect(
            abs(account.attributedCPUMilliseconds + account.unattributedCPUMilliseconds
                - account.processCPUMilliseconds) < 1e-6,
            """
            账对不上：已入账 \(account.attributedCPUMilliseconds) \
            + 余额 \(account.unattributedCPUMilliseconds) \
            ≠ 总量 \(account.processCPUMilliseconds)
            """
        )
        #expect(account.unattributedCPUMilliseconds >= 0)
        // 加总必须是"九段之和"，不能是其中几段——否则余额会被当成余量。
        // 容差 1e-6：字典求和与本用例的按序求和只是加法顺序不同（Dictionary 无序）。
        let manual = TickStage.allCases.reduce(0.0) { $0 + (account.stageCPUMilliseconds[$1] ?? 0) }
        #expect(abs(manual - account.attributedCPUMilliseconds) < 1e-6)
    }

    @Test("从前没被量过的四段在真引擎上非零（缺口那段确实有活）")
    func previouslyUnmeasuredStagesDoWork() async throws {
        let account = try await drivenAccount(ticks: 3)

        // 旧的 PlatformTickBreakdownTests 只量了 scan/detect/infer/sample 这几段；
        // 下面四段是「396 vs 68」那笔缺口的落点，必须能拿到读数。
        for stage in [TickStage.storeReady, .ingestAgents, .ingestPerformance, .syncProjects] {
            #expect(
                (account.stageCPUMilliseconds[stage] ?? 0) > 0,
                "\(stage.rawValue) 为 0 ⇒ 这段要么被旁路了，要么没打进账边界"
            )
        }
        // prune 只在首轮到期（`cadence.prune` = 24 h）、settling 只做一次状态比较，
        // 二者都可能落到 getrusage 的分辨率以下 ⇒ 不断言非零，只断言它们在场。
        #expect(account.stageCPUMilliseconds[.prune] != nil)
        #expect(account.stageCPUMilliseconds[.settling] != nil)
    }

    /// 静默窗用的读数出口：把整笔账打出来，供人对照 90 ms 预算。
    /// 断言只保证"表非空"，判定一律是人读输出（绝对值随负载变，写进断言就是 flake）。
    @Test("打印每-tick 加总表（静默窗取数用）")
    func printsTheAccount() async throws {
        let account = try await drivenAccount(ticks: 10)
        let cycle = 3.0
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        #if DEBUG
        let build = "DEBUG（不可用于判据）"
        #else
        let build = "RELEASE"
        #endif
        print("TICK-ACCOUNT 构建档=\(build) load \(String(format: "%.2f", load[0])) ticks=\(account.tickCount)")
        for stage in TickStage.allCases {
            print("TICK-ACCOUNT \(stage.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0))"
                + " = \(String(format: "%7.2f", account.msPerTick(stage))) ms/tick")
        }
        print("TICK-ACCOUNT 已入账 = \(String(format: "%7.2f", account.attributedMSPerTick)) ms/tick"
            + " 未归属 = \(String(format: "%7.2f", account.unattributedMSPerTick)) ms/tick"
            + " 预算(周期 \(cycle) s × 3%) = \(String(format: "%.1f", TickAccount.budgetMSPerTick(cycleSeconds: cycle))) ms/tick")

        #expect(account.tickCount == 10)
        #expect(account.attributedMSPerTick > 0)
    }
}
