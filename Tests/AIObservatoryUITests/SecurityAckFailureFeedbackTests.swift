//
//  SecurityAckFailureFeedbackTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/trust（#77 风险确认失败必须有提示）
//  ─────────────────────────────────────────────────────────
//  这一页的缺陷形状是「值设了，没人读」：`SecurityModel.acknowledge` 早就把失败写进
//  `errorMessage`（`SecurityCopy.ackSaveFailed`），而渲染条件是
//  `errorMessage != nil && events.isEmpty` ⇒ 点确认时列表**必然非空**，那一格整条分支
//  走不到；`SecurityConfirmationSheet` 又是 fire-and-forget，返回的 `false` 就地丢弃。
//  台账第 5 节验收 2 要求「造一次真失败看到提示出现」，所以这里两把仪器都要有：
//   ① Model 级：错误确实被设值、主语（是读取还是确认）被记住、该撤的时候才撤；
//   ② **真渲染树**级（`A11yTree`，走 AX API 读本进程窗口的无障碍元素）：
//      那句原话真的出现在屏幕上。只测 ① 等于把「有视图读它」这件事又写回注释里。
//
//  失败是**注入**出来的，不是模拟出来的：
//   · 写失败 ⇒ `FailingController`（`acknowledgeRiskEvent` 一定抛，形状同
//     `RiskAcknowledgementTests`，那条用例是总控写的，这里不改动它）；
//   · 读失败 ⇒ `FlakyRiskReadService`（转发明库，只在 `riskEvents` 上按开关抛），
//     用来造「列表非空 + 最近一次读取失败」这一档 —— 旧写法同样没有任何视图读它。
//
//  ⚠️ 两条 AX 用例必须 `.serialized`：`A11yTree` 在同一时刻只能读一棵树
//     （泵循环期间会让出主执行序，别的用例的窗口会串进来，见 `AccessibilityTreeHarness` 文件头）。
//

import AppKit
import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

// MARK: - 注入件

/// 落库一定失败的 controller（形状与 `RiskAcknowledgementTests` 同源）。
private struct FailingController: ObservatoryControlling {
    func start() async {}
    func stop() async {}
    func rescanNow() async {}
    func updateSettings(_ settings: ObservatorySettings) async {}
    func acknowledgeRiskEvent(id: UUID) async throws { throw StoreUnavailable() }
}

private struct StoreUnavailable: Error {}

/// 只有**第一次**落库失败的 controller：用来钉「成功一次之后，上一句失败提示必须撤掉」。
/// `@unchecked Sendable`：测试替身，只在对应用例（`@MainActor`）里单线程访问。
private final class FirstWriteFailsController: ObservatoryControlling, @unchecked Sendable {
    private let inner: InMemoryObservatoryService
    private var attempts = 0

    init(_ inner: InMemoryObservatoryService) {
        self.inner = inner
    }

    func start() async {}
    func stop() async {}
    func rescanNow() async {}
    func updateSettings(_ settings: ObservatorySettings) async {}

    func acknowledgeRiskEvent(id: UUID) async throws {
        attempts += 1
        if attempts == 1 { throw StoreUnavailable() }
        try await inner.acknowledgeRiskEvent(id: id)
    }
}

/// 转发明库、但能让 `riskEvents` 按开关抛错的读服务。
///
/// `@unchecked Sendable`：测试替身，只在对应用例（`@MainActor`）里单线程访问，
/// 开关的写与读都发生在同一条主执行序上（同 `SelfProcessGaugeTests` 的假仪器口径）。
private final class FlakyRiskReadService: ObservatoryService, @unchecked Sendable {
    private let inner: InMemoryObservatoryService
    var failsRiskReads = false

    init(_ inner: InMemoryObservatoryService) {
        self.inner = inner
    }

    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        guard failsRiskReads else { return try await inner.riskEvents(matching: query) }
        throw StoreUnavailable()
    }

    func dashboardStats(for date: Date) async throws -> DashboardStats {
        try await inner.dashboardStats(for: date)
    }

    func activeAgents() async throws -> [AgentInstance] { try await inner.activeAgents() }

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        try await inner.sessions(matching: query)
    }

    func session(id: UUID) async throws -> AgentSession? { try await inner.session(id: id) }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        try await inner.events(matching: query)
    }

    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        try await inner.fileChanges(matching: query)
    }

    func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        try await inner.fileDiff(for: changeID)
    }

    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        try await inner.commands(matching: query)
    }

    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        try await inner.performanceSamples(sessionID: sessionID)
    }

    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        try await inner.systemPerformance(since: date)
    }

    func projects() async throws -> [ProjectActivity] { try await inner.projects() }

    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        try await inner.projectActivity(path: path, dateRange: dateRange)
    }

    func performanceSamples(sessionID: UUID, limit: Int) async throws -> [PerformanceSample] {
        try await inner.performanceSamples(sessionID: sessionID, limit: limit)
    }

    func systemPerformance(since date: Date, limit: Int) async throws -> [SystemPerformanceSample] {
        try await inner.systemPerformance(since: date, limit: limit)
    }
}

// MARK: - 夹具

private let stamp = Date(timeIntervalSinceNow: -120)

/// 一条待确认的高危事件：`requiresConfirmation` 是真的（确认卡与 `requestConfirmation` 都看它）。
private func risk(_ title: String, requiresConfirmation: Bool = true) -> RiskEvent {
    RiskEvent(
        timestamp: stamp,
        level: .high,
        category: .massDeletion,
        title: title,
        detail: "命中批量删除规则（#77 夹具）。",
        filePaths: ["/Users/dev/Projects/App.swift"],
        requiresConfirmation: requiresConfirmation,
        matchedRuleID: "R-MASSDEL-01"
    )
}

@MainActor
private func makeModel(
    risks: [RiskEvent],
    controller: (any ObservatoryControlling)? = nil,
    service: (any ObservatoryService)? = nil
) -> SecurityModel {
    let store = InMemoryObservatoryService()
    store.seed(risks: risks)
    let runtime = ObservatoryRuntime(
        service: service ?? store,
        controller: controller ?? store,
        updates: store
    )
    return SecurityModel(runtime: runtime)
}

// MARK: - ① Model 级：错误被设值、主语被记住、该撤时才撤

@Suite("Security #77 · 确认失败的提示有主语、有读者", .timeLimit(.minutes(1)))
@MainActor struct SecurityAckFailureModelTests {

    @Test("落库失败：errorMessage 设值，且主语记为「确认」")
    func failureRecordsItsOrigin() async throws {
        let model = makeModel(risks: [risk("批量删除")], controller: FailingController())
        await model.load()
        #expect(model.events.count == 1)
        let event = try #require(model.events.first)

        let saved = await model.acknowledge(event: event)

        #expect(saved == false)
        #expect(model.errorMessage?.contains("确认没有保存") == true)
        #expect(model.errorOrigin == .acknowledgement,
                "不记主语，成功路径就没法只撤自己那一句（会连读取失败一起抹掉）")
        #expect(model.events[0].isAcknowledged == false, "库里没落成，界面不许显示已确认")
    }

    @Test("随后一次成功的确认：只撤自己那句，提示不留在屏幕上撒谎")
    func successClearsOnlyAcknowledgementError() async throws {
        let store = InMemoryObservatoryService()
        store.seed(risks: [risk("批量删除 A"), risk("批量删除 B")])
        let model = SecurityModel(
            runtime: ObservatoryRuntime(service: store, controller: FirstWriteFailsController(store), updates: store)
        )
        await model.load()
        let (first, second) = (try #require(model.events.first), try #require(model.events.last))

        #expect(await model.acknowledge(event: first) == false)
        let message = try #require(model.errorMessage)
        #expect(message.contains("确认没有保存"))

        #expect(await model.acknowledge(event: second) == true)
        #expect(model.errorMessage == nil,
                "已经有一次成功的写 ⇒ 上一句「确认没有保存」过时了，留着它就是说一件不做数的事")
        #expect(model.errorOrigin == nil)
    }

    @Test("确认失败后的一次成功重读：提示必须留在屏幕上（重读不 retract 一次失败的写）")
    func reloadDoesNotEraseAckFailure() async throws {
        let model = makeModel(risks: [risk("批量删除")], controller: FailingController())
        await model.load()
        _ = await model.acknowledge(event: try #require(model.events.first))
        let message = try #require(model.errorMessage)

        await model.load()   // 读是成功的（mimic 用户下拉刷新 / 改过滤条件）

        #expect(model.errorMessage == message,
                "那一行照旧显示未确认 ⇒ 「确认没有保存」这句仍然是事实，刷新不许把它抹掉")
        #expect(model.errorOrigin == .acknowledgement)
    }

    @Test("读取失败的主语是「读取」，与确认失败不串台")
    func readFailureRecordsReadingOrigin() async {
        let store = InMemoryObservatoryService()
        store.seed(risks: [risk("批量删除")])
        let flaky = FlakyRiskReadService(store)
        let model = makeModel(risks: [risk("批量删除")], service: flaky)
        flaky.failsRiskReads = true

        await model.load()

        #expect(model.errorMessage != nil, "读取失败也要有 errorMessage，否则视图无从渲染")
        #expect(model.errorOrigin == .reading)
        #expect(model.errorMessage?.contains("确认没有保存") == false,
                "两句话不许混成一句：读取失败不是确认失败")
    }

    @Test("换一张卡 / 收掉卡：上一张卡的确认失败提示不跟着串台")
    func presentingAnotherCardClearsPreviousAckError() async throws {
        let model = makeModel(risks: [risk("批量删除 A"), risk("批量删除 B")], controller: FailingController())
        await model.load()
        let first = try #require(model.events.first)
        model.requestConfirmation(for: first)
        #expect(model.confirmationTarget?.id == first.id)

        _ = await model.acknowledge(event: first)
        #expect(model.errorMessage != nil)

        let second = try #require(model.events.last)
        model.requestConfirmation(for: second)
        #expect(model.errorMessage == nil, "新卡一开张就背着别人的失败 = 第二句谎")
        #expect(model.errorOrigin == nil)
    }
}

// MARK: - ② 真渲染树：那句话确实上了屏

@Suite("Security #77 · 失败提示真的渲染出来（真无障碍树）", .timeLimit(.minutes(4)), .serialized)
@MainActor struct SecurityAckFailureRenderedTests {

    /// 列表非空 + 确认失败 ⇒ 横幅必须出现在**这一页**上。
    ///
    /// 旧写法（`errorMessage != nil && events.isEmpty`）在这一格什么都不渲染：
    /// 变异检查就是把那个条件加回去，这一条会立刻红（`A11yTree` 读不到那句）。
    @Test("列表非空时确认失败：横幅带着「确认没有保存」上屏")
    func bannerRendersWhileListIsNotEmpty() async throws {
        let model = makeModel(risks: [risk("批量删除")], controller: FailingController())
        await model.load()
        #expect(model.events.isEmpty == false, "夹具没喂进去，这一条测的就不是「列表非空」")
        _ = await model.acknowledge(event: try #require(model.events.first))
        #expect(model.errorMessage != nil)

        let texts = await A11yTree.renderedTexts(SecurityView(model: model), settle: 6)
        #expect(texts.count >= 10, "树几乎没读到东西（\(texts.count) 段），这条判据不成立")
        #expect(texts.contains { $0.contains("确认没有保存") },
                "列表非空时错误没有任何视图读它 —— #77 的原始缺陷。读到的是：\(texts)")
        // 行还在：这条横幅是「挂在列表上方」，不是顶掉列表。
        #expect(texts.contains { $0.contains("批量删除") }, "确认失败不该让行消失")
    }

    /// 同一格形状的**读取**失败：标题换成「最近一次读取失败，下面显示的是上一次成功加载的结果」。
    /// 两档标题走的是同一个 `SecurityErrorNotice`，但说的话不同 —— 这一条钉住它们不串台。
    @Test("列表非空时读取失败：横幅说的是「读失败 + 下面还是旧结果」，不是确认失败")
    func staleReadFailureBannerRenders() async throws {
        let store = InMemoryObservatoryService()
        let fixture = risk("批量删除")
        store.seed(risks: [fixture])
        let flaky = FlakyRiskReadService(store)
        let model = SecurityModel(
            runtime: ObservatoryRuntime(service: flaky, controller: store, updates: store)
        )
        await model.load()                     // 先成功读一次，让列表非空
        #expect(model.events.count == 1)
        flaky.failsRiskReads = true            // 此后每次读都抛（模拟库被关掉 / 只读）

        let texts = await A11yTree.renderedTexts(SecurityView(model: model), settle: 6)
        #expect(texts.contains { $0.contains("最近一次读取失败") },
                "非空列表上的读取失败没有读者。读到的是：\(texts)")
        #expect(texts.contains { $0.contains("上一次成功加载") })
        #expect(texts.contains { $0.contains("确认没有保存") } == false)
    }

    /// 确认卡是**模态层**：页面那一档修好了也不等于这里看得见。
    @Test("确认卡内：落库失败的原话就显示在卡里，卡不消失")
    func sheetShowsFailureInsideTheCard() async throws {
        let event = risk("批量删除")
        let model = makeModel(risks: [event], controller: FailingController())
        await model.load()
        let subject = try #require(model.events.first)
        model.requestConfirmation(for: subject)
        #expect(model.confirmationTarget?.id == subject.id, "卡没开，测的就不是卡")

        let saved = await model.acknowledge(event: subject)
        #expect(saved == false)
        // 返回值决定界面状态：失败 ⇒ 这张卡一定还在（`acknowledge` 只在落库成功时收它）。
        #expect(model.confirmationTarget?.id == subject.id)

        let texts = await A11yTree.renderedTexts(
            SecurityConfirmationSheet(model: model, event: subject), size: NSSize(width: 460, height: 900),
            minCount: 5, settle: 6
        )
        #expect(texts.contains { $0.contains("确认没有保存") },
                "卡里读不到失败原话。读到的是：\(texts)")
        #expect(texts.contains { $0.contains("我已确认") }, "失败时这张卡必须还能再点一次")
    }
}
