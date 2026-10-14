//
//  ProjectContributionChart.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-UI (subagent J)
//  ─────────────────────────────────────────────────────────
//  Agent 贡献占比柱状图（Swift Charts），单个项目与跨项目聚合共用。
//
//  「quiet」语言下的四条约束：
//    · 序列色只用 `ObservatoryTheme.chartColor(rank: chartRank(for:))` —— 有序灰阶，
//      同一 kind 永远同一灰；Agent 身份不靠配色（契约 §2）。
//    · 轴只走共享画法与共享挂载：`observatoryAxes(x: .category, ySuffix: "%")`
//      （y = 左侧标签 + 水平网格线的数值轴，x = 底部类目轴，两档都在
//      `DesignSystem/ChartChrome.swift` 里）。为此把条形从横向改成**纵向**：
//      共享轴的定位是「数值轴在左、类目轴在下」，横条图会让两条轴各跑错一侧。
//    · 图例用 `ChartLegend`，不再手搓 `Circle()`；`chartLegend(.hidden)` 那套删掉。
//    · 高度用 `Sizing.chartHeight`。
//  纵轴数据换算成 0...100 的百分数再画：`valueAxis(suffix:)` 的标签是 `Int(double)`，
//  直接画 0...1 会得到一排「0%」。y 域钉死 0...100（占比的物理上界），
//  因此单 Agent 100% 时既不会被夹掉，也不会出现「贴着顶却报 87%」的错位轴。
//  本图没有 `RuleMark`，参考线那句 y 域余量规则在这里不适用。
//
//  既服务 ProjectDetailView（单项目），也服务 ProjectsView 右栏的聚合视图（可见项目）。
//

import SwiftUI
import Charts
import AIObservatoryCore

struct ProjectContributionChart: View {

    let contributions: [AgentContribution]
    /// 标题与摘要不给就走本页文案表的默认值（默认值写成中文就会让英文态拿到中文）。
    var title: String? = nil
    var subtitle: String? = nil
    var summaryHint: String? = nil

    private var language: AppLanguage { UILanguage.current }

    /// 最多画几条序列，超出的折进「其他 Agent」——7 根以上的窄栏里读不出差异。
    private static let maxRows = 6

    // MARK: - Body

    var body: some View {
        Panel.recessed(padding: Spacing.md) {
            // 绑一次再下传：`rows` 是排序 + 归一化的派生数组，每次读都是新身份，
            // 而 Charts 按身份管理内部状态——读两次以上就会让 RSS 只增不减。
            let rows = self.rows

            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(resolvedTitle, subtitle: resolvedSubtitle(rows: rows)) {
                    Text(summaryHint ?? ProjectsCopy.chartTotalChanges.format(language, totalEvents))
                        .font(.axMeta)
                        .monospacedDigit()
                        .foregroundStyle(Surface.secondaryLabel)
                }

                if rows.isEmpty {
                    EmptyStateView(
                        ProjectsCopy.shareNoData.text(language),
                        systemImage: "circle.dotted",
                        message: ProjectsCopy.chartEmptyMessage.text(language),
                        fills: false
                    )
                } else {
                    chart(rows)
                    legend(rows)
                }
            }
        }
    }

    // MARK: - 图表

    /// 单个 `ForEach` 里只放**一个** `BarMark`（图表铁律：两条序列就要两个 `ForEach`，
    /// 内联多个 Mark 的长表达式还会把类型检查拖爆）。
    private func chart(_ rows: [ContributionRow]) -> some View {
        Chart {
            ForEach(rows) { row in
                BarMark(
                    // #82：轴标签走表（改前是裸字面量 "Agent"，英文态与中文态同一串、
                    // 且没有任何出处能改它）；这一行的名字与 `AgentChip` 取同一个入口，
                    // 图例与列表里不会再是两种写法。
                    x: .value(AgentNaming.fieldLabel.text(language), row.name),
                    y: .value(ProjectsCopy.chartAxisShare.text(language), row.percent)
                )
                .foregroundStyle(row.color)
                .cornerRadius(ObservatoryRadius.tag)
            }
        }
        .chartYScale(domain: 0...100)
        .observatoryAxes(x: .category, ySuffix: "%")
        .frame(maxWidth: .infinity)
        .frame(height: Sizing.chartHeight)
        .animation(ObservatoryMotion.value, value: rows.count)
        .accessibilityLabel(accessibilitySummary(rows))
    }

    /// 图例即读数：每条序列一行「名称 · 次数 · 占比」，色点与那根柱子同源。
    private func legend(_ rows: [ContributionRow]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            // `Item.id` 用行号而不是灰阶位次：位次来自 `AgentKind` 声明序，
            // 「其他 Agent」合并段与真实的 unknown kind 会撞成同一个 id。
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                ChartLegend([.init(id: index, label: row.legendLabel, color: row.color)])
            }
        }
    }

    // MARK: - 数据

    /// 排序 + 折叠「其他」+ 归一化，全在一次求值里做完。
    private var rows: [ContributionRow] {
        let sorted = contributions
            .filter { $0.relativeShare > 0 || $0.eventCount > 0 }
            .sorted { lhs, rhs in
                if lhs.eventCount != rhs.eventCount { return lhs.eventCount > rhs.eventCount }
                return lhs.relativeShare > rhs.relativeShare
            }
        guard !sorted.isEmpty else { return [] }
        let total = max(0.0001, sorted.reduce(0) { $0 + $1.relativeShare })

        let head: [AgentContribution]
        let tail: [AgentContribution]
        if sorted.count > Self.maxRows {
            head = Array(sorted.prefix(Self.maxRows - 1))
            tail = Array(sorted.dropFirst(Self.maxRows - 1))
        } else {
            head = sorted
            tail = []
        }

        var result: [ContributionRow] = []
        result.reserveCapacity(head.count + 1)
        for contribution in head {
            result.append(ContributionRow(
                id: "kind:\(contribution.kind.rawValue)",
                name: AgentNaming.name(kind: contribution.kind),
                rank: ObservatoryTheme.chartRank(for: contribution.kind),
                events: contribution.eventCount,
                percent: percent(contribution.relativeShare, of: total)
            ))
        }
        if tail.isEmpty == false {
            let events = tail.reduce(0) { $0 + $1.eventCount }
            let share = tail.reduce(0) { $0 + $1.relativeShare }
            // 合并段的灰阶位次取 unknown 那一档，与左栏项目卡的贡献条同一口径。
            result.append(ContributionRow(
                id: "merged",
                name: ProjectsCopy.chartOtherAgents.text(language),
                rank: ObservatoryTheme.chartRank(for: .unknown),
                events: events,
                percent: percent(share, of: total)
            ))
        }
        return result
    }

    private func percent(_ share: Double, of total: Double) -> Double {
        min(100, max(0, share / total * 100))
    }

    private var totalEvents: Int {
        contributions.reduce(0) { $0 + $1.eventCount }
    }

    private var resolvedTitle: String {
        title ?? ProjectsCopy.chartTitle.text(language)
    }

    private func resolvedSubtitle(rows: [ContributionRow]) -> String? {
        if let subtitle { return subtitle }
        return rows.isEmpty ? nil
            : ProjectsCopy.chartSubtitleHint.format(language, rows.count, totalEvents)
    }

    private func accessibilitySummary(_ rows: [ContributionRow]) -> String {
        guard !rows.isEmpty else { return ProjectsCopy.shareNoData.text(language) }
        return ProjectsCopy.chartA11yPrefix.text(language) + rows
            .map { ProjectsCopy.chartA11yRow.format(
                language, $0.name, PercentFormat.short($0.percent, fractionDigits: 1), $0.events) }
            .joined(separator: "；")
    }
}

// MARK: - 一行数据

/// 图里一行的预绑定值：身份、名字、序列灰阶位次、事件数与百分比一次算完。
///
/// 声明在文件级而不是 `ProjectContributionChart` 里面：`View` 是 @MainActor 隔离的，
/// 嵌套的辅助类型会连带变成 main-actor 隔离，作为泛型实参传给 `ForEach` 时
/// 会吃到 #SendableMetatypes 那类看不懂的警告（DesignSystem/Panel.swift 里同样搬过一次）。
private struct ContributionRow: Identifiable {
    /// 身份来自 kind 的 rawValue，合并段单独一档：`AgentContribution.id` 是由 kind 推导的
    /// 稳定 UUID，真实存在 `unknown` 贡献时「其他 Agent」合并段就会与它撞成同一个 id。
    let id: String
    let name: String
    let rank: Int
    let events: Int
    /// 0...100，已按总量归一化。
    let percent: Double

    var color: Color { ObservatoryTheme.chartColor(rank: rank) }
    var legendLabel: String {
        ProjectsCopy.chartLegendRow.format(UILanguage.current, name, events,
                                           PercentFormat.short(percent, fractionDigits: 1))
    }
}

// MARK: - Previews

enum ProjectContributionChartPreviewSamples {
    static let mixed: [AgentContribution] = [
        AgentContribution(kind: .claudeCode, relativeShare: 0.46, eventCount: 58),
        AgentContribution(kind: .openAICodex, relativeShare: 0.21, eventCount: 27),
        AgentContribution(kind: .cursorAgent, relativeShare: 0.13, eventCount: 16),
        AgentContribution(kind: .geminiCLI, relativeShare: 0.08, eventCount: 10),
        AgentContribution(kind: .aiderCLI, relativeShare: 0.06, eventCount: 7),
        AgentContribution(kind: .windsurf, relativeShare: 0.04, eventCount: 5),
        AgentContribution(kind: .genericCLIAgent, relativeShare: 0.02, eventCount: 3)
    ]
}

#Preview("ProjectContributionChart") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        ProjectContributionChart(contributions: ProjectContributionChartPreviewSamples.mixed)
        ProjectContributionChart(contributions: Array(ProjectContributionChartPreviewSamples.mixed.prefix(2)))
        ProjectContributionChart(contributions: [])
    }
    .padding(Spacing.lg)
    .frame(width: 520)
    .background(Surface.page)
}
