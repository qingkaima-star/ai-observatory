//
//  SessionFileCountPersistenceTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws/trust（#78）
//
//  缺陷（活库实测，见 `AiX-Vault/04-决策记录/发现-会话计数列比真实行数多1（活库实测）.md`）：
//  真库会话 #2 的 `modified_file_count = 19`，而按 `session_id` 数出的 modified 行是 18；
//  三列之和 26 对不上该会话的总行 25。根因是**先计数、后落库**——
//  `ObservatoryEngine+Ingestion.ingestFileEvent` 里 `store.append(change)` 走 `BatchWriter` 缓冲，
//  返回只意味着「语句进了缓冲」，而 `SessionLifecycleManager.record(fileChange:)` 在那一刻就把
//  内存计数器 +1。批次被丢弃或逐条兜底失败时，列值就比真实行数高。
//
//  本文件钉两件事（都是**走真引擎**的端到端，不直接摆弄管理器——病就长在采集链的写入顺序上）：
//  1. 计数以真正入库的行结果为准（同成同败）。其中一格**真的制造一次「没落库」**：
//     给 `file_changes` 挂一条 `BEFORE INSERT … RAISE(ABORT)` 触发器，让其中一条行被 SQLite 拒掉，
//     于是它进 `BatchWriter` 的丢弃计数（`droppedStatementCount`——这就是「失败与丢弃路径可观察」
//     那一头，不靠翻日志），然后证明三列与总行都对得上，没有那一格虚高。
//  2. 跨表恒等式：`created + modified + deleted == 按 session_id 数出的 file_changes 行数`，
//     且每列分别等于按 kind 数出的行数。
//
//  ⚠️ 期望值全部**手推**并把算式写在旁边，不从实现反推。本项目反复栽在「把 round-trip 当证明」：
//  `读回来 == 写进去的` 对「多记一次」完全失明，所以这里每一格都是
//  「会话表里那个数」vs「另一次独立 COUNT」——两个来源不同的数必须相等。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport
@testable import AIObservatoryEngine

// MARK: - 夹具

/// 基准取「相对 now」而不是常量日期：`SessionLifecycleManager` 的 idle 超时与最短会话时长
/// 都按传入时刻与 `Date()` 判，常量日期（哪怕是几年后）会让「这条会话还算活着吗」每次跑都不一样。
let base = Date()

/// `seconds` 秒之前（事件时刻一律取过去，不拿未来时刻去考验别的时间判定）。
func ago(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(-seconds) }

/// 合成项目根（§7：只用 `/Users/dev/…` 这类合成路径）。
let root = FixturePaths.projectRoot

struct IngestHarness {
    var engine: ObservatoryEngine
    var store: ObservatoryStore
    var observer: StubFileObserver
    var detector: StubDetector
    /// #86 交出来的：命令是**从这台桩审计器**进来的，别的文件想走同一条生产通路需要拿到它。
    var auditor: StubAuditor

    /// 待认领条数：已投入缓冲写通道、**尚未证明入库**的文件变更。
    var stagedCount: Int {
        get async { await engine.components.lifecycle.stagedFileChangeCount }
    }
}

/// 建一台只跑内存库、采集件全是桩的引擎；已经开好一条会话并让它活着（600 秒前起）。
///
/// `absenceGrace: 0` 让「agent 从列表里消失」在本轮就结算（用例不必为宽限期等墙钟）；
/// 其余生命周期口径一律用生产默认值。
func makeIngestHarness() async throws -> IngestHarness {
    let agent = AgentInstance(
        kind: .claudeCode, pid: 41_400, displayName: "Claude Code",
        executablePath: "/usr/local/bin/claude", workingDirectory: root,
        startedAt: ago(600), lastSeenAt: ago(1), state: .running,
        detectedVia: .processName
    )
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let detector = StubDetector(agents: [agent])
    let observer = StubFileObserver()
    let mapper = ProjectMapper(resolver: { path in path.hasPrefix(root) ? root : nil })
    let auditor = StubAuditor()
    let engine = ObservatoryEngine(
        settings: ObservatorySettings(
            monitoredRoots: [root],
            processScanIntervalSeconds: 3_600      // 只有显式 rescan 才推状态机
        ),
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: detector,
            processInspector: StubProcessSource(),
            metrics: StubMetrics(),
            commandAuditor: auditor,
            fileObserver: observer,
            snapshotter: StubSnapshotter(providesContent: false),  // 本文件不测 diff，省掉读盘
            differ: StubDiffer(),
            lifecycle: SessionLifecycleManager(
                configuration: SessionLifecycleManager.Configuration(absenceGrace: 0)
            ),
            aggregator: TimelineAggregator(projectMapper: mapper),
            projectMapper: mapper
        )
    )
    await engine.rescanNow()
    #expect(try await engine.sessions(matching: .all).totalCount == 1, "会话确实开了")
    return IngestHarness(engine: engine, store: store, observer: observer, detector: detector, auditor: auditor)
}

func sessionID(_ harness: IngestHarness) async throws -> UUID {
    try #require(await harness.engine.sessions(matching: .all).items.first?.id)
}

/// 该会话名下那条会话行的三列（读**库**，不是读内存快照）。
func storedSession(_ harness: IngestHarness) async throws -> AgentSession {
    try #require(await harness.engine.session(id: try await sessionID(harness)))
}

/// 投一条文件事件（桩观测源 → 引擎的观测任务异步消费）。
/// `.bin` 后缀让它落在 `isText == false` 那一支：本文件钉的是计数，不该顺手牵进 diff 链路。
func emit(_ harness: IngestHarness, _ name: String, kind: FileChangeKind, before seconds: TimeInterval) {
    harness.observer.emit(RawFileSystemEvent(
        path: "\(root)/\(name).bin",
        previousPath: kind == .renamed ? "\(root)/\(name)-before.bin" : nil,
        kind: kind,
        timestamp: ago(seconds),
        sizeBytes: 32
    ))
}

/// 轮询到条件成立（事件是异步消费的，固定 sleep 一遇到本机负载就抖）。
func waitUntil(
    timeout: TimeInterval = 10,
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

/// 按 kind 数某会话名下的 `file_changes` 行数——**恒等式的另一侧**：
/// 一条独立 COUNT 查询，与内存计数器没有任何关系。
func rowCount(_ harness: IngestHarness, kinds: [FileChangeKind]) async throws -> Int {
    try await harness.store.fileChanges(
        matching: FileChangeQuery(kinds: Set(kinds), sessionID: try await sessionID(harness), limit: 1)
    ).totalCount
}

/// 等到「投出去的事件都到了待认领这一步」（小批量专用：几十条语句凑不满一批，
/// 所以待认领数在这里是稳定读数——没有任何一条会被中途认领掉）。
func waitUntilStaged(_ harness: IngestHarness, changes: Int) async throws {
    try await waitUntil { await harness.stagedCount == changes }
}

/// 推到「这一批彻底收口」：库里恰好 `rows` 行，且没有任何待认领条目。
///
/// 事件多到会把缓冲凑满一批（32 条语句就地提交）时得用它：那里"待认领条数"不再是稳定读数
/// （涨到一半就被一次中途提交认领掉），只有「行数 + 归零」这一对读数能说明全部落定。
func settleIngested(_ harness: IngestHarness, rows: Int) async throws {
    try await waitUntil {
        await harness.engine.rescanNow()
        let landed = try await rowCount(harness, kinds: FileChangeKind.allCases)
        let staged = await harness.stagedCount
        return landed == rows && staged == 0
    }
}

/// 反复推采集，直到「待认领清零」——即三列已经跟着真实行数走完一趟。
///
/// 为什么一次 `rescanNow` 不够：认领要求写入通道报告缓冲已排空，而并发到达的新事件会在
/// flush 之后立刻把缓冲再填满 ⇒ 那一轮**正确地**什么都不记（不猜「待会儿应该会写进去」）。
/// 生产里这件事由下一轮采集接上（默认 3 秒），测试里用「再推一轮 + 等到归零」代替睡墙钟。
func settleCredits(_ harness: IngestHarness) async throws {
    try await waitUntil {
        await harness.engine.rescanNow()
        return await harness.stagedCount == 0
    }
}

// MARK: - 1. 计数以真正入库的行结果为准

@Suite("Engine #78：会话文件计数只在行真的落库之后才动", .timeLimit(.minutes(2)))
struct SessionFileCountCreditTests {

    /// 行还在写通道缓冲里 ⇒ 库里 0 行、会话三列也必须是 0。
    ///
    /// 这一格钉的是**顺序**：改前的代码在这里会读出「库 0 行 / 列 1」。
    /// 本夹具没起 `BatchWriter` 的定时 flush 循环（引擎没 `start()`，只显式推采集），
    /// 所以缓冲里那条既没提交也没丢弃——「还没答案」不等于「会成功」，一个都不记。
    @Test("在途行不计入：库里 0 行时三列也是 0，不虚高")
    func inFlightRowIsNotCounted() async throws {
        let harness = try await makeIngestHarness()
        emit(harness, "in-flight", kind: .modified, before: 50)
        try await waitUntilStaged(harness, changes: 1)

        // 还没跑过带 flush 的那一轮采集 ⇒ 语句仍躺在缓冲里。
        #expect(try await rowCount(harness, kinds: [.modified]) == 0, "起点：库里确实一行都还没有")
        let stored = try await storedSession(harness)
        #expect(stored.modifiedFileCount == 0, "行没进库，列就不许动——这一格改前是 1")
        #expect(stored.createdFileCount == 0 && stored.deletedFileCount == 0)
        #expect(await harness.stagedCount == 1, "它确实还挂在待认领上，不是被悄悄丢了")

        // 写入通道给出"已排空且没丢"的答案之后才追平：列 = 1，行 = 1，两边同时成立。
        try await settleCredits(harness)
        let credited = try await storedSession(harness)
        #expect(credited.modifiedFileCount == 1)
        #expect(try await rowCount(harness, kinds: [.modified]) == 1)
        #expect(await harness.stagedCount == 0, "认领完不留待认条目")
    }

    /// 台账验收点名的那一格：**真的**制造一次「没落库」。
    ///
    /// 手法：给 `file_changes` 挂一条 `BEFORE INSERT … RAISE(ABORT)` 触发器，只拒 path 带
    /// `doomed` 的那一条（= 一条写不进去的坏数据，其余照旧）。三条变更一起进缓冲，
    /// flush 时整批失败 ⇒ `BatchWriter` 逐条重投 ⇒ 两条入库、一条被丢弃并计入
    /// `droppedStatementCount`。
    ///
    /// 期望值手推：投入 3 条 modified，真实入库 3 − 1 = **2** 条。
    /// 改前的口径会记成 3（先 +1 后落库），于是列比行多 1——正是真库会话 #2 的 19 vs 18。
    @Test("批次里一条被 SQLite 拒掉：三列与总行都不虚高（19 vs 18 那一格）")
    func droppedRowDoesNotInflateCounts() async throws {
        let harness = try await makeIngestHarness()
        // 触发器写在测试自己的内存库上，不碰任何产品配置。
        try await harness.store.database.execute([SQLiteStatement("""
            CREATE TRIGGER trust78_reject_doomed
                BEFORE INSERT ON file_changes
                WHEN NEW.path LIKE '%/doomed%'
            BEGIN
                SELECT RAISE(ABORT, 'fixture(#78): 这一行写不进去');
            END
            """)])

        emit(harness, "keep-a", kind: .modified, before: 50)
        emit(harness, "doomed", kind: .modified, before: 49)
        emit(harness, "keep-b", kind: .modified, before: 48)
        try await waitUntilStaged(harness, changes: 3)
        try await settleCredits(harness)

        let stats = await harness.store.batchStats()
        #expect(stats.pendingCount == 0, "收口之后缓冲必须空")
        #expect(stats.droppedStatementCount == 1, "恰好丢掉那一条被拒的语句（可观察，不是只进日志）")

        let stored = try await storedSession(harness)
        let landedModified = try await rowCount(harness, kinds: [.modified])
        let landedCounted = try await rowCount(harness, kinds: [.created, .modified, .deleted])
        #expect(landedModified == 2, "真实入库的是 2 行")
        #expect(stored.modifiedFileCount == 2, "列必须等于行数：改前这里是 3（虚高 1）")
        #expect(stored.createdFileCount == 0)
        #expect(stored.deletedFileCount == 0)
        // 恒等式在这一格同样成立，而且是"总数"那一层：三列之和 == 该会话的总行数。
        #expect(landedCounted == 2)
        #expect(stored.createdFileCount + stored.modifiedFileCount + stored.deletedFileCount
                == landedCounted)
        let doomed = try await harness.store.fileChanges(
            matching: FileChangeQuery(searchText: "doomed", limit: 1)
        ).totalCount
        #expect(doomed == 0, "被拒的那一条在库里根本不存在，界面上也不许留下它的痕迹")

        // 丢掉一条之后再正常写一条：新行照常入账，不被上一次的丢弃"吞掉"。
        // （被拒的那一条永远不会有行，所以此刻待认领的是"新到的这一条"，不是累计条数。）
        emit(harness, "keep-c", kind: .modified, before: 47)
        try await waitUntilStaged(harness, changes: 1)
        try await settleCredits(harness)
        #expect(try await storedSession(harness).modifiedFileCount == 3)
        #expect(try await rowCount(harness, kinds: [.modified]) == 3)
        #expect(await harness.store.batchStats().droppedStatementCount == 1, "丢弃计数不重复累加")
    }

    /// 会话结算那一轮不得把在途行丢掉。
    ///
    /// `ingestAgents` 的顺序是有原因的：先认领、再 `sync`——`sync` 可能就地结算会话，
    /// 而结算出来的三列与 `hasEvidence`（判 `.success` 还是 `.unknown`）都读这几个数。
    /// 反过来排的话，「进程消失前最后一次编辑」会以"什么都没发生"的姿态被结算掉。
    @Test("缺席结算的那一轮先认领再结算：计数与结论都跟着真实行数")
    func settlementCarriesCreditedCounts() async throws {
        let harness = try await makeIngestHarness()
        emit(harness, "last-edit", kind: .modified, before: 50)
        try await waitUntilStaged(harness, changes: 1)
        #expect(await harness.stagedCount == 1, "起点：这一条还在途")

        // agent 从本轮列表里消失 ⇒ 不宽限，下一轮采集就结算（`absenceGrace: 0`）。
        harness.detector.setAgents([])
        try await settleCredits(harness)

        let settled = try await storedSession(harness)
        #expect(settled.endedAt != nil, "确实走了结算这条路")
        #expect(settled.outcome == .success, "有实测依据才判成功：这条依据就是那一行真实入库的变更")
        #expect(settled.modifiedFileCount == 1, "结算快照带着已落库的行数")
        #expect(try await rowCount(harness, kinds: [.modified]) == 1)
    }
}
