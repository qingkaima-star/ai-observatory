//
//  CommandsModel.swift
//  AIObservatoryUI
//
//  Owner: WS-UI
//  ─────────────────────────────────────────────────────────
//  Commands 板块（需求④「终端命令审计：命令 / 退出结果 / 耗时」）的数据流：
//  唯一直接查全局命令库（`ObservatoryService.commands(matching:)`）的板块，
//  不再依附于某个会话的详情面板。
//
//  三条不可让步的诚实规则（与 SessionCommandList 同一套视觉语言，不另立口径）：
//    · 没有退出码就是「结果未知」：绝不写成成功，也绝不补一个 0。
//    · 没有 `endedAt` 就没有耗时：显示「—」，绝不显示 0s。
//    · 空列表要说清是「还没采到」还是「被当前筛选筛光」。
//
//  结构上跟 `SessionsModel` 对齐：条件全部下推进 `CommandQuery`（不做本地二次过滤），
//  实时增量用同一份 `CommandAuditCriteria.matches(_:)` 判定，避免「服务端筛过、增量没筛」两套口径。
//

import Foundation
import Observation
import AIObservatoryCore

// MARK: - Exit status

/// 一行的退出结果分类：只认「有没有退出码」这条硬事实。
enum CommandExitStatus: String, CaseIterable, Hashable, Identifiable {
    case succeeded
    case failed
    case unknown

    var id: String { rawValue }

    var displayName: String { displayName(UILanguage.current) }

    /// 语言显式传入的用例（同 `SessionsModel.heroSupplementaryStats(_:)`）：
    /// 逐字断言不许依赖宿主系统语言。
    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .succeeded: return CommandsCopy.succeeded.text(language)
        case .failed:    return CommandsCopy.failed.text(language)
        case .unknown:   return CommandsCopy.unknownResult.text(language)
        }
    }

    var symbol: String {
        switch self {
        case .succeeded: return "checkmark.circle"
        case .failed:    return "xmark.circle"
        case .unknown:   return "questionmark.circle"
        }
    }
}

// MARK: - Exit filter

/// 结果过滤器：换算成 `CommandQuery.outcomes` 下推给服务端，因此分桶口径与服务端一致。
///
/// ## #76：`.terminated` 在哪一格
///
/// 三格分桶按**「有没有拿到退出码」**切，不按「进程结没结束」切：
/// `.running`（还没结束）、`.unknown`（没结论）、`.terminated`（随进程结束但没采到退出码）
/// 三条同属「结果未知」——这与行内的渲染完全一致（`CommandAuditFormat.exitStatus`
/// 对这三条一律给 `.unknown`，`exitText` 一律写「结果未知」）。
/// 旧写法把 `.terminated` 塞进「失败或终止」那一格，等于在过滤器层面
/// 违反引擎侧的口径红线（`ObservatoryEngine+Ingestion.settleOpenCommands`：
/// `.terminated` **不等于**成功也**不等于**失败），也会让「点失败格得到的条数」
/// 与「本页失败 tile 的条数」（只看退出码非 0）给出两个数。
enum CommandExitFilter: String, CaseIterable, Hashable, Identifiable {
    case all
    case succeeded
    case failed
    case unknownResult

    var id: String { rawValue }

    var displayName: String { displayName(UILanguage.current) }

    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .all:           return CommandsCopy.filterAllResults.text(language)
        case .succeeded:     return CommandsCopy.succeeded.text(language)
        // 「失败」这一格现在只装真失败 ⇒ 直接复用页内那一个出处（`CommandsCopy.failed`），
        // 不另写「失败或终止」：那个标签描述的桶已经不存在了。
        case .failed:        return CommandsCopy.failed.text(language)
        case .unknownResult: return CommandsCopy.filterRunningOrUnknown.text(language)
        }
    }

    var symbol: String {
        switch self {
        case .all:           return "checkmark.seal"
        case .succeeded:     return "checkmark.circle"
        case .failed:        return "xmark.circle"
        case .unknownResult: return "circle.dotted"
        }
    }

    /// 下推给服务端的 outcome 集合；空集表示不限制（契约里空集 = 全放开）。
    var outcomes: Set<CommandOutcome> {
        switch self {
        case .all:           return []
        case .succeeded:     return [.success]
        case .failed:        return [.failure]
        case .unknownResult: return [.running, .unknown, .terminated]
        }
    }

    /// 与 `outcomes` 严格等义的本地判定：`.terminated` 属「结果未知」，**不属**「失败」。
    func matches(_ record: CommandRecord) -> Bool {
        let allowed = outcomes
        guard !allowed.isEmpty else { return true }
        return allowed.contains(record.outcome)
    }
}

// MARK: - Criteria

/// 当前生效的过滤条件快照：既是服务端查询的唯一来源，也是实时增量的本地判定。
struct CommandAuditCriteria: Hashable {
    var dateRange: DateRangeFilter = .unbounded
    var agentKinds: Set<AgentKind> = []
    var exitFilter: CommandExitFilter = .all
    var destructiveOnly: Bool = false
    var sessionID: UUID?
    /// 只看这个项目里跑过的命令（#81(a)：`CommandQuery.projectPath` 那一维的本地一份）。
    /// 精确相等、不做前缀；命令没有采到归属项目（nil）时在任何项目条件下都不算匹配——
    /// 与 `ObservatoryStore` / `SwiftDataObservatoryStore` 两侧的 SQL / 判据逐字同一条口径。
    var projectPath: String?
    var searchText: String = ""
    /// 排序方向：必须写全限定名 —— UI 模块里 SwiftUI 也导出同名 `SortOrder`。
    var sort: AIObservatoryCore.SortOrder = .newestFirst

    /// 换算成 `CommandQuery`。分页参数由模型掌握，避免两处各算一套 offset。
    func makeQuery(limit: Int, offset: Int) -> CommandQuery {
        CommandQuery(
            dateRange: dateRange,
            agentKinds: agentKinds,
            sessionID: sessionID,
            projectPath: projectPath,
            outcomes: exitFilter.outcomes,
            destructiveOnly: destructiveOnly,
            searchText: searchText,
            limit: limit,
            offset: offset,
            sort: sort
        )
    }

    /// 用户主动收紧的条件数（不含时间范围）。
    var activeFilterCount: Int {
        var count = 0
        if !agentKinds.isEmpty { count += 1 }
        if exitFilter != .all { count += 1 }
        if destructiveOnly { count += 1 }
        if sessionID != nil { count += 1 }
        if projectPath != nil { count += 1 }
        if !searchText.isEmpty { count += 1 }
        return count
    }

    /// 与 `ObservatoryService.commands(matching:)` 同语义的本地判定：
    /// 实时增量靠它决定「这条命令属不属于当前列表」。搜索口径与服务端一致 ——
    /// 只匹配命令行本身（SQLite 侧 `search_text` 存的就是 `commandLine`）。
    func matches(_ record: CommandRecord) -> Bool {
        guard dateRange.contains(record.startedAt) else { return false }
        if !agentKinds.isEmpty, !agentKinds.contains(record.agentKind) { return false }
        if let sessionID, record.sessionID != sessionID { return false }
        if let projectPath, record.projectPath != projectPath { return false }
        if !exitFilter.matches(record) { return false }
        if destructiveOnly, !record.isDestructive { return false }
        if !searchText.isEmpty {
            guard record.commandLine.lowercased().contains(searchText.lowercased()) else { return false }
        }
        return true
    }
}

// MARK: - Formatting

/// 命令审计的文案口径：所有「退出结果 / 耗时 / 时间」的呈现都走这里，行内不留私有拼接。
enum CommandAuditFormat {
    /// 没有退出码时的统一说法：既不是成功也不是失败。
    static var unknownResultText: String { unknownResultText(UILanguage.current) }

    static func unknownResultText(_ language: AppLanguage) -> String {
        CommandsCopy.unknownResult.text(language)
    }

    /// 缺失值的占位符：不编造数字。
    static let missingValueText = "—"

    /// 退出结果：没有退出码 → `.unknown`（含 `.running` 采集未收尾的情况）。
    static func exitStatus(of record: CommandRecord) -> CommandExitStatus {
        guard let code = record.exitCode else { return .unknown }
        return code == 0 ? .succeeded : .failed
    }

    /// 结果列：有退出码才写 `exit N`，否则明说「结果未知」，绝不补 0。
    static func exitText(of record: CommandRecord) -> String {
        exitText(of: record, UILanguage.current)
    }

    /// `exit N` 两语言同串（它是终端里的原话，不是给人读的散文），只有「结果未知」跟语言走。
    static func exitText(of record: CommandRecord, _ language: AppLanguage) -> String {
        guard let code = record.exitCode else { return unknownResultText(language) }
        return "exit \(code)"
    }

    /// 耗时列：`endedAt` 缺失 → 「—」。有结束时间才计算，倒挂的时钟夹到 0 而不显负数。
    static func durationText(of record: CommandRecord) -> String {
        guard record.endedAt != nil, let duration = record.duration, duration.isFinite else {
            return missingValueText
        }
        return DurationFormat.compact(max(0, duration))
    }

    /// 结束时间：采不到就是「—」，不拿开始时间冒充。
    static func endedText(of record: CommandRecord) -> String {
        guard let endedAt = record.endedAt else { return missingValueText }
        return DateFormat.timestamp(endedAt)
    }

    /// 行内/无障碍用的摘要：命令 · 结果 · 耗时。
    static func summary(of record: CommandRecord) -> String {
        summary(of: record, UILanguage.current)
    }

    /// 摘要里「耗时」跟着语言走；分隔符「 · 」两语言同串（VoiceOver 在英文态读全角逗号会被
    /// 念成停顿，中点不会）。
    static func summary(of record: CommandRecord, _ language: AppLanguage) -> String {
        [
            record.commandLine,
            exitText(of: record, language),
            CommandsCopy.durationPrefix.format(language, durationText(of: record))
        ].joined(separator: " · ")
    }
}

// MARK: - Paging

/// 分页与合并的纯算术：抽出来才谈得上「不重查全库、不重复计数」这件事能被测试钉住。
enum CommandPaging {
    /// 第 `page` 页（0 起）的 offset；对负页码与 0 页宽做防御性夹取。
    static func offset(page: Int, pageSize: Int) -> Int {
        max(0, page) * max(1, pageSize)
    }

    /// 「还有更多」：已加载条数 < 服务端匹配总数。负数一律夹到 0。
    static func hasMore(loadedCount: Int, totalCount: Int) -> Bool {
        max(0, loadedCount) < max(0, totalCount)
    }

    /// 还差多少条没加载（状态条用），恒非负。
    static func unloadedCount(loadedCount: Int, totalCount: Int) -> Int {
        max(0, totalCount - loadedCount)
    }

    /// 排序后的全序比较：时间相同再比 id，保证多次运行结果一致（测试依赖这点）。
    static func precedes(_ lhs: CommandRecord, _ rhs: CommandRecord, descending: Bool) -> Bool {
        if lhs.startedAt != rhs.startedAt {
            return descending ? lhs.startedAt > rhs.startedAt : lhs.startedAt < rhs.startedAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    /// 信息完整度：退出码权重高于结束时间。用于同 id 合并时不拿「运行中」盖掉已完成结果。
    static func completeness(of record: CommandRecord) -> Int {
        (record.exitCode != nil ? 2 : 0) + (record.endedAt != nil ? 1 : 0)
    }

    /// 按排序方向裁到 `cap` 条：降序（最新在前）丢尾部最旧的那些；
    /// 升序（最早在前）丢头部 —— 那一端是已经划过去的旧数据，新命令都从尾部进来。
    /// 与 `SessionsModel.trimSessions()` 同一口径，避免两个板块对「保留哪一端」给出两种答案。
    static func trim(_ records: [CommandRecord], cap: Int, descending: Bool) -> [CommandRecord] {
        let cap = max(0, cap)
        guard records.count > cap else { return records }
        let excess = records.count - cap
        var result = records
        if descending {
            result.removeLast(excess)
        } else {
            result.removeFirst(excess)
        }
        return result
    }

    /// 两批记录合流：按 id 去重（同 id 留下更完整的一条）→ 按排序方向重排 → 裁剪。
    static func merge(
        _ existing: [CommandRecord],
        adding incoming: [CommandRecord],
        descending: Bool,
        cap: Int
    ) -> [CommandRecord] {
        var latest: [UUID: CommandRecord] = [:]
        var order: [UUID] = []
        for record in existing + incoming {
            if let seen = latest[record.id] {
                if completeness(of: record) >= completeness(of: seen) { latest[record.id] = record }
            } else {
                latest[record.id] = record
                order.append(record.id)
            }
        }
        let combined = order.compactMap { latest[$0] }
            .sorted { precedes($0, $1, descending: descending) }
        return trim(combined, cap: cap, descending: descending)
    }
}

// MARK: - Model

@Observable @MainActor final class CommandsModel {

    // MARK: Tunables

    /// 单页大小。
    static let pageSize = 100
    /// 内存中保留的命令上限，超出丢离当前排序方向最远的一端。
    static let maxRetainedRecords = 500

    // MARK: Dependencies

    private let runtime: ObservatoryRuntime

    // MARK: Load state

    private(set) var isLoading: Bool = false
    private(set) var isLoadingMore: Bool = false
    private(set) var errorMessage: String?

    /// 与 `criteria.sort` 方向一致的命令列表（默认新→旧）。
    private(set) var records: [CommandRecord] = []
    /// 服务端匹配总数（≠ records.count）。
    private(set) var totalCount: Int = 0
    private(set) var hasMore: Bool = false

    /// 整体重载计数：`List(selection:)` 在行身份变化后会复用旧的选中下标（与 Sessions/Timeline 同一处置）。
    private(set) var listRevision: Int = 0

    // MARK: Filter state（每一项都真实下推到 CommandQuery）

    /// 生效中的过滤条件；过滤条直接读它。
    var criteria: CommandAuditCriteria

    /// 板块内时间范围（默认跟随 `ShellModel.timeRange`）→ `criteria.dateRange`。
    var timeRange: ObservatoryTimeRange = .today {
        didSet {
            guard oldValue != timeRange else { return }
            criteria.dateRange = timeRange.dateRange(now: Date())
        }
    }

    /// 当前生效的服务端查询（派生值：条件 + 分页位置，永不与 `criteria` 分叉）。
    var query: CommandQuery {
        criteria.makeQuery(
            limit: Self.pageSize,
            offset: CommandPaging.offset(page: pagesLoaded - 1, pageSize: Self.pageSize)
        )
    }

    /// 已加载页数：`loadMore` 只往前走页号，实时插入因此不会打乱 offset。
    private var pagesLoaded: Int = 1

    // MARK: Selection

    private(set) var selectedID: UUID?

    // MARK: Tokens

    private var loadToken: Int = 0

    // MARK: Init

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        // 默认「今天」：init 内赋值不触发 didSet，因此把 dateRange 一并显式落到 criteria 上。
        let initialRange: ObservatoryTimeRange = .today
        self.timeRange = initialRange
        self.criteria = CommandAuditCriteria(dateRange: initialRange.dateRange(now: Date()))
    }

    // MARK: Derived

    var selectedRecord: CommandRecord? {
        guard let selectedID else { return nil }
        return records.first { $0.id == selectedID }
    }

    /// 用户主动收紧的条件数（不含时间范围）。
    var activeFilterCount: Int { criteria.activeFilterCount }

    /// 「有数据但被过滤光」的语义判定，决定空态文案与重置按钮。
    var hasNarrowedFilters: Bool { activeFilterCount > 0 || timeRange != .all }

    /// 当前被聚焦（只看它）的会话，来自详情面板的「只看此会话」。
    var focusedSessionID: UUID? { criteria.sessionID }

    /// 服务端匹配但还没加载进来的条数。
    var unloadedCount: Int { CommandPaging.unloadedCount(loadedCount: records.count, totalCount: totalCount) }

    /// 已加载命令里落在某个结果分桶中的条数（过滤菜单的提示数字）。
    func count(for filter: CommandExitFilter) -> Int {
        records.lazy.filter { filter.matches($0) }.count
    }

    /// 采集时仍在运行、结果尚未落库的条数。
    var runningCount: Int { records.lazy.filter { $0.outcome == .running }.count }

    /// 破坏性命令条数。
    var destructiveCount: Int { records.lazy.filter { $0.isDestructive }.count }

    /// 已加载命令里退出码为 0 的条数（没有退出码的不计入任何一侧）。
    var successCount: Int { records.lazy.filter { CommandAuditFormat.exitStatus(of: $0) == .succeeded }.count }

    /// 已加载命令里退出码非 0 的条数。
    var failureCount: Int { records.lazy.filter { CommandAuditFormat.exitStatus(of: $0) == .failed }.count }

    /// 结果未知（没有退出码）的条数：这些绝不能被算进成功或失败里。
    /// 结果未知（没有退出码）的条数：这些绝不能被算进成功或失败里。
    var unknownResultCount: Int {
        records.lazy.filter { CommandAuditFormat.exitStatus(of: $0) == .unknown }.count
    }

    /// 当前已加载命令的耗时总和；没有结束时间的命令不计入（不猜时长）。
    var measuredDuration: TimeInterval {
        records.compactMap { record -> TimeInterval? in
            guard record.endedAt != nil, let duration = record.duration, duration.isFinite else { return nil }
            return max(0, duration)
        }.reduce(0, +)
    }

    /// 状态条左侧的加载进度文案。
    var progressText: String { progressText(UILanguage.current) }

    func progressText(_ language: AppLanguage) -> String {
        CommandsCopy.progressText.format(language, totalCount, records.count)
    }

    /// 结果分布摘要（状态条与空态说明共用）。
    var outcomeSummaryText: String { outcomeSummaryText(UILanguage.current) }

    /// 拼接结构保持原样（三个标签各带一个数，中间「 · 」），只把字面来源换成文案表：
    /// 这句被逐字断言，动结构等于动口径。
    func outcomeSummaryText(_ language: AppLanguage) -> String {
        "\(CommandsCopy.succeeded.text(language)) \(successCount)"
            + " · \(CommandsCopy.failed.text(language)) \(failureCount)"
            + " · \(CommandsCopy.unknownResult.text(language)) \(unknownResultCount)"
    }

    // MARK: Loading
    func load() async {
        loadToken += 1
        let token = loadToken
        isLoading = true
        errorMessage = nil
        do {
            let page = try await runtime.service.commands(matching: query)
            guard token == loadToken else { return }
            records = CommandPaging.trim(
                page.items,
                cap: Self.maxRetainedRecords,
                descending: criteria.sort.descending
            )
            pagesLoaded = 1
            totalCount = page.totalCount
            hasMore = page.hasMore
            listRevision += 1
            isLoading = false
            await ensureSelection()
        } catch {
            guard token == loadToken else { return }
            records = []
            totalCount = 0
            hasMore = false
            pagesLoaded = 1
            listRevision += 1
            selectedID = nil
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    /// 下一页：只往前走页号，不重查已加载区间。
    func loadMore() async {
        guard hasMore, !isLoadingMore, !isLoading else { return }
        isLoadingMore = true
        let token = loadToken
        let previousPages = pagesLoaded
        pagesLoaded += 1
        do {
            let page = try await runtime.service.commands(matching: query)
            guard token == loadToken else {
                // 期间发生了新的整体加载 → 丢弃这一页并回滚页号。
                pagesLoaded = previousPages
                isLoadingMore = false
                return
            }
            if page.items.isEmpty {
                pagesLoaded = previousPages
                hasMore = false
            } else {
                records = CommandPaging.merge(
                    records,
                    adding: page.items,
                    descending: criteria.sort.descending,
                    cap: Self.maxRetainedRecords
                )
                totalCount = page.totalCount
                hasMore = page.hasMore
            }
        } catch {
            pagesLoaded = previousPages
            errorMessage = error.localizedDescription
        }
        isLoadingMore = false
    }

    func applyFilters() async {
        pagesLoaded = 1
        await load()
    }

    // MARK: Filter mutation

    func setTimeRange(_ range: ObservatoryTimeRange) async {
        guard timeRange != range else { return }
        timeRange = range
        await applyFilters()
    }

    func toggleAgentKind(_ kind: AgentKind) async {
        var next = criteria.agentKinds
        if next.contains(kind) {
            next.remove(kind)
        } else {
            next.insert(kind)
        }
        await setAgentKinds(next)
    }

    /// 一次性设定 Agent 集合（过滤条菜单里的「全部 Agent」与逐项勾选都走这里）。
    func setAgentKinds(_ kinds: Set<AgentKind>) async {
        // 全选等价于不选：收口成空集，免得界面显示「在筛」而查询其实没筛。
        let normalized = kinds.count >= AgentKind.allCases.count ? [] : kinds
        guard criteria.agentKinds != normalized else { return }
        criteria.agentKinds = normalized
        await applyFilters()
    }

    func setExitFilter(_ filter: CommandExitFilter) async {
        guard criteria.exitFilter != filter else { return }
        criteria.exitFilter = filter
        await applyFilters()
    }

    func setDestructiveOnly(_ enabled: Bool) async {
        guard criteria.destructiveOnly != enabled else { return }
        criteria.destructiveOnly = enabled
        await applyFilters()
    }

    /// 只看某次会话的命令（详情面板的「只看此会话」按钮使用）。
    func focusSession(_ id: UUID?) async {
        guard criteria.sessionID != id else { return }
        criteria.sessionID = id
        await applyFilters()
    }

    func setSearchText(_ text: String) async {
        guard text != criteria.searchText else { return }
        criteria.searchText = text
        await applyFilters()
    }

    func setSortDescending(_ descending: Bool) async {
        guard criteria.sort.descending != descending else { return }
        criteria.sort = AIObservatoryCore.SortOrder(descending: descending)
        await applyFilters()
    }

    func resetFilters() async {
        criteria.agentKinds = []
        criteria.exitFilter = .all
        criteria.destructiveOnly = false
        criteria.sessionID = nil
        criteria.projectPath = nil   // #81(a)：项目现在是一条真过滤维度，「回到全量」必须清掉它
        criteria.searchText = ""
        await applyFilters()
    }

    // MARK: Selection

    func select(_ id: UUID?) {
        guard id != selectedID else { return }
        selectedID = id
    }

    /// 列表为空或选中项已不在结果里时，默认选中第一条（Preview 与键盘导航都依赖这个行为）。
    private func ensureSelection() async {
        if let selectedID, records.contains(where: { $0.id == selectedID }) { return }
        selectedID = records.first?.id
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
        case .command(let record):
            ingestCommand(record)

        case .sessions, .timelineEvent, .agents, .fileChange, .performance, .risk, .dashboard, .engineState:
            // `.sessions` 是**部分**推送（引擎只推变化/关闭的那几条），
            // 拿它反推「哪些会话已不存在」会误删仍在库里的命令行，因此这里刻意不消费。
            return
        }
    }

    private func ingestCommand(_ record: CommandRecord) {
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            // 同一条命令的后续快照（运行中 → 已完成）就地替换，绝不插第二条。
            if CommandPaging.completeness(of: record) >= CommandPaging.completeness(of: records[index]) {
                records[index] = record
            }
            return
        }
        guard criteria.matches(record) else { return }
        records = CommandPaging.merge(
            records,
            adding: [record],
            descending: criteria.sort.descending,
            cap: Self.maxRetainedRecords
        )
        totalCount += 1
        hasMore = CommandPaging.hasMore(loadedCount: records.count, totalCount: totalCount)
        if selectedID == nil { selectedID = record.id }
    }
}
