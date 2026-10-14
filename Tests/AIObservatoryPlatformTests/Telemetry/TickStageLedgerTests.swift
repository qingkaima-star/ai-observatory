//
//  TickStageLedgerTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-Platform（性能收尾线 ws/perfclose）
//  ─────────────────────────────────────────────────────────
//  这把账的**全部口径**都用手推字面量钉住：注入一个按脚本给数的 CPU 时钟，
//  于是每个期望值都能手算（不读真进程、不用墙钟——AGENTS §6 已明确墙钟不是性能尺子）。
//  所有秒数取二进制可精确表示的值（n/32、n/16、n/2），×1000 之后仍是精确毫秒，
//  所以 `==` 比较不是"碰运气的浮点相等"。
//

import Testing
import Foundation
import os   // `OSAllocatedUnfairLock`
@testable import AIObservatoryPlatform

/// 脚本化 CPU 时钟：按顺序给出累计 CPU 秒，取完后重复末值。
/// 同时记录被调了几次——那是仪器自身开销的上界（读数次数），与机器负载无关。
private final class ScriptedCPU: Sendable {
    private struct Box: Sendable { var values: [Double]; var index = 0; var calls = 0 }
    private let lock = OSAllocatedUnfairLock(initialState: Box(values: []))

    init(_ values: [Double]) { lock.withLock { $0.values = values } }

    var callCount: Int { lock.withLock { $0.calls } }

    func read() -> Double {
        lock.withLock { box in
            box.calls += 1
            let value = box.index < box.values.count ? box.values[box.index] : box.values.last ?? 0
            box.index += 1
            return value
        }
    }
}

/// 建账本 + 拿到它的读数器（要看调用次数的用例用后者）。
private func makeLedger(_ values: [Double]) -> (TickStageLedger, ScriptedCPU) {
    let cpu = ScriptedCPU(values)
    return (TickStageLedger(cpuSeconds: cpu.read), cpu)
}

/// 走完一个 tick 的九个阶段边界（与 `ObservatoryEngine.runTick()` 的调用顺序一致）。
private func runFullTick(_ tick: TickStageLedger) {
    tick.beginTick()
    tick.mark(.scanProcesses)
    tick.mark(.detectAgents)
    tick.mark(.ingestAgents)
    tick.mark(.ingestCommands)
    tick.mark(.ingestPerformance)
    tick.mark(.syncProjects)
    tick.mark(.prune)
    tick.mark(.settling)
    tick.endTick()
}

@Suite("WS-Platform：每-tick 阶段 CPU 账本（手推字面量口径）")
struct TickStageLedgerTests {

    @Test("一个 tick 九个阶段各分到一个读数区间：每段 1.0 s，加总恰等于进程总量")
    func nineStagesPartitionTheWindow() {
        let (tick, cpu) = makeLedger(Array(0...9).map { Double($0) })
        runFullTick(tick)
        let boundaryReads = cpu.callCount     // snapshot 自己也要读一次表，所以先记下边界读数次数
        let account = tick.snapshot()         // 第 11 次读数，脚本已耗尽 ⇒ 仍是 9.0

        #expect(account.tickCount == 1)
        #expect(boundaryReads == TickStageLedger.boundaryCountPerTick,
                "一个 tick 只允许 \(TickStageLedger.boundaryCountPerTick) 次读数")
        #expect(account.attributedCPUMilliseconds == 9_000, "Σ 阶段 = 9 段 × 1000 ms")
        #expect(account.processCPUMilliseconds == 9_000, "总量 = 末读数 9.0 − 首读数 0")
        #expect(account.unattributedCPUMilliseconds == 0)
        #expect(!account.isClockInconsistent)
        for stage in TickStage.allCases {
            #expect(account.stageCPUMilliseconds[stage] == 1_000, "\(stage.rawValue) 应恰好一个 1.0 s 区间")
        }
    }

    @Test("每 tick 的读数次数按构造有界（仪器不得吃掉它要测的预算）")
    func boundaryCountIsBoundedByConstruction() {
        let (tick, cpu) = makeLedger(Array(0...29).map { Double($0) })
        runFullTick(tick)
        runFullTick(tick)
        #expect(
            cpu.callCount == TickStageLedger.boundaryCountPerTick * 2,
            "两轮应各读 \(TickStageLedger.boundaryCountPerTick) 次，实测 \(cpu.callCount) 次"
        )
        #expect(TickStageLedger.boundaryCountPerTick == 10, "beginTick + 8 次 mark + endTick")
    }

    @Test("账外工作显式成为「未归属」余额：不减总数，也不被读成余量")
    func workOutsideStagesBecomesResidual() {
        let (tick, cpu) = makeLedger([0, 0.03125, 0.0625, 0.5, 0.5])
        tick.beginTick()
        tick.mark(.scanProcesses)
        tick.endTick()
        let account = tick.snapshot()

        #expect(account.attributedCPUMilliseconds == 62.5, "storeReady 31.25 + scanProcesses 31.25")
        #expect(account.processCPUMilliseconds == 500, "0.5 s − 0")
        #expect(account.unattributedCPUMilliseconds == 437.5)
        #expect(account.isOverBudget(cycleSeconds: 3) == false, "只看已入账：62.5 < 90 ⇒ 像是达标")
        #expect(account.isOverBudgetIncludingUnattributed(cycleSeconds: 3), "含余额：500 > 90 ⇒ 其实超")
        #expect(cpu.callCount == 4)
    }

    @Test("snapshot 不偷走开着的段：同一 tick 内两次结账一致，且那段之后仍归它自己的阶段")
    func snapshotIsNonMutating() {
        // begin(0) → mark(scan, 1) → snapshot(2) → snapshot(2) → mark(detect, 3) → snapshot(3)
        let (tick, _) = makeLedger([0, 1, 2, 2, 3])
        tick.beginTick()
        tick.mark(.scanProcesses)
        let first = tick.snapshot()
        let second = tick.snapshot()
        tick.mark(.detectAgents)

        #expect(first == second, "同一读数下两次结账必须完全相同（快照不得改状态）")
        #expect(first.stageCPUMilliseconds[.scanProcesses] == 0)
        #expect(first.unattributedCPUMilliseconds == 1_000, "开着的 1.0 s 段此刻在余额里，不是丢了")
        // 若 snapshot 闭合过这一段，下面这条会停在 1000 而不是 2000（1.0 → 3.0 归 scan）。
        #expect(tick.snapshot().stageCPUMilliseconds[.scanProcesses] == 2_000)
    }

    @Test("第一段之前没有'幻影父段'：没开过的阶段拿不到 ms，也拿不到计数")
    func firstBoundarySetsTheBaselineWithoutInventingAParent() {
        // mark(prune, 0) → mark(settling, 4) → endTick(5) → snapshot(5)
        let (tick, _) = makeLedger([0, 4, 5, 5])
        tick.mark(.prune)
        tick.mark(.settling)
        tick.endTick()
        let account = tick.snapshot()

        #expect(account.tickCount == 1)
        #expect(account.stageCPUMilliseconds[.prune] == 4_000)
        #expect(account.stageCPUMilliseconds[.settling] == 1_000)
        #expect(account.unattributedCPUMilliseconds == 0, "首边界之前不存在区间，所以没有幻影归属也没有丢账")
        #expect(account.stageCPUMilliseconds[.storeReady] == 0)
        #expect(account.stageMarkCounts[.storeReady] == 0)
        #expect(!account.isStageCoverageComplete)
        let neverOpened = Set(TickStage.allCases.filter { $0 != .prune && $0 != .settling })
        #expect(Set(account.stagesWithWrongMarkCount) == neverOpened)
    }

    @Test("漏打一个 mark：恒等式照样成立，但边界计数当场点名漏项")
    func coverageCompletenessNamesTheMissingStage() {
        let (tick, _) = makeLedger(Array(0...40).map { Double($0) })
        runFullTick(tick)
        #expect(tick.snapshot().isStageCoverageComplete)

        // 模拟「runTick 里新增了一段活但忘了打边界」：第二轮跳过 mark(.syncProjects)。
        tick.beginTick()
        tick.mark(.scanProcesses)
        tick.mark(.detectAgents)
        tick.mark(.ingestAgents)
        tick.mark(.ingestCommands)
        tick.mark(.ingestPerformance)
        tick.mark(.prune)          // ← 少了 .syncProjects
        tick.mark(.settling)
        tick.endTick()

        let account = tick.snapshot()
        #expect(account.tickCount == 2)
        #expect(!account.isStageCoverageComplete)
        #expect(account.stagesWithWrongMarkCount == [.syncProjects])
        #expect(account.stageCPUMilliseconds[.syncProjects] == 1_000,
                "只有打了边界的第一轮分到 1.0 s；第二轮那段被并进 prune")
        #expect(account.attributedCPUMilliseconds + account.unattributedCPUMilliseconds
                == account.processCPUMilliseconds, "漏边界不减总量")
    }

    @Test("累计 CPU 倒退：不给负毫秒、也不给负余额")
    func clockRegressionClampsToZero() {
        let (tick, _) = makeLedger([5, 3, 1, 1])
        tick.beginTick()
        tick.mark(.scanProcesses)
        tick.endTick()
        let account = tick.snapshot()

        #expect(account.attributedCPUMilliseconds == 0)
        #expect(account.processCPUMilliseconds == 0, "末读数小于首读数 ⇒ 总量钳到 0，不是负数")
        #expect(account.unattributedCPUMilliseconds == 0)
        #expect(!account.isClockInconsistent)
    }

    @Test("阶段之和大于进程总量时如实报不自洽，而不是抹平")
    func clockInconsistencyIsReported() {
        let account = TickAccount(
            tickCount: 1,
            stageCPUMilliseconds: [.scanProcesses: 500],
            processCPUMilliseconds: 300
        )
        #expect(account.isClockInconsistent)
        #expect(account.unattributedCPUMilliseconds == 0, "余额钳到 0，不给出一个假的负数")
    }

    @Test("§6 的换算：3 秒周期 ⇒ 90 ms/tick；两 tick 各摊一半")
    func budgetConversion() {
        #expect(TickAccount.budgetMSPerTick(cycleSeconds: 3) == 90)
        #expect(TickAccount.budgetMSPerTick(cycleSeconds: 0) == 0)
        let account = TickAccount(
            tickCount: 2,
            stageCPUMilliseconds: [.scanProcesses: 100, .prune: 60],
            processCPUMilliseconds: 400
        )
        #expect(account.attributedMSPerTick == 80)
        #expect(account.msPerTick(.scanProcesses) == 50)
        #expect(account.unattributedMSPerTick == 120)
        #expect(!account.isOverBudget(cycleSeconds: 3), "已入账 80 < 90")
        #expect(account.isOverBudgetIncludingUnattributed(cycleSeconds: 3), "进程实际 200 > 90")
    }

    @Test("没跑过任何 tick：全是 0，不出现 NaN、不假装量过、九个键都在")
    func emptyLedgerIsAllZero() {
        let (tick, _) = makeLedger([0])
        let account = tick.snapshot()
        #expect(account.tickCount == 0)
        #expect(account.attributedCPUMilliseconds == 0)
        #expect(account.attributedMSPerTick == 0)
        #expect(account.msPerTick(.scanProcesses) == 0)
        #expect(!account.isOverBudget(cycleSeconds: 3))
        #expect(!account.isStageCoverageComplete, "0 个 tick 不构成「完备」的证据")
        #expect(account.stageCPUMilliseconds.count == TickStage.allCases.count,
                "快照必须给出每个阶段；缺键会被读成「这段没活」")
    }
}
