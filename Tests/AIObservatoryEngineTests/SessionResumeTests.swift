//
//  SessionResumeTests.swift
//  AIObservatoryEngineTests
//
//  Owner: master-controller
//
//  N1 的回归：观测站重启后，同一个还活着的 Agent 必须**续用**原来那条会话。
//  真机代价很直观——反复重启后 Dashboard 上同一个 Codex 进程（PID 32,630，01:34 启动）
//  留下 9 条 0 秒会话，而需求要的是「运行时长 2 小时 15 分钟」。
//

import Foundation
import Testing
@testable import AIObservatoryEngine
import AIObservatoryCore

@Suite("Engine: 重启续接未结算会话（N1）", .timeLimit(.minutes(1)))
struct SessionResumeTests {

    private static let started = Date(timeIntervalSince1970: 1_800_000_000)
    private static let now = Date(timeIntervalSince1970: 1_800_000_000 + 8 * 3600)

    private func agent(id: UUID = UUID(), pid: Int32 = 4242) -> AgentInstance {
        AgentInstance(
            id: id,
            kind: .claudeCode,
            pid: pid,
            displayName: "Claude Code",
            executablePath: "/usr/local/bin/claude",
            workingDirectory: "/Users/testhost/proj",
            startedAt: Self.started,
            lastSeenAt: Self.now,
            state: .running,
            cpuPercent: 1.5,
            memoryBytes: 120 * 1024 * 1024,
            detectedVia: .executablePath
        )
    }

    private func openSession(agentID: UUID, displayIndex: Int = 1) -> AgentSession {
        AgentSession(
            id: UUID(),
            displayIndex: displayIndex,
            kind: .claudeCode,
            agentID: agentID,
            title: "Claude Code · 续接",
            projectPath: "/Users/testhost/proj",
            startedAt: Self.started,
            endedAt: nil,
            outcome: .running
        )
    }

    @Test("不续接时确实会另开一条（对照组：证明下面那条断言不是恒真）")
    func withoutResumeOpensSecondSessionForSameAgent() async {
        let lifecycle = SessionLifecycleManager()
        let instance = agent()
        let result = await lifecycle.sync(agents: [instance], at: Self.now)
        #expect(result.opened.count == 1)
        // 原来写的是 `== Self.now || (… ?? .distantPast) >= Self.started`：右半对任何
        // 晚于 started 的时刻都成立，而新开的会话本来就晚于 started ⇒ 整个断言恒真，
        // 「对照组」其实根本没在对照。
        // 会话起点取 **Agent 进程自己的启动时刻**（SessionLifecycleManager:336 用
        // `record.snapshot.startedAt`），不是「我们什么时候看见它」——否则需求点名的
        // 「运行时长」会被重启次数切碎。原断言用 `== now || >= started` 把这个区别抹平了。
        #expect(result.opened.first?.startedAt == Self.started,
                "新开会话必须从 Agent 进程启动时刻算起，而不是扫描时刻")
    }

    @Test("续接后同一个 agent 不再开新会话，startedAt 保持原值")
    func resumeKeepsTheOriginalSession() async {
        let lifecycle = SessionLifecycleManager()
        let instance = agent()
        let existing = openSession(agentID: instance.id)

        await lifecycle.resume(sessions: [existing], at: Self.now)
        let result = await lifecycle.sync(agents: [instance], at: Self.now)

        #expect(result.opened.isEmpty, "续接过的 agent 不该再被开一条会话")
        #expect(await lifecycle.sessionID(forAgentID: instance.id) == existing.id)
        #expect(await lifecycle.currentSessions().first?.startedAt == Self.started,
                "运行时长必须从最初那次启动算，不是从重启那一刻算")
    }

    @Test("续接时 pid 未知，首次 sync 后按 pid 也能查到会话")
    func pidIsRepairedOnFirstSync() async {
        let lifecycle = SessionLifecycleManager()
        let instance = agent(pid: 8123)
        let existing = openSession(agentID: instance.id)
        await lifecycle.resume(sessions: [existing], at: Self.now)

        // 续接当下还没有 pid 索引（AgentSession 不带 pid）。
        #expect(await lifecycle.sessionID(forPID: 8123) == nil)

        _ = await lifecycle.sync(agents: [instance], at: Self.now)
        #expect(await lifecycle.sessionID(forPID: 8123) == existing.id,
                "补不上 pid 的话，命令归因会在重启后整段丢失")
    }

    @Test("已结算的会话不会被续接回来")
    func ignoresSettledSessions() async {
        let lifecycle = SessionLifecycleManager()
        var closed = openSession(agentID: UUID())
        closed.endedAt = Self.now
        closed.outcome = .success

        await lifecycle.resume(sessions: [closed], at: Self.now)
        #expect(await lifecycle.currentSessions().isEmpty)
    }

    @Test("续接后 displayIndex 不从 1 重来（编号撞车会让列表身份混乱）")
    func displayIndexContinuesPastResumed() async {
        let lifecycle = SessionLifecycleManager()
        let instance = agent()
        await lifecycle.resume(sessions: [openSession(agentID: instance.id, displayIndex: 7)], at: Self.now)

        // 另一个 agent 才应该拿到 8。
        let other = agent(id: UUID(), pid: 999)
        _ = await lifecycle.sync(agents: [instance, other], at: Self.now)
        let sessions = await lifecycle.currentSessions().map(\.displayIndex).sorted()
        // 原来 `contains(7)` + `max() >= 8`：续接进来的 7 与随便一个大数就能过，
        // 哪怕编号器给新 agent 发了 999 或者把两条都编号成 7 也看不见。
        #expect(sessions == [7, 8], "续接的 7 保留，新 agent 拿到下一个编号")
        #expect(Set(sessions).count == sessions.count, "displayIndex 不得重复：\(sessions)")
    }
}
