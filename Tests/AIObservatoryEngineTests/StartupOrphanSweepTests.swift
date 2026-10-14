//
//  StartupOrphanSweepTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws-engaudit
//
//  #39（需求④ 的最后一块）：异常退出之后库里永远挂着"运行中"。
//
//  真库证据（`ai-observatory/tmp/verify-realdata/observatory.sqlite`，`-readonly`，2026-09-21）：
//    · `agents` 6 行里 **5 行的 pid 已经不存在**，却仍记 `state='running'`；
//    · 其中两个死 Agent 名下共 **15 条** `outcome='running' AND ended_at IS NULL`；
//    · 全库 `running 372 / terminated 86` —— 那 86 条全部来自 ⌘Q（走 `stop()`），
//      强杀 / 崩溃 / 断电那条路径根本不经过退出结算。
//  ⚠️ 同一个库里那个**还活着**的 Agent 名下有 357 条开放命令：那是进程轮询看不到退出码的
//  已知口径，不是孤儿 ⇒ "只收口 pid 已经不在了的那批"是这条修复的边界，
//  下面专门有一条阴性用例钉住它（把它做成"所有 running 一律收掉"的，那条会红）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
@testable import AIObservatoryEngine

/// 相对 now，不用常量：默认保留期 30 天，摆到几个月前会让同一轮的 `pruneIfNeeded` 先把样本删掉
/// （今天 ICR-0004 那组用例已经因为同一件事飘过一次）。
/// 「活」还必须**观测上活**：`sync` 的 `isStale` 会按 `lastSeenAt` 把列表里的 Agent 判成超时结算——
/// 第一版我把活 Agent 的 lastSeenAt 摆在 15 分钟前，于是它的会话被既有路径关掉、命令被判
/// terminated，看起来像"我的收口误伤了活的"，其实是 fixture 自己造的形状。
private let sweepBase = Date().addingTimeInterval(-900)
/// 活 Agent 的行与本轮检出都取"刚刚"，只有死掉的才留在过去。
private let liveSeen = Date()

private enum OrphanFixture {
    /// 死掉的 Agent：库里有行、pid 已不存在、状态还写着 running。
    static let deadAgentID = StableID.uuid(namespace: "orphansweep", key: "dead-agent")
    static let deadSessionID = StableID.uuid(namespace: "orphansweep", key: "dead-session")
    /// 本轮仍被识别出的 Agent：它名下的开放命令**不许**被动。
    static let liveAgentID = StableID.uuid(namespace: "orphansweep", key: "live-agent")
    static let liveSessionID = StableID.uuid(namespace: "orphansweep", key: "live-session")

    /// 高过 macOS 默认 pid 上界（99 999）⇒ 不可能被复用成别的真进程。
    static let deadPID: Int32 = 4_000_100
    static let livePID: Int32 = 4_000_101

    static func agent(id: UUID, pid: Int32, lastSeen: Date, state: AgentRunState = .running) -> AgentInstance {
        AgentInstance(id: id, kind: .claudeCode, pid: pid, displayName: "Claude Code",
                      executablePath: "/usr/local/bin/claude", workingDirectory: "/work/orphan",
                      startedAt: lastSeen.addingTimeInterval(-300), lastSeenAt: lastSeen, state: state,
                      cpuPercent: 5, memoryBytes: 4_096, childPIDs: [], detectedVia: .executablePath)
    }

    static func session(id: UUID, agentID: UUID, endedAt: Date?) -> AgentSession {
        AgentSession(id: id, kind: .claudeCode, agentID: agentID, title: "会话 · 收口",
                     projectPath: "/work/orphan", startedAt: sweepBase, endedAt: endedAt,
                     outcome: endedAt == nil ? .running : .success)
    }

    static func command(id: UUID, agentID: UUID, sessionID: UUID) -> CommandRecord {
        CommandRecord(id: id, executable: "swift", arguments: ["test"], workingDirectory: "/work/orphan",
                      agentID: agentID, sessionID: sessionID, agentKind: .claudeCode,
                      startedAt: sweepBase.addingTimeInterval(5), outcome: .running)
    }

    /// 死 Agent：3 条开放命令 + 一条未结算会话；活 Agent：5 条开放命令 + 一条未结算会话。
    static func seed(_ store: ObservatoryStore) async throws {
        try await store.upsertAgents([
            agent(id: deadAgentID, pid: deadPID, lastSeen: sweepBase.addingTimeInterval(60)),
            agent(id: liveAgentID, pid: livePID, lastSeen: liveSeen),
        ])
        try await store.upsertSessions([
            session(id: deadSessionID, agentID: deadAgentID, endedAt: nil),
            session(id: liveSessionID, agentID: liveAgentID, endedAt: nil),
        ])
        for index in 0..<3 {
            await store.append(command(id: StableID.uuid(namespace: "orphansweep", key: "dead-\(index)"),
                                       agentID: deadAgentID, sessionID: deadSessionID))
        }
        for index in 0..<5 {
            await store.append(command(id: StableID.uuid(namespace: "orphansweep", key: "live-\(index)"),
                                       agentID: liveAgentID, sessionID: liveSessionID))
        }
        await store.flush()
    }
}

@Suite("启动孤儿收口：只收 pid 已经不在了的那批", .timeLimit(.minutes(1)))
struct StartupOrphanSweepTests {

    private func makeEngine(store: ObservatoryStore) -> ObservatoryEngine {
        ObservatoryEngine(
            settings: ObservatorySettings(
                monitoredRoots: [], ignoredPathPatterns: [], processScanIntervalSeconds: 3_600
            ),
            components: ObservatoryEngine.Components(
                storeSource: .ready(store),
                detector: StubDetector(agents: [OrphanFixture.agent(
                    id: OrphanFixture.liveAgentID, pid: OrphanFixture.livePID, lastSeen: liveSeen
                )]),
                processInspector: StubProcessSource(),
                metrics: StubMetrics(),
                commandAuditor: StubAuditor(),
                fileObserver: StubFileObserver(),
                snapshotter: StubSnapshotter(),
                differ: StubDiffer(),
                projectMapper: ProjectMapper(resolver: { _ in nil })
            )
        )
    }

    private func outcomes(_ store: ObservatoryStore, agentID: UUID) async throws -> [CommandOutcome] {
        let rows = try await store.commands(matching: CommandQuery(sessionID: nil)).items
        return rows.filter { $0.agentID == agentID }.map(\.outcome)
    }

    @Test("死 Agent 的 3 条开放命令落为 terminated，`ended_at` 取它最后可见的时刻（上界口径）")
    func deadAgentsCommandsAreSettled() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await OrphanFixture.seed(store)
        let engine = makeEngine(store: store)
        await engine.start()
        await engine.rescanNow()
        await store.flush()

        let dead = try await store.commands(matching: .all).items
            .filter { $0.agentID == OrphanFixture.deadAgentID }
        #expect(dead.count == 3)
        #expect(Set(dead.map(\.outcome)) == [.terminated], "死 Agent 的开放命令必须全部收口")
        let expectedEnd = sweepBase.addingTimeInterval(60)
        for record in dead {
            #expect(record.endedAt == expectedEnd,
                    "必须是我这条收口写的（Agent 最后可见时刻）；若是本轮 now，说明动它的是别的路径")
        }
        await engine.stop()
    }

    @Test("阴性对照：还活着的 Agent 名下 5 条开放命令一格都不许动")
    func liveAgentsCommandsStayRunning() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await OrphanFixture.seed(store)
        let engine = makeEngine(store: store)
        await engine.start()
        await engine.rescanNow()
        await store.flush()

        let live = try await store.commands(matching: .all).items
            .filter { $0.agentID == OrphanFixture.liveAgentID }
        #expect(live.count == 5)
        #expect(Set(live.map(\.outcome)) == [.running],
                "轮询看不到退出码 ≠ 进程没了；一律收口就是凭空造事实（真库里这有 357 条）")
        #expect(live.allSatisfy { $0.endedAt == nil })
        await engine.stop()
    }

    @Test("死 Agent 的行判为 terminated、未结算会话落为 interrupted；活的那个两样都不动")
    func agentRowsAndSessionsAreSettled() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await OrphanFixture.seed(store)
        let engine = makeEngine(store: store)
        await engine.start()
        await engine.rescanNow()
        await store.flush()

        let agents = try await store.activeAgents()
        #expect(agents.first { $0.id == OrphanFixture.deadAgentID } == nil,
                "死 Agent 行已不是 running/idle ⇒ 不该再出现在活跃集里")
        #expect(agents.first { $0.id == OrphanFixture.liveAgentID }?.state == .running)

        let deadSession = try #require(await store.session(id: OrphanFixture.deadSessionID))
        #expect(deadSession.endedAt == sweepBase.addingTimeInterval(60))
        #expect(deadSession.outcome == .interrupted, "进程没了既不是成功也不是失败，只能是中断")
        let liveSession = try #require(await store.session(id: OrphanFixture.liveSessionID))
        #expect(liveSession.endedAt == nil, "活 Agent 的会话必须继续开着——那是续接功能的本意")
        await engine.stop()
    }

    @Test("收口只做一次：第二轮启动不再重收（它是启动账，不是每轮账）")
    func sweepRunsOnlyOnce() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await OrphanFixture.seed(store)
        let engine = makeEngine(store: store)
        await engine.start()
        await engine.rescanNow()
        // 第一轮之后再给死 Agent 补一条开放命令：本轮已经不再运行收口，它应保持 running。
        await store.append(OrphanFixture.command(
            id: StableID.uuid(namespace: "orphansweep", key: "late"),
            agentID: OrphanFixture.deadAgentID, sessionID: OrphanFixture.deadSessionID
        ))
        await store.flush()
        await engine.rescanNow()
        await store.flush()

        let late = try #require((try await store.commands(matching: .all)).items
            .first { $0.id == StableID.uuid(namespace: "orphansweep", key: "late") })
        #expect(late.outcome == .running, "启动收口不当事务性兜底；每轮的路径是 settleOpenCommands")
        let early = (try await store.commands(matching: .all)).items
            .filter { $0.agentID == OrphanFixture.deadAgentID }
            .filter { $0.outcome == .terminated }
        #expect(early.count == 3, "第一轮收掉的还是那 3 条，没有多收")
        await engine.stop()
    }
}
