//
//  DiffBaselineSwiftDataParityTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: WS-Diff
//  ─────────────────────────────────────────────────────────
//  需求「三套 store 等价」里 SwiftData 这一套的溯源列。
//
//  为什么两后端的对账不够：`swiftDiff == sqliteDiff` 这种断言对**对称错误**免疫——
//  如果两边都默默把 `baselineSource` 丢掉，等式照样成立，而界面上「与上次观测对比」
//  这句话就变成了「首次观测」。所以这里每个期望值都是手写字面量，不从另一侧读回。
//
//  「老库里根本没有这一列」在 SwiftData 侧无法用两个模型版本同时存在来演（一个二进制里
//  只有一份 schema），这里用「列值为 nil 的记录」代理：自动迁移给老行的正是 nil。
//

import Testing
import Foundation
import SwiftData
import SQLite3
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport
@testable import AIObservatorySwiftDataStore

// MARK: - 夹具

private let baselineAt = Date(timeIntervalSinceReferenceDate: 750_000_123.456)
private let capturedAt = Date(timeIntervalSinceReferenceDate: 750_000_456.789)

private func diffValue(
    id: UUID,
    source: DiffBaselineSource,
    baseline: Date?
) -> FileDiff {
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

// MARK: - 读写

@Suite("SwiftData: diff 溯源列读写", .timeLimit(.minutes(1)))
struct SwiftDataDiffBaselineTests {

    /// 「明文被关掉」这件事必须能在事后被查出来，否则换台机器/换个后端就说不清
    /// 一行都没有是设置的效果还是这次真的没改东西。
    @Test("plaintextStored=false 在 SwiftData 侧往返不塌成 true")
    func plaintextFlagRoundTrips() async throws {
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        var off = diffValue(id: UUID(), source: .lastObserved, baseline: baselineAt)
        off.plaintextStored = false
        off.lines = []
        try await store.record(off, forChangeID: off.id)

        let readBack = try #require(try await store.fileDiff(for: off.id))
        #expect(readBack.plaintextStored == false)
        #expect(readBack.lines.isEmpty)
        #expect(readBack.baselineSource == .lastObserved)

        var on = diffValue(id: UUID(), source: .unavailableFirstSighting, baseline: nil)
        on.plaintextStored = true
        try await store.record(on, forChangeID: on.id)
        #expect(try await store.fileDiff(for: on.id)?.plaintextStored == true)
    }

    @Test("lastObserved 与它的时刻各自入库、各自读回，小数时刻无损")
    func provenanceRoundTrips() async throws {
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let changeID = UUID()
        try await store.record(diffValue(id: changeID, source: .lastObserved, baseline: baselineAt),
                               forChangeID: changeID)

        let readBack = try #require(try await store.fileDiff(for: changeID))
        #expect(readBack.baselineSource == .lastObserved)
        #expect(readBack.baselineCapturedAt?.timeIntervalSinceReferenceDate
                == baselineAt.timeIntervalSinceReferenceDate)
        // 溯源之外的一条都不许掉
        #expect(readBack.id == changeID)
        #expect(readBack.kind == .modified)
        #expect(readBack.lines.map(\.text) == ["let token = \"old\"", "let token = config.apiToken"])
        #expect(readBack.linesAdded == 1 && readBack.linesRemoved == 1)
        #expect(readBack.capturedAt == capturedAt)
    }

    @Test("三个枚举值在 SwiftData 侧互不塌缩，NULL 时刻不变成某个日期")
    func everySourceStaysDistinct() async throws {
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let cases: [(DiffBaselineSource, Date?)] = [
            (.lastObserved, baselineAt),
            (.unavailableFirstSighting, nil),
            (.notApplicable, nil),
        ]
        for entry in cases {
            let id = UUID()
            try await store.record(diffValue(id: id, source: entry.0, baseline: entry.1), forChangeID: id)
            let readBack = try #require(try await store.fileDiff(for: id))
            #expect(readBack.baselineSource == entry.0)
            #expect(readBack.baselineCapturedAt == entry.1, "缺时刻不许造一个时刻出来")
        }
    }

    /// 老行（自动迁移后列为 nil）与认不出的值都只能落到「单边 diff」。
    /// 丢整条不行：那会让界面把「有 diff」显示成「没有 diff」。
    @Test("列为 nil / 值认不出 ⇒ 回落单边 diff，其余字段照旧读回")
    func missingOrUnknownColumnFallsBack() throws {
        let changeID = UUID()
        let stored = SDDiff(diffValue(id: changeID, source: .lastObserved, baseline: baselineAt),
                            changeID: changeID)
        #expect(stored.domainValue()?.baselineSource == .lastObserved, "映射不许是恒返回某个常数的摆设")

        stored.baselineSource = nil
        let legacy = try #require(stored.domainValue())
        #expect(legacy.baselineSource == .unavailableFirstSighting)
        #expect(legacy.baselineCapturedAt == baselineAt, "回落只管来源一列，不许牵连时刻")
        #expect(legacy.lines.count == 2)

        stored.baselineSource = "gitHead"
        #expect(stored.domainValue()?.baselineSource == .unavailableFirstSighting)

        // v4 之前建的库自动迁移后这一列也是 nil：老记录唯一正确的解释是「存了明文」。
        stored.plaintextStored = nil
        #expect(stored.domainValue()?.plaintextStored == true)
        stored.plaintextStored = false
        #expect(stored.domainValue()?.plaintextStored == false)
    }
}

// MARK: - 迁移通路

@Suite("SwiftData: 从 SQLite 搬 diff 时带上溯源", .timeLimit(.minutes(1)))
struct SwiftDataDiffMigrationTests {

    /// 只建 `diffs` 一张表：迁移器对缺表是容忍的（`toleratesMissingTables` 已证），
    /// 不复用别人那份 6 表 fixture，避免把别人的行数期望值一起动了。
    private static let ddl = """
    CREATE TABLE diffs (
        id TEXT PRIMARY KEY, change_id TEXT NOT NULL UNIQUE, path TEXT NOT NULL,
        previous_path TEXT, kind TEXT NOT NULL, lines_json TEXT NOT NULL,
        lines_added INTEGER NOT NULL, lines_removed INTEGER NOT NULL,
        is_binary INTEGER NOT NULL, is_truncated INTEGER NOT NULL, captured_at REAL NOT NULL,
        baseline_source TEXT, baseline_captured_at REAL);
    """

    private static func linesJSON(id: String) -> String {
        """
        [{"id":"\(id)","style":"removed","text":"let token = \\"old\\"","oldLineNumber":1}]
        """
    }

    @Test("有溯源的行按值搬走，NULL 的行落到「单边 diff」而不是丢行")
    func migratesProvenanceAndNull() async throws {
        let directory = try Scratch.directory("swiftdata-diff-baseline")
        let source = directory.appendingPathComponent("source.sqlite")
        defer { try? FileManager.default.removeItem(at: directory) }

        let withBaseline = UUID()
        let withoutBaseline = UUID()
        var handle: OpaquePointer?
        guard sqlite3_open_v2(source.path, &handle, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
              let db = handle else {
            sqlite3_close_v2(handle)
            throw ObservatoryError.storeUnavailable("测试无法创建源 SQLite 库")
        }
        defer { sqlite3_close_v2(db) }
        try Self.exec(Self.ddl, on: db)
        let json = Self.linesJSON(id: UUID().uuidString)
        try Self.exec("""
            INSERT INTO diffs VALUES (
                '\(withBaseline.uuidString)', '\(withBaseline.uuidString)',
                '/repo/Sources/Auth.swift', NULL, 'modified', '\(json)', 1, 1, 0, 0,
                \(capturedAt.timeIntervalSinceReferenceDate), 'lastObserved', \(baselineAt.timeIntervalSinceReferenceDate));
            INSERT INTO diffs VALUES (
                '\(withoutBaseline.uuidString)', '\(withoutBaseline.uuidString)',
                '/repo/Sources/Legacy.swift', NULL, 'created', '\(json)', 1, 0, 0, 0,
                \(capturedAt.timeIntervalSinceReferenceDate), NULL, NULL);
            """, on: db)

        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let report = try await SwiftDataMigrator(sourceURL: source, destination: store).migrate()
        #expect(report.countsByEntity[.diffs]?.read == 2)
        #expect(report.countsByEntity[.diffs]?.written == 2, "溯源为 NULL 的老行不是坏行，不该被跳过")

        let migrated = try #require(try await store.fileDiff(for: withBaseline))
        #expect(migrated.baselineSource == .lastObserved)
        #expect(migrated.baselineCapturedAt?.timeIntervalSinceReferenceDate
                == baselineAt.timeIntervalSinceReferenceDate)
        #expect(migrated.path == "/repo/Sources/Auth.swift")

        let legacy = try #require(try await store.fileDiff(for: withoutBaseline))
        #expect(legacy.baselineSource == .unavailableFirstSighting)
        #expect(legacy.baselineCapturedAt == nil)
        #expect(legacy.path == "/repo/Sources/Legacy.swift")
    }

    private static func exec(_ sql: String, on db: OpaquePointer) throws {
        var errorPointer: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errorPointer) == SQLITE_OK else {
            let reason = errorPointer.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errorPointer)
            throw ObservatoryError.storeUnavailable("测试建源库失败：\(reason)")
        }
    }
}
