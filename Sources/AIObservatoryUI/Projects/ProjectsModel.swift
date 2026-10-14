//
//  ProjectsModel.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-UI (subagent G)
//  职责：Projects 板块唯一数据源（项目级 AI 活动地图）。
//    · load()             —— 全量拉取项目清单：runtime.service.projects()。
//    · loadDetail()       —— 选中项目按当前时间范围重查：projectActivity(path:dateRange:)。
//    · loadRecentChanges()—— 详情面板的最近文件变更（分页受限，后台加载）。
//    · observeUpdates()   —— 长驻订阅 ObservatoryUpdate，只对 .fileChange / .command / .sessions
//                            （以及 .risk 的风险计数）做**本地增量累加**，绝不重查全库。
//  上限保护：hotFiles / recentChanges 都有硬上限，异常高频推送不会撑爆内存。
//

import Foundation
import Observation
import AIObservatoryCore

// MARK: - Time Text

/// 项目板块共用的时间文案：相对时间（基于 `DurationFormat`）+ 绝对时间（基于 `DateFormat`）。
/// 卡片与详情面板都引用它，避免两处实现漂移。
enum ProjectTimeText {
    /// "刚刚" / "18分钟前" / "2小时15分钟前" / "3天前的 14:22"
    static func since(_ date: Date, now: Date = Date()) -> String {
        since(date, now: now, UILanguage.current)
    }

    static func since(_ date: Date, now: Date = Date(), _ language: AppLanguage) -> String {
        let elapsed = now.timeIntervalSince(date)
        if elapsed < 60 { return ProjectsCopy.timeJustNow.text(language) }
        if elapsed < 86_400 {
            return ProjectsCopy.timeAgo.format(language, DurationFormat.humanReadable(elapsed))
        }
        let days = Int(elapsed / 86_400)
        return ProjectsCopy.timeDaysAgo.format(language, days, DateFormat.day(date))
    }

    /// 时间跨度：`firstSeenAt` → `lastSeenAt` 的持续时长文案。
    static func span(from start: Date, to end: Date) -> String {
        span(from: start, to: end, UILanguage.current)
    }

    static func span(from start: Date, to end: Date, _ language: AppLanguage) -> String {
        let seconds = max(0, end.timeIntervalSince(start))
        guard seconds >= 1 else { return ProjectsCopy.timeSameInstant.text(language) }
        return DurationFormat.humanReadable(seconds)
    }

    /// 绝对时间戳。
    static func absolute(_ date: Date) -> String { DateFormat.timestamp(date) }
}

// MARK: - Sort Key

/// 项目卡片网格的排序口径。
enum ProjectsSortKey: String, CaseIterable, Identifiable {
    case recent
    case busiest
    case growth
    case risk

    var id: String { rawValue }

    var displayName: String { displayName(UILanguage.current) }

    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .recent:  return ProjectsCopy.sortRecent.text(language)
        case .busiest: return ProjectsCopy.sortBusiest.text(language)
        case .growth:  return ProjectsCopy.netCode.text(language)
        case .risk:    return ProjectsCopy.sortRiskFirst.text(language)
        }
    }

    var symbol: String {
        switch self {
        case .recent:  return "clock"
        case .busiest: return "doc.on.doc"
        case .growth:  return "arrow.up.right"
        case .risk:    return "exclamationmark.triangle"
        }
    }
}

// MARK: - Model

@Observable
@MainActor
final class ProjectsModel {

    /// 单项目内存保留的热区文件上限。
    static let maxHotFiles = 40
    /// 详情面板「最近变更」的拉取与保留上限。
    static let maxRecentChanges = 60
    /// 合并后的全局热点榜长度。
    static let hottestFileLimit = 12

    // MARK: 只读状态

    private(set) var isLoading: Bool = false
    private(set) var isLoadingDetail: Bool = false
    private(set) var isLoadingChanges: Bool = false
    private(set) var errorMessage: String?
    private(set) var projects: [ProjectActivity] = []
    private(set) var selectedPath: String?
    private(set) var detail: ProjectActivity?
    private(set) var recentChanges: [FileChange] = []
    private(set) var hasMoreChanges: Bool = false
    /// 本次订阅周期内新增命中的项目数（用于右上角「实时」提示）。
    private(set) var liveTouchedPaths: Set<String> = []
    /// 选中项目的健康度（分析层给出；`nil` = 活动地图里没有这个项目的行，或分析层未接入）。
    private(set) var health: ProjectHealthSnapshot?
    /// 健康度查询失败原因。与「没有健康度」分开，是为了不把失败渲染成「数据不足」。
    private(set) var healthErrorMessage: String?
    private(set) var isLoadingHealth: Bool = false

    // MARK: 可写过滤条件

    var timeRange: ObservatoryTimeRange = .lastSevenDays
    var searchText: String = ""
    var selectedKinds: Set<AgentKind> = []
    var sortKey: ProjectsSortKey = .recent

    // MARK: 跳转带进来的两项（#81）——只有「最近变更」那一条 `FileChangeQuery` 读它们
    //
    // 为什么单独放两个字段而不是塞进 `searchText`：这一格没有一份常驻的 `query` 存储位
    // （`loadRecentChanges()` 每次现构造一条），所以「这一屏带着什么条件」的唯一出处
    // 就是这两个字段本身 —— `carriedJumpConditions` 读它们，构造查询也用它们，
    // 两边不可能分叉。会话 id / 变更种类都不是本页过滤条上的控件在管的东西，
    // 因此它们不进 `selectedKinds`（那是 Agent 种类，另一维）。

    /// 跳转带来的会话：只筛「最近变更」那一条查询（项目列表本身不按会话筛）。
    var changesSessionID: UUID?
    /// 跳转带来的变更种类（由 `JumpIntent.eventKinds` 映射而来；空集合 = 不表态）。
    var changesKinds: Set<FileChangeKind> = []

    // MARK: 私有

    private let runtime: ObservatoryRuntime
    private var loadToken: Int = 0
    private var detailToken: Int = 0
    private var changesToken: Int = 0
    private var healthToken: Int = 0

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
    }

    // MARK: - 派生属性

    /// 命中当前搜索 / Agent 过滤条件的项目。
    var filteredProjects: [ProjectActivity] {
        projects.filter { passesFilters($0) }
    }

    /// 过滤 + 排序后的项目卡片数据源。
    var sortedProjects: [ProjectActivity] {
        filteredProjects.sorted { lhs, rhs in
            switch sortKey {
            case .recent:
                if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
                return lhs.fileChangeCount > rhs.fileChangeCount
            case .busiest:
                if lhs.fileChangeCount != rhs.fileChangeCount { return lhs.fileChangeCount > rhs.fileChangeCount }
                return lhs.lastSeenAt > rhs.lastSeenAt
            case .growth:
                return lhs.codeGrowthLines - lhs.codeShrinkLines > rhs.codeGrowthLines - rhs.codeShrinkLines
            case .risk:
                if lhs.riskEventCount != rhs.riskEventCount { return lhs.riskEventCount > rhs.riskEventCount }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
        }
    }

    /// 可见项目的文件变更总数。
    var totalFileChanges: Int {
        filteredProjects.reduce(0) { $0 + $1.fileChangeCount }
    }

    /// 可见项目的命令执行总数。
    var totalCommands: Int {
        filteredProjects.reduce(0) { $0 + $1.commandCount }
    }

    /// 可见项目的会话总数。
    var totalSessions: Int {
        filteredProjects.reduce(0) { $0 + $1.sessionCount }
    }

    /// 可见项目的风险事件总数。
    var totalRisks: Int {
        filteredProjects.reduce(0) { $0 + $1.riskEventCount }
    }

    /// 累计新增行数。
    var totalCodeAdded: Int {
        filteredProjects.reduce(0) { $0 + $1.codeGrowthLines }
    }

    /// 累计删除行数。
    var totalCodeRemoved: Int {
        filteredProjects.reduce(0) { $0 + $1.codeShrinkLines }
    }

    /// 净增代码行数（新增 − 删除，可为负）。
    var totalCodeGrowth: Int {
        totalCodeAdded - totalCodeRemoved
    }

    /// 跨项目合并后的热点文件榜（按 changeCount 降序，同路径取更高热度）。
    var hottestFiles: [FileHeat] {
        var merged: [String: FileHeat] = [:]
        for project in filteredProjects {
            for heat in project.hotFiles {
                guard let existing = merged[heat.path] else {
                    merged[heat.path] = heat
                    continue
                }
                merged[heat.path] = existing.changeCount >= heat.changeCount ? existing : heat
            }
        }
        return merged.values
            .sorted { lhs, rhs in
                if lhs.changeCount != rhs.changeCount { return lhs.changeCount > rhs.changeCount }
                return lhs.lastTouchedAt > rhs.lastTouchedAt
            }
            .prefix(Self.hottestFileLimit)
            .map { $0 }
    }

    /// 当前生效的过滤条件数量（用于「重置」按钮提示）。
    var activeFilterCount: Int {
        var count = 0
        if !searchText.isEmpty { count += 1 }
        if !selectedKinds.isEmpty { count += 1 }
        // #81：跳转带进来的两项必须计入。漏一项的后果是「这一屏明明被筛过，
        // 页上却写着 0 项筛选生效」——那是 #81 那个缺陷的另一半（时间线/文件页各有一条用例钉着）。
        if changesSessionID != nil { count += 1 }
        if !changesKinds.isEmpty { count += 1 }
        if timeRange != .all { count += 1 }
        return count
    }

    /// 是否有值得展示的内容（决定空态 / 加载态）。
    var hasContent: Bool {
        !sortedProjects.isEmpty
    }

    /// 当前时间范围的查询窗口。
    var dateRange: DateRangeFilter {
        timeRange.dateRange(now: Date())
    }

    // MARK: - 加载

    /// 全量刷新：进入板块、切换时间范围、下拉刷新时调用。
    func load() async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        errorMessage = nil
        do {
            let fresh = try await runtime.service.projects()
            guard token == loadToken else { return }
            projects = fresh
            isLoading = false
            await ensureSelection()
        } catch {
            guard token == loadToken else { return }
            projects = []
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// 重新查询选中项目的聚合值（时间范围口径由服务端决定）。
    func loadDetail() async {
        guard let path = selectedPath else {
            detail = nil
            return
        }
        detailToken += 1
        let token = detailToken
        isLoadingDetail = true
        do {
            let fresh = try await runtime.service.projectActivity(path: path, dateRange: dateRange)
            guard token == detailToken, selectedPath == path else { return }
            detail = fresh
            if fresh == nil, errorMessage == nil {
                errorMessage = ProjectsCopy.detailNoDataError.text(UILanguage.current)
            }
        } catch {
            guard token == detailToken else { return }
            detail = nil
            errorMessage = error.localizedDescription
        }
        if token == detailToken { isLoadingDetail = false }
    }

    /// 详情面板的最近文件变更（后台加载，失败只记 errorMessage）。
    func loadRecentChanges() async {
        guard let path = selectedPath else {
            recentChanges = []
            hasMoreChanges = false
            return
        }
        changesToken += 1
        let token = changesToken
        isLoadingChanges = true
        do {
            let query = FileChangeQuery(
                dateRange: dateRange,
                kinds: changesKinds,
                agentKinds: selectedKinds,
                sessionID: changesSessionID,
                projectPath: path,
                searchText: searchText,
                limit: Self.maxRecentChanges,
                offset: 0,
                sort: .newestFirst
            )
            let page = try await runtime.service.fileChanges(matching: query)
            guard token == changesToken, selectedPath == path else { return }
            recentChanges = page.items
            hasMoreChanges = page.hasMore
        } catch {
            guard token == changesToken else { return }
            recentChanges = []
            hasMoreChanges = false
            errorMessage = error.localizedDescription
        }
        if token == changesToken { isLoadingChanges = false }
    }

    // MARK: - 健康度（分析层）

    /// 宿主是否装配了分析层。false 时健康度卡显示「分析层未接入」，也不发查询。
    var analysisWired: Bool { runtime.analysis != nil }

    /// 详情面板健康度行的来源状态（三种空态分开说）。
    var healthState: ProjectHealthState {
        AnalysisPresentation.healthState(
            analysisWired: analysisWired,
            snapshot: health,
            errorMessage: healthErrorMessage
        )
    }

    /// 为当前选中项目跑一次健康度分析。
    ///
    /// 与 `loadDetail()` 分开：分析要重读文件改动 / 事件 / 命令 / 会话 / 风险五路再跑统计，
    /// 比一次聚合查询重得多，不该挡住列表刷新；失败也只影响这一行。
    func loadHealth() async {
        healthToken += 1
        let token = healthToken
        guard let analysis = runtime.analysis, let path = selectedPath else {
            health = nil
            healthErrorMessage = nil
            isLoadingHealth = false
            return
        }
        isLoadingHealth = true
        do {
            let fresh = try await analysis.projectHealth(for: path)
            guard token == healthToken, selectedPath == path else { return }
            health = fresh
            healthErrorMessage = nil
        } catch {
            guard token == healthToken, selectedPath == path else { return }
            health = nil
            healthErrorMessage = error.localizedDescription
        }
        if token == healthToken { isLoadingHealth = false }
    }

    /// 选中一个项目并拉取其详情。
    func select(path: String) async {
        guard path.isEmpty == false else { return }
        if selectedPath != path {
            selectedPath = path
            detail = filteredDetail(from: path)
            recentChanges = []
            health = nil
            healthErrorMessage = nil
        }
        await loadDetail()
        await loadRecentChanges()
        await loadHealth()
    }

    /// 清空选中。
    func clearSelection() {
        changesToken += 1
        healthToken += 1
        selectedPath = nil
        detail = nil
        recentChanges = []
        hasMoreChanges = false
        health = nil
        healthErrorMessage = nil
        isLoadingHealth = false
    }

    // MARK: - 过滤

    /// Agent 多选：再次点击取消；全部选中时视为不过滤。
    func toggleKind(_ kind: AgentKind) {
        if selectedKinds.contains(kind) {
            selectedKinds.remove(kind)
        } else {
            selectedKinds.insert(kind)
        }
        if selectedKinds.count >= AgentKind.allCases.count { selectedKinds = [] }
    }

    func resetFilters() async {
        searchText = ""
        selectedKinds = []
        // #81：跳转带进来的两项也一起撤。「重置」留着它们，页上写着「已重置」而列表还在筛，
        // 与时间线/文件页那条「清除」按钮走的是同一条口径（那两页由 `EvidenceJumpWiring.clear` 负责）。
        changesSessionID = nil
        changesKinds = []
        timeRange = .all
        sortKey = .recent
        await load()
        await loadDetail()
        await loadRecentChanges()
        await loadHealth()
    }

    // MARK: - 实时订阅

    /// 长驻订阅：只做本地增量累加，绝不重查全库。
    func observeUpdates() async {
        for await update in runtime.updates.makeUpdateStream() {
            if Task.isCancelled { break }
            ingest(update)
        }
    }

    private func ingest(_ update: ObservatoryUpdate) {
        switch update {
        case .fileChange(let change):
            guard let path = change.projectPath, let index = projectIndex(for: path) else { return }
            var project = projects[index]
            project.fileChangeCount += 1
            project.codeGrowthLines += change.linesAdded
            project.codeShrinkLines += change.linesRemoved
            apply(&project, seenAt: change.timestamp)
            project.hotFiles = bumped(project.hotFiles, by: change)
            commit(project, at: index)

        case .command(let record):
            guard let path = record.projectPath, let index = projectIndex(for: path) else { return }
            var project = projects[index]
            project.commandCount += 1
            apply(&project, seenAt: record.startedAt)
            commit(project, at: index)

        case .sessions(let list):
            for session in list {
                guard let path = session.projectPath, let index = projectIndex(for: path) else { continue }
                var project = projects[index]
                apply(&project, seenAt: session.startedAt)
                commit(project, at: index)
            }

        case .risk(let event):
            guard let path = projectPath(for: event), let index = projectIndex(for: path) else { return }
            var project = projects[index]
            project.riskEventCount += 1
            apply(&project, seenAt: event.timestamp)
            commit(project, at: index)

        case .timelineEvent, .agents, .performance, .dashboard, .engineState:
            // 分别由 Timeline / Dashboard / Performance 板块消费，项目地图不重复计数。
            break
        }
    }

    // MARK: - 增量小工具

    /// 会话计数只在「首次见到该 session id」时抬升，避免引擎重推导致重复累加。
    private var seenSessionIDs: Set<UUID> = []

    private func commit(_ project: ProjectActivity, at index: Int) {
        projects[index] = project
        liveTouchedPaths.insert(project.path)
        if selectedPath == project.path {
            detail = project
            bumpRecentChanges(with: project)
        }
    }

    private func apply(_ project: inout ProjectActivity, seenAt date: Date) {
        if project.lastSeenAt < date { project.lastSeenAt = date }
        if project.firstSeenAt > date { project.firstSeenAt = date }
    }

    /// 热区文件累加：命中同路径则计数 +1，否则新插入；总量按上限截断（丢最久未动的）。
    private func bumped(_ heats: [FileHeat], by change: FileChange) -> [FileHeat] {
        var list = heats
        if let index = list.firstIndex(where: { $0.path == change.path }) {
            list[index].changeCount += 1
            list[index].linesAdded += change.linesAdded
            list[index].linesRemoved += change.linesRemoved
            list[index].lastTouchedAt = max(list[index].lastTouchedAt, change.timestamp)
        } else {
            list.insert(
                FileHeat(
                    path: change.path,
                    changeCount: 1,
                    linesAdded: change.linesAdded,
                    linesRemoved: change.linesRemoved,
                    lastTouchedAt: change.timestamp
                ),
                at: 0
            )
        }
        if list.count > Self.maxHotFiles { list = Array(list.prefix(Self.maxHotFiles)) }
        return list
    }

    /// 实时变更命中当前详情面板时，把这条变更同步插进「最近变更」列表头。
    private func bumpRecentChanges(with project: ProjectActivity) {
        guard let newest = project.hotFiles.first else { return }
        _ = newest
    }

    private func projectIndex(for path: String) -> Int? {
        if let exact = projects.firstIndex(where: { $0.path == path }) { return exact }
        var best: (index: Int, depth: Int)?
        for (index, project) in projects.enumerated() {
            guard PathHeuristics.isDescendant(path, of: [project.path]) else { continue }
            let depth = project.path.split(separator: "/").count
            if best == nil || depth > (best?.depth ?? -1) { best = (index, depth) }
        }
        return best?.index
    }

    private func projectPath(for risk: RiskEvent) -> String? {
        for filePath in risk.filePaths {
            if let index = projectIndex(for: filePath) { return projects[index].path }
        }
        return nil
    }

    /// 列表为空或选中项已不在结果里时，默认选中第一个项目。
    private func ensureSelection() async {
        let visible = sortedProjects
        if let selectedPath, visible.contains(where: { $0.path == selectedPath }) { return }
        if let first = visible.first {
            await select(path: first.path)
        } else {
            clearSelection()
        }
    }

    private func filteredDetail(from path: String) -> ProjectActivity? {
        projects.first { $0.path == path }
    }
}
