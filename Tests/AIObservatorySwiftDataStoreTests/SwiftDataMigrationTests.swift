//
//  SwiftDataMigrationTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: WS-SwiftData
//
//  一次性迁移（SQLite 库 → SwiftData 库）的验收测试。
//
//  源库怎么来：本测试 target 的依赖里没有 `AIObservatoryStore`（`Package.swift` 冻结），
//  所以不能用 SQLite 后端去造源库；这里改用系统 `SQLite3` 模块**按 `StoreSchema` 的
//  DDL 逐字建表**，并按 SQLite 后端的存储口径写入值（日期 REAL REF 秒、枚举 TEXT rawValue、
//  UInt64 走 `Int64(bitPattern:)` 的负数、JSON 列表是 TEXT）。
//  这样测的正是「真实源库的形状」，而不是迁移器自己臆造的形状。
//
//  覆盖 6 张表（agents / sessions / events / commands / risk_events / file_snapshots）；
//  另外 5 张（file_changes / diffs / perf_samples / system_perf / projects）**不建**，
//  用来钉「缺表按 0 行处理、不崩」这条——顺带也就是本文件未覆盖的范围，如实记录在简报里。
//

import Testing
import Foundation
import SQLite3
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatorySwiftDataStore

/// 与 `AIObservatoryStore.StoreSchema` v1/v2 DDL 逐字一致的建表语句（只取本测试用到的 6 张）。
private let sourceDDL = """
CREATE TABLE agents (
    id TEXT PRIMARY KEY, kind TEXT NOT NULL, pid INTEGER NOT NULL, parent_pid INTEGER,
    display_name TEXT NOT NULL, executable_path TEXT NOT NULL, working_directory TEXT,
    bundle_identifier TEXT, tty TEXT, started_at REAL NOT NULL, last_seen_at REAL NOT NULL,
    state TEXT NOT NULL, cpu_percent REAL NOT NULL, memory_bytes INTEGER NOT NULL,
    child_pids_json TEXT NOT NULL, detected_via TEXT NOT NULL);
CREATE TABLE sessions (
    id TEXT PRIMARY KEY, display_index INTEGER NOT NULL, kind TEXT NOT NULL, agent_id TEXT,
    title TEXT NOT NULL, project_path TEXT, started_at REAL NOT NULL, ended_at REAL,
    modified_file_count INTEGER NOT NULL, created_file_count INTEGER NOT NULL,
    deleted_file_count INTEGER NOT NULL, command_count INTEGER NOT NULL,
    failed_command_count INTEGER NOT NULL, cpu_seconds REAL NOT NULL,
    peak_cpu_percent REAL NOT NULL, peak_memory_bytes INTEGER NOT NULL,
    estimated_tokens INTEGER NOT NULL, risk_event_count INTEGER NOT NULL,
    outcome TEXT NOT NULL, search_text TEXT NOT NULL);
CREATE TABLE events (
    id TEXT PRIMARY KEY, timestamp REAL NOT NULL, session_id TEXT, agent_id TEXT,
    agent_kind TEXT NOT NULL, kind TEXT NOT NULL, title TEXT NOT NULL, summary TEXT NOT NULL,
    file_path TEXT, command TEXT, exit_code INTEGER, duration_seconds REAL,
    cost_cpu_seconds REAL NOT NULL, cost_memory_bytes INTEGER NOT NULL,
    cost_bytes_read INTEGER NOT NULL, cost_bytes_written INTEGER NOT NULL,
    risk_level TEXT NOT NULL, risk_rank INTEGER NOT NULL, project_path TEXT,
    search_text TEXT NOT NULL);
CREATE TABLE commands (
    id TEXT PRIMARY KEY, executable TEXT NOT NULL, arguments_json TEXT NOT NULL,
    working_directory TEXT, agent_id TEXT, session_id TEXT, agent_kind TEXT NOT NULL,
    started_at REAL NOT NULL, ended_at REAL, exit_code INTEGER, outcome TEXT NOT NULL,
    is_destructive INTEGER NOT NULL, requires_confirmation INTEGER NOT NULL,
    risk_level TEXT NOT NULL, risk_rank INTEGER NOT NULL, project_path TEXT,
    search_text TEXT NOT NULL);
CREATE TABLE risk_events (
    id TEXT PRIMARY KEY, timestamp REAL NOT NULL, level TEXT NOT NULL, level_rank INTEGER NOT NULL,
    category TEXT NOT NULL, title TEXT NOT NULL, detail TEXT NOT NULL, agent_id TEXT,
    agent_kind TEXT NOT NULL, session_id TEXT, command TEXT, file_paths_json TEXT NOT NULL,
    requires_confirmation INTEGER NOT NULL, is_acknowledged INTEGER NOT NULL,
    matched_rule_id TEXT, search_text TEXT NOT NULL);
CREATE TABLE file_snapshots (
    id TEXT PRIMARY KEY, path TEXT NOT NULL, content_hash TEXT NOT NULL, size_bytes INTEGER NOT NULL,
    line_count INTEGER NOT NULL, captured_at REAL NOT NULL);
"""

// MARK: - 源库 fixture

private enum Source {
    static let agent = UUID()
    static let session = UUID()
    static let goodEvent = UUID()
    static let corruptEvent = UUID()
    static let command = UUID()
    static let risk = UUID()
    static let snapshot = UUID()
    /// REF 秒带小数：迁移必须按值无损搬过去。
    static let startedAt = 800_000_000.5
    /// > Int64.max，SQLite 侧存成负数（bit-pattern）。
    static let bigBytes: UInt64 = UInt64(Int64.max) + 4_096
    static var bigBytesAsInt64: Int64 { Int64(bitPattern: bigBytes) }

    // 合成宿主布局（不落盘，只进 SQL 字面量与断言）。
    //
    // 为什么写成常量而不是各处写字面量：`search_text` 列里存的是这些路径的**小写副本**
    // （FTS 口径），原值、小写副本、断言侧三处必须同源于同一个前缀。任何一处单独手改，
    // 「迁移后仍能被小写关键词命中」这条就会变成假通过——所以小写副本一律由
    // `.lowercased()` 现算，不重复书写。
    static let projectAlpha = FixturePaths.projectAlpha
    static let projectAlphaFTS = FixturePaths.projectAlpha.lowercased()
    static let engineFile = "\(FixturePaths.projectAlpha)/Sources/Engine.swift"
    static let engineFileFTS = engineFile.lowercased()
}

/// 建源库并写入若干行。`eventCount` 决定 events 表里「批量事件」的条数（keyset 分页测试用）。
///
/// 落盘位置一律由 `Scratch.directory` 给出（ci.yml 的 G2 门禁禁止测试写死个人检出目录）：
/// 它自带唯一后缀，Swift Testing 并行跑也不会互相踩；调用方 `defer` 删掉整个目录即可，
/// `-wal` / `-shm` 兄弟文件一起走。
private func makeSourceDatabase(eventCount: Int) throws -> (url: URL, directory: URL) {
    let directory = try Scratch.directory("swiftdata-mig-source")
    let url = directory.appendingPathComponent("source.sqlite")
    var handle: OpaquePointer?
    guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
          let db = handle else {
        sqlite3_close_v2(handle)
        try? FileManager.default.removeItem(at: directory)
        throw ObservatoryError.storeUnavailable("测试无法创建源 SQLite 库")
    }
    defer { sqlite3_close_v2(db) }
    try exec(db, sourceDDL)

    let text: (String) -> String = { "'\($0.replacingOccurrences(of: "'", with: "''"))'" }
    try exec(db, """
        INSERT INTO agents VALUES (
            \(text(Source.agent.uuidString)), 'claudeCode', 4001, 3001, 'Claude Code',
            '/usr/local/bin/claude', '\(Source.projectAlpha)', NULL, '/dev/ttys003',
            \(Source.startedAt), \(Source.startedAt + 60), 'running', 12.5, \(Source.bigBytesAsInt64),
            '[4002,4003]', 'processName');
        INSERT INTO sessions VALUES (
            \(text(Source.session.uuidString)), 101, 'claudeCode', \(text(Source.agent.uuidString)),
            '重构持久层', '\(Source.projectAlpha)', \(Source.startedAt), NULL,
            3, 1, 1, 2, 0, 42.5, 78.5, \(Source.bigBytesAsInt64), 18000, 0,
            'running', '重构持久层 \(Source.projectAlphaFTS) claude code');
        INSERT INTO risk_events VALUES (
            \(text(Source.risk.uuidString)), \(Source.startedAt + 10), 'critical', 3,
            'massDeletion', '批量删除', 'rm -rf 命中构建产物', \(text(Source.agent.uuidString)),
            'claudeCode', \(text(Source.session.uuidString)), 'rm -rf ./out',
            '["\(Source.projectAlpha)/out"]', 1, 1, 'R-DANGEROUS-RM', '批量删除 rm -rf 命中构建产物 rm -rf ./out');
        INSERT INTO commands VALUES (
            \(text(Source.command.uuidString)), 'rm', '["-rf","./out"]', '\(Source.projectAlpha)',
            \(text(Source.agent.uuidString)), \(text(Source.session.uuidString)), 'claudeCode',
            \(Source.startedAt + 20), \(Source.startedAt + 21), 0, 'success', 1, 1, 'critical', 3,
            '\(Source.projectAlpha)', 'rm -rf ./out');
        INSERT INTO file_snapshots VALUES (
            \(text(Source.snapshot.uuidString)), '\(Source.projectAlpha)/a.swift',
            'sha256:abcd', \(Source.bigBytesAsInt64), 120, \(Source.startedAt + 30));
        """)

    // 一条正常事件 + 一条枚举 rawValue 无法识别的事件（后者必须被 skip 而不是伪造）。
    try exec(db, """
        INSERT INTO events VALUES (
            \(text(Source.goodEvent.uuidString)), \(Source.startedAt + 1),
            \(text(Source.session.uuidString)), \(text(Source.agent.uuidString)), 'claudeCode',
            'fileCreated', '创建 Engine.swift', '新文件', '\(Source.engineFile)',
            NULL, NULL, 1.5, 0.4, \(Source.bigBytesAsInt64), 4096, 8192, 'high', 2,
            '\(Source.projectAlpha)', '创建 engine.swift 新文件 \(Source.engineFileFTS) ');
        INSERT INTO events VALUES (
            \(text(Source.corruptEvent.uuidString)), \(Source.startedAt + 2), NULL, NULL,
            'not-a-real-agent-kind', 'fileRead', '坏行', '', NULL, NULL, NULL, NULL,
            0, 0, 0, 0, 'low', 0, NULL, '坏行');
        """)
    for index in 0..<eventCount {
        let id = UUID()
        try exec(db, """
            INSERT INTO events (id, timestamp, session_id, agent_id, agent_kind, kind, title, summary,
                file_path, command, exit_code, duration_seconds, cost_cpu_seconds, cost_memory_bytes,
                cost_bytes_read, cost_bytes_written, risk_level, risk_rank, project_path, search_text)
            VALUES (\(text(id.uuidString)), \(Source.startedAt + 100 + Double(index)), NULL, NULL,
                'openAICodex', 'fileModified', '批量事件 \(index)', '', NULL, NULL, NULL, NULL,
                0, 0, 0, 0, 'low', 0, NULL, '批量事件');
            """)
    }
    return (url, directory)
}

private func exec(_ db: OpaquePointer, _ sql: String) throws {
    var errorPointer: UnsafeMutablePointer<CChar>?
    guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
        let reason = errorPointer.map { String(cString: $0) } ?? "未知错误"
        sqlite3_free(errorPointer)
        throw ObservatoryError.storeUnavailable("测试建源库失败：\(reason)")
    }
}

// MARK: - 测试

@Suite("SQLite → SwiftData 迁移：按值还原", .timeLimit(.minutes(1)))
struct SwiftDataMigrationValueTests {

    @Test("6 类实体的字段按值搬过来，日期与 UInt64 无损")
    func migratesAllFields() async throws {
        let (source, sourceDirectory) = try makeSourceDatabase(eventCount: 0)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let report = try await SwiftDataMigrator(sourceURL: source, destination: store).migrate()

        #expect(report.totalSkipped == 1, "只应有那条坏枚举的行被跳过：\(report.totalSkipped)")
        #expect(report.countsByEntity[.agents]?.written == 1)
        #expect(report.countsByEntity[.sessions]?.written == 1)
        // events：1 条正常 + 1 条坏 + 0 条批量 = 读到 2、写入 1
        #expect(report.countsByEntity[.events]?.read == 2)
        #expect(report.countsByEntity[.events]?.written == 1)
        #expect(report.countsByEntity[.commands]?.written == 1)
        #expect(report.countsByEntity[.riskEvents]?.written == 1)
        #expect(report.countsByEntity[.fileSnapshots]?.written == 1)

        let session = try #require(try await store.session(id: Source.session))
        #expect(session.title == "重构持久层")
        #expect(session.projectPath == Source.projectAlpha)
        #expect(session.displayIndex == 101)
        #expect(session.kind == .claudeCode)
        #expect(session.outcome == .running)
        #expect(session.agentID == Source.agent)
        #expect(session.endedAt == nil, "NULL 必须还原成 nil，不能变成某个日期")
        // REAL REF 秒 → Date：小数部分必须留住
        #expect(session.startedAt.timeIntervalSinceReferenceDate == Source.startedAt)
        #expect(session.peakMemoryBytes == Source.bigBytes, "负 INTEGER 要还原成原始 UInt64")
        #expect(session.cpuSeconds == 42.5)

        let agents = try await store.activeAgents()
        #expect(agents.count == 1)
        let agent = try #require(agents.first)
        #expect(agent.pid == 4001)
        #expect(agent.parentPID == 3001)
        #expect(agent.memoryBytes == Source.bigBytes)
        #expect(agent.childPIDs == [4002, 4003], "child_pids_json 要解成 [Int32]")
        #expect(agent.detectedVia == .processName)
        #expect(agent.bundleIdentifier == nil)

        let events = try await store.events(matching: .all)
        #expect(events.items.count == 1, "坏枚举行不得伪造进来")
        let event = try #require(events.items.first)
        #expect(event.id == Source.goodEvent)
        #expect(event.kind == .fileCreated)
        #expect(event.riskLevel == .high)
        #expect(event.cost.memoryBytes == Source.bigBytes)
        #expect(event.exitCode == nil)
        #expect(event.durationSeconds == 1.5)
        #expect(event.timestamp.timeIntervalSinceReferenceDate == Source.startedAt + 1)

        let commands = try await store.commands(matching: .all)
        let command = try #require(commands.items.first)
        #expect(command.arguments == ["-rf", "./out"])
        #expect(command.isDestructive)
        #expect(command.exitCode == 0)
        #expect(command.outcome == .success)
        #expect(command.endedAt?.timeIntervalSinceReferenceDate == Source.startedAt + 21)

        let risks = try await store.riskEvents(matching: .all)
        let risk = try #require(risks.items.first)
        #expect(risk.filePaths == ["\(Source.projectAlpha)/out"])
        #expect(risk.isAcknowledged, "is_acknowledged=1 必须还原成 true")
        #expect(risk.matchedRuleID == "R-DANGEROUS-RM")
        #expect(risk.level == .critical)

        #expect(try await store.rowCount(table: "file_snapshots") == 1)
    }

    @Test("recordRisks 的会话风险计数按迁移结果重算")
    func recomputesSessionRiskCount() async throws {
        let (source, sourceDirectory) = try makeSourceDatabase(eventCount: 0)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        _ = try await SwiftDataMigrator(sourceURL: source, destination: store).migrate()
        // 源库里 sessions.risk_event_count 是 0，但有 1 条风险挂在它身上 → 迁移后应被结算为 1。
        let session = try #require(try await store.session(id: Source.session))
        #expect(session.riskEventCount == 1)
        #expect(session.isActive, "ended_at 为 NULL 的会话迁移后仍是进行中")
        #expect(try await store.openSessionCount() == 1)
    }

    @Test("缺表按 0 行处理，不抛错")
    func toleratesMissingTables() async throws {
        let (source, sourceDirectory) = try makeSourceDatabase(eventCount: 0)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let report = try await SwiftDataMigrator(sourceURL: source, destination: store).migrate()
        for entity in [SwiftDataMigrationEntity.fileChanges, .diffs, .perfSamples, .systemPerf, .projects] {
            #expect(report.countsByEntity[entity]?.read == 0, "\(entity) 缺表应为 0 行")
            #expect(report.countsByEntity[entity]?.written == 0)
        }
        #expect(try await store.rowCount(table: "projects") == 0)
    }

    @Test("源库不存在时抛 storeUnavailable，不静默产出空报告")
    func missingSourceThrows() async throws {
        let directory = try Scratch.directory("swiftdata-mig-ghost")
        defer { try? FileManager.default.removeItem(at: directory) }
        let ghost = directory.appendingPathComponent("definitely-not-here.sqlite")
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        await #expect(throws: (any Error).self) {
            try await SwiftDataMigrator(sourceURL: ghost, destination: store).migrate()
        }
    }
}

@Suite("SQLite → SwiftData 迁移：可重入与分页", .timeLimit(.minutes(1)))
struct SwiftDataMigrationReentrancyTests {

    /// 本任务验收第 4 条：跑两次不产生重复行。
    @Test("迁移两次后每张表行数不变")
    func secondRunAddsNothing() async throws {
        let (source, sourceDirectory) = try makeSourceDatabase(eventCount: 12)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)

        let first = try await SwiftDataMigrator(sourceURL: source, destination: store).migrate()
        var countsAfterFirst: [String: Int] = [:]
        for table in ["agents", "sessions", "events", "commands", "risk_events", "file_snapshots"] {
            countsAfterFirst[table] = try await store.rowCount(table: table)
        }
        #expect(countsAfterFirst["events"] == 13, "1 好 + 12 批量（坏枚举行被跳过）")

        let second = try await SwiftDataMigrator(sourceURL: source, destination: store).migrate()
        #expect(second.totalRead == first.totalRead, "第二次仍应完整读一遍源库")
        #expect(second.totalWritten == first.totalWritten, "覆盖式写入，条数一致")
        for table in countsAfterFirst.keys {
            #expect(try await store.rowCount(table: table) == countsAfterFirst[table],
                    "重跑迁移后 \(table) 行数变了 → 产生了重复行")
        }

        let third = try await SwiftDataMigrator(sourceURL: source, destination: store).migrate()
        #expect(third.totalRead == first.totalRead)
        #expect(try await store.rowCount(table: "events") == 13, "第三次仍不增行")
    }

    /// keyset 游标必须按**读到的行**推进，而不是按解码成功的行推进；
    /// 否则遇到坏行就会停在原地，导致后面的行永远迁不过来（或死循环）。
    @Test("chunkSize 小于行数时逐页推进，不丢行也不重复")
    func keysetPagingAcrossChunks() async throws {
        let (source, sourceDirectory) = try makeSourceDatabase(eventCount: 25)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let report = try await SwiftDataMigrator(sourceURL: source, destination: store,
                                                 chunkSize: 4).migrate()
        #expect(report.countsByEntity[.events]?.read == 27, "2 条种子 + 25 条批量")
        #expect(report.countsByEntity[.events]?.written == 26)
        #expect(try await store.rowCount(table: "events") == 26)

        // 翻完所有页：id 集合大小等于行数（不重复），且时间戳覆盖到最后一页。
        let all = try await store.events(matching: EventQuery(limit: 100, sort: .oldestFirst))
        #expect(all.items.count == 26)
        #expect(Set(all.items.map { $0.id }).count == 26)
        #expect(all.items.last?.timestamp.timeIntervalSinceReferenceDate
                == Source.startedAt + 100 + 24, "最后一批事件必须也迁进来")
    }

    @Test("迁移两次：目标库内容逐字段仍等于源库（覆盖式写入不损数据）")
    func secondRunPreservesValues() async throws {
        let (source, sourceDirectory) = try makeSourceDatabase(eventCount: 0)
        defer { try? FileManager.default.removeItem(at: sourceDirectory) }
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let migrator = SwiftDataMigrator(sourceURL: source, destination: store)
        _ = try await migrator.migrate()
        let afterFirst = try #require(try await store.session(id: Source.session))
        _ = try await migrator.migrate()
        let afterSecond = try #require(try await store.session(id: Source.session))
        #expect(afterFirst == afterSecond)
        // 会话的 riskEventCount 由 recordRisks 结算，重跑不得翻倍
        #expect(afterSecond.riskEventCount == 1)
    }
}
