//
//  PerformanceNetworkGraph.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-Perf → WS-QUIET-3（本轮只改画法，没动采集与可信判定口径）
//  职责：整机网络速率时间序列（↓ rank 0 / ↑ rank 1），纵轴按峰值量级自动选单位。
//
//  只有整机口径：会话级采样不带网络字段（macOS 给不出非 root 的按进程字节数），
//  所以这张图不进会话视图，也不参与任何「某个 Agent 用了多少流量」的归因。
//  本轮不可信的采样点（计数器回绕、网卡重连）直接没有值——图上不画点，
//  而不是补一个 0 让曲线看起来「掉底了」。
//
//  序列色只用 `ObservatoryChart.color(rank:)`：旧版 ↓ 蓝 ↑ 青是两个不带语义的色相，
//  读者无法从颜色解码任何信息，只制造噪声（ADR-0007 三条禁令之「禁装饰性配色」）。
//

import SwiftUI
import Charts
import AIObservatoryCore

struct PerformanceNetworkGraph: View {
    /// 只接受 `hasNetworkReading` 为真的点；这里再过滤一遍，视图不依赖调用方的自觉。
    let points: [PerformanceSeriesPoint]
    let emptyMessage: String

    /// 图上真正要画的点：两个方向都拿到值的轮次。
    private struct Reading: Identifiable {
        let id: UUID
        let timestamp: Date
        let inbound: Double
        let outbound: Double
    }

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        // 算一次并 let 住：它原先是计算属性，却被 4 个 ForEach + 判空 + 峰值各读一遍，
        // 每读一次就 compactMap 重出一条 [Reading]（真机 heap 里同时存活着 8 份）。
        let readings = points.compactMap { point -> Reading? in
            guard let inbound = point.networkInBytesPerSecond,
                  let outbound = point.networkOutBytesPerSecond else { return nil }
            return Reading(id: point.id, timestamp: point.timestamp, inbound: inbound, outbound: outbound)
        }
        let peakRate = readings.reduce(0) { max(max($0, $1.inbound), $1.outbound) }
        let scale = PerformanceUnits.rateScale(peakBytesPerSecond: peakRate)
        if readings.isEmpty {
            EmptyStateView(
                PerformanceCopy.networkEmptyTitle.text(language),
                systemImage: "network",
                message: emptyMessage,
                fills: false
            )
            .frame(maxWidth: .infinity)
            .frame(height: Sizing.chartHeight)
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // `id` 必须显式传，理由同 `PerformanceCPUGraph`。
                ChartLegend([
                    .init(id: 0, label: PerformanceCopy.networkDown.text(language),
                          color: ObservatoryChart.color(rank: 0)),
                    .init(id: 1, label: PerformanceCopy.networkUp.text(language),
                          color: ObservatoryChart.color(rank: 1)),
                ])
                Chart {
                    ForEach(readings) { reading in
                        AreaMark(
                            x: .value(PerformanceCopy.axisTime.text(language), reading.timestamp),
                            y: .value(PerformanceCopy.axisRate.text(language), reading.inbound / scale.divisor),
                            series: .value(PerformanceCopy.axisDirection.text(language),
                                            PerformanceCopy.networkDown.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 0).opacity(0.12))
                        .interpolationMethod(.monotone)
                    }

                    ForEach(readings) { reading in
                        AreaMark(
                            x: .value(PerformanceCopy.axisTime.text(language), reading.timestamp),
                            y: .value(PerformanceCopy.axisRate.text(language), reading.outbound / scale.divisor),
                            series: .value(PerformanceCopy.axisDirection.text(language),
                                            PerformanceCopy.networkUp.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 1).opacity(0.12))
                        .interpolationMethod(.monotone)
                    }

                    ForEach(readings) { reading in
                        LineMark(
                            x: .value(PerformanceCopy.axisTime.text(language), reading.timestamp),
                            y: .value(PerformanceCopy.axisRate.text(language), reading.inbound / scale.divisor),
                            series: .value(PerformanceCopy.axisDirection.text(language),
                                            PerformanceCopy.networkDown.text(language))
                        )
                        .foregroundStyle(ObservatoryChart.color(rank: 0))
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 1.8))
                    }

                    ForEach(readings) { reading in
                        LineMark(
                            x: .value(PerformanceCopy.axisTime.text(language), reading.timestamp),
                            y: .value(PerformanceCopy.axisRate.text(language), reading.outbound / scale.divisor),
                            series: .value(PerformanceCopy.axisDirection.text(language),
                                            PerformanceCopy.networkUp.text(language))
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
            .accessibilityLabel(PerformanceCopy.networkA11y.format(
                language, ByteFormat.rate(peakRate)))
        }
    }
}

#Preview("PerformanceNetworkGraph") {
    Panel {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader("网络", subtitle: "整机下行 / 上行速率")
            PerformanceNetworkGraph(points: previewPoints, emptyMessage: "—")
        }
    }
    .padding(Spacing.xl)
    .frame(width: 620)
    .background(Surface.page)
}

/// 预览用的整机采样：夹具（`SampleData`）不带网络字段，这里自带一份，
/// 否则这张图在 Preview 里永远是空态，看不出画成什么样。
private func previewPoint(_ index: Int) -> PerformanceSeriesPoint {
    let interval = Double(index) * 30
    let inbound = 2_000_000.0 + Double(index) * 240_000
    let outbound = 600_000.0 + Double(index % 4) * 420_000
    let sample = SystemPerformanceSample(
        timestamp: Date().addingTimeInterval(interval),
        networkInBytesPerSecond: inbound,
        networkOutBytesPerSecond: outbound
    )
    return PerformanceSeriesPoint(sample)
}

private let previewPoints: [PerformanceSeriesPoint] = (0..<12).map(previewPoint)
