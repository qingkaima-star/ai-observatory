//
//  SessionsModel.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent I)
//  Sessions 板块数据流：SessionQuery 构造与分页、选中会话的命令/事件详情懒加载、实时增量合并。
//
//  铁律：
//    · `.sessions` 按 id 合并去重、上限 500 截断；权威快照到达即清零该会话的增量计数
//      （增量计数只负责补齐「快照之后」的窗口，绝不双计）。
//    · `.timelineEvent` / `.fileChange` / `.command` / `.risk` 命中列表内会话时 **只累加计数**，
//      绝不重查全库；命中当前详情所属会话时向已加载的详情列表做头部插入。
//    · 所有 throws 走 do/catch 存 `errorMessage`，禁止 `try!` 与强制解包。
//

import Foundation
import Observation
import AIObservatoryCore

// MARK: - Counters

/// 会话计数快照：列表行与详情瓷贴都读这个，保证「服务端计数 + 实时增量」口径一致。
struct SessionCounters: Hashable {
    var created: Int = 0
    var modified: Int = 0
    var deleted: Int = 0
    var commands: Int = 0
    var failedCommands: Int = 0
    var riskEvents: Int = 0
    var events: Int = 0

    /// 文件改动总数（created + modified + deleted）。
    var touchedFiles: Int { created + modified + deleted }

    static func + (lhs: SessionCounters, rhs: SessionCounters) -> SessionCounters {
        SessionCounters(
            created: lhs.created + rhs.created,
            modified: lhs.modified + rhs.modified,
            deleted: lhs.deleted + rhs.deleted,
            commands: lhs.commands + rhs.commands,
            failedCommands: lhs.failedCommands + rhs.failedCommands,
            riskEvents: lhs.riskEvents + rhs.riskEvents,
            events: lhs.events + rhs.events
        )
    }

    /// 由权威会话记录出发，叠加实时增量。
    static func merged(session: AgentSession, delta: SessionCounters) -> SessionCounters {
        SessionCounters(
            created: session.createdFileCount + delta.created,
            modified: session.modifiedFileCount + delta.modified,
            deleted: session.deletedFileCount + delta.deleted,
            commands: session.commandCount + delta.commands,
            failedCommands: session.failedCommandCount + delta.failedCommands,
            riskEvents: session.riskEventCount + delta.riskEvents,
            events: delta.events
        )
    }
}

// MARK: - Detail tab

/// 详情面板的分段页签。
enum SessionsDetailTab: String, CaseIterable, Identifiable {
    case commands
    case events
    case changes

    var id: String { rawValue }

    var displayName: String { displayName(UILanguage.current) }

    /// 显式语言那一版给用例：测试进程的语言 = 宿主系统语言，逐字断言不能建在它上面。
    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .commands: return SessionsCopy.tabCommands.text(language)
        case .changes: return SessionsCopy.tabChanges.text(language)
        case .events:   return SessionsCopy.tabEvents.text(language)
        }
    }

    var symbol: String {
        switch self {
        case .commands: return "terminal"
        case .events:   return "list.bullet.rectangle"
        case .changes:  return "doc.text.magnifyingglass"
        }
    }
}

// MARK: - Model

@Observable @MainActor final class SessionsModel {

    // MARK: Tunables

    /// 列表单页大小。
    static let pageSize = 100
    /// 内存中保留的会话上限，超出丢最旧的。
    static let maxRetainedSessions = 500
    /// 详情命令一次性拉取条数。
    static let commandPageSize = 200
    /// 详情事件摘要预览条数（契约要求 ~50）。
    static let eventPreviewCount = 50

    // MARK: Dependencies

    private let runtime: ObservatoryRuntime

    // MARK: Load state

    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var errorMessage: String?

    /// 与 `query.sort` 方向一致的会话列表（默认新→旧）。
    private(set) var sessions: [AgentSession] = []
    /// 服务端匹配总数（≠ sessions.count）。
    private(set) var totalCount: Int = 0
    private(set) var hasMore: Bool = false

    // MARK: Filter state（每一项都真实下推到 SessionQuery）

    var query: SessionQuery

    /// 板块内时间范围（默认跟随 `ShellModel.timeRange`）→ `query.dateRange`。
    var timeRange: ObservatoryTimeRange = .all {
        didSet {
            guard oldValue != timeRange else { return }
            query.dateRange = timeRange.dateRange(now: Date())
        }
    }

    /// 只看存在风险事件的会话（本地过滤，不改服务端查询）。
    var riskyOnly: Bool = false

    // MARK: Selection & detail

    private(set) var selectedID: UUID?

    // MARK: 本次改动清单（#60）

    /// 会话详情的「改动清单」页签读数：行 = 该会话 `file_changes` 的行（**不去重**），
    /// 外加每个项目的版本控制判定。首次切到该页签时才取数（懒加载，与命令/事件明细同一形状）。
    private(set) var changeInventory: SessionChangeInventory = .init()
    private(set) var isLoadingChanges: Bool = false
    private(set) var changeErrorMessage: String?
    /// 改动清单的取数代号：切会话/重取时递增，用来丢掉过期回来的结果。
    private var changeToken: Int = 0

    /// 只读 git 探针。**类型上就只有三种读调用可构造**，写子命令在执行器里还会被再拦一次
    /// （#60 第 3 条红线，用例 `GitProbeReadOnlyTests` 拿真 git 夹具对整棵树取 sha256 判前后一致）。
    private let gitReader: any GitReadOnlyReading = SystemGitReader()
    private(set) var detailID: UUID?
    private(set) var isLoadingDetail: Bool = false
    private(set) var detailErrorMessage: String?
    private(set) var commands: [CommandRecord] = []
    private(set) var events: [TimelineEvent] = []

    var detailTab: SessionsDetailTab = .commands

    // MARK: Incremental deltas

    /// 权威快照之后累计到的增量计数，key = sessionID。
    private var liveDelta: [UUID: SessionCounters] = [:]

    /// 单调递加载令牌：丢弃被更晚查询覆盖的异步结果。
    private var loadToken: Int = 0
    private var detailToken: Int = 0

    // MARK: Init

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        // 默认「今天」：init 内赋值不触发 didSet，因此把 dateRange 一并显式落到 query 上。
        let initialRange: ObservatoryTimeRange = .today
        var initialQuery = SessionQuery(limit: Self.pageSize, offset: 0, sort: .newestFirst)
        initialQuery.dateRange = initialRange.dateRange(now: Date())
        self.query = initialQuery
        self.timeRange = initialRange
    }

    // MARK: Derived

    var selected: AgentSession? {
        guard let selectedID else { return nil }
        return sessions.first { $0.id == selectedID }
    }

    var visibleSessions: [AgentSession] {
        guard riskyOnly else { return sessions }
        return sessions.filter { counters(for: $0).riskEvents > 0 }
    }

    /// 用户主动收紧的条件类过滤项数量（不含时间范围）。
    var activeFilterCount: Int {
        var count = 0
        if !query.agentKinds.isEmpty { count += 1 }
        if !query.outcomes.isEmpty { count += 1 }
        if !query.searchText.isEmpty { count += 1 }
        if query.projectPath != nil { count += 1 }
        if riskyOnly { count += 1 }
        return count
    }

    /// 「有数据但被过滤光」的语义判定，决定空态文案与重置按钮。
    var hasNarrowedFilters: Bool { activeFilterCount > 0 || timeRange != .all }

    /// 当前已加载会话中仍在进行的数量。
    var runningCount: Int { sessions.lazy.filter { $0.outcome == .running }.count }

    // MARK: hero 下面那排「凑不进网格的落单读数」

    /// 一行落单读数（标签 + 值）。
    struct SupplementaryStat: Hashable {
        let label: String
        let value: String
    }

    /// hero 与四格之间那一排的**唯一出处**。
    ///
    /// 两条刻意规则，都是真机截图逼出来的（空态下这一页一度有 13 个 0）：
    /// · **零信息不排格**——`未加载 0 个` 与 `过滤条件 未启用` 都不构成结论，
    ///   「0」和「未启用」恰恰是最容易被当成结论的那两个值（宁缺不造）；
    ///   「已全部加载」这件事由列表标题行的「共 N · 已加载 M」说，不在这里再排一格。
    /// · **不重复**——`进行中` 在下面的四格里已经有同口径的一格，这里不排第二遍。
    ///
    /// 排序方向**留着**：它是读整张列表的口径（最新在前 vs 最早在前决定第一行是谁），
    /// 别处没有说过这件事。
    var heroSupplementaryStats: [SupplementaryStat] { heroSupplementaryStats(UILanguage.current) }

    func heroSupplementaryStats(_ language: AppLanguage) -> [SupplementaryStat] {
        var stats: [SupplementaryStat] = []
        if unloadedCount > 0 {
            stats.append(SupplementaryStat(label: SessionsCopy.statUnloadedLabel.text(language),
                                             value: SessionsCopy.statUnloadedValue.copy.format(language, unloadedCount)))
        }
        if activeFilterCount > 0 {
            stats.append(SupplementaryStat(label: SessionsCopy.statFilterLabel.text(language),
                                             value: filterSummaryText))
        }
        stats.append(SupplementaryStat(
            label: SessionsCopy.statSortLabel.text(language),
            value: query.sort.descending ? SessionsCopy.filterNewestFirst.text(language)
                                         : SessionsCopy.filterOldestFirst.text(language)
        ))
        return stats
    }

    /// 「过滤条件」那一格的内容：只在真的有条件时才有意义（调用方已保证）。
    var filterSummaryText: String { filterSummaryText(UILanguage.current) }

    func filterSummaryText(_ language: AppLanguage) -> String {
        var parts: [String] = []
        if activeFilterCount > 0 { parts.append(SessionsCopy.statFiltersActive.copy.format(language, activeFilterCount)) }
        if let project = query.projectPath, !project.isEmpty {
            parts.append(SessionsCopy.statProject.copy.format(language, (project as NSString).lastPathComponent))
        }
        return parts.isEmpty ? SessionsCopy.statFilterOff.text(language) : parts.joined(separator: " · ")
    }

    // MARK: 聚合读数（口径一律是「本页已加载」，不是服务端总数）
    //
    // 下面这些数字全部由 `sessions`（单页 `Self.pageSize` 条，另加实时增量补进来的行）算出，
    // 和权威的服务端匹配数 `totalCount` 是两个口径。
    //
    // ⚠️ 这条口径**只在「已加载会话的合计」那张卡的标题行说一次**（见
    // `SessionsView.metricsPanel` 的 `SectionHeader`）。这里曾写着「用到它们的读数都必须在
    // caption 里写『已加载 N 个中』」——那正是被真机截图否掉的做法：四格挂同一句前缀
    // 就是「拥挤」，而且信息量并不比标题行多。改回去之前先看那张图。

    /// 尚未拉到本地的会话条数（服务端匹配总数 − 已加载）。
    var unloadedCount: Int { max(0, totalCount - sessions.count) }

    /// 已加载会话的墙钟时长合计（进行中会话算到当前时刻）。
    var loadedDurationSeconds: TimeInterval {
        sessions.reduce(0) { $0 + duration(for: $1) }
    }

    /// 已加载会话的命令数合计（服务端计数 + 实时增量）。
    var loadedCommandTotal: Int {
        sessions.reduce(0) { $0 + counters(for: $1).commands }
    }

    /// 已加载会话的失败命令合计。
    var loadedFailedCommandTotal: Int {
        sessions.reduce(0) { $0 + counters(for: $1).failedCommands }
    }

    /// 已加载会话的文件改动合计（处：created + modified + deleted）。
    var loadedTouchedFileTotal: Int {
        sessions.reduce(0) { $0 + counters(for: $1).touchedFiles }
    }

    /// 已加载会话里命中过风险事件的**会话数**（不是事件数，两者不许混着说）。
    var riskySessionCount: Int {
        sessions.lazy.filter { [self] in counters(for: $0).riskEvents > 0 }.count
    }

    /// 「文件改动」那一格的自身口径：新建 / 修改 / 删除 的拆分。
    ///
    /// 为什么要有它：这一格的 caption 原本挂的是「有风险事件的会话 N 个」——
    /// 风险事件数与文件改动**没有归属关系**，那是四格里唯一一句凑数的话，
    /// 读者只会以为风险是文件改动引来的。风险那句挪到这张卡的标题行（同口径、不同对象）。
    var loadedFileBreakdown: String { loadedFileBreakdown(UILanguage.current) }

    func loadedFileBreakdown(_ language: AppLanguage) -> String {
        var created = 0
        var modified = 0
        var deleted = 0
        for session in sessions {
            let counters = counters(for: session)
            created += counters.created
            modified += counters.modified
            deleted += counters.deleted
        }
        return SessionsCopy.detailFileBreakdown.copy.format(language, created, modified, deleted)
    }

    /// 已加载会话的风险**事件**总数。
    var loadedRiskEventTotal: Int {
        sessions.reduce(0) { $0 + counters(for: $1).riskEvents }
    }

    /// 会话列表面板副标题的计数口径：服务端匹配总数 / 本页已加载 / 本地「只看有风险」筛过的可见数。
    ///
    /// 它替代旧底部状态条的 `progressText`：那句把「已加载」写成**筛过的**可见数，
    /// 与本页所有 caption 里的「已加载 = sessions.count」直接冲突——同一个词两个口径就是说谎。
    var listCountSummary: String { listCountSummary(UILanguage.current) }

    func listCountSummary(_ language: AppLanguage) -> String {
        let loaded = sessions.count
        let visible = visibleSessions.count
        guard visible != loaded else {
            return SessionsCopy.progressTotalLoaded.copy.format(language, totalCount, loaded)
        }
        return SessionsCopy.progressRiskyShown.copy.format(language, totalCount, loaded, visible)
    }

    func sessionCount(for outcome: SessionOutcome) -> Int {
        sessions.lazy.filter { $0.outcome == outcome }.count
    }

    func counters(for session: AgentSession) -> SessionCounters {
        SessionCounters.merged(session: session, delta: liveDelta[session.id] ?? SessionCounters())
    }

    /// 进行中会话的时长随墙钟推进；已结束会话用固定区间。
    func duration(for session: AgentSession) -> TimeInterval {
        max(0, session.duration)
    }

    /// 列表行/详情头部的时间区间文案。
    func timeRangeText(for session: AgentSession) -> String {
        timeRangeText(for: session, UILanguage.current)
    }

    func timeRangeText(for session: AgentSession, _ language: AppLanguage) -> String {
        let start = DateFormat.timestamp(session.startedAt)
        guard let end = session.endedAt else {
            return SessionsCopy.timeRangeRunning.copy.format(language, start)
        }
        return "\(start) → \(DateFormat.timestamp(end))"
    }

    // MARK: Loading

    func load() async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        errorMessage = nil
        do {
            let page = try await runtime.service.sessions(matching: query)
            guard token == loadToken else { return }
            sessions = page.items
            totalCount = page.totalCount
            hasMore = page.hasMore
            isLoading = false
            await ensureSelection()
        } catch {
            guard token == loadToken else { return }
            sessions = []
            totalCount = 0
            hasMore = false
            clearDetail()
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let token = loadToken
        let previousOffset = query.offset
        query.offset = previousOffset + query.limit
        do {
            let page = try await runtime.service.sessions(matching: query)
            guard token == loadToken else {
                // 期间发生了新的整体加载 → 丢弃这一页并回滚 offset。
                query.offset = previousOffset
                isLoadingMore = false
                return
            }
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

    func setTimeRange(_ range: ObservatoryTimeRange) async {
        timeRange = range
        await applyFilters()
    }

    // MARK: Filter mutation

    func toggleAgentKind(_ kind: AgentKind) async {
        if query.agentKinds.contains(kind) {
            query.agentKinds.remove(kind)
        } else {
            query.agentKinds.insert(kind)
        }
        if query.agentKinds.count >= AgentKind.allCases.count { query.agentKinds = [] }
        await applyFilters()
    }

    func toggleOutcome(_ outcome: SessionOutcome) async {
        if query.outcomes.contains(outcome) {
            query.outcomes.remove(outcome)
        } else {
            query.outcomes.insert(outcome)
        }
        if query.outcomes.count >= SessionOutcome.allCases.count { query.outcomes = [] }
        await applyFilters()
    }

    func setSearchText(_ text: String) async {
        guard text != query.searchText else { return }
        query.searchText = text
        await applyFilters()
    }

    func setProjectPath(_ path: String?) async {
        guard path != query.projectPath else { return }
        query.projectPath = path
        await applyFilters()
    }

    func setSortDescending(_ descending: Bool) async {
        guard query.sort.descending != descending else { return }
        query.sort = SortOrder(descending: descending)
        await applyFilters()
    }

    func setRiskyOnly(_ enabled: Bool) {
        riskyOnly = enabled
    }

    func resetFilters() async {
        query.agentKinds = []
        query.outcomes = []
        query.searchText = ""
        query.projectPath = nil
        riskyOnly = false
        await applyFilters()
    }

    /// 把当前过滤条件聚焦到某个会话所属项目（详情卡片按钮使用）。
    func focusProject(_ session: AgentSession) async {
        await setProjectPath(session.projectPath)
    }

    // MARK: Selection & detail

    func select(_ id: UUID?) async {
        guard id != selectedID || detailID != id else { return }
        selectedID = id
        await loadDetail(for: id)
    }

    /// 详情栏（`.inspector`）是否展示。**计算属性**，不新增存储字段：
    /// 以「当前选中的那条会话还在列表里」为准，所以关掉详情 = 取消选中，
    /// 不会出现「详情栏关着但模型还以为开着」的两处真相。
    var showsDetailPanel: Bool { selected != nil }

    /// 键盘 ↑/↓ 换选中：在**当前可见列表**里移动一格，两端停住、不环绕。
    ///
    /// 为什么在模型里而不是视图里：这条原本是 `List(selection:)` 白送的，
    /// 为了修「高亮有两处真相」把列表换成 `LazyVStack` 之后就没了
    /// （`SessionsView` 里那条自陈「已知功能回归、本车道不许跑编译所以没写」的注释）。
    /// 视图只负责按键接线，**移动语义**要能被手推字面量断言住，所以抽在这里。
    ///
    /// 不环绕是刻意的：列表按时间排序，往下走到底突然跳回最新一条，
    /// 在审计场景里是丢上下文而不是省事。
    /// - Parameter delta: `-1` 上移、`+1` 下移；当前没有选中时，上移落到末条、下移落到首条。
    func moveSelection(by delta: Int) async {
        let list = visibleSessions
        guard !list.isEmpty, delta != 0 else { return }
        let target: Int
        if let selectedID, let current = list.firstIndex(where: { $0.id == selectedID }) {
            target = min(max(current + delta, 0), list.count - 1)
        } else {
            target = delta < 0 ? list.count - 1 : 0
        }
        await select(list[target].id)
    }

    /// 收起详情栏（inspector 的关闭按钮走这里）：取消选中并卸载详情。
    func clearSelection() async {
        await select(nil)
    }

    // MARK: - 本次改动清单（#60）

    /// 取当前选中会话的改动清单 + 版本控制判定。
    ///
    /// 三条口径写在这里，都有用例对着：
    ///   · 取数翻到**取完**为止 ⇒ 等价式「清单条数 == 该会话 `file_changes` 行数」不是只在头 100 行成立；
    ///   · 只读：这一路只发 `rev-parse` / `status` 两种 git 调用，绝不 `checkout` / `stash` / `reset`；
    ///   · 探针问不到 ⇒ `unknown`，界面写「未能确认版本状态」，不写"干净"。
    func loadChanges() async {
        guard let session = selectedID else {
            changeInventory = .init()
            changeErrorMessage = nil
            return
        }
        changeToken += 1
        let token = changeToken
        isLoadingChanges = true
        changeErrorMessage = nil
        do {
            let fresh = try await SessionChangeInventoryBuilder(reader: gitReader).inventory(
                sessionID: session, from: runtime.service
            )
            guard token == changeToken else { return }
            changeInventory = fresh
        } catch {
            guard token == changeToken else { return }
            changeErrorMessage = error.localizedDescription
        }
        if token == changeToken { isLoadingChanges = false }
    }

    /// 「改前 / 改后」入口：点开才取那一条的 diff（不为一整页清单先发 N 次查询）。
    func diff(for changeID: UUID) async -> FileDiff? {
        try? await runtime.service.fileDiff(for: changeID)
    }

    func setDetailTab(_ tab: SessionsDetailTab) {
        detailTab = tab
    }

    private func loadDetail(for id: UUID?) async {
        detailToken += 1
        let token = detailToken
        commands = []
        events = []
        detailErrorMessage = nil
        detailID = nil
        guard let id else {
            isLoadingDetail = false
            return
        }
        isLoadingDetail = true

        // 命令记录
        do {
            let page = try await runtime.service.commands(matching: CommandQuery(
                sessionID: id,
                limit: Self.commandPageSize,
                sort: .newestFirst
            ))
            guard token == detailToken, selectedID == id else { return }
            commands = page.items
        } catch {
            guard token == detailToken, selectedID == id else { return }
            detailErrorMessage = error.localizedDescription
        }

        // 事件摘要（前 eventPreviewCount 条）
        do {
            let page = try await runtime.service.events(matching: EventQuery(
                sessionID: id,
                limit: Self.eventPreviewCount,
                sort: .newestFirst
            ))
            guard token == detailToken, selectedID == id else { return }
            events = page.items
        } catch {
            guard token == detailToken, selectedID == id else { return }
            detailErrorMessage = error.localizedDescription
        }

        guard token == detailToken else { return }
        detailID = id
        isLoadingDetail = false
    }

    private func clearDetail() {
        detailToken += 1
        selectedID = nil
        detailID = nil
        commands = []
        events = []
        detailErrorMessage = nil
        isLoadingDetail = false
    }

    /// 列表为空或选中项已不在结果里时，默认选中第一条（Preview 也依赖这个行为）。
    private func ensureSelection() async {
        let list = visibleSessions
        if let selectedID, list.contains(where: { $0.id == selectedID }) { return }
        if let first = list.first {
            await select(first.id)
        } else {
            clearDetail()
        }
    }

    // MARK: Live updates

    func observeUpdates() async {
        for await update in runtime.updates.makeUpdateStream() {
            if Task.isCancelled { break }
            ingest(update)
        }
    }

    private func ingest(_ update: ObservatoryUpdate) {
        switch update {
        case .sessions(let incoming):
            var didInsert = false
            for session in incoming where mergeSession(session) { didInsert = true }
            if didInsert { Task { await self.ensureSelection() } }

        case .fileChange(let change):
            bump(for: change.sessionID) { delta in
                switch change.kind {
                case .created:  delta.created += 1
                case .modified: delta.modified += 1
                case .deleted:  delta.deleted += 1
                case .renamed:  delta.modified += 1
                case .unknown:  delta.modified += 1
                }
            }

        case .command(let record):
            bump(for: record.sessionID) { delta in
                delta.commands += 1
                if record.outcome == .failure { delta.failedCommands += 1 }
            }
            if detailID != nil, detailID == record.sessionID { insertCommand(record) }

        case .risk(let risk):
            bump(for: risk.sessionID) { delta in delta.riskEvents += 1 }

        case .timelineEvent(let event):
            bump(for: event.sessionID) { delta in delta.events += 1 }
            if detailID == event.sessionID {
                insertEvent(event)
            }

        case .agents, .performance, .dashboard, .engineState:
            return
        }
    }

    // MARK: - Private: 增量合并

    /// 合并一条权威会话快照。返回 true 表示新插入了一条。
    @discardableResult
    private func mergeSession(_ session: AgentSession) -> Bool {
        if let index = sessions.firstIndex(where: { $0.id == session.id }) {
            let merged = mergedSession(existing: sessions[index], incoming: session)
            if merged != sessions[index] { sessions[index] = merged }
            // 权威快照已包含这些计数 → 清零增量，避免双计。
            liveDelta[session.id] = nil
            return false
        }
        guard matchesCurrentQuery(session) else { return false }
        insertSession(session)
        totalCount += 1
        hasMore = sessions.count < totalCount
        return true
    }

    /// 字段级合并：标量以「不小于已见值」为准，避免计数倒退；状态只前进不倒退。
    private func mergedSession(existing: AgentSession, incoming: AgentSession) -> AgentSession {
        var result = incoming
        result.displayIndex = incoming.displayIndex > 0 ? incoming.displayIndex : existing.displayIndex
        if result.title.isEmpty { result.title = existing.title }
        result.projectPath = incoming.projectPath ?? existing.projectPath
        result.agentID = incoming.agentID ?? existing.agentID
        result.startedAt = min(existing.startedAt, incoming.startedAt)
        result.endedAt = incoming.endedAt ?? existing.endedAt
        result.modifiedFileCount = max(existing.modifiedFileCount, incoming.modifiedFileCount)
        result.createdFileCount = max(existing.createdFileCount, incoming.createdFileCount)
        result.deletedFileCount = max(existing.deletedFileCount, incoming.deletedFileCount)
        result.commandCount = max(existing.commandCount, incoming.commandCount)
        result.failedCommandCount = max(existing.failedCommandCount, incoming.failedCommandCount)
        result.cpuSeconds = max(existing.cpuSeconds, incoming.cpuSeconds)
        result.peakCPUPercent = max(existing.peakCPUPercent, incoming.peakCPUPercent)
        result.peakMemoryBytes = max(existing.peakMemoryBytes, incoming.peakMemoryBytes)
        result.estimatedTokens = max(existing.estimatedTokens, incoming.estimatedTokens)
        result.riskEventCount = max(existing.riskEventCount, incoming.riskEventCount)
        if incoming.outcome == .unknown || incoming.outcome == .running,
           existing.outcome != .unknown, existing.outcome != .running {
            result.outcome = existing.outcome
        }
        return result
    }

    private func insertSession(_ session: AgentSession) {
        let descending = query.sort.descending
        let position = sessions.firstIndex { existing in
            descending ? existing.startedAt < session.startedAt : existing.startedAt > session.startedAt
        } ?? sessions.endIndex
        sessions.insert(session, at: position)
        trimSessions()
    }

    private func merge(_ incoming: [AgentSession]) {
        var seen: Set<UUID> = []
        var combined: [AgentSession] = []
        combined.reserveCapacity(sessions.count + incoming.count)
        for candidate in sessions + incoming where !seen.contains(candidate.id) {
            seen.insert(candidate.id)
            combined.append(candidate)
        }
        let descending = query.sort.descending
        combined.sort { descending ? $0.startedAt > $1.startedAt : $0.startedAt < $1.startedAt }
        sessions = combined
        trimSessions()
    }

    private func trimSessions() {
        guard sessions.count > Self.maxRetainedSessions else { return }
        let excess = sessions.count - Self.maxRetainedSessions
        if query.sort.descending {
            sessions.removeLast(excess)
        } else {
            sessions.removeFirst(excess)
        }
    }

    /// 命中列表内会话才累加计数（会话不在观测范围内 → 直接忽略）。
    private func bump(for sessionID: UUID?, _ mutate: (inout SessionCounters) -> Void) {
        guard let sessionID, sessions.contains(where: { $0.id == sessionID }) else { return }
        var delta = liveDelta[sessionID] ?? SessionCounters()
        mutate(&delta)
        liveDelta[sessionID] = delta
    }

    private func insertCommand(_ record: CommandRecord) {
        guard !commands.contains(where: { $0.id == record.id }) else { return }
        commands.insert(record, at: 0)
        if commands.count > Self.commandPageSize { commands.removeLast() }
    }

    private func insertEvent(_ event: TimelineEvent) {
        guard !events.contains(where: { $0.id == event.id }) else { return }
        events.insert(event, at: 0)
        if events.count > Self.eventPreviewCount { events.removeLast() }
    }

    /// 与 `ObservatoryService.sessions(matching:)` 一致的过滤语义。
    private func matchesCurrentQuery(_ session: AgentSession) -> Bool {
        guard query.dateRange.contains(session.startedAt) else { return false }
        if let project = query.projectPath, session.projectPath != project { return false }
        if !query.agentKinds.isEmpty, !query.agentKinds.contains(session.kind) { return false }
        if !query.outcomes.isEmpty, !query.outcomes.contains(session.outcome) { return false }
        if !query.searchText.isEmpty {
            let needle = query.searchText.lowercased()
            let haystack = "\(session.title) \(session.projectPath ?? "") \(session.kind.displayName)".lowercased()
            guard haystack.contains(needle) else { return false }
        }
        return true
    }
}

// MARK: - 会话结果 → 标签色调

extension TagTone {
    /// `SessionOutcome` 的色调映射，语义与 `ObservatoryTheme.color(for: SessionOutcome)` 一致。
    ///
    /// 为什么在本页补这一份：`ObservatoryTheme` 只对风险等级暴露 `tone(for:)`，
    /// 而 `Tag` 收的参数是 `TagTone`（色点 + 文字，不画胶囊）。若在每个调用点各写一遍
    /// if 分支，两处映射迟早漂移成两种颜色说法。
    /// CONTRACT-CHANGE 候选：应上收为 `ObservatoryTheme.tone(for: SessionOutcome)`。
    static func sessionOutcome(_ outcome: SessionOutcome) -> Self {
        switch outcome {
        case .running:     return .accent
        case .success:     return .positive
        case .failed:      return .critical
        case .interrupted: return .caution
        case .unknown:     return .neutral
        }
    }

    /// `CommandOutcome` 的色调映射，语义与 `ObservatoryTheme.color(for: CommandOutcome)` 一致。
    /// 同上：补齐 `Tag` 需要的色调档，CONTRACT-CHANGE 候选一并上收。
    static func commandOutcome(_ outcome: CommandOutcome) -> Self {
        switch outcome {
        case .running:    return .accent
        case .success:    return .positive
        case .failure:    return .critical
        case .terminated: return .caution
        case .unknown:    return .neutral
        }
    }
}

private extension SessionsDetailTab {
    var language: AppLanguage { UILanguage.current }
}

private extension SessionsModel {
    var language: AppLanguage { UILanguage.current }
}
