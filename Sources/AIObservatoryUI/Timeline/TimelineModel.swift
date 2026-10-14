//
//  TimelineModel.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent C) → WS-QUIET-1 (subagent A) 改版
//  时间线板块数据流：EventQuery 构造、分页、过滤状态下推、实时增量合并与内存裁剪。
//  铁律：增量事件只做头部插入，禁止每次重查全库。
//
//  【口径分界，quiet 改版加的】本文件里所有派生读数分成两类，**命名时必须体现**：
//    ① `totalCount` / `hasMore` —— 服务端按 query 算出的**权威总数**，与分页无关；
//    ② `loaded*` / `riskEventCount` / `dayBuckets` / `busiestHour` … —— 由**已加载**的
//       ≤ `pageSize`(200) 条 `events` 算出，**不代表全库**。视图侧把它们显示出来时
//       必须在 caption / subtitle 里写「已加载 N 条中」，否则界面就在说谎。
//

import Foundation
import Observation
import AIObservatoryCore

// MARK: - Day bucket

/// 一天的事件桶（`TimelineView` 用它渲染分组头：日期 + 条数 + 当日风险徽标）。
struct TimelineDayBucket: Identifiable {
    /// 该天的零点，用作分组稳定标识。
    let day: Date
    let events: [TimelineEvent]

    var id: Date { day }

    /// 当天风险 ≥ medium 的条数（分组头徽标用）。
    var riskCount: Int {
        events.lazy.filter { $0.riskLevel >= .medium }.count
    }
}

/// 已加载集合里事件最密集的一小时（`TimelineView` 的「最活跃时段」指标格用）。
/// ⚠️ 口径：只统计**已加载**的那 ≤ pageSize 条，所以它是「这一页里最忙的钟点」，
/// 不是「全库最忙的钟点」。caption 必须把这条边界写出来。
struct TimelineBusyHour: Hashable {
    /// 该小时的整点起点。
    let start: Date
    /// 该小时内已加载的事件条数。
    let count: Int
}

// MARK: - Model

@Observable @MainActor final class TimelineModel {

    // MARK: Tunables

    /// 单页大小（契约要求 200）。
    static let pageSize = 200
    /// 内存中保留的事件上限，超出丢弃尾部（最旧的一条）。
    static let maxRetainedEvents = 1_000

    // MARK: Dependencies

    private let runtime: ObservatoryRuntime

    // MARK: Load state

    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var errorMessage: String?

    /// 与 `query.sort` 方向一致的事件（默认新→旧）。
    private(set) var events: [TimelineEvent] = []

    /// 服务端匹配总数（分页语义下 ≠ events.count）。
    private(set) var totalCount: Int = 0
    private(set) var hasMore: Bool = false

    // MARK: Filter state（每一项都直接落到 EventQuery）

    /// 当前查询。视图通过 `applyFilters()` 触发重查。
    var query: EventQuery

    /// 板块内时间范围（默认跟随 `ShellModel.timeRange`）→ `query.dateRange`。
    var timeRange: ObservatoryTimeRange = .all {
        didSet {
            guard oldValue != timeRange else { return }
            query.dateRange = timeRange.dateRange(now: Date())
        }
    }

    /// 「只看风险」开关 → true: `query.minimumRisk = .high`；false: `.low`。
    var riskOnly: Bool = false {
        didSet {
            guard oldValue != riskOnly else { return }
            query.minimumRisk = riskOnly ? .high : .low
        }
    }

    /// 呈现密度（不影响查询）。
    var density: TimelineDensity = .comfortable

    /// 选中事件（驱动 `TimelineDetailPanel`）。
    var selectedEventID: UUID?

    /// 单调递增加载令牌：丢弃被更晚查询覆盖的异步结果。
    private var loadToken: Int = 0

    // MARK: Init

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        self.query = EventQuery(limit: Self.pageSize, offset: 0, sort: .newestFirst)
    }

    // MARK: Derived

    var selectedEvent: TimelineEvent? {
        guard let selectedEventID else { return nil }
        return events.first { $0.id == selectedEventID }
    }

    /// 详情面板有没有内容可显示 —— 驱动 `.inspector(isPresented:)`。命名与 Sessions 页对齐
    /// （`SessionsModel.showsDetailPanel`），两页是同一套主从布局解法。
    /// ⚠️ 这里**不能**只看 `selectedEventID != nil`：重查 / 裁剪 / 内存上限都可能把选中那条
    /// 挤出 `events`，那时 id 还在但详情是空的，面板没理由继续占着一列。
    var showsDetailPanel: Bool { selectedEvent != nil }

    /// 关闭详情面板（inspector 的系统开关与「关闭」按钮都走这里）。
    func clearSelection() {
        selectedEventID = nil
    }

    /// 用户主动收紧的「条件类」过滤项数量（不含时间范围）。
    ///
    /// #81 补上 `projectPath` / `sessionID` 两项：它们过去只能从别处（跳转意图）落进来，
    /// 于是出现新的一格说谎——列表已经被某一次跳转筛到 12 条，徽标还写着「0 项筛选生效」。
    /// 这两项在本页没有控件，唯一的写入口就是 `EvidenceJumpWiring`，所以它们**必须**算进来，
    /// 否则「筛选生效」这个读数只统计了本页能改的那一半。
    var activeFilterCount: Int {
        var count = 0
        if !query.kinds.isEmpty { count += 1 }
        if !query.agentKinds.isEmpty { count += 1 }
        if !query.searchText.isEmpty { count += 1 }
        if query.projectPath != nil { count += 1 }
        if query.sessionID != nil { count += 1 }
        if query.minimumRisk > .low { count += 1 }
        return count
    }

    /// 是否处于「有数据但被过滤光」的语义（决定空态文案与重置按钮）。
    var hasNarrowedFilters: Bool {
        activeFilterCount > 0 || timeRange != .all
    }

    var isEmptyLoad: Bool { events.isEmpty && totalCount == 0 }

    /// 已加载条数 / 服务端总数。**底部状态条已经取消**，这一句现在挂在
    /// 事件流 `SectionHeader` 的 subtitle 上（口径说明离数据最近）。
    var loadedProgressText: String {
        TimelineCopy.loadedProgress.format(UILanguage.current, events.count, totalCount)
    }

    /// 当前已加载集合里风险 ≥ medium 的条数。
    /// ⚠️ 口径：已加载（≤ pageSize），**不是**服务端全量风险数——`EventQuery.minimumRisk`
    /// 过滤下推的只有服务端能算的部分，这个数是本地二次统计。
    var riskEventCount: Int {
        events.lazy.filter { $0.riskLevel >= .medium }.count
    }

    /// 已加载集合里 critical 的条数（「风险事件」那格的副标题，避免只报 ≥ medium 却读成高危数）。
    var loadedCriticalEventCount: Int {
        events.lazy.filter { $0.riskLevel == .critical }.count
    }

    /// 已加载集合里出现过的 Agent **类型**数（按 `AgentKind` 去重，不是实例 / 进程数）。
    var loadedAgentKindCount: Int {
        Set(events.lazy.map(\.agentKind)).count
    }

    /// 已加载集合里的「执行命令」事件数。
    var loadedCommandCount: Int {
        events.lazy.filter { $0.kind == .commandExecuted }.count
    }

    /// 已加载命令事件里退出码非 0 的条数。退出码为 nil（还没回填）**不算失败**。
    var loadedFailedCommandCount: Int {
        events.lazy.filter { $0.kind == .commandExecuted && ($0.exitCode ?? 0) != 0 }.count
    }

    /// 已加载集合里的文件变更事件数（创建 / 修改 / 删除 / 重命名）。
    var loadedFileChangeCount: Int {
        events.lazy.filter {
            $0.kind == .fileCreated || $0.kind == .fileModified
                || $0.kind == .fileDeleted || $0.kind == .fileRenamed
        }.count
    }

    /// 已加载文件变更里「删除」的条数（副标题用：删除是本板块唯一需要立刻处理的文件动作）。
    var loadedFileDeletedCount: Int {
        events.lazy.filter { $0.kind == .fileDeleted }.count
    }

    /// 已加载集合跨了几个日历日（＝ `dayBuckets.count`，但这里不重建桶数组，
    /// 免得 body 里每读一次就多一次整表分组）。
    var loadedDayCount: Int {
        let calendar = Calendar.current
        return Set(events.lazy.map { calendar.startOfDay(for: $0.timestamp) }).count
    }

    /// 已加载集合里事件最密集的一小时；无事件时 nil（视图显示「—」，不许编一个）。
    /// 并列时取**更晚**的那个钟点，保证同一份数据每次渲染读出同一个数
    /// （`Dictionary` 的遍历序不稳定，不写这条 tie-break 数字会随机跳）。
    var busiestHour: TimelineBusyHour? {
        guard !events.isEmpty else { return nil }
        let calendar = Calendar.current
        var counts: [Date: Int] = [:]
        for event in events {
            let hour = calendar.dateInterval(of: .hour, for: event.timestamp)?.start ?? event.timestamp
            counts[hour, default: 0] += 1
        }
        guard let best = counts.max(by: { lhs, rhs in
            lhs.value != rhs.value ? lhs.value < rhs.value : lhs.key < rhs.key
        }) else { return nil }
        return TimelineBusyHour(start: best.key, count: best.value)
    }

    /// 已加载最早 ↔ 最晚事件之间的跨度（「—」表示还没有事件）。
    var loadedSpanText: String {
        guard let oldest = loadedOldestEventAt, let newest = loadedNewestEventAt else { return "—" }
        return DurationFormat.humanReadable(max(0, newest.timeIntervalSince(oldest)))
    }

    /// 已加载集合里最早一条事件的时间。
    var loadedOldestEventAt: Date? { events.lazy.map(\.timestamp).min() }

    /// 已加载集合里最晚一条事件的时间（增量事件从头部插入，所以它未必是 `events.first`）。
    var loadedNewestEventAt: Date? { events.lazy.map(\.timestamp).max() }

    /// 按天分桶。桶顺序跟随 `query.sort`；桶内恒为「新→旧」或「旧→新」与排序一致。
    var dayBuckets: [TimelineDayBucket] {
        let calendar = Calendar.current
        var buckets: [Date: [TimelineEvent]] = [:]
        var order: [Date] = []
        for event in events {
            let day = calendar.startOfDay(for: event.timestamp)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(event)
        }
        // events 本身已按 sort 有序，order 自然继承同一方向，这里只保证桶内同向。
        let descending = query.sort.descending
        return order.map { day in
            let items = buckets[day] ?? []
            let sorted = items.sorted {
                descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp
            }
            return TimelineDayBucket(day: day, events: sorted)
        }
    }

    // MARK: Loading

    func load() async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        errorMessage = nil
        do {
            let page = try await runtime.service.events(matching: query)
            guard token == loadToken else { return }
            events = page.items
            totalCount = page.totalCount
            hasMore = page.hasMore
            isLoading = false
        } catch {
            guard token == loadToken else { return }
            events = []
            totalCount = 0
            hasMore = false
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// 下一页：`offset += limit`，并与已加载集合去重合并。
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let previousOffset = query.offset
        query.offset = previousOffset + query.limit
        do {
            let page = try await runtime.service.events(matching: query)
            if page.items.isEmpty {
                query.offset = previousOffset
                hasMore = false
            } else {
                merge(page.items)
                totalCount = page.totalCount
                hasMore = page.hasMore
            }
        } catch {
            query.offset = previousOffset
            errorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }

    func applyFilters() async {
        query.offset = 0
        await load()
    }

    // MARK: Filter mutation

    /// 时间范围（视图层负责同步回 `ShellModel.timeRange`）。
    func setTimeRange(_ range: ObservatoryTimeRange) async {
        guard timeRange != range else { return }
        timeRange = range
        await applyFilters()
    }

    /// 操作类型多选。空集合 == 不过滤（`EventQuery` 约定）。
    func toggleKind(_ kind: OperationKind) async {
        var next = query.kinds
        if next.contains(kind) {
            next.remove(kind)
        } else {
            next.insert(kind)
        }
        await setKinds(next)
    }

    func setKinds(_ kinds: Set<OperationKind>) async {
        query.kinds = kinds.count >= OperationKind.allCases.count ? [] : kinds
        await applyFilters()
    }

    func toggleAgentKind(_ kind: AgentKind) async {
        var next = query.agentKinds
        if next.contains(kind) {
            next.remove(kind)
        } else {
            next.insert(kind)
        }
        await setAgentKinds(next)
    }

    func setAgentKinds(_ kinds: Set<AgentKind>) async {
        query.agentKinds = kinds.count >= AgentKind.allCases.count ? [] : kinds
        await applyFilters()
    }

    func setRiskOnly(_ enabled: Bool) async {
        guard riskOnly != enabled else { return }
        riskOnly = enabled
        await applyFilters()
    }

    func setSearchText(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != query.searchText else { return }
        query.searchText = trimmed
        await applyFilters()
    }

    /// 重置全部过滤条件（含时间范围回到「全部」）。
    func resetFilters() async {
        query.kinds = []
        query.agentKinds = []
        query.searchText = ""
        query.sessionID = nil
        query.projectPath = nil
        riskOnly = false
        query.minimumRisk = .low
        timeRange = .all
        await applyFilters()
    }

    func select(_ eventID: UUID?) {
        selectedEventID = (selectedEventID == eventID) ? nil : eventID
    }

    // MARK: Live updates

    /// 订阅引擎推送：只做头部插入 / 原地回填，禁止重查全库。
    func observeUpdates() async {
        for await update in runtime.updates.makeUpdateStream() {
            if Task.isCancelled { break }
            ingest(update)
        }
    }

    private func ingest(_ update: ObservatoryUpdate) {
        switch update {
        case .timelineEvent(let event):
            absorb(event)

        case .command(let record):
            // 命令结束：把退出码 / 时长回填到那条「执行命令」事件上。
            applyExitCode(of: record)

        case .risk(let risk):
            raiseRisk(of: risk)

        case .fileChange, .agents, .sessions, .performance, .dashboard, .engineState:
            return
        }
    }

    // MARK: - Private helpers

    private func absorb(_ event: TimelineEvent) {
        guard matchesCurrentQuery(event) else { return }
        guard !events.contains(where: { $0.id == event.id }) else { return }
        insert(event)
        totalCount += 1
        hasMore = events.count < totalCount
    }

    private func insert(_ event: TimelineEvent) {
        let descending = query.sort.descending
        let position = events.firstIndex { existing in
            descending ? existing.timestamp < event.timestamp : existing.timestamp > event.timestamp
        } ?? events.endIndex
        events.insert(event, at: position)
        trim(&events)
    }

    private func merge(_ incoming: [TimelineEvent]) {
        var seen: Set<UUID> = []
        var combined: [TimelineEvent] = []
        combined.reserveCapacity(events.count + incoming.count)
        for candidate in events + incoming where !seen.contains(candidate.id) {
            seen.insert(candidate.id)
            combined.append(candidate)
        }
        let descending = query.sort.descending
        combined.sort { descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
        trim(&combined)
        events = combined
    }

    /// 列表按 sort 有序，最旧一条固定在某一端 → 直接裁尾。
    private func trim(_ list: inout [TimelineEvent]) {
        guard list.count > Self.maxRetainedEvents else { return }
        let excess = list.count - Self.maxRetainedEvents
        if query.sort.descending {
            list.removeLast(excess)
        } else {
            list.removeFirst(excess)
        }
    }

    private func applyExitCode(of record: CommandRecord) {
        guard let exitCode = record.exitCode else { return }
        let line = record.commandLine
        guard let index = events.lastIndex(where: { event in
            guard event.kind == .commandExecuted else { return false }
            if event.sessionID != record.sessionID { return false }
            return event.command == line
        }) else { return }
        var event = events[index]
        guard event.exitCode != exitCode else { return }
        event.exitCode = exitCode
        if let duration = record.duration { event.durationSeconds = duration }
        if record.riskLevel > event.riskLevel { event.riskLevel = record.riskLevel }
        events[index] = event
    }

    private func raiseRisk(of risk: RiskEvent) {
        var matched = false
        for index in events.indices {
            let event = events[index]
            let sameSession = event.sessionID != nil && event.sessionID == risk.sessionID
            let sameCommand = risk.command != nil && event.command == risk.command
            let samePath = event.filePath != nil && risk.filePaths.contains(event.filePath ?? "")
            guard sameSession || sameCommand || samePath else { continue }
            guard risk.level > event.riskLevel else { matched = true; continue }
            var updated = event
            updated.riskLevel = risk.level
            if updated.summary.isEmpty { updated.summary = risk.detail }
            events[index] = updated
            matched = true
        }
        guard !matched else { return }

        // 引擎只推了 RiskEvent：合成一条 riskDetected 事件，时间线不丢信息。
        let synthetic = TimelineEvent(
            timestamp: risk.timestamp,
            sessionID: risk.sessionID,
            agentID: risk.agentID,
            agentKind: risk.agentKind,
            kind: .riskDetected,
            title: risk.title,
            summary: risk.detail,
            filePath: risk.filePaths.first,
            command: risk.command,
            riskLevel: risk.level
        )
        guard !events.contains(where: { existing in
            existing.kind == .riskDetected
                && existing.timestamp == synthetic.timestamp
                && existing.title == synthetic.title
        }) else { return }
        absorb(synthetic)
    }

    /// 与 `ObservatoryService.events(matching:)` 一致的过滤语义（增量路径必须复刻）。
    private func matchesCurrentQuery(_ event: TimelineEvent) -> Bool {
        guard query.dateRange.contains(event.timestamp) else { return false }
        if let sessionID = query.sessionID, event.sessionID != sessionID { return false }
        if let project = query.projectPath, event.projectPath != project { return false }
        if !query.kinds.isEmpty, !query.kinds.contains(event.kind) { return false }
        if !query.agentKinds.isEmpty, !query.agentKinds.contains(event.agentKind) { return false }
        if event.riskLevel < query.minimumRisk { return false }
        if !query.searchText.isEmpty {
            let needle = query.searchText.lowercased()
            let haystack = "\(event.title) \(event.summary) \(event.filePath ?? "") \(event.command ?? "")"
                .lowercased()
            if !haystack.contains(needle) { return false }
        }
        return true
    }
}
