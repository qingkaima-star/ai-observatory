//
//  ObservatoryEngine.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine
//  ─────────────────────────────────────────────────────────
//  编排层：把 Platform 采集器 → Session 生命周期 / 时间线 / 风险 / 项目地图 → SQLite Store → UI 推送
//  串成一条流水线。查询全部委托给 `ObservatoryStore`（其语义与 InMemoryObservatoryService 一致），
//  本类型只负责装配、轮询与增量广播。
//
//  设计约束：
//    · 空闲时不占 CPU：轮询走 `Task.sleep`，文件事件走 `AsyncStream` 推送（无轮询）。
//    · 一个 tick 只扫一次进程表：`ReplayProcessInspector` 把同一份快照复用给识别与命令审计。
//    · 推送必须增量：一次新增 1 条就推 1 条，禁止全量重算后广播。
//    · 拿不到的数据保持 0 / nil，绝不伪造指标。
//

import Foundation
import os
import CryptoKit
import AIObservatoryCore
import AIObservatoryRiskRules   // 装配点要直接构造 RiskAssessor（语言要同源）
import AIObservatoryStore
import AIObservatoryPlatform

public final class ObservatoryEngine: ObservatoryService, ObservatoryControlling, ObservatoryEventStreaming, RealtimeCapabilityReporting, MonitoringScopeReporting, AttributionGapReporting, Sendable {

    // MARK: - Internal State

    struct MutableState: Sendable {
        var state: EngineState = .stopped
        var subscribers: [UUID: AsyncStream<ObservatoryUpdate>.Continuation] = [:]
        /// 最近一轮识别到的 Agent，用于文件事件归属与监控根推导。
        var agents: [AgentInstance] = []
        /// 按 `AgentInstance.id` 缓存的最后一次快照；Agent 消失后仍能产出诚实的「退出」事件。
        var agentSnapshots: [UUID: AgentInstance] = [:]
        var observedRoots: [String] = []
        var lastTickAt: Date?
        /// 项目地图聚合的触发闸门（见 `ProjectSyncGate`）。
        var projectGate = ProjectSyncGate()
        var lastPruneAt: Date?
        var consecutiveTickFailures = 0
        /// 启动后的孤儿收口是否已经做过（一次性的账，见 `settleOrphansFromPreviousRun`）。
        var startupSweepDone = false
        /// 本次运行内「文件变更没能归到某个 Agent 名下」的机制分布（ICR-0009）。
        /// `nil` = 一条文件事件都还没处理过——它与"处理过、但一条都没漏"必须能区分开，
        /// 否则界面只能把「还没有读数」画成「归属率 100 %」。
        var attributionCounts: [AttributionGap.Reason: Int]?
    }

    /// 轮询节奏（秒）。
    private struct Cadence: Sendable {
        var scan: TimeInterval
        var projectSync: TimeInterval
        var prune: TimeInterval
    }

    /// 项目地图聚合的触发闸门。两个条件任一成立即同步：
    ///  1. `file_changes` 出现了上次同步之后**新插入的行**（新活动立即反映）；
    ///  2. 距上次同步超过 `throttle`（兜住"只有命令 / 风险、没有文件变更"的场景）。
    ///
    /// 为什么判据是 **最大 rowid** 而不是 `COUNT(*)`：后者要扫过整棵索引，
    /// 是**每 tick 的 O(历史长度)** 成本（实测 20 000 行 0.69 ms/tick，百万行外推几十 ms）；
    /// `MAX(rowid)` 走表 B-tree 最右叶子，与行数无关。见 `ObservatoryStore.maxRowID(table:)`。
    ///
    /// 为什么**不**用 timestamp 游标：批量写通道会把「事件时间早于上次同步」的行**晚**提交
    /// （攒批 32 条 / 1 秒），按事件时间比较会永久漏掉它——漏了还不报错，
    /// 是本仓最贵的那一类缺陷。rowid 只看插入顺序，不看事件时间。
    struct ProjectSyncGate: Sendable {
        /// 上次同步时已见到的最大 `file_changes` rowid；0 = 还没有任何行。
        private(set) var lastFileChangeRowID = 0
        private(set) var lastSyncAt: Date?

        /// 本轮是否要同步；返回 true 的同时推进游标。
        mutating func shouldSync(newestFileChangeRowID: Int, now: Date, throttle: TimeInterval) -> Bool {
            let timedOut = lastSyncAt.map { now.timeIntervalSince($0) >= throttle } ?? true
            if newestFileChangeRowID < lastFileChangeRowID {
                // 最大那几行被删掉了（保留期清理）⇒ 游标跟着退。
                // 不退的话：清理后新插入的行会复用被删掉的 rowid，`>` 永不成立，
                // 「新活动立即反映」这条会**静默失效**，只剩 60 s 节流在兜。
                lastFileChangeRowID = newestFileChangeRowID
            }
            guard newestFileChangeRowID > lastFileChangeRowID || timedOut else { return false }
            lastFileChangeRowID = max(lastFileChangeRowID, newestFileChangeRowID)
            lastSyncAt = now
            return true
        }
    }

    private static let projectSyncInterval: TimeInterval = 60
    private static let pruneInterval: TimeInterval = 24 * 60 * 60
    static let snapshotTTL: TimeInterval = 300
    static let maxSnippetBytes = 64 * 1024
    /// 文本留底的条数上限 ⇒ 常驻上限约 `capacity × maxSnippetBytes`。
    /// internal 而不是 private：留底逐出的用例按它自己算「要塞多少条才会逐出第一条」，
    /// 写死数字会在容量被调大后静默变成永真断言。
    static let baselineCacheCapacity = 64
    private static let degradationThreshold = 3
    static let textExtensions: Set<String> = [
        "swift", "py", "js", "jsx", "ts", "tsx", "java", "kt", "go", "rs", "rb", "php", "c", "h",
        "cc", "cpp", "hpp", "m", "mm", "sh", "zsh", "bash", "sql", "md", "markdown", "txt", "json",
        "yaml", "yml", "toml", "xml", "html", "css", "scss", "plist", "env", "ini", "gradle"
    ]

    let mutable = OSAllocatedUnfairLock(initialState: MutableState())
    private let loops = OSAllocatedUnfairLock<[Task<Void, Never>]>(initialState: [])
    let observer = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)
    /// 当前设置。放在锁里而不是 `let`，是为了让 `updateSettings` 热生效：
    /// 下面十几处读取点全部走这个计算属性，因此改一次即对所有轮次生效，
    /// 不需要重启、也不会有人拿到过期副本。
    private let settingsBox = OSAllocatedUnfairLock<ObservatorySettings>(initialState: .default)
    var settings: ObservatorySettings { settingsBox.withLock { $0 } }

    /// 「该路径上一次被观测到的内容」留底 —— Before/After 的 Before 只存在于此。
    /// 放进程内、不新开表存内容：落盘等于把文件明文再复制一份进数据库（隐私 §7）。
    let textBaselines = OSAllocatedUnfairLock(
        initialState: FileTextBaselineCache(capacity: ObservatoryEngine.baselineCacheCapacity)
    )

    private let cadence: Cadence
    let components: Components
    /// 每-tick 阶段 CPU 账本（AGENTS §6 的「可核对加总」）。见 `runTick()` 的段落注释。
    private let tickLedger = TickStageLedger()
    /// 上次打账目日志时已完成的 tick 数。
    private let accountingCursor = OSAllocatedUnfairLock<Int>(initialState: 0)
    /// 每多少轮打一行 `tick-account`（默认周期下约 1 分钟）。
    static let accountingEveryTicks = 20
    private let monitoringRootsBox = OSAllocatedUnfairLock<MonitoringRootResolver>(initialState: MonitoringRootResolver())
    var monitoringRoots: MonitoringRootResolver { monitoringRootsBox.withLock { $0 } }

    /// 最近一次解析出的采集面实况（ICR-0006）。`nil` = 这一轮还没跑过 `refreshFileObservation`，
    /// 界面此时只许说"尚无采集面读数"，不许据此推断"用户没配监控根"。
    let monitoringScopeBox = OSAllocatedUnfairLock<MonitoringScope?>(initialState: nil)
    /// Store 解析单飞任务：打开（含迁移）并校验版本；之后所有调用共享同一结果。
    let storeBootstrap: Task<ObservatoryStore, any Error>
    /// 解析完成后的 Store（`stop()` 等非抛出路径用它做尽力而为的收尾）。
    let resolvedStore = OSAllocatedUnfairLock<ObservatoryStore?>(initialState: nil)

    // MARK: - Init

    /// 用生产采集器装配引擎。`settings.storeDirectory` 为空时数据只留在内存库（不落文件）。
    public convenience init(settings: ObservatorySettings = .default) {
        self.init(settings: settings, components: .live(settings: settings))
    }

    /// 注入装配（测试与自定义采集器组合用）。
    public init(settings: ObservatorySettings, components: Components) {
        let restored = SettingsPersistence.restore(ifPresentIn: settings.storeDirectory) ?? settings
        settingsBox.withLock { $0 = restored }
        monitoringRootsBox.withLock { $0 = MonitoringRootResolver(ignoredPathPatterns: restored.ignoredPathPatterns) }
        self.cadence = Cadence(
            scan: max(restored.processScanIntervalSeconds, 0.05),
            projectSync: ObservatoryEngine.projectSyncInterval,
            prune: ObservatoryEngine.pruneInterval
        )
        self.components = components
        self.storeBootstrap = Task {
            switch components.storeSource {
            case .ready(let store):
                // 注入的 Store 已由 `ObservatoryStore.open` 迁移过；这里只校验，不静默接受空库。
                let version = try await store.database.userVersion()
                guard version == StoreSchema.schemaVersion else {
                    throw ObservatoryError.storeUnavailable("schema version \(version) != \(StoreSchema.schemaVersion)")
                }
                return store
            case .configuration(let configuration):
                return try await ObservatoryStore.open(configuration: configuration)
            case .unavailable(let reason):
                throw ObservatoryError.storeUnavailable(reason)
            }
        }
    }

    // MARK: - Lifecycle

    /// 启动：应用 schema → 打开批量写通道与文件观测 → 拉起轮询循环 → 状态置 `running` 并广播。
    /// 重复调用无副作用（已运行则直接返回）。`.starting` 只做内部过渡，不广播。
    public func start() async {
        let alreadyLive = mutable.withLock { state -> Bool in
            guard state.state == .stopped else { return true }
            state.state = .starting
            return false
        }
        guard !alreadyLive else { return }

        do {
            _ = try await readyStore()
        } catch {
            transition(to: .failed)
            ObservatoryLog.engine.error("start aborted: \(error.localizedDescription, privacy: .public)")
            return
        }

        await settledStore?.start()
        await resumeOpenSessions()
        refreshFileObservation(agents: mutable.withLock { $0.agents })
        startScanLoop()
        transition(to: .running)
        ObservatoryLog.engine.info("ObservatoryEngine started")
    }

    /// 重启续接：把库里未结算的会话装回生命周期管理器。
    ///
    /// 失败不阻断启动——最坏情况就是退回「每次重启都新开一条会话」的旧行为，
    /// 比因为读不到历史而整个引擎起不来要好；但必须留下日志，不能静默。
    private func resumeOpenSessions() async {
        do {
            let store = try await readyStore()
            // 编号下限先取**全历史**：这一步必须在下面那道 `open.isEmpty` 之前——
            // 「上一轮会话全都结算了」恰恰是最常见的重启形状，放在 return 之后就永远喂不到，
            // 于是新会话从 1 重新发号，与历史撞号（ICR-0004，真机 Sessions 同屏两个 #2）。
            let historyMax = try await store.maxSessionDisplayIndex()
            await components.lifecycle.seedDisplayIndexFloor(fromHistoryMax: historyMax)
            let open = try await store.openSessions()
            guard !open.isEmpty else { return }
            await components.lifecycle.resume(sessions: open, at: Date())
            broadcast(.sessions(open))
            ObservatoryLog.engine.info("续接未结算会话 \(open.count) 条，避免重启把活着的 Agent 拆成新会话")
        } catch {
            ObservatoryLog.engine.error("续接未结算会话失败（退回旧行为）：\(error.localizedDescription, privacy: .public)")
        }
    }

    /// 启动后的**孤儿收口**（#38 队列里的第 5 条，需求④ 的最后一块）。只在第一轮采集里做一次。
    ///
    /// 缺陷形状（真库 `ai-observatory/tmp/verify-realdata/observatory.sqlite`，2026-09-21 查得）：
    /// `agents` 6 行里有 **5 行的 pid 已经不存在**、却仍记着 `state='running'`；其中两个死 Agent
    /// 名下挂着 **15 条** `outcome='running' AND ended_at IS NULL` 的命令。全库
    /// `running 372 / terminated 86`——那 86 条全部来自 ⌘Q 的正常 `stop()`；
    /// 强杀 / 崩溃 / 断电根本不经过退出结算，于是那 329 条会永远挂着"运行中"。
    ///
    /// 判据取「本轮扫描里它不再是任何被识别 Agent 的 pid」，**不是**"库里说它 running"：
    /// 同一个库里，那个**还活着**的 Agent 名下同样有大量开放命令（实测 357 条）——那是
    /// 进程轮询看不到退出码的已知口径（`settleOpenCommands` 的注释写过：只能给上界），
    /// 在这里把它判成终止就是凭空造事实。⇒ 只收口"进程已经不在了"的那批。
    ///
    /// 收口三件事，都用 Agent 最后一次可见的时刻当 `ended_at`（**上界**口径同 `settleOpenCommands`）：
    ///  1. 它名下未闭合的命令 → `.terminated`；
    ///  2. 它那条未结算的会话 → `.interrupted`（`resumeOpenSessions` 会把它当活着的接回来，
    ///     而进程已经没了 ⇒ 不接就永远开着）；
    ///  3. `agents` 那一行本身 → `.terminated`，否则下一轮启动还要重收一遍、
    ///     而且界面会把死进程显示成"运行中"。
    private func settleOrphansFromPreviousRun(liveAgents: [AgentInstance], store: ObservatoryStore) async {
        let shouldSweep = mutable.withLock { state -> Bool in
            if state.startupSweepDone { return false }
            state.startupSweepDone = true
            return true
        }
        guard shouldSweep else { return }
        let livePIDs = Set(liveAgents.map(\.pid))
        do {
            let known = try await store.activeAgents()
            var settledCommands = 0
            var settledSessions = 0
            var orphans: [AgentInstance] = []
            for record in known where !livePIDs.contains(record.pid) {
                // 命令先落：`terminateOpenCommands` 只碰 `outcome='running' AND ended_at IS NULL`，
                // 已被 hook 闭合过的行绝不会被改写。
                settledCommands += try await store.terminateOpenCommands(
                    agentID: record.id, sessionID: nil, outcome: .terminated, endedAt: record.lastSeenAt
                )
                if let session = await components.lifecycle.closeSession(
                    agentID: record.id, at: record.lastSeenAt, outcome: .interrupted
                ) {
                    try await store.upsertSessions([session])
                    settledSessions += 1
                }
                var ended = record
                ended.state = .terminated
                orphans.append(ended)
            }
            if !orphans.isEmpty {
                try await store.upsertAgents(orphans)
                broadcast(.agents(orphans))
            }
            if settledCommands > 0 || settledSessions > 0 || !orphans.isEmpty {
                ObservatoryLog.engine.notice(
                    "启动孤儿收口：agent \(orphans.count, privacy: .public) 个判为已终止，命令 \(settledCommands, privacy: .public) 条落为 terminated，会话 \(settledSessions, privacy: .public) 条落为 interrupted"
                )
            }
        } catch {
            noteTickFailure(why: "startup orphan sweep failed: \(error.localizedDescription)")
        }
    }

    /// 停止：取消循环 → 结算未闭合会话 → 强制 flush 缓冲 → 状态置 `stopped` 并广播。
    public func stop() async {
        let tasks = loops.withLock { registered in
            let snapshot = registered
            registered.removeAll()
            return snapshot
        }
        for task in tasks { task.cancel() }
        observer.withLock { task in
            task?.cancel()
            task = nil
        }
        await components.fileObserver.stopObserving()
        await settledStore?.flush()
        // 缓冲已排空 ⇒ 这是最后一次数得准的时机。漏这一步，最后结算的那几个会话会**少记**在途的行
        // （只会偏低不会偏高），而它们马上就不在 `openSessions()` 里了，重启的对账也捞不到。
        if let store = settledStore {
            await settleFileChangeCredits(store: store, flushingBuffer: false)
            await settleCommandCredits(store: store, flushingBuffer: false)
        }

        let now = Date()
        let closed = await components.lifecycle.closeAll(at: now, outcome: .interrupted)
        if !closed.isEmpty {
            do {
                let store = try await readyStore()
                try await store.upsertSessions(closed)
                for session in closed {
                    guard let event = agentStoppedEvent(for: session, at: now) else { continue }
                    await store.append(event)
                    broadcast(.timelineEvent(event))
                }
                broadcast(.sessions(closed))
                ObservatoryLog.engine.info("settled \(closed.count, privacy: .public) open sessions")
            } catch {
                ObservatoryLog.engine.error("session settlement on stop failed: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 会话既然全部收口了，它们名下**还没闭合的命令也必须收口**——否则库里永远挂着
        // 一堆 `outcome = running` 的行，而进程其实早就不见了（需求④ 的「结果 / 耗时」实测
        // 在三个独立库里 236/236 条都是这个形状）。
        // 用 `.terminated`（退出码未知），**不是** success/failure：我们没有 hook，不知道退出码。
        // ⚠️ 必须先 `flush()`：命令走缓冲写入通道，未落盘的插入会被这条 UPDATE 漏掉。
        if !closed.isEmpty {
            do {
                let store = try await readyStore()
                await store.flush()
                let settled = try await store.terminateOpenCommands(
                    agentID: nil,
                    sessionID: nil,
                    outcome: .terminated,
                    endedAt: now
                )
                if settled > 0 {
                    ObservatoryLog.engine.info(
                        "settled \(settled, privacy: .public) open commands as terminated"
                    )
                }
            } catch {
                ObservatoryLog.engine.error(
                    "command settlement on stop failed: \(error.localizedDescription, privacy: .public)"
                )
            }
        }

        components.riskPipeline.reset()
        if let store = settledStore {
            await store.stop()
            let dropped = await store.batchStats().droppedStatementCount
            if dropped > 0 {
                transition(to: .degraded)
                ObservatoryLog.store.error("\(dropped, privacy: .public) 条语句在停机等价过程中被丢弃，数据不完整")
                transition(to: .stopped)
            }
        }
        transition(to: .stopped)
        ObservatoryLog.engine.info("ObservatoryEngine stopped")
    }

    /// 立即执行一轮完整采集（不等定时器）。未运行时也可调用，便于确定性测试。
    public func rescanNow() async {
        await runTick()
    }

    /// 每-tick 阶段 CPU 账本快照（AGENTS §6「各阶段加起来必须等于实测每 tick」的那笔账）。
    ///
    /// 口径：单位是**本进程累计 CPU 毫秒**，不是墙钟；`unattributedCPUMilliseconds` 是
    /// 「进程总量 − 已入账」，非零就说明有活没进账（先补项，再谈达不达标）。
    /// 预期消费者：#29「性能页显示自身开销」那一格（界面侧由 UI 车道接线）。
    public func tickAccount() -> TickAccount {
        tickLedger.snapshot()
    }

    /// 标记风险事件为已确认。失败**如实抛出**，不吞进日志。
    ///
    /// 旧写法是 `do { try … } catch { os_log(.error) }`，而调用方
    /// （`SecurityModel.acknowledge`）紧接着无条件 `markAcknowledged`
    /// ⇒ 界面显示"已确认"、库里仍是未确认、重启翻回去。见契约上的说明。
    public func acknowledgeRiskEvent(id: UUID) async throws {
        try await readyStore().acknowledgeRisk(id: id)
    }

    /// 最近一轮解析出的采集面（ICR-0006）：实际监控了哪些根、剔除了哪些、为什么剔除。
    ///
    /// 这是**只读实况**，不是重新算一遍：界面拿它才能把"文件页为什么是空的"说全。
    /// 返回 nil 表示这一轮还没跑过文件观测（刚启动、或一个 Agent 都没识别到），
    /// 此时界面只许说"尚无采集面读数"。
    /// 本次运行内的未归属机制分布；一条文件事件都没处理过时是 nil（ICR-0009）。
    public func currentAttributionGap() async -> AttributionGap? {
        guard let counts = mutable.withLock({ $0.attributionCounts }) else { return nil }
        return AttributionGap(counts: counts)
    }

    public func currentMonitoringScope() async -> MonitoringScope? {
        monitoringScopeBox.withLock { $0 }
    }

    /// 应用新设置：先改内存态（下一轮采集立即生效），再落盘（跨启动保留）。
    ///
    /// 落盘失败不回滚内存态 —— 本次会话按新设置运行是用户刚做的决定，
    /// 但会通过日志明确报告「下次启动会回到旧值」，不假装已经持久化。
    public func updateSettings(_ settings: ObservatorySettings) async {
        settingsBox.withLock { $0 = settings }
        monitoringRootsBox.withLock { $0 = MonitoringRootResolver(ignoredPathPatterns: settings.ignoredPathPatterns) }
        if !SettingsPersistence.save(settings) {
            ObservatoryLog.engine.error(
                "设置已本次生效但无法持久化：下次启动将回到基线值"
            )
        }
    }

    /// 引擎**当前实际生效**的设置（可能来自磁盘上上次保存的值，而非构造时传入的基线）。
    ///
    /// 公开它是为了让 UI 能显示「真的生效了什么」，而不是只显示用户点了什么。
    public var currentSettings: ObservatorySettings { settings }

    /// 需要重启才生效的设置项。UI 可以据此提示用户，而不是让开关看起来已经起作用。
    public static let restartRequiredSettings: [String] = [
        "theme", "launchAtLogin", "enableEndpointSecurity", "enableMenuBarExtra", "storeDirectory"
    ]

    /// 当前引擎状态。
    public func currentState() async -> EngineState {
        mutable.withLock { $0.state }
    }

    /// 当前生效的文件监控根（只读，供诊断与测试断言）。
    public var monitoredRootsSnapshot: [String] {
        mutable.withLock { $0.observedRoots }
    }

    /// 当前探测到的实时捕获能力（ADR-0006 #6：把 `realtimeCapability()` 接给界面）。
    ///
    /// 只做转发、不缓存、不改变采集行为：真值只有一份，来源是装配进来的 detector。
    /// 之所以由引擎而不是界面去问 detector——`ObservatoryRuntime` 只把 UI 与 Engine 连起来，
    /// 界面 target 不依赖 Platform，拿不到 `AgentDetectionPipeline`。
    public func currentRealtimeCapability() -> RealtimeCapability {
        components.detector.realtimeCapability()
    }

    // MARK: - Live Updates

    /// 每次调用返回一条独立订阅流；流终止时自动摘除续传。
    ///
    /// 建立订阅时**立刻补发一次当前状态**，且「登记订阅者」与「读当前状态」在同一次加锁里完成。
    /// 否则存在一个窗口：调用方先读到 `.stopped`、还没登记完，`start()` 就广播了 `.running`，
    /// 这条变化对该订阅者永久丢失——真机就是这样：数据一直在流进来，
    /// 而左下角的状态胶囊一直显示「引擎 已停止」。
    public func makeUpdateStream() -> AsyncStream<ObservatoryUpdate> {
        let id = UUID()
        return AsyncStream { continuation in
            let initial = mutable.withLock { state -> EngineState in
                state.subscribers[id] = continuation
                return state.state
            }
            continuation.onTermination = { [weak self] _ in
                self?.removeSubscriber(id)
            }
            continuation.yield(.engineState(initial))
        }
    }

    private func removeSubscriber(_ id: UUID) {
        mutable.withLock { $0.subscribers[id] = nil }
    }

    func broadcast(_ update: ObservatoryUpdate) {
        let continuations = mutable.withLock { Array($0.subscribers.values) }
        for continuation in continuations {
            continuation.yield(update)
        }
    }

    private func transition(to state: EngineState) {
        mutable.withLock { $0.state = state }
        broadcast(.engineState(state))
    }


    // MARK: - Polling

    private func startScanLoop() {
        let task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runTick()
                // 每轮重读间隔：`updateSettings` 改采样频率后下一轮就用新值，
                // 而不是启动时捕获常量（那样改了必须重启）。
                let interval = self?.settings.processScanIntervalSeconds ?? 3
                try? await Task.sleep(for: .seconds(max(interval, 0.05)))
            }
        }
        loops.withLock { $0.append(task) }
    }

    /// 一轮采集：Agent → 命令 → 性能 → 项目 → 保留期。
    /// 连续 `degradationThreshold` 轮失败才降级为 `.degraded`（瞬时抖动不影响对外状态），恢复后置回 `.running`。
    ///
    /// 每个 `await` 段之间打一次 `tickLedger` 边界 —— AGENTS §6 要求「每 tick ≤ 周期 × 3%」
    /// 是一笔**可对账的加总**。边界必须跟着本函数的段落走：新增一段活却没进账，
    /// 它不会让总数变小，只会表现为一笔明写着「未归属」的余额 + 该段边界计数对不上
    /// （见 `EngineTickAccountTests`）。`TickStage` 的九个 case 与本函数的顺序一一对应。
    private func runTick() async {
        let now = Date()
        let previousTick = mutable.withLock { state -> Date? in
            let last = state.lastTickAt
            state.lastTickAt = now
            return last
        }
        tickLedger.beginTick()
        do {
            let store = try await readyStore()
            tickLedger.mark(.scanProcesses)
            let records = await components.processInspector.scanProcesses()
            tickLedger.mark(.detectAgents)
            let agents = await components.detector.detectAgents(using: ReplayProcessInspector(records: records))
            tickLedger.mark(.ingestAgents)
            try await ingestAgents(agents, store: store, at: now)
            // 一次性孤儿收口：计入 `.ingestAgents` 那一段（它就在这一段里做）。
            await settleOrphansFromPreviousRun(liveAgents: agents, store: store)
            tickLedger.mark(.ingestCommands)
            try await ingestCommands(records: records, agents: agents, store: store, since: previousTick ?? now.addingTimeInterval(-cadence.scan), at: now)
            tickLedger.mark(.ingestPerformance)
            try await ingestPerformance(store: store, at: now)
            tickLedger.mark(.syncProjects)
            try await syncProjectsIfNeeded(store: store, at: now)
            tickLedger.mark(.prune)
            try await pruneIfNeeded(store: store, at: now)
            tickLedger.mark(.settling)
            noteTickSuccess()
        } catch is CancellationError {
            // 停止流程触发的取消，属正常路径。
            tickLedger.mark(.settling)
        } catch {
            tickLedger.mark(.settling)
            noteTickFailure(why: error.localizedDescription)
        }
        tickLedger.endTick()
        reportTickAccountPeriodically()
    }

    /// 每 `accountingEveryTicks` 轮把这笔账打进统一日志一次。
    ///
    /// 为什么要有它：判据④ 的加总此前**只有外部工具量得到**（`footprint` / `ps -o time=`
    /// 反推整进程），于是「哪一段超了」永远要重搭一次仪器才能回答。周期性落一行，
    /// 让产品自己带着账跑：`log show --info --predicate 'eventMessage CONTAINS "tick-account"'`。
    /// 取 20 轮（默认周期下约 1 分钟）：`snapshot()` 每次要建两个字典，不该按轮做。
    ///
    /// ⚠️ **这条出口在本机没能验证**（2026-09-21 实测）：这台宿主上
    /// `log show` 对**任何** subsystem 都返回空（连 `--info --debug` 也是），
    /// 所以"能不能在产品里读到"这件事仍未定——见认领牌更正块。
    /// 界面那一格（#29 的 `SelfProcessOverheadPanel`）是更可靠的落点，需要契约变更 ⇒ IFR。
    /// 正因出口不可靠，`shouldReportAccount` 与 `tickAccountLine` 被抽成纯函数单独测：
    /// 频率与列齐不能靠"跑一次肉眼看日志"来保证。
    private func reportTickAccountPeriodically() {
        let current = tickLedger.tickCount
        let previous = accountingCursor.withLock { cursor -> Int in
            let last = cursor
            cursor = current
            return last
        }
        guard Self.shouldReportAccount(
            current: current, previous: previous, every: Self.accountingEveryTicks
        ) else { return }
        let line = Self.tickAccountLine(
            account: tickLedger.snapshot(),
            cycleSeconds: settings.processScanIntervalSeconds
        )
        ObservatoryLog.engine.info("\(line, privacy: .public)")
    }

    /// 这一轮该不该打账（纯函数）。
    ///
    /// 用「跨过整数倍边界」而不是「等于整数倍」：`tickCount` 是累计值，
    /// 跨过 20 的倍数就打一次 ⇒ 中途漏检（例如某轮没跑到）不会让后面全部轮次都不打。
    static func shouldReportAccount(current: Int, previous: Int, every: Int) -> Bool {
        guard every > 0 else { return false }
        return current / every > previous / every
    }

    /// 账目行的内容（纯函数）：预算 + 九个阶段 + 已入账 + 未归属，**缺一列就不是那笔账**。
    static func tickAccountLine(account: TickAccount, cycleSeconds: Double) -> String {
        let budget = TickAccount.budgetMSPerTick(cycleSeconds: cycleSeconds)
        var line = "tick-account ticks=\(account.tickCount) 预算=\(String(format: "%.1f", budget)) ms/tick"
        for stage in TickStage.allCases {
            line += " \(stage.rawValue)=\(String(format: "%.2f", account.msPerTick(stage)))"
        }
        line += " 已入账=\(String(format: "%.2f", account.attributedMSPerTick))"
            + " 未归属=\(String(format: "%.2f", account.unattributedMSPerTick))"
        return line
    }

    private func noteTickSuccess() {
        let recovered = mutable.withLock { state -> Bool in
            guard state.consecutiveTickFailures >= Self.degradationThreshold else {
                state.consecutiveTickFailures = 0
                return false
            }
            state.consecutiveTickFailures = 0
            return true
        }
        guard recovered else { return }
        transition(to: .running)
        ObservatoryLog.engine.info("scan ticks recovered")
    }

    func noteTickFailure(why: String) {
        let shouldDegrade = mutable.withLock { state -> Bool in
            state.consecutiveTickFailures += 1
            return state.consecutiveTickFailures == Self.degradationThreshold
        }
        if shouldDegrade { transition(to: .degraded) }
        ObservatoryLog.engine.error("scan tick failed: \(why, privacy: .public)")
    }

    // MARK: - Risk

    func evaluateRisk(_ context: RiskContext, store: ObservatoryStore) async {
        await recordRisks(components.riskPipeline.evaluate(context), store: store)
    }

    /// 风险产出的**唯一**落库 / 推送 / 计数路径。
    ///
    /// 两条进料口共用：单事件事实走 `evaluateRisk(_:store:)`（→ `RiskPipeline.evaluate`），
    /// 性能采样走 `ingestPerformance(store:at:)`（→ `RiskPipeline.noteSample`）。
    /// 分叉成两份会让采样产出的风险漏掉推送或会话风险计数。
    ///
    /// `internal`（不是 `private`）只为让幂等用例能直接驱动这条真收口
    /// （`RiskEventIdempotencyTests`）：时钟不能注入，端到端没法把「同一 finding 滑出保留窗
    /// 再产出」摆成确定性的 5 次，那就得从这一格的入口进。
    ///
    /// 三件事各自的所有者，别再混：
    ///  · `risk_events` 行 → Store 的 upsert（id 来自幂等键）；
    ///  · `events` 里的时间线行 → 由风险 id 派生的确定性 id + `upsertEvents`（同一 finding
    ///    重发只刷那一行；改前是 `append` + 随机 id，真机刷出 43 行）；
    ///  · `sessions.risk_event_count` → **只有** Store 那条派生重算写它。这里过去还叠一次
    ///    `lifecycle.record(riskCount: 1)` 的自增，把刚算好的派生值盖掉 ⇒ 真机计数 40、
    ///    该会话名下风险行只有 5。自增整条摘掉，一个计数器不能有两个主人。
    func recordRisks(_ risks: [RiskEvent], store: ObservatoryStore) async {
        guard !risks.isEmpty else { return }
        do {
            try await store.recordRisks(risks)
            var timeline: [TimelineEvent] = []
            timeline.reserveCapacity(risks.count)
            for risk in risks {
                let event = components.aggregator.event(for: risk)
                timeline.append(event)
                broadcast(.risk(risk))
                broadcast(.timelineEvent(event))
            }
            try await store.upsertEvents(timeline)
            let categories = risks.map(\.category.rawValue).joined(separator: ",")
            ObservatoryLog.security.notice("risk detected: \(categories, privacy: .public)")
        } catch {
            noteTickFailure(why: "risk persistence failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Projects / Retention

    private func syncProjectsIfNeeded(store: ObservatoryStore, at now: Date) async throws {
        // 闸门判据与理由见 `ProjectSyncGate`（要点：不用每 tick 的 O(历史长度) `COUNT(*)`，
        // 也不用会静默漏行的 timestamp 游标）。
        let newestRowID = try await store.maxRowID(table: StoreSchema.Table.fileChanges)
        let due = mutable.withLock { state -> Bool in
            state.projectGate.shouldSync(
                newestFileChangeRowID: newestRowID, now: now, throttle: cadence.projectSync
            )
        }
        guard due else { return }

        // 聚合读取前先把缓冲写落库，否则最多会漏掉 32 条 / 1 秒内的变更。
        await store.flush()
        // 五路窄取数（`projectFeed`）：今天这里是 5 次 `SELECT *` 共 7 000 行，把
        // `commands.arguments_json`（每行一次 JSON 解码）与五张表的 `search_text` 全解开，
        // 只为喂给下面这个只读 6~8 个列的聚合 ⇒ 15.8 ms/tick 的大头在取数不在算。
        // 上限与顺序沿用原路径（2 000 / 2 000 / 2 000 / 500 / 500，`DESC, id DESC`）。
        let feed = try await store.projectFeed(
            fileChangeLimit: 2_000,
            commandLimit: 2_000,
            eventLimit: 2_000,
            sessionLimit: 500,
            riskLimit: 500
        )
        try await store.upsertProjects(components.projectMapper.aggregate(
            changes: feed.fileChanges,
            commands: feed.commands,
            events: feed.events,
            sessions: feed.sessions,
            risks: feed.risks
        ))
    }

    private func pruneIfNeeded(store: ObservatoryStore, at now: Date) async throws {
        let due = mutable.withLock { state -> Bool in
            if let last = state.lastPruneAt, now.timeIntervalSince(last) < cadence.prune { return false }
            state.lastPruneAt = now
            return true
        }
        guard due, settings.retentionDays > 0 else { return }
        await store.flush()
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -settings.retentionDays, to: now) else { return }
        let result = try await store.prune(olderThan: cutoff, vacuum: false)
        if result.totalDeletedRows > 0 {
            ObservatoryLog.store.notice("retention pruned \(result.totalDeletedRows, privacy: .public) rows")
        }
    }
}
