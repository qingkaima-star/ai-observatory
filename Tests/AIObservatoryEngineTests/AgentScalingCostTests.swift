//
//  AgentScalingCostTests.swift
//  AIObservatoryEngineTests
//
//  Owner: ws/engaudit（#53，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  #53 的问题：#47 把 GUI 宿主检出之后，判据④ 的 CPU 半边从 1.23–2.10 % 涨到 19.06 %
//  （三轮 42.59 / 7.53 / 4.39）。要回答的不是"能不能优化"，而是**涨在哪一段、随什么变**。
//
//  为什么现在就能测（不必等静默窗）：`TickStageLedger` 记的是本进程**累计 CPU 时间**
//  （`getrusage`），别人抢 CPU 只会让我们少被调度，不会把我们自己烧掉的秒数变成别的数字
//  ⇒ 阶段间的**相对**归因在非静默窗成立；要静默窗的是「Δcputime ÷ 墙钟 ≤ 3 %」那条聚合判据。
//  出口按 #53 第 1 条换掉了：**不读日志、不读 stderr**，直接读 `ObservatoryEngine.tickAccount()`
//  （本机 `log show` 对任何 subsystem 都返 0 行，那条路早就证明不可靠）。
//
//  两档：
//   · **默认跑的判定用例**（`perAgentBoundIsAssertable`）——把"每轮每 Agent 的成本上界"
//     做成断言，而不是事后肉眼。它同时钉住离散度的来源：Agent 数、每个 Agent 名下子孙数。
//   · **env 开关的打数用例**（`AIOBSERVATORY_AGENT_SCALING=1`）——扫 1/2/4/8 个 Agent，
//     逐段打 ms/tick 与相对 1-Agent 的倍率。打数不做判定（判定留给上面那条与静默窗）。
//
//  ⚠️ 绝对值随机器负载漂移，所以断言用的是**比值与斜率**，不是毫秒数；
//     并且有一条仪器闸门：整轮成本必须明显贵到可测，否则不许在噪声上判绿。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryEngine
@testable import AIObservatoryStore
@testable import AIObservatoryPlatform

private let scalingEnabled = ProcessInfo.processInfo.environment["AIOBSERVATORY_AGENT_SCALING"] != nil

/// 每个 Agent 名下的子孙进程数。真机一个 Electron 家族实测 8 个包内进程 + 每条命令一个 shell，
/// 取 12 是为了让"子孙规模"这一维真的参与扫描。
private let descendantsPerAgent = 12
private let scalingTicks = 12

/// 造 N 个 Agent × 各自一棵子孙树，外加一批"看起来像真机"的无关进程（策略链要为它们白跑）。
private func scalingFixture(agents agentCount: Int, noise: Int) -> (
    records: [ProcessRecord], agents: [AgentInstance]
) {
    let started = Date(timeIntervalSince1970: 1_900_008_000)
    var records: [ProcessRecord] = []
    var agents: [AgentInstance] = []
    for slot in 0..<agentCount {
        let basePID = Int32(50_000 + slot * 1_000)
        let bundle = "/Applications/Scaling Host \(slot).app"
        let mainExecutable = "\(bundle)/Contents/MacOS/Scaling Host \(slot)"
        records.append(ProcessRecord(
            pid: basePID, parentPID: 1, name: "Scaling Host \(slot)",
            executablePath: mainExecutable, arguments: [mainExecutable],
            startTime: started, workingDirectory: "/"
        ))
        var childPIDs: [Int32] = []
        for offset in 1...descendantsPerAgent {
            let pid = basePID + Int32(offset)
            let helper = "\(bundle)/Contents/Frameworks/Scaling Helper.app/Contents/MacOS/Scaling Helper"
            records.append(ProcessRecord(
                pid: pid, parentPID: offset == 1 ? basePID : basePID + 1,
                name: "Scaling Helper",
                executablePath: helper,
                arguments: [helper, "--type=renderer", "--user-data-dir=/Users/dev/.scaling"],
                startTime: started, workingDirectory: "/Users/dev/Projects/Scaling\(slot)"
            ))
            childPIDs.append(pid)
        }
        agents.append(AgentInstance(
            kind: .genericCLIAgent,
            pid: basePID,
            displayName: "Scaling Host \(slot)",
            executablePath: mainExecutable,
            workingDirectory: "/",
            startedAt: started,
            lastSeenAt: started.addingTimeInterval(60),
            state: .running,
            childPIDs: childPIDs,
            detectedVia: .argumentSignature
        ))
    }
    for offset in 0..<noise {
        let pid = Int32(70_000 + offset)
        records.append(ProcessRecord(
            pid: pid, parentPID: 1, name: "idle-daemon-\(offset)",
            executablePath: "/usr/local/libexec/idle-daemon-\(offset)",
            arguments: ["/usr/local/libexec/idle-daemon-\(offset)"],
            startTime: started
        ))
    }
    return (records, agents)
}

private struct ScalingSource: ProcessInspecting {
    let records: [ProcessRecord]
    func scanProcesses() async -> [ProcessRecord] { records }
}

private struct ScalingDetector: AgentDetecting {
    let agents: [AgentInstance]
    func detectAgents(using processSource: any ProcessInspecting) async -> [AgentInstance] { agents }
    func realtimeCapability() -> RealtimeCapability { .processPolling }
}

private func scalingEngine(_ agentCount: Int, noise: Int) async throws -> ObservatoryEngine {
    let fixture = scalingFixture(agents: agentCount, noise: noise)
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let settings = ObservatorySettings(
        monitoredRoots: [],
        ignoredPathPatterns: [],
        processScanIntervalSeconds: 3
    )
    let live = ObservatoryEngine.Components.live(settings: settings)
    let mapper = ProjectMapper(resolver: { _ in nil })
    return ObservatoryEngine(
        settings: settings,
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: ScalingDetector(agents: fixture.agents),
            processInspector: ScalingSource(records: fixture.records),
            metrics: StubMetrics(),
            commandAuditor: StubAuditor(),
            fileObserver: StubFileObserver(),
            snapshotter: StubSnapshotter(),
            differ: live.differ,
            aggregator: TimelineAggregator(projectMapper: mapper),
            projectMapper: mapper
        )
    )
}

/// 跑 `scalingTicks` 轮，返回整段的本进程 CPU 毫秒。
private func runTicks(_ engine: ObservatoryEngine) async -> Double {
    let cpu0 = TickStageLedger.selfCPUSeconds()
    for _ in 0..<scalingTicks {
        await engine.rescanNow()
    }
    let cpu1 = TickStageLedger.selfCPUSeconds()
    return (cpu1 - cpu0) * 1_000
}

@Suite("每轮每 Agent 的成本：可断言的上界", .serialized)
struct AgentScalingCostTests {

    /// 默认跑的判定：**成本随 Agent 数的斜率**有上界。
    ///
    /// 为什么断斜率而不是断毫秒：绝对值随机器与编译配置漂移，而 #53 要回答的恰恰是
    /// "多检出 N 个 Agent 要多花多少"——那是一阶导数，不是截距。
    ///
    /// ⚠️ **默认不跑，必须单独 `--filter` 跑**（与 `EngineTickAttributionTests` 同一条理由，
    ///    这里是实测踩出来的）：`selfCPUSeconds()` 量的是**整个进程**的累计 CPU，
    ///    而 Swift Testing 默认并行执行套件——第一次全量跑时这条断言报
    ///    "1 个 Agent 32 720 ms / 12 轮"，那是别的用例烧的 CPU 记到了我头上。
    ///    单独跑同一台机器同一份代码：1.34 ms/tick。
    ///    ⇒ 任何"进程 CPU 时间"型断言都不能待在默认并行的套件里。
    /// 离散度（42 % vs 4 %）的线索也在这里：如果斜率小而方差大，涨的是**每 Agent 的子孙规模**
    /// 与命令落库条数，不是"检出本身"。
    @Test("成本随 Agent 数近似线性，且每多一个 Agent 的增量有上界", .enabled(if: scalingEnabled))
    func perAgentBoundIsAssertable() async throws {
        let noise = 200
        let one = await runTicks(try await scalingEngine(1, noise: noise))
        let four = await runTicks(try await scalingEngine(4, noise: noise))
        // 仪器闸门：单 Agent 那档必须贵到可测。合成装置的真实读数在 0.3 ms/tick 量级
        // （这本身就是 #53 的一条结论：引擎账内按 Agent 展开的工作是亚毫秒的），
        // 所以地板定在 0.05 ms——低于它才是"在噪声上判绿"。
        #expect(
            one / Double(scalingTicks) > 0.05,
            "单 Agent 每轮只有 \(one / Double(scalingTicks)) ms CPU，仪器读不出斜率——这条不许在噪声上判绿"
        )
        // 斜率：从 1 个到 4 个 Agent，多出的成本除以多出的 3 个 Agent。
        let msPerExtraAgent = (four - one) / 3.0 / Double(scalingTicks)
        #expect(
            msPerExtraAgent < 1.0,
            "每多一个 Agent（含 \(descendantsPerAgent) 个子孙）每轮多花 \(msPerExtraAgent) ms CPU，超过 1 ms 的上界"
        )
        // 单调性：涨必须真的来自 Agent 数，不是噪声（4 个必须明显贵过 1 个）。
        #expect(four > one * 1.2, "1 个 Agent \(one) ms、4 个 \(four) ms ⇒ 成本不随 Agent 数走，#53 的归因要重做")
    }

    /// env 开关的打数：扫 1/2/4/8 个 Agent，逐段打 ms/tick 与相对倍率。
    @Test("打数：逐段 ms/tick 随 Agent 数的变化", .enabled(if: scalingEnabled))
    func printStageBreakdown() async throws {
        for agentCount in [1, 2, 4, 8] {
            let engine = try await scalingEngine(agentCount, noise: 200)
            let total = await runTicks(engine)
            let account = engine.tickAccount()
            var pieces: [String] = []
            for stage in TickStage.allCases {
                pieces.append("\(stage.rawValue)=\(String(format: "%.2f", account.msPerTick(stage)))")
            }
            print(String(
                format: "#53 agents=%d 总 CPU=%.1f ms（%.2f ms/tick） attributed=%.2f/tick unattributed=%.2f/tick 分段: %@",
                agentCount, total, total / Double(scalingTicks),
                account.attributedMSPerTick, account.unattributedMSPerTick,
                pieces.joined(separator: " ")
            ))
        }
    }

    /// env 开关的**真采集件**探针：同一份真实进程快照，只改"检出几个 Agent"，
    /// 采集器与命令推断都用真的（`LibprocProcessInspector` / `CommandInferenceEngine`）+ 真库。
    /// 这是 #53 第 1 条要的分解：涨如果不在账内，这里就会露出来（`unattributed` 那一列）。
    @Test("真采集件：0 / 1 / 4 个 Agent 的逐段 ms/tick", .enabled(if: scalingEnabled))
    func realCollectorProbe() async throws {
        let records = await LibprocProcessInspector().scanProcesses()
        // 真实扫描本身的成本（探针其余部分都在**回放**这份快照，所以扫描不在 ms/tick 里）。
        let probeInspector = LibprocProcessInspector()
        let scanCPU0 = TickStageLedger.selfCPUSeconds()
        for _ in 0..<3 { _ = await probeInspector.scanProcesses() }
        let scanMSPerRun = (TickStageLedger.selfCPUSeconds() - scanCPU0) * 1_000 / 3
        print(String(format: "#53-scan 真实 scanProcesses()（%d 个进程）= %.1f ms CPU/次", records.count, scanMSPerRun))
        // 从真实快照里挑 N 个"像宿主"的进程当 Agent（父是 launchd、在某个 .app 内），
        // 子孙用真实父链算 ⇒ 推断器要做的事与产品里同形。
        let hosts = records.filter {
            $0.parentPID == 1 && $0.executablePath.contains(".app/")
        }
        #expect(!hosts.isEmpty, "这台机器上没有一个 .app 宿主进程，探针无从测起")
        for agentCount in [0, 1, min(4, hosts.count)] {
            let agents = hosts.prefix(agentCount).map { host -> AgentInstance in
                let children = records.filter { $0.parentPID == host.pid }.map(\.pid)
                return AgentInstance(
                    kind: .genericCLIAgent,
                    pid: host.pid,
                    displayName: "Probe Agent",
                    executablePath: host.executablePath,
                    workingDirectory: host.workingDirectory ?? "/",
                    startedAt: host.startTime ?? Date(),
                    lastSeenAt: Date(),
                    state: .running,
                    childPIDs: children,
                    detectedVia: .argumentSignature
                )
            }
            let engine = try await realCollectorEngine(records: records, agents: agents)
            let total = await runTicks(engine)
            let account = engine.tickAccount()
            var pieces: [String] = []
            for stage in TickStage.allCases where (account.stageCPUMilliseconds[stage] ?? 0) > 0 {
                pieces.append("\(stage.rawValue)=\(String(format: "%.2f", account.msPerTick(stage)))")
            }
            print(String(
                format: "#53-real 快照=%d agents=%d 总=%.1f ms（%.2f ms/tick） attributed=%.2f unattributed=%.2f | %@",
                records.count, agents.count, total, total / Double(scalingTicks),
                account.attributedMSPerTick, account.unattributedMSPerTick,
                pieces.joined(separator: " ")
            ))
            // 扫描这一维现在**在计时循环里**（真 inspector 直接挂在引擎上）⇒ 台账必须记到它。
            // 记到 0 就是账本有洞，这条断言是 #53 第 1 条的守卫。
            let scanMS = account.msPerTick(.scanProcesses)
            #expect(scanMS > 2.0, "真扫描挂在引擎上，台账却只记到 \(scanMS) ms/tick ⇒ 这一段没进账")
        }
    }
}

/// 用真采集件装配一台"只换 Agent 数"的引擎。
private func realCollectorEngine(records: [ProcessRecord], agents: [AgentInstance]) async throws -> ObservatoryEngine {
    let settings = ObservatorySettings(
        monitoredRoots: [], ignoredPathPatterns: [], processScanIntervalSeconds: 3
    )
    let live = ObservatoryEngine.Components.live(settings: settings)
    let mapper = ProjectMapper(resolver: { _ in nil })
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    return ObservatoryEngine(
        settings: settings,
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: ScalingDetector(agents: agents),
            processInspector: LibprocProcessInspector(),
            metrics: live.metrics,
            commandAuditor: CommandInferenceEngine(),
            fileObserver: StubFileObserver(),
            snapshotter: live.snapshotter,
            differ: live.differ,
            aggregator: TimelineAggregator(projectMapper: mapper),
            projectMapper: mapper
        )
    )
}