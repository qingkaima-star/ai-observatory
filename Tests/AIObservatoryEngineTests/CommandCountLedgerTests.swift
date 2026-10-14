//
//  CommandCountLedgerTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: master-controller（#86）
//
//  病与 #78 完全同形，只是长在另一组列上：`SessionLifecycleManager.record(command:)`
//  在 `store.append(command)` **刚把语句投进 `BatchWriter` 缓冲**的那一刻就 `commandCount += 1`。
//  投进缓冲不等于落库 ⇒ 一条语句被 SQLite 拒掉，那一格就永久虚高，而且账当场销掉，
//  之后再没有第二个写入者会去数它（文件那三列的真库实测是 19 vs 18）。
//
//  现在这两列唯一的写入路径是 `applyCommandCounts`，值来自 `commands` 的 `COUNT(*)`；
//  失败数用**两次 COUNT 的容斥**表达 `outcome == .failure || exit_code != 0`，
//  于是"什么算失败"这条规则只有一份判据，不必再抄一份 SQL 影子进三个后端。
//
//  ⚠️ 期望值全部手推，算式写在旁边。本文件每一格都是"会话表里那个数"vs"另一次独立 COUNT"，
//     因为 `读回来 == 写进去的` 对"多记一次"完全失明（#78 已经为这句话付过学费）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport
@testable import AIObservatoryEngine

@Suite("Engine: 命令两列以 commands 行数为唯一来源（#86）", .serialized, .timeLimit(.minutes(1)))
struct CommandCountLedgerTests {

    private func record(agentID: UUID, line: String, outcome: CommandOutcome, exit: Int32?,
                        startedAt: Date) -> CommandRecord {
        let parts = line.split(separator: " ").map(String.init)
        return CommandRecord(
            executable: parts.first ?? "sh",
            arguments: Array(parts.dropFirst()),
            agentID: agentID,
            startedAt: startedAt,
            endedAt: startedAt.addingTimeInterval(1),
            exitCode: exit,
            outcome: outcome
        )
    }

    /// 走**生产通路**交命令：桩审计器交一批 → 推一轮采集 → 清空审计器（它每轮都原样重交）
    /// → 再推一轮让对平那一步跑起来。返回会话行（读库，不读内存快照）。
    private func ingest(_ harness: IngestHarness, _ commands: [CommandRecord]) async throws -> AgentSession {
        harness.auditor.setCommands(commands)
        await harness.engine.rescanNow()
        harness.auditor.setCommands([])
        try await settleCredits(harness)
        await harness.engine.rescanNow()
        return try await storedSession(harness)
    }

    /// 会话名下 `commands` 的总行数——**恒等式的另一侧**，与会话表那两列来源独立。
    private func commandRows(_ harness: IngestHarness, outcomes: Set<CommandOutcome> = [],
                             nonZeroExitCode: Bool = false) async throws -> Int {
        try await harness.store.commands(
            matching: CommandQuery(sessionID: try await sessionID(harness), outcomes: outcomes,
                                   withNonZeroExitCode: nonZeroExitCode, limit: 1)
        ).totalCount
    }

    @Test("三条命令都落库：两列等于行数，且失败数按容斥口径手推")
    func countsComeFromRows() async throws {
        let harness = try await makeIngestHarness()
        let agentID = try #require(await storedSession(harness).agentID)
        let t = Date(timeIntervalSinceReferenceDate: 800_000_100)
        // 手推：入库 3 行 ⇒ total 3；失败 = #(outcome=.failure)=1 + #(outcome≠failure ∧ exit≠0)=0 = 1
        let session = try await ingest(harness, [
            record(agentID: agentID, line: "swift build", outcome: .failure, exit: 1, startedAt: t),
            record(agentID: agentID, line: "git status", outcome: .success, exit: 0, startedAt: t.addingTimeInterval(2)),
            record(agentID: agentID, line: "npm install", outcome: .running, exit: nil, startedAt: t.addingTimeInterval(4)),
        ])
        #expect(session.commandCount == 3)
        #expect(session.failedCommandCount == 1)
        #expect(try await commandRows(harness) == 3, "另一侧的 COUNT 必须与列上的数一致")
    }

    /// 台账点名的那一格：**真的**制造一次「没落库」。
    ///
    /// 手法与 #78 同源：给 `commands` 挂一条 `BEFORE INSERT … RAISE(ABORT)` 触发器，只拒
    /// command_line 带 `doomed` 的那一条。投入 3 条 ⇒ 真实入库 **2** 条。
    /// 改前的口径会记成 3（先 +1 后落库），而且再也回不来。
    /// ⚠️ 触发器的条件只能写**真实存在的列**：`commands` 没有 `command_line` 这一列
    /// （行面是 `executable` + `arguments_json` 拼出来的），而 SQLite 建触发器时**不校验**
    /// 触发体里的列名，要等第一次插入才炸——于是三条全写不进去，这一格会"红得很像成功"
    /// （0 行入库、0 计数、看起来两边都对得上）。所以我同时钉三个数：行数 2、列 2、丢弃 ≥1。
    @Test("批次里一条被 SQLite 拒掉：两列不虚高（3 投 2 落 ⇒ 记 2）")
    func droppedCommandDoesNotInflateCounts() async throws {
        let harness = try await makeIngestHarness()
        try await harness.store.database.execute([SQLiteStatement("""
            CREATE TRIGGER trust86_reject_doomed
                BEFORE INSERT ON commands
                WHEN NEW.executable = 'doomed'
            BEGIN
                SELECT RAISE(ABORT, 'fixture(#86): 这一行写不进去');
            END
            """)])
        let agentID = try #require(await storedSession(harness).agentID)
        let t = Date(timeIntervalSinceReferenceDate: 800_000_200)
        // 手推：入库 2 ⇒ total 2；两条都落库且都是"非失败"（exit 0/success 与 nil/unknown）⇒ failed 0
        let session = try await ingest(harness, [
            record(agentID: agentID, line: "keep one", outcome: .success, exit: 0, startedAt: t),
            record(agentID: agentID, line: "doomed two", outcome: .unknown, exit: nil, startedAt: t.addingTimeInterval(2)),
            record(agentID: agentID, line: "keep three", outcome: .unknown, exit: nil, startedAt: t.addingTimeInterval(4)),
        ])
        #expect(try await commandRows(harness) == 2, "触发器没生效的话，这一格的前提就塌了")
        #expect(session.commandCount == 2, "列比真实行数多 ⇒ 又回到先计数后落库那个病")
        #expect(session.failedCommandCount == 0)
        #expect(await harness.store.batchStats().droppedStatementCount >= 1,
                "这一格的前提：确实有一次丢弃是可观察的，不是靠没写进去猜的")
    }

    /// 容斥的第二项（`outcome ≠ .failure ∧ exit ≠ 0`）在既有夹具里**无处可测**——那一族的行
    /// 只有在这里出现。缺了它，`#86` 的失败数会与 `isFailure` 静默分叉。
    ///
    /// 手推四行：
    ///  · `failure` + exit 0  → 失败（靠 outcome 那一支）
    ///  · `unknown` + exit 7  → 失败（靠 exit 那一支，也就是容斥的第二项）
    ///  · `success` + exit 0  → 不失败
    ///  · `terminated` + nil  → 不失败（引擎红线：终止不判成败，退出码必须仍是 NULL）
    /// ⇒ total 4、failed 2。
    @Test("失败口径的两支各自都要能落到数：#(failure) 与 #(非 failure ∧ exit≠0)")
    func failureRuleCoversBothHalves() async throws {
        let harness = try await makeIngestHarness()
        let agentID = try #require(await storedSession(harness).agentID)
        let t = Date(timeIntervalSinceReferenceDate: 800_000_300)
        let session = try await ingest(harness, [
            record(agentID: agentID, line: "one failure zero exit", outcome: .failure, exit: 0, startedAt: t),
            record(agentID: agentID, line: "two unknown seven", outcome: .unknown, exit: 7, startedAt: t.addingTimeInterval(2)),
            record(agentID: agentID, line: "three success zero", outcome: .success, exit: 0, startedAt: t.addingTimeInterval(4)),
            record(agentID: agentID, line: "four terminated nil", outcome: .terminated, exit: nil, startedAt: t.addingTimeInterval(6)),
        ])
        #expect(session.commandCount == 4)
        #expect(session.failedCommandCount == 2,
                "只数 outcome 会得 1、把两支直接相加会得 3——2 才是容斥的答案")
        // 两个来源各数一遍：交并都必须为空/为 1，否则容斥的减法在这里没有守卫。
        #expect(try await commandRows(harness, outcomes: [.failure]) == 1)
        #expect(try await commandRows(
            harness,
            outcomes: Set(CommandOutcome.allCases).subtracting([.failure]),
            nonZeroExitCode: true) == 1)
    }

    /// 反向守卫（本文件最重要的一条）：**只投不数**的窗口里两列必须还是旧值。
    /// 把 `record(command:)` 里那两句 `+= 1` 接回来，这一格当场红——
    /// 上面三条都是"最终相等"，对"中间多记一次"失明。
    @Test("record 之后、对平之前：列上仍是 0（自增一接回来就红）")
    func stagingDoesNotTouchTheColumns() async throws {
        let harness = try await makeIngestHarness()
        let agentID = try #require(await storedSession(harness).agentID)
        let t = Date(timeIntervalSinceReferenceDate: 800_000_400)
        harness.auditor.setCommands([
            record(agentID: agentID, line: "swift test", outcome: .failure, exit: 1, startedAt: t)
        ])
        await harness.engine.rescanNow()
        harness.auditor.setCommands([])
        let before = try await storedSession(harness)
        #expect(before.commandCount == 0, "投进缓冲的那一刻不该产出数字")
        #expect(before.failedCommandCount == 0)
        #expect(await harness.engine.components.lifecycle.hasStagedCommandCounts,
                "欠账得挂着，否则没人会再去数这两列")
        try await settleCredits(harness)
        let after = try await storedSession(harness)
        #expect(after.commandCount == 1, "对平之后才有的数——这条把「只投不数」与「数了就对」两头都钉住")
        #expect(after.failedCommandCount == 1)
    }
}
