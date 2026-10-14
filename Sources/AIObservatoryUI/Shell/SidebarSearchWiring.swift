//
//  SidebarSearchWiring.swift
//  AIObservatoryUI / Shell
//
//  Owner: ws/wiring（#74 侧栏搜索接线）
//  ─────────────────────────────────────────────────────────
//  侧栏那一个 `.searchable` 输入框与各板块查询之间的**唯一**一座桥。
//
//  为什么要有这座桥：#74 之前 `ShellModel.searchText` 全仓零读取者——界面上摆着一个
//  搜索框，它却不参与任何一次查询（「界面在说谎」那一族里最直白的一格）。各板块**自己的**
//  过滤条一直是真下推的（`SwiftDataObservatoryStore+Queries` 那一路），所以缺的不是
//  「搜索能力」，而是「外壳那一个框 → 当前板块查询」这条线。三条语义（台账裁定 11）
//  在这里各落成一个函数：
//    ① `seed`：进板块、第一次加载**之前**把侧栏词落进查询 ⇒ 首屏那次查询就是筛过的，
//              不会先画一屏没筛的结果再跳一下；也不会「侧栏一个查询 + 本页一个查询」各发一次。
//    ② `push`：侧栏改词 ⇒ 防抖后交给板块走**真查询**（落进 `*Query.searchText` 再由
//              Store 执行），不是把已加载的本地数组再筛一遍。
//    ③ `pull`：板块自己的过滤条改词 ⇒ 侧栏显示同一个词。
//
//  为什么是协议而不是在每个视图里各写一遍：九个板块的查询类型互不相同
//  （`EventQuery` / `SessionQuery` / `FileChangeQuery` / 项目地图那格是本地条件），
//  视图里手写等于把「什么时候该重查、什么时候不该」这条判断复制四份，第四份必然漂移。
//  板块侧只交出三个把手（读当前词 / 只落词 / 落词并重查），**判断只在这一个文件里**。
//
//  性能（AGENTS.md §6）：`push` 挂在视图的 `.task(id: shell.searchText)` 上，只在用户
//  改词那一刻跑一次性延时（`.task(id:)` 会自动取消上一次等待，连打只有一个查询落地）。
//  不长驻、不轮询、不新增每 tick 取数；两侧词相等时直接返回，连查询都不发。
//
//  不做的事（本波口径）：不重做板块自己那条过滤条、不给 `projects()` 加查询参数
//  （那要动 Store ⇒ 交总控立项，见文件底部对 Projects 那一格的如实说明）。
//

import Foundation
import Observation
import AIObservatoryCore

// MARK: - 板块侧把手

/// 一个板块对「侧栏搜索词」交出的三个把手。
///
/// 名字一律带 `sidebar`：板块**自己的**过滤条走的是它原有的 `setSearchText` 那一路，
/// 本协议不替换它，只是外壳那个框的入口。
@MainActor protocol SidebarSearchTarget: AnyObject {
    /// 本板块当前生效的搜索词——也就是它构造 `*Query.searchText` 用的那一个值。
    var sidebarSearchTerm: String { get }

    /// 只落词、不重查：进板块那一次由本页自己的加载链路把这个词一起带走。
    func seedSidebarSearchTerm(_ term: String)

    /// 落词并走板块的**真查询**。词没变时不许发查询（下面六个实现都靠各板块既有的 guard，
    /// 或靠本页那条 `.task(id: filterToken)` 自己重查）。
    func applySidebarSearchTerm(_ term: String) async
}

extension TimelineModel: SidebarSearchTarget {
    var sidebarSearchTerm: String { query.searchText }
    func seedSidebarSearchTerm(_ term: String) { query.searchText = term }
    func applySidebarSearchTerm(_ term: String) async { await setSearchText(term) }
}

extension SessionsModel: SidebarSearchTarget {
    var sidebarSearchTerm: String { query.searchText }
    func seedSidebarSearchTerm(_ term: String) { query.searchText = term }
    func applySidebarSearchTerm(_ term: String) async { await setSearchText(term) }
}

extension FilesModel: SidebarSearchTarget {
    var sidebarSearchTerm: String { query.searchText }
    func seedSidebarSearchTerm(_ term: String) { query.searchText = term }
    func applySidebarSearchTerm(_ term: String) async { await setSearchText(term) }
}

/// 项目地图那一格：**本地过滤**，见文件底部「Projects 那一格的如实说明」。
extension ProjectsModel: SidebarSearchTarget {
    var sidebarSearchTerm: String { searchText }
    func seedSidebarSearchTerm(_ term: String) { searchText = term }
    func applySidebarSearchTerm(_ term: String) async { searchText = term }
}

/// 命令审计那一格（#74 收口时差的那三行里的一行；文件面原来归 `ws/trust`，现已放行）。
/// 落点仍然是 `CommandQuery.searchText`（`Contracts/Queries.swift:169` 早就有这一字段），
/// 重查走本页既有的 `setSearchText` —— 它自带「词没变就不发查询」那道 guard。
extension CommandsModel: SidebarSearchTarget {
    var sidebarSearchTerm: String { criteria.searchText }
    func seedSidebarSearchTerm(_ term: String) { criteria.searchText = term }
    func applySidebarSearchTerm(_ term: String) async { await setSearchText(term) }
}

/// 风险那一格（同上）。`SecurityModel` 没有 `setSearchText` 那一步：它的重查由视图里
/// `.task(id: model.filterToken)` 驱动，而 `filterToken` 里就含 `query.searchText`
/// （`SecurityModel.swift:93`）⇒ 「落词」本身就是「让本页带着新词去发那条 `RiskQuery`」，
/// 在这里再手写一次 `load()` 只会把一次改词变成两次取数。与 Projects 那一格同形。
extension SecurityModel: SidebarSearchTarget {
    var sidebarSearchTerm: String { query.searchText }
    func seedSidebarSearchTerm(_ term: String) { query.searchText = term }
    func applySidebarSearchTerm(_ term: String) async { query.searchText = term }
}

// MARK: - 桥

/// 侧栏 ↔ 板块 的三个动作。视图里只留三行调用，语义全在这里，用例钉的也是这里。
@MainActor enum SidebarSearchWiring {

    /// 侧栏改词的防抖时长：**与各板块过滤条那一条 `.task(id:)` 同值**（300 ms）。
    /// 抄两份数值的话，调手感时只会调快一边，另一边留下「同一个搜索框两种延迟」。
    static let debounce: Duration = .milliseconds(300)

    /// ① 进入板块：把侧栏当前词落进板块查询，**不**额外发查询。
    ///
    /// 调用点必须在本页那条加载 `.task` 里、`load()` 之前。词本来就相等时不写，
    /// 免得把 `@Observable` 的变更惊动一次（视图会跟着重算）。
    static func seed(fromShell shell: ShellModel?, into target: SidebarSearchTarget) {
        guard let shell else { return }
        let term = shell.searchQueryTerm
        guard term != target.sidebarSearchTerm else { return }
        target.seedSidebarSearchTerm(term)
    }

    /// ② 侧栏改词：防抖之后把有效词交给板块，由板块走真查询。
    ///
    /// 两次「比了再走」是刻意的：
    ///   · 进/改那一刻先比一次，相等直接返回 ⇒ 与 ① 的播种重复时不多发一次查询；
    ///   · 睡完 300 ms 再比一次 ⇒ 这段窗口里可能已经发生别的路径落词
    ///     （板块自己那条 `.task` 已把同一个词推给 `setSearchText`、或本页重置），
    ///     那时再发一次查询就是纯重复。
    static func push(fromShell shell: ShellModel?, into target: SidebarSearchTarget) async {
        guard let shell else { return }
        guard shell.searchQueryTerm != target.sidebarSearchTerm else { return }
        try? await Task.sleep(for: debounce)
        guard !Task.isCancelled else { return }
        let term = shell.searchQueryTerm
        guard term != target.sidebarSearchTerm else { return }
        await target.applySidebarSearchTerm(term)
    }

    /// ③ 板块改词：让侧栏显示同一个词（「只差空白就不动」那条判定在 `ShellModel` 里）。
    static func pull(queryTerm: String, into shell: ShellModel?) {
        shell?.adoptSectionSearchTerm(queryTerm)
    }
}

// MARK: - Projects 那一格的如实说明（本波可接受，是否立项交总控判）
//
// 项目名列表这一格是**本地过滤**：`ProjectsModel.load()` 走的是
// `runtime.service.projects()`（`ObservatoryService` 冻结签名，**没有**查询参数），
// 拿回全量项目之后由 `ProjectsFilterSupport.passesFilters(_:)` 在 Swift 侧按
// 项目名 / 路径 / Agent 条件筛。所以侧栏词进到这里改的是 `model.searchText`，
// 列表跟着本地收窄，**不产生一次 SQL**。
//
// 为什么本波这样收：要把它变成真下推就得给 `projects()` 加查询参数 ⇒ 动
// `Contracts/ServiceProtocols.swift` + Store 两条后端 + 它们的对拍用例，
// 那是 §3 冻结区、也不在 #74 的文件面里。
//
// 这一格并不是「完全没下推」：详情面板的「最近变更」走的是 `FileChangeQuery`，
// `ProjectsModel.loadRecentChanges()` 已经把同一个 `searchText` 塞进了那条真查询。
// 差的那一条 SQL 只在项目列表本身。
