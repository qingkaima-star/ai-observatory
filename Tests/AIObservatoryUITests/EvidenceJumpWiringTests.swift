//
//  EvidenceJumpWiringTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/trace（#81 概览 → 证据的完整路径）
//  ─────────────────────────────────────────────────────────
//  钉的是「跳过去之后，条件真的生效了」这件事。判据刻意不用「selection 变了」：
//  #81 的现场缺陷恰恰是**跨页按钮只改 selection**，那类断言在缺陷存在时也全绿。
//  这里每条正向判据断两件事：
//    ① 目标板块**真正发出去**的那条 `*Query` 带着这一跳的条件（读记账替身，不读 `model.query`
//      ——字段被写了不等于那条查询带着它）；
//    ② 服务端算出的结果集**真的被筛小**（`totalCount` 与服务端返回的行，本地数组过滤动不了它们）。
//  期望值全部手推，注释里写出推的过程。
//
//  夹具形状（三条时间轴上刻意拉开距离，避开日历边界的偶发红）：
//    · 三条在 1 小时前（落在「最近 24 小时 / 7 天 / 全部」里）
//    · 一条在 3 天前（落在「7 天 / 全部」里）
//    · 一条在 10 天前（只落在「全部」里）
//  路径一律合成 `/Users/dev/…`（AGENTS.md §0/§7）；文案一律 ASCII，
//  免得 `HardcodedChineseRatchetTests` 那类门禁把测试夹具算成存量。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

// MARK: - 夹具

private let alpha = "/Users/dev/alpha"
private let beta = "/Users/dev/beta"

private let sessionA = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!
private let sessionB = UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!

private let ev1 = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000001")!
private let ev2 = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000002")!
private let ev3 = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000003")!
private let ev4 = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000004")!
private let ev5 = UUID(uuidString: "EEEEEEEE-0000-0000-0000-000000000005")!

/// 命令与风险那两页的固定 id（跳转要「定位到哪一条」读的就是它）。
private let cmd1 = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!
private let cmd2 = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!
private let cmd3 = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000003")!
private let cmd4 = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000004")!
private let cmd5 = UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000005")!

private let risk1 = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000001")!
private let risk2 = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000002")!
private let risk3 = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000003")!
private let risk4 = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000004")!
private let risk5 = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000005")!

/// 五个时刻：一小时前 3 条、三天前 1 条、十天前 1 条。
private func hourAgo(_ now: Date) -> Date { now.addingTimeInterval(-3_600) }
private func threeDaysAgo(_ now: Date) -> Date { now.addingTimeInterval(-3 * 24 * 3_600) }
private func tenDaysAgo(_ now: Date) -> Date { now.addingTimeInterval(-10 * 24 * 3_600) }

/// 五条时间线事件。手推的分布（用于下面每条用例的期望值）：
///
/// | id | 项目  | 会话 | 种类 | 时刻 |
/// | -- | ----- | ---- | ---- | ---- |
/// | ev1 | alpha | A | 修改文件 | 1 h 前 |
/// | ev2 | alpha | A | 删除文件 | 1 h 前 |
/// | ev3 | beta  | B | 修改文件 | 1 h 前 |
/// | ev4 | alpha | B | 执行命令 | 3 d 前 |
/// | ev5 | beta  | B | 删除文件 | 10 d 前 |
///
/// ⇒ 全量 5；`alpha` 3；`beta` 2；会话 A 2；会话 B 3；
/// 「删除文件」2；「修改文件」2；最近 24 小时 3；最近 7 天 4。
private func seededEvents(now: Date) -> [TimelineEvent] {
    [
        TimelineEvent(id: ev1, timestamp: hourAgo(now), sessionID: sessionA, kind: .fileModified,
                      title: "Edit engine source", filePath: "\(alpha)/Sources/engine.swift",
                      projectPath: alpha),
        TimelineEvent(id: ev2, timestamp: hourAgo(now), sessionID: sessionA, kind: .fileDeleted,
                      title: "Delete legacy source", filePath: "\(alpha)/Sources/legacy.swift",
                      projectPath: alpha),
        TimelineEvent(id: ev3, timestamp: hourAgo(now), sessionID: sessionB, kind: .fileModified,
                      title: "Edit readme", filePath: "\(beta)/README.md", projectPath: beta),
        TimelineEvent(id: ev4, timestamp: threeDaysAgo(now), sessionID: sessionB, kind: .commandExecuted,
                      title: "Run build", command: "swift build --build-tests", projectPath: alpha),
        TimelineEvent(id: ev5, timestamp: tenDaysAgo(now), sessionID: sessionB, kind: .fileDeleted,
                      title: "Delete old notes", filePath: "\(beta)/notes/old.md", projectPath: beta),
    ]
}

/// 与事件同形状的五条文件变更（种类用文件页那一份说法）。
/// ⇒ 全量 5；`alpha` 3；会话 A 2；「删除」2；最近 24 小时 3。
private func seededFileChanges(now: Date) -> [FileChange] {
    [
        FileChange(path: "\(alpha)/Sources/engine.swift", kind: .modified, timestamp: hourAgo(now),
                   sessionID: sessionA, projectPath: alpha),
        FileChange(path: "\(alpha)/Sources/legacy.swift", kind: .deleted, timestamp: hourAgo(now),
                   sessionID: sessionA, projectPath: alpha),
        FileChange(path: "\(beta)/README.md", kind: .modified, timestamp: hourAgo(now),
                   sessionID: sessionB, projectPath: beta),
        FileChange(path: "\(alpha)/Sources/Generated.swift", kind: .created, timestamp: threeDaysAgo(now),
                   sessionID: sessionB, projectPath: alpha),
        FileChange(path: "\(beta)/notes/old.md", kind: .deleted, timestamp: tenDaysAgo(now),
                   sessionID: sessionB, projectPath: beta),
    ]
}

/// 两条会话：A 一小时前起（在 24 小时窗内），B 三天前起（窗外）。
private func seededSessions(now: Date) -> [AgentSession] {
    [
        AgentSession(id: sessionA, displayIndex: 301, kind: .claudeCode, title: "Alpha work",
                     projectPath: alpha, startedAt: hourAgo(now)),
        AgentSession(id: sessionB, displayIndex: 302, kind: .openAICodex, title: "Beta work",
                     projectPath: beta, startedAt: threeDaysAgo(now)),
    ]
}

/// 五条命令记录，会话归属与时刻分布跟上面那张事件表对齐。
/// `projectPath` 按 #81(a) 之后那条真字段填：cmd1/cmd2 在 alpha、cmd3/cmd4 在 beta、
/// cmd5 **不带项目**（采不到归属）⇒ 它在任何项目条件下都不该出现（那条就是钉它的）。
/// ⇒ 全量 5；会话 A 2；会话 B 3；最近 24 小时 3；alpha 2；beta 2；无项目 1。
private func seededCommands(now: Date) -> [CommandRecord] {
    [
        CommandRecord(id: cmd1, executable: "swift", arguments: ["build", "--build-tests"],
                      sessionID: sessionA, agentKind: .claudeCode, startedAt: hourAgo(now),
                      endedAt: hourAgo(now), exitCode: 0, outcome: .success,
                      projectPath: alpha),
        CommandRecord(id: cmd2, executable: "git", arguments: ["commit", "-m", "tidy"],
                      sessionID: sessionA, agentKind: .claudeCode, startedAt: hourAgo(now),
                      endedAt: hourAgo(now), exitCode: 0, outcome: .success,
                      projectPath: alpha),
        CommandRecord(id: cmd3, executable: "rm", arguments: ["-rf", "/Users/dev/tmp/build"],
                      sessionID: sessionB, agentKind: .openAICodex, startedAt: hourAgo(now),
                      endedAt: hourAgo(now), exitCode: 0, outcome: .success, isDestructive: true,
                      projectPath: beta),
        CommandRecord(id: cmd4, executable: "swift", arguments: ["test"],
                      sessionID: sessionB, agentKind: .claudeCode, startedAt: threeDaysAgo(now),
                      endedAt: threeDaysAgo(now), exitCode: 1, outcome: .failure,
                      projectPath: beta),
        CommandRecord(id: cmd5, executable: "npm", arguments: ["install"],
                      sessionID: sessionB, agentKind: .claudeCode, startedAt: tenDaysAgo(now),
                      endedAt: tenDaysAgo(now), exitCode: 0, outcome: .success),
    ]
}

/// 五条风险事件，同一张时刻表。
/// 项目归属走那条**归属边**（风险自己不挂项目，经 `sessionID` 落到会话、会话落到项目）：
/// risk1/risk2 挂会话 A（alpha），risk3/risk4/risk5 挂会话 B（beta）。
/// ⇒ 全量 5；会话 A 2；会话 B 3；最近 24 小时 3；alpha 2；beta 3。
private func seededRisks(now: Date) -> [RiskEvent] {
    [
        RiskEvent(id: risk1, timestamp: hourAgo(now), level: .high, category: .dangerousCommand,
                  title: "Delete build directory", detail: "rm -rf", sessionID: sessionA,
                  command: "rm -rf /Users/dev/tmp/build"),
        RiskEvent(id: risk2, timestamp: hourAgo(now), level: .medium, category: .sensitivePathAccess,
                  title: "Read credential cache", sessionID: sessionA),
        RiskEvent(id: risk3, timestamp: hourAgo(now), level: .low, category: .unknown,
                  title: "Wide filesystem read", sessionID: sessionB),
        RiskEvent(id: risk4, timestamp: threeDaysAgo(now), level: .high, category: .massDeletion,
                  title: "Remove checkout", sessionID: sessionB),
        RiskEvent(id: risk5, timestamp: tenDaysAgo(now), level: .medium, category: .resourceAbuse,
                  title: "Long running reader", sessionID: sessionB),
    ]
}

/// 一套「外壳 + 板块」的同源运行时（与 `ObservatoryRootView` 的装配形状一致）。
@MainActor
private func makeStage() -> (shell: ShellModel, recorder: QueryRecordingService, host: InMemoryObservatoryService) {
    let now = Date()
    let host = InMemoryObservatoryService()
    host.seed(sessions: seededSessions(now: now),
              events: seededEvents(now: now),
              fileChanges: seededFileChanges(now: now),
              commands: seededCommands(now: now),
              risks: seededRisks(now: now),
              projects: [
                  ProjectActivity(id: alpha, name: "alpha", path: alpha, fileChangeCount: 3),
                  ProjectActivity(id: beta, name: "beta", path: beta, fileChangeCount: 2),
              ])
    let recorder = QueryRecordingService(forwardingTo: host)
    let runtime = ObservatoryRuntime(service: recorder, controller: host, updates: host)
    let shell = ShellModel(runtime: runtime)
    // 外壳默认档是「今天」，而夹具用的是相对时刻（一小时前 / 三天前 / 十天前）。
    // 把全局那把尺调到「全部」，下面每条用例的期望值才只由**它要测的那一项**决定；
    // 专门测时间区间的用例自己会 `jump` 一个区间进来（那才是它要断的东西）。
    shell.timeRange = .all
    return (shell, recorder, host)
}

@MainActor
private func runtime(host: InMemoryObservatoryService,
                     service: QueryRecordingService) -> ObservatoryRuntime {
    ObservatoryRuntime(service: service, controller: host, updates: host)
}

// MARK: - 一只「按项目筛小」的服务替身

/// 为什么必须有它（而不是直接拿 `QueryRecordingService` + `InMemoryObservatoryService` 断「筛小」）：
/// 冻结基准 `InMemoryObservatoryService` 在 §3 冻结区（`AIObservatoryTestSupport/**`，本轮未授权改），
/// 它读不到 `CommandQuery.projectPath` / `RiskQuery.projectPath` 这一维 ⇒ 拿它当服务端，
/// 「结果集真的被筛小」这半句在 UI 这一头根本量不到（会一直得到全量 5）。
///
/// 所以这一格换一只**专用**替身，判据逐字照两侧 Store 的既有口径：
///   · 命令：`record.projectPath == 条件`（精确相等，NULL 永不匹配）。
///   · 风险：「风险 → 会话 → 项目」那条归属边（`risk_events` 没有项目列，与
///     `ObservatoryStore.riskEvents` 那句 `session_id IN (SELECT …)` 同一条）。
///
/// 它钉的是**页面**那一头：条件上了那条真查询 ⇒ 服务端给的行变少 ⇒ 页面照抄服务端，
/// 不会自己再把本地数组放宽回去。至于「实现真把结果筛小」，那是
/// `StoreParityTests`（SQLite 手算 6 → 2 / 5 → 3）与两后端直接对照那一族的活，不靠这一格。
/// 夹具只有 5 条、一页装得下（命令页 limit 500、风险页 limit 100），
/// 所以「在服务端返回的那一页上补按项目筛一次」与服务端的等价结果同一条。
actor ProjectScopedQueryService: ObservatoryService {
    private let inner: InMemoryObservatoryService
    private(set) var commandQueries: [CommandQuery] = []
    private(set) var riskQueries: [RiskQuery] = []

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
        try await inner.sessions(matching: query)
    }

    func session(id: UUID) async throws -> AgentSession? {
        try await inner.session(id: id)
    }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        try await inner.events(matching: query)
    }

    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        try await inner.fileChanges(matching: query)
    }

    func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        try await inner.fileDiff(for: changeID)
    }

    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        commandQueries.append(query)
        let page = try await inner.commands(matching: query)
        guard let project = query.projectPath else { return page }
        let kept = page.items.filter { $0.projectPath == project }
        return Page(items: kept, totalCount: kept.count, offset: query.offset)
    }

    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        try await inner.performanceSamples(sessionID: sessionID)
    }

    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        try await inner.systemPerformance(since: date)
    }

    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        riskQueries.append(query)
        let page = try await inner.riskEvents(matching: query)
        guard let project = query.projectPath else { return page }
        // 归属边：先问「这个项目名下有哪些会话」，再留下挂在这些会话上的风险。
        let owners = try await inner.sessions(matching: SessionQuery(projectPath: project, limit: 500))
        let ownerIDs = Set(owners.items.map(\.id))
        let kept = page.items.filter { ownerIDs.contains($0.sessionID ?? UUID()) }
        return Page(items: kept, totalCount: kept.count, offset: query.offset)
    }

    func projects() async throws -> [ProjectActivity] {
        try await inner.projects()
    }

    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        try await inner.projectActivity(path: path, dateRange: dateRange)
    }
}

@MainActor
private func scopedRuntime(host: InMemoryObservatoryService,
                           service: ProjectScopedQueryService) -> ObservatoryRuntime {
    ObservatoryRuntime(service: service, controller: host, updates: host)
}

// MARK: - 用例

@MainActor
@Suite("UI: #81 带条件的跳转（四类条件真的进得了查询）", .timeLimit(.minutes(3)))
struct EvidenceJumpWiringTests {

    // MARK: ① 项目路径

    @Test("项目 → 时间线：发出去的 EventQuery 带着 projectPath，服务端总数 5 → 3")
    func projectLandsOnTimelineQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.searchText = ""
        shell.jump(JumpIntent(target: .timeline, projectPath: alpha))
        // 模拟目的页的加载任务（顺序与 `TimelineView` 一致，源码级那条用例钉着这个次序）。
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(model.query.projectPath == alpha)

        await model.load()
        let sent = await recorder.eventQueries
        #expect(sent.count == 1, "进板块只该发一条查询，实际 \(sent.count) 条")
        #expect(sent[0].projectPath == alpha, "发出去的 EventQuery 没带项目路径 ⇒ 这一跳只换了页")
        #expect(model.totalCount == 3, "alpha 只有 ev1/ev2/ev4 三条；仍是 5 就是没下推")
        #expect(Set(model.events.map(\.id)) == Set([ev1, ev2, ev4]))
    }

    @Test("项目 → 文件页：FileChangeQuery 带着 projectPath，行数从 5 收到 3")
    func projectLandsOnFileQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = FilesModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .files, projectPath: alpha))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)

        await model.load()
        let sent = await recorder.fileQueries
        #expect(sent.count == 1)
        #expect(sent[0].projectPath == alpha)
        #expect(model.totalCount == 3, "alpha 的变更是 engine/legacy/Generated 三条")
        // 断的是服务端回来的 `changes`，不是本地二次筛的 `visibleChanges`。
        #expect(model.changes.count == 3)
        #expect(Set(model.changes.map(\.path)) == Set([
            "\(alpha)/Sources/engine.swift",
            "\(alpha)/Sources/legacy.swift",
            "\(alpha)/Sources/Generated.swift",
        ]))
    }

    @Test("项目 → 会话页：SessionQuery 带着 projectPath，会话从 2 条收到 1 条")
    func projectLandsOnSessionQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = SessionsModel(runtime: runtime(host: host, service: recorder))
        // 区间给「7 天」而不是留着默认那档「今天」：夹具是「一小时前 / 三天前」，
        // 跨过午夜跑就会有一条件凭空出局（用例红得没有道理）。7 天把两条都装得下，
        // 于是「2 → 1」这个差值只可能来自 projectPath 那一项。
        shell.jump(JumpIntent(target: .sessions, projectPath: alpha, timeRange: .lastSevenDays))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)

        await model.load()
        let sent = await recorder.sessionQueries
        #expect(sent.count == 1)
        #expect(sent[0].projectPath == alpha)
        #expect(model.totalCount == 1, "两条会话都在 7 天窗内，只剩 1 条只能是项目筛的")
        #expect(model.sessions.map(\.displayIndex) == [301])
    }

    // MARK: ② 会话

    @Test("会话 → 时间线：EventQuery 带着 sessionID，总数 5 → 2（这一跳是「这一条会话的证据」）")
    func sessionLandsOnTimelineQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .timeline, projectPath: nil, sessionID: sessionA))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)

        await model.load()
        let sent = await recorder.eventQueries
        #expect(sent.count == 1)
        #expect(sent[0].sessionID == sessionA)
        #expect(model.totalCount == 2, "A 只有 ev1/ev2 两条")
        #expect(Set(model.events.map(\.id)) == Set([ev1, ev2]))
    }

    @Test("会话 → 文件页：FileChangeQuery 带着 sessionID，行数 5 → 2")
    func sessionLandsOnFileQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = FilesModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .files, sessionID: sessionA))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)

        await model.load()
        let sent = await recorder.fileQueries
        #expect(sent[0].sessionID == sessionA)
        #expect(model.totalCount == 2)
        #expect(model.changes.map(\.fileName).sorted() == ["engine.swift", "legacy.swift"])
    }

    /// `SessionQuery` **没有** `sessionID` 字段，所以这一格落地的是「选中那一条」而不是
    /// 「把列表筛小」。单独钉一条：不许把它报成生效的筛选条件 —— 那会把「列表还是全量、
    /// 详情看的是 B」说成「列表也被筛过了」，正是本波一直在修的那族缺陷。
    @Test("会话 → 会话页：那一格是定位（选中那一条并拉它的详情），不是把列表筛小")
    func sessionFocusOnSessionsBoard() async {
        let (shell, recorder, host) = makeStage()
        let model = SessionsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .sessions, sessionID: sessionB, timeRange: .lastSevenDays))
        model.timeRange = shell.timeRange
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)

        // 列表仍是全量两条：这一格没骗人说自己筛小了。
        #expect(model.totalCount == 2)
        #expect(model.carriedJumpConditions.sessionID == nil,
                "SessionQuery 没有 sessionID 字段，把它报成「生效的筛选条件」就是界面在说谎")
        // 承重的部分是「选中的确实是 B」以及「详情那条真查询取的是 B」。
        #expect(model.selected?.id == sessionB)
        #expect(model.selected?.displayIndex == 302)
        #expect(model.detailID == sessionB)
        let detailQuery = await recorder.eventQueries.last
        #expect(detailQuery?.sessionID == sessionB, "详情取的是别的会话 ⇒ 跳过去看到的不是这一条")
    }

    // MARK: ③ 事件种类

    @Test("事件种类 → 时间线：EventQuery.kinds 带着它，总数 5 → 2")
    func kindsLandOnTimelineQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .timeline, eventKinds: [.fileDeleted]))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(model.query.kinds == [.fileDeleted])

        await model.load()
        let sent = await recorder.eventQueries
        #expect(sent[0].kinds == [.fileDeleted], "发出去的查询没带种类 ⇒ 那一类事件在页面上又混回全部")
        #expect(model.totalCount == 2, "删除文件的是 ev2（alpha）与 ev5（beta）")
        #expect(Set(model.events.map(\.id)) == Set([ev2, ev5]))
    }

    @Test("事件种类 → 文件页：映射成 FileChangeQuery.kinds，总数 5 → 2")
    func kindsLandOnFileQueryThroughMapping() async {
        let (shell, recorder, host) = makeStage()
        let model = FilesModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .files, eventKinds: [.fileDeleted, .fileCreated]))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(model.query.kinds == [.deleted, .created])

        await model.load()
        let sent = await recorder.fileQueries
        #expect(sent[0].kinds == [.deleted, .created])
        // 反向那一份也要对上：diff 面板那颗按钮要不要排、页面上「带几类事件」那一格，
        // 读的都是这个反向映射（两份表分叉就是在造第二个真相）。
        #expect(model.carriedJumpConditions.eventKinds == [.fileDeleted, .fileCreated])
        // 手推：deleted 两条（legacy.swift / notes/old.md）+ created 一条（Generated.swift）= 3。
        #expect(model.totalCount == 3)
    }

    /// 反向那一半同样承重：文件页**没有**「执行命令」这种种类。把不存在的条件塞过去
    /// 会得到一个恒假的过滤器（结果集凭空归零，比不筛更坏），所以桥必须不映射它。
    @Test("事件种类 → 文件页：文件页没有的种类不许映射（恒假过滤器比不筛更坏）")
    func nonFileKindsDoNotBecomeFakeFileFilters() async {
        let (shell, recorder, host) = makeStage()
        let model = FilesModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .files, eventKinds: [.commandExecuted]))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(model.query.kinds.isEmpty, "把 commandExecuted 映射成文件种类会筛出一条不存在的变更")

        await model.load()
        #expect(model.totalCount == 5, "这一跳在文件种类这一维上就是不表态，全量才是对的")
    }

    // MARK: ③b 单值映射那张表（diff 面板那颗按钮排不排，读的就是它）

    /// 两个方向各有**一份单值**表，集合版逐值转调它们（两份表分叉 = 在造第二个真相）。
    /// 逐值手推：
    ///   · 正向 13 个操作种类里只有 4 个文件页有对应项（其余在文件页没有可落字段）；
    ///   · 反向 5 个变更种类里 4 个有时间线对应项，唯一映射不到的是 `.unknown` ——
    ///     文件页自己都说不出这是哪一类变更，硬派一个操作类型就是替用户编条件，
    ///     所以 diff 面板里那颗按钮**根本不排**（比排了再悄悄少带一项诚实）。
    @Test("单值映射两向逐值对平，且与集合版逐值一致")
    func singleValueMappingsAreTheOnlySource() {
        let operationToFile: [OperationKind: FileChangeKind] = [
            .fileCreated: .created, .fileModified: .modified,
            .fileDeleted: .deleted, .fileRenamed: .renamed,
        ]
        for kind in OperationKind.allCases {
            #expect(JumpIntent.fileKind(forOperationKind: kind) == operationToFile[kind],
                    "\(kind) 这一格的映射变了 ⇒ 按钮带出去的条件与屏幕上那句话不再是一回事")
        }

        let fileToOperation: [FileChangeKind: OperationKind] = [
            .created: .fileCreated, .modified: .fileModified,
            .deleted: .fileDeleted, .renamed: .fileRenamed,
        ]
        for kind in FileChangeKind.allCases {
            #expect(JumpIntent.operationKind(forFileKind: kind) == fileToOperation[kind],
                    "`.unknown` 之外都不许新增或改掉对应项（那颗按钮排不排由这一格决定）")
        }

        // 集合版与单值版必须逐值同构（分叉点在没人看得见的那一侧）。
        #expect(JumpIntent.fileKinds(forOperationKinds: Set(OperationKind.allCases)) == Set(operationToFile.values))
        #expect(JumpIntent.operationKinds(forFileKinds: Set(FileChangeKind.allCases)) == Set(fileToOperation.values))

        // 往返：能映射的四项来回一次要落回原处。
        for (operation, file) in operationToFile {
            #expect(JumpIntent.operationKind(forFileKind: file) == operation)
        }
    }

    // MARK: ④ 时间区间

    @Test("时间区间 → 时间线：区间端点进得了查询，总数 5 → 3（三天前与十天前那两条出局）")
    func timeRangeLandsOnTimelineQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .timeline, timeRange: .last24Hours))

        // 时间区间走的是**既有**的全局把手：`jump` 写 `shell.timeRange`，
        // 本页那条 `.task(id: shell?.timeRange)` 读到它 ⇒ 不多一条 `.task`、不多一次取数。
        #expect(shell.timeRange == .last24Hours)
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)

        await model.load()
        let sent = await recorder.eventQueries
        #expect(sent.count == 1, "一次跳转该只发一条查询，实际 \(sent.count) 条")
        let window = sent[0].dateRange
        #expect(window.contains(hourAgo(Date())), "一小时前三条都在窗内")
        #expect(!window.contains(threeDaysAgo(Date())), "三天前那条必须出局")
        #expect(!window.contains(tenDaysAgo(Date())))
        #expect(model.totalCount == 3)
        #expect(model.timeRange == .last24Hours, "页头那把尺与真查询用的区间不是同一个 ⇒ 界面在说谎")
    }

    @Test("时间区间 → 会话页：同一条区间把两天收到一天")
    func timeRangeLandsOnSessionQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = SessionsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .sessions, timeRange: .lastSevenDays))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)

        await model.load()
        let sent = await recorder.sessionQueries
        #expect(sent[0].dateRange.contains(hourAgo(Date())))
        #expect(!sent[0].dateRange.contains(tenDaysAgo(Date())))
        // 手推：A 一小时前 → 在窗内；B 三天前 → 也在七天内 ⇒ 两条都留着。
        // 这一条断的是「区间真的进去了」而不是「筛到 1 条」，所以换成 24 小时档才是 1。
        #expect(model.totalCount == 2)
        #expect(sent[0].dateRange.contains(threeDaysAgo(Date())))
    }

    // MARK: ⑤ 四类条件同时生效

    @Test("四类条件一起带：项目 + 会话 + 事件种类 + 时间区间，总数 5 → 1")
    func allFourConditionsLandTogether() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .timeline,
                              projectPath: alpha,
                              sessionID: sessionA,
                              eventKinds: [.fileModified],
                              timeRange: .last24Hours))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(model.carriedJumpConditions.projectPath == alpha)
        #expect(model.carriedJumpConditions.sessionID == sessionA)
        #expect(model.carriedJumpConditions.eventKinds == [.fileModified])
        #expect(model.carriedJumpConditions.timeRange == .last24Hours)

        await model.load()
        let sent = await recorder.eventQueries
        #expect(sent.count == 1)
        #expect(sent[0].projectPath == alpha)
        #expect(sent[0].sessionID == sessionA)
        #expect(sent[0].kinds == [.fileModified])
        #expect(sent[0].dateRange.contains(hourAgo(Date())))
        #expect(!sent[0].dateRange.contains(threeDaysAgo(Date())))
        // 手推交集：alpha ∩ 会话A ∩ 修改文件 ∩ 24 小时 = 只有 ev1。
        #expect(model.totalCount == 1)
        #expect(model.events.map(\.id) == [ev1])
    }

    // MARK: ⑥ 落地的形状：消费一次、路由、幂等

    @Test("落地即消费：条件落完外壳那条意图就没了，切回来不会被旧条件压一遍")
    func intentIsConsumedOnSeed() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .timeline, projectPath: alpha))
        #expect(shell.pendingJump != nil, "跳转那一瞬间意图必须在外壳里等着，否则目的页读不到")

        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(shell.pendingJump == nil, "没消费 ⇒ 下一次进这一页还会被这一跳的条件压一遍")
        #expect(jumped?.projectPath == alpha, "seed 要把消费掉的意图交回去，好让取数之后落「打开哪一行」")

        // 用户在这一页自己重置过了 ⇒ 晚一步再进这一页不该把旧条件搬回来。
        let second = TimelineModel(runtime: runtime(host: host, service: recorder))
        EvidenceJumpWiring.seed(fromShell: shell, into: second)
        #expect(second.query.projectPath == nil)
        await second.load()
        let sent = await recorder.eventQueries
        // 上面那条 `model.load()` 都没跑 ⇒ 到这里整条账上只有这一条查询。
        // 「旧意图没有偷偷再触发一次重查」断的就是这个数。
        #expect(sent.count == 1, "被消费掉的意图又触发了一次查询：\(sent.count) 条")
        #expect(sent.last?.projectPath == nil)
        #expect(second.totalCount == 5)
    }

    @Test("路由：目的地不是这一页时，这一页一行条件都不落")
    func intentForAnotherBoardIsIgnored() async {
        let (shell, recorder, host) = makeStage()
        let files = FilesModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .timeline, projectPath: alpha))
        EvidenceJumpWiring.seed(fromShell: shell, into: files)
        #expect(files.query.projectPath == nil, "时间线的意图被文件页吃掉了 ⇒ 两个板块共用一份条件")
        #expect(shell.pendingJump != nil, "不是本页的意图不许被消费掉，否则到目的地时已经没了")

        await files.load()
        let sent = await recorder.fileQueries
        #expect(sent[0].projectPath == nil)
        #expect(files.totalCount == 5)
    }

    @Test("同页再来一次跳转：走真查询重筛一次，服务端总数 5 → 2")
    func pushAppliesWhenAlreadyOnBoard() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        #expect(model.totalCount == 5)
        let afterFirst = await recorder.eventQueries.count
        #expect(afterFirst == 1)

        // 已经停在时间线时点详情里那颗「只看这一类事件」。
        shell.jump(JumpIntent(target: .timeline, eventKinds: [.fileModified]))
        await EvidenceJumpWiring.push(fromShell: shell, into: model)
        let sent = await recorder.eventQueries
        #expect(sent.count == afterFirst + 1, "一次同页跳转应当只多一条查询")
        #expect(sent.last?.kinds == [.fileModified])
        #expect(model.totalCount == 2, "修改文件的是 ev1/ev3 两条")
        #expect(shell.pendingJump == nil)
    }

    @Test("幂等与成本：条件与本页已生效的那一份相等 ⇒ 一条查询都不发")
    func identicalIntentSendsNoQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .timeline, projectPath: alpha))
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        #expect(await recorder.eventQueries.count == 1)

        // 同一个目的地、同一组条件再来一次（用户多点了一下那颗按钮）。
        shell.jump(JumpIntent(target: .timeline, projectPath: alpha))
        await EvidenceJumpWiring.push(fromShell: shell, into: model)
        #expect(await recorder.eventQueries.count == 1, "条件没变却重查：接线不许靠重查来确认")

        // 消费之后 seed 也一样：空意图不许把条件写回去，也不许发查询。
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(model.query.projectPath == alpha)
    }

    // MARK: ⑦ 撤销这一跳的条件

    @Test("清除：三项条件回到没有，时间区间回到全局那一份，结果集回到全量")
    func clearRemovesJumpedConditions() async {
        let (shell, recorder, host) = makeStage()
        let model = TimelineModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .timeline,
                              projectPath: alpha,
                              sessionID: sessionA,
                              eventKinds: [.fileDeleted],
                              timeRange: .lastSevenDays))
        model.timeRange = shell.timeRange
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        // 手推：alpha ∩ A ∩ 删除 ∩ 7 天 = ev2 一条。
        #expect(model.totalCount == 1)

        await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        let sent = await recorder.eventQueries
        #expect(sent.last?.projectPath == nil)
        #expect(sent.last?.sessionID == nil)
        #expect(sent.last?.kinds.isEmpty == true)
        // 手推：清完只剩全局那一份区间「最近 7 天」⇒ 十天前那条 ev5 仍然不在窗内，
        // 于是回到的是 4 条而不是 5 条。这一格故意不"顺手清成全部"：页头那把尺说什么
        // 就是什么，清除跳转条件不是重置全局时间范围。
        #expect(model.totalCount == 4, "撤掉三项条件后应当回到「全局区间内的那几条」，实际 \(model.totalCount) 条")
        #expect(model.timeRange == shell.timeRange, "时间区间不许被清成第四种状态，得回到页头那把尺")
    }

    // MARK: ⑧ #59 那条例外的收编

    /// #81(b)：`ShellModel.pendingRiskEventID` 那个兼容壳**删干净**了（项目纪律：能直改就不留兼容层）。
    /// 三条判据，缺一条都不算收口：
    ///   ① 名字在源码里消失 ⇒ 跨页状态只剩 `pendingJump` 一份（第二个出处必分叉，本仓头号缺陷族）；
    ///   ② 冻结区那一个写入点确实改成了这座桥（`shell.jump(...)`），不再是「存一个 id + 换一页」两句式；
    ///   ③ 通知那一路的行为不变：打开那一条、**不把列表筛小**、落地即消费。
    /// 原来这一格钉的是读写口本身的行为（写进去读得回来、清一条不许顺手清掉别的目的地）——
    /// 壳没了，那两条判据整体上移到 ②③ 这两条真通路上，一条没少。
    ///
    /// ②那一句为什么是 `.locating(target:eventID:)` 而不是 `JumpIntent(target:eventID:)`：
    /// 成员式 `init` 带着 `timeRange:`，那一维的类型在设计系统里是 internal ⇒ 想让 App 侧走成员式
    /// 构造只有两条路，要么把 `ObservatoryTimeRange` 升 public（放宽射程，本车道禁止），
    /// 要么把 init 收成 internal + 一只只带 public 类型的工厂（取这一条）。
    /// **这一格的编译就是它的自证**：`AIObservatoryApp` 那个 target 只用 `import AIObservatoryUI`
    /// （无 @testable），工厂退回 internal 立刻 emit-module 失败。
    @Test("高危通知的兼容壳删净：跨页存储只剩 pendingJump 一份，通知那一路照旧打开那一条")
    func legacyRiskHandleIsGoneAndNotificationPathStillLandsOnTheRow() async throws {
        let shellFile = try Self.codeOnly("Sources/AIObservatoryUI/Shell/ShellModel.swift")
        #expect(!shellFile.contains("pendingRiskEventID"),
                "兼容壳又长回来了：外壳里出现了第二个跨页存储")
        #expect(shellFile.contains("public func jump(_ intent: JumpIntent)"),
                "App 侧那个写入点要靠这一条才能进桥；它退回 internal 就等于把通知点击重新赶回旁路")
        let appFile = try Self.codeOnly("Sources/AIObservatoryApp/RiskNotifications.swift")
        #expect(appFile.contains("shell.jump(.locating(target: .security, eventID: id))"),
                "冻结区那一句不再走这座桥 ⇒ 点通知又变成「存一个 id + 换一页」两句式")
        #expect(!appFile.contains("shell.select(.security)"),
                "目的地改回由 `select` 单独做 ⇒ 一次跨页动作被两处各写一遍")

        let (shell, _, host) = makeStage()
        let service = QueryRecordingService(forwardingTo: host)
        let model = SecurityModel(runtime: runtime(host: host, service: service))
        model.range = .all
        let riskID = UUID(uuidString: "FFFFFFFF-0000-0000-0000-000000000009")!

        // ③ 走的是**生产那一条通路本身**：App 侧点通知就是 `JumpIntent.locating(target: .security,
        // eventID:)` + `shell.jump(...)`，所以这里不再自己 `JumpIntent(...)` 抄一份——
        // 抄一份等于工厂的本体没被测过（它把 `eventID` 弄丢了、或者顺手多带一项条件，这里都看不见）。
        // 先把全局那把尺挪到与本页那一份**不同**的一档（夹具默认两者同为 `.all`，量不出"被顺手改"）：
        // 通知那一路只定位，不许把页头那把尺也一起带走。
        shell.timeRange = .lastSevenDays
        shell.jump(.locating(target: .security, eventID: riskID))
        #expect(shell.pendingJump?.target == .security)
        #expect(shell.pendingJump?.eventID == riskID)
        #expect(shell.timeRange == .lastSevenDays,
                "通知那一路自己表态了时间区间 ⇒ 一条「打开这一条」的跳转把全局时间档改掉，结果集跟着被筛小")

        // 目的地不是这一页的那一条，风险页一行都不动（旧读写口「清一条顺手清掉别的目的地」
        // 那一格现在由这条路由判据代钉）。
        shell.jump(JumpIntent(target: .timeline, projectPath: alpha))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(jumped == nil, "时间线那一条意图被风险页吃掉了 ⇒ 两个板块共用一份条件")
        #expect(shell.pendingJump?.target == .timeline, "别的板块的意图不许在风险页被消费")

        // 换回目的地为风险页的那一条：seed 消费 + focus 打开那一条，列表不筛小。
        shell.jump(.locating(target: .security, eventID: riskID))
        let mine = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(mine?.eventID == riskID)
        #expect(shell.pendingJump == nil, "意图落完还留在外壳里 ⇒ 切回来会被旧条件再压一遍")
        await model.load()
        await EvidenceJumpWiring.focus(mine, into: model)
        #expect(model.totalCount == 5, "通知不是筛选条件：那一跳不该把列表筛小")
        #expect(model.carriedJumpConditions.projectPath == nil)
        #expect(model.carriedJumpConditions.sessionID == nil)
        #expect(model.range == .all, "seed 之后本页那把尺仍是本页自己的，没被那一跳写过")
    }

    // MARK: ⑨ Projects 那一格：项目条件 = 选中它，带出去的两条查询都筛过

    @Test("项目 → 项目地图：选中该项目，「最近变更」那条真查询带着路径与区间（5 → 2）")
    func projectJumpSelectsAndFiltersDetailQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = ProjectsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .projects, projectPath: alpha, timeRange: .last24Hours))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(model.timeRange == .last24Hours)
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)

        #expect(model.selectedPath == alpha)
        let sent = await recorder.fileQueries
        #expect(sent.count >= 1, "详情那一路没发查询 ⇒ 这一跳没把项目条件带到任何一条真查询上")
        #expect(sent.last?.projectPath == alpha)
        #expect(sent.last?.dateRange.contains(hourAgo(Date())) == true)
        #expect(sent.last?.dateRange.contains(threeDaysAgo(Date())) == false)
        // 手推：alpha 的变更三条，其中 Generated.swift 在三天前 ⇒ 24 小时窗内剩 2 条。
        #expect(model.recentChanges.count == 2)
        // 「跳过去的确实是被筛小的一屏」也要求这一格自己承认带了条件（页面上那一格读的就是它）。
        #expect(model.carriedJumpConditions.projectPath == alpha)
    }

    /// 这一格原来只收两类条件（时间区间 + 选中项目），会话与变更种类进来会**静默丢掉**：
    /// 桥不报错、页面也不显示徽标，用户读到的还是「这个项目的全部变更」。
    /// 这一条钉的是四类在 Projects 也真的各落一格，且都进得了那条发出去的 `FileChangeQuery`。
    @Test("项目地图四类条件一起收：会话与变更种类落进「最近变更」那条真查询（2 → 1）")
    func projectsAcceptAllFourConditions() async {
        let (shell, recorder, host) = makeStage()
        let model = ProjectsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .projects, projectPath: alpha, sessionID: sessionA,
                              eventKinds: [.fileDeleted], timeRange: .last24Hours))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)

        let sent = await recorder.fileQueries
        #expect(sent.count >= 1, "「最近变更」那一路没发查询 ⇒ 这一跳什么条件都没带过去")
        #expect(sent.last?.projectPath == alpha)
        #expect(sent.last?.sessionID == sessionA, "会话条件在这一格被悄悄丢掉了")
        #expect(sent.last?.kinds == [.deleted], "事件种类没有映射成文件页那一份 kinds")
        #expect(sent.last?.dateRange.contains(hourAgo(Date())) == true)
        #expect(sent.last?.dateRange.contains(threeDaysAgo(Date())) == false)
        // 手推：alpha 名下三条变更（engine 修改 / legacy 删除 / Generated 新建）。
        // 会话 A 名下只剩两条（engine、legacy），再按「删除」筛 ⇒ 只剩 legacy.swift。
        #expect(model.recentChanges.count == 1)
        #expect(model.recentChanges.first?.path == "\(alpha)/Sources/legacy.swift")
        // 这一格自己承认带了哪几项（页面上那颗 chip 与徽标读的都是它，不是外壳那份）
        let carried = model.carriedJumpConditions
        #expect(carried.projectPath == alpha)
        #expect(carried.sessionID == sessionA)
        #expect(carried.eventKinds == [.fileDeleted])
        #expect(carried.timeRange == .last24Hours)
        // 徽标：会话 + 种类 + 时间档三项都数得着（`timeRange == .all` 那一档白送不算）。
        #expect(model.activeFilterCount == 3, "被筛过的屏写着「0 项筛选生效」就是这一格漏计的形状")
    }

    /// 「清除」在 Projects 同样要把三项条件一起撤掉（不然撤完还留着会话条件，页上却说已清除），
    /// 而时间区间**归全局那把尺管**：这一跳自己把它写成了「24 小时」（见桥文件头注释：
    /// 区间走既有的 `ShellModel.timeRange`，为的是不多一条 `.task`、不多一次取数），
    /// 所以清除之后屏幕上仍是 24 小时档 —— 那是页头的读数，不是这一跳的残留。
    @Test("项目地图的清除：三项条件归零，区间交还全局那把尺")
    func clearingProjectsJumpConditionsRestoresFullList() async {
        let (shell, recorder, host) = makeStage()
        let model = ProjectsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .projects, projectPath: alpha, sessionID: sessionA,
                              eventKinds: [.fileDeleted], timeRange: .last24Hours))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)
        #expect(model.recentChanges.count == 1)

        await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        let sent = await recorder.fileQueries
        #expect(sent.last?.sessionID == nil)
        #expect(sent.last?.kinds.isEmpty == true)
        #expect(sent.last?.projectPath == alpha, "清除只撤跳转带来的条件，选中哪个项目不归它管")
        // 手推：撤掉会话与种类之后，alpha 名下 24 小时窗内的是 engine（修改）与 legacy（删除）两条；
        // Generated.swift 在三天前，本来就落在窗外（它是区间那一档在筛，不是这一跳的残留）。
        #expect(model.recentChanges.count == 2)
        #expect(model.carriedJumpConditions.sessionID == nil)
        #expect(model.carriedJumpConditions.eventKinds.isEmpty)
        #expect(model.carriedJumpConditions.timeRange == .last24Hours)
        // 徽标只该剩下「区间不是全部」那一项：三项条件都撤干净了才会掉到 1。
        #expect(model.activeFilterCount == 1, "清除之后徽标必须只余区间那一项，多一项就是有条件没撤")
    }

    // MARK: ⑨b 命令页与风险页：这两格各收得下两类条件，收不下的不许谎报

    /// `CommandQuery` 有 `sessionID` 与 `dateRange`，所以会话与时间区间这两类条件在这一格
    /// 落得下去。判据仍然不看 `model.criteria`（字段被写了不等于发出去的那条带着它），
    /// 看记账替身里那条真 `CommandQuery` 与**服务端**算出的总数。
    /// 手推：会话 A 名下 `swift build` + `git commit` 两条 ⇒ 5 → 2。
    @Test("会话 → 命令页：发出去的 CommandQuery 带着 sessionID，服务端总数 5 → 2")
    func sessionLandsOnCommandQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = CommandsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .commands, sessionID: sessionA, timeRange: .all))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)

        let sent = await recorder.commandQueries
        #expect(sent.count >= 1, "命令页这一路没发查询 ⇒ 这一跳什么条件都没带过去")
        #expect(sent.last?.sessionID == sessionA, "发出去的那条 CommandQuery 没带会话条件")
        #expect(model.totalCount == 2)
        #expect(model.records.count == 2)
        #expect(shell.pendingJump == nil, "意图落完还留在外壳里 ⇒ 切回来会被旧条件再压一遍")
    }

    /// 这一格**过去**收不下项目那一维（`CommandQuery` 没字段），#81(a) 把字段补上之后就收得下了；
    /// 仍然收不下的是「事件种类」——`CommandQuery` 没有 `kinds`（它的两维是 `outcomes` / `agentKinds`，
    /// 与 `OperationKind` 不是一对一关系）。收不下的那一类继续不许谎报：谎报的后果不是「少筛一项」，
    /// 是屏幕上那颗 chip 写着「带着项目条件」而下面那屏其实没筛 —— 本波头号缺陷的形状。
    @Test("命令页收得下项目、仍收不下事件种类：落下的进真查询，收不下的不谎报")
    func commandsBoardHoldsProjectButStillNotKinds() async {
        let (shell, recorder, host) = makeStage()
        let model = CommandsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .commands, projectPath: alpha, sessionID: sessionA,
                              eventKinds: [.fileDeleted], timeRange: .all))
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()

        let sent = await recorder.commandQueries
        #expect(sent.last?.sessionID == sessionA, "收得下的那一类（会话）必须真的落进查询")
        #expect(sent.last?.projectPath == alpha,
                "项目现在收得下了：写进 criteria 却没上那条发出去的查询 ⇒ 这一跳只改了页")
        let carried = model.carriedJumpConditions
        #expect(carried.projectPath == alpha, "条件真进了查询，页面上那颗 chip 就必须说出来")
        #expect(carried.eventKinds.isEmpty, "同理：事件种类在命令页没有可落字段，报上去就是谎报")
        #expect(carried.sessionID == sessionA)
        #expect(model.activeFilterCount == 2, "徽标该数到会话 + 项目两项（原来只数得着一项）")
    }

    /// 项目条件进得了命令页的**真查询**，并且服务端给的行确实变少（5 → 2）。
    /// 判据不吃 `model.query`（字段被写了不等于那条查询带着它），也不吃本地数组过滤：
    /// 读的是替身记下的那条发出去的 `CommandQuery` 与服务端算出的 `totalCount` / 页内身份。
    /// 手推：alpha 名下 cmd1（swift build）+ cmd2（git commit）两条；
    /// cmd5 不带项目 ⇒ 任何项目条件下都不该出现（这一条就是钉它的）。
    @Test("项目 → 命令页：发出去的 CommandQuery 带着 projectPath，服务端总数 5 → 2")
    func projectLandsOnCommandQuery() async {
        let now = Date()
        let host = InMemoryObservatoryService()
        host.seed(sessions: seededSessions(now: now), events: seededEvents(now: now),
                  fileChanges: seededFileChanges(now: now), commands: seededCommands(now: now),
                  risks: seededRisks(now: now), projects: [])
        let service = ProjectScopedQueryService(forwardingTo: host)
        let shell = ShellModel(runtime: scopedRuntime(host: host, service: service))
        shell.timeRange = .all
        let model = CommandsModel(runtime: scopedRuntime(host: host, service: service))

        shell.jump(JumpIntent(target: .commands, projectPath: alpha, timeRange: .all))
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()

        let sent = await service.commandQueries
        #expect(sent.count >= 1, "命令页这一路没发查询 ⇒ 这一跳什么条件都没带过去")
        #expect(sent.last?.projectPath == alpha, "发出去的那条 CommandQuery 没带项目条件")
        #expect(model.totalCount == 2, "服务端没把命令页的结果集筛小（夹具全量是 5 条）")
        #expect(Set(model.records.map(\.id)) == Set([cmd1, cmd2]),
        "页内那两条必须是服务给的筛过的那两条（三条同刻 ⇒ 不比顺序，只比集合）")
        #expect(model.carriedJumpConditions.projectPath == alpha)

        // 清除：条件归零 ⇒ 服务端回到全量 5（撤完还带着项目条件就是「撤了个假清除」）。
        await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        let afterClear = await service.commandQueries
        #expect(afterClear.last?.projectPath == nil)
        #expect(model.carriedJumpConditions.projectPath == nil)
        #expect(model.totalCount == 5)
    }

    /// 项目条件进得了风险页的**真查询**，并且服务端给的行确实变少（5 → 2）。
    /// 风险的归属口径不是「风险自己带项目」，是「风险 → 会话 → 项目」：
    /// 夹具里 risk1/risk2 挂会话 A（alpha），risk3/4/5 挂会话 B（beta）⇒ alpha 那一条筛出 2 条。
    /// `SecurityModel.load()` 会发两条查询（第二条是「今日总数」那把独立的尺，`limit: 1`、
    /// 本来就不带项目条件），所以按本页那把尺的 `pageSize` 挑主查询。
    @Test("项目 → 风险页：发出去的 RiskQuery 带着 projectPath，服务端总数 5 → 2")
    func projectLandsOnRiskQuery() async {
        let now = Date()
        let host = InMemoryObservatoryService()
        host.seed(sessions: seededSessions(now: now), events: seededEvents(now: now),
                  fileChanges: seededFileChanges(now: now), commands: seededCommands(now: now),
                  risks: seededRisks(now: now), projects: [])
        let service = ProjectScopedQueryService(forwardingTo: host)
        let shell = ShellModel(runtime: scopedRuntime(host: host, service: service))
        shell.timeRange = .all
        let model = SecurityModel(runtime: scopedRuntime(host: host, service: service))

        shell.jump(JumpIntent(target: .security, projectPath: alpha, timeRange: .all))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)

        let sent = await service.riskQueries
        let main = sent.filter { $0.limit == SecurityModel.pageSize }
        #expect(main.count >= 1, "风险页这一路没发查询 ⇒ 这一跳什么条件都没带过去")
        #expect(main.last?.projectPath == alpha, "发出去的那条 RiskQuery 没带项目条件")
        #expect(model.totalCount == 2, "服务端没把风险页的结果集筛小（夹具全量是 5 条）")
        #expect(Set(model.events.map(\.id)) == Set([risk1, risk2]),
        "同上：risk1/risk2 同刻 ⇒ 比集合不比顺序")
        #expect(model.carriedJumpConditions.projectPath == alpha)

        await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        let afterClear = await service.riskQueries
        #expect(afterClear.filter { $0.limit == SecurityModel.pageSize }.last?.projectPath == nil)
        #expect(model.carriedJumpConditions.projectPath == nil)
        #expect(model.totalCount == 5)
    }

    /// #81(a) 顺带闭合的那处「不可达形状」：`differsFromCarried` 比的是四项全量，
    /// 而这两格过去读不回 `projectPath`（恒 nil）⇒ 任何带项目的意图都永远被判成「与本页不同」，
    /// §6 那条「条件没变就不重查」的成本闸在这一格对 `projectPath` **恒不成立**（不可达分支）。
    /// 字段接上之后它必须收敛：条件真的换了 ⇒ 发一条；同一条条件再推一遍 ⇒ 一条都不许多发。
    @Test("同一跳重复推：条件真变了发一条，条件没变不多发（两页都收敛得了）")
    func repeatedIdenticalJumpFiresNoExtraQuery() async {
        let (shell, recorder, host) = makeStage()
        let commands = CommandsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .commands, projectPath: alpha, timeRange: .all))
        EvidenceJumpWiring.seed(fromShell: shell, into: commands)
        await commands.load()
        let afterSeed = await recorder.commandQueries.count

        // 换成另一个项目 ⇒ 条件真的变了，必须发一条（这条是「闸没被焊死」的反证）。
        shell.jump(JumpIntent(target: .commands, projectPath: beta, timeRange: .all))
        await EvidenceJumpWiring.push(fromShell: shell, into: commands)
        let afterRealChange = await recorder.commandQueries.count
        #expect(afterRealChange == afterSeed + 1, "项目从 alpha 换成 beta 是条件真的变了 ⇒ 该发一条")
        #expect(commands.carriedJumpConditions.projectPath == beta)

        // 同一条意图再推一遍 ⇒ 一条都不许多发（这一格过去在这两页恒不成立）。
        shell.jump(JumpIntent(target: .commands, projectPath: beta, timeRange: .all))
        await EvidenceJumpWiring.push(fromShell: shell, into: commands)
        #expect(await recorder.commandQueries.count == afterRealChange,
                "同样的条件又重查一遍 ⇒ 这一页的 projectPath 没能读回来（不可达形状没闭合）")

        let security = SecurityModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .security, projectPath: beta, timeRange: .all))
        EvidenceJumpWiring.seed(fromShell: shell, into: security)
        await security.load()
        let risksAfterSeed = (await recorder.riskQueries)
            .filter { $0.limit == SecurityModel.pageSize }.count
        shell.jump(JumpIntent(target: .security, projectPath: beta, timeRange: .all))
        await EvidenceJumpWiring.push(fromShell: shell, into: security)
        let risksAfterRepeat = (await recorder.riskQueries)
            .filter { $0.limit == SecurityModel.pageSize }.count
        #expect(risksAfterRepeat == risksAfterSeed,
                "风险页同理：条件相等就不该再发一条（修之前这条恒多发一次）")
    }

    /// 清除在这一格同样要撤干净（撤完还留着会话条件，chip 却说已清除）。
    /// 手推：会话 A 那 2 条撤掉条件后回到全量 5 条。
    @Test("命令页的清除：会话条件归零，服务端总数回到全量 5")
    func clearingCommandsJumpConditions() async {
        let (shell, recorder, host) = makeStage()
        let model = CommandsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .commands, sessionID: sessionA, timeRange: .all))
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        #expect(model.totalCount == 2)

        await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        let sent = await recorder.commandQueries
        #expect(sent.last?.sessionID == nil, "清除之后发出去的那条查询还带着会话条件")
        #expect(model.carriedJumpConditions.sessionID == nil)
        #expect(model.totalCount == 5)
    }

    /// 「打开哪一条命令」与「把列表筛小」是两种语义，得分开钉（会话页同一对语义已经分开了）。
    /// 只带 `eventID` 的一跳：列表仍是全量，选中的是那一条。
    @Test("命令页那一格的定位：eventID 打开那一条命令，但不筛列表")
    func commandJumpFocusesTheRowWithoutFiltering() async {
        let (shell, recorder, host) = makeStage()
        let model = CommandsModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .commands, sessionID: nil, timeRange: .all, eventID: cmd3))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)

        #expect(model.selectedID == cmd3, "跳转说要打开这一条命令，详情栏却没过去")
        #expect(model.totalCount == 5, "eventID 不是筛选条件：列表该回到全量")
    }

    /// 风险页那一条 `RiskQuery` 同样有 `sessionID` / `dateRange`。
    /// `SecurityModel.load()` 会发**两条**查询（第二条是「今日总数」那把独立的尺，
    /// `limit: 1`），所以这里按本页那把尺的 `pageSize` 挑出主查询，别拿 `.last` 拿到小查询。
    /// 手推：会话 A 名下两条（高危命令 + 敏感路径）⇒ 5 → 2。
    @Test("会话 → 风险页：发出去的 RiskQuery 带着 sessionID，服务端总数 5 → 2")
    func sessionLandsOnRiskQuery() async {
        let (shell, recorder, host) = makeStage()
        let model = SecurityModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .security, sessionID: sessionA, timeRange: .all))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)

        let sent = await recorder.riskQueries
        let main = sent.filter { $0.limit == SecurityModel.pageSize }
        #expect(main.count >= 1, "风险页这一路没发主查询 ⇒ 这一跳什么条件都没带过去")
        #expect(main.last?.sessionID == sessionA)
        #expect(model.totalCount == 2)
        let carried = model.carriedJumpConditions
        #expect(carried.sessionID == sessionA)
        #expect(carried.projectPath == nil, "这一跳本来就只带了会话条件：没带的项不许报上去（现在字段有了，谎报更藏不住）")
    }

    /// #59 那条高危通知：装配口只写一个风险 id（冻结区 `RiskNotifications.swift:128` 那一句），
    /// 收编进 `JumpIntent.eventID` 之后，这一跳的语义必须是「打开那一条」而不是「把列表筛光」。
    /// 桥在 `push` 里对这一类意图只跳过重查、不跳过定位（见桥文件注释）；这条用例钉的就是
    /// 「通知点进来屏幕上什么都没发生」会不会回来。
    @Test("风险通知那一跳：只带 eventID ⇒ 打开那一条，列表回到全量")
    func riskNotificationJumpFocusesTheEvent() async {
        let (shell, recorder, host) = makeStage()
        let model = SecurityModel(runtime: runtime(host: host, service: recorder))
        model.range = .all
        shell.jump(JumpIntent(target: .security, eventID: risk2))
        let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
        #expect(jumped?.eventID == risk2, "冻结区那个读写口没落到跳转意图上")
        await model.load()
        await EvidenceJumpWiring.focus(jumped, into: model)

        #expect(model.selected?.id == risk2)
        #expect(model.totalCount == 5, "通知不是筛选条件：那一跳不该把列表筛小")
        #expect(model.carriedJumpConditions.sessionID == nil)
        #expect(shell.pendingJump == nil)
    }

    /// 风险页的清除：会话条件归零 ⇒ 服务端总数回到全量。
    @Test("风险页的清除：会话条件归零，服务端总数回到全量 5")
    func clearingSecurityJumpConditions() async {
        let (shell, recorder, host) = makeStage()
        let model = SecurityModel(runtime: runtime(host: host, service: recorder))
        shell.jump(JumpIntent(target: .security, sessionID: sessionB, timeRange: .all))
        EvidenceJumpWiring.seed(fromShell: shell, into: model)
        await model.load()
        #expect(model.totalCount == 3, "手推：会话 B 名下三条（低危 / 高危删除 / 十天前那条）")

        await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        let sent = await recorder.riskQueries
        let main = sent.filter { $0.limit == SecurityModel.pageSize }
        #expect(main.last?.sessionID == nil)
        #expect(model.carriedJumpConditions.sessionID == nil)
        #expect(model.totalCount == 5)
    }

    // MARK: ⑩ 接线本身（源码级）：桥在，视图与按钮也得在

    /// 「桥修好了但没人走」是这一族缺陷的第二个形状（`SidebarSearchWiringTests` 已经为它
    /// 写过一条同手法用例）。这里钉的是：六页都挂了 seed，seed 排在本页第一次 load 之前，
    /// 并且各页都订阅了「同页新意图」那条 push。
    ///
    /// 每页的加载任务得**各自报**：风险页的加载任务是无参的 `.task {`，拿整份文件的第一处
    /// `.task(id: ` 去比会稳定命中它后面那条 `.task(id: shell?.pendingJump)`（它在文件里
    /// 出现得更晚，seed 却在前面的加载任务里）⇒ 顺序核对会假红。与 `viewsMountTheBridge` 同一处置。
    @Test("六页都挂了这座桥：seed 在本页第一次取数之前，push 订阅在同页")
    func viewsMountTheJumpBridge() throws {
        let wired: [(file: String, loadTask: String)] = [
            ("Sources/AIObservatoryUI/Timeline/TimelineView.swift", ".task(id: shell?.timeRange)"),
            ("Sources/AIObservatoryUI/Sessions/SessionsView.swift", ".task(id: shell?.timeRange)"),
            ("Sources/AIObservatoryUI/Files/FilesView.swift", ".task(id: shell?.timeRange)"),
            ("Sources/AIObservatoryUI/Projects/ProjectsView.swift", ".task(id: effectiveRange)"),
            ("Sources/AIObservatoryUI/Commands/CommandsView.swift", ".task(id: shell?.timeRange)"),
            ("Sources/AIObservatoryUI/Security/SecurityView.swift", ".task {"),
        ]
        for entry in wired {
            let file = entry.file
            let text = try Self.codeOnly(file)
            #expect(text.contains("EvidenceJumpWiring.seed(fromShell: shell, into: model)")
                        || text.contains("let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)"),
                    "\(file) 不再在进板块时落跳转条件 ⇒ 首屏那次查询又是不筛的")
            #expect(text.contains("EvidenceJumpWiring.push(fromShell: shell, into: model)"),
                    "\(file) 不再订阅同页新到的跳转意图 ⇒ 详情里那颗跳转按钮点了没反应")
            #expect(text.contains(".task(id: shell?.pendingJump)"),
                    "\(file) 的 push 没有订阅外壳那条意图 ⇒ 桥在，腿断了")

            guard let taskMark = text.range(of: entry.loadTask) else {
                Issue.record("\(file) 里找不到本页的加载任务 \(entry.loadTask) ⇒ 顺序无从核对")
                continue
            }
            let body = text[taskMark.upperBound...]
            guard let seedAt = body.range(of: "EvidenceJumpWiring.seed"),
                  let loadAt = body.range(of: "await model.load()") else {
                Issue.record("\(file) 的加载任务里少了 seed 或 load ⇒ 接线被搬走或改名了")
                continue
            }
            #expect(seedAt.lowerBound < loadAt.lowerBound,
                    "\(file) 里 seed 排到了 load 之后 ⇒ 第一次查询又不带条件了")
        }
    }

    /// 键盘可达（验收第 4 条）。这里能机检的是「出口是不是标准按钮」：
    /// `Button` 才吃得到 Tab/Return，`.onTapGesture` 那一类手势在 macOS 上不带焦点。
    /// 「跳过去之后条件生效」由上面那批行为用例钉，两件事缺一都不算通。
    @Test("跳转出口与清除都是标准 Button：Tab/Return 走得通，清除另绑 Esc")
    func jumpAffordancesAreKeyboardReachable() throws {
        let producers: [(file: String, expectedJumps: Int)] = [
            // 项目详情：两颗（文件板块 / 时间板块）
            ("Sources/AIObservatoryUI/Projects/ProjectDetailView.swift", 2),
            // 会话详情：三颗（这一条会话的事件 / 文件变更 / 命令）
            // 第三颗是 #81 覆盖面收口时加的：`CommandQuery` 有 `sessionID`，
            // 「这条会话里跑过哪些命令」那一问不该再靠用户手打过滤 —— 上面
            // 「会话 → 命令页」那条用例钉的就是它带出去的那条真查询。
            ("Sources/AIObservatoryUI/Sessions/SessionDetailView.swift", 3),
            // 事件详情：两颗（这一类变更 / 这条会话）
            ("Sources/AIObservatoryUI/Timeline/TimelineEventDetail.swift", 2),
            // diff 面板：一颗（这一条变更回时间线；映射不到种类时那颗根本不排）
            ("Sources/AIObservatoryUI/Files/DiffView.swift", 1),
            // 命令详情：一颗（这一条命令是在什么现场跑的 → 时间线带上那一条会话）
            ("Sources/AIObservatoryUI/Commands/CommandsDetailView.swift", 1),
            // 风险页：两颗（卡片上那颗 + 详情栏那颗），都带上这一条风险的会话。
            // 这一格原来是 `shell?.select(.timeline)` —— 正是 #81 的原始缺陷形状，
            // 下面「跨页出口不再只改 selection」那条把它钉死。
            ("Sources/AIObservatoryUI/Security/SecurityView.swift", 2),
        ]
        for producer in producers {
            let text = try Self.codeOnly(producer.file)
            let jumps = text.components(separatedBy: "shell?.jump(JumpIntent(").count - 1
            #expect(jumps == producer.expectedJumps,
                    "\(producer.file) 里带条件跳转的出口数量变了：\(jumps) 颗")
            // 每一颗都得挂在 `Button` 的 action 上（手势不算键盘可达）。
            // 两种写法都数：`Button { … } label: { … }` 与 `Button(标题) { … }`。
            let buttons = text.components(separatedBy: "Button {").count - 1
                + text.components(separatedBy: "Button(").count - 1
            #expect(buttons >= producer.expectedJumps,
                    "\(producer.file) 的跳转出口不是标准 Button ⇒ Tab 走不到")
            #expect(!text.contains(".onTapGesture"),
                    "\(producer.file) 用 tap 手势做跳转 ⇒ 键盘用户按不到")
        }

        // ⚠️ 上面那道计数看不见这一格（本轮变异检查实测出来的形状）：把 `evidenceJumpButton` 的
        // **调用点**摘掉、只留那颗按钮的定义，`shell?.jump(JumpIntent(` 与 `Button {` 各一颗都还在，
        // 用例照样全绿 —— 而屏幕上永远排不出这颗按钮。所以"真的排了它"要单独钉一次。
        let diffPanel = try Self.codeOnly("Sources/AIObservatoryUI/Files/DiffView.swift")
        #expect(diffPanel.contains("evidenceJumpButton(for: change)"),
                "diff 面板那颗出口只剩定义、没有调用点 ⇒ 用户永远看不到它")

        // 目的页那一格的清除按钮：Esc（`.cancelAction`），且六页都排了。
        // ⚠️ 读的是**剥掉注释之后**的代码：这一份文件的文件头与 chip 的文档注释里都写着
        // 「.keyboardShortcut(.cancelAction)」这句话，拿整份源码去 contains 会在按钮被删掉之后
        // 仍然全绿（本仓为这个形状红过三次，`BilingualCopyGate.codeOnlyString` 就是为它存在的）。
        let chip = try Self.codeOnly("Sources/AIObservatoryUI/Shell/EvidenceJumpWiring.swift")
        #expect(chip.contains(".keyboardShortcut(.cancelAction)"),
                "清除那颗按钮不再绑 Esc ⇒ 「带着条件进来退不出去」回到只能靠鼠标")
        for file in [
            "Sources/AIObservatoryUI/Timeline/TimelineView.swift",
            "Sources/AIObservatoryUI/Sessions/SessionsView.swift",
            "Sources/AIObservatoryUI/Files/FilesView.swift",
            "Sources/AIObservatoryUI/Projects/ProjectsView.swift",
            "Sources/AIObservatoryUI/Commands/CommandsView.swift",
            "Sources/AIObservatoryUI/Security/SecurityView.swift",
        ] {
            let text = try Self.codeOnly(file)
            #expect(text.contains("EvidenceJumpChip(conditions: model.carriedJumpConditions)"),
                    "\(file) 不再显示「这一屏带着跳转条件」⇒ 条件真筛小了也没人知道")
        }
    }

    /// 不许有人把「只改 selection」当成跳转：那正是 #81 的原始缺陷形状。
    @Test("跨页出口不再只改 selection（那等于什么都没带）")
    func crossPageButtonsCarryConditions() throws {
        let detail = try Self.codeOnly("Sources/AIObservatoryUI/Projects/ProjectDetailView.swift")
        #expect(!detail.contains("shell?.selection = .files"),
                "项目详情的跨页按钮退回了只改 selection ⇒ 跳过去看到的还是全量")
        #expect(!detail.contains("shell?.selection = .timeline"))

        // 风险页那两颗出口原来是 `shell?.select(.timeline)`：#81 的原始缺陷形状
        // 就长在这一格上（跳过去了，看到的是全量时间线，读成的却是「这一条风险的来龙去脉」）。
        let security = try Self.codeOnly("Sources/AIObservatoryUI/Security/SecurityView.swift")
        #expect(!security.contains("shell?.select(.timeline)"),
                "风险页的取证出口退回只改 selection ⇒ 「这一条风险」那句话又成了空话")
        #expect(!security.contains("shell?.selection = .timeline"))

        // 侧栏那九行是纯路由，本来就**不该**带条件（它不知道用户要去干什么）。
        let root = try Self.codeOnly("Sources/AIObservatoryUI/Shell/ObservatoryRootView.swift")
        #expect(root.contains("shell.select(section)"))
    }

    /// 「0 项筛选生效」而列表已被筛过，是同一条缺陷的另一半：徽标只统计本页有控件的那几项。
    @Test("徽标数得算上跳转带来的两项：项目 / 会话在时间线与文件页都算一项筛选")
    func jumpedConditionsCountTowardTheFilterBadge() async {
        let (shell, _, host) = makeStage()
        let timeline = TimelineModel(runtime: runtime(host: host, service: QueryRecordingService(forwardingTo: host)))
        #expect(timeline.activeFilterCount == 0)
        shell.jump(JumpIntent(target: .timeline, projectPath: alpha, sessionID: sessionA))
        EvidenceJumpWiring.seed(fromShell: shell, into: timeline)
        #expect(timeline.activeFilterCount == 2, "跳过来的两项条件必须让「N 项筛选生效」跟着动")

        let files = FilesModel(runtime: runtime(host: host, service: QueryRecordingService(forwardingTo: host)))
        #expect(files.activeFilterCount == 0, "文件页默认区间是「全部」，不该白送一项")
        shell.jump(JumpIntent(target: .files, sessionID: sessionA))
        EvidenceJumpWiring.seed(fromShell: shell, into: files)
        #expect(files.activeFilterCount == 1)
    }

    // MARK: - 解析

    /// 剥掉注释与 `#Preview` 之后的代码（门禁那套尺子的入口，免得被自己写的解释注释判红）。
    private static func codeOnly(_ relative: String) throws -> String {
        try BilingualCopyGate.codeOnlyString(relative)
    }
}
