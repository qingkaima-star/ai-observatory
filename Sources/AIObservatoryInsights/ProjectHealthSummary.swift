//
//  ProjectHealthSummary.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

/// 一个项目的「AI Contribution Map」汇总入口。
///
/// 本文件只做**装配**：把热度 / 参与度 / 增长 / 产量 / 异常 / 效率六个分析器拼成
/// 一个可直接渲染的结构体，不重复实现任何算法。
/// 输入须已由 WS-Engine 的 `ProjectMapper` 按项目根归好组。
public enum ProjectHealthAnalyzer {
    /// 风险事件按等级计数。
    public static func riskCounts(from riskEvents: [RiskEvent]) -> ProjectRiskCounts {
        var counts = ProjectRiskCounts()
        for event in riskEvents {
            switch event.level {
            case .low: counts.low += 1
            case .medium: counts.medium += 1
            case .high: counts.high += 1
            case .critical: counts.critical += 1
            }
        }
        return counts
    }

    /// 汇总单项目健康度。
    ///
    /// - Parameters:
    ///   - changes/commands/events/systemSamples/sessions/riskEvents: 同一项目内的各类观测数据。
    ///   - windowStart/windowEnd: 统计窗口（趋势与吞吐的分母）。
    ///   - referenceDate: 「现在」，一律注入，绝不在内部读墙钟。
    ///   - topHotFileLimit: 保留的热文件条数。
    ///   - bucketSeconds: 趋势与异常检测的桶宽。
    /// - Returns: 汇总结果；空输入仍然返回完整结构（各分项为「不可估计」而不是 0）。
    ///
    /// 置信度取各分项的**最弱一环**，不做平均：一个模块的数据缺口不能被另一个模块的充沛样本掩盖。
    public static func summarize(
        projectName: String,
        projectPath: String,
        changes: [FileChange],
        commands: [CommandRecord],
        events: [TimelineEvent],
        systemSamples: [SystemPerformanceSample],
        sessions: [AgentSession],
        riskEvents: [RiskEvent],
        windowStart: Date,
        windowEnd: Date,
        referenceDate: Date,
        topHotFileLimit: Int = 10,
        bucketSeconds: Double = 3600,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> ProjectHealthSummary {
        // 一次汇总只有一个语言：各分项都收同一个 `interfaceLanguage`，不各自 `resolved()`，
        // 否则一次刷新里读到一半中文一半英文（语言不会中途变，但**读八次**这件事本身就是隐患）。
        let hotFiles = FileHotnessScorer.topHotFiles(
            FileHotnessScorer.score(changes: changes, referenceDate: referenceDate,
                                    interfaceLanguage: interfaceLanguage),
            limit: topHotFileLimit
        )
        let contribution = ContributionRatioAnalyzer.analyze(
            agentChanges: changes,
            humanChanges: nil,
            referenceDate: referenceDate,
            interfaceLanguage: interfaceLanguage
        )
        let codeGrowth = CodeGrowthEstimator.summarize(
            changes: changes,
            windowStart: windowStart,
            windowEnd: windowEnd,
            bucketSeconds: bucketSeconds,
            interfaceLanguage: interfaceLanguage
        )
        let throughput = CommandThroughputAnalyzer.summarize(
            commands: commands,
            windowStart: windowStart,
            windowEnd: windowEnd,
            interfaceLanguage: interfaceLanguage
        )
        let anomalies = [
            AnomalyDetector.detectEventRates(
                events: events,
                windowStart: windowStart,
                windowEnd: windowEnd,
                bucketSeconds: bucketSeconds,
                interfaceLanguage: interfaceLanguage
            ),
            AnomalyDetector.detectDeletions(
                changes: changes,
                windowStart: windowStart,
                windowEnd: windowEnd,
                bucketSeconds: bucketSeconds,
                interfaceLanguage: interfaceLanguage
            ),
            AnomalyDetector.detectCommands(
                commands: commands,
                windowStart: windowStart,
                windowEnd: windowEnd,
                bucketSeconds: bucketSeconds,
                interfaceLanguage: interfaceLanguage
            ),
            AnomalyDetector.detectCPU(samples: systemSamples, interfaceLanguage: interfaceLanguage)
        ]
        .filter { !$0.observations.isEmpty }
        let efficiency = AgentEfficiencyComparator.compare(
            sessions: sessions,
            changes: changes,
            commands: commands,
            referenceDate: referenceDate,
            interfaceLanguage: interfaceLanguage
        )
        let counts = riskCounts(from: riskEvents)
        let confidence = InsightConfidenceEvaluator.weakest([
            contribution.confidence,
            codeGrowth.confidence,
            throughput.confidence,
            efficiency.confidence
        ]) ?? .low

        return ProjectHealthSummary(
            projectName: projectName,
            projectPath: projectPath,
            windowStart: windowStart,
            windowEnd: windowEnd,
            fileChangeCount: changes.count,
            commandCount: commands.count,
            sessionCount: sessions.count,
            topHotFiles: hotFiles,
            contribution: contribution,
            codeGrowth: codeGrowth,
            throughput: throughput,
            anomalies: anomalies,
            efficiency: efficiency,
            riskCounts: counts,
            growthTrend: codeGrowth.trend,
            activityTrend: activityTrend(
                events: events,
                windowStart: windowStart,
                windowEnd: windowEnd,
                bucketSeconds: bucketSeconds
            ),
            confidence: confidence,
            basis: basis(
                hotFileCount: hotFiles.count,
                contribution: contribution,
                codeGrowth: codeGrowth,
                throughput: throughput,
                anomalyCount: anomalies.reduce(0) { $0 + $1.anomalousObservations.count },
                skippedAnomalies: anomalies.filter { $0.skippedReason != nil }.count,
                riskCounts: counts,
                confidence: confidence,
                interfaceLanguage: interfaceLanguage
            )
        )
    }

    /// 事件密度的走向。桶数不足 2 时无法判断斜率，明确返回 `unknown`。
    private static func activityTrend(
        events: [TimelineEvent],
        windowStart: Date,
        windowEnd: Date,
        bucketSeconds: Double
    ) -> InsightTrend {
        guard let counts = InsightStatistics.bucketCounts(
            timestamps: events.map(\.timestamp),
            start: windowStart,
            end: windowEnd,
            bucketSeconds: bucketSeconds
        ), counts.count >= 2 else { return .unknown }
        let xs = (0..<counts.count).map(Double.init)
        return InsightTrend.of(
            slope: InsightStatistics.linearSlope(xs: xs, ys: counts),
            threshold: activityTrendThreshold
        )
    }

    /// 事件密度「持平」判定阈值（每分钟事件数的变化量）。
    static let activityTrendThreshold = 1.0

    private static func basis(
        hotFileCount: Int,
        contribution: ContributionBreakdown,
        codeGrowth: CodeGrowthSummary,
        throughput: CommandThroughputSummary,
        anomalyCount: Int,
        skippedAnomalies: Int,
        riskCounts: ProjectRiskCounts,
        confidence: InsightConfidence,
        interfaceLanguage: AppLanguage
    ) -> String {
        let language = interfaceLanguage
        var parts: [String] = [
            InsightCopy.healthHotFiles.format(language, String(hotFileCount)),
            InsightCopy.healthContribution.format(
                language, String(contribution.agentShares.count),
                contribution.isHumanShareEstimable
                    ? InsightCopy.estimated.text(language)
                    : InsightCopy.notEstimable.text(language)
            ),
            InsightCopy.healthCodeGrowth.format(
                language,
                "\(codeGrowth.netLines >= 0 ? "+" : "")\(codeGrowth.netLines)",
                codeGrowth.trend.displayName(language)
            ),
            InsightCopy.healthCommands.format(language, String(throughput.commandCount)),
            InsightCopy.healthAnomalies.format(language, String(anomalyCount)),
        ]
        if skippedAnomalies > 0 {
            parts.append(InsightCopy.healthSkippedAnomalies.format(language, String(skippedAnomalies)))
        }
        if riskCounts.total > 0 {
            parts.append(InsightCopy.healthRisks.format(language, String(riskCounts.total),
                                                        String(riskCounts.attentionCount)))
        }
        parts.append(InsightCopy.healthConfidence.format(language, confidence.displayName))
        return parts.joined(separator: " · ")
    }
}
