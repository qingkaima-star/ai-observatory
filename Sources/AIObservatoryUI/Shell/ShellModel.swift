//
//  ShellModel.swift
//  AIObservatoryUI
//
//  Owner: WS-UI
//  ─────────────────────────────────────────────────────────
//  外壳状态：全局路由、全局时间范围、引擎状态、活跃 Agent。
//  各板块自己订阅增量；本模型只负责跨板块共享的那一份「环境事实」。
//

import Foundation
import Observation
import SwiftUI
import AIObservatoryCore

/// 主界面外壳的共享状态。
@Observable
@MainActor
public final class ShellModel {

    /// 活跃 Agent 的内存保留上限（防御性截断）。
    static let maxRetainedAgents = 256

    // MARK: 路由与全局过滤

    /// 当前选中的侧边栏板块。
    var selection: SidebarSection? = .dashboard
    /// #81：一条**待落地的跳转意图**（项目 / 会话 / 事件种类 / 时间区间 四类条件 + 要打开哪一行）。
    ///
    /// 它是跨板块的路由把手，所以放在外壳而不是各板块的 Model 里（与 `SidebarSearchWiring`
    /// 同一处置）。**落地即消费**：目标板块在 `EvidenceJumpWiring.seed` 里把它取走并置回 nil，
    /// 于是「上一跳的条件」不会在用户已经自己改过之后再被压回来。
    /// 语义、路由与幂等全在 `EvidenceJumpWiring`，这里只存这一份状态。
    var pendingJump: JumpIntent?
    /// 全局时间范围：板块进入时以此为初值，板块修改时回写。
    var timeRange: ObservatoryTimeRange = .today
    /// 全局搜索词（侧栏那一格 `.searchable` 写的就是它）。
    ///
    /// #74 起它**承重**，三条语义都在 `SidebarSearchWiring`：
    ///   ① 这里改词 ⇒ 下推进当前板块的 `*Query.searchText`，走 Store 真查询；
    ///   ② 板块自己的过滤条改词 ⇒ 回写到这里（侧栏显示的是同一个词）；
    ///   ③ 切板块不清空，新板块进入时继续下推。
    /// 板块侧**只读 `searchQueryTerm`**，不要自己再去 trim 原文（两处归一迟早分叉）。
    var searchText: String = ""

    /// 侧栏那一格的**有效查询词**：去首尾空白，全是空白 == 没在搜。
    ///
    /// `.searchable` 的原文里常有用户还没打完的尾随空格；把它直接当查询词会让
    /// 「搜 `abc`」与「搜 `abc `」成为两次不同的重查。板块侧统一读这一份。
    var searchQueryTerm: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 板块自己的过滤条改了查询词 ⇒ 侧栏同步显示同一个词（裁定 11 第 2 条）。
    ///
    /// 判定只看「有效词是否不同」：板块查询词恒为去过空白的那一份，
    /// 所以侧栏刚敲下的尾随空格不算差异（不该把用户正在打的字吞掉改写），
    /// 而「板块重置成空」「板块框里换了词」这两类真差异会照实回填侧栏。
    /// 相等时**不写**——写了会再惊动板块那一条 `.task(id: shell.searchText)`，
    /// 于是一次改动被两个方向各推一遍（查询次数翻倍）。
    /// - Returns: 真的改了侧栏返回 `true`。
    @discardableResult
    func adoptSectionSearchTerm(_ term: String) -> Bool {
        let normalized = term.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized != searchQueryTerm else { return false }
        searchText = normalized
        return true
    }

    // MARK: 引擎事实

    /// 观测引擎状态。
    private(set) var engineState: EngineState = .stopped
    /// 当前活跃（运行中 / 空闲）的 Agent 进程，按 CPU 降序。
    private(set) var activeAgents: [AgentInstance] = []
    /// 订阅循环是否在跑。
    private(set) var isStreaming: Bool = false
    /// 最近一次收到推送的时间。
    private(set) var lastUpdateAt: Date?
    /// 最近一次加载/订阅错误。
    private(set) var errorMessage: String?
    /// 重新扫描进行中。
    private(set) var isRescanning: Bool = false

    private let runtime: ObservatoryRuntime

    public init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        // 真机 UI 验收与冒烟截图需要「不点击就直接进到某个板块」（见 `Tools/UIProbe/`），
        // 名字不认识就不覆盖，退回默认 Dashboard——一个环境变量不该让启动失败。
        if let name = ProcessInfo.processInfo.environment["AIOBSERVATORY_SECTION"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           let section = SidebarSection(rawValue: name) {
            selection = section
        }
    }

    // MARK: 派生展示属性

    var engineStateColor: Color { ObservatoryTheme.color(for: engineState) }

    /// 状态名**原样**来自 `EngineState.displayName`（在 `AIObservatoryCore/Contracts/**`，
    /// §3 冻结区，仍是中文）。英文态下它是那一格唯一没翻的部分，已随 B3 交回总控，
    /// 不在这里另抄一份英文状态名（第二个出处必分叉）。
    var engineStateText: String { engineState.displayName(UILanguage.current) }

    /// 侧栏底部那一格的整句（「引擎 …」/ "Engine: …"）。
    var engineStateReadout: String { engineStateReadout(UILanguage.current) }

    func engineStateReadout(_ language: AppLanguage) -> String {
        ShellCopy.engineStateLabel.format(language, engineStateText)
    }

    /// 引擎当前是否在采集（用于启停按钮文案）。
    var isCollecting: Bool { engineState.isCollecting }

    var runningAgentCount: Int {
        activeAgents.filter { $0.state == .running }.count
    }

    var idleAgentCount: Int {
        activeAgents.filter { $0.state == .idle }.count
    }

    /// 侧栏底部 tooltip 那句「订阅是否活着 / 最后更新时间」。
    ///
    /// 双语：三条文案都在 `ShellCopy`，这里只留一个按当前语言渲染的展口
    /// （显式语言那一份给用例用，测试进程读宿主系统语言不可靠）。
    var monitoringLabel: String { monitoringLabel(UILanguage.current) }

    func monitoringLabel(_ language: AppLanguage) -> String {
        if !isStreaming { return ShellCopy.subscriptionNotStarted.text(language) }
        guard let lastUpdateAt else { return ShellCopy.waitingForLiveEvents.text(language) }
        return ShellCopy.lastUpdatedFormat.format(language, DateFormat.time(lastUpdateAt))
    }

    // MARK: 生命周期

    /// 长驻入口：先取一次快照，随后消费增量流。
    /// 由 `ObservatoryRootView` 在 `.task` 中调用，随视图消失被取消。
    func start() async {
        errorMessage = nil
        engineState = await runtime.updates.currentState()
        await refreshSnapshot()

        isStreaming = true
        defer { isStreaming = false }

        for await update in runtime.updates.makeUpdateStream() {
            if Task.isCancelled { break }
            ingest(update)
        }
    }

    /// 拉取一次引擎状态与活跃 Agent 快照。
    func refreshSnapshot() async {
        do {
            let agents = try await runtime.service.activeAgents()
            activeAgents = Self.sortedByCPU(Array(agents.prefix(Self.maxRetainedAgents)))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 触发一次立即重新扫描。
    ///
    /// ⚠️ 这里在 `rescanNow()` 之后**多拉一次快照**，只是为了让工具栏那个转圈停得干脆
    /// （按钮自己持有 `isRescanning`）。它**不代表**「观测」菜单里那条 ⇧⌘R 也这么做——
    /// 菜单那条只调 `controller.rescanNow()`，总控在 ICR-0005 的回执里明确**不补**这次重拉，
    /// 理由是语义单一优先于手感。别拿这一行当依据去给菜单项加活。
    /// 实况：`rescanNow()` = `runTick()`，一个 tick 结束会无条件广播 `.agents`，
    /// 所以菜单那条最多晚一个 tick（默认 3 s）看到新 Agent，不会停在旧数据上。
    func rescan() async {
        guard !isRescanning else { return }
        isRescanning = true
        defer { isRescanning = false }
        await runtime.controller.rescanNow()
        await refreshSnapshot()
    }

    /// 启停观测引擎（采集开关）。
    func toggleEngine() async {
        if isCollecting {
            await runtime.controller.stop()
            engineState = .stopped
        } else {
            engineState = .starting
            await runtime.controller.start()
            engineState = await runtime.updates.currentState()
        }
        await refreshSnapshot()
    }

    /// 跳转到某个板块（不带条件的那一种：侧栏那九行本来就是纯路由）。
    public func select(_ section: SidebarSection) {
        selection = section
    }

    /// #81：发起一次**带条件的跳转**——界面上任何一个数 / 任何一行记录走这里去详情。
    ///
    /// 三条动作都在这一个函数里，就是为了不给第二条路径：
    ///   ① 意图带了时间区间 ⇒ 先写全局那一份 `timeRange`。目标页的加载任务是
    ///      `.task(id: shell?.timeRange)`，它在**同一次渲染**里读到新值，于是这一跳
    ///      不多发一条查询（另开一条 `pendingTimeRange` 就会多一条 `.task`，见该文件头）。
    ///   ② 存意图，交给目标板块在第一次取数之前 `seed` 进自己那条 `*Query`。
    ///   ③ 换 selection。顺序在 ② 之后：目标视图挂上时读到的必须已经是那条意图。
    /// 这里**不取数**（§6：跳转不是新的每 tick 成本）。
    ///
    /// `public` 的两个消费者：① 各板块/详情面板的取证出口（UI 内部调用，走得到就够），
    /// ② 冻结区 `AIObservatoryApp/RiskNotifications.swift` 里「点了那条高危通知」那一个写入点
    /// —— 它原来走的是 `pendingRiskEventID` 那个兼容壳，#81(b) 把它收进这座桥之后壳删干净，
    /// 跨页跳转从此**只有这一条路**。
    /// App 侧那条意图由 `JumpIntent.locating(target:eventID:)` 造（`JumpIntent` 的成员式 `init`
    /// 是 internal —— 它带的那一维 `ObservatoryTimeRange` 在设计系统里，不随 `jump` 一起出门）。
    public func jump(_ intent: JumpIntent) {
        if let range = intent.timeRange, range != timeRange {
            timeRange = range
        }
        pendingJump = intent
        selection = intent.target
    }

    // MARK: 增量合并

    private func ingest(_ update: ObservatoryUpdate) {
        lastUpdateAt = Date()
        switch update {
        case .agents(let list):
            activeAgents = Self.sortedByCPU(Array(list.prefix(Self.maxRetainedAgents)))

        case .engineState(let state):
            engineState = state

        case .timelineEvent, .sessions, .fileChange, .command, .performance, .risk, .dashboard:
            // 明细数据由各板块自行订阅，外壳不重复持有。
            break
        }
    }

    private static func sortedByCPU(_ agents: [AgentInstance]) -> [AgentInstance] {
        agents.sorted { lhs, rhs in
            if lhs.state == rhs.state { return lhs.cpuPercent > rhs.cpuPercent }
            return lhs.state.rank < rhs.state.rank
        }
    }
}

// MARK: - AgentRunState ordering

private extension AgentRunState {
    /// running 优先于 idle 优先于 terminated。
    var rank: Int {
        switch self {
        case .running:     return 0
        case .idle:        return 1
        case .terminated:  return 2
        }
    }
}
