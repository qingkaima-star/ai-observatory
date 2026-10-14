//
//  InsightModels.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

// MARK: - 趋势

/// 指标随时间的走向。
///
/// `unknown` 与 `flat` 严格区分：前者是「样本不足以判断」，后者是「样本充足但无明显斜率」。
public enum InsightTrend: String, Codable, Sendable, CaseIterable, Hashable {
    case rising
    case flat
    case falling
    case unknown

    /// 显示名，按当前进程语言取（趋势只在看的时候渲染，不落库）。
    public var displayName: String { displayName(AppLanguage.resolved()) }

    /// 按**指定语言**取显示名。
    ///
    /// 拼一句依据时**必须**用这一条：`trend.displayName` 读的是进程语言，
    /// 于是英文依据句里会混进「持平」——用例 `codeGrowthBasis` 就是靠
    /// 「英文句里不许有中文」抓到的。
    public func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .rising:   return InsightCopy.trendRising.text(language)
        case .flat:     return InsightCopy.trendFlat.text(language)
        case .falling:  return InsightCopy.trendFalling.text(language)
        case .unknown:  return InsightCopy.trendUnknown.text(language)
        }
    }

    /// 由最小二乘斜率判定趋势。
    ///
    /// - Parameters:
    ///   - slope: 每桶变化量；`nil` 表示不可计算（样本 < 2 或无离散度）。
    ///   - threshold: 判定为「持平」的绝对值上限，必须为正。
    public static func of(slope: Double?, threshold: Double) -> InsightTrend {
        guard let slope, slope.isFinite, threshold > 0 else { return .unknown }
        if slope > threshold { return .rising }
        if slope < -threshold { return .falling }
        return .flat
    }
}

// MARK: - 文件热度

/// 热度各因子的权重。四个权重之和建议为 1，便于结果直接落在 `0...1`。
public struct HotFileWeights: Codable, Sendable, Hashable {
    public var frequency: Double
    public var repetition: Double
    public var breadth: Double
    public var recency: Double

    public init(frequency: Double, repetition: Double, breadth: Double, recency: Double) {
        self.frequency = frequency
        self.repetition = repetition
        self.breadth = breadth
        self.recency = recency
    }

    /// 默认权重：改动次数与「最近是否还在动」同等重要，多 Agent 触碰次之，重复次数最弱（已含在对数/衰减里）。
    public static let standard = HotFileWeights(frequency: 0.35, repetition: 0.15, breadth: 0.20, recency: 0.30)

    public var total: Double { frequency + repetition + breadth + recency }
}

/// 单个文件的原始因子取值，供 UI 展开「为什么这个文件排第一」。
public struct HotFileFactors: Codable, Sendable, Hashable {
    public var changeCount: Int
    /// 去重后触碰该文件的 Agent 种类数。
    public var distinctAgentCount: Int
    /// 最后一次改动距参考时刻的秒数。
    public var ageSeconds: Double
    /// `1 + r + r² + …`（`r` 为衰减系数）后的有效改动次数。
    public var effectiveEditCount: Double

    /// 归一化到语料库内最大值的因子（`0...1`）。
    public var normalizedFrequency: Double
    public var normalizedRepetition: Double
    public var normalizedBreadth: Double
    public var normalizedRecency: Double

    public init(
        changeCount: Int,
        distinctAgentCount: Int,
        ageSeconds: Double,
        effectiveEditCount: Double,
        normalizedFrequency: Double,
        normalizedRepetition: Double,
        normalizedBreadth: Double,
        normalizedRecency: Double
    ) {
        self.changeCount = changeCount
        self.distinctAgentCount = distinctAgentCount
        self.ageSeconds = ageSeconds
        self.effectiveEditCount = effectiveEditCount
        self.normalizedFrequency = normalizedFrequency
        self.normalizedRepetition = normalizedRepetition
        self.normalizedBreadth = normalizedBreadth
        self.normalizedRecency = normalizedRecency
    }
}

/// 一个文件的热度评分。
public struct HotFileScore: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    /// 归一化综合分，`0...1`。
    public var score: Double
    public var factors: HotFileFactors
    public var weights: HotFileWeights
    public var confidence: InsightConfidence
    /// 人类可读依据，例如「12 次改动、2 个 Agent、距今 1.5 天」。
    public var basis: String

    public init(
        path: String,
        score: Double,
        factors: HotFileFactors,
        weights: HotFileWeights,
        confidence: InsightConfidence,
        basis: String
    ) {
        self.path = path
        self.score = score
        self.factors = factors
        self.weights = weights
        self.confidence = confidence
        self.basis = basis
    }
}

// MARK: - 参与度

/// 单一 Agent 的贡献占比。
public struct AgentContributionShare: Identifiable, Codable, Sendable, Hashable {
    public var id: AgentKind { agentKind }
    public var agentKind: AgentKind
    public var changeCount: Int
    public var linesAdded: Int
    public var linesRemoved: Int
    /// 占**全部变更**的比例，`0...1`。
    public var share: Double

    public init(
        agentKind: AgentKind,
        changeCount: Int,
        linesAdded: Int,
        linesRemoved: Int,
        share: Double
    ) {
        self.agentKind = agentKind
        self.changeCount = changeCount
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.share = share
    }
}

/// Agent / 人工 / 归属不明 的参与度切分。
///
/// 人工占比**只有在调用方显式提供人工基线时才给出**，否则为 `nil` 并在 `basis` 中说明原因——
/// 观测数据里没有任何字段能证明「这次改动是人做的」，硬编一个数字就是伪造。
public struct ContributionBreakdown: Codable, Sendable, Hashable {
    public var agentShares: [AgentContributionShare]
    /// `agentKind == .unknown` 的变更占比。
    public var unattributedShare: Double
    /// 人工占比；不可估计时为 `nil`。
    public var humanShare: Double?
    /// 全部占比之和（agent + unattributed + human），用于自检，应约等于 1。
    public var shareTotal: Double
    public var totalChangeCount: Int
    public var agentChangeCount: Int
    public var unattributedChangeCount: Int
    public var humanChangeCount: Int
    public var isHumanShareEstimable: Bool
    public var confidence: InsightConfidence
    public var basis: String

    public init(
        agentShares: [AgentContributionShare],
        unattributedShare: Double,
        humanShare: Double?,
        shareTotal: Double,
        totalChangeCount: Int,
        agentChangeCount: Int,
        unattributedChangeCount: Int,
        humanChangeCount: Int,
        isHumanShareEstimable: Bool,
        confidence: InsightConfidence,
        basis: String
    ) {
        self.agentShares = agentShares
        self.unattributedShare = unattributedShare
        self.humanShare = humanShare
        self.shareTotal = shareTotal
        self.totalChangeCount = totalChangeCount
        self.agentChangeCount = agentChangeCount
        self.unattributedChangeCount = unattributedChangeCount
        self.humanChangeCount = humanChangeCount
        self.isHumanShareEstimable = isHumanShareEstimable
        self.confidence = confidence
        self.basis = basis
    }
}

// MARK: - 代码增长

/// 单文件净增长。
public struct CodeGrowthFile: Identifiable, Codable, Sendable, Hashable {
    public var id: String { path }
    public var path: String
    public var language: String
    public var linesAdded: Int
    public var linesRemoved: Int
    public var netLines: Int
    public var changeCount: Int

    public init(
        path: String,
        language: String,
        linesAdded: Int,
        linesRemoved: Int,
        netLines: Int,
        changeCount: Int
    ) {
        self.path = path
        self.language = language
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.netLines = netLines
        self.changeCount = changeCount
    }
}

/// 按语言（文件后缀归类）聚合的增长。
public struct CodeGrowthGroup: Identifiable, Codable, Sendable, Hashable {
    public var id: String { language }
    public var language: String
    public var fileCount: Int
    public var linesAdded: Int
    public var linesRemoved: Int
    public var netLines: Int

    public init(language: String, fileCount: Int, linesAdded: Int, linesRemoved: Int, netLines: Int) {
        self.language = language
        self.fileCount = fileCount
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.netLines = netLines
    }
}

/// 代码增长汇总。
public struct CodeGrowthSummary: Codable, Sendable, Hashable {
    public var linesAdded: Int
    public var linesRemoved: Int
    public var netLines: Int
    public var fileCount: Int
    /// 行数不可得（二进制或非文本）而被排除的变更数。
    public var skippedChangeCount: Int
    public var byFile: [CodeGrowthFile]
    public var byLanguage: [CodeGrowthGroup]
    /// 每桶净增行数序列，供画柱状图。
    public var netLinesPerBucket: [Int]
    public var trend: InsightTrend
    public var confidence: InsightConfidence
    public var basis: String

    public init(
        linesAdded: Int,
        linesRemoved: Int,
        netLines: Int,
        fileCount: Int,
        skippedChangeCount: Int,
        byFile: [CodeGrowthFile],
        byLanguage: [CodeGrowthGroup],
        netLinesPerBucket: [Int],
        trend: InsightTrend,
        confidence: InsightConfidence,
        basis: String
    ) {
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.netLines = netLines
        self.fileCount = fileCount
        self.skippedChangeCount = skippedChangeCount
        self.byFile = byFile
        self.byLanguage = byLanguage
        self.netLinesPerBucket = netLinesPerBucket
        self.trend = trend
        self.confidence = confidence
        self.basis = basis
    }
}

// MARK: - 命令产量

/// 命令执行吞吐与耗时分布。
public struct CommandThroughputSummary: Codable, Sendable, Hashable {
    public var commandCount: Int
    public var succeededCount: Int
    public var failedCount: Int
    /// 结果未知（仍在运行 / 无退出码）的命令数。
    public var unresolvedCount: Int
    /// 成功数 / 已判定数；无已判定命令时为 `nil`（不可估计，不等于 0）。
    public var successRate: Double?
    public var failureRate: Double?
    /// 窗口内每小时命令数；窗口非正时长为 `nil`。
    public var commandsPerHour: Double?
    /// 以下为耗时统计，仅覆盖有结束时间的命令。
    public var timedCommandCount: Int
    public var averageDurationSeconds: Double?
    public var medianDurationSeconds: Double?
    public var p95DurationSeconds: Double?
    public var destructiveCount: Int
    public var windowSeconds: Double
    public var confidence: InsightConfidence
    public var basis: String

    public init(
        commandCount: Int,
        succeededCount: Int,
        failedCount: Int,
        unresolvedCount: Int,
        successRate: Double?,
        failureRate: Double?,
        commandsPerHour: Double?,
        timedCommandCount: Int,
        averageDurationSeconds: Double?,
        medianDurationSeconds: Double?,
        p95DurationSeconds: Double?,
        destructiveCount: Int,
        windowSeconds: Double,
        confidence: InsightConfidence,
        basis: String
    ) {
        self.commandCount = commandCount
        self.succeededCount = succeededCount
        self.failedCount = failedCount
        self.unresolvedCount = unresolvedCount
        self.successRate = successRate
        self.failureRate = failureRate
        self.commandsPerHour = commandsPerHour
        self.timedCommandCount = timedCommandCount
        self.averageDurationSeconds = averageDurationSeconds
        self.medianDurationSeconds = medianDurationSeconds
        self.p95DurationSeconds = p95DurationSeconds
        self.destructiveCount = destructiveCount
        self.windowSeconds = windowSeconds
        self.confidence = confidence
        self.basis = basis
    }
}

// MARK: - 异常检测

/// 被检测的指标类型，决定缺省阈值语义。
public enum AnomalyMetric: String, Codable, Sendable, CaseIterable, Hashable {
    case eventRate
    case deletionRate
    case commandRate
    case cpuLoad

    /// 显示名，按当前进程语言取。
    public var displayName: String { displayName(AppLanguage.resolved()) }

    /// 按指定语言取（拼句时用这条，理由同 `InsightTrend.displayName(_:)`）。
    public func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .eventRate:    return InsightCopy.metricEventRate.text(language)
        case .deletionRate: return InsightCopy.metricDeletionRate.text(language)
        case .commandRate:  return InsightCopy.metricCommandRate.text(language)
        case .cpuLoad:      return InsightCopy.metricCPULoad.text(language)
        }
    }
}

public enum AnomalyDirection: String, Codable, Sendable, CaseIterable, Hashable {
    case spike
    case drop
}

/// 单个时间桶的观测值。
public struct AnomalyObservation: Identifiable, Codable, Sendable, Hashable {
    public var id: String { "\(metric.rawValue)-\(bucketIndex)" }
    public var metric: AnomalyMetric
    public var bucketIndex: Int
    public var bucketStart: Date?
    public var value: Double
    /// 基线不足时为 `nil`，此时绝不应被判为异常。
    public var zScore: Double?
    public var isAnomalous: Bool
    public var direction: AnomalyDirection?

    public init(
        metric: AnomalyMetric,
        bucketIndex: Int,
        bucketStart: Date?,
        value: Double,
        zScore: Double?,
        isAnomalous: Bool,
        direction: AnomalyDirection?
    ) {
        self.metric = metric
        self.bucketIndex = bucketIndex
        self.bucketStart = bucketStart
        self.value = value
        self.zScore = zScore
        self.isAnomalous = isAnomalous
        self.direction = direction
    }
}

/// 一份 z-score 异常检测报告。
///
/// 保护性约束：样本量低于 `minimumSampleSize` 或标准差为 0（常量/全零序列）时，
/// `anomalousObservations` 必为空，且 `skippedReason` 说明原因。
public struct AnomalyReport: Codable, Sendable, Hashable {
    public var metric: AnomalyMetric
    public var observations: [AnomalyObservation]
    public var anomalousObservations: [AnomalyObservation]
    public var baselineMean: Double?
    public var baselineStdev: Double?
    public var threshold: Double
    public var sampleSize: Int
    public var minimumSampleSize: Int
    public var isBaselineSufficient: Bool
    /// 未做判定时的原因，判定成功时为 `nil`。
    public var skippedReason: String?
    public var confidence: InsightConfidence
    public var basis: String

    public init(
        metric: AnomalyMetric,
        observations: [AnomalyObservation],
        anomalousObservations: [AnomalyObservation],
        baselineMean: Double?,
        baselineStdev: Double?,
        threshold: Double,
        sampleSize: Int,
        minimumSampleSize: Int,
        isBaselineSufficient: Bool,
        skippedReason: String?,
        confidence: InsightConfidence,
        basis: String
    ) {
        self.metric = metric
        self.observations = observations
        self.anomalousObservations = anomalousObservations
        self.baselineMean = baselineMean
        self.baselineStdev = baselineStdev
        self.threshold = threshold
        self.sampleSize = sampleSize
        self.minimumSampleSize = minimumSampleSize
        self.isBaselineSufficient = isBaselineSufficient
        self.skippedReason = skippedReason
        self.confidence = confidence
        self.basis = basis
    }
}

// MARK: - Agent 效率

/// 单个 Agent 的产出/成本对比行。
public struct AgentEfficiencyRow: Identifiable, Codable, Sendable, Hashable {
    public var id: AgentKind { agentKind }
    public var agentKind: AgentKind
    public var sessionCount: Int
    public var changeCount: Int
    public var distinctFileCount: Int
    public var commandCount: Int
    public var failedCommandCount: Int
    public var cpuSeconds: Double
    public var activeSeconds: Double
    /// 成功命令 / 全部命令；无命令时 `nil`。
    public var commandSuccessRate: Double?
    /// 触碰文件数 / 活跃秒；活跃秒非正时 `nil`。
    public var filesPerSecond: Double?
    /// CPU 秒 / 触碰文件数；无文件时 `nil`。
    public var cpuSecondsPerFile: Double?

    public init(
        agentKind: AgentKind,
        sessionCount: Int,
        changeCount: Int,
        distinctFileCount: Int,
        commandCount: Int,
        failedCommandCount: Int,
        cpuSeconds: Double,
        activeSeconds: Double,
        commandSuccessRate: Double?,
        filesPerSecond: Double?,
        cpuSecondsPerFile: Double?
    ) {
        self.agentKind = agentKind
        self.sessionCount = sessionCount
        self.changeCount = changeCount
        self.distinctFileCount = distinctFileCount
        self.commandCount = commandCount
        self.failedCommandCount = failedCommandCount
        self.cpuSeconds = cpuSeconds
        self.activeSeconds = activeSeconds
        self.commandSuccessRate = commandSuccessRate
        self.filesPerSecond = filesPerSecond
        self.cpuSecondsPerFile = cpuSecondsPerFile
    }
}

/// 同项目内多 Agent 的效率对比。
public struct AgentEfficiencyComparison: Codable, Sendable, Hashable {
    public var rows: [AgentEfficiencyRow]
    /// 单位时间产出最高的 Agent；不足两个可比 Agent 或全部不可比时 `nil`。
    public var mostEfficientAgent: AgentKind?
    /// 每文件 CPU 成本最低的 Agent；同上条件时为 `nil`。
    public var cheapestAgent: AgentKind?
    public var confidence: InsightConfidence
    public var basis: String

    public init(
        rows: [AgentEfficiencyRow],
        mostEfficientAgent: AgentKind?,
        cheapestAgent: AgentKind?,
        confidence: InsightConfidence,
        basis: String
    ) {
        self.rows = rows
        self.mostEfficientAgent = mostEfficientAgent
        self.cheapestAgent = cheapestAgent
        self.confidence = confidence
        self.basis = basis
    }
}

// MARK: - 项目健康摘要

/// 按风险等级计数。
public struct ProjectRiskCounts: Codable, Sendable, Hashable {
    public var critical: Int
    public var high: Int
    public var medium: Int
    public var low: Int

    public init(critical: Int = 0, high: Int = 0, medium: Int = 0, low: Int = 0) {
        self.critical = critical
        self.high = high
        self.medium = medium
        self.low = low
    }

    public var total: Int { critical + high + medium + low }
    /// 需要人看一眼的量级：HIGH 与 CRITICAL。
    public var attentionCount: Int { critical + high }
}

/// 一个项目的「AI Contribution Map」汇总，可直接渲染成一个页面。
public struct ProjectHealthSummary: Codable, Sendable, Hashable {
    public var projectName: String
    public var projectPath: String
    public var windowStart: Date
    public var windowEnd: Date
    public var fileChangeCount: Int
    public var commandCount: Int
    public var sessionCount: Int
    public var topHotFiles: [HotFileScore]
    public var contribution: ContributionBreakdown
    public var codeGrowth: CodeGrowthSummary
    public var throughput: CommandThroughputSummary
    public var anomalies: [AnomalyReport]
    public var efficiency: AgentEfficiencyComparison
    public var riskCounts: ProjectRiskCounts
    public var growthTrend: InsightTrend
    public var activityTrend: InsightTrend
    /// 取各分项置信度中最弱者。
    public var confidence: InsightConfidence
    public var basis: String

    public init(
        projectName: String,
        projectPath: String,
        windowStart: Date,
        windowEnd: Date,
        fileChangeCount: Int,
        commandCount: Int,
        sessionCount: Int,
        topHotFiles: [HotFileScore],
        contribution: ContributionBreakdown,
        codeGrowth: CodeGrowthSummary,
        throughput: CommandThroughputSummary,
        anomalies: [AnomalyReport],
        efficiency: AgentEfficiencyComparison,
        riskCounts: ProjectRiskCounts,
        growthTrend: InsightTrend,
        activityTrend: InsightTrend,
        confidence: InsightConfidence,
        basis: String
    ) {
        self.projectName = projectName
        self.projectPath = projectPath
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.fileChangeCount = fileChangeCount
        self.commandCount = commandCount
        self.sessionCount = sessionCount
        self.topHotFiles = topHotFiles
        self.contribution = contribution
        self.codeGrowth = codeGrowth
        self.throughput = throughput
        self.anomalies = anomalies
        self.efficiency = efficiency
        self.riskCounts = riskCounts
        self.growthTrend = growthTrend
        self.activityTrend = activityTrend
        self.confidence = confidence
        self.basis = basis
    }
}
