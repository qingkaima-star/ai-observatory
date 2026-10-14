//
//  StoreInternalsTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine
//
//  Store 层内部机制测试：批量写提交次数、schema 迁移幂等、事务原子性、
//  字段级往返无损、保留期清理。与 `StoreParityTests`（对外查询语义）互补。
//

import Testing
import Foundation
import os
import AIObservatoryCore
@testable import AIObservatoryStore
@testable import AIObservatoryEngine

// MARK: - 夹具

private enum Internals {
    /// 固定基准时间（2023-11-14），与真实时钟无关。
    static let base = Date(timeIntervalSince1970: 1_700_000_000)

    static func offset(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    static func session(id: UUID = UUID(), kind: AgentKind = .claudeCode, endedAt: Date? = nil) -> AgentSession {
        AgentSession(id: id, displayIndex: 1, kind: kind, title: "会话", startedAt: base,
                     endedAt: endedAt, outcome: endedAt == nil ? .running : .success)
    }

    static func event(id: UUID = UUID(), at date: Date, risk: RiskLevel = .low, kind: OperationKind = .fileModified) -> TimelineEvent {
        TimelineEvent(id: id, timestamp: date, kind: kind, title: "事件 \(kind.rawValue)", riskLevel: risk)
    }

    static func agent(id: UUID = UUID(), pid: Int32, state: AgentRunState = .running, children: [Int32] = []) -> AgentInstance {
        AgentInstance(id: id, kind: .openAICodex, pid: pid, displayName: "Codex",
                      executablePath: "/usr/bin/codex", startedAt: base, lastSeenAt: base,
                      state: state, cpuPercent: 10, memoryBytes: UInt64(Int64.max) + 1,
                      childPIDs: children, detectedVia: .processName)
    }

    static func store() async throws -> ObservatoryStore {
        try await ObservatoryStore.open(configuration: .inMemory)
    }

    static func database() throws -> SQLiteDatabase {
        try SQLiteDatabase(configuration: .inMemory)
    }

    /// 已应用 schema 的底层连接：`ObservatoryStore.open` 才会跑迁移，裸 `SQLiteDatabase` 不会。
    static func migratedDatabase() async throws -> (ObservatoryStore, SQLiteDatabase) {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        return (store, await store.database)
    }
}

// MARK: - 批量写

@Suite("BatchWriter：攒批与提交次数", .timeLimit(.minutes(1)))
struct BatchWriterTests {

    /// 验收硬指标：100 次写入实际事务提交 ≤ 4 次（性能预算：单次事务 ≥ 32 行）。
    @Test("100 条写入只产生 4 次事务提交")
    func commitsStayBounded() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY, label TEXT)")
        let writer = BatchWriter(database: database, policy: .init(maxStatementsInBatch: 32, flushInterval: 3_600))

        for index in 0..<100 {
            await writer.submit(SQLiteStatement("INSERT INTO probe (n, label) VALUES (?, ?)",
                                               arguments: [.integer(Int64(index)), .text("row-\(index)")]))
        }

        let beforeFlush = await writer.stats
        #expect(beforeFlush.commitCount == 3, "满批应提交 3 次（32/64/96）")
        #expect(beforeFlush.pendingCount == 4)
        #expect(beforeFlush.totalSubmitted == 100)

        await writer.flush()
        let afterFlush = await writer.stats
        #expect(afterFlush.commitCount == 4)
        #expect(afterFlush.pendingCount == 0)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM probe") == 100)
    }

    @Test("恰好攒满一批时提交一次，未满不提交")
    func commitsExactlyOnceAtThreshold() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY)")
        let writer = BatchWriter(database: database, policy: .init(maxStatementsInBatch: 8, flushInterval: 3_600))

        for index in 0..<7 {
            await writer.submit(SQLiteStatement("INSERT INTO probe (n) VALUES (?)", arguments: [.integer(Int64(index))]))
        }
        #expect(await writer.stats.commitCount == 0)
        #expect(await writer.stats.pendingCount == 7)

        await writer.submit(SQLiteStatement("INSERT INTO probe (n) VALUES (?)", arguments: [.integer(Int64(7))]))
        #expect(await writer.stats.commitCount == 1)
        #expect(await writer.stats.pendingCount == 0)
    }

    /// AGENTS §6「单次事务 ≥ 32 行」：定时器不得把 1–5 行的 trickle 直接提交成逐行事务。
    @Test("定时器攒批判定：少量行不提交，攒够或超龄才提交")
    func timerOnlyCommitsWhenWorthwhile() {
        let policy = BatchWriter.Policy(maxStatementsInBatch: 32, flushInterval: 1, minRowsPerCommit: 8, maxBufferAge: 10)
        // 行数不足且未超龄 → 不提交
        #expect(!BatchWriter.TimerPolicy.shouldCommit(bufferCount: 3, oldestBufferedSeconds: 2, secondsSinceLastCommit: 5, policy: policy))
        #expect(!BatchWriter.TimerPolicy.shouldCommit(bufferCount: 0, oldestBufferedSeconds: 99, secondsSinceLastCommit: 99, policy: policy))
        // 攒够最少行数且过了检查周期 → 提交
        #expect(BatchWriter.TimerPolicy.shouldCommit(bufferCount: 8, oldestBufferedSeconds: 2, secondsSinceLastCommit: 1.2, policy: policy))
        #expect(!BatchWriter.TimerPolicy.shouldCommit(bufferCount: 8, oldestBufferedSeconds: 0.2, secondsSinceLastCommit: 0.2, policy: policy))
        // 硬延迟兜底：哪怕只有 1 行，超龄也必须落盘
        #expect(BatchWriter.TimerPolicy.shouldCommit(bufferCount: 1, oldestBufferedSeconds: 10, secondsSinceLastCommit: 0.1, policy: policy))
        // 从未提交过（nil）时，够行数即可提交
        #expect(BatchWriter.TimerPolicy.shouldCommit(bufferCount: 8, oldestBufferedSeconds: 0.1, secondsSinceLastCommit: nil, policy: policy))
        // maxBufferAge 被抬到不小于检查周期，避免定时器永远看不到兜底
        #expect(BatchWriter.Policy(flushInterval: 30, maxBufferAge: 1).maxBufferAge >= 30)
    }

    @Test("空缓冲 flush 不产生提交")
    func emptyFlushIsFree() async throws {
        let writer = BatchWriter(database: try Internals.database(), policy: .init(maxStatementsInBatch: 4, flushInterval: 3_600))
        await writer.flush()
        await writer.flush()
        #expect(await writer.stats.commitCount == 0)
    }

    @Test("stop 会强制落盘剩余缓冲")
    func stopFlushesRemainder() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY)")
        let writer = BatchWriter(database: database, policy: .init(maxStatementsInBatch: 32, flushInterval: 3_600))
        await writer.start()
        for index in 0..<5 {
            await writer.submit(SQLiteStatement("INSERT INTO probe (n) VALUES (?)", arguments: [.integer(Int64(index))]))
        }
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM probe") == 0)

        await writer.stop()
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM probe") == 5)
        #expect(await writer.stats.pendingCount == 0)
    }

    @Test("maxStatementsInBatch 为 0 时收敛为 1，不丢不卡")
    func zeroBatchSizeConverges() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY)")
        let writer = BatchWriter(database: database, policy: .init(maxStatementsInBatch: 0, flushInterval: 3_600))
        for index in 0..<10 {
            await writer.submit(SQLiteStatement("INSERT INTO probe (n) VALUES (?)", arguments: [.integer(Int64(index))]))
        }
        await writer.flush()
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM probe") == 10)
        // 原来 `>= 10`：批大小为 0 必须收敛成「一条一提交」，正好 10 次；
        // 写成 >= 就把「退化成逐条之外还多提交几次」的回归放过了。
        #expect(await writer.stats.commitCount == 10)
    }

    @Test("批量写中途失败不丢语句：失败后重投仍完整")
    func failedBatchKeepsStatements() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY)")
        let writer = BatchWriter(database: database, policy: .init(maxStatementsInBatch: 2, flushInterval: 3_600))

        // 第 3 条与已插入的主键冲突 → 该批失败；不应把整批语句丢弃后静默。
        await writer.submit(SQLiteStatement("INSERT INTO probe (n) VALUES (?)", arguments: [.integer(1)]))
        await writer.submit(SQLiteStatement("INSERT INTO probe (n) VALUES (?)", arguments: [.integer(1)]))
        await writer.submit(SQLiteStatement("INSERT INTO probe (n) VALUES (?)", arguments: [.integer(2)]))
        await writer.stop()

        // 整批失败 → 逐条重投：两条有效写入入库，只有违反唯一约束的那条被丢弃（且记日志）。
        let rows = try await database.scalarInt("SELECT COUNT(*) FROM probe") ?? 0
        #expect(rows == 2, "一条坏数据不得带走同批的有效写入")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM probe WHERE n = 2") == 1)
    }

    /// Store 的缓冲路径：未 flush 前查不到，flush 后可见。
    @Test("Store 缓冲写在 flush 前不可见")
    func storeBufferIsInvisibleUntilFlush() async throws {
        let store = try await Internals.store()
        await store.append(Internals.event(at: Internals.base))
        #expect(try await store.events(matching: .all).totalCount == 0)

        await store.flush()
        #expect(try await store.events(matching: .all).totalCount == 1)
    }

    /// P1-5：丢弃必须能被调用方看到（而不是只写日志）。
    @Test("无法写入的语句计入 droppedStatementCount")
    func droppedStatementsAreVisible() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY)")
        let writer = BatchWriter(database: database, policy: .init(maxStatementsInBatch: 4, flushInterval: 3_600))
        // 4 条一批：第 2、3 条主键冲突，其余应入库
        await writer.submit([
            SQLiteStatement("INSERT INTO probe (n) VALUES (1)"),
            SQLiteStatement("INSERT INTO probe (n) VALUES (1)"),
            SQLiteStatement("INSERT INTO probe (n) VALUES (1)"),
            SQLiteStatement("INSERT INTO probe (n) VALUES (2)"),
        ])
        await writer.flush()
        let stats = await writer.stats
        #expect(stats.droppedStatementCount == 2, "只有违反约束的两条被丢弃")
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM probe") == 2, "有效语句必须逐条兜底入库")
    }

    /// `UPDATE … RETURNING` 需要系统 libsqlite3 ≥ 3.35；`Package.swift` 没有 vendored SQLite，
    /// 因此这里用真实运行时版本作为硬断言，一旦系统库退化会立刻失败。
    @Test("系统 SQLite 支持 UPDATE…RETURNING")
    func systemSqliteSupportsReturning() async throws {
        let (store, database) = try await Internals.migratedDatabase()
        let row = try #require(try await database.optionalRow("SELECT sqlite_version() AS v"))
        let version = try #require(row.text("v"))
        let parts = version.split(separator: ".").compactMap { Int($0) }
        let major = parts.first ?? 0
        let minor = parts.count > 1 ? parts[1] : 0
        #expect(major > 3 || (major == 3 && minor >= 35), "RETURNING 需要 ≥ 3.35，实际 \(version)")

        let openID = UUID()
        try await store.upsertSessions([Internals.session(id: openID)])
        // 真实走一遍 UPDATE…RETURNING
        #expect(try await store.markRunningSessionsInterrupted(at: Internals.offset(60)) == 1)
        #expect(try await store.session(id: openID)?.outcome == .interrupted)
    }

    @Test("Store stop 会 flush 缓冲并保留数据")
    func storeStopKeepsBufferedRows() async throws {
        let store = try await Internals.store()
        await store.start()
        for index in 0..<3 {
            await store.append(Internals.event(at: Internals.offset(Double(index))))
        }
        await store.stop()
        #expect(try await store.rowCount(table: StoreSchema.Table.events) == 3)
    }
}

// MARK: - Schema 与迁移

@Suite("SchemaMigrator：版本与幂等", .timeLimit(.minutes(1)))
struct SchemaMigrationTests {

    @Test("新库打开即落到最新 schema 版本")
    func freshDatabaseIsMigrated() async throws {
        let (store, database) = try await Internals.migratedDatabase()
        #expect(try await database.userVersion() == StoreSchema.schemaVersion)
        #expect(try await store.rowCount(table: StoreSchema.Table.sessions) == 0)
    }

    @Test("重复应用迁移是幂等的（第二次应用 0 个）")
    func applyingTwiceIsNoop() async throws {
        let (_, database) = try await Internals.migratedDatabase()
        #expect(try await database.applyMigrations(StoreSchema.migrations) == 0)
        #expect(try await database.applyMigrations(StoreSchema.migrations) == 0)
        #expect(try await database.userVersion() == StoreSchema.schemaVersion)
    }

    @Test("每张表都可查询，未知表名被拒绝")
    func tablesExistAndWhitelistHolds() async throws {
        let store = try await Internals.store()
        for table in StoreSchema.allTables {
            #expect(try await store.rowCount(table: table) == 0, "\(table) 应存在且为空")
        }
        await #expect(throws: ObservatoryError.invalidQuery("rowCount: unknown table 'secrets'")) {
            _ = try await store.rowCount(table: "secrets")
        }
    }

    @Test("索引覆盖了查询用到的每个过滤列")
    func indexesCoverFilterColumns() async throws {
        let (_, database) = try await Internals.migratedDatabase()
        let rows = try await database.rows("SELECT name FROM sqlite_master WHERE type = 'index' AND name LIKE 'idx_%'")
        let names = Set(rows.compactMap { $0.text("name") })
        for required in ["idx_events_ts", "idx_events_session", "idx_events_project", "idx_events_risk_rank",
                         "idx_sessions_started", "idx_sessions_outcome", "idx_files_ts", "idx_files_path",
                         "idx_commands_started", "idx_commands_destructive", "idx_risk_ts", "idx_risk_ack",
                         "idx_perf_session", "idx_sysperf_ts", "idx_projects_last_seen"] {
            #expect(names.contains(required), "缺少索引 \(required)")
        }
    }

    @Test("迁移清单非法时分别抛对应错误", arguments: [
        ([], "empty"),
        ([SchemaMigration(version: 2, name: "只从 2 开始", statements: [])], "mustStartAtOne"),
        ([SchemaMigration(version: 1, name: "a", statements: []), SchemaMigration(version: 1, name: "b", statements: [])], "duplicate"),
        ([SchemaMigration(version: 1, name: "a", statements: []), SchemaMigration(version: 3, name: "b", statements: []), SchemaMigration(version: 2, name: "c", statements: [])], "outOfOrder"),
    ])
    func validateRejectsBadPlans(migrations: [SchemaMigration], expectation: String) {
        switch expectation {
        case "empty": #expect(throws: SchemaMigrator.MigratorError.emptyMigrations) { try SchemaMigrator.validate(migrations) }
        case "mustStartAtOne": #expect(throws: SchemaMigrator.MigratorError.mustStartAtOne(firstVersion: 2)) { try SchemaMigrator.validate(migrations) }
        case "duplicate": #expect(throws: SchemaMigrator.MigratorError.duplicateVersion(1)) { try SchemaMigrator.validate(migrations) }
        default: #expect(throws: SchemaMigrator.MigratorError.outOfOrder(version: 2, previous: 3)) { try SchemaMigrator.validate(migrations) }
        }
    }

    @Test("合法迁移清单通过校验，且 plan 只挑更高版本")
    func planSelectsPendingVersions() throws {
        let migrations = [
            SchemaMigration(version: 1, name: "baseline", statements: []),
            SchemaMigration(version: 2, name: "加索引", statements: []),
            SchemaMigration(version: 3, name: "补列", statements: []),
        ]
        try SchemaMigrator.validate(migrations)
        #expect(SchemaMigrator.latestVersion(of: migrations) == 3)
        #expect(SchemaMigrator.plan(currentVersion: 0, migrations: migrations).map(\.version) == [1, 2, 3])
        #expect(SchemaMigrator.plan(currentVersion: 2, migrations: migrations).map(\.version) == [3])
        #expect(SchemaMigrator.plan(currentVersion: 3, migrations: migrations).isEmpty)
    }

    @Test("StoreSchema 自身通过校验且版本为 4（v1 十表 + v2 file_snapshots + v3 网络/GPU 列 + v4 diff 溯源列）")
    func storeSchemaIsValid() throws {
        #expect(StoreSchema.schemaVersion == 4)
        #expect(StoreSchema.migrations.map(\.version) == [1, 2, 3, 4])
        try SchemaMigrator.validate(StoreSchema.migrations)
        #expect(!StoreSchema.prunable.isEmpty)
    }
}

// MARK: - SQLiteDatabase 语义

@Suite("SQLiteDatabase：事务与取值", .timeLimit(.minutes(1)))
struct SQLiteDatabaseTests {

    @Test("事务内任一语句失败 → 全部回滚")
    func transactionRollsBack() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY CHECK (n < 10))")
        #expect(try await database.execute([
            SQLiteStatement("INSERT INTO probe (n) VALUES (1)"),
        ]) == 1)

        await #expect(throws: (any Error).self) {
            try await database.inTransaction([
                SQLiteStatement("INSERT INTO probe (n) VALUES (2)"),
                SQLiteStatement("INSERT INTO probe (n) VALUES (99)"),   // 违反 CHECK
                SQLiteStatement("INSERT INTO probe (n) VALUES (3)"),
            ])
        }
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM probe") == 1)
    }

    @Test("execute 返回受影响行数累加")
    func executeReportsChanges() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY)")
        let affected = try await database.execute([
            SQLiteStatement("INSERT INTO probe (n) VALUES (1)"),
            SQLiteStatement("INSERT INTO probe (n) VALUES (2)"),
            SQLiteStatement("UPDATE probe SET n = n + 10"),
        ])
        #expect(affected == 4, "2 插入 + 2 更新")
    }

    @Test("非法 SQL 抛 prepareFailed 且带上 SQL 便于定位")
    func prepareFailureCarriesContext() async throws {
        let database = try Internals.database()
        do {
            try await database.run("SELECT * FROM 没有这张表")
            Issue.record("应当抛出 prepareFailed")
        } catch let error as SQLiteDatabase.Error {
            guard case .prepareFailed(let sql, _, _) = error else {
                Issue.record("错误类型应为 prepareFailed，实际 \(error)")
                return
            }
            // 断的是「错误里带回的是哪条 SQL」，contains("SELECT") 对任何 SELECT 都成立。
            #expect(sql == "SELECT * FROM 没有这张表")
        }
    }

    @Test("行取值：整数/实数/文本/NULL/布尔/日期/UUID/超大 UInt64")
    func rowAccessorsCoverEveryColumnKind() async throws {
        let database = try Internals.database()
        let uuid = UUID()
        let date = Internals.offset(1_234.5)
        try await database.run("CREATE TABLE probe (i INTEGER, r REAL, t TEXT, n INTEGER, d REAL, u TEXT, big INTEGER)")
        try await database.run(
            "INSERT INTO probe (i, r, t, n, d, u, big) VALUES (?, ?, ?, ?, ?, ?, ?)",
            arguments: [
                .integer(-7), .real(2.5), .text("中文"), .null,
                .real(date.timeIntervalSinceReferenceDate), .text(uuid.uuidString),
                .integer(Int64(bitPattern: UInt64(Int64.max) + 1)),
            ]
        )

        let row = try #require(try await database.optionalRow("SELECT * FROM probe"))
        #expect(row.int("i") == -7)
        #expect(row.double("r") == 2.5)
        #expect(row.text("t") == "中文")
        #expect(row.int("n") == nil)
        #expect(row.bool("n") == false)
        #expect(row.date("d") == date)
        #expect(row.uuid("u") == uuid)
        #expect(row.uint64("big") == UInt64(Int64.max) + 1)
        #expect(row.text("missing") == nil)
        #expect(row.column("i") != nil)
        #expect(Set(row.columnNames).isSuperset(of: ["i", "r", "t", "big"]))
    }

    @Test("语句缓存复用：200 次不同参数结果始终正确")
    func statementCacheStaysCorrect() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER PRIMARY KEY, label TEXT)")
        for index in 0..<200 {
            try await database.run(
                "INSERT INTO probe (n, label) VALUES (?, ?)",
                arguments: [.integer(Int64(index)), .text("l\(index)")]
            )
        }
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM probe") == 200)
        let label = try await database.rows("SELECT label FROM probe WHERE n = ?", arguments: [.integer(199)])
        #expect(label.first?.text("label") == "l199")
        let fresh = try await database.rows("SELECT label FROM probe WHERE n = ?", arguments: [.integer(3)])
        #expect(fresh.first?.text("label") == "l3", "缓存语句须清空绑定，不能串味")
    }

    @Test("scalar 与 optionalRow 在无数据时返回 nil 而不是报错")
    func emptyResultsAreNil() async throws {
        let database = try Internals.database()
        try await database.run("CREATE TABLE probe (n INTEGER)")
        #expect(try await database.scalarInt("SELECT MAX(n) FROM probe") == nil)
        #expect(try await database.optionalRow("SELECT * FROM probe") == nil)
        #expect(try await database.rows("SELECT * FROM probe").isEmpty)
    }

    @Test("close 之后再查询会抛 closed")
    func closedDatabaseRejectsWork() async throws {
        let database = try Internals.database()
        await database.close()
        #expect(await database.isOpen == false)
        await #expect(throws: SQLiteDatabase.Error.closed) {
            try await database.run("SELECT 1")
        }
    }
}

// MARK: - 字段往返与保留期

@Suite("Store：字段往返与清理", .timeLimit(.minutes(1)))
struct StoreRoundTripTests {

    @Test("Agent 的 childPIDs、超大 memoryBytes、可空列无损")
    func agentFieldsRoundTrip() async throws {
        let store = try await Internals.store()
        let children: [Int32] = [7, 8, 9]
        let instance = Internals.agent(pid: 4321, state: .idle, children: children)
        try await store.upsertAgents([instance])
        await store.flush()

        let restored = try #require(try await store.activeAgents().first)
        #expect(restored.id == instance.id)
        #expect(restored.childPIDs == children)
        #expect(restored.memoryBytes == instance.memoryBytes)
        #expect(restored.state == .idle)
        #expect(restored.kind == .openAICodex)
        #expect(restored.detectedVia == .processName)
        #expect(restored.bundleIdentifier == nil)
        #expect(restored.workingDirectory == nil)
    }

    @Test("upsert 幂等：同 id 两次写入只留一行且取后者")
    func upsertOverwrites() async throws {
        let store = try await Internals.store()
        let id = UUID()
        try await store.upsertSessions([Internals.session(id: id, kind: .claudeCode)])
        try await store.upsertSessions([Internals.session(id: id, kind: .windsurf)])
        #expect(try await store.rowCount(table: StoreSchema.Table.sessions) == 1)
        #expect(try await store.session(id: id)?.kind == .windsurf)
    }

    @Test("风险等级按 rank 过滤，不受 TEXT 字典序影响")
    func riskLevelFiltersByRank() async throws {
        let store = try await Internals.store()
        for (index, level) in RiskLevel.allCases.enumerated() {
            await store.append(Internals.event(at: Internals.offset(Double(index) * 60), risk: level))
        }
        await store.flush()

        let high = try await store.events(matching: EventQuery(minimumRisk: .high))
        #expect(high.totalCount == 2, "high 与 critical 共 2 条")
        // allSatisfy 在 items 为空时恒真；totalCount == 2 并不保证页里有货。
        #expect(high.items.map(\.riskLevel) == [.critical, .high], "倒序：critical 在前")
        let critical = try await store.events(matching: EventQuery(minimumRisk: .critical))
        #expect(critical.items.map(\.riskLevel) == [.critical])
        #expect(try await store.events(matching: .all).totalCount == 4)
    }

    @Test("Diff 多行与二进制标记无损，未知 changeID 返回 nil")
    func diffRoundTrip() async throws {
        let store = try await Internals.store()
        let changeID = UUID()
        let diff = FileDiff(
            id: changeID, path: "/repo/a.swift", previousPath: "/repo/old.swift", kind: .renamed,
            lines: [
                DiffLine(style: .hunkHeader, text: "@@ -1,2 +1,3 @@", oldLineNumber: 1, newLineNumber: 1),
                DiffLine(style: .removed, text: "let a = 1", oldLineNumber: 2),
                DiffLine(style: .added, text: "let a = 2", newLineNumber: 2),
            ],
            linesAdded: 1, linesRemoved: 1, isBinary: false, isTruncated: true, capturedAt: Internals.base
        )
        try await store.record(diff, forChangeID: changeID)

        let restored = try #require(try await store.fileDiff(for: changeID))
        #expect(restored.path == diff.path)
        #expect(restored.previousPath == diff.previousPath)
        #expect(restored.kind == .renamed)
        #expect(restored.lines == diff.lines)
        #expect(restored.lines.count == 3)
        #expect(restored.lines[2].newLineNumber == 2)
        #expect(restored.lines[1].oldLineNumber == 2)
        #expect(restored.isBinary == false && restored.isTruncated == true)
        #expect(restored.capturedAt == Internals.base)
        #expect(try await store.fileDiff(for: UUID()) == nil)
    }

    @Test("recordRisks 自增会话风险计数，acknowledge 生效")
    func riskCountAndAcknowledgement() async throws {
        let store = try await Internals.store()
        let sessionID = UUID()
        try await store.upsertSessions([Internals.session(id: sessionID, endedAt: Internals.offset(600))])
        let risks = (0..<3).map { index in
            RiskEvent(timestamp: Internals.offset(Double(index)), level: .high, category: .dangerousCommand,
                      title: "风险 \(index)", agentKind: .claudeCode, sessionID: sessionID,
                      command: "rm -rf /\(index)", filePaths: ["/a\(index).txt"], requiresConfirmation: true)
        }
        try await store.recordRisks(risks)

        #expect(try await store.session(id: sessionID)?.riskEventCount == 3)
        let queried = try await store.riskEvents(matching: RiskQuery(unacknowledgedOnly: true))
        #expect(queried.totalCount == 3)
        #expect(queried.items.first?.filePaths.count == 1)

        try await store.acknowledgeRisk(id: risks[0].id)
        let remaining = try await store.riskEvents(matching: RiskQuery(unacknowledgedOnly: true))
        #expect(remaining.totalCount == 2)
        #expect(remaining.items.allSatisfy { $0.id != risks[0].id })
    }

    @Test("markRunningSessionsInterrupted 只动未闭合会话")
    func interruptOnlyOpenSessions() async throws {
        let store = try await Internals.store()
        let open = UUID()
        let closed = UUID()
        try await store.upsertSessions([
            Internals.session(id: open),
            Internals.session(id: closed, endedAt: Internals.offset(600)),
        ])

        #expect(try await store.openSessionCount() == 1)
        #expect(try await store.markRunningSessionsInterrupted(at: Internals.offset(900)) == 1)
        let settled = try #require(try await store.session(id: open))
        #expect(settled.outcome == .interrupted)
        #expect(settled.endedAt == Internals.offset(900))
        #expect(try #require(try await store.session(id: closed)).outcome == .success)
        #expect(try await store.openSessionCount() == 0)
    }

    @Test("删除计数窗口为闭区间，且可按会话过滤")
    func deletionWindowIsInclusive() async throws {
        let store = try await Internals.store()
        let sessionID = UUID()
        for index in 0..<5 {
            await store.append(FileChange(path: "/repo/f\(index).txt", kind: .deleted,
                                          timestamp: Internals.offset(Double(index) * 10),
                                          sessionID: index < 4 ? sessionID : UUID(), agentKind: .claudeCode))
        }
        await store.flush()

        let all = try await store.deletedFileChangeCount(sessionID: nil, from: Internals.base, to: Internals.offset(40))
        #expect(all == 5)
        let mine = try await store.deletedFileChangeCount(sessionID: sessionID, from: Internals.base, to: Internals.offset(30))
        #expect(mine == 4)
        let openEdge = try await store.deletedFileChangeCount(sessionID: nil, from: Internals.offset(10), to: Internals.offset(30))
        #expect(openEdge == 3, "两端都应包含")
        #expect(try await store.fileChangeCount(sessionID: nil, from: Internals.base, to: Internals.offset(40)) == 5)
    }

    /// P0-1 回归：`recordSnapshot` 一直在写 `file_snapshots`，v1 却没建这张表。
    @Test("文件快照可写入并读回（v2 迁移建表）")
    func snapshotRoundTrip() async throws {
        let (store, database) = try await Internals.migratedDatabase()
        let id = UUID()
        let snapshot = FileSnapshot(id: id, path: "/repo/a.swift", contentHash: "sha256:abc",
                                    sizeBytes: 4_096, capturedAt: Internals.base, lineCount: 120)
        try await store.recordSnapshot(snapshot)

        #expect(try await store.rowCount(table: StoreSchema.Table.fileSnapshots) == 1)
        let row = try #require(try await database.optionalRow("SELECT * FROM file_snapshots WHERE id = ?",
                                                             arguments: [.text(id.uuidString)]))
        #expect(row.text("path") == "/repo/a.swift")
        #expect(row.text("content_hash") == "sha256:abc")
        #expect(row.int("size_bytes") == 4_096)
        #expect(row.int("line_count") == 120)
        #expect(row.date("captured_at") == Internals.base)

        // 同 id 覆盖而不是新增一行
        try await store.recordSnapshot(FileSnapshot(id: id, path: "/repo/a.swift", contentHash: "sha256:def",
                                                   sizeBytes: 5_000, capturedAt: Internals.base, lineCount: 130))
        #expect(try await store.rowCount(table: StoreSchema.Table.fileSnapshots) == 1)
        let updated = try #require(try await database.optionalRow("SELECT content_hash FROM file_snapshots WHERE id = ?",
                                                                  arguments: [.text(id.uuidString)]))
        #expect(updated.text("content_hash") == "sha256:def")
    }

    @Test("快照表在清理与白名单清单里，v1 老库可一路升到最新并拿到网络/GPU 列")
    func snapshotTableIsRegisteredAndUpgrades() async throws {
        #expect(StoreSchema.allTables.contains(StoreSchema.Table.fileSnapshots))
        #expect(StoreSchema.prunable.contains { $0.table == StoreSchema.Table.fileSnapshots })

        // 只应用 v1 模拟老库，再整体升级应补上 v2 + v3 + v4 三步且不报错。
        let database = try Internals.database()
        _ = try await database.applyMigrations([StoreSchema.migrations[0]])
        #expect(try await database.userVersion() == 1)
        #expect(try await database.applyMigrations(StoreSchema.migrations) == 3)
        #expect(try await database.userVersion() == StoreSchema.schemaVersion)
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM file_snapshots") == 0)

        // v3 的证据要落在列上，而不是只数迁移条数：老库升级后这四列必须存在且可空。
        let columns = try await database.rows("PRAGMA table_info(system_perf)")
        let names = Set(columns.compactMap { $0.text("name") })
        for column in ["network_in_bytes_per_second", "network_out_bytes_per_second",
                       "network_availability", "gpu_percent"] {
            #expect(names.contains(column), "v1 老库升级后 system_perf 应带 \(column)")
        }
        // 老行（本次升级前不存在的行）读回来是 NULL ⇒ 契约侧必须是 nil，不能塌成 0。
        let roundTrip = SystemPerformanceSample(
            timestamp: Internals.base, cpuTotalPercent: 12, cpuSystemPercent: 3, cpuUserPercent: 9,
            memoryUsedBytes: 1 << 30, memoryTotalBytes: 1 << 34,
            diskReadBytesPerSecond: 1_024, diskWriteBytesPerSecond: 2_048, loadAverage1m: 1.5,
            networkInBytesPerSecond: 3_000, networkOutBytesPerSecond: 4_000,
            networkAvailability: .counterRegression, gpuActivityPercent: 64
        )
        let store = try await Internals.store()
        await store.append(roundTrip)
        await store.flush()
        let readBack = try await store.systemPerformance(since: Internals.base.addingTimeInterval(-60))
        let restored = readBack.first { $0.id == roundTrip.id }
        #expect(restored?.networkInBytesPerSecond == 3_000)
        #expect(restored?.networkOutBytesPerSecond == 4_000)
        #expect(restored?.networkAvailability == .counterRegression)
        #expect(restored?.gpuActivityPercent == 64)
    }

    /// P1-3 回归：重复录入同一批风险不得双计数，也不得撤销用户已确认状态。
    @Test("重复录入风险：计数派生不自增，已确认状态不被冲掉")
    func riskReRecordingIsIdempotent() async throws {
        let store = try await Internals.store()
        let sessionID = UUID()
        try await store.upsertSessions([Internals.session(id: sessionID, endedAt: Internals.offset(600))])
        let risk = RiskEvent(id: UUID(), timestamp: Internals.base, level: .high, category: .dangerousCommand,
                             title: "强制删除", detail: "rm -rf", agentKind: .claudeCode, sessionID: sessionID,
                             command: "rm -rf /tmp/x", requiresConfirmation: true)

        try await store.recordRisks([risk])
        #expect(try await store.session(id: sessionID)?.riskEventCount == 1)

        try await store.recordRisks([risk])
        try await store.recordRisks([risk])
        #expect(try await store.session(id: sessionID)?.riskEventCount == 1, "同一风险重录不得翻倍")
        #expect(try await store.riskEvents(matching: .all).totalCount == 1)

        try await store.acknowledgeRisk(id: risk.id)
        try await store.recordRisks([risk])   // 传入值 isAcknowledged == false
        let after = try #require(try await store.riskEvents(matching: .all).items.first)
        #expect(after.isAcknowledged, "重复录入不得静默撤销用户的确认")
    }

    @Test("两条不同会话的风险各自计数")
    func riskCountsArePerSession() async throws {
        let store = try await Internals.store()
        let first = UUID()
        let second = UUID()
        try await store.upsertSessions([
            Internals.session(id: first, endedAt: Internals.offset(600)),
            Internals.session(id: second, endedAt: Internals.offset(700)),
        ])
        let risks = [
            RiskEvent(timestamp: Internals.base, level: .high, category: .massDeletion, title: "a",
                      agentKind: .claudeCode, sessionID: first),
            RiskEvent(timestamp: Internals.base, level: .high, category: .massDeletion, title: "b",
                      agentKind: .claudeCode, sessionID: second),
            RiskEvent(timestamp: Internals.base, level: .medium, category: .unknown, title: "c",
                      agentKind: .claudeCode, sessionID: second),
        ]
        try await store.recordRisks(risks)
        #expect(try await store.session(id: first)?.riskEventCount == 1)
        #expect(try await store.session(id: second)?.riskEventCount == 2)
    }

    @Test("保留期清理只删 cutoff 之前的行，并按表统计")
    func pruneRemovesOnlyExpiredRows() async throws {
        let store = try await Internals.store()
        for index in 0..<4 {
            await store.append(Internals.event(at: Internals.offset(Double(index) * -86_400)))   // 0..3 天前
        }
        await store.flush()
        #expect(try await store.rowCount(table: StoreSchema.Table.events) == 4)

        let result = try await store.prune(olderThan: Internals.offset(-1.5 * 86_400), vacuum: false)
        #expect(result.cutoff == Internals.offset(-1.5 * 86_400))
        #expect(result.deletedRowsByTable[StoreSchema.Table.events] == 2)
        #expect(result.totalDeletedRows == 2)
        #expect(result.didVacuum == false)
        #expect(try await store.rowCount(table: StoreSchema.Table.events) == 2)
    }

    @Test("RetentionPruner 按 retentionDays 推算 cutoff")
    func prunerUsesPolicyRetention() async throws {
        let (store, database) = try await Internals.migratedDatabase()
        #expect(try await store.rowCount(table: StoreSchema.Table.events) == 0)
        let now = Internals.base
        let pruner = RetentionPruner(database: database, policy: .init(retentionDays: 7, vacuumAfterPrune: false))
        let expected = Calendar.current.date(byAdding: .day, value: -7, to: now)
        let result = try await pruner.prune(now: now)
        #expect(result.cutoff == expected)
        #expect(result.totalDeletedRows == 0)
    }

    @Test("deleteAllData 清空所有表")
    func deleteAllEmptiesEveryTable() async throws {
        let store = try await Internals.store()
        try await store.upsertAgents([Internals.agent(pid: 1)])
        try await store.upsertSessions([Internals.session()])
        await store.append(Internals.event(at: Internals.base))
        await store.flush()
        #expect(try await store.rowCount(table: StoreSchema.Table.agents) == 1)

        try await store.deleteAllData()
        for table in StoreSchema.allTables {
            #expect(try await store.rowCount(table: table) == 0, "\(table) 未被清空")
        }
    }
}
// MARK: - 统计口径与墙钟无关

@Suite("Store：统计口径不依赖运行时刻", .timeLimit(.minutes(1)))
struct ClockIndependenceTests {

    /// 参数化覆盖 0/1/8/13/20/23 点：含一条**运行中**会话的数据集，
    /// `totalActiveSeconds` 必须等于手工值，且不随真实当前时刻变化。
    @Test("dashboardStats 在任意墙钟时刻都自洽", arguments: [0, 1, 8, 13, 20, 23])
    func dashboardIsClockIndependent(hour: Int) async throws {
        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_700_000_000))
        let now = dayStart.addingTimeInterval(Double(hour) * 3_600 + 1_800)

        let store = try await Internals.store()
        // 种子一律从 dayStart 往后推，不能用 now 往前减：hour == 0 时
        // `now - 3000` 会掉到前一天，被 today 窗口排除，测试就会假失败。
        let closedStart = dayStart.addingTimeInterval(60)
        let closedEnd = closedStart.addingTimeInterval(1_800)
        let runningStart = dayStart.addingTimeInterval(600)
        // 手工期望值：闭合会话固定 1800 秒；运行中会话按传入 date 结算。
        let expected = 1_800 + now.timeIntervalSince(runningStart)
        try await store.upsertSessions([
            AgentSession(id: UUID(), displayIndex: 1, kind: .claudeCode, title: "闭合",
                         startedAt: closedStart, endedAt: closedEnd, outcome: .success),
            AgentSession(id: UUID(), displayIndex: 2, kind: .claudeCode, title: "运行中",
                         startedAt: runningStart, outcome: .running),
        ])

        let stats = try await store.dashboardStats(for: now)
        #expect(stats.sessionCount == 2)
        #expect(stats.totalActiveSeconds == expected)
        let share = try #require(stats.agentShares.first)
        #expect(share.totalSeconds == expected)

        // 同一个 now 再查一次：结果必须逐位相同（说明没有偷读墙钟）。
        let again = try await store.dashboardStats(for: now)
        #expect(again.totalActiveSeconds == stats.totalActiveSeconds)

        // 换个更晚的 date 结算，运行中会话的时长应当随之增长，而不是保持上次的值。
        let later = try await store.dashboardStats(for: now.addingTimeInterval(600))
        #expect(later.totalActiveSeconds == stats.totalActiveSeconds + 600,
                "换一个更晚的结算时刻，运行中会话必须随之增长")
    }

    /// `AgentSession.duration` 读墙钟，只允许出现在非统计路径；统计入口必须显式给时刻。
    @Test("TokenEstimator 结算时刻可注入且非负")
    func estimatorUsesInjectedDate() {
        let started = Date(timeIntervalSince1970: 1_700_000_000)
        let running = AgentSession(kind: .claudeCode, title: "运行中", startedAt: started, outcome: .running)
        let early = TokenEstimator().estimate(session: running, until: started.addingTimeInterval(3_600))
        let late = TokenEstimator().estimate(session: running, until: started.addingTimeInterval(7_200))
        #expect(early != nil && late != nil)
        #expect((late?.tokens ?? 0) > (early?.tokens ?? 0))
        // 起点之后之前（负时长）不得给出估算，也不得取绝对值伪造。
        #expect(TokenEstimator().estimate(session: running, until: started.addingTimeInterval(-60)) == nil)
    }
}

