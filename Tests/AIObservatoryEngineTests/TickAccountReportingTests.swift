//
//  TickAccountReportingTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Platform（性能收尾线 ws/perfclose；补 `686b6b7` 漏掉的那段测试）
//  ─────────────────────────────────────────────────────────
//  上一轮交付 `tick-account` 周期日志时，**这条出口一行用例都没写**，
//  而 2026-09-21 的实测发现它在真机上根本读不到（这台宿主 `log show` 对任何 subsystem
//  都返回空）。这件事暴露两件事：
//   1. 我把"能在产品里核对"当成了结论，而它从没被验证过 ⇒ 已在认领牌落更正块；
//   2. 频率（每 20 轮一次）与"列齐不齐"此前只能靠"跑一次肉眼看日志"保证，
//      而恰恰是最不该靠肉眼的两件事。
//  ⇒ 把判断抽成 `shouldReportAccount` / `tickAccountLine` 两个纯函数，期望值手推。
//  这样即使出口暂时不通，"这一轮该不该打、打了什么"也已经是可回归的事实。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryPlatform

@Suite("Engine：tick-account 那行日志的周期与内容")
struct TickAccountReportingTests {

    @Test(arguments: [
        // (当前 tick 数, 上次打时的 tick 数, 间隔, 该不该打, 为什么)
        (20, 19, 20, true, "跨过 20 的倍数 ⇒ 打一次"),
        (21, 20, 20, false, "同一档内不得重复打"),
        (39, 38, 20, false, "38/39 都在第 1 档"),
        (40, 39, 20, true, "跨过 40 ⇒ 再打一次"),
        (19, 18, 20, false, "第一档内不打"),
        (0, 0, 20, false, "还没跑过 tick 不打"),
        (60, 20, 20, true, "中间漏检过也要能补上：跨过边界即打，不要求'恰好整除'"),
        (20, 0, 0, false, "间隔为 0 不得除零"),
    ])
    func cadence(current: Int, previous: Int, every: Int, expected: Bool, why: String) {
        #expect(
            ObservatoryEngine.shouldReportAccount(current: current, previous: previous, every: every) == expected,
            "current=\(current) previous=\(previous) every=\(every)：\(why)"
        )
    }

    @Test("行的内容 = 预算 + 九段每-tick 毫秒 + 已入账 + 未归属（期望串手推）")
    func lineCarriesEveryColumn() {
        let account = TickAccount(
            tickCount: 2,
            stageCPUMilliseconds: [.scanProcesses: 100, .prune: 60],
            processCPUMilliseconds: 400
        )
        // 手推：每 tick 各段 = 总毫秒 ÷ 2 ⇒ scan 50.00、prune 30.00、其余 0.00；
        //       已入账 = (100+60)/2 = 80.00；未归属 = (400−160)/2 = 120.00；预算 = 3×3%×1000 = 90.0。
        #expect(
            ObservatoryEngine.tickAccountLine(account: account, cycleSeconds: 3) ==
            "tick-account ticks=2 预算=90.0 ms/tick storeReady=0.00 scanProcesses=50.00"
            + " detectAgents=0.00 ingestAgents=0.00 ingestCommands=0.00 ingestPerformance=0.00"
            + " syncProjects=0.00 prune=30.00 settling=0.00 已入账=80.00 未归属=120.00"
        )
    }

    @Test("九个阶段一个都不能少（新增段落进 allCases 就必须出现在这行里）")
    func everyStageAppearsInTheLine() {
        let line = ObservatoryEngine.tickAccountLine(
            account: TickAccount(tickCount: 1, stageCPUMilliseconds: [:], processCPUMilliseconds: 10),
            cycleSeconds: 3
        )
        for stage in TickStage.allCases {
            #expect(line.contains("\(stage.rawValue)="), "少了 \(stage.rawValue) 这一列 ⇒ 加总当场不可核对")
        }
        #expect(line.contains("未归属="), "少了余额列 ⇒ 漏项会被读成余量")
    }

    @Test("一轮都没跑完时不出现 nan / inf（除零被守住）")
    func zeroTicksDoesNotDivideByZero() {
        let line = ObservatoryEngine.tickAccountLine(
            account: TickAccount(
                tickCount: 0, stageCPUMilliseconds: [.prune: 5], processCPUMilliseconds: 40
            ),
            cycleSeconds: 3
        )
        #expect(line.contains("ticks=0"))
        #expect(line.contains("已入账=0.00"), "0 轮时给 0，不假装量过")
        #expect(!line.contains("nan") && !line.contains("inf"), "除零泄漏到日志里：\(line)")
    }
}
