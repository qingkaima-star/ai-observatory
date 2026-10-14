//
//  DashboardView.swift
//  AIObservatoryUI / Dashboard
//
//  职责：Dashboard 板块入口 —— 首页信息架构按 **#79 裁定的四个区块**依次给出：
//  待查看事项 → 当前观测对象 → 时段摘要 → 活动趋势与关键事件。
//

import SwiftUI
import Observation
import AIObservatoryCore

/// Dashboard 入口视图（Shell 以 `DashboardView(runtime:)` 调用）。
@MainActor
struct DashboardView: View {

    @State private var model: DashboardModel
    /// #89：上屏的是"一条活动"的自由文本 ⇒ 与全站同一把尺（`scrub` 对无路径的串恒等）。
    @Environment(\.demoRedaction) private var demoRedaction
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: DashboardModel(runtime: runtime))
    }

    // MARK: - 全局时间范围

    /// 生效中的时间范围：优先跟随 Shell 顶栏，取不到环境时退回「今天」。
    private var selectedRange: ObservatoryTimeRange {
        shell?.timeRange ?? .today
    }

    /// 首页各列表/卡片**不持 shell**，它们只把"这一行是哪一跳"交回来（#98）。
    /// 区间在这里一次性注入：跳出去的区间与格子上那个数用的是**同一个** `selectedRange`，
    /// 不由各行自己猜，免得出现"格子按 7 天算、点进去是今天"那种两份时间。
    private func jump(_ evidence: DashboardEvidenceJump) {
        shell?.jump(evidence.intent(window: selectedRange))
    }

    private var queryRange: DateRangeFilter {
        selectedRange.dateRange()
    }

    // MARK: - 区块顺序（#79）

    /// 首页的四个区块。**顺序是数据，不是代码写在哪一行的巧合**。
    ///
    /// 台账 `整改波次-2026-09-22` 第六节 S.1 定死这一列：
    /// 待查看事项 → 当前观测对象 → 时段摘要 → 活动趋势与关键事件。
    /// 改前它是「页头 → 六宫格 → 两张图 → 活跃 Agent 列表 → 风险条 → 异常卡」，
    /// 也就是**最不需要立刻处置的东西（时长、命令数）占了首屏，而要看的风险与异常排在最后**。
    /// 把顺序做成数组，`DashboardInformationArchitectureTests` 才能逐格认它；
    /// 只把四行调用摊在 `body` 里，"把某块挪回末尾"这种改动测试是看不见的。
    enum Block: String, CaseIterable, Identifiable {
        /// 待查看事项：最近风险条 + 异常检测卡。
        case toReview
        /// 当前观测对象：此刻在跑的 Agent 进程列表。
        case watched
        /// 时段摘要：所选区间的累计读数（与「当前状态」分组分开）。
        case periodSummary
        /// 活动趋势与关键事件：分桶柱图 + Agent 时长读数。
        case activityTrend

        var id: String { rawValue }
    }

    /// 渲染顺序的唯一出处：`body` 与用例都读它（用例认的是**手推的四格顺序**，
    /// 不是"实现现在长什么样"——见 `DashboardInformationArchitectureTests`）。
    static let blockOrder: [Block] = Block.allCases

    // MARK: - Body

    var body: some View {
        ObservatoryPage(
            SidebarSection.dashboard.title,
            subtitle: DashboardCopy.pageSubtitle.copy.format(
                language, DateFormat.day(model.focusDate), selectedRange.displayName(UILanguage.current)
            )
        ) {
            // 页头右侧只留「这一页在刷新」那一颗转圈。
            // 改前这里还印着「最近事件 N」，而第 4 档那张趋势卡自己就写着同一个数
            // （两处都是 `model.hourlyEventTotal`，同一次取数、同一个口径）⇒ 同一个数一屏两遍，
            // 而且页头那一份连窗口上下文都没有（它写的是所选区间，不是"最近"）。#85 收成一处。
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
        } content: {
            if let message = model.errorMessage {
                errorCard(message)
            }

            ForEach(DashboardView.blockOrder) { block in
                blockView(block)
            }
        }
        .task(id: selectedRange) {
            // 先登记订阅，再拉快照。反过来的话 `load()` + `loadAnomalies()` 这段
            // await 窗口里引擎推的 `.sessions(open)` 会整个错过——
            // 真机上「会话已经建好了但界面显示 0」就有这一层。
            async let watching: Void = model.observeUpdates()
            await model.load(range: queryRange)
            await model.loadAnomalies()
            _ = await watching
        }
        .refreshable {
            await model.load(range: queryRange)
            await model.loadAnomalies()
        }
        .accessibilityLabel(DashboardCopy.pageA11y.text(language))
    }

    // MARK: - 区块内容

    /// 一个区块渲染什么。
    ///
    /// ⚠️ **这里一个取数都没有**（#79 硬约束 / 台账裁定 5）：四个区块全部读 `model`
    /// 已经加载好的那一份载荷。首页每 tick 的预算已经被一次 `dashboardStats` 占掉 91 %
    /// （AGENTS.md §6），重排只许挪区块、不许顺手多查一路。
    @ViewBuilder
    private func blockView(_ block: Block) -> some View {
        switch block {
        case .toReview:
            // 原第 5 位的风险条与原末位的异常卡合并提到首位。
            riskStrip
            anomalyCard
        case .watched:
            // 原第 4 位的运行中 Agent 列表提到第 2 位。
            DashboardActiveAgentsList(agents: model.activeAgents, jump: jump)
        case .periodSummary:
            // 「时段摘要」由所选区间的累计读数承担；库里还没内容时这一档给加载/空态卡。
            if model.hasContent {
                statGrid
            } else {
                stateCard
            }
        case .activityTrend:
            // 没有内容时不画两张空图：上面那张卡已经把"为什么还没有图"说清了。
            if model.hasContent {
                trendRow
            }
        }
    }

    /// 时段摘要那一档在「还没有内容」时给什么：加载中与空库两句话。
    ///
    /// `hasContent == false` 已经是外层条件，所以这里只需分辨它在不在加载。
    @ViewBuilder
    private var stateCard: some View {
        if model.isLoading {
            loadingCard
        } else {
            emptyCard
        }
    }

    // MARK: - 时段摘要（第 3 档）

    /// 六项读数排成 **3 列 × 2 行**，第一个是本页唯一的 `.hero`。
    ///
    /// 为什么不是原来的自适应 5 列：`.adaptive(minimum: 168)` 在宽窗口下一行塞 5 个、
    /// 第 6 个（风险事件）孤零零挂在下一行，而且六个读数全是同一档字号
    /// ——那就是「不规整 + 没有主次」。本页最重要的数是活跃总时长，
    /// 它决定用户要不要继续往下看，所以给它 40pt，其余降到 22pt。
    ///
    /// ⚠️ 这一档里**两组读数各有自己的标签**（#75 裁定 3）：
    /// 「当前状态」= 此刻在跑几个 Agent（全表快照，与所选区间无关），单独一组、只有一格；
    /// 「时段累计」= 所选区间的六个数。两组并排同格混卖过一次，
    /// 那次还把两种口径 `max()` 取大，谁也验证不了（现已取消）。
    private var statGrid: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(DashboardCopy.currentStatusTitle.text(language),
                          subtitle: DashboardCopy.currentStatusSubtitle.text(language))
            MetricGrid(snapshotTiles, columns: 1) { tile in statTile(tile) }
            SectionHeader(DashboardCopy.periodTotalTitle.text(language),
                          subtitle: model.windowCaptionText)
            MetricGrid(periodTiles, columns: Sizing.summaryColumns) { tile in statTile(tile) }
        }
    }

    private func statTile(_ tile: DashboardTile) -> some View {
        StatTile(
            title: tile.title,
            value: tile.value,
            caption: tile.caption,
            emphasis: tile.emphasis,
            action: tile.action
        )
    }

    /// 「当前状态」一组：只有此刻在跑的 Agent 数。
    ///
    /// 改前这一格和五格时段累计并排在一起，而且读的是
    /// `liveAgentCount = max(窗口累计, 全表快照)`——两种口径取大之后谁都验证不了
    /// （台账裁定 3 点名的就是那一句）。取大写法已取消：
    /// 大数走实时进程列表，副标题走库里那条全表快照，各说各的。
    ///
    /// ⚠️ 标题**不复用下面那张列表卡的「当前运行中的 Agent」**（#85）：那张是清单（都有谁），
    /// 这一格是读数（几个）。同一个名字在一屏里挂两处、指的却是两件事，
    /// 读者只能靠位置猜——而且那一屏里"几个"这个数本来也只该出现一次
    /// （列表卡副标题原先那句"N 个进程正在被观测"已因此删掉）。
    private var snapshotTiles: [DashboardTile] {
        [
            DashboardTile(
                id: 100,
                title: DashboardCopy.tileCurrentRunning.text(language),
                value: "\(model.currentRunningAgentCount)",
                caption: DashboardCopy.currentRunningCaption.copy.format(
                    language, model.snapshotRunningAgentCount
                ),
                emphasis: .metric,
                action: { shell?.jump(DashboardEvidenceJump.runningAgentSnapshot.intent(window: selectedRange)) }
            ),
        ]
    }

    private var periodTiles: [DashboardTile] {
        let stats = model.stats
        return [
            DashboardTile(
                id: 0,
                title: DashboardCopy.tileActiveDuration.text(language),
                value: DurationFormat.compact(stats.totalActiveSeconds),
                caption: model.activeDurationCaption,
                emphasis: .hero,
                action: { shell?.jump(DashboardEvidenceJump.activeDuration.intent(window: selectedRange)) }
            ),
            DashboardTile(
                id: 1,
                // `sessionCount` 筛的是 `started_at ∈ 所选区间`（#75 之后区间真的进 SQL），
                // 也就是**区间内新建**的会话，不是"区间内在跑的会话"：昨天 22:00 起
                // 一直跑今天的会话，在「今天」这一档不算进来。这一点以前靠
                // 副标题里塞一个"活跃 Agent 全表快照"来旁敲（两个口径并排 = 互相矛盾），
                // 现在那一格整体搬去「当前状态」组了，这里只说清自己的窗口。
                title: DashboardCopy.tileWindowSessions.text(language),
                value: "\(stats.sessionCount)",
                caption: DashboardCopy.tileWindowSessionsCaption.copy.format(language, model.windowCaptionText),
                emphasis: .metric,
                action: { shell?.jump(DashboardEvidenceJump.windowSessions.intent(window: selectedRange)) }
            ),
            DashboardTile(
                id: 2,
                title: DashboardCopy.tileFileChanges.text(language),
                // 三个计数在服务端都是 `SUM(CASE WHEN kind = ? THEN 1 …)`，按**事件行**计
                // 且互斥：谁也不是谁的分项。原来大数只放 filesModified、副标题再并列
                // 「新建 / 删除」，读起来就是「3 个文件，其中新建 9、删除 8」这种对不上的账。
                // 大数改成三者之和 ⇒ 恒等于分项之和。
                value: "\(stats.filesModified + stats.filesCreated + stats.filesDeleted)",
                caption: DashboardCopy.fileTripleCaption.copy.format(
                    language, stats.filesModified, stats.filesCreated, stats.filesDeleted
                ),
                emphasis: .metric,
                action: { shell?.jump(DashboardEvidenceJump.fileChanges.intent(window: selectedRange)) }
            ),
            DashboardTile(
                id: 3,
                title: DashboardCopy.tileCommands.text(language),
                value: "\(stats.commandsExecuted)",
                caption: DashboardCopy.failedCommandsCaption.copy.format(language, stats.failedCommands),
                emphasis: .metric,
                action: { shell?.jump(DashboardEvidenceJump.commands.intent(window: selectedRange)) }
            ),
            DashboardTile(
                id: 4,
                title: DashboardCopy.tileCPU.text(language),
                value: PercentFormat.short(stats.averageCPUPercent),
                caption: DashboardCopy.peakCPUCaption.copy.format(language, PercentFormat.short(stats.peakCPUPercent)),
                emphasis: .metric,
                action: { shell?.jump(DashboardEvidenceJump.agentCPU.intent(window: selectedRange)) }
            ),
            DashboardTile(
                id: 5,
                title: DashboardCopy.tileRisks.text(language),
                value: "\(stats.riskEventCount)",
                caption: DashboardCopy.highRiskCaption.copy.format(language, stats.highRiskEventCount),
                emphasis: .metric,
                action: { shell?.jump(DashboardEvidenceJump.risks.intent(window: selectedRange)) }
            ),
        ]
    }

    // MARK: - 活动趋势与关键事件

    /// 第 4 档「活动趋势与关键事件」：分桶柱图 + Agent 时长读数，各占一半、顶对齐。
    /// 用非懒 `Grid`：数量恒定为 2，
    /// 懒容器在这里省不到任何东西，反而会在滚动时反复回收卡片。
    private var trendRow: some View {
        Grid(alignment: .top, horizontalSpacing: Spacing.md, verticalSpacing: Spacing.md) {
            GridRow {
                DashboardHourlyActivityChart(
                    points: model.activityPoints,
                    bucketSpan: model.stats.bucketSpan,
                    windowCaption: model.windowCaptionText,
                    totalEvents: model.hourlyEventTotal,
                    lastEventAt: model.lastEventAt
                )
                DashboardAgentShareReadout(
                    shares: model.stats.agentShares,
                    windowCaption: model.windowCaptionText
                )
            }
        }
    }

    // MARK: - 异常检测卡

    /// 属于第 1 档「待查看事项」，并且**挂在时段摘要的加载/空态分支之外**：
    /// 分析层是否接入、检不出异常、库里没有记录，与「六宫格有没有内容」
    /// 是三件不同的事，各自有自己的文案（见 `AnalysisPresentation`）。
    private var anomalyCard: some View {
        DashboardAnomalyCard(
            findings: model.anomalies,
            analysisWired: model.analysisWired,
            hasRecords: model.hasContent,
            isLoading: model.isLoadingAnomalies,
            errorMessage: model.anomalyErrorMessage,
            windowText: model.anomalyWindowStart.map { DashboardCopy.anomalySince.copy.format(language, DateFormat.timestamp($0)) },
            jump: jump
        )
    }

    // MARK: - 最近风险条

    private var riskStrip: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // 标题右侧原本还印着一颗「N 起」，取的是 `stats.riskEventCount`——
                // 与「时段累计」里那格「风险事件」是**同一个数的第二处**，而且这屏它不回答
                // 任何操作问题（要点去看的是清单本身）。#85 一个数只留一个出处：那颗已删，
                // 数字与「高危 N 起」都归那一格。
                SectionHeader(
                    DashboardCopy.recentRiskTitle.text(language),
                    subtitle: DashboardCopy.recentRiskSubtitle.text(language))

                if model.riskHighlights.isEmpty {
                    Label(DashboardCopy.riskNoneLabel.text(language), systemImage: "checkmark.shield")
                        .font(.axBody)
                        .foregroundStyle(Surface.secondaryLabel)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Spacing.sm)
                } else {
                    ForEach(model.riskHighlights) { risk in
                        // 这一屏的每个数都来自所选区间（副标题那句"本范围内没有触发风险规则"
                        // 就是它的口径），所以出口必须带上同一个区间，再带上"哪一条"。
                        Button {
                            jump(.riskRow(riskID: risk.id))
                        } label: {
                        HStack(spacing: Spacing.sm) {
                            RiskBadge(risk.level, prominent: risk.level >= .high)
                            VStack(alignment: .leading, spacing: Spacing.xs) {
                                Text(demoRedaction.scrub(risk.title))
                                    .font(.axBody)
                                    .lineLimit(1)
                                Text("\(risk.category.displayName) · \(DateFormat.time(risk.timestamp))")
                                    .font(.axMeta)
                                    .monospacedDigit()
                                    .foregroundStyle(Surface.tertiaryLabel)
                                    .lineLimit(1)
                            }
                            Spacer(minLength: Spacing.sm)
                            AgentChip(kind: risk.agentKind, compact: true)
                        }
                        .padding(.vertical, Spacing.xs)
                        .accessibilityElement(children: .combine)
                        }
                        .buttonStyle(.axPressable)
                    }
                }
            }
        }
    }

    // MARK: - 加载 / 空 / 错误

    /// 加载卡与空态卡都**不再钉固定高度**（#85）。
    ///
    /// 改前空态是 `minHeight: 260`、异常卡 140、柱图空态 180、占比环 204 —— 四处定高加起来
    /// 首屏有近 800pt 的"什么都没有"，而里面只有两行字。收高不等于少画数据：
    /// 图表有数据时那 180pt 一根没动（`DashboardHourlyActivityChart` 的 `.frame(height:)`
    /// 仍然钉在 `Sizing.chartHeight`），这里收掉的只是"空着也要占一页"的留白。

    private var loadingCard: some View {
        Panel {
            HStack(spacing: Spacing.md) {
                ProgressView()
                    .controlSize(.regular)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(DashboardCopy.loadingTitle.text(language))
                        .font(.axBody)
                    Text(DashboardCopy.loadingNote.text(language))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                }
                Spacer(minLength: Spacing.none)
            }
        }
    }

    private var emptyCard: some View {
        Panel {
            EmptyStateView(
                DashboardCopy.emptyTitle.text(language),
                systemImage: "sparkles",
                message: DashboardCopy.emptyMessage.text(language),
                fills: false
            ) {
                Button(DashboardCopy.rescan.text(language)) {
                    guard let shell else { return }
                    Task { await shell.rescan() }
                }
            }
        }
    }

    private func errorCard(_ message: String) -> some View {
        Panel {
            HStack(spacing: Spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.axMetric)
                    .foregroundStyle(ObservatoryColor.caution)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(DashboardCopy.errorTitle.text(language))
                        .font(.axSection)
                    Text(message)
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .textSelection(.enabled)
                }
                Spacer(minLength: Spacing.md)
                Button(DashboardCopy.retry.text(language)) {
                    Task { await model.load(range: queryRange) }
                }
            }
        }
    }
}

#Preview("有数据") {
    ObservatoryPreview.screen { runtime in
        DashboardView(runtime: runtime)
    }
}

#Preview("空状态") {
    ObservatoryPreview.screen(empty: true) { runtime in
        DashboardView(runtime: runtime)
    }
}

#Preview("窄窗口（两列指标）") {
    ObservatoryPreview.screen { runtime in
        DashboardView(runtime: runtime)
            .frame(width: 560, height: 900)
    }
}

/// 指标区的一格。`MetricGrid` 要 `Identifiable` 的数据，所以把六项读数收成值类型，
/// 布局与取数就此分开——原来六个 `StatTile` 直接摊在 `LazyVGrid` 里，
/// 谁该大谁该小完全看不出来。
private struct DashboardTile: Identifiable {
    let id: Int
    let title: String
    let value: String
    let caption: String?
    let emphasis: StatTile.Emphasis
    var action: (() -> Void)? = nil
}

private extension DashboardView {
    var language: AppLanguage { UILanguage.current }
}
