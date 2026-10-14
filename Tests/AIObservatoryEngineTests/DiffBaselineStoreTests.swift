//
//  DiffBaselineStoreTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Diff
//  ─────────────────────────────────────────────────────────
//  守 `diffs` 表 v4 迁移与「改前内容从哪来」这一列的落库口径。
//
//  为什么必须真开一个「只升到 v3 的库文件」再交给新代码：
//  在已迁移的库上少写一列，读回来也是 NULL，那只能证明「列可空」；
//  而真实事故形状是**用户磁盘上的库根本没有这一列**（`ALTER TABLE` 之后老行才是 NULL）。
//  这两种形状在「迁移有没有跑、老行会不会整条丢掉」上是不同的失败面，
//  所以这里按前者造。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryStore
@testable import AIObservatoryEngine

// MARK: - 夹具

private enum Fixtures {
    static let baselineAt = Date(timeIntervalSinceReferenceDate: 750_000_123.456)
    static let capturedAt = Date(timeIntervalSinceReferenceDate: 750_000_456.789)

    /// 旧代码写 `lines_json` 时的**逐字形状**：`DiffLine.id` 非 Optional 一定有键，
    /// 为 nil 的行号被 `encodeIfPresent` 整个省略。手工拼这条字符串是为了让
    /// 「老行长什么样」在用例里可读、可复核，而不是靠调用今天的编码器蒙混过去。
    static let legacyLinesJSON =
        "[{\"id\":\"11111111-1111-1111-1111-111111111111\",\"style\":\"removed\","
        + "\"text\":\"let token = \\\"old\\\"\",\"oldLineNumber\":1},"
        + "{\"id\":\"22222222-2222-2222-2222-222222222222\",\"style\":\"added\","
        + "\"text\":\"let token = config.apiToken\",\"newLineNumber\":1}]"

    static func diff(id: UUID, source: DiffBaselineSource, baseline: Date?) -> FileDiff {
        FileDiff(
            id: id,
            path: "/repo/Sources/Auth.swift",
            previousPath: nil,
            kind: .modified,
            lines: [
                DiffLine(style: .removed, text: "let token = \"old\"", oldLineNumber: 1),
                DiffLine(style: .added, text: "let token = config.apiToken", newLineNumber: 1),
            ],
            linesAdded: 1,
            linesRemoved: 1,
            isBinary: false,
            isTruncated: false,
            capturedAt: capturedAt,
            baselineSource: source,
            baselineCapturedAt: baseline
        )
    }

    /// 除溯源两列之外的字段 —— 迁移与回落都不许动它们。
    static func expectBusinessFields(_ diff: FileDiff, id: UUID) {
        #expect(diff.id == id)
        #expect(diff.path == "/repo/Sources/Auth.swift")
        #expect(diff.previousPath == nil)
        #expect(diff.kind == .modified)
        #expect(diff.lines.map(\.style) == [.removed, .added])
        #expect(diff.lines.map(\.text) == ["let token = \"old\"", "let token = config.apiToken"])
        #expect(diff.linesAdded == 1)
        #expect(diff.linesRemoved == 1)
        #expect(diff.isBinary == false)
        #expect(diff.isTruncated == false)
        #expect(diff.capturedAt == capturedAt)
    }
}

// MARK: - v4 迁移

@Suite("Store: diffs v4 溯源列迁移", .timeLimit(.minutes(1)))
struct DiffBaselineMigrationTests {

    @Test("v1 老库一路升到 v4：diffs 拿到两个可空溯源列")
    func legacyDatabaseGainsProvenanceColumns() async throws {
        let database = try SQLiteDatabase(configuration: .inMemory)
        _ = try await database.applyMigrations([StoreSchema.migrations[0]])
        #expect(try await database.userVersion() == 1)
        let before = Set(try await database.rows("PRAGMA table_info(diffs)").compactMap { $0.text("name") })
        #expect(!before.contains("baseline_source"))
        #expect(!before.contains("baseline_captured_at"))

        // 证据要落在列上，而不是只数迁移条数（v3 那批用例同口径）。
        #expect(try await database.applyMigrations(StoreSchema.migrations) == 3)
        #expect(try await database.userVersion() == 4)
        let after = Set(try await database.rows("PRAGMA table_info(diffs)").compactMap { $0.text("name") })
        #expect(after.contains("baseline_source"))
        #expect(after.contains("baseline_captured_at"))
        // 这两列必须可空：老行没有值，给 DEFAULT 等于替历史数据编一条供述（口径见 StoreSchema v4）。
        let notNull = try await database.rows("PRAGMA table_info(diffs)")
            .filter { ($0.int("notnull") ?? 0) != 0 }
            .compactMap { $0.text("name") }
        #expect(!notNull.contains("baseline_source"))
        #expect(!notNull.contains("baseline_captured_at"))
    }

    @Test("迁移幂等：同一库重复应用不再新增列也不报错")
    func migrationIsIdempotent() async throws {
        let database = try SQLiteDatabase(configuration: .inMemory)
        #expect(try await database.applyMigrations(StoreSchema.migrations) == 4)
        #expect(try await database.applyMigrations(StoreSchema.migrations) == 0)
        let columns = try await database.rows("PRAGMA table_info(diffs)")
            .compactMap { $0.text("name") }
        #expect(columns.filter { $0 == "baseline_source" }.count == 1)
        #expect(columns.filter { $0 == "baseline_captured_at" }.count == 1)
    }
}

// MARK: - 读写口径

@Suite("Store: 溯源列读写", .timeLimit(.minutes(1)))
struct DiffBaselineWriteReadTests {

    /// round-trip 相等 ≠ 编码正确：这里同时断底层列的**存储类与字面值**。
    @Test("baselineSource 以枚举 rawValue 文本入库，时刻以 REAL 入库")
    func provenanceLandsAsLiteralText() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let database = await store.database
        let changeID = UUID()
        try await store.record(
            Fixtures.diff(id: changeID, source: .lastObserved, baseline: Fixtures.baselineAt),
            forChangeID: changeID
        )

        let row = try #require(try await database.optionalRow(
            "SELECT baseline_source, baseline_captured_at FROM diffs WHERE change_id = ?",
            arguments: [.text(changeID.uuidString)]
        ))
        #expect(row.text("baseline_source") == "lastObserved")
        #expect(row.double("baseline_captured_at") == Fixtures.baselineAt.timeIntervalSinceReferenceDate)

        let readBack = try #require(try await store.fileDiff(for: changeID))
        #expect(readBack.baselineSource == .lastObserved)
        #expect(readBack.baselineCapturedAt == Fixtures.baselineAt)
        Fixtures.expectBusinessFields(readBack, id: changeID)
    }

    @Test("plaintextStored=false 往返不塌成 true（关掉明文这件事必须能被事后查出来）")
    func plaintextFlagRoundTrips() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let database = await store.database
        var off = Fixtures.diff(id: UUID(), source: .lastObserved, baseline: Fixtures.baselineAt)
        off.plaintextStored = false
        off.lines = []
        try await store.record(off, forChangeID: off.id)

        let stored = try #require(try await database.optionalRow(
            "SELECT plaintext_stored FROM diffs WHERE change_id = ?",
            arguments: [.text(off.id.uuidString)]
        ))
        #expect(stored.int("plaintext_stored") == 0)
        let readBack = try #require(try await store.fileDiff(for: off.id))
        #expect(readBack.plaintextStored == false)
        #expect(readBack.baselineSource == .lastObserved, "关掉明文不许顺带改掉溯源结论")
        #expect(readBack.lines.isEmpty)
    }

    @Test("notApplicable 与单边 diff 各自入库各自读回，不塌成同一个值")
    func everySourceStaysDistinct() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let cases: [(DiffBaselineSource, Date?)] = [
            (.lastObserved, Fixtures.baselineAt),
            (.unavailableFirstSighting, nil),
            (.notApplicable, nil),
        ]
        for entry in cases {
            let id = UUID()
            try await store.record(
                Fixtures.diff(id: id, source: entry.0, baseline: entry.1),
                forChangeID: id
            )
            let readBack = try #require(try await store.fileDiff(for: id))
            #expect(readBack.baselineSource == entry.0)
            #expect(readBack.baselineCapturedAt == entry.1)
        }
    }

    /// 真·老库：磁盘上的文件只到 v3，`diffs` 里已经有一行旧格式数据。
    @Test("v3 库文件 + 新代码：旧 diff 读得开，且回落为「单边 diff」")
    func legacyFileRowStillReads() async throws {
        let directory = try Scratch.directory("diff-baseline-legacy-v3")
        let filePath = directory.appendingPathComponent("observatory.sqlite").path
        let configuration = SQLiteDatabase.Configuration(location: .file(path: filePath))

        let legacyID = UUID()
        let legacy = try SQLiteDatabase(configuration: configuration)
        _ = try await legacy.applyMigrations(Array(StoreSchema.migrations[0..<3]))
        #expect(try await legacy.userVersion() == 3)
        // 逐字照旧代码的 INSERT（11 列，没有溯源列）写一行。
        try await legacy.execute([SQLiteStatement(
            """
            INSERT INTO diffs (id, change_id, path, previous_path, kind, lines_json,
                lines_added, lines_removed, is_binary, is_truncated, captured_at)
            VALUES (?,?,?,?,?,?,?,?,?,?,?)
            """,
            arguments: [
                .text(legacyID.uuidString),
                .text(legacyID.uuidString),
                .text("/repo/Sources/Auth.swift"),
                .null,
                .text("modified"),
                .text(Fixtures.legacyLinesJSON),
                .integer(1),
                .integer(1),
                .integer(0),
                .integer(0),
                .real(Fixtures.capturedAt.timeIntervalSinceReferenceDate),
            ]
        )])

        let store = try await ObservatoryStore.open(configuration: configuration)
        #expect(try await store.database.userVersion() == 4)

        let restored = try #require(try await store.fileDiff(for: legacyID),
                                   "v4 迁移不得让老 diff 整条消失")
        // 明确回落值：写这行的旧代码 `oldText` 恒为 nil ⇒ 客观上就是单边 diff。
        #expect(restored.baselineSource == .unavailableFirstSighting)
        #expect(restored.baselineCapturedAt == nil)
        // 老行确实带着正文（那是唯一的形状），所以缺列回落 true 是陈述事实，不是猜测。
        #expect(restored.plaintextStored == true)
        Fixtures.expectBusinessFields(restored, id: legacyID)
    }
}
