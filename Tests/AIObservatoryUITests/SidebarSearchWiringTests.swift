//
//  SidebarSearchWiringTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/wiring（#74 侧栏搜索接线）
//  ─────────────────────────────────────────────────────────
//  钉的是台账裁定 11 那三条语义。写这批用例的理由很具体：
//  `shell.searchText` 原来全仓**零读取者**（界面上有个框，不参与任何查询），
//  而 `Tests/AIObservatoryUITests/` 对它一条用例都没有 ⇒ 把接线改坏也照样全绿。
//  所以这里刻意**不写**「输入框能打字」那一类用例——那一类当时也会全绿。
//  每条正向判据断的都是「侧栏那个词进到了 Model 构造出来、发给 Store 的那条 `*Query` 里」，
//  并且配一条只有真下推才成立的形状判据：
//    · `totalCount` 是**服务端**按整条 query 算出来的数，本地数组过滤动不了它；
//    · `changes` / `sessions` 这些行本身变少，也是本地过滤做不到的（那只会动 `visible*`）。
//  取数出口另配一个记账替身（`QueryRecordingService`），因为只看 `model.query` 只能证明
//  「字段被写了」，证明不了「发出去的那一条查询真的带着它」。
//
//  夹具路径一律合成 `/Users/dev/…`（AGENTS.md §0/§7）；文案一律 ASCII，
//  免得 `HardcodedChineseRatchetTests` 那类门禁把测试夹具算成存量。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

// MARK: - 夹具

/// 转发给内存实现、顺手把发出去的查询记下来的替身。
///
/// 只做两件事：转发 + 记账。任何过滤语义都不在这里复刻——那是 `InMemoryObservatoryService`
/// 的既有职责（它本身是「真实过滤/排序/分页实现」，见其文件头）。
actor QueryRecordingService: ObservatoryService {
    private let inner: InMemoryObservatoryService
    private(set) var sessionQueries: [SessionQuery] = []
    private(set) var eventQueries: [EventQuery] = []
    private(set) var fileQueries: [FileChangeQuery] = []
    // #81 收口：命令页与风险页也在这张记账表里了。这两格原来**根本不在账上** ⇒
    // 「侧栏那个词进没进 `CommandQuery`」「跳转条件进没进 `RiskQuery`」这两问
    // 只看 `model.query` 答不了（字段被写了不等于发出去的那条带着它），必须逐条记。
    private(set) var commandQueries: [CommandQuery] = []
    private(set) var riskQueries: [RiskQuery] = []
    private(set) var projectListCalls: Int = 0

    init(forwardingTo inner: InMemoryObservatoryService) {
        self.inner = inner
    }

    func dashboardStats(for date: Date) async throws -> DashboardStats {
        try await inner.dashboardStats(for: date)
    }

    func activeAgents() async throws -> [AgentInstance] {
        try await inner.activeAgents()
    }

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        sessionQueries.append(query)
        return try await inner.sessions(matching: query)
    }

    func session(id: UUID) async throws -> AgentSession? {
        try await inner.session(id: id)
    }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        eventQueries.append(query)
        return try await inner.events(matching: query)
    }

    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        fileQueries.append(query)
        return try await inner.fileChanges(matching: query)
    }

    func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        try await inner.fileDiff(for: changeID)
    }

    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        commandQueries.append(query)
        return try await inner.commands(matching: query)
    }

    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        try await inner.performanceSamples(sessionID: sessionID)
    }

    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        try await inner.systemPerformance(since: date)
    }

    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        riskQueries.append(query)
        return try await inner.riskEvents(matching: query)
    }

    func projects() async throws -> [ProjectActivity] {
        projectListCalls += 1
        return try await inner.projects()
    }

    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        try await inner.projectActivity(path: path, dateRange: dateRange)
    }
}

/// 三条时间线事件：只有第二条带 `engine.swift`，第三条与第二条同含 `swift`。
private let timelineEvents: [TimelineEvent] = [
    TimelineEvent(kind: .commandExecuted, title: "Run command",
                  command: "rm -rf /Users/dev/tmp/build"),
    TimelineEvent(kind: .fileModified, title: "Edit engine source",
                  filePath: "/Users/dev/alpha/Sources/engine.swift"),
    TimelineEvent(kind: .fileModified, title: "Edit app source",
                  filePath: "/Users/dev/alpha/Sources/App.swift"),
]

/// 三条会话：第一条标题里有 `engine`，后两条的项目路径都是 `/Users/dev/beta`。
private let seededSessions: [AgentSession] = [
    AgentSession(displayIndex: 201, kind: .claudeCode, title: "Fix engine crash",
                 projectPath: "/Users/dev/alpha", startedAt: Date()),
    AgentSession(displayIndex: 202, kind: .claudeCode, title: "Tidy tests",
                 projectPath: "/Users/dev/beta", startedAt: Date()),
    AgentSession(displayIndex: 203, kind: .openAICodex, title: "Update docs",
                 projectPath: "/Users/dev/beta", startedAt: Date()),
]

/// 三条文件变更：两条路径里有 `engine`，一条在 `/Users/dev/beta`。
private let seededFileChanges: [FileChange] = [
    FileChange(path: "/Users/dev/alpha/Sources/engine.swift", kind: .modified),
    FileChange(path: "/Users/dev/alpha/Tests/engineTests.swift", kind: .created),
    FileChange(path: "/Users/dev/beta/README.md", kind: .deleted),
]

/// 两个项目：Projects 那一格是**本地**按名字/路径筛（`projects()` 没有查询参数）。
private let seededProjects: [ProjectActivity] = [
    ProjectActivity(id: "/Users/dev/alpha", name: "alpha", path: "/Users/dev/alpha",
                    fileChangeCount: 2),
    ProjectActivity(id: "/Users/dev/beta", name: "beta", path: "/Users/dev/beta",
                    fileChangeCount: 1),
]

/// 三条命令：Store 侧的命令搜索口径是「`commandLine` 子串」（`commandLine` = 可执行文件 + 参数），
/// 只有第二条的 commit message 里带 `engine`，第一条带 `swift`，第三条带 `rm`。
/// ⇒ 词 `engine` → 1 条、`swift` → 1 条、`rm` → 1 条、`credential` → 0 条。
private let seededCommands: [CommandRecord] = [
    CommandRecord(executable: "swift", arguments: ["build", "--build-tests"],
                  outcome: .success),
    CommandRecord(executable: "git", arguments: ["commit", "-m", "engine-tweak"],
                  outcome: .success),
    CommandRecord(executable: "rm", arguments: ["-rf", "/Users/dev/tmp/build"],
                  outcome: .success, isDestructive: true),
]

/// 三条风险：风险页的搜索口径是「标题 + 详情 + 命令行」拼起来子串匹配。
/// ⇒ 词 `engine` → 1 条、`credential` → 1 条、`swift` → 0 条。
private let seededRisks: [RiskEvent] = [
    RiskEvent(level: .high, category: .dangerousCommand, title: "Delete build directory",
              command: "rm -rf /Users/dev/tmp/build"),
    RiskEvent(level: .medium, category: .systemFileModification,
              title: "Edit engine source out of band"),
    RiskEvent(level: .critical, category: .credentialExposure, title: "Read credential cache"),
]

/// 一套「外壳 + 板块」的同源运行时：`ShellModel` 与各板块模型读的是同一份服务，
/// 与 `ObservatoryRootView` 的装配形状一致（区别只在这里多了一层记账）。
@MainActor
private func makeStage() -> (shell: ShellModel, service: QueryRecordingService, host: InMemoryObservatoryService) {
    let host = InMemoryObservatoryService()
    host.seed(sessions: seededSessions, events: timelineEvents,
              fileChanges: seededFileChanges, commands: seededCommands, risks: seededRisks,
              projects: seededProjects)
    let recorder = QueryRecordingService(forwardingTo: host)
    let runtime = ObservatoryRuntime(service: recorder, controller: host, updates: host)
    return (ShellModel(runtime: runtime), recorder, host)
}

/// 板块模型共用的运行时（与 `makeStage` 同源的那份服务）。
@MainActor
private func runtime(host: InMemoryObservatoryService, service: QueryRecordingService) -> ObservatoryRuntime {
    ObservatoryRuntime(service: service, controller: host, updates: host)
}

@MainActor
@Suite("UI: #74 侧栏搜索接线（词真的进得了查询）", .timeLimit(.minutes(2)))
struct SidebarSearchWiringTests {

    // MARK: - ① 外壳那一条语义：有效查询词的归一与回填判据

    @Test("有效查询词：去首尾空白；全是空白 == 没在搜")
    func queryTermNormalisation() {
        let (shell, _, _) = makeStage()
        shell.searchText = ""
        #expect(shell.searchQueryTerm == "")
        shell.searchText = "   \n\t "
        #expect(shell.searchQueryTerm == "", "整格空白应当当成没搜，否则会发一条必然全空的查询")
        shell.searchText = "  engine.swift "
        #expect(shell.searchQueryTerm == "engine.swift")
        // 中间空白是语义的一部分（短语），不许被"归一"掉。
        shell.searchText = "rm  -rf"
        #expect(shell.searchQueryTerm == "rm  -rf")
    }

    @Test("板块改词回填侧栏：只差空白不动，真不同才动（裁定 11 第 2 条）")
    func sectionTermWritesBackOnlyWhenItReallyDiffers() {
        let (shell, _, _) = makeStage()

        // 用户在侧栏刚敲下尾随空格、还没打完：板块落的是去过空白的同一个词 ⇒ 不顶用户的手。
        shell.searchText = "engine "
        #expect(!shell.adoptSectionSearchTerm("engine"))
        #expect(shell.searchText == "engine ", "同一个词（只差空白）被改写 ⇒ 会把用户正在打的字吞掉")

        // 板块「重置」：词真的没了 ⇒ 侧栏必须跟着清空（否则侧栏还显示着一个不在查询里的词）。
        #expect(shell.adoptSectionSearchTerm(""))
        #expect(shell.searchText == "")

        // 板块过滤条换成另一个词 ⇒ 侧栏显示新词，且显示的是归一后的那一份。
        #expect(shell.adoptSectionSearchTerm("  beta  "))
        #expect(shell.searchText == "beta")

        // 同词再回填一次必须是幂等的：回填侧栏会惊动板块那条 `.task(id:)`，
        // 幂等断掉就是「一次改动被两个方向各推一遍」= 查询次数翻倍。
        #expect(!shell.adoptSectionSearchTerm("beta"))
        #expect(shell.searchText == "beta")
    }

    // MARK: - ② 下推进当前板块的真查询（三页各钉一条）

    @Test("时间线：进板块的第一次查询就带着侧栏词（seed 在 load 之前）")
    func timelineSeedReachesFirstQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.searchText = "engine.swift"

        SidebarSearchWiring.seed(fromShell: shell, into: model)
        #expect(model.query.searchText == "engine.swift")
        #expect(model.sidebarSearchTerm == "engine.swift")

        await model.load()
        let sent = await recorder.eventQueries
        #expect(sent.count == 1, "第一次进板块只该发一条查询，实际 \(sent.count) 条")
        #expect(sent[0].searchText == "engine.swift", "发出去的 EventQuery 没带上侧栏词 ⇒ 这条线又断了")
        // 只有真下推才动得了服务端总数：本地数组过滤会留下 totalCount == 3。
        #expect(model.totalCount == 1, "三条事件里只有 engine.swift 那条命中；总数仍是 3 就是没下推")
        #expect(model.events.map(\.title) == ["Edit engine source"])
    }

    @Test("时间线：侧栏改词 ⇒ 重查，服务端总数从 3 收到 2")
    func timelinePushOnSidebarChange() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        SidebarSearchWiring.seed(fromShell: shell, into: model)
        await model.load()
        #expect(model.totalCount == 3)

        shell.searchText = "swift"
        await SidebarSearchWiring.push(fromShell: shell, into: model)
        #expect(model.query.searchText == "swift")
        #expect(model.totalCount == 2, "两条 Sources/*.swift 命中；App.swift 那条也在内")
        #expect(model.events.map(\.title).sorted() == ["Edit app source", "Edit engine source"])
        let sent = await recorder.eventQueries
        #expect(sent.count == 2, "一次改词应当只多一条查询，实际发了 \(sent.count) 条")
        #expect(sent.last?.searchText == "swift")

        // 换成一个必然搜不到的词：服务端总数归零，界面才会走「被筛空」那一支。
        shell.searchText = "nothing-matches-this"
        await SidebarSearchWiring.push(fromShell: shell, into: model)
        #expect(model.totalCount == 0)
        #expect(model.events.isEmpty)
    }

    @Test("会话页：同一个词进 SessionQuery.searchText，服务端总数 = 1")
    func sessionsPushReachesQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = SessionsModel(runtime: runtime(host: host, service: recorder))
        model.timeRange = .all
        shell.searchText = "engine"

        SidebarSearchWiring.seed(fromShell: shell, into: model)
        #expect(model.query.searchText == "engine")
        await model.load()
        let sent = await recorder.sessionQueries
        #expect(sent.count == 1)
        #expect(sent[0].searchText == "engine")
        #expect(model.totalCount == 1, "只有标题带 engine 的那条会话命中")
        #expect(model.sessions.map(\.displayIndex) == [201])
    }

    @Test("文件页：行本身变少（本地过滤只能让 visibleChanges 变少，动不了 changes）")
    func filesPushIsNotLocalFiltering() async {
        let (shell, recorder, host) = makeStage()
        let model = FilesModel(runtime: runtime(host: host, service: recorder))
        shell.searchText = "engine"

        SidebarSearchWiring.seed(fromShell: shell, into: model)
        #expect(model.query.searchText == "engine")
        await model.load()
        let sent = await recorder.fileQueries
        #expect(sent.count == 1)
        #expect(sent[0].searchText == "engine")
        #expect(model.totalCount == 2)
        // ⚠️ 断的是 `changes`（服务端回来的行）而不是 `visibleChanges`：
        // 后者是本地二次筛，把接线整条删掉它也可能给出同一个数。
        // 行序按时间戳（夹具是同秒建的），所以只断集合与条数，不赌顺序。
        #expect(model.changes.count == 2)
        #expect(Set(model.changes.map(\.path)) == Set([
            "/Users/dev/alpha/Sources/engine.swift",
            "/Users/dev/alpha/Tests/engineTests.swift",
        ]))
    }

    // MARK: - ③ 切板块保留并继续下推（裁定 11 第 3 条）

    @Test("切换板块：词不清空，新板块的第一次查询继续带着它")
    func termSurvivesSectionSwitch() async {
        let (shell, recorder, host) = makeStage()
        shell.searchText = "engine"

        // 「时间线」
        let timeline = TimelineModel(runtime: runtime(host: host, service: recorder))
        SidebarSearchWiring.seed(fromShell: shell, into: timeline)
        await timeline.load()
        #expect(timeline.totalCount == 1)

        // 切到「会话」——新板块新模型，词必须还在，而且照样下推
        let sessions = SessionsModel(runtime: runtime(host: host, service: recorder))
        sessions.timeRange = .all
        SidebarSearchWiring.seed(fromShell: shell, into: sessions)
        await sessions.load()
        #expect(sessions.query.searchText == "engine")
        #expect(sessions.totalCount == 1)

        // 再切到「文件」
        let files = FilesModel(runtime: runtime(host: host, service: recorder))
        SidebarSearchWiring.seed(fromShell: shell, into: files)
        await files.load()
        #expect(files.query.searchText == "engine")
        #expect(files.totalCount == 2)

        // 侧栏那个词在这一路里既没被清空也没被某一页改写（三页命中数不同 ≠ 词不同）
        #expect(shell.searchText == "engine")
        // `engine` 命中的那条事件标题里没有 "engine"？有（Edit engine source）。
        // 会话详情那一路也会发 `events(matching:)`，但它的 searchText 是空的 ⇒ 只数带词的那条。
        let sentEvents = await recorder.eventQueries.filter { $0.searchText == "engine" }
        #expect(sentEvents.count == 1)
    }

    // MARK: - ④ 板块 ↔ 侧栏 的反向那条

    @Test("板块过滤条改词 / 重置 ⇒ 侧栏显示同一个词（两把尺子量不出两个答案）")
    func sectionBarChangeReflectsInSidebar() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        SidebarSearchWiring.seed(fromShell: shell, into: model)

        await model.setSearchText("beta")
        SidebarSearchWiring.pull(queryTerm: model.query.searchText, into: shell)
        #expect(shell.searchText == "beta")
        #expect(shell.searchQueryTerm == "beta")

        await model.resetFilters()
        SidebarSearchWiring.pull(queryTerm: model.query.searchText, into: shell)
        #expect(shell.searchText == "", "板块已经把词清了，侧栏还挂着 beta ⇒ 界面在说谎")
    }

    @Test("相等不重查：反复 seed / push 同一个词，一条查询都不发（§6 成本闸）")
    func idempotentPushSendsNoQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = FilesModel(runtime: runtime(host: host, service: recorder))
        shell.searchText = "engine"

        SidebarSearchWiring.seed(fromShell: shell, into: model)
        SidebarSearchWiring.seed(fromShell: shell, into: model)
        await SidebarSearchWiring.push(fromShell: shell, into: model)
        await SidebarSearchWiring.push(fromShell: shell, into: model)
        // 回填侧栏也一样：同一个词第二次回填不许改侧栏（改了就会再惊动板块那条 `.task`）。
        SidebarSearchWiring.pull(queryTerm: model.query.searchText, into: shell)
        SidebarSearchWiring.pull(queryTerm: model.query.searchText, into: shell)

        #expect(model.query.searchText == "engine")
        #expect(shell.searchText == "engine")
        let sent = await recorder.fileQueries
        #expect(sent.isEmpty, "词没变却发了查询：\(sent.count) 条。接线不许靠重查来确认")
    }

    // MARK: - ⑤ Projects 那一格：本地过滤，如实钉住现状

    @Test("Projects：侧栏词进的是本地过滤（projects() 无查询参数），但详情那一路是真查询")
    func projectsCellIsHonestAboutLocalFiltering() async {
        let (shell, recorder, host) = makeStage()
        let model = ProjectsModel(runtime: runtime(host: host, service: recorder))
        shell.searchText = "alpha"

        SidebarSearchWiring.seed(fromShell: shell, into: model)
        #expect(model.searchText == "alpha")
        await model.load()

        // 列表这一格是 Swift 侧筛的：服务端仍然返回全量两条 ⇒ `projects()` 一条查询里
        // 根本没有搜索参数可带（`ObservatoryService.projects()` 是冻结签名，加参数要动 Store）。
        #expect(model.projects.count == 2, "本地过滤不该让服务端返回变少——变少了才是假话")
        #expect(model.filteredProjects.map(\.name) == ["alpha"])
        let calls = await recorder.projectListCalls
        #expect(calls == 1, "换词不该重拉整张项目地图（每加一个字多一条全量查询）")

        // 同一条词在**有查询参数**的那一路是真下推的：详情面板的「最近变更」走 FileChangeQuery。
        let fileQueries = await recorder.fileQueries
        #expect(fileQueries.last?.searchText == "alpha",
                "详情那一路没带词 ⇒ 这一页只剩纯本地过滤，界面说的和查的又是两回事")
    }

    // MARK: - ⑤b 命令页与风险页（#74 收口时欠的那六行：每页 seed / push / pull 各一行）

    /// 命令页这一格原来什么都不做：`CommandQuery.searchText` 早就在契约里
    /// （`Contracts/Queries.swift:169`），只是没人把侧栏那个词递过去。
    /// 三条语义分开钉：① seed 排在 load 之前（首屏那一次查询就是筛过的）、
    /// ② 改词只多一条查询、③ 本页改词能回填侧栏，外加 §6 那道「相等不重查」。
    @Test("命令页：侧栏词进的是那条发出去的 CommandQuery（seed / push / pull 三条都在）")
    func commandsCellWiresAllThreeDirections() async {
        let (shell, recorder, host) = makeStage()
        let model = CommandsModel(runtime: runtime(host: host, service: recorder))
        // 夹具的时刻是「现在」，别让「今天」那条日历边界参与这一格的期望值。
        model.timeRange = .all
        shell.searchText = "engine"

        SidebarSearchWiring.seed(fromShell: shell, into: model)
        #expect(model.criteria.searchText == "engine")
        #expect(model.sidebarSearchTerm == "engine")
        await model.load()
        let sent = await recorder.commandQueries
        #expect(sent.count == 1, "第一次进板块只该发一条查询，实际 \(sent.count) 条")
        #expect(sent[0].searchText == "engine", "发出去的 CommandQuery 没带侧栏词 ⇒ 这一格还是零读取者")
        // 只有真下推才动得了服务端总数：本地过滤会留下 totalCount == 3。
        #expect(model.totalCount == 1, "三条命令里只有那条 commit message 带 engine；总数仍是 3 就是没下推")

        shell.searchText = "swift"
        await SidebarSearchWiring.push(fromShell: shell, into: model)
        let afterPush = await recorder.commandQueries
        #expect(afterPush.count == 2, "一次改词应当只多一条查询，实际发了 \(afterPush.count) 条")
        #expect(afterPush.last?.searchText == "swift")
        #expect(model.totalCount == 1)

        // 反向那一条：本页过滤条改词 ⇒ 侧栏显示同一个词。
        await model.setSearchText("rm")
        SidebarSearchWiring.pull(queryTerm: model.criteria.searchText, into: shell)
        #expect(shell.searchText == "rm")

        // §6 成本闸：词没变 ⇒ 一条都不许多发。
        let before = await recorder.commandQueries.count
        shell.searchText = "rm"
        await SidebarSearchWiring.push(fromShell: shell, into: model)
        #expect(await recorder.commandQueries.count == before, "相等还重查：接线在靠重查确认自己")
    }

    /// 风险页的扳机与命令页**不同**：`SecurityModel` 没有 `setSearchText` 那一步，
    /// 视图靠 `.task(id: model.filterToken)` 重查 ⇒ 桥只许落词，不许自己再 `load()` 一次
    /// （那等于一次改词被扳两回）。所以这一格断的是「桥发零条查询 + `filterToken` 真的动了」，
    /// 再由测试替视图跑那一条 `load()`，验证词确实进了发出去的 `RiskQuery`。
    @Test("风险页：桥只落词、重查归 filterToken 那一格（一次改词不许被扳两回）")
    func securityCellWiresAllThreeWithoutDoubleFetching() async {
        let (shell, recorder, host) = makeStage()
        let model = SecurityModel(runtime: runtime(host: host, service: recorder))
        model.range = .all
        shell.searchText = "engine"

        SidebarSearchWiring.seed(fromShell: shell, into: model)
        #expect(model.query.searchText == "engine")
        #expect(model.sidebarSearchTerm == "engine")
        await model.load()
        // `load()` 每回发两条（本页那条 + 「今日总数」那把 `limit: 1` 的小尺），只数主查询。
        let main = await recorder.riskQueries.filter { $0.limit == SecurityModel.pageSize }
        #expect(main.count == 1, "第一次进板块只该发一条主查询，实际 \(main.count) 条")
        #expect(main[0].searchText == "engine")
        #expect(model.totalCount == 1, "三条风险里只有标题带 engine 那条")

        let tokenBefore = model.filterToken
        let before = await recorder.riskQueries.count
        shell.searchText = "credential"
        await SidebarSearchWiring.push(fromShell: shell, into: model)
        #expect(await recorder.riskQueries.count == before, "桥自己又发了一次查询 ⇒ 一次改词被扳两回")
        #expect(model.filterToken != tokenBefore,
                "落词没让本页的取数扳机动起来 ⇒ 这一格是只写不查的死格子")

        await model.load()   // 替视图那条 `.task(id: model.filterToken)` 扳一次
        let after = await recorder.riskQueries.filter { $0.limit == SecurityModel.pageSize }
        #expect(after.last?.searchText == "credential")
        #expect(model.totalCount == 1)

        model.query.searchText = "rm"
        SidebarSearchWiring.pull(queryTerm: model.query.searchText, into: shell)
        #expect(shell.searchText == "rm", "风险页改了词，侧栏还挂着旧词 ⇒ 两处真相")
    }

    // MARK: - ⑥ 接线本身（源码级）：桥在，视图也得接

    /// 「桥修好了但没人走」是这一族缺陷的第二个形状：`SidebarSearchWiring` 存在、
    /// 各视图却把它删了，行为用例仍然全绿（用例调的是桥）。所以这里逐个视图钉挂载点，
    /// 与 `SidebarNavigationTests` 同一手法（键位能不能按归实拍，接没接线归源码级检查）。
    ///
    /// 「seed 在 load 之前」要在本页那条加载 `.task` **内部**比：FilesView 标题行那颗
    /// 「重新加载」按钮里也有一句 `await model.load()`，它在文件里出现得更早——
    /// 拿整份文件的第一处去比会稳定误报（本用例第一版就是把文件页判红的）。
    @Test("六个视图都挂了这座桥，而且 seed 排在本页第一次 load 之前")
    func viewsMountTheBridge() throws {
        let wired: [(file: String, loadTask: String)] = [
            ("Sources/AIObservatoryUI/Timeline/TimelineView.swift", ".task(id: shell?.timeRange)"),
            ("Sources/AIObservatoryUI/Sessions/SessionsView.swift", ".task(id: shell?.timeRange)"),
            ("Sources/AIObservatoryUI/Files/FilesView.swift", ".task(id: shell?.timeRange)"),
            ("Sources/AIObservatoryUI/Projects/ProjectsView.swift", ".task(id: effectiveRange)"),
            ("Sources/AIObservatoryUI/Commands/CommandsView.swift", ".task(id: shell?.timeRange)"),
            // 风险页的加载任务是无参的 `.task {`：拿第一处 `.task(id:` 去比会命中它后面
            // 那条 `.task(id: shell?.pendingJump)`，seed 反而在更早的位置 ⇒ 顺序核对假红。
            ("Sources/AIObservatoryUI/Security/SecurityView.swift", ".task {"),
        ]
        for entry in wired {
            let text = try Self.source(entry.file)
            #expect(text.contains("SidebarSearchWiring.seed(fromShell: shell, into: model)"),
                    "\(entry.file) 不再在进板块时播种侧栏词 ⇒ 首屏那一次查询是没筛过的")
            #expect(text.contains("SidebarSearchWiring.push(fromShell: shell, into: model)"),
                    "\(entry.file) 不再订阅侧栏改词 ⇒ 那一格又回到零读取者")
            #expect(text.contains("SidebarSearchWiring.pull(queryTerm:"),
                    "\(entry.file) 少了板块 → 侧栏的反向那条 ⇒ 两把尺子重新各说各话")

            guard let taskMark = text.range(of: entry.loadTask) else {
                Issue.record("\(entry.file) 里找不到本页的加载任务 \(entry.loadTask) ⇒ 顺序无从核对")
                continue
            }
            let body = text[taskMark.upperBound...]
            guard let seedAt = body.range(of: "SidebarSearchWiring.seed"),
                  let loadAt = body.range(of: "await model.load()") else {
                Issue.record("\(entry.file) 的加载任务里少了 seed 或 load ⇒ 接线被搬走或改名了")
                continue
            }
            // `body` 是 `text` 的子串 ⇒ 两个 Range 的边界是同一条字符串上的下标，直接比。
            #expect(seedAt.lowerBound < loadAt.lowerBound,
                    "\(entry.file) 里 seed 排到了 load 之后 ⇒ 第一次查询又变成不带词")
        }
    }

    /// 各页的搜索框：侧栏一改词，框里也得跟着变（原来 Sessions / Files 两页没有回填路径，
    /// 接线一做就冒出新的一格说谎：列表已筛过而框还空着）。
    /// 命令页同样是草稿态输入框（`@State searchText`），#74 收口时这里曾是缺口。
    @Test("搜索框都有从查询词回填的那条路（框与列表不许两处真相）")
    func filterBarsBackfillFromTheLiveQuery() throws {
        for file in [
            "Sources/AIObservatoryUI/Timeline/TimelineFilterBar.swift",
            "Sources/AIObservatoryUI/Sessions/SessionFilterBar.swift",
            "Sources/AIObservatoryUI/Files/FilesFilterBar.swift",
        ] {
            let text = try Self.source(file)
            #expect(text.contains(".onChange(of: model.query.searchText)"),
                    "\(file) 的搜索框不再从生效的查询词回填 ⇒ 侧栏改词后它是空的")
        }
        // 命令页的生效词住在 `criteria` 而不是 `query`（它每回换算一条 `CommandQuery`）。
        let commands = try Self.source("Sources/AIObservatoryUI/Commands/CommandsFilterBar.swift")
        #expect(commands.contains(".onChange(of: model.criteria.searchText)"),
                "命令页的搜索框不再从生效的查询词回填 ⇒ 侧栏改完词，列表筛了而框还空着")
        // Projects 与风险的框直接绑在生效词上（没有草稿态），因此它们天然是同一份。
        let projects = try Self.source("Sources/AIObservatoryUI/Projects/ProjectsView.swift")
        #expect(projects.contains("text: $model.searchText"),
                "Projects 的搜索框不再绑定生效词 ⇒ 这一页多了第二处真相")
        let security = try Self.source("Sources/AIObservatoryUI/Security/SecurityFilterBar.swift")
        #expect(security.contains("text: $model.query.searchText"),
                "风险页的搜索框不再绑定生效词 ⇒ 这一页多了第二处真相")
    }

    @Test("防抖只有一个出处：桥与 Projects 都用 SidebarSearchWiring.debounce")
    func debounceHasSingleSource() throws {
        let bridge = try Self.source("Sources/AIObservatoryUI/Shell/SidebarSearchWiring.swift")
        #expect(bridge.contains("static let debounce: Duration = .milliseconds(300)"))
        let projects = try Self.source("Sources/AIObservatoryUI/Projects/ProjectsView.swift")
        #expect(projects.contains("SidebarSearchWiring.debounce"),
                "Projects 又自己写死一个防抖时长 ⇒ 同一个搜索框两种延迟")
    }

    // MARK: - 解析

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        return try String(contentsOf: root.appending(path: relative), encoding: .utf8)
    }
}
