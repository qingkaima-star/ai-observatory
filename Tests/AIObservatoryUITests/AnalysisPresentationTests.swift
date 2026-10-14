//
//  AnalysisPresentationTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-InsightsMount（波次 4）
//  ─────────────────────────────────────────────────────────
//  分析层进入界面后最容易撒谎的那部分（纯口径 + 两个模型的数据流）：
//    1. 三种空态必须互斥且可分辨：「分析层未接入」「还没有可分析的记录」「查过了没检出」
//       ——把第一种念成第三种，等于对着没插电的表说「一切正常」。
//    2. `insufficientData` 只能渲染成「数据不足」，永不成绿色「健康」，
//       而且此时连派生数字（风险分解 / 异常数 / 单位产出）都不展示。
//    3. 不可估计的量写「不可估计」，不写 0；非有限数值写「不可计算」，不写 nan。
//    4. 卡片只留 5 条，但被裁掉几条要写在脸上。
//    5. 模型侧接线：分析层缺失时不发查询、不编结果；查询失败要单独记，
//       不能降级成「该项目没有健康度」。
//
//  没有 sleep，没有对挂钟的断言：时间全部由固定基线推出来。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

// MARK: - 夹具

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)
private let projectPath = "/Users/demo/Projects/Mona"

private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

private func finding(_ kind: AnomalyFinding.Kind, at date: Date, severity: RiskLevel = .medium) -> AnomalyFinding {
    AnomalyFinding(
        kind: kind,
        severity: severity,
        summary: "实测 40.0",
        observed: 40,
        expected: 2.8,
        detectedAt: date,
        projectPath: projectPath
    )
}

private func snapshot(
    verdict: ProjectHealthSnapshot.Verdict,
    riskCounts: AnalysisRiskCounts = .none,
    anomalyCount: Int = 0,
    efficiencyScore: Double? = nil
) -> ProjectHealthSnapshot {
    ProjectHealthSnapshot(
        projectPath: projectPath,
        riskCounts: riskCounts,
        anomalyCount: anomalyCount,
        efficiencyScore: efficiencyScore,
        verdict: verdict,
        generatedAt: epoch
    )
}

private func failedMessage(_ state: ProjectHealthState) -> String? {
    if case .failed(let message) = state { return message }
    return nil
}

// MARK: - 分析层桩

/// 真实现的分析层桩：记录被问到的参数，好让「since 有没有真的下推」可断言。
private struct StubAnalysis: ObservatoryAnalysisProviding {
    let health: ProjectHealthSnapshot?
    let findings: [AnomalyFinding]
    let shouldFail: Bool

    init(
        health: ProjectHealthSnapshot? = nil,
        findings: [AnomalyFinding] = [],
        shouldFail: Bool = false
    ) {
        self.health = health
        self.findings = findings
        self.shouldFail = shouldFail
    }

    func projectHealth(for path: String) async throws -> ProjectHealthSnapshot? {
        if shouldFail { throw ObservatoryError.storeUnavailable("分析层读不到库") }
        guard path == projectPath else { return nil }
        return health
    }

    func anomalies(since date: Date) async throws -> [AnomalyFinding] {
        if shouldFail { throw ObservatoryError.notRunning }
        return findings.filter { $0.detectedAt >= date }
    }
}

private func makeRuntime(analysis: (any ObservatoryAnalysisProviding)?) -> ObservatoryRuntime {
    let service = InMemoryObservatoryService()
    service.seed(projects: [ProjectActivity(
        id: ProjectActivity.identity(path: projectPath),
        name: "Mona",
        path: projectPath
    )])
    return ObservatoryRuntime(
        service: service,
        controller: service,
        updates: service,
        analysis: analysis
    )
}

// MARK: - 1. 三种空态

@Suite("UI: 分析层 · 空态必须可分辨", .timeLimit(.minutes(1)))
struct AnalysisEmptyStateTests {

    @Test("未接入优先于一切：没装配分析层时不许说「没有异常」")
    func notWiredWinsOverEverything() {
        #expect(AnalysisPresentation.emptyKind(analysisWired: false, hasRecords: true, hasFindings: false) == .notWired)
        #expect(AnalysisPresentation.emptyKind(analysisWired: false, hasRecords: false, hasFindings: false) == .notWired)
        #expect(AnalysisPresentation.title(for: .notWired) == "分析层未接入")
        #expect(AnalysisPresentation.message(for: .notWired).contains("没有装配"))
    }

    @Test("接入了但库里没有记录 → 「还没有可分析的记录」")
    func noRecordsIsItsOwnState() {
        #expect(AnalysisPresentation.emptyKind(analysisWired: true, hasRecords: false, hasFindings: false) == .noRecords)
        #expect(AnalysisPresentation.title(for: .noRecords) == "还没有可分析的记录")
        #expect(AnalysisPresentation.message(for: .noRecords).contains("基线"))
    }

    @Test("有记录、检不出异常 → 第三种状态，并说明「没检出 ≠ 一定没有」")
    func nothingFoundIsItsOwnState() {
        #expect(AnalysisPresentation.emptyKind(analysisWired: true, hasRecords: true, hasFindings: false) == .nothingFound)
        #expect(AnalysisPresentation.title(for: .nothingFound) == "本范围内没有检出异常")
        #expect(AnalysisPresentation.message(for: .nothingFound).contains("不等于"))
    }

    @Test("三种状态互不相同，且只有真有结论时才返回 nil")
    func theThreeStatesAreMutuallyDistinct() {
        let kinds = [
            AnalysisPresentation.emptyKind(analysisWired: false, hasRecords: true, hasFindings: false),
            AnalysisPresentation.emptyKind(analysisWired: true, hasRecords: false, hasFindings: false),
            AnalysisPresentation.emptyKind(analysisWired: true, hasRecords: true, hasFindings: false)
        ]
        #expect(Set(kinds).count == 3)
        #expect(AnalysisPresentation.emptyKind(analysisWired: true, hasRecords: true, hasFindings: true) == nil)
    }
}

// MARK: - 2. 裁剪与排序

@Suite("UI: 分析层 · 列表裁剪", .timeLimit(.minutes(1)))
struct AnalysisListTests {

    @Test("卡片上限 5 条，被裁掉的条数写在脸上")
    func limitIsFiveAndTruncationIsVisible() {
        let all = (0..<8).map { finding(.eventBurst, at: at(TimeInterval($0) * 600)) }
        let visible = AnalysisPresentation.visibleFindings(all)
        #expect(visible.count == 5)
        #expect(AnalysisPresentation.hiddenCount(all) == 3)
        #expect(AnalysisPresentation.dashboardFindingLimit == 5)
        // 展示的是最近的 5 条，而不是数组前 5 个。
        #expect(visible.first?.detectedAt == at(7 * 600))
        #expect(visible.last?.detectedAt == at(3 * 600))
        #expect(AnalysisPresentation.hiddenCount(Array(visible)) == 0)
    }

    @Test("上限为 0 时不展示任何一条，但隐藏数不为负")
    func degenerateLimitsAreClamped() {
        let all = [finding(.commandSpike, at: epoch)]
        #expect(AnalysisPresentation.visibleFindings(all, limit: 0).isEmpty)
        #expect(AnalysisPresentation.hiddenCount(all, limit: -3) == 1)
        #expect(AnalysisPresentation.visibleFindings([], limit: 5).isEmpty)
        #expect(AnalysisPresentation.hiddenCount([], limit: 5) == 0)
    }

    @Test("排序与输入顺序无关：新→旧，同一时刻按 id 定序")
    func orderingDoesNotDependOnInputOrder() {
        let early = finding(.eventBurst, at: epoch)
        let late = finding(.cpuSpike, at: at(3_600))
        let sameA = finding(.deletionSpike, at: at(1_800))
        let sameB = finding(.commandSpike, at: at(1_800))
        let forward = AnalysisPresentation.orderedFindings([early, sameA, late, sameB])
        let backward = AnalysisPresentation.orderedFindings([sameB, late, sameA, early])
        #expect(forward.map(\.id) == backward.map(\.id))
        #expect(forward.first?.detectedAt == at(3_600))
        #expect(forward.last?.detectedAt == epoch)
    }
}

// MARK: - 3. 健康度口径

@Suite("UI: 分析层 · 数据不足不是健康", .timeLimit(.minutes(1)))
struct ProjectHealthPresentationTests {

    @Test("来源状态优先级：未接入 > 查询失败 > 没有健康度 > 有结论")
    func statePrecedence() {
        #expect(AnalysisPresentation.healthState(analysisWired: false, snapshot: snapshot(verdict: .healthy)) == .notWired)
        #expect(AnalysisPresentation.healthState(
            analysisWired: true,
            snapshot: snapshot(verdict: .healthy),
            errorMessage: "读不到库"
        ) == .failed("读不到库"))
        #expect(AnalysisPresentation.healthState(analysisWired: true, snapshot: nil) == .unavailable)
        let resolved = snapshot(verdict: .watch)
        #expect(AnalysisPresentation.healthState(analysisWired: true, snapshot: resolved) == .resolved(resolved))
    }

    @Test("insufficientData 只会被念成「数据不足」，绝不会被念成「健康」")
    func insufficientDataNeverReadsAsHealthy() {
        let state = AnalysisPresentation.healthState(analysisWired: true, snapshot: snapshot(verdict: .insufficientData))
        #expect(AnalysisPresentation.healthTitle(state) == "数据不足")
        #expect(AnalysisPresentation.healthTitle(state) != "健康")
        #expect(AnalysisPresentation.verdictSymbol(state) == "tray")
    }

    @Test("四种结论各有各的图标，未接入 / 无健康度 / 失败也不会被画成「健康」")
    func verdictsAreDistinguishable() {
        let symbols = ProjectHealthSnapshot.Verdict.allCases.map {
            AnalysisPresentation.verdictSymbol(.resolved(snapshot(verdict: $0)))
        }
        #expect(Set(symbols).count == ProjectHealthSnapshot.Verdict.allCases.count)
        #expect(AnalysisPresentation.verdictSymbol(.notWired) == "questionmark.circle")
        #expect(AnalysisPresentation.verdictSymbol(.unavailable) == "tray")
        #expect(AnalysisPresentation.verdictSymbol(.failed("x")) == "exclamationmark.triangle")
        // 只有 healthy 才配得上盾牌勾；其余状态一律不能借用它的图标。
        let healthySymbol = AnalysisPresentation.verdictSymbol(.resolved(snapshot(verdict: .healthy)))
        #expect(healthySymbol == "checkmark.shield")
        for state in [ProjectHealthState.notWired, .unavailable, .failed("x"),
                      .resolved(snapshot(verdict: .insufficientData))] {
            #expect(AnalysisPresentation.verdictSymbol(state) != healthySymbol)
        }
    }

    @Test("数据不足时连派生数字都不展示：一句「数据不足」配一排数只会让人只记住数")
    func insufficientDataHidesDerivedNumbers() {
        let sparse = snapshot(verdict: .insufficientData, riskCounts: AnalysisRiskCounts(high: 2), anomalyCount: 3)
        let state = ProjectHealthState.resolved(sparse)
        #expect(!AnalysisPresentation.showsBreakdown(state))
        #expect(!AnalysisPresentation.healthDetail(state).contains("异常 3"))
        #expect(AnalysisPresentation.healthDetail(state).contains("放弃判定"))
        // 有结论时才展示数字。⚠️ 2026-09-21 全站口径之后，那三个数由**上方三格
        // `InlineStat`（`ProjectHealthCard.breakdown`）**报，detail 行不再重复一遍
        // ——所以这里断言的是「派生文案函数仍然产出那句话」+「detail 行不再出现它」。
        let judged = ProjectHealthState.resolved(snapshot(verdict: .watch, anomalyCount: 3))
        #expect(AnalysisPresentation.showsBreakdown(judged))
        #expect(AnalysisPresentation.anomalyText(3) == "3 处")
        #expect(!AnalysisPresentation.healthDetail(judged).contains("异常 3 处"),
                "detail 行又把 breakdown 报过的数说了一遍")
        #expect(!AnalysisPresentation.showsBreakdown(.notWired))
        #expect(!AnalysisPresentation.showsBreakdown(.unavailable))
        #expect(!AnalysisPresentation.showsBreakdown(.failed("x")))
    }

    @Test("口径行把「什么时候算的」带上，不让人把旧结论当新的")
    func detailCarriesTheAnalysisTime() {
        let detail = AnalysisPresentation.healthDetail(.resolved(snapshot(verdict: .healthy)))
        #expect(detail.contains("分析于 "))
        #expect(detail.contains(DateFormat.timestamp(epoch)))
        // 有结论时这一整行**只有**时间：三个数在 breakdown 三格里，一行之内说两遍
        // 就是全站口径点名要收的那类复述。
        #expect(detail == "分析于 \(DateFormat.timestamp(epoch))")
        #expect(!AnalysisPresentation.healthDetail(.resolved(snapshot(verdict: .atRisk)))
            .contains("风险 0"), "detail 行又回去复述风险分解了")
    }
}

// MARK: - 4. 数字文案

@Suite("UI: 分析层 · 数字不许撒谎", .timeLimit(.minutes(1)))
struct AnalysisNumberTests {

    @Test("不可估计写成「不可估计」，不是 0")
    func nilIsNotZero() {
        #expect(AnalysisPresentation.efficiencyText(nil) == "不可估计")
        #expect(AnalysisPresentation.efficiencyText(0) == "0.00 文件/活跃秒")
        #expect(AnalysisPresentation.riskBreakdownText(.none) == "0 起")
        #expect(AnalysisPresentation.anomalyText(0) == "0 处")
    }

    @Test("风险分解带等级明细，全零时不假装「无事发生」以外的话")
    func riskBreakdownShowsLevels() {
        let counts = AnalysisRiskCounts(critical: 1, high: 2, medium: 3, low: 4)
        #expect(AnalysisPresentation.riskBreakdownText(counts) == "10（严重 1 · 高 2 · 中 3 · 低 4）")
        #expect(AnalysisPresentation.riskBreakdownText(AnalysisRiskCounts(low: 5)) == "5（低 5）")
        #expect(AnalysisPresentation.riskBreakdownText(AnalysisRiskCounts(medium: 2, low: 1)).contains("严重") == false)
    }

    @Test("极小的非零产出不被印成 0.00，非有限值不落到文案里")
    func tinyAndInvalidNumbersStayReadable() {
        #expect(AnalysisPresentation.compactNumber(0.00042) == "0.0004")
        #expect(AnalysisPresentation.compactNumber(0) == "0.00")
        #expect(AnalysisPresentation.compactNumber(12.3456) == "12.35")
        #expect(AnalysisPresentation.compactNumber(.nan) == "不可计算")
        #expect(AnalysisPresentation.efficiencyText(.nan) == "不可计算 文件/活跃秒")
    }

    @Test("异常行同时给出实测、基线与观测口径")
    func findingRowKeepsBothNumbers() {
        let text = AnalysisPresentation.observedExpectedText(finding(.deletionSpike, at: epoch))
        #expect(text.contains("实测 40.00"))
        #expect(text.contains("基线 2.80"))
        #expect(text.contains("删除行数"))
    }
}

// MARK: - 5. Dashboard 数据流

@MainActor
@Suite("UI: 分析层 · Dashboard 数据流", .timeLimit(.minutes(1)))
struct DashboardAnalysisTests {

    @Test("未接入分析层：不发查询、不编结果，只报告「未接入」")
    func missingAnalysisLayerIsReportedNotFaked() async {
        let model = DashboardModel(runtime: makeRuntime(analysis: nil))
        #expect(!model.analysisWired)
        await model.loadAnomalies(now: epoch)
        #expect(model.anomalies.isEmpty)
        #expect(model.anomalyWindowStart == nil)
        #expect(model.anomalyErrorMessage == nil)
        #expect(!model.isLoadingAnomalies)
    }

    @Test("接入后：结论落到模型里，起点按注入的时刻算，不读墙钟")
    func findingsFlowIntoTheCard() async {
        let findings = [
            finding(.eventBurst, at: at(6 * 3_600), severity: .high),
            finding(.commandSpike, at: at(2 * 3_600))
        ]
        let model = DashboardModel(runtime: makeRuntime(analysis: StubAnalysis(findings: findings)))
        model.queryRange = DateRangeFilter(start: at(3 * 3_600), end: epoch)
        await model.loadAnomalies(now: epoch)
        #expect(model.analysisWired)
        // 起点来自范围本身，扫描真的把 since 下推了：早于起点的那条不该回来。
        #expect(model.anomalyWindowStart == at(3 * 3_600))
        #expect(model.anomalies.map(\.kind) == [.eventBurst])
    }

    @Test("范围没有起点（「全部」）时回看 24 小时，并把口径留在模型里给卡片写")
    func openEndedRangeFallsBackToAFiniteWindow() async {
        let model = DashboardModel(runtime: makeRuntime(analysis: StubAnalysis()))
        model.queryRange = .unbounded
        await model.loadAnomalies(now: epoch)
        #expect(model.anomalyWindowStart == epoch.addingTimeInterval(-DashboardModel.defaultAnomalyWindowSeconds))
        #expect(DashboardModel.defaultAnomalyWindowSeconds == 24 * 3_600)
    }

    @Test("扫描失败不清空上一轮，但会把「这一轮没成功」说清楚")
    func failureKeepsLastResultsAndSaysSo() async {
        let wired = StubAnalysis(findings: [finding(.eventBurst, at: epoch)])
        let model = DashboardModel(runtime: makeRuntime(analysis: wired))
        await model.loadAnomalies(now: epoch)
        #expect(model.anomalies.count == 1)

        let broken = DashboardModel(runtime: makeRuntime(analysis: StubAnalysis(shouldFail: true)))
        await broken.loadAnomalies(now: epoch)
        #expect(broken.anomalies.isEmpty)
        #expect(broken.anomalyErrorMessage?.contains("观测引擎未运行") == true)
        #expect(!broken.isLoadingAnomalies)
    }
}

// MARK: - 6. Projects 数据流

@MainActor
@Suite("UI: 分析层 · 项目健康度数据流", .timeLimit(.minutes(1)))
struct ProjectHealthModelTests {

    @Test("选中项目即拉健康度；没选中之前不显示任何结论")
    func healthFollowsSelection() async {
        let model = ProjectsModel(runtime: makeRuntime(analysis: StubAnalysis(health: snapshot(verdict: .watch))))
        #expect(model.analysisWired)
        #expect(model.health == nil)
        // 还没选中项目 → 状态是「暂无健康度」，不是「数据不足」。
        #expect(model.healthState == .unavailable)
        await model.select(path: projectPath)
        #expect(model.health?.verdict == .watch)
        #expect(model.healthState == .resolved(snapshot(verdict: .watch)))
    }

    @Test("宿主没装配分析层：状态是「未接入」，与「该项目没有健康度」严格分开")
    func notWiredIsNotTheSameAsNoData() async {
        let model = ProjectsModel(runtime: makeRuntime(analysis: nil))
        await model.select(path: projectPath)
        #expect(!model.analysisWired)
        #expect(model.health == nil)
        #expect(model.healthState == .notWired)
        #expect(AnalysisPresentation.healthTitle(model.healthState) == "分析层未接入")
    }

    @Test("分析层不认识这个项目 → unavailable；查询失败 → failed，两者不混用")
    func unavailableAndFailureAreDifferentStates() async {
        let unknown = ProjectsModel(runtime: makeRuntime(analysis: StubAnalysis(health: nil)))
        await unknown.select(path: projectPath)
        #expect(unknown.healthState == .unavailable)
        #expect(unknown.healthErrorMessage == nil)

        let broken = ProjectsModel(runtime: makeRuntime(analysis: StubAnalysis(shouldFail: true)))
        await broken.select(path: projectPath)
        #expect(failedMessage(broken.healthState)?.contains("分析层读不到库") == true)
        #expect(broken.health == nil)
    }

    @Test("取消选中即作废上一轮结论，不把旧项目的健康度留给新项目")
    func clearingSelectionDropsStaleHealth() async {
        let model = ProjectsModel(runtime: makeRuntime(analysis: StubAnalysis(health: snapshot(verdict: .healthy))))
        await model.select(path: projectPath)
        #expect(model.health != nil)
        model.clearSelection()
        #expect(model.health == nil)
        #expect(model.healthState == .unavailable)
    }
}
