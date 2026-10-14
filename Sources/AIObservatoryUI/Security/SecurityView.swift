//
//  SecurityView.swift
//  AIObservatoryUI / Security
//
//  Owner: WS-UI → WS-QUIET-3（本轮按 ADR-0007 重排到「quiet」语言）
//  ─────────────────────────────────────────────────────────
//  安全风险板块入口（需求模块⑧）：外层 `ObservatoryPage`、唯一的 `.hero`（高危待处置）、
//  四个次级读数、过滤面板、事件列表 + 详情，人工确认闭环。
//  确认动作真实调用 runtime.controller.acknowledgeRiskEvent(id:)。
//
//  为什么这里**没有** `List` 与内层 `ScrollView`：`ObservatoryPage` 自己就是
//  `ScrollView { VStack(spacing: Spacing.section) }`，再嵌一个滚动容器会得到
//  「滚轮到底部后另一个列表接着滚」的手感，而且嵌套滚动容器在懒回收时
//  正是本仓性能页自旋的那类根因。列表因此是页面内的 `LazyVStack`（唯一无上限的行列表），
//  代价见 `eventList` 的注释。
//

import SwiftUI
import AIObservatoryCore

/// 安全风险主视图。
@MainActor
struct SecurityView: View {

    private var language: AppLanguage { UILanguage.current }
    @State private var model: SecurityModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: SecurityModel(runtime: runtime))
    }

    /// #77 的**测试接缝**（页面正常装配走 `init(runtime:)`，装配根里没有第二个调用者）。
    ///
    /// 为什么非要有这条口子：本页的缺陷恰好是「`errorMessage` 被设了值，但只有
    /// `events.isEmpty` 那一支渲染它」——而点确认时列表**必然非空**。
    /// 要在机器里证明这句话真的上了屏，就得把「列表非空 + 有错误」这一形状渲染一次；
    /// 只测 Model 等于回到「注释承诺、代码没做」的老路（`ShippedCopyHonestyTests` 钉的那一类）。
    init(model: SecurityModel) {
        _model = State(initialValue: model)
    }

    // MARK: - Body

    var body: some View {
        @Bindable var model = model
        // 排序与读数各只算一次：`sortedEvents` / `pendingHighRiskCount` / 四个计数
        // 原先在 body 里被分别读，每一处都要重过一遍 events。
        let events = model.sortedEvents
        let readouts = model.readouts

        ObservatoryPage(
            SidebarSection.security.title,
            subtitle: "\(model.range.displayName(UILanguage.current)) · \(model.loadSummary)"
        ) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(SecurityCopy.pendingHighHero.format(language, readouts.pendingHighRiskCount))
                .font(.axMeta)
                .monospacedDigit()
                .axCaptionStyle()   // #99：口径句提档
                .contentTransition(.numericText())
        } content: {
            // #81：这一屏带着跳转条件 ⇒ 必须说出来（读的是本页那条真 `RiskQuery`，不是外壳那份）。
            EvidenceJumpChip(conditions: model.carriedJumpConditions) {
                await EvidenceJumpWiring.clear(fromShell: shell, into: model)
            }
            heroCard(readouts: readouts)
            Panel {
                MetricGrid(securityTiles(readouts: readouts), columns: Sizing.metricColumns) { tile in
                    StatTile(
                        title: tile.title,
                        value: tile.value,
                        caption: tile.caption
                    )
                }
            }
            SecurityFilterBar(model: model)
            Grid(alignment: .top, horizontalSpacing: Spacing.lg, verticalSpacing: Spacing.md) {
                GridRow {
                    eventList(events: events)
                    detailPane(events: events)
                }
            }
        }
        .onChange(of: shell?.timeRange, initial: true) { _, newValue in
            // 时间范围**只有一个入口**（顶栏），这里单向同步进来；
            // 过滤条里不再放第二个范围选择器，见 `SecurityFilterBar`。
            if let newValue { model.range = newValue }
        }
        .task {
            // #74 ①：侧栏那个词在第一次取数之前落进 `RiskQuery.searchText`；
            // #81 ①：跳转条件（这一格收得下的是会话、项目与时间区间）落进**同一条** `RiskQuery`
            // ⇒ 首屏那一次 `riskEvents(matching:)` 就是筛过的，不先画一屏未筛的再跳一下。
            SidebarSearchWiring.seed(fromShell: shell, into: model)
            let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
            await model.load()
            // #81 ①b / #59：取数之后再落「打开哪一条」。高危通知那条只带一个风险 id 的例外
            // 已经收进 `JumpIntent.eventID`（旧的那条 `.onChange(of: shell?.pendingRiskEventID)`
            // 与 `ShellModel.pendingRiskEventID` 那个读写口一并删净，不留兼容壳）：
            // 冻结区 `RiskNotifications` 现在直接 `shell.jump(...)`，读取端就是下面这一条 focus。
            await EvidenceJumpWiring.focus(jumped, into: model)
            await model.observeUpdates()
        }
        // #81 ②：已经停在本页时又来了一条意图（另一条高危通知、别页跳过来）⇒ 落条件、重查、定位那一行。
        .task(id: shell?.pendingJump) {
            await EvidenceJumpWiring.push(fromShell: shell, into: model)
        }
        // #74 ②：侧栏改词 ⇒ 防抖后下推进 `RiskQuery.searchText`，走 Store 真查询。
        .task(id: shell?.searchText) {
            await SidebarSearchWiring.push(fromShell: shell, into: model)
        }
        // #74 ③：本页过滤条改词 ⇒ 侧栏显示同一个词（两把尺子量不出两个答案）。
        .onChange(of: model.query.searchText) { _, term in
            SidebarSearchWiring.pull(queryTerm: term, into: shell)
        }
        .task(id: model.filterToken) {
            await model.load()
        }
        .refreshable { await model.load() }
        .sheet(item: $model.confirmationTarget) { event in
            SecurityConfirmationSheet(model: model, event: event)
        }
    }

    // MARK: - Hero

    /// 本页**唯一**的 40pt 主读数：高危待处置条数。
    ///
    /// 为什么是它：全页只有这一个数会改变读者的下一步动作
    /// （> 0 就该现在去看是哪几条）。今日风险、敏感路径命中、已确认条数
    /// 都是「知道就好」的量，放到 22pt 一档就够——旧版五个读数同一档字号，
    /// 就是用户说的「没有主次」。
    ///
    /// ⚠️ caption 必须把**统计范围**写在脸上：这些计数是按当前**已加载**的那一页
    /// （`SecurityModel.pageSize = 100`，内存上限 `eventCap = 500`）算的，
    /// 而 `totalCount` 是全库命中数。少了这句，「高危待处置 0」会被读成
    /// 「这台机器没有高危」——那是假阴性结论，比报错更糟。
    private func heroCard(readouts: SecurityReadouts) -> some View {
        Panel {
            StatTile(
                title: SecurityCopy.tilePendingHigh.text(language),
                value: "\(readouts.pendingHighRiskCount)",
                caption: SecurityCopy.tilePendingHighCaption.format(
                    language, readouts.loadedCount, readouts.totalCount),
                emphasis: .hero
            )
        }
    }

    /// 四个次级读数：一行 4 格填满，不留孤卡。
    ///
    /// 旧版这里另有 `CRITICAL` / `HIGH` 两格，与过滤条上每个等级自带的条数重复，
    /// 同一页两处列同一组数就是「东一个西一个」；等级分布现在只在过滤条上给一次。
    private func securityTiles(readouts: SecurityReadouts) -> [SecurityMetricTile] {
        [
            SecurityMetricTile(
                id: 0,
                title: SecurityCopy.tileAllPending.text(language),
                value: "\(readouts.pendingCount)",
                caption: SecurityCopy.tileAllPendingCaption.text(language)
            ),
            SecurityMetricTile(
                id: 1,
                title: SecurityCopy.tileToday.text(language),
                value: "\(readouts.todayTotal)",
                caption: SecurityCopy.tileTodayCaption.text(language)
            ),
            SecurityMetricTile(
                id: 2,
                title: SecurityCopy.tileSensitive.text(language),
                value: "\(readouts.sensitivePathEventCount)",
                caption: SecurityCopy.tileSensitiveCaption.text(language)
            ),
            SecurityMetricTile(
                id: 3,
                title: SecurityCopy.acknowledged.text(language),
                value: "\(readouts.acknowledgedCount)",
                caption: SecurityCopy.tileAcknowledgedCaption.text(language)
            ),
        ]
    }

    // MARK: - 列表

    /// 事件列表。
    ///
    /// ⚠️ 只有这里允许懒容器：它是本页唯一无上限的行列表（上限 `eventCap`）。
    /// 行本身是纯 Text/HStack，**里面不许放 `.menu` Picker 或 Menu**——
    /// 本仓实测过懒容器反复物化含 `.menu` Picker 的卡 ⇒ 滚动自旋、
    /// RSS 每 10 秒 +142 MB、CPU 108.8%、停手 40 秒不回落。
    ///
    /// 换成 `LazyVStack` 的代价（要在交付里说明，不要假装没发生）：
    /// 原来 `List(selection:)` 自带的**键盘方向键选行**没有了，
    /// 只剩鼠标点选与 VoiceOver 的 `.isSelected` 特征。
    ///
    /// #77：错误提示的渲染条件从「`errorMessage != nil && events.isEmpty`」拆成两档
    /// （与 `SessionsView.contentBlocks` 同形，那一页早就分了两档）：
    /// 列表为空 ⇒ 错误顶掉空态整块接管；列表非空 ⇒ 错误挂在行之前。
    /// 旧写法只有前一档 ⇒ 「批量确认」「行菜单确认」这些**列表必然非空**的路径
    /// 把 `errorMessage` 设了值却没有任何视图读它。
    private func eventList(events: [RiskEvent]) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    SecurityCopy.listTitle.text(language),
                    subtitle: SecurityCopy.listSubtitle.text(language)) {
                    Text(SecurityCopy.countedItems(events.count, language))
                        .font(.axMeta)
                        .monospacedDigit()
                        .axCaptionStyle()   // #99：口径句提档
                }

                if model.isLoading && events.isEmpty {
                    loadingState
                } else if let errorMessage = model.errorMessage, events.isEmpty {
                    errorState(errorMessage)
                } else if events.isEmpty {
                    emptyState
                } else {
                    if let errorMessage = model.errorMessage {
                        actionFailedNotice(errorMessage)
                    }
                    LazyVStack(spacing: Spacing.none) {
                        ForEach(events) { event in
                            RiskEventRow(
                                event: event,
                                isSelected: model.selected?.id == event.id
                            ) {
                                model.selected = event
                            }
                            .contextMenu { rowContextMenu(for: event) }
                            Hairline()
                        }
                    }

                    footer(events: events)
                }
            }
        }
        .frame(maxWidth: 460, alignment: .leading)
    }

    /// 分页与批量动作。
    ///
    /// 旧的 `.safeAreaInset(edge: .bottom)` 操作条依赖 `List` 才存在，
    /// 现在它是列表的最后一行——面板内部不需要第二条分隔线，
    /// 上面那行 `Hairline()` 已经分隔了最后一条事件。
    private func footer(events: [RiskEvent]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    Text(model.isLoading ? SecurityCopy.loadingRow.text(language)
                            : SecurityCopy.loadMoreCount.format(language, model.totalCount))
                        .font(.axMeta)
                }
                .buttonStyle(.link)
                .disabled(model.isLoading)
            }

            HStack(spacing: Spacing.sm) {
                Button {
                    Task { await model.acknowledgeAllVisible() }
                } label: {
                    Text(SecurityCopy.markAllAcknowledged.text(language))
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(!model.hasPendingEvents)

                if model.isFiltering {
                    Button(SecurityCopy.clearFilters.text(language)) { model.resetFilters() }
                        .buttonStyle(.link)
                        .controlSize(.small)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func rowContextMenu(for event: RiskEvent) -> some View {
        if !event.isAcknowledged {
            Button(SecurityCopy.markAcknowledged.text(language)) {
                Task { await model.acknowledge(event: event) }
            }
        }
        if event.requiresConfirmation {
            Button(SecurityCopy.reviewConfirmation.text(language)) { model.requestConfirmation(for: event) }
        }
        // #81：这一条风险的取证出口。原来那句 `shell?.select(.timeline)` 就是 #81 的原始缺陷
        // 形状——跳过去了，看到的是全量时间线，读成的却是「这一条风险的来龙去脉」。
        Button(SecurityCopy.viewInTimeline.text(language)) {
            shell?.jump(JumpIntent(target: .timeline,
                                   sessionID: event.sessionID,
                                   timeRange: shell?.timeRange))
        }
    }

    // MARK: - 详情

    @ViewBuilder
    private func detailPane(events: [RiskEvent]) -> some View {
        if let event = model.selectedEvent ?? events.first {
            SecurityDetailPanel(
                event: event,
                onAcknowledge: event.isAcknowledged ? nil : {
                    Task { await model.acknowledge(event: event) }
                },
                onDefer: event.requiresConfirmation ? {
                    model.requestConfirmation(for: event)
                } : nil,
                canJumpToTimeline: shell != nil,
                // #81：详情栏那一颗同样带条件过去（这一条风险所属的会话 + 页头那把时间尺）。
                onJumpToTimeline: {
                    shell?.jump(JumpIntent(target: .timeline,
                                           sessionID: event.sessionID,
                                           timeRange: shell?.timeRange))
                }
            )
        } else {
            Panel {
                EmptyStateView(
                    SecurityCopy.selectEventTitle.text(language),
                    systemImage: "shield.lefthalf.filled",
                    message: SecurityCopy.selectEventMessage.text(language),
                    fills: false
                )
                .frame(minHeight: 240)
            }
        }
    }

    // MARK: - 三态

    private var loadingState: some View {
        HStack(spacing: Spacing.md) {
            ProgressView().controlSize(.small)
            Text(SecurityCopy.readingEvents.text(language))
                .font(.axBody)
                .foregroundStyle(Surface.secondaryLabel)
            Spacer(minLength: Spacing.none)
        }
        .frame(maxWidth: .infinity, minHeight: Sizing.rowMinHeight * 4)
    }

    private func errorState(_ message: String) -> some View {
        SecurityErrorNotice(
            title: SecurityCopy.readFailedTitle.text(language),
            message: message,
            onRetry: { await model.load() }
        )
        .frame(maxWidth: .infinity, minHeight: Sizing.rowMinHeight * 4)
    }

    /// #77：列表**非空**时挂在行之前的失败横幅。两档标题按 `errorOrigin` 取，各说各的事：
    ///  · 确认没落库 ⇒ 直接用 `acknowledge` 写进 `errorMessage` 的那句原话
    ///    （`SecurityCopy.ackSaveFailed`「确认没有保存：…」），不另起一句、不设第二处出处；
    ///  · 读取失败而行还在 ⇒ `errorStaleBelowTitle`（与 `SessionsCopy.errorStale` 同一说法），
    ///    底层原因走 message 那一行原文。
    /// 为什么不放「重试」按钮：这里的重试语义是「再读一次」，会把确认失败的提示
    /// 悄悄抹掉却不重试那一步 —— 那等于换个途径把 #77 要修的毛病做回来。
    /// 真要重做确认，行还在下面，用户点它就是了。
    @ViewBuilder
    private func actionFailedNotice(_ message: String) -> some View {
        if model.errorOrigin == .acknowledgement {
            SecurityErrorNotice(title: message)
        } else {
            SecurityErrorNotice(
                title: SecurityCopy.errorStaleBelowTitle.text(language),
                message: message
            )
        }
    }

    private var emptyState: some View {
        EmptyStateView(
            model.isFiltering ? SecurityCopy.emptyFilteredTitle.text(language)
                : SecurityCopy.emptyNoRiskTitle.text(language),
            systemImage: "checkmark.shield",
            message: model.isFiltering
                ? SecurityCopy.emptyFilteredMessage.text(language)
                : SecurityCopy.emptyNoRiskMessage.text(language),
            fills: false
        ) {
            if model.isFiltering {
                Button(SecurityCopy.clearFilters.text(language)) { model.resetFilters() }
            } else {
                Button(SecurityCopy.rescanNow.text(language)) {
                    guard let shell else { return }
                    Task { await shell.rescan() }
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: Sizing.rowMinHeight * 4)
    }
}

#Preview("Security") {
    ObservatoryPreview.screen { runtime in
        SecurityView(runtime: runtime)
    }
}

#Preview("Security · 空状态") {
    ObservatoryPreview.screen(empty: true) { runtime in
        SecurityView(runtime: runtime)
    }
}

/// 概览网格的一格。
///
/// `MetricGrid` 要 `Identifiable` 的数据，所以把四个读数收成值类型：
/// 布局与取数就此分开。与 `DashboardTile` 同一个形状——**刻意没有 `emphasis`**，
/// 本页唯一的 `.hero` 是「高危待处置」，它不在这张网格里。
private struct SecurityMetricTile: Identifiable, Hashable {
    let id: Int
    let title: String
    let value: String
    let caption: String?
}

/// 失败提示的**唯一**形状（#77）：三处共用这一个出处 ——
/// 整页读失败（`SecurityView.errorState`）、列表上方的横幅（`actionFailedNotice`）、
/// 确认卡内（`SecurityConfirmationSheet`）。
///
/// **这不是新机制**：用的还是本页原本那一份 `EmptyStateView` + `exclamationmark.triangle`
/// +（可选）`SecurityCopy.retry`，没有 toast、没有 alert、没有新图标。
/// 之所以要从 `SecurityView` 的 private 方法拆成视图：留在 private 里正是
/// 「`errorMessage` 被设了值却没有任何视图读它」能成立的原因 ——
/// 确认卡是**模态层**，盖在页面上方，页面那一档即使修好，用户在那张卡里也看不见。
///
/// `message` 允许为空（`EmptyStateView` 本来就跳过空串）：确认失败时标题那句
/// `ackSaveFailed` 已经把原因带全了，不再拼第二句。
@MainActor
struct SecurityErrorNotice: View {
    let title: String
    var message: String = ""
    var onRetry: (@MainActor () async -> Void)?

    var body: some View {
        EmptyStateView(
            title,
            systemImage: "exclamationmark.triangle",
            message: message,
            fills: false
        ) {
            if let onRetry {
                Button(SecurityCopy.retry.text(UILanguage.current)) {
                    Task { await onRetry() }
                }
            }
        }
    }
}
