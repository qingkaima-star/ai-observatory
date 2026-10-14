//
//  SessionLifecycleManager.swift
//  AIObservatoryEngine — Session 生命周期子模块
//
//  Owner: WS-Engine
//  Sub-owner: C
//
//  ─────────────────────────────────────────────────────────
//  职责：把「Agent 进程上下线」翻译成「AI Session 的开闭与结算」。
//  以 `AgentInstance.id` 为键维护打开中的会话，并为每条会话维护累计器
//  （文件计数 / 命令计数 / 失败命令 / 性能采样序列 / 风险计数 / 最后活跃时间）。
//
//  ## 结算规则（本类型唯一口径，`sync` / `closeSession` / `closeAll` 共用）
//
//  1. `endedAt`：结算时显式传入的 `at`（不少于 `startedAt`）。
//     仅当「agent 仍在列表里但 `lastSeenAt` 已陈旧超过 `idleTimeout`」时，
//     以该 `lastSeenAt` 作为 `endedAt`（更接近真实死亡时刻）。
//  2. `outcome` 判定顺序（自上而下，先命中者胜）：
//     a. 会话存活期间**最后一条**命令失败（`outcome == .failure` 或 `exitCode != 0`）→ `.failed`；
//     b. 调用方显式给出 `.failed` 结论 → `.failed`；
//     c. 存活时长 < `minimumSessionSeconds` → `.interrupted`（短会话一律判中断）；
//     d. 调用方给出其它明确结论（正常下线传 `.success`、pid 复用 / 超时传 `.interrupted`、
//        `closeAll` 透传）→ 用该结论；
//     e. 调用方未给结论（传 `.running`）且会话有任一实测依据（文件/命令/采样/风险）→ `.success`；
//     f. 其余 → `.unknown`。
//  3. `cpuSeconds`：`Σ (cpuPercent / 100) × Δt`。第 i 个样本的 Δt 区间为
//     「上一个样本时间戳（首个样本取 `startedAt`）→ 该样本时间戳」，
//     最后一个样本的区间收口到 `endedAt`；单个 Δt 超过 60 秒（或 ≤0）视为异常间隔，**不入账**。
//     **无任何采样 → 0**（禁止用墙钟时长伪造 CPU 消耗）。
//  4. `peakCPUPercent` / `peakMemoryBytes`：采样本内最大值，无样本 → 0。
//  5. `modified/created/deletedFileCount`：**唯一写入口子是 `applyFileCounts`（绝对赋值），
//     赋的是调用方从 `file_changes` 数出来的真实行数**（#78）。这里没有任何一处 `+= 1`。
//     `renamed` / `unknown` 类型的文件变更不计入三个文件计数。
//     为什么不让内存计数承重：文件变更行走 `BatchWriter` 缓冲写，`store.append(change)` 返回
//     只意味着「语句进了缓冲」，不意味着「这一行在库里」。曾经在那里直接 +1，于是批次被丢弃 /
//     逐条兜底失败时列值比真实行数高——真库实测会话 #2 `modified_file_count = 19`
//     而按 `session_id` 数出的 modified 行是 18，三列之和 26 对不上总行 25
//     （`04-决策记录/发现-会话计数列比真实行数多1（活库实测）.md`）。
//     流程：`stage`（挂一笔欠账，不动计数）→ `fileCountRecountsRequired`（写入通道报过一次数，
//     问哪些会话该改写了）→ 调用方数三类的行数 → `applyFileCounts`（赋值 + 收账）。
//     ⚠️ 「缓冲排空且一条没丢」**不是**证据：`BatchWriter.commitBuffer()` 先换出缓冲再去 await
//     另一个 actor 的事务，那段在途窗口里 `pendingCount` 已经是 0 而丢弃还没记账 ——
//     那一轮的 +1 同样会永久虚高。所以观测只用来决定「欠账要不要继续追」，永远不参与取值。
//     欠账追平（或被丢弃额度解释掉）才收账；`resume` 接回来的历史会话只数一次即收账。
//     `commandCount` / `failedCommandCount` 仍由 `record(command:)` 直接累计——
//     它们和文件计数是同一个形状（缓冲写 + 内存自增），但不在 #78 这一格里，见交回来的 NEXT。
//     **`riskEventCount` 不在这一条里**：它派生自 `risk_events` 行数，唯一的写入者是
//     Store 的重算（`ObservatoryStore.recordRisks` / `upsertSessions`）。这里曾有过一条
//     `record(riskCount: 1)` 的自增，同一 finding 每重发一次就 +1 并把派生值盖掉，
//     真机 `sessions.risk_event_count = 40` 而该会话名下只有 5 行风险 —— 一个计数器不能有两个主人。
//  6. `estimatedTokens`：结算时取 `TokenEstimator.estimate(session:)?.tokens`，估算不出来 → 0。
//     打开中的会话该字段保持 0（避免依赖 `Date()` 造成非确定性）。
//  7. `title` = `"\(kind.displayName) · \(DateFormat.timestamp(startedAt))"`；
//     `projectPath` = `agent.workingDirectory`，但**必须先过** `MonitoringRootResolver.isUsableAttributionRoot`
//     （非空、不是 `/` 与家目录这类受保护根、至少两个路径分量），判不出来就写 nil；
//     后续同步里首次拿到可用 cwd 时同样按这条口径补齐。
//     `displayIndex` 从 1 起在同一 manager 内单调递增且不复用。
//  8. 同一 pid 被复用（`AgentInstance.id` 变了、pid 没变）→ 旧会话按 `.interrupted` 结算后移出，
//     再为新 id 开启新会话。
//  9. agent 从本轮列表里消失**不再立刻结算**：第一次缺席只记下时刻（`Opened.absentSince`），
//     会话原样留在打开态、不出现在 `SyncResult` 的任何一栏；连续缺席满 `Configuration.absenceGrace`
//     才按 `.success` 结算，`endedAt` 仍取「真正结算那一轮」传入的 `at`（口径见规则 1，不改成最后观测时刻）。
//     宽限期内重新出现在列表里 → 抹掉缺席标记，同一条会话继续，不另开。
//     为什么要有这条：检出侧每 3 秒交一次全集，而漏检是常态（某次读不到 argv、bundle 归并的
//     成员集合瞬时变化），缺席一次就结算会把一个一直活着的进程拆成「一条已结算会话 + 下一条新会话」，
//     每次抖动还要 upsert 行 + 重算聚合 + 向界面广播；真机出现过 11 秒内会话数 1 → 15。
//     `absenceGrace == 0` = 不宽限，第一次缺席即结算（旧行为，留作对照）。
//     规则 8 的 pid 复用、「仍在列表但 `lastSeenAt` 陈旧超过 `idleTimeout`」、以及 `closeAll`
//     都**不等宽限**，立刻结算。
//
//  ## 并发
//  `public actor`，全部方法内部**无 await**（纯内存计算），因此不存在重入窗口；
//  所有时间都通过 `at:` 显式传入，保证测试确定性。
//

import Foundation
import AIObservatoryCore

/// 结算用的内部常量。
private enum LifecycleConstants {
    /// 单个采样区间可入账的最大时长（秒）；超出即视为异常间隔，不计入 `cpuSeconds`。
    static let maximumCreditedSampleInterval: TimeInterval = 60
}

/// Agent 上下线 → Session 开闭与统计结算。
public actor SessionLifecycleManager {

    // MARK: - Configuration

    /// 生命周期判定阈值。
    public struct Configuration: Sendable, Hashable {
        /// `lastSeenAt` 超过它（秒）视为已下线。
        public var idleTimeout: TimeInterval
        /// 短于此存活时长的会话在结算时判为 `.interrupted`。
        public var minimumSessionSeconds: TimeInterval
        /// agent 连续缺席多久（秒）之后才结算它的会话。
        ///
        /// 为什么需要：`sync` 每 3 秒收到一次「本轮 Agent 全集」，而漏检是常态
        /// （某一次读不到 argv、bundle 归并的成员集合瞬时变化）。缺席一次就结算会把一个
        /// 一直活着的进程拆成「一条已结算会话 + 下一条新会话」，每次抖动还要 upsert 会话行、
        /// 重算聚合、向界面广播——既是每-tick 成本也是数据质量问题（真机出现过 11 秒内会话数 1 → 15）。
        /// 默认 6 秒 = 两个 tick：单轮漏检被吸收，真正的下线只晚两个 tick 记账。
        ///
        /// `0` 表示**不宽限**：agent 第一次从列表缺席即结算（旧行为），用于对照与回归。
        public var absenceGrace: TimeInterval

        /// 以可选阈值初始化；负数会被收敛为 0，非有限值回落到默认值。
        public init(
            idleTimeout: TimeInterval = 120,
            minimumSessionSeconds: TimeInterval = 5,
            absenceGrace: TimeInterval = 6
        ) {
            self.idleTimeout = Self.sanitize(idleTimeout, fallback: 120)
            self.minimumSessionSeconds = Self.sanitize(minimumSessionSeconds, fallback: 5)
            self.absenceGrace = Self.sanitize(absenceGrace, fallback: 6)
        }

        /// 默认配置：空闲超时 120 秒，最短有效会话 5 秒，缺席宽限 6 秒。
        public static let standard = Configuration()

        private static func sanitize(_ value: TimeInterval, fallback: TimeInterval) -> TimeInterval {
            guard value.isFinite else { return fallback }
            return max(0, value)
        }
    }

    // MARK: - SyncResult

    /// 一次 `sync` 的结果：本轮新建、已结算、以及内容发生变化的打开中会话。
    public struct SyncResult: Sendable, Hashable {
        /// 本轮新开的会话（`outcome == .running`、`endedAt == nil`）。
        public var opened: [AgentSession]
        /// 本轮结算完成的会话（`endedAt` / `outcome` / 全部统计字段已填好）。
        public var closed: [AgentSession]
        /// 仍打开但快照内容变化的会话（例如补到了 `projectPath`）。
        public var updated: [AgentSession]

        public init(opened: [AgentSession] = [], closed: [AgentSession] = [], updated: [AgentSession] = []) {
            self.opened = opened
            self.closed = closed
            self.updated = updated
        }

        /// 是否有任何会话需要落库。
        public var needsPersistence: Bool { !opened.isEmpty || !closed.isEmpty || !updated.isEmpty }
    }

    // MARK: - Internal state

    /// 一条打开中的会话及其累计器。
    private struct Opened: Sendable {
        /// 未结算快照（`outcome == .running`、`endedAt == nil`）。
        var snapshot: AgentSession
        /// 开会话时该 agent 的 pid，用于 pid 复用检测与索引清理。
        var agentPID: Int32
        /// 最后一次在 `sync` 列表中看到它的时间。
        var lastSeenAt: Date
        /// 第一次在本轮列表中缺席的时刻；nil 表示最近一轮仍然检出。
        /// 非 nil 且缺席时长满 `Configuration.absenceGrace` 才真正结算（见文件头规则 9）。
        var absentSince: Date?
        /// 时间升序的性能采样序列，结算时用于 `cpuSeconds` / 峰值。
        var samples: [Sample]
        /// 最后一条命令的时间戳（用于判定「最后一条命令是否失败」）。
        var lastCommandAt: Date?
        /// 最后一条命令是否失败。
        var lastCommandFailed: Bool
    }

    /// 结算用的单个性能采样。
    private struct Sample: Sendable {
        var timestamp: Date
        var cpuPercent: Double
        var memoryBytes: UInt64
    }

    private let configuration: Configuration
    private let tokenEstimator: TokenEstimator
    /// 下一条会话的 `displayIndex`（从 1 起，永不回退）。
    private var nextDisplayIndex: Int = 1
    /// 主索引：`AgentInstance.id` → 打开中的会话。
    private var opened: [UUID: Opened] = [:]
    /// 次索引：`AgentSession.id` → `AgentInstance.id`。
    private var sessionIndex: [UUID: UUID] = [:]
    /// 次索引：`pid` → `AgentInstance.id`。
    private var pidIndex: [Int32: UUID] = [:]

    // MARK: - Init

    /// 以阈值配置与 token 估算器初始化（估算器可注入，便于测试）。
    public init(configuration: Configuration = .standard, tokenEstimator: TokenEstimator = TokenEstimator()) {
        self.configuration = configuration
        self.tokenEstimator = tokenEstimator
    }

    // MARK: - Sync

    /// 本轮扫描到的 Agent 全集 → 会话增删改。
    ///
    /// 新出现的 agent 开会话；仍在列表但 `lastSeenAt` 已陈旧超过 `idleTimeout` 的会话在此结算并移出；
    /// 从列表消失的 agent 先进入缺席宽限（`Configuration.absenceGrace`，默认 6 秒），
    /// 宽限期满仍未回来才结算，宽限期内重新出现则同一条会话继续；
    /// 同一 pid 换新 UUID 时旧会话按 `.interrupted` 结算（不等宽限）。
    /// `sync` 内不读墙钟：所有时间判定只用调用方传入的 `at`。
    ///
    /// 重启续接：把库里未结算的会话装回内存，`sync` 就会**继续**它们而不是另开一条。
    ///
    /// 为什么必须有：重启后内存是空的，同一个还活着的 Agent 会被再开一条会话 ⇒
    /// 需求点名的「运行时长 2 小时 15 分钟」被截断成两段。真机实测：反复重启后
    /// 同一个 Codex 进程（PID 32,630，01:34 启动）在 Dashboard 上留下 9 条 0 秒会话。
    ///
    /// `AgentSession` 不带 pid，所以续接时 pid 先记 0（未知），由 `sync` 首次看到该 agent 时补上
    /// ——不猜 pid，也不因为拿不到就放弃续接。
    public func resume(sessions: [AgentSession], at date: Date) {
        for session in sessions where session.endedAt == nil {
            guard let agentID = session.agentID, opened[agentID] == nil else { continue }
            opened[agentID] = Opened(
                snapshot: session,
                agentPID: 0,
                lastSeenAt: max(session.startedAt, date),
                absentSince: nil,
                samples: [],
                lastCommandAt: nil,
                lastCommandFailed: false
            )
            sessionIndex[session.id] = agentID
            nextDisplayIndex = max(nextDisplayIndex, session.displayIndex + 1)
            // #78：这一行带着的是**上一个进程**记的三列，而那些 `file_changes` 语句早就有了归宿
            // （干净退出时缓冲被 flush、崩溃 / 断电时更是如此）。本进程没有「投了几笔」的账可追
            // ⇒ 挂一笔"只数一次"的对账，让第一轮采集按真实行数把它改写一遍。
            // 少这一格，那三列会永远停在旧值上：界面上读到的是"上次进程记得数"，不是"库里有几行"。
            fileCountWatches[session.id] = FileCountWatch(reconcileOnceOnly: true)
        }
    }

    /// 用**全历史**已用过的最大编号给发号器定下限（ICR-0004）。
    ///
    /// 为什么单独一条口子：`resume(sessions:)` 拿到的只有「未结算」那几行，而重启最常见的
    /// 形状是上一轮的会话**全都结算了** ⇒ 只从它取 max 等于没取，新会话从 1 重新发号，
    /// 与历史行撞成同一屏两个 #2。下限必须来自 `MAX(display_index)` 全历史。
    /// 只做「抬高下限」，绝不下调：同一进程内已经发出去的号不可能收回。
    public func seedDisplayIndexFloor(fromHistoryMax historyMax: Int) {
        nextDisplayIndex = max(nextDisplayIndex, historyMax + 1)
    }

    public func sync(agents: [AgentInstance], at date: Date) -> SyncResult {
        var result = SyncResult()
        var seen: Set<UUID> = []

        for agent in agents {
            seen.insert(agent.id)

            if let existing = opened[agent.id] {
                // 仍在列表里，但观测时间已过陈旧 → 按超时结算（以最后一次真实观测收口）。
                if isStale(agent, at: date) {
                    if let settled = settle(agentKey: agent.id, endAt: agent.lastSeenAt, requested: .interrupted) {
                        result.closed.append(settled)
                    }
                    continue
                }
                var current = existing
                let before = current.snapshot
                current.lastSeenAt = max(current.lastSeenAt, date)
                // 宽限期内又检出 → 回到正常打开态，同一条会话继续（不结算、不另开）。
                current.absentSince = nil
                backfill(&current.snapshot, from: agent)
                // 重启续接的会话不知道 pid（`AgentSession` 不带这个字段）；
                // 第一次在本轮列表里看到该 agent 时补上，否则按 pid 查会话会一直查不到。
                if current.agentPID == 0, agent.pid != 0 {
                    current.agentPID = agent.pid
                    pidIndex[agent.pid] = agent.id
                }
                opened[agent.id] = current
                if current.snapshot != before {
                    result.updated.append(current.snapshot)
                }
                continue
            }

            // pid 复用：旧 agent id 仍挂着会话 → 先按 .interrupted 结算。
            if let previous = pidIndex[agent.pid], previous != agent.id, opened[previous] != nil {
                if let settled = settle(agentKey: previous, endAt: date, requested: .interrupted) {
                    result.closed.append(settled)
                }
            }
            result.opened.append(open(agent, at: date))
        }

        // 列表中不再出现的 agent → 先进入缺席宽限；宽限期满才按正常下线结算。
        // 先物化 keys，避免在遍历中改动字典。
        let disappeared = opened.keys.filter { !seen.contains($0) }.sorted {
            (opened[$0]?.snapshot.displayIndex ?? 0) < (opened[$1]?.snapshot.displayIndex ?? 0)
        }
        for agentKey in disappeared {
            guard var record = opened[agentKey] else { continue }
            if shouldSettleOnAbsence(&record, at: date) {
                if let settled = settle(agentKey: agentKey, endAt: date, requested: .success) {
                    result.closed.append(settled)
                }
            } else {
                // 宽限未到期：只记下第一次缺席的时刻，本轮不出现在 SyncResult 的任何一栏。
                opened[agentKey] = record
            }
        }
        return result
    }

    /// 强制结束某个 agent 的会话并返回结算结果；该 agent 无打开会话时返回 nil。
    public func closeSession(agentID: UUID, at date: Date, outcome: SessionOutcome) -> AgentSession? {
        settle(agentKey: agentID, endAt: date, requested: outcome)
    }

    /// 结算并清空**全部**打开中的会话（引擎停止 / 重启时对账用）。
    /// 无视缺席宽限：本轮全部收口，三张索引一并清空——停机路径不能留下「等着宽限期过」的会话。
    public func closeAll(at date: Date, outcome: SessionOutcome) -> [AgentSession] {
        var closed: [AgentSession] = []
        let keys = opened.keys.sorted {
            (opened[$0]?.snapshot.displayIndex ?? .max) < (opened[$1]?.snapshot.displayIndex ?? .max)
        }
        for agentKey in keys {
            if let settled = settle(agentKey: agentKey, endAt: date, requested: outcome) {
                closed.append(settled)
            }
        }
        opened.removeAll()
        sessionIndex.removeAll()
        pidIndex.removeAll()
        return closed
    }

    /// 当前打开中的会话快照（按 `displayIndex` 升序，稳定输出）；处于缺席宽限期内的会话也算打开。
    public func currentSessions() -> [AgentSession] {
        opened.values.map(\.snapshot).sorted { $0.displayIndex < $1.displayIndex }
    }

    /// agent → 打开中的会话 id；无该会话返回 nil。
    public func sessionID(forAgentID agentID: UUID) -> UUID? {
        opened[agentID]?.snapshot.id
    }

    /// pid → 打开中的会话 id；无该会话返回 nil。
    public func sessionID(forPID pid: Int32) -> UUID? {
        guard let agentKey = pidIndex[pid] else { return nil }
        return opened[agentKey]?.snapshot.id
    }

    // MARK: - File-change counts (三列只跟着 `file_changes` 的行数走)

    /// 缓冲写通道的一次观测，由调用方（引擎）从 `ObservatoryStore.batchStats()` 读来。
    ///
    /// 本类型不认识 Store，也不碰 SQL。**⚠️ 这份观测不参与三列的取值**——取值只有一个来源：
    /// 调用方从 `file_changes` 数出来的行数（`applyFileCounts`）。观测只决定
    /// 「还欠着的那几行要不要继续追下去」。
    public struct WriteChannelObservation: Sendable, Hashable {
        /// 缓冲里还有没有**排队**的语句。
        ///
        /// 为什么它不等于「之前投入的每条语句都有了归宿」：`BatchWriter.commitBuffer()` 先把
        /// 缓冲换出（它自己的注释就叫 swap-out），再 `await database.inTransaction(...)`，
        /// 而 `SQLiteDatabase` 是另一个 actor ⇒ 那一跳是真挂起。事务在途的那段窗口里
        /// `pendingCount` 已经是 0、`droppedStatementCount` 也还没加上；生产里定时器
        /// （`engine.start()` → `store.start()` → `writer.start()`）和别的任务凑满一批的
        /// 就地提交随时会开这么一趟。把它当「这一批没丢」的证据，就是 19 vs 18 的另一个出生方式：
        /// 那一次 +1 记完之后账也销了，再没有第二个人去数那三列。
        /// 现在它只留一个用途：**缓冲还排着队就别白数一遍行数**（省一次查询），仅此而已。
        public var bufferDrained: Bool
        /// 累计被丢弃的语句条数（单调不降）。它的**增量**是「确实有行进不了库」的唯一凭据，
        /// 只用来给欠账销账（N 条丢弃最多解释 N 笔欠账），不参与任何一格的取值。
        public var droppedStatementCount: Int

        public init(bufferDrained: Bool, droppedStatementCount: Int) {
            self.bufferDrained = bufferDrained
            self.droppedStatementCount = max(0, droppedStatementCount)
        }
    }

    /// 计入三个文件计数列的变更类型（`renamed` / `unknown` 不计，见文件头规则 5）。
    ///
    /// 写成数组而不是 `Set`：销账时「缺口最大的一类优先」必须有确定的遍历顺序，
    /// 不然同样的输入会因为 Set 的随机序给出不同的收账结果。
    static let countedFileChangeKinds: [FileChangeKind] = [.created, .modified, .deleted]

    /// 一笔还没跟 `file_changes` 对平的账（按会话记）。
    private struct FileCountWatch {
        /// 已投入缓冲写通道的变更 id：同一行不被记两次，也是 `stagedFileChangeCount` 的尺。
        var changeIDs: Set<UUID> = []
        /// 按类记的「库里至少该数到多少行」。投一条抬 1，数到了就跟上实际值。
        var expected: [FileChangeKind: Int] = [:]
        /// 只对账一次就收账：`resume` 接回来的历史会话用它——那几行是**上一个进程**投的，
        /// 本进程不知道欠了几笔 ⇒ 按行数改写一次即作数（干净退出时留在途行、崩溃、断电
        /// 三种形状都靠这一格收口，否则那三列会永远停在旧值上）。
        var reconcileOnceOnly = false
    }

    /// 还没对平的账：`会话 id → 欠账`。会话结算时**不**跟着清掉：
    /// 结算之后才落定的那些行不能凭空消失，库里那一行仍然要有人去改写。
    private var fileCountWatches: [UUID: FileCountWatch] = [:]
    /// 上一次观测到的丢弃条数（算增量用）。
    private var lastObservedDroppedStatements = 0
    /// 观测到、还没被某笔缺口消耗掉的丢弃额度。N 条丢弃最多解释 N 笔欠账，多给就是编事实。
    private var unattributedDrops = 0

    /// #86：命令两列（`commandCount` / `failedCommandCount`）的欠账表，键是会话 id。
    private var commandCountWatches: [UUID: CommandCountWatch] = [:]

    /// 还没对平的文件变更条数（全部类型合计）。0 表示「三列已经与行数对上」。
    public var stagedFileChangeCount: Int {
        fileCountWatches.values.reduce(0) { $0 + $1.changeIDs.count }
    }

    /// 是否有任何待对平的账（含「只数一次」的历史会话）。引擎据此决定这一轮要不要去问写入通道：
    /// 一条文件事件都没产、也没有会话要接时它恒 false ⇒ 认领检查在静默机器上零成本。
    public var hasStagedFileChanges: Bool { !fileCountWatches.isEmpty }

    /// 某一类计数列在给定快照上的读数（`AgentSession` 没有按 kind 取数的口子，这里补私有的）。
    private static func fileCount(_ kind: FileChangeKind, of session: AgentSession) -> Int {
        switch kind {
        case .created:  return session.createdFileCount
        case .modified: return session.modifiedFileCount
        case .deleted:  return session.deletedFileCount
        case .renamed, .unknown: return 0
        }
    }

    /// 把某一类计数列写到给定快照上。
    private static func setFileCount(_ kind: FileChangeKind, to value: Int, on session: inout AgentSession) {
        switch kind {
        case .created:  session.createdFileCount = value
        case .modified: session.modifiedFileCount = value
        case .deleted:  session.deletedFileCount = value
        case .renamed, .unknown: break
        }
    }

    /// 记下一条**已经**投入缓冲写通道的文件变更：**不动任何计数**，只挂一笔欠账。
    ///
    /// 归属顺序与 `record(command:)` 同一条：`fileChange.sessionID`（必须命中已知会话）
    /// → `fileChange.agentID` → 在打开会话中唯一匹配 `agentKind` 的那条。
    /// 顺带做一件与计数无关的事：会话还没有项目路径时用这条变更的 `projectPath` 补上
    /// （补上了就要落库，见 `Staged.snapshot`）——旧口径里这件事和 +1 挤在同一个返回值上，
    /// 拆成两步之后它仍得有个出口，否则「先观测到文件、后观测到 cwd」的会话会一直缺归属。
    ///
    /// - Returns: `nil` 表示不计入三列的类型（`renamed` / `unknown`）或无法归属
    ///   ——同时意味着这条没进欠账，调用方不必为它对账。
    public func stage(fileChange: FileChange, agentKind: AgentKind) -> Staged? {
        guard Self.countedFileChangeKinds.contains(fileChange.kind) else { return nil }
        guard let agentKey = resolveAgentKey(
            sessionID: fileChange.sessionID, agentID: fileChange.agentID, kind: agentKind
        ) else { return nil }
        guard var record = opened[agentKey] else { return nil }
        let sessionID = record.snapshot.id
        var watch = fileCountWatches[sessionID] ?? FileCountWatch()
        if watch.changeIDs.insert(fileChange.id).inserted {
            let kind = fileChange.kind
            watch.expected[kind, default: Self.fileCount(kind, of: record.snapshot)] += 1
        }
        // 本进程亲手投的行 ⇒ 得追到数平才收账，不能像接回来的历史会话那样只数一遍。
        watch.reconcileOnceOnly = false
        fileCountWatches[sessionID] = watch

        var updated: AgentSession?
        if record.snapshot.projectPath == nil, let path = usableProjectPath(fileChange.projectPath) {
            record.snapshot.projectPath = path
            opened[agentKey] = record
            updated = record.snapshot
        }
        return Staged(sessionID: sessionID, snapshot: updated)
    }

    /// 一次暂存的结果。
    public struct Staged: Sendable, Hashable {
        /// 这条变更归到的会话。
        public var sessionID: UUID
        /// 快照若有变化（只可能是补到了项目路径）带新快照，调用方要落库并广播；
        /// **计数不在这里变**，所以 nil 是常态。
        public var snapshot: AgentSession?
    }

    /// 写入通道报过一次数之后，问一遍：**哪些会话的三列现在该按 `file_changes` 的行数改写**。
    ///
    /// 这里**没有自增**（#78 的落点）。原来那一支「缓冲排空且一条没丢 ⇒ 逐条 +1」被删掉了：
    /// `pendingCount == 0` 证明不了在途事务的结局（见 `WriteChannelObservation.bufferDrained`），
    /// 而 +1 一旦记高就再也回不来——账当场销掉，之后没人会再去数那三列。
    /// 现在每一格都只能由行数写（`applyFileCounts`），观测到的丢弃只用来决定「还欠的要不要继续追」。
    ///
    /// - Returns: 要改写三列的会话 id（顺序确定，可重复）。空数组表示本轮什么都不做：
    ///   要么没账可追，要么缓冲还排着队（这会儿数出来的行数必然偏低，白数一趟）。
    public func fileCountRecountsRequired(observation: WriteChannelObservation) -> [UUID] {
        // 丢弃基准照常推进：它单调不降。本轮不认领也得记住「现在一共丢了多少」，
        // 额度先攒着，等下面 `applyFileCounts` 拿到真实行数时再决定给谁销账。
        let dropped = observation.droppedStatementCount
        unattributedDrops += max(0, dropped - lastObservedDroppedStatements)
        lastObservedDroppedStatements = max(lastObservedDroppedStatements, dropped)
        guard observation.bufferDrained, !fileCountWatches.isEmpty else { return [] }
        return fileCountWatches.keys.sorted { $0.uuidString < $1.uuidString }
    }

    /// 三列按 `file_changes` 的真实行数**赋值**（不是自增、不是取大）——这三列唯一的写入口子。
    ///
    /// 同时收账：某一类数到了「至少该有」的条数 ⇒ 那笔欠账跟着销；数不到 ⇒ 差额只允许被
    /// **观测到的丢弃额度**冲抵（N 条丢弃最多解释 N 笔欠账，从缺口最大的一类抵起），
    /// 冲不平就留着下一轮再数——那一行也许只是还在途，不等于永远不会到。
    /// 负数按 0 处理（§5：不替调用方兜住假数据，但也不写出负计数）。
    /// - Returns: 更新后的快照；该会话不在打开集合里（已结算）时返回 nil——
    ///   库里那一行由调用方自己读回来改写，但欠账照样在这里销掉。
    public func applyFileCounts(
        sessionID: UUID, created: Int, modified: Int, deleted: Int
    ) -> AgentSession? {
        let actual: [FileChangeKind: Int] = [
            .created: max(0, created), .modified: max(0, modified), .deleted: max(0, deleted),
        ]
        reconcileFileCountWatch(sessionID: sessionID, actual: actual)
        guard let agentKey = sessionIndex[sessionID], var record = opened[agentKey] else { return nil }
        for kind in Self.countedFileChangeKinds {
            Self.setFileCount(kind, to: actual[kind] ?? 0, on: &record.snapshot)
        }
        opened[agentKey] = record
        return record.snapshot
    }

    /// 拿一次真实行数对一遍某会话的欠账，能销的销掉、销不掉的留下轮。
    private func reconcileFileCountWatch(sessionID: UUID, actual: [FileChangeKind: Int]) {
        guard var watch = fileCountWatches[sessionID] else { return }
        // 接回来的历史会话没有本进程的账可追 ⇒ 数一次就按那一次作数。
        if watch.reconcileOnceOnly {
            fileCountWatches[sessionID] = nil
            return
        }
        // 1. 数到多少就把「至少该有」抬到多少：欠账不因一次赋值而消失，但基准要跟上新事实。
        for kind in Self.countedFileChangeKinds {
            guard watch.expected[kind] != nil else { continue }
            watch.expected[kind] = max(watch.expected[kind] ?? 0, actual[kind] ?? 0)
        }
        // 2. 缺口按"最大优先"吃掉丢弃额度：被丢的语句无从知道是哪一类，
        //    但 N 条丢弃最多解释 N 笔欠账——把 1 条丢弃花在 3 笔欠账上就是替 SQLite 编行。
        let gaps = Self.countedFileChangeKinds.compactMap { kind -> (FileChangeKind, Int)? in
            guard let expected = watch.expected[kind] else { return nil }
            let gap = expected - (actual[kind] ?? 0)
            return gap > 0 ? (kind, gap) : nil
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.id < $1.0.id }
        for gap in gaps {
            guard unattributedDrops > 0 else { break }
            let spent = min(unattributedDrops, gap.1)
            unattributedDrops -= spent
            watch.expected[gap.0] = (watch.expected[gap.0] ?? 0) - spent
        }
        // 3. 全数平（或已被丢弃解释）才收账；还有缺口就留着，下一轮观测再数。
        let remaining = Self.countedFileChangeKinds.reduce(0) { total, kind in
            guard let expected = watch.expected[kind] else { return total }
            return total + max(0, expected - (actual[kind] ?? 0))
        }
        if remaining == 0 {
            fileCountWatches[sessionID] = nil
        } else {
            fileCountWatches[sessionID] = watch
        }
    }

    // MARK: - Command count ledger（#86）

    /// 一个会话在命令两列上欠的账。
    ///
    /// 与文件那三列的欠账表**同一个目的、不同的收账判据**：文件那一支吃
    /// `WriteChannelObservation.droppedStatementCount` 的增量额度，而那份额度是**通道级唯一资源**
    /// （两条账一起花就会互相抢，抢输的那条永远追不平）。所以这一支改用**收敛**停追：
    /// 缓冲已排空、且这一轮数出来的总行数与上一轮**一模一样** ⇒ 不会再有增量进来，库就是答案。
    /// 注意这不影响正确性：两列的值**永远来自行数**，`expected*` 只决定"还要不要再数一遍"。
    private struct CommandCountWatch {
        var expectedTotal: Int = 0
        var expectedFailed: Int = 0
        /// 接回来的历史会话没有本进程投出去的账可追 ⇒ 数一次就按那一次作数。
        var reconcileOnceOnly: Bool = true
        /// 上一轮数到的 `commands` 总行数；用来判"这一轮还涨不涨"。
        var lastCountedTotal: Int?
    }

    /// 挂一笔欠账：本进程又投了一条命令进缓冲写通道。**不动任何一格计数**。
    private func stageCommandCount(sessionID: UUID, failed: Bool) {
        var watch = commandCountWatches[sessionID] ?? CommandCountWatch()
        watch.expectedTotal += 1
        if failed { watch.expectedFailed += 1 }
        watch.reconcileOnceOnly = false
        commandCountWatches[sessionID] = watch
    }

    /// 有没有欠账要追（引擎拿这个决定本轮要不要去问写入通道）。
    public var hasStagedCommandCounts: Bool { !commandCountWatches.isEmpty }

    /// 写入通道报过一次数之后，问一遍：**哪些会话的两列现在该按 `commands` 的行数改写**。
    /// 缓冲还排着队 ⇒ 空表（这会儿数出来的行数必然偏低，白数一趟），仅此而已。
    public func commandCountRecountsRequired(observation: WriteChannelObservation) -> [UUID] {
        guard observation.bufferDrained, !commandCountWatches.isEmpty else { return [] }
        return commandCountWatches.keys.sorted { $0.uuidString < $1.uuidString }
    }

    /// 两列按 `commands` 的**真实行数**赋值——这是这两列唯一的写入口子（#86）。
    /// 负数按 0 处理（§5：不写出负计数），但**不夹到 `total` 以内**：
    /// `失败 = #(outcome = .failure) + #(outcome ≠ .failure ∧ exit ≠ 0)` 在算术上必然 ≤ 总行数，
    /// 真出现比总行数大就是取数错了，那种假象得让它红着暴露出来，而不是被 `min` 抹平。
    /// - Returns: 更新后的快照；该会话已结算（不在打开集合里）时返回 nil——
    ///   库里那一行由调用方读回来改写，欠账照样在这里销掉。
    public func applyCommandCounts(sessionID: UUID, total: Int, failed: Int) -> AgentSession? {
        let actualTotal = max(0, total)
        let actualFailed = max(0, failed)
        reconcileCommandCountWatch(sessionID: sessionID, total: actualTotal, failed: actualFailed)
        guard let agentKey = sessionIndex[sessionID], var record = opened[agentKey] else { return nil }
        record.snapshot.commandCount = actualTotal
        record.snapshot.failedCommandCount = actualFailed
        opened[agentKey] = record
        return record.snapshot
    }

    /// 拿一次真实行数对一遍某会话的欠账：追平就销，没追平但**已收敛**也销（库就是答案），
    /// 还在涨就留着下一轮再数。
    private func reconcileCommandCountWatch(sessionID: UUID, total: Int, failed: Int) {
        guard var watch = commandCountWatches[sessionID] else { return }
        if watch.reconcileOnceOnly {
            commandCountWatches[sessionID] = nil
            return
        }
        watch.expectedTotal = max(watch.expectedTotal, total)
        watch.expectedFailed = max(watch.expectedFailed, failed)
        if total >= watch.expectedTotal, failed >= watch.expectedFailed {
            commandCountWatches[sessionID] = nil
            return
        }
        if let last = watch.lastCountedTotal, last == total {
            // 连着两轮总数不再增长 ⇒ 差额不会再进来了（被丢弃的那些没有第二个人来解释）。
            commandCountWatches[sessionID] = nil
        } else {
            watch.lastCountedTotal = total
            commandCountWatches[sessionID] = watch
        }
    }

    // MARK: - Recording

    /// 累计一条命令执行（含失败判定），返回更新后的会话快照；无法归属时返回 nil。
    ///
    /// ⚠️ 命令走的是**同一条缓冲写通道**（`ObservatoryStore.append(CommandRecord)`），
    /// 所以这两个计数与上面的文件计数是同一个形状、同一个病；本波（#78）只裁了文件那一头，
    /// 命令那一头照实记在交回来的 NEXT 里，不在这里顺手改口径。
    public func record(command: CommandRecord) -> AgentSession? {
        guard let agentKey = resolveAgentKey(sessionID: command.sessionID, agentID: command.agentID, kind: command.agentKind) else {
            return nil
        }
        guard var record = opened[agentKey] else { return nil }

        let failed = isFailure(command)
        // #86：**这里不再 `+= 1`**。命令走的是与文件变更同一条 `BatchWriter` 缓冲写通道
        // （`ObservatoryStore.append(CommandRecord)`），"投进缓冲"不等于"落库"：
        // 一条语句被丢弃 ⇒ 那一格永久虚高，而账当场销掉之后再没人去数它——
        // #78 在 `modified/created/deletedFileCount` 那三列上就是这个形状出的 19 vs 18。
        // 现在两列唯一的写入路径是 `applyCommandCounts`，值来自 `commands` 的行数；
        // 这里只挂一笔"至少该有这么多"的欠账。
        stageCommandCount(sessionID: record.snapshot.id, failed: failed)
        // 「最后一条」按时间戳判定，而非到达顺序。
        let isNewest = record.lastCommandAt.map { command.startedAt >= $0 } ?? true
        if isNewest {
            record.lastCommandAt = command.startedAt
            record.lastCommandFailed = failed
        }
        var projectPathFilled = false
        if record.snapshot.projectPath == nil, let path = usableProjectPath(command.projectPath) {
            record.snapshot.projectPath = path
            projectPathFilled = true
        }
        opened[agentKey] = record
        // 只有补到项目路径时才需要落库与广播；**计数不在这条路上**（见上），
        // 所以常态返回 nil，由对平那一路按行数改写这两列。
        return projectPathFilled ? record.snapshot : nil
    }

    /// 累计一条性能采样（同时刷新峰值与已入账的 `cpuSeconds`），返回更新后的会话快照。
    public func record(performanceSample: PerformanceSample) -> AgentSession? {
        guard let agentKey = resolveAgentKey(sessionID: performanceSample.sessionID, agentID: performanceSample.agentID, kind: nil) else {
            return nil
        }
        guard var record = opened[agentKey] else { return nil }

        let cpu = performanceSample.cpuPercent.isFinite ? max(0, performanceSample.cpuPercent) : 0
        record.samples.append(Sample(timestamp: performanceSample.timestamp, cpuPercent: cpu, memoryBytes: performanceSample.memoryBytes))
        record.samples.sort { $0.timestamp < $1.timestamp }

        let peaks = Self.peaks(of: record.samples)
        record.snapshot.peakCPUPercent = peaks.cpu
        record.snapshot.peakMemoryBytes = peaks.memory
        // 打开中的会话也给出「已入账部分」，最后一段在结算时收口到 endedAt。
        record.snapshot.cpuSeconds = Self.cpuSeconds(
            samples: record.samples,
            startedAt: record.snapshot.startedAt,
            endedAt: nil
        )
        opened[agentKey] = record
        return record.snapshot
    }

    // MARK: - Settlement

    /// 结算一条打开中的会话：填齐 `endedAt` / 资源指标 / `estimatedTokens` / `outcome` 并移出索引。
    private func settle(agentKey: UUID, endAt rawEnd: Date, requested: SessionOutcome) -> AgentSession? {
        guard let record = opened.removeValue(forKey: agentKey) else { return nil }
        sessionIndex[record.snapshot.id] = nil
        if pidIndex[record.agentPID] == agentKey {
            pidIndex[record.agentPID] = nil
        }

        var session = record.snapshot
        let startedAt = session.startedAt
        session.endedAt = max(startedAt, rawEnd)
        session.cpuSeconds = Self.cpuSeconds(samples: record.samples, startedAt: startedAt, endedAt: session.endedAt)
        let peaks = Self.peaks(of: record.samples)
        session.peakCPUPercent = peaks.cpu
        session.peakMemoryBytes = peaks.memory

        let duration = session.endedAt.map { $0.timeIntervalSince(startedAt) } ?? 0
        session.estimatedTokens = tokenEstimator.estimate(
            session: session,
            until: session.endedAt ?? rawEnd
        )?.tokens ?? 0
        session.outcome = resolveOutcome(requested: requested, duration: duration, session: session, record: record)
        return session
    }

    /// `outcome` 判定，顺序见文件头「结算规则 2」。
    private func resolveOutcome(requested: SessionOutcome, duration: TimeInterval, session: AgentSession, record: Opened) -> SessionOutcome {
        if record.lastCommandFailed { return .failed }
        if requested == .failed { return .failed }
        if duration < configuration.minimumSessionSeconds { return .interrupted }
        guard requested == .running else { return requested }
        return Self.hasEvidence(session) ? .success : .unknown
    }

    /// 是否存在任何实测依据（文件 / 命令 / 采样 / 风险）。
    private static func hasEvidence(_ session: AgentSession) -> Bool {
        session.createdFileCount > 0 || session.modifiedFileCount > 0 || session.deletedFileCount > 0
            || session.commandCount > 0 || session.riskEventCount > 0
            || session.peakCPUPercent > 0 || session.peakMemoryBytes > 0 || session.cpuSeconds > 0
    }

    /// 新 agent → 打开会话。
    private func open(_ agent: AgentInstance, at date: Date) -> AgentSession {
        let index = nextDisplayIndex
        nextDisplayIndex += 1
        let startedAt = min(agent.startedAt, date)
        let session = AgentSession(
            id: UUID(),
            displayIndex: index,
            kind: agent.kind,
            agentID: agent.id,
            title: "\(agent.kind.displayName) · \(DateFormat.timestamp(startedAt))",
            projectPath: usableProjectPath(agent.workingDirectory),
            startedAt: startedAt,
            endedAt: nil,
            outcome: .running
        )
        opened[agent.id] = Opened(
            snapshot: session,
            agentPID: agent.pid,
            lastSeenAt: date,
            absentSince: nil,
            samples: [],
            lastCommandAt: nil,
            lastCommandFailed: false
        )
        sessionIndex[session.id] = agent.id
        pidIndex[agent.pid] = agent.id
        return session
    }

    /// 打开中的会话若尚未拿到项目路径，则用本轮 agent 快照补齐（同样要过可用性判据）。
    /// 只在 `projectPath == nil` 时补，已合法填好的值不会被更浅的 cwd 冲掉。
    private func backfill(_ session: inout AgentSession, from agent: AgentInstance) {
        guard session.projectPath == nil else { return }
        session.projectPath = usableProjectPath(agent.workingDirectory)
    }

    /// agent 虽在列表里，但其 `lastSeenAt` 已比本轮时刻陈旧超过 `idleTimeout`。
    private func isStale(_ agent: AgentInstance, at date: Date) -> Bool {
        guard agent.lastSeenAt <= date else { return false }
        return date.timeIntervalSince(agent.lastSeenAt) > configuration.idleTimeout
    }

    /// 本轮缺席是否已经该结算。
    ///
    /// 第一次缺席只把 `absentSince` 记成本轮时刻并返回 false（会话留在打开态）；
    /// 之后只有缺席满 `Configuration.absenceGrace` 才返回 true。
    /// `absenceGrace == 0` 表示不宽限：直接返回 true，与「第一次缺席即结算」的旧行为逐字一致。
    private func shouldSettleOnAbsence(_ record: inout Opened, at date: Date) -> Bool {
        guard configuration.absenceGrace > 0 else { return true }
        guard let firstAbsent = record.absentSince else {
            record.absentSince = date
            return false
        }
        return date.timeIntervalSince(firstAbsent) >= configuration.absenceGrace
    }

    /// 候选项目路径能不能写进 `AgentSession.projectPath`；判不出来返回 nil。
    ///
    /// 判据复用 `MonitoringRootResolver.isUsableAttributionRoot`（与监控面 / 归因面同一套），
    /// 不在这里另立标准。宁缺毋滥的理由：GUI Agent 主进程的 cwd 通常就是 `/`，
    /// 原样写进 `sessions.project_path` 会让 `ProjectMapper.aggregate` 把整台机器当成一个项目落库
    /// 并向界面广播——对审计工具来说那是假证据，比少一格归属更糟。
    private func usableProjectPath(_ candidate: String?) -> String? {
        guard let candidate, MonitoringRootResolver.isUsableAttributionRoot(candidate) else { return nil }
        return candidate
    }

    // MARK: - Lookup helpers

    /// 按 sessionID → agentID → 唯一 kind 匹配 的严格顺序解析归属。
    private func resolveAgentKey(sessionID: UUID?, agentID: UUID?, kind: AgentKind?) -> UUID? {
        if let sessionID {
            guard let key = sessionIndex[sessionID], opened[key] != nil else { return nil }
            return key
        }
        if let agentID {
            return opened[agentID] != nil ? agentID : nil
        }
        guard let kind else { return nil }
        let candidates = opened.filter { $0.value.snapshot.kind == kind }
        return candidates.count == 1 ? candidates.first?.key : nil
    }

    /// 命令是否失败：`outcome == .failure` 或 `exitCode != 0`。
    private func isFailure(_ command: CommandRecord) -> Bool {
        if command.outcome == .failure { return true }
        if let code = command.exitCode, code != 0 { return true }
        return false
    }

    // MARK: - Metrics helpers

    /// `Σ (cpuPercent / 100) × Δt`；规则见文件头「结算规则 3」。无样本 → 0。
    private static func cpuSeconds(samples: [Sample], startedAt: Date, endedAt: Date?) -> Double {
        guard !samples.isEmpty else { return 0 }
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        // 末样本收口位置：有 endedAt 用 endedAt，否则退化为末样本自身（该段贡献为 0）。
        let closeAt = endedAt ?? ordered[ordered.count - 1].timestamp
        var total = 0.0
        var cursor = startedAt
        for index in ordered.indices {
            let sample = ordered[index]
            let segmentEnd = (index == ordered.count - 1) ? closeAt : sample.timestamp
            let delta = segmentEnd.timeIntervalSince(cursor)
            if delta > 0, delta <= LifecycleConstants.maximumCreditedSampleInterval, sample.cpuPercent > 0 {
                total += (sample.cpuPercent / 100.0) * delta
            }
            cursor = sample.timestamp
        }
        guard total.isFinite, total > 0 else { return 0 }
        return total
    }

    /// 采样序列的 CPU / 内存峰值；无样本 → (0, 0)。
    private static func peaks(of samples: [Sample]) -> (cpu: Double, memory: UInt64) {
        var cpu = 0.0
        var memory: UInt64 = 0
        for sample in samples {
            if sample.cpuPercent > cpu { cpu = sample.cpuPercent }
            if sample.memoryBytes > memory { memory = sample.memoryBytes }
        }
        return (cpu, memory)
    }
}
