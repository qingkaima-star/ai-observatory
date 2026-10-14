//
//  DashboardIdleRefreshTests.swift
//  Tests/AIObservatoryUITests
//
//  Owner: ws/engaudit（#53 动作 2b，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  总控给动作 2 的验收里有两条要在这里判：
//   ①「无新数据时，查询次数与 body 重算次数都不随轮数增长」；
//   ②「有新数据时那一格必须变」（不许冻在启动值）。
//
//  【写这一档之前先标定了尺子，结论和预设相反】
//  预设是"扫描每拍推一份 `.agents`，无脑赋值 ⇒ 零活动也每拍重算整页 body"，
//  并按这个预设加过一道"值相同就不写"的闸门。**变异检查把它证伪了**：
//  把闸门撤掉、只留 `activeAgents = sorted` 这一句无条件赋值，
//  下面那条"空表推 40 拍 = 0 次失效"的判据**照样通过**。
//  标定探针（`equalWritesDoNotInvalidate`）实测：
//      空表 → 空表   不失效
//      空表 → 1 个   失效
//      同一个 1 个   不失效
//  ⇒ `@Observable` 的失效是**按值**的，不是按写入的：值没变，赋同一个回去也不惊动 body。
//  那道闸门省不下任何一次重算，于是**撤掉**（留着只会让注释里"防每拍重算"这句话变成假话）。
//
//  那么这一档还判什么？判据① 从"我修好的东西"降级成**回退守卫**，而且守卫的位置随之改变：
//   · 零活动时页面上本来就没有 Agent ⇒ `[] == []`，不重算；有 1 个 Agent 在跑时
//     `lastSeenAt` / cpu / memory 每拍都是新值 ⇒ 每拍都会重算，那是"读数真的变了"，
//     不是空转。所以**判据④ 的剩余开销不在这一格**，本文件不负责解释它。
//   · 这一格真正能挡住的是：有人给这一页加了定时器、或者把"每拍必变"的字段
//     （时间戳、UUID、`Date()`）混进增量载荷里 ⇒ 那都会让它立刻变红。
//  判据② 是硬的：影子提交与服务端补查两条路都要能动，且服务端真值必须盖过本地累加。
//

import Testing
import Foundation
import os
import Observation
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 记账替身

/// 只加计数、不改行为的转发壳：每个成员都原样转给内层。
/// 用它才能把"页面这一轮到底向服务要了几次数"变成一个可断言的数。
private final class CountingService: ObservatoryService, Sendable {
    enum Call: String, CaseIterable {
        case dashboardStats, activeAgents, riskEvents, events, fileChanges, commands, sessions
    }

    private let inner: any ObservatoryService
    private let counts: [OSAllocatedUnfairLock<Int>]

    init(_ inner: any ObservatoryService) {
        self.inner = inner
        self.counts = Call.allCases.map { _ in OSAllocatedUnfairLock(initialState: 0) }
    }

    func count(of call: Call) -> Int { counts[Call.allCases.firstIndex(of: call)!].withLock { $0 } }

    func reset() {
        for lock in counts { lock.withLock { $0 = 0 } }
    }

    private func tick(_ call: Call) {
        counts[Call.allCases.firstIndex(of: call)!].withLock { $0 += 1 }
    }

    func dashboardStats(for date: Date) async throws -> DashboardStats {
        tick(.dashboardStats)
        return try await inner.dashboardStats(for: date)
    }

    func activeAgents() async throws -> [AgentInstance] {
        tick(.activeAgents)
        return try await inner.activeAgents()
    }

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        tick(.sessions)
        return try await inner.sessions(matching: query)
    }

    func session(id: UUID) async throws -> AgentSession? { try await inner.session(id: id) }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        tick(.events)
        return try await inner.events(matching: query)
    }

    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        tick(.fileChanges)
        return try await inner.fileChanges(matching: query)
    }

    func fileDiff(for changeID: UUID) async throws -> FileDiff? { try await inner.fileDiff(for: changeID) }

    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        tick(.commands)
        return try await inner.commands(matching: query)
    }

    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        tick(.riskEvents)
        return try await inner.riskEvents(matching: query)
    }

    func projects() async throws -> [ProjectActivity] { try await inner.projects() }

    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        try await inner.projectActivity(path: path, dateRange: dateRange)
    }

    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        try await inner.performanceSamples(sessionID: sessionID)
    }

    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        try await inner.systemPerformance(since: date)
    }
}

// MARK: - 尺子

/// 这一页 body 会读到的属性。用例读的就是这几个 —— 它们和 SwiftUI 的失效来源同源。
@MainActor
private func pageReadings(_ model: DashboardModel) -> Int {
    model.activeAgents.count + model.stats.filesModified + model.stats.hourlyActivity.count
        + model.stats.sessionCount + (model.engineState == .running ? 1 : 0)
}

/// 跑一轮，返回"这一轮有没有引发失效"（＝ SwiftUI 会不会重算 body）。
@MainActor
private func didInvalidate(_ model: DashboardModel, round: () async -> Void) async -> Bool {
    let fired = OSAllocatedUnfairLock(initialState: false)
    withObservationTracking {
        _ = pageReadings(model)
    } onChange: {
        fired.withLock { value in value = true }
    }
    await round()
    return fired.withLock { $0 }
}

// MARK: - 夹具

@MainActor
private func makeModel(
    service: InMemoryObservatoryService
) -> (DashboardModel, CountingService) {
    let counter = CountingService(service)
    let model = DashboardModel(runtime: ObservatoryRuntime(
        service: counter, controller: service, updates: service, analysis: nil
    ))
    return (model, counter)
}

/// 今天第 `hour` 小时、第 `slot` 个位置上的事件。
private func eventAt(hour: Int, slot: Int) -> TimelineEvent {
    // `slot % 18`：分钟数收在 1′…52′ 之内，任何 slot 都不会跨进下一个小时
    // （跨了就是"用例以为在测第 3 格、实际灌进第 4 格"那种假绿）。
    let stamp = Calendar.current.startOfDay(for: Date())
        .addingTimeInterval(TimeInterval(hour * 3_600 + (slot % 18) * 3 + 1))
    return TimelineEvent(
        timestamp: stamp,
        agentKind: .claudeCode,
        kind: .fileModified,
        title: "改了 \(slot).swift",
        summary: "第 \(slot) 条",
        projectPath: "/idle-fixture/Project"
    )
}

private func serverEvents(hour: Int, count: Int) -> [TimelineEvent] {
    (0..<count).map { eventAt(hour: hour, slot: $0) }
}

private func localFileChange() -> ObservatoryUpdate {
    .fileChange(FileChange(
        path: "/idle-fixture/Project/Sources/A.swift",
        kind: .modified,
        timestamp: Date(),
        agentKind: .claudeCode,
        linesAdded: 1,
        linesRemoved: 0,
        projectPath: "/idle-fixture/Project"
    ))
}

/// 内容完全确定的 Agent 实例。`startedAt` / `lastSeenAt` 必须钉死：
/// 默认值取 `Date()` 的话"同一份列表"每拍都不相等，标定探针就测不出它在比什么。
private func agent(pid: Int32, kind: AgentKind = .claudeCode) -> AgentInstance {
    AgentInstance(
        id: StableID.uuid(namespace: "idletest", key: "agent-\(pid)"),
        kind: kind,
        pid: pid,
        displayName: "agent-\(pid)",
        executablePath: "/usr/local/bin/agent",
        startedAt: Date(timeIntervalSince1970: 1_900_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_900_000_001)
    )
}

/// 被查询的那一天里一个确定的、通常已经过完的小时格。
private let quietHour = 3

/// 只数"这一档到底被调了几次"的分析层替身。返回值固定，不参与判定。
///
/// ⚠️ 第一版把 `anomalies(since:)` 写成 `{ [] }` —— **忘了记数**，于是"40 轮 0 次"
/// 那条判据永远绿。是它前面那句"进页该扫一次"（要求 == 1）把这只哑巴仪器照出来的：
/// 替身的正例必须先判，否则反例的 0 没有意义。
private final class CountingAnalysis: ObservatoryAnalysisProviding, Sendable {
    private let calls = OSAllocatedUnfairLock(initialState: 0)
    private let findings = OSAllocatedUnfairLock(initialState: [AnomalyFinding]())
    var count: Int { calls.withLock { $0 } }
    func reset() { calls.withLock { $0 = 0 } }
    private func bump() { calls.withLock { $0 += 1 } }
    /// 换一批结论：让"那一格必须变"有内容可判（不是只数次数）。
    func set(_ newFindings: [AnomalyFinding]) { findings.withLock { $0 = newFindings } }
    func projectHealth(for path: String) async throws -> ProjectHealthSnapshot? {
        bump()
        return nil
    }
    func anomalies(since date: Date) async throws -> [AnomalyFinding] {
        bump()
        return findings.withLock { $0 }
    }
}

/// 一条能上屏的结论（形状与 `AnalysisPresentationTests` 的夹具一致）。
private func finding(_ observed: Double) -> AnomalyFinding {
    AnomalyFinding(
        kind: .eventBurst,
        severity: .high,
        summary: "实测 \(observed)",
        observed: observed,
        expected: 2.8,
        detectedAt: Date(),
        projectPath: "/idle-fixture/Project"
    )
}

@Suite("Dashboard 零活动轮次：不查询、不重算")
@MainActor struct DashboardIdleRefreshTests {

    // MARK: - 尺子本身（先判它灵不灵，再拿它判产品）

    @Test("标定：失效是按值算的 —— 值相同的写入不惊动 body，值变了才惊动")
    func equalWritesDoNotInvalidate() async {
        let service = InMemoryObservatoryService()
        let (model, _) = makeModel(service: service)
        await model.load()

        // 反面：值真的变了，尺子必须响。这条不响，下面所有"0 次失效"的判据都是假的。
        let appeared = await didInvalidate(model, round: { model.ingest(.agents([agent(pid: 4_242)])) })
        #expect(appeared, "第一次出现 Agent 却没测到失效 ⇒ 尺子不灵，本文件的判据①作废")
        #expect(model.activeAgents.map(\.pid) == [4_242])

        // 正面：逐字段相同的再来一拍，不许算一次重算。
        let repeated = await didInvalidate(model, round: { model.ingest(.agents([agent(pid: 4_242)])) })
        #expect(!repeated, "同样的内容也算失效 ⇒ 判据① 就没法用这条尺子判")

        // 换 pid（真有新进程）必须再响 —— 否则"值相同不失效"就成了"永远不失效"。
        let grew = await didInvalidate(model, round: { model.ingest(.agents([agent(pid: 4_242), agent(pid: 5_100, kind: .openAICodex)])) })
        #expect(grew, "多了一个进程却测不到 ⇒ 尺子只在比数量，那不够")
        #expect(model.activeAgents.count == 2)
    }

    // MARK: - ① 无新数据：查询次数与重算次数都不随轮数增长

    @Test("40 轮空扫描（每拍推同一份空 Agent 表）：0 次查询、0 次失效")
    func idleRoundsIssueNothing() async {
        let service = InMemoryObservatoryService()
        let (model, counter) = makeModel(service: service)
        await model.load()                 // 首屏那一次不算在轮数里
        counter.reset()

        var invalidations = 0
        for _ in 0..<40 {
            let fired = await didInvalidate(model) {
                model.ingest(.agents([]))          // 与上一拍逐字段相同的一份空表
                model.ingest(.engineState(model.engineState))
                model.flushPendingStats()          // 没有影子 ⇒ 必须是空操作
            }
            if fired { invalidations += 1 }
        }

        #expect(invalidations == 0, "\(invalidations)/40 轮引发失效 ⇒ 零活动也在每拍重算整页 body")
        #expect(counter.count(of: .dashboardStats) == 0, "零活动轮次不该向服务要聚合：\(counter.count(of: .dashboardStats)) 次")
        #expect(counter.count(of: .activeAgents) == 0, "零活动轮次不该重查活跃 Agent：\(counter.count(of: .activeAgents)) 次")
        #expect(counter.count(of: .riskEvents) == 0)
        #expect(counter.count(of: .events) == 0)
    }

    @Test("失效次数与轮数无关：跑 1 轮和跑 25 轮是同一个数")
    func invalidationsDoNotGrowWithRounds() async {
        var observed: [Int] = []
        for rounds in [1, 5, 25] {
            let service = InMemoryObservatoryService()
            let (model, counter) = makeModel(service: service)
            await model.load()
            counter.reset()
            var fired = 0
            for _ in 0..<rounds {
                if await didInvalidate(model, round: {
                    model.ingest(.agents([]))
                    model.flushPendingStats()
                }) { fired += 1 }
            }
            observed.append(fired)
            #expect(counter.count(of: .dashboardStats) == 0, "\(rounds) 轮之后向服务要了聚合值 ⇒ 轮数在换查询")
        }
        #expect(observed == [0, 0, 0], "轮数 1/5/25 的失效次数是 \(observed) ⇒ 只要不为 0 就是每轮都在重算")
    }

    @Test("性能采样每几秒推一发，但 Dashboard 不因此查询、不重算")
    func performanceUpdatesAreIgnored() async {
        let service = InMemoryObservatoryService()
        let (model, counter) = makeModel(service: service)
        await model.load()
        counter.reset()

        var invalidations = 0
        for index in 0..<20 {
            let sample = PerformanceSample(
                timestamp: Date(),
                cpuPercent: Double(index),
                memoryBytes: UInt64(index) * 1_024
            )
            if await didInvalidate(model, round: { model.ingest(.performance(sample)) }) {
                invalidations += 1
            }
        }
        #expect(invalidations == 0)
        #expect(counter.count(of: .dashboardStats) == 0)
    }

    // MARK: - ①b 异常扫描（B2 那一臂）：判的是次数，窗口一个字不缩

    @Test("`loadAnomalies` 每轮空扫描都不重跑：40 轮 = 0 次全窗口分析（审计窗口没缩，省的是次数）")
    func anomalyScanDoesNotRerunOnIdleRounds() async {
        let service = InMemoryObservatoryService()
        let counter = CountingService(service)
        let spy = CountingAnalysis()
        let model = DashboardModel(runtime: ObservatoryRuntime(
            service: counter, controller: service, updates: service, analysis: spy
        ))
        await model.loadAnomalies()                       // 进页那一次
        #expect(spy.count == 1, "进页该扫一次，实得 \(spy.count)")
        let window = model.anomalyWindowStart
        #expect(window != nil, "窗口起点必须登记（卡片要写口径）")
        spy.reset()

        for _ in 0..<40 {
            model.ingest(.agents([]))
            model.flushPendingStats()
        }
        #expect(spy.count == 0, "零活动轮次重跑了 \(spy.count) 次全窗口分析 ⇒ 这一档的成本是 O(轮数 × 6 千行)")

        // 到点的那一趟补查：六宫格与异常扫描**各一次**，共用同一个冷却（不开第二个时钟）。
        await model.refreshAggregatesAndAnomalies()
        #expect(spy.count == 1, "到点应正好重扫一次，实得 \(spy.count)")
        #expect(counter.count(of: .dashboardStats) == 1, "到点应正好补查一次聚合")

        // 回看窗口不能被"次数"挤掉：默认口径 = 范围起点，且 `today` 覆盖整日（不缩窗）。
        await model.loadAnomalies()
        #expect(spy.count == 2, "冷却那一趟 1 次 + 这次显式重扫 1 次 = 2，实得 \(spy.count)")
        if let start = model.anomalyWindowStart {
            let span = Date().timeIntervalSince(start)
            #expect(span >= 0 && span <= 86_400, "回看窗口应落在『今天』之内，实测 \(span) 秒")
        }
    }

    @Test("增量来了也不许顺手重扫全窗口分析（分析层与六宫格各自一条补查路）")
    func incrementsDoNotTriggerAnomalyScan() async {
        let service = InMemoryObservatoryService()
        let counter = CountingService(service)
        let spy = CountingAnalysis()
        let model = DashboardModel(runtime: ObservatoryRuntime(
            service: counter, controller: service, updates: service, analysis: spy
        ))
        await model.load()
        spy.reset()
        for slot in 0..<30 {
            model.ingest(.timelineEvent(eventAt(hour: quietHour, slot: slot)))
            model.ingest(localFileChange())
        }
        model.flushPendingStats()
        #expect(spy.count == 0, "一波增量里重扫了 \(spy.count) 次 ⇒ 分析层被挂进了增量路径")
    }

    @Test("到点补查必须把异常卡一起推起来（改前它冻在进页那一刻），且不许闪加载态")
    func throttledRefreshMovesTheAnomalyCard() async {
        let service = InMemoryObservatoryService()
        let counter = CountingService(service)
        let spy = CountingAnalysis()
        spy.set([finding(40)])
        let model = DashboardModel(runtime: ObservatoryRuntime(
            service: counter, controller: service, updates: service, analysis: spy
        ))
        await model.loadAnomalies()
        #expect(model.anomalies.count == 1, "进页那一次该看到 1 条结论")

        // 一波增量（30 条）里一次都不该重扫。
        for slot in 0..<30 {
            model.ingest(.timelineEvent(eventAt(hour: quietHour, slot: slot)))
            model.ingest(localFileChange())
        }
        #expect(spy.count == 1, "增量里重扫了 \(spy.count - 1) 次 ⇒ 分析层被挂进了增量路径，而不是挂在冷却上")

        // 到点：卡必须跟着新结论走（不许停在进页那一刻），而且不闪 spinner。
        spy.set([finding(90), finding(120)])
        await model.refreshAggregatesAndAnomalies()
        #expect(spy.count == 2, "到点没重扫异常卡 ⇒ 卡片仍冻在启动值")
        #expect(model.anomalies.count == 2, "异常卡应跟到 2 条新结论，实得 \(model.anomalies.count)")
        #expect(!model.isLoadingAnomalies, "live 那一趟把加载态翻起来了 ⇒ 卡片每 10 秒闪一次圈")
        #expect(model.anomalyWindowStart != nil, "回看窗口口径必须还在（不缩窗）")
    }

    // MARK: - ② 有新数据：那一格必须变

    @Test("灌 3 条事件到点之后那一格必须 +3；再灌 2 条还能继续动")
    func hourlyCellMovesWithNewEvents() async {
        let service = InMemoryObservatoryService()
        service.seed(events: serverEvents(hour: quietHour, count: 4))
        let (model, counter) = makeModel(service: service)
        await model.load()
        counter.reset()

        let start = model.stats.hourlyActivity.first { $0.hour == quietHour }?.eventCount ?? -1
        #expect(start == 4, "首屏该拿到服务端的 4 条，实得 \(start)")

        for slot in 0..<3 {
            model.ingest(.timelineEvent(eventAt(hour: quietHour, slot: slot)))
        }
        #expect(model.flushPendingStats(), "有增量时到点必须提交")
        let afterLocal = model.stats.hourlyActivity.first { $0.hour == quietHour }?.eventCount ?? -1
        #expect(afterLocal == 7, "本地累加后那一格应为 7，实得 \(afterLocal) ⇒ 提交被做成了冻在启动值")
        #expect(counter.count(of: .dashboardStats) == 0, "增量累加这一路不该顺手重查全库")

        for slot in 3..<5 {
            model.ingest(.timelineEvent(eventAt(hour: quietHour, slot: slot)))
        }
        #expect(model.flushPendingStats())
        let afterMore = model.stats.hourlyActivity.first { $0.hour == quietHour }?.eventCount ?? -1
        #expect(afterMore == 9, "第二批必须还能推进，实得 \(afterMore)")
    }

    @Test("服务端补查回来更大的值时，那一格必须跟到服务端真值（影子不许把它压回去）")
    func serverRefreshWinsOverShadow() async {
        let service = InMemoryObservatoryService()
        service.seed(events: serverEvents(hour: quietHour, count: 2))
        let (model, counter) = makeModel(service: service)
        await model.load()
        #expect(model.stats.hourlyActivity.first { $0.hour == quietHour }?.eventCount == 2)
        counter.reset()          // 首屏那一次不计入本轮判据

        // 一波增量先走本地累加（这就是"还没到补查窗口"时用户看到的值）。
        model.ingest(localFileChange())
        model.ingest(.timelineEvent(eventAt(hour: quietHour, slot: 90)))
        #expect(model.flushPendingStats())

        // 服务端此时已经落库更多事件（引擎广播不到这一格，靠低频补查对齐）。
        service.seed(events: serverEvents(hour: quietHour, count: 11))
        await model.load()
        let cell = model.stats.hourlyActivity.first { $0.hour == quietHour }?.eventCount ?? -1
        #expect(cell == 11, "补查之后那一格应为服务端真值 11，实得 \(cell) ⇒ 影子把服务端真值盖掉了")
        #expect(counter.count(of: .dashboardStats) == 1, "一次显式 load 该正好发一次聚合查询")
    }
}
