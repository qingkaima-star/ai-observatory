//
//  EngineIntegrationTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine
//
//  端到端：用桩采集器驱动 ObservatoryEngine，验证「识别 → Session 开闭 → 落库 → 风险 → 推送 → 结算」
//  这条链路真的通，以及 MonitoringRootResolver 的推导/拒绝规则。
//  断言只看查询返回值与推送内容，不绑定实现细节。
//

import Testing
import Foundation
import os
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

// MARK: - 桩采集器

struct StubProcessSource: ProcessInspecting {
    var records: [ProcessRecord] = []
    func scanProcesses() async -> [ProcessRecord] { records }
}

final class StubDetector: AgentDetecting, Sendable {
    private let lock = OSAllocatedUnfairLock<[AgentInstance]>(initialState: [])
    init(agents: [AgentInstance] = []) { lock.withLock { $0 = agents } }
    func setAgents(_ agents: [AgentInstance]) { lock.withLock { $0 = agents } }
    func detectAgents(using processSource: any ProcessInspecting) async -> [AgentInstance] {
        lock.withLock { $0 }
    }
    func realtimeCapability() -> RealtimeCapability { .processPolling }
}

final class StubAuditor: CommandAuditing, Sendable {
    private let lock = OSAllocatedUnfairLock<[CommandRecord]>(initialState: [])
    func setCommands(_ commands: [CommandRecord]) { lock.withLock { $0 = commands } }
    func inferCommands(processes: [ProcessRecord], agents: [AgentInstance], since: Date) -> [CommandRecord] {
        lock.withLock { $0 }
    }
    func classify(command: String) -> CommandClassification { .benign }
}

final class StubMetrics: SystemMetricsSampling, Sendable {
    private let lock = OSAllocatedUnfairLock(initialState: 0)
    var cpuPercent: Double { 40 }
    var memoryBytes: UInt64 { 512 * 1024 * 1024 }

    func sampleSystem() async -> SystemPerformanceSample {
        lock.withLock { $0 += 1 }
        return SystemPerformanceSample(
            cpuTotalPercent: cpuPercent,
            memoryUsedBytes: memoryBytes,
            memoryTotalBytes: 16 * 1024 * 1024 * 1024
        )
    }

    func sampleProcesses(pids: [Int32]) async -> [Int32: ProcessSample] {
        var result: [Int32: ProcessSample] = [:]
        for pid in pids { result[pid] = ProcessSample(pid: pid, cpuPercent: cpuPercent, memoryBytes: memoryBytes) }
        return result
    }
}

final class StubFileObserver: FileActivityObserving, Sendable {
    private let lock = OSAllocatedUnfairLock<AsyncStream<RawFileSystemEvent>.Continuation?>(initialState: nil)

    func startObserving(roots: [URL], ignoredPatterns: [String]) throws -> AsyncStream<RawFileSystemEvent> {
        AsyncStream { continuation in
            lock.withLock { stored in stored = continuation }
        }
    }

    func stopObserving() async { lock.withLock { $0 = nil } }

    /// 注入一条文件事件（引擎观测任务会消费它）。
    func emit(_ event: RawFileSystemEvent) {
        lock.withLock { continuation in
            guard let continuation else { return }
            continuation.yield(event)
        }
    }
}

struct StubSnapshotter: FileSnapshotting {
    var providesContent = true
    func snapshot(path: String) async -> FileSnapshot? {
        providesContent ? FileSnapshot(path: path, contentHash: "sha-test", sizeBytes: 18, lineCount: 2) : nil
    }
    func readTextSnippet(path: String, maxBytes: Int) async -> String? {
        providesContent ? "line one\nline two" : nil
    }
}

struct StubDiffer: DiffComputing {
    func diff(oldText: String?, newText: String?, path: String, changeKind: FileChangeKind) -> FileDiff {
        guard oldText == nil else { return FileDiff(path: path, kind: changeKind) }
        let lines = (newText ?? "").split(separator: "\n").enumerated().map { offset, text in
            DiffLine(style: .added, text: String(text), newLineNumber: offset + 1)
        }
        return FileDiff(path: path, kind: changeKind, lines: lines, linesAdded: lines.count)
    }
}

// MARK: - 装配

private struct Harness {
    var engine: ObservatoryEngine
    var store: ObservatoryStore
    var detector: StubDetector
    var auditor: StubAuditor
    var observer: StubFileObserver
}

private func makeSettings(
    scanInterval: TimeInterval = 3_600,
    monitoredRoots: [String] = [],
    ignoredPathPatterns: [String] = []
) -> ObservatorySettings {
    ObservatorySettings(
        monitoredRoots: monitoredRoots,
        ignoredPathPatterns: ignoredPathPatterns,
        processScanIntervalSeconds: scanInterval
    )
}

private func stubAgent(
    pid: Int32,
    workingDirectory: String?,
    startedAt: Date,
    kind: AgentKind = .claudeCode
) -> AgentInstance {
    AgentInstance(
        kind: kind,
        pid: pid,
        displayName: kind.displayName,
        executablePath: "/usr/local/bin/claude",
        workingDirectory: workingDirectory,
        startedAt: startedAt,
        lastSeenAt: Date(),   // 真实检测器每轮都会刷新 lastSeen，否则会立刻被判空闲超时
        state: .running,
        detectedVia: .processName
    )
}

/// 为什么从 `FixturePaths` 取而不是就地写字面量：它同时是注入给 `ProjectMapper` 的前缀谓词
/// 与各用例事件路径的根，两处必须同源——分头书写一旦漂移，谓词就不再命中事件路径，
/// 用例失败的原因会变成「项目归属推导为 nil」，而不是它真正要测的那件事。
/// 这条链路不落盘（`.inMemory` 库 + 桩采集器），所以合成路径可以直接用。
private let harnessProjectRoot = FixturePaths.projectRoot

/// 确定性 harness：项目根推导被注入为「AiX 前缀即项目根」，不依赖真实 `.git` 探测。
private func makeHarness(
    settings: ObservatorySettings = makeSettings(),
    agents: [AgentInstance] = [],
    providesContent: Bool = true,
    lifecycle: SessionLifecycleManager = SessionLifecycleManager()
) async throws -> Harness {
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let detector = StubDetector(agents: agents)
    let auditor = StubAuditor()
    let observer = StubFileObserver()
    let mapper = ProjectMapper(resolver: { path in
        path.hasPrefix(harnessProjectRoot) ? harnessProjectRoot : nil
    })
    let engine = ObservatoryEngine(
        settings: settings,
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: detector,
            processInspector: StubProcessSource(),
            metrics: StubMetrics(),
            commandAuditor: auditor,
            fileObserver: observer,
            snapshotter: StubSnapshotter(providesContent: providesContent),
            differ: StubDiffer(),
            lifecycle: lifecycle,
            aggregator: TimelineAggregator(projectMapper: mapper),
            projectMapper: mapper
        )
    )
    return Harness(engine: engine, store: store, detector: detector, auditor: auditor, observer: observer)
}

/// 轮询到条件成立；超时记录失败（避免固定 sleep 抖动）。
private func eventually(
    timeout: TimeInterval = 4,
    _ condition: @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("condition not met within \(timeout)s")
}

private func isFileChange(_ update: ObservatoryUpdate) -> Bool {
    if case .fileChange = update { return true }
    return false
}

private func isTimelineEvent(_ update: ObservatoryUpdate) -> Bool {
    if case .timelineEvent = update { return true }
    return false
}

// MARK: - 存储位置与装配失败面

@Suite("Engine：存储位置与装配", .timeLimit(.minutes(1)))
struct EngineStorageTests {

    /// 默认 `storeDirectory` 为空 → 内存库：不得在授权目录（AiX）之外落文件。
    @Test("storeDirectory 为空时使用内存库")
    func emptyStoreDirectoryUsesMemoryDatabase() {
        let configuration = ObservatoryEngine.Components.databaseConfiguration(for: .default)
        #expect(configuration.location == .memory)
    }

    /// 显式配置目录 → 该目录下的 `observatory.sqlite`。
    @Test("storeDirectory 非空时落文件库")
    func explicitStoreDirectoryProducesFilePath() {
        var settings = makeSettings()
        settings.storeDirectory = Scratch.path("engine-db")
        let configuration = ObservatoryEngine.Components.databaseConfiguration(for: settings)
        #expect(configuration.location == .file(path: Scratch.path("engine-db/observatory.sqlite")))
    }

    /// 持久化不可用（store == nil）时：start 进入 failed，查询给出明确错误而不是崩溃。
    @Test("store 缺失时查询抛 storeUnavailable 且 start 转 failed")
    func missingStoreSurfacesError() async {
        let engine = ObservatoryEngine(
            settings: makeSettings(),
            components: ObservatoryEngine.Components(
                storeSource: .unavailable(reason: "SQLite runtime unavailable"),
                detector: StubDetector(),
                processInspector: StubProcessSource(),
                metrics: StubMetrics(),
                commandAuditor: StubAuditor(),
                fileObserver: StubFileObserver(),
                snapshotter: StubSnapshotter(),
                differ: StubDiffer()
            )
        )
        #expect(await engine.currentState() == .stopped)
        await engine.start()
        #expect(await engine.currentState() == .failed)
        await #expect(throws: ObservatoryError.storeUnavailable("SQLite runtime unavailable")) {
            _ = try await engine.sessions(matching: .all)
        }
        await engine.stop()
        #expect(await engine.currentState() == .stopped)
    }
}

// MARK: - Session 生命周期

@Suite("Engine：Session 生命周期端到端", .timeLimit(.minutes(1)))
struct EngineSessionLifecycleTests {

    @Test("识别到 Agent 后自动开会话并入库")
    func agentOpensSession() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let agent = stubAgent(pid: 4242, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent])

        await harness.engine.rescanNow()
        await harness.store.flush()

        let page = try await harness.engine.sessions(matching: .all)
        #expect(page.totalCount == 1)
        let session = try #require(page.items.first)
        #expect(session.kind == .claudeCode)
        #expect(session.endedAt == nil)
        #expect(session.outcome == .running)
        #expect(session.agentID == agent.id)
        #expect(session.displayIndex == 1, "这套库里第一条会话的编号就是 1")
        #expect(try await harness.engine.activeAgents().map(\.pid) == [4242])
    }

    @Test("Agent 消失后会话自动结算并产出上下线事件")
    func agentDisappearanceSettlesSession() async throws {
        let started = Date().addingTimeInterval(-3_600)
        let agent = stubAgent(pid: 5151, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        // 本用例钉的是「消失之后结算成什么」，与缺席宽限无关，所以显式关掉宽限
        // （生产默认 6 秒：单轮漏检不结算，那是 `flickeringDetectionKeepsASingleSession` 钉的事）。
        let harness = try await makeHarness(
            agents: [agent],
            lifecycle: SessionLifecycleManager(
                configuration: SessionLifecycleManager.Configuration(absenceGrace: 0)
            )
        )
        await harness.engine.rescanNow()
        let sessionID = try #require(try await harness.engine.sessions(matching: .all).items.first?.id)
        // cpuSeconds 由相邻两次采样求差 → 至少需要两个采样点。
        try await Task.sleep(for: .milliseconds(30))
        await harness.engine.rescanNow()

        harness.detector.setAgents([])
        await harness.engine.rescanNow()
        await harness.store.flush()

        let settled = try #require(try await harness.engine.session(id: sessionID))
        #expect(settled.endedAt != nil)
        #expect(!settled.isActive)
        // 正常从扫描结果中消失且无失败命令 → 计为 success（超时未再见才计 interrupted）。
        #expect(settled.outcome == .success)
        // 采样桩报 40% CPU / 512MB：峰值必须被归因到会话。
        #expect(settled.peakCPUPercent == 40)
        #expect(settled.peakMemoryBytes == 512 * 1024 * 1024)
        #expect(settled.cpuSeconds > 0)

        let kinds = try await harness.engine.events(matching: .all).items.map(\.kind)
        #expect(kinds.contains(.agentStarted))
        #expect(kinds.contains(.agentStopped))
    }

    /// 端到端钉住简报 §1.4 的两面：漏检一轮**不**产生第二条会话，宽限期满**仍**会结算。
    /// 注入 0.05 秒的宽限，让「等一等」这件事在测试里可承受；判定仍由引擎自己的墙钟做，
    /// 所以这里靠「再跑一轮采集」推进状态机，而不是猜数据库会自己变。
    @Test("检出抖动一轮不拆会话，真下线仍结算")
    func flickeringDetectionKeepsASingleSession() async throws {
        let started = Date().addingTimeInterval(-600)
        let agent = stubAgent(pid: 7373, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(
            agents: [agent],
            lifecycle: SessionLifecycleManager(
                configuration: SessionLifecycleManager.Configuration(absenceGrace: 0.05)
            )
        )
        await harness.engine.rescanNow()
        let sessionID = try #require(try await harness.engine.sessions(matching: .all).items.first?.id)

        // 漏检一轮，然后又检出一轮：这条会话必须还是同一条、还是打开的。
        harness.detector.setAgents([])
        await harness.engine.rescanNow()
        harness.detector.setAgents([agent])
        await harness.engine.rescanNow()

        #expect(try await harness.engine.sessions(matching: .all).totalCount == 1, "一次漏检不该多出一条会话")
        let kept = try #require(try await harness.engine.session(id: sessionID))
        #expect(kept.endedAt == nil, "宽限期内的漏检不能把它结算掉")
        let kindsWhileFlickering = try await harness.engine.events(matching: .all).items.map(\.kind)
        #expect(!kindsWhileFlickering.contains(.agentStopped), "漏检一轮不该向界面广播一条假的下线")

        // 真下线：连续缺席越过宽限期之后仍要结算，并补出 agentStopped。
        // 结算发生在 `sync` 里，所以必须**再跑一轮采集**才会推进——光轮询数据库是等不到的
        // （第一版就是这么错的：`eventually` 只读不采，超时后看起来像"永远不结算"）。
        harness.detector.setAgents([])
        await harness.engine.rescanNow()                     // 第一次缺席：只记时刻
        try await Task.sleep(for: .milliseconds(120))        // 越过注入的 0.05 秒宽限
        await harness.engine.rescanNow()                     // 第二次缺席：宽限期满 → 结算
        await harness.store.flush()

        let stopped = try #require(try await harness.engine.session(id: sessionID))
        #expect(stopped.outcome == .success)
        #expect(stopped.endedAt != nil)
        let kinds = try await harness.engine.events(matching: .all).items.map(\.kind)
        #expect(kinds.contains(.agentStopped))
    }

    @Test("命令与文件变更计入会话统计")
    func commandAndFileChangesAreAttributed() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_200)
        let agent = stubAgent(pid: 6161, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.rescanNow()
        let sessionID = try #require(try await harness.engine.sessions(matching: .all).items.first?.id)

        harness.auditor.setCommands([
            CommandRecord(
                executable: "swift",
                arguments: ["test"],
                workingDirectory: FixturePaths.projectRoot,
                agentID: agent.id,
                agentKind: .claudeCode,
                startedAt: started.addingTimeInterval(5),
                endedAt: started.addingTimeInterval(9),
                exitCode: 1,
                outcome: .failure
            ),
        ])
        harness.observer.emit(RawFileSystemEvent(
            path: FixturePaths.inProjectRoot("README.md"),
            kind: .modified,
            timestamp: started.addingTimeInterval(6),
            sizeBytes: 30
        ))
        await harness.engine.rescanNow()

        // #78 之后文件计数**不在投入缓冲写通道的那一刻**发生：那一行还没证明在库里。
        // 所以这里必须再推一轮采集——`ingestAgents` 开头那一步会向写入通道要一次答案
        // （缓冲已排空且没丢语句 ⇒ 逐条认领；丢了东西 ⇒ 按 `file_changes` 的真实行数回灌）。
        // 桩审计器每轮都会原样再交一遍同一条命令，先清空它：本用例钉的是"记一次"，不是"记几次"。
        harness.auditor.setCommands([])
        try await eventually {
            await harness.engine.rescanNow()
            let session = try await harness.engine.session(id: sessionID)
            return session?.commandCount == 1 && session?.failedCommandCount == 1 && session?.modifiedFileCount == 1
        }
        let session = try #require(try await harness.engine.session(id: sessionID))
        #expect(session.createdFileCount == 0)
        #expect(session.deletedFileCount == 0)
        let commands = try await harness.engine.commands(matching: .all)
        #expect(commands.totalCount == 1)
        #expect(commands.items.first?.sessionID == sessionID)
    }

    @Test("stop 结算未闭合会话并 flush 缓冲写")
    func stopSettlesAndFlushes() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_300)
        let agent = stubAgent(pid: 7171, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.start()
        try await eventually { (try await harness.store.openSessionCount()) == 1 }

        await harness.engine.stop()
        let page = try await harness.engine.sessions(matching: SessionQuery(outcomes: [.interrupted]))
        #expect(page.totalCount == 1)
        #expect(page.items.first?.endedAt != nil)
        #expect(try await harness.engine.events(matching: EventQuery(kinds: [.agentStarted])).totalCount == 1)
    }
}

// MARK: - 时间线 / diff / 风险 / 推送

@Suite("Engine：时间线、diff 与风险", .timeLimit(.minutes(1)))
struct EngineTimelineAndRiskTests {

    @Test("新建文本文件写入 diff 与行数")
    func createdTextFileRecordsDiff() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_400)
        let agent = stubAgent(pid: 8181, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.rescanNow()
        harness.observer.emit(RawFileSystemEvent(
            path: FixturePaths.inProjectRoot("Sources/App.swift"),
            kind: .created,
            timestamp: started.addingTimeInterval(3),
            sizeBytes: 18
        ))
        try await eventually {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let change = try #require(try await harness.engine.fileChanges(matching: .all).items.first)
        #expect(change.linesAdded == 2)
        #expect(change.isText)
        #expect(change.agentKind == .claudeCode)
        #expect(change.sessionID != nil)
        #expect(change.projectPath == FixturePaths.projectRoot)
        let diff = try #require(try await harness.engine.fileDiff(for: change.id))
        #expect(diff.lines.count == 2)
        #expect(diff.lines.allSatisfy { $0.style == .added })
        #expect(try await harness.engine.events(matching: EventQuery(kinds: [.fileCreated])).totalCount == 1)
    }

    @Test("读不到内容时行数保持 0 且不写 diff")
    func missingSnapshotDoesNotFabricateLines() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_450)
        let agent = stubAgent(pid: 8282, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent], providesContent: false)
        await harness.engine.rescanNow()
        harness.observer.emit(RawFileSystemEvent(
            path: FixturePaths.inProjectRoot("Sources/Ghost.swift"),
            kind: .created,
            timestamp: started.addingTimeInterval(2)
        ))
        try await eventually {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let change = try #require(try await harness.engine.fileChanges(matching: .all).items.first)
        #expect(change.linesAdded == 0)
        #expect(change.linesRemoved == 0)
        #expect(try await harness.engine.fileDiff(for: change.id) == nil)
    }

    /// 修改类变更缺改前留底 ⇒ **不许**把全文行数当增量（这条守的原话不变）。
    /// 2026-09-20（WS-Diff）改了后半段：以前是「拿不到留底就一条 diff 都不落」⇒
    /// Before/After 面板对最主要的场景（改一个已存在的文件）显示空白。
    /// 现在的契约是「照样落一条单边 diff，但把『没有可比版本』写进 `baselineSource`」，
    /// 呈现层照它出措辞。行数仍为 0 这条真值一个字没放松。
    @Test("修改类变更不伪造 diff 行数，但要落单边 diff 并写明原因")
    func modifiedChangeDoesNotInflateLines() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_470)
        let agent = stubAgent(pid: 8383, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.rescanNow()
        harness.observer.emit(RawFileSystemEvent(
            path: FixturePaths.inProjectRoot("Sources/Edited.swift"),
            kind: .modified,
            timestamp: started.addingTimeInterval(2),
            sizeBytes: 40
        ))
        try await eventually {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let change = try #require(try await harness.engine.fileChanges(matching: .all).items.first)
        #expect(change.linesAdded == 0)
        #expect(change.linesRemoved == 0)
        let diff = try #require(
            try await harness.engine.fileDiff(for: change.id),
            "没有可比版本也要有一条 diff + 原因，不许退回空白面板"
        )
        #expect(diff.baselineSource == .unavailableFirstSighting)
        #expect(diff.baselineCapturedAt == nil)
    }

    @Test("破坏性命令产出需确认的高风险事件")
    func destructiveCommandProducesHighRisk() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_500)
        let documents = NSString(string: "~/Documents").expandingTildeInPath
        let agent = stubAgent(pid: 9191, workingDirectory: documents, startedAt: started, kind: .openAICodex)
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.rescanNow()
        harness.auditor.setCommands([
            CommandRecord(
                executable: "rm",
                arguments: ["-rf", documents],
                workingDirectory: documents,
                agentID: agent.id,
                agentKind: .openAICodex,
                startedAt: started.addingTimeInterval(4),
                outcome: .running,
                isDestructive: true,
                requiresConfirmation: true,
                riskLevel: .high
            ),
        ])
        await harness.engine.rescanNow()
        await harness.store.flush()

        let risks = try await harness.engine.riskEvents(matching: .all)
        // 原来三条 `>= 1` 加两条 `allSatisfy`：命中 1 条还是 10 条都算过，
        // 而 allSatisfy 在集合为空时恒真（本周第四次踩的同一个形状）。
        // `rm -rf ~/Documents` 恰好命中主目录一级子树删除这一条规则 ⇒ HIGH + 需确认。
        // 规则表第 3 条 `outside-project-write` 也在这里命中（删除目标 == 会话项目根本身，
        // 按 `isWithinAllowedWriteRoots` 的判据算「越界」，等级 MEDIUM）——是否该这样算已写进回报，
        // 本用例只把「当前确实产出这两条」钉成字面量，防止下次改动静默多/少一条。
        #expect(risks.items.compactMap(\.matchedRuleID).sorted() == [
            "risk.destructive.home-subtree-deletion",
            "risk.destructive.outside-project-write",
        ])
        #expect(risks.totalCount == 2)
        // 本用例真正要证的「需确认的高风险」只有主目录子树删除那一条。
        let severe = risks.items.filter { $0.level >= .high && $0.requiresConfirmation }
        #expect(severe.map(\.matchedRuleID) == ["risk.destructive.home-subtree-deletion"])
        #expect(severe.first?.level == .high)
        #expect(severe.first?.agentKind == .openAICodex)
        #expect(try await harness.engine.events(matching: EventQuery(kinds: [.riskDetected])).totalCount == 2,
                "两条风险各产出一条 riskDetected 时间线事件")
    }

    @Test("推送是增量的：一条文件事件只推一条 fileChange 与一条时间线事件")
    func updatesAreIncremental() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_600)
        let agent = stubAgent(pid: 10101, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.rescanNow()

        let stream = harness.engine.makeUpdateStream()
        let collector = Task { () -> [ObservatoryUpdate] in
            var received: [ObservatoryUpdate] = []
            for await update in stream {
                received.append(update)
                if received.filter(isFileChange).count == 1, received.filter(isTimelineEvent).count >= 1 { break }
            }
            return received
        }
        try await Task.sleep(for: .milliseconds(50))
        harness.observer.emit(RawFileSystemEvent(
            path: FixturePaths.inProjectRoot("Incremental.swift"),
            kind: .created,
            timestamp: started.addingTimeInterval(2)
        ))

        let received = await collector.value
        #expect(received.filter(isFileChange).count == 1)
        #expect(received.filter(isTimelineEvent).count == 1)
    }

    @Test("acknowledgeRiskEvent 标记为已确认")
    func acknowledgeRiskEvent() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_700)
        let documents = NSString(string: "~/Documents").expandingTildeInPath
        let agent = stubAgent(pid: 11111, workingDirectory: documents, startedAt: started)
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.rescanNow()
        harness.auditor.setCommands([
            CommandRecord(
                executable: "sudo",
                arguments: ["rm", "-rf", "/"],
                workingDirectory: documents,
                agentID: agent.id,
                agentKind: .claudeCode,
                startedAt: started.addingTimeInterval(1),
                isDestructive: true,
                requiresConfirmation: true,
                riskLevel: .critical
            ),
        ])
        await harness.engine.rescanNow()
        await harness.store.flush()

        let unacknowledged = try await harness.engine.riskEvents(matching: RiskQuery(unacknowledgedOnly: true))
        #expect(unacknowledged.totalCount == 1, "sudo rm -rf / 命中 1 条需确认风险")
        let target = try #require(unacknowledged.items.first?.id)

        try await harness.engine.acknowledgeRiskEvent(id: target)
        let after = try await harness.engine.riskEvents(matching: RiskQuery(unacknowledgedOnly: true))
        // allSatisfy 在空集上恒真；这里要的是「恰好少一条」而不是「一条不剩」。
        #expect(after.totalCount == 0)
        #expect(!after.items.map(\.id).contains(target))
        let all = try await harness.engine.riskEvents(matching: .all)
        #expect(all.items.first { $0.id == target }?.isAcknowledged == true)
    }
}

// MARK: - 项目地图 / 轮询节奏

@Suite("Engine：项目地图与轮询", .timeLimit(.minutes(1)))
struct EngineProjectAndCadenceTests {

    @Test("文件与命令聚合出项目地图")
    func projectsAggregated() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_800)
        let agent = stubAgent(pid: 12121, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.rescanNow()   // 先跑一轮：观测流在此轮内建立
        harness.observer.emit(RawFileSystemEvent(
            path: FixturePaths.inProjectRoot("README.md"),
            kind: .created,
            timestamp: started.addingTimeInterval(1),
            sizeBytes: 4
        ))
        try await eventually {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.engine.rescanNow()   // 文件变更计数变化 → 项目地图立即重算
        await harness.store.flush()

        let projects = try await harness.engine.projects()
        // 只投了一条文件事件、一个 agent ⇒ 项目和计数都是确定的 1。
        #expect(projects.count == 1)
        let repository = try #require(projects.first { $0.path == FixturePaths.projectRoot })
        #expect(repository.fileChangeCount == 1)
        #expect(repository.name == "AiX")
        #expect(repository.sessionCount == 1)
        #expect(repository.agentContributions.map(\.kind) == [.claudeCode])
        #expect(repository.agentContributions.map(\.relativeShare) == [1])
        // 原来断 `activity?.fileChangeCount == repository.fileChangeCount`：
        // 期望值就是从同一处读回来的数，两边一起算成 0 也绿。改成断字面量。
        let activity = try await harness.engine.projectActivity(path: repository.path, dateRange: .unbounded)
        #expect(activity?.fileChangeCount == 1)
        #expect(activity?.path == FixturePaths.projectRoot)
    }

    /// 轮询不得退化成忙等：固定间隔内的 tick 次数有上界。
    @Test("轮询按间隔推进而非忙等")
    func pollingIsNotBusyWait() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_900)
        let agent = stubAgent(pid: 13131, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(settings: makeSettings(scanInterval: 0.15), agents: [agent])
        await harness.engine.start()
        try await eventually(timeout: 5) {
            try await harness.store.rowCount(table: StoreSchema.Table.systemPerf) >= 3
        }
        await harness.engine.stop()

        let ticks = try await harness.store.rowCount(table: StoreSchema.Table.systemPerf)
        // 3 个 tick 至少跨越 2 个间隔；忙等会在同一时间内产出上千行。
        #expect(ticks >= 3)
        #expect(ticks <= 60)
    }

    @Test("dashboardStats 经引擎可查且活跃数正确")
    func dashboardStatsViaEngine() async throws {
        let harness = try await makeHarness(agents: [
            stubAgent(pid: 14141, workingDirectory: FixturePaths.projectRoot, startedAt: Date(timeIntervalSince1970: 1_800_000_950)),
        ])
        await harness.engine.rescanNow()
        await harness.store.flush()

        let now = Date()
        let stats = try await harness.engine.dashboardStats(for: now)
        #expect(stats.activeAgentCount == 1)
        #expect(stats.date == now)
    }
}

// MARK: - 监控根推导

@Suite("Engine：监控根推导", .timeLimit(.minutes(1)))
struct MonitoringRootTests {

    @Test("无显式配置时从 Agent cwd 推导监控根")
    func derivesFromAgentWorkingDirectory() {
        let resolver = MonitoringRootResolver(projectRootResolver: { path in
            path.hasPrefix("/Users/x/proj") ? "/Users/x/proj" : nil
        })
        let agent = stubAgent(pid: 2001, workingDirectory: "/Users/x/proj/src", startedAt: Date())
        #expect(resolver.resolve(explicit: [], agents: [agent]) == ["/Users/x/proj"])
    }

    /// 推导不出项目根时回退到 cwd 本身。
    @Test("推导失败回退到 cwd")
    func fallsBackToWorkingDirectory() {
        let resolver = MonitoringRootResolver(projectRootResolver: { _ in nil })
        let agent = stubAgent(pid: 2008, workingDirectory: "/Users/x/loose", startedAt: Date())
        #expect(resolver.resolve(explicit: [], agents: [agent]) == ["/Users/x/loose"])
    }

    @Test("推导出家目录或根目录时拒绝监控")
    func rejectsProtectedDerivedRoots() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agent = stubAgent(pid: 2002, workingDirectory: home, startedAt: Date())
        #expect(MonitoringRootResolver(projectRootResolver: { _ in home }).resolve(explicit: [], agents: [agent]).isEmpty)
        #expect(MonitoringRootResolver(projectRootResolver: { _ in "/" }).resolve(explicit: [], agents: [agent]).isEmpty)
        #expect(MonitoringRootResolver.isProtected(home))
        #expect(MonitoringRootResolver.isProtected("/"))
        #expect(!MonitoringRootResolver.isProtected("/Users/x/proj"))
    }

    @Test("显式配置与推导结果取并集并去重")
    func unionsExplicitAndDerived() {
        let resolver = MonitoringRootResolver(projectRootResolver: { path in
            path.hasPrefix("/Users/x/repoB") ? "/Users/x/repoB" : "/Users/x/repoA/nested"
        })
        let nestedAgent = stubAgent(pid: 2004, workingDirectory: "/Users/x/repoA/nested/src", startedAt: Date())
        let repoAgent = stubAgent(pid: 2005, workingDirectory: "/Users/x/repoB", startedAt: Date())
        #expect(resolver.resolve(explicit: ["/Users/x/explicit"], agents: [nestedAgent, repoAgent])
                == ["/Users/x/explicit", "/Users/x/repoA/nested", "/Users/x/repoB"])

        // 推导根落在显式根之内 → 被去重（显式优先）。
        let inside = MonitoringRootResolver(projectRootResolver: { _ in "/Users/x/proj/inside" })
        #expect(inside.resolve(explicit: ["/Users/x/proj"], agents: [nestedAgent]) == ["/Users/x/proj"])
    }

    @Test("忽略规则命中的推导根被排除")
    func ignoredPatternsExcludeDerivedRoots() {
        let resolver = MonitoringRootResolver(
            projectRootResolver: { _ in "/Users/x/repo" },
            ignoredPathPatterns: ["/Users/x/*"]
        )
        let agent = stubAgent(pid: 2006, workingDirectory: "/Users/x/repo", startedAt: Date())
        #expect(resolver.resolve(explicit: [], agents: [agent]).isEmpty)
    }

    @Test("无工作目录的 Agent 不产生监控根")
    func agentWithoutWorkingDirectoryProducesNothing() {
        let resolver = MonitoringRootResolver(projectRootResolver: { _ in nil })
        let agent = stubAgent(pid: 2007, workingDirectory: nil, startedAt: Date())
        #expect(resolver.resolve(explicit: [], agents: [agent, agent]).isEmpty)
    }

    /// 引擎在 tick 中把推导结果写入生效监控根。
    @Test("引擎按推导结果更新监控根集合")
    func engineUpdatesMonitoredRoots() async throws {
        let started = Date(timeIntervalSince1970: 1_800_001_000)
        let agent = stubAgent(pid: 2009, workingDirectory: FixturePaths.projectRoot, startedAt: started)
        let harness = try await makeHarness(agents: [agent])
        #expect(harness.engine.monitoredRootsSnapshot.isEmpty)
        await harness.engine.rescanNow()
        #expect(harness.engine.monitoredRootsSnapshot.contains(FixturePaths.projectRoot))
    }
}

// MARK: - 文件归因的根目录守卫（#19）

/// 守的是 dogfood 实测到的真实事故：一个由 launchd 拉起、cwd 就是 `/` 的 Codex 进程，
/// 把总控（Qoder，根本没被检出）改的 10 个文件**全部记成了它自己的**。
/// 任何绝对路径都以 `/` 开头 ⇒ 前缀匹配永远命中，还以「最长匹配」胜出。
///
/// **必须显式给 monitoredRoots**：真实事故里用户就是显式配了监控根（`settings.json`），
/// 事件才会流到归因这一步。若只靠「从 agent cwd 推导监控根」，cwd=`/` 的 agent 会被
/// `protectedRoots()` 过滤成**零监控根** ⇒ 观察者根本不投递事件 ⇒ 测试会因为错误的原因通过。
/// （这一点是本测试第一版写错时暴露出来的，不是先验知道的。）
///
/// 路径用合成的，不写个人绝对路径。
@Suite("Engine: 文件归因拒绝把太浅的 cwd 当前缀依据（#19）", .timeLimit(.minutes(1)))
struct FileAttributionRootGuardTests {

    /// 核心用例：cwd 是 `/` 的 agent **不得**吸收任何文件变更，宁可记成「未归属」。
    @Test("cwd=/ 的 agent 不再吞掉全机变更：记为未归属而不是错记到它头上")
    func rootCwdAgentDoesNotAbsorbChanges() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_900)
        let agent = stubAgent(pid: 9101, workingDirectory: "/", startedAt: started, kind: .openAICodex)
        let harness = try await makeHarness(
            settings: makeSettings(monitoredRoots: ["/Users/example/workbench"]),
            agents: [agent]
        )
        await harness.engine.rescanNow()
        harness.observer.emit(RawFileSystemEvent(
            path: "/Users/example/workbench/src/App.swift",
            kind: .created,
            timestamp: started.addingTimeInterval(3),
            sizeBytes: 18
        ))
        try await eventually {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let change = try #require(try await harness.engine.fileChanges(matching: .all).items.first)
        // 断的是**绝对真值**：不是「和某个 agent 一致」，而是「谁都不是」。
        #expect(change.agentKind == .unknown, "cwd=/ 的 agent 抢到了归属：\(change.agentKind)")
        #expect(change.agentID == nil)
        #expect(change.sessionID == nil)
    }

    /// 半截根同样危险：`/Users` 也是几乎所有用户文件的前缀。
    @Test("cwd=/Users 这种半截根也不参与归因")
    func shallowCwdAgentDoesNotAbsorb() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_930)
        let agent = stubAgent(pid: 9102, workingDirectory: "/Users", startedAt: started, kind: .openAICodex)
        let harness = try await makeHarness(
            settings: makeSettings(monitoredRoots: ["/Users/example/workbench"]),
            agents: [agent]
        )
        await harness.engine.rescanNow()
        harness.observer.emit(RawFileSystemEvent(
            path: "/Users/example/workbench/src/Util.swift",
            kind: .created,
            timestamp: started.addingTimeInterval(3),
            sizeBytes: 18
        ))
        try await eventually {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let change = try #require(try await harness.engine.fileChanges(matching: .all).items.first)
        #expect(change.agentKind == .unknown)
    }

    /// **反向守卫**：抬门槛不能把正常归因一起废掉。这条不成立就是修过头了。
    @Test("cwd 足够深的 agent 仍然正常拿到归属（防止守卫过头）")
    func deepCwdAgentStillAttributesNormally() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_960)
        let agent = stubAgent(
            pid: 9103,
            workingDirectory: "/Users/example/workbench",
            startedAt: started,
            kind: .claudeCode
        )
        let harness = try await makeHarness(agents: [agent])
        await harness.engine.rescanNow()
        harness.observer.emit(RawFileSystemEvent(
            path: "/Users/example/workbench/src/Keep.swift",
            kind: .created,
            timestamp: started.addingTimeInterval(3),
            sizeBytes: 18
        ))
        try await eventually {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let change = try #require(try await harness.engine.fileChanges(matching: .all).items.first)
        #expect(change.agentKind == .claudeCode)
        #expect(change.agentID == agent.id)
        #expect(change.sessionID != nil)
    }

    /// 两个都够深的候选并存时，仍然是最长前缀赢——守卫不能改变原有的相对优先级。
    @Test("两个合法候选并存时最长前缀赢，且太浅的那个不参与")
    func longestUsablePrefixWins() async throws {
        let started = Date(timeIntervalSince1970: 1_800_000_990)
        let shallow = stubAgent(
            pid: 9104,
            workingDirectory: "/Users/example",
            startedAt: started,
            kind: .openAICodex
        )
        let deep = stubAgent(
            pid: 9105,
            workingDirectory: "/Users/example/workbench",
            startedAt: started,
            kind: .claudeCode
        )
        let rooter = stubAgent(pid: 9106, workingDirectory: "/", startedAt: started, kind: .cursorAgent)
        let harness = try await makeHarness(agents: [shallow, deep, rooter])
        await harness.engine.rescanNow()
        harness.observer.emit(RawFileSystemEvent(
            path: "/Users/example/workbench/src/Deep.swift",
            kind: .created,
            timestamp: started.addingTimeInterval(3),
            sizeBytes: 18
        ))
        try await eventually {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let change = try #require(try await harness.engine.fileChanges(matching: .all).items.first)
        #expect(change.agentKind == .claudeCode, "最深目录的 agent 应该赢")
        #expect(change.agentID == deep.id)
    }

    // MARK: 纯函数：门槛规则本身

    @Test("isUsableAttributionRoot：太浅/受保护的根一律不可用，够深的可用")
    func rootGuardPredicateTruthTable() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        #expect(MonitoringRootResolver.isUsableAttributionRoot("/") == false)
        #expect(MonitoringRootResolver.isUsableAttributionRoot("/Users") == false)
        #expect(MonitoringRootResolver.isUsableAttributionRoot(home) == false)
        #expect(MonitoringRootResolver.isUsableAttributionRoot("") == false)
        #expect(MonitoringRootResolver.isUsableAttributionRoot("/Users/example/workbench") == true)
        #expect(MonitoringRootResolver.isUsableAttributionRoot(home + "/repos/proj") == true)
        // 尾斜杠不该改变判断
        #expect(MonitoringRootResolver.isUsableAttributionRoot("/Users/example/workbench/") == true)
    }
}
