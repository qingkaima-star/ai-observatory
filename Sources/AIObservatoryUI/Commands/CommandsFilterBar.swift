//
//  CommandsFilterBar.swift
//  Commands
//
//  Owner: WS-UI（由 CommandsView.swift 原样搬来：只按职责分文件，行为未变。）
//

import SwiftUI
import Observation
import AIObservatoryCore
// MARK: - 过滤条

/// 过滤条：非懒 `VStack`（卡片数量恒定有界）。旧版这里踩过
/// 「`LazyVStack` + 含 `.menu` 的 `Picker` ⇒ 滚动自旋、RSS 不回落」。
/// 控件功能全部保留，只收掉装饰色与阶梯外的字号。
@MainActor struct CommandsFilterBar: View {

    @Bindable private var model: CommandsModel

    @State private var searchText: String
    @State private var suppressDebounce: Bool = false

    init(model: CommandsModel) {
        self._model = Bindable(model)
        self._searchText = State(initialValue: model.criteria.searchText)
    }

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                HStack(spacing: Spacing.sm) {
                    timeRangeMenu
                    agentMenu
                    exitMenu
                    destructiveToggle
                    sortMenu
                    // 这里原来挂着一个「N 条命令」的尾签：同一个服务端总数在一屏里
                    // 已经说过两遍（页头副标题「共 N 条命令 · 已加载 M」+ 下面那格 tile 的
                    // 40pt 以下大数），全站口径的上限就是两次。
                    Spacer(minLength: Spacing.sm)
                }
                HStack(spacing: Spacing.sm) {
                    searchField
                    sessionChip
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
                    Task { await model.setTimeRange(range) }
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
        .accessibilityLabel(CommandsCopy.a11yTimeRange.text(language))
    }

    private var agentMenu: some View {
        Menu {
            Button {
                Task { await model.setAgentKinds([]) }
            } label: {
                Label(
                    CommandsCopy.allAgents.text(language),
                    systemImage: model.criteria.agentKinds.isEmpty ? "checkmark.circle.fill" : "circle"
                )
            }
            Divider()
            ForEach(AgentKind.allCases) { kind in
                Button {
                    Task { await model.toggleAgentKind(kind) }
                } label: {
                    Label(
                        kind.displayName,
                        systemImage: model.criteria.agentKinds.contains(kind) ? "checkmark.square.fill" : "square"
                    )
                }
            }
        } label: {
            Label(agentTitle, systemImage: "person.2")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(CommandsCopy.a11yAgentKind.text(language))
    }

    /// 菜单项不再逐项染色（旧版 `.foregroundStyle(filter.tint)` 是装饰配色）：
    /// 成败的判断由标签文字与勾选承担。
    private var exitMenu: some View {
        Menu {
            ForEach(CommandExitFilter.allCases) { filter in
                Button {
                    Task { await model.setExitFilter(filter) }
                } label: {
                    Label(
                        "\(filter.displayName)  (\(model.count(for: filter)))",
                        systemImage: model.criteria.exitFilter == filter ? "checkmark.square.fill" : "square"
                    )
                }
            }
        } label: {
            Label(model.criteria.exitFilter.displayName, systemImage: "checkmark.seal")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(CommandsCopy.fieldExitResult.text(language))
    }

    /// 激活态留 `critical` 色：这个开关承载的是「只看会改变系统的命令」，是语义不是装饰。
    private var destructiveToggle: some View {
        Toggle(isOn: Binding(
            get: { model.criteria.destructiveOnly },
            set: { enabled in Task { await model.setDestructiveOnly(enabled) } }
        )) {
            Label(CommandsCopy.destructiveOnlyToggle.text(language), systemImage: "exclamationmark.octagon")
                .foregroundStyle(model.criteria.destructiveOnly ? ObservatoryColor.critical : Surface.secondaryLabel)
        }
        .toggleStyle(.button)
        .controlSize(.small)
        .fixedSize()
    }

    private var sortMenu: some View {
        Menu {
            Button {
                Task { await model.setSortDescending(true) }
            } label: {
                Label(CommandsCopy.sortNewestFirst.text(language),
                      systemImage: model.criteria.sort.descending ? "checkmark.circle.fill" : "circle")
            }
            Button {
                Task { await model.setSortDescending(false) }
            } label: {
                Label(CommandsCopy.sortOldestFirst.text(language),
                      systemImage: model.criteria.sort.descending ? "circle" : "checkmark.circle.fill")
            }
        } label: {
            Label(model.criteria.sort.descending ? CommandsCopy.sortNewestFirst.text(language)
                                                 : CommandsCopy.sortOldestFirst.text(language),
                  systemImage: "arrow.up.arrow.down")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(CommandsCopy.a11ySortDirection.text(language))
    }

    /// 搜索框底色走 `Surface.recessed`（旧版 `.fill(.primary.opacity(0.06))` 是自造灰）。
    private var searchField: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: "magnifyingglass")
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            TextField(CommandsCopy.searchPrompt.text(language), text: $searchText)
                .textFieldStyle(.plain)
                .font(.axBody)
                .frame(maxWidth: .infinity)
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
                .accessibilityLabel(CommandsCopy.a11yClearSearch.text(language))
            }
        }
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: ObservatoryRadius.control, style: .continuous)
                .fill(Surface.recessed)
        )
        .task(id: searchText) {
            await debounceSearch()
        }
        // #74 收口：生效的查询词从**别处**变了 ⇒ 回填这一格。来源有两个：
        //   ① 侧栏那一格：`SidebarSearchWiring` 把它下推成 `model.criteria.searchText`；
        //   ② 上面那颗「重置」：`model.resetFilters()` 把词清空。
        // 少了这一条，侧栏改完词以后列表已经筛过而这一格还空着 ⇒ 同一屏两处真相
        // （时间线 / 会话 / 文件三页各有一条同手法的门禁用例管着，命令页原来是缺口）。
        // 不许多发一次查询：回填之后草稿与生效词相等，上面那条防抖自己的 guard 就返回了；
        // 「重置」那一路也相等（它先把 `searchText` 清成空），所以不需要再借 `suppressDebounce`。
        .onChange(of: model.criteria.searchText) { _, newValue in
            guard newValue != searchText else { return }
            searchText = newValue
        }
    }

    /// 由详情「只看这个会话」写入的会话过滤，在这里给出可见的撤销入口。
    @ViewBuilder private var sessionChip: some View {
        if let sessionID = model.focusedSessionID {
            Button {
                Task { await model.focusSession(nil) }
            } label: {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "list.bullet.rectangle")
                    Text(String(sessionID.uuidString.prefix(8)))
                        .font(.axMetaMono)
                    Image(systemName: "xmark.circle.fill")
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .fixedSize()
            .help(CommandsCopy.sessionChipHelp.text(language))
            .accessibilityLabel(CommandsCopy.a11yClearSessionFilter.text(language))
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
            Label(CommandsCopy.reset.text(language), systemImage: "arrow.counterclockwise")
        }
        .disabled(model.activeFilterCount == 0 && searchText.isEmpty && model.timeRange == .all)
    }

    // MARK: 标题

    private var agentTitle: String {
        switch model.criteria.agentKinds.count {
        case 0:  return CommandsCopy.allAgents.text(language)
        case 1:  return model.criteria.agentKinds.first?.displayName ?? "Agent"
        default: return CommandsCopy.agentKindCount.format(language, model.criteria.agentKinds.count)
        }
    }

    // MARK: 行为

    private func debounceSearch() async {
        guard searchText != model.criteria.searchText else { return }
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, !suppressDebounce else { return }
        await model.setSearchText(searchText)
    }
}
