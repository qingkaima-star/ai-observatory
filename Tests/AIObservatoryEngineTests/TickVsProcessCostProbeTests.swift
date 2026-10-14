//
//  TickVsProcessCostProbeTests.swift
//  AIObservatoryEngineTests
//
//  Owner: ws/engaudit（#53 第一步，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  #53 要回答的第一个问题不是"哪一段贵"，而是**那 22–32 % 到底在不在引擎 tick 里**。
//  `TickStageLedger` 的九段只覆盖 `runTick()`；界面、采样线程、`SelfProcessSampler` 自己
//  烧的 CPU 全在分母之外——所以"未归属 ≈ 0"只说明**tick 内部**记全了，不代表整进程记全了。
//
//  判别实验（本文件）：在**同一个测试进程**里跑真装配（真 `LibprocProcessInspector` +
//  真 `SelfProcessSampler` + 真 `AgentDetectionPipeline` + 真 SQLite 库，`monitoredRoots=[]` ⇒ 无文件事件），
//  同时取两个数：
//   · A = `tickAccount()` 的 attributed + unattributed（= 九段记到的每轮 CPU 之和）
//   · B = `SelfProcessSampler` 的进程 CPU 增量 ÷ 轮数（= 这个进程每轮真实烧掉多少）
//  比值 A/B 就是答案：
//   · A/B ≈ 1 ⇒ 成本全在 tick 内 ⇒ 嫌疑 ①②（逐 pid `task_info`、批量写）按段减就行；
//   · A/B ≪ 1 ⇒ 大头在 tick **外** ⇒ ①② 白测，该去找界面/常驻线程（测试进程没有界面，
//     所以这里 ≪ 1 就直接把渲染那一块夹出来了）。
//
//  对照：同一份代码跑两遍，一遍让真检测器自然跑（本机有被检出的宿主 ⇒ agents ≥ 1），
//  一遍把检测器换成"永远返回空"（agents = 0）——这就是派单要的"有 1 个 Agent vs 无"两态。
//
//  ⚠️ 纪律（本会话已栽过一次）：
//   · **默认不跑**（env 开关 + `.serialized`）：`selfCPUSeconds()` 量整进程，并行套件会污染读数；
//   · 库落在 `Scratch`（工作树内），不设 `AIOBSERVATORY_DATA_DIR` 那种会写到 ~/Library 的路径；
//   · 跑完自己把两个数打出来，不要留"应该没差"这种话。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

private let probeEnabled = ProcessInfo.processInfo.environment["AIOBSERVATORY_TICK_VS_PROCESS"] != nil

/// 每轮之间的间隔。真机节奏是 3 s；这里压到 1 s 换轮数（比值与节奏无关，
/// 但轮数越多越能把一次性开销摊掉）。
private let probeTicks = 20
private let probeCadenceSeconds = 1.0

/// 只换检测结果的桩：其余全部用 `Components.live` 的真件。
private struct DetectorStub: AgentDetecting {
    /// false = 永远检不出（agents=0 那一态）；true = 交给真检测器，让本机进程自己决定，不造数。
    let realDetection: Bool
    /// nil = 用默认策略链；给了数字就只跑前 N 条（用来量 #47 新加的第 7 条策略自己值多少钱）。
    var strategyLimit: Int? = nil
    func detectAgents(using processSource: any ProcessInspecting) async -> [AgentInstance] {
        guard realDetection else { return [] }
        let all = AgentDetectionPipeline.defaultStrategies
        let strategies = strategyLimit.map { Array(all.prefix($0)) } ?? all
        return await AgentDetectionPipeline(strategies: strategies).detectAgents(using: processSource)
    }
    func realtimeCapability() -> RealtimeCapability { .processPolling }
}

/// 空库还是**真库副本**：#53 第三档的关键一维——产品里 `syncProjects` 要聚合的是几万行历史，
/// 空库探针量不到它（前面几档 syncProjects 恒 0.0，就是因为库里没东西）。
/// 用 `AIOBSERVATORY_PROBE_DB=<副本路径>` 指过去；不设就用空库。
private var probeDatabasePath: String? {
    ProcessInfo.processInfo.environment["AIOBSERVATORY_PROBE_DB"]
}

private func probeEngine(detecting: Bool, strategyLimit: Int? = nil) async throws -> (ObservatoryEngine, ObservatoryStore) {
    let configuration: SQLiteDatabase.Configuration
    if let path = probeDatabasePath {
        configuration = SQLiteDatabase.Configuration(location: .file(path: path))
    } else {
        let directory = try Scratch.directory("tick-vs-process-\(detecting ? "on" : "off")-\(strategyLimit.map(String.init) ?? "all")")
        configuration = SQLiteDatabase.Configuration(location: .file(path: directory.appending(path: "observatory.sqlite").path))
    }
    let store = try await ObservatoryStore.open(configuration: configuration)
    let settings = ObservatorySettings(
        monitoredRoots: [],
        ignoredPathPatterns: [],
        processScanIntervalSeconds: probeCadenceSeconds
    )
    var components = ObservatoryEngine.Components.live(settings: settings)
    components.detector = DetectorStub(realDetection: detecting, strategyLimit: strategyLimit)
    return (ObservatoryEngine(settings: settings, components: components), store)
}

@Suite("tick 九段之和 vs 整进程 CPU：#53 的第一步判别", .serialized)
struct TickVsProcessCostProbeTests {

    @Test("同一进程里比 A=九段之和 与 B=进程增量，两态各跑一遍", .enabled(if: probeEnabled))
    func compareLedgerAgainstProcessCPU() async throws {
        var baselineMSPerTick = 0.0
        var differenceMSPerTick = 0.0
        var detectedAgents = 0
        for state in [(false, nil), (true, 6), (true, nil)] {
            let (detecting, strategyLimit) = state
            let (engine, store) = try await probeEngine(detecting: detecting, strategyLimit: strategyLimit)
            let sampler = SelfProcessSampler()
            // 先跑一轮把建库、迁移、首次符号解析这些一次性开销排除在测量之外。
            await engine.rescanNow()
            let cpu0 = sampler.sample()
            for _ in 0..<probeTicks {
                await engine.rescanNow()
                try await Task.sleep(for: .seconds(probeCadenceSeconds))
            }
            let cpu1 = sampler.sample()
            let account = engine.tickAccount()
            let wall = cpu1.takenAt.timeIntervalSince(cpu0.takenAt)
            let processMSPerTick = (cpu1.cpuSeconds - cpu0.cpuSeconds) * 1_000 / Double(probeTicks)
            let ledgerMSPerTick = account.attributedMSPerTick + account.unattributedMSPerTick
            let ratio = ledgerMSPerTick / max(processMSPerTick, 0.0001)
            var segments: [String] = []
            for stage in TickStage.allCases {
                segments.append("\(stage.rawValue)=\(String(format: "%.1f", account.msPerTick(stage)))")
            }
            print(String(
                format: "#53-judge agents=%@ 墙钟 %.0fs 进程 %.1f ms/tick | 台账 %.1f（unattr %.1f）A/B=%.2f | %@",
                detecting ? "≥1/限\(strategyLimit.map(String.init) ?? "全")" : "0", wall,
                processMSPerTick, ledgerMSPerTick,
                account.unattributedMSPerTick, ratio, segments.joined(separator: " ")
            ))
            // 两态之差就是"多检出 1 个 Agent"的账内代价，逐段可查。
            if detecting {
                differenceMSPerTick = processMSPerTick - baselineMSPerTick
                detectedAgents = try await engine.activeAgents().count
            }
            if !detecting { baselineMSPerTick = processMSPerTick }
            // 仪器闸门：进程每轮必须真的烧到可测，否则比值是噪声。
            #expect(processMSPerTick > 1.0, "每轮只烧 \(processMSPerTick) ms，仪器读不出 A/B 比值")
            // 台账必须覆盖整进程（A/B ≈ 1）：这一条与数据形状无关，是"洞"的判据。
            #expect(ratio > 0.85 && ratio < 1.2,
                    "A/B=\(ratio) ⇒ 九段之和与进程增量对不上，台账视野之外还有东西")
            // 库不显式关：ObservatoryStore 没有 close（连接随 actor 释放）。
            _ = store
        }
        print(String(format: "#53-judge 检出 %@ 个 Agent，账内增量合计 %.1f ms/tick ⇒ 每 Agent %.1f ms/tick",
                     String(detectedAgents), differenceMSPerTick,
                     differenceMSPerTick / Double(max(detectedAgents, 1))))
        // 结论**不写死在代码里**：上一版我在这里印了一句"账内 ≈ 2.6 %"，
        // 那是空库探针的数，换成真库副本之后同一档实测 190.7 ms/tick ⇒ 那句结论是错的。
        // 现在只印算式，谁读谁自己换算节奏（产品 3 s、本探针 1 s）。
        print(String(format: "#53-judge ⇒ 账内每轮 %.1f ms；3 s 节奏 = %.2f %%、1 s 节奏 = %.2f %%",
                     differenceMSPerTick, differenceMSPerTick / 30.0, differenceMSPerTick / 10.0))
        // 断"每 Agent 每轮"，不断合计差值：合计随本机此刻检出几个 Agent 变
        // （同一份代码两次实测 162.5 与 296.8 ms/tick），那是机器状态不是代码性质。
        // ⚠️ 60 ms 是**回归哨兵**，不是 #53 的验收判据——验收是"整进程 ≤ 3 % 预算"，现在远没到。
        let perAgentMS = differenceMSPerTick / Double(max(detectedAgents, 1))
        #expect(perAgentMS < 60, "每个被检出的 Agent 每轮多烧 \(perAgentMS) ms，超过 60 ms 的回归哨兵")
    }
}
