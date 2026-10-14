//
//  DashboardStatsCoalescingTests.swift
//  Tests/AIObservatoryUITests
//
//  Owner: ws/engaudit（#53 动作 1，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  钉的是"一波 N 条事件只引发 1 次 body 重算"，以及它的两个反面：
//   · 不许变成"读数冻在启动值"（#8 那一族）——提交后必须看到真值，且后续批次还能继续变；
//   · 无新数据时提交必须是**空操作**（不产生赋值）⇒ 重算次数不随轮数增长。
//  窗口本身（50 ms）不由用例等真时钟：用例直接驱动 `flushPendingStats()`，
//  这样"影子先累加、到点一次提交"这个形状是可断言的，而不是靠 sleep 赌时序。
//

import Testing
import Foundation
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryTestSupport

private let coalescePath = "/Users/demo/Projects/Mona"

@MainActor
private func makeModel() -> DashboardModel {
    let service = InMemoryObservatoryService()
    return DashboardModel(runtime: ObservatoryRuntime(
        service: service, controller: service, updates: service, analysis: nil
    ))
}

private func fileChange(_ index: Int) -> ObservatoryUpdate {
    .fileChange(FileChange(
        path: "\(coalescePath)/Sources/F\(index).swift",
        kind: .modified,
        timestamp: Date(timeIntervalSince1970: 1_900_020_000),
        agentKind: .claudeCode,
        linesAdded: 1,
        linesRemoved: 0,
        projectPath: coalescePath
    ))
}

@Suite("Dashboard 增量：一波事件只提交一次", .serialized)
@MainActor struct DashboardStatsCoalescingTests {

    @Test("20 条文件变更先累加不提交；一次提交后读数等于 20，再灌 5 条还能变")
    func burstCommitsOnce() {
        let model = makeModel()
        let baseline = model.stats.filesModified

        for index in 0..<20 { model.ingest(fileChange(index)) }
        // 没到点：一条都没提交 ⇒ 这一波只会在到点时引发一次重算
        #expect(model.stats.filesModified == baseline, "影子还没到点就直接改了 stats ⇒ 合并没生效")

        #expect(model.flushPendingStats(), "有影子时提交必须返回 true")
        #expect(model.stats.filesModified == baseline + 20, "提交后必须看到全部 20 条 ⇒ 不许把合并做成丢数")

        for index in 20..<25 { model.ingest(fileChange(index)) }
        #expect(model.flushPendingStats())
        #expect(model.stats.filesModified == baseline + 25, "第二批必须还能推进 ⇒ 不许冻在上一批的值")
    }

    @Test("无新数据时提交是空操作：连做 50 次不产生任何赋值")
    func idleCommitDoesNothing() {
        let model = makeModel()
        for _ in 0..<50 {
            #expect(!model.flushPendingStats(), "没有增量却报告提交了 ⇒ 每轮都会白重算一次")
        }
        #expect(model.stats.filesModified == 0)
        #expect(model.stats.hourlyActivity.isEmpty)
    }

    @Test("hourly 分桶也走影子：一波事件只加一个小时的计数，不逐条排序")
    func hourlyActivityAccumulatesInShadow() {
        let model = makeModel()
        let stamp = Date(timeIntervalSince1970: 1_900_020_000)
        // #75 之后增量要落进**所选窗口**才入账（窗口外的事件不改这张图，见
        // `DashboardRangeParityTests` 里钉的那一条）。这个用例原先靠 `queryRange` 的默认值
        // 「今天」跑，而夹具时刻是 2030 年 —— 旧实现压根不看窗口，所以它"碰巧"通过。
        // 这里把窗口显式声明成包住夹具时刻，**断言本身一字未改**（8 条 ⇒ 一格 8 次）。
        model.queryRange = DateRangeFilter(start: stamp.addingTimeInterval(-1800), end: stamp.addingTimeInterval(1800))
        for _ in 0..<8 {
            model.ingest(.timelineEvent(TimelineEvent(
                timestamp: stamp,
                agentKind: .claudeCode,
                kind: .fileModified,
                title: "改了 F.swift",
                summary: "1 行",
                filePath: "\(coalescePath)/Sources/F.swift"
            )))
        }
        #expect(model.stats.hourlyActivity.isEmpty, "到点前不该看到任何分桶变化")
        #expect(model.flushPendingStats())
        let total = model.stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }
        #expect(total == 8, "8 条事件必须都进同一小时桶，实得 \(total)")
    }
}
