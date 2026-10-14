//
//  SessionKeyboardSelectionTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uiclose · 键盘导航回归）
//  ─────────────────────────────────────────────────────────
//  守 `SessionsModel.moveSelection(by:)`：↑/↓ 在**可见列表**里移动一格、两端停住不环绕。
//  这条原本是 `List(selection:)` 白送的，换成 `LazyVStack` 之后丢了，
//  旧代码里留着一句「已知功能回归……本车道不许跑编译所以没写」。
//  期望值用 `displayIndex` 手推（101/102/103），不读被测代码算出来的下标。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

/// 三条会话：`startedAt` 依次 +10 分钟，`displayIndex` 与插入顺序同号。
/// 列表默认 `.newestFirst` ⇒ 屏幕上从上到下是 **103、102、101**。
/// 造一个只有这三条会话的模型，并把范围放到「全部」。
///
/// ⚠️ `timeRange = .all` 这一步不能省：模型默认范围是**今天**，而夹具用的是固定 epoch
/// （2026-09-17），跨到第二天跑就会全被日期过滤掉 ⇒ 列表空、断言假红，
/// 更糟的是「空列表不崩」那类用例会在什么都没测到的情况下变绿。
@MainActor
private func makeModel(sessions: [AgentSession]) -> SessionsModel {
    let service = InMemoryObservatoryService()
    service.seed(sessions: sessions)
    let model = SessionsModel(
        runtime: ObservatoryRuntime(service: service, controller: service, updates: service)
    )
    model.timeRange = .all
    return model
}

@MainActor
private func seeded() -> SessionsModel {
    makeModel(sessions: [
        AgentSession(displayIndex: 101, kind: .claudeCode, title: "最早", startedAt: t0),
        AgentSession(displayIndex: 102, kind: .claudeCode, title: "中间", startedAt: t0.addingTimeInterval(600)),
        AgentSession(displayIndex: 103, kind: .openAICodex, title: "最新", startedAt: t0.addingTimeInterval(1_200)),
    ])
}

@Suite("UI: 会话列表键盘换选中", .timeLimit(.minutes(1)))
@MainActor struct SessionKeyboardSelectionTests {

    @Test("进页面默认选中最上面那条（newestFirst ⇒ 103）")
    func loadSelectsFirstRow() async {
        let model = seeded()
        await model.load()
        #expect(model.visibleSessions.map(\.displayIndex) == [103, 102, 101])
        #expect(model.selected?.displayIndex == 103)
    }

    @Test("↓ 一次走一行，到底停住不环绕")
    func downMovesOneRowAndClamps() async {
        let model = seeded()
        await model.load()
        await model.moveSelection(by: 1)
        #expect(model.selected?.displayIndex == 102)
        await model.moveSelection(by: 1)
        #expect(model.selected?.displayIndex == 101)
        // 已经到底：再按 ↓ 必须停在 101，而不是跳回 103
        await model.moveSelection(by: 1)
        #expect(model.selected?.displayIndex == 101)
    }

    @Test("↑ 往回走；到顶停住；delta 超过整段也只到端点")
    func upMovesBackAndClamps() async {
        let model = seeded()
        await model.load()
        await model.moveSelection(by: 2)
        #expect(model.selected?.displayIndex == 101)
        await model.moveSelection(by: -1)
        #expect(model.selected?.displayIndex == 102)
        await model.moveSelection(by: -5)
        #expect(model.selected?.displayIndex == 103)
        await model.moveSelection(by: -5)
        #expect(model.selected?.displayIndex == 103)
    }

    @Test("没有选中时：↓ 落到首行、↑ 落到末行")
    func fromNoSelectionPicksAnEnd() async {
        let model = seeded()
        await model.load()
        await model.clearSelection()
        #expect(model.selectedID == nil)
        await model.moveSelection(by: 1)
        #expect(model.selected?.displayIndex == 103)

        await model.clearSelection()
        await model.moveSelection(by: -1)
        #expect(model.selected?.displayIndex == 101)
    }

    @Test("delta 为 0 不动选中（按键重复不该把选中甩到别处）")
    func zeroDeltaIsANoOp() async {
        let model = seeded()
        await model.load()
        await model.moveSelection(by: 1)
        let before = model.selected?.displayIndex
        #expect(before == 102)
        await model.moveSelection(by: 0)
        #expect(model.selected?.displayIndex == 102)
    }

    @Test("空列表上按方向键不崩、不造出选中")
    func emptyListStaysEmpty() async {
        let model = makeModel(sessions: [])
        await model.load()
        await model.moveSelection(by: 1)
        await model.moveSelection(by: -1)
        #expect(model.selectedID == nil)
    }

    @Test("「只看有风险」过滤生效时，键盘只在可见行里走（不会跳到被过滤掉的行）")
    func movesStayInsideTheVisibleList() async {
        let model = makeModel(sessions: [
            AgentSession(displayIndex: 101, kind: .claudeCode, title: "最早 · 有风险",
                         startedAt: t0, riskEventCount: 2),
            AgentSession(displayIndex: 102, kind: .claudeCode, title: "中间 · 无风险",
                         startedAt: t0.addingTimeInterval(600), riskEventCount: 0),
            AgentSession(displayIndex: 103, kind: .openAICodex, title: "最新 · 有风险",
                         startedAt: t0.addingTimeInterval(1_200), riskEventCount: 1),
        ])
        await model.load()
        model.setRiskyOnly(true)
        // 可见列表只剩 103 与 101（102 被过滤掉）
        #expect(model.visibleSessions.map(\.displayIndex) == [103, 101])
        #expect(model.selected?.displayIndex == 103)
        await model.moveSelection(by: 1)
        // 跳过被过滤的 102，直接到 101 —— 键盘走的必须是「屏幕上看到的那几行」
        #expect(model.selected?.displayIndex == 101)
    }
}
