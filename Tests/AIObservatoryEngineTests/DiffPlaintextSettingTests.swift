//
//  DiffPlaintextSettingTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Diff
//  ─────────────────────────────────────────────────────────
//  AGENTS.md §7：「禁止采集文件内容明文（除 diff 所需的最小片段，**且需可关闭**）」。
//  `diffs.lines_json` 一直在存正文，而「可关闭」这半句从来没被实现——
//  这份测试就是那半句的可执行版本：开关拨到关，库里必须一个正文字节都没有，
//  但增删统计与「这份内容是哪一份」的指纹还得留着，否则产品只剩一片空白。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore

// 由 `shasum -a 256` 独立算出后抄进来：不是在本仓库里再跑一遍同一个算法，
// 因此算法或前缀格式被改坏时这两条常量会红。
private let firstVersionHash = "f3220283d05d1ff2ae350cfe9e0e367cb5aef46e10efb203c8a53c678e2218c8"
private let secondVersionHash = "5e3ae5c6097e0543044b114478d66704d097752981a0156abab5c5d04e5105e3"

@Suite("Engine: diff 明文开关（#15 / 隐私 §7）", .timeLimit(.minutes(1)))
struct DiffPlaintextSettingTests {

    /// 走一遍「先创建、再修改」，返回两条变更。
    private func runPipeline(
        plaintext: Bool,
        path: String,
        started: Date
    ) async throws -> (harness: DiffHarness, created: FileChange, modified: FileChange) {
        let harness = try await makeDiffHarness(plaintext: plaintext)
        harness.snapshotter.setContent(firstVersion, forPath: path)
        harness.observer.emit(rawEvent(path, .created, at: started, sizeBytes: 18))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        harness.snapshotter.setContent(secondVersion, forPath: path)
        harness.observer.emit(rawEvent(path, .modified, at: started.addingTimeInterval(6), sizeBytes: 33))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 2
        }
        await harness.store.flush()
        return (
            harness,
            try await changeRow(of: harness.engine, path: path, kind: .created),
            try await changeRow(of: harness.engine, path: path, kind: .modified)
        )
    }

    @Test("关掉明文：库里一个正文字节都没有，但统计、溯源与指纹都还在")
    func offKeepsOnlyStatsAndHash() async throws {
        let started = Date(timeIntervalSince1970: 1_900_100_000)
        let path = "\(fixtureRoot)/Sources/Private.swift"
        let (harness, created, modified) = try await runPipeline(
            plaintext: false, path: path, started: started
        )

        for change in [created, modified] {
            let diff = try #require(
                try await harness.engine.fileDiff(for: change.id),
                "关掉明文只关内容，不许把这条 diff 一起关掉"
            )
            #expect(diff.plaintextStored == false)
            #expect(diff.lines.isEmpty, "关了开关还把正文写进 lines_json = 开关是假的")
            #expect(!diff.isBinary && !diff.isTruncated)
        }

        let modifiedDiff = try #require(try await harness.engine.fileDiff(for: modified.id))
        #expect(modifiedDiff.baselineSource == .lastObserved,
                "开关只关内容；「这次确实比得了」这个结论必须照记")
        #expect(modifiedDiff.baselineCapturedAt == started, "Before 的时刻也不受开关影响")
        #expect(modifiedDiff.linesAdded == 2 && modifiedDiff.linesRemoved == 1)
        #expect(modified.linesAdded == 2 && modified.linesRemoved == 1,
                "行增删统计是关掉了明文之后剩下的全部信息量")

        let createdDiff = try #require(try await harness.engine.fileDiff(for: created.id))
        #expect(createdDiff.baselineSource == .unavailableFirstSighting)
        #expect(createdDiff.linesAdded == 3)

        let database = await harness.store.database
        let row = try #require(try await database.optionalRow(
            "SELECT content_hash, size_bytes, line_count FROM file_snapshots WHERE path = ? AND captured_at = ?",
            arguments: [.text(path), .real(started.addingTimeInterval(6).timeIntervalSinceReferenceDate)]
        ))
        #expect(row.text("content_hash") == secondVersionHash)
        #expect(row.int("size_bytes") == secondVersion.utf8.count)
        #expect(row.int("line_count") == 4)
    }

    @Test("默认开着明文：逐行内容照旧入库（开关不许顺带改掉既有行为）")
    func onKeepsLineContent() async throws {
        let started = Date(timeIntervalSince1970: 1_900_110_000)
        let path = "\(fixtureRoot)/Sources/Public.swift"
        let (harness, _, modified) = try await runPipeline(
            plaintext: true, path: path, started: started
        )

        let diff = try #require(try await harness.engine.fileDiff(for: modified.id))
        #expect(diff.plaintextStored == true)
        #expect(diff.lines.filter { $0.style == .removed }.map(\.text) == ["beta"])
        #expect(diff.lines.filter { $0.style == .added }.map(\.text) == ["BETA CHANGED", "delta"])
    }

    /// 只读到了前 `maxSnippetBytes` 时，那段前缀的 hash **不等于**文件内容的 hash。
    /// 写进 `file_snapshots` 会让日后拿整文件算出的 hash 对不上，还看起来像被篡改过；
    /// 宁可不写这一条快照。
    @Test("内容可能被截断时不写 hash，但 diff 统计照记")
    func truncatedSnippetGetsNoHash() async throws {
        let started = Date(timeIntervalSince1970: 1_900_120_000)
        let path = "\(fixtureRoot)/Sources/Big.swift"
        let harness = try await makeDiffHarness(plaintext: false)

        harness.snapshotter.setContent(firstVersion, forPath: path)
        harness.observer.emit(rawEvent(path, .created, at: started, sizeBytes: 18))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        let big = String(repeating: "a", count: 64 * 1024)
        harness.snapshotter.setContent(big, forPath: path)
        harness.observer.emit(rawEvent(path, .modified, at: started.addingTimeInterval(6), sizeBytes: UInt64(big.utf8.count)))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 2
        }
        await harness.store.flush()

        let modified = try await changeRow(of: harness.engine, path: path, kind: .modified)
        let diff = try #require(try await harness.engine.fileDiff(for: modified.id))
        #expect(diff.plaintextStored == false)
        #expect(diff.lines.isEmpty)
        #expect(diff.linesAdded == 1 && diff.linesRemoved == 3)
        // 读到的正好是 64 KB ⇒ 这份 diff 的两端可能都被切过，必须自称「已截断」，
        // 否则界面上那组行数看起来像整文件的精确测量。
        #expect(diff.isTruncated, "按前缀算出来的行数不许冒充全文测量")

        let database = await harness.store.database
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM file_snapshots") == 1,
                "只有那条没被截断的创建事件该有快照")
        let kept = try #require(try await database.optionalRow(
            "SELECT content_hash, line_count FROM file_snapshots"
        ))
        #expect(kept.text("content_hash") == firstVersionHash)
        #expect(kept.int("line_count") == 3)
    }

    @Test("明文开着时不额外读盘写快照（这个开关不是多一遍 IO 的开关）")
    func onDoesNotWriteSnapshots() async throws {
        let started = Date(timeIntervalSince1970: 1_900_130_000)
        let path = "\(fixtureRoot)/Sources/NoSnapshot.swift"
        let (harness, _, _) = try await runPipeline(
            plaintext: true, path: path, started: started
        )
        let database = await harness.store.database
        #expect(try await database.scalarInt("SELECT COUNT(*) FROM file_snapshots") == 0)
    }
}
