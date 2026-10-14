//
//  FilesFilterBar.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (QUIET-2)
//  文件板块过滤条：搜索 / 变更类型 / Agent / 时间范围 / Diff 视图模式 / 只看敏感路径，全部真实生效。
//
//  quiet 语言：控件功能全部保留，只收掉装饰色与阶梯外的字号。
//  搜索框底色走 `Surface.recessed`（旧版 `.primary.opacity(0.06)` 是自造灰，深色发脏）；
//  敏感开关的激活态留 `caution` 色——它承载「只看敏感路径」是语义不是装饰。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor struct FilesFilterBar: View {

    @Bindable private var model: FilesModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    @State private var searchText: String
    @State private var suppressDebounce: Bool = false
    /// 只用来做「正在这一格打字时别把草稿顶掉」的判据（与 `TimelineFilterControls` 同一手法）。
    @FocusState private var isSearchFocused: Bool

    init(model: FilesModel) {
        self._model = Bindable(model)
        self._searchText = State(initialValue: model.query.searchText)
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    timeRangeMenu
                    kindMenu
                    agentMenu
                    sensitiveToggle
                    Spacer(minLength: Spacing.sm)
                    viewModePicker
                }
                HStack(spacing: Spacing.sm) {
                    searchField
                    resetButton
                }
            }
        }
    }

    // MARK: - 控件

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
        .fixedSize()
        .accessibilityLabel(FilesCopy.filterTimeRangeA11y.text())
    }

    private var kindMenu: some View {
        Menu {
            Button {
                model.query.kinds = []
                Task { await model.applyFilters() }
            } label: {
                Label(FilesCopy.filterAllKinds.text(), systemImage: model.query.kinds.isEmpty ? "checkmark.circle.fill" : "circle")
            }
            Divider()
            ForEach(FileChangeKind.allCases) { kind in
                Button {
                    Task { await model.toggleKind(kind) }
                } label: {
                    Label(
                        "\(kind.displayName)  (\(model.eventCount(for: kind)))",
                        systemImage: isKindActive(kind) ? "checkmark.square.fill" : "square"
                    )
                }
            }
        } label: {
            Label(kindTitle, systemImage: "doc.badge.gearshape")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(FilesCopy.filterKindsA11y.text())
    }

    private var agentMenu: some View {
        Menu {
            Button {
                model.query.agentKinds = []
                Task { await model.applyFilters() }
            } label: {
                Label(FilesCopy.filterAllAgents.text(), systemImage: model.query.agentKinds.isEmpty ? "checkmark.circle.fill" : "circle")
            }
            Divider()
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
        } label: {
            Label(agentTitle, systemImage: "person.2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(FilesCopy.filterAgentsA11y.text())
    }

    private var sensitiveToggle: some View {
        Toggle(isOn: Binding(
            get: { model.sensitiveOnly },
            set: { model.sensitiveOnly = $0 }
        )) {
            Label(FilesCopy.filterSensitiveOnly.text(), systemImage: "lock.doc")
                .foregroundStyle(model.sensitiveOnly ? ObservatoryColor.caution : Surface.secondaryLabel)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private var viewModePicker: some View {
        Picker(FilesCopy.diffPickerView.text(), selection: Binding(
            get: { model.viewMode },
            set: { model.viewMode = $0 }
        )) {
            ForEach(FilesDiffViewMode.allCases) { mode in
                Label(mode.displayName, systemImage: mode.symbol).tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(FilesCopy.filterDiffModeA11y.text())
    }

    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            TextField(FilesCopy.filterSearchPath.text(), text: $searchText)
                .textFieldStyle(.plain)
                .font(.axBody)
                .frame(maxWidth: .infinity)
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
                .accessibilityLabel(FilesCopy.filterClearSearchA11y.text())
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        // 搜索框是面板内的控件，语义上「沉进去一块」，用 `Surface.recessed`（旧版自造灰发脏）。
        .background(
            RoundedRectangle(cornerRadius: ObservatoryRadius.control, style: .continuous)
                .fill(Surface.recessed)
        )
        .task(id: searchText) {
            await debounceSearch()
        }
        // #74 ③：生效的查询词从**别处**变了（侧栏那一格经 `SidebarSearchWiring` 下推、
        // 上面那颗「重置」清词）时回填这一格——否则列表已按路径筛过而框还空着，就是说谎。
        // 正在这一格打字时不打断（防抖未落词的草稿不该被顶掉）。
        .onChange(of: model.query.searchText) { _, newValue in
            guard !isSearchFocused else { return }
            if newValue != searchText { searchText = newValue }
        }
    }

    private var resetButton: some View {
        Button {
            suppressDebounce = true
            searchText = ""
            Task {
                await model.resetFilters()
                suppressDebounce = false
            }
        } label: {
            Label(FilesCopy.filterReset.text(), systemImage: "arrow.counterclockwise")
        }
        .disabled(model.activeFilterCount == 0 && searchText.isEmpty)
    }

    // MARK: - 标题

    private var kindTitle: String {
        switch model.query.kinds.count {
        case 0:  return FilesCopy.filterAllKinds.text()
        case 1:  return model.query.kinds.first?.displayName ?? FilesCopy.filterKindFallback.text()
        default: return FilesCopy.filterKindsSummary.format(.resolved(), model.query.kinds.count)
        }
    }

    private var agentTitle: String {
        switch model.query.agentKinds.count {
        case 0:  return FilesCopy.filterAllAgents.text()
        case 1:  return model.query.agentKinds.first?.displayName ?? "Agent"
        default: return FilesCopy.filterAgentsSummary.format(.resolved(), model.query.agentKinds.count)
        }
    }

    private func isKindActive(_ kind: FileChangeKind) -> Bool {
        model.query.kinds.isEmpty || model.query.kinds.contains(kind)
    }

    private func isAgentActive(_ kind: AgentKind) -> Bool {
        model.query.agentKinds.isEmpty || model.query.agentKinds.contains(kind)
    }

    // MARK: - 行为

    private func apply(timeRange: ObservatoryTimeRange) {
        if let shell { shell.timeRange = timeRange }
        Task { await model.setTimeRange(timeRange) }
    }

    private func debounceSearch() async {
        guard searchText != model.query.searchText else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, !suppressDebounce else { return }
        await model.setSearchText(searchText)
    }
}
