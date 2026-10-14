//
//  CommandsView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI
//  ─────────────────────────────────────────────────────────
//  Commands 板块入口（需求④「终端命令审计：命令 / 退出结果 / 耗时」）：
//  指标区（hero = 失败命令数）→ 过滤条 → 全局命令列表（左）/ 命令详情（右）主从区。
//  与 `SessionCommandList`（会话内嵌套视图）的分工：这里查的是**全库**，
//  跨会话、跨 Agent，是所有被审计命令的第一等入口。
//
//  视觉语言：全部落在 quiet 基座上（`ObservatoryPage` + `Panel` + 七级排版阶梯）。
//  本页没有 `.shadow`、没有 `Material`、没有装饰配色——颜色只留给两件会改变读者判断的
//  事：**风险等级**与**失败退出码**。旧版那条「底部计数条」已拆进指标区的 caption 与
//  `InlineStat` 行；信息一条没少，只是回到了有主次的地方。
//
//  诚实规则（渲染层也守）：没有退出码 → 「结果未知」，没有 `endedAt` → 「—」。
//  「没有采到退出码」「退出码非 0」两条说明原文保留，不做任何美化性改写。
//
//  【冻结签名】Shell 以 `CommandsView(runtime: ObservatoryRuntime)` 挂载本板块。
//  `CommandsModel` 只读：本页不产生任何取数与文案口径，只做排布。
//

import SwiftUI
import Observation
import AIObservatoryCore

// MARK: - 主从区高度带

/// 主从区的高度带。`List` 坐在 `ObservatoryPage` 的 `ScrollView` 里，
/// **必须**拿到确定高度，否则塌成 0；旧版用 `GeometryReader` 求宽，
/// 而 `GeometryReader` 在 `ScrollView` 内会把高度也塌掉，所以整块换成定高带。
/// `Sizing` 没有这一档（它是页面级常量），故把本板块仅有的两个数集中在这里，
/// 而不是散进调用点。
private enum CommandsSplitBand {
    static let minHeight: CGFloat = 520
    static let maxHeight: CGFloat = 620
}

// MARK: - 板块入口

@MainActor struct CommandsView: View {

    @State private var model: CommandsModel
    @Environment(ShellModel.self) private var shell: ShellModel?
    /// #89：错误面板走 `SectionHeader`（已在组件里掩），但 `staleBanner` 那句是自己画的。
    @Environment(\.demoRedaction) private var demoRedaction
    /// 详情面板要按 sessionID 反查会话标题，因此同样只依赖注入的 runtime。
    private let runtime: ObservatoryRuntime

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        _model = State(initialValue: CommandsModel(runtime: runtime))
    }

    var body: some View {
        ObservatoryPage(
            SidebarSection.commands.title,
            subtitle: "\(model.timeRange.displayName(UILanguage.current)) · \(model.progressText)"
        ) {
            // 页面级操作，两个封顶：分页推进口（原底部状态条搬来）+ 手动重读。
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    if model.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(CommandsCopy.loadMore.text(language))
                    }
                }
                .controlSize(.small)
                .disabled(model.isLoadingMore)
            }
            Button {
                Task { await model.load() }
            } label: {
                Label(CommandsCopy.reload.text(language), systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        } content: {
            // #81：这一屏带着跳转条件 ⇒ 必须说出来（读的是本页那条真 `CommandQuery`）。
            EvidenceJumpChip(conditions: model.carriedJumpConditions) {
                await EvidenceJumpWiring.clear(fromShell: shell, into: model)
            }
            // 有数据时的读取失败不再盖浮层：降级成一条下沉横幅，说清「数字可能不完整」。
            if let message = model.errorMessage, !model.records.isEmpty {
                staleBanner(message)
            }

            if hasRecords {
                metricPanel
            }

            statePanel

            // 过滤条在任何一态都留在页面上：空态时要靠它放宽条件，不能只给「重置」。
            CommandsFilterBar(model: model)

            if hasRecords {
                splitPanel
            }
        }
        .task(id: shell?.timeRange) {
            if let shell, model.timeRange != shell.timeRange {
                model.timeRange = shell.timeRange
            }
            // #74 ①：侧栏那个词在第一次取数之前落进 `CommandQuery.searchText`；
            // #81 ①：跳转条件（这一格收得下的是会话、项目与时间区间）落进**同一条**查询
            // ⇒ 首屏那一次 `commands(matching:)` 就是筛过的。
            SidebarSearchWiring.seed(fromShell: shell, into: model)
            let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
            await model.load()
            await EvidenceJumpWiring.focus(jumped, into: model)
            await model.observeUpdates()
        }
        // #81 ②：已经停在本页时又来了一条意图 ⇒ 落条件并走真查询（相等不重查，判定在桥里）。
        .task(id: shell?.pendingJump) {
            await EvidenceJumpWiring.push(fromShell: shell, into: model)
        }
        // #74 ②：侧栏改词 ⇒ 防抖后下推进 `CommandQuery.searchText`，走 Store 真查询。
        .task(id: shell?.searchText) {
            await SidebarSearchWiring.push(fromShell: shell, into: model)
        }
        // #74 ③：本页过滤条改词 ⇒ 侧栏显示同一个词。
        .onChange(of: model.criteria.searchText) { _, term in
            SidebarSearchWiring.pull(queryTerm: term, into: shell)
        }
        .refreshable { await model.load() }
    }

    private var hasRecords: Bool { !model.records.isEmpty }

    private var language: AppLanguage { UILanguage.current }

    // MARK: - 指标区（本页唯一的 .hero 在这里）

    /// 四个读数填满一行（`columns: 4`），`successCount` / `runningCount` 降级成
    /// `InlineStat` 排在下面一行——指标数不是 4 的倍数时留一张孤卡就是「不规整」。
    ///
    /// **hero 给「失败命令数」的理由**：这是本页唯一一个「用户必须现在行动」的数——
    /// 其余读数（总数 / 结果未知 / 破坏性）都是背景，只有失败命令决定读者要不要
    /// 往下查详情。给它 40pt，其余一律降到 22pt，主次就落在语义上而不是装饰上。
    private var metricPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.md) {
                MetricGrid(tiles, columns: Sizing.metricColumns) { tile in
                    StatTile(
                        title: tile.title,
                        value: tile.value,
                        caption: tile.caption,
                        emphasis: tile.emphasis
                    )
                }

                Hairline()

                HStack(spacing: Spacing.xl) {
                    InlineStat(CommandsCopy.succeeded.text(language), value: "\(model.successCount)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    InlineStat(CommandsCopy.statRunning.text(language), value: "\(model.runningCount)")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    // 「未加载 0」不排格：它说的就是「全在这一页了」，
                    // 而这句话上方 30pt 的副标题「共 19 条命令 · 已加载 19」已经说过。
                    // 「成功 0」留着——那是有对象的结论（19 条里确实没有一条成功）。
                    if model.unloadedCount > 0 {
                        InlineStat(CommandsCopy.statUnloaded.text(language), value: "\(model.unloadedCount)")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    InlineStat(CommandsCopy.statMeasuredDuration.text(language),
                               value: DurationFormat.compact(model.measuredDuration))
                        .help(CommandsCopy.measuredDurationHelp.text(language))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    /// 四个读数收成值类型喂给 `MetricGrid`（它要 `Identifiable`），布局与取数就此分开。
    private var tiles: [CommandTile] {
        [
            CommandTile(
                id: 0,
                title: CommandsCopy.tileFailedTitle.text(language),
                value: "\(model.failureCount)",
                caption: CommandsCopy.tileFailedCaption.text(language),
                emphasis: .hero
            ),
            CommandTile(
                id: 1,
                title: CommandsCopy.tileTotalTitle.text(language),
                value: "\(model.totalCount)",
                caption: ReadoutCopy.serverTotalCaption,
                emphasis: .metric
            ),
            CommandTile(
                id: 2,
                title: CommandsCopy.unknownResult.text(language),
                value: "\(model.unknownResultCount)",
                caption: CommandsCopy.tileUnknownCaption.text(language),
                emphasis: .metric
            ),
            CommandTile(
                id: 3,
                title: CommandsCopy.tileDestructiveTitle.text(language),
                value: "\(model.destructiveCount)",
                caption: CommandsCopy.tileDestructiveCaption.text(language),
                emphasis: .metric
            ),
        ]
    }

    // MARK: - 主从区

    /// 列表列定宽收口（不再按窗口比例算宽度），整块给确定高度带：
    /// 里面的 `List` 与详情的 `ScrollView` 都靠它有界。
    private var splitPanel: some View {
        Panel(padding: Spacing.sm) {
            HStack(spacing: Spacing.md) {
                commandList
                    .frame(minWidth: 320, idealWidth: 440, maxWidth: 520)

                Hairline(vertical: true)

                CommandsDetailView(model: model, runtime: runtime)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .frame(minHeight: CommandsSplitBand.minHeight, maxHeight: CommandsSplitBand.maxHeight)
    }

    // MARK: - 左：命令列表

    /// 内嵌列表用 `Surface.recessed` 下沉一级（旧版是 `.primary.opacity(0.03)` 自造灰）。
    private var commandList: some View {
        List(selection: selectionBinding) {
            ForEach(model.records) { record in
                commandRow(record)
            }

            if model.isLoadingMore {
                loadingMoreRow
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Surface.recessed)
        // List(selection:) 在行身份整体变化后会复用旧选中下标，靠 revision 强制重建（与 Sessions 一致）。
        .id(model.listRevision)
        .animation(ObservatoryMotion.value, value: model.records.count)
    }

    /// 行视图必须抽成独立 `func`：内联在 `List { ForEach { … } }` 里
    /// 一长就 `unable to type-check in reasonable time`（本页踩过）。
    private func commandRow(_ record: CommandRecord) -> some View {
        CommandAuditRow(
            record: record,
            isSelected: model.selectedID == record.id
        ) {
            model.select(record.id)
        }
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: Spacing.sm,
            bottom: 0,
            trailing: Spacing.sm
        ))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    private var loadingMoreRow: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(CommandsCopy.loadingEarlierRows.text(language))
                .axCaptionStyle()   // #99：口径句提档（原 .axMeta + tertiary）
        }
        .frame(minHeight: Sizing.rowMinHeight)
        .listRowInsets(EdgeInsets(
            top: 0,
            leading: Spacing.sm,
            bottom: 0,
            trailing: Spacing.sm
        ))
        .listRowBackground(Color.clear)
        .listRowSeparator(.hidden)
    }

    /// `List(selection:)` 与模型选中态打通：键盘上下键即可切换命令。
    private var selectionBinding: Binding<UUID?> {
        Binding(
            get: { model.selectedID },
            set: { next in model.select(next) }
        )
    }

    // MARK: - 加载 / 空 / 错误三态

    /// 三态分支语义与旧版逐字一致，只是不再撑满整窗：
    /// loading → error（且为空）→ 三种空态 → 有数据时这里不产出任何东西。
    @ViewBuilder private var statePanel: some View {
        if model.isLoading && model.records.isEmpty {
            loadingPanel
        } else if model.records.isEmpty {
            if let message = model.errorMessage {
                errorPanel(message)
            } else {
                emptyPanel
            }
        }
    }

    private var loadingPanel: some View {
        Panel {
            HStack(spacing: Spacing.md) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(CommandsCopy.loadingAudit.text(language))
                        .font(.axBody)
                        .foregroundStyle(Surface.label)
                }
                Spacer(minLength: Spacing.none)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 200)
        }
    }

    /// 真·没采到：说清是「一条命令都没有」，而不是「被筛没了」。
    /// 三种空态的判定与文案逐字沿用旧版（`activeFilterCount` → `hasNarrowedFilters` → 无数据）。
    private var emptyPanel: some View {
        Panel {
            if model.activeFilterCount > 0 {
                filteredOutState
            } else if model.hasNarrowedFilters {
                narrowedRangeState
            } else {
                noDataState
            }
        }
    }

    private var noDataState: some View {
        EmptyStateView(
            CommandsCopy.emptyNoDataTitle.text(language),
            systemImage: "terminal",
            message: CommandsCopy.emptyNoDataMessage.text(language),
            fills: false
        ) {
            Button {
                Task { await shell?.rescan() }
            } label: {
                Label(CommandsCopy.rescanNow.text(language), systemImage: "arrow.clockwaves")
            }
        }
    }

    /// 被条件筛到空：给出撤销入口，而不是让用户以为没有数据。
    private var filteredOutState: some View {
        EmptyStateView(
            CommandsCopy.emptyFilteredTitle.text(language),
            systemImage: "line.3.horizontal.decrease.circle",
            message: CommandsCopy.emptyFilteredMessage.format(
                language, model.activeFilterCount, model.timeRange.displayName(language)
            ),
            fills: false
        ) {
            HStack(spacing: Spacing.sm) {
                Button(CommandsCopy.resetFilters.text(language)) {
                    Task { await model.resetFilters() }
                }
                Button {
                    Task { await shell?.rescan() }
                } label: {
                    Label(CommandsCopy.rescanNow.text(language), systemImage: "arrow.clockwaves")
                }
            }
        }
    }

    /// 只有时间范围收窄导致为空：直接给「查看全部时间」，并与 Shell 同步。
    private var narrowedRangeState: some View {
        EmptyStateView(
            CommandsCopy.emptyRangeTitle.format(language, model.timeRange.displayName(language)),
            systemImage: model.timeRange.symbol,
            message: CommandsCopy.emptyRangeMessage.text(language),
            fills: false
        ) {
            HStack(spacing: Spacing.sm) {
                Button {
                    if let shell { shell.timeRange = .all }
                    Task { await model.setTimeRange(.all) }
                } label: {
                    Label(CommandsCopy.viewAllTime.text(language), systemImage: "infinity")
                }
                Button {
                    Task { await shell?.rescan() }
                } label: {
                    Label(CommandsCopy.rescanNow.text(language), systemImage: "arrow.clockwaves")
                }
            }
        }
    }

    /// 错误态不再画 34pt 大图标 + `.orange`：`SectionHeader` 承担标题，
    /// 消息走副标题，重试留在右侧操作区。
    private func errorPanel(_ message: String) -> some View {
        Panel {
            SectionHeader(CommandsCopy.readFailedTitle.text(language), subtitle: message) {
                Button(CommandsCopy.retry.text(language)) {
                    Task { await model.load() }
                }
                .controlSize(.small)
            }
        }
    }

    /// 有数据但这一轮读取失败：结果可能不完整，必须说，不能安静地显示旧列表。
    private func staleBanner(_ message: String) -> some View {
        Panel.recessed(padding: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                Tag(CommandsCopy.staleReadTag.text(language), tone: .caution)
                Text(demoRedaction.scrub(message))
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer(minLength: Spacing.md)
                Button(CommandsCopy.retry.text(language)) {
                    Task { await model.load() }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - 指标区的一格

/// 指标区的一格。`MetricGrid` 要 `Identifiable` 的数据，所以把四个读数收成值类型
/// （与 `DashboardTile` 同一画法）——谁该大谁该小在数据里就写死，不留给布局猜。
private struct CommandTile: Identifiable {
    let id: Int
    let title: String
    let value: String
    let caption: String?
    let emphasis: StatTile.Emphasis
}




// MARK: - Previews

#Preview("命令审计") {
    ObservatoryPreview.screen { runtime in
        CommandsView(runtime: runtime)
    }
}

#Preview("命令审计 · 空状态") {
    ObservatoryPreview.screen(empty: true) { runtime in
        CommandsView(runtime: runtime)
    }
}
