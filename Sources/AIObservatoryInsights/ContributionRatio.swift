//
//  ContributionRatio.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

/// 「谁改的」占比切分：Agent / 归属不明 / 人工。
///
/// 输入须已由 WS-Engine 的 `ProjectMapper` 按项目根归好组；本文件只算占比，不做路径归属判断。
public enum ContributionRatioAnalyzer {
    /// 参与度分析。
    ///
    /// - Parameters:
    ///   - agentChanges: 采集到的 Agent 改动。
    ///   - humanChanges: 人工改动基线。`nil` 表示没有人工基线。
    ///   - referenceDate: 时间覆盖度量的参考终点。
    /// - Returns: 占比切分。`total == 0` 时返回全零结构且 `confidence == .low`。
    ///
    /// 人工占比只有在调用方**显式提供**人工基线时才给出。观测数据里没有任何字段能证明
    /// 「这次改动是人做的」，硬编一个数字就是伪造，所以缺基线时 `humanShare` 必须是 `nil`。
    public static func analyze(
        agentChanges: [FileChange],
        humanChanges: [FileChange]?,
        referenceDate: Date,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> ContributionBreakdown {
        let humanCount = humanChanges?.count ?? 0
        let total = agentChanges.count + humanCount

        guard total > 0 else {
            return emptyBreakdown(interfaceLanguage: interfaceLanguage)
        }

        let denominator = Double(total)
        let grouped = Dictionary(grouping: agentChanges, by: \.agentKind)

        var shares: [AgentContributionShare] = []
        var unattributedCount = 0
        for (kind, rows) in grouped {
            if kind == .unknown {
                unattributedCount = rows.count
                continue
            }
            var added = 0
            var removed = 0
            for row in rows {
                added += max(0, row.linesAdded)
                removed += max(0, row.linesRemoved)
            }
            shares.append(
                AgentContributionShare(
                    agentKind: kind,
                    changeCount: rows.count,
                    linesAdded: added,
                    linesRemoved: removed,
                    share: Double(rows.count) / denominator
                )
            )
        }
        shares.sort {
            if $0.share != $1.share { return $0.share > $1.share }
            return $0.agentKind.rawValue < $1.agentKind.rawValue
        }

        let humanShare = humanChanges == nil ? nil : Double(humanCount) / denominator
        let unattributedShare = Double(unattributedCount) / denominator
        let shareTotal = shares.reduce(0) { $0 + $1.share } + unattributedShare + (humanShare ?? 0)

        let agentCount = agentChanges.count - unattributedCount
        let evidence = InsightEvidence(
            observationCount: total,
            coverageSeconds: coverage(agentChanges, humanChanges: humanChanges, referenceDate: referenceDate),
            missingFieldRatio: unattributedShare
        )

        return ContributionBreakdown(
            agentShares: shares,
            unattributedShare: unattributedShare,
            humanShare: humanShare,
            shareTotal: shareTotal,
            totalChangeCount: total,
            agentChangeCount: agentCount,
            unattributedChangeCount: unattributedCount,
            humanChangeCount: humanCount,
            isHumanShareEstimable: humanChanges != nil,
            confidence: InsightConfidenceEvaluator.evaluate(evidence),
            basis: basis(
                shares: shares,
                unattributedShare: unattributedShare,
                humanShare: humanShare,
                total: total,
                humanBaseline: humanChanges != nil,
                interfaceLanguage: interfaceLanguage
            )
        )
    }

    private static func emptyBreakdown(interfaceLanguage: AppLanguage) -> ContributionBreakdown {
        ContributionBreakdown(
            agentShares: [],
            unattributedShare: 0,
            humanShare: nil,
            shareTotal: 0,
            totalChangeCount: 0,
            agentChangeCount: 0,
            unattributedChangeCount: 0,
            humanChangeCount: 0,
            isHumanShareEstimable: false,
            confidence: .low,
            basis: InsightCopy.contributionNoData.text(interfaceLanguage)
        )
    }

    /// 覆盖时长：样本自身的时间跨度，上界夹到注入的参考时刻——
    /// 不把「参考时刻之后」这段没有任何证据的时间算进覆盖度。
    private static func coverage(_ changes: [FileChange], humanChanges: [FileChange]?, referenceDate: Date) -> Double {
        var dates = changes.map(\.timestamp)
        if let humanChanges {
            dates.append(contentsOf: humanChanges.map(\.timestamp))
        }
        guard let earliest = dates.min(), let latest = dates.max() else { return 0 }
        let upper = min(latest, referenceDate)
        return max(0, upper.timeIntervalSince(earliest))
    }

    private static func basis(
        shares: [AgentContributionShare],
        unattributedShare: Double,
        humanShare: Double?,
        total: Int,
        humanBaseline: Bool,
        interfaceLanguage: AppLanguage
    ) -> String {
        var parts: [String] = []
        for share in shares {
            parts.append("\(share.agentKind.displayName) \(percentText(share.share))")
        }
        if unattributedShare > 0 {
            parts.append(InsightCopy.contributionUnattributed.format(interfaceLanguage,
                                                                     percentText(unattributedShare)))
        }
        if let humanShare {
            parts.append(InsightCopy.contributionHuman.format(interfaceLanguage, percentText(humanShare)))
        } else {
            parts.append(InsightCopy.contributionHumanUnknown.text(interfaceLanguage))
        }
        var text = InsightCopy.contributionTotal.format(
            interfaceLanguage, String(total), parts.joined(separator: " · ")
        )
        if !humanBaseline {
            text += " · " + InsightCopy.contributionAgentSideOnly.text(interfaceLanguage)
        }
        return text
    }

    private static func percentText(_ share: Double) -> String {
        let clamped = min(1, max(0, share))
        let basisPoints = Int(clamped * 10_000)
        return String(format: "%d.%02d%%", basisPoints / 100, basisPoints % 100)
    }
}
