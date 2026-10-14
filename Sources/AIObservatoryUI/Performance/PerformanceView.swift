//
//  PerformanceView.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-UI (subagent D) → WS-QUIET-3（本轮按 ADR-0007 重排到「quiet」语言）
//  职责：Performance 板块入口 —— 外层 `ObservatoryPage`、本页唯一的 `.hero`、
//        按口径分组的指标网格、CPU/内存/磁盘/网络四张曲线、会话明细，含空/加载/错误三态。
//        网络曲线只在「整机」口径下出现（会话级采样不带网络与 GPU）。
//
//  这一页是全仓最容易自旋的一页：动布局之前先读 `PerformanceChartStack` 那段记录。
//

import SwiftUI
import Observation
import AIObservatoryCore

/// 性能页入口（Shell 以 `PerformanceView(runtime:)` 调用）。
@MainActor
struct PerformanceView: View {
    @Environment(ShellModel.self) private var shell
    @State private var model: PerformanceModel

    private var language: AppLanguage { UILanguage.current }

    init(runtime: ObservatoryRuntime, selfProcessSource: (any SelfProcessReadingSource)? = nil) {
        _model = State(initialValue: PerformanceModel(runtime: runtime, selfProcessSource: selfProcessSource))
    }

    // MARK: - Body

    var body: some View {
        @Bindable var model = model
        // 序列、它的汇总量、会话聚合各只物化**一次**，再作为值传下去。
        // 以前下面十几处分别读 `model.points` / `model.cpuPeak` / `model.sessionStats`…，
        // 而它们各自都是计算属性 ⇒ 一次 body 把整条曲线重算 24 遍以上；
        // 每遍都是**新数组身份** ⇒ Swift Charts 按身份重分配内部 id ⇒ RSS 只增不减。
        let points = model.points
        let metrics = PerformanceSeriesMetrics(points: points)
        let sessionStats = model.sessionStats
        let tiles = metricTiles(metrics: metrics, stats: sessionStats)

        ObservatoryPage(
            SidebarSection.performance.title,
            subtitle: "\(model.scopeTitle) · \(PerformanceCopy.samplePointCount.format(language, points.count))"
        ) {
            if model.isLoading {
                ProgressView().controlSize(.small)
            }
            Text(PerformanceCopy.lastSampled.format(
                language, model.lastReloadedAt.map { DateFormat.time($0) } ?? "—"))
                .font(.axMeta)
                .monospacedDigit()
                .axCaptionStyle()   // #99：承载口径，曾在最低档
                .contentTransition(.numericText())
        } content: {
            if model.isLoading && points.isEmpty {
                loadingCard
            } else if let message = model.errorMessage, points.isEmpty {
                errorCard(message)
            } else if !model.hasData {
                emptyCard
            } else {
                controlPanel(
                    selectedSessionID: $model.selectedSessionID,
                    sessions: model.sessions
                )
                heroCard(metrics: metrics)
                Panel {
                    PerformanceSummaryGrid(tiles, columns: Sizing.metricColumns)
                }
                // 全页唯一一块按**本进程**口径读数的区域，独立成块而不是混进上面的网格：
                // 混排就会让读者拿整机读数去对 3% / 200 MB（AGENTS.md §6 明令禁止的那种误读）。
                SelfProcessOverheadPanel(
                    overhead: model.selfOverhead,
                    isInstrumented: model.hasSelfProcessInstrument,
                    machineLoad1m: model.latestSystemSample?.loadAverage1m
                )
                PerformanceChartStack(
                    points: points,
                    metrics: metrics,
                    scopeTitle: model.scopeTitle,
                    networkSubtitle: networkSubtitle(points: points, metrics: metrics),
                    networkEmptyMessage: PerformanceDisplay.networkCaption(
                        bytesPerSecond: nil,
                        peak: nil,
                        availability: model.networkAvailability,
                        hasSamples: model.hasSystemSamples,
                        language
                    ),
                    showsNetwork: model.scope == .system
                )
                PerformanceSessionBreakdown(
                    session: model.selectedSession,
                    selectedSessionID: model.selectedSessionID,
                    stats: sessionStats,
                    samples: model.sessionSamples,
                    engineIntervalText: intervalText(model.engineScanIntervalSeconds)
                )
            }
        }
        .task(id: model.range) { await model.load() }
        .task { await model.observeUpdates() }
        .onChange(of: shell.timeRange, initial: true) { _, newValue in
            model.range = newValue
        }
        .onChange(of: model.selectedSessionID) { _, _ in
            Task { await model.loadSessionSamples() }
        }
        .refreshable { await model.load() }
    }

    // MARK: - 观测对象

    /// 观测对象（整机 / 某个会话）选择器。
    ///
    /// **这里刻意没有「时间范围」控件**：顶栏 `ToolbarContent.timeRangeMenu` 是全局范围的
    /// 唯一入口，`ShellModel.timeRange` 的注释写明「板块修改时回写」。
    /// 页面里再放一个是同一个状态两个入口，而且页面那个只写 `model.range`、不回写 shell
    /// ⇒ 顶栏 chip 与页面读数会各自显示一个范围，谁也不报错。
    /// 范围变化由下面的 `.onChange(of: shell.timeRange)` 同步进来。
    ///
    /// ⚠️ 这个 `.menu` 样式的 Picker **必须待在非懒面板里**，不要塞回懒容器
    /// （见 `PerformanceChartStack` 那条自旋记录：懒容器反复物化含 `.menu` Picker 的卡，
    /// 每轮都要重建 NSMenu 并解析菜单项的无障碍富文本，重建又改变测得高度 ⇒ 振荡不自愈）。
    ///
    /// 为什么不放进 `ObservatoryPage` 的 trailing：`PageHeader` 整块带
    /// `.accessibilityElement(children: .combine)`，把可操作控件并进去会让它
    /// 在 VoiceOver 下失去自己的元素。参考页 `DashboardView` 的 trailing 只放不可交互的读数，
    /// 这里跟随同一个取舍，页面级操作因此落在第一块面板里。
    private func controlPanel(
        selectedSessionID: Binding<UUID?>,
        sessions: [AgentSession]
    ) -> some View {
        Panel(padding: Spacing.md) {
            HStack(spacing: Spacing.md) {
                Picker(PerformanceCopy.observeTarget.text(language), selection: selectedSessionID) {
                    Text(PerformanceCopy.scopeSystem.text(language)).tag(UUID?.none)
                    ForEach(sessions) { session in
                        Text(model.sessionPickerTitle(session)).tag(UUID?.some(session.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 300)

                Spacer(minLength: Spacing.none)

                InlineStat(PerformanceCopy.statVisibleSessions.text(language),
                           value: PerformanceCopy.countedItems(sessions.count, language))
                    .frame(maxWidth: 160)
            }
        }
    }

    // MARK: - Hero

    /// 本页**唯一**的 40pt 主读数：当前 CPU。
    ///
    /// 为什么选它而不是峰值内存：当前 CPU 是这一页唯一带「现在」语义的读数，
    /// 它决定用户要不要继续往下看（此刻到底有没有负载）；
    /// 峰值内存是历史极值，无论多大都不触发任何动作，
    /// 把它放到 40pt 只会让每一页看起来都在报警——「没有主次」的另一半，
    /// 是该轻的东西也被画得那么重。
    ///
    /// caption 必须点明**这个数量的是谁**（整机 / 某个会话）。
    /// 这里**不许**并列本 App 的 3% / 200 MB 预算——那是另一个对象的尺子，
    /// 混排会让读者算出「超预算 133 倍」这种荒谬结论（AGENTS.md §6）。
    /// 本 App 自己的预算与实测在下面的 `SelfProcessOverheadPanel`，那是全页唯一按本进程口径的一块。
    private func heroCard(metrics: PerformanceSeriesMetrics) -> some View {
        Panel {
            StatTile(
                title: PerformanceCopy.tileCurrentCPU.text(language),
                value: String(format: "%.1f", model.currentCPUPercent),
                unit: "%",
                trend: cpuTrend(metrics: metrics),
                caption: model.scope == .system
                    ? PerformanceCopy.heroCaptionSystem.text(language)
                    : PerformanceCopy.heroCaptionSession.text(language),
                emphasis: .hero
            )
        }
    }

    // MARK: - 次级读数

    /// 读数按**口径**分组，而不是按字段清单排。
    ///
    /// 整机口径给 8 格（正好 4 列 × 2 行填满）；会话口径给 4 格（1 行填满）。
    /// 会话口径**不给**网络 / GPU / 温度 / 功耗：
    /// - 网络与 GPU：macOS 给不出非 root 的按进程量，`PerformanceSeriesPoint(_ PerformanceSample)`
    ///   刻意把它们写成 `nil`，正是为了不把「没采」画成「没流量」；
    /// - 温度与功耗：会话行根本没有生产者（见 `PerformanceSessionBreakdown` 文件头）。
    /// 在会话视图里放四格「—」不是诚实，那是让读者以为这些量本该按会话算、只是这台机器读不到。
    private func metricTiles(
        metrics: PerformanceSeriesMetrics,
        stats: PerformanceSessionStats
    ) -> [PerformanceMetricTile] {
        if model.scope == .system {
            return systemTiles(metrics: metrics)
        }
        return sessionTiles(stats: stats)
    }

    private func systemTiles(metrics: PerformanceSeriesMetrics) -> [PerformanceMetricTile] {
        // 「当前」负载优先取整机最新一行，其次退回曲线最后一点（原先靠 `points.last` 实现，
        // 为取一个末尾元素把整条序列重算一遍）。
        let currentLoad = model.latestSystemSample?.loadAverage1m ?? metrics.lastLoadAverage ?? 0
        return [
            PerformanceMetricTile(
                id: 0,
                title: PerformanceCopy.tileCPUPeak.text(language),
                value: String(format: "%.1f", metrics.cpuPeak),
                unit: "%",
                caption: PerformanceCopy.captionIntervalAverage.format(
                    language, PercentFormat.short(metrics.cpuAverage, fractionDigits: 1))
            ),
            PerformanceMetricTile(
                id: 1,
                title: PerformanceCopy.tileMemoryPeak.text(language),
                value: ByteFormat.humanReadable(metrics.memoryPeakBytes),
                caption: metrics.memoryTotalBytes > 0
                    ? PerformanceCopy.captionPhysicalTotal.format(
                        language, ByteFormat.humanReadable(metrics.memoryTotalBytes))
                    : PerformanceCopy.captionMemoryUsedPeak.text(language)
            ),
            PerformanceMetricTile(
                id: 2,
                title: PerformanceCopy.tileLoadAverage.text(language),
                value: String(format: "%.2f", currentLoad),
                caption: metrics.averageLoadAverage > 0
                    ? PerformanceCopy.captionIntervalAverage.format(
                        language, String(format: "%.2f", metrics.averageLoadAverage))
                    : PerformanceCopy.captionAwaitSystem.text(language)
            ),
            PerformanceMetricTile(
                id: 3,
                title: PerformanceCopy.tileGPUActivity.text(language),
                value: PerformanceDisplay.gpuValue(percent: model.gpuActivityPercent),
                unit: PerformanceDisplay.gpuUnit(percent: model.gpuActivityPercent),
                caption: PerformanceDisplay.gpuCaption(
                    percent: model.gpuActivityPercent,
                    hasSamples: model.hasSystemSamples,
                    language
                )
            ),
            PerformanceMetricTile(
                id: 4,
                title: PerformanceCopy.tileNetworkDown.text(language),
                value: PerformanceDisplay.networkValue(bytesPerSecond: model.networkInBytesPerSecond),
                caption: PerformanceDisplay.networkCaption(
                    bytesPerSecond: model.networkInBytesPerSecond,
                    peak: metrics.networkInPeak,
                    availability: model.networkAvailability,
                    hasSamples: model.hasSystemSamples
                )
            ),
            PerformanceMetricTile(
                id: 5,
                title: PerformanceCopy.tileNetworkUp.text(language),
                value: PerformanceDisplay.networkValue(bytesPerSecond: model.networkOutBytesPerSecond),
                caption: PerformanceDisplay.networkCaption(
                    bytesPerSecond: model.networkOutBytesPerSecond,
                    peak: metrics.networkOutPeak,
                    availability: model.networkAvailability,
                    hasSamples: model.hasSystemSamples
                )
            ),
            PerformanceMetricTile(
                id: 6,
                title: PerformanceCopy.tileThermal.text(language),
                value: model.thermalCelsius.map { String(format: "%.0f", $0) } ?? "—",
                unit: model.thermalCelsius == nil ? "" : "°C",
                caption: thermalCaption
            ),
            PerformanceMetricTile(
                id: 7,
                title: PerformanceCopy.tilePower.text(language),
                value: model.powerWatts.map { String(format: "%.1f", $0) } ?? "—",
                unit: model.powerWatts == nil ? "" : "W",
                caption: powerCaption
            ),
        ]
    }

    private func sessionTiles(stats: PerformanceSessionStats) -> [PerformanceMetricTile] {
        [
            PerformanceMetricTile(
                id: 0,
                title: PerformanceCopy.tileSessionCPUPeak.text(language),
                // `value` 里不能再带 `%`：`StatTile` 会把 `unit` 拼在值后面，
                // 用 `PercentFormat.short` 会渲染成「0.0% %」（真机截图上出现过）。
                value: String(format: "%.1f", stats.peakCPUPercent),
                unit: "%",
                caption: PerformanceCopy.captionIntervalAverage.format(
                    language, PercentFormat.short(stats.averageCPUPercent, fractionDigits: 1))
            ),
            PerformanceMetricTile(
                id: 1,
                title: PerformanceCopy.tileSessionMemoryPeak.text(language),
                value: ByteFormat.humanReadable(stats.peakMemoryBytes),
                caption: PerformanceCopy.captionIntervalAverage.format(
                    language, ByteFormat.humanReadable(stats.averageMemoryBytes))
            ),
            PerformanceMetricTile(
                id: 2,
                title: PerformanceCopy.tileSampleCount.text(language),
                value: "\(stats.sampleCount)",
                caption: PerformanceCopy.captionSampleCap.format(language, PerformanceModel.sampleCap)
            ),
            PerformanceMetricTile(
                id: 3,
                title: PerformanceCopy.tileObservedTime.text(language),
                // 22pt 那一档放不进「17:06:44 → 17:06:47」这种长串：
                // `StatTile` 的 minimumScaleFactor 压过之后仍然顶到列边界（真机上被切字）。
                // 大数位置给一个短的量，起止时刻降到 11pt 的 caption 里。
                value: stats.coveredSeconds.map { DurationFormat.humanReadable($0) } ?? "—",
                caption: stats.windowText
            ),
        ]
    }

    /// 当前值相对区间均值的偏离百分比；无均值时不给趋势，避免假数据。
    ///
    /// ⚠️ 还要过一道**量级下限**：`(current - avg) / avg × 100` 在 avg 接近 0 时会爆炸——
    /// 真机截图上会话口径出现过「↗ +1652545%」（区间均值 0.004%，一次正常抖动就被读成
    /// 一千六百万倍）。这不是格式问题，是一个读者会当真的假信号，
    /// 所以基数低于 1% 时干脆不给趋势（宁缺不造）。
    private func cpuTrend(metrics: PerformanceSeriesMetrics) -> Double? {
        guard metrics.cpuAverage >= 1 else { return nil }
        return (model.currentCPUPercent - metrics.cpuAverage) / metrics.cpuAverage * 100
    }

    private var thermalCaption: String {
        guard let celsius = model.thermalCelsius else {
            return unavailableCaption(metric: PerformanceCopy.metricThermal.text(language))
        }
        if celsius >= 70 { return PerformanceCopy.thermalHigh.text(language) }
        if celsius >= 55 { return PerformanceCopy.thermalMedium.text(language) }
        return PerformanceCopy.thermalNormal.text(language)
    }

    /// macOS 没有公开的整机功耗读取，`powerWatts` 恒为 nil：
    /// 副标题不能再写「整机瞬时估算值」，那等于给一个永远不出数的瓷贴背书。
    private var powerCaption: String {
        guard model.powerWatts != nil else { return unavailableCaption(metric: PerformanceCopy.metricPower.text(language)) }
        return PerformanceCopy.powerInstantEstimate.text(language)
    }

    private func unavailableCaption(metric: String) -> String {
        MetricAvailability.resolve(
            hasSamples: model.hasSystemSamples,
            reading: nil
        ).caption(metric: metric)
    }

    private func networkSubtitle(
        points: [PerformanceSeriesPoint],
        metrics: PerformanceSeriesMetrics
    ) -> String {
        // `contains` 而不是 `filter(...).isEmpty`：这里只要一个 Bool，
        // 不该为了判空再产出一条新数组（新数组身份 = Charts 重新分配内部 id）。
        points.contains(where: \.hasNetworkReading)
            ? PerformanceCopy.networkPeakBoth.format(language, ByteFormat.rate(metrics.networkInPeak),
                                                     ByteFormat.rate(metrics.networkOutPeak))
            : PerformanceCopy.networkRatesCaption.text(language)
    }

    private func intervalText(_ seconds: Double) -> String {
        seconds >= 1 ? PerformanceCopy.intervalWholeSeconds.format(language, seconds)
                     : PerformanceCopy.intervalFractionSeconds.format(language, seconds)
    }

    // MARK: - 加载 / 空 / 错误

    private var loadingCard: some View {
        Panel {
            HStack(spacing: Spacing.md) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(PerformanceCopy.loadingReading.text(language))
                        .font(.axBody)
                        .foregroundStyle(Surface.label)
                    Text(PerformanceCopy.loadingFirstHint.text(language))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                }
                Spacer(minLength: Spacing.none)
            }
            .frame(maxWidth: .infinity, minHeight: Sizing.chartHeight)
        }
    }

    private var emptyCard: some View {
        Panel {
            EmptyStateView(
                PerformanceCopy.emptyTitle.text(language),
                systemImage: "chart.xyaxis.line",
                message: PerformanceCopy.emptyMessage.text(language),
                fills: false
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: Sizing.chartHeight)
        }
    }

    private func errorCard(_ message: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.md) {
                HStack(spacing: Spacing.sm) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.axMetric)
                        .foregroundStyle(ObservatoryColor.caution)
                    Text(PerformanceCopy.readFailed.text(language))
                        .font(.axSection)
                        .foregroundStyle(Surface.label)
                }
                Text(message)
                    .font(.axBody)
                    .foregroundStyle(Surface.secondaryLabel)
                    .textSelection(.enabled)
                Button(PerformanceCopy.retry.text(language)) {
                    Task { await model.load() }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Chart stack

/// 四张曲线卡。
///
/// ⚠️ 外层刻意用**非懒** `VStack`，不要退回 `LazyVStack`。
/// 这里只有恒定 4 张卡，懒加载省不下任何东西，却会要命：
/// 本仓真机实测（debug 包、同一份 319 行快照、同一 200 次滚轮）
/// 性能页外层用 `LazyVStack` 时 **RSS 每 10 秒 +142 MB、CPU 108.8%、停手 40 秒仍不回落**，
/// 换成 `VStack` 后是 +3 MB、9.7%、之后 0.0–0.2 MB/s。
/// 根因是懒容器反复物化/回收含 `.menu` `Picker` 的卡：每轮都要重建 NSMenu
/// 并解析各菜单项的无障碍富文本，重建又改变测得高度 ⇒ 再判一次可见性 ⇒ 振荡不自愈。
/// 其余各页的 LazyVStack 装的是**无上限的行列表**，那里懒加载才有意义，别照搬这条。
///
/// 入参全是值：`points` 由调用方 `let` 绑一次传下来，这里不再读 model 的任何计算属性。
private struct PerformanceChartStack: View {
    let points: [PerformanceSeriesPoint]
    let metrics: PerformanceSeriesMetrics
    let scopeTitle: String
    let networkSubtitle: String
    let networkEmptyMessage: String
    let showsNetwork: Bool

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            Panel {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader("CPU", subtitle: scopeTitle)
                    PerformanceCPUGraph(points: points)
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader(
                        PerformanceCopy.chartMemoryTitle.text(language),
                        subtitle: PerformanceCopy.chartPeakValue.format(
                            language, ByteFormat.humanReadable(metrics.memoryPeakBytes))
                            + (metrics.memoryTotalBytes > 0
                                ? PerformanceCopy.chartPhysicalSuffix.format(
                                    language, ByteFormat.humanReadable(metrics.memoryTotalBytes))
                                : ""))
                    PerformanceMemoryGraph(
                        points: points,
                        capacityBytes: metrics.memoryTotalBytes
                    )
                }
            }

            Panel {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    SectionHeader(
                        PerformanceCopy.chartDiskTitle.text(language),
                        subtitle: PerformanceCopy.chartPeakValue.format(
                            language, ByteFormat.rate(metrics.diskTotalPeak)))
                    PerformanceDiskIOGraph(points: points)
                }
            }

            // 网络速率只有整机口径（macOS 给不出按进程的非 root 字节数），
            // 所以会话视图里干脆不放这张卡——放进来只能画一排「不可得」，白占位置。
            if showsNetwork {
                Panel {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SectionHeader(PerformanceCopy.chartNetworkTitle.text(language), subtitle: networkSubtitle)
                        PerformanceNetworkGraph(
                            points: points,
                            emptyMessage: networkEmptyMessage
                        )
                    }
                }
            }
        }
    }
}

#Preview("有数据") {
    ObservatoryPreview.screen { runtime in
        PerformanceView(runtime: runtime)
    }
}

#Preview("空状态") {
    ObservatoryPreview.screen(empty: true) { runtime in
        PerformanceView(runtime: runtime)
    }
}
