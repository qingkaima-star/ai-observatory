//
//  DashboardInformationArchitectureTests.swift
//  Tests/AIObservatoryUITests
//
//  Owner: ws/summary（#79 首页信息架构）
//  ─────────────────────────────────────────────────────────
//  #79 的判据是**顺序**与**零新增取数**两条，都不许做成"打开页面没崩"。
//
//  ① 顺序：`blockOrder` 是渲染顺序的唯一出处（`body` 走 `ForEach(blockOrder)`），
//     所以四格顺序是一条可以逐字对的数组期望；再把每个区块渲染哪个组件也从源码里取出来对，
//     并且要求每个组件在全文件**只被用一次**——把风险条顺手再补回页尾，
//     那一处的计数就变 3，当场红。
//     （为什么不走真无障碍树：`A11yTree.windowTexts()` 读的是**本进程所有窗口**，
//     同一测试可执行文件里已有 `RenderedPageRedactionTests` 在开窗口并行跑，
//     第二个消费者会把两边的集合搅在一起。台账允许"视图树或源码级"两种先例，这里取源码级。）
//
//  ② 零新增取数（台账裁定 5 / AGENTS.md §6）：一次 `dashboardStats` 就是首页全部预算
//     （账内实测已占 90 ms/tick 的 91 %）。这一条钉两遍：
//     模型侧用带计数器的替身，数每 tick 到底发了几路读；
//     视图侧不许绕开模型自己碰服务（否则计数器看不见那一半）。
//
//  ⚠️ 期望值全是手推：四格顺序抄自台账第六节 S.1，读数额是"一次 load = 四路、其余为 0"，
//     不是从实现里反推出来的数字。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

@MainActor
@Suite("UI: #79 首页区块顺序 + 每 tick 取数预算", .timeLimit(.minutes(2)))
struct DashboardInformationArchitectureTests {

    // MARK: - ① 顺序

    @Test("四格顺序 = 台账 S.1 那一句（待查看 → 观测对象 → 时段摘要 → 趋势与关键事件）")
    func blockOrderIsTheAdjudicatedSequence() {
        // 手推期望：台账 `整改波次-2026-09-22` 第六节 S.1 逐字定的这一列。
        #expect(DashboardView.blockOrder == [.toReview, .watched, .periodSummary, .activityTrend],
                "区块顺序变了：\(DashboardView.blockOrder.map(\.rawValue))")
        #expect(DashboardView.blockOrder.count == 4, "四个区块少了一格就不是那套信息架构了")
        #expect(Set(DashboardView.blockOrder).count == DashboardView.blockOrder.count, "同一格排了两次")
    }

    @Test("渲染确实由那个数组驱动，且四个区块各自渲染它该渲染的组件")
    func bodyRendersThroughTheOrderArrayWithOneComponentPerBlock() throws {
        let code = try squeezedDashboardView()
        // `body` 里如果还留着四行顺序调用，数组改了也没用上 ⇒ 顺序判据射程为零。
        #expect(code.contains("ForEach(DashboardView.blockOrder)"),
                "body 不再走 blockOrder 渲染 ⇒ 上面那条数组顺序断言是空的")

        let composition: [(block: String, end: String, components: [String])] = [
            ("toReview", "case.watched:", ["riskStrip", "anomalyCard"]),
            // #98 之后这一格多收一个 `jump:` 参数 ⇒ 针停在"渲染的是这个列表、吃的是这批 agents"
            // 那半句上（闭括号不写进 needle，否则参数一多就又得改它，而那并不是这一格要判的事）。
            ("watched", "case.periodSummary:", ["DashboardActiveAgentsList(agents:model.activeAgents"]),
            ("periodSummary", "case.activityTrend:", ["statGrid"]),
            ("activityTrend", "privatevarstateCard", ["trendRow"]),
        ]
        for entry in composition {
            let branch = try Self.branch(after: "case.\(entry.block):", before: entry.end, in: code)
            for component in entry.components {
                #expect(branch.contains(component),
                        "区块 \(entry.block) 没渲染 \(component)，实得分支：\(branch)")
            }
        }
    }

    @Test("「待查看事项」里风险条在异常卡之前，且两者都不在页尾")
    func reviewItemsLeadAndTheRiskStripComesFirst() throws {
        let code = try squeezedDashboardView()
        let branch = try Self.branch(after: "case.toReview:", before: "case.watched:", in: code)
        let risk = try #require(branch.range(of: "riskStrip")?.lowerBound)
        let anomaly = try #require(branch.range(of: "anomalyCard")?.lowerBound)
        #expect(risk < anomaly, "异常卡排到风险条之前了：\(branch)")

        // 改前这两块挂在页尾（第 5 位与末位）。现在全文件只许各出现两次：
        // 一次是分支里的使用，一次是它自己的定义。多一处就是"顺手又补回末尾"。
        #expect(Self.occurrences(of: "riskStrip", in: code) == 2,
                "riskStrip 在 DashboardView 里不止「定义 + 一次使用」⇒ 又被画到别处了")
        #expect(Self.occurrences(of: "anomalyCard", in: code) == 2, "anomalyCard 同上")
    }

    @Test("时段摘要里「当前状态」与「时段累计」各成一组、标签分开，且不互相掺数")
    func currentStatusAndWindowTotalsStayInSeparateGroups() throws {
        let code = try squeezedDashboardView()
        let grid = try Self.branch(after: "varstatGrid:someView{", before: "funcstatTile(", in: code)
        // 两个组标题 + 两个网格：一组一格（当前状态）与一组六格（时段累计）不并排同格。
        #expect(Self.occurrences(of: "SectionHeader(", in: grid) == 2,
                "时段摘要这一档的分组标签数变了：\(grid)")
        #expect(Self.occurrences(of: "MetricGrid(", in: grid) == 2, "两组读数没各自成网格")
        #expect(grid.contains("currentStatusTitle") && grid.contains("periodTotalTitle"),
                "两组标签必须一个写「当前状态」一个写「时段累计」（裁定 3）")
        // 「六格排两行三列」的**那个 3** 已经从这一页的字面量搬进了档位常量
        // （#83：`Sizing.summaryColumns`，值由 `ColumnAlignmentTests.metricGridColumnCountsComeFromTokens`
        // 逐字钉为 3，`columns: 1` 那一组也仍是字面量、由同一用例点名豁免）。
        // 这里改钉"两组各自成网格、累计那一组用摘要档"——断言强度没有降：
        // 把摘要档改成 2 会红（在档位用例那儿），把两组并排会红（在上面的分组标签与这里）。
        #expect(grid.contains("snapshotTiles,columns:1")
                    && grid.contains("periodTiles,columns:Sizing.summaryColumns"),
                "当前状态那组单独成档：改前它与那六格并排同格，两个口径互相矛盾")

        let snapshot = try Self.branch(after: "varsnapshotTiles:[DashboardTile]{",
                                       before: "varperiodTiles:[DashboardTile]{", in: code)
        #expect(Self.occurrences(of: "DashboardTile(", in: snapshot) == 1, "当前状态那组只许一格")
        #expect(snapshot.contains("model.currentRunningAgentCount")
                    && snapshot.contains("model.snapshotRunningAgentCount"),
                "当前状态那组要给实时列表数与全表快照两个数（不再取大）")

        let period = try Self.branch(after: "varperiodTiles:[DashboardTile]{",
                                     before: "vartrendRow:someView{", in: code)
        // 时段累计那六格不许再掺任何"当前状态"的读数 —— 那正是裁定 3 拆开的混卖。
        let lowercasedPeriod = period.lowercased()
        #expect(!lowercasedPeriod.contains("snapshot") && !lowercasedPeriod.contains("currentrunning"),
                "时段累计组里又混进了当前状态的读数：两种口径并排就再也对不上账")
        #expect(Self.occurrences(of: "DashboardTile(", in: period) == 6, "时段累计应是六格")
    }

    // MARK: - ② 零新增取数

    @Test("一次 load(range:) 只发四路读：区间聚合恰好一次，其余读全为零")
    func oneLoadUsesTheWholeBudgetAndNothingMore() async throws {
        let spy = ShareBudgetSpyService()
        let model = DashboardModel(runtime: ObservatoryRuntime(service: spy, controller: spy, updates: spy))
        await model.load(range: .today(Date()))

        // 手推预算：一次结算聚合 + 一次进程列表 + 一次风险页 + 一次引擎状态，共四路。
        #expect(spy.rangedStatsCalls == 1, "区间聚合被查了 \(spy.rangedStatsCalls) 次")
        #expect(spy.activeAgentsCalls == 1)
        #expect(spy.riskEventsCalls == 1)
        #expect(spy.currentStateCalls == 1)
        // 重排之后不许多出任何一路读：这一列每一项都必须是 0。
        #expect(spy.legacyStatsCalls == 0, "又有人走回单日那条 `dashboardStats(for:)` ⇒ 无声降级")
        #expect(spy.sessionsCalls == 0)
        #expect(spy.eventsCalls == 0)
        #expect(spy.fileChangesCalls == 0)
        #expect(spy.commandsCalls == 0)
        #expect(spy.performanceSamplesCalls == 0)
        #expect(spy.systemPerformanceCalls == 0)
        #expect(spy.projectsCalls == 0)
        #expect(spy.projectActivityCalls == 0)
        #expect(spy.sessionDetailCalls == 0)
        #expect(spy.fileDiffCalls == 0)

        // 换档同样是四路，不是"每个区块各查一遍"。
        let before = spy.totalReadCalls
        await model.load(range: .lastHours(6, now: Date()))
        #expect(spy.totalReadCalls - before == 4, "换一次区间发了 \(spy.totalReadCalls - before) 路读")
    }

    @Test("视图自己不碰服务：所有读数都从模型那一份载荷里取")
    func viewNeverReachesForDataItself() throws {
        let code = try squeezedDashboardView()
        for banned in ["runtime.", "service.", "dashboardStats", "activeAgents()", "riskEvents(",
                       "analysis.", "InMemoryObservatoryService"] {
            #expect(!code.contains(banned),
                    "视图里出现了 \(banned) ⇒ 它绕开模型自己取数，上面的读数额就数不全")
        }
        // 首页每 tick 只许那三处调用（`.task` 进页/换档、`.refreshable` 下拉、错误卡的「重试」），
        // 区块本身不再各拉一路。多一处 = 有人给某个区块新加了取数。
        #expect(Self.occurrences(of: "model.load(range:", in: code) == 3)
        #expect(Self.occurrences(of: "model.loadAnomalies()", in: code) == 2)
    }

    // MARK: - 源码取词小工具

    /// `DashboardView.swift` 的"只看代码"版：剥掉注释与预览块，再压掉所有空白
    /// （同 `DashboardDurationWindowTests.viewWiresTheCaptionAndDoesNotDoublePeakMemory` 的切法——
    /// 那里已经证明跨行写法会把按行切的尺子骗过去）。
    private func squeezedDashboardView() throws -> String {
        let code = try BilingualCopyGate.codeOnlyString(Self.dashboardViewFile)
        guard code.contains("struct DashboardView") else {
            throw StructureError.missingBody(Self.dashboardViewFile)
        }
        return code.split(whereSeparator: \.isWhitespace).joined()
    }

    private static let dashboardViewFile = "Sources/AIObservatoryUI/Dashboard/DashboardView.swift"

    /// 取 `start` 之后、`end` 之前的那一段。
    private static func branch(after start: String, before end: String, in code: String) throws -> String {
        let opened = try #require(code.range(of: start), "源码里找不到锚点 \(start)")
        let tail = code[opened.upperBound...]
        let closed = try #require(tail.range(of: end), "锚点 \(start) 之后找不到收尾 \(end)")
        return String(tail[..<closed.lowerBound])
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        var search = code.startIndex
        var count = 0
        while let found = code.range(of: needle, range: search..<code.endIndex) {
            count += 1
            search = found.upperBound
        }
        return count
    }

    private enum StructureError: Error {
        case missingBody(String)
    }
}

// MARK: - 取数计数器

/// 只会"数自己被打了几次"的 `ObservatoryService` 替身。
///
/// 载荷是空的：这一条用例问的不是数字对不对（那是 `DashboardSixCellSQLReconciliationTests`
/// 与 `DashboardRangeParityTests` 的活），问的是**首页每 tick 发了几路读**。
final class ShareBudgetSpyService: ObservatoryService, ObservatoryControlling,
                                   ObservatoryEventStreaming, @unchecked Sendable {

    private(set) var rangedStatsCalls = 0
    private(set) var legacyStatsCalls = 0
    private(set) var activeAgentsCalls = 0
    private(set) var sessionsCalls = 0
    private(set) var sessionDetailCalls = 0
    private(set) var eventsCalls = 0
    private(set) var fileChangesCalls = 0
    private(set) var fileDiffCalls = 0
    private(set) var commandsCalls = 0
    private(set) var performanceSamplesCalls = 0
    private(set) var systemPerformanceCalls = 0
    private(set) var riskEventsCalls = 0
    private(set) var projectsCalls = 0
    private(set) var projectActivityCalls = 0
    private(set) var currentStateCalls = 0

    /// 每 tick 一共发了几路读（含引擎状态那一路快照）。
    var totalReadCalls: Int {
        rangedStatsCalls + legacyStatsCalls + activeAgentsCalls + sessionsCalls + sessionDetailCalls
            + eventsCalls + fileChangesCalls + fileDiffCalls + commandsCalls + performanceSamplesCalls
            + systemPerformanceCalls + riskEventsCalls + projectsCalls + projectActivityCalls
            + currentStateCalls
    }

    func dashboardStats(for date: Date) async throws -> DashboardStats {
        legacyStatsCalls += 1
        return .empty
    }

    func dashboardStats(settledAt: Date, within range: DateRangeFilter) async throws -> DashboardStats {
        rangedStatsCalls += 1
        return .empty
    }

    func activeAgents() async throws -> [AgentInstance] {
        activeAgentsCalls += 1
        return []
    }

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        sessionsCalls += 1
        return Page()
    }

    func session(id: UUID) async throws -> AgentSession? {
        sessionDetailCalls += 1
        return nil
    }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        eventsCalls += 1
        return Page()
    }

    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        fileChangesCalls += 1
        return Page()
    }

    func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        fileDiffCalls += 1
        return nil
    }

    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        commandsCalls += 1
        return Page()
    }

    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        performanceSamplesCalls += 1
        return []
    }

    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        systemPerformanceCalls += 1
        return []
    }

    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        riskEventsCalls += 1
        return Page()
    }

    func projects() async throws -> [ProjectActivity] {
        projectsCalls += 1
        return []
    }

    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        projectActivityCalls += 1
        return nil
    }

    func start() async {}
    func stop() async {}
    func rescanNow() async {}
    func acknowledgeRiskEvent(id: UUID) async throws {}
    func updateSettings(_ settings: ObservatorySettings) async {}

    func makeUpdateStream() -> AsyncStream<ObservatoryUpdate> { AsyncStream { $0.finish() } }

    func currentState() async -> EngineState {
        currentStateCalls += 1
        return .running
    }
}
