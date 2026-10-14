//
//  AnalysisProviderTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-InsightsMount（波次 4）
//  ─────────────────────────────────────────────────────────
//  ObservatoryAnalysisProvider = Insights 分析层进入生产路径的唯一入口。
//  这里守的是四条最容易「悄悄撒谎」的行为：
//    1. 观测条数不足时结论必须是 insufficientData，而不是 healthy（把「没查」念成「查过没事」
//       是可信审计最不能犯的错）；
//    2. 注入一个尖峰 ⇒ 恰好一条 eventBurst。不多不少：既不能漏报，也不能把零值桶报成异常；
//    3. 同一份输入两次调用，快照与结论的 id 必须逐个相同（StableID，见 c94d48a）；
//    4. `since` 是真的下推：把起点推到尖峰之后，那条尖峰就不该再出现。
//  外加纯函数口径：σ→严重度换算表、桶宽上限闸、归属混判（混杂时宁可留 nil）。
//
//  确定性：分析终点由 `referenceDate` 注入，时间戳全是 timeIntervalSince1970 常量。
//  没有 sleep，没有对挂钟的断言。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 固定时间与夹具

private let epoch = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ offset: TimeInterval) -> Date { epoch.addingTimeInterval(offset) }

/// 分析终点：epoch + 16 小时。整点倍数，保证 1 小时桶刚好铺满 16 个。
private let horizon = at(16 * 3600)

private let projectA = "/Users/observer/Projects/Alpha"
private let projectB = "/Users/observer/Projects/Beta"

private func event(
    _ date: Date,
    project: String?,
    session: UUID? = nil,
    kind: OperationKind = .fileModified
) -> TimelineEvent {
    TimelineEvent(timestamp: date, sessionID: session, agentKind: .claudeCode, kind: kind,
                  title: "event", projectPath: project)
}

private func projectRow(_ path: String) -> ProjectActivity {
    ProjectActivity(id: ProjectActivity.identity(path: path),
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    firstSeenAt: epoch,
                    lastSeenAt: horizon)
}

private func provider(for service: InMemoryObservatoryService) -> ObservatoryAnalysisProvider {
    ObservatoryAnalysisProvider(service: service, referenceDate: { horizon })
}

// MARK: - 1. 数据不足 ≠ 健康

@Suite("Engine: 分析层 · 数据不足不判健康", .timeLimit(.minutes(1)))
struct AnalysisInsufficientDataTests {

    @Test("项目只有 3 条事件：结论是 insufficientData，不是 healthy")
    func tooFewObservationsIsInsufficient() async throws {
        let service = InMemoryObservatoryService()
        service.seed(
            events: [
                event(at(3_000), project: projectA),
                event(at(3_600), project: projectA),
                event(at(4_200), project: projectA)
            ],
            projects: [projectRow(projectA)]
        )
        let snapshot = try await provider(for: service).projectHealth(for: projectA)
        #expect(snapshot?.verdict == .insufficientData)
        #expect(snapshot?.verdict.displayName == "数据不足")
        // 数据不足时也不许凭空长出结论数字。
        #expect(snapshot?.riskCounts.total == 0)
        #expect(snapshot?.efficiencyScore == nil)
    }

    @Test("活动地图里没有这个项目：返回 nil，而不是一个 insufficientData 的壳")
    func unknownProjectIsNil() async throws {
        let service = InMemoryObservatoryService()
        service.seed(events: [event(at(3_000), project: projectA)], projects: [projectRow(projectA)])
        let provider = provider(for: service)
        #expect(try await provider.projectHealth(for: "/Users/observer/Projects/Gamma") == nil)
        #expect(try await provider.projectHealth(for: "") == nil)
    }

    @Test("门槛值本身可注入：门槛调到 2 时同一份数据就能出结论")
    func thresholdIsPolicyControlled() async throws {
        let service = InMemoryObservatoryService()
        service.seed(
            events: (0..<3).map { event(at(3_000 + Double($0) * 600), project: projectA) },
            projects: [projectRow(projectA)]
        )
        let lenient = ObservatoryAnalysisProvider(
            service: service,
            policy: .init(minimumObservations: 2),
            referenceDate: { horizon }
        )
        let snapshot = try await lenient.projectHealth(for: projectA)
        #expect(snapshot?.verdict != .insufficientData)
    }
}

// MARK: - 2. 注入尖峰 ⇒ 恰好一条 eventBurst

@Suite("Engine: 分析层 · 尖峰检出", .timeLimit(.minutes(1)))
struct AnalysisBurstTests {

    /// 16 个小时桶：0..3 各 1 条事件，12 号桶 40 条，其余为空。
    /// 均值 2.75、总体标准差 9.63 ⇒ 尖峰 z ≈ 3.87σ（≥3σ 判异常，<4σ 只到 MEDIUM），
    /// 其余桶 |z| < 0.3 全都不该被报出来。
    private static func seededService(session: UUID) -> InMemoryObservatoryService {
        let service = InMemoryObservatoryService()
        var events: [TimelineEvent] = (0..<4).map { index in
            event(at(Double(index) * 3_600 + 60), project: projectB, session: UUID())
        }
        events.append(contentsOf: (0..<40).map { index in
            event(at(12 * 3_600 + 60 + Double(index)), project: projectA, session: session)
        })
        service.seed(events: events, projects: [projectRow(projectA)])
        return service
    }

    @Test("一个尖峰恰好产出一条 eventBurst，数字来自分析器而不是补出来的")
    func burstYieldsExactlyOneFinding() async throws {
        let session = UUID()
        let findings = try await provider(for: Self.seededService(session: session))
            .anomalies(since: epoch)
        #expect(findings.count == 1)
        guard let finding = findings.first else { return }
        #expect(finding.kind == .eventBurst)
        #expect(finding.severity == .medium)
        #expect(finding.observed == 40)
        #expect(Swift.abs(finding.expected - 2.75) < 0.01)
        #expect(finding.detectedAt == at(12 * 3_600))
        // 归属：尖峰桶里 40 条事件同属一个项目 / 一个会话，才敢把结论挂上去。
        #expect(finding.projectPath == projectA)
        #expect(finding.sessionID == session)
        // 文案里的数字必须是真实观测值与基线，不出现「大约」「可能」这类含糊话。
        #expect(finding.summary.contains("40.0"))
        #expect(finding.summary.contains("2.8") || finding.summary.contains("2.7"))
        #expect(finding.summary.contains("3.9σ") || finding.summary.contains("3.8σ"))
    }

    @Test("同一批记录归属到两个项目时，异常不指名道姓地赖给其中一个")
    func mixedAttributionStaysUnattributed() async throws {
        let service = InMemoryObservatoryService()
        var events: [TimelineEvent] = (0..<4).map { index in
            event(at(Double(index) * 3_600 + 60), project: projectB)
        }
        events.append(contentsOf: (0..<40).map { index in
            event(at(12 * 3_600 + 60 + Double(index)),
                  project: index.isMultiple(of: 2) ? projectA : projectB)
        })
        service.seed(events: events, projects: [projectRow(projectA), projectRow(projectB)])
        let findings = try await provider(for: service).anomalies(since: epoch)
        #expect(findings.count == 1)
        #expect(findings.first?.projectPath == nil)
        #expect(findings.first?.sessionID == nil)
    }

    @Test("恒定序列不报异常：全零基线不是「一切正常」的证据，分析器主动放弃判定")
    func flatSeriesProducesNothing() async throws {
        let service = InMemoryObservatoryService()
        service.seed(
            events: (0..<16).map { event(at(Double($0) * 3_600 + 60), project: projectA) },
            projects: [projectRow(projectA)]
        )
        #expect(try await provider(for: service).anomalies(since: epoch).isEmpty)
    }

    @Test("空库扫描：没有任何可建立基线的样本，返回空而不是编一个尖峰")
    func emptyStoreYieldsNoFindings() async throws {
        #expect(try await provider(for: InMemoryObservatoryService()).anomalies(since: epoch).isEmpty)
    }
}

// MARK: - 3. 稳定身份 + 4. since 过滤

@Suite("Engine: 分析层 · 稳定身份与时间过滤", .timeLimit(.minutes(1)))
struct AnalysisStabilityTests {

    @Test("同一份输入两次调用：结论数组逐个相等，id 也相等（c94d48a 的教训）")
    func findingsAreStableAcrossCalls() async throws {
        let service = InMemoryObservatoryService()
        var events: [TimelineEvent] = (0..<4).map { event(at(Double($0) * 3_600 + 60), project: projectB) }
        events.append(contentsOf: (0..<40).map { event(at(12 * 3_600 + 60 + Double($0)), project: projectA) })
        service.seed(events: events, projects: [projectRow(projectA)])
        let provider = provider(for: service)

        let first = try await provider.anomalies(since: epoch)
        let second = try await provider.anomalies(since: epoch)
        #expect(first == second)
        #expect(first.map(\.id) == second.map(\.id))
        #expect(first.first?.id == StableID.uuid(
            namespace: "anomalyfinding",
            key: "eventBurst|\(Int(at(12 * 3_600).timeIntervalSince1970))|\(projectA)"
        ))
    }

    @Test("健康度快照 id 由项目路径推出，重算两次完全相等")
    func healthSnapshotIsStable() async throws {
        let service = InMemoryObservatoryService()
        service.seed(
            events: (0..<10).map { event(at(Double($0) * 600), project: projectA) },
            projects: [projectRow(projectA)]
        )
        let provider = provider(for: service)
        let first = try await provider.projectHealth(for: projectA)
        let second = try await provider.projectHealth(for: projectA)
        #expect(first == second)
        #expect(first?.id == StableID.uuid(namespace: "projecthealth", key: projectA))
        #expect(first?.projectPath == projectA)
        #expect(first?.generatedAt == horizon)
    }

    @Test("since 是真的下推：起点越过尖峰后那条结论就不再出现")
    func sinceTruncatesTheScan() async throws {
        let service = InMemoryObservatoryService()
        var events: [TimelineEvent] = (0..<4).map { event(at(Double($0) * 3_600 + 60), project: projectB) }
        events.append(contentsOf: (0..<40).map { event(at(12 * 3_600 + 60 + Double($0)), project: projectA) })
        service.seed(events: events, projects: [projectRow(projectA)])
        let provider = provider(for: service)

        let wide = try await provider.anomalies(since: epoch)
        #expect(wide.count == 1)
        let narrow = try await provider.anomalies(since: at(13 * 3_600))
        #expect(narrow.isEmpty)

        // 起点落在尖峰之前 4 小时（仍有 12 个桶，样本量够）时仍能检出，且每条结论都不早于起点。
        let mid = try await provider.anomalies(since: at(4 * 3_600))
        #expect(mid.contains { $0.kind == .eventBurst })
        #expect(mid.allSatisfy { $0.detectedAt >= at(4 * 3_600) })
    }

    @Test("非法窗口（起点在未来 / 与现在重合）不做任何判定")
    func invalidWindowIsNotJudged() async throws {
        let provider = provider(for: InMemoryObservatoryService())
        #expect(try await provider.anomalies(since: horizon).isEmpty)
        #expect(try await provider.anomalies(since: at(999 * 3_600)).isEmpty)
    }
}

// MARK: - 5. 换算口径（纯函数）

@Suite("Engine: 分析层 · 换算口径", .timeLimit(.minutes(1)))
struct AnalysisConversionTests {

    @Test("σ 倍数只负责翻译已有的判定：刚过 3σ 线是 MEDIUM，不是 HIGH")
    func severityTracksSigma() {
        #expect(ObservatoryAnalysisProvider.severity(zScore: 3.0) == .medium)
        #expect(ObservatoryAnalysisProvider.severity(zScore: -3.9) == .medium)
        #expect(ObservatoryAnalysisProvider.severity(zScore: 4.0) == .high)
        #expect(ObservatoryAnalysisProvider.severity(zScore: -4.9) == .high)
        #expect(ObservatoryAnalysisProvider.severity(zScore: 5.0) == .critical)
    }

    @Test("桶宽有上限闸：「全部时间」不会被切成几十万个小时桶")
    func bucketWidthIsCapped() {
        let policy = ObservatoryAnalysisProvider.Policy.standard
        // 默认 1 小时桶，240 个桶封顶 ⇒ 10 天以内的窗口仍按小时分。
        #expect(ObservatoryAnalysisProvider.bucketSeconds(windowSeconds: 10 * 3_600, policy: policy) == 3_600)
        // 100 天 ⇒ 被抬到约 1 天一个桶，桶数不再爆炸。
        let wide = ObservatoryAnalysisProvider.bucketSeconds(windowSeconds: 100 * 24 * 3_600, policy: policy)
        #expect(wide >= 100 * 24 * 3_600 / Double(policy.maxBuckets))
        #expect(100 * 24 * 3_600 / wide <= Double(policy.maxBuckets))
        // 非法窗口退回默认桶宽，不返回 0（除零会污染整条分桶链）。
        #expect(ObservatoryAnalysisProvider.bucketSeconds(windowSeconds: 0, policy: policy) >= 1)
        #expect(ObservatoryAnalysisProvider.bucketSeconds(windowSeconds: .nan, policy: policy) >= 1)
    }

    @Test("归属混判宁可留 nil：把多数派说成归属就是伪造")
    func singleValueOnlyWhenUnanimous() {
        #expect(ObservatoryAnalysisProvider.singleValue([nil, nil] as [String?]) == nil)
        #expect(ObservatoryAnalysisProvider.singleValue([String?]()) == nil)
        #expect(ObservatoryAnalysisProvider.singleValue(["a", "a"]) == "a")
        #expect(ObservatoryAnalysisProvider.singleValue(["a", "b"]) == nil)
        #expect(ObservatoryAnalysisProvider.singleValue(["a", nil]) == nil)
        let session = UUID()
        #expect(ObservatoryAnalysisProvider.singleValue([session, session]) == session)
        #expect(ObservatoryAnalysisProvider.singleValue([UUID?]()) == nil)
    }

    @Test("非有限数值写成「不可计算」，绝不落进文案变成 nan")
    func numbersStayHonest() {
        #expect(ObservatoryAnalysisProvider.number(2.75) == "2.8")
        #expect(ObservatoryAnalysisProvider.number(.nan) == "不可计算")
        #expect(ObservatoryAnalysisProvider.number(.infinity) == "不可计算")
    }

    @Test("分桶反查与 Insights 同规则：桶起点内第一条记录落在该桶，起点之前夹到首桶")
    func bucketIndexMatchesDetector() {
        let buckets = AnomalyBuckets(start: epoch, bucketSeconds: 3_600)
        #expect(buckets.index(of: epoch) == 0)
        #expect(buckets.index(of: at(3_599)) == 0)
        #expect(buckets.index(of: at(3_600)) == 1)
        #expect(buckets.index(of: at(12 * 3_600 + 99)) == 12)
        #expect(buckets.index(of: at(-1)) == 0)   // 起点之前的记录夹到首桶，与 Insights 的边界夹取同向
    }

    @Test("结论按检出时间降序，同一时刻按 id 定序（两次刷新行序不抖）")
    func orderingIsDeterministic() {
        let findings = [
            AnomalyFinding(kind: .eventBurst, severity: .medium, summary: "s", observed: 40,
                           expected: 2.75, detectedAt: at(3_600)),
            AnomalyFinding(kind: .commandSpike, severity: .high, summary: "s", observed: 9,
                           expected: 1.0, detectedAt: at(7_200)),
            AnomalyFinding(kind: .deletionSpike, severity: .critical, summary: "s", observed: 900,
                           expected: 3.0, detectedAt: at(3_600))
        ]
        let ordered = ObservatoryAnalysisProvider.ordered(findings)
        #expect(ordered.first?.detectedAt == at(7_200))
        #expect(ordered.last?.detectedAt == at(3_600))
        #expect(ObservatoryAnalysisProvider.ordered(findings.reversed()).map(\.id) == ordered.map(\.id))
    }
}

// MARK: - 6. 风险计数换算

@Suite("Engine: 分析层 · 风险计数落到 Core", .timeLimit(.minutes(1)))
struct AnalysisRiskMappingTests {

    @Test("HIGH 风险事件按文件路径归属到项目，并把结论推成 atRisk")
    func highRiskFlipsVerdict() async throws {
        let service = InMemoryObservatoryService()
        service.seed(
            events: (0..<10).map { event(at(Double($0) * 600), project: projectA) },
            risks: [RiskEvent(
                timestamp: at(600),
                level: .high,
                category: .massDeletion,
                title: "批量删除",
                filePaths: ["\(projectA)/Sources/App.swift"]
            )],
            projects: [projectRow(projectA)]
        )
        let snapshot = try await provider(for: service).projectHealth(for: projectA)
        #expect(snapshot?.riskCounts.high == 1)
        #expect(snapshot?.riskCounts.attentionCount == 1)
        #expect(snapshot?.verdict == .atRisk)
    }

    @Test("别的项目的风险不算到本项目头上；统计偏差不单独升格成风险")
    func risksAreScopedByPath() async throws {
        let service = InMemoryObservatoryService()
        service.seed(
            events: (0..<10).map { event(at(Double($0) * 600), project: projectA) },
            risks: [RiskEvent(
                timestamp: at(600),
                level: .critical,
                category: .dangerousCommand,
                title: "危险命令",
                filePaths: ["/Users/observer/Projects/Other/Secrets.env"]
            )],
            projects: [projectRow(projectA)]
        )
        let snapshot = try await provider(for: service).projectHealth(for: projectA)
        #expect(snapshot?.riskCounts == AnalysisRiskCounts())
        // 这条稀疏序列确实会被 z-score 判成偏离（anomalyCount > 0），
        // 但没有风险事件背书，结论最多到 watch——把统计偏离念成「有风险」是伪造结论。
        #expect(snapshot?.verdict == .watch)
    }
}
