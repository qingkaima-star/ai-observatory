//
//  ProjectRootHonestyTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine
//  ─────────────────────────────────────────────────────────
//  钉住「项目根归属不许给出一个看起来合理的答案」这条口径（简报 §1.5 / D2）。
//
//  为什么专门写这一组：真机实测到 `ws/engperf` 基线（main `7473697`）上仍然在产出伪项目——
//  一次 180 秒窗口的落库里
//      sessions: display_index=3, kind=openAICodex, project_path='/'
//      projects: path='/'  name='/'  session_count=1
//              agent_contributions_json=[{"kind":"openAICodex","eventCount":1,"relativeShare":1}]
//  肇事进程是 `AGENT|32630|openAICodex|/Applications/ChatGPT.app/Contents/Resources/codex|cwd=/`。
//  检出侧的守卫（`attributedAgent` 走 `isUsableAttributionRoot`，main `62b46d78`）把
//  `file_change_count` 挡成了 0，但**会话与项目这两条通路没有那道守卫**：
//  `SessionLifecycleManager` 把 `agent.workingDirectory` 原样写进 `AgentSession.projectPath`，
//  `ProjectMapper.aggregate` 又对记录自带的 `projectPath` 只判「非空 + 未命中忽略」。
//  于是一条 `path='/'` 的项目进了库、并被界面当成真实项目呈现。
//  对审计工具来说这是**假证据**，比少一格归属更糟——所以每条通路都要求「判不出来就 nil」。
//
//  断言全部是照夹具手算的字面量，不从实现读回（见 AGENTS 断言口径）。
//

import Foundation
import Testing
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryPlatform

private enum Root {
    /// 三层深度、确定可用的项目根。刻意用 `testhost` 而不是真用户，避免把宿主路径写进测试。
    static let usable = "/Users/testhost/Projects/Mona"
    static let tooShallow = "/"
    static let halfRoot = "/Users"
    static let trailingSlash = "/Users/testhost/Projects/Mona/"
    /// 两个分量、按现行口径**可用**的最浅路径——把门槛钉成「≥2 分量」而不是碰巧。
    static let twoComponents = "/Applications/Some.app"
    /// 一个分量的系统目录：按同一口径被拒（`/Applications` 只有一个路径分量）。
    static let oneComponent = "/Applications"
}

private func harness(agents: [AgentInstance]) async throws -> (ObservatoryEngine, ObservatoryStore) {
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let engine = ObservatoryEngine(
        settings: ObservatorySettings(processScanIntervalSeconds: 3_600),
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: StubDetector(agents: agents),
            processInspector: StubProcessSource(records: []),
            metrics: StubMetrics(),
            commandAuditor: StubAuditor(),
            fileObserver: StubFileObserver(),
            snapshotter: StubSnapshotter(),
            differ: StubDiffer()
        )
    )
    return (engine, store)
}

private func agent(
    id: UUID = UUID(),
    pid: Int32 = 4242,
    workingDirectory: String?
) -> AgentInstance {
    AgentInstance(
        id: id,
        kind: .openAICodex,
        pid: pid,
        displayName: "Codex",
        executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
        workingDirectory: workingDirectory,
        startedAt: Date(timeIntervalSince1970: 1_800_000_000),
        lastSeenAt: Date(timeIntervalSince1970: 1_800_000_003)
    )
}

@Suite("§1.5 项目根可用性：宁缺毋滥", .timeLimit(.minutes(1)))
struct ProjectRootHonestyTests {

    // MARK: - 判定口径本身（三条来源共用那一把尺子）

    @Test("usableRoot 的采纳与拒绝边界")
    func usableRootBoundaries() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        #expect(ProjectMapper.usableRoot(for: Root.usable) == Root.usable, "三层深度的根必须原样采纳")
        #expect(ProjectMapper.usableRoot(for: nil) == nil)
        #expect(ProjectMapper.usableRoot(for: "") == nil)
        #expect(ProjectMapper.usableRoot(for: Root.tooShallow) == nil, "'/' 会吞掉全盘世界")
        #expect(ProjectMapper.usableRoot(for: Root.halfRoot) == nil, "家目录的父目录同样是半截根")
        #expect(ProjectMapper.usableRoot(for: home) == nil, "家目录本身不是项目根")
        // 采纳时**不改写**候选：分组键与 ProjectActivity.id 必须与库里已有的行对得上。
        #expect(ProjectMapper.usableRoot(for: Root.trailingSlash) == Root.trailingSlash,
                "守卫只判可用性，不顺手规范化路径（那会让同一个根产出两个分组键）")
        // 现行门槛是「至少两个分量」，所以 /Applications 是**过**的。钉住它，
        // 免得将来有人把门槛调到三层而没人发现一批既有项目行从此不再被采纳。
        #expect(ProjectMapper.usableRoot(for: Root.twoComponents) == Root.twoComponents)
        #expect(ProjectMapper.usableRoot(for: Root.oneComponent) == nil,
                "路径分量不按开头的斜杠计数：/Applications 只有 1 个分量 ⇒ 按同一口径被拒")
    }

    // MARK: - 来源一：注入的 resolver

    @Test("注入的 resolver 返回 '/' 时，五路输入一律不产出分组")
    func resolverCannotProduceRootSlash() {
        // 默认那个 resolver 自身不会返回 '/' 或家目录（`Formatting.swift:147-161` 的循环就排除了），
        // 但它是**注入的闭包**：守卫必须设在 mapper 的出口，而不是信任每个实现。
        let mapper = ProjectMapper(resolver: { _ in "/" })
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)

        #expect(mapper.projectPath(for: "/anywhere/file.swift") == nil)
        #expect(mapper.aggregate(
            changes: [FileChange(path: "/anywhere/file.swift", kind: .modified, timestamp: stamp)],
            commands: [CommandRecord(executable: "swift", arguments: [], startedAt: stamp)],
            events: [TimelineEvent(timestamp: stamp, kind: .fileModified, title: "改了一个文件", filePath: "/anywhere/file.swift")],
            sessions: [AgentSession(kind: .openAICodex, title: "t", projectPath: "/", startedAt: stamp)],
            risks: [RiskEvent(timestamp: stamp, level: .medium, category: .unknown, title: "r", filePaths: ["/anywhere/file.swift"])]
        ).isEmpty, "一个 '/' 项目根下五类记录各喂一条，项目地图必须一条分组都不产出")
    }

    // MARK: - 来源二：记录自带的 projectPath（此前只判「非空」）

    @Test("记录自带 projectPath='/' 时不进分组；合法根照常计入")
    func statedProjectPathIsGuarded() throws {
        let stamp = Date(timeIntervalSince1970: 1_800_000_000)
        let mapper = ProjectMapper(resolver: { _ in nil })   // resolver 一律判不出来 → 只看 stated

        // 只有 '/' 的会话：没有任何分组产出（历史行为是产出一条 path='/' 的伪项目）。
        #expect(mapper.aggregate(
            changes: [], commands: [], events: [],
            sessions: [AgentSession(kind: .openAICodex, title: "t", projectPath: "/", startedAt: stamp)],
            risks: []
        ).isEmpty)

        // 混合：'/' 的那条被跳过，合法那条照常计数——守卫不是「一律不采纳」。
        let mixed = mapper.aggregate(
            changes: [], commands: [], events: [],
            sessions: [
                AgentSession(kind: .openAICodex, title: "bogus", projectPath: "/", startedAt: stamp),
                AgentSession(kind: .claudeCode, title: "real", projectPath: Root.usable, startedAt: stamp),
            ],
            risks: []
        )
        #expect(mixed.count == 1)
        let kept = try #require(mixed.first)
        #expect(kept.path == Root.usable)
        #expect(kept.sessionCount == 1, "只该计入那一条合法会话")
        #expect(kept.agentContributions.count == 1)
        #expect(kept.agentContributions.first?.kind == .claudeCode)
        #expect(kept.id == ProjectActivity.identity(path: Root.usable))
    }

    // MARK: - 来源三：Agent 的 cwd → 会话 projectPath

    @Test("cwd 为 '/' 的 Agent 开会话：projectPath 为 nil，而不是 '/'")
    func sessionAdoptsOnlyUsableCwd() async throws {
        let lifecycle = SessionLifecycleManager()
        let opened = await lifecycle.sync(agents: [agent(workingDirectory: "/")], at: Date(timeIntervalSince1970: 1_800_000_000))
        let session = try #require(opened.opened.first)
        #expect(session.projectPath == nil, "cwd='/' 必须记成「未归属」，而不是记成整台机器")

        // 对照组：合法 cwd 照常采纳，否则这条守卫就成了「一律不采纳」。
        let legit = await SessionLifecycleManager().sync(
            agents: [agent(workingDirectory: Root.usable)],
            at: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(try #require(legit.opened.first).projectPath == Root.usable)
    }

    @Test("缺席宽限期内补到合法 cwd 才写 projectPath；'/' 永远补不进去")
    func backfillRejectsUnusableCwd() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        _ = await lifecycle.sync(agents: [agent(id: agentID, workingDirectory: nil)], at: at)

        // 先补一个 '/'：不算「拿到归属」，projectPath 仍为 nil。
        let bogus = await lifecycle.sync(agents: [agent(id: agentID, workingDirectory: "/")], at: at.addingTimeInterval(3))
        #expect(bogus.updated.isEmpty, "把 nil 换成 nil 不是更新，不该广播一条假 updated")

        // 再补一个合法根：正常补齐并计入 updated。
        let fixed = await lifecycle.sync(
            agents: [agent(id: agentID, workingDirectory: Root.usable)], at: at.addingTimeInterval(6)
        )
        #expect(try #require(fixed.updated.first).projectPath == Root.usable)
    }

    // MARK: - 生产形状：引擎端到端

    /// 直接复现真机那次落库：注入一个 cwd 为 `/` 的 Agent，跑一轮完整采集。
    @Test("端到端：cwd='/' 的 Agent 不再让 sessions.project_path 或 projects 出现 '/'")
    func engineTickDoesNotPersistSlashProject() async throws {
        let (engine, store) = try await harness(agents: [agent(workingDirectory: "/")])
        await engine.rescanNow()
        await store.flush()

        let sessions = try await engine.sessions(matching: .all).items
        #expect(sessions.count == 1)
        #expect(sessions.first?.projectPath == nil)

        let projects = try await engine.projects()
        #expect(projects.isEmpty, "真机基线上这里曾经躺着一条 path='/' 的伪项目")
        #expect(!projects.contains { $0.path == "/" })
    }

    @Test("端到端对照：合法 cwd 的 Agent 照常产出它的项目行")
    func engineTickStillPersistsLegitProject() async throws {
        let (engine, _) = try await harness(agents: [agent(workingDirectory: Root.usable)])
        await engine.rescanNow()

        let projects = try await engine.projects()
        #expect(projects.count == 1)
        let project = try #require(projects.first)
        #expect(project.path == Root.usable)
        #expect(project.name == "Mona", "项目名取根的最后一个路径分量")
        #expect(project.sessionCount == 1)
    }
}
