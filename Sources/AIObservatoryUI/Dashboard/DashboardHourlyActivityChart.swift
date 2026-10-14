//
//  DashboardHourlyActivityChart.swift
//  AIObservatoryUI / Dashboard
//
//  Owner: WS-UI (subagent B)
//  24 小时 AI 行为柱状图（Swift Charts BarMark）。
//  约定：缺时段补 0（组件内部再兜底补齐一次，保证 24 根柱子稳定对齐）；
//  x 轴只在 0 / 6 / 12 / 18 / 23 打刻度，避免标签拥挤；不使用 annotation 气泡，
//  悬停信息通过 .help() 与页脚文字给出，保持视觉克制。
//

import SwiftUI
import Charts
import AIObservatoryCore

/// 活动趋势柱图（Swift Charts `BarMark`）。
///
/// #75 之后一格不一定是一小时：窗口 ≤ 36 h 是小时桶，更宽是自然日桶
/// （`bucketSpan` 由载荷给，标题/副标题/坐标轴都跟着它走）。
/// 补齐由取数侧做（两侧 Store 同一条口径），所以这里**不再自己写死 0...23**——
/// 那种补齐会把 7 个日桶压进 24 个格子里，画出来的东西和标题说的不是一回事。
struct DashboardHourlyActivityChart: View {

    let points: [DashboardHourPoint]
    /// 桶粒度（跟随 `DashboardStats.bucketSpan`）。
    var bucketSpan: ActivityBucketSpan = .hourOfDay
    /// 所选窗口的人读口径，进副标题。
    var windowCaption: String = ""
    var totalEvents: Int = 0
    var lastEventAt: Date?

    private var usesDayBuckets: Bool { bucketSpan == .naturalDay }

    /// 小时档沿用的刻度位置（0 / 6 / 12 / 18 / 23）：日档要的是日期标签，不是这几个数。
    static let axisHours: [Int] = [0, 6, 12, 18, 23]

    private var events: Int {
        totalEvents > 0 ? totalEvents : points.reduce(0) { $0 + $1.eventCount }
    }

    private var hasActivity: Bool {
        points.contains { $0.eventCount > 0 }
    }

    private var busiestPoint: DashboardHourPoint? {
        points.max(by: { $0.eventCount < $1.eventCount }).flatMap { $0.eventCount > 0 ? $0 : nil }
    }

    /// x 轴那一列的语义标签也随档位走（VoiceOver 与图例都读它）。
    /// 横轴范围：直接用格子序号（日档是负数偏移，不能假设从 0 起）。
    private var xDomain: ClosedRange<Int> {
        let low = points.first?.slot ?? 0
        let high = points.last?.slot ?? (low + 1)
        return low...(high > low ? high : low + 1)
    }

    private var axisColumnLabel: String {
        usesDayBuckets
            ? DashboardCopy.hourlyAxisDay.text(language)
            : DashboardCopy.hourlyAxisHour.text(language)
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    DashboardCopy.hourlyTitle(language, bucketSpan: bucketSpan),
                    subtitle: DashboardCopy.hourlySubtitle(language, bucketSpan: bucketSpan, windowCaption: windowCaption)) {
                    Text(DashboardCopy.hourlyEventCount.copy.format(language, events))
                        .font(.axMeta)
                        .monospacedDigit()
                        .foregroundStyle(Surface.secondaryLabel)
                }

                if hasActivity {
                    chart
                    footer
                } else {
                    // 空态**不钉图高**（#85）：原先这里给的是 `Sizing.chartHeight`（180 pt），
                    // 于是"这段时间还没有行为"两行字坐在 180 pt 的空框里，首页四张这样的卡
                    // 首屏就吃掉近 800 pt。收掉定高不等于减数据点——有数据时那一根 180 pt
                    // 的柱图区（上面 `chart` 的 `.frame(height:)`）一个字没动。
                    EmptyStateView(
                        DashboardCopy.hourlyEmptyTitle.text(language),
                        systemImage: "chart.bar.xaxis",
                        message: DashboardCopy.hourlyEmptyMessage.text(language),
                        fills: false
                    )
                }
            }
        }
    }

    // MARK: - 图表

    private var chart: some View {
        Chart {
            ForEach(points) { point in
                BarMark(
                    x: .value(axisColumnLabel, point.slot),
                    y: .value(DashboardCopy.hourlyAxisEvents.text(language), point.eventCount)
                )
                .foregroundStyle(point.isHighLoad ? ObservatoryColor.caution : Color.accentColor)
                .cornerRadius(ObservatoryRadius.mark)
                .accessibilityLabel(DashboardCopy.hourlyBarA11y.copy.format(
                    language, point.label, point.eventCount
                ))
            }
        }
        .chartXScale(domain: xDomain)
        // 横轴随桶档换：小时档要「0 / 6 / 12 / 18 / 23」那一串整点标签（白名单见 `axisHours`），
        // 日档**整根收起**——那一列是"距今第几天"的带符号序号（-6…0），给人读毫无意义，
        // 真正要看的日期标签由副标题与页脚那两句给（`hourlyDayRange`）。
        // 两档的画法都在 `DesignSystem/ChartChrome.swift`：这里只说"这一档画不画、画哪几个刻度"，
        // 不说"轴长什么样"（台账裁定 4 / 门禁 2：共享件之外不许出现自绘坐标轴）。
        .observatoryAxes(x: usesDayBuckets ? .hidden : .hours(Self.axisHours))
        .chartLegend(.hidden)
        .frame(maxWidth: .infinity)
        .frame(height: Sizing.chartHeight)
        .animation(.snappy, value: events)
        .accessibilityLabel(DashboardCopy.hourlyA11y.copy.format(language, events))
    }

    // MARK: - 页脚

    private var footer: some View {
        HStack(spacing: Spacing.sm) {
            if let busiestPoint {
                Label(
                    DashboardCopy.hourlyBusiest.copy.format(language, busiestPoint.label, busiestPoint.eventCount),
                    systemImage: "flame"
                )
            }
            if usesDayBuckets, let first = points.first, let last = points.last {
                Text(DashboardCopy.hourlyDayRange.copy.format(language, first.label, last.label))
            }
            Spacer(minLength: Spacing.sm)
            if let lastEventAt {
                HStack(spacing: Spacing.xs) {
                    Circle()
                        .fill(ObservatoryColor.positive)
                        .frame(width: 6, height: 6)
                    Text(DashboardCopy.hourlyLastEvent.copy.format(language, DateFormat.time(lastEventAt)))
                }
            }
        }
        // #84：这一整条页脚说的是这张图的口径（按什么桶、覆盖哪几天、最近一条在什么时候），
        // 原先整条 11pt + 二级色、其中两截还再降到三级色（≈1.8:1）——
        // 「窗口是哪个」恰恰是核对柱图读数第一眼要看的那句。走口径层。
        .monospacedDigit()
        .axCaptionStyle()
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

#Preview("DashboardHourlyActivityChart") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        DashboardHourlyActivityChart(
            points: (0..<24).map { hour in
                let busy = hour >= 9 && hour <= 21
                return DashboardHourPoint(
                    slot: hour,
                    start: Calendar.current.date(byAdding: .hour, value: hour, to: Date()) ?? Date(),
                    label: String(format: "%02d", hour),
                    eventCount: busy ? 6 + (hour * 7) % 34 : (hour.isMultiple(of: 5) ? 2 : 0),
                    cpuAverage: busy && hour.isMultiple(of: 6) ? 63 : 12
                )
            },
            totalEvents: 412,
            lastEventAt: Date().addingTimeInterval(-96)
        )
        DashboardHourlyActivityChart(points: [], totalEvents: 0, lastEventAt: nil)
    }
    .padding(Spacing.lg)
    .frame(width: 620)
}

private extension DashboardHourlyActivityChart {
    var language: AppLanguage { UILanguage.current }
}
