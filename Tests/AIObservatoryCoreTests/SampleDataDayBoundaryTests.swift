//
//  SampleDataDayBoundaryTests.swift
//  AIObservatoryCoreTests
//
//  Owner: master-controller（测试支撑的样本生成归总控；原始取证由 WS-UI/uicopy 交回）
//  ─────────────────────────────────────────────────────────
//  来历（两条车道在同一件事上从相反方向动手，这里把结论钉成一个）：
//  · `uicopy` 在 00:07 与 00:21 两次全量跑里抓到 `CoreContractTests:132` 红：
//    `(stats.riskEventCount → 0) >= 1`。原因是样本风险时间戳写死
//    `now − 1500 / − 3600 / − 7200` 秒，而 `dashboardStats` 按**当日窗口**过滤
//    ⇒ 刚过午夜时它们全掉到昨天。他们用固定锚点把这个形状取证成用例。
//  · 总控同日 00:15 修的是生成端：`withinToday(_:)` 把相对时间戳夹进当天（`7026c3f`）。
//
//  所以本文件断言的是**修复后的不变量**：不论锚点落在当天哪一刻，三条风险都在当日窗口内。
//  它同时是 `CoreContractTests:132` 那条"用墙上时钟"的用例的确定性替身——
//  那条用例自己不该再依赖跑测试的时刻。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport

@Suite("测试支撑：样本风险必须落在当日窗口内（任何锚点）", .timeLimit(.minutes(1)))
struct SampleDataDayBoundaryTests {

    private static func riskCount(at anchorOffset: TimeInterval) async throws -> (Int, Int) {
        let now = Calendar.current.startOfDay(for: Date()).addingTimeInterval(anchorOffset)
        let stats = try await SampleData.demoService(now: now, sessionCount: 12)
            .dashboardStats(for: now)
        return (stats.riskEventCount, stats.sessionCount)
    }

    @Test("锚点 00:10 ⇒ 三条风险仍算当日（修前这里是 0，就是 CoreContractTests:132 红的那个形状）")
    func justAfterMidnightKeepsAllRisksToday() async throws {
        let (risks, sessions) = try await Self.riskCount(at: 600)
        #expect(risks == 3, "刚过午夜时当日风险数必须仍是 3；掉到 0 就说明时间戳没夹进当天")
        #expect(sessions > 0, "会话一直统计得到 ⇒ 红的不是整份样本空了，只有风险这一支跨了日界")
    }

    @Test("锚点 00:30 ⇒ 同样三条齐全")
    func halfPastMidnightKeepsAllRisksToday() async throws {
        let (risks, _) = try await Self.riskCount(at: 1_800)
        // 修前这里是 1（只有 now−1500 落在今天）。
        #expect(risks == 3)
    }

    @Test("锚点 09:00 ⇒ 三条齐全，与凌晨两档同值 ⇒ 当日风险数不再依赖跑测试的时刻")
    func middayIsUnchanged() async throws {
        let (risks, _) = try await Self.riskCount(at: 9 * 3600)
        #expect(risks == 3)
    }
}
