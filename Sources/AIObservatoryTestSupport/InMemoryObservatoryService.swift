//
//  InMemoryObservatoryService.swift
//  AIObservatoryTestSupport
//
//  Owner: master-controller（冻结）
//
//  一个**功能完整**的内存实现，同时服务于：
//    · WS-UI 的 SwiftUI Preview 与 UI 开发（UI 不必等待 Engine 完工）
//    · 各工作流的单元测试
//  注意：它不是 mock 桩，而是真实的过滤/排序/分页实现 —— 行为需与 Engine 一致。
//

import Foundation
import os
import AIObservatoryCore

public final class InMemoryObservatoryService: ObservatoryService, ObservatoryControlling, ObservatoryEventStreaming, Sendable {

    private struct State: Sendable {
        var agents: [AgentInstance] = []
        var sessions: [AgentSession] = []
        var events: [TimelineEvent] = []
        var fileChanges: [FileChange] = []
        var diffs: [UUID: FileDiff] = [:]
        var commands: [CommandRecord] = []
        var performance: [PerformanceSample] = []
        var systemPerformance: [SystemPerformanceSample] = []
        var risks: [RiskEvent] = []
        var projects: [ProjectActivity] = []
        var engineState: EngineState = .stopped
        /// 最近一次 `updateSettings` 收到的设置，用于与 `ObservatoryEngine` 做行为对照测试。
        var settings: ObservatorySettings = .default
        var subscribers: [UUID: AsyncStream<ObservatoryUpdate>.Continuation] = [:]
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    public init() {}

    // MARK: - Seeding (for previews & tests)

    public func seed(
        agents: [AgentInstance] = [],
        sessions: [AgentSession] = [],
        events: [TimelineEvent] = [],
        fileChanges: [FileChange] = [],
        diffs: [FileDiff] = [],
        commands: [CommandRecord] = [],
        performance: [PerformanceSample] = [],
        systemPerformance: [SystemPerformanceSample] = [],
        risks: [RiskEvent] = [],
        projects: [ProjectActivity] = []
    ) {
        state.withLock { s in
            s.agents = agents
            s.sessions = sessions
            s.events = events
            s.fileChanges = fileChanges
            s.diffs = Dictionary(uniqueKeysWithValues: diffs.map { ($0.id, $0) })
            s.commands = commands
            s.performance = performance
            s.systemPerformance = systemPerformance
            s.risks = risks
            s.projects = projects
        }
    }

    /// 增量注入一条事件并广播（用于 UI 实时演示）。
    public func ingest(_ update: ObservatoryUpdate) {
        state.withLock { s in
            switch update {
            case .timelineEvent(let e):   s.events.append(e)
            case .sessions(let v):        s.sessions = v
            case .agents(let v):          s.agents = v
            case .fileChange(let c):      s.fileChanges.append(c)
            case .command(let c):         s.commands.append(c)
            case .performance(let p):     s.performance.append(p)
            case .risk(let r):            s.risks.append(r)
            case .dashboard, .engineState: break
            }
        }
        broadcast(update)
    }

    // MARK: - ObservatoryControlling

    public func start() async {
        state.withLock { $0.engineState = .running }
        broadcast(.engineState(.running))
    }

    public func stop() async {
        state.withLock { $0.engineState = .stopped }
        broadcast(.engineState(.stopped))
    }

    public func rescanNow() async {}

    public func acknowledgeRiskEvent(id: UUID) async throws {
        state.withLock { s in
            if let index = s.risks.firstIndex(where: { $0.id == id }) {
                s.risks[index].isAcknowledged = true
            }
        }
    }

    /// 与 `ObservatoryEngine` 行为一致：接受新设置并对外可见（内存实现不落盘）。
    public func updateSettings(_ settings: ObservatorySettings) async {
        state.withLock { $0.settings = settings }
    }

    /// 最近一次 `updateSettings` 收到的设置；初始值为构造时的基线。
    public var currentSettings: ObservatorySettings {
        state.withLock { $0.settings }
    }

    // MARK: - ObservatoryEventStreaming

    public func currentState() async -> EngineState {
        state.withLock { $0.engineState }
    }

    public func makeUpdateStream() -> AsyncStream<ObservatoryUpdate> {
        let id = UUID()
        return AsyncStream { continuation in
            state.withLock { $0.subscribers[id] = continuation }
            continuation.onTermination = { [weak self] _ in
                self?.state.withLock { $0.subscribers[id] = nil }
            }
        }
    }

    private func broadcast(_ update: ObservatoryUpdate) {
        let continuations = state.withLock { Array($0.subscribers.values) }
        for continuation in continuations { continuation.yield(update) }
    }

    // MARK: - ObservatoryService

    // MARK: - Dashboard 聚合（单日 = 区间在 `.today` 下的特例，与两个真后端逐字同形）

    /// 旧口径：只做"某一天"。#95 之后它与 `ObservatoryStore` 一样，把单日转交区间版
    /// （窗口 = `.today(date)`），两条路共用同一份按窗口取数的实现，不再各写一套。
    public func dashboardStats(for date: Date) async throws -> DashboardStats {
        try await dashboardStats(settledAt: date, within: .today(date))
    }

    /// **时段累计**：口径逐条对齐 `AIObservatoryStore/ObservatoryStore+Queries.swift` 的
    /// `dashboardStats(settledAt:within:)`——会话按 `startedAt`、事件 / 文件 / 命令 / 风险 /
    /// 采样按各自时间列，全部落在 `range` 的**闭区间**里（窗口真进过滤，不再是某一天）；
    /// 活动分桶按窗口宽度换档（≤ 36 h 小时桶、更宽自然日桶，#75 裁定 9）。
    /// 只有 `activeAgentCount` 是**当前状态快照**（全表 `state = .running`，**不限窗口**），
    /// 沿用契约既有口径，未随本格改动。
    ///
    /// 为什么内存参照**必须**自己实现这一条：`ObservatoryService` 给区间版留了一条退化桥
    /// （`ServiceProtocols.swift` 默认实现把区间版转调单日版）。两个真后端各自重写了它，
    /// 而本参照实现此前只实现单日版 ⇒ 走桥 ⇒ 凡拿它、又递非今天区间给 `DashboardModel` 的
    /// UI 用例看到的其实永远是"某一天"的数（无声降级）。`InMemoryDashboardRangeGuardTests`
    /// 用 1 小时 / 24 小时 / 7 天三档钉住这里不再走桥。
    public func dashboardStats(settledAt: Date, within range: DateRangeFilter) async throws -> DashboardStats {
        state.withLock { s in
            let windowSessions = s.sessions.filter { range.contains($0.startedAt) }
            let windowEvents = s.events.filter { range.contains($0.timestamp) }
            let windowFiles = s.fileChanges.filter { range.contains($0.timestamp) }
            let windowCommands = s.commands.filter { range.contains($0.startedAt) }
            let windowRisks = s.risks.filter { range.contains($0.timestamp) }
            let windowPerf = s.performance.filter { range.contains($0.timestamp) }

            let span = Self.bucketSpan(for: range)
            let hourly = Self.activityBuckets(
                events: windowEvents, samples: windowPerf,
                span: span, range: range, settledAt: settledAt
            )

            let totalSeconds = windowSessions.reduce(0.0) { $0 + $1.duration(until: settledAt) }
            let shares = AgentKind.allCases.compactMap { kind -> AgentUsageShare? in
                let matched = windowSessions.filter { $0.kind == kind }
                guard !matched.isEmpty else { return nil }
                return AgentUsageShare(kind: kind, sessionCount: matched.count, totalSeconds: matched.reduce(0) { $0 + $1.duration(until: settledAt) })
            }

            return DashboardStats(
                date: settledAt,
                sessionCount: windowSessions.count,
                totalActiveSeconds: totalSeconds,
                filesModified: windowFiles.filter { $0.kind == .modified }.count,
                filesCreated: windowFiles.filter { $0.kind == .created }.count,
                filesDeleted: windowFiles.filter { $0.kind == .deleted }.count,
                commandsExecuted: windowCommands.count,
                failedCommands: windowCommands.filter { $0.outcome == .failure }.count,
                riskEventCount: windowRisks.count,
                highRiskEventCount: windowRisks.filter { $0.level >= .high }.count,
                averageCPUPercent: windowPerf.isEmpty ? 0 : windowPerf.reduce(0) { $0 + $1.cpuPercent } / Double(windowPerf.count),
                peakCPUPercent: windowPerf.map(\.cpuPercent).max() ?? 0,
                peakMemoryBytes: windowPerf.map(\.memoryBytes).max() ?? 0,
                // 当前状态快照：与查询窗口无关（契约既有口径，本格未动）。
                activeAgentCount: s.agents.filter { $0.state == .running }.count,
                hourlyActivity: hourly,
                agentShares: shares,
                bucketSpan: span
            )
        }
    }

    // MARK: 活动分桶（与 `ObservatoryStore+Queries.swift` 逐字同一条口径：#75 裁定 9）

    /// 窗口宽度 → 桶粒度：≤ 36 h 小时桶，> 36 h 或无端点（「全部」）自然日桶。
    private static func bucketSpan(for range: DateRangeFilter) -> ActivityBucketSpan {
        guard let start = range.start, let end = range.end else { return .naturalDay }
        return end.timeIntervalSince(start) <= 36 * 3600 ? .hourOfDay : .naturalDay
    }

    /// 一次聚合最多回多少格（日档下等于一年），与 `ObservatoryStore.maxActivityBuckets` 同值。
    private static let maxActivityBuckets = 366

    /// 分桶：事件计数与采样 CPU 均值按**桶起点**归到同一序号，再补齐成连续格子（空格 eventCount = 0）。
    /// 序号口径与两个真后端逐字相同（见 `DashboardStats.bucketSpan` 注释）：
    ///   · 小时档：锚点 = 窗口起点落到整点，序号 = 自锚点起的小时偏移 ⇒「今天」那档恰好 0…23；
    ///   · 自然日档：锚点 = 结算时刻所在自然日零点，序号 = 带符号的天偏移。
    /// 用 `Calendar` 数格子，不做秒除（§5）。纯函数，不碰共享状态、不引并发原语。
    private static func activityBuckets(
        events: [TimelineEvent],
        samples: [PerformanceSample],
        span: ActivityBucketSpan,
        range: DateRangeFilter,
        settledAt: Date,
        calendar: Calendar = .current
    ) -> [HourlyActivity] {
        let anchor = span == .naturalDay
            ? calendar.startOfDay(for: settledAt)
            : floorToHour(range.start ?? settledAt, calendar: calendar)

        var eventCount: [Int: Int] = [:]
        var cpuSum: [Int: Double] = [:]
        var cpuSamples: [Int: Int] = [:]
        for event in events {
            let slot = bucketIndex(from: anchor, to: event.timestamp, span: span, calendar: calendar)
            eventCount[slot, default: 0] += 1
        }
        for sample in samples {
            let slot = bucketIndex(from: anchor, to: sample.timestamp, span: span, calendar: calendar)
            cpuSum[slot, default: 0] += sample.cpuPercent
            cpuSamples[slot, default: 0] += 1
        }

        let populated = Set(eventCount.keys).union(cpuSamples.keys)
        let slots = paddedSlots(populated, span: span, range: range, settledAt: settledAt, anchor: anchor, calendar: calendar)
        return slots.map { slot in
            let n = cpuSamples[slot] ?? 0
            return HourlyActivity(
                hour: slot,
                eventCount: eventCount[slot] ?? 0,
                cpuAverage: n > 0 ? cpuSum[slot]! / Double(n) : 0
            )
        }
    }

    /// 把散落的有数据桶铺成一段连续序号区间（边界只由窗口与数据决定），与 Store 的 `paddedSlots` 同一条：
    ///   · 日档两边都补：窗口起点那天 ⇄ 结算那天（「全部」无起点 ⇒ 只补到最早有数据那天）；
    ///   · 小时档从锚点补到窗口末，至少覆盖最后一个有数据的格子。
    private static func paddedSlots(
        _ populated: Set<Int>,
        span: ActivityBucketSpan,
        range: DateRangeFilter,
        settledAt: Date,
        anchor: Date,
        calendar: Calendar
    ) -> [Int] {
        let present = Array(populated)
        let endLimit = paddingEnd(range: range, settledAt: settledAt, span: span, calendar: calendar)
        let endSlot = bucketIndex(from: anchor, to: endLimit, span: span, calendar: calendar)
        let lastSlot = max(present.max() ?? endSlot, endSlot)
        let firstSlot: Int
        if span == .naturalDay {
            let windowSlot = range.start.map { bucketIndex(from: anchor, to: $0, span: span, calendar: calendar) }
            firstSlot = min(present.min() ?? lastSlot, windowSlot ?? lastSlot)
        } else {
            firstSlot = min(present.min() ?? 0, 0)
        }
        guard lastSlot >= firstSlot else { return [] }
        let count = min(lastSlot - firstSlot + 1, maxActivityBuckets)
        guard count > 0 else { return [] }
        return Array(firstSlot..<(firstSlot + count))
    }

    /// 补齐右边界（三条口径与 Store 逐字相同）：无终点→结算时刻；终点正好落在桶边界→退一格；
    /// 其余取 `min(终点, 结算时刻)`。「今天」那档因此仍是整 24 格（0…23，与改造前逐格相同）。
    private static func paddingEnd(
        range: DateRangeFilter,
        settledAt: Date,
        span: ActivityBucketSpan,
        calendar: Calendar
    ) -> Date {
        guard let end = range.end else { return settledAt }
        if floorBucketStart(end, span: span, calendar: calendar) == end {
            return calendar.date(byAdding: span.calendarUnit, value: -1, to: end) ?? end
        }
        return min(end, settledAt)
    }

    /// 锚点到 `date` 所属桶起点之间隔了几个粒度单位（日档往回数为负）。
    private static func bucketIndex(
        from anchor: Date,
        to date: Date,
        span: ActivityBucketSpan,
        calendar: Calendar
    ) -> Int {
        let unit = span.calendarUnit
        let floored = floorBucketStart(date, span: span, calendar: calendar)
        return calendar.dateComponents([unit], from: anchor, to: floored).value(for: unit) ?? 0
    }

    /// 把时刻落到它所属的桶起点（小时档 = 整点，日档 = `startOfDay`）。
    private static func floorBucketStart(_ date: Date, span: ActivityBucketSpan, calendar: Calendar) -> Date {
        span == .hourOfDay ? floorToHour(date, calendar: calendar) : calendar.startOfDay(for: date)
    }

    /// `Calendar` 里「这一小时」的起点（§5 不许手写 `ts - ts % 3600`）。
    private static func floorToHour(_ date: Date, calendar: Calendar = .current) -> Date {
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour]
        return calendar.date(from: calendar.dateComponents(parts, from: date)) ?? date
    }

    public func activeAgents() async throws -> [AgentInstance] {
        state.withLock { $0.agents.filter { $0.state == .running || $0.state == .idle } }
    }

    public func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        state.withLock { s in
            var results = s.sessions.filter { session in
                guard query.dateRange.contains(session.startedAt) else { return false }
                if !query.agentKinds.isEmpty, !query.agentKinds.contains(session.kind) { return false }
                if !query.outcomes.isEmpty, !query.outcomes.contains(session.outcome) { return false }
                if let project = query.projectPath, session.projectPath != project { return false }
                if !query.searchText.isEmpty {
                    let needle = query.searchText.lowercased()
                    let haystack = "\(session.title) \(session.projectPath ?? "") \(session.kind.displayName)".lowercased()
                    if !haystack.contains(needle) { return false }
                }
                return true
            }
            results.sort { query.sort.descending ? $0.startedAt > $1.startedAt : $0.startedAt < $1.startedAt }
            let total = results.count
            let page = Array(results.dropFirst(query.offset).prefix(query.limit))
            return Page(items: page, totalCount: total, offset: query.offset)
        }
    }

    public func session(id: UUID) async throws -> AgentSession? {
        state.withLock { $0.sessions.first { $0.id == id } }
    }

    public func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        state.withLock { s in
            var results = s.events.filter { event in
                guard query.dateRange.contains(event.timestamp) else { return false }
                if !query.kinds.isEmpty, !query.kinds.contains(event.kind) { return false }
                if !query.agentKinds.isEmpty, !query.agentKinds.contains(event.agentKind) { return false }
                if let sessionID = query.sessionID, event.sessionID != sessionID { return false }
                if let project = query.projectPath, event.projectPath != project { return false }
                if event.riskLevel < query.minimumRisk { return false }
                if !query.searchText.isEmpty {
                    let needle = query.searchText.lowercased()
                    let haystack = "\(event.title) \(event.summary) \(event.filePath ?? "") \(event.command ?? "")".lowercased()
                    if !haystack.contains(needle) { return false }
                }
                return true
            }
            results.sort { query.sort.descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
            let total = results.count
            let page = Array(results.dropFirst(query.offset).prefix(query.limit))
            return Page(items: page, totalCount: total, offset: query.offset)
        }
    }

    public func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        state.withLock { s in
            var results = s.fileChanges.filter { change in
                guard query.dateRange.contains(change.timestamp) else { return false }
                if !query.kinds.isEmpty, !query.kinds.contains(change.kind) { return false }
                if !query.agentKinds.isEmpty, !query.agentKinds.contains(change.agentKind) { return false }
                if let sessionID = query.sessionID, change.sessionID != sessionID { return false }
                if let project = query.projectPath, change.projectPath != project { return false }
                if let prefix = query.pathPrefix, !change.path.hasPrefix(prefix) { return false }
                if !query.searchText.isEmpty, !change.path.lowercased().contains(query.searchText.lowercased()) { return false }
                return true
            }
            results.sort { query.sort.descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
            let total = results.count
            let page = Array(results.dropFirst(query.offset).prefix(query.limit))
            return Page(items: page, totalCount: total, offset: query.offset)
        }
    }

    public func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        state.withLock { $0.diffs[changeID] }
    }

    public func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        state.withLock { s in
            var results = s.commands.filter { record in
                guard query.dateRange.contains(record.startedAt) else { return false }
                if !query.agentKinds.isEmpty, !query.agentKinds.contains(record.agentKind) { return false }
                if let sessionID = query.sessionID, record.sessionID != sessionID { return false }
                if !query.outcomes.isEmpty, !query.outcomes.contains(record.outcome) { return false }
                if query.withNonZeroExitCode, (record.exitCode ?? 0) == 0 { return false }
                if query.destructiveOnly, !record.isDestructive { return false }
                if !query.searchText.isEmpty, !record.commandLine.lowercased().contains(query.searchText.lowercased()) { return false }
                return true
            }
            results.sort { query.sort.descending ? $0.startedAt > $1.startedAt : $0.startedAt < $1.startedAt }
            let total = results.count
            let page = Array(results.dropFirst(query.offset).prefix(query.limit))
            return Page(items: page, totalCount: total, offset: query.offset)
        }
    }

    public func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        state.withLock { s in
            s.performance.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
        }
    }

    public func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        state.withLock { s in
            s.systemPerformance.filter { $0.timestamp >= date }.sorted { $0.timestamp < $1.timestamp }
        }
    }

    public func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        state.withLock { s in
            var results = s.risks.filter { risk in
                guard query.dateRange.contains(risk.timestamp) else { return false }
                if !query.levels.isEmpty, !query.levels.contains(risk.level) { return false }
                if !query.categories.isEmpty, !query.categories.contains(risk.category) { return false }
                if !query.agentKinds.isEmpty, !query.agentKinds.contains(risk.agentKind) { return false }
                if let sessionID = query.sessionID, risk.sessionID != sessionID { return false }
                if query.unacknowledgedOnly, risk.isAcknowledged { return false }
                if !query.searchText.isEmpty {
                    let needle = query.searchText.lowercased()
                    if !"\(risk.title) \(risk.detail) \(risk.command ?? "")".lowercased().contains(needle) { return false }
                }
                return true
            }
            results.sort { query.sort.descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
            let total = results.count
            let page = Array(results.dropFirst(query.offset).prefix(query.limit))
            return Page(items: page, totalCount: total, offset: query.offset)
        }
    }

    public func projects() async throws -> [ProjectActivity] {
        state.withLock { $0.projects.sorted { $0.lastSeenAt > $1.lastSeenAt } }
    }

    public func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        state.withLock { s in
            guard var project = s.projects.first(where: { $0.path == path }) else { return nil }
            let changes = s.fileChanges.filter { $0.projectPath == path && dateRange.contains($0.timestamp) }
            let commands = s.commands.filter { $0.projectPath == path && dateRange.contains($0.startedAt) }
            project.fileChangeCount = changes.count
            project.commandCount = commands.count
            project.codeGrowthLines = changes.reduce(0) { $0 + $1.linesAdded }
            project.codeShrinkLines = changes.reduce(0) { $0 + $1.linesRemoved }
            return project
        }
    }
}
