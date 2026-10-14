//
//  DashboardModel.swift
//  AIObservatoryUI / Dashboard
//
//  Owner: WS-UI (subagent B)
//  职责：Dashboard 板块唯一数据源。
//    · load()            —— 一次性拉取「今日统计 + 运行中 Agent + 引擎状态」（并发，不串行等三路）。
//    · observeUpdates()  —— 长驻订阅 ObservatoryUpdate，只做本地增量合并，绝不重查全库。
//  计数累加约定：同一行为引擎可能同时推 .timelineEvent 与 .fileChange/.command/.risk，
//  因此「小时柱状图」只由 .timelineEvent 抬升，「文件/命令/风险计数」只由各自的专用 case 抬升，
//  避免同一行为被计两次；收到 .dashboard(stats) 时以服务端聚合值为权威真值整体覆盖。
//

import Foundation
import Observation
import AIObservatoryCore

// MARK: - Chart Point

/// 活动柱图的一格。#75 起它**不一定是一小时**：窗口 ≤ 36 h 是小时桶，更宽是自然日桶
/// （粒度由服务端给出，见 `DashboardStats.bucketSpan`，界面只跟随）。
///
/// 类型名与 `slot` 的语义都按"桶序号"来：`slot` 是载荷里的序号（契约里那个字段仍叫 `hour`，
/// 改名要牵动 §3 冻结区的内存参照实现），`start` 才是这一格真正的起点时刻。
struct DashboardHourPoint: Identifiable, Hashable, Sendable {
    /// 桶序号（0 基）。
    let slot: Int
    /// 这一格的起点（由 `queryRange` 的起点 / 第一个有数据的桶推出来，口径见 `bucketStart(for:)`）。
    let start: Date
    /// 坐标轴与 tooltip 用的短标签（小时档 "00"…"23"，日档 "09-16" 一类）。
    let label: String
    let eventCount: Int
    let cpuAverage: Double

    var id: Int { slot }

    /// 高负载时段用强调色区分，不使用自定义渐变。
    var isHighLoad: Bool { cpuAverage >= 50 }
}

// MARK: - Model

/// Dashboard 视图模型：只读 `ObservatoryService`，只吸收 `ObservatoryEventStreaming` 增量。
@Observable
@MainActor
final class DashboardModel {

    // MARK: 常量

    /// 运行中 Agent 的内存保留上限（防御性截断，避免异常推送撑爆内存）。
    static let maxRetainedAgents = 256
    /// 「最近风险」条保留的事件数上限。
    static let maxRetainedRisks = 12
    /// 时间范围没有起点（「全部」）时，异常扫描回看多久。
    ///
    /// 不回看全库有两个理由：一是桶数会撑爆内存，二是把三个月前的静默期混进基线
    /// 会让最近的真实尖峰被零桶墙抹平。口径会写进卡片副标题，不藏着。
    static let defaultAnomalyWindowSeconds: TimeInterval = 24 * 3600

    // MARK: 采集状态

    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?

    // MARK: 数据

    /// 本范围内聚合统计（六宫格 + 两张图表的唯一来源）。
    private(set) var stats: DashboardStats = .empty
    /// 当前运行中的 Agent 进程列表，按 CPU 降序。
    private(set) var activeAgents: [AgentInstance] = []
    /// 引擎状态：优先使用 ShellModel 的值，取不到时由本模型自行观测兜底。
    private(set) var engineState: EngineState = .stopped
    /// 最近一次收到事件的时间，用于「实时」指示条。
    private(set) var lastEventAt: Date?

    /// 本次 load 之后由 `.sessions` 增量新引入的会话 ID 集合（不覆盖服务端 sessionCount）。
    private(set) var liveSessionIDs: Set<UUID> = []
    /// 当前范围内最近的风险事件（「最近风险」条的数据源）。
    private(set) var recentRisks: [RiskEvent] = []
    /// 分析层检出的异常（按检出时间降序，裁剪由 `AnalysisPresentation` 负责）。
    private(set) var anomalies: [AnomalyFinding] = []
    /// 本轮异常扫描的起点，用于卡片上写清口径。
    private(set) var anomalyWindowStart: Date?
    /// 异常扫描失败原因。单独一路：分析层挂了不该把整个 Dashboard 打成错误态。
    private(set) var anomalyErrorMessage: String?
    private(set) var isLoadingAnomalies: Bool = false

    /// 统计口径所属时间范围。由视图在 load 之前写入（默认「今天」）。
    var queryRange: DateRangeFilter = .today()

    // MARK: 私有

    private let runtime: ObservatoryRuntime
    private var loadToken: Int = 0
    private var anomalyToken: Int = 0
    private var statsRefreshTask: Task<Void, Never>?
    /// 合并重算用的影子（#53 动作 1）：`ingest` 的多条增量先累加在这里，
    /// 到点一次性提交给 `stats` —— 让"一波 N 条事件"只引发 **1 次** body 重算。
    private var pendingStats: DashboardStats?
    private var pendingLastEventAt: Date?
    private var statsFlushTask: Task<Void, Never>?

    /// 合并窗口。取 50 ms（约 3 帧）：真机上一波文件抖动/命令回包会在几十毫秒内推十几条过来，
    /// 这条窗口把它们并成一次提交；而人眼对 50 ms 的读数延迟无感（不是"冻住"）。
    static let statsFlushWindowNanoseconds: UInt64 = 50_000_000

    /// 增量流触发聚合补查的最小间隔（秒）。
    ///
    /// 为什么需要这条边：会话派生的四个值（会话数 / 总时长 / 峰值内存 / 时长占比）
    /// 只有服务端 `dashboardStats` 能算对，而契约里的 `.dashboard` 推送
    /// **全仓没有生产者**（只有 `ServiceProtocols.swift` 的声明与本文件的消费），
    /// 于是这四个值此前只在启动那一次 `load()` 里取过，之后永远冻结在
    /// 「引擎还没有会话」的那一刻。真机实测：库里 sessions=2 / 峰值 227.9 MB，
    /// 界面「AI 会话 0 / 总时长 0s / 峰值内存 0 B」，而带各自增量 case 的
    /// 文件 / 命令 / 风险 / 事件计数都在正常增长——所以看起来像「会话没刷新」而不是「全坏了」。
    /// 叠加的第二个坑：`.task` 里 `observeUpdates()` 排在 `load()` 与 `loadAnomalies()`
    /// 之后，启动窗口内的 `.sessions(open)` 要么没订到、要么被 `load()` 末尾清掉。
    ///
    /// 这里把「收到过会改变聚合的增量」当作「聚合值可能过期」的信号，合并成一次低频补查：
    /// 既不让每个事件打一次全库聚合，也不会让界面长期停在启动瞬间。
    /// 聚合口径仍然只有服务端一份，避免与 Sessions 页各算一套。
    static let statsRefreshCooldown: TimeInterval = 10

    // MARK: 初始化

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
    }

    // MARK: 派生属性

    /// 卡片副标题用的日期：优先范围起点，否则服务端统计日期。
    var focusDate: Date {
        queryRange.start ?? stats.date
    }

    /// 是否有任何值得展示的内容（决定空态 / 加载态）。
    var hasContent: Bool {
        stats.sessionCount > 0
            || stats.filesModified > 0
            || stats.filesCreated > 0
            || stats.filesDeleted > 0
            || stats.commandsExecuted > 0
            || stats.riskEventCount > 0
            || stats.totalActiveSeconds > 0
            || !activeAgents.isEmpty
            || !liveSessionIDs.isEmpty
    }

    /// 柱图的数据点：**格数与粒度都由服务端的载荷决定**（#75）。
    ///
    /// 改前这里写死 `(0..<24)`，而载荷在 > 36 h 的窗口下给的是自然日桶
    /// （`hour` 字段是"自锚点起的第几天"）——那种补齐会把 7 个日桶压进 0…23 的格子里，
    /// 标题写"24 小时"、画的却是 7 天。现在界面只按载荷实际给了几格来画，
    /// 缺失的格子由取数侧补零（两侧同一条补齐口径）。
    var activityPoints: [DashboardHourPoint] {
        stats.hourlyActivity.map { entry in
            let start = bucketStart(for: entry.hour)
            return DashboardHourPoint(
                slot: entry.hour,
                start: start,
                label: bucketLabel(start),
                eventCount: entry.eventCount,
                cpuAverage: entry.cpuAverage
            )
        }
    }

    /// 柱图是不是自然日档（标题/副标题/坐标轴都跟随它，界面自己不重算宽度阈值）。
    var usesDayBuckets: Bool { stats.bucketSpan == .naturalDay }

    /// 第 `slot` 格的起点。锚点与取数侧逐字同一条（见 `DashboardStats.bucketSpan` 的注释）：
    ///   · 日档：锚点 = 结算时刻所在自然日零点，`slot` 是**带符号**的天偏移；
    ///   · 小时档：锚点 = 窗口起点落到整点（「今天」= 当日零点 ⇒ slot 恰好等于 0…23 的时）。
    /// 只认这两个出处，界面不另算一套；用 `Calendar` 加减，不手写秒差（§5）。
    func bucketStart(for slot: Int) -> Date {
        let calendar = Calendar.current
        let anchor = bucketAnchor
        return calendar.date(byAdding: stats.bucketSpan.calendarUnit, value: slot, to: anchor) ?? anchor
    }

    /// 锚点本身（用例与坐标轴标签都读它，避免两处各推一遍）。
    var bucketAnchor: Date {
        let calendar = Calendar.current
        if usesDayBuckets {
            return calendar.startOfDay(for: stats.date)
        }
        return DashboardModel.floorToHour(queryRange.start ?? stats.date, calendar: calendar)
    }

    /// 桶起点的短标签：日档给「09-16」，小时档给「14」。
    private func bucketLabel(_ date: Date) -> String {
        usesDayBuckets ? DashboardModel.dayLabel(date) : String(format: "%02d", Calendar.current.component(.hour, from: date))
    }

    static func dayLabel(_ date: Date) -> String {
        date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
    }

    static func floorToHour(_ date: Date, calendar: Calendar = .current) -> Date {
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour]
        return calendar.date(from: calendar.dateComponents(parts, from: date)) ?? date
    }

    /// 柱图事件合计（用于卡片右上角计数）。
    var hourlyEventTotal: Int {
        stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }
    }

    /// 最忙的那一格，用于图表页脚。
    var busiestBucketLabel: String? {
        guard let top = activityPoints.max(by: { $0.eventCount < $1.eventCount }), top.eventCount > 0 else { return nil }
        return top.label
    }

    /// 峰值内存文案。
    var peakMemoryText: String {
        ByteFormat.humanReadable(stats.peakMemoryBytes)
    }

    /// 「活跃总时长」那一格的 caption —— 前半句是**窗口口径**，不是装饰。
    ///
    /// 为什么必须写：这个数只累计**落在所选窗口内新建**的会话
    /// （`ObservatoryStore+Queries.swift` 用 `started_at ∈ range` 筛出会话，
    /// 再对它们求 `duration(until: settledAt)`；SwiftData 侧同形）。
    /// 而同一页下方「活跃 Agent」列表里那个「运行时长 6h5m」是**进程 uptime，不带窗口**
    /// （`DashboardActiveAgentsList.swift:107/135`）。于是真机上出现过这样一屏：
    /// 「活跃总时长 **0s**」+「OpenAI Codex CLI 运行时长 **6h5m**」+「Agent 时长占比 · **0 会话**」。
    /// 三句各自都成立（那个进程是昨天起的 ⇒ 窗口内新建会话 0 ⇒ 总时长 0），
    /// 但并排读起来就是自相矛盾，用户只会以为观测器坏了。
    ///
    /// 所以这句现在把**两件事**都写出来：累计的是哪一段（窗口）、没结算的算到几时（结算时刻）。
    /// 原注释里"主修在 Store（把窗口改成与今天有交集）"那半句已经由 #75 落地成"窗口就是
    /// 用户所选的区间"，`BLOCKED-6` 就此解掉。
    var activeDurationCaption: String { activeDurationCaption(UILanguage.current) }

    /// 显式语言那一版给用例（`DashboardDurationWindowTests` 逐字认这句，
    /// 不能建在"跑测试那台机器的系统语言"上）。
    func activeDurationCaption(_ language: AppLanguage) -> String {
        DashboardCopy.activeDurationCaption.copy.format(
            language, settlementText(language), peakMemoryText
        )
    }

    /// 未结算会话被算到的那个时刻（人读版）。
    private func settlementText(_ language: AppLanguage) -> String {
        DateFormat.timestamp(stats.date)
    }

    /// 「当前状态」那一组读的数：**此刻在跑的 Agent 进程数**（实时列表 + 全表快照）。
    ///
    /// 改前这里是 `liveAgentCount = max(stats.activeAgentCount, activeAgents.count)`——
    /// 把"窗口内出现过多少场会话/几个 Agent"与"全表 running 快照"两种口径取大并成一个数卖
    /// （台账裁定 3 点名的就是这一句）。取大不叫聚合，叫挑好看的：两个读数各自都可能是对的，
    /// 合成一个之后谁都验证不了。现在两边各显各的：
    ///   · 这里给当前状态（快照与实时列表取并集，同一种口径内部对齐）；
    ///   · 时段累计那组另有格，并在副标题写明窗口。
    var currentRunningAgentCount: Int {
        if !activeAgents.isEmpty { return activeAgents.count }
        return stats.runningAgentSnapshotCount
    }

    /// 快照读数（全表 `state = 'running'`，不限窗口）——与 `currentRunningAgentCount`
    /// 分开显示，让人看见"界面按实时列表"和"库里快照"是两个来源。
    var snapshotRunningAgentCount: Int { stats.runningAgentSnapshotCount }

    /// 本次加载后实时新增的会话数。
    var liveSessionCount: Int {
        liveSessionIDs.count
    }

    /// Agent 时长占比，按秒数降序。
    var sortedShares: [AgentUsageShare] {
        stats.agentShares.sorted { lhs, rhs in
            if lhs.totalSeconds != rhs.totalSeconds { return lhs.totalSeconds > rhs.totalSeconds }
            return lhs.sessionCount > rhs.sessionCount
        }
    }

    // MARK: - 加载

    /// 「最近风险」条展示的事件：先按等级、再按时间排序。
    var riskHighlights: [RiskEvent] {
        recentRisks
            .sorted { lhs, rhs in
                if lhs.level != rhs.level { return lhs.level > rhs.level }
                return lhs.timestamp > rhs.timestamp
            }
            .prefix(4)
            .map { $0 }
    }

    /// 按指定时间范围刷新（视图切换全局范围时调用）。
    func load(range: DateRangeFilter) async {
        queryRange = range
        await load()
    }

    /// 聚合结算时刻——**只管"还没结算的会话长度算到几时"，不再管选哪一天**（#75）。
    ///
    /// 改前这一个 `Date` 同时是"选哪一天"（Store 内部 `DateRangeFilter.today(date)`），
    /// 于是选「7 天」时六宫格算的还是某一天。现在窗口走 `queryRange` 真区间，这里只剩结算：
    ///   · 窗口已经过去（`now ≥ end`）：区间里没有"还在跑"的会话可言，取区间末；
    ///   · 窗口开着 / 没有终点（「全部」）：取现在——取区间末会把刚开始的未结算会话夹成 0。
    /// 原注释里那笔真机账（库里 2 个会话在跑、界面总时长 0s）就是"把范围起点当结算时刻"的代价，
    /// 那条坑不在这次改动里复活。
    private var statsSettledAt: Date {
        let now = Date()
        guard let end = queryRange.end else { return now }
        return now >= end ? end : now
    }

    /// 所选窗口的人读口径（六宫格分组标题与几张卡的副标题都用它）。
    ///
    /// 为什么由界面拼而不是让 Store 回传：端点本来就是界面递给查询的那一份，
    /// 再回传一次等于把同一个窗口存在两处（早晚两个数字）。载荷里只带**取数侧才决定**的
    /// 那件事——分桶粒度（`DashboardStats.bucketSpan`）。
    func windowCaption(_ language: AppLanguage) -> String {
        guard let start = queryRange.start else {
            return DashboardCopy.windowAll.text(language)
        }
        guard let end = queryRange.end else {
            return DashboardCopy.windowSince.copy.format(language, DateFormat.timestamp(start))
        }
        return DashboardCopy.windowBetween.copy.format(
            language, DateFormat.timestamp(start), DateFormat.timestamp(end)
        )
    }

    /// 无语言入参的那一版只给界面属性读（界面自己传 `UILanguage.current`）。
    var windowCaptionText: String { windowCaption(UILanguage.current) }

    func load() async {
        await load(live: false)
    }

    /// - Parameter live: 增量合并路径发起的后台补查。为真时不置 `isLoading`
    ///   （否则头部每 10 秒闪一次进度圈），也不清 `liveSessionIDs`
    ///   （清了就把「实时新增 N 个会话」这句刚拿到的信息擦掉）。
    private func load(live: Bool) async {
        loadToken += 1
        let token = loadToken
        if !live { isLoading = true }
        errorMessage = nil

        let settledAt = statsSettledAt

        do {
            async let statsResult = runtime.service.dashboardStats(settledAt: settledAt, within: queryRange)
            async let agentsResult = runtime.service.activeAgents()
            async let stateResult = runtime.updates.currentState()
            async let risksResult = runtime.service.riskEvents(
                matching: RiskQuery(dateRange: queryRange, limit: Self.maxRetainedRisks)
            )

            let (freshStats, agents, state, riskPage) = try await (statsResult, agentsResult, stateResult, risksResult)
            guard token == loadToken else { return }

            pendingStats = nil        // 同上：整份读数落地，影子作废
            stats = freshStats
            recentRisks = Array(riskPage.items.prefix(Self.maxRetainedRisks))
            activeAgents = Self.sortedByCPU(Array(agents.prefix(Self.maxRetainedAgents)))
            engineState = state
            if !live { liveSessionIDs.removeAll() }
        } catch {
            guard token == loadToken else { return }
            errorMessage = error.localizedDescription
        }

        if token == loadToken { isLoading = false }
    }

    // MARK: - 分析层（异常检测）

    /// 宿主是否装配了分析层。false 时「异常检测」卡显示「分析层未接入」，也不发查询。
    var analysisWired: Bool { runtime.analysis != nil }

    /// 扫描当前范围内的异常。与 `load()` 分开：分析要重读事件 / 变更 / 命令 / 采样四路，
    /// 不该把六宫格与图表的刷新串行挡在后面。
    /// - Parameter now: 「现在」。默认取墙钟，测试注入固定时刻。
    /// - Parameter live: 由节流补查那一条路发起（``refreshAggregatesAndAnomalies()``）。
    ///   理由与 `load(live:)` 同一条：不闪加载态 —— 否则异常卡每 `statsRefreshCooldown` 秒
    ///   转一次圈，读数没变却一直在"正在分析"。**这一路不改审计窗口，只改它被重跑的时机。**
    func loadAnomalies(now: Date = Date(), live: Bool = false) async {
        guard let analysis = runtime.analysis else {
            anomalyToken += 1
            anomalies = []
            anomalyWindowStart = nil
            anomalyErrorMessage = nil
            isLoadingAnomalies = false
            return
        }
        anomalyToken += 1
        let token = anomalyToken
        if !live { isLoadingAnomalies = true }
        let start = queryRange.start ?? now.addingTimeInterval(-Self.defaultAnomalyWindowSeconds)
        anomalyWindowStart = start
        do {
            let fresh = try await analysis.anomalies(since: start)
            guard token == anomalyToken else { return }
            anomalies = fresh
            anomalyErrorMessage = nil
        } catch {
            guard token == anomalyToken else { return }
            // 保留上一轮结果，但把「这一轮没成功」说清楚，不装作还是新鲜的。
            anomalyErrorMessage = error.localizedDescription
        }
        if token == anomalyToken, !live { isLoadingAnomalies = false }
    }

    // MARK: - 实时订阅

    /// 长驻订阅：只做本地增量累加，绝不重查全库。
    func observeUpdates() async {
        for await update in runtime.updates.makeUpdateStream() {
            ingest(update)
        }
    }

    /// internal 只为让用例能确定性驱动"一波事件"（不依赖活的广播流与真时钟）；
    /// 与 `ObservatoryEngine.recordRisks` 同一条理由。
    func ingest(_ update: ObservatoryUpdate) {
        switch update {
        case .dashboard(let fresh):
            // ⚠️ 这条 case **今天没有生产者**：全仓 `broadcast(.dashboard(` 零命中
            // （引擎每 tick 广播的集合里没有它）。所以页面上的实时数字全部来自
            // 本地增量累加 + `scheduleStatsRefresh` 的节流兜底，不是服务端推来的聚合值。
            // 分支保留是因为 `ObservatoryUpdate` 是穷举枚举（冻结契约），删不掉 case；
            // 一旦引擎真的发这条，这里就是它的落点——整体覆盖本地累加结果并撤掉兜底补查。
            statsRefreshTask?.cancel()
            statsRefreshTask = nil
            pendingStats = nil        // 服务端整体覆盖：影子作废，否则旧增量会盖掉新读数
            pendingLastEventAt = nil
            stats = fresh

        case .agents(let list):
            activeAgents = Self.sortedByCPU(Array(list.prefix(Self.maxRetainedAgents)))

        case .engineState(let state):
            engineState = state

        case .timelineEvent(let event):
            mutateStats { bumpHourlyActivity(for: event.timestamp, into: &$0) }
            pendingLastEventAt = event.timestamp
            scheduleStatsFlush()
            scheduleStatsRefresh()

        case .sessions(let list):
            // 只记录「新出现过的会话 ID」，不改写服务端给出的 sessionCount。
            for session in list where !liveSessionIDs.contains(session.id) {
                liveSessionIDs.insert(session.id)
            }
            if !list.isEmpty { scheduleStatsRefresh() }

        case .fileChange(let change):
            // 与服务端 `dashboardStats` 的 SQL 严格同口径：只按 modified / created /
            // deleted 三类计数。`.renamed` 在服务端哪一类都不进，
            // 本地要是把它算进 filesModified，两次补查之间就会凭空多出差值。
            mutateStats { stats in
                switch change.kind {
                case .created:            stats.filesCreated += 1
                case .modified:           stats.filesModified += 1
                case .deleted:            stats.filesDeleted += 1
                case .renamed, .unknown:  break
                }
            }
            scheduleStatsFlush()
            scheduleStatsRefresh()

        case .command(let record):
            mutateStats { stats in
                stats.commandsExecuted += 1
                switch record.outcome {
                case .failure: stats.failedCommands += 1
                // `.terminated` 是"收口时拿不到退出码"，既不是失败也不算已解决（引擎侧红线），
                // 所以这里刻意不落进任何一桶——看着像漏计，计进去才是错。
                case .running, .success, .unknown, .terminated: break
                }
            }
            scheduleStatsFlush()
            scheduleStatsRefresh()

        case .risk(let event):
            mutateStats { stats in
                stats.riskEventCount += 1
                if event.level >= .high {
                    stats.highRiskEventCount += 1
                }
            }
            scheduleStatsFlush()
            if !recentRisks.contains(where: { $0.id == event.id }) {
                recentRisks.insert(event, at: 0)
                if recentRisks.count > Self.maxRetainedRisks {
                    recentRisks.removeLast(recentRisks.count - Self.maxRetainedRisks)
                }
            }
            scheduleStatsRefresh()

        case .performance:
            // 性能曲线由 Performance 板块负责，Dashboard 不重复消费。
            // 也不因此补查：采样每几秒就来一发，而它不改今日聚合的任何一个字段。
            break
        }
    }

    /// 合并短时间内的多次增量为一趟聚合补查，且两次补查之间至少隔
    /// ``statsRefreshCooldown`` 秒。放在这里而不是各 case 里重查，
    /// 是因为一次文件抖动就能推十几条过来。
    private func scheduleStatsRefresh() {
        guard statsRefreshTask == nil else { return }
        statsRefreshTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(nanoseconds: UInt64(Self.statsRefreshCooldown * 1_000_000_000))
            guard !Task.isCancelled else {
                self.statsRefreshTask = nil
                return
            }
            self.statsRefreshTask = nil
            await self.refreshAggregatesAndAnomalies()
        }
    }

    /// 到点的那"一趟"补查：六宫格 + 异常扫描**各一次**，共用同一个冷却。
    ///
    /// 为什么异常扫描要挂在这里（#53 动作 2b，B2）：改前 `loadAnomalies()` 全仓只有两个调用点
    /// —— `DashboardView.swift:75`（进页/换范围）与 `:80`（下拉刷新），于是**页面开着、
    /// 新数据一直在进，异常卡却永远停在进页那一刻的结论**。那是"读数冻在启动值"那一族
    /// （#8）在这张卡上的形状：卡片下面写着回看窗口 = 今天，读起来却像实时结论。
    ///
    /// 修法只降频率、不动口径：
    ///   · `fetchLimit` 与回看窗口一个字不改（需求层面"审计窗口不缩"优先于性能参数）；
    ///   · **不开第二个时钟** —— 重跑次数由 `statsRefreshCooldown` 这一个人管，
    ///     且只有"收到过会改变聚合的增量"才会排上这一趟（零活动 ⇒ 一趟都不排）。
    ///
    /// internal 是为了让用例确定性驱动"到点了"，与 `flushPendingStats()` 同一条理由。
    func refreshAggregatesAndAnomalies() async {
        await load(live: true)
        await loadAnomalies(live: true)
    }

    // MARK: - 增量小工具

    /// 增量抬升"活动趋势"那一列。
    ///
    /// ⚠️ #75 之后这条格子**不一定按小时**：窗口 > 36 h 时服务端给的是自然日桶，
    /// 而 `HourlyActivity.hour` 装的是**带符号的天偏移**（锚点 = `stats.date` 那天零点）。
    /// 改前这里无条件写 `component(.hour)`，于是 7 天档下每条事件都会去碰 0…23 里的
    /// 某一格 —— 与同一份载荷里那些格子的含义根本对不上，柱图会莫名长高在一格上。
    /// 现在按 `stats.bucketSpan` 走与服务端同一条序号口径，落在窗口外的增量不入账。
    private func bumpHourlyActivity(for date: Date, into stats: inout DashboardStats) {
        let calendar = Calendar.current
        let slot: Int
        switch stats.bucketSpan {
        case .naturalDay:
            let anchor = calendar.startOfDay(for: stats.date)
            guard let day = calendar.dateComponents([.day], from: anchor,
                                                    to: calendar.startOfDay(for: date)).day else { return }
            slot = day
        case .hourOfDay:
            let anchor = DashboardModel.floorToHour(queryRange.start ?? stats.date, calendar: calendar)
            let floored = DashboardModel.floorToHour(date, calendar: calendar)
            guard floored >= anchor,
                  let hour = calendar.dateComponents([.hour], from: anchor, to: floored).hour else { return }
            slot = hour
        }
        // 窗口外的增量不改这次读数的柱子：例如"最近 1 小时"档里收到一条上一小时的余波事件，
        // 加进去就等于替服务端没数的那一段编一个数。
        if let start = queryRange.start, date < start { return }
        if let end = queryRange.end, date > end { return }

        if let index = stats.hourlyActivity.firstIndex(where: { $0.hour == slot }) {
            stats.hourlyActivity[index].eventCount += 1
            return
        }
        stats.hourlyActivity.append(HourlyActivity(hour: slot, eventCount: 1, cpuAverage: 0))
        stats.hourlyActivity.sort { $0.hour < $1.hour }
    }

    /// 把一条增量累加到影子上，并保证"到点只提交一次"。
    /// N 条事件 ⇒ N 次影子累加 ⇒ **1 次** `stats` 赋值 ⇒ 1 次 body 重算。
    private func mutateStats(_ body: (inout DashboardStats) -> Void) {
        var shadow = pendingStats ?? stats
        body(&shadow)
        pendingStats = shadow
    }

    private func scheduleStatsFlush() {
        guard statsFlushTask == nil else { return }
        statsFlushTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: DashboardModel.statsFlushWindowNanoseconds)
            self?.flushPendingStats()
        }
    }

    /// 一次性提交影子。internal 是为了让用例能确定性地驱动"到点"这件事
    /// （不等真时钟 50 ms，也不把窗口做成可注入的假时钟——那会让生产多一个参数）。
    @discardableResult
    func flushPendingStats() -> Bool {
        statsFlushTask?.cancel()
        statsFlushTask = nil
        defer { pendingStats = nil; pendingLastEventAt = nil }
        if let at = pendingLastEventAt { lastEventAt = at }
        guard let shadow = pendingStats else { return false }
        stats = shadow
        return true
    }

    private static func sortedByCPU(_ agents: [AgentInstance]) -> [AgentInstance] {
        agents.sorted { lhs, rhs in
            if lhs.cpuPercent != rhs.cpuPercent { return lhs.cpuPercent > rhs.cpuPercent }
            return lhs.memoryBytes > rhs.memoryBytes
        }
    }
}

private extension DashboardModel {
    var language: AppLanguage { UILanguage.current }
}
