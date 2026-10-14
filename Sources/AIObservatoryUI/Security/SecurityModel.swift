//
//  SecurityModel.swift
//  AIObservatoryUI / Security
//
//  Owner: WS-UI (subagent D)
//  职责：Security 板块数据流 —— 真实调用 riskEvents(matching:) 过滤分页，确认动作调用 controller.acknowledgeRiskEvent。
//

import Foundation
import Observation
import AIObservatoryCore

/// 过滤条件的可哈希快照：用作 `.task(id:)` 的触发键，任一条件变化即重新查询。
///
/// 刻意**不含** `query.sessionID` 与 `query.projectPath`：那两维只有跳转那座桥在写，
/// 而桥自己走 `applyJumpConditions → load()` 那一条重查（与本页的 `filterToken` 任务同一扇门，
/// 只是早一步）。把它们再塞进这把键里，等于一次跳转被两个观察者各扳一遍 ⇒ 多发一条查询
/// （AGENTS.md §6）。桥侧的用例钉的是「落完条件恰好发一条」。
struct SecurityFilterToken: Hashable {
    var range: ObservatoryTimeRange
    var levels: [RiskLevel]
    var categories: [RiskCategory]
    var unacknowledgedOnly: Bool
    var searchText: String
}

@Observable @MainActor
final class SecurityModel {
    /// 列表内存上限：实时风险增量超限时从尾部裁剪。
    static let eventCap = 500
    /// 单次分页大小。
    static let pageSize = 100

    /// `errorMessage` 是哪一类动作留下的。
    ///
    /// #77 为什么需要这个：`errorMessage` 是**一个**存储位、**两类**动作在写
    /// （读取失败 / 确认落库失败）。要把「这次确认成功了 ⇒ 上一句『确认没有保存』已经过时」
    /// 做对，又**不顺手抹掉一条仍然成立的读取失败**，就必须知道当前这句话是谁说的。
    /// 没有它只有两种坏选择：成功路径不清错误（提示赖在屏幕上说一件已经不做数的事），
    /// 或者成功路径无条件清（把读取失败一起抹掉 = 又回到「失败没有提示」）。
    enum ErrorOrigin: Hashable {
        case reading
        case acknowledgement
    }

    private(set) var isLoading = false
    private(set) var errorMessage: String? {
        didSet {
            // 被别处（含 `load()` 开头那句 `errorMessage = nil`）清空时，出处一起清空：
            // 否则残留的 origin 会让下一次渲染认错了主语。
            if errorMessage == nil { errorOrigin = nil }
        }
    }
    /// 当前那句错误是谁说的；`errorMessage == nil` 时恒为 nil。
    private(set) var errorOrigin: ErrorOrigin?

    private(set) var events: [RiskEvent] = []
    private(set) var totalCount = 0
    private(set) var hasMore = false
    /// 今日风险总数（独立小查询，不受当前过滤条件影响）。
    private(set) var todayTotal = 0

    /// 生效中的查询条件；过滤条直接绑定它。
    var query = RiskQuery.all
    /// 本地时间范围（初始跟随 Shell 全局范围）。
    var range: ObservatoryTimeRange = .lastSixHours
    var selected: RiskEvent?
    /// 非空时弹出确认 sheet。
    ///
    /// #77：换一张卡（id 变了，含收成 nil）时把**上一张卡**留下的确认失败提示撤掉。
    /// 不做这一件事，「卡内显示失败原话」就会串台：新卡一开张先背着别人的一条失败。
    /// 只撤确认类，读取失败不在此列（那条由列表上方的横幅继续负责）。
    var confirmationTarget: RiskEvent? {
        didSet {
            guard confirmationTarget?.id != oldValue?.id, errorOrigin == .acknowledgement else { return }
            errorMessage = nil
        }
    }

    private let runtime: ObservatoryRuntime

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
    }

    // MARK: Derived

    // 概览读数（待确认 / 高危待处置 / 敏感路径 / 已确认 / 今日）以前是这里四个
    // 各自独立的 `events.filter { … }`，一次 body 把同一个数组重过四遍，
    // 而且加第五个数的人不会去对齐前四个的口径。
    // 现在整页只读一个 `SecurityReadouts` 快照，见 `SecurityExtensions.swift`。

    var isFiltering: Bool {
        !query.levels.isEmpty || !query.categories.isEmpty || query.unacknowledgedOnly || !query.searchText.isEmpty
    }

    /// 当前过滤条件的快照；视图用它作为重新查询的 id。
    var filterToken: SecurityFilterToken {
        SecurityFilterToken(
            range: range,
            levels: query.levels.sorted(),
            categories: query.categories.sorted { $0.rawValue < $1.rawValue },
            unacknowledgedOnly: query.unacknowledgedOnly,
            searchText: query.searchText
        )
    }

    /// 契约里的确认开关：关闭时不自动弹确认 sheet。
    var confirmationEnabled: Bool { runtime.settings.enableRiskConfirmation }

    var selectedEvent: RiskEvent? {
        guard let selected else { return nil }
        return events.first { $0.id == selected.id }
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        // #77：只撤**读取类**的错误。确认落库失败那句说的是「刚才那一下没写进去」，
        // 而一次成功的重读并不 retract 它 —— 那一行照旧显示未确认，提示撤掉就等于
        // 「刷新一下，失败就没发生过」。台账要求的「失败时提示留在屏幕上」在这一头也得成立。
        if errorOrigin != .acknowledgement { errorMessage = nil }
        defer { isLoading = false }

        query.dateRange = range.dateRange()
        query.offset = 0
        query.limit = Self.pageSize

        do {
            let page = try await runtime.service.riskEvents(matching: query)
            events = Array(page.items.prefix(Self.eventCap))
            totalCount = page.totalCount
            hasMore = page.hasMore

            let today = try await runtime.service.riskEvents(
                matching: RiskQuery(dateRange: .today(), limit: 1)
            )
            todayTotal = today.totalCount

            if let selected, !events.contains(where: { $0.id == selected.id }) {
                self.selected = events.first
            }
        } catch {
            errorMessage = error.localizedDescription
            errorOrigin = .reading
        }
    }

    /// 下一页：只查 offset 之后的数据，不重查全库。
    func loadMore() async {
        guard hasMore, !isLoading else { return }
        isLoading = true
        defer { isLoading = false }

        query.dateRange = range.dateRange()
        query.offset = events.count
        query.limit = Self.pageSize

        do {
            let page = try await runtime.service.riskEvents(matching: query)
            var merged = events
            for item in page.items where !merged.contains(where: { $0.id == item.id }) {
                merged.append(item)
            }
            if merged.count > Self.eventCap {
                merged.removeFirst(merged.count - Self.eventCap)
            }
            events = merged
            totalCount = page.totalCount
            hasMore = page.hasMore
        } catch {
            errorMessage = error.localizedDescription
            errorOrigin = .reading
        }
    }

    // MARK: Actions

    /// 真实确认：**先落库，只有落库成功才更新界面状态**。
    ///
    /// 旧写法是 `await controller.acknowledgeRiskEvent(...)`（那时协议不抛错，失败只进
    /// `os_log`）之后无条件 `markAcknowledged` ⇒ 界面显示"已确认"、库里仍是未确认、
    /// 重启就翻回去。需求⑧ 的处置动作上，"以为处置过了"比"报错说没处置成"严重得多。
    /// `@discardableResult` 是为了让既有调用点（sheet / 批量确认）不必跟着改返回值。
    ///
    /// ⚠️ #77 的另一半：失败时这句 `errorMessage` **必须有人渲染**。以前渲染条件是
    /// `errorMessage != nil && events.isEmpty`，而点确认时列表必然非空 ⇒ 值设了、屏幕没读。
    /// 现由 `SecurityView`（列表上方的横幅）与 `SecurityConfirmationSheet`（卡内）共同渲染，
    /// 两个调用点都从这一个出处取原文，界面不再自己拼第二句。
    @discardableResult
    func acknowledge(event: RiskEvent) async -> Bool {
        do {
            try await runtime.controller.acknowledgeRiskEvent(id: event.id)
        } catch {
            // 不吞异常：把底层原因原样带进给用户看的那一句（`ackSaveFailed` 的 %@）。
            // 状态一律不动：这一条仍显示未确认，用户可以重试。
            errorMessage = SecurityCopy.ackSaveFailed.format(UILanguage.current, error.localizedDescription)
            errorOrigin = .acknowledgement
            return false
        }
        // 成功 ⇒ 上一句「确认没有保存」已经过时，撤掉它；
        // 只撤**确认类**的错误，读取失败仍然成立，不该被一次成功的写顺手抹掉。
        if errorOrigin == .acknowledgement { errorMessage = nil }
        markAcknowledged(id: event.id)
        if confirmationTarget?.id == event.id { confirmationTarget = nil }
        return true
    }

    /// 逐条串行确认当前可见的未确认事件；**第一条失败就停**。
    /// 落库失败通常是同一个原因（库不可写 / 已关闭），继续跑只会把 N 条失败堆成 N 条提示。
    func acknowledgeAllVisible() async {
        let pending = events.filter { !$0.isAcknowledged }
        for event in pending {
            if !(await acknowledge(event: event)) { return }
        }
    }

    /// 为待确认事件准备 sheet 目标（由用户点击触发，非自动弹出）。
    func requestConfirmation(for event: RiskEvent) {
        guard event.requiresConfirmation, !event.isAcknowledged else { return }
        confirmationTarget = event
    }

    func presentNextConfirmationIfNeeded() {
        guard confirmationEnabled, confirmationTarget == nil else { return }
        confirmationTarget = events.first { $0.requiresConfirmation && !$0.isAcknowledged }
    }

    private func markAcknowledged(id: UUID) {
        guard let index = events.firstIndex(where: { $0.id == id }) else { return }
        events[index].isAcknowledged = true
        if selected?.id == id { selected = events[index] }
    }

    // MARK: Filters

    func toggle(level: RiskLevel) {
        if query.levels.contains(level) {
            query.levels.remove(level)
        } else {
            query.levels.insert(level)
        }
    }

    func toggle(category: RiskCategory) {
        if query.categories.contains(category) {
            query.categories.remove(category)
        } else {
            query.categories.insert(category)
        }
    }

    func resetFilters() {
        query.levels = []
        query.categories = []
        query.unacknowledgedOnly = false
        query.searchText = ""
    }

    // MARK: Live updates

    func observeUpdates() async {
        for await update in runtime.updates.makeUpdateStream() {
            ingest(update)
        }
    }

    private func ingest(_ update: ObservatoryUpdate) {
        switch update {
        case .risk(let event):
            guard matchesQuery(event) else { return }
            events.insert(event, at: 0)
            if events.count > Self.eventCap {
                events.removeLast(events.count - Self.eventCap)
            }
            totalCount += 1
            if DateRangeFilter.today().contains(event.timestamp) { todayTotal += 1 }
            if !event.isAcknowledged, event.requiresConfirmation, confirmationEnabled, confirmationTarget == nil {
                confirmationTarget = event
            }
        case .timelineEvent, .agents, .sessions, .fileChange, .command, .performance, .dashboard, .engineState:
            break
        }
    }

    /// 与 Engine 侧一致的本地判定，用于实时增量是否应进入当前列表。
    private func matchesQuery(_ event: RiskEvent) -> Bool {
        guard query.dateRange.contains(event.timestamp) else { return false }
        if !query.levels.isEmpty, !query.levels.contains(event.level) { return false }
        if !query.categories.isEmpty, !query.categories.contains(event.category) { return false }
        if !query.agentKinds.isEmpty, !query.agentKinds.contains(event.agentKind) { return false }
        if let sessionID = query.sessionID, event.sessionID != sessionID { return false }
        // #81(a)：服务端那条 `RiskQuery.projectPath` 走的是「风险 → 会话 → 项目」归属边，
        // 而 `RiskEvent` 自己不挂项目、这一头手上也没有会话→项目的映射表，**本地判不出**归属。
        // 于是取保守侧：带了项目条件时，实时增量一律不插（宁可少给也不猜）——
        // 把某条判不出项目的风险插进「只看这个项目」的列表，就是让它冒充这个项目的证据，
        // 比晚一条更坏。列表本身在跳转那一刻由 `applyJumpConditions → load()` 从库里读回筛好的那批。
        if query.projectPath != nil { return false }
        if query.unacknowledgedOnly, event.isAcknowledged { return false }
        if !query.searchText.isEmpty {
            let needle = query.searchText.lowercased()
            let haystack = "\(event.title) \(event.detail) \(event.command ?? "")".lowercased()
            if !haystack.contains(needle) { return false }
        }
        return true
    }
}
