//
//  FilesModel.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent C)
//  文件板块数据流：变更列表分页与过滤、选中变更的 Before/After diff 懒加载、实时增量合并。
//

import Foundation
import Observation
import AIObservatoryCore

// MARK: - Supporting enums

/// diff 加载状态。
enum FilesDiffLoadState: String, CaseIterable {
    case idle
    case loading
    case loaded
    case missing
    case binary
    case truncated

    var isLoading: Bool { self == .loading }
    var showsContent: Bool { self == .loaded || self == .truncated }
}

/// diff 呈现模式。
enum FilesDiffViewMode: String, CaseIterable, Identifiable {
    case unified
    case sideBySide

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .unified:     return FilesCopy.viewModeUnified.text()
        case .sideBySide:  return FilesCopy.viewModeSideBySide.text()
        }
    }

    var symbol: String {
        switch self {
        case .unified:     return "text.alignleft"
        case .sideBySide:  return "rectangle.split.2x1"
        }
    }
}

// MARK: - Model

@Observable @MainActor final class FilesModel {

    /// 单页大小。
    static let pageSize = 150
    /// 内存中保留的变更上限，超出丢最旧的。
    static let maxRetainedChanges = 500

    private let runtime: ObservatoryRuntime

    // MARK: State

    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var errorMessage: String?
    /// 引擎状态（空态要说清「没在采集」与「在采集但这一页没记录」是两回事）。
    /// 默认 `.stopped` 与侧栏那颗状态点同一个起点，首帧就会被 `load()` 里的探活覆盖。
    private(set) var engineState: EngineState = .stopped

    /// 与 `query.sort` 方向一致的变更列表。
    private(set) var changes: [FileChange] = []
    private(set) var totalCount: Int = 0
    private(set) var hasMore: Bool = false

    var query: FileChangeQuery = .all

    var timeRange: ObservatoryTimeRange = .all {
        didSet {
            guard oldValue != timeRange else { return }
            query.dateRange = timeRange.dateRange(now: Date())
        }
    }

    /// 仅显示敏感路径（本地过滤，不下推到服务端查询）。
    var sensitiveOnly: Bool = false

    var viewMode: FilesDiffViewMode = .unified

    private(set) var selected: FileChange?
    private(set) var diff: FileDiff?
    private(set) var diffState: FilesDiffLoadState = .idle

    private var loadToken: Int = 0
    private var diffToken: Int = 0

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        self.query = FileChangeQuery(limit: Self.pageSize, offset: 0, sort: .newestFirst)
        self.timeRange = .all
    }

    // MARK: Derived

    var visibleChanges: [FileChange] {
        guard sensitiveOnly else { return changes }
        return changes.filter { PathHeuristics.isSensitive($0.path) }
    }

    var selectedDiff: FileDiff? { diffState.showsContent ? diff : nil }

    /// 用户主动收紧的条件类过滤项数量（不含搜索框之外的那一份本地开关）。
    ///
    /// #81 补 `projectPath` / `sessionID`：这两项在本页没有控件，只能经跳转意图落进来，
    /// 不数就会出现「列表只剩 3 条、徽标写着 0 项筛选生效」。
    var activeFilterCount: Int {
        var count = 0
        if !query.kinds.isEmpty { count += 1 }
        if !query.agentKinds.isEmpty { count += 1 }
        if !query.searchText.isEmpty { count += 1 }
        if query.projectPath != nil { count += 1 }
        if query.sessionID != nil { count += 1 }
        if sensitiveOnly { count += 1 }
        if timeRange != .all { count += 1 }
        return count
    }

    var isEmptyLoad: Bool { visibleChanges.isEmpty && totalCount == 0 }

    /// 本页的采集面实况（引擎那一轮解析出的 kept/dropped）。
    /// `nil` = 还没有读数——只说明「没有读数」，不代表用户没配监控根。
    private(set) var monitoringScope: MonitoringScope?

    /// 本次运行内的未归属机制分布（ICR-0009 / #54）。
    /// `nil` = 引擎这一轮还没处理过文件事件，与 `total == 0`（一条都没漏）是两件事，
    /// 界面必须分开说——`AttributionGapPanel` 的约束①。这份账不落库、重启归零，
    /// 所以措辞永远带「本次运行内」（约束②）。
    private(set) var attributionGap: AttributionGap?

    /// 本页的采集范围读数。唯一出处是引擎实况，**不再**从 `runtime.settings` 那份启动快照拼。
    ///
    /// #64：映射在这里注入，而不是在视图里包一层——这一句会同时从
    /// `FilesView` 的常驻行与空态说明两条路渲染，视图侧包就等于要记两处。
    /// `runtime.settings` 是启动快照 ⇒ 与 `ObservatoryRootView` 注入给 `FilePathText`
    /// 的那一份同源，改开关后同样**重启生效**（隐私页的 caveat 已经这么写）。
    var captureScope: CaptureScope {
        CaptureScope(live: monitoringScope,
                     rangeName: timeRange.displayName(UILanguage.current),
                     mask: PathPrivacy.Mask.configured(from: runtime.settings))
    }

    /// 空态口径；`nil` = 这一页有记录，不该出现空态话术。
    /// 视图只读它，不自己组织句子——两把尺的说法必须一致。
    var captureAvailability: CaptureAvailability? {
        CaptureAvailability.resolve(engineState: engineState, rowCount: changes.count, scope: captureScope)
    }

    /// 当前已加载集合的增删行数汇总。
    var loadedLineTotals: (added: Int, removed: Int) {
        visibleChanges.reduce((added: 0, removed: 0)) { total, change in
            (total.added + change.linesAdded, total.removed + change.linesRemoved)
        }
    }

    /// 该类型的**变更事件**条数（同一个文件被改三次就是三条）。
    /// 给「按类型筛选」的菜单用：那里要回答的是「选这一项会看到几行」，行就是事件。
    func eventCount(for kind: FileChangeKind) -> Int {
        changes.filter { $0.kind == kind }.count
    }

    /// 该类型涉及的**去重路径**数。
    ///
    /// 为什么要与 `eventCount(for:)` 分开：这两格的大字标题写的是「新建文件」「删除文件」，
    /// 用事件数填就等于**拿事件数冒充文件数**——同一路径被删两次会报成「删除文件 2」。
    /// 本文件里 `FilesView` 早就为 hero 踩过这一条（见 `distinctFileCount` 上方那段注释），
    /// 但分类型那三格一直在犯同一个错。
    /// ⚠️ 各类型之间可以重叠（一个文件可以先新建再被修改），所以
    /// `新建 + 修改 + 删除 + 重命名 ≥ 变更文件总数` 是**正常**的，界面必须把这句说出来。
    func distinctFileCount(for kind: FileChangeKind) -> Int {
        Set(changes.filter { $0.kind == kind }.map(\.path)).count
    }

    // MARK: Loading

    func load() async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        errorMessage = nil
        // 先取引擎状态与采集面实况，再取数：空态那句「没有在采集」和那句「正在监控 N 个根」
        // 都要有出处，不能猜。宿主没装配 monitoringScope 时这里是 nil ⇒ 界面说「尚无读数」，
        // 而不是把 nil 画成「0 个根」（那正是本文件要治的那类错）。
        let state = await runtime.updates.currentState()
        let (scope, gap) = await sampleEngineReadings()
        guard token == loadToken else { return }
        engineState = state
        monitoringScope = scope
        attributionGap = gap
        do {
            let page = try await runtime.service.fileChanges(matching: query)
            guard token == loadToken else { return }
            changes = page.items
            totalCount = page.totalCount
            hasMore = page.hasMore
            isLoading = false
            await ensureSelection()
        } catch {
            guard token == loadToken else { return }
            changes = []
            totalCount = 0
            hasMore = false
            diff = nil
            diffState = .idle
            selected = nil
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let previousOffset = query.offset
        query.offset = previousOffset + query.limit
        do {
            let page = try await runtime.service.fileChanges(matching: query)
            if page.items.isEmpty {
                query.offset = previousOffset
                hasMore = false
            } else {
                merge(page.items)
                totalCount = page.totalCount
                hasMore = page.hasMore || hasMore
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

    func setTimeRange(_ range: ObservatoryTimeRange) async {
        timeRange = range
        await applyFilters()
    }

    // MARK: Filter mutation

    func toggleKind(_ kind: FileChangeKind) async {
        if query.kinds.contains(kind) {
            query.kinds.remove(kind)
        } else {
            query.kinds.insert(kind)
        }
        if query.kinds.count >= FileChangeKind.allCases.count { query.kinds = [] }
        await applyFilters()
    }

    func toggleAgentKind(_ kind: AgentKind) async {
        if query.agentKinds.contains(kind) {
            query.agentKinds.remove(kind)
        } else {
            query.agentKinds.insert(kind)
        }
        if query.agentKinds.count >= AgentKind.allCases.count { query.agentKinds = [] }
        await applyFilters()
    }

    func setSearchText(_ text: String) async {
        guard text != query.searchText else { return }
        query.searchText = text
        await applyFilters()
    }

    func setSensitiveOnly(_ enabled: Bool) {
        sensitiveOnly = enabled
    }

    func resetFilters() async {
        query.kinds = []
        query.agentKinds = []
        query.searchText = ""
        query.pathPrefix = nil
        query.sessionID = nil
        query.projectPath = nil
        sensitiveOnly = false
        await applyFilters()
    }

    // MARK: Diff

    /// 选中一条变更并在后台拉取它的 diff；`nil` → `.missing`，二进制 → `.binary`。
    func select(_ change: FileChange) async {
        selected = change
        diffToken += 1
        let token = diffToken
        diff = nil
        diffState = .loading

        guard change.isText else {
            diffState = .binary
            return
        }

        do {
            let loaded = try await runtime.service.fileDiff(for: change.id)
            guard token == diffToken, selected?.id == change.id else { return }
            guard let loaded else {
                diffState = .missing
                return
            }
            diff = loaded
            if loaded.isBinary {
                diffState = .binary
            } else {
                diffState = loaded.isTruncated ? .truncated : .loaded
            }
        } catch {
            guard token == diffToken, selected?.id == change.id else { return }
            errorMessage = error.localizedDescription
            diffState = .missing
        }
    }

    func setViewMode(_ mode: FilesDiffViewMode) {
        viewMode = mode
    }

    // MARK: Live updates

    func observeUpdates() async {
        for await update in runtime.updates.makeUpdateStream() {
            if Task.isCancelled { break }
            await ingest(update)
        }
    }

    /// 引擎那两份只读实况（采集面、归属缺口）的唯一取样出口。
    /// `load()` 与推送路径共用：两处各写一遍的话，加了新读数只会有一处跟着长。
    private func sampleEngineReadings() async -> (scope: MonitoringScope?, gap: AttributionGap?) {
        let scope = await runtime.monitoringScope?.currentMonitoringScope()
        // 归属缺口走 `AttributionGapWiring` 那座临时桥（正门要等 `Runtime.attributionGap`，
        // §3 冻结区）。桥断了这里就是 nil ⇒ 那一格会说"尚无读数"，而那是假话——
        // 所以装配根那一条有独立的守卫用例，见 `AttributionGapWiring` 文件头。
        let gap = await AttributionGapWiring.reporter(runtime)?.currentAttributionGap()
        return (scope, gap)
    }

    /// 把两份读数写回模型。相等就不写：`@Observable` 不看内容只看赋值，
    /// 每条事件都写一遍等于让那一格跟着整个列表抖。
    private func applyEngineReadings(_ readings: (scope: MonitoringScope?, gap: AttributionGap?)) {
        if readings.scope != monitoringScope { monitoringScope = readings.scope }
        if readings.gap != attributionGap { attributionGap = readings.gap }
    }

    private func ingest(_ update: ObservatoryUpdate) async {
        switch update {
        case .fileChange(let change):
            // 先重取样，再判过滤：引擎那本账数的是**它处理过的事件**，跟本页的筛选条件无关。
            // 放在 `matchesCurrentQuery` 之后就是一条被筛掉的事件永远唤不起这次取样。
            //
            // 为什么必须有这一句：两份读数过去只在 `load()` 里取一次，而列表是走推送长起来的
            // ⇒ 页面开着不动，下面每一行都写「未能归属」，上面那一格仍停在启动值
            // 「本次运行尚无归属读数：引擎还没处理过文件事件」。07:55 真机就是这么撞见的。
            // `ObservatoryUpdate` 里没有承载这两份读数的 case（§3 冻结），只能由界面回头再取。
            applyEngineReadings(await sampleEngineReadings())
            guard matchesCurrentQuery(change) else { return }
            guard !changes.contains(where: { $0.id == change.id }) else { return }
            insert(change)
            totalCount += 1
            hasMore = changes.count < totalCount
            // 新变更命中当前选中项时刷新其 diff。
            if selected?.id == change.id {
                Task { await self.select(change) }
            }

        case .risk(let risk):
            raiseRisk(of: risk)

        case .engineState(let state):
            engineState = state

        case .timelineEvent, .command, .agents, .sessions, .performance, .dashboard:
            return
        }
    }

    // MARK: - Private

    /// 列表为空或选中项已不在结果里时，默认选中第一条（Preview 也依赖这个行为）。
    private func ensureSelection() async {
        let list = visibleChanges
        if let selected, list.contains(where: { $0.id == selected.id }) {
            return
        }
        if let first = list.first {
            await select(first)
        } else {
            selected = nil
            diff = nil
            diffState = .idle
        }
    }

    private func insert(_ change: FileChange) {
        let descending = query.sort.descending
        let position = changes.firstIndex { existing in
            descending ? existing.timestamp < change.timestamp : existing.timestamp > change.timestamp
        } ?? changes.endIndex
        changes.insert(change, at: position)
        trim(&changes)
    }

    private func merge(_ incoming: [FileChange]) {
        var seen: Set<UUID> = []
        var combined: [FileChange] = []
        combined.reserveCapacity(changes.count + incoming.count)
        for candidate in changes + incoming where !seen.contains(candidate.id) {
            seen.insert(candidate.id)
            combined.append(candidate)
        }
        let descending = query.sort.descending
        combined.sort { descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
        trim(&combined)
        changes = combined
    }

    private func trim(_ list: inout [FileChange]) {
        guard list.count > Self.maxRetainedChanges else { return }
        let excess = list.count - Self.maxRetainedChanges
        if query.sort.descending {
            list.removeLast(excess)
        } else {
            list.removeFirst(excess)
        }
    }

    /// 风险事件抬升同会话 / 同路径变更的风险标记。
    private func raiseRisk(of risk: RiskEvent) {
        for index in changes.indices {
            let change = changes[index]
            let sameSession = change.sessionID != nil && change.sessionID == risk.sessionID
            let samePath = risk.filePaths.contains(change.path)
                || risk.filePaths.contains { candidate in
                    !candidate.isEmpty && change.path.hasPrefix(candidate + "/")
                }
            guard sameSession || samePath else { continue }
            guard risk.level > change.riskLevel else { continue }
            var updated = change
            updated.riskLevel = risk.level
            changes[index] = updated
            if selected?.id == change.id { selected = updated }
        }
    }

    /// 与 `ObservatoryService.fileChanges(matching:)` 一致的过滤语义。
    private func matchesCurrentQuery(_ change: FileChange) -> Bool {
        guard query.dateRange.contains(change.timestamp) else { return false }
        if let sessionID = query.sessionID, change.sessionID != sessionID { return false }
        if let project = query.projectPath, change.projectPath != project { return false }
        if let prefix = query.pathPrefix, !change.path.hasPrefix(prefix) { return false }
        if !query.kinds.isEmpty, !query.kinds.contains(change.kind) { return false }
        if !query.agentKinds.isEmpty, !query.agentKinds.contains(change.agentKind) { return false }
        if !query.searchText.isEmpty, !change.path.lowercased().contains(query.searchText.lowercased()) { return false }
        return true
    }
}
