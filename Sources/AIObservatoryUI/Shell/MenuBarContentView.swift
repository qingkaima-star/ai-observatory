//
//  MenuBarContentView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI → WS-QUIET-3（本轮按 ADR-0007 重排到「quiet」语言）
//  ─────────────────────────────────────────────────────────
//  菜单栏（MenuBarExtra）的 .window 内容视图。
//  MenuBarExtra 只能定义在 Scene 里，因此本视图交由总控在 App 外壳接入：
//      MenuBarExtra { MenuBarContentView(runtime: runtime) } label: { ... }
//      .menuBarExtraStyle(.window)     ← 已核实：是 .window，所以富布局是安全的
//  详见 AiX-Vault/04-决策记录/IFR-ui-menubar.md。
//
//  与主窗口的两点不同，都是刻意的：
//  1. **没有 `.hero`**：这里只有 320pt 宽，四个读数一律 `.compact`（13pt 半粗）。
//     放一个 40pt 的大数会把菜单变成一个告示牌，而且菜单栏面板从来不是「一页」。
//  2. 分隔用 `Hairline()` 而不是 `Divider()`：`Divider` 在 macOS 上是一条带内凹的
//     系统线，在这里它比内容更抢眼；`Hairline` 是 1pt 的 separatorColor，正好低一档。
//

import SwiftUI
import AIObservatoryCore

/// 菜单栏下拉面板内容：引擎状态 + 今日摘要 + 活跃 Agent + 快捷入口。
@MainActor
public struct MenuBarContentView: View {
    private static let visibleAgentLimit = 5

    @State private var model: DashboardModel
    @Environment(\.openWindow) private var openWindow

    public init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: DashboardModel(runtime: runtime))
    }

    public var body: some View {
        let stats = model.stats
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            Hairline()
            MetricGrid(MenuStat.make(from: stats), columns: 2) { item in
                StatTile(
                    title: item.title,
                    value: item.value,
                    caption: item.caption,
                    emphasis: .compact
                )
            }
            Hairline()
            agentList
            Hairline()
            quickActions
            footer
        }
        .padding(Spacing.md)
        .frame(width: 320)
        .task {
            await model.load()
            await model.observeUpdates()
        }
    }

    // MARK: 片段

    /// 引擎状态点：运行状态是**功能色**（`ObservatoryTheme.color(for: EngineState)`），
    /// 所以保留色点；旧版旁边那颗 `Color.accentColor` 的品牌图标不是，删掉。
    private var header: some View {
        HStack(spacing: Spacing.sm) {
            Text(ShellCopy.brandName.text(UILanguage.current))
                .font(.axSection)
                .foregroundStyle(Surface.label)
            Spacer(minLength: Spacing.sm)
            Circle()
                .fill(ObservatoryTheme.color(for: model.engineState))
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
            Text(model.engineState.displayName(UILanguage.current))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
        }
    }

    @ViewBuilder
    private var agentList: some View {
        let language = UILanguage.current
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(ShellCopy.activeAgents.text(language)) {
                if model.activeAgents.count > Self.visibleAgentLimit {
                    Text(ShellCopy.agentTotalCount.format(language, model.activeAgents.count))
                        .font(.axMeta)
                        .monospacedDigit()
                        .axCaptionStyle()   // #99：承载口径，曾在最低档
                }
            }
            if model.activeAgents.isEmpty {
                Text(ShellCopy.noRunningAgents.text(language))
                    .axCaptionStyle()   // #99：口径句提档（原 .axMeta + tertiary）
            } else {
                // 行数量有上限（`visibleAgentLimit`）⇒ 非懒 VStack。
                VStack(alignment: .leading, spacing: Spacing.none) {
                    ForEach(model.activeAgents.prefix(Self.visibleAgentLimit)) { agent in
                        agentRow(agent)
                        Hairline()
                    }
                }
            }
        }
    }

    private func agentRow(_ agent: AgentInstance) -> some View {
        HStack(spacing: Spacing.sm) {
            AgentChip(kind: agent.kind, displayName: agent.displayName, compact: true)
            Spacer(minLength: Spacing.sm)
            Text(PercentFormat.short(agent.cpuPercent))
                .font(.axMetaMono)
                .foregroundStyle(Surface.secondaryLabel)
                .axNumberColumn(Column.percent)
            Text(ByteFormat.humanReadable(agent.memoryBytes))
                .font(.axMetaMono)
                .foregroundStyle(Surface.tertiaryLabel)
                .axNumberColumn(Column.memory)
        }
        .padding(.vertical, Spacing.xs)
        .accessibilityElement(children: .combine)
    }

    private var quickActions: some View {
        let language = UILanguage.current
        return VStack(alignment: .leading, spacing: Spacing.sm) {
            Button {
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            } label: {
                Text(ShellCopy.openMainWindow.text(language))
            }
            Button {
                Task { await model.load() }
            } label: {
                Text(ShellCopy.refreshTodaySummary.text(language))
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
        .font(.axBody)
    }

    private var footer: some View {
        Text(ShellCopy.privacyFooter.text(UILanguage.current))
            .axCaptionStyle()   // #99：口径句提档（原 .axMeta + tertiary）
    }
}

// MARK: - 今日摘要

/// 菜单栏里的一格读数。
///
/// 风险的 caption 说清「高危」是全部风险里的一个子集，
/// 而不是让人自己猜「风险 7 · 高危 2」是不是两个互不相干的数。
private struct MenuStat: Identifiable, Hashable {
    let id: Int
    let title: String
    let value: String
    var caption: String? = nil

    static func make(from stats: DashboardStats, _ language: AppLanguage) -> [MenuStat] {
        [
            MenuStat(id: 0, title: ShellCopy.menuStatSessions.text(language),
                     value: "\(stats.sessionCount)"),
            MenuStat(
                id: 1,
                title: ShellCopy.menuStatFileChanges.text(language),
                value: "\(stats.filesModified + stats.filesCreated)",
                caption: ShellCopy.menuStatFileChangesCaption.format(
                    language, stats.filesModified, stats.filesCreated
                )
            ),
            MenuStat(id: 2, title: ShellCopy.menuStatCommands.text(language),
                     value: "\(stats.commandsExecuted)"),
            MenuStat(
                id: 3,
                title: ShellCopy.menuStatRisks.text(language),
                value: "\(stats.riskEventCount)",
                caption: ShellCopy.menuStatHighRiskCaption.format(language, stats.highRiskEventCount)
            ),
        ]
    }

    /// 按当前语言渲染的展口（调用点只认这一个，语言在 `UILanguage` 一处解析）。
    static func make(from stats: DashboardStats) -> [MenuStat] {
        make(from: stats, UILanguage.current)
    }
}

#Preview("菜单栏") {
    MenuBarContentView(runtime: ObservatoryPreview.runtime())
        .padding(Spacing.md)
}

#Preview("菜单栏 · 空状态") {
    MenuBarContentView(runtime: ObservatoryPreview.emptyRuntime())
        .padding(Spacing.md)
}
