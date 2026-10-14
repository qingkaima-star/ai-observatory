//
//  SessionLifecycleManagerTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Hygiene
//  ─────────────────────────────────────────────────────────
//  `SessionLifecycleManager` 的**直接**测试。它此前只被 Engine 端到端间接碰到，
//  而它承担的是八模块里 ⑥ 的全部结算口径：会话什么时候收口、收口成什么结论、
//  资源数字从哪来。这三件事错了，Dashboard 与 Sessions 页上没有任何一处是对的。
//
//  为什么要直测（本项目已经栽过三次）：「测试全绿但生产恒不触发」。间接用例只证明
//  装配没炸，证不出「idle 超时以最后一次真实观测收口」这种差 170 秒的口径。
//
//  全部时间都显式传入（manager 内部无 await、不读墙钟），所以这些断言是确定的。
//

import Foundation
import Testing
@testable import AIObservatoryEngine
import AIObservatoryCore

/// 固定基准时刻。`Date` 在 1.8e9 秒量级上的表示误差约 5e-7，
/// 因此凡由日期差算出的量都用区间断言，只有「同一个 Date 值原样传出去」才用 `==`。
private enum When {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func after(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
}

private func makeAgent(
    id: UUID = UUID(),
    pid: Int32 = 4242,
    kind: AgentKind = .claudeCode,
    startedAt: Date = When.t0,
    lastSeenAt: Date = When.t0,
    workingDirectory: String? = "/Users/testhost/proj"
) -> AgentInstance {
    AgentInstance(
        id: id,
        kind: kind,
        pid: pid,
        displayName: kind.displayName,
        executablePath: "/usr/local/bin/claude",
        workingDirectory: workingDirectory,
        startedAt: startedAt,
        lastSeenAt: lastSeenAt
    )
}

private func fileChange(
    kind: FileChangeKind,
    agentID: UUID?,
    sessionID: UUID? = nil,
    path: String = "/Users/testhost/proj/Sources/a.swift"
) -> FileChange {
    FileChange(path: path, kind: kind, timestamp: When.after(10), agentID: agentID, sessionID: sessionID)
}

private func command(
    agentID: UUID,
    startedAt: Date,
    outcome: CommandOutcome = .success,
    exitCode: Int32? = 0
) -> CommandRecord {
    CommandRecord(
        executable: "swift",
        arguments: ["build"],
        agentID: agentID,
        startedAt: startedAt,
        exitCode: exitCode,
        outcome: outcome
    )
}

/// #78 之后文件计数唯一的入账路径：**挂账（`stage`）→ 问一次哪些会话该改写 → 由调用方把
/// 从 `file_changes` 数出来的行数交回 `applyFileCounts` 赋值**。这里没有任何一处 `+1`。
///
/// ⚠️ `rowCount` 是**用例手推的**"库里现在有几行"，不是从 `change.kind` 现算的：
/// 单元测试里没有 SQLite，让被测代码（或从它自己的输入反推的循环）自己数行数，
/// 等于把证明交给被质疑的那台机器。每个调用点旁边都写清楚了这笔账（一条 modified ⇒ `(0,1,0)`）。
private func countFileChange(
    _ lifecycle: SessionLifecycleManager,
    _ change: FileChange,
    as rowCount: (created: Int, modified: Int, deleted: Int),
    agentKind: AgentKind = .claudeCode
) async throws -> AgentSession {
    let staged = try #require(
        await lifecycle.stage(fileChange: change, agentKind: agentKind),
        "这条变更应当能归属到打开中的会话，否则下面什么都测不到"
    )
    #expect(
        await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 0)
        ) == [staged.sessionID],
        "写入通道报过数之后只点名「要改写哪些会话」，取值不在这里发生"
    )
    return try #require(
        await lifecycle.applyFileCounts(
            sessionID: staged.sessionID,
            created: rowCount.created, modified: rowCount.modified, deleted: rowCount.deleted
        ),
        "赋值完成时必须带回落库用的快照"
    )
}

private func sample(agentID: UUID, at date: Date, cpuPercent: Double, memoryBytes: UInt64) -> PerformanceSample {
    PerformanceSample(timestamp: date, agentID: agentID, cpuPercent: cpuPercent, memoryBytes: memoryBytes)
}

// MARK: - 结算时机

@Suite("Engine: 会话结算时机", .timeLimit(.minutes(1)))
struct SessionSettlementTimingTests {

    /// 需求点名的「运行时长 2 小时 15 分钟」就取决于这条：agent 还挂在列表里、
    /// 但观测已经陈旧时，必须收口到**最后一次真实观测**，而不是本轮扫描时刻。
    @Test("idle 超时以最后一次真实观测收口，判中断")
    func idleTimeoutClosesAtLastRealObservation() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)

        // 本轮扫描时刻 200s，但最后一次真实看到它是在 30s（差 170s > 默认 idleTimeout 120s）。
        let result = await lifecycle.sync(
            agents: [makeAgent(id: agentID, lastSeenAt: When.after(30))],
            at: When.after(200)
        )

        let closed = try #require(result.closed.first)
        #expect(result.closed.count == 1)
        #expect(result.opened.isEmpty, "超时结算不该顺手再开一条")
        #expect(closed.endedAt == When.after(30), "以本轮时刻收口会把运行时长虚报 170 秒")
        #expect(closed.outcome == .interrupted)
        #expect(await lifecycle.currentSessions().isEmpty)
        #expect(await lifecycle.sessionID(forAgentID: agentID) == nil)
    }

    /// 上一条的对照组：没超时就必须不结算，否则「超时」那条断言恒真。
    @Test("未超时的 agent 继续打开，不结算")
    func withinIdleTimeoutStaysOpen() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)

        // 最后观测 100s、本轮 150s：差 50s < 120s。
        let result = await lifecycle.sync(
            agents: [makeAgent(id: agentID, lastSeenAt: When.after(100))],
            at: When.after(150)
        )

        #expect(result.closed.isEmpty)
        #expect(result.opened.isEmpty)
        #expect(await lifecycle.currentSessions().count == 1)
    }

    /// 这两条钉的是「结算时刻与结论」的口径，与缺席宽限无关，因此显式关掉宽限
    /// （`absenceGrace: 0`）。生产默认是 6 秒宽限，那套行为由 `SessionAbsenceGraceTests`
    /// 逐条钉；这里若改成走默认配置，断言会变成「等第二轮」，就不再是在钉「收口到哪一刻」了。
    private static func withoutGrace() -> SessionLifecycleManager {
        SessionLifecycleManager(configuration: SessionLifecycleManager.Configuration(absenceGrace: 0))
    }

    @Test("不宽限时：列表里消失的 agent 正常下线，收口到本轮时刻")
    func disappearedAgentClosesAtScanTime() async throws {
        let lifecycle = Self.withoutGrace()
        _ = await lifecycle.sync(agents: [makeAgent()], at: When.t0)

        let closed = try #require(await lifecycle.sync(agents: [], at: When.after(600)).closed.first)
        #expect(closed.endedAt == When.after(600))
        #expect(closed.outcome == .success)
    }

    @Test("不宽限时：短于最短会话时长的存活期判中断，不判成功")
    func shortSessionIsInterrupted() async throws {
        let lifecycle = Self.withoutGrace()
        _ = await lifecycle.sync(agents: [makeAgent()], at: When.t0)

        let closed = try #require(await lifecycle.sync(agents: [], at: When.after(3)).closed.first)
        #expect(closed.outcome == .interrupted, "3 秒的会话不能记成一次成功")
    }

    /// 重启续接的会话不知道项目路径；后续扫描拿到 cwd 时必须补上，
    /// 否则项目级活动地图（模块⑦）对这条会话整段失明。
    @Test("首次拿到 cwd 时补齐 projectPath 并报为 updated")
    func projectPathIsBackfilled() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID, workingDirectory: nil)], at: When.t0)

        let result = await lifecycle.sync(
            agents: [makeAgent(id: agentID, workingDirectory: "/Users/testhost/proj")],
            at: When.after(10)
        )

        let updated = try #require(result.updated.first)
        #expect(updated.projectPath == "/Users/testhost/proj")
        #expect(result.closed.isEmpty)
        #expect(result.opened.isEmpty)
    }
}

// MARK: - pid 复用与对账

@Suite("Engine: pid 复用与全量对账", .timeLimit(.minutes(1)))
struct SessionPIDReuseTests {

    @Test("同一 pid 换新身份：旧会话先结算，新会话才开")
    func reusedPIDClosesOldBeforeOpeningNew() async throws {
        let lifecycle = SessionLifecycleManager()
        let oldID = UUID()
        let newID = UUID()
        let first = await lifecycle.sync(agents: [makeAgent(id: oldID, pid: 500)], at: When.t0)
        let oldSessionID = try #require(first.opened.first?.id)
        _ = try await countFileChange(
            lifecycle, fileChange(kind: .modified, agentID: oldID, sessionID: oldSessionID),
            as: (created: 0, modified: 1, deleted: 0)   // 手推：该会话名下只有这一行 modified
        )

        // 内核把 500 号发给了另一个进程 ⇒ 身份换了、pid 没换。
        let result = await lifecycle.sync(
            agents: [makeAgent(id: newID, pid: 500, lastSeenAt: When.after(600))],
            at: When.after(600)
        )

        let closed = try #require(result.closed.first)
        #expect(result.closed.count == 1)
        #expect(closed.agentID == oldID)
        #expect(closed.outcome == .interrupted)
        #expect(closed.endedAt == When.after(600))
        #expect(closed.modifiedFileCount == 1, "旧会话的累计必须跟着它一起结算走")

        let fresh = try #require(result.opened.first)
        #expect(fresh.agentID == newID)
        #expect(fresh.id != closed.id)
        #expect(fresh.modifiedFileCount == 0, "旧进程的文件计数不得渗进新会话")
        #expect(await lifecycle.sessionID(forPID: 500) == fresh.id,
                "按 pid 查会话必须指向新的那条，否则命令归因写进已结算的旧会话")
    }

    @Test("closeAll 结算全部打开中的会话并清空索引")
    func closeAllSettlesEverything() async throws {
        let lifecycle = SessionLifecycleManager()
        let first = UUID()
        let second = UUID()
        _ = await lifecycle.sync(
            agents: [makeAgent(id: first, pid: 10), makeAgent(id: second, pid: 20, kind: .cursorAgent)],
            at: When.t0
        )

        let closed = await lifecycle.closeAll(at: When.after(600), outcome: .interrupted)

        #expect(closed.count == 2)
        #expect(closed.map(\.displayIndex) == closed.map(\.displayIndex).sorted(), "结算顺序按编号稳定")
        #expect(closed.allSatisfy { $0.endedAt == When.after(600) })
        #expect(closed.allSatisfy { $0.outcome == .interrupted }, "引擎停止时要透传结论，不得各自判成成功")
        #expect(Set(closed.compactMap(\.agentID)) == [first, second])
        #expect(await lifecycle.currentSessions().isEmpty)
        #expect(await lifecycle.sessionID(forPID: 10) == nil)
        #expect(await lifecycle.sessionID(forAgentID: second) == nil)
        #expect(await lifecycle.closeAll(at: When.after(700), outcome: .interrupted).isEmpty,
                "对账第二次跑不得凭空产出会话")
    }
}

// MARK: - 结论判定

@Suite("Engine: 会话结论判定", .timeLimit(.minutes(1)))
struct SessionOutcomeTests {

    @Test("最后一条命令失败 ⇒ 整场判失败，盖过调用方给的成功结论")
    func lastCommandFailureWins() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        _ = await lifecycle.record(command: command(agentID: agentID, startedAt: When.after(100)))
        _ = await lifecycle.record(command: command(agentID: agentID, startedAt: When.after(200),
                                                   outcome: .failure, exitCode: 1))

        // #86：这两列从此**只能由 `commands` 的行数写进来**。上面两次 `record` 一格都不加
        // （那是这一格自带的反向守卫：把 `+= 1` 接回来，下面那条"record 之后仍是 0"当场红）。
        let openID = try #require(await lifecycle.sessionID(forAgentID: agentID))
        #expect(await lifecycle.currentSessions().first?.commandCount == 0,
                "record(command:) 不再累计计数——虚高的那一格就是这么来的")
        #expect(await lifecycle.applyCommandCounts(
            sessionID: openID, total: 2, failed: 1)?.commandCount == 2)
        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(600),
                                                               outcome: .success))
        #expect(settled.outcome == .failed)
        #expect(settled.commandCount == 2)
        #expect(settled.failedCommandCount == 1)
    }

    /// 「最后一条」按时间戳判定，不是按到达顺序——采样与 hook 乱序到达是真机常态。
    @Test("失败之后又有成功的命令 ⇒ 不判失败")
    func laterSuccessOverridesEarlierFailure() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        _ = await lifecycle.record(command: command(agentID: agentID, startedAt: When.after(300),
                                                   outcome: .failure, exitCode: 1))
        _ = await lifecycle.record(command: command(agentID: agentID, startedAt: When.after(400)))
        // #86：这两列从此**只能由 `commands` 的行数写进来**。上面两次 `record` 一格都不加
        // （那是这一格自带的反向守卫：把 `+= 1` 接回来，下面那条"record 之后仍是 0"当场红）。
        let openID = try #require(await lifecycle.sessionID(forAgentID: agentID))
        #expect(await lifecycle.currentSessions().first?.commandCount == 0,
                "record(command:) 不再累计计数——虚高的那一格就是这么来的")
        #expect(await lifecycle.applyCommandCounts(
            sessionID: openID, total: 2, failed: 1)?.commandCount == 2)

        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(600),
                                                               outcome: .success))
        #expect(settled.outcome == .success)
        #expect(settled.failedCommandCount == 1, "失败计数照样记，只是整场结论看最后一条")
    }

    @Test("退出码非零即失败，即使命令自述成功")
    func nonzeroExitCodeContradictingOutcomeCountsAsFailure() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        _ = await lifecycle.record(command: command(agentID: agentID, startedAt: When.after(100),
                                                   outcome: .success, exitCode: 2))

        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(600),
                                                               outcome: .success))
        #expect(settled.outcome == .failed, "自述成功与退出码矛盾时按失败收口，不替 Agent 遮掩")
    }

    /// 真机轮询几乎永远拿不到退出码（捕获率 1–2%），所以「未知」才是常态。
    @Test("退出码与结论都没有 ⇒ 不算失败")
    func missingExitCodeIsNotFailure() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        _ = await lifecycle.record(command: command(agentID: agentID, startedAt: When.after(100),
                                                   outcome: .running, exitCode: nil))
        // #86：这两列从此**只能由 `commands` 的行数写进来**。上面两次 `record` 一格都不加
        // （那是这一格自带的反向守卫：把 `+= 1` 接回来，下面那条"record 之后仍是 0"当场红）。
        let openID = try #require(await lifecycle.sessionID(forAgentID: agentID))
        #expect(await lifecycle.currentSessions().first?.commandCount == 0,
                "record(command:) 不再累计计数——虚高的那一格就是这么来的")
        #expect(await lifecycle.applyCommandCounts(
            sessionID: openID, total: 1, failed: 0)?.commandCount == 1)

        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(600),
                                                               outcome: .success))
        #expect(settled.outcome == .success)
        #expect(settled.failedCommandCount == 0)
        #expect(settled.commandCount == 1)
    }

    @Test("调用方不下结论时：有实测依据才判成功，否则判未知")
    func runningConclusionFallsBackToEvidence() async throws {
        let withEvidence = SessionLifecycleManager()
        let agentA = UUID()
        _ = await withEvidence.sync(agents: [makeAgent(id: agentA)], at: When.t0)
        _ = try await countFileChange(
            withEvidence, fileChange(kind: .created, agentID: agentA),
            as: (created: 1, modified: 0, deleted: 0)   // 手推：一行 created
        )
        let succeeded = try #require(await withEvidence.closeSession(agentID: agentA, at: When.after(600),
                                                                    outcome: .running))
        #expect(succeeded.outcome == .success)

        let withoutEvidence = SessionLifecycleManager()
        let agentB = UUID()
        _ = await withoutEvidence.sync(agents: [makeAgent(id: agentB)], at: When.t0)
        let unknown = try #require(await withoutEvidence.closeSession(agentID: agentB, at: When.after(600),
                                                                     outcome: .running))
        #expect(unknown.outcome == .unknown, "什么都没观测到就是没观测到，不能记成成功")
    }
}

// MARK: - 资源指标

@Suite("Engine: 会话资源指标结算", .timeLimit(.minutes(1)))
struct SessionResourceMetricsTests {

    /// 口径：`Σ (cpuPercent / 100) × Δt`，段为「上一个样本（首段从 startedAt）→ 该样本」，
    /// 末段收口到 endedAt。这里 10s@50% + 10s@100% + 20s@25% = 20 CPU 秒。
    @Test("cpuSeconds 逐段积分并收口到 endedAt")
    func cpuSecondsIntegrateSamples() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        _ = await lifecycle.record(performanceSample: sample(agentID: agentID, at: When.after(10),
                                                            cpuPercent: 50, memoryBytes: 5_000_000))
        let second = try #require(await lifecycle.record(performanceSample: sample(agentID: agentID, at: When.after(20),
                                                                                  cpuPercent: 100, memoryBytes: 8_000_000)))
        #expect(second.peakCPUPercent == 100)
        #expect(second.peakMemoryBytes == 8_000_000)
        // 打开中只入账长度已确定的两段：10s@50% + 10s@100%。第三段要等收口才知长度。
        #expect(14.9...15.1 ~= second.cpuSeconds, "打开中的部分入账值错: \(second.cpuSeconds)")

        _ = await lifecycle.record(performanceSample: sample(agentID: agentID, at: When.after(30),
                                                            cpuPercent: 25, memoryBytes: 6_000_000))
        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(40),
                                                               outcome: .success))
        #expect(19.9...20.1 ~= settled.cpuSeconds, "结算值错: \(settled.cpuSeconds)")
        #expect(settled.peakCPUPercent == 100)
        #expect(settled.peakMemoryBytes == 8_000_000)
    }

    @Test("超过 60 秒的异常间隔不入账")
    func abnormalGapIsNotCredited() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        _ = await lifecycle.record(performanceSample: sample(agentID: agentID, at: When.after(10),
                                                            cpuPercent: 50, memoryBytes: 1_000_000))
        _ = await lifecycle.record(performanceSample: sample(agentID: agentID, at: When.after(200),
                                                            cpuPercent: 50, memoryBytes: 1_000_000))

        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(210),
                                                               outcome: .success))
        // 190 秒的空档要么是采样断了、要么是机器睡过一觉；按 50% 记满就是凭空多出 100 CPU 秒。
        #expect(4.9...5.1 ~= settled.cpuSeconds, "异常间隔被入账了: \(settled.cpuSeconds)")
    }

    @Test("没有任何采样时 cpuSeconds 为 0，绝不用墙钟时长伪造")
    func noSamplesMeansZeroCPUNotWallClock() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)

        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(3600),
                                                               outcome: .success))
        #expect(settled.cpuSeconds == 0)
        #expect(settled.peakCPUPercent == 0)
        #expect(settled.peakMemoryBytes == 0)
    }

    @Test("非有限与负的 CPU 读数按 0 处理，不污染峰值与积分")
    func nonsenseCPUNumbersAreIgnored() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        _ = await lifecycle.record(performanceSample: sample(agentID: agentID, at: When.after(10),
                                                            cpuPercent: .nan, memoryBytes: 2_000_000))
        _ = await lifecycle.record(performanceSample: sample(agentID: agentID, at: When.after(20),
                                                            cpuPercent: -30, memoryBytes: 9_000_000))

        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(30),
                                                               outcome: .success))
        #expect(settled.cpuSeconds == 0, "NaN / 负读数进了积分: \(settled.cpuSeconds)")
        #expect(settled.peakCPUPercent == 0)
        #expect(settled.peakMemoryBytes == 9_000_000, "内存峰值仍要成立")
    }
}

// MARK: - 归属

@Suite("Engine: 行为归属", .timeLimit(.minutes(1)))
struct SessionAttributionTests {

    @Test("指向未知会话 id 的行为不猜归属，也不改任何计数")
    func unknownSessionIDIsRejected() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        let opened = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        let realSessionID = try #require(opened.opened.first?.id)

        // 指向未知会话 id ⇒ 不猜归属，连暂存都不进（`stage` 返回 nil 就是「不必为它对账」）。
        #expect(await lifecycle.stage(
            fileChange: fileChange(kind: .created, agentID: nil, sessionID: UUID()),
            agentKind: .claudeCode
        ) == nil)
        #expect(await lifecycle.stagedFileChangeCount == 0, "归不上的变更不许留下待认领条目")
        let updated = try await countFileChange(
            lifecycle, fileChange(kind: .created, agentID: nil, sessionID: realSessionID),
            as: (created: 1, modified: 0, deleted: 0)   // 手推：一行 created
        )
        #expect(updated.createdFileCount == 1)
    }

    @Test("同类有多个打开中的会话时不猜归属")
    func ambiguousKindIsNotGuessed() async throws {
        let lifecycle = SessionLifecycleManager()
        let first = UUID()
        let second = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: first, pid: 10), makeAgent(id: second, pid: 20)],
                                 at: When.t0)
        let unowned = fileChange(kind: .deleted, agentID: nil)

        #expect(await lifecycle.stage(fileChange: unowned, agentKind: .claudeCode) == nil)

        // 收掉一条之后，剩下的那条才是唯一可能的归属。
        _ = await lifecycle.closeSession(agentID: first, at: When.after(600), outcome: .interrupted)
        let attributed = try await countFileChange(
            lifecycle, unowned, as: (created: 0, modified: 0, deleted: 1)   // 手推：一行 deleted
        )
        #expect(attributed.agentID == second)
        #expect(attributed.deletedFileCount == 1)
    }

    @Test("renamed 与 unknown 不计入三个文件计数")
    func renamedAndUnknownDoNotCountAsFileChanges() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        // 不计入三列的类型连暂存都不进：留个待认领条目就是给后面的对账添一笔空账。
        #expect(await lifecycle.stage(
            fileChange: fileChange(kind: .renamed, agentID: agentID, path: "/Users/dev/proj/new.swift"),
            agentKind: .claudeCode
        ) == nil)
        #expect(await lifecycle.stage(
            fileChange: fileChange(kind: .unknown, agentID: agentID), agentKind: .claudeCode
        ) == nil)
        #expect(await lifecycle.stagedFileChangeCount == 0)
        // 就算写入通道报告"全部落库"，这两类也不得动三列：一笔欠账都没挂 ⇒ 连"该改写谁"都不该报出来。
        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 0)
        ) == [], "renamed / unknown 一条都不该被点名改写")
        let last = try #require(await lifecycle.currentSessions().first)
        #expect(last.createdFileCount == 0)
        #expect(last.modifiedFileCount == 0)
        #expect(last.deletedFileCount == 0)
    }

    /// 原来这里是一条「`record(riskCount:)` 累加 3 → 7」的用例。那个自增已经被整条摘掉：
    /// 它和 Store 的派生重算同写一列，谁后写谁赢，真机因此看到 `sessions.risk_event_count = 40`
    /// 而该会话名下只有 5 行风险。现在那一列只有一个写入者（`ObservatoryStore` 的重算），
    /// 所以本用例改成钉「会话管理器不再碰这一列」——把自增接回来就会红。
    @Test("会话管理器不再持有风险计数：其它累计都不动它")
    func riskCountIsNotOwnedByLifecycle() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        let opened = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        // 原来这里绑了一个 `sessionID`，改写本用例后它没人读了 —— 留着一个不读的绑定
        // 等于"看起来还在验会话"，实际什么都没测，所以换成一条真断言。
        #expect(opened.opened.count == 1, "会话确实开了：下面三条 record 都要挂在这条会话上")

        // #86 之后 `record(command:)` 常态返回 nil：它只挂欠账，不改任何一格 ⇒ 没东西要落库。
        #expect(await lifecycle.record(command: command(agentID: agentID, startedAt: When.after(10))) == nil,
                "record 不再交出一份带着计数的快照（虚高就是这么产生的）")
        let openForRisk = try #require(await lifecycle.sessionID(forAgentID: agentID))
        let afterCommand = try #require(await lifecycle.applyCommandCounts(
            sessionID: openForRisk, total: 1, failed: 0))
        #expect(afterCommand.commandCount == 1, "命令计数只能从行数进来（#86 的唯一写入路径）")
        #expect(afterCommand.riskEventCount == 0)

        let afterChange = try await countFileChange(
            lifecycle, fileChange(kind: .deleted, agentID: agentID),
            as: (created: 0, modified: 0, deleted: 1)   // 手推：一行 deleted
        )
        #expect(afterChange.deletedFileCount == 1)
        #expect(afterChange.riskEventCount == 0, "风险计数不从这条路径累加——它派生自 risk_events")

        let settled = try #require(await lifecycle.closeSession(agentID: agentID, at: When.after(600), outcome: .success))
        #expect(settled.riskEventCount == 0, "结算也不会顺手把计数写回去")
    }
}

// MARK: - 文件计数：挂账 → 数行数 → 赋值（#78）

/// 这一组直测**接口本身不自欺**的那几格（端到端那一份在
/// `SessionFileCountPersistenceTests.swift`：病长在采集链的写入顺序上，
/// 只有真引擎那条路能证「批次丢了一条时列不虚高」）。
///
/// 这里钉的是取值来源：**manager 里没有 SQLite，所以它也就不该有任何一个数**。
/// 观测（排空 / 丢弃）只决定"该改写谁"和"欠账要不要继续追"，永远不参与赋值。
@Suite("Engine: 文件计数——观测只点名，取值一律来自 file_changes 的行数", .timeLimit(.minutes(1)))
struct FileChangeCreditTests {

    /// `stage` 只挂一笔欠账，三列一个都不动。
    ///
    /// 这一格钉的就是改前的那个动作：旧代码在这里直接 +1，于是"投进缓冲"被当成了"已经落库"。
    @Test("stage 不动任何计数：它留下的唯一痕迹是待对平条数")
    func stagingCountsNothing() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)

        let staged = try #require(await lifecycle.stage(
            fileChange: fileChange(kind: .modified, agentID: agentID), agentKind: .claudeCode
        ))
        #expect(staged.snapshot == nil, "没补到项目路径 ⇒ 快照不该变")
        #expect(await lifecycle.stagedFileChangeCount == 1)
        let open = try #require(await lifecycle.currentSessions().first)
        #expect(open.modifiedFileCount == 0, "行还在缓冲里，列不许动")
        #expect(open.createdFileCount == 0 && open.deletedFileCount == 0)
        // 挂账不动快照：同一条会话再挂两笔也还是 0，只有调用方交回行数才开始有数。
        _ = await lifecycle.stage(fileChange: fileChange(kind: .created, agentID: agentID), agentKind: .claudeCode)
        _ = await lifecycle.stage(fileChange: fileChange(kind: .deleted, agentID: agentID), agentKind: .claudeCode)
        #expect(await lifecycle.stagedFileChangeCount == 3)
        #expect(try #require(await lifecycle.currentSessions().first).modifiedFileCount == 0)

        // 写入通道报过数：只点名"该改写谁"，点名这一步本身一个数都不给。
        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 0)
        ) == [staged.sessionID])
        #expect(try #require(await lifecycle.currentSessions().first).modifiedFileCount == 0,
                "点名之后仍然不许自增——数只从行数来")
        // 手推：库里 created / modified / deleted 各 1 行。
        let credited = try #require(await lifecycle.applyFileCounts(
            sessionID: staged.sessionID, created: 1, modified: 1, deleted: 1
        ))
        #expect(credited.createdFileCount == 1 && credited.modifiedFileCount == 1 && credited.deletedFileCount == 1)
        #expect(await lifecycle.stagedFileChangeCount == 0, "行数追平欠账 ⇒ 收账")
    }

    /// 缓冲还排着队 ⇒ 一个会话都不点名（这会儿数行数必然偏低），也**不清空**欠账。
    @Test("缓冲未排空时不点名也不清账")
    func undrainedBufferCreditsNothing() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        _ = await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)
        _ = await lifecycle.stage(fileChange: fileChange(kind: .modified, agentID: agentID), agentKind: .claudeCode)

        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: false, droppedStatementCount: 0)
        ) == [])
        #expect(await lifecycle.stagedFileChangeCount == 1, "没答案就不许把账抹掉")
        #expect(try #require(await lifecycle.currentSessions().first).modifiedFileCount == 0)
    }

    /// **H1 那一格**：`pendingCount == 0` 不等于「那批语句跑完了」——
    /// `BatchWriter.commitBuffer()` 先换出缓冲、再去 await 另一个 actor 的事务，
    /// 那段在途窗口里排空是真的、"一条没丢"也是真的，而行还没进库。
    ///
    /// 于是这里给一次**乐观到位**的观测（排空 + 零丢弃），但调用方只数到 2 行：
    /// 旧口径（"排空且没丢 ⇒ 逐条 +1"）会当场把列写成 3，而那一行最终没落库 ⇒ 永久虚高，
    /// 正是真库 19 vs 18。新口径只赋值数到的 2，并且**不收账**：下一轮数到 3 才算对平。
    @Test("乐观观测（排空、零丢弃）配不满的行数：记低的值、留着账，绝不记高的值")
    func optimisticObservationCannotInflateCounts() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        let sessionID = try #require(
            (await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)).opened.first?.id
        )
        for _ in 0..<3 {
            _ = await lifecycle.stage(
                fileChange: fileChange(kind: .modified, agentID: agentID, sessionID: sessionID),
                agentKind: .claudeCode
            )
        }
        #expect(await lifecycle.stagedFileChangeCount == 3)

        // 事务在途：库里此刻只数得到 2 行（手推：3 投出去、1 还在 BEGIN…COMMIT 之间）。
        let low = try #require(await lifecycle.applyFileCounts(
            sessionID: sessionID, created: 0, modified: 2, deleted: 0
        ))
        #expect(low.modifiedFileCount == 2, "写数到的行数，不是投出去的条数 3")
        #expect(low.createdFileCount == 0 && low.deletedFileCount == 0)
        #expect(await lifecycle.stagedFileChangeCount == 3, "欠的 1 行没数到 ⇒ 账不许销，下一轮还得再数")

        // 下一轮：那一行进库了 ⇒ 数到 3，这才算对平。
        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 0)
        ) == [sessionID], "还欠着账 ⇒ 下一轮照样点名")
        let caught = try #require(await lifecycle.applyFileCounts(
            sessionID: sessionID, created: 0, modified: 3, deleted: 0
        ))
        #expect(caught.modifiedFileCount == 3)
        #expect(await lifecycle.stagedFileChangeCount == 0, "数平了才收账")
    }

    /// 调用方数出个负数（假数据 / 将来某条减法写错）时，界面上永远读不到负计数。
    ///
    /// 但**不许**顺手把这笔欠账当成已对平：夹到 0 是防脏数据，不是"行落库了"的证据。
    @Test("行数里的负数夹到 0，欠账照样留着")
    func negativeRowCountsClampToZeroButStayOwed() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        let sessionID = try #require(
            (await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)).opened.first?.id
        )
        _ = await lifecycle.stage(
            fileChange: fileChange(kind: .modified, agentID: agentID, sessionID: sessionID),
            agentKind: .claudeCode
        )
        let clamped = try #require(await lifecycle.applyFileCounts(
            sessionID: sessionID, created: -5, modified: -1, deleted: 0
        ))
        #expect(clamped.createdFileCount == 0 && clamped.modifiedFileCount == 0 && clamped.deletedFileCount == 0)
        #expect(await lifecycle.stagedFileChangeCount == 1, "夹到 0 不算数平：那一行到底进库没有，还得再数一轮")
    }

    /// 丢弃额度**按条**冲抵欠账：N 条丢弃最多解释 N 笔没数到的行，多给就是替 SQLite 编行。
    ///
    /// 前半段是真库那一格的最小形状（投 3、落 2、丢 1）⇒ 一次对账就收账，列停在 2。
    /// 后半段是它的反面：投 2、只数到 1、丢弃额度只有 0 ⇒ 绝不能收账
    /// （那一行可能只是还在途；这里若收账，行随后落库就再没人来改这格 ⇒ 少记一格的永久漂移）。
    @Test("丢弃额度只能按条冲抵欠账：抵得平的收账，抵不平的继续追")
    func dropsForgiveOnlyWhatTheyExplain() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        let sessionID = try #require(
            (await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)).opened.first?.id
        )
        for _ in 0..<3 {
            _ = await lifecycle.stage(
                fileChange: fileChange(kind: .modified, agentID: agentID, sessionID: sessionID),
                agentKind: .claudeCode
            )
        }
        // 报"排空 + 丢了 1 条"，实际入库 2 行（19 vs 18 那一格）。
        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 1)
        ) == [sessionID])
        let forgiven = try #require(await lifecycle.applyFileCounts(
            sessionID: sessionID, created: 0, modified: 2, deleted: 0
        ))
        #expect(forgiven.modifiedFileCount == 2, "缺口 1 恰好被 1 条丢弃解释 ⇒ 写数到的 2，不写投出去的 3")
        #expect(await lifecycle.stagedFileChangeCount == 0, "抵平了 ⇒ 收账，不再白数")

        // 再投两条，只数到一条，且丢弃计数没有再涨（额度已花光）：不许收账。
        for _ in 0..<2 {
            _ = await lifecycle.stage(
                fileChange: fileChange(kind: .modified, agentID: agentID, sessionID: sessionID),
                agentKind: .claudeCode
            )
        }
        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 1)   // 与上次同值：没有新丢弃
        ) == [sessionID])
        let short = try #require(await lifecycle.applyFileCounts(
            sessionID: sessionID, created: 0, modified: 3, deleted: 0
        ))
        #expect(short.modifiedFileCount == 3, "基准 2 + 投 2 = 至少该数到 4，只数到 3 也照样按 3 写")
        #expect(await lifecycle.stagedFileChangeCount == 2, "还欠 1 行又没有任何丢弃可抵 ⇒ 账留着")

        // 那条缺口最终被一条真丢弃解释掉：额度到手才收账。
        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 2)
        ) == [sessionID])
        let settled = try #require(await lifecycle.applyFileCounts(
            sessionID: sessionID, created: 0, modified: 3, deleted: 0
        ))
        #expect(settled.modifiedFileCount == 3)
        #expect(await lifecycle.stagedFileChangeCount == 0, "1 条丢弃解释 1 笔欠账 ⇒ 收账")
    }

    /// 会话在对平之前就结算了：欠账不许凭空消失，得报给调用方去改库里那一行。
    /// 否则「结算之后才落库的行」会永远不进这三列，而界面上看起来像真的没有那次编辑。
    @Test("已结算会话的在途行照样点名改写，不被静默丢掉")
    func settledSessionStillAsksForRecount() async throws {
        let lifecycle = SessionLifecycleManager()
        let agentID = UUID()
        let sessionID = try #require(
            (await lifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)).opened.first?.id
        )
        _ = await lifecycle.stage(
            fileChange: fileChange(kind: .modified, agentID: agentID, sessionID: sessionID),
            agentKind: .claudeCode
        )
        _ = await lifecycle.closeSession(agentID: agentID, at: When.after(600), outcome: .success)
        #expect(await lifecycle.stagedFileChangeCount == 1, "结算不清欠账")

        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 0)
        ) == [sessionID], "库里那一行仍要跟着真实行数走")
        #expect(await lifecycle.applyFileCounts(
            sessionID: sessionID, created: 0, modified: 1, deleted: 0
        ) == nil, "已结算的会话不在打开集合里：只能由调用方改库里那行")
        #expect(await lifecycle.stagedFileChangeCount == 0, "交回过一次行数就收账，不留永远追不完的账")
    }

    /// 重启接回来的会话带着的是**上一个进程**写的三列（本进程没有"投了几笔"的账可追）。
    ///
    /// 这一格钉"对账一次即作数"：`resume` 之后必须点名改写，改写之后必须收账——
    /// 少前者，那三列停在旧值上（干净退出时留在途行、崩溃、断电三种形状都无从修复）；
    /// 少后者，每条活着的会话会让引擎每 tick 白数一遍行数。
    @Test("resume 接回来的会话按行数对账一次就收账")
    func resumedSessionIsReconciledOnce() async throws {
        // 造一条"上一个进程记的"会话：三列带着虚高的旧值（19 / 18 那个形状）。
        let staleLifecycle = SessionLifecycleManager()
        let agentID = UUID()
        let stale = try #require(
            (await staleLifecycle.sync(agents: [makeAgent(id: agentID)], at: When.t0)).opened.first
        )
        var carried = stale
        carried.createdFileCount = 7
        carried.modifiedFileCount = 19   // 上个进程记的：比库里真实行数多 1
        carried.deletedFileCount = 0

        let lifecycle = SessionLifecycleManager()
        await lifecycle.resume(sessions: [carried], at: When.after(60))
        #expect(await lifecycle.hasStagedFileChanges, "接回来的会话要挂一笔对账，否则没人会去数它")
        #expect(await lifecycle.stagedFileChangeCount == 0, "本进程没投过任何行 ⇒ 条数是 0，但账要数一次")

        #expect(await lifecycle.fileCountRecountsRequired(
            observation: .init(bufferDrained: true, droppedStatementCount: 0)
        ) == [carried.id], "第一轮采集就该点名改写它")
        // 手推：库里真实行数是 created 7 / modified 18 / deleted 0。
        let reconciled = try #require(await lifecycle.applyFileCounts(
            sessionID: carried.id, created: 7, modified: 18, deleted: 0
        ))
        #expect(reconciled.modifiedFileCount == 18, "19 是上一个进程留下的虚高，按行数改写成 18")
        #expect(reconciled.createdFileCount == 7 && reconciled.deletedFileCount == 0)
        #expect(await lifecycle.hasStagedFileChanges == false, "只对账一次 ⇒ 收账，不许每 tick 白数")
    }
}
