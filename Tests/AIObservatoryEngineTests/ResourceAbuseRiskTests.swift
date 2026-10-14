//
//  ResourceAbuseRiskTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine
//
//  「资源滥用」两条规则的**可达性**回归：
//   · `risk.pattern.sustained-cpu-peak`
//   · `risk.pattern.excessive-memory-peak`
//
//  为什么需要这个文件：这两条是全库唯一以 `RiskFactWindow.samples` 为输入的规则，而契约
//  `RiskContext`（`AIObservatoryCore`，冻结）只携带 event / command / fileChange —— **不带采样**。
//  在 `RiskPipeline.noteSample(_:sessionID:agentKind:)` 出现之前，编排层唯一的入口是
//  `evaluate(_:)`，于是 `window.samples` 恒为空数组，两条规则在运行中的 app 里**永不触发**。
//  模块 ⑧ 的既有测试仍然全绿，因为它们直接手工构造 `RiskFactWindow` 喂 `RiskAssessor`，
//  绕过了「采样能不能进到窗口」这一层。所以本文件刻意分两层断言：
//
//   A. 编排层（`RiskPipeline`）：采样经 `noteSample` → 恰好命中 1 条；重放被 `emitted`
//      幂等键挡住；低于阈值不命中（并断言采样确实进了窗口，防止「空窗口所以不命中」的假绿）。
//   B. 端到端（`ObservatoryEngine`）：采样经引擎自己的采集节拍（`ingestPerformance`）
//      → 真的落库到 `risk_events`。缺了 B 正是当初这个 bug 藏住的原因。
//
//  确定性约定：A 层全部时间戳是 `Date(timeIntervalSince1970:)` 常量，采样 id 由
//  `StableID.uuid(namespace:key:)` 派生（`PerformanceSample.init` 默认 `UUID()` 会把不确定性
//  带进幂等键），home / 阈值经构造子注入，不读墙钟、不 sleep 等阈值。
//  B 层的采样时间戳来自引擎节拍（`Date()`），因此阈值调成「单个采样就足以一个采样间隔」，
//  使结论与墙钟推进量无关。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryRiskRules
import AIObservatoryStore
import AIObservatoryTestSupport

//  关于 `AIObservatoryTestSupport`：本文件只取 `FixturePaths` 作宿主前缀
//  （Agent 的 cwd 与注入给 `ProjectMapper` 的前缀谓词必须同源，否则谓词不再命中）。
//  `SampleData` 只在 `demoService()` 里造**随机区间**的采样
//  （cpu 4…88、内存 300…2800MB），跨在阈值两侧，无法用来做「恰好 120 秒 / 恰好 1 倍阈值」这类
//  边界断言；`Scratch` 也不需要（引擎端到端用 `.inMemory` 库，不落文件）。
//  本文件的确定性来自 `StableID.uuid(namespace:key:)` 派生的采样 id 与固定 epoch 时间戳。

// MARK: - 固定基准与工厂

private enum SampleClock {
    static let base = Date(timeIntervalSince1970: 1_900_000_000)
    static func at(_ offset: TimeInterval) -> Date { base.addingTimeInterval(offset) }
}

/// 注入的宿主 home：与真实机器无关。
private let abuseHome = "/Users/observer"
private let gibibyte: UInt64 = 1024 * 1024 * 1024

/// 确定性采样 id：`PerformanceSample` 默认 `UUID()` 是进程随机的。
private func sampleID(_ key: String) -> UUID {
    StableID.uuid(namespace: "risk-sample", key: key)
}

/// 一条性能采样。`batch` 进 id，用于「同一批事实换个 id 再投一遍」的用例。
private func abuseSample(
    batch: String,
    index: Int,
    offset: TimeInterval,
    cpu: Double,
    memory: UInt64,
    session: UUID?
) -> PerformanceSample {
    PerformanceSample(
        id: sampleID("\(batch):\(index)"),
        timestamp: SampleClock.at(offset),
        sessionID: session,
        agentID: nil,
        cpuPercent: cpu,
        memoryBytes: memory
    )
}

/// 高 CPU 采样批：60 个点、每点间隔 2 秒 ⇒ 运行段时长 = 59×2 + 2 = **恰好 120 秒**，
/// 等于默认阈值 `sustainedCPUSeconds = 120`（`sustainedCPUPercent = 80`，报 95%）。
private func cpuBurst(batch: String = "a", session: UUID, count: Int = 60) -> [PerformanceSample] {
    (0..<count).map { index in
        abuseSample(batch: batch, index: index, offset: Double(index) * 2,
                    cpu: 95, memory: 0, session: session)
    }
}

/// 走「唯一规则库 + 默认阈值」的编排层实例。
private func abusePipeline(thresholds: RiskThresholds = .standard) -> RiskPipeline {
    RiskPipeline(homeDirectory: abuseHome, thresholds: thresholds)
}

/// 命中事件的规则 id（保持产出顺序）。
private func ruleIDs(_ events: [RiskEvent]) -> [String] {
    events.compactMap(\.matchedRuleID)
}

// MARK: - A. 编排层：采样进窗才有产出

@Suite("资源滥用：RiskPipeline 采样进料口", .timeLimit(.minutes(1)))
struct ResourceAbusePipelineTests {

    @Test("持续高 CPU 采样序列：整段只产出 1 条 sustained-cpu-peak")
    func sustainedCPUYieldsExactlyOneEvent() throws {
        let pipeline = abusePipeline()
        let session = UUID()
        var produced: [RiskEvent] = []
        for sample in cpuBurst(session: session) {
            produced += pipeline.noteSample(sample, sessionID: session, agentKind: .claudeCode)
        }

        #expect(ruleIDs(produced) == ["risk.pattern.sustained-cpu-peak"],
                "60 点 × 2 秒 = 120 秒高峰应恰好产出 1 条，实得 \(ruleIDs(produced))")
        let event = try #require(produced.first)
        #expect(event.sessionID == session, "采样单独成窗时窗口推不出归属，必须由进料口回填")
        #expect(event.agentKind == .claudeCode)
        #expect(event.category == .resourceAbuse)
        #expect(event.level == .medium, "120 秒 = 1 倍阈值应为 MEDIUM（2 倍才升 HIGH）")
    }

    @Test("重放同一批采样被幂等键去重：换 id 重投也不再加行")
    func replayIsDeduplicated() throws {
        let pipeline = abusePipeline()
        let session = UUID()
        var firstPass: [RiskEvent] = []
        for sample in cpuBurst(batch: "a", session: session) {
            firstPass += pipeline.noteSample(sample, sessionID: session, agentKind: .claudeCode)
        }
        #expect(firstPass.count == 1)

        // ① 同一对象重放：采样 id 去重 + `emitted` 幂等键，两道都拦住。
        for sample in cpuBurst(batch: "a", session: session) {
            #expect(pipeline.noteSample(sample, sessionID: session, agentKind: .claudeCode).isEmpty)
        }

        // ② 换个批次标记（= 每个采样换 UUID）重投同样 60 个点：
        //    事实确实进了窗口（见下方 factCount），但 `finding.id` 未变 ⇒ `emitted` 仍拦住。
        //    这条区分了「被采样 id 挡住」与「被幂等键挡住」，只有后者才是节流语义。
        var secondPass: [RiskEvent] = []
        for sample in cpuBurst(batch: "b", session: session) {
            secondPass += pipeline.noteSample(sample, sessionID: session, agentKind: .claudeCode)
        }
        #expect(secondPass.isEmpty, "同根因重放不得再加行：实得 \(ruleIDs(secondPass))")

        let key = RiskPipeline.windowKey(sessionID: session, agentKind: .claudeCode)
        #expect(pipeline.factCount(forKey: key) == 120, "两批共 120 个采样都进了同一个会话窗口")
    }

    @Test("内存峰值采样：产出 excessive-memory-peak 一条并回填会话归属")
    func memorySpikeFires() throws {
        let pipeline = abusePipeline()
        let session = UUID()
        let spike = abuseSample(batch: "mem", index: 0, offset: 0,
                                cpu: 0, memory: 3 * gibibyte, session: session)
        let events = pipeline.noteSample(spike, sessionID: session, agentKind: .openAICodex)

        #expect(ruleIDs(events) == ["risk.pattern.excessive-memory-peak"],
                "3GB 峰值（阈值 2GB）应命中内存峰值规则，实得 \(ruleIDs(events))")
        let event = try #require(events.first)
        #expect(event.sessionID == session)
        #expect(event.agentKind == .openAICodex)
        #expect(event.level == .medium, "3GB 在 1~2 倍阈值之间应为 MEDIUM")

        // 同值换 id 重放：幂等键（`excessive-memory`，整窗只报 1 条）拦住。
        let replay = abuseSample(batch: "mem-replay", index: 0, offset: 0,
                                 cpu: 0, memory: 3 * gibibyte, session: session)
        #expect(pipeline.noteSample(replay, sessionID: session, agentKind: .openAICodex).isEmpty)
    }

    @Test("低于阈值的采样不产出——且证明确实进了窗口（防空窗假绿）")
    func belowThresholdProducesNothing() {
        let pipeline = abusePipeline()
        let session = UUID()
        var produced: [RiskEvent] = []
        for index in 0..<100 {
            // 79% CPU（阈值 80）+ 1GB 内存（阈值 2GB）：两个维度都差一点。
            let sample = abuseSample(batch: "low", index: index, offset: Double(index) * 2,
                                     cpu: 79, memory: gibibyte, session: session)
            produced += pipeline.noteSample(sample, sessionID: session, agentKind: .claudeCode)
        }
        #expect(produced.isEmpty, "低于阈值的采样不该有产出：\(ruleIDs(produced))")

        let key = RiskPipeline.windowKey(sessionID: session, agentKind: .claudeCode)
        #expect(pipeline.factCount(forKey: key) == 100,
                "100 个采样都应留在窗口里——否则本用例只是「没进料」的空转，证不了阈值判断")
    }

    @Test("采样与事件事实共用同一个会话窗口：不互相冲掉")
    func samplesAndFactsShareOneWindow() throws {
        let pipeline = abusePipeline()
        let session = UUID()
        let change = FileChange(path: "/Users/observer/Projects/App/x.swift", kind: .modified,
                                timestamp: SampleClock.at(0), sessionID: session,
                                agentKind: .claudeCode, projectPath: "/Users/observer/Projects/App")
        let fromFact = pipeline.evaluate(RiskContext(fileChange: change, agentKind: .claudeCode,
                                                    sessionID: session))
        #expect(Set(ruleIDs(fromFact)).isDisjoint(with: ResourceAbusePipelineTests.resourceRuleIDs),
                "只有 1 条文件变更时不该出现资源滥用结论")

        var produced: [RiskEvent] = []
        for sample in cpuBurst(session: session) {
            produced += pipeline.noteSample(sample, sessionID: session, agentKind: .claudeCode)
        }
        #expect(ruleIDs(produced) == ["risk.pattern.sustained-cpu-peak"])
        let key = RiskPipeline.windowKey(sessionID: session, agentKind: .claudeCode)
        #expect(pipeline.factCount(forKey: key) == 61, "1 条文件变更 + 60 个采样同窗")
    }

    /// 本文件盯着的两条资源滥用规则 id。
    fileprivate static let resourceRuleIDs: Set<String> = [
        "risk.pattern.sustained-cpu-peak", "risk.pattern.excessive-memory-peak"
    ]
}

// MARK: - B. 端到端：引擎采集节拍必须喂到规则

/// 可编排负载的指标桩：把 cpu / memory 固定成常量，端到端验证「采样 → 风险」这条链。
private struct FixedLoadMetrics: SystemMetricsSampling {
    var cpuPercent: Double
    var memoryBytes: UInt64

    func sampleSystem() async -> SystemPerformanceSample {
        SystemPerformanceSample(
            cpuTotalPercent: cpuPercent,
            memoryUsedBytes: memoryBytes,
            memoryTotalBytes: 16 * gibibyte
        )
    }

    func sampleProcesses(pids: [Int32]) async -> [Int32: ProcessSample] {
        var result: [Int32: ProcessSample] = [:]
        for pid in pids {
            result[pid] = ProcessSample(pid: pid, cpuPercent: cpuPercent, memoryBytes: memoryBytes)
        }
        return result
    }
}

/// 单点即够一个采样间隔的阈值：引擎每轮只出 1 个采样，且时间戳来自墙钟节拍，
/// 把「段时长 = 尾-首 + 采样间隔」里的间隔调成 ≥ 所需秒数，结论就与 tick 间隔无关。
private func singleSampleThresholds() -> RiskThresholds {
    var thresholds = RiskThresholds.standard
    thresholds.sustainedCPUPercent = 80
    thresholds.sustainedCPUSeconds = 5
    thresholds.sampleInterval = 5
    thresholds.peakMemoryBytes = gibibyte
    return thresholds
}

/// 端到端用的 Agent 实例。
///
/// 这里的时间刻意取「相对 now」而不是常量：`ObservatoryEngine.runTick` 内部就用 `Date()`
/// 打采样时间戳，这条链无法注入固定时钟。用例因此不依赖任何时间差——阈值调成
/// 「单个采样即等于一个完整采样间隔」（见 `singleSampleThresholds`），
/// 采样落在哪一刻都不影响是否命中，只影响 `finding.timestamp` 的值（未断言）。
private func abuseAgent(pid: Int32, startedAt: Date = Date().addingTimeInterval(-600)) -> AgentInstance {
    AgentInstance(
        kind: .claudeCode,
        pid: pid,
        displayName: "Claude Code",
        executablePath: "/usr/local/bin/claude",
        workingDirectory: FixturePaths.projectRoot,
        startedAt: startedAt,
        // 每轮都刷新 lastSeen（真实检测器就是这么做的）：给旧值会立刻被判空闲超时，
        // 于是每 tick 结算并重开一个会话 —— 三个会话键各自命中一次，端到端就会看到 3 行。
        lastSeenAt: Date(),
        state: .running,
        detectedVia: .processName
    )
}

@Suite("资源滥用：引擎端到端（采集节拍 → 风险落库）", .timeLimit(.minutes(1)))
struct ResourceAbuseEngineTests {

    /// 用真实 Store + 注入的阈值装配一台引擎。
    private func makeEngine(agents: [AgentInstance], metrics: any SystemMetricsSampling) async throws
        -> (engine: ObservatoryEngine, store: ObservatoryStore)
    {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let mapper = ProjectMapper(resolver: { path in
            path.hasPrefix(FixturePaths.projectRoot) ? FixturePaths.projectRoot : nil
        })
        let engine = ObservatoryEngine(
            settings: ObservatorySettings(
                monitoredRoots: [],
                ignoredPathPatterns: [],
                processScanIntervalSeconds: 3_600
            ),
            components: ObservatoryEngine.Components(
                storeSource: .ready(store),
                detector: StubDetector(agents: agents),
                processInspector: StubProcessSource(),
                metrics: metrics,
                commandAuditor: StubAuditor(),
                fileObserver: StubFileObserver(),
                snapshotter: StubSnapshotter(),
                differ: StubDiffer(),
                aggregator: TimelineAggregator(projectMapper: mapper),
                projectMapper: mapper,
                riskPipeline: RiskPipeline(homeDirectory: abuseHome, thresholds: singleSampleThresholds())
            )
        )
        return (engine, store)
    }

    @Test("引擎采集到的采样让两条资源规则真的命中并落库")
    func engineIngestionMakesResourceRulesReachable() async throws {
        let agent = abuseAgent(pid: 7301)
        let (engine, store) = try await makeEngine(
            agents: [agent],
            metrics: FixedLoadMetrics(cpuPercent: 97, memoryBytes: 4 * gibibyte)
        )

        // 连推 3 轮：第 1 轮开会话 + 首个采样，后两轮证明「继续采样不刷屏」。
        for _ in 0..<3 { await engine.rescanNow() }
        await store.flush()

        let sessionID = try #require(try await engine.sessions(matching: .all).items.first?.id)
        #expect(try await engine.performanceSamples(sessionID: sessionID).count == 3,
                "采样应已按会话落库")

        let risks = try await engine.riskEvents(matching: .all)
        let ids = Set(risks.items.compactMap(\.matchedRuleID))
        #expect(ids.contains("risk.pattern.sustained-cpu-peak"),
                "端到端必须能命中持续 CPU 规则（此前恒不触发），实得 \(ids)")
        #expect(ids.contains("risk.pattern.excessive-memory-peak"),
                "端到端必须能命中内存峰值规则（此前恒不触发），实得 \(ids)")
        #expect(risks.items.filter { $0.matchedRuleID == "risk.pattern.sustained-cpu-peak" }.count == 1,
                "3 轮采样只该有 1 条 CPU 风险（节流在端到端同样成立）")
        #expect(risks.items.filter { $0.matchedRuleID == "risk.pattern.excessive-memory-peak" }.count == 1)
        #expect(risks.items.allSatisfy { $0.sessionID == sessionID }, "风险要归到采样所属的会话")
        #expect(risks.items.allSatisfy { $0.category == .resourceAbuse })
    }

    /// `recordRisks` 除了写 `risk_events` 还会：为每条风险落一条 `riskDetected` 时间线事件、
    /// 并把会话的 `riskEventCount` 递增。这两件事只有「走同一条收口」才会同时成立，
    /// 所以它们是对共用持久化路径的直接证明
    /// （刻意不断言 `makeUpdateStream()` 的推送：`for await` 停在空流上无法被 `.timeLimit`
    ///  打断，红的时候会挂住整个测试进程——本项目已被墙钟等待咬过一次）。
    @Test("采样驱动的风险走 evaluateRisk 那条共用收口（时间线与计数都到位）")
    func sampleDrivenRisksUseTheSharedPersistencePath() async throws {
        let agent = abuseAgent(pid: 7302)
        let (engine, store) = try await makeEngine(
            agents: [agent],
            metrics: FixedLoadMetrics(cpuPercent: 97, memoryBytes: 4 * gibibyte)
        )
        await engine.rescanNow()
        await store.flush()

        let sessionID = try #require(try await engine.sessions(matching: .all).items.first?.id)
        #expect(try await engine.riskEvents(matching: .all).totalCount == 2)
        #expect(try await engine.events(matching: EventQuery(kinds: [.riskDetected])).totalCount == 2,
                "每条资源风险都应落一条 riskDetected 时间线事件")
        let session = try #require(try await engine.session(id: sessionID))
        #expect(session.riskEventCount == 2, "会话风险计数应由同一条收口递增")
    }

    @Test("良性负载的采样端到端不产出资源风险（但确实进库了）")
    func benignLoadStaysSilent() async throws {
        let agent = abuseAgent(pid: 7303)
        let (engine, store) = try await makeEngine(
            agents: [agent],
            metrics: FixedLoadMetrics(cpuPercent: 20, memoryBytes: 512 * 1024 * 1024)
        )
        for _ in 0..<3 { await engine.rescanNow() }
        await store.flush()

        let sessionID = try #require(try await engine.sessions(matching: .all).items.first?.id)
        #expect(try await engine.performanceSamples(sessionID: sessionID).count == 3)
        let ids = Set((try await engine.riskEvents(matching: .all)).items.compactMap(\.matchedRuleID))
        #expect(!ids.contains("risk.pattern.sustained-cpu-peak"))
        #expect(!ids.contains("risk.pattern.excessive-memory-peak"))
    }
}
