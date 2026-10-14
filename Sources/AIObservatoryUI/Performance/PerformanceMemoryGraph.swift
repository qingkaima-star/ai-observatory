//
//  PerformanceMemoryGraph.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-QUIET-3
//  职责：内存曲线 —— 已用内存折线 + 淡面积 + 可选的物理内存参考线。
//        纵轴按 **GB** 画（`ObservatoryChart.valueAxis(suffix:)` 的标签是整数，
//        直接画字节会得到 18633392025 这种读不了的刻度）。
//
//  刻意**不画**「常驻预算 200 MB」参考线：那是**本 App 这个进程**的尺子，
//  这张图画的是整机（或某个会话）的常驻量，两者不同阶（AGENTS.md §6）。
//  物理内存线则**必须**参与 y 域计算，见下面 `chartYScale` 那段注释——
//  这条线被夹到绘图区上沿却仍标着「物理 48.0 GB」的错，本仓真机踩过一次。
//

import SwiftUI
import Charts
import AIObservatoryCore

struct PerformanceMemoryGraph: View {
    let points: [PerformanceSeriesPoint]
    /// 物理内存上限（字节）；> 0 时画参考线。
    var capacityBytes: UInt64 = 0

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        // 峰值与容量各换算一次，别在 4 个 Mark 里各自重复除。
        let peakBytes = points.reduce(UInt64(0)) { max($0, $1.memoryUsedBytes) }
        let peakGB = PerformanceUnits.gb(peakBytes)
        let capacityGB = PerformanceUnits.gb(capacityBytes)
        if points.isEmpty {
            EmptyStateView(
                PerformanceCopy.memoryEmptyTitle.text(language),
                systemImage: "memorychip",
                message: PerformanceCopy.memoryEmptyMessage.text(language),
                fills: false
            )
            .frame(maxWidth: .infinity)
            .frame(height: Sizing.chartHeight)
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                ChartLegend([
                    // `id` 显式传且不得重复（同 id 会让 ForEach 把第一条渲染两遍，理由见 CPU 图）。
                    .init(id: 0, label: PerformanceCopy.memoryUsed.text(language),
                          color: ObservatoryChart.color(rank: 0)),
                ])
                Chart {
                    ForEach(points) { point in
                        AreaMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.memoryUsed.text(language),
                                      PerformanceUnits.gb(point.memoryUsedBytes))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 0).opacity(0.12))
                        .interpolationMethod(.monotone)
                    }

                    ForEach(points) { point in
                        LineMark(
                            x: .value(PerformanceCopy.axisTime.text(language), point.timestamp),
                            y: .value(PerformanceCopy.memoryUsed.text(language),
                                      PerformanceUnits.gb(point.memoryUsedBytes)),
                            series: .value(PerformanceCopy.seriesName.text(language),
                                            PerformanceCopy.seriesUsed.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 0))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }

                    if capacityBytes > 0 {
                        RuleMark(y: .value(PerformanceCopy.axisPhysicalMemory.text(language), capacityGB))
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
                            .foregroundStyle(Surface.tertiaryLabel)
                            .annotation(position: .top, alignment: .trailing) {
                                // 标注与纵轴同一个单位（GB）。写 ByteFormat 那种
                                // 「48.0 GB」带一位小数的形式，会和整数刻度打架。
                                Text(PerformanceCopy.physicalAnnotation.format(
                                    language, String(format: "%.0f GB", capacityGB)))
                                    .font(.axMeta)
                                    .monospacedDigit()
                                    .axCaptionStyle()   // #99：承载口径，曾在最低档
                            }
                    }
                }
                // 定域必须容得下物理内存参考线：原先只按 peak*1.2 定域，
                // 而整机用量峰值（实测 25.4 GB）× 1.2 = 30.5 GB < 物理 48 GB ⇒ 参考线落在域外，
                // 被夹到绘图区上沿后仍然标着「物理 48.0 GB」——那是一条指错位置的参考线。
                .chartYScale(domain: 0...max(peakGB * 1.2, capacityGB * 1.05, 1))
                .observatoryAxes(x: .time, ySuffix: " GB")
                .frame(maxWidth: .infinity)
                .frame(height: Sizing.chartHeight)
            }
            .accessibilityLabel(PerformanceCopy.memoryA11y.format(
                language, ByteFormat.humanReadable(peakBytes)))
        }
    }
}

#Preview("PerformanceMemoryGraph") {
    Panel {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("内存", subtitle: "整机已用常驻内存")
            PerformanceMemoryGraph(
                points: PerformancePreviewPoints.sixHours(),
                capacityBytes: 32 * 1_073_741_824
            )
        }
    }
    .padding(Spacing.xl)
    .frame(width: 620)
    .background(Surface.page)
}

#Preview("PerformanceMemoryGraph 空态") {
    Panel {
        PerformanceMemoryGraph(points: [])
    }
    .padding(Spacing.xl)
    .frame(width: 620)
    .background(Surface.page)
}
