//
//  SampleReadLimitDifferentialTests.swift
//  Tests/AIObservatorySwiftDataStoreTests
//
//  Owner: ws-engaudit
//
//  #38：性能曲线的两条取数没有上限。`systemPerformance(since:)` 与会话级
//  `performanceSamples(sessionID:)` 都是 `SELECT *`，按 `retentionDays`（默认 30 天）
//  整段捞回，**然后**才在 UI 里 `suffix(1000)`（`PerformanceModel.swift:365/391/402`）。
//  3 s 一拍 ⇒ 30 天是 86 万行的量级，翻页一次就重建一遍这个数量的对象。
//
//  修法：`ORDER BY timestamp DESC, id DESC LIMIT ?` 取尾部再翻回升序。
//  本文件判三件事，每件都两侧一起判：
//   1. 只返回最新 N 条（库里塞 N+500 行时仍然只有 N 条 ⇒ 挡住"悄悄退化成全表"）；
//   2. 返回顺序与无界版逐字相同 ⇒ 加 LIMIT 不改口径；
//   3. 无界那条（冻结契约成员）行为一字未变 ⇒ 没有偷偷改别人的语义。
//
//  ⚠️ 两侧都有的 `limit <= 0 → 空数组` 是**刻意的**：SQLite 的 `LIMIT -1` 与
//  SwiftData 的 `limit: 0` 都是"不设限"，直传会把要修的退化重新敞开（各 1 条用例钉着）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
@testable import AIObservatorySwiftDataStore

private let sampleBase = Date(timeIntervalSinceReferenceDate: 800_008_000)

/// 1 200 行样本、取最新 700 ⇒ 跳过最旧的 500（这就是"N+500"那一条）。
private let seededRows = 1_200
private let readLimit = 700
private let skippedRows = seededRows - readLimit

private enum SampleLimit {
    static let session = UUID()
    static let agent = UUID()

    static func systemID(_ index: Int) -> UUID {
        StableID.uuid(namespace: "samplelimit", key: "system-\(index)")
    }

    static func sessionSampleID(_ index: Int) -> UUID {
        StableID.uuid(namespace: "samplelimit", key: "session-\(index)")
    }

    static func timestamp(_ index: Int) -> Date {
        sampleBase.addingTimeInterval(Double(index))
    }

    static func systemSample(_ index: Int) -> SystemPerformanceSample {
        SystemPerformanceSample(
            id: systemID(index),
            timestamp: timestamp(index),
            cpuTotalPercent: Double(index % 100),
            memoryUsedBytes: UInt64(1_024 * (index + 1)),
            memoryTotalBytes: 16 * 1_024 * 1_024 * 1_024
        )
    }

    static func sessionSample(_ index: Int) -> PerformanceSample {
        PerformanceSample(
            id: sessionSampleID(index),
            timestamp: timestamp(index),
            sessionID: session,
            agentID: agent,
            cpuPercent: Double(index % 90),
            memoryBytes: UInt64(2_048 * (index + 1))
        )
    }
}

private func makePair() async throws -> (ObservatoryStore, SwiftDataObservatoryStore) {
    let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
    let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
    for index in 0..<seededRows {
        await sqlite.append(SampleLimit.systemSample(index))
        await sqlite.append(SampleLimit.sessionSample(index))
        await swiftData.append(SampleLimit.systemSample(index))
        await swiftData.append(SampleLimit.sessionSample(index))
    }
    await sqlite.flush()
    await swiftData.flush()
    return (sqlite, swiftData)
}

@Suite("性能采样取数的上限：SQLite 与 SwiftData 一致")
struct SampleReadLimitDifferentialTests {

    // MARK: - 1. 只返回最新 N 条

    @Test("整机采样：库里 1200 行只取回最新 700 条，且是升序的最后一段")
    func systemSamplesAreBounded() async throws {
        let (sqlite, swiftData) = try await makePair()

        let fromSQLite = try await sqlite.systemPerformance(since: sampleBase, limit: readLimit)
        let fromSwiftData = try await swiftData.systemPerformance(since: sampleBase, limit: readLimit)
        for (name, page) in [("SQLite", fromSQLite), ("SwiftData", fromSwiftData)] {
            #expect(page.count == readLimit, "\(name) 侧只该返回 \(readLimit) 条，实得 \(page.count) —— 数目不对就是 LIMIT 没生效（悄悄退化成全表）")
            // 手推：跳过的必然最旧的 500 条 ⇒ 首条是 index 500，末条是最后一条。
            #expect(page.first?.id == SampleLimit.systemID(skippedRows),
                    "\(name) 侧首条应为第 \(skippedRows) 行的样本")
            #expect(page.last?.id == SampleLimit.systemID(seededRows - 1),
                    "\(name) 侧末条必须是最新那条（截断截的是尾部，不是头部）")
            #expect(page.map(\.timestamp) == page.map(\.timestamp).sorted(),
                    "\(name) 侧返回仍是时间升序")
        }
        #expect(fromSQLite.map(\.id) == fromSwiftData.map(\.id), "两后端逐行同序同集")
    }

    @Test("会话采样：同一口径，最新 700 条升序")
    func sessionSamplesAreBounded() async throws {
        let (sqlite, swiftData) = try await makePair()
        let fromSQLite = try await sqlite.performanceSamples(sessionID: SampleLimit.session, limit: readLimit)
        let fromSwiftData = try await swiftData.performanceSamples(sessionID: SampleLimit.session, limit: readLimit)
        #expect(fromSQLite.count == readLimit)
        let expectedIDs = (skippedRows..<seededRows).map { SampleLimit.sessionSampleID($0) }
        #expect(fromSQLite.map(\.id) == expectedIDs, "手推：跳过的必然是最旧的 \(skippedRows) 条")
        #expect(fromSQLite.map(\.id) == fromSwiftData.map(\.id), "两后端逐行同序同集")
    }

    // MARK: - 2. 与无界版同口径

    @Test("样本数不超过 limit 时：带限与无界逐字相同（加 LIMIT 没改口径）")
    func boundedMatchesUnboundedWhenNothingIsCut() async throws {
        let (sqlite, swiftData) = try await makePair()
        // `try` 不能出现在 `==` 右侧，所以两侧都先绑成局部量再比。
        let sqliteBounded = try await sqlite.systemPerformance(since: sampleBase, limit: seededRows * 4)
        let sqliteAll = try await sqlite.systemPerformance(since: sampleBase)
        #expect(sqliteBounded == sqliteAll)
        let swiftBounded = try await swiftData.systemPerformance(since: sampleBase, limit: seededRows * 4)
        let swiftAll = try await swiftData.systemPerformance(since: sampleBase)
        #expect(swiftBounded == swiftAll)
        let sqliteSessionBounded = try await sqlite.performanceSamples(sessionID: SampleLimit.session, limit: seededRows * 4)
        let sqliteSessionAll = try await sqlite.performanceSamples(sessionID: SampleLimit.session)
        #expect(sqliteSessionBounded == sqliteSessionAll)
        let swiftSessionBounded = try await swiftData.performanceSamples(sessionID: SampleLimit.session, limit: seededRows * 4)
        let swiftSessionAll = try await swiftData.performanceSamples(sessionID: SampleLimit.session)
        #expect(swiftSessionBounded == swiftSessionAll)
    }

    /// 契约成员是「整段捞回」，本车道**没有**改它（那会同时改掉 UI 与 `AnalysisProvider` 的输入）。
    /// 这条把它钉住：谁哪天顺手在无界版本里塞了个 LIMIT，这里立刻红。
    @Test("冻结契约那条无界方法行为未变（两侧都还是全量）")
    func unboundedContractMethodsStillReturnEverything() async throws {
        let (sqlite, swiftData) = try await makePair()
        #expect(try await sqlite.systemPerformance(since: sampleBase).count == seededRows)
        #expect(try await swiftData.systemPerformance(since: sampleBase).count == seededRows)
        #expect(try await sqlite.performanceSamples(sessionID: SampleLimit.session).count == seededRows)
        #expect(try await swiftData.performanceSamples(sessionID: SampleLimit.session).count == seededRows)
    }

    // MARK: - 3. 非正数上限不许退化成全表

    @Test("limit 为 0 或负数：两侧都返回空数组，而不是「不设限」")
    func nonPositiveLimitDoesNotSilentlyUnlimit() async throws {
        let (sqlite, swiftData) = try await makePair()
        for limit in [0, -1, -10_000] {
            #expect(try await sqlite.systemPerformance(since: sampleBase, limit: limit).isEmpty, "SQLite 的 LIMIT -1 语义是不设限，必须在进 SQL 前挡掉（limit=\(limit)）")
            #expect(try await swiftData.systemPerformance(since: sampleBase, limit: limit).isEmpty, "SwiftData 的 limit: 0 同样可能被解释成不设限（limit=\(limit)）")
            #expect(try await sqlite.performanceSamples(sessionID: SampleLimit.session, limit: limit).isEmpty)
            #expect(try await swiftData.performanceSamples(sessionID: SampleLimit.session, limit: limit).isEmpty)
        }
    }

    @Test("时间下界仍生效：带限不是「拿最新的 N 条 regardless of 范围」")
    func lowerBoundStillApplies() async throws {
        let (sqlite, swiftData) = try await makePair()
        let since = SampleLimit.timestamp(seededRows - 100)
        let fromSQLite = try await sqlite.systemPerformance(since: since, limit: 10_000)
        let fromSwiftData = try await swiftData.systemPerformance(since: since, limit: 10_000)
        #expect(fromSQLite.count == 100, "下界之后只有 100 行，实得 \(fromSQLite.count)")
        #expect(fromSQLite.map(\.id) == fromSwiftData.map(\.id))
        #expect(fromSQLite.first?.id == SampleLimit.systemID(seededRows - 100))
    }
}
