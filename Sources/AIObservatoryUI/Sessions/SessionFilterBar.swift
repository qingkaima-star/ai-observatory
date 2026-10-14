//
//  SessionFilterBar.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent I)
//  Sessions 板块过滤控件：搜索 / Agent 多选 / 结果状态多选 / 时间范围（与 Shell 双向同步）/
//  排序方向 / 只看有风险 / 项目聚焦 / 重置，全部真实下推到 SessionQuery。
//
//  【quiet 改版要点】本视图**不再是单独占一行的卡片**：它渲染成页面标题行右侧的那一组
//  页面级控件（`ObservatoryPage` 的 trailing）。原因——旧版是一个 `Panel` 里塞两排控件，
//  其中搜索框还自造了一层 6% 主色底，既多占一个板块、
//  又和面板底抢层次。现在：时间范围一个 Menu，其余收进一个「筛选」Menu，右侧只剩计数。
//  ⚠️ 这些 Menu 必须待在**非懒容器**里（标题行），放进懒列表的行内会触发滚动自旋。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor struct SessionFilterBar: View {

    @Bindable private var model: SessionsModel
    @Environment(ShellModel.self) private var shell: ShellModel?
    /// #89：清除筛选那颗按钮的 tooltip 念的是**完整项目路径**（按钮标题只给末段名）。
    @Environment(\.demoRedaction) private var demoRedaction

    @State private var searchText: String
    @State private var suppressDebounce: Bool = false
    /// 只用来做「正在这一格打字时别把草稿顶掉」的判据（与 `TimelineFilterControls` 同一手法）。
    @FocusState private var isSearchFocused: Bool

    init(model: SessionsModel) {
        self._model = Bindable(model)
        self._searchText = State(initialValue: model.query.searchText)
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            searchField
            timeRangeMenu
            filterMenu
            // 这里原本还挂着一个「N 个会话」的计数。**删掉**：同一个 `totalCount`
            // 在真机截图里出现了五次（这一处、hero 的 40pt 大字、页面副标题、
            // 「已加载会话的合计」卡头、列表标题行的「共 N · 已加载 M」），
            // 而它正下方 30pt 就是那个 40pt 大字。计数归 hero 与列表头两处说，
            // 控件行只管控件。
        }
        .controlSize(.small)
    }

    // MARK: - 标题行控件

    /// 时间范围：与 Shell 顶栏双向同步（Shell 改了这里跟，这里改了推回去）。
    private var timeRangeMenu: some View {
        Menu {
            ForEach(ObservatoryTimeRange.allCases) { range in
                Button {
                    apply(timeRange: range)
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
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel(SessionsCopy.filterTimeRange.text(language))
    }

    /// 除时间范围之外的全部条件收在一个 Menu 里：菜单标签上直接带「已启用 N 项」，
    /// 不开菜单也知道当前看的是筛过的结果（旧版把这些摊成两排等宽按钮，谁生效看不出来）。
    private var filterMenu: some View {
        Menu {
            agentSection
            Divider()
            outcomeSection
            Divider()
            riskyButton
            sortSection
            Divider()
            projectSection
            Button {
                resetAll()
            } label: {
                Label(SessionsCopy.filterResetAll.text(language), systemImage: "arrow.counterclockwise")
            }
            .disabled(model.activeFilterCount == 0 && searchText.isEmpty && model.timeRange == .all)
        } label: {
            Label(filterTitle, systemImage: "line.3.horizontal.decrease.circle")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.visible)
        .fixedSize()
        .accessibilityLabel(SessionsCopy.filterGroupA11y.text(language))
    }

    private var filterTitle: String {
        model.activeFilterCount == 0
                ? SessionsCopy.filterMenu.text(language)
                : SessionsCopy.filterMenuCounted.copy.format(language, model.activeFilterCount)
    }

    @ViewBuilder private var agentSection: some View {
        Button {
            clearAgentKinds()
        } label: {
            Label(SessionsCopy.filterAllAgents.text(language), systemImage: model.query.agentKinds.isEmpty ? "checkmark.circle.fill" : "circle")
        }
        ForEach(AgentKind.allCases) { kind in
            Button {
                Task { await model.toggleAgentKind(kind) }
            } label: {
                Label(
                    kind.displayName,
                    systemImage: isAgentActive(kind) ? "checkmark.square.fill" : "square"
                )
            }
        }
    }

    @ViewBuilder private var outcomeSection: some View {
        Button {
            clearOutcomes()
        } label: {
            Label(SessionsCopy.filterAllOutcomes.text(language), systemImage: model.query.outcomes.isEmpty ? "checkmark.circle.fill" : "circle")
        }
        ForEach(SessionOutcome.allCases, id: \.self) { outcome in
            Button {
                Task { await model.toggleOutcome(outcome) }
            } label: {
                // 条数是**本页已加载**会话里的条数，不是服务端匹配数——菜单里也得说清。
                Label(
                    SessionsCopy.filterOutcomeRow.copy.format(language, outcome.displayName, model.sessionCount(for: outcome)),
                    systemImage: isOutcomeActive(outcome) ? "checkmark.square.fill" : "square"
                )
            }
        }
    }

    private var riskyButton: some View {
        Button {
            model.setRiskyOnly(!model.riskyOnly)
        } label: {
            Label(
                SessionsCopy.filterRiskyOnly.text(language),
                systemImage: model.riskyOnly ? "checkmark.square.fill" : "square"
            )
        }
    }

    @ViewBuilder private var sortSection: some View {
        Divider()
        Button {
            Task { await model.setSortDescending(true) }
        } label: {
            Label(SessionsCopy.filterNewestFirst.text(language), systemImage: model.query.sort.descending ? "checkmark.circle.fill" : "circle")
        }
        Button {
            Task { await model.setSortDescending(false) }
        } label: {
            Label(SessionsCopy.filterOldestFirst.text(language), systemImage: model.query.sort.descending ? "circle" : "checkmark.circle.fill")
        }
    }

    /// 由详情「聚焦此项目」写入的项目过滤，在这里给出撤销入口。
    @ViewBuilder private var projectSection: some View {
        if let project = model.query.projectPath, !project.isEmpty {
            Button {
                Task { await model.setProjectPath(nil) }
            } label: {
                Label(SessionsCopy.filterClearProject.copy.format(language, (project as NSString).lastPathComponent),
                        systemImage: "folder")
            }
            .help(demoRedaction.scrub(SessionsCopy.filterProjectHelp.copy.format(language, project)))
        }
    }

    /// 搜索框：系统画的 `roundedBorder`，不再自造那层 6% 主色底。
    private var searchField: some View {
        TextField(SessionsCopy.filterSearchPrompt.text(language), text: $searchText)
            .textFieldStyle(.roundedBorder)
            .labelsHidden()
            .frame(width: 200)
            .accessibilityLabel(SessionsCopy.filterSearchA11y.text(language))
            .focused($isSearchFocused)
            .onSubmit {
                Task { await model.setSearchText(searchText) }
            }
            .task(id: searchText) {
                await debounceSearch()
            }
            // #74 ③：生效的查询词从**别处**变了（侧栏那一格经 `SidebarSearchWiring` 下推、
            // 空态里那条「重置」清词）时回填这一格。原来这一格没有回填路径：侧栏一改词，
            // 列表已经筛过而这里的框还空着，等于新一格说谎。正在这一格打字时不打断
            // （防抖还没落词的草稿不该被顶掉）。
            .onChange(of: model.query.searchText) { _, newValue in
                guard !isSearchFocused else { return }
                if newValue != searchText { searchText = newValue }
            }
    }


    // MARK: - 判定

    private func isAgentActive(_ kind: AgentKind) -> Bool {
        model.query.agentKinds.isEmpty || model.query.agentKinds.contains(kind)
    }

    private func isOutcomeActive(_ outcome: SessionOutcome) -> Bool {
        model.query.outcomes.isEmpty || model.query.outcomes.contains(outcome)
    }

    // MARK: - 行为

    private func apply(timeRange range: ObservatoryTimeRange) {
        if let shell { shell.timeRange = range }
        Task { await model.setTimeRange(range) }
    }

    /// 菜单里的「全部 Agent」：已是全放开时不触发多余重查。
    private func clearAgentKinds() {
        guard !model.query.agentKinds.isEmpty else { return }
        model.query.agentKinds = []
        Task { await model.applyFilters() }
    }

    /// 菜单里的「全部状态」。
    private func clearOutcomes() {
        guard !model.query.outcomes.isEmpty else { return }
        model.query.outcomes = []
        Task { await model.applyFilters() }
    }

    /// 重置：先压住防抖，避免清空搜索框又立刻触发一次独立重查。
    private func resetAll() {
        suppressDebounce = true
        searchText = ""
        Task {
            await model.resetFilters()
            suppressDebounce = false
        }
    }

    private func debounceSearch() async {
        guard searchText != model.query.searchText else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, !suppressDebounce else { return }
        await model.setSearchText(searchText)
    }
}

// MARK: - Previews

#Preview("SessionFilterBar 页面级控件") {
    // 用空运行时：本预览只验证标题行控件排的宽度与对齐，不拉样本数据。
    HStack(alignment: .firstTextBaseline, spacing: Spacing.lg) {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text("AI 会话").font(.axPage)
            Text("口径说明 · 范围：今天").font(.axBody).foregroundStyle(Surface.secondaryLabel)
        }
        Spacer(minLength: Spacing.md)
        SessionFilterBar(model: SessionsModel(runtime: ObservatoryPreview.emptyRuntime()))
    }
    .padding(.horizontal, Spacing.xl)
    .padding(.top, Spacing.lg)
    .frame(width: 980, alignment: .leading)
}

private extension SessionFilterBar {
    var language: AppLanguage { UILanguage.current }
}
