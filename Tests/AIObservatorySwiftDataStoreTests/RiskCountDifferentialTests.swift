//
//  RiskCountDifferentialTests.swift
//  Tests/AIObservatorySwiftDataStoreTests
//
//  Owner: ws-engaudit
//
//  #35 修完之后，「风险计数只有一个写入者」与「一条风险对应一行时间线」这两条语义
//  必须在**两个可切换后端**上长得一样：本文件不判数值对错（那是 SQLite 侧
//  `RiskCountSingleWriterTests` 与 Engine 侧 `RiskEventIdempotencyTests` 的活），
//  只判「同一批输入，两侧结果相同」——本仓靠差分把三个后端钉在一起。
//
//  四条各管一处改动面：派生不被整行覆盖 / 与写入顺序无关 / 清理后退值 / 事件行按 id 幂等。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
@testable import AIObservatorySwiftDataStore

private let base = Date(timeIntervalSinceReferenceDate: 800_003_000)

private enum RiskDiff {
    static let session = UUID()
    static let agent = UUID()
    static let riskID = StableID.uuid(namespace: "riskdiff", key: "one")

    static func session(riskEventCount: Int = 0, startedAt: Date = base) -> AgentSession {
        AgentSession(id: session, kind: .claudeCode, agentID: agent, title: "会话 · 差分",
                     projectPath: "/work/Alpha", startedAt: startedAt, riskEventCount: riskEventCount)
    }

    static func risk(timestamp: Date = base, detail: String = "内存峰值 6.0 GB") -> RiskEvent {
        RiskEvent(id: riskID, timestamp: timestamp, level: .high, category: .resourceAbuse,
                  title: "内存峰值超限", detail: detail, agentID: agent, agentKind: .claudeCode,
                  sessionID: session, matchedRuleID: "risk.pattern.excessive-memory-peak")
    }

    /// 与 `TimelineAggregator.eventID(for:)` 同一条派生口径下的两行时间线（同一 id 写两次）。
    static func riskTimeline(timestamp: Date) -> TimelineEvent {
        TimelineEvent(
            id: StableID.uuid(namespace: "risktimeline", key: riskID.uuidString),
            timestamp: timestamp, sessionID: session, agentID: agent, agentKind: .claudeCode,
            kind: .riskDetected, title: "内存峰值超限", summary: detailish(timestamp: timestamp),
            riskLevel: .high
        )
    }

    private static func detailish(timestamp: Date) -> String {
        "时刻 \(Int(timestamp.timeIntervalSinceReferenceDate))"
    }
}

private func makePair() async throws -> (ObservatoryStore, SwiftDataObservatoryStore) {
    let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
    let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
    return (sqlite, swiftData)
}

@Suite("差分：风险计数与时间线的单一写入者语义")
struct RiskCountDifferentialTests {

    private func count(_ sqlite: ObservatoryStore, _ swiftData: SwiftDataObservatoryStore) async throws -> (Int, Int) {
        let left = try #require(await sqlite.session(id: RiskDiff.session)).riskEventCount
        let right = try #require(await swiftData.session(id: RiskDiff.session)).riskEventCount
        return (left, right)
    }

    @Test("整行 upsert 盖不动派生计数：两侧同为 1")
    func upsertCannotClobber() async throws {
        let (sqlite, swiftData) = try await makePair()
        try await sqlite.upsertSessions([RiskDiff.session()])
        try await swiftData.upsertSessions([RiskDiff.session()])
        try await sqlite.recordRisks([RiskDiff.risk()])
        try await swiftData.recordRisks([RiskDiff.risk()])

        // 携带一个绝不可能等于行数的数字：两侧都不许把它写进那一列。
        try await sqlite.upsertSessions([RiskDiff.session(riskEventCount: 40)])
        try await swiftData.upsertSessions([RiskDiff.session(riskEventCount: 40)])
        let (left, right) = try await count(sqlite, swiftData)
        #expect(left == right, "两后端必须给同一个数，实得 SQLite \(left) / SwiftData \(right)")
        #expect(left == 1, "该会话名下只有 1 行风险")
    }

    @Test("写入顺序无关：先风险后会话 与 先会话后风险 两侧都同值")
    func orderDoesNotMatter() async throws {
        let (a, b) = try await makePair()
        let (c, d) = try await makePair()
        // a：会话 → 风险；c：风险 → 会话
        try await a.upsertSessions([RiskDiff.session()])
        try await a.recordRisks([RiskDiff.risk()])
        try await c.recordRisks([RiskDiff.risk()])
        try await c.upsertSessions([RiskDiff.session()])
        let fromA = try #require(await a.session(id: RiskDiff.session)).riskEventCount
        let fromC = try #require(await c.session(id: RiskDiff.session)).riskEventCount
        #expect(fromA == fromC, "SQLite 侧两种顺序同值：\(fromA) / \(fromC)")
        // b / d 同两条序在 SwiftData 侧
        try await b.upsertSessions([RiskDiff.session()])
        try await b.recordRisks([RiskDiff.risk()])
        try await d.recordRisks([RiskDiff.risk()])
        try await d.upsertSessions([RiskDiff.session()])
        let fromB = try #require(await b.session(id: RiskDiff.session)).riskEventCount
        let fromD = try #require(await d.session(id: RiskDiff.session)).riskEventCount
        #expect(fromB == fromD, "SwiftData 侧两种顺序同值：\(fromB) / \(fromD)")
        // 注意：c / d 那一路「风险先落、会话行还没有」时重算命中 0 行，是随后那次
        // upsertSessions 里的重算补上的——两侧都补，所以四条路径都是同一个数。
        #expect(fromA == 1); #expect(fromB == 1)
    }

    @Test("清理掉风险行之后计数退到 0：两侧一致")
    func pruneRollsBackOnBoth() async throws {
        let (sqlite, swiftData) = try await makePair()
        // 会话 startedAt 比 cutoff 新，免得它自己也被同一刀删掉。
        let startedAt = base.addingTimeInterval(172_800)
        try await sqlite.upsertSessions([RiskDiff.session(startedAt: startedAt)])
        try await swiftData.upsertSessions([RiskDiff.session(startedAt: startedAt)])
        try await sqlite.recordRisks([RiskDiff.risk()])
        try await swiftData.recordRisks([RiskDiff.risk()])
        let cutoff = base.addingTimeInterval(86_400)

        _ = try await sqlite.prune(olderThan: cutoff, vacuum: false)
        _ = try await swiftData.prune(olderThan: cutoff, vacuum: false)

        let (left, right) = try await count(sqlite, swiftData)
        #expect(left == right, "两后端同为 0，实得 \(left) / \(right)")
        #expect(left == 0)
    }

    @Test("同一 id 的时间线行写两次：两侧都只有一行，且刷成新值")
    func eventUpsertIsIdempotentOnBoth() async throws {
        let (sqlite, swiftData) = try await makePair()
        let first = RiskDiff.riskTimeline(timestamp: base)
        let refreshed = RiskDiff.riskTimeline(timestamp: base.addingTimeInterval(60))
        #expect(first.id == refreshed.id, "身份由风险 id 派生 ⇒ 同一 finding 必然是同一个 id")
        try await sqlite.upsertEvents([first])
        try await sqlite.upsertEvents([refreshed])
        try await swiftData.upsertEvents([first])
        try await swiftData.upsertEvents([refreshed])

        #expect(try await sqlite.rowCount(table: "events") == 1)
        #expect(try await swiftData.rowCount(table: "events") == 1)
        let sqliteEvent = try #require((try await sqlite.events(matching: .all)).items.first)
        let swiftEvent = try #require((try await swiftData.events(matching: .all)).items.first)
        #expect(sqliteEvent == swiftEvent, "刷成同一个值：\(sqliteEvent.summary) / \(swiftEvent.summary)")
        #expect(sqliteEvent.timestamp == base.addingTimeInterval(60), "不是「丢掉第二次写」")
    }
}
