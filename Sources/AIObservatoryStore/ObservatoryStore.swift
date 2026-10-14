//
//  ObservatoryStore.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine
//  Sub-owner: B
//
//  SQLite 落库门面：actor，符合 ObservatoryService。
//  本文件负责 init / open / 生命周期 / 全部写入 API / 全部辅助 API。
//  13 个只读查询（dashboardStats 等）在 ObservatoryStore+Queries.swift（Sub-owner: E）。
//
//  写路径规则（INTERFACE.md §5）：
//    · 多语句原子写 → `database.inTransaction([...])`；单条写 → `database.execute([...])`。
//    · append(_:) 系列把 INSERT 交给 BatchWriter.submit，不自己开事务。
//    · 所有 SQL 参数化（? 绑定），零拼接用户输入。
//    · search_text 在写入侧用 Swift `.lowercased()` 预计算，逐字对齐 InMemoryObservatoryService。
//

import Foundation
import os
import AIObservatoryCore

/// SQLite 落库门面 actor：写入立即提交或经 BatchWriter 缓冲，查询由同模块扩展提供。
public actor ObservatoryStore: ObservatoryService {

    private let db: SQLiteDatabase
    private let writer: BatchWriter

    /// 用现成连接构造 Store；`batchPolicy` 控制缓冲写通道攒批策略。
    ///
    /// **内部**：`init` 不会（也无法同步地）跑迁移，只经 `open(configuration:)` 暴露给外部，
    /// 否则调用方很容易拿到一个「零张表」的 Store，错误要到第一次查询才以 `no such table` 浮现。
    init(database: SQLiteDatabase, batchPolicy: BatchWriter.Policy = .init()) {
        self.db = database
        self.writer = BatchWriter(database: database, policy: batchPolicy)
    }

    /// 打开（或创建）数据库、应用 StoreSchema 迁移；失败时关闭连接并抛 `ObservatoryError.storeUnavailable`。
    public static func open(
        configuration: SQLiteDatabase.Configuration,
        batchPolicy: BatchWriter.Policy = .init()
    ) async throws -> ObservatoryStore {
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(configuration: configuration)
        } catch {
            throw ObservatoryError.storeUnavailable("open failed: \(error.localizedDescription)")
        }
        do {
            _ = try await database.applyMigrations(StoreSchema.migrations)
        } catch {
            await database.close()
            throw ObservatoryError.storeUnavailable("migration failed: \(error.localizedDescription)")
        }
        return ObservatoryStore(database: database, batchPolicy: batchPolicy)
    }

    /// 底层连接（actor 同步属性；跨 actor 调用需 `await store.database`）。E 的查询扩展依赖此入口。
    public var database: SQLiteDatabase { db }

    // MARK: - 生命周期

    /// 启动 BatchWriter 的定时 flush 循环（幂等）。
    public func start() async {
        await writer.start()
    }

    /// 停止：强制 flush 缓冲 → 取消定时循环 → WAL checkpoint（checkpoint 失败仅记日志）。
    public func stop() async {
        await writer.stop()
        do {
            try await db.checkpoint()
        } catch {
            ObservatoryLog.store.error(
                "checkpoint on stop failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    /// 立即提交缓冲区里的全部待写语句。
    public func flush() async {
        await writer.flush()
    }

    /// 批量写通道统计：`commitCount` 验证攒批效果，`droppedStatementCount` 把
    /// 「有语句始终写不进去」暴露给调用方（引擎据此告警，不靠日志翻找）。
    public func batchStats() async -> BatchWriter.Stats {
        await writer.stats
    }

    // MARK: - 立即提交的写入

    /// 全列覆盖式 upsert agents（INSERT … ON CONFLICT(id) DO UPDATE）。空数组直接返回。
    public func upsertAgents(_ agents: [AgentInstance]) async throws {
        guard !agents.isEmpty else { return }
        try await db.inTransaction(agents.map { Self.upsertAgentStatement($0) })
    }

    /// 覆盖式 upsert sessions，**但 `risk_event_count` 这一列例外**：它只有一个写入者
    /// （本方法与 `recordRisks` 共用的那条派生重算），整行覆盖不会把调用方携带的数字写进去。
    ///
    /// 为什么：`SessionLifecycleManager` 的自增快照曾在风险落库之后再把会话整行 upsert 一遍，
    /// 于是同一 finding 每重发一次计数就 +1——真机 `sessions.risk_event_count = 40`
    /// 而该会话名下 `risk_events` 只有 5 行（`03-进度日志` 里那条 P0）。
    /// 重算排在同一笔事务里 ⇒ 与调用顺序无关：先落会话还是先落风险都得到同一个数。
    public func upsertSessions(_ sessions: [AgentSession]) async throws {
        guard !sessions.isEmpty else { return }
        var statements = sessions.map { Self.upsertSessionStatement($0) }
        let sessionIDs = Set(sessions.map(\.id)).sorted { $0.uuidString < $1.uuidString }
        statements.append(SQLiteStatement(
            SQL.recomputeSessionRiskCount(sessionIDCount: sessionIDs.count),
            arguments: sessionIDs.map { .text($0.uuidString) }
        ))
        try await db.inTransaction(statements)
    }

    /// 全列覆盖式 upsert projects（JSON 列存 agent 贡献与热文件）。空数组直接返回。
    public func upsertProjects(_ projects: [ProjectActivity]) async throws {
        guard !projects.isEmpty else { return }
        try await db.inTransaction(projects.map { Self.upsertProjectStatement($0) })
    }

    /// 记录风险事件（按 id upsert），并把涉及会话的 `sessions.risk_event_count` **重算**
    /// （不是自增）成该会话名下的风险行数；全部同一事务。
    ///
    /// 这条重算就是那一列的唯一写入者（`upsertSessions` 走同一条 SQL，见其注释）。
    public func recordRisks(_ risks: [RiskEvent]) async throws {
        guard !risks.isEmpty else { return }
        var statements: [SQLiteStatement] = risks.map { Self.upsertRiskStatement($0) }
        // 去重 + 排序：同一事务内语句顺序确定，且重复录入只会派生出同一个计数。
        let sessionIDs = Set(risks.compactMap { $0.sessionID })
            .sorted { $0.uuidString < $1.uuidString }
        if !sessionIDs.isEmpty {
            statements.append(SQLiteStatement(
                SQL.recomputeSessionRiskCount(sessionIDCount: sessionIDs.count),
                arguments: sessionIDs.map { .text($0.uuidString) }
            ))
        }
        try await db.inTransaction(statements)
    }

    /// 将某条风险标记为已确认（`is_acknowledged = 1`）；id 不存在时静默 0 行更新。
    public func acknowledgeRisk(id: UUID) async throws {
        _ = try await db.execute([SQLiteStatement(SQL.acknowledgeRisk, arguments: [.text(id.uuidString)])])
    }

    /// 收敛仍开放的命令（契约见 `ObservatoryWriting.terminateOpenCommands`）。
    ///
    /// 谓词写死成「`outcome = 'running'` 且 `ended_at IS NULL`」，
    /// 所以**已经由 hook 闭合过的行绝不会被改写**——hook 的退出码优先级更高，
    /// 这条只是"进程都不见了，还挂着运行中"的兜底。
    /// 所有值都走绑定占位符（包括那个 `'running'`），SQL 文本里不拼任何外部数据。
    @discardableResult
    public func terminateOpenCommands(
        agentID: UUID?,
        sessionID: UUID?,
        outcome: CommandOutcome,
        endedAt: Date
    ) async throws -> Int {
        var sql = """
            UPDATE commands
               SET outcome = ?, ended_at = ?
             WHERE outcome = ? AND ended_at IS NULL
            """
        var arguments: [SQLiteValue] = [
            .text(outcome.rawValue),
            StoreValues.date(endedAt),
            .text(CommandOutcome.running.rawValue),
        ]
        if let agentID {
            sql += " AND agent_id = ?"
            arguments.append(.text(agentID.uuidString))
        }
        if let sessionID {
            sql += " AND session_id = ?"
            arguments.append(.text(sessionID.uuidString))
        }
        return try await db.execute([SQLiteStatement(sql, arguments: arguments)])
    }

    /// 记录某次文件变更的 diff（`change_id` 唯一，INSERT OR REPLACE）。
    ///
    /// **约定（审计 P2-9）**：`FileDiff.id` 必须等于 `changeID`。参考实现
    /// `InMemoryObservatoryService` 用 `diff.id` 当 changeID 索引，若两者不等，
    /// 同一入参会在两边得到不同结果；`StoreParityTests` 已按此约定断言。
    public func record(_ diff: FileDiff, forChangeID changeID: UUID) async throws {
        _ = try await db.execute([Self.insertDiffStatement(diff, changeID: changeID)])
    }

    /// 记录文件内容快照（哈希/大小/行数），落入 `file_snapshots` 表（INSERT OR REPLACE）。
    public func recordSnapshot(_ snapshot: FileSnapshot) async throws {
        _ = try await db.execute([Self.insertSnapshotStatement(snapshot)])
    }

    /// 按 id 覆盖式 upsert 时间线事件（立即提交，不走缓冲）。
    ///
    /// 存在的理由只有一件事：**身份来自被派生对象的那些行**。`.riskDetected` 的 id 由
    /// `RiskEvent.id` 确定性算出，而同一条 finding 在证据滑出保留窗后会被再产出一次
    /// （`RiskPipeline` 的「跨窗可再告警」）。用只插入的 `append(_:)` 写它，每重发一次
    /// 就多一行时间线——真机一条「内存峰值超限」在 `events` 里盖了 **43** 行，
    /// 而 `risk_events` 同一条只有 2 行（时间线被刷屏就是那么来的）。
    ///
    /// 与 `append(_:)` 的分工照旧：随机 id 的普通事件仍是「只插入、约束违规要冒出来」，
    /// 不把幂等当成为所有事件关掉那层保护。
    public func upsertEvents(_ events: [TimelineEvent]) async throws {
        guard !events.isEmpty else { return }
        try await db.inTransaction(events.map { SQLiteStatement(SQL.upsertEvent, arguments: Self.eventArguments($0)) })
    }

    // MARK: - 缓冲写（BatchWriter 路径）

    /// 缓冲写入一条时间线事件（INSERT OR IGNORE，满批或定时提交）。
    public func append(_ event: TimelineEvent) async {
        await writer.submit(Self.insertEventStatement(event))
    }

    /// 缓冲写入一条文件变更。
    public func append(_ change: FileChange) async {
        await writer.submit(Self.insertFileChangeStatement(change))
    }

    /// 缓冲写入一条命令记录。
    public func append(_ command: CommandRecord) async {
        await writer.submit(Self.insertCommandStatement(command))
    }

    /// 缓冲写入一条会话性能采样。
    public func append(_ sample: PerformanceSample) async {
        await writer.submit(Self.insertPerfSampleStatement(sample))
    }

    /// 缓冲写入一条整机性能采样。
    public func append(_ sample: SystemPerformanceSample) async {
        await writer.submit(Self.insertSystemPerfStatement(sample))
    }

    // MARK: - 辅助查询（Engine / 风险窗口 / 测试用）

    /// 活跃 agent（state 为 running 或 idle，与 InMemoryObservatoryService 口径一致）；非法行被丢弃。
    public func activeAgents() async throws -> [AgentInstance] {
        let rows = try await db.rows(SQL.selectActiveAgents, arguments: [
            .text(AgentRunState.running.rawValue),
            .text(AgentRunState.idle.rawValue),
        ])
        return rows.compactMap { StoreRows.agent(from: $0) }
    }

    /// 未结算（`ended_at IS NULL`）会话数。
    public func openSessionCount() async throws -> Int {
        try await db.scalarInt(SQL.selectOpenSessionCount) ?? 0
    }

    /// 未结算的会话本体。观测站重启后要用它把「同一个还活着的 Agent」的会话接回来，
    /// 否则每次重启都会给活进程新开一条 0 秒会话，需求点名的「运行时长」就被截断。
    public func openSessions() async throws -> [AgentSession] {
        let rows = try await db.rows(SQL.selectOpenSessions)
        return rows.compactMap { StoreRows.session(from: $0) }
    }

    /// 全历史里已经用过的最大会话编号（空库 → 0）。
    ///
    /// 为什么要有这条（ICR-0004）：会话编号的下限此前只从「未结算的那几行」取，
    /// 而重启最常见的形状恰恰是**上一轮的会话全都结算了** ⇒ 发号器退回 1，
    /// 真机 Sessions 列表同一屏出现两个 #2、顺序也不单调（用户肉眼可见的错号）。
    /// 只在启动时读一次，不在每 tick 的路径上；`sessions` 是个位到百级的行数，
    /// 这条 `MAX(display_index)` 无索引可定位，但代价与调用频率都不构成问题。
    public func maxSessionDisplayIndex() async throws -> Int {
        try await db.scalarInt(SQL.selectMaxSessionDisplayIndex) ?? 0
    }

    /// 把所有未结算会话结算为 `.interrupted`（ended_at = at），单语句 UPDATE…RETURNING 返回受影响条数。
    public func markRunningSessionsInterrupted(at date: Date) async throws -> Int {
        let rows = try await db.rows(SQL.markInterruptedReturning, arguments: [
            .real(date.timeIntervalSinceReferenceDate),
            .text(SessionOutcome.interrupted.rawValue),
        ])
        return rows.count
    }

    /// 时间窗内 `kind == 'deleted'` 的文件变更数（风险窗口用）；sessionID 为 nil 时统计全部会话。
    public func deletedFileChangeCount(sessionID: UUID?, from: Date, to: Date) async throws -> Int {
        try await countFileChanges(sessionID: sessionID, from: from, to: to, kind: FileChangeKind.deleted.rawValue)
    }

    /// 时间窗内文件变更总数；sessionID 为 nil 时统计全部会话。
    public func fileChangeCount(sessionID: UUID?, from: Date, to: Date) async throws -> Int {
        try await countFileChanges(sessionID: sessionID, from: from, to: to, kind: nil)
    }

    /// 清空所有表（按 prunable 先子后父顺序 DELETE，单事务）。测试装配用。
    public func deleteAllData() async throws {
        try await db.inTransaction(StoreSchema.allTables.map { table in
            SQLiteStatement("DELETE FROM \(table)")   // table 取自编译期常量白名单，非用户输入
        })
    }

    /// 指定表行数；表名必须在 `StoreSchema.allTables` 白名单内，否则抛 `ObservatoryError.invalidQuery`。
    public func rowCount(table: String) async throws -> Int {
        guard StoreSchema.allTables.contains(table) else {
            throw ObservatoryError.invalidQuery("rowCount: unknown table '\(table)'")
        }
        return try await db.scalarInt("SELECT COUNT(*) FROM \(table)") ?? 0
    }

    /// 表内**最大 rowid**；空表返回 0（真实行的 rowid 恒 ≥ 1，所以 0 是干净的"还没有行"）。
    ///
    /// 为什么要有它，而不是用 `rowCount(table:)` 判「有没有新行」：
    /// `SELECT COUNT(*)` 没有任何谓词可以定位索引，SQLite 只能把最小的那棵索引整个扫一遍
    /// ⇒ 代价**随历史长度线性增长**，而它被放在每 tick 的采集路径上
    /// （实测 20 000 行时 0.69 ms/tick，30 天保留期攒到百万行就是几十 ms/tick）。
    /// `MAX(rowid)` 走表 B-tree 的最右叶子，代价与行数无关。
    public func maxRowID(table: String) async throws -> Int {
        guard StoreSchema.allTables.contains(table) else {
            throw ObservatoryError.invalidQuery("maxRowID: unknown table '\(table)'")
        }
        return try await db.scalarInt("SELECT MAX(rowid) FROM \(table)") ?? 0
    }

    /// 委托 `RetentionPruner` 删除 cutoff 之前的行（含可选 VACUUM），返回每表删除数。
    public func prune(olderThan cutoff: Date, vacuum: Bool) async throws -> RetentionPruner.Result {
        // `sessions.risk_event_count` 的唯一写入者是那条派生重算 ⇒ 删掉风险行之后必须再派生一次，
        // 否则「只有一个写入者」会变成一句空话：计数会停在删除前的值上偏大。
        // 先取受影响会话（删完就查不到了），再删，再重算。多出来的这一条 SELECT 每个保留周期
        // 才跑一次（`cadence.prune`），不在每 tick 的路径上。
        let threshold = cutoff.timeIntervalSinceReferenceDate
        let touchedSessions = try await db.rows(
            "SELECT DISTINCT session_id FROM risk_events WHERE timestamp < ? AND session_id IS NOT NULL",
            arguments: [.real(threshold)]
        ).compactMap { row in row.text("session_id").flatMap(UUID.init(uuidString:)) }
        let pruner = RetentionPruner(database: db)
        let result = try await pruner.prune(olderThan: cutoff, vacuum: vacuum)
        guard (result.deletedRowsByTable[StoreSchema.Table.riskEvents] ?? 0) > 0,
              !touchedSessions.isEmpty else { return result }
        let sessionIDs = Set(touchedSessions).sorted { $0.uuidString < $1.uuidString }
        _ = try await db.execute([SQLiteStatement(
            SQL.recomputeSessionRiskCount(sessionIDCount: sessionIDs.count),
            arguments: sessionIDs.map { .text($0.uuidString) }
        )])
        return result
    }

    // MARK: - 私有：计数查询

    private func countFileChanges(sessionID: UUID?, from: Date, to: Date, kind: String?) async throws -> Int {
        // 只拼接固定 SQL 片段，用户输入全部走 ? 绑定。
        var sql = "SELECT COUNT(*) FROM file_changes WHERE timestamp >= ? AND timestamp <= ?"
        var arguments: [SQLiteValue] = [
            .real(from.timeIntervalSinceReferenceDate),
            .real(to.timeIntervalSinceReferenceDate),
        ]
        if let kind {
            sql += " AND kind = ?"
            arguments.append(.text(kind))
        }
        if let sessionID {
            sql += " AND session_id = ?"
            arguments.append(.text(sessionID.uuidString))
        }
        return try await db.scalarInt(sql, arguments: arguments) ?? 0
    }

    // MARK: - 私有：JSON（编码失败回退 "[]"，解码宽松不 crash）

    private static func encodeJSON<T: Encodable>(_ value: T) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            ObservatoryLog.store.error(
                "StoreJSON encode failed, wrote empty array: \(error.localizedDescription, privacy: .public)"
            )
            return "[]"
        }
    }

    // MARK: - 私有：语句组装（static，纯函数）

    private static func upsertAgentStatement(
        _ agent: AgentInstance
    ) -> SQLiteStatement {
        SQLiteStatement(SQL.upsertAgent, arguments: [
            .text(agent.id.uuidString),
            .text(agent.kind.rawValue),
            .integer(Int64(agent.pid)),
            agent.parentPID.map { .integer(Int64($0)) } ?? .null,
            .text(agent.displayName),
            .text(agent.executablePath),
            StoreValues.optionalText(agent.workingDirectory),
            StoreValues.optionalText(agent.bundleIdentifier),
            StoreValues.optionalText(agent.tty),
            StoreValues.date(agent.startedAt),
            StoreValues.date(agent.lastSeenAt),
            .text(agent.state.rawValue),
            .real(agent.cpuPercent),
            StoreValues.uint64(agent.memoryBytes),
            .text(Self.encodeJSON(agent.childPIDs)),
            .text(agent.detectedVia.rawValue),
        ])
    }

    private static func upsertSessionStatement(
        _ session: AgentSession
    ) -> SQLiteStatement {
        // 与 InMemoryObservatoryService.sessions(matching:) 的 haystack 逐字一致。
        let searchText =
            "\(session.title) \(session.projectPath ?? "") \(session.kind.displayName)".lowercased()
        return SQLiteStatement(SQL.upsertSession, arguments: [
            .text(session.id.uuidString),
            .integer(Int64(session.displayIndex)),
            .text(session.kind.rawValue),
            StoreValues.optionalUUID(session.agentID),
            .text(session.title),
            StoreValues.optionalText(session.projectPath),
            StoreValues.date(session.startedAt),
            StoreValues.optionalDate(session.endedAt),
            .integer(Int64(session.modifiedFileCount)),
            .integer(Int64(session.createdFileCount)),
            .integer(Int64(session.deletedFileCount)),
            .integer(Int64(session.commandCount)),
            .integer(Int64(session.failedCommandCount)),
            .real(session.cpuSeconds),
            .real(session.peakCPUPercent),
            StoreValues.uint64(session.peakMemoryBytes),
            .integer(Int64(session.estimatedTokens)),
            .integer(Int64(session.riskEventCount)),
            .text(session.outcome.rawValue),
            .text(searchText),
        ])
    }

    private static func upsertProjectStatement(
        _ project: ProjectActivity
    ) -> SQLiteStatement {
        SQLiteStatement(SQL.upsertProject, arguments: [
            .text(project.id),
            .text(project.name),
            .text(project.path),
            .integer(Int64(project.fileChangeCount)),
            .integer(Int64(project.commandCount)),
            .integer(Int64(project.sessionCount)),
            .integer(Int64(project.riskEventCount)),
            .integer(Int64(project.codeGrowthLines)),
            .integer(Int64(project.codeShrinkLines)),
            .text(Self.encodeJSON(project.agentContributions)),
            .text(Self.encodeJSON(project.hotFiles)),
            StoreValues.date(project.firstSeenAt),
            StoreValues.date(project.lastSeenAt),
        ])
    }

    private static func upsertRiskStatement(
        _ risk: RiskEvent
    ) -> SQLiteStatement {
        // 与 InMemoryObservatoryService.riskEvents(matching:) 的 haystack 逐字一致。
        let searchText = "\(risk.title) \(risk.detail) \(risk.command ?? "")".lowercased()
        return SQLiteStatement(SQL.upsertRisk, arguments: [
            .text(risk.id.uuidString),
            StoreValues.date(risk.timestamp),
            .text(risk.level.rawValue),
            .integer(Int64(risk.level.rank)),
            .text(risk.category.rawValue),
            .text(risk.title),
            .text(risk.detail),
            StoreValues.optionalUUID(risk.agentID),
            .text(risk.agentKind.rawValue),
            StoreValues.optionalUUID(risk.sessionID),
            StoreValues.optionalText(risk.command),
            .text(Self.encodeJSON(risk.filePaths)),
            StoreValues.flag(risk.requiresConfirmation),
            StoreValues.flag(risk.isAcknowledged),
            StoreValues.optionalText(risk.matchedRuleID),
            .text(searchText),
        ])
    }

    private static func insertDiffStatement(
        _ diff: FileDiff, changeID: UUID
    ) -> SQLiteStatement {
        SQLiteStatement(SQL.insertDiff, arguments: [
            .text(diff.id.uuidString),
            .text(changeID.uuidString),
            .text(diff.path),
            StoreValues.optionalText(diff.previousPath),
            .text(diff.kind.rawValue),
            .text(Self.encodeJSON(diff.lines)),
            .integer(Int64(diff.linesAdded)),
            .integer(Int64(diff.linesRemoved)),
            StoreValues.flag(diff.isBinary),
            StoreValues.flag(diff.isTruncated),
            StoreValues.date(diff.capturedAt),
            .text(diff.baselineSource.rawValue),
            StoreValues.optionalDate(diff.baselineCapturedAt),
            StoreValues.flag(diff.plaintextStored),
        ])
    }

    private static func insertSnapshotStatement(_ snapshot: FileSnapshot) -> SQLiteStatement {
        SQLiteStatement(SQL.insertSnapshot, arguments: [
            .text(snapshot.id.uuidString),
            .text(snapshot.path),
            .text(snapshot.contentHash),
            StoreValues.uint64(snapshot.sizeBytes),
            .integer(Int64(snapshot.lineCount)),
            StoreValues.date(snapshot.capturedAt),
        ])
    }

    private static func insertEventStatement(
        _ event: TimelineEvent
    ) -> SQLiteStatement {
        SQLiteStatement(SQL.insertEvent, arguments: eventArguments(event))
    }

    /// `events` 一行 20 个绑定值。`insertEvent` 与 `upsertEvent` 共用，防两条路径写歪。
    static func eventArguments(_ event: TimelineEvent) -> [SQLiteValue] {
        // 与 InMemoryObservatoryService.events(matching:) 的 haystack 逐字一致。
        let searchText =
            "\(event.title) \(event.summary) \(event.filePath ?? "") \(event.command ?? "")".lowercased()
        return [
            .text(event.id.uuidString),
            StoreValues.date(event.timestamp),
            StoreValues.optionalUUID(event.sessionID),
            StoreValues.optionalUUID(event.agentID),
            .text(event.agentKind.rawValue),
            .text(event.kind.rawValue),
            .text(event.title),
            .text(event.summary),
            StoreValues.optionalText(event.filePath),
            StoreValues.optionalText(event.command),
            StoreValues.optionalInt32(event.exitCode),
            event.durationSeconds.map { SQLiteValue.real($0) } ?? .null,
            .real(event.cost.cpuSeconds),
            StoreValues.uint64(event.cost.memoryBytes),
            StoreValues.uint64(event.cost.bytesRead),
            StoreValues.uint64(event.cost.bytesWritten),
            .text(event.riskLevel.rawValue),
            .integer(Int64(event.riskLevel.rank)),
            StoreValues.optionalText(event.projectPath),
            .text(searchText),
        ]
    }

    private static func insertFileChangeStatement(_ change: FileChange) -> SQLiteStatement {
        // 与 InMemoryObservatoryService.fileChanges(matching:) 的 haystack 逐字一致。
        let searchText = change.path.lowercased()
        return SQLiteStatement(SQL.insertFileChange, arguments: [
            .text(change.id.uuidString),
            .text(change.path),
            StoreValues.optionalText(change.previousPath),
            .text(change.kind.rawValue),
            StoreValues.date(change.timestamp),
            StoreValues.optionalUUID(change.agentID),
            StoreValues.optionalUUID(change.sessionID),
            .text(change.agentKind.rawValue),
            StoreValues.uint64(change.sizeBytes),
            change.previousSizeBytes.map { StoreValues.uint64($0) } ?? .null,
            StoreValues.flag(change.isText),
            .integer(Int64(change.linesAdded)),
            .integer(Int64(change.linesRemoved)),
            .text(change.riskLevel.rawValue),
            .integer(Int64(change.riskLevel.rank)),
            StoreValues.optionalText(change.projectPath),
            .text(searchText),
        ])
    }

    private static func insertCommandStatement(
        _ command: CommandRecord
    ) -> SQLiteStatement {
        // 与 InMemoryObservatoryService.commands(matching:) 的 haystack 逐字一致
        // （commandLine = ([executable] + arguments).joined(" ")）。
        let searchText = command.commandLine.lowercased()
        return SQLiteStatement(SQL.insertCommand, arguments: [
            .text(command.id.uuidString),
            .text(command.executable),
            .text(Self.encodeJSON(command.arguments)),
            StoreValues.optionalText(command.workingDirectory),
            StoreValues.optionalUUID(command.agentID),
            StoreValues.optionalUUID(command.sessionID),
            .text(command.agentKind.rawValue),
            StoreValues.date(command.startedAt),
            StoreValues.optionalDate(command.endedAt),
            StoreValues.optionalInt32(command.exitCode),
            .text(command.outcome.rawValue),
            StoreValues.flag(command.isDestructive),
            StoreValues.flag(command.requiresConfirmation),
            .text(command.riskLevel.rawValue),
            .integer(Int64(command.riskLevel.rank)),
            StoreValues.optionalText(command.projectPath),
            .text(searchText),
        ])
    }

    private static func insertPerfSampleStatement(_ sample: PerformanceSample) -> SQLiteStatement {
        SQLiteStatement(SQL.insertPerfSample, arguments: [
            .text(sample.id.uuidString),
            StoreValues.date(sample.timestamp),
            StoreValues.optionalUUID(sample.sessionID),
            StoreValues.optionalUUID(sample.agentID),
            .real(sample.cpuPercent),
            StoreValues.uint64(sample.memoryBytes),
            sample.gpuPercent.map { SQLiteValue.real($0) } ?? .null,
            .real(sample.diskReadBytesPerSecond),
            .real(sample.diskWriteBytesPerSecond),
            StoreValues.uint64(sample.networkBytesIn),
            StoreValues.uint64(sample.networkBytesOut),
            sample.thermalCelsius.map { SQLiteValue.real($0) } ?? .null,
            sample.powerWatts.map { SQLiteValue.real($0) } ?? .null,
        ])
    }

    private static func insertSystemPerfStatement(_ sample: SystemPerformanceSample) -> SQLiteStatement {
        SQLiteStatement(SQL.insertSystemPerf, arguments: [
            .text(sample.id.uuidString),
            StoreValues.date(sample.timestamp),
            .real(sample.cpuTotalPercent),
            .real(sample.cpuSystemPercent),
            .real(sample.cpuUserPercent),
            StoreValues.uint64(sample.memoryUsedBytes),
            StoreValues.uint64(sample.memoryTotalBytes),
            .real(sample.diskReadBytesPerSecond),
            .real(sample.diskWriteBytesPerSecond),
            .real(sample.loadAverage1m),
            sample.thermalCelsius.map { SQLiteValue.real($0) } ?? .null,
            sample.powerWatts.map { SQLiteValue.real($0) } ?? .null,
            sample.networkInBytesPerSecond.map { SQLiteValue.real($0) } ?? .null,
            sample.networkOutBytesPerSecond.map { SQLiteValue.real($0) } ?? .null,
            sample.networkAvailability.map { SQLiteValue.text($0.rawValue) } ?? .null,
            sample.gpuActivityPercent.map { SQLiteValue.real($0) } ?? .null,
        ])
    }
}

