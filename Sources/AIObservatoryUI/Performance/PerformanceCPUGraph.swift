//
//  PerformanceCPUGraph.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-QUIET-3
//  职责：CPU 曲线 —— 用户 / 系统两条折线 + 总量面积 + 区间峰值参考线。
//        轴的**画法**与**挂载**都取自 `ObservatoryChart`（`observatoryAxes(x:ySuffix:)`），
//        图例取自 `ChartLegend`：九张图各写各的轴就是「东一个西一个」，字号也会一张一个样。
//        `ws/axes` 之后本文件里不再出现挂轴的动作 —— 门禁 2（`Scripts/gate-quiet-design.sh`）
//        数的正是「共享件之外还有几处自己挂坐标轴」。
//
//  刻意**不画**「空闲 CPU 预算 3%」参考线：那条预算属于本 App 这个进程，
//  而这张曲线是整机（或某个会话）的占用，两者不是同一个对象，
//  压在整机曲线上只会让人拿错尺子（AGENTS.md §6）。
//
//  序列色只用 `ObservatoryChart.color(rank:)`（rank 0 = 强调色，其余灰阶梯队），
//  不再用「蓝/橙 + chartForegroundStyleScale」那套固定色相：
//  两个方向谁高谁低用灰阶比用蓝橙更好读，也不会在深色模式下发成两块色斑。
//

import Foundation
import SwiftUI
import Charts
import AIObservatoryCore

struct PerformanceCPUGraph: View {
    private var language: AppLanguage { UILanguage.current }

    let points: [PerformanceSeriesPoint]

    var body: some View {
        // 峰值只算一次。它原先是计算属性，却在 body 里被读 5 次
        // （参考线判据、取值、annotation 文案、y 轴定域、无障碍标签），
        // 每读一次就重新过一遍序列。
        let peak = points.reduce(0) { max($0, $1.cpuTotalPercent) }
        if points.isEmpty {
            EmptyStateView(
                PerformanceCopy.cpuEmptyTitle.text(language),
                systemImage: "cpu",
                message: PerformanceCopy.cpuEmptyMessage.text(language),
                fills: false
            )
            .frame(maxWidth: .infinity)
            .frame(height: Sizing.chartHeight)
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // `id` 必须显式传，且**两条不许同值**：`ChartLegend` 内部按 `\.id` 走 ForEach，
                // 同 id 会把第一条渲染两遍、第二条在图例里消失（真机截图上出现过「用户 · 用户」）。
                // 漏传现在已经是编译错误（默认值删了），同值编译器管不着 ⇒ 由
                // `ChartLegendIdentityTests` 逐调用点扫。用 rank 当 id，和取色同一个序。
                ChartLegend([
                    .init(id: 0, label: PerformanceCopy.cpuUser.text(language),
                          color: ObservatoryChart.color(rank: 0)),
                    .init(id: 1, label: PerformanceCopy.cpuSystem.text(language),
                          color: ObservatoryChart.color(rank: 1)),
                ])
                Chart {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.axisCPUTotal.text(language), point.cpuTotalPercent)
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 0).opacity(0.12))
                        .interpolationMethod(.monotone)
                    }

                    ForEach(points) { point in
                        LineMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.axisShare.text(language), point.cpuUserPercent),
                            series: .value(PerformanceCopy.seriesCPUComposition.text(language),
                                            PerformanceCopy.cpuUser.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 0))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }

                    ForEach(points) { point in
                        LineMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.axisShare.text(language), point.cpuSystemPercent),
                            series: .value(PerformanceCopy.seriesCPUComposition.text(language),
                                            PerformanceCopy.cpuSystem.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 1))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }

                    if peak > 0 {
                        RuleMark(y: .value(PerformanceCopy.axisPeak.text(language), peak))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle(Surface.tertiaryLabel)
                            .annotation(position: .top, alignment: .trailing) {
                                Text(PerformanceCopy.chartPeakValue.format(
                                        language, PercentFormat.short(peak, fractionDigits: 1)))
                                    .font(.axMeta)
                                    .monospacedDigit()
                                    .foregroundStyle(Surface.tertiaryLabel)
                            }
                    }
                }
                // 定域必须给参考线留出余量：`0...max(100, peak)` 会让 peak 正好贴在
                // 绘图区上沿，虚线与它的「峰值 87.6%」标注一起被切掉半截。
                // 多核机器的 cpuTotalPercent 可以远超 100%，所以 100 不是上界而是**下界**。
                .chartYScale(domain: 0...max(100, peak * 1.1))
                .observatoryAxes(x: .time, ySuffix: "%")
                .frame(maxWidth: .infinity)
                .frame(height: Sizing.chartHeight)
            }
            .accessibilityLabel(PerformanceCopy.cpuA11y.format(
                language, PercentFormat.short(peak, fractionDigits: 1)))
        }
    }
}

#Preview("PerformanceCPUGraph") {
    Panel {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("CPU", subtitle: "用户 / 系统两条线 + 区间峰值参考线")
            PerformanceCPUGraph(points: PerformancePreviewPoints.sixHours())
        }
    }
    .padding(Spacing.xl)
    .frame(width: 620)
    .background(Surface.page)
}

/// 图表 Preview 用的确定性点位（不依赖 TestSupport target）。
enum PerformancePreviewPoints {
    /// 以「现在」为终点、每 5 分钟一个点的演示序列。
    static func sixHours(count: Int = 72) -> [PerformanceSeriesPoint] {
        series(count: count, secondsAgo: 6 * 3600, step: 300)
    }

    private static func series(count: Int, secondsAgo: TimeInterval, step: TimeInterval) -> [PerformanceSeriesPoint] {
        let now = Date()
        let start = now.addingTimeInterval(-secondsAgo)
        return (0..<max(1, count)).map { index in
            let wave = Double(index) / Double(max(1, count - 1))
            let sample = SystemPerformanceSample(
                timestamp: start.addingTimeInterval(TimeInterval(index) * step),
                cpuTotalPercent: 6 + 34 * abs(sin(wave * 6)),
                cpuSystemPercent: 2 + 9 * abs(sin(wave * 4)),
                cpuUserPercent: 4 + 24 * abs(sin(wave * 7)),
                memoryUsedBytes: UInt64((9 + 6 * abs(sin(wave * 3))) * 1_073_741_824),
                memoryTotalBytes: 32 * 1_073_741_824,
                diskReadBytesPerSecond: 40_000_000 + 120_000_000 * abs(sin(wave * 5)),
                diskWriteBytesPerSecond: 15_000_000 + 60_000_000 * abs(sin(wave * 8)),
                loadAverage1m: 1.2 + 3.4 * abs(sin(wave * 5)),
                thermalCelsius: 48 + 14 * abs(sin(wave * 4)),
                powerWatts: 9 + 12 * abs(sin(wave * 6))
            )
            return PerformanceSeriesPoint(sample)
        }
    }
}
