//
//  SessionsView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent I)
//  Sessions 板块入口（用户需求模块⑥）：`ObservatoryPage` 骨架 + 本页唯一 hero（服务端会话总数）
//  + 已加载会话合计 + 会话列表面板；会话详情挂 `.inspector`。
//  【冻结签名】Shell 以 `SessionsView(runtime: ObservatoryRuntime)` 挂载本板块。
//  ─────────────────────────────────────────────────────────
//  【quiet 改版要点】旧骨架是 `VStack { SessionFilterBar ; Divider ; GeometryReader { HStack { List ; 详情 } } ; Divider ; statusBar }`，
//  自己拼了一套页面骨架：左列宽度手算（`total * 0.36`）、`List` 自己带滚动、底部还有一条状态条。
//  现在外层只有一个 `ObservatoryPage`（它内部已有 `ScrollView { VStack(spacing: .section) }`、
//  1120pt 收口与 32pt 边距），所以：
//    · `GeometryReader` 与手算列宽整段删除；
//    · `List` / `.listStyle(.inset)` / `.scrollContentBackground(.hidden)` /
//      自造 3% 主色底 / 行内边距 / 行背景 三类覆写全部删除
//      —— 页面里第二个滚动容器就是「双滚动会塌」的那个塌；
//    · 过滤条从「单独占一行的卡片」收进标题行 trailing（见 `SessionFilterBar`）；
//    · 底部状态条不再是独立一条：它的信息进了 hero 的说明行与会话列表 `SectionHeader`；
//    · `.id(model.listRevision)` 一并删除，理由见 `sessionList(rows:)` 上方注释。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor struct SessionsView: View {

    @State private var model: SessionsModel
    @Environment(ShellModel.self) private var shell: ShellModel?
    /// #89：错误那一句是 `error.localizedDescription`，本仓的存储错误带库文件绝对路径。
    @Environment(\.demoRedaction) private var demoRedaction
    /// 会话列表是否持有键盘焦点。方向键要落到列表，就得先有焦点；
    /// 点一行选中时顺手把焦点拿过来，用户不必再按一次 Tab 才能上下走。
    @FocusState private var listIsFocused: Bool
    /// 导出走 runtime 注入的执行者：UI 不依赖导出层（依赖倒置，见 Core/Contracts/Exporting.swift）。
    private let runtime: ObservatoryRuntime

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        _model = State(initialValue: SessionsModel(runtime: runtime))
    }

    var body: some View {
        page
            .inspector(isPresented: showsDetail) {
                SessionDetailView(model: model)
                    .inspectorColumnWidth(min: 300, ideal: 320, max: 420)
            }
            .task(id: shell?.timeRange) {
                // 时间范围跟随 Shell 顶栏。`load()` → `observeUpdates()` 的调用次序**一字不动**地保留
                // （简报第 10 条：增量订阅次序原样保留）。`observeUpdates()` 是长驻的 for-await 循环，
                // 本页改版只重排视图，不碰数据流时序；若要把订阅改成「先登记再拉快照」
                // （Dashboard 那种 `async let` 写法），那是数据层的改动，另开一次。
                if let shell, model.timeRange != shell.timeRange {
                    model.timeRange = shell.timeRange
                }
                // #74 ①：侧栏那个词在第一次取数之前落进 `query.searchText` ⇒ 首屏那次
                // `sessions(matching:)` 就是筛过的，不是「先拉一页再本地筛」。
                SidebarSearchWiring.seed(fromShell: shell, into: model)
                // #81 ①：跳转条件（这一格是项目路径 + 时间区间）在第一次
                // `sessions(matching:)` 之前落进同一条 `SessionQuery`。
                let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
                await model.load()
                // #81 ①b：列表筛小之后，若这一跳点名了某一条会话就把它选中（走本页
                // 既有的 `select(_:)`，详情那一路因此只取一次）。
                await EvidenceJumpWiring.focus(jumped, into: model)
                await model.observeUpdates()
            }
            // #74 ②：侧栏改词 ⇒ 防抖后下推进 `SessionQuery.searchText`，走 Store 真查询。
            .task(id: shell?.searchText) {
                await SidebarSearchWiring.push(fromShell: shell, into: model)
            }
            // #81 ②：已经停在本页时又来了一条跳转意图 ⇒ 落条件并走真查询（相等不重查）。
            .task(id: shell?.pendingJump) {
                await EvidenceJumpWiring.push(fromShell: shell, into: model)
            }
            // #81 ②：已经停在本页时又来了一条跳转意图 ⇒ 落条件并走真查询（相等不重查）。
            .task(id: shell?.pendingJump) {
                await EvidenceJumpWiring.push(fromShell: shell, into: model)
            }
            // #74 ③：本页过滤条改词 / 空态里那条「重置」清了词 ⇒ 侧栏同步显示同一个词。
            .onChange(of: model.query.searchText) { _, term in
                SidebarSearchWiring.pull(queryTerm: term, into: shell)
            }
            .refreshable { await model.load() }
    }

    // MARK: - 页面骨架

    private var page: some View {
        ObservatoryPage(
            SidebarSection.sessions.title,
            // 旧版这里是一句 173 字的口径长句（「口径：大数是服务端匹配总数，其余读数只算
            // 本页已加载的 N 个（单页上限 100） · 范围：全部」），在标题区折成三行，
            // 而它说过的两件事下面还各说一遍：hero 的 caption 说「服务端匹配总数」，
            // 「已加载会话的合计」那张卡的 subtitle 说「只统计本页已加载的 N 个」。
            // ⇒ 副标题只留**别处没有的**那一条信息：每页上限（它决定「共 N · 已加载 M」怎么读）。
            subtitle: SessionsCopy.pageSubtitle.copy.format(language, model.timeRange.displayName(language), SessionsModel.pageSize)
        ) {
            HStack(spacing: Spacing.md) {
                SessionFilterBar(model: model)
                exportMenu
            }
        } content: {
            contentBlocks
        }
    }

    @ViewBuilder private var contentBlocks: some View {
        // #81：这一屏带着跳转条件 ⇒ 说出来（读的是本页那条真 `SessionQuery`，不是外壳状态）。
        EvidenceJumpChip(conditions: model.carriedJumpConditions) {
            await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        }
        if let message = model.errorMessage, model.sessions.isEmpty {
            errorPanel(message: message, fillsWholePage: true)
        } else if model.isLoading && model.sessions.isEmpty {
            loadingPanel
        } else {
            if let message = model.errorMessage {
                errorPanel(message: message, fillsWholePage: false)
            }

            heroPanel
            // 「已加载会话的合计」在**一条都没加载**时整块不排：那四格只会是四个 0，
            // 回答的是一个没有对象的问题，而下面的空态已经说清了为什么没有。
            // 真机实测：这一屏原本有 13 个 0。
            if !model.sessions.isEmpty {
                metricsPanel
            }
            sessionList(rows: model.visibleSessions)
        }
    }

    // MARK: - hero：本页唯一的 40pt 读数
    //
    // 为什么是**服务端会话总数**：进这一页第一个要回答的问题是「这个范围里到底有多少次会话」，
    // 它是本页唯一带「全量」语义的数（`totalCount` 来自服务端 `COUNT`，与分页无关）。
    // 候选「活跃会话数」和「累计时长」都是从**已加载的那一页**算出来的局部读数，
    // 放到 40pt 会把「只数了这一页」说得像全局结论——它们降级到下面的 `metricsPanel` 与
    // `InlineStat` 说明行，并在 caption 里写清口径。

    private var heroPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.md) {
                StatTile(
                    title: SessionsCopy.heroTitle.text(language),
                    value: "\(model.totalCount)",
                    unit: SessionsCopy.unitSessions(language),
                    caption: ReadoutCopy.serverTotalCaption,
                    emphasis: .hero
                )

                // 只在「有信息可说」时才排这一排：`heroSupplementaryStats` 已经把
                // 「0 与未启用不排格」「不与四格重复」两条规则收在里面，
                // 所以这里不再自己判断，也不留一条光秃的 Hairline。
                if !model.heroSupplementaryStats.isEmpty {
                    Hairline()

                    HStack(spacing: Spacing.lg) {
                        ForEach(model.heroSupplementaryStats, id: \.self) { stat in
                            InlineStat(stat.label, value: stat.value)
                        }
                        Spacer(minLength: Spacing.none)
                    }
                }
            }
        }
    }

    // MARK: - 次级读数（合计口径 = 本页已加载）

    /// 四格一排填满（`columns: 4`），八个读数里落单的都排进了 hero 的 `InlineStat` 行。
    ///
    /// ⚠️ 这四格全部由 `model.sessions`（单页最多 `SessionsModel.pageSize` 条）求和而来，
    /// 与 hero 的服务端总数不是一个口径——口径由上面 `SectionHeader` 的 subtitle **说一次**，
    /// 格子只留自己那条信息。原来四格 caption 各自重复「已加载 N 个中」，
    /// 与 Timeline 同一处毛病：四个相同前缀就是「拥挤」，而且信息量并不比标题行多。
    private var metricsPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionHeader(
                    SessionsCopy.totalsTitle.text(language),
                    subtitle: SessionsCopy.totalsSubtitle.copy.format(language, model.sessions.count)) {
                    // 「有风险事件的会话数」从「文件改动」那一格的 caption 挪到这里：
                    // 它数的是会话、不是文件，挂在那一格下面会被读成因果关系。
                    if model.riskySessionCount > 0 {
                        InlineStat(SessionsCopy.totalsRisky.text(language),
                                   value: SessionsCopy.totalsRiskyValue.copy.format(language, model.riskySessionCount))
                    }
                }

                Hairline()

                MetricGrid(metricTiles, columns: Sizing.metricColumns) { tile in
                    StatTile(
                        title: tile.title,
                        value: tile.value,
                        unit: tile.unit,
                        caption: tile.caption,
                        emphasis: .metric
                    )
                }
            }
        }
    }

    private var metricTiles: [SessionsMetricTile] {
        return [
            SessionsMetricTile(
                id: 0,
                title: SessionsCopy.totalsRunning.text(language),
                value: "\(model.runningCount)",
                unit: SessionsCopy.unitSessions(language),
                caption: SessionsCopy.totalsRunningCaption.text(language)
            ),
            SessionsMetricTile(
                id: 1,
                title: SessionsCopy.totalsDuration.text(language),
                value: DurationFormat.compact(model.loadedDurationSeconds),
                caption: SessionsCopy.totalsDurationCaption.text(language)
            ),
            SessionsMetricTile(
                id: 2,
                title: SessionsCopy.totalsCommands.text(language),
                value: "\(model.loadedCommandTotal)",
                unit: SessionsCopy.unitItems(language),
                caption: SessionsCopy.totalsCommandsCaption.copy.format(language, model.loadedFailedCommandTotal)
            ),
            SessionsMetricTile(
                id: 3,
                title: SessionsCopy.totalsFiles.text(language),
                value: "\(model.loadedTouchedFileTotal)",
                unit: SessionsCopy.unitLocations(language),
                caption: model.loadedFileBreakdown
            ),
        ]
    }

    // MARK: - 会话列表
    //
    // 关于删掉的 `.id(model.listRevision)`：那句只为绕开 `List(selection:)` 的一个具体缺陷——
    // List 自己在内部记着「选中的是第几行」，行身份整体换掉（应用过滤）之后它会复用旧下标，
    // 于是高亮行和 `model.selectedID` 对不上，只能靠换 `.id` 重建整个 List。
    // 换成 `LazyVStack` 之后高亮**只**从 `model.selectedID` 这一个真相渲染
    // （`SessionRow.isSelected: model.selectedID == session.id`），列表内部不再持有第二份选中态，
    // 复用旧下标的前提不存在；「过滤后自动选中第一条」由 `SessionsModel.load()` 末尾的
    // `ensureSelection()` 负责，它本来就在跑。反过来，留着 `.id` 会在每次加载后重建整个懒列表、
    // 把滚动位置甩回顶部。所以这里删掉它，并把模型里那个只为它存在的 `listRevision` 一并删了。

    private func sessionList(rows: [AgentSession]) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    SessionsCopy.listTitle.text(language),
                    subtitle: model.listCountSummary) {
                    trailingControls
                }

                Hairline()

                if rows.isEmpty {
                    emptyState
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, Spacing.sm)
                } else {
                    LazyVStack(alignment: .leading, spacing: Spacing.none) {
                        ForEach(rows) { session in
                            sessionRow(session)
                            if session.id != rows.last?.id {
                                Hairline()
                            }
                        }
                    }
                    .animation(ObservatoryMotion.value, value: rows.count)
                    // 键盘 ↑/↓ 换选中。这条原本是 `List(selection:)` 白送的，
                    // 换成懒列表（为了修「高亮有两处真相」）之后一度丢失，
                    // 旧注释把它留成「已知功能回归、本车道不许跑编译所以没写」——
                    // 移动语义在 `SessionsModel.moveSelection(by:)`，视图这里只接线。
                    .focusable()
                    .focused($listIsFocused)
                    .focusEffectDisabled()
                    .onKeyPress(.upArrow) {
                        listIsFocused = true
                        Task { await model.moveSelection(by: -1) }
                        return .handled
                    }
                    .onKeyPress(.downArrow) {
                        listIsFocused = true
                        Task { await model.moveSelection(by: 1) }
                        return .handled
                    }
                    // 刻意不挂 `.help(...)`：挂在整块列表上，指针在任意一行停一下就会
                    // 弹出一条盖住列表的 tooltip（真机验证时它把截图整个挡住过一次）。
                    // 键盘提示改成常驻在列表标题行的 trailing，见 `trailingControls`。
                }

                if model.isLoadingMore {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(SessionsCopy.listLoadingEarlier.text(language))
                            .font(.axMeta)
                            .foregroundStyle(Surface.secondaryLabel)
                        Spacer(minLength: Spacing.none)
                    }
                }
            }
        }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        SessionRow(
            session: session,
            counters: model.counters(for: session),
            isSelected: model.selectedID == session.id
        ) {
            listIsFocused = true
            Task { await model.select(session.id) }
        }
        .transition(.opacity)
    }

    @ViewBuilder private var trailingControls: some View {
        HStack(spacing: Spacing.sm) {
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Text(SessionsCopy.listLoadEarlier.text(language))
                }
                .controlSize(.small)
                .disabled(model.isLoadingMore)
                .help(SessionsCopy.listLoadEarlierHelp.copy.format(language, SessionsModel.pageSize))
            }
            Text(SessionsCopy.listKeyboardHint.text(language))
                .axCaptionStyle()   // #99：口径句提档（原 .axMeta + tertiary）
                .fixedSize()
        }
    }


    // MARK: - 导出

    /// 导出入口只在宿主真的接了导出层时出现——预览里一个点了没反应的按钮比没有按钮更糟。
    /// 时间范围取列表当前生效的筛选：用户筛完再导，拿到的就该是他看到的那一份。
    @ViewBuilder private var exportMenu: some View {
        if let exporter = runtime.exporter {
            Menu {
                ForEach(ActivityExportRequest.Format.allCases) { format in
                    Button(format.displayName) {
                        let range = model.query.dateRange
                        Task { await exporter.export(
                            ActivityExportRequest(dateRange: range, format: format)
                        ) }
                    }
                }
            } label: {
                Label(SessionsCopy.exportLabel.text(language), systemImage: "square.and.arrow.up")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.visible)
            .fixedSize()
            .disabled(model.sessions.isEmpty)
            .help(SessionsCopy.exportHelp.text(language))
        }
    }

    // MARK: - 三态

    private var loadingPanel: some View {
        Panel {
            HStack(spacing: Spacing.md) {
                ProgressView().controlSize(.small)
                Text(SessionsCopy.loadingTitle.text(language))
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                Spacer(minLength: Spacing.none)
            }
            .frame(minHeight: Sizing.rowMinHeight)
        }
    }

    /// 真·无数据：引导用户重新扫描。
    private var noDataState: some View {
        EmptyStateView(
            SessionsCopy.emptyNoSessionTitle.text(language),
            systemImage: "list.bullet.rectangle.portrait",
            message: SessionsCopy.emptyNoSessionMessage.text(language),
            fills: false
        ) {
            Button {
                Task { await shell?.rescan() }
            } label: {
                Label(SessionsCopy.rescanNow.text(language), systemImage: "arrow.clockwaves")
            }
        }
    }

    /// 被过滤到空：给出撤销入口，而不是让用户以为没有数据。
    private var filteredOutState: some View {
        EmptyStateView(
            SessionsCopy.emptyFilteredTitle.text(language),
            systemImage: "line.3.horizontal.decrease.circle",
            message: SessionsCopy.emptyFilteredMessage.copy.format(language, model.activeFilterCount, model.timeRange.displayName(language)),
            fills: false
        ) {
            HStack(spacing: Spacing.sm) {
                Button(SessionsCopy.resetFilters.text(language)) {
                    Task { await model.resetFilters() }
                }
                Button {
                    Task { await shell?.rescan() }
                } label: {
                    Label(SessionsCopy.rescanNow.text(language), systemImage: "arrow.clockwaves")
                }
            }
        }
    }

    /// 仅时间范围收窄导致为空：直接给「查看全部时间」，并与 Shell 同步。
    private var narrowedRangeState: some View {
        EmptyStateView(
            SessionsCopy.emptyRangeTitle.copy.format(language, model.timeRange.displayName(language)),
            systemImage: model.timeRange.symbol,
            message: SessionsCopy.emptyRangeMessage.text(language),
            fills: false
        ) {
            HStack(spacing: Spacing.sm) {
                Button {
                    if let shell { shell.timeRange = .all }
                    Task { await model.setTimeRange(.all) }
                } label: {
                    Label(SessionsCopy.showAllTime.text(language), systemImage: "infinity")
                }
                Button {
                    Task { await shell?.rescan() }
                } label: {
                    Label(SessionsCopy.rescanNow.text(language), systemImage: "arrow.clockwaves")
                }
            }
        }
    }

    /// 列表被筛空的三种原因，各说各的话——合并成一句「无数据」就是在替引擎宣布它没宣布过的结论。
    @ViewBuilder private var emptyState: some View {
        if model.activeFilterCount > 0 {
            filteredOutState
        } else if model.hasNarrowedFilters {
            narrowedRangeState
        } else {
            noDataState
        }
    }

    private func errorPanel(message: String, fillsWholePage: Bool) -> some View {
        Panel {
            HStack(alignment: .top, spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.axBody)
                    .foregroundStyle(ObservatoryColor.caution)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(fillsWholePage ? SessionsCopy.errorFull.text(language)
                                    : SessionsCopy.errorStale.text(language))
                        .font(.axSection)
                        .foregroundStyle(Surface.label)
                    Text(demoRedaction.scrub(message))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.md)
                Button(SessionsCopy.retry.text(language)) {
                    Task { await model.load() }
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: - 详情栏开关

    /// `.inspector` 的开关是**计算属性**：开 = 当前选中项还在列表里，关 = 取消选中。
    /// 不新增存储字段，避免「详情栏关着而模型还以为开着」这种两处真相。
    private var showsDetail: Binding<Bool> {
        Binding(
            get: { model.showsDetailPanel },
            set: { presented in
                guard !presented else { return }
                Task { await model.clearSelection() }
            }
        )
    }
}

// MARK: - 指标区的一格

/// 次级读数的一格。`MetricGrid` 要 `Identifiable`，所以把「有几格、每格说什么」收成值类型。
private struct SessionsMetricTile: Identifiable {
    let id: Int
    let title: String
    let value: String
    var unit: String = ""
    var caption: String?
}

// MARK: - Previews

#Preview("会话列表与详情") {
    ObservatoryPreview.screen { runtime in
        SessionsView(runtime: runtime)
    }
}

#Preview("空状态") {
    ObservatoryPreview.screen(empty: true) { runtime in
        SessionsView(runtime: runtime)
    }
}

private extension SessionsView {
    /// 本次启动的语言（`UILanguage` 一处解析，见其注释）。
    var language: AppLanguage { UILanguage.current }
}
