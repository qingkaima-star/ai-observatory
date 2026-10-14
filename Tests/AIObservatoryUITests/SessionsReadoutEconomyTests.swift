//
//  SessionsReadoutEconomyTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uiclose · 目标②③）
//  ─────────────────────────────────────────────────────────
//  守 Sessions 页那排「落单读数」的取舍规则。真机截图是出发点：
//  空态那一屏上有 **13 个 0**，同一个 `totalCount` 出现 **5 次**，
//  同一句「已加载 vs 服务端」的口径用散文写了 **3 遍**。
//  这里钉住的是可判定的那部分：什么该排、什么不该排。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

private let base = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private func makeModel(sessionCount: Int) -> SessionsModel {
    let service = InMemoryObservatoryService()
    service.seed(sessions: (0..<sessionCount).map { index in
        AgentSession(
            displayIndex: 100 + index,
            kind: .claudeCode,
            title: "会话 \(index)",
            startedAt: base.addingTimeInterval(Double(index) * 60)
        )
    })
    let model = SessionsModel(
        runtime: ObservatoryRuntime(service: service, controller: service, updates: service)
    )
    // 默认范围是「今天」，夹具用的是固定 epoch ⇒ 不设成「全部」会被日期过滤成空列表。
    model.timeRange = .all
    return model
}

private func labels(_ stats: [SessionsModel.SupplementaryStat]) -> [String] {
    stats.map(\.label)
}

@Suite("UI: 会话页读数不重复、零信息不排格", .timeLimit(.minutes(1)))
@MainActor struct SessionsReadoutEconomyTests {

    @Test("没有未加载、没有过滤条件时：只剩「排序」一条，不排三格 0 与「未启用」")
    func quietPageShowsOnlyTheOrdering() async {
        let model = makeModel(sessionCount: 3)
        await model.load()
        #expect(model.unloadedCount == 0)
        #expect(model.activeFilterCount == 0)
        // 旧版这里固定排四格：未加载 0 个 / 进行中 N 个（已加载内）/ 过滤条件 未启用 / 排序
        #expect(model.heroSupplementaryStats(.chineseSimplified)
                == [SessionsModel.SupplementaryStat(label: "排序", value: "最新在前")])
    }

    @Test("「进行中」不再在 hero 下面排第二遍——下面四格里已有同口径的一格")
    func runningCountIsNotDuplicated() async {
        let model = makeModel(sessionCount: 2)
        await model.load()
        #expect(!labels(model.heroSupplementaryStats(.chineseSimplified)).contains("进行中"))
    }

    @Test("真有未加载的行时才排「未加载」，且数值 = 服务端总数 − 已加载")
    func unloadedAppearsOnlyWhenThereIsSome() async {
        // 105 条会话、单页上限 100 ⇒ 服务端 total 105、本地 100 ⇒ 未加载 5
        let model = makeModel(sessionCount: 105)
        await model.load()
        #expect(model.totalCount == 105)
        #expect(model.sessions.count == 100)
        #expect(model.heroSupplementaryStats(.chineseSimplified).first(where: { $0.label == "未加载" })?.value == "5 个")
    }

    @Test("开了「只看有风险」才排「过滤条件」，内容带生效项数")
    func filterRowAppearsOnlyWhenActive() async {
        let service = InMemoryObservatoryService()
        service.seed(sessions: [
            AgentSession(displayIndex: 101, kind: .claudeCode, title: "有风险",
                         startedAt: base, riskEventCount: 2),
            AgentSession(displayIndex: 102, kind: .claudeCode, title: "没风险",
                         startedAt: base.addingTimeInterval(60), riskEventCount: 0),
        ])
        let model = SessionsModel(
            runtime: ObservatoryRuntime(service: service, controller: service, updates: service)
        )
        model.timeRange = .all
        await model.load()
        #expect(!labels(model.heroSupplementaryStats(.chineseSimplified)).contains("过滤条件"))

        model.setRiskyOnly(true)
        #expect(model.heroSupplementaryStats(.chineseSimplified).first(where: { $0.label == "过滤条件" })?.value
                == "1 项生效")
    }

    @Test("排序方向是这一排唯一常驻的那条（它决定列表第一行是谁，别处没说过）")
    func orderingFollowsTheQuery() async {
        let model = makeModel(sessionCount: 2)
        await model.load()
        #expect(model.heroSupplementaryStats(.chineseSimplified).last?.value == "最新在前")
        await model.setSortDescending(false)
        #expect(model.heroSupplementaryStats(.chineseSimplified).last?.value == "最早在前")
    }

    @Test("「文件改动」格的 caption 是它自己的拆分，不再挂风险事件数")
    func fileTileCaptionIsAboutFiles() async {
        let service = InMemoryObservatoryService()
        service.seed(sessions: [
            AgentSession(displayIndex: 101, kind: .claudeCode, title: "甲",
                         startedAt: base,
                         modifiedFileCount: 3, createdFileCount: 2, deletedFileCount: 1),
            AgentSession(displayIndex: 102, kind: .claudeCode, title: "乙",
                         startedAt: base.addingTimeInterval(60),
                         modifiedFileCount: 0, createdFileCount: 1, deletedFileCount: 0),
        ])
        let model = SessionsModel(
            runtime: ObservatoryRuntime(service: service, controller: service, updates: service)
        )
        model.timeRange = .all
        await model.load()
        // 新建 2+1=3 · 修改 3+0=3 · 删除 1+0=1；合计 = 三者相加 = 7 处
        #expect(model.loadedFileBreakdown(.chineseSimplified) == "新建 3 · 修改 3 · 删除 1")
        #expect(model.loadedTouchedFileTotal == 7)
        // 风险那句确实存在，只是不再属于这一格
        #expect(model.riskySessionCount == 0)
    }
}
