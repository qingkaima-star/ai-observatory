//
//  ProjectDetailView.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-UI (subagent J)
//  ─────────────────────────────────────────────────────────
//  主从区右列的详情面板：一个项目的完整 AI 活动画像（「quiet」语言）。
//    头部（名称 / 路径 / 口径字段 / 跳转与刷新）
//    → 四格指标 MetricGrid → 净增代码等降级字段行 → 健康度行（分析层）
//    → ProjectContributionChart → ProjectHotFilesPanel → 最近变更列表。
//  数据来源全部走 ProjectsModel 已有 API：detail（projectActivity 查询）+ recentChanges
//  （fileChanges 查询）+ health（runtime.analysis，Core 值类型）+ 实时增量后的 projects。
//  视图层不直接碰 service，也不依赖 AIObservatoryInsights。
//
//  三处改版要点：
//    · 原来那组「自适应 `GridItem` + minimum 152」的瓷贴阵列删了 —— 自适应列在宽栏里一行塞 5 个、
//      第 6 个挂在下一行，就是「不规整」。现在四格一行填满，第五格（净增代码）降级成字段行。
//    · **这里没有 `.hero`**：本页唯一的 40pt 数在页面指标区（可见项目数），详情四格全是 22pt。
//    · 外壳不再自己铺一层 3% 的自造灰底（那种灰在深色下发脏）：主从区已经是一个 Panel，
//      内部块用 `Panel.recessed` 沉一级，白底叠白底那种「卡中卡」不表达层级。
//  板块数量恒定 ⇒ 用非懒 `VStack`（懒容器在这里省不到东西，却会在滚动时反复回收卡片）。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor
struct ProjectDetailView: View {

    @Bindable private var model: ProjectsModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(model: ProjectsModel) {
        self._model = Bindable(model)
    }

    private var language: AppLanguage { UILanguage.current }

    // MARK: - Body

    var body: some View {
        // 绑一次再下传：`selectedProject` / `recentChanges` 都是每次读就换身份的派生值，
        // 而下面这些板块会被同一个 body 读两三遍。
        let project = model.selectedProject
        let changes = model.recentChanges

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                if let project {
                    header(project)
                    statusStrips
                    metricGrid(project)
                    ProjectHealthCard(state: model.healthState, isLoading: model.isLoadingHealth)
                    ProjectContributionChart(
                        contributions: project.agentContributions,
                        subtitle: ProjectsCopy.detailChartSubtitle.format(
                            language, model.timeRange.displayName(language))
                    )
                    ProjectHotFilesPanel(
                        heats: project.hotFiles,
                        title: ProjectsCopy.detailHotFilesTitle.text(language),
                        emptyMessage: ProjectsCopy.detailHotFilesEmpty.text(language)
                    )
                    recentChangesCard(changes)
                } else {
                    emptyDetail
                }
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 头部

    private func header(_ project: ProjectActivity) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(project.name, subtitle: ProjectsCopy.detailMapSubtitle.text(language)) {
                HStack(spacing: Spacing.sm) {
                    if model.liveTouchedPaths.contains(project.path) {
                        Tag(ProjectsCopy.liveTag.text(language), tone: .positive)
                    }
                    Button {
                        Task {
                            await model.loadDetail()
                            await model.loadRecentChanges()
                            await model.loadHealth()
                        }
                    } label: {
                        if model.isLoadingDetail || model.isLoadingChanges || model.isLoadingHealth {
                            ProgressView().controlSize(.small)
                        } else {
                            Label(ProjectsCopy.reaggregate.text(language), systemImage: "arrow.clockwise")
                        }
                    }
                    .controlSize(.small)
                }
            }

            FilePathText(path: project.path, mode: .middleEllipsis)
                .frame(maxWidth: .infinity, alignment: .leading)

            // 口径字段一律走 InlineStat：标签 11pt 次级色、值 11pt 等宽右对齐，
            // 一行一个字段，不为了「省高度」把三个字段挤在同一行里互相抢宽度。
            VStack(alignment: .leading, spacing: Spacing.xs) {
                InlineStat(ProjectsCopy.timeRange.text(language), value: model.timeRange.displayName(language))
                InlineStat(ProjectsCopy.fieldActivitySpan.text(language),
                           value: ProjectTimeText.span(from: project.firstSeenAt, to: project.lastSeenAt))
                InlineStat(ProjectsCopy.fieldLastActivity.text(language),
                           value: ProjectTimeText.since(project.lastSeenAt))
                InlineStat(ProjectsCopy.fieldActivityWindow.text(language),
                           value: "\(ProjectTimeText.absolute(project.firstSeenAt)) → \(ProjectTimeText.absolute(project.lastSeenAt))")
            }

            HStack(spacing: Spacing.sm) {
                // #81：这两颗按钮原来**只**改 `shell.selection` ⇒ 跳过去看到的是全量列表，
                // 而用户读成「这个项目的文件/事件」。现在走 `shell.jump(...)`：
                // 项目路径与本页口径行刚显示的那个时间区间一起带过去，
                // 目的地板块在第一次取数之前把它们落进自己那条 `*Query`。
                Button {
                    shell?.jump(JumpIntent(target: .files,
                                           projectPath: project.path,
                                           timeRange: model.timeRange))
                } label: {
                    Label(ProjectsCopy.jumpToFiles.text(language), systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                .disabled(model.canJumpToFileBoard == false)

                Button {
                    shell?.jump(JumpIntent(target: .timeline,
                                           projectPath: project.path,
                                           timeRange: model.timeRange))
                } label: {
                    Label(ProjectsCopy.jumpToTimeline.text(language), systemImage: "clock.arrow.circlepath")
                }
                .controlSize(.small)

                Button {
                    model.clearSelection()
                } label: {
                    Label(ProjectsCopy.clearSelection.text(language), systemImage: "xmark")
                }
                .controlSize(.small)

                Spacer(minLength: Spacing.none)
            }
        }
    }

    // MARK: - 加载 / 错误提示条

    @ViewBuilder private var statusStrips: some View {
        if model.isLoadingDetail {
            Panel.recessed(padding: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(ProjectsCopy.reaggregatingHint.format(language, model.timeRange.displayName(language)))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                    Spacer(minLength: Spacing.none)
                }
            }
        }
        if let message = model.errorMessage {
            Panel.recessed(padding: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    Text(ProjectsCopy.readFailedShort.text(language))
                        .font(.axSection)
                        .foregroundStyle(Surface.label)
                    Text(message)
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .textSelection(.enabled)
                    Spacer(minLength: Spacing.sm)
                    Button(ProjectsCopy.retry.text(language)) {
                        Task {
                            await model.load()
                            await model.loadDetail()
                            await model.loadRecentChanges()
                        }
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: - 指标

    /// 四格一行填满（`MetricGrid` 是**非懒** Grid，末行用空格补齐以保持列对齐）。
    ///
    /// 为什么只有四格：第五格「净增代码」如果留下来，一行 5 个在 3 列/4 列下都会落单，
    /// 而且净增行数不是「要不要继续看这个项目」的判据 —— 降级成下面的字段行，
    /// 并且只写带符号的数字（净增不携带好坏判断，上色就是假信号）。
    ///
    /// 这里刻意**不再套一层 Panel**：`StatTile` 自身不带容器，而本面板已经坐在
    /// 主从区那块白底面板里，再铺一层白底面板是「卡中卡」，不表达任何层级。
    private func metricGrid(_ project: ProjectActivity) -> some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            MetricGrid(detailTiles(project), columns: Sizing.metricColumns) { tile in
                StatTile(
                    title: tile.title,
                    value: tile.value,
                    unit: tile.unit,
                    caption: tile.caption,
                    emphasis: tile.emphasis,
                    action: tile.action
                )
            }
            Hairline()
            InlineStat(ProjectsCopy.netCode.text(language),
                       value: ProjectDeltaText.detailed(added: project.codeGrowthLines,
                                                        removed: project.codeShrinkLines,
                                                        language))
            InlineStat(ProjectsCopy.statHotFiles.text(language),
                       value: ProjectsCopy.countedItems(project.hotFiles.count, language))
        }
    }

    private func detailTiles(_ project: ProjectActivity) -> [ProjectDetailTile] {
        [
            ProjectDetailTile(
                id: 0,
                title: ProjectsCopy.tileFileChanges.text(language),
                value: "\(project.fileChangeCount)",
                unit: ProjectsCopy.unitTimes(language),
                caption: ProjectsCopy.detailFileChangesCaption.format(
                    language, model.timeRange.displayName(language)),
                emphasis: .metric
            ),
            ProjectDetailTile(
                id: 1,
                title: ProjectsCopy.tileCommands.text(language),
                value: "\(project.commandCount)",
                unit: ProjectsCopy.unitTimes(language),
                caption: ProjectsCopy.detailCommandsCaption.text(language),
                emphasis: .metric
            ),
            ProjectDetailTile(
                id: 2,
                title: ProjectsCopy.tileSessions.text(language),
                value: "\(project.sessionCount)",
                unit: ProjectsCopy.unitProjects(language),
                caption: ProjectsCopy.detailSessionsCaption.format(
                    language, ProjectTimeText.span(from: project.firstSeenAt, to: project.lastSeenAt)),
                emphasis: .metric
            ),
            ProjectDetailTile(
                id: 3,
                title: ProjectsCopy.tileRiskEvents.text(language),
                value: "\(project.riskEventCount)",
                unit: ProjectsCopy.unitRisks(language),
                caption: project.riskEventCount > 0 ? ProjectsCopy.riskCaptionSome.text(language)
                                                    : ProjectsCopy.riskCaptionNone.text(language),
                emphasis: .metric,
                action: { shell?.selection = .security }
            ),
        ]
    }

    // MARK: - 最近变更

    /// `changes` 由 body 绑好后传进来，不在这里重读 `model.recentChanges`。
    private func recentChangesCard(_ changes: [FileChange]) -> some View {
        Panel.recessed(padding: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    ProjectsCopy.recentChangesTitle.text(language),
                    subtitle: ProjectsCopy.recentChangesSubtitle.text(language)) {
                    Text(ProjectsCopy.countedRows(changes.count, language))
                        .font(.axMeta)
                        .monospacedDigit()
                        .foregroundStyle(Surface.secondaryLabel)
                }

                if model.isLoadingChanges {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(ProjectsCopy.loadingChanges.text(language))
                            .font(.axMeta)
                            .foregroundStyle(Surface.secondaryLabel)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, Spacing.sm)
                } else if changes.isEmpty {
                    EmptyStateView(
                        ProjectsCopy.emptyChangesTitle.text(language),
                        systemImage: "magnifyingglass",
                        message: ProjectsCopy.emptyChangesMessage.text(language),
                        fills: false
                    ) {
                        Button(ProjectsCopy.resetFilters.text(language)) {
                            Task { await model.resetFilters() }
                        }
                    }
                } else {
                    VStack(alignment: .leading, spacing: Spacing.none) {
                        ForEach(Array(changes.enumerated()), id: \.element.id) { index, change in
                            changeRow(index: index, change: change)
                        }
                    }
                    if model.hasMoreChanges {
                        Text(ProjectsCopy.hitFetchCapNote.text(language))
                            .axCaptionStyle()   // #99：这句承载口径，曾在最低档（≈1.8:1）
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.top, Spacing.xs)
                    }
                }
            }
        }
    }

    /// 行视图抽成独立 func：`ForEach` 里内联「条件分隔线 + 行」是把类型检查拖爆的老写法。
    private func changeRow(index: Int, change: FileChange) -> some View {
        Group {
            if index > 0 { Hairline() }
            FileChangeRow(change: change)
        }
    }

    // MARK: - 空详情

    private var emptyDetail: some View {
        Panel {
            EmptyStateView(
                model.projects.isEmpty ? ProjectsCopy.emptyNoMapTitle.text(language)
                                       : ProjectsCopy.emptyUnselectedTitle.text(language),
                systemImage: "square.stack.3d.up",
                message: model.projects.isEmpty
                    ? ProjectsCopy.emptyNoMapMessage.text(language)
                    : ProjectsCopy.emptyUnselectedMessage.text(language),
                fills: false
            ) {
                if model.projects.isEmpty {
                    Button(ProjectsCopy.rescan.text(language)) {
                        guard let shell else { return }
                        Task { await shell.rescan() }
                    }
                }
            }
        }
    }
}

/// 详情指标区的一格。与页面级 `ProjectTile` 各自私有：两处读的字段集合不同
/// （这里全是单项目口径，那里是可见项目的合计），合并成一个类型只会让两边互相迁就。
private struct ProjectDetailTile: Identifiable {
    let id: Int
    let title: String
    let value: String
    var unit: String = ""
    let caption: String?
    let emphasis: StatTile.Emphasis
    var action: (() -> Void)? = nil
}

// MARK: - Preview

/// 独立预览用宿主：真实入口是 ProjectsView 主从区右列，这里单独挂一个详情面板。
@MainActor
private struct ProjectDetailViewPreviewHost: View {

    @State private var model: ProjectsModel

    init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: ProjectsModel(runtime: runtime))
    }

    var body: some View {
        ProjectDetailView(model: model)
            .task {
                await model.load()
                if let first = model.sortedProjects.first {
                    await model.select(path: first.path)
                }
            }
    }
}

#Preview("ProjectDetailView") {
    ObservatoryPreview.screen { runtime in
        ProjectDetailViewPreviewHost(runtime: runtime)
    }
}
