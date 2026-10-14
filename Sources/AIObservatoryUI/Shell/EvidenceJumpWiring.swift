//
//  EvidenceJumpWiring.swift
//  AIObservatoryUI / Shell
//
//  Owner: ws/trace（#81 概览 → 证据的完整路径）
//  ─────────────────────────────────────────────────────────
//  一条**泛化的跳转意图**（`JumpIntent`）与它到各板块查询之间的那座桥。
//
//  为什么要有这座桥（现场事实，台账第六节「T」段）：`*Query` 五族的字段**早就齐备**
//  （`Contracts/Queries.swift` 的 `projectPath` / `sessionID` / `kinds` / `dateRange`），
//  但**没有一条 UI 路径能把条件带过去**：各板块 `init(runtime:)` 不收外部条件，跨页按钮
//  只改 `shell.selection`。结果就是「界面上那个数点进详情，结果集根本没被筛小」——
//  用户看到的是全量列表，读成的却是「这一条的证据」。
//
//  形状照抄 `SidebarSearchWiring`（裁定 11 已建立的既有模式，**不另起第二套**）：
//    ① `seed`：进板块、第一次取数**之前**把条件落进本页那条 `*Query` ⇒ 首屏那一次查询
//              就是筛过的，不会先画一屏未筛的再跳一下，也不会「外壳一条 + 本页一条」各发一次。
//    ② `push`：已经停在本页时又来了一条意图（同页跳转，例如详情里「只看这一类事件」）
//              ⇒ 落条件并走**真查询**（Store 侧 SQL 收窄），不是把已加载的数组再本地筛一遍。
//    ③ `clear`：把这一跳带来的三项条件撤掉，时间区间回到全局那一格。
//
//  与搜索那座桥的一处差别（有意为之，不是漏了第 ③ 条腿）：跳转条件**落地即从外壳消费**，
//  承重真相只有目标页自己那条 `*Query`。所以这里没有「板块 → 外壳」的反向 `pull`——
//  再加一份外壳状态就是第二个出处，第二个出处必然分叉（本仓头号缺陷族）。
//  界面上「这一屏带着跳转条件」那一格读的是 `carriedJumpConditions`，也就是 query 本身。
//
//  时间区间为什么走 `ShellModel.timeRange` 这个**既有**把手（`jump(_:)` 里顺手写它），
//  而不是在桥里另开一条：四页的加载任务本来就是 `.task(id: shell?.timeRange)`，
//  写全局那一份等于让页头的时间选择器、本页模型、外壳三处同时跟着变，且**不多发一条查询**。
//  桥里再存一份区间就会多一条 `.task(id:)` —— 一次跳转两次取数，正是 §6 明令禁止的形状。
//
//  性能（AGENTS.md §6）：`seed` 只写字段、不发查询；`push` 只在「意图真的换了」那一刻跑一次；
//  不长驻、不轮询、不新增每 tick 取数。意图相等时一条查询都不发。
//
//  九页里本轮收完的六页：Timeline / Sessions / Files / Projects / Commands / Security。
//  仍然缺的那两格：`Dashboard/**` 各区块的跳转按钮（车道 `ws/summary` 在飞，文件面互斥），
//  以及 Performance / Settings / 侧栏本身（它们没有"带条件过去"的语义，也不该硬造）。
//  `#59` 那条只带一个风险 id 的例外**已经收干净**：`ShellModel.pendingRiskEventID` 那个兼容壳
//  删了（不留兼容层，项目纪律「能直改就不加 flag」），冻结区 `RiskNotifications.swift` 那一个
//  写入点现在直接 `shell.jump(.locating(target: .security, eventID: id))`；
//  读取端在 `SecurityModel.focusJumpRow`（与其它页同一扇门）。跨页跳转从此只有这一条路，
//  「存一个 id + 换一页」那种两句式状态不再有第二个出处。
//
//  两类条件在这两页收不下过，是契约决定的、不是没做完 —— 其中一条已经在 #81(a) 里补上了：
//  `CommandQuery` 与 `RiskQuery` 现在**都有** `projectPath` 字段（命令侧走 `commands.project_path`
//  那一列，风险侧走「风险 → 会话 → 项目」那条既有归属边），所以项目条件进得了这两页的真查询，
//  `carriedJumpConditions` 也读得回它（chip 说的还是「真带着的那几项」，一句不多）。
//  仍然收不下的只剩「事件种类」这一维：`CommandQuery` 与 `RiskQuery` 都没有 `kinds`，
//  风险的两维（`levels` / `categories`）与 `OperationKind` 不是一对一关系 ⇒ 这两页不假装带了种类。
//
//  顺带闭合的一处形状（#81(a) 的副产品）：`differsFromCarried` 比的是四项全量，
//  而这两页过去读不回 `projectPath`（恒 nil）⇒ 任何带项目的意图都**永远**被判成「与本页不同」，
//  「同一条件重复推 ⇒ 不重查」那条 §6 成本闸在这两页对 `projectPath` 恒不成立（不可达分支）。
//  字段接上之后它可达了，用例 `同一跳重复推` 钉的就是这一格。
//

import Foundation
import Observation
import SwiftUI
import AIObservatoryCore

// MARK: - 跳转意图

/// 一次「跳到证据」所带的四类条件。值类型：可比、可测、可被外壳原样交给地板块。
///
/// 【四类条件的落点】每一项都直接落到目标板块**自己那条** `*Query` 的既有字段上，
/// 再走各页已经下推真查询的那条链路（桥不新增取数路径）：
///   · `projectPath` → `SessionQuery.projectPath` / `EventQuery.projectPath` /
///     `FileChangeQuery.projectPath` / `CommandQuery.projectPath` / `RiskQuery.projectPath`
///     （后两条 #81(a) 补上：命令页走 `commands.project_path`，风险页走「风险 → 会话 → 项目」
///     那条归属边）；Projects 那一格 = 选中这个项目（它的详情那条
///     `projectActivity(path:dateRange:)` 与「最近变更」的 `FileChangeQuery` 都带着它）。
///   · `sessionID`   → `EventQuery.sessionID` / `FileChangeQuery.sessionID`；
///     `SessionQuery` **没有**这个字段（它按项目/时间筛），所以会话页收到它是「选中那一条」，
///     属于「定位」而不是「筛小」—— 用例把这两种语义分开钉，不许混着报。
///   · `eventKinds`  → `EventQuery.kinds`；文件页按同一族语义映射成 `FileChangeQuery.kinds`
///     （只有文件那四类操作类型在文件页有对应项，其余种类在文件页没有可落字段 ⇒ 不带过去）。
///   · `timeRange`   → 各页 `timeRange` → `query.dateRange`（六档，与页头那把尺同一个出处）。
///
/// 【nil 与空的分别】`projectPath` / `sessionID` / `eventKinds` 用「有没有值」表达
/// 「这一跳有没有这个条件」，所以它们是**权威**的：意图说没有，目标页就该把上一跳
/// 留下的那一条撤掉。`timeRange == nil` 是「这一跳对时间没意见」，目标页保持原样。
public struct JumpIntent: Hashable {

    /// 目的地板块。意图按它路由：不是这一页的意图，这一页一行代码都不动。
    var target: SidebarSection

    /// ① 项目路径。
    var projectPath: String?
    /// ② 会话 id。
    var sessionID: UUID?
    /// ③ 事件种类（空集合 = 这一跳不限制种类）。
    var eventKinds: Set<OperationKind> = []
    /// ④ 时间区间（`nil` = 不表态，见类型注释）。
    var timeRange: ObservatoryTimeRange?
    /// 定位到某一条记录（时间线那一条事件 / 风险那一条事件）。
    /// 它**不是**筛小结果集的条件，是「打开哪一行的详情」，所以不进 `carriedJumpConditions`。
    /// #59 的 `pendingRiskEventID` 收编到这一个字段上。
    var eventID: UUID?

    /// 成员式构造口（**只给 UI 内部**：各板块的取证出口要能带时间区间，而那个类型是 internal 的）。
    /// 默认值与上面各字段的「这一跳没带这一项」逐字同义：可选字段 `nil`、种类空集合、区间不表态。
    ///
    /// 为什么它不是 `public`（跨模块那一个写入点用下面 `locating(target:eventID:)`）：
    /// `timeRange:` 的参数类型 `ObservatoryTimeRange` 声明在 `DesignSystem/**`，是 internal 的
    /// ⇒ `public init` 直接编译失败（emit-module 报 "initializer cannot be declared public
    /// because its parameter uses an internal type"）。两条出路里：
    ///   · 把 `ObservatoryTimeRange` 升 `public` —— 那是把**设计系统的时间档整把尺**交出去当跨模块
    ///     射程（它挂着页头那把尺的显示语义），而车道 `ws/consistency` 正在改那个目录；
    ///   · 把消费者真正需要的那两项单独开一只工厂 —— 两项的类型本来就都是 `public`
    ///     （`SidebarSection` / `UUID`），一个 internal 类型都没进签名。
    /// 取后一条：跨模块可见性只多这一只工厂，`DesignSystem/**` 与 `Contracts/**` 的射程一个字没动。
    init(
        target: SidebarSection,
        projectPath: String? = nil,
        sessionID: UUID? = nil,
        eventKinds: Set<OperationKind> = [],
        timeRange: ObservatoryTimeRange? = nil,
        eventID: UUID? = nil
    ) {
        self.target = target
        self.projectPath = projectPath
        self.sessionID = sessionID
        self.eventKinds = eventKinds
        self.timeRange = timeRange
        self.eventID = eventID
    }

    /// 只去目的地、不带任何条件的那一种（等价于过去的「只改 selection」，仍然合法：
    /// 有些跳转本来就没有条件可带，比如侧栏那九行）。
    static func board(_ target: SidebarSection) -> JumpIntent {
        JumpIntent(target: target)
    }

    /// 跨模块那一个写入点的构造口（#59 → #81(b)：点了那条高危通知 ⇒
    /// `shell.jump(.locating(target: .security, eventID: id))`）。
    ///
    /// 语义 = 「去这一页，打开这一条记录」：目的地与 `eventID` 都是「定位」，
    /// 不是筛选条件（`eventID` 不进 `carriedJumpConditions`，见上面那一条字段注释）⇒
    /// 通知点进来列表不该被筛小。时间区间这里**不表态**（`nil`）：通知说的是"就这么一条"，
    /// 页头那把尺说什么就是什么，跨模块这一路不改全局时间。
    /// 签名里没有任何 internal 类型，所以它可以 `public`（可见性只到这一只工厂）；
    /// 反过来成员式 `init` 收回 `internal`——它带着 `timeRange:`，那一维的类型在
    /// `DesignSystem/**` 里是 internal，升它等于把设计系统那把尺交给跨模块射程。
    public static func locating(target: SidebarSection, eventID: UUID) -> JumpIntent {
        JumpIntent(target: target, eventID: eventID)
    }

    /// 这一跳有没有真的带条件（决定页面上那一格要不要出现）。
    var carriesConditions: Bool {
        projectPath != nil || sessionID != nil || !eventKinds.isEmpty || timeRange != nil
    }
}

// MARK: - 板块侧把手

/// 一个板块对「跳转意图」交出的把手。与 `SidebarSearchTarget` 同形：
/// 板块只交出「读回生效条件 / 只落条件 / 落条件并重查 / 定位一行」四个把手，
/// **判断（该不该落、什么时候消费）只在这一个文件里**。
@MainActor protocol EvidenceJumpTarget: AnyObject {

    /// 这一格是哪个板块（意图按它路由）。
    var jumpTargetSection: SidebarSection { get }

    /// 本页**当前生效**的跳转条件：一律从自己那条 `*Query`（以及页头那把时间尺）读回来。
    /// 不许另存一份「我被告知过什么」——那就是第二个真相。
    var carriedJumpConditions: JumpIntent { get }

    /// 只落条件、**不**重查：进板块那一次由本页自己的加载链路把这些条件一起带走。
    func seedJumpConditions(_ intent: JumpIntent)

    /// 落条件并走板块的**真查询**（已在本页时来了一条新意图）。
    func applyJumpConditions(_ intent: JumpIntent) async

    /// 把「打开哪一行」落进本页。默认什么都不做：不是每一页都有「选中一行」的形状，
    /// 而把空实现写四遍会让人以为这一格真的还没接。
    func focusJumpRow(_ intent: JumpIntent) async
}

extension EvidenceJumpTarget {
    func focusJumpRow(_ intent: JumpIntent) async {}
}

// MARK: - 桥

/// 外壳 ↔ 板块 的跳转动作。视图里只留两三行调用，语义全在这里，用例钉的也是这里。
@MainActor enum EvidenceJumpWiring {

    /// ① 进入板块：把待落地意图的条件落进本页查询，**不**发查询，并把这条意图消费掉。
    ///
    /// 调用点必须在本页那条加载 `.task` 里、`load()` 之前（与 `SidebarSearchWiring.seed`
    /// 并排，谁在前都行：两者写的是同一条 query 上互不相干的字段）。
    /// 返回被消费的意图，供取数之后交给 `focus(_:into:)` 落「打开哪一行」。
    /// 消费放在这一条而不是 `focus` 里：目标页的加载任务可能因为别的原因重跑
    /// （换时间档、点「重新加载」），那时条件早该落完了，留着一份待办反而会把旧条件
    /// 在用户已经自己改过之后再压一遍。
    @discardableResult
    static func seed(fromShell shell: ShellModel?, into target: EvidenceJumpTarget) -> JumpIntent? {
        guard let intent = pendingJump(fromShell: shell, for: target) else { return nil }
        target.seedJumpConditions(intent)
        shell?.pendingJump = nil
        return intent
    }

    /// ①b 取数之后落「打开哪一行」。没有要打开的行 ⇒ 一条查询都不发。
    static func focus(_ intent: JumpIntent?, into target: EvidenceJumpTarget) async {
        guard let intent else { return }
        await target.focusJumpRow(intent)
    }

    /// ② 已经停在本页时又来了一条意图 ⇒ 落条件、走真查询、再定位那一行。
    ///
    /// 与 ① 一样先比路由再动手，且**消费放在动手之前**：`applyJumpConditions` 里那条
    /// `await` 期间用户可能又点了别的入口，留着旧意图就是让它被晚一步的新意图覆盖之前
    /// 再触发一次重查。
    ///
    /// 「条件与本页已生效的那一份相等」只豁免**重查**（§6 成本闸），不豁免定位那一行：
    /// 只带 `eventID` 的意图（#59 那条高危通知）本来就不带任何筛选条件，
    /// 拿 `differsFromCarried` 一并挡掉它，等于「点了通知、页面上什么都没发生」——
    /// 收编之前那条路是 `SecurityView` 自己那一条 `.onChange` 在走，收编之后必须由桥自己认。
    static func push(fromShell shell: ShellModel?, into target: EvidenceJumpTarget) async {
        guard let intent = pendingJump(fromShell: shell, for: target) else { return }
        shell?.pendingJump = nil
        if differsFromCarried(intent, in: target) {
            await target.applyJumpConditions(intent)
        }
        await target.focusJumpRow(intent)
    }

    /// ③ 撤掉这一跳带来的条件：三项归到「没有」，时间区间回到全局那一格（页头显示什么就是什么）。
    ///
    /// 复用 ② 的同一条落地路径（`applyJumpConditions`），差别只在传进去的是**空意图**——
    /// 「清条件」与「带条件」因此不可能走出两套语义。
    static func clear(fromShell shell: ShellModel?, into target: EvidenceJumpTarget) async {
        var empty = JumpIntent.board(target.jumpTargetSection)
        empty.timeRange = shell?.timeRange
        await target.applyJumpConditions(empty)
        await target.focusJumpRow(empty)
    }

    // MARK: 路由与幂等

    /// 外壳里那条待落地意图，且**只有目的地是这一页时**才交出来。
    private static func pendingJump(fromShell shell: ShellModel?, for target: EvidenceJumpTarget) -> JumpIntent? {
        guard let intent = shell?.pendingJump, intent.target == target.jumpTargetSection else { return nil }
        return intent
    }

    /// 条件与本页已经生效的那一份完全相等 ⇒ 不重查（§6 成本闸）。
    /// 只比「这一跳会改的东西」：搜索词与 Agent 条件是各页自己的控件在管，不归跳转管。
    private static func differsFromCarried(_ intent: JumpIntent, in target: EvidenceJumpTarget) -> Bool {
        let carried = target.carriedJumpConditions
        return carried.projectPath != intent.projectPath
            || carried.sessionID != intent.sessionID
            || carried.eventKinds != intent.eventKinds
            || (intent.timeRange != nil && carried.timeRange != intent.timeRange)
    }
}

// MARK: - 各板块的 conformance（写在这里，与各页 Model 文件互不越界；与 `SidebarSearchWiring` 同一处置）

extension TimelineModel: EvidenceJumpTarget {
    var jumpTargetSection: SidebarSection { .timeline }

    var carriedJumpConditions: JumpIntent {
        var carried = JumpIntent.board(.timeline)
        carried.projectPath = query.projectPath
        carried.sessionID = query.sessionID
        carried.eventKinds = query.kinds
        carried.timeRange = timeRange
        return carried
    }

    func seedJumpConditions(_ intent: JumpIntent) {
        query.projectPath = intent.projectPath
        query.sessionID = intent.sessionID
        query.kinds = intent.eventKinds
        if let range = intent.timeRange { timeRange = range }
    }

    func applyJumpConditions(_ intent: JumpIntent) async {
        seedJumpConditions(intent)
        await applyFilters()
    }

    /// 时间线的「打开哪一行」= 详情栏（`.inspector`）跟着打开那条事件。
    /// 直接写 `selectedEventID` 而不是走 `select(_:)`：后者是**列表行的点击**语义，
    /// 再点同一条会被它的 toggle 判成取消，而跳转不是「再点一次」。
    func focusJumpRow(_ intent: JumpIntent) async {
        guard let eventID = intent.eventID else { return }
        selectedEventID = eventID
    }
}

extension SessionsModel: EvidenceJumpTarget {
    var jumpTargetSection: SidebarSection { .sessions }

    var carriedJumpConditions: JumpIntent {
        var carried = JumpIntent.board(.sessions)
        carried.projectPath = query.projectPath
        carried.timeRange = timeRange
        // `SessionQuery` 没有 `sessionID` 字段：会话页那一格是「选中那一条」，
        // 不是「把列表筛小」，所以这里不谎报一个生效的会话条件。
        return carried
    }

    func seedJumpConditions(_ intent: JumpIntent) {
        query.projectPath = intent.projectPath
        if let range = intent.timeRange { timeRange = range }
    }

    func applyJumpConditions(_ intent: JumpIntent) async {
        seedJumpConditions(intent)
        await applyFilters()
    }

    /// 走本页既有的 `select(_:)`：它同时负责拉那条会话的详情（命令 / 事件 / 变更清单），
    /// 「跳到会话就该看到那一条的详情」这件事没有第二条路径。
    func focusJumpRow(_ intent: JumpIntent) async {
        guard let sessionID = intent.sessionID else { return }
        await select(sessionID)
    }
}

extension FilesModel: EvidenceJumpTarget {
    var jumpTargetSection: SidebarSection { .files }

    var carriedJumpConditions: JumpIntent {
        var carried = JumpIntent.board(.files)
        carried.projectPath = query.projectPath
        carried.sessionID = query.sessionID
        carried.eventKinds = JumpIntent.operationKinds(forFileKinds: query.kinds)
        carried.timeRange = timeRange
        return carried
    }

    func seedJumpConditions(_ intent: JumpIntent) {
        query.projectPath = intent.projectPath
        query.sessionID = intent.sessionID
        query.kinds = JumpIntent.fileKinds(forOperationKinds: intent.eventKinds)
        if let range = intent.timeRange { timeRange = range }
    }

    func applyJumpConditions(_ intent: JumpIntent) async {
        seedJumpConditions(intent)
        await applyFilters()
    }
}

extension ProjectsModel: EvidenceJumpTarget {
    var jumpTargetSection: SidebarSection { .projects }

    var carriedJumpConditions: JumpIntent {
        var carried = JumpIntent.board(.projects)
        // 这一格的项目条件就是「选中了哪个项目」：详情面板那条 `projectActivity(path:dateRange:)`
        // 与「最近变更」的 `FileChangeQuery` 都带着它 ⇒ 它承重，不是又一份显示用状态。
        carried.projectPath = selectedPath
        // 会话与变更种类这一格只由「最近变更」那条 `FileChangeQuery` 承接
        // （`projects()` 是冻结签名，不收这两维），读回来与它构造查询用的是同一对字段。
        carried.sessionID = changesSessionID
        carried.eventKinds = JumpIntent.operationKinds(forFileKinds: changesKinds)
        carried.timeRange = timeRange
        return carried
    }

    func seedJumpConditions(_ intent: JumpIntent) {
        changesSessionID = intent.sessionID
        changesKinds = JumpIntent.fileKinds(forOperationKinds: intent.eventKinds)
        if let range = intent.timeRange { timeRange = range }
    }

    func applyJumpConditions(_ intent: JumpIntent) async {
        seedJumpConditions(intent)
        // 这一格读这三项的只有两条查询：详情的 `projectActivity(path:dateRange:)`
        // 与「最近变更」的 `FileChangeQuery`。项目列表本身不读 ⇒ 不重拉它（少一条查询，
        // 换不来任何正确性）。意图点名要换项目时也不在这里拉：
        // 紧随其后的 `focusJumpRow` 走 `select(path:)`，那一条路自己带齐详情 + 变更 + 健康度。
        if intent.projectPath == nil || intent.projectPath == selectedPath {
            await loadDetail()
            await loadRecentChanges()
        }
    }

    /// 项目这一格没有 `projectPath` 查询字段可播种，落地方式就是选中它。
    /// `load()` 末尾的 `ensureSelection()` 认这份选中（它只在「选中的还在列表里」时不动手），
    /// 所以顺序是 `load()` 之后 —— 与 `SidebarSearchWiring` 的「先播种再取数」不冲突，
    /// 因为这一格要筛小的不是项目列表本身，而是它带出去的那两条真查询。
    func focusJumpRow(_ intent: JumpIntent) async {
        guard let path = intent.projectPath else { return }
        await select(path: path)
    }
}

extension CommandsModel: EvidenceJumpTarget {
    var jumpTargetSection: SidebarSection { .commands }

    var carriedJumpConditions: JumpIntent {
        var carried = JumpIntent.board(.commands)
        carried.sessionID = criteria.sessionID
        carried.projectPath = criteria.projectPath
        carried.timeRange = timeRange
        // 这一格收得下三类条件：项目 / 会话 / 时间区间。事件种类仍收不下——
        // `CommandQuery` 没有 `kinds` 那一维（命令的操作类型只体现在 `outcome` / `destructiveOnly`，
        // 与 `OperationKind` 不是一对一关系，硬映射就是编条件）。
        // `criteria.projectPath` 是 #81(a) 补进来的那一条：`CommandQuery.projectPath` 现在有字段了，
        // 于是这里读回来的就是**真生效**的那一条命令查询里的项目条件（不是又一份显示状态）。
        return carried
    }

    func seedJumpConditions(_ intent: JumpIntent) {
        criteria.sessionID = intent.sessionID
        criteria.projectPath = intent.projectPath
        if let range = intent.timeRange { timeRange = range }
    }

    func applyJumpConditions(_ intent: JumpIntent) async {
        seedJumpConditions(intent)
        await applyFilters()
    }

    /// 「打开哪一条命令」：本页详情栏读的就是 `selectedID`。
    func focusJumpRow(_ intent: JumpIntent) async {
        guard let id = intent.eventID else { return }
        select(id)
    }
}

extension SecurityModel: EvidenceJumpTarget {
    var jumpTargetSection: SidebarSection { .security }

    var carriedJumpConditions: JumpIntent {
        var carried = JumpIntent.board(.security)
        carried.sessionID = query.sessionID
        carried.projectPath = query.projectPath
        carried.timeRange = range
        // 项目那一维（#81(a)）读的是本页那条真 `RiskQuery.projectPath`，口径 = 「风险 → 会话 → 项目」
        // 那条归属边（见 Contracts 与两侧 Store 的注释）。
        // 风险没有「操作种类」这一维（它自己的两维是 `levels` / `categories`，
        // 与 `OperationKind` 不是一对一关系，硬映射就是编条件）⇒ 那一格仍然不落、也不谎报。
        return carried
    }

    func seedJumpConditions(_ intent: JumpIntent) {
        query.sessionID = intent.sessionID
        query.projectPath = intent.projectPath
        if let range = intent.timeRange { self.range = range }
    }

    func applyJumpConditions(_ intent: JumpIntent) async {
        seedJumpConditions(intent)
        // `load()` 里那句 `query.dateRange = range.dateRange()` 是本页区间的唯一写入口，
        // 所以条件落完直接走它：不另开一条取数路径，也不多一条查询。
        await load()
    }

    /// #59 那条例外收进这里：高危通知点进来要打开的就是这一条风险事件。
    /// 通知对应的多是刚广播进来的新事件（已在 `events` 头部），找不到才重读一次兜底。
    func focusJumpRow(_ intent: JumpIntent) async {
        guard let eventID = intent.eventID else { return }
        if let hit = events.first(where: { $0.id == eventID }) {
            selected = hit
        } else {
            await load()
            selected = events.first(where: { $0.id == eventID })
        }
    }
}

// MARK: - 事件种类 ↔ 文件变更种类

extension JumpIntent {

    /// 时间线的操作类型 → 文件页的变更种类（**单值那一份，两份映射表只有这一个出处**）。
    ///
    /// 只映四个真有一对一关系的项：文件页没有「执行命令」「风险」这些种类，
    /// 把不存在的条件硬塞进去会得到一个恒假的过滤器（结果集凭空归零，比不筛更坏）。
    /// 所以映射不到时交出去的是 `nil`，调用方（diff 面板那颗按钮）**那颗根本不排**——
    /// 排了却悄悄少带一项，就回到「界面上那句话与实际操作不是一回事」。
    static func fileKind(forOperationKind kind: OperationKind) -> FileChangeKind? {
        switch kind {
        case .fileCreated: return .created
        case .fileModified: return .modified
        case .fileDeleted: return .deleted
        case .fileRenamed: return .renamed
        case .agentStarted, .agentStopped, .fileRead, .commandExecuted, .gitOperation,
             .networkRequest, .systemModification, .riskDetected, .unknown:
            return nil
        }
    }

    /// 集合版：逐值转调上面那一份。两份表分叉是在造第二个真相，而分叉点没人看得见。
    static func fileKinds(forOperationKinds kinds: Set<OperationKind>) -> Set<FileChangeKind> {
        Set(kinds.compactMap { fileKind(forOperationKind: $0) })
    }

    /// 反向那一份（单值）：文件页的一条变更 → 时间线的操作类型。
    /// 给 diff 面板那颗「在时间线看这一条」用，也让 `carriedJumpConditions` 与它读同一张表。
    static func operationKind(forFileKind kind: FileChangeKind) -> OperationKind? {
        switch kind {
        case .created: return .fileCreated
        case .modified: return .fileModified
        case .deleted: return .fileDeleted
        case .renamed: return .fileRenamed
        case .unknown: return nil
        }
    }

    /// 集合版同上，逐值转调单值那一份。
    static func operationKinds(forFileKinds kinds: Set<FileChangeKind>) -> Set<OperationKind> {
        Set(kinds.compactMap { operationKind(forFileKind: $0) })
    }
}

// MARK: - 页面上那一格：这一屏正带着跳转来的条件

/// 「条件已生效」的唯一显示口。
///
/// 为什么必须有它：#81 修的是「点一个数跳到详情、结果集其实没被筛小」。条件真筛小了而
/// 页面上**没有任何地方说它带着条件**，用户读到的仍然是「这就是全部」——那是同一个缺陷的
/// 另一半。所以这一格只读 `carriedJumpConditions`（也就是那条真 `*Query`），
/// 不读外壳里那条已经被消费掉的意图。
///
/// 键盘（验收第 4 条）：这颗「清除」是一个真的 `Button` ⇒ Tab 能走到、Return 能按下，
/// 并额外绑 `.keyboardShortcut(.cancelAction)`（macOS 上的 Esc），
/// 于是「带着条件进来 → 看清是哪几个条件 → 一键退回」整条路不用碰鼠标。
@MainActor struct EvidenceJumpChip: View {

    private let conditions: JumpIntent
    private let onClear: () async -> Void

    @MainActor init(conditions: JumpIntent, onClear: @escaping () async -> Void) {
        self.conditions = conditions
        self.onClear = onClear
    }

    var body: some View {
        // 没带条件时**不排格**：`未指定` 那一格只会把「这一屏是全量」这件事说成「好像出问题了」。
        if conditions.carriesConditions {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "arrow.up.forward.app")
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .accessibilityHidden(true)
                Text(ShellCopy.jumpConditionsLead.text(language))
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                ForEach(summaryItems, id: \.self) { item in
                    Tag(item, tone: .neutral, showsDot: false)
                }
                Button {
                    Task { await onClear() }
                } label: {
                    Text(ShellCopy.jumpConditionsClear.text(language))
                }
                // #11（只改这一颗长什么样，seed/push/clear 的语义一字未动）：
                // 原来没写样式 = `.automatic`，而 `.automatic` 在窗口 / 工具栏 / sheet
                // 三种容器里会长成三种样子——同一颗"清除"在别的容器里就可能变成无边框文字。
                // 显式写成系统 `.bordered`：它的悬停、按下、焦点三态由 OS 给，
                // 与全站其余系统控件同一份（本格自绘的那一档 `.axPressable` 只服务
                // "整块可点"那一族，见 `DesignSystem/InteractiveFeedback.swift`）。
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel(ShellCopy.jumpConditionsClear.text(language))
                .keyboardShortcut(.cancelAction)
                Spacer(minLength: Spacing.sm)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(ShellCopy.jumpConditionsGroup.text(language))
        }
    }

    /// 本项目语言（用例走下面的显式展口，不读宿主系统语言）。
    private var language: AppLanguage { UILanguage.current }

    /// 逐条列出生效的条件（按显式语言那一份，给用例留展口）。
    ///
    /// 两条口径：项目只报末段名字（与 `SessionsModel.filterSummaryText` 同一说法）；
    /// 事件种类只报条数而不报名字 —— 种类名还在 Contracts 里（中文、无语言入参，归 #82 那一格），
    /// 在页面上再抄一份英文种类名就是第二个出处，而第二个出处必然分叉。
    private func summaryItems(_ language: AppLanguage) -> [String] {
        var items: [String] = []
        if let project = conditions.projectPath, !project.isEmpty {
            items.append(ShellCopy.jumpConditionProject.format(language, (project as NSString).lastPathComponent))
        }
        if conditions.sessionID != nil {
            items.append(ShellCopy.jumpConditionSession.text(language))
        }
        if !conditions.eventKinds.isEmpty {
            items.append(ShellCopy.jumpConditionKinds.format(language, conditions.eventKinds.count))
        }
        if let range = conditions.timeRange {
            items.append(range.displayName(language))
        }
        return items
    }

    private var summaryItems: [String] { summaryItems(language) }
}
