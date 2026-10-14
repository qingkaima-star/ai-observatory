//
//  PerformanceDiskIOGraph.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-QUIET-3
//  职责：磁盘 IO 曲线 —— 读取 / 写入两条双向序列，纵轴按峰值量级自动选单位。
//
//  序列色只用 `ObservatoryChart.color(rank:)`（读取 = rank 0 强调色，写入 = rank 1 灰阶）。
//  旧版是「蓝/紫 + chartForegroundStyleScale」那套固定色相：
//  读和写谁高谁低用灰阶比用蓝紫好读，而且紫色在深色模式下发成一块色斑，
//  正是用户说的「黑黢黢、脏」。
//
//  纵轴为什么不能直接画字节：`ObservatoryChart.valueAxis(suffix:)` 的标签是整数
//  （见 `PerformanceUnits` 的说明），所以先按峰值量级换算到 KB / MB / GB 再画。
//

import SwiftUI
import Charts
import AIObservatoryCore

struct PerformanceDiskIOGraph: View {
    let points: [PerformanceSeriesPoint]

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        // 峰值一趟算完。它原先是计算属性，自身要过两遍序列，而它在 body 里被读 2 次。
        let peakRate = points.reduce(0) { max(max($0, $1.diskReadBytesPerSecond), $1.diskWriteBytesPerSecond) }
        let scale = PerformanceUnits.rateScale(peakBytesPerSecond: peakRate)
        if points.isEmpty {
            EmptyStateView(
                PerformanceCopy.diskEmptyTitle.text(language),
                systemImage: "internaldrive",
                message: PerformanceCopy.diskEmptyMessage.text(language),
                fills: false
            )
            .frame(maxWidth: .infinity)
            .frame(height: Sizing.chartHeight)
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // `id` 必须显式传，理由同 `PerformanceCPUGraph`。
                ChartLegend([
                    .init(id: 0, label: PerformanceCopy.diskRead.text(language),
                          color: ObservatoryChart.color(rank: 0)),
                    .init(id: 1, label: PerformanceCopy.diskWrite.text(language),
                          color: ObservatoryChart.color(rank: 1)),
                ])
                Chart {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.axisRate.text(language), point.diskReadBytesPerSecond / scale.divisor),
                            series: .value(PerformanceCopy.axisDirection.text(language),
                                            PerformanceCopy.diskRead.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 0).opacity(0.12))
                        .interpolationMethod(.monotone)
                    }

                    ForEach(points) { point in
                        AreaMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.axisRate.text(language), point.diskWriteBytesPerSecond / scale.divisor),
                            series: .value(PerformanceCopy.axisDirection.text(language),
                                            PerformanceCopy.diskWrite.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 1).opacity(0.12))
                        .interpolationMethod(.monotone)
                    }

                    ForEach(points) { point in
                        LineMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.axisRate.text(language), point.diskReadBytesPerSecond / scale.divisor),
                            series: .value(PerformanceCopy.axisDirection.text(language),
                                            PerformanceCopy.diskRead.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 0))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }

                    ForEach(points) { point in
                        LineMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.axisRate.text(language), point.diskWriteBytesPerSecond / scale.divisor),
                            series: .value(PerformanceCopy.axisDirection.text(language),
                                            PerformanceCopy.diskWrite.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 1))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.4))
                    }
                }
                .chartYScale(domain: 0...max(peakRate / scale.divisor * 1.15, 1))
                .observatoryAxes(x: .time, ySuffix: scale.suffix)
                .frame(maxWidth: .infinity)
                .frame(height: Sizing.chartHeight)
            }
            .accessibilityLabel(PerformanceCopy.diskA11y.format(
                language, ByteFormat.rate(peakRate)))
        }
    }
}

#Preview("PerformanceDiskIOGraph") {
    Panel {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("磁盘 IO", subtitle: "读取 / 写入速率")
            PerformanceDiskIOGraph(points: PerformancePreviewPoints.sixHours())
        }
    }
    .padding(Spacing.xl)
    .frame(width: 620)
    .background(Surface.page)
}
