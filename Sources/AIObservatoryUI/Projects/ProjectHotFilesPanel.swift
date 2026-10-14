//
//  ProjectHotFilesPanel.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-UI (subagent J)
//  ─────────────────────────────────────────────────────────
//  热区文件榜：把 ProjectActivity.hotFiles / 跨项目 hottestFiles 渲染成「改动强度」榜单。
//    · score（缺省时退回 changeCount）→ 强度条与排名（纯 SwiftUI，不用 Charts）
//    · +新增 / -删除 用 diff 语义色（`ObservatoryColor.positive` / `.critical`），
//      净增**倾向**不上色：强度条只编码长度，颜色不携带「这个项目是好是坏」的判断
//    · lastTouchedAt 用 ProjectTimeText.since 给相对时间
//    · 敏感路径额外给一枚警示图标（PathHeuristics 判定），颜色是功能色 caution
//  面板只吃值类型，可独立 Preview；数据增量更新由 ProjectsModel 负责（有 40 条硬上限）。
//
//  榜身是 `Panel.recessed`：它永远画在主从区的面板**里面**，再套一层白底面板就是
//  「卡中卡」——层级要靠字号与一级下沉背景差，不是靠第二层容器。
//

import SwiftUI
import AIObservatoryCore

struct ProjectHotFilesPanel: View {

    let heats: [FileHeat]
    /// 标题与空态话术都可以由调用方覆盖；不给就走本页文案表的默认值
    /// （默认值不能写成中文字面量，否则英文态拿到的是 caller 传进来的中文）。
    var title: String? = nil
    var subtitle: String? = nil
    /// 榜单长度上限：默认取全局热点榜口径（ProjectsModel.hottestFileLimit 同为 12）。
    var limit: Int = 12
    var emptyMessage: String? = nil

    private var language: AppLanguage { UILanguage.current }

    /// 排名与强度都用综合分；只有拿不到分数时（旧数据、或上游没接 Insights）才退回原始计数。
    /// 口径抽到 ``HotFileRanking``，那里有「老文件改 40 次不该压过今天改 8 次」的回归用例。
    private var shown: [FileHeat] { HotFileRanking.ranked(heats, limit: limit) }

    private var totalChanges: Int {
        heats.reduce(0) { $0 + $1.changeCount }
    }

    var body: some View {
        Panel.recessed(padding: Spacing.md) {
            // `shown` 绑一次：它每次读都是一次新的排序 + 新数组，
            // 原来每行再各读一次（`intensity(of:ranked:)` 里还要重算榜首权重）。
            let rows = self.shown

            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(resolvedTitle, subtitle: resolvedSubtitle) {
                    Text(ProjectsCopy.totalChangesHint.format(language, totalChanges))
                        .font(.axMeta)
                        .monospacedDigit()
                        .foregroundStyle(Surface.secondaryLabel)
                }

                if rows.isEmpty {
                    EmptyStateView(
                        ProjectsCopy.emptyHotFilesTitle.text(language),
                        systemImage: "doc.badge.gearshape",
                        message: resolvedEmptyMessage,
                        fills: false
                    )
                } else {
                    VStack(alignment: .leading, spacing: Spacing.none) {
                        ForEach(Array(rows.enumerated()), id: \.element.id) { index, heat in
                            heatRow(index: index, heat: heat, ranked: rows)
                        }
                    }
                    if heats.count > rows.count {
                        Text(ProjectsCopy.notInTopHint.format(language, heats.count - rows.count, rows.count))
                            .font(.axMeta)
                            .monospacedDigit()
                            .axCaptionStyle()   // #99：承载口径，曾在最低档
                    }
                }
            }
            .animation(ObservatoryMotion.value, value: rows.count)
        }
    }

    /// 行视图抽成独立 func：`ForEach` 里内联「条件分隔线 + 多段 HStack」这种长表达式
    /// 会把类型检查拖到超时（本仓的图表铁律第 2 条）。
    /// `ranked` 用绑好的那份，绝不在这里再读一次 `shown`。
    private func heatRow(index: Int, heat: FileHeat, ranked: [FileHeat]) -> some View {
        Group {
            if index > 0 { Hairline() }
            ProjectHeatRow(
                rank: index + 1,
                heat: heat,
                intensity: HotFileRanking.intensity(of: heat, ranked: ranked)
            )
        }
    }

    private var resolvedTitle: String {
        title ?? ProjectsCopy.statHotFiles.text(language)
    }

    private var resolvedEmptyMessage: String {
        emptyMessage ?? ProjectsCopy.hotFilesEmptyDefault.text(language)
    }

    private var resolvedSubtitle: String? {
        // 排序口径已经从「改动次数」改成多因子综合分（`HotFileRanking`，
        // 见 04-决策记录/完工审计-八模块覆盖矩阵.md 的 ⑦ 收口），
        // 这句副标题还写着旧的规则——等于把「今天活跃的文件排在 40 天前的老文件前面」
        // 这个真实行为说成按次数排，用户会以为榜单出错。
        subtitle ?? ProjectsCopy.hotFilesSortSubtitle.text(language)
    }
}

// MARK: - 单行

/// 热区文件的一行：排名 + 文件名/路径 + 强度条 + 增删行数 + 最后改动时间。
/// 行视图必须是独立 struct：`List`/`ForEach` 里内联这种多段 HStack 会让类型检查超时。
private struct ProjectHeatRow: View {

    let rank: Int
    let heat: FileHeat
    /// #89：与 `ProjectCard` 同族——行内路径给了 `FilePathText`，读屏那句是自己拼的。
    @Environment(\.demoRedaction) private var demoRedaction
    /// 0...1，相对榜首的改动强度。
    let intensity: Double

    private var language: AppLanguage { UILanguage.current }

    private static let intensityBarHeight: CGFloat = 4
    /// #83：档位在 `Column` 里，这里只留本页的语义别名（改前是写死的 20）。
    private static let rankColumnWidth: CGFloat = Column.rank
    private static let deltaColumnWidth: CGFloat = Column.delta

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.sm) {
            Text("\(rank)")
                .font(.axMeta)
                .axNumberColumn(Self.rankColumnWidth)
                .foregroundStyle(Surface.tertiaryLabel)
                .padding(.top, Spacing.xs)
                .accessibilityLabel(ProjectsCopy.rankLabel.format(language, rank))

            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(spacing: Spacing.sm) {
                    Text(heat.fileName)
                        .font(.axSection)
                        .foregroundStyle(Surface.label)
                        .lineLimit(1)
                        .truncationMode(.middle)

                    if PathHeuristics.isSensitive(heat.path) {
                        Image(systemName: "lock.open.trianglebadge.exclamationmark")
                            .font(.axMeta)
                            .foregroundStyle(ObservatoryColor.caution)
                            .accessibilityLabel(ProjectsCopy.sensitivePath.text(language))
                    }

                    Spacer(minLength: Spacing.sm)

                    deltaText
                }

                FilePathText(path: heat.path, mode: .lastTwoComponents)
                    .foregroundStyle(Surface.tertiaryLabel)

                HStack(spacing: Spacing.xs) {
                    intensityBar
                    Text(ProjectsCopy.countedTimes(heat.changeCount, language))
                        .font(.axMeta)
                        .monospacedDigit()
                        .axCaptionStyle()   // #99：口径句提档
                        .fixedSize()
                    Text(ProjectTimeText.since(heat.lastTouchedAt))
                        .font(.axMeta)
                        .monospacedDigit()
                        .foregroundStyle(Surface.tertiaryLabel)
                        .fixedSize()
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, Spacing.sm)
        .frame(minHeight: Sizing.rowMinHeight, alignment: .top)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// 增删行数：diff 的「新增绿 / 删除红」是全应用保留的三处彩色之一（契约 §2）。
    private var deltaText: some View {
        HStack(spacing: Spacing.xs) {
            if heat.linesAdded > 0 {
                Text("+\(heat.linesAdded)")
                    .foregroundStyle(ObservatoryColor.positive)
            }
            if heat.linesRemoved > 0 {
                Text("-\(heat.linesRemoved)")
                    .foregroundStyle(ObservatoryColor.critical)
            }
            if heat.linesAdded == 0, heat.linesRemoved == 0 {
                Text("—")
                    .foregroundStyle(Surface.tertiaryLabel)
            }
        }
        .font(.axMeta)
        .axNumberColumn(Self.deltaColumnWidth)
        .accessibilityLabel(ProjectsCopy.deltaLinesA11y.format(
            language, heat.linesAdded, heat.linesRemoved))
    }

    /// 强度条：`Surface.recessed` 底槽 + 按比例填充的圆角条。
    ///
    /// 填充色是有序灰阶里的一档，**不再随净增/净删染成绿或红**：
    /// 「删得比加多」在这个面板里只说明改动方向，不说明好坏，
    /// 而条的长度已经在回答「哪个文件最活跃」。
    private var intensityBar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: ObservatoryRadius.tag, style: .continuous)
                    .fill(Surface.recessed)
                RoundedRectangle(cornerRadius: ObservatoryRadius.tag, style: .continuous)
                    .fill(ObservatoryChart.color(rank: 1))
                    .frame(width: max(2, proxy.size.width * min(1, max(0, intensity))))
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: Self.intensityBarHeight)
        .accessibilityHidden(true)
    }

    private var accessibilitySummary: String {
        demoRedaction.scrub(ProjectsCopy.heatA11ySummary.format(
            language,
            rank,
            heat.path,
            heat.changeCount,
            heat.linesAdded,
            heat.linesRemoved,
            ProjectTimeText.since(heat.lastTouchedAt)
        ))
    }
}

// MARK: - Previews

enum ProjectHotFilesPanelPreviewSamples {
    static let heats: [FileHeat] = [
        FileHeat(path: "/Users/demo/Projects/Mona/Sources/AIObservatoryUI/Dashboard/DashboardView.swift",
                 changeCount: 24, linesAdded: 612, linesRemoved: 188,
                 lastTouchedAt: Date(timeIntervalSince1970: 1_700_086_400)),
        FileHeat(path: "/Users/demo/Projects/Mona/Sources/AIObservatoryEngine/Orchestrator.swift",
                 changeCount: 15, linesAdded: 240, linesRemoved: 512,
                 lastTouchedAt: Date(timeIntervalSince1970: 1_700_082_800)),
        FileHeat(path: "/Users/demo/.ssh/config",
                 changeCount: 6, linesAdded: 6, linesRemoved: 0,
                 lastTouchedAt: Date(timeIntervalSince1970: 1_700_070_000)),
        FileHeat(path: "/Users/demo/Projects/Mona/Package.swift",
                 changeCount: 2, linesAdded: 0, linesRemoved: 0,
                 lastTouchedAt: Date(timeIntervalSince1970: 1_700_000_000))
    ]
}

#Preview("ProjectHotFilesPanel") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        ProjectHotFilesPanel(heats: ProjectHotFilesPanelPreviewSamples.heats, limit: 3)
        ProjectHotFilesPanel(heats: [])
    }
    .padding(Spacing.lg)
    .frame(width: 520)
    .background(Surface.page)
}
