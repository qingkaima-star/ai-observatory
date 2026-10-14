//
//  ChartChrome.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  图表公共外壳：坐标轴画法、序列取色、图例。所有 Swift Charts 必须走这里，
//  否则九张图会长出九套轴标签字号——那正是「东一个西一个」。
//
//  画法约定：
//  - 只有水平网格线，1pt `Surface.hairline`，不画轴线（axis line）；
//  - 轴标签 11pt 三级色，与正文抢注意力的一律不要；
//  - 序列色走 `ObservatoryTheme.chartColor(rank:)`：第一条强调色，其余灰阶梯队；
//  - 参考线（物理内存、峰值）必须把自身值算进 y 域，否则会被夹到绘图区上沿却仍标着原值
//    ——本仓踩过，见 [[aix-ui-integration-gotchas]] 第 14 条。
//
//  「轴**怎么画**」与「轴**在哪里挂上**」也必须同源（`ws/axes` 补的那一格）：
//  本文件过去只给 `AxisMarks`，六处图表各自写 `.chartXAxis { … }` / `.chartYAxis { … }`，
//  字号颜色是统一了，但「哪条轴走哪一档」仍是六份各自的决定，而第七张图只会去抄调用点。
//  `Scripts/gate-quiet-design.sh` 门禁 2 数的就是这个动作（判据 = 本文件之外零 `chart*Axis`），
//  所以挂轴这一步收在下面的 `observatoryAxes(x:ySuffix:)` 里，调用点只剩一行。
//  实现口径：一条轴一个分支、每个分支只出现**一种** `AxisContent`（见
//  `ObservatoryXAxisModifier`），多分支的 `some AxisContent` 在这套工具链上解析不稳定，
//  真需要跨分支换类型时才擦成 `AnyView`——这里不需要。
//

import SwiftUI
import Charts

enum ObservatoryChart {

    /// 第 `rank` 条序列的颜色。
    static func color(rank: Int) -> Color { ObservatoryTheme.chartColor(rank: rank) }

    /// 数值轴（y）：左侧标签 + 水平网格线，无轴线。
    static var valueAxis: some AxisContent {
        AxisMarks(preset: .aligned, position: .leading, values: .automatic(desiredCount: 4)) {
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                .foregroundStyle(Surface.hairline)
            AxisValueLabel()
                .foregroundStyle(Surface.tertiaryLabel)
        }
    }

    /// 数值轴（y）带单位后缀。
    static func valueAxis(suffix: String) -> some AxisContent {
        AxisMarks(preset: .aligned, position: .leading, values: .automatic(desiredCount: 4)) { value in
            AxisGridLine(stroke: StrokeStyle(lineWidth: 1))
                .foregroundStyle(Surface.hairline)
            AxisValueLabel {
                if let double = value.as(Double.self) {
                    Text("\(Int(double))\(suffix)")
                        .font(.axMeta)
                        .foregroundStyle(Surface.tertiaryLabel)
                }
            }
        }
    }

    /// 时间轴（x）：底部稀疏刻度 + 标签，无网格线。
    static var timeAxis: some AxisContent {
        AxisMarks(preset: .aligned, position: .bottom, values: .automatic(desiredCount: 5)) {
            AxisValueLabel()
                .foregroundStyle(Surface.tertiaryLabel)
        }
    }

    /// 类目轴（x）：用于按小时 / 按项目分组的稀疏标签。
    static var categoryAxis: some AxisContent {
        AxisMarks(preset: .aligned, position: .bottom, values: .automatic(desiredCount: 5)) {
            AxisValueLabel()
                .foregroundStyle(Surface.tertiaryLabel)
        }
    }

    /// 小时轴（x）：只在给定的整点上标注，标签补零成「06」。
    ///
    /// 为什么要单开一条而不是复用 `categoryAxis`：24 小时柱图要的是一个**白名单**
    /// （0/6/12/18/23），`.automatic(desiredCount:)` 给不出确定集合；
    /// 但字号、颜色、「x 轴不画网格线与轴线」这几条必须和别的轴一模一样。
    /// 共享 chrome 之前每张图各写一套，九张图就长出九套轴标签——那正是「东一个西一个」。
    static func hourAxis(hours: [Int]) -> some AxisContent {
        AxisMarks(preset: .aligned, position: .bottom, values: hours) { value in
            AxisValueLabel {
                if let hour = value.as(Int.self) {
                    Text(String(format: "%02d", hour))
                        .font(.axMeta)
                        .monospacedDigit()
                        .foregroundStyle(Surface.tertiaryLabel)
                }
            }
        }
    }

    /// 迷你图（行内 sparkline）：固定高度、完全隐轴。
    static func sparkline(_ chart: some View, height: CGFloat = Sizing.sparklineHeight) -> some View {
        chart
            .frame(height: height)
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
    }
}

// MARK: - 共享轴的挂载点

/// 一张图的横轴走哪一种共享画法。
///
/// 只有这四档，且**每一档怎么画都写在本文件里**：调用点只说「我这根轴是什么」
/// （时间 / 类目 / 小时白名单 / 这一档根本不画），说不出「这条轴长什么样」。
enum ObservatoryXAxis {
    /// 连续时间轴（性能那四张曲线的 x）。
    case time
    /// 类目轴（按 Agent / 按项目分组的柱图 x）。
    case category
    /// 小时轴：只在给定的整点上标注（首页 24 格柱图）。白名单由调用点给，
    /// 但必须是**共用的那一份常量**，不要每次刷新现造一个数组。
    case hours([Int])
    /// 整根轴收起：那一档的刻度数字读不出意义（首页 > 36 h 走自然日桶，
    /// x 那列是「距今第几天」的带符号序号），日期口径由副标题与页脚那两句给。
    case hidden
}

extension View {

    /// 给一张 Swift Charts 图挂上共享的两条坐标轴（本文件之外不许再写 `.chartXAxis` / `.chartYAxis`）。
    ///
    /// 【为什么必须有它】共享件先前只给 `AxisMarks`，六处图表各自写一遍挂载动作，
    /// 于是 `Scripts/gate-quiet-design.sh` 门禁 2 数到 6 个「自绘坐标轴」文件而常红
    /// （台账裁定 4 / 裁定 12）。把动作也收进共享实现之后，「统一」才是结构上的事实
    /// 而不是每次审查时的一句约定：新图抄这一行，抄不到第二套轴。
    ///
    /// 【为什么不写成「一个 `chartXAxis` 闭包里 `switch axis`」】一个 `@AxisContentBuilder` 闭包里
    /// 要同时满足四种返回类型，正是本文件头那条「多分支的 `some AxisContent` 解析不稳定」——
    /// 这里改成「一种轴一个分支、每分支一种 `AxisContent`」的 `ViewModifier`，
    /// 既不用 `AnyView` 擦除，也不跟类型推导较劲。
    ///
    /// - Parameters:
    ///   - x: 横轴种类，见 `ObservatoryXAxis`。
    ///   - ySuffix: 纵轴刻度的单位后缀（`"%"` / `" MB"` / `" GB"`）；
    ///     不传就是让 Swift Charts 自己格式化（首页柱图那种纯计数）。
    func observatoryAxes(x: ObservatoryXAxis, ySuffix: String? = nil) -> some View {
        self
            .modifier(ObservatoryXAxisModifier(axis: x))
            .modifier(ObservatoryValueYAxisModifier(suffix: ySuffix))
    }
}

/// 横轴挂载：四种轴各一条分支。
private struct ObservatoryXAxisModifier: ViewModifier {
    let axis: ObservatoryXAxis

    // `ViewModifier.body` 是 `@ViewBuilder`，四条分支的底层类型可以不同；
    // 每条分支的闭包里只有一种 `AxisContent`，推导就不会在四种返回类型之间摇摆。
    func body(content: Content) -> some View {
        switch axis {
        case .time:
            content.chartXAxis { ObservatoryChart.timeAxis }
        case .category:
            content.chartXAxis { ObservatoryChart.categoryAxis }
        case .hours(let hours):
            content.chartXAxis { ObservatoryChart.hourAxis(hours: hours) }
        case .hidden:
            content.chartXAxis(.hidden)
        }
    }
}

/// 纵轴挂载：带单位后缀与不带，是同一套画法的两档。
private struct ObservatoryValueYAxisModifier: ViewModifier {
    let suffix: String?

    func body(content: Content) -> some View {
        if let suffix {
            content.chartYAxis { ObservatoryChart.valueAxis(suffix: suffix) }
        } else {
            content.chartYAxis { ObservatoryChart.valueAxis }
        }
    }
}

// MARK: - 图例

/// 序列图例：色点 + 名称，11pt。放在图的右上方或下方，不画框。
struct ChartLegend: View {
    /// 一条图例项。
    struct Item: Identifiable {
        let id: Int
        let label: String
        let color: Color

        /// ⚠️ `id` **没有默认值，这是故意的**，别加回去：
        /// `ChartLegend.body` 按 `\.id` 走 `ForEach`，两条序列同 id 时 SwiftUI 把第一条
        /// 渲染 N 遍、其余序列在图例里凭空消失——真机实测是图例写着「用户 用户」，
        /// 而图上确实有两条线。原来这里是 `id: Int = 0`，于是**漏传就是同 id**，
        /// 编译零警告、上千条测试全绿都抓不到它（本仓吃过一次）。
        /// 现在漏传是编译错误，而不是一个看起来正常的图例。
        init(id: Int, label: String, color: Color) {
            self.id = id
            self.label = label
            self.color = color
        }
    }

    private let items: [Item]

    init(_ items: [Item]) {
        self.items = items
    }

    var body: some View {
        HStack(spacing: Spacing.md) {
            ForEach(items) { item in
                HStack(spacing: Spacing.xs) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 6, height: 6)
                        .accessibilityHidden(true)
                    Text(item.label)
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .lineLimit(1)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("图表外壳与图例") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        ChartLegend([
            .init(id: 0, label: "用户", color: ObservatoryChart.color(rank: 0)),
            .init(id: 1, label: "系统", color: ObservatoryChart.color(rank: 1)),
            .init(id: 2, label: "空闲", color: ObservatoryChart.color(rank: 2)),
        ])
        Chart(CPUSample.demo) { point in
            LineMark(x: .value("时间", point.at), y: .value("用户", point.user))
                .foregroundStyle(ObservatoryChart.color(rank: 0))
            LineMark(x: .value("时间", point.at), y: .value("系统", point.system))
                .foregroundStyle(ObservatoryChart.color(rank: 1))
        }
        .chartYAxis { ObservatoryChart.valueAxis }
        .chartXAxis { ObservatoryChart.timeAxis }
        .frame(height: Sizing.chartHeight)
    }
    .padding(Spacing.lg)
    .background(Surface.panel)
}

private struct CPUSample: Identifiable {
    let index: Int
    let at: Date
    let user: Double
    let system: Double

    var id: Int { index }

    static let demo: [CPUSample] = (0..<40).map { index in
        let phase = Double(index) / 6
        return CPUSample(
            index: index,
            at: Date(timeIntervalSince1970: 1_800_000_000 + Double(index) * 60),
            user: 20 + 14 * sin(phase),
            system: 8 + 5 * cos(phase)
        )
    }
}
