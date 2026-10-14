//
//  RiskEventIdempotencyTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws-engaudit
//
//  P0 #35：一条风险的三个下游各有几个主人，重发时会多出几行。
//
//  真库证据（`ai-observatory/tmp/verify-realdata/observatory.sqlite`，`-readonly` 查得）：
//    · 「内存峰值超限」在 `events` 里有 **43** 行，`risk_events` 里同规则只有 **2** 行；
//    · 「同一目录被成批清空」`events` 7 行 / `risk_events` 1 行；
//    · 会话 `081ADE07-3610-4244-859A-D991671D2A05` 的 `risk_event_count = 40`，
//      而它名下 `risk_events` 只有 5 行。
//  ⇒ 同一 finding 每重发一次：`risk_events` 因为 id 稳定而只有一行（对的），
//    `events` 因为随机 id 而多一行（刷屏），计数因为自增而 +1（虚高）。
//
//  口径（本轮定死，写在这里以免下一个人重新猜）：
//   1. **一条风险的幂等键 = 会话窗口键 + `ruleID@suppressionKey`**（`RiskPipeline` 原有那条），
//      风险行 id 由它确定性派生 ⇒ 同一 finding 重发**不**新增行；
//      刻意**不**再往键里加时间窗：加了就把「重发」变成「新行」，正是要修的东西；
//      真正的新一次告警由 `suppressionKey` 变化（时间簇起点不同）自然产生新 id。
//   2. 时间线行 id = 由风险行 id 再派生（`TimelineAggregator.eventID(for:)`），写它走 upsert
//      ⇒ 「一条风险对应一行时间线」与 (1) 同生同死。
//   3. `sessions.risk_event_count` 只有一个写入者：Store 里那条派生重算
//      （`recordRisks` 与 `upsertSessions` 共用）。引擎侧的自增整条摘掉。
//
//  驱动的是 `ObservatoryEngine.recordRisks` 那一格真收口（不是自己摆一遍等价序列）：
//  时钟不可注入，端到端摆不出「同一 finding 滑出保留窗再产出」的确定性 5 次，
//  所以从收口入口进——把自增接回来、或把 id 改回随机，这里都会红。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
@testable import AIObservatoryEngine

private let when = Date(timeIntervalSinceReferenceDate: 800_002_000)

private enum RiskFixture {
    static let agent = UUID()
    static let session = UUID()
    /// 固定 id：模拟 `RiskPipeline` 由幂等键派生出来的那一把（同 finding 重发必然是它）。
    static let riskID = StableID.uuid(namespace: "riskfixture", key: "repeat")

    static func session(riskEventCount: Int = 0, startedAt: Date = when) -> AgentSession {
        AgentSession(id: session, kind: .claudeCode, agentID: agent, title: "会话 · 幂等",
                     projectPath: "/work/Alpha", startedAt: startedAt, riskEventCount: riskEventCount)
    }

    /// `id` 必须真的传进去：上一版这里忘了传，`RiskEvent.init` 就自己摇了一个随机 uuid，
    /// 于是「同一 finding 重发」在测试里其实是两条不同风险，红得毫无道理。
    static func risk(id: UUID, timestamp: Date, detail: String) -> RiskEvent {
        RiskEvent(id: id, timestamp: timestamp, level: .high, category: .resourceAbuse,
                  title: "内存峰值超限", detail: detail, agentID: agent, agentKind: .claudeCode,
                  sessionID: session, command: nil, matchedRuleID: "risk.pattern.excessive-memory-peak")
    }

    /// 与 `RiskPipeline.event(from:idempotencyKey:…)` 同一条派生口径。
    static func stableID(_ key: String) -> UUID {
        StableID.uuid(namespace: "riskfixture", key: key)
    }
}

@Suite("风险重发：行、时间线、计数各只有一份", .timeLimit(.minutes(1)))
struct RiskEventIdempotencyTests {

    private func makeEngine(store: ObservatoryStore) -> ObservatoryEngine {
        let mapper = ProjectMapper(resolver: { _ in nil })
        return ObservatoryEngine(
            settings: ObservatorySettings(
                monitoredRoots: [], ignoredPathPatterns: [], processScanIntervalSeconds: 3_600
            ),
            components: ObservatoryEngine.Components(
                storeSource: .ready(store),
                detector: StubDetector(agents: []),
                processInspector: StubProcessSource(),
                metrics: StubMetrics(),
                commandAuditor: StubAuditor(),
                fileObserver: StubFileObserver(),
                snapshotter: StubSnapshotter(),
                differ: StubDiffer(),
                aggregator: TimelineAggregator(projectMapper: mapper),
                projectMapper: mapper,
                riskPipeline: RiskPipeline()
            )
        )
    }

    // MARK: - 1. 一跳主判据

    @Test("同一风险连发 5 次：risk_events +1、events +1、计数 = 1")
    func fiveRepeatsStayOneRowEach() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let engine = makeEngine(store: store)
        try await store.upsertSessions([RiskFixture.session()])

        let id = RiskFixture.riskID
        let risk = RiskFixture.risk(id: id, timestamp: when, detail: "内存峰值 6.0 GB")
        for _ in 0..<5 { await engine.recordRisks([risk], store: store) }
        await store.flush()

        #expect(try await store.riskEvents(matching: .all).totalCount == 1, "风险行只该有一条")
        let timeline = try await store.events(matching: EventQuery(kinds: [.riskDetected]))
        #expect(timeline.totalCount == 1, "时间线不该被同一条风险刷 5 行（真机刷了 43 行）")
        let session = try #require(await store.session(id: RiskFixture.session))
        #expect(session.riskEventCount == 1, "计数 = 实际行数，不是发射次数")
        #expect(await store.batchStats().droppedStatementCount == 0,
                "没有靠主键冲突丢行来达成「一条」——那会把别的行一起丢")
    }

    @Test("第 6 次重发是**原地刷新**：行数不变，但那一行的内容跟着走")
    func repeatRefreshesInPlace() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let engine = makeEngine(store: store)
        try await store.upsertSessions([RiskFixture.session()])
        let id = RiskFixture.riskID
        await engine.recordRisks([RiskFixture.risk(id: id, timestamp: when, detail: "第一次")], store: store)
        let later = when.addingTimeInterval(120)
        await engine.recordRisks([RiskFixture.risk(id: id, timestamp: later, detail: "第二次")], store: store)
        await store.flush()

        let risks = try await store.riskEvents(matching: .all)
        #expect(risks.totalCount == 1)
        // `RiskFinding.riskEvent()` 会把置信度追加到 detail 尾部，所以这里判前缀。
        #expect(risks.items.first?.detail.hasPrefix("第二次") == true,
                "重发要把那一行刷成新值，而不是丢掉新值")
        #expect(risks.items.first?.timestamp == later)
        let events = try await store.events(matching: EventQuery(kinds: [.riskDetected]))
        #expect(events.totalCount == 1)
        #expect(events.items.first?.timestamp == later, "时间线那一行跟着风险行走，不留旧时刻")
    }

    @Test("阴性对照：两条**不同** finding 各占一行（幂等没把不同的东西并掉）")
    func distinctFindingsStayDistinct() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let engine = makeEngine(store: store)
        try await store.upsertSessions([RiskFixture.session()])
        let first = RiskFixture.stableID("risk.pattern.excessive-memory-peak@session")
        let second = RiskFixture.stableID("risk.pattern.sustained-cpu-peak@session")
        #expect(first != second)
        await engine.recordRisks([RiskFixture.risk(id: first, timestamp: when, detail: "内存")], store: store)
        await engine.recordRisks([RiskFixture.risk(id: second, timestamp: when, detail: "CPU")], store: store)
        await store.flush()

        #expect(try await store.riskEvents(matching: .all).totalCount == 2)
        #expect(try await store.events(matching: EventQuery(kinds: [.riskDetected])).totalCount == 2)
        let session = try #require(await store.session(id: RiskFixture.session))
        #expect(session.riskEventCount == 2)
    }

    // MARK: - 2. 时间线身份

    @Test("风险→时间线的 id 由风险 id 派生：稳定、且不同风险之间不撞")
    func timelineIdentityIsDerived() {
        let first = RiskFixture.risk(id: RiskFixture.stableID("a"), timestamp: when, detail: "x")
        let second = RiskFixture.risk(id: RiskFixture.stableID("b"), timestamp: when, detail: "y")
        let mapper = ProjectMapper(resolver: { _ in nil })
        let aggregator = TimelineAggregator(projectMapper: mapper)
        #expect(aggregator.event(for: first).id == aggregator.event(for: first).id)
        #expect(aggregator.event(for: first).id != aggregator.event(for: second).id)
        // 命令/文件事件仍是随机身份（只插入语义没被一起改掉）：两次调用不该给出同一个 id。
        let command = CommandRecord(executable: "ls", agentKind: .claudeCode, startedAt: when)
        #expect(aggregator.event(for: command).id != aggregator.event(for: command).id)
    }
}

@Suite("风险计数只有一个写入者：Store 侧", .timeLimit(.minutes(1)))
struct RiskCountSingleWriterTests {

    private static let fixedRiskID = StableID.uuid(namespace: "riskfixture", key: "single-writer")

    @Test("整行 upsert 不会把派生计数盖成调用方携带的数字（两个写入者的那一条）")
    func sessionUpsertCannotClobberDerivedCount() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let riskID = RiskCountSingleWriterTests.fixedRiskID
        try await store.upsertSessions([RiskFixture.session()])
        try await store.recordRisks([
            RiskFixture.risk(id: riskID, timestamp: when, detail: "一条风险"),
        ])
        #expect(try await store.session(id: RiskFixture.session)?.riskEventCount == 1)

        // 引擎每 tick 都会把会话整行覆盖一次，携带的是它自己那份快照（现在是 0）。
        try await store.upsertSessions([RiskFixture.session(riskEventCount: 99)])
        #expect(try await store.session(id: RiskFixture.session)?.riskEventCount == 1,
                "99 是调用方携带的数，不该盖住派生值")
        try await store.upsertSessions([RiskFixture.session(riskEventCount: 0)])
        #expect(try await store.session(id: RiskFixture.session)?.riskEventCount == 1,
                "0 也不行——那一列不再由会话整行写入")
    }

    @Test("删掉风险行之后计数跟着退（派生不能停在旧值上）")
    func pruneRollsTheDerivedCountBack() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let riskID = RiskFixture.riskID
        // 会话行的 startedAt 要比 cutoff 新：不然它自己也在那一刀里被删掉，
        // 这条用例要判的「计数跟着退」就无从读起。
        let startedAt = when.addingTimeInterval(172_800)
        try await store.upsertSessions([RiskFixture.session(startedAt: startedAt)])
        try await store.recordRisks([RiskFixture.risk(id: riskID, timestamp: when, detail: "一条风险")])
        #expect(try await store.session(id: RiskFixture.session)?.riskEventCount == 1)

        _ = try await store.prune(olderThan: when.addingTimeInterval(86_400), vacuum: false)
        #expect(try await store.riskEvents(matching: .all).totalCount == 0)
        #expect(try await store.session(id: RiskFixture.session)?.riskEventCount == 0,
                "源表空了而计数还留着，就是「唯一写入者」没兑现")
    }
}
