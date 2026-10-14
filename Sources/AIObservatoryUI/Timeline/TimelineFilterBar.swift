//
//  TimelineFilterBar.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent C) → WS-QUIET-1 (subagent A) 改版
//  时间线的页面级过滤控件 —— **不再是事件流上方的一整行卡片**。
//
//  五项过滤仍然全部真实下推到 `EventQuery` 并触发重查：
//    ① 时间范围 → dateRange      ② Agent 多选 → agentKinds
//    ③ 操作类型多选 → kinds      ④ 只看风险 → minimumRisk(.high / .low)
//    ⑤ 搜索框 → searchText
//
//  【quiet 改版改了什么】
//  旧版是一条 `Panel` 卡片横在页面顶部：折叠三角 + 四个控件 + 计数 + 重置，
//  第二行才是搜索框。用户说的「东一个西一个」有一半就是它 —— 过滤器是**页面级**的口径，
//  不是内容板块，所以它收进 `ObservatoryPage` 标题行的 trailing：
//  搜索框 + 时间范围 Menu + 一个「筛选」Menu（Agent 多选 / 操作类型多选 / 只看风险 / 重置都在里面）。
//  生效条件数变成「筛选」按钮上的数字徽标（`activeFilterCount`），
//  原来那句「非阶梯小字号 + 强调色」的独立文字随之删掉。
//  折叠三角也删了：控件收进标题行后它没有存在的理由（旧版那个图标按钮用的是系统 body 字号，
//  不在 ax 阶梯上）。
//
//  ⚠️ 这里的 Menu 全都在**懒容器之外**（页面标题行）。不要把它们搬进事件流的行里 ——
//  本仓实测过「懒栈容器 + 卡内含 `.menu` Picker ⇒ 滚动自旋、RSS +142 MB/10s、CPU 108%」。
//

import SwiftUI
import Observation
import AIObservatoryCore

/// 页面标题行右侧的过滤控件组（搜索 + 时间范围 + 筛选）。
@MainActor struct TimelineFilterControls: View {

    private let model: TimelineModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    /// 搜索框草稿：300ms 防抖后才落到 `query.searchText`。
    @State private var searchText: String
    @State private var suppressDebounce: Bool = false
    @FocusState private var isSearchFocused: Bool

    @MainActor init(model: TimelineModel) {
        self.model = model
        self._searchText = State(initialValue: model.query.searchText)
    }

    /// 控件几何（表格列宽一类，允许字面量；集中在这里免得散进布局）。
    /// 刻意不叫 `Layout` —— 那是 SwiftUI 的同名协议，撞名会得到成片的 ambiguous use 错误。
    private enum ControlWidths {
        static let searchMinWidth: CGFloat = 120
        static let searchMaxWidth: CGFloat = 240
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            searchField
            timeRangeMenu
            filterMenu
        }
        .controlSize(.small)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(TimelineCopy.filterGroupLabel.text(language))
    }

    // MARK: - ⑤ 搜索

    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.axMeta)
                .foregroundStyle(Surface.tertiaryLabel)
                .accessibilityHidden(true)
            TextField(TimelineCopy.filterSearchPrompt.text(language), text: $searchText)
                .textFieldStyle(.plain)
                .font(.axBody)
                .focused($isSearchFocused)
                .onSubmit {
                    Task { await model.setSearchText(searchText) }
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                    Task { await model.setSearchText("") }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Surface.tertiaryLabel)
                }
                .buttonStyle(.axPressable)   // #11：搜索框里那颗「清除」与全站同一份悬停/按下档
                .accessibilityLabel(TimelineCopy.filterClearSearch.text(language))
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            Surface.recessed,
            in: RoundedRectangle(cornerRadius: ObservatoryRadius.control, style: .continuous)
        )
        .frame(minWidth: ControlWidths.searchMinWidth, maxWidth: ControlWidths.searchMaxWidth)
        .task(id: searchText) { await debounceSearch() }
        // 生效的查询词从**别处**变了 ⇒ 回填输入框。#74 之后这条数据流真的存在，来源有两个：
        //   ① 侧栏那一格：`SidebarSearchWiring` 把它下推成 `model.query.searchText`；
        //   ② 上面那颗「重置」：`model.resetFilters()` 把词清空。
        // 正在这一格打字时不打断——防抖还没落词的草稿不许被顶掉。
        // （#74 之前这里写着「外部（ShellModel.searchText）改了查询词时回填」，而侧栏那个词
        // 全仓零读取者，等于注释指了一条不存在的线。）
        .onChange(of: model.query.searchText) { _, newValue in
            guard !isSearchFocused else { return }
            if newValue != searchText { searchText = newValue }
        }
    }

    // MARK: - ① 时间范围

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
                .font(.axMeta)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(TimelineCopy.filterTimeRangeHelp.text(language))
        .accessibilityLabel(TimelineCopy.filterTimeRange.text(language))
    }

    // MARK: - ②③④ 一个「筛选」Menu 装下其余四项

    private var filterMenu: some View {
        Menu {
            agentSubmenu
            kindSubmenu
            Divider()
            riskOnlyToggle
            resetButton
        } label: {
            HStack(spacing: Spacing.xs) {
                Image(systemName: "line.3.filter")
                    .accessibilityHidden(true)
                Text(TimelineCopy.filterMenu.text(language))
                if model.activeFilterCount > 0 {
                    // 数字徽标：让「有几项条件在收窄这个范围」不点也能看见。
                    Text("\(model.activeFilterCount)")
                        .font(.axLabel)
                        .monospacedDigit()
                        .foregroundStyle(ObservatoryColor.accent)
                        .accessibilityLabel(TimelineCopy.filterBadgeCount.format(language, model.activeFilterCount))
                }
            }
            .font(.axMeta)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(TimelineCopy.filterMenuHelp.text(language))
        .accessibilityLabel(TimelineCopy.filterMenuLabel.format(language, model.activeFilterCount))
    }

    /// Agent 多选（菜单每行一个 `AgentChip`）。
    private var agentSubmenu: some View {
        Menu {
            Button {
                Task { await model.setAgentKinds([]) }
            } label: {
                Label(TimelineCopy.filterAllAgents.text(language), systemImage: checkmark(model.query.agentKinds.isEmpty))
            }
            Divider()
            ForEach(AgentKind.allCases) { kind in
                Button {
                    Task { await model.toggleAgentKind(kind) }
                } label: {
                    HStack(spacing: Spacing.sm) {
                        Image(systemName: checkmark(model.query.agentKinds.contains(kind)))
                        AgentChip(kind: kind, compact: true)
                    }
                }
            }
        } label: {
            Label(agentTitle, systemImage: "person.2")
        }
    }

    /// 操作类型多选。
    private var kindSubmenu: some View {
        Menu {
            Button {
                Task { await model.setKinds([]) }
            } label: {
                Label(TimelineCopy.filterAllKinds.text(language), systemImage: checkmark(model.query.kinds.isEmpty))
            }
            Divider()
            ForEach(OperationKind.allCases) { kind in
                Button {
                    Task { await model.toggleKind(kind) }
                } label: {
                    Label(kind.displayName, systemImage: checkmark(model.query.kinds.contains(kind)))
                }
            }
        } label: {
            // 不用 "terminal"：那是 `AgentKind.genericCLIAgent` 的图标，同一菜单里出现两次会串味。
            Label(kindTitle, systemImage: "list.bullet")
        }
    }

    /// 只看风险：风险等级过滤是下推到服务端的（`minimumRisk = .high`）。
    private var riskOnlyToggle: some View {
        Toggle(isOn: Binding(
            get: { model.riskOnly },
            set: { isOn in Task { await model.setRiskOnly(isOn) } }
        )) {
            Text(TimelineCopy.filterRiskOnly.text(language))
        }
        .help(TimelineCopy.filterRiskOnlyHelp.text(language))
    }

    private var resetButton: some View {
        Button {
            reset()
        } label: {
            Label(TimelineCopy.filterReset.text(language), systemImage: "arrow.counterclockwise")
        }
        .disabled(!model.hasNarrowedFilters && searchText.isEmpty)
        .help(TimelineCopy.filterResetHelp.text(language))
    }

    // MARK: - 标题

    private var agentTitle: String {
        switch model.query.agentKinds.count {
        case 0:  return TimelineCopy.filterAllAgents.text(language)
        case 1:  return model.query.agentKinds.first?.displayName ?? TimelineCopy.filterAgentFallback.text(language)
        default: return TimelineCopy.filterAgentCount.format(language, model.query.agentKinds.count)
        }
    }

    private var kindTitle: String {
        switch model.query.kinds.count {
        case 0:  return TimelineCopy.filterAllKinds.text(language)
        case 1:  return model.query.kinds.first?.displayName ?? TimelineCopy.filterKindFallback.text(language)
        default: return TimelineCopy.filterKindCount.format(language, model.query.kinds.count)
        }
    }

    /// 本次启动的语言（`UILanguage` 一处解析）。
    private var language: AppLanguage { UILanguage.current }

    private func checkmark(_ isSelected: Bool) -> String {
        isSelected ? "checkmark.square.fill" : "square"
    }

    // MARK: - 行为

    private func apply(timeRange: ObservatoryTimeRange) {
        // 板块内的时间范围改动要写回全局壳，保证跨板块一致。
        if let shell { shell.timeRange = timeRange }
        Task { await model.setTimeRange(timeRange) }
    }

    private func reset() {
        suppressDebounce = true
        searchText = ""
        Task {
            await model.resetFilters()
            suppressDebounce = false
        }
    }

    /// 300ms 防抖；`.task(id:)` 在输入变化时会自动取消上一次等待。
    private func debounceSearch() async {
        guard searchText != model.query.searchText else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, !suppressDebounce else { return }
        await model.setSearchText(searchText)
    }
}

// MARK: - Previews

#Preview("TimelineFilterControls") {
    TimelineFilterControls(model: {
        let model = TimelineModel(runtime: ObservatoryPreview.runtime())
        model.query.kinds = [.commandExecuted, .fileModified]
        return model
    }())
    .frame(maxWidth: .infinity, alignment: .trailing)
    .padding(Spacing.xl)
    .background(Surface.page)
}
