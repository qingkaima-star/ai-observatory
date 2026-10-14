//
//  DashboardAnomalyCard.swift
//  AIObservatoryUI / Dashboard
//
//  Owner: WS-InsightsMount（波次 4）
//  ─────────────────────────────────────────────────────────
//  「异常检测」卡片：列出最近检出的 AI 行为异常（最多 5 条）。
//
//  数据全部来自 `runtime.analysis`（Engine 侧的分析层执行者），视图不碰分析器也不查库。
//  三种空态文案见 `AnalysisPresentation`：未接入 / 没有可分析的记录 / 查过了没检出。
//

import SwiftUI
import AIObservatoryCore

/// Dashboard 的异常检测卡片。
struct DashboardAnomalyCard: View {

    let findings: [AnomalyFinding]
    /// `runtime.analysis != nil`。false 时整卡只说「未接入」，不显示任何数字。
    let analysisWired: Bool
    /// 本范围内是否有任何观测记录（决定「没有可分析的记录」与「没检出异常」的差别）。
    let hasRecords: Bool
    let isLoading: Bool
    let errorMessage: String?
    /// 扫描起点的口径文案（例如「自 2026-09-20 04:00 起」）。nil 表示范围待定。
    let windowText: String?
    /// 每条结论的取证出口（#98）：异常按种类跳去**它自己的证据页**（删除突增 → 文件页…）。
    var jump: (@MainActor (DashboardEvidenceJump) -> Void)? = nil

    private var emptyKind: AnalysisEmptyKind? {
        AnalysisPresentation.emptyKind(
            analysisWired: analysisWired,
            hasRecords: hasRecords,
            hasFindings: !findings.isEmpty
        )
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    DashboardCopy.anomalyTitle.text(language),
                    subtitle: subtitle) {
                    HStack(spacing: Spacing.sm) {
                        if isLoading {
                            ProgressView().controlSize(.small)
                        }
                        Text(AnalysisPresentation.anomalyText(findings.count))
                            .font(.axMeta)
                            .monospacedDigit()
                            .foregroundStyle(Surface.secondaryLabel)
                            .contentTransition(.numericText())
                    }
                }

                if findings.isEmpty {
                    emptyBody
                } else {
                    findingList
                }

                if let errorMessage {
                    failureRow(errorMessage)
                }
            }
        }
        .animation(.snappy, value: findings.count)
    }

    // MARK: - 副标题

    private var subtitle: String {
        if !analysisWired { return DashboardCopy.anomalyNotWired.text(language) }
        if let windowText { return DashboardCopy.anomalyWindow.copy.format(language, windowText) }
        return DashboardCopy.anomalyWindowPlain.text(language)
    }

    // MARK: - 列表

    private var findingList: some View {
        VStack(spacing: Spacing.xs) {
            ForEach(AnalysisPresentation.visibleFindings(findings)) { finding in
                if let jump {
                    Button {
                        jump(.anomaly(finding.kind))
                    } label: {
                        AnomalyFindingRow(finding: finding)
                    }
                    .buttonStyle(.axPressable)
                } else {
                    AnomalyFindingRow(finding: finding)
                }
            }
            if let hidden = trailingNote {
                Text(hidden)
                    // #97 的第二处（第一遍漏的）：「还有 N 条没显示给你看」回答的是**哪些没算进来**，
                    // 与已修的 `morePathsUnlisted` 同句形——挂在最低档就等于让读的人以为屏上这几条是全部。
                    .axCaptionStyle()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, Spacing.xs)
            }
        }
    }

    /// 超出展示上限时的说明：不显示的行数也要说清楚，别让人以为「一共就这 5 条」。
    private var trailingNote: String? {
        let hidden = AnalysisPresentation.hiddenCount(findings)
        guard hidden > 0 else { return nil }
        return DashboardCopy.anomalyHiddenRest.copy.format(
                language, hidden, AnalysisPresentation.dashboardFindingLimit
            )
    }

    // MARK: - 空态 / 失败

    @ViewBuilder private var emptyBody: some View {
        if let emptyKind {
            // 空态**不钉卡高**（#85）：改前这里是 `.frame(height: 140)`，于是"查过了，没检出"
            // 那两行字坐在 140 pt 的空框里。`fills: false` 是基座给"面板内空"那一档的占位，
            // 高度由内容决定；"整页空"（`fills: true`）才垂直撑满。
            EmptyStateView(
                AnalysisPresentation.title(for: emptyKind),
                systemImage: AnalysisPresentation.systemImage(for: emptyKind),
                message: AnalysisPresentation.message(for: emptyKind),
                fills: false
            )
        }
    }

    private func failureRow(_ message: String) -> some View {
        HStack(spacing: Spacing.sm) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.axMeta)
                .foregroundStyle(ObservatoryColor.caution)
            Text(DashboardCopy.anomalyStaleScan.copy.format(language, message))
                // #97 同一条：这句说的是"上面的异常读数是旧扫描的结果"，
                // 它决定读者要不要信这一屏，属于口径句 ⇒ 不提档就没法读。
                .axCaptionStyle()
                .textSelection(.enabled)
            Spacer(minLength: Spacing.none)
        }
    }
}

/// 单条异常结论。
struct AnomalyFindingRow: View {

    let finding: AnomalyFinding
    /// #89：`finding.summary` 与读屏那一句都是自由文本 ⇒ 与全站同一把尺。
    @Environment(\.demoRedaction) private var demoRedaction

    var body: some View {
        HStack(spacing: Spacing.sm) {
            RiskBadge(finding.severity, prominent: finding.severity >= .high)
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(demoRedaction.scrub(finding.summary))
                    .font(.axBody)
                    .lineLimit(2)
                Text(AnalysisPresentation.observedExpectedText(finding))
                    // #97：这一句是"实测 vs 期望"的**口径**，不是装饰——
                    // 它就是让人判断"这条异常凭什么成立"的那半句话，原先跑在最低对比档
                    // （11pt + tertiaryLabel，面板底上实测 ~1.8:1），等于把可核对性的入口画成点缀。
                    .axCaptionStyle()
                    .monospacedDigit()
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.sm)
            VStack(alignment: .trailing, spacing: Spacing.xs) {
                Label(finding.kind.displayName, systemImage: finding.kind.sfSymbolName)
                    .font(.axMeta)
                    .foregroundStyle(ObservatoryTheme.color(for: finding.severity))
                Text(DateFormat.time(finding.detectedAt))
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.tertiaryLabel)
            }
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
        // 显式标签会**覆盖** combine 的结果，所以屏幕上的三项都要写进来：
        // 缺了等级名， VoiceOver 用户拿到的就是「只有 summary」，而 medium/high 共用橙色。
        .accessibilityLabel(demoRedaction.scrub(DashboardCopy.anomalyA11y.copy.format(
                language, finding.severity.displayName, finding.kind.displayName, finding.summary
            )))
    }
}

#Preview("异常检测卡片") {
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let findings = [
        AnomalyFinding(
            kind: .eventBurst, severity: .high,
            summary: "桶宽 1h0m 的事件数 实测 40.0（基线均值 3.7，偏离 3.3σ，阈值 3.0σ）",
            observed: 40, expected: 3.67, detectedAt: base, projectPath: "/Users/demo/Projects/Mona"
        ),
        AnomalyFinding(
            kind: .deletionSpike, severity: .medium,
            summary: "桶宽 1h0m 的删除行数 实测 1820.0（基线均值 96.4，偏离 3.1σ，阈值 3.0σ）",
            observed: 1820, expected: 96.4, detectedAt: base.addingTimeInterval(-3600)
        )
    ]
    ObservatoryPreview.screen { _ in
        VStack(spacing: Spacing.md) {
            DashboardAnomalyCard(
                findings: findings, analysisWired: true, hasRecords: true,
                isLoading: false, errorMessage: nil, windowText: "自 2026-09-19 12:00 起"
            )
            DashboardAnomalyCard(
                findings: [], analysisWired: false, hasRecords: true,
                isLoading: false, errorMessage: nil, windowText: nil
            )
            DashboardAnomalyCard(
                findings: [], analysisWired: true, hasRecords: false,
                isLoading: false, errorMessage: nil, windowText: nil
            )
        }
        .padding(Spacing.lg)
    }
}

private extension DashboardAnomalyCard {
    var language: AppLanguage { UILanguage.current }
}

private extension AnomalyFindingRow {
    var language: AppLanguage { UILanguage.current }
}
