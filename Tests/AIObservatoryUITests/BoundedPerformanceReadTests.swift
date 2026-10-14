//
//  BoundedPerformanceReadTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · #52 接应 ICR-0007 第二半）
//  ─────────────────────────────────────────────────────────
//  钉两件事，缺一不可：
//  ① 界面拿到的行数 ≤ `sampleCap`（派单原话"要钉成断言，不是只测渲染"）；
//  ② 截断发生在**取数层**，界面不再自己 `suffix(sampleCap)` 兑底。
//
//  为什么 ① 单独存在是**没牙的**：`ObservatoryService` 给这两个新成员配了协议扩展默认实现
//  （转调无界版再 `suffix`），而 `InMemoryObservatoryService` **没有重写它们**
//  （实测 `Sources/AIObservatoryTestSupport/InMemoryObservatoryService.swift:291/297` 只有无界版）。
//  ⇒ 走预览运行时测"行数 ≤ 1000"，无论界面调的是哪一版、也无论实现有没有整段捞回，**都会通过**。
//  真正有牙的是"界面调了哪一个成员"，所以本文件用一个记录型替身把调用记下来：
//  带上限那版必须被调到，无界那版**一次都不许**被调。
//  （两个真后端确实把截断下推到 SQL/SwiftData 这件事，由 `ws/engaudit` 的
//  `BoundedPerformanceReadContractTests` 钉着，不在本文件重复。）
//

import Foundation
import Testing
import os
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

@Suite("UI: 性能页走带上限的取数（ICR-0007 / #52）", .timeLimit(.minutes(2)))
@MainActor struct BoundedPerformanceReadTests {

    /// 整机：库里比 `sampleCap` 多 500 条 ⇒ 只有取数层限得住，界面才会正好拿到 1000 条。
    @Test("① 行数 ≤ sampleCap，且② 界面向带上限那版取数、没碰无界那版")
    func systemReadIsBoundedAtTheSource() async throws {
        let seed = Self.systemSamples(count: PerformanceModel.sampleCap + 500)
        let (model, calls) = try makeModel(system: seed)

        await model.load()

        #expect(model.systemSamples.count == PerformanceModel.sampleCap,
                "取到 \(model.systemSamples.count) 条，上限 \(PerformanceModel.sampleCap)")
        // 限住的必须是**最新**那一段：取到最老的 1000 条说明谁都没在工作。
        #expect(model.systemSamples.last?.id == seed.last?.id, "曲线尾部不是最新一条采样")
        #expect(calls.boundedSystemReads == 1, "带上限的整机取数被调了 \(calls.boundedSystemReads) 次")
        #expect(calls.unboundedSystemReads == 0,
                "界面还在调无界版 ⇒ 每刷一次页就重建保留期内全部采样")
        #expect(calls.lastSystemLimit == PerformanceModel.sampleCap,
                "传给取数层的 limit 是 \(calls.lastSystemLimit ?? -1)，不是 sampleCap")
    }

    /// 少于上限时不许"顺手截一刀"：全量都要在（截多与截少是同一个 bug 的两面）。
    @Test("① 不足上限时一条都不许多截")
    func smallLibraryIsReturnedWhole() async throws {
        let seed = Self.systemSamples(count: 10)
        let (model, calls) = try makeModel(system: seed)

        await model.load()

        #expect(model.systemSamples.count == 10, "只取到 \(model.systemSamples.count) 条")
        #expect(calls.boundedSystemReads == 1)
        #expect(calls.unboundedSystemReads == 0)
    }

    @Test("切时间范围重查（reloadSystemSamples）也走带上限那版")
    func reloadSystemSamplesIsBounded() async throws {
        let seed = Self.systemSamples(count: PerformanceModel.sampleCap + 200)
        let (model, calls) = try makeModel(system: seed)

        await model.reloadSystemSamples()

        #expect(model.systemSamples.count == PerformanceModel.sampleCap)
        #expect(calls.boundedSystemReads == 1, "换范围这一路还在走无界版")
        #expect(calls.unboundedSystemReads == 0)
    }

    @Test("会话明细（loadSessionSamples）走带上限那版，且传的是 sampleCap")
    func sessionReadIsBounded() async throws {
        let sessionID = UUID()
        let samples: [PerformanceSample] = (0..<PerformanceModel.sampleCap + 300).map { index in
            PerformanceSample(
                timestamp: Date().addingTimeInterval(Double(index)),
                sessionID: sessionID
            )
        }
        let inner = InMemoryObservatoryService()
        inner.seed(
            sessions: [AgentSession(id: sessionID, kind: .claudeCode,
                              startedAt: Date().addingTimeInterval(-600))],
            performance: samples
        )
        let (model, calls) = try makeModel(inner: inner)
        model.selectedSessionID = sessionID

        await model.loadSessionSamples()

        #expect(model.sessionSamples.count == PerformanceModel.sampleCap,
                "会话明细取到 \(model.sessionSamples.count) 条")
        #expect(calls.boundedSessionReads == 1)
        #expect(calls.unboundedSessionReads == 0,
                "会话明细还在整段捞回 ⇒ 长会话每刷一次页重建几万条对象")
        #expect(calls.lastSessionLimit == PerformanceModel.sampleCap)
    }

    /// ②的另一半：**不许两边都限**。上面几条行为断言看得见"有没有调带上限那版"，
    /// 但看不见"调了之后又在界面里再截一刀"——那种写法结果完全相同，却把取数层是否在工作
    /// 变成不可观测（派单点名的正是这一点）。所以这一条只能扫源码。
    @Test("② 界面不再自己 suffix(sampleCap) 兑底")
    func modelDoesNotTruncateAgain() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Performance/PerformanceModel.swift"
        )
        #expect(!code.contains("suffix(Self.sampleCap)"),
                "取数层已经限住了，界面又截一刀 ⇒ 谁在工作看不出来")
        // 增量缓冲的上界（`:460` 的 removeFirst）是**内存上界**，不是取数兑底，必须留着。
        #expect(code.contains("removeFirst(sessionSamples.count - Self.sampleCap)"),
                "增量缓冲的裁剪被顺手删了：推流会无上界增长")
    }

    /// 版面侧的事实：`PerformanceSessionBreakdown` 不查库，它切的是模型里那一段。
    /// 派单把它列成"第四处无界查询"，实测不是——这条用例把那个结论钉住，
    /// 免得下一个人以为还有一处没修。
    @Test("第四处不是查询：明细视图只切模型给的数组")
    func breakdownDoesNotQuery() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Performance/PerformanceSessionBreakdown.swift"
        )
        #expect(!code.contains("runtime.service"), "明细视图开始自己查库了（它只该收数组）")
        #expect(!code.contains("performanceSamples(sessionID:"), "明细视图里出现了取数调用")
        // 它那一刀是**版面**截断（表格只画最近 60 行），入参数组已经在取数层限过。
        #expect(code.contains("suffix(Self.recentRowLimit)"), "版面截断被误删：表会一次画满 1000 行")
    }

    // MARK: 装配

    private func makeModel(
        system: [SystemPerformanceSample] = [],
        inner: InMemoryObservatoryService? = nil
    ) throws -> (PerformanceModel, CallLog) {
        let base = inner ?? InMemoryObservatoryService()
        if inner == nil {
            base.seed(systemPerformance: system)
        }
        let calls = CallLog()
        let recorder = RecordingObservatoryService(inner: base, calls: calls)
        let runtime = ObservatoryRuntime(
            service: recorder, controller: base, updates: base, settings: .default
        )
        return (PerformanceModel(runtime: runtime), calls)
    }

    /// 时间戳全部**从 now 往前**排：`.lastSixHours` 是相对窗口，不受"跨过午夜"影响
    /// （本仓有过一次常量日期在 00:00–00:25 必红的教训）。
    private static func systemSamples(count: Int) -> [SystemPerformanceSample] {
        let now = Date()
        return (0..<count).map { index in
            SystemPerformanceSample(
                timestamp: now.addingTimeInterval(Double(index) - Double(count)),
                cpuTotalPercent: Double(index % 90),
                cpuSystemPercent: 1,
                cpuUserPercent: 2,
                memoryUsedBytes: 8_589_934_592,
                memoryTotalBytes: 34_359_738_368,
                diskReadBytesPerSecond: 0,
                diskWriteBytesPerSecond: 0,
                loadAverage1m: 1,
                thermalCelsius: nil,
                powerWatts: nil
            )
        }
    }
}

// MARK: - 记录型替身

/// 记录"界面向服务要了哪一版取数"的转发壳。
///
/// 为什么必须自己写：`InMemoryObservatoryService` 没有重写带上限那两个成员，
/// 于是它们落到协议扩展的默认实现（转调无界版再 `suffix`）——
/// 用它直接测"行数 ≤ limit"会**永远通过**，测不到取数有没有被限住。
/// 本壳只加计数，行为一律转给内层，不改变任何返回值。
final class RecordingObservatoryService: ObservatoryService, Sendable {
    private let inner: any ObservatoryService
    private let calls: BoundedPerformanceReadTests.CallLog

    init(inner: any ObservatoryService, calls: BoundedPerformanceReadTests.CallLog) {
        self.inner = inner
        self.calls = calls
    }

    func dashboardStats(for date: Date) async throws -> DashboardStats {
        try await inner.dashboardStats(for: date)
    }

    func activeAgents() async throws -> [AgentInstance] {
        try await inner.activeAgents()
    }

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        try await inner.sessions(matching: query)
    }

    func session(id: UUID) async throws -> AgentSession? {
        try await inner.session(id: id)
    }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        try await inner.events(matching: query)
    }

    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        try await inner.fileChanges(matching: query)
    }

    func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        try await inner.fileDiff(for: changeID)
    }

    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        try await inner.commands(matching: query)
    }

    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        try await inner.riskEvents(matching: query)
    }

    func projects() async throws -> [ProjectActivity] {
        try await inner.projects()
    }

    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        try await inner.projectActivity(path: path, dateRange: dateRange)
    }

    // MARK: 四个要记的

    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        calls.recordUnboundedSession()
        return try await inner.performanceSamples(sessionID: sessionID)
    }

    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        calls.recordUnboundedSystem()
        return try await inner.systemPerformance(since: date)
    }

    func performanceSamples(sessionID: UUID, limit: Int) async throws -> [PerformanceSample] {
        calls.recordBoundedSession(limit: limit)
        return try await inner.performanceSamples(sessionID: sessionID, limit: limit)
    }

    func systemPerformance(since date: Date, limit: Int) async throws -> [SystemPerformanceSample] {
        calls.recordBoundedSystem(limit: limit)
        return try await inner.systemPerformance(since: date, limit: limit)
    }
}

extension BoundedPerformanceReadTests {
    /// 调用计数。`@unchecked Sendable` 的理由：所有读写都在 `OSAllocatedUnfairLock` 里，
    /// 与 `InMemoryObservatoryService` 同一形状（测试替身，不进产物）。
    final class CallLog: Sendable {
        struct Values {
            var boundedSystemReads = 0
            var unboundedSystemReads = 0
            var boundedSessionReads = 0
            var unboundedSessionReads = 0
            var lastSystemLimit: Int?
            var lastSessionLimit: Int?
        }

        private let state = OSAllocatedUnfairLock(initialState: Values())

        var boundedSystemReads: Int { state.withLock { $0.boundedSystemReads } }
        var unboundedSystemReads: Int { state.withLock { $0.unboundedSystemReads } }
        var boundedSessionReads: Int { state.withLock { $0.boundedSessionReads } }
        var unboundedSessionReads: Int { state.withLock { $0.unboundedSessionReads } }
        var lastSystemLimit: Int? { state.withLock { $0.lastSystemLimit } }
        var lastSessionLimit: Int? { state.withLock { $0.lastSessionLimit } }

        func recordUnboundedSession() { state.withLock { $0.unboundedSessionReads += 1 } }
        func recordUnboundedSystem() { state.withLock { $0.unboundedSystemReads += 1 } }
        func recordBoundedSession(limit: Int) {
            state.withLock { $0.boundedSessionReads += 1; $0.lastSessionLimit = limit }
        }
        func recordBoundedSystem(limit: Int) {
            state.withLock { $0.boundedSystemReads += 1; $0.lastSystemLimit = limit }
        }
    }
}
