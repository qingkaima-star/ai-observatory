//
//  DashboardDurationWindowTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · #50）
//  ─────────────────────────────────────────────────────────
//  #50 的形状：今日概览同一屏三句互相打架——「活跃总时长 **0s**」、
//  「当前运行中的 Agent：OpenAI Codex CLI 运行时长 **6h5m**」、
//  「Agent 时长占比 · **0 会话** · 还没有 Agent 使用记录」。
//  三句各自都成立：总时长与占比都只累计**今日新建**的会话
//  （`ObservatoryStore+Queries.swift:48-49` 用 `started_at ∈ 今日` 筛 `daySessions`，`:165` 求和），
//  而 6h5m 是**进程 uptime、不带日期窗口**（`DashboardActiveAgentsList.swift:107/135`）。
//  ⇒ 那个进程是昨天起的：今日会话 0 ⇒ 总时长 0，同时它确实在跑。
//  用户读到的是矛盾，处置是把窗口写上屏（本页「今日新建会话」那格已经这么做过一次）。
//
//  ⚠️ 本文件是**跨组件**断言：先证明取数侧真的按那个窗口算（种一个昨天起、今天还在跑的会话，
//  看它进不进 `totalActiveSeconds`），再证明界面读的是那句口径。
//  只测 `activeDurationCaption` 的字符串只能证明那句话存在，证明不了它**说的是这批数据**。
//
//  ── ~~BLOCKED-6~~（#75 解，车道 ws/range）───────────────────────────────
//  ~~「主修在 Store：把窗口改成与今日有交集」~~ —— 落地的不是"与今日有交集"，
//  而是**更彻底的那一步**：Dashboard 不再把区间压成一天交给 Store，
//  `dashboardStats(settledAt:within:)` 收的就是用户所选的 `DateRangeFilter`
//  （SQLite 侧端点进 SQL、SwiftData 侧进 `#Predicate`）。
//  于是"今日"不再是硬编码窗口，而只是六档里的一个档：
//    · 选「今天」⇒ 行为与本文件写下时**逐字相同**（昨天起那条仍不进总时长）；
//    · 选「最近 7 天」⇒ 同一条会话进来了（见下面 `sevenDayRange*` 那两条用例）。
//  窗口口径那句 caption 因此从「按今日新建的会话累计」改成「按区间内新建的会话累计 ·
//  未结算会话算到 …」——本文件的期望串跟着改，**两处一起动**正是下面那条反证注释要求的方式。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryTestSupport

@MainActor
@Suite("UI: 今日概览「活跃总时长」的窗口口径（#50）", .timeLimit(.minutes(1)))
struct DashboardDurationWindowTests {

    private let today = Date()
    private var startOfToday: Date { Calendar.current.startOfDay(for: today) }

    /// 结算时刻不靠墙钟：两个会话都是**已闭合**的，长度与"现在几点"无关。
    private func todaySession() -> AgentSession {
        AgentSession(
            kind: .claudeCode, title: "今天的会话",
            startedAt: startOfToday.addingTimeInterval(3_600),
            endedAt: startOfToday.addingTimeInterval(4_200)      // 恰好 600 秒
        )
    }

    /// 昨天 23:00 起、跨过零点还在跑的那种——真机上就是它让「6h5m」与「0s」并排。
    private func overnightSession() -> AgentSession {
        AgentSession(
            kind: .openAICodex, title: "昨天起、今天还在跑",
            startedAt: startOfToday.addingTimeInterval(-3_600),
            endedAt: startOfToday.addingTimeInterval(-600)
        )
    }

    private func model(sessions: [AgentSession]) async -> DashboardModel {
        let service = InMemoryObservatoryService()
        service.seed(sessions: sessions)
        let model = DashboardModel(
            runtime: ObservatoryRuntime(service: service, controller: service, updates: service)
        )
        await model.load(range: .today(today))
        return model
    }

    // MARK: ① 取数侧：窗口是真的，不是一句措辞

    @Test("总时长只累计今日新建的会话：昨天起那条一秒都不算")
    func producerCountsOnlySessionsStartedToday() async {
        let model = await model(sessions: [todaySession(), overnightSession()])
        // 今日那条 = 600 秒；昨天那条 3000 秒**不进**这个数。
        #expect(model.stats.totalActiveSeconds == 600)
        #expect(model.stats.sessionCount == 1)
        // 反证（写在 #50）：若窗口改成「与今天有交集」，这条用例应当被**改掉**而不是被删，
        // 同时 caption 那句窗口话也必须跟着改，两处一起动。
        // ↓ #75 正是这么做的：窗口换成用户所选区间（「今天」档行为不变，故这几行原样成立），
        //   caption 改成「区间内新建的会话累计 · 未结算会话算到 …」，7 天档新增用例在下面。
        #expect(model.stats.totalActiveSeconds != 3_600)
    }

    // MARK: ② 界面侧：读的就是那个窗口

    @Test("caption 前半句 = 手推口径字面量，后半句保住 Agent 峰值内存不丢")
    func captionCarriesTheWindowAndKeepsPeakMemory() async {
        let model = await model(sessions: [todaySession()])
        // #75：窗口不再是写死的"今日"，而是所选区间 ⇒ 前半句跟着改口径。
        #expect(model.activeDurationCaption(.chineseSimplified).hasPrefix("区间内新建的会话累计"))
        // 后半句必须继续保住峰值内存（#50 那半件事不能被窗口措辞挤掉），
        // 中间多出来的是**结算时刻**：未闭合的会话算到几时，不写就等于让人以为在跑实时数。
        // ⚠️ 期望串在这里**逐字拼**出来，不引用 Copy 表：引用 `DashboardCopy.activeDurationCaption`
        // 等于让实现自己给自己当基准，文案漂了用例还绿着。
        // #96 在这里补了主体词 "Agent"：这一格的内存来自 `perf_samples` 里挂着会话的采样，
        // 不是整机内存（整机在 `system_perf`）。少了这个词，"区分整机 vs Agent 开销"就只是心里话。
        let settlement = DateFormat.timestamp(model.stats.date)
        #expect(model.activeDurationCaption(.chineseSimplified)
            == "区间内新建的会话累计 · 未结算会话算到 " + settlement + " · Agent 峰值内存 " + model.peakMemoryText)
        // 不许把别格的窗口词搬过来：「不限所选区间」是「当前状态」那组（全表快照）的口径，
        // 用在时段累计上就是一句假话（它恰恰**是**限区间的）。
        #expect(!model.activeDurationCaption(.chineseSimplified).contains("不限所选区间"))
        #expect(!model.activeDurationCaption(.chineseSimplified).contains("全部会话"))
        // 写死的"今日"不该再出现在这一格：窗口是所选区间，选「今天」时才恰好等于今日。
        #expect(!model.activeDurationCaption(.chineseSimplified).contains("今日"))
    }

    @Test("0s 那一屏现在自解释了：窗口句与数字同格")
    func zeroDurationIsSelfExplaining() async {
        // 只有昨天起的那条 ⇒ 总时长 0s，而窗口句就在它下面一行。
        let model = await model(sessions: [overnightSession()])
        #expect(model.stats.totalActiveSeconds == 0)
        #expect(DurationFormat.compact(model.stats.totalActiveSeconds) == "0s")
        #expect(model.activeDurationCaption(.chineseSimplified).contains("区间内新建的会话累计"))
    }

    // MARK: ②b #75：界面递给服务端的必须是**真区间**，不是被压成的那一天
    //
    // 为什么这里用替身而不是真 Store：内存参照实现（`AIObservatoryTestSupport`，§3 冻结区）
    // 只实现单日版 `dashboardStats(for:)`，区间版走的是契约里那条"退化成单日"的默认实现——
    // 拿它测 7 天档等于测了个假窗口。「7 天档数字真的变多」那半边由
    // `Tests/AIObservatorySwiftDataStoreTests/DashboardRangeParityTests.swift` 用两个真后端钉，
    // 这里钉的是**界面这一侧**：递出去的窗口、以及那句话说的是不是同一个窗口。

    @Test("load(range: 7 天) 递给服务端的窗口就是那 7 天（不再被压成一天）")
    func sevenDayRangeIsHandedToTheServiceVerbatim() async {
        let spy = WindowSpyService()
        let model = DashboardModel(
            runtime: ObservatoryRuntime(service: spy, controller: spy, updates: spy)
        )
        let range = DateRangeFilter.lastHours(24 * 7, now: today)
        await model.load(range: range)

        let captured = spy.capturedWindow
        #expect(captured != nil, "窗口压根没递出去 ⇒ 界面还在走单日那条路")
        #expect(captured?.start == range.start,
                "窗口起点被改了：递进 \(String(describing: captured?.start))，选的 \(String(describing: range.start))")
        #expect(captured?.end == range.end, "窗口终点没递到位")
        // 结算时刻必须是"开着窗口的现在"，不是区间起点（改前传的是范围起点 ⇒ 未结算会话被夹成 0s）。
        // 这里不用 `!`：窗口没递进来就是这条用例要报的红，不该以崩溃收场。
        #expect(spy.capturedSettledAt.map { $0 >= today.addingTimeInterval(-2) } == true,
                "结算时刻退回到窗口起点去了 ⇒ 未结算会话又会被算成 0")
    }

    /// ①「7 天档下六格数字来自真区间」的**界面半边**：
    /// 六格读的就是那份按 7 天窗口取回来的载荷，一格都没有在界面上被重新按"某一天"算过。
    /// （载荷那半边——同一个窗口在两个真后端算出的六个数确实是 7 天的量而不是一天的量——
    /// 由 `DashboardRangeParityTests.sevenDayWindowIsNotASingleDay` 钉，这里递的是替身，量不出来。）
    @Test("7 天档：六格全部取自那份区间载荷，且端点逐字是所选的 168 小时")
    func allSixPeriodCellsReadTheRangePayload() async {
        let spy = WindowSpyService()
        let model = DashboardModel(
            runtime: ObservatoryRuntime(service: spy, controller: spy, updates: spy)
        )
        let range = DateRangeFilter.lastHours(24 * 7, now: today)
        await model.load(range: range)
        let payload = spy.statsPayload

        // 端点：界面递出去的窗口，起点必须正好是 `现在 − 7×24 h`。
        #expect(spy.capturedWindow?.start == range.start, "7 天窗口起点没递出去")
        #expect(spy.capturedWindow?.end == range.end, "7 天窗口终点没递出去")
        // 六格逐格与载荷同值（任何一格偷偷回落到"某一天"的口径都会在这里红）。
        #expect(model.stats.totalActiveSeconds == payload.totalActiveSeconds)
        #expect(model.stats.sessionCount == payload.sessionCount)
        #expect(model.stats.filesModified + model.stats.filesCreated + model.stats.filesDeleted
                == payload.filesModified + payload.filesCreated + payload.filesDeleted)
        #expect(model.stats.commandsExecuted == payload.commandsExecuted)
        #expect(model.stats.averageCPUPercent == payload.averageCPUPercent)
        #expect(model.stats.riskEventCount == payload.riskEventCount)
        // 分组副标题带的是**同一个**窗口（两端都在，且就是那 168 小时）。
        let expectedStart = range.start.map(DateFormat.timestamp) ?? "（无起点）"
        let expectedEnd = range.end.map(DateFormat.timestamp) ?? "（无终点）"
        let window = model.windowCaption(.chineseSimplified)
        #expect(window.contains(expectedStart) && window.contains(expectedEnd),
                "窗口括注没把所选区间两端写全：\(window)")
    }

    /// ② 前一手在收口时踩到的设计 bug：载荷里塞一个"桶锚点"（从窗口起点推），
    /// 于是 `.unbounded`（「全部」档）**没有起点 ⇒ 标签推不出来**。
    /// 回炉之后锚点不进载荷，两侧各自按「日档 = 结算日零点」复算，
    /// 于是「全部」档既不崩也不空标。这条用例钉的就是"不再依赖窗口起点"这件事本身：
    /// 同一份带负序号的日桶载荷，在「全部」档与在 72 小时档下**必须给出同一串标签**。
    @Test("「全部」档：日桶标签照样推得出来，且不靠窗口起点")
    func unboundedRangeStillDerivesBucketLabels() async {
        let days = DashboardStats(
            date: RangeSettlement.date,
            hourlyActivity: (-5...0).map { HourlyActivity(hour: $0, eventCount: 10 + $0, cpuAverage: 10) },
            bucketSpan: .naturalDay
        )
        let all = WindowSpyService(payload: days)
        let allModel = DashboardModel(runtime: ObservatoryRuntime(service: all, controller: all, updates: all))
        await allModel.load(range: .unbounded)

        // 「全部」没有起点：改前那版从这里读锚点，于是 activityPoints 会整排空标 / 错标。
        #expect(allModel.queryRange.start == nil, "夹具应该给一个没有起点的窗口")
        #expect(allModel.usesDayBuckets, "「全部」档应当是自然日桶")
        #expect(allModel.bucketAnchor == Calendar.current.startOfDay(for: RangeSettlement.date),
                "日档锚点必须只认结算时刻，不能去读那个根本不存在的窗口起点")
        let points = allModel.activityPoints
        #expect(points.map(\.slot) == Array(-5...0), "格子序号被界面自己重排/补齐过：\(points.map(\.slot))")
        #expect(points.allSatisfy { !$0.label.isEmpty }, "有格子推不出标签 ⇒ 锚点又回到窗口起点上去了")
        #expect(Set(points.map(\.label)).count == points.count, "标签撞车（错标）：\(points.map(\.label))")
        #expect(points.map(\.start) == points.map(\.start).sorted(), "桶起点没按时间升序")
        // 最后一格就是结算那天（序号 0 ⇔ 锚点本身），这一条把"带符号偏移"钉成实义。
        #expect(points.last?.start == allModel.bucketAnchor)
        #expect(points.first?.start == Calendar.current.date(byAdding: .day, value: -5, to: allModel.bucketAnchor))
        // 窗口口径那句在「全部」档必须换成"全部时间"，不能印出 `nil — 某时刻` 这种半句话。
        #expect(allModel.windowCaption(.chineseSimplified) == "全部时间",
                "「全部」档的窗口括注没走那句中性文案：\(allModel.windowCaption(.chineseSimplified))")
        #expect(!allModel.windowCaption(.chineseSimplified).contains("nil"),
                "窗口括注里漏了 nil：拿可选端点拼句子的下场")
    }

    @Test("7 天档下界面那句话说的是这个窗口，不是写死的今日")
    func captionAndGroupHeaderCarryTheSevenDayWindow() async {
        let spy = WindowSpyService()
        let model = DashboardModel(
            runtime: ObservatoryRuntime(service: spy, controller: spy, updates: spy)
        )
        await model.load(range: .lastHours(24 * 7, now: today))

        let caption = model.activeDurationCaption(.chineseSimplified)
        #expect(caption.contains("区间内新建的会话累计"))
        #expect(!caption.contains("今日"), "窗口都换档了，这句话还写着今日")
        // 分组副标题（时段累计那一组的窗口括注）必须带端点。
        let window = model.windowCaption(.chineseSimplified)
        #expect(window.contains("—"), "窗口括注没给两端：\(window)")
        // 「当前状态」那组不跟着窗口变：这里两份读数是同一个人造的，专门钉"没跟着变"。
        #expect(model.currentRunningAgentCount == 1,
                "当前状态那格应当读实时列表里的 1 个进程，实得 \(model.currentRunningAgentCount)")
        #expect(model.snapshotRunningAgentCount == 3,
                "全表快照没单独显示：实得 \(model.snapshotRunningAgentCount)")
        // 取消 max() 之后：两个读数各说各的，谁也不把对方撑大。
        #expect(model.currentRunningAgentCount != model.snapshotRunningAgentCount)
    }

    // MARK: ③ 接线：视图不许绕开模型自己拼

    @Test("DashboardView 的 hero 格读模型口径，且峰值内存这一屏只报一次")
    func viewWiresTheCaptionAndDoesNotDoublePeakMemory() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appending(path: "Sources/AIObservatoryUI/Dashboard/DashboardView.swift")
        let text = try String(contentsOf: url, encoding: .utf8)
        let code = text.split(separator: "\n")
            .map { line in String(line.components(separatedBy: " //").first ?? "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let squeezed = code.split(whereSeparator: \.isWhitespace).joined()
        #expect(squeezed.contains("caption:model.activeDurationCaption"),
                "hero 格没读模型口径（口径与视图会长成两把尺）")
        // 峰值内存不许在视图里再拼一遍（那会两份字面量、两处各自漂移）。
        #expect(!code.contains("peakMemoryBytes"), "视图又自己去拼峰值内存了")
        #expect(!code.contains("\"峰值内存"), "视图自带了一份 caption 字面量")
    }
}

// MARK: - 窗口替身

/// 替身载荷用的结算时刻：当地 15:00（不读成"某个整点"）。
///
/// 为什么不能落在**当地零点后的第一小时**里（原夹具 `800_036_400` 在 UTC+8 下正好是 00:30）：
/// 那一小时里 `startOfDay` 与"整点下取"是同一个时刻 ⇒ 把日档锚点错写成 `floorToHour`
/// 也测不出来（变异检查 M5 实测就是这样溜过去的）。取下午三点，两种锚点差 15 小时。
enum RangeSettlement {
    static var date: Date {
        let calendar = Calendar.current
        return calendar.date(byAdding: .hour, value: 15, to: calendar.startOfDay(for: Date())) ?? Date()
    }
}

/// 只记录"界面到底递了什么窗口进来"的 `ObservatoryService` 替身。
///
/// 载荷是手搓的：实时列表 1 个进程、全表快照 3 个 —— 两个数**故意不相等**，
/// 这样任何"取大 / 覆盖"的写法都会当场红（#75 取消的就是 `max(累计, 快照)`）。
/// 载荷可按用例替换（`init(payload:)`）：默认那份是「自然日桶」档，
/// 「全部」档那条用例要的是**带负序号**的日桶。
final class WindowSpyService: ObservatoryService, ObservatoryControlling, ObservatoryEventStreaming, @unchecked Sendable {
    private(set) var capturedWindow: DateRangeFilter?
    private(set) var capturedSettledAt: Date?

    /// `@unchecked Sendable` 只在测试替身内：可变状态只有 `captured*`，
    /// 用例都是单线程驱动（`await model.load(...)` 之后才读），不跨并发域共享。
    init(payload: DashboardStats = WindowSpyService.defaultPayload) { statsPayload = payload }

    let statsPayload: DashboardStats

    static var defaultPayload: DashboardStats {
        DashboardStats(
            date: RangeSettlement.date,
            sessionCount: 2,
            totalActiveSeconds: 3_600,
            filesModified: 1, filesCreated: 1, filesDeleted: 0,
            commandsExecuted: 4, failedCommands: 1,
            riskEventCount: 2, highRiskEventCount: 1,
            averageCPUPercent: 20, peakCPUPercent: 40, peakMemoryBytes: 2_000_000_000,
            activeAgentCount: 3,
            hourlyActivity: [
                HourlyActivity(hour: -1, eventCount: 5, cpuAverage: 10),
                HourlyActivity(hour: 0, eventCount: 7, cpuAverage: 60),
            ],
            agentShares: [],
            bucketSpan: .naturalDay
        )
    }

    func dashboardStats(for date: Date) async throws -> DashboardStats {
        capturedWindow = DateRangeFilter.today(date)
        capturedSettledAt = date
        return statsPayload
    }

    func dashboardStats(settledAt: Date, within range: DateRangeFilter) async throws -> DashboardStats {
        capturedWindow = range
        capturedSettledAt = settledAt
        return statsPayload
    }

    func activeAgents() async throws -> [AgentInstance] { [Self.agent] }
    private static let agent = AgentInstance(
        kind: .claudeCode, pid: 4_242, displayName: "claude",
        executablePath: "/usr/local/bin/claude",
        startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
        lastSeenAt: Date(timeIntervalSinceReferenceDate: 800_036_400),
        state: .running, cpuPercent: 12, memoryBytes: 300_000_000
    )

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> { Page() }
    func session(id: UUID) async throws -> AgentSession? { nil }
    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> { Page() }
    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> { Page() }
    func fileDiff(for changeID: UUID) async throws -> FileDiff? { nil }
    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> { Page() }
    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] { [] }
    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] { [] }
    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> { Page() }
    func projects() async throws -> [ProjectActivity] { [] }
    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? { nil }

    func start() async {}
    func stop() async {}
    func rescanNow() async {}
    func acknowledgeRiskEvent(id: UUID) async throws {}
    func updateSettings(_ settings: ObservatorySettings) async {}

    func makeUpdateStream() -> AsyncStream<ObservatoryUpdate> { AsyncStream { $0.finish() } }
    func currentState() async -> EngineState { .running }
}
