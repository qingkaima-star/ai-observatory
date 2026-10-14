//
//  ProjectsView.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-UI (subagent J)
//  ─────────────────────────────────────────────────────────
//  需求模块⑦「项目级 AI 活动地图」入口视图，设计语言「quiet」。
//
//  页面骨架（外层唯一容器是 `ObservatoryPage`：页面底 + 1120 收口 + 32 边距 + 标题）：
//    ① 指标区  Panel { MetricGrid(4) } —— 本页唯一的 `.hero` 是「可见项目数」
//    ② 过滤条  Panel { 非懒 VStack }   —— 时间范围 / Agent 多选 / 排序 / 搜索 / 重置
//    ③ 主从区  Panel(padding: sm) { 项目列表 | Hairline(vertical) | 详情列 }
//      · 选中项目 → ProjectDetailView；未选中 → 跨项目总览（贡献图 + 全局热点榜）。
//        这条分支判据（`model.selectedProject != nil`）与改版前逐字一致。
//
//  删掉的旧结构（都是「不规整 / 拥挤」的直接来源）：
//    · 外层的「过滤条 + 分隔线 + GeometryReader 双栏 + 分隔线 + 底部状态条」：
//      `ObservatoryPage` 的 content 已经在 `ScrollView` 里，`GeometryReader` 的高度会塌成 0，
//      列宽改由 `minWidth/idealWidth/maxWidth` 表达；底部状态条与那两条分隔线一并删除，
//      那些读数已经上移到指标区与它的 `InlineStat` 行，不必再在页面最底下报第二遍。
//    · 总览区那个「自适应 `GridItem` + minimum 168」的瓷贴阵列 —— 换成 MetricGrid（见①）。
//
//  实时更新：model.observeUpdates() 内部只吃 .fileChange/.command/.sessions/.risk 做本地累加，
//  视图不重查全库；搜索与 Agent 变化只补拉详情面板的「最近变更」。两条 .task(id:) 语义未动。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor
struct ProjectsView: View {

    @State private var model: ProjectsModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: ProjectsModel(runtime: runtime))
    }

    /// 首次进入时不重复触发过滤补拉（load 链路已经查过一次详情）。
    @State private var filtersInitialized = false

    /// 主从区一块的有界高度：左列表与右详情各自内部滚动，整块不跟着页面一起长。
    private static let detailMinHeight: CGFloat = 560
    private static let detailMaxHeight: CGFloat = 660
    /// 左列宽度区间（列宽，不是 padding）：窄到读不出项目名之前停下，宽到把详情挤瘦之前收口。
    private static let listMinWidth: CGFloat = 280
    private static let listIdealWidth: CGFloat = 360
    private static let listMaxWidth: CGFloat = 440

    // MARK: - 时间范围与过滤签名

    /// 生效范围：优先跟随 Shell 顶栏，取不到环境时退回模型本地值。
    private var effectiveRange: ObservatoryTimeRange {
        shell?.timeRange ?? model.timeRange
    }

    /// 搜索 + Agent 过滤的签名：只有它变化才补拉「最近变更」（时间范围走主加载链路）。
    private var filterSignature: String {
        let kinds = model.selectedKinds.map(\.rawValue).sorted().joined(separator: ",")
        return "\(model.searchText)|\(kinds)"
    }

    /// 标题下的口径行：**可见 / 全量两个数一起报**——前者过了搜索与 Agent 条件，
    /// 后者只是当前时间范围拉回的项目数，只报一个必然让人以为「项目丢了」。
    private var language: AppLanguage { UILanguage.current }

    private var pageSubtitle: String {
        ProjectsCopy.pageSubtitle.format(
            language, model.timeRange.displayName(language),
            model.filteredProjects.count, model.projects.count
        )
    }

    // MARK: - Body

    var body: some View {
        ObservatoryPage(SidebarSection.projects.title, subtitle: pageSubtitle) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            if let date = model.latestActivityAt {
                InlineStat(ProjectsCopy.statLatestActivity.text(language), value: ProjectTimeText.since(date))
                    .fixedSize()
            }
        } content: {
            pageContent
        }
        .task(id: effectiveRange) {
            if model.timeRange != effectiveRange { model.timeRange = effectiveRange }
            // #74 ①：进这一页时先把侧栏词落到 `model.searchText`，再走本页那条加载链路——
            // 顺序很重要：`load()` 末尾的 `ensureSelection()` → `loadRecentChanges()` 用的
            // 就是这个词（它进的是真 `FileChangeQuery`），先播种才不必为它再补一次取数。
            SidebarSearchWiring.seed(fromShell: shell, into: model)
            // #81 ①：这一格的时间区间落在 `model.timeRange`（它下面那两条真查询
            // `projectActivity(path:dateRange:)` 与「最近变更」的 `FileChangeQuery` 都读它）。
            let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
            await model.load()
            // #81 ①b：项目条件在这一格=选中那个项目，走本页既有的 `select(path:)`，
            // 详情与「最近变更」因此只各取一次（`load()` 末尾的 `ensureSelection()`
            // 认这份选中，不会另挑一条）。
            await EvidenceJumpWiring.focus(jumped, into: model)
            await model.observeUpdates()
        }
        .task(id: filterSignature) {
            if filtersInitialized {
                try? await Task.sleep(for: SidebarSearchWiring.debounce)
                guard !Task.isCancelled else { return }
                await model.loadDetail()
                await model.loadRecentChanges()
            } else {
                filtersInitialized = true
            }
        }
        // #74 ②：侧栏改词 ⇒ 防抖后交给这一页。项目名列表这一格是**本地过滤**
        // （`projects()` 没有查询参数，见 `SidebarSearchWiring` 文件底部），
        // 落进 `model.searchText` 之后：列表由 `passesFilters(_:)` 收窄，
        // 「最近变更」那一路则由下面那条 `filterSignature` 任务带着词重取。
        // 不在此处直接调 `load()`：全量重拉项目地图换不来任何正确性，只多一条查询。
        .task(id: shell?.searchText) {
            await SidebarSearchWiring.push(fromShell: shell, into: model)
        }
        // #81 ②：已经停在本页时又来了一条跳转意图 ⇒ 时间区间/选中项目落进去并重取
        // （条件与本页已生效的那一份相等时一条查询都不发，判定在桥里）。
        .task(id: shell?.pendingJump) {
            await EvidenceJumpWiring.push(fromShell: shell, into: model)
        }
        // #74 ③：本页搜索框改词 ⇒ 侧栏显示同一个词（这一格的框直接绑在 `model.searchText` 上）。
        .onChange(of: model.searchText) { _, term in
            SidebarSearchWiring.pull(queryTerm: term, into: shell)
        }
        .refreshable {
            await model.load()
            await model.loadDetail()
            await model.loadRecentChanges()
        }
        .accessibilityLabel(SidebarSection.projects.title)
    }

    // MARK: - 分段（四态 + 正文）

    /// 判定顺序与改版前逐字一致：加载 → 错误 → 真没数据 → 被筛空 → 正文。
    /// 区别只在「正文之前不再画过滤条」：过滤条挪进正文分支，被筛空时它仍然在，
    /// 用户才有条可改——空态文案里那句「重置过滤条件」就是给它用的。
    @ViewBuilder private var pageContent: some View {
        // #81：这一屏带着跳转条件 ⇒ 必须说出来。放在四态判定**之前**：
        // 「被筛空」那一态最需要这句话（不然它读起来像这台机器没有变更）。
        EvidenceJumpChip(conditions: model.carriedJumpConditions) {
            await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        }
        if model.isLoading && !model.hasProjectsIgnoringFilters {
            loadingPanel
        } else if let message = model.errorMessage, !model.hasProjectsIgnoringFilters {
            errorPanel(message)
        } else if !model.hasProjectsIgnoringFilters {
            emptyPanel
        } else {
            metricsPanel
            ProjectsFilterBar(model: model)
            if model.hasContent {
                masterDetailPanel
            } else {
                filteredOutPanel
            }
        }
    }

    // MARK: - ① 指标区

    /// 指标区：四格一行填满 + 一条 `Hairline` + 一行降级字段。
    private var metricsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.md) {
                MetricGrid(tiles, columns: Sizing.metricColumns) { tile in
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
                summaryRow
            }
        }
    }

    /// 指标区四格。第一格是本页**唯一**的 `.hero`。
    ///
    /// 为什么 hero 是「可见项目数」：本页是一张「哪些项目被 AI 动过」的地图，
    /// 决定用户要不要继续往下钻的第一数就是**项目数**——文件变更 / 命令 / 会话都是
    /// 点进某个项目之后才需要看的细节，把它们摆成 40pt 会把「地图」读成「计数器」。
    ///
    /// caption 必须诚实写「共 N 个 · <时间范围>」：大数是**过滤后可见数**，
    /// caption 里的是**本次拉回的全量数**，两个数口径不同。本仓在 Dashboard 踩过
    /// 「大数与说明口径互相矛盾、用户以为观测器坏了」的前科，所以口径差写出来而不是让读者推。
    private var tiles: [ProjectTile] {
        [
            ProjectTile(
                id: 0,
                title: ProjectsCopy.tileVisibleProjects.text(language),
                value: "\(model.filteredProjects.count)",
                unit: ProjectsCopy.unitProjects(language),
                caption: ProjectsCopy.tileVisibleProjectsCaption.text(language),
                emphasis: .hero
            ),
            ProjectTile(
                id: 1,
                title: ProjectsCopy.tileFileChanges.text(language),
                value: "\(model.totalFileChanges)",
                unit: ProjectsCopy.unitTimes(language),
                caption: ProjectsCopy.tileFileChangesCaption.format(language, model.distinctHotFileCount),
                emphasis: .metric
            ),
            ProjectTile(
                id: 2,
                title: ProjectsCopy.tileCommands.text(language),
                value: "\(model.totalCommands)",
                unit: ProjectsCopy.unitTimes(language),
                caption: ProjectsCopy.tileCommandsCaption.text(language),
                emphasis: .metric
            ),
            ProjectTile(
                id: 3,
                title: ProjectsCopy.tileSessions.text(language),
                value: "\(model.totalSessions)",
                unit: ProjectsCopy.unitProjects(language),
                caption: ProjectsCopy.tileSessionsCaption.format(
                    language, model.busiestProject?.name ?? "—"),
                emphasis: .metric
            ),
        ]
    }

    /// 凑不满一行、但删掉就丢信息的读数降级成字段行：净增代码 / 实时命中 / 风险。
    ///
    /// 净增行**不上色**：涨跌算不算好事取决于指标语义（契约 §2 明令趋势不上色），
    /// 这里只报带符号的数字与两个分项。风险这一档是功能色，允许保留颜色。
    private var summaryRow: some View {
        HStack(spacing: Spacing.lg) {
            InlineStat(ProjectsCopy.netCode.text(language),
                       value: ProjectDeltaText.detailed(added: model.totalCodeAdded,
                                                        removed: model.totalCodeRemoved,
                                                        language))
            InlineStat(ProjectsCopy.statLiveHits.text(language),
                       value: model.hasLiveActivity
                           ? ProjectsCopy.liveHitValue.format(language, model.liveProjectCount)
                           : ProjectsCopy.liveHitNone.text(language))
            Spacer(minLength: Spacing.md)
            if model.totalRisks > 0 {
                Tag(ProjectsCopy.riskTag.format(language, model.totalRisks, model.riskProjectCount),
                    tone: ObservatoryTheme.tone(for: .high))
            }
        }
    }

    // MARK: - ③ 主从区

    /// 左列表 + 竖线 + 右详情。整块给一个有界高度，两侧各自内部滚动，
    /// 页面滚动条不会因为某个项目热区文件多就抖一下。
    private var masterDetailPanel: some View {
        Panel(padding: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                projectList
                    .frame(minWidth: Self.listMinWidth,
                           idealWidth: Self.listIdealWidth,
                           maxWidth: Self.listMaxWidth)
                Hairline(vertical: true)
                detailColumn
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: Self.detailMinHeight, maxHeight: Self.detailMaxHeight)
        }
    }

    /// 左列：行与行之间只有一根 `Hairline`，没有卡框（卡片本体见 `ProjectCard`）。
    /// 行视图是独立 struct，不在这里内联 —— 内联长表达式会把类型检查拖爆。
    private var projectList: some View {
        // 整列的路径标签**一次算好**：每行各算一遍就是 O(行数²)，而这一列没有上限。
        let labels = ProjectPathLabels.labels(for: model.sortedProjects.map(\.path))
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.none) {
                // 项目数量没有上限，这一列才用懒容器；过滤条与总览里的板块数量恒定，用非懒。
                ForEach(Array(model.sortedProjects.enumerated()), id: \.element.id) { index, project in
                    projectRow(index: index, project: project, pathLabel: labels[project.path])
                }
                if model.isLoadingDetail {
                    detailLoadingRow
                }
            }
            .padding(.horizontal, Spacing.sm)
        }
        .animation(ObservatoryMotion.value, value: model.sortedProjects.count)
    }

    private func projectRow(index: Int, project: ProjectActivity, pathLabel: String?) -> some View {
        Group {
            if index > 0 { Hairline() }
            ProjectCard(
                project: project,
                pathLabel: pathLabel,
                isSelected: model.selectedPath == project.path,
                showsLiveActivity: model.liveTouchedPaths.contains(project.path)
            ) {
                Task { await model.select(path: project.path) }
            }
        }
    }

    private var detailLoadingRow: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(ProjectsCopy.loadingDetailRow.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            Spacer(minLength: Spacing.none)
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var detailColumn: some View {
        if model.selectedProject != nil {
            ProjectDetailView(model: model)
        } else {
            overviewPanel
        }
    }

    /// 未选中项目 → 跨项目总览。
    ///
    /// 单独成 property 只为一件事：**数组在这里各读一次、绑成常量再下传**。
    /// `aggregateContributions` / `hottestFiles` 都是 `filteredProjects` 上的派生值，
    /// 每次读都是新数组身份；子视图再各读两遍，Charts 的内部状态就会跟着身份漂移（RSS 只增不减）。
    private var overviewPanel: some View {
        let contributions = model.aggregateContributions
        let heats = model.hottestFiles
        return ProjectOverviewPanel(contributions: contributions, heats: heats)
    }

    // MARK: - 加载 / 空 / 被筛空 / 错误

    private var loadingPanel: some View {
        Panel {
            HStack(spacing: Spacing.md) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(ProjectsCopy.loadingAggregating.text(language))
                        .font(.axBody)
                        .foregroundStyle(Surface.label)
                    Text(ProjectsCopy.loadingFirstHint.format(language, model.timeRange.displayName(language)))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                }
                Spacer(minLength: Spacing.none)
            }
        }
    }

    private var emptyPanel: some View {
        Panel {
            EmptyStateView(
                ProjectsCopy.emptyNoActivityTitle.text(language),
                systemImage: "square.stack.3d.up",
                message: ProjectsCopy.emptyNoActivityMessage.text(language),
                fills: false
            ) {
                Button(ProjectsCopy.rescan.text(language)) {
                    if let shell {
                        Task { await shell.rescan() }
                    }
                }
            }
        }
    }

    private var filteredOutPanel: some View {
        Panel {
            EmptyStateView(
                ProjectsCopy.emptyFilteredTitle.text(language),
                systemImage: "line.3.horizontal.decrease.circle",
                message: ProjectsCopy.emptyFilteredMessage.format(language, model.projects.count),
                fills: false
            ) {
                Button(ProjectsCopy.resetFilters.text(language)) {
                    Task { await model.resetFilters() }
                }
            }
        }
    }

    /// 错误态不摆 34pt 大图标、不涂橙色：读取失败是「这一页没有可信数字」，
    /// 不是「有危险」——把错误画成告警反而稀释了真正的风险色。
    private func errorPanel(_ message: String) -> some View {
        Panel {
            SectionHeader(ProjectsCopy.readFailedTitle.text(language), subtitle: message) {
                Button(ProjectsCopy.retry.text(language)) {
                    Task { await model.load() }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - 指标区的一格

/// 指标区的一格（值类型）。`MetricGrid` 要 `Identifiable` 的数据，所以把读数收成值，
/// 布局与取数就此分开——原来四个 `StatTile` 直接摊在 `LazyVGrid` 里，
/// 谁该大谁该小完全看不出来。
private struct ProjectTile: Identifiable {
    let id: Int
    let title: String
    let value: String
    var unit: String = ""
    let caption: String?
    let emphasis: StatTile.Emphasis
    var action: (() -> Void)? = nil
}

// MARK: - 跨项目总览

/// 未选中项目时右列的跨项目总览：贡献图 + 全局热点榜。
///
/// 用非懒 `VStack`：板块数量恒定为 3（小节头 / 贡献图 / 热点榜），
/// 懒容器在这里省不到东西，却会在滚动时反复回收卡片。
/// 页面级指标（文件变更 / 命令 / 会话 / 风险）不在这里重复一遍——它们在①指标区。
@MainActor
private struct ProjectOverviewPanel: View {

    /// 由父视图绑好一次再传下来的数组。
    let contributions: [AgentContribution]
    let heats: [FileHeat]

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionHeader(
                    ProjectsCopy.overviewTitle.text(language),
                    subtitle: ProjectsCopy.overviewSubtitle.text(language))
                ProjectContributionChart(
                    contributions: contributions,
                    title: ProjectsCopy.overviewChartTitle.text(language),
                    subtitle: ProjectsCopy.overviewChartSubtitle.text(language)
                )
                ProjectHotFilesPanel(
                    heats: heats,
                    title: ProjectsCopy.globalHotFilesTitle.text(language),
                    subtitle: ProjectsCopy.globalHotFilesSubtitle.text(language),
                    emptyMessage: ProjectsCopy.globalHotFilesEmpty.text(language)
                )
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - ② 过滤条

/// Projects 过滤条：时间范围 / Agent 多选 / 排序 / 搜索 / 重置，功能与改版前一致。
/// 时间范围优先写回 Shell 顶栏（全局口径），没有 Shell 时直接落到模型并显式重查。
@MainActor
private struct ProjectsFilterBar: View {

    @Bindable private var model: ProjectsModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(model: ProjectsModel) {
        self._model = Bindable(model)
    }

    private var language: AppLanguage { UILanguage.current }

    /// ⚠️ 这里是**非懒** `VStack`，不是可优化的写法：三个控件是
    /// `.menuStyle(.borderlessButton)` 的 Menu，一旦把它们放进 `LazyVStack`，
    /// 滚动时反复物化会当场自旋（本仓实测：RSS +142 MB/10s、CPU 108%、停手 40s 不回落）。
    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    timeRangeMenu
                    agentMenu
                    sortMenu
                    Spacer(minLength: Spacing.sm)
                    liveBadge
                }
                HStack(spacing: Spacing.sm) {
                    searchField
                    resetButton
                }
            }
        }
    }

    // MARK: 控件

    private var timeRangeMenu: some View {
        Menu {
            ForEach(ObservatoryTimeRange.allCases) { range in
                Button {
                    choose(range)
                } label: {
                    Label(
                        range.displayName(UILanguage.current),
                        systemImage: model.timeRange == range ? "checkmark.circle.fill" : range.symbol
                    )
                }
            }
        } label: {
            Label(model.timeRange.displayName(UILanguage.current), systemImage: "calendar")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(ProjectsCopy.timeRange.text(language))
    }

    private var agentMenu: some View {
        Menu {
            Button {
                model.selectedKinds = []
            } label: {
                Label(ProjectsCopy.allAgents.text(language),
                      systemImage: model.selectedKinds.isEmpty ? "checkmark.circle.fill" : "circle")
            }
            Divider()
            ForEach(availableKinds) { kind in
                Button {
                    model.toggleKind(kind)
                } label: {
                    Label(
                        kind.displayName,
                        systemImage: model.selectedKinds.contains(kind) ? "checkmark.square.fill" : "square"
                    )
                }
            }
        } label: {
            Label(agentTitle, systemImage: "person.2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(ProjectsCopy.a11yAgentFilter.text(language))
    }

    private var sortMenu: some View {
        Menu {
            ForEach(ProjectsSortKey.allCases) { key in
                Button {
                    model.sortKey = key
                } label: {
                    Label(
                        key.displayName,
                        systemImage: model.sortKey == key ? "checkmark.circle.fill" : key.symbol
                    )
                }
            }
        } label: {
            Label(model.sortKey.displayName, systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(ProjectsCopy.a11ySortMode.text(language))
    }

    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            TextField(ProjectsCopy.searchPrompt.text(language), text: $model.searchText)
                .textFieldStyle(.plain)
                .font(.axBody)
                .frame(maxWidth: .infinity)
            if model.searchText.isEmpty == false {
                Button {
                    model.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Surface.secondaryLabel)
                }
                .buttonStyle(.axPressable)   // #11：搜索框里那颗「清除」与全站同一份悬停/按下档
                .accessibilityLabel(ProjectsCopy.a11yClearSearch.text(language))
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        // 旧写法是给搜索框填一层 6% 的自造灰——那种灰在深色模式下会变成发灰的脏斑。
        // 搜索框是面板内的控件，语义上就是「沉进去一块」，用 `Surface.recessed`。
        .background(
            RoundedRectangle(cornerRadius: ObservatoryRadius.control, style: .continuous)
                .fill(Surface.recessed)
        )
    }

    private var resetButton: some View {
        Button {
            Task { await model.resetFilters() }
        } label: {
            Label(ProjectsCopy.reset.text(language), systemImage: "arrow.counterclockwise")
        }
        .controlSize(.small)
        .disabled(model.activeFilterCount == 0)
    }

    /// 订阅状态：有实时命中时报数，没有时也要说明「在订阅」，
    /// 否则用户分不清「没人动过」和「订阅断了」。用 `Tag` 而不是绿字。
    private var liveBadge: some View {
        HStack(spacing: Spacing.sm) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            if model.hasLiveActivity {
                Tag(ProjectsCopy.liveUpdatingTag.text(language), tone: .positive)
            } else {
                Tag(ProjectsCopy.subscribedTag.text(language), tone: .neutral)
            }
        }
        .fixedSize()
    }

    // MARK: 行为与文案

    /// 过滤菜单只列真实出现过的 Agent；一条样本都没有时退回全量枚举。
    private var availableKinds: [AgentKind] {
        let visible = model.visibleAgentKinds
        return visible.isEmpty ? AgentKind.allCases : visible
    }

    private var agentTitle: String {
        switch model.selectedKinds.count {
        case 0:  return ProjectsCopy.allAgents.text(language)
        // #82：兜底标签走表（原来是裸 `"Agent"` 字面量，英文/中文态各写各的、没有出处）。
        case 1:  return model.selectedKinds.first.map { AgentNaming.name(kind: $0) }
            ?? AgentNaming.fieldLabel.text(language)
        default: return ProjectsCopy.agentKindCount.format(language, model.selectedKinds.count)
        }
    }

    private func choose(_ range: ObservatoryTimeRange) {
        if let shell {
            shell.timeRange = range
        } else {
            Task { await apply(range) }
        }
    }

    /// 无 Shell 环境（单元 Preview 裸窗口）时的兜底：直接改模型并重查。
    private func apply(_ range: ObservatoryTimeRange) async {
        model.timeRange = range
        await model.load()
        await model.loadDetail()
        await model.loadRecentChanges()
    }
}

// MARK: - Previews

#Preview("项目地图（有数据）") {
    ObservatoryPreview.screen { runtime in
        ProjectsView(runtime: runtime)
    }
}

#Preview("项目地图（空状态）") {
    ObservatoryPreview.screen(empty: true) { runtime in
        ProjectsView(runtime: runtime)
    }
}
