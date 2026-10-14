//
//  SwiftDataObservatoryStore.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-SwiftData
//
//  SwiftData 落库门面：actor。写入与辅助查询 API 与 SQLite 后端的
//  `AIObservatoryStore.ObservatoryStore` **同名同语义**，装配层因此可以一行切换。
//  13 个只读查询在 `SwiftDataObservatoryStore+Queries.swift`。
//
//  ── 严格并发（ADR-0001 当年据此把 SwiftData 排到第二阶段）──────────────────
//  `@Model` 记录与 `ModelContext`/`ModelContainer` 都不是 `Sendable`。处理方式：
//    · 容器与上下文是 actor 的 private 存储属性，**永不出现在任何 public 签名里**；
//    · 每个 public 方法只收/发 `AIObservatoryCore` 的值类型（`AgentSession`、`TimelineEvent`…）；
//    · 于是 `@Model` 无法跨过 actor 边界——不是靠约定，而是签名层面就没有这条路。
//  顺带一条硬约束：`#Predicate` 的宏展开要求**具体**的 `PersistentModel` 类型，
//  所以按 id 查记录的代码必须逐实体写（`agentRecord(id:)` 等），无法泛型化。
//
//  ── 事务口径 ────────────────────────────────────────────────────────────────
//  SQLite 侧的「多语句原子写 → `inTransaction`」在这里对应**一次 `context.save()`**：
//  actor 串行化保证一次调用内的多次 mutate 不被插队，而 `save()` 本身是一笔事务，
//  因此一次 `recordRisks(_:)`（风险全行覆盖 + 会话计数重算）仍是一笔原子提交。
//
//  ── 与 SQLite 后端的既有差异（显式，不静默降级）────────────────────────────
//  · `prune(olderThan:vacuum: true)` 抛 `ObservatoryError.unsupported`：SwiftData 不暴露
//    VACUUM。SQLite 会回收磁盘而这里不会，假装做了比不做更糟。
//  · upsert 落为「同 id 先删后插 + 一次 save」，语义等同 `INSERT … ON CONFLICT DO UPDATE`
//    （全列覆盖）。由 `SwiftDataPredicateCapabilityTests` 第 9 条钉住唯一约束不报错。
//

import Foundation
import os
import SwiftData
import AIObservatoryCore

/// SwiftData 落库门面 actor。
public actor SwiftDataObservatoryStore {

    // MARK: - 批量写策略与统计

    /// 高频 append 的缓冲策略；字段名与 `AIObservatoryStore.BatchWriter.Policy` 一致。
    public struct Policy: Sendable, Hashable {

        /// 单批最多攒多少条；达到即就地提交一次事务。
        public var maxStatementsInBatch: Int

        /// 定时器检查间隔（秒）。
        public var flushInterval: TimeInterval

        /// 定时器路径每次提交的最少行数（AGENTS.md §6「单次事务 ≥ 32 行」口径）。
        public var minRowsPerCommit: Int

        /// 缓冲硬延迟上限（秒）：最老一条超过它，即使行数不足也必须落盘。
        public var maxBufferAge: TimeInterval

        /// 创建策略；`minRowsPerCommit` 收敛为 ≥1，`maxBufferAge` 不小于 `flushInterval`。
        public init(
            maxStatementsInBatch: Int = 32,
            flushInterval: TimeInterval = 1,
            minRowsPerCommit: Int = 8,
            maxBufferAge: TimeInterval = 10
        ) {
            self.maxStatementsInBatch = maxStatementsInBatch
            self.flushInterval = flushInterval
            self.minRowsPerCommit = max(minRowsPerCommit, 1)
            // 兜底上限不得小于检查周期，否则定时器永远来不及看它。
            self.maxBufferAge = max(maxBufferAge, flushInterval)
        }

        /// 默认策略：32 条 / 1 秒（对齐性能预算表）。
        public static let standard = Policy()
    }

    /// 批量写运行期统计；字段名与 `AIObservatoryStore.BatchWriter.Stats` 一致。
    public struct Stats: Sendable, Hashable {

        /// 实际提交过的事务数（空缓冲的 flush 不计）。
        public var commitCount: Int

        /// 缓冲区里还没提交的行数。
        public var pendingCount: Int

        /// 累计 submit 进来的行数。
        public var totalSubmitted: Int

        /// 因违反约束而被逐条丢弃的行数（每条都记了日志）。
        public var droppedStatementCount: Int

        /// 全量成员初始化，默认全 0。
        public init(
            commitCount: Int = 0,
            pendingCount: Int = 0,
            totalSubmitted: Int = 0,
            droppedStatementCount: Int = 0
        ) {
            self.commitCount = commitCount
            self.pendingCount = pendingCount
            self.totalSubmitted = totalSubmitted
            self.droppedStatementCount = droppedStatementCount
        }
    }

    /// 一次保留期清理的结果；字段名与 `AIObservatoryStore.RetentionPruner.Result` 一致。
    public struct PruneResult: Sendable, Hashable {

        /// 实际使用的截止时间点（早于它的行被删除）。
        public var cutoff: Date

        /// 每张表删除的行数（含本次删了 0 行的表），key 用 SQLite 的表名口径。
        public var deletedRowsByTable: [String: Int]

        /// 是否执行了 VACUUM。SwiftData 后端恒为 false（请求 VACUUM 会直接抛错）。
        public var didVacuum: Bool

        /// 全量成员初始化。
        public init(cutoff: Date, deletedRowsByTable: [String: Int] = [:], didVacuum: Bool = false) {
            self.cutoff = cutoff
            self.deletedRowsByTable = deletedRowsByTable
            self.didVacuum = didVacuum
        }

        /// 所有表删除行数之和。
        public var totalDeletedRows: Int { deletedRowsByTable.values.reduce(0, +) }
    }

    /// 缓冲区内的一条待写记录：全部是 Core 的值类型，因此 `Sendable`。
    enum BufferedRow: Sendable {
        case event(TimelineEvent)
        case fileChange(FileChange)
        case command(CommandRecord)
        case performance(PerformanceSample)
        case systemPerformance(SystemPerformanceSample)
    }

    // MARK: - 状态

    private let container: ModelContainer

    /// internal 而非 private：同模块的 `+Queries` 扩展与迁移器要在 actor 的隔离域内
    /// 直接用它 fetch。它是 `non-Sendable`，本模块之外（App / Engine）看不到，
    /// 因此 `@Model` 记录依然出不了这个 target。
    let context: ModelContext

    private let policy: Policy
    private let url: URL?

    private var buffer: [BufferedRow] = []
    private var oldestBufferedAt: ContinuousClock.Instant?
    private var commitCount = 0
    private var totalSubmitted = 0
    private var droppedStatementCount = 0
    private var flushTask: Task<Void, Never>?

    /// 单批物化的行数上限：SwiftData 一次 fetch 会把整批 `@Model` 拉进内存，靠它钉住峰值。
    static let chunkSize = 500

    private let clock = ContinuousClock()

    // MARK: - 初始化

    /// 用现成容器构造。容器与 storeURL 由 `SwiftDataContainerFactory` 按配置决定，
    /// 这样配置错误在容器阶段就暴露，而不是等到第一次查询。
    init(container: ModelContainer, storeURL url: URL?, policy: Policy = .standard) {
        self.container = container
        self.context = ModelContext(container)
        self.url = url
        self.policy = policy
    }

    /// 打开（或创建）SwiftData 库并落地 schema。
    ///
    /// - Parameters:
    ///   - configuration: 落盘配置；`directory` 为空时使用内存库。
    ///   - policy: 缓冲写策略。
    /// - Throws: `ObservatoryError.storeUnavailable(_)` — 目录不可创建或容器初始化失败。
    public static func open(
        configuration: SwiftDataStoreConfiguration,
        policy: Policy = .standard
    ) async throws -> SwiftDataObservatoryStore {
        let container = try SwiftDataContainerFactory.makeContainer(configuration: configuration)
        return SwiftDataObservatoryStore(container: container, storeURL: configuration.storeURL, policy: policy)
    }

    /// store 文件位置；内存库返回 nil。
    ///
    /// 只暴露 URL（`Sendable`），不暴露 `container`/`context`：后者一旦外泄，
    /// 调用方就能拿到 `@Model` 记录并跨 actor 传递。
    public var fileURL: URL? { url }

    /// 是否为内存库（零磁盘写入）。
    public var isInMemory: Bool { url == nil }

    // MARK: - 生命周期

    /// 启动定时 flush 循环（幂等）。
    public func start() {
        guard flushTask == nil else { return }
        let interval = max(policy.flushInterval, 0.01)
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                if Task.isCancelled { return }
                await self?.timerTick()
            }
        }
    }

    /// 停止：取消定时循环 → 强制提交剩余缓冲（对齐 `ObservatoryStore.stop()` 的先 flush 语义）。
    public func stop() async {
        flushTask?.cancel()
        flushTask = nil
        commitBuffer()
    }

    /// 立即提交缓冲区里的全部待写行。
    public func flush() {
        commitBuffer()
    }

    /// 缓冲写通道统计：`commitCount` 验证攒批效果，`droppedStatementCount` 把
    /// 「有行始终写不进去」暴露给调用方，而不是只留在日志里。
    public func batchStats() -> Stats {
        Stats(
            commitCount: commitCount,
            pendingCount: buffer.count,
            totalSubmitted: totalSubmitted,
            droppedStatementCount: droppedStatementCount
        )
    }

    /// 定时器：攒够 `minRowsPerCommit` 或最老一条超过 `maxBufferAge` 才提交，否则继续攒。
    private func timerTick() {
        guard !buffer.isEmpty else { return }
        if buffer.count >= policy.minRowsPerCommit {
            commitBuffer()
            return
        }
        if let oldestBufferedAt,
           oldestBufferedAt.duration(to: .now) >= .seconds(policy.maxBufferAge) {
            commitBuffer()
        }
    }

    // MARK: - 立即提交的写入

    /// 全行覆盖式 upsert agents。空数组直接返回。
    public func upsertAgents(_ agents: [AgentInstance]) async throws {
        guard !agents.isEmpty else { return }
        for agent in agents {
            let text = agent.id.uuidString
            if let existing = try agentRecord(id: text) { context.delete(existing) }
            context.insert(SDAgent(agent))
            flushPendingChanges()
        }
        try save()
    }

    /// 覆盖式 upsert sessions，**但 `riskEventCount` 这一列例外**：它只有一个写入者
    /// （`recalculateRiskCounts(for:)` 那条派生重算，与 SQLite 侧 `SQL.recomputeSessionRiskCount`
    /// 同一条语义）。整行覆盖（删+插）会连那一列一起写脏，历史上就是这么把派生值盖成自增值的。
    ///
    /// 与 SQLite 侧一致：先落行、再在同一处按 `risk_events` 的实际行数重算 ⇒ 与调用顺序无关。
    public func upsertSessions(_ sessions: [AgentSession]) async throws {
        guard !sessions.isEmpty else { return }
        for session in sessions {
            let text = session.id.uuidString
            if let existing = try sessionRecord(id: text) { context.delete(existing) }
            context.insert(SDSession(session))
            flushPendingChanges()
        }
        try recalculateRiskCounts(for: Set(sessions.map(\.id)))
        try save()
    }

    /// 全行覆盖式 upsert projects。空数组直接返回。
    public func upsertProjects(_ projects: [ProjectActivity]) async throws {
        guard !projects.isEmpty else { return }
        for project in projects {
            let text = project.id
            if let existing = try projectRecord(id: text) { context.delete(existing) }
            context.insert(SDProject(project))
            flushPendingChanges()
        }
        try save()
    }

    /// 记录风险事件（全行覆盖 upsert），并按 sessionID 重算 `riskEventCount`；全部一笔提交。
    ///
    /// 与 SQLite 侧一致的两条语义：
    ///   · `isAcknowledged` **单调为真**（SQL 侧写作 `is_acknowledged = MAX(old, new)`）：
    ///     已确认的风险被再次采集命中时不得退回未确认——那会让用户以为冒出了新风险。
    ///   · 计数是**重算**而非自增，因此同一批风险重复录入不会翻倍。
    public func recordRisks(_ risks: [RiskEvent]) async throws {
        guard !risks.isEmpty else { return }
        for risk in risks {
            let existing = try riskRecord(id: risk.id.uuidString)
            var value = risk
            value.isAcknowledged = (existing?.isAcknowledged ?? false) || risk.isAcknowledged
            if let existing { context.delete(existing) }
            context.insert(SDRiskEvent(value))
            flushPendingChanges()
        }
        // 上面的 processPendingChanges 保证下面的计数看得见本批刚插入的风险行。
        try recalculateRiskCounts(for: Set(risks.compactMap(\.sessionID)))
        try save()
    }

    /// `sessions.riskEventCount` 的**唯一**写入者：按 `risk_events` 的实际行数重算。
    ///
    /// 去重 + 稳定排序后再逐条写：与 SQLite 侧 `Set(...).sorted(uuidString)` 同一口径，
    /// 因此两个后端在同一批输入下走同一顺序、得到同一个数。
    /// 调用方需保证风险行已可见（`upsertSessions` 里的 `flushPendingChanges` /
    /// `recordRisks` 里的同一处理）。
    private func recalculateRiskCounts(for sessionIDs: Set<UUID>) throws {
        for sessionID in sessionIDs.sorted(by: uuidTextLessThan) {
            let text = sessionID.uuidString
            let count = try context.fetchCount(FetchDescriptor<SDRiskEvent>(
                predicate: #Predicate { $0.sessionID == text }
            ))
            if let session = try sessionRecord(id: text) {
                session.riskEventCount = count
            }
        }
    }

    /// 将某条风险标记为已确认（`isAcknowledged = true`）；id 不存在时静默无操作。
    public func acknowledgeRisk(id: UUID) async throws {
        guard let record = try riskRecord(id: id.uuidString) else { return }
        record.isAcknowledged = true
        try save()
    }

    /// 收敛仍开放的命令。语义与 SQLite 后端逐字一致（契约见 `ObservatoryWriting`）：
    /// 只改「`outcome == running` 且 `endedAt == nil`」的行 ⇒ hook 先闭合过的不会被改写。
    ///
    /// ⚠️ 谓词只放**两个子句**：`#Predicate` 在本项目实测过超过约 6 个子句就编译失败的坑，
    /// 而 `agentID` / `sessionID` 是"可空才加"的条件，写进谓词会变成 4 个版本。
    /// 因此这里用最小谓词取开放行，再在 Swift 侧按可选条件过滤——行数极少（一个 Agent 的命令），
    /// 不值得为它把谓词撑大。
    @discardableResult
    public func terminateOpenCommands(
        agentID: UUID?,
        sessionID: UUID?,
        outcome: CommandOutcome,
        endedAt: Date
    ) async throws -> Int {
        let running = CommandOutcome.running.rawValue
        let open: [SDCommand] = try context.fetch(FetchDescriptor<SDCommand>(
            predicate: #Predicate<SDCommand> { command in
                command.outcome == running && command.endedAt == nil
            }
        ))
        var changed = 0
        for command in open {
            if let agentID, command.agentID != agentID.uuidString { continue }
            if let sessionID, command.sessionID != sessionID.uuidString { continue }
            command.outcome = outcome.rawValue
            command.endedAt = endedAt
            changed += 1
        }
        if changed > 0 { try save() }   // 幂等：没有匹配行时不产生写入
        return changed
    }

    /// 记录某次文件变更的 diff（`changeID` 唯一，覆盖式）。
    ///
    /// **约定与 SQLite 后端相同**：`FileDiff.id` 必须等于 `changeID`
    /// （参考实现 `InMemoryObservatoryService` 用 `diff.id` 当 changeID 索引，
    /// 两者不等时同一入参会在两边得到不同结果）。
    public func record(_ diff: FileDiff, forChangeID changeID: UUID) async throws {
        if let existing = try diffRecord(changeID: changeID.uuidString) { context.delete(existing) }
        context.insert(SDDiff(diff, changeID: changeID))
        try save()
    }

    /// 记录文件内容快照（哈希/大小/行数），覆盖同 id 旧行。
    public func recordSnapshot(_ snapshot: FileSnapshot) async throws {
        if let existing = try snapshotRecord(id: snapshot.id.uuidString) { context.delete(existing) }
        context.insert(SDFileSnapshot(snapshot))
        try save()
    }

    // MARK: - 缓冲写

    /// 缓冲写入一条时间线事件（满批或定时提交）。
    public func append(_ event: TimelineEvent) {
        submit(.event(event))
    }

    /// 缓冲写入一条文件变更。
    public func append(_ change: FileChange) {
        submit(.fileChange(change))
    }

    /// 缓冲写入一条命令记录。
    public func append(_ command: CommandRecord) {
        submit(.command(command))
    }

    /// 缓冲写入一条会话性能采样。
    public func append(_ sample: PerformanceSample) {
        submit(.performance(sample))
    }

    /// 缓冲写入一条整机性能采样。
    public func append(_ sample: SystemPerformanceSample) {
        submit(.systemPerformance(sample))
    }

    // MARK: - 辅助查询

    /// 活跃 Agent（state 为 running 或 idle，与 `InMemoryObservatoryService` 口径一致）；
    /// 无法还原的行被丢弃。
    public func activeAgents() async throws -> [AgentInstance] {
        let running = AgentRunState.running.rawValue
        let idle = AgentRunState.idle.rawValue
        let records = try context.fetch(FetchDescriptor<SDAgent>(
            predicate: #Predicate { $0.state == running || $0.state == idle },
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse), SortDescriptor(\.rowID)]
        ))
        return records.compactMap { $0.domainValue() }
    }

    /// 未结算（`endedAt == nil`）会话数。
    public func openSessionCount() async throws -> Int {
        try context.fetchCount(FetchDescriptor<SDSession>(predicate: #Predicate { $0.endedAt == nil }))
    }

    /// 把所有未结算会话结算为 `.interrupted`（`endedAt = date`），返回受影响条数。
    ///
    /// 分块推进：每块结算后就退出 `endedAt == nil` 的命中集，因此不会一次物化全部会话。
    public func markRunningSessionsInterrupted(at date: Date) async throws -> Int {
        let outcome = SessionOutcome.interrupted.rawValue
        var changed = 0
        while true {
            var descriptor = FetchDescriptor<SDSession>(predicate: #Predicate { $0.endedAt == nil })
            descriptor.fetchLimit = Self.chunkSize
            let records = try context.fetch(descriptor)
            if records.isEmpty { break }
            for record in records {
                record.endedAt = date
                record.outcome = outcome
            }
            changed += records.count
            try save()
            if records.count < Self.chunkSize { break }
        }
        return changed
    }

    /// 时间窗内 `kind == deleted` 的文件变更数（风险窗口用）；sessionID 为 nil 时统计全部会话。
    public func deletedFileChangeCount(sessionID: UUID?, from: Date, to: Date) async throws -> Int {
        try countFileChanges(sessionID: sessionID, from: from, to: to, kind: FileChangeKind.deleted.rawValue)
    }

    /// 时间窗内文件变更总数；sessionID 为 nil 时统计全部会话。
    public func fileChangeCount(sessionID: UUID?, from: Date, to: Date) async throws -> Int {
        try countFileChanges(sessionID: sessionID, from: from, to: to, kind: "")
    }

    /// 清空所有表（按 `prunable` 先子后父顺序，逐表提交）。测试装配用。
    public func deleteAllData() async throws {
        for entity in ObservatorySchema.prunable {
            try deleteEverything(of: entity)
        }
        try save()
    }

    /// 指定表行数；表名必须在 `ObservatorySchema.allTableNames` 白名单内。
    ///
    /// - Throws: `ObservatoryError.invalidQuery(_)` — 表名不在白名单。
    public func rowCount(table: String) async throws -> Int {
        guard let entity = ObservatorySchema.prunable.first(where: { $0.tableName == table }) else {
            throw ObservatoryError.invalidQuery("rowCount: unknown table '\(table)'")
        }
        switch entity {
        case .fileSnapshots: return try countRows(of: SDFileSnapshot.self)
        case .diffs:         return try countRows(of: SDDiff.self)
        case .perfSamples:   return try countRows(of: SDPerformanceSample.self)
        case .events:        return try countRows(of: SDEvent.self)
        case .fileChanges:   return try countRows(of: SDFileChange.self)
        case .commands:      return try countRows(of: SDCommand.self)
        case .riskEvents:    return try countRows(of: SDRiskEvent.self)
        case .systemPerf:    return try countRows(of: SDSystemPerformanceSample.self)
        case .sessions:      return try countRows(of: SDSession.self)
        case .agents:        return try countRows(of: SDAgent.self)
        case .projects:      return try countRows(of: SDProject.self)
        }
    }

    /// 删除 cutoff 之前的行（顺序同 SQLite 的 `StoreSchema.prunable`：先子后父）。
    ///
    /// - Parameters:
    ///   - cutoff: 截止时间点，早于它的行被删除（与 SQL 侧 `col < ?` 同为严格小于）。
    ///   - vacuum: 必须为 false；SwiftData 不暴露 VACUUM。
    /// - Throws: `ObservatoryError.unsupported(_)` — 要求 VACUUM 时。
    ///   SQLite 后端会回收磁盘而本后端不会，静默返回会让调用方以为空间已回收。
    public func prune(olderThan cutoff: Date, vacuum: Bool) async throws -> PruneResult {
        if vacuum {
            throw ObservatoryError.unsupported(
                "SwiftData 后端不暴露 VACUUM；需要回收磁盘请切回 SQLite 后端"
            )
        }
        var deleted: [String: Int] = [:]
        // 先记下「将被删掉的风险行属于哪些会话」：`riskEventCount` 的唯一写入者是那条派生重算，
        // 删完不重算就会把计数停在偏大的旧值上（与 SQLite 侧 `prune` 同一条语义）。
        let touchedSessions = try riskSessionIDs(olderThan: cutoff)
        for entity in ObservatorySchema.prunable {
            deleted[entity.tableName] = try prune(entity, olderThan: cutoff)
        }
        if deleted[SwiftDataEntity.riskEvents.tableName, default: 0] > 0 {
            try recalculateRiskCounts(for: touchedSessions)
        }
        try save()
        return PruneResult(cutoff: cutoff, deletedRowsByTable: deleted, didVacuum: false)
    }

    /// 截止时间之前还活着的那些风险行所归属的会话集合（供 `prune` 之后重算计数用）。
    private func riskSessionIDs(olderThan cutoff: Date) throws -> Set<UUID> {
        let stale = try context.fetch(FetchDescriptor<SDRiskEvent>(
            predicate: #Predicate { $0.timestamp < cutoff }
        ))
        return Set(stale.compactMap { UUID(uuidString: $0.sessionID ?? "") })
    }

    /// 按 id 覆盖式写入时间线事件：同一 id 只留一行。
    ///
    /// 与 SQLite 侧 `upsertEvents(_:)` 同一条语义，存在的理由也一样——
    /// `.riskDetected` 那一行的 id 由 `RiskEvent.id` 确定性派生，同一 finding 被重评再产出时
    /// 应当**刷那一行**，而不是每次多一行时间线。普通事件仍走只插入的 `append(_:)`。
    public func upsertEvents(_ events: [TimelineEvent]) async throws {
        try replaceEvents(events)
    }

    // MARK: - 迁移专用（internal，不是公共 API）
    //
    // `append` 系列是「只插入」语义（与 SQLite 侧 `INSERT INTO events` 一致：约束违规要冒出来），
    // 因此不能直接用于迁移——重跑一次就会重复落库。`SwiftDataMigrator` 需要的是
    // 「同 id 覆盖」，而 SQLite 后端里那 5 张表根本没有 upsert，所以这个差异只存在于
    // 本模块内部，不污染两个后端的公共 API 对照。

    /// 先删同 id 旧行、再整批插入，一笔提交 → 重复迁移不产生重复行。
    func replaceEvents(_ values: [TimelineEvent]) throws {
        guard !values.isEmpty else { return }
        let ids = values.map { $0.id.uuidString }
        try deleteMatching(#Predicate<SDEvent> { event in ids.contains(event.rowID) })
        for value in values { context.insert(SDEvent(value)) }
        try save()
    }

    /// 见 `replaceEvents(_:)`。
    func replaceFileChanges(_ values: [FileChange]) throws {
        guard !values.isEmpty else { return }
        let ids = values.map { $0.id.uuidString }
        try deleteMatching(#Predicate<SDFileChange> { change in ids.contains(change.rowID) })
        for value in values { context.insert(SDFileChange(value)) }
        try save()
    }

    /// 见 `replaceEvents(_:)`。
    func replaceCommands(_ values: [CommandRecord]) throws {
        guard !values.isEmpty else { return }
        let ids = values.map { $0.id.uuidString }
        try deleteMatching(#Predicate<SDCommand> { command in ids.contains(command.rowID) })
        for value in values { context.insert(SDCommand(value)) }
        try save()
    }

    /// 见 `replaceEvents(_:)`。
    func replacePerformanceSamples(_ values: [PerformanceSample]) throws {
        guard !values.isEmpty else { return }
        let ids = values.map { $0.id.uuidString }
        try deleteMatching(#Predicate<SDPerformanceSample> { sample in ids.contains(sample.rowID) })
        for value in values { context.insert(SDPerformanceSample(value)) }
        try save()
    }

    /// 见 `replaceEvents(_:)`。
    func replaceSystemPerformance(_ values: [SystemPerformanceSample]) throws {
        guard !values.isEmpty else { return }
        let ids = values.map { $0.id.uuidString }
        try deleteMatching(#Predicate<SDSystemPerformanceSample> { sample in ids.contains(sample.rowID) })
        for value in values { context.insert(SDSystemPerformanceSample(value)) }
        try save()
    }

    // MARK: - 私有：单实体记录查找
    //
    // `#Predicate` 只能对**具体** `PersistentModel` 类型展开，所以下面这组函数
    // 无法收敛成一个泛型 helper——这是 SwiftData 的既有限制，不是偷懒。
    // 本 SDK 的 `ModelContext` 没有 `fetchOne`，因此用 `fetchLimit = 1` + `first`。

    private func agentRecord(id text: String) throws -> SDAgent? {
        try firstMatch(of: SDAgent.self) { #Predicate { $0.rowID == text } }
    }

    private func sessionRecord(id text: String) throws -> SDSession? {
        try firstMatch(of: SDSession.self) { #Predicate { $0.rowID == text } }
    }

    private func projectRecord(id text: String) throws -> SDProject? {
        try firstMatch(of: SDProject.self) { #Predicate { $0.rowID == text } }
    }

    private func riskRecord(id text: String) throws -> SDRiskEvent? {
        try firstMatch(of: SDRiskEvent.self) { #Predicate { $0.rowID == text } }
    }

    private func diffRecord(changeID text: String) throws -> SDDiff? {
        try firstMatch(of: SDDiff.self) { #Predicate { $0.changeID == text } }
    }

    private func snapshotRecord(id text: String) throws -> SDFileSnapshot? {
        try firstMatch(of: SDFileSnapshot.self) { #Predicate { $0.rowID == text } }
    }

    /// 按 predicate 取一行（`fetchLimit = 1`，不做全表物化）。
    private func firstMatch<Model: PersistentModel>(
        of type: Model.Type,
        _ build: () -> Predicate<Model>
    ) throws -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: build())
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    // MARK: - 私有：计数与批量删除

    private func countFileChanges(sessionID: UUID?, from: Date, to: Date, kind: String) throws -> Int {
        // 空串 = 该维度不过滤（哨兵），与查询扩展里的 `addIn`/`addEqual` 口径一致。
        let sessionText = sessionID?.uuidString ?? ""
        let kindText = kind
        return try context.fetchCount(FetchDescriptor<SDFileChange>(
            predicate: #Predicate { change in
                change.timestamp >= from
                    && change.timestamp <= to
                    && (kindText.isEmpty || change.kind == kindText)
                    && (sessionText.isEmpty || change.sessionID == sessionText)
            }
        ))
    }

    private func countRows<Model: PersistentModel>(of type: Model.Type) throws -> Int {
        try context.fetchCount(FetchDescriptor<Model>())
    }

    /// 统计并删除匹配 predicate 的行，返回删除条数。
    ///
    /// 用 `ModelContext.delete(model:where:)`：删除在存储层执行，不像 `fetch` 那样
    /// 把每行物化成 `@Model`。先 `fetchCount` 才能报出条数——批量删除本身只返回 Void。
    @discardableResult
    private func deleteMatching<Model: PersistentModel>(
        _ predicate: Predicate<Model>
    ) throws -> Int {
        let matched = try context.fetchCount(FetchDescriptor<Model>(predicate: predicate))
        guard matched > 0 else { return 0 }
        try context.delete(model: Model.self, where: predicate)
        return matched
    }

    private func deleteEverything<Model: PersistentModel>(of type: Model.Type) throws {
        try context.delete(model: type)
    }

    private func deleteEverything(of entity: SwiftDataEntity) throws {
        switch entity {
        case .fileSnapshots: try deleteEverything(of: SDFileSnapshot.self)
        case .diffs:         try deleteEverything(of: SDDiff.self)
        case .perfSamples:   try deleteEverything(of: SDPerformanceSample.self)
        case .events:        try deleteEverything(of: SDEvent.self)
        case .fileChanges:   try deleteEverything(of: SDFileChange.self)
        case .commands:      try deleteEverything(of: SDCommand.self)
        case .riskEvents:    try deleteEverything(of: SDRiskEvent.self)
        case .systemPerf:    try deleteEverything(of: SDSystemPerformanceSample.self)
        case .sessions:      try deleteEverything(of: SDSession.self)
        case .agents:        try deleteEverything(of: SDAgent.self)
        case .projects:      try deleteEverything(of: SDProject.self)
        }
    }

    private func prune(_ entity: SwiftDataEntity, olderThan cutoff: Date) throws -> Int {
        switch entity {
        case .fileSnapshots: return try deleteMatching(#Predicate<SDFileSnapshot> { $0.capturedAt < cutoff })
        case .diffs:         return try deleteMatching(#Predicate<SDDiff> { $0.capturedAt < cutoff })
        case .perfSamples:   return try deleteMatching(#Predicate<SDPerformanceSample> { $0.timestamp < cutoff })
        case .events:        return try deleteMatching(#Predicate<SDEvent> { $0.timestamp < cutoff })
        case .fileChanges:   return try deleteMatching(#Predicate<SDFileChange> { $0.timestamp < cutoff })
        case .commands:      return try deleteMatching(#Predicate<SDCommand> { $0.startedAt < cutoff })
        case .riskEvents:    return try deleteMatching(#Predicate<SDRiskEvent> { $0.timestamp < cutoff })
        case .systemPerf:    return try deleteMatching(#Predicate<SDSystemPerformanceSample> { $0.timestamp < cutoff })
        case .sessions:      return try deleteMatching(#Predicate<SDSession> { $0.startedAt < cutoff })
        case .agents:        return try deleteMatching(#Predicate<SDAgent> { $0.lastSeenAt < cutoff })
        case .projects:      return try deleteMatching(#Predicate<SDProject> { $0.lastSeenAt < cutoff })
        }
    }

    // MARK: - 私有：缓冲

    private func submit(_ row: BufferedRow) {
        if buffer.isEmpty { oldestBufferedAt = clock.now }
        buffer.append(row)
        totalSubmitted += 1
        if buffer.count >= max(policy.maxStatementsInBatch, 1) { commitBuffer() }
    }

    private func insert(_ row: BufferedRow) {
        switch row {
        case .event(let value):            context.insert(SDEvent(value))
        case .fileChange(let value):       context.insert(SDFileChange(value))
        case .command(let value):          context.insert(SDCommand(value))
        case .performance(let value):      context.insert(SDPerformanceSample(value))
        case .systemPerformance(let value): context.insert(SDSystemPerformanceSample(value))
        }
    }

    /// 提交缓冲：一次 `save()` 即一笔事务；整批失败时逐条重投，只丢真正违规的那行。
    ///
    /// 逐条重投与 `BatchWriter` 同策：一条坏数据不该连坐一整批，
    /// 但也不能静默消失——丢弃条数累加进 `droppedStatementCount` 供调用方告警。
    private func commitBuffer() {
        guard !buffer.isEmpty else { return }
        let rows = buffer
        buffer.removeAll(keepingCapacity: true)
        oldestBufferedAt = nil
        for row in rows { insert(row) }
        do {
            try context.save()
            commitCount += 1
        } catch {
            context.rollback()
            var dropped = 0
            for row in rows {
                insert(row)
                do {
                    try context.save()
                    commitCount += 1
                } catch {
                    context.rollback()
                    dropped += 1
                    ObservatoryLog.store.error(
                        "SwiftData append 丢弃一行：\(error.localizedDescription, privacy: .public)"
                    )
                }
            }
            droppedStatementCount += dropped
        }
    }

    private func save() throws {
        try context.save()
    }

    /// 让挂起的插入/删除对后续 fetch 可见——仍是一笔事务（`save()` 才是提交点）。
    ///
    /// 不加这一步，同一批里出现重复 id 时，第二行的「查旧行」看不到第一行刚插入的行，
    /// 于是插出两条同 unique id 的记录，最后在 `save()` 上炸成约束违规；
    /// 而 SQLite 侧的 `ON CONFLICT DO UPDATE` 是「后者覆盖前者」，静默成功。
    /// 两个后端对同一批输入给出不同结果，正是本工作流要消灭的那类差异。
    private func flushPendingChanges() {
        context.processPendingChanges()
    }
}

/// UUID 的稳定排序口径（与 SQLite 侧按 `uuidString` 字典序一致）。
func uuidTextLessThan(_ lhs: UUID, _ rhs: UUID) -> Bool {
    lhs.uuidString < rhs.uuidString
}

// MARK: - 契约符合
//
// 写侧走 `ObservatoryWriting`（Core，IFR-swiftdata-write-protocol 已被总控采纳），
// 读侧走 `ObservatoryService`（在同模块的 `+Queries` 扩展里声明）。
// 两者合起来意味着装配层可以真的「一行切换」：
//
//     let store: any ObservatoryService & ObservatoryWriting = switch backend {
//     case .sqlite:    try await ObservatoryStore.open(configuration: …)
//     case .swiftData: try await SwiftDataObservatoryStore.open(configuration: …)
//     }
//
// 本文件里的 `start()` / `flush()` / `append(_:)` 都是**非 async** 的 actor 成员，
// 满足协议里声明为 `async` 的要求——actor 隔离本身就意味着调用点要 `await`，
// 所以两侧调用形状完全一致。
extension SwiftDataObservatoryStore: ObservatoryWriting {}
