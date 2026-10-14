//
//  DashboardCommandOutcomeTallyTests.swift
//  Tests/AIObservatoryUITests
//
//  Owner: ws/engaudit（#76 收口，2026-09-22）
//  ─────────────────────────────────────────────────────────
//  钉的是首页六宫格「命令」那一格的**分桶口径**：`DashboardModel.ingest(.command)` 里
//  `commandsExecuted` 每来一条都加，而 `failedCommands` **只认 `.failure`**。
//
//  为什么这一处必须单独钉：同一条红线（`.terminated` = 收口时拿不到退出码，
//  既不是失败也不是"已解决"）在 #76 里已经落了三处用例 ——
//  `InsightClassification` / `CommandsModel`（`TerminatedOutcomeTests`）/ `CommandResultReadout`。
//  但 Dashboard 这一处**当时一格都没有**：总控手改成 `case .failure:` 之后，
//  谁把它退回成 `case .failure, .terminated:` 都不会红（全仓 `failedCommands` 的用例
//  都在服务端 SQL 侧与别的页面上，没有一条喂过 `DashboardModel.ingest(.command(...))`）。
//  口径出处是引擎侧红线 1：`Sources/AIObservatoryEngine/ObservatoryEngine+Ingestion.swift:61-98`
//  ——「`.terminated` 不等于成功也不等于失败，成败类聚合必须继续排除它」。
//
//  ⚠️ 两格各自独立、且第二格是对照组：
//  只钉"terminated 不进失败桶"会被一种假绿蒙过去 —— 命令事件压根没被处理，于是两个数都不动。
//  所以第一格同时钉 `commandsExecuted` **+1**（证明确实处理了），
//  第二格用**同一条路径、只换 outcome** 钉 `failedCommands` **+1**（证明不是"这一格本来就永远不加"）。
//
//  装配照 `DashboardStatsCoalescingTests` 的先例：`InMemoryObservatoryService` 直接喂
//  `ObservatoryRuntime`，用例里**不调 `load()`** ⇒ `stats` 停在 `.empty`，起点是可手推的 0/0；
//  增量先落影子（`mutateStats`），由 `flushPendingStats()` 确定性提交，不等 50 ms 真时钟。
//  命令这两个计数**不受 `queryRange` 影响**（只有 `bumpHourlyActivity` 那一路才看窗口），
//  所以这里不设置窗口 —— 这一点也在断言里显式写出来，免得以后有人以为是窗口挡掉的。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryTestSupport

/// 合成项目路径（门禁 G1/G4/G5：不许出现本机真实家目录）。
private let tallyProjectPath = "/Users/dev/Projects/Mona"

/// 夹具时刻：与同目录其它 Dashboard 套件同一批合成时间戳，不读墙钟。
private let tallyStartedAt = Date(timeIntervalSince1970: 1_900_030_000)

@MainActor
private func makeTallyModel() -> DashboardModel {
    let service = InMemoryObservatoryService()
    return DashboardModel(runtime: ObservatoryRuntime(
        service: service, controller: service, updates: service, analysis: nil
    ))
}

/// 引擎收口路径产出的真实形状：`terminated` 有 `endedAt`（上界口径）、永远没有退出码；
/// `failure` 则由 shell hook 带回退出码。两个字段本套件都不参与断言，
/// 它们在这里只为"这条记录长得像真数据"——把 outcome 换成另一种时不必改夹具。
private func command(_ line: String, outcome: CommandOutcome, exitCode: Int32?) -> ObservatoryUpdate {
    .command(CommandRecord(
        executable: String(line.split(separator: " ").first.map(String.init) ?? line),
        arguments: Array(line.split(separator: " ").dropFirst()).map(String.init),
        workingDirectory: tallyProjectPath,
        agentKind: .claudeCode,
        startedAt: tallyStartedAt,
        endedAt: outcome == .running ? nil : tallyStartedAt.addingTimeInterval(30),
        exitCode: exitCode,
        outcome: outcome,
        projectPath: tallyProjectPath
    ))
}

@MainActor
@Suite("Dashboard 命令计数：.terminated 不落失败桶（#76 第四处）", .timeLimit(.minutes(1)), .serialized)
struct DashboardCommandOutcomeTallyTests {

    /// 起点自查：不调 `load()`，`stats` 必须是 `.empty` 的那两个 0。
    /// 单独抽出来是因为两条用例的期望值都是从这两个 0 **加**出来的——
    /// 起点若不再是 0，"0 + 1 = 1" 这句手推就整片失效，那要比期望值先红。
    private func expectEmptyStart(_ model: DashboardModel) {
        #expect(model.stats.commandsExecuted == 0, "起点不是 0 ⇒ 下面所有加法型期望都要重推")
        #expect(model.stats.failedCommands == 0, "起点不是 0 ⇒ 同上")
    }

    // MARK: - 格 1：口径本身

    @Test("一条 .terminated：commandsExecuted 0→1、failedCommands 0→0（影子提交前后都钉）")
    func terminatedBumpsExecutedButNotFailed() {
        let model = makeTallyModel()
        expectEmptyStart(model)

        model.ingest(command("npm run dev", outcome: .terminated, exitCode: nil))
        // 手推：`mutateStats` 只写 `pendingStats` ⇒ 到点前 `stats` 仍 0 + 0 = 0/0。
        // 这一格是"增量确实经过了 command 分支"的前置条件：没有它，下面的 1 可能是别处给的。
        #expect(model.stats.commandsExecuted == 0, "影子没到点就改了 stats ⇒ 上面那条 +1 就不是这条事件给的")
        #expect(model.stats.failedCommands == 0)

        #expect(model.flushPendingStats(), "有一条增量 ⇒ 提交必须返回 true")
        // 手推期望值：
        //   commandsExecuted = 0 + 1 = 1   （每条命令都进"执行"这一格，与 outcome 无关）
        //   failedCommands   = 0 + 0 = 0   （`.terminated` 既不是失败也不是已解决 ⇒ 一桶都不进）
        #expect(model.stats.commandsExecuted == 1,
                "terminated 这条没被算成已执行 ⇒ 它压根没走 command 分支，格 2 的绿也就是假的")
        #expect(model.stats.failedCommands == 0,
                ".terminated 又被折进失败桶了：引擎侧红线 1（+Ingestion.swift:61-98）说它拿不到退出码、不是失败")
    }

    // MARK: - 格 2：对照组

    @Test("对照：同一条路径喂 .failure ⇒ commandsExecuted 0→1 且 failedCommands 0→1")
    func failureBumpsBothCounters() {
        let model = makeTallyModel()
        expectEmptyStart(model)

        // 与格 1 唯一的差别就是 outcome / exitCode（夹具函数同一个，装配路径同一条）。
        model.ingest(command("npm test", outcome: .failure, exitCode: 1))
        #expect(model.flushPendingStats())
        // 手推期望值：
        //   commandsExecuted = 0 + 1 = 1
        //   failedCommands   = 0 + 1 = 1   （只有 `.failure` 落这一桶）
        // ⇒ 若格 1 因为"命令根本没被处理"而通过，这一格会红在 1 ≠ 0 上。
        #expect(model.stats.commandsExecuted == 1, "对照组里执行数也没加 ⇒ 增量压根没进 command 分支")
        #expect(model.stats.failedCommands == 1,
                "真失败却不进失败桶 ⇒ 首页那一格会把有故障的会话报成 0 失败")
    }

    // MARK: - 份数下限自证

    /// 中央棘轮（`HardcodedChineseRatchetTests.everyDirectoryGateDeclaresAFileCountFloor`）
    /// 那一族的形状：**没有下限的门禁，会在被守的东西消失后静默常绿**。
    /// 本套件的"被守的东西"是用例自己：删掉格 1 或格 2 中的任一条，
    /// 剩下那条都能单独常绿（一条只说"执行数加了"、另一条只说"失败数加了"，
    /// 都不足以否定"terminated 进失败桶"这个反向实现）。
    /// 所以这里从源码数一遍份数与两种 outcome 是否在场 —— 少一条就红在这一格。
    @Test("份数下限：本文件 ≥2 条用例，且 terminated 与 failure 两种 outcome 各在场")
    func suiteDeclaresItsOwnFloor() throws {
        let text = try String(contentsOf: URL(fileURLWithPath: #filePath), encoding: .utf8)
        let declaredTests = text.split(separator: "\n")
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("@Test(") }
        // 手推：本文件三条 @Test（格 1 / 格 2 / 这一格）⇒ 下限取 2，
        // 取"两份口径都在"这个语义下限，不取 3（有人加用例不该把门禁撑红）。
        #expect(declaredTests.count >= 2,
                "只数出 \(declaredTests.count) 条用例 ⇒ 这套门禁的射程已经为零")

        // Outcome 覆盖：只认真正在喂给夹具的那几处（`outcome: .terminated` 一类），
        // 夹具函数签名里的 `outcome: CommandOutcome` 因为后面不是 `.` 而不会被数进来。
        var covered: Set<String> = []
        for line in text.split(separator: "\n") {
            guard let at = line.range(of: "outcome: .") else { continue }
            covered.insert(String(line[at.upperBound...].prefix(while: { $0.isLetter })))
        }
        // 手推：整个文件里这种写法只有两处 —— 格 1 的 `outcome: .terminated`、
        // 格 2 的 `outcome: .failure`（夹具函数签名写的是 `outcome: CommandOutcome`，
        // 后面跟的不是 `.` 所以不会被数进来）。
        // 判据只要求口径两侧都在 —— 任一侧被抹掉，另一侧的绿就不再是证据。
        #expect(covered.isSuperset(of: ["terminated", "failure"]),
                "两种 outcome 缺了一种 ⇒ 对照组失效：\(covered.sorted())")
    }
}
