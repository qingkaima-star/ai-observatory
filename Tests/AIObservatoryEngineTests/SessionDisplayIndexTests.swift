//
//  SessionDisplayIndexTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws-engaudit（ICR-0004，总控 00:48 批准、00:49 用真机截图升级为"眼见为实"）
//
//  缺陷：真机 Sessions 列表四行是 `进行中 #2 / 成功 #4 / 成功 #3 / 成功 #2` ——
//  **同一屏两个 #2，且顺序不单调**。根因不是显示层：发号器的下限只从「未结算的那几行」取，
//  而重启最常见的形状恰恰是上一轮的会话**全都结算了** ⇒ 那道 `guard !open.isEmpty else { return }`
//  直接返回，`nextDisplayIndex` 留在 1，新会话重新从 1 开始与历史撞号。
//
//  总控定的修法：改的是**编号的同步来源**（全历史 `MAX(display_index)`），
//  **不许**顺手删掉那道 guard（它是"没有未结算行就别空转"的优化）。
//  验收加一条与图面对齐的：重启后连续新建 3 个会话，编号互不相同且单调递增。
//
//  「重启」在这组用例里用**同一颗文件库 + 一台全新的引擎**表示：
//  新引擎 = 新的 `SessionLifecycleManager`（发号器归零），库里已经躺着结算完的历史行——
//  这就是真机那次重启的形状，比 mock 一个 restart 更硬。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport
@testable import AIObservatoryEngine

/// 时间一律取「相对 now」：`SessionLifecycleManager` 的缺勤宽限是按墙钟判的，
/// 常量日期（哪怕是几个月前）会让「Agent 还活着吗」在每次运行时得到不同答案 ——
/// 这条用例第一版就是这么飘的（同一份代码两次跑出 [5,6] 与 [6,7]）。
private let indexBase = Date()

/// 历史行的编号布局：故意**不**从 1 连续，且最大的是那条已结算的 #4
/// （改前只会看到未结算那几条 ⇒ 取到 2，于是 #3、#4 会被重新发一遍）。
private enum History {
    static let settled: [(index: Int, id: UUID, title: String)] = [
        (1, UUID(), "历史 · 一号"),
        (4, UUID(), "历史 · 四号"),
        (3, UUID(), "历史 · 三号"),
    ]
    static let open = (2, UUID(), "历史 · 二号（未结算）")

    static func rows() -> [AgentSession] {
        settled.map { item in
            AgentSession(displayIndex: item.0, kind: .claudeCode, agentID: item.1, title: item.2,
                         projectPath: "/work/icr0004", startedAt: indexBase,
                         endedAt: indexBase.addingTimeInterval(600), outcome: .success)
        } + [
            AgentSession(displayIndex: open.0, kind: .claudeCode, agentID: open.1, title: open.2,
                         projectPath: "/work/icr0004", startedAt: indexBase, outcome: .running)
        ]
    }
}

@Suite("会话编号：下限来自全历史（ICR-0004）", .timeLimit(.minutes(1)))
struct SessionDisplayIndexTests {

    private static func agent(_ name: String, pid: Int32) -> AgentInstance {
        AgentInstance(kind: .claudeCode, pid: pid, displayName: "Claude Code",
                      executablePath: "/usr/local/bin/claude", workingDirectory: "/work/icr0004",
                      startedAt: indexBase.addingTimeInterval(-600), lastSeenAt: indexBase, state: .running,
                      cpuPercent: 3, memoryBytes: 1_024, childPIDs: [], detectedVia: .executablePath)
    }

    // MARK: - Store 侧那条新查询

    @Test("maxSessionDisplayIndex：空库 0，有历史时取全历史最大值（不是未结算那几条的最大）")
    func storeQueryReadsWholeHistory() async throws {
        let empty = try await ObservatoryStore.open(configuration: .inMemory)
        #expect(try await empty.maxSessionDisplayIndex() == 0, "空库必须是 0，不能是 nil 或 -1")

        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await store.upsertSessions(History.rows())
        // 未结算的那条是 #2，全历史最大的是已结算的 #4 ⇒ 只有 4 是对的。
        #expect(try await store.maxSessionDisplayIndex() == 4)
        #expect(try await store.openSessions().map(\.displayIndex) == [2], "对照：未结算集合确实只有 #2")
    }

    // MARK: - 管理器侧的下限语义

    @Test("seedDisplayIndexFloor 只抬高下限，绝不下调")
    func seedOnlyRaisesTheFloor() async throws {
        let lifecycle = SessionLifecycleManager()
        await lifecycle.seedDisplayIndexFloor(fromHistoryMax: 4)
        let first = await lifecycle.sync(agents: [Self.agent("a", pid: 9_001)], at: indexBase)
        #expect(first.opened.first?.displayIndex == 5, "历史最大 4 ⇒ 新会话必须是 5")

        // 比当前下限还小的历史值不该把已经发出去的号拉回去。
        await lifecycle.seedDisplayIndexFloor(fromHistoryMax: 0)
        let second = await lifecycle.sync(agents: [Self.agent("b", pid: 9_002)], at: indexBase)
        #expect(second.opened.first?.displayIndex == 6)

        // 历史值正好等于当前下限：也不该重复发同一个号。
        await lifecycle.seedDisplayIndexFloor(fromHistoryMax: 6)
        let third = await lifecycle.sync(agents: [Self.agent("c", pid: 9_003)], at: indexBase)
        #expect(third.opened.first?.displayIndex == 7)
    }

    @Test("空历史（0）时仍从 1 起号——这条改动没把旧行为改掉")
    func freshDatabaseStillStartsAtOne() async throws {
        let lifecycle = SessionLifecycleManager()
        await lifecycle.seedDisplayIndexFloor(fromHistoryMax: 0)
        let opened = await lifecycle.sync(agents: [Self.agent("a", pid: 9_011)], at: indexBase)
        #expect(opened.opened.first?.displayIndex == 1)
    }

    // MARK: - 端到端：重启之后连开三个会话

    @Test("重启后连续新建 3 个会话：编号互不相同且单调递增，且不与历史撞号")
    func restartThenThreeNewSessions() async throws {
        let directory = try Scratch.directory("icr0004-restart")
        let url = directory.appendingPathComponent("observatory.sqlite")

        // 第一轮：库里躺着 #1 / #3 / #4（已结算）+ #2（未结算）。
        let first = try await ObservatoryStore.open(configuration: .file(url.path))
        try await first.upsertSessions(History.rows())
        await first.flush()
        await first.stop()

        // 「重启」= 新引擎 + 新发号器，同一颗库文件。
        let store = try await ObservatoryStore.open(configuration: .file(url.path))
        let detector = StubDetector(agents: [Self.agent("a", pid: 9_021)])
        let engine = ObservatoryEngine(
            settings: ObservatorySettings(
                monitoredRoots: [], ignoredPathPatterns: [], processScanIntervalSeconds: 3_600
            ),
            components: ObservatoryEngine.Components(
                storeSource: .ready(store),
                detector: detector,
                processInspector: StubProcessSource(),
                metrics: StubMetrics(),
                commandAuditor: StubAuditor(),
                fileObserver: StubFileObserver(),
                snapshotter: StubSnapshotter(),
                differ: StubDiffer(),
                projectMapper: ProjectMapper(resolver: { _ in nil })
            )
        )
        // 只看「历史之上多出来的编号」：谁被结算、谁还开着都不影响这条判据，
        // 而撞号一定会在这里露出来（新会话如果从 1 重新发号，就不会有 > 4 的行）。
        // `start()` 是必须的：发号下限在 `resumeOpenSessions()` 里喂，而那是 start 的一步。
        await engine.start()
        for pid in [Int32(9_021), 9_022, 9_023] {
            detector.setAgents([Self.agent("agent", pid: pid)])
            await engine.rescanNow()
        }
        await engine.stop()
        await store.stop()

        let all = try await store.sessions(matching: SessionQuery(limit: 200)).items
        for row in all.sorted(by: { $0.displayIndex < $1.displayIndex }) {
            print("ICR0004 \n" + "idx=\(row.displayIndex) title=\(row.title) ended=\(row.endedAt != nil) outcome=\(row.outcome) agent=\(row.agentID.map { "\($0)" } ?? "nil")")
        }
        let every = all.map(\.displayIndex).sorted()
        let beyond = every.filter { $0 > 4 }
        #expect(beyond.first == 5,
                "重启后第一个新会话必须接在全历史 #4 之后；实得全部编号 \(every)")
        #expect(beyond.count >= 3, "连开三个新会话，历史之上至少要看到三个新号：\(every)")
        #expect(Set(every).count == every.count, "整屏编号不得重复：\(every)")
    }
}
