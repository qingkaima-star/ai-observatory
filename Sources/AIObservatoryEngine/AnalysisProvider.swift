//
//  AnalysisProvider.swift
//  AIObservatoryEngine
//
//  Owner: WS-InsightsMount（波次 4）
//  ─────────────────────────────────────────────────────────
//  把 `AIObservatoryInsights` 的四个分析器挂进生产路径，输出 **Core 值类型**。
//
//  为什么要这么一层薄壳：UI 只依赖 Core（并行开发的前提），分析器住在 Insights，
//  所以结论必须在 Engine 换算成 `ProjectHealthSnapshot` / `AnomalyFinding` 再交给界面。
//  本文件**不做任何统计**：桶宽、z 值、基线、置信度全部来自 Insights，
//  这里只负责取数、换算与「拿不到就不判定」。
//
//  取数一律走 `any ObservatoryService`（Store 与 Engine 都已实现），不重写 SQL。
//  三条诚实约定：
//    1. 分析窗口终点用注入的 `referenceDate`，不读墙钟——同一份库同一时刻重算必然同结果；
//    2. 拿不到的输入不补数：整机 CPU 采样没有项目维度，项目健康度就一个 cpuSpike 都不算；
//       `efficiencyScore` 没有任何可比 Agent 时为 `nil`，界面显示「不可估计」；
//    3. 观测条数不足门槛（默认 8 条，与 Insights 的 `minimumSampleSize` /
//       `minimumCountForMedium` 同一量级）时结论是 `insufficientData`，不是 `healthy`。
//

import Foundation
import AIObservatoryCore
import AIObservatoryInsights

/// 分析层执行者：查询 → Insights 分析器 → Core 值类型。
public final class ObservatoryAnalysisProvider: ObservatoryAnalysisProviding, Sendable {

    // MARK: - Policy

    /// 分析口径（纯值，全部可注入，便于测试与后续调参）。
    public struct Policy: Sendable, Hashable {
        /// 项目健康度的回溯窗口（秒）。默认 7 天。
        public var healthWindowSeconds: Double
        /// 期望的时间桶宽（秒）。默认 1 小时。
        ///
        /// 实际桶宽会按窗口长度放大到 `窗口 / maxBuckets`，避免「全部时间」这种
        /// 起点在 1970 年的范围按小时分桶算出几十万个空桶。
        public var bucketSeconds: Double
        /// 单次分析允许的最大桶数（内存与耗时的硬闸）。
        public var maxBuckets: Int
        /// 每类观测的单次拉取上限。与 `ObservatoryEngine.syncProjectsIfNeeded` 同口径（2_000）。
        public var fetchLimit: Int
        /// 判定 `insufficientData` 的观测条数门槛（文件改动 + 事件 + 命令 + 会话之和）。
        public var minimumObservations: Int

        public init(
            healthWindowSeconds: Double = 7 * 24 * 3600,
            bucketSeconds: Double = 3600,
            maxBuckets: Int = 240,
            fetchLimit: Int = 2_000,
            minimumObservations: Int = 8
        ) {
            self.healthWindowSeconds = healthWindowSeconds
            self.bucketSeconds = bucketSeconds
            self.maxBuckets = maxBuckets
            self.fetchLimit = fetchLimit
            self.minimumObservations = minimumObservations
        }

        public static let standard = Policy()
    }

    // MARK: - State

    private let service: any ObservatoryService
    private let policy: Policy
    /// 分析窗口的终点（「现在」）。测试注入固定时刻，生产走 `Date()`。
    private let referenceDate: @Sendable () -> Date
    /// 路径 → 项目名。只用它的纯字符串口径，不触发任何磁盘探测。
    private let mapper = ProjectMapper()

    // MARK: - Init

    public init(
        service: any ObservatoryService,
        policy: Policy = .standard,
        referenceDate: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.service = service
        self.policy = policy
        self.referenceDate = referenceDate
    }

    // MARK: - ObservatoryAnalysisProviding

    /// 单个项目的健康度。
    ///
    /// - Returns: 活动地图里没有这个项目行时返回 `nil`（「不认识这个项目」），
    ///   与「认识但观测太少」（`verdict == .insufficientData`）严格区分。
    public func projectHealth(for path: String) async throws -> ProjectHealthSnapshot? {
        guard !path.isEmpty else { return nil }
        let now = referenceDate()
        let healthStart = now.addingTimeInterval(-policy.healthWindowSeconds)
        guard healthStart < now else { return nil }
        // 项目是否存在以引擎自己维护的活动地图为准，不另开一条判定路径。
        guard let row = try await service.projectActivity(
            path: path, dateRange: DateRangeFilter(start: healthStart, end: now)
        ) else { return nil }

        // 分析窗口 = 「健康度回溯窗口」∩「这个项目自己真正有活动的那段跨度」。
        //
        // 收窄而不是固定按回溯全长分桶，是因为一条近乎全零的小时序列会把 z-score 变成噪音：
        // 一个只在某一个小时动过 10 次的项目，其余 160 多个空桶会把均值压到 0.06，
        // 于是「6 次」就是 10σ——统计上没错，语义上是把「你恰好干了活」报成异常。
        // 收窄之后仍由 Insights 自己的 `minimumSampleSize` 决定「够不够判」。
        let windowStart = Swift.max(healthStart, row.firstSeenAt)
        let windowEnd = Swift.max(windowStart, Swift.min(now, row.lastSeenAt))
        let bucketSeconds = Self.bucketSeconds(windowSeconds: windowEnd.timeIntervalSince(windowStart), policy: policy)

        let range = DateRangeFilter(start: windowStart, end: windowEnd)
        let changes = try await service.fileChanges(
            matching: FileChangeQuery(dateRange: range, projectPath: path, limit: policy.fetchLimit)
        ).items
        let events = try await service.events(
            matching: EventQuery(dateRange: range, projectPath: path, limit: policy.fetchLimit)
        ).items
        let sessions = try await service.sessions(
            matching: SessionQuery(dateRange: range, projectPath: path, limit: policy.fetchLimit)
        ).items
        // `CommandQuery` / `RiskQuery` 都没有 projectPath 谓词（契约冻结），因此沿用引擎既有做法：
        // 拉回窗口内的记录，再按记录上已填好的 projectPath / filePaths 归属到本项目
        // ——与 `syncProjectsIfNeeded` 喂给 ProjectMapper 的口径一致，不新写 SQL。
        let commands = try await service.commands(
            matching: CommandQuery(dateRange: range, limit: policy.fetchLimit)
        ).items.filter { $0.projectPath == path }
        let risks = try await service.riskEvents(
            matching: RiskQuery(dateRange: range, limit: policy.fetchLimit)
        ).items.filter { risk in
            risk.filePaths.contains { PathHeuristics.isDescendant($0, of: [path]) }
        }

        let summary = ProjectHealthAnalyzer.summarize(
            projectName: mapper.name(forProjectPath: path),
            projectPath: path,
            changes: changes,
            commands: commands,
            events: events,
            // 整机性能采样（`SystemPerformanceSample`）既不带 projectPath 也不带 sessionID，
            // 无法归属到某个项目：传空数组让 `detectCPU` 走「无数据」短路，
            // 而不是把整机负载算成这个项目的 CPU 异常。
            systemSamples: [],
            sessions: sessions,
            riskEvents: risks,
            windowStart: windowStart,
            windowEnd: windowEnd,
            referenceDate: now,
            bucketSeconds: bucketSeconds
        )

        let counts = AnalysisRiskCounts(
            critical: summary.riskCounts.critical,
            high: summary.riskCounts.high,
            medium: summary.riskCounts.medium,
            low: summary.riskCounts.low
        )
        let anomalyCount = summary.anomalies.reduce(0) { $0 + $1.anomalousObservations.count }
        return ProjectHealthSnapshot(
            projectPath: path,
            riskCounts: counts,
            anomalyCount: anomalyCount,
            efficiencyScore: Self.efficiencyScore(from: summary.efficiency),
            verdict: Self.verdict(
                observationCount: changes.count + events.count + commands.count + sessions.count,
                riskCounts: counts,
                anomalyCount: anomalyCount,
                confidence: summary.confidence,
                policy: policy
            ),
            generatedAt: now
        )
    }

    /// 全库异常扫描：四类指标各自跑一遍 z-score，只保留「突增」方向的桶。
    public func anomalies(since date: Date) async throws -> [AnomalyFinding] {
        let now = referenceDate()
        let span = now.timeIntervalSince(date)
        guard span > 0 else { return [] }   // 起点在未来或与现在重合：分桶无定义，不做任何判定

        let bucketSeconds = Self.bucketSeconds(windowSeconds: span, policy: policy)
        let range = DateRangeFilter(start: date, end: now)
        let events = try await service.events(
            matching: EventQuery(dateRange: range, limit: policy.fetchLimit)
        ).items
        let changes = try await service.fileChanges(
            matching: FileChangeQuery(dateRange: range, limit: policy.fetchLimit)
        ).items
        let commands = try await service.commands(
            matching: CommandQuery(dateRange: range, limit: policy.fetchLimit)
        ).items
        let samples = try await service.systemPerformance(since: date)

        // 分桶归属与 Insights 完全同步（同一起点、同一桶宽），保证「异常落在第几个桶」
        // 与「这个桶里的记录属于哪个项目」说的是同一件事。
        let buckets = AnomalyBuckets(start: date, bucketSeconds: bucketSeconds)
        let reports: [(report: AnomalyReport, sources: [BucketedRecord])] = [
            (
                AnomalyDetector.detectEventRates(
                    events: events, windowStart: date, windowEnd: now, bucketSeconds: bucketSeconds
                ),
                events.map { BucketedRecord(date: $0.timestamp, projectPath: $0.projectPath, sessionID: $0.sessionID) }
            ),
            (
                AnomalyDetector.detectDeletions(
                    changes: changes, windowStart: date, windowEnd: now, bucketSeconds: bucketSeconds
                ),
                changes.map { BucketedRecord(date: $0.timestamp, projectPath: $0.projectPath, sessionID: $0.sessionID) }
            ),
            (
                AnomalyDetector.detectCommands(
                    commands: commands, windowStart: date, windowEnd: now, bucketSeconds: bucketSeconds
                ),
                commands.map { BucketedRecord(date: $0.startedAt, projectPath: $0.projectPath, sessionID: $0.sessionID) }
            ),
            // 整机 CPU：样本本身不带归属，结论的 projectPath / sessionID 就留 nil（不猜）。
            (AnomalyDetector.detectCPU(samples: samples), [])
        ]

        var findings: [AnomalyFinding] = []
        findings.reserveCapacity(reports.count)
        for entry in reports {
            for observation in entry.report.anomalousObservations {
                guard let finding = Self.finding(
                    for: observation,
                    report: entry.report,
                    buckets: buckets,
                    sources: entry.sources,
                    bucketSeconds: bucketSeconds
                ) else { continue }
                findings.append(finding)
            }
        }
        return Self.ordered(findings)
    }

    // MARK: - 换算

    /// 实际桶宽：不小于 `policy.bucketSeconds`，且保证总桶数不超过 `maxBuckets`。
    ///
    /// 「全部时间」这类范围若坚持小时桶，会算出几十万空桶——z-score 会被一堵零桶墙
    /// 拉平（标准差虚高），既费内存又判不出真异常。
    static func bucketSeconds(windowSeconds: Double, policy: Policy) -> Double {
        guard windowSeconds.isFinite, windowSeconds > 0, policy.maxBuckets > 0 else {
            return max(policy.bucketSeconds, 1)
        }
        let widest = windowSeconds / Double(policy.maxBuckets)
        return max(policy.bucketSeconds, widest).rounded(.up)
    }

    /// 健康判定。规则简单到可以在界面上逐条解释，且不引入任何新的统计量。
    ///
    /// 关键取舍：**异常检出不单独构成 `atRisk`**。z-score 说的是「这段时间偏离了你自己的
    /// 基线」，一次正常的集中改动同样能触发它；把统计偏离直接念成风险，就是自己造了个
    /// 没有依据的结论。所以异常只能把项目推到 `watch`（值得看一眼），`atRisk` 必须有
    /// 风险事件（HIGH / CRITICAL）背书——那是风险规则库逐条命中出来的、有凭据的东西。
    static func verdict(
        observationCount: Int,
        riskCounts: AnalysisRiskCounts,
        anomalyCount: Int,
        confidence: InsightConfidence,
        policy: Policy
    ) -> ProjectHealthSnapshot.Verdict {
        guard observationCount >= policy.minimumObservations else { return .insufficientData }
        if riskCounts.attentionCount > 0 { return .atRisk }
        if riskCounts.total > 0 || anomalyCount > 0 || confidence == .low { return .watch }
        return .healthy
    }

    /// 单位时间产出：效率最高的**可比** Agent 的「去重文件数 / 活跃秒」。
    ///
    /// 归属不明（`.unknown`）的行不进来看——它代表的是观测缺口，不是某种 Agent 的产出。
    /// 一行都没有（没有会话活跃秒，或只剩归属不明）时返回 `nil`：分析器给不出，我们就不给。
    static func efficiencyScore(from comparison: AgentEfficiencyComparison) -> Double? {
        comparison.rows
            .filter { $0.agentKind != .unknown }
            .compactMap(\.filesPerSecond)
            .max()
    }

    /// 一个异常桶 → 一条结论。返回 `nil` 的三种情况都是「说不清就不说」：
    /// 偏低方向没有对应种类、缺桶起始时刻（无法放进时间轴）、基线不可计算。
    static func finding(
        for observation: AnomalyObservation,
        report: AnomalyReport,
        buckets: AnomalyBuckets,
        sources: [BucketedRecord],
        bucketSeconds: Double
    ) -> AnomalyFinding? {
        guard observation.direction == .spike else { return nil }
        guard let kind = kind(for: report.metric) else { return nil }
        guard let detectedAt = observation.bucketStart, let expected = report.baselineMean,
              let zScore = observation.zScore else { return nil }

        // 归属：该桶内的记录若属于同一个项目 / 同一个会话才填，混杂时留 nil。
        let inBucket = sources.filter { buckets.index(of: $0.date) == observation.bucketIndex }
        return AnomalyFinding(
            kind: kind,
            severity: severity(zScore: zScore),
            summary: summary(
                kind: kind,
                observed: observation.value,
                expected: expected,
                zScore: zScore,
                threshold: report.threshold,
                bucketSeconds: bucketSeconds
            ),
            observed: observation.value,
            expected: expected,
            detectedAt: detectedAt,
            projectPath: singleValue(inBucket.map(\.projectPath)),
            sessionID: singleValue(inBucket.map(\.sessionID))
        )
    }

    /// 指标 → 结论种类。`AnomalyDetector` 只有这四个指标，因此不存在 default 分支。
    static func kind(for metric: AnomalyMetric) -> AnomalyFinding.Kind? {
        switch metric {
        case .eventRate:    return .eventBurst
        case .deletionRate: return .deletionSpike
        case .commandRate:  return .commandSpike
        case .cpuLoad:      return .cpuSpike
        }
    }

    /// σ 倍数 → 已有的风险色阶。默认阈值是 3σ，所以「刚过线」是 MEDIUM，不是 HIGH。
    static func severity(zScore: Double) -> RiskLevel {
        let sigma = Swift.abs(zScore)
        switch sigma {
        case ..<4: return .medium
        case ..<5: return .high
        default:   return .critical
        }
    }

    /// 一行结论：数字全部来自分析器给出的观测值、基线与阈值，单位与桶宽一起写出来。
    static func summary(
        kind: AnomalyFinding.Kind,
        observed: Double,
        expected: Double,
        zScore: Double,
        threshold: Double,
        bucketSeconds: Double
    ) -> String {
        "桶宽 \(DurationFormat.compact(bucketSeconds)) 的 \(kind.metricText) 实测 \(number(observed))"
            + "（基线均值 \(number(expected))，偏离 \(number(zScore))σ，阈值 \(number(threshold))σ）"
    }

    /// 定点一位小数。非有限数值写成「不可计算」，绝不落进文案里变成 `nan`。
    static func number(_ value: Double) -> String {
        guard value.isFinite else { return "不可计算" }
        return String(format: "%.1f", value)
    }

    /// 全部一致时给出那个值；混杂 / 全缺失时返回 `nil`（不把「多数派」说成「归属」）。
    static func singleValue<Value: Hashable>(_ values: [Value?]) -> Value? {
        guard let first = values.first, values.allSatisfy({ $0 == first }) else { return nil }
        return first
    }

    /// 检出时间降序；同一时刻按 id 定序，保证两次刷新顺序不抖。
    static func ordered(_ findings: [AnomalyFinding]) -> [AnomalyFinding] {
        findings.sorted { lhs, rhs in
            if lhs.detectedAt != rhs.detectedAt { return lhs.detectedAt > rhs.detectedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }
}

// MARK: - Bucket helpers

/// 一条观测记录在它所属指标里的时间归属，用来把异常桶反查回项目 / 会话。
struct BucketedRecord: Sendable, Hashable {
    let date: Date
    let projectPath: String?
    let sessionID: UUID?
}

/// 与 `InsightStatistics.bucketSums` 一致的分桶规则：`index = floor((date - start) / 桶宽)`，
/// 起点之前的记录夹到首桶（Insights 对窗口两端都做夹取，这里只会用到下界——
/// 异常桶号必然落在窗口内，窗口外的记录本来就不参与本轮统计）。
///
/// 只有复用同一套夹取规则，反查出来的「这个桶里的记录」才和分析器数出来的那个桶是同一批。
struct AnomalyBuckets: Sendable, Hashable {
    let start: Date
    let bucketSeconds: Double

    func index(of date: Date) -> Int {
        guard bucketSeconds > 0 else { return 0 }
        let raw = date.timeIntervalSince(start) / bucketSeconds
        return raw < 0 ? 0 : Int(raw.rounded(.down))
    }
}
