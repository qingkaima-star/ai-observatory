//
//  PerformanceSummaryGrid.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-QUIET-3
//  ─────────────────────────────────────────────────────────
//  职责：关键指标网格（值入参）与四张曲线共用的单位换算。
//
//  两条刻意的设计决定，不许在后续改动里漂回去：
//
//  1. **只收 `[PerformanceMetricTile]`，不收 `PerformanceModel`。**
//     旧版这里直接 `let model: PerformanceModel`，而 model 的 `points` /
//     `thermalCelsius` / `networkInBytesPerSecond` 等全是计算属性
//     （`@Observable` 不缓存），于是一次 body 把整条序列重算多遍，
//     每遍都是**新数组身份** ⇒ Swift Charts 按身份重新分配内部 id ⇒ RSS 只增不减。
//     取数因此上移到 `PerformanceView`（那里在 body 顶部 `let` 绑一次）。
//
//  2. **瓷贴不再并列本 App 的 3% / 200 MB 预算**（那是**本进程**的尺子，
//     而这里读的是整机 / 被观测会话的量）。原先「当前 CPU 15.6%」下面挂
//     「空闲预算 3%」，读者会算出「超预算 133 倍」这种荒谬结论。
//     预算的自述行改由 `PerformanceView` 的 hero 区如实说明，本页只有一份。
//
//  网络与 GPU 是**整机**口径：读不到时显示空态而不是 0，见 `PerformanceDisplay`。
//

import SwiftUI
import AIObservatoryCore

/// 指标网格的一格。
///
/// 刻意**不带 `emphasis`**：本页唯一的 `.hero`（当前 CPU）由 `PerformanceView` 画，
/// 网格里的每一格都是 22pt 的次级读数——「九个读数九个重量」就是「没有主次」。
struct PerformanceMetricTile: Identifiable, Hashable {
    let id: Int
    let title: String
    let value: String
    var unit: String = ""
    var trend: Double? = nil
    var caption: String? = nil
}

/// 四张曲线共用的单位换算。
///
/// 为什么必须有它：`ObservatoryChart.valueAxis(suffix:)` 的轴标签是
/// `Int(double) + suffix`，所以纵轴**必须换算到量级合适的单位**才能画——
/// 直接画字节会得到 `18633392025` 这种没法读的标签，
/// 而固定 MB/s 会把「每秒几百 KB」的网络曲线压成一排 0。
enum PerformanceUnits {
    /// 除数一律按 1024 进位，与 `ByteFormat`（`Formatting.swift:64`）同一个口径——
    /// 它除的是 1024 而写的是 KB/MB/GB，所以这里的后缀也必须写 KB/MB/GB，
    /// 否则同一张图上会出现两把尺（轴读 MB、副标题读 MiB）。
    static let bytesPerKB: Double = 1_024
    static let bytesPerMB: Double = 1_048_576
    static let bytesPerGB: Double = 1_073_741_824

    /// 常驻内存一律按 GB 画（整机 8–192 GB，会话几十 MB 到几 GB）。
    static func gb(_ bytes: UInt64) -> Double { Double(bytes) / bytesPerGB }
    static func gb(_ bytes: Double) -> Double { bytes / bytesPerGB }

    /// 按峰值量级选速率单位，让轴标签始终落在个位到三位数之间。
    /// 返回 `(换算除数, 轴后缀)`。
    ///
    /// 后缀沿用 `ByteFormat` 的说法（KB/MB/GB）而不是 IEC 的 KiB/MiB/GiB：
    /// `Formatting.swift:64` 那个 formatter **除的是 1024、写的是 KB**，
    /// 图上一句「峰值 320MB/s」的副标题配的正是这套词。
    /// 轴上另起一套 IEC 词，等于在同一张图里放两把尺。
    static func rateScale(peakBytesPerSecond: Double) -> (divisor: Double, suffix: String) {
        if peakBytesPerSecond <= bytesPerMB { return (bytesPerKB, " KB/s") }
        if peakBytesPerSecond <= bytesPerGB { return (bytesPerMB, " MB/s") }
        return (bytesPerGB, " GB/s")
    }
}

/// 定宽等分指标网格。
struct PerformanceSummaryGrid: View {
    private let tiles: [PerformanceMetricTile]
    private let columns: Int

    init(_ tiles: [PerformanceMetricTile], columns: Int = Sizing.metricColumns) {
        self.tiles = tiles
        self.columns = columns
    }

    var body: some View {
        MetricGrid(tiles, columns: columns) { tile in
            StatTile(
                title: tile.title,
                value: tile.value,
                unit: tile.unit,
                trend: tile.trend,
                caption: tile.caption
            )
        }
        .animation(ObservatoryMotion.value, value: tiles)
    }
}

#Preview("PerformanceSummaryGrid 整机口径 8 格") {
    Panel {
        PerformanceSummaryGrid(PerformanceMetricTilePreviewSamples.system, columns: 4)
    }
    .padding(Spacing.xl)
    .frame(width: 1_000)
    .background(Surface.page)
}

#Preview("PerformanceSummaryGrid 会话口径 4 格") {
    Panel {
        PerformanceSummaryGrid(PerformanceMetricTilePreviewSamples.session, columns: 4)
    }
    .padding(Spacing.xl)
    .frame(width: 1_000)
    .background(Surface.page)
}

/// 只给 `#Preview` 喂假数据的脚手架（同 `ProjectCardPreviewSamples` 那一族）。
/// 刻意做成**顶层、标识符里带 Preview 的一整块**而不是 `PerformanceMetricTile` 的静态成员：
/// 双语门禁认这种形状（按括号配对跳过预览脚手架），而挂在 extension 里的静态成员
/// 会被判成"生产代码里写死中文"——那也确实是需要被看见的形状。
/// 演示值本身不参与翻译：它们不进产物。
enum PerformanceMetricTilePreviewSamples {
    /// 演示数据：只用于 Preview，让「一格到底长多大」在不接引擎的情况下也能目视核对。
    static let system: [PerformanceMetricTile] = [
        .init(id: 0, title: "峰值 CPU", value: "148.6", unit: "%", caption: "区间均值 26.4%"),
        .init(id: 1, title: "峰值内存", value: "25.4", unit: "GB", caption: "整机物理 48.0 GB"),
        .init(id: 2, title: "平均负载 (1m)", value: "5.32", caption: "区间均值 3.10"),
        .init(id: 3, title: "GPU 活动（整机近似）", value: "31", unit: "%",
              caption: "整机近似值，不归属任何 Agent 进程"),
        .init(id: 4, title: "网络 ↓", value: "2.4", unit: "MB/s", caption: "区间峰值 8.9 MB/s"),
        .init(id: 5, title: "网络 ↑", value: "310.0", unit: "KB/s", caption: "本轮区间整机没有流量"),
        .init(id: 6, title: "温度", value: "—", caption: "这台机器拿不到温度"),
        .init(id: 7, title: "功耗", value: "—", caption: "这台机器拿不到功耗"),
    ]

    static let session: [PerformanceMetricTile] = [
        .init(id: 0, title: "CPU 峰值", value: "96.0", unit: "%", caption: "含子孙进程同一时刻求和"),
        .init(id: 1, title: "内存峰值", value: "1.8", unit: "GB", caption: "含子孙进程同一时刻求和"),
        .init(id: 2, title: "采样点数", value: "312", caption: "上限 1000，超出从头部裁剪"),
        .init(id: 3, title: "覆盖窗口", value: "15:02 → 15:34", caption: "按当前时间范围"),
    ]
}
