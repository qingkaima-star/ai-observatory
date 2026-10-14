//
//  SessionAbsenceGraceTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine
//  ─────────────────────────────────────────────────────────
//  钉住「agent 缺席一次不再立刻结算会话」（简报 §1.4 / D1）。
//
//  病症（真机出现过 11 秒内会话数 1 → 15）：`sync` 每 3 秒收到一次「本轮 Agent 全集」，
//  而漏检是常态（某次读不到 argv、bundle 归并的成员集合瞬时变化）。旧实现里
//  **一次缺席 = 一条已结算会话 + 下一轮一条新会话**，每次抖动还要 upsert 行、重算聚合、
//  向界面广播——既是每-tick 成本，也把「一个活了两小时的进程」拆成一串短会话。
//
//  本文件把两件事分开钉：
//    · 宽限吸收了单轮漏检（同一条会话 id、同一起点、不产出任何 SyncResult 栏位）；
//    · 三条「不等宽限」的例外原样保留（idleTimeout / pid 复用 / closeAll）。
//  期望时刻全部照 `absenceGrace = 6` 与 3 秒节奏手算成字面量，不从实现读回。
//

import Foundation
import Testing
@testable import AIObservatoryEngine
import AIObservatoryCore

private enum Clock {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func after(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
}

private func agentWith(
    id: UUID,
    pid: Int32 = 4242,
    lastSeenAt: Date = Clock.t0
) -> AgentInstance {
    AgentInstance(
        id: id,
        kind: .claudeCode,
        pid: pid,
        displayName: "Claude",
        executablePath: "/usr/local/bin/claude",
        workingDirectory: "/Users/testhost/Projects/Mona",
        startedAt: Clock.t0,
        lastSeenAt: lastSeenAt
    )
}

private func manager(grace: TimeInterval) -> SessionLifecycleManager {
    SessionLifecycleManager(configuration: SessionLifecycleManager.Configuration(
        idleTimeout: 120, minimumSessionSeconds: 5, absenceGrace: grace
    ))
}

@Suite("§1.4 缺席宽限：单轮漏检不拆会话", .timeLimit(.minutes(1)))
struct SessionAbsenceGraceTests {

    /// 手算节奏（grace = 6 秒、每 3 秒一轮）：
    /// t=0 开会话 → t=3 第一次缺席（只记时刻）→ t=6 缺席 3 秒（未到期）→ t=9 缺席满 6 秒 → 结算。
    @Test("默认宽限下，缺席要连满 6 秒才结算，且收口到结算那一轮")
    func absenceSettlesOnlyAfterGrace() async throws {
        let lifecycle = manager(grace: 6)
        let agentID = UUID()
        let opened = await lifecycle.sync(agents: [agentWith(id: agentID)], at: Clock.after(0))
        let session = try #require(opened.opened.first)

        for second in [3.0, 6.0] {
            let result = await lifecycle.sync(agents: [], at: Clock.after(second))
            #expect(result.closed.isEmpty, "缺席 \(second - 3) 秒（自第一次缺席算起）不该结算")
            #expect(result.opened.isEmpty, "宽限期内不该重开会话")
            #expect(await lifecycle.currentSessions().count == 1, "会话要原样留在打开态")
        }

        let settled = await lifecycle.sync(agents: [], at: Clock.after(9))
        let closed = try #require(settled.closed.first)
        #expect(closed.id == session.id, "结算的必须是同一条会话，而不是新造一条")
        #expect(closed.endedAt == Clock.after(9), "口径：收口到真正结算那一轮的时刻")
        #expect(closed.outcome == .success, "存活 9 秒 ≥ minimumSessionSeconds 5 秒 → 判成功")
        #expect(await lifecycle.currentSessions().isEmpty)
    }

    @Test("宽限期内重新检出 → 同一条会话继续，不结算、不另开、不消耗编号")
    func flickerKeepsTheSameSession() async throws {
        let lifecycle = manager(grace: 6)
        let firstID = UUID()
        let original = try #require((await lifecycle.sync(agents: [agentWith(id: firstID)], at: Clock.after(0))).opened.first)

        _ = await lifecycle.sync(agents: [], at: Clock.after(3))                       // 漏检一轮
        let back = await lifecycle.sync(agents: [agentWith(id: firstID)], at: Clock.after(6))
        #expect(back.opened.isEmpty, "回来不是新开会话")
        #expect(back.closed.isEmpty, "回来之前它从未被结算")
        #expect(back.updated.isEmpty, "内容没变就不该广播 updated")
        let current = try #require(await lifecycle.currentSessions().first)
        #expect(current.id == original.id)
        #expect(current.startedAt == original.startedAt)
        #expect(current.displayIndex == 1)

        // 真正的下线（t=9 起缺席满 6 秒）结算成一条，随后新 Agent 拿到的编号必须是 2：
        // 上一段那一轮漏检不许在编号序列里留下空洞。
        _ = await lifecycle.sync(agents: [], at: Clock.after(9))
        _ = await lifecycle.sync(agents: [], at: Clock.after(12))
        let closed = try #require((await lifecycle.sync(agents: [], at: Clock.after(15))).closed.first)
        #expect(closed.id == original.id)
        let next = try #require((await lifecycle.sync(agents: [agentWith(id: UUID(), pid: 9001)], at: Clock.after(18))).opened.first)
        #expect(next.displayIndex == 2, "缺席宽限不该消耗 displayIndex")
    }

    @Test("absenceGrace = 0 时与旧行为逐字一致：第一次缺席即结算")
    func zeroGraceRestoresLegacyBehaviour() async throws {
        let lifecycle = manager(grace: 0)
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [agentWith(id: agentID)], at: Clock.after(0))

        let closed = try #require((await lifecycle.sync(agents: [], at: Clock.after(600))).closed.first)
        #expect(closed.endedAt == Clock.after(600))
        #expect(closed.outcome == .success)
        // 短会话判中断这条也不受宽限开关影响（3 秒 < minimumSessionSeconds 5 秒）。
        let shortManager = manager(grace: 0)
        _ = await shortManager.sync(agents: [agentWith(id: UUID())], at: Clock.after(0))
        let short = try #require((await shortManager.sync(agents: [], at: Clock.after(3))).closed.first)
        #expect(short.outcome == .interrupted, "3 秒的会话不能记成一次成功")
    }

    // MARK: - 三条「不等宽限」的例外

    @Test("仍在列表但 lastSeenAt 陈旧超 idleTimeout：立刻结算，以最后一次真实观测收口")
    func staleObservationIgnoresGrace() async throws {
        let lifecycle = manager(grace: 6)
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [agentWith(id: agentID)], at: Clock.after(0))

        // 本轮时刻 200s，最后观测 30s（差 170s > idleTimeout 120s），但 agent 仍在列表里。
        let result = await lifecycle.sync(
            agents: [agentWith(id: agentID, lastSeenAt: Clock.after(30))], at: Clock.after(200)
        )
        let closed = try #require(result.closed.first)
        #expect(closed.endedAt == Clock.after(30), "以本轮时刻收口会把运行时长虚报 170 秒")
        #expect(closed.outcome == .interrupted)
    }

    @Test("同一 pid 换新身份：旧会话不等宽限就按 .interrupted 结算")
    func pidReuseIgnoresGrace() async throws {
        let lifecycle = manager(grace: 6)
        let oldID = UUID()
        _ = await lifecycle.sync(agents: [agentWith(id: oldID)], at: Clock.after(0))
        _ = await lifecycle.sync(agents: [], at: Clock.after(3))          // 先进入宽限期
        let newID = UUID()
        let result = await lifecycle.sync(agents: [agentWith(id: newID)], at: Clock.after(6))   // 同 pid 换身份

        let closed = try #require(result.closed.first)
        #expect(closed.agentID == oldID)
        #expect(closed.outcome == .interrupted, "pid 复用是身份变更，不是正常下线")
        #expect(closed.endedAt == Clock.after(6))
        #expect(result.opened.count == 1)
        #expect(try #require(result.opened.first).agentID == newID)
    }

    @Test("closeAll 无视宽限：全部收口并清空三张索引")
    func closeAllIgnoresGrace() async throws {
        let lifecycle = manager(grace: 6)
        let first = UUID()
        let second = UUID()
        _ = await lifecycle.sync(agents: [agentWith(id: first), agentWith(id: second, pid: 4243)], at: Clock.after(0))
        _ = await lifecycle.sync(agents: [agentWith(id: second, pid: 4243)], at: Clock.after(3))   // first 进入宽限期

        let closed = await lifecycle.closeAll(at: Clock.after(600), outcome: .interrupted)
        #expect(closed.count == 2, "停机对账不能把处于宽限期的那条留给下一轮")
        #expect(closed.map(\.displayIndex) == [1, 2], "结算顺序按编号稳定")
        #expect(closed.allSatisfy { $0.endedAt == Clock.after(600) })
        #expect(closed.allSatisfy { $0.outcome == .interrupted })
        #expect(await lifecycle.currentSessions().isEmpty)
    }

    @Test("停机路径：宽限期内的会话在 closeAll 之前不得被误判为已下线")
    func gracePeriodDoesNotBroadcastAnything() async throws {
        let lifecycle = manager(grace: 6)
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [agentWith(id: agentID)], at: Clock.after(0))
        let quiet = await lifecycle.sync(agents: [], at: Clock.after(3))
        #expect(quiet.needsPersistence == false, "宽限期内的第一轮缺席不该产生任何要落库的行")
    }
}
