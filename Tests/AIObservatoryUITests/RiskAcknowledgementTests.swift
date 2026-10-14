//
//  RiskAcknowledgementTests.swift
//  AIObservatoryUITests
//
//  Owner: 总控（组合根 / 需求⑧ 处置动作）
//  ─────────────────────────────────────────────────────────
//  钉住一件事：**库里没落成，界面就不许显示"已确认"**。
//  旧实现是协议不抛错、引擎把失败吞进 `os_log`，而 `SecurityModel.acknowledge`
//  紧接着无条件 `markAcknowledged` ⇒ 用户点完看到"已确认"，重启后那条又变回未确认。
//  风险确认是需求⑧ 的处置动作，"以为处置过了"比"报错说没处置成"严重得多。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryTestSupport

private struct StoreUnavailable: Error {}

/// 落库一定失败的 controller：模拟磁盘不可写 / 库被关掉 / SQL 报错。
private struct FailingController: ObservatoryControlling {
    func start() async {}
    func stop() async {}
    func rescanNow() async {}
    func updateSettings(_ settings: ObservatorySettings) async {}
    func acknowledgeRiskEvent(id: UUID) async throws { throw StoreUnavailable() }
}

@Suite("UI: 风险确认必须落库成功才改状态", .timeLimit(.minutes(1)))
@MainActor struct RiskAcknowledgementTests {

    /// 必须落在 `SecurityModel` 默认时间范围内，否则 `load()` 返回 0 行、
    /// 用例测的就不是"确认失败"而是"列表是空的"（第一版就踩了：写死 1.8e9 已是 2027 年）。
    private static let stamp = Date(timeIntervalSinceNow: -120)

    private static func risk(_ title: String) -> RiskEvent {
        RiskEvent(
            timestamp: stamp,
            level: .high,
            category: .massDeletion,
            title: title,
            filePaths: ["/repo/Sources/App.swift"]
        )
    }

    private func model(
        risks: [RiskEvent],
        controller: (any ObservatoryControlling)? = nil
    ) -> SecurityModel {
        let service = InMemoryObservatoryService()
        service.seed(risks: risks)
        let runtime = ObservatoryRuntime(
            service: service,
            controller: controller ?? service,
            updates: service
        )
        return SecurityModel(runtime: runtime)
    }

    @Test("落库失败：返回 false、界面状态不动、并把失败说给人听")
    func failureKeepsTheRowUnacknowledged() async throws {
        let subject = model(risks: [Self.risk("批量删除")], controller: FailingController())
        await subject.load()
        #expect(subject.events.count == 1)
        let event = try #require(subject.events.first)
        #expect(event.isAcknowledged == false, "刚加载完就该是未确认")

        let ok = await subject.acknowledge(event: event)

        #expect(ok == false, "落库失败必须让调用方知道")
        #expect(subject.events[0].isAcknowledged == false,
                "库里没落成，界面却显示已确认 = 撒谎（旧行为）")
        let message = subject.errorMessage ?? ""
        #expect(message.contains("确认没有保存"),
                "失败要上屏，实际 errorMessage = \(subject.errorMessage ?? "nil")")
    }

    @Test("落库成功：才就地标记为已确认，且不残留错误")
    func successMarksAfterTheStoreAcceptsIt() async throws {
        let subject = model(risks: [Self.risk("批量删除")])
        await subject.load()
        let event = try #require(subject.events.first)

        let ok = await subject.acknowledge(event: event)

        #expect(ok == true)
        #expect(subject.events[0].isAcknowledged == true)
        #expect(subject.errorMessage == nil)
    }

    @Test("批量确认在第一条失败时就停，不把 N 条失败堆成 N 条提示")
    func batchStopsAtTheFirstFailure() async {
        let subject = model(
            risks: [Self.risk("批量删除 A"), Self.risk("批量删除 B")],
            controller: FailingController()
        )
        await subject.load()
        #expect(subject.events.count == 2)

        await subject.acknowledgeAllVisible()

        #expect(subject.events.contains { $0.isAcknowledged } == false,
                "一条都没落库，却有任何一条显示已确认")
        #expect(subject.errorMessage?.contains("确认没有保存") == true)
    }
}
