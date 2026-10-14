//
//  StatTile.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  指标读数块。**自身不带容器**——要不要白底面板由调用方决定（`Panel { MetricGrid… }`）。
//
//  与旧版的区别就是本次重构的缩影：
//    旧：玻璃卡里塞一个彩色 SF 图标 + 圆角数字 + 一张卡，五个一排，第六个掉到下一行。
//    新：三档字号阶梯（hero / metric / compact），无图标、无色彩、无容器，
//        一排几列由 `MetricGrid` 定死，落单的行用空格补齐以保持列对齐。
//
//  层级靠字号，不靠框。每页只允许一个 `.hero`。
//
//  【#11 · 2026-09-22】带 `action` 与不带 `action` 的**样子**从此不同：
//  上面那句"自身不带容器"仍然成立，可点的判据不再是"有没有被私有的 `OptionalTap` 包了一层
//  `.plain` 按钮"（`.plain` 只有按下有反馈，悬停与光标都没有），而是走 `DesignSystem`
//  里那一份共用处理 `axPressable(when:)`：有 action ⇒ 悬停抬一档、按下再抬一档、手型光标、
//  Tab 停得住；没有 action ⇒ 这四样**一个都拿不到**，于是"看起来不可点"不再靠读者猜。
//  判据用例：`Tests/AIObservatoryUITests/InteractionFeedbackTests.swift`。
//
//  【#84 · 2026-09-22】caption / 单位 / 趋势这三处原先跑在最低对比档
//  （`.axMeta` 11pt + `Surface.tertiaryLabel`，在面板底上实测 ≈1.8:1），
//  而首页每一句「这个数是怎么算出来的」都从这里过（`DashboardView` 的六个 tile、
//  五页的「服务端匹配总数 · 与分页无关」…）——可核对性的入口被画成了装饰。
//  现在三处统一走口径层 `axCaptionStyle()`（12pt + 与正文同档的颜色）。
//  判据与反向校准用例：`Tests/AIObservatoryUITests/CaptionContrastTests.swift`。
//

import SwiftUI

struct StatTile: View {
    /// 数值在页面层级里的重量。
    enum Emphasis {
        /// 40pt：本页唯一的主读数。
        case hero
        /// 22pt：并列的次级读数。
        case metric
        /// 13pt 半粗：行内、列表尾、菜单栏里的紧凑读数。
        case compact
    }

    private let title: String
    private let value: String
    private let unit: String
    private let trend: Double?
    private let caption: String?
    private let emphasis: Emphasis
    /// 块内对齐方向。**列表/表格里的数字列传 `true`**（#83：同一列末位对齐才叫成列），
    /// 页面顶部的指标网格保持 `.false`——那里读的是标题，不是竖着比大小。
    private let trailing: Bool
    private let action: (() -> Void)?

    init(title: String,
         value: String,
         unit: String = "",
         trend: Double? = nil,
         caption: String? = nil,
         emphasis: Emphasis = .metric,
         trailing: Bool = false,
         action: (() -> Void)? = nil) {
        self.title = title
        self.value = value
        self.unit = unit
        self.trend = trend
        self.caption = caption
        self.emphasis = emphasis
        self.trailing = trailing
        self.action = action
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: blockAlignment)
            .contentShape(Rectangle())
            // #11：可点与否的唯一判据。原来这里是一份**文件私有**的 `OptionalTap`
            // （`Button` + `.buttonStyle(.plain)`），悬停没有反馈、光标不变手型，
            // 界面上"这一格能不能点"就只剩"有没有人包过 Button"这一条隐形的线。
            .axPressable(when: action)
    }

    private var blockAlignment: Alignment { trailing ? .trailing : .leading }

    private var content: some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                Text(title)
                    .font(emphasis == .compact ? .axMeta : .axLabel)
                    .foregroundStyle(Surface.secondaryLabel)
                    .lineLimit(1)
                Spacer(minLength: Spacing.none)
                if let trend { trendLabel(trend) }
            }
            valueRow
            if let caption {
                Text(caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    // 2026-09-24：给 caption 的理想宽封顶。`fixedSize(horizontal: false)` 只在
                    // **有提案宽**时换行；`ViewThatFits` 量理想宽时提案是 nil ⇒ caption 按单行算
                    // （实测一句口径 caption 单行理想宽 ~573pt），于是整页地板被一句说明文字顶到 1133，
                    // 1280 宽的窗口里三栏放不下、两端裁切。封到 300：现有各档列宽都 < 300，
                    // 宽屏视觉逐字不变，窄屏的理想宽不再由一句 caption 说了算。
                    .frame(maxWidth: 300, alignment: .leading)
                    .axCaptionStyle()
            }
        }
        .animation(ObservatoryMotion.value, value: value)
        .accessibilityElement(children: .combine)
    }

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Text(value)
                .font(valueFont)
                .foregroundStyle(Surface.label)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if !unit.isEmpty {
                Text(unit)
                    .axCaptionStyle()
            }
        }
    }

    private var valueFont: Font {
        switch emphasis {
        case .hero:    return .axHero
        case .metric:  return .axMetric
        case .compact: return .system(size: 13, weight: .semibold).monospacedDigit()
        }
    }

    /// 趋势只画方向与幅度，**不上色**：涨跌是否算「好」取决于指标语义
    /// （风险上升是坏事、吞吐上升是好事），调用方没有渠道表达这一点，染色的趋势就是假信号。
    private func trendLabel(_ trend: Double) -> some View {
        let isUp = trend >= 0
        return HStack(spacing: Spacing.xs) {
            Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                .font(.system(size: 9, weight: .semibold))
            Text(String(format: "%@%.0f%%", isUp ? "+" : "-", abs(trend)))
                .font(.axMeta)
                .monospacedDigit()
        }
        .axCaptionStyle()
        .accessibilityLabel("趋势 \(String(format: "%+.0f", trend))%")
    }
}

#Preview("StatTile 三档") {
    HStack(alignment: .top, spacing: Sizing.metricGutter) {
        StatTile(title: "活跃总时长", value: "12h47m", caption: "跨 2 个会话", emphasis: .hero)
        StatTile(title: "今日文件变更", value: "26", unit: "处", caption: "修改 6 · 新建 5 · 删除 15")
        StatTile(title: "执行命令", value: "2", trend: 18, caption: "失败 0 次")
        StatTile(title: "峰值内存", value: "267.8", unit: "MB", emphasis: .compact)
    }
    .padding(Spacing.lg)
    .background(Surface.panel)
}
