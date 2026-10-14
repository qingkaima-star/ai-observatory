//
//  PreviewFixtureShapeTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（#66 代码健康车道：预览夹具的形状守卫）
//  ─────────────────────────────────────────────────────────
//  为什么补这一份：`ObservatoryPreviewService` 的确定性夹具此前**零用例覆盖**
//  （全仓 `grep -rn ObservatoryPreview Tests` 为空），所以拆它的装配步骤时，
//  "全量绿"这句话对这份夹具并不成立。期望值一律按夹具自己的分段注释手推
//  （2 Agent / 7 Session / 7×7=49 事件 / 其中 3×7=21 条文件变更 / 8 份 diff /
//   16 命令 / 36 采样 / 24 点整机 / 4 风险 / 2 项目），不是抄实测输出。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

@Suite("UI: 预览夹具的形状（#66 拆装配步骤前后的对拍固化）")
struct PreviewFixtureShapeTests {

    /// 固定时刻 ⇒ 同一份夹具必须逐格可复现（拆前/拆后两版实测完全一致）。
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func service() -> ObservatoryPreviewService {
        ObservatoryPreviewService(now: Self.now)
    }

    @Test("九段的条数按夹具自己的注释手推，一格不许漂")
    func sectionCountsArePinned() async throws {
        let service = service()
        #expect(try await service.activeAgents().count == 2, "Agent 段漂了（注释写 2 个 running）")
        let sessions = try await service.sessions(matching: SessionQuery()).items
        #expect(sessions.count == 7, "Session 段漂了（running×2 + success×3 + failed + interrupted）")
        #expect(try await service.events(matching: EventQuery()).items.count == 49,
                "事件段 = 7 session × 7 类操作")
        #expect(try await service.fileChanges(matching: FileChangeQuery()).items.count == 21,
                "文件变更段 = 三种文件类操作 × 7 session")
        #expect(try await service.commands(matching: CommandQuery()).items.count == 16, "命令段")
        #expect(try await service.riskEvents(matching: RiskQuery()).items.count == 4, "风险段")
        #expect(try await service.projects().count == 2, "项目段")
    }

    @Test("diff 只给前 8 条文件变更配，性能采样合计 36 条、整机 24 点")
    func attachedCountsMatchTheirOwnRecipes() async throws {
        let service = service()
        let changes = try await service.fileChanges(matching: FileChangeQuery()).items
        var withDiff = 0
        for change in changes {
            if try await service.fileDiff(for: change.id) != nil { withDiff += 1 }
        }
        #expect(withDiff == 8, "夹具注释写「8 份完整 FileDiff」")
        var perfTotal = 0
        for session in try await service.sessions(matching: SessionQuery()).items {
            perfTotal += try await service.performanceSamples(sessionID: session.id).count
        }
        #expect(perfTotal == 36, "36 条 PerformanceSample 必须全部挂在某个 session 下")
        #expect(try await service.systemPerformance(since: Self.now.addingTimeInterval(-86_400)).count == 24,
                "24 点 SystemPerformanceSample")
    }

    @Test("仪表板与夹具自洽：分桶合计等于事件数、小时格固定 24 格、越出今日的事件为 0")
    func dashboardAgreesWithTheFixture() async throws {
        let service = service()
        let stats = try await service.dashboardStats(for: Self.now)
        let events = try await service.events(matching: EventQuery()).items
        let hourlyTotal = stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }
        #expect(stats.hourlyActivity.count == 24, "hourly 必须固定铺满 0…23，UI 不必自己补洞")
        #expect(hourlyTotal == 49, "分桶合计必须等于事件总数：\(hourlyTotal)")
        #expect(stats.sessionCount == 7)
        #expect(stats.riskEventCount == 4)
        #expect(stats.agentShares.count == 5, "五个出现过会话的 Agent 种类各占一格")
        let day = Calendar.current.startOfDay(for: Self.now)
        #expect(events.filter { $0.timestamp < day || $0.timestamp > Self.now }.isEmpty,
                "夹具必须全部落在今日，否则仪表板与时间线会对不上")
    }

    @Test("同一个 now 装两次，形状逐格相同（拆装配步骤时的对拍就是这条在盯）")
    func fixtureIsDeterministic() async throws {
        let a = try await service().events(matching: EventQuery()).items
        let b = try await service().events(matching: EventQuery()).items
        #expect(a.map(\.title) == b.map(\.title), "同时刻装配必须可复现")
        #expect(a.map(\.timestamp) == b.map(\.timestamp), "时间戳一格都不许漂")
    }
}
