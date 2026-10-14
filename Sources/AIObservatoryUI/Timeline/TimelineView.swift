//
//  TimelineView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent C) → WS-QUIET-1 (subagent A) 改版
//  时间线主视图（全应用核心）：`ObservatoryPage` 骨架 + 标题行过滤控件 +
//  唯一 hero（服务端事件总数）+ 六格已加载口径指标 + 按天分组的单行事件流 +
//  详情走 `.inspector` 那一列。
//
//  【这次重排掉的是什么】旧根视图是自拼骨架：
//      HStack { VStack { TimelineFilterBar ; List ; Divider ; statusBar } ; 详情列 }
//  那种「页面自己拼滚动 + 分隔线 + 底部条」就是没做完的样子：过滤器占一整行卡片、
//  事件流用 `List`（叠在页面滚动之上＝双滚动）、底部一条状态条把「共 N / 已加载 M /
//  载入更早 / 密度」摊在离数据最远的地方、右侧详情用 `Divider()` 硬接一列。
//  现在：外层只有 `ObservatoryPage` 一个滚动容器；过滤控件收进标题行 trailing；
//  状态条取消、信息并入事件流 `SectionHeader` 的 subtitle 与流末尾的翻页行；
//  详情挂 `.inspector(isPresented:)`。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor struct TimelineView: View {

    @State private var model: TimelineModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: TimelineModel(runtime: runtime))
    }

    // MARK: - Body

    var body: some View {
        ObservatoryPage(SidebarSection.timeline.title, subtitle: pageSubtitle) {
            TimelineFilterControls(model: model)
        } content: {
            pageContent
        }
        .inspector(isPresented: showsDetail) {
            detailColumn
        }
        .task(id: shell?.timeRange) {
            if let shell, model.timeRange != shell.timeRange {
                model.timeRange = shell.timeRange
            }
            // #74 ①：侧栏那个词在**第一次取数之前**落进 `query.searchText` ⇒ 首屏这一次
            // `load()` 就是筛过的（不是先拉全量再本地筛），切回本页也不会先闪一屏未筛的。
            SidebarSearchWiring.seed(fromShell: shell, into: model)
            // #81 ①：跳转意图里的项目 / 会话 / 事件种类在第一次取数之前落进同一条
            // `EventQuery` ⇒ 首屏那一次查询就是筛过的（时间区间由 `shell.jump` 写在全局
            // 那一份上，上面第三行已经跟着同步过，所以这里不必为它多等一次往返）。
            let jumped = EvidenceJumpWiring.seed(fromShell: shell, into: model)
            // 先登记增量订阅，再拉快照。反过来的话 `load()` 这段 await 窗口里
            // 引擎推的 `.timelineEvent` / `.risk` 会整个错过——顺序是修过的真机 bug，不许颠倒。
            async let watching: Void = model.observeUpdates()
            await model.load()
            // #81 ①b：列表真筛小了之后再把「打开哪一行」落上（详情栏跟着开）。
            await EvidenceJumpWiring.focus(jumped, into: model)
            _ = await watching
        }
        // #74 ②：侧栏改词 ⇒ 防抖 300 ms 后交给 `EventQuery.searchText` 走 Store 真查询。
        // 与上面那条 `.task` 各管各的（换时间范围 vs 换词），词没变时一条查询都不发。
        .task(id: shell?.searchText) {
            await SidebarSearchWiring.push(fromShell: shell, into: model)
        }
        // #81 ②：**已经停在时间线**时又点了一次跳转（详情里那颗「只看这一类事件」）
        // ⇒ 落条件并走真查询。意图相等时不重查（判定在桥里）。
        .task(id: shell?.pendingJump) {
            await EvidenceJumpWiring.push(fromShell: shell, into: model)
        }
        // #74 ③：本页过滤条改词 / 「重置」清词 ⇒ 侧栏显示同一个词（两把尺子量不出两个答案）。
        .onChange(of: model.query.searchText) { _, term in
            SidebarSearchWiring.pull(queryTerm: term, into: shell)
        }
        .refreshable { await model.load() }
        .accessibilityLabel(SidebarSection.timeline.title)
    }

    // MARK: - 页面内容

    /// 页面内容区。抽出来是因为 `body` 里再叠一串 if/else 进 `ObservatoryPage` 的双
    /// ViewBuilder 参数会让 type-check 组合爆炸（施工图 §8.2 同一类坑）。
    /// 加载中与空态**不显示** hero 与指标区：那两处数字在那两个状态下必然全是 0，
    /// 0 不是「没有事件」的读数，是还没取到数——与 Dashboard 的分支保持一致。
    @ViewBuilder private var pageContent: some View {
        if let message = model.errorMessage {
            errorBanner(message)
        }

        // #81：这一屏带着跳转条件 ⇒ 必须说出来。只报「筛小了」不说凭什么筛小，
        // 用户读到的仍是「这就是全部」——那是 #81 那个缺陷的另一半。
        EvidenceJumpChip(conditions: model.carriedJumpConditions) {
            await EvidenceJumpWiring.clear(fromShell: shell, into: model)
        }

        if model.isLoading && model.events.isEmpty {
            loadingPanel
        } else if model.events.isEmpty {
            emptyPanel
        } else {
            heroBlock
            metricBlock
            eventStream
        }
    }

    /// 本次启动的语言（`UILanguage` 一处解析，见其注释）。
    private var language: AppLanguage { UILanguage.current }

    // MARK: - 口径说明

    /// 页面副标题：**只留别处没有的那一条信息**（每页上限，它决定「已加载 M / 共 N」怎么读）。
    ///
    /// 删掉的两截：
    /// · 「N 项筛选生效」——hero 下面那行 `InlineStat` 已经报同一个数，同屏两遍；
    /// · 「指标区只统计已加载部分」——那句话归指标区自己的小节标题说（离它统计的对象更近）。
    private var pageSubtitle: String {
        TimelineCopy.pageSubtitle.format(language, model.timeRange.displayName(language), TimelineModel.pageSize)
    }

    /// `.inspector` 的开关：用计算出来的 `Binding` 桥接模型的 `selectedEventID`，
    /// **不新增存储字段**（施工图 §6，命名与 Sessions 页的 `showsDetail` 对齐）。
    /// 关 = 清空选中，而不是「把面板藏起来但记住选中了谁」——
    /// 否则系统开关关掉后再点同一条事件会被 `select()` 的 toggle 语义判成取消。
    private var showsDetail: Binding<Bool> {
        Binding(
            get: { model.showsDetailPanel },
            set: { isPresented in
                guard !isPresented else { return }
                model.clearSelection()
            }
        )
    }

    @ViewBuilder private var detailColumn: some View {
        if let event = model.selectedEvent {
            TimelineEventDetail(event: event, onClose: { model.clearSelection() })
                .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        } else {
            // `showsDetailPanel` 为真才会打开这一列，所以这里只是重查那一瞬间的防御落点，
            // 绝不能留白屏。
            EmptyStateView(
                TimelineCopy.noSelectionTitle.text(language),
                systemImage: "cursorarrow.rays",
                message: TimelineCopy.noSelectionMessage.text(language),
                fills: false
            )
            .inspectorColumnWidth(min: 300, ideal: 340, max: 420)
        }
    }

    // MARK: - hero（全页唯一）

    /// 全页唯一的 `.hero`（40pt）= **服务端事件总数 `model.totalCount`**。
    ///
    /// 为什么是这个数：进这一页第一个要回答的问题是「这个范围里到底发生了多少行为」。
    /// `totalCount` 由服务端按整份 `EventQuery`（时间范围 + Agent + 操作类型 + 风险 + 搜索）
    /// 算出，分页不影响它，是权威总数。
    ///
    /// 为什么不选别的：
    /// - `events.count` 只是本地已加载窗口（首页上限 `pageSize` = 200），拿它当主读数
    ///   会在第 201 条开始说谎——而「界面在说谎」正是本仓的主要缺陷类别；
    /// - 「最活跃时段」「风险事件数」这类由已加载集合算出来的次要读数，
    ///   降级到下面的 `MetricGrid`（22pt）与 `InlineStat` 说明行。
    private var heroBlock: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                StatTile(
                    title: TimelineCopy.heroTitle.text(language),
                    value: "\(model.totalCount)",
                    unit: TimelineCopy.unitItems(language),
                    caption: ReadoutCopy.serverTotalCaption,
                    emphasis: .hero
                )
                // hero 自己的口径行。⚠️ 这里**不排**「本页已加载 M 条」：M 由事件流那一节的
                // 标题「已加载 M / 共 N」报（那是全站口径允许的第二处——分页操作就在那张列表上，
                // 数字要离它最近）。原来两处都排，于是全部加载完的那一屏上，同一个 176
                // 会出现在 hero 大数、这一格、以及流标题三个位置（真机实拍 01:57 就是这样）。
                HStack(spacing: Spacing.md) {
                    InlineStat(TimelineCopy.daysCoveredLabel.text(language),
                               value: TimelineCopy.daysCoveredValue.format(language, model.loadedDayCount))
                    // 「筛选条件 无」是一格零信息：没有条件时这一句不提供任何可行动的事实，
                    // 却和别的读数并排，读起来像三项里的一项有结论。
                    // 与 Sessions 页同一条规则：零信息不排格（见 `SessionsModel.heroSupplementaryStats`）。
                    if model.activeFilterCount > 0 {
                        InlineStat(TimelineCopy.filterCountLabel.text(language),
                                   value: TimelineCopy.filterCountValue.format(language, model.activeFilterCount))
                    }
                    Spacer(minLength: Spacing.none)
                }
                .padding(.top, Spacing.xs)
            }
        }
    }

    // MARK: - 指标区

    /// 六格 × **3 列**＝两整行，一行必须填满（`MetricGrid` 末行会补空 spacer，
    /// 但 6 是 3 的整数倍，所以永远没有孤卡）。
    ///
    /// 六格**全部**由已加载的 `events` 算出，与服务端 `totalCount` 不是同一个口径
    /// （施工图 §7：不写口径就是界面在说谎）。但口径只在**小节标题里说一次**：
    /// 原来六格 caption 各自重复「已加载 200 条里…」，六个相同前缀正是用户说的「拥挤」。
    private var metricBlock: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    TimelineCopy.metricsTitle.text(language),
                    subtitle: TimelineCopy.metricsSubtitle.text(language)
                )
                Hairline()
                MetricGrid(metricTiles, columns: Sizing.summaryColumns) { tile in
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

    private var metricTiles: [TimelineMetricTile] {
        var tiles: [TimelineMetricTile] = []

        tiles.append(TimelineMetricTile(
            id: 0,
            title: TimelineCopy.riskTileTitle.text(language),
            value: "\(model.riskEventCount)",
            unit: TimelineCopy.unitItems(language),
            caption: TimelineCopy.riskTileCaption.format(language, model.loadedCriticalEventCount)
        ))

        if let busiest = model.busiestHour {
            tiles.append(TimelineMetricTile(
                id: 1,
                title: TimelineCopy.busiestTileTitle.text(language),
                // `HH:mm:ss` 只留「时:分」——分位恒为 00，是整点分桶的结果，不是读数。
                value: String(DateFormat.time(busiest.start).prefix(5)),
                unit: TimelineCopy.busiestTileUnit.format(language, busiest.count),
                caption: TimelineCopy.busiestTileCaption.text(language)
            ))
        } else {
            tiles.append(TimelineMetricTile(
                id: 1,
                title: TimelineCopy.busiestTileTitle.text(language),
                value: "—",
                caption: TimelineCopy.busiestTileEmptyCaption.text(language)
            ))
        }

        tiles.append(TimelineMetricTile(
            id: 2,
            title: TimelineCopy.commandTileTitle.text(language),
            value: "\(model.loadedCommandCount)",
            unit: TimelineCopy.unitItems(language),
            caption: TimelineCopy.commandTileCaption.format(language, model.loadedFailedCommandCount)
        ))

        tiles.append(TimelineMetricTile(
            id: 3,
            title: TimelineCopy.fileTileTitle.text(language),
            value: "\(model.loadedFileChangeCount)",
            unit: TimelineCopy.unitLocations(language),
            caption: TimelineCopy.fileTileCaption.format(language, model.loadedFileDeletedCount)
        ))

        tiles.append(TimelineMetricTile(
            id: 4,
            title: TimelineCopy.agentTileTitle.text(language),
            value: "\(model.loadedAgentKindCount)",
            unit: TimelineCopy.unitTypes(language),
            caption: TimelineCopy.agentTileCaption.text(language)
        ))

        tiles.append(TimelineMetricTile(
            id: 5,
            title: TimelineCopy.spanTileTitle.text(language),
            value: model.loadedSpanText,
            // 「更早的要翻页」必须真的还有更早的才能说：本页已含全部时说这句就是假话
            // （真机截图上正是 80 / 共 80 的全加载状态）。
            caption: model.events.count < model.totalCount
                ? TimelineCopy.spanTileCaptionPaged.text(language)
                : TimelineCopy.spanTileCaptionAll.text(language)
        ))

        return tiles
    }

    // MARK: - 事件流

    /// 事件流面板。**这里不再有 `List`**：外层基座自带滚动容器，页面里再放一个列表容器
    /// 就是双滚动。随之删掉的旧写法：`.listRowInsets` / `.listRowSeparator(.hidden)` /
    /// `.listRowBackground(Color.clear)` / `.listStyle(.inset)` / `.scrollContentBackground(.hidden)`
    /// 以及铺在流区域上的那条「主色 3% 自造灰底」——最后那条就是「脏」的字面来源。
    ///
    /// 全页**只有一处**懒栈容器，就是这里——事件数量没有上界，必须懒。
    /// 里面只有「一行文本 + 一个按钮」的事件行与 `Hairline`，**没有**任何 `.menu` 控件：
    /// 密度 `Picker` 在 `SectionHeader` 的 trailing（有界、懒容器之外）。
    private var eventStream: some View {
        // body 顶部绑一次：`dayBuckets` 每读一次就把整表重排一遍并新建数组。
        let buckets = model.dayBuckets
        return Panel(padding: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(TimelineCopy.streamTitle.text(language), subtitle: streamSubtitle) {
                    densityPicker
                }
                LazyVStack(alignment: .leading, spacing: Spacing.none) {
                    ForEach(Array(buckets.enumerated()), id: \.element.id) { index, bucket in
                        dayGroup(bucket, showsSeparator: index > 0)
                    }
                    paginationFooter
                }
            }
        }
    }

    /// 事件流副标题：原底部状态条的「共 N · 已加载 M」并入这里（口径离数据最近）。
    private var streamSubtitle: String {
        TimelineCopy.streamSubtitle.format(language, model.loadedProgressText)
    }

    /// 一天的分组：组头 + 行 + 行间 `Hairline()`。
    /// 组与组之间、行与行之间都只画一条 1pt 线，不画框、不做胶囊填充。
    private func dayGroup(_ bucket: TimelineDayBucket, showsSeparator: Bool) -> some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            if showsSeparator {
                Hairline(inset: TimelineMetrics.hairlineInset)
                    .padding(.top, Spacing.md)
            }
            dayHeader(for: bucket)
            ForEach(Array(bucket.events.enumerated()), id: \.element.id) { index, event in
                if index > 0 {
                    Hairline(inset: TimelineMetrics.hairlineInset)
                }
                eventRow(event)
            }
        }
    }

    /// 单条事件行。抽成独立 `func` 而不是一长串内联闭包——
    /// 嵌套 `ForEach` 里塞完整行视图会得到 `unable to type-check in reasonable time`。
    private func eventRow(_ event: TimelineEvent) -> some View {
        TimelineEventRow(
            event: event,
            density: model.density,
            isSelected: model.selectedEventID == event.id
        ) {
            model.select(event.id)
        }
    }

    private func dayHeader(for bucket: TimelineDayBucket) -> some View {
        HStack(spacing: Spacing.sm) {
            Text(relativeDayLabel(for: bucket.events))
                .font(.axSection)
                .foregroundStyle(Surface.label)
            Text(DateFormat.day(bucket.day))
                .font(.axMetaMono)
                .monospacedDigit()
                .foregroundStyle(Surface.tertiaryLabel)
            Spacer(minLength: Spacing.sm)
            if bucket.riskCount > 0 {
                // 风险日一眼可见：`TimelineDayBucket.riskCount` 早就算好了，旧版只是没渲染。
                // 旧写法是「非阶梯小字号 + 装饰橙」，现在走 `Tag` 的色点 + 文字。
                Tag(TimelineCopy.dayRiskCount.format(language, bucket.riskCount), tone: .caution)
            }
            Text(TimelineCopy.dayGroupCount.format(language, bucket.events.count))
                .font(.axMeta)
                .monospacedDigit()
                .foregroundStyle(Surface.secondaryLabel)
        }
        .padding(.horizontal, Spacing.sm)
        .frame(minHeight: Sizing.rowMinHeight)
        .accessibilityElement(children: .combine)
    }

    /// 用 Calendar 判定「今天 / 昨天」，禁止手写时间戳算术。
    private func relativeDayLabel(for events: [TimelineEvent]) -> String {
        guard let reference = events.first?.timestamp else { return TimelineCopy.dayUnknown.text(language) }
        let calendar = Calendar.current
        if calendar.isDateInToday(reference) { return TimelineCopy.dayToday.text(language) }
        if calendar.isDateInYesterday(reference) { return TimelineCopy.dayYesterday.text(language) }
        return TimelineCopy.dayEarlier.text(language)
    }

    // MARK: - 翻页（原底部状态条的尾部，现在挂在流的末尾）

    @ViewBuilder private var paginationFooter: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Hairline(inset: TimelineMetrics.hairlineInset)
            HStack(spacing: Spacing.sm) {
                if model.isLoadingMore {
                    ProgressView()
                        .controlSize(.small)
                    Text(TimelineCopy.loadingEarlier.text(language))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                } else if model.hasMore {
                    Button {
                        Task { await model.loadMore() }
                    } label: {
                        Text(TimelineCopy.loadEarlier.text(language))
                    }
                    .controlSize(.small)
                    // 这里原来还跟一句「还有 N 条未加载」。删掉：未加载条数 = 共 N − 已加载 M，
                    // 而这两个操作数就在本节标题上（`streamSubtitle` 那句
                    // 「已加载 M / 共 N」）——同一个数在一屏里第三次出现，正是全站口径要收的。
                } else if !model.isEmptyLoad {
                    // 只报状态，不再带 `loadedProgressText`：那句「已加载 M / 共 N」就在本节
                    // 标题上（`streamSubtitle`），这一行是它的下沿，重复一遍就是第三次。
                    Text(TimelineCopy.reachedOldest.text(language))
                        .font(.axMeta)
                        .monospacedDigit()
                        .axCaptionStyle()   // #99：承载口径，曾在最低档
                }
                Spacer(minLength: Spacing.sm)
            }
            .padding(.horizontal, Spacing.sm)
            .frame(minHeight: Sizing.rowMinHeight)
        }
        .padding(.top, Spacing.xs)
    }

    // MARK: - 密度（有界控件，待在懒容器之外）

    private var densityPicker: some View {
        Picker(TimelineCopy.densityLabel.text(language), selection: Binding(
            get: { model.density },
            set: { model.density = $0 }
        )) {
            ForEach(TimelineDensity.allCases) { density in
                Label(density.displayName, systemImage: density.symbol).tag(density)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .frame(width: TimelineMetrics.densityPickerWidth)
        .help(TimelineCopy.densityHelp.text(language))
        .accessibilityLabel(TimelineCopy.densityA11yLabel.text(language))
    }

    // MARK: - 加载 / 空 / 错误

    private var loadingPanel: some View {
        Panel {
            HStack(spacing: Spacing.md) {
                ProgressView()
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(TimelineCopy.loadingTitle.text(language))
                        .font(.axBody)
                        .foregroundStyle(Surface.label)
                    Text(TimelineCopy.loadingNote.format(language, TimelineModel.pageSize))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.none)
            }
        }
    }

    private var emptyPanel: some View {
        Panel {
            EmptyStateView(
                TimelineCopy.emptyTitle.text(language),
                systemImage: "clock.arrow.circlepath",
                message: model.activeFilterCount > 0
                    ? TimelineCopy.emptyFilteredMessage.format(language, model.totalCount)
                    : TimelineCopy.emptyNoDataMessage.text(language)
            ) {
                if model.activeFilterCount > 0 {
                    Button(TimelineCopy.resetFilters.text(language)) {
                        Task { await model.resetFilters() }
                    }
                }
            }
            .frame(minHeight: 200)
        }
    }

    /// 整页唯一的错误呈现：旧版这里有两套（空态整屏 + 流右上角一个自造白底浮层
    /// `inlineError`，那个用圆角矩形 `fill` 出来的白底是我们自己画的假浮层）。
    /// 现在一律收成页面顶部一条 banner，重试入口只有一个。
    private func errorBanner(_ message: String) -> some View {
        Panel {
            HStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.axSection)
                    .foregroundStyle(ObservatoryColor.caution)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(TimelineCopy.errorTitle.text(language))
                        .font(.axSection)
                        .foregroundStyle(Surface.label)
                    Text(message)
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Spacing.md)
                Button(TimelineCopy.retry.text(language)) {
                    Task { await model.load() }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - 指标格值类型

/// 指标区的一格（值类型）。`MetricGrid` 要求数据是 `Identifiable`，
/// 所以把六个读数收成值数组，布局与取数分开——与 Dashboard 同一写法。
/// 注意这里**不带 emphasis**：本页唯一的 `.hero` 由 `heroBlock` 画，这六格全是 22pt 次级读数。
private struct TimelineMetricTile: Identifiable {
    let id: Int
    let title: String
    let value: String
    var unit: String = ""
    var caption: String? = nil
}

// MARK: - Previews

#Preview("时间线") {
    ObservatoryPreview.screen { runtime in
        TimelineView(runtime: runtime)
    }
}

#Preview("空状态") {
    ObservatoryPreview.screen(empty: true) { runtime in
        TimelineView(runtime: runtime)
    }
}
