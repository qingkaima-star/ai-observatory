//
//  ProjectHealthCard.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-InsightsMount（波次 4）
//  ─────────────────────────────────────────────────────────
//  项目详情面板的健康度行：判定结论 + 风险计数 + 异常数 + 单位时间产出。
//
//  数据全部来自 `runtime.analysis?.projectHealth(for:)`（Core 值类型），
//  UI 不依赖 AIObservatoryInsights。文案口径集中在 `AnalysisPresentation`。
//
//  一条硬规则：`insufficientData` 渲染成「数据不足」并配灰色，绝不显示成绿色的「健康」。
//

import SwiftUI
import AIObservatoryCore

/// 项目健康度行。
struct ProjectHealthCard: View {

    let state: ProjectHealthState
    let isLoading: Bool

    var body: some View {
        Panel.recessed(padding: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: AnalysisPresentation.verdictSymbol(state))
                        .font(.axBody)
                        .foregroundStyle(AnalysisPresentation.verdictTint(state))
                    Text(AnalysisPresentation.healthTitle(state))
                        .font(.axSection)
                        .foregroundStyle(Surface.label)
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Spacer(minLength: Spacing.sm)
                    if isLoading {
                        ProgressView().controlSize(.small)
                    }
                }

                breakdown

                Text(AnalysisPresentation.healthDetail(state))
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 只在拿到快照、且结论不是「数据不足」时才有分解数字。
    /// 未接入 / 无健康度 / 查失败 / 观测不够时都不摆数字，免得一排数被读成结论。
    private var language: AppLanguage { UILanguage.current }

    @ViewBuilder private var breakdown: some View {
        if AnalysisPresentation.showsBreakdown(state), case .resolved(let snapshot) = state {
            HStack(spacing: Spacing.sm) {
                InlineStat(
                    ProjectsCopy.tileRiskEvents.text(language),
                    value: AnalysisPresentation.riskBreakdownText(snapshot.riskCounts))
                InlineStat(
                    ProjectsCopy.healthAnomalies.text(language),
                    value: AnalysisPresentation.anomalyText(snapshot.anomalyCount))
                InlineStat(
                    ProjectsCopy.healthEfficiency.text(language),
                    value: AnalysisPresentation.efficiencyText(snapshot.efficiencyScore))
            }
        }
    }
}

#Preview("项目健康度三种状态") {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    ObservatoryPreview.screen { _ in
        VStack(spacing: Spacing.md) {
            ProjectHealthCard(
                state: .resolved(ProjectHealthSnapshot(
                    projectPath: "/Users/demo/Projects/Mona",
                    riskCounts: AnalysisRiskCounts(critical: 1, high: 2, medium: 3, low: 4),
                    anomalyCount: 2,
                    efficiencyScore: 0.00042,
                    verdict: .atRisk,
                    generatedAt: base
                )),
                isLoading: false
            )
            ProjectHealthCard(
                state: .resolved(ProjectHealthSnapshot(
                    projectPath: "/Users/demo/Projects/Aurora",
                    verdict: .insufficientData,
                    generatedAt: base
                )),
                isLoading: false
            )
            ProjectHealthCard(state: .notWired, isLoading: false)
            ProjectHealthCard(state: .unavailable, isLoading: true)
        }
        .padding(Spacing.lg)
    }
}
