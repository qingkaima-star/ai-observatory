//
//  ObservatoryTokens.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  设计语言「 quiet 」的唯一令牌源：表面、圆角、排版阶梯、间距、布局常量。
//
//  【三条不可协商的规矩】
//  1. 禁止 `.shadow(...)`。深度只由「一级背景差 + 1pt hairline」表达；
//     投影只允许出现在真正浮起的层（sheet / popover / menu），那是系统画的，不是我们画的。
//  2. 禁止 `Material`（ultraThinMaterial 等）做卡片底。材质叠在任意桌面上会糊成灰泥，
//     这正是旧界面「黑黢黢、脏」的根因。
//  3. 禁止 `Color(red:green:blue:)` 与自定义色值。只允许两类：
//     ① 系统语义色（`Color(nsColor: .separatorColor)` 这类，自动适配深浅色）；
//     ② `ObservatoryColor` 里的功能色（风险 / diff / 运行状态）。装饰性配色一律不用。
//

import SwiftUI
import AppKit

// MARK: - 表面

/// 背景与分隔的唯一来源。全部走系统语义色，因此深浅两套自动成立。
enum Surface {
    /// 页面底。**实测**（2026-09-20，macOS 26 浅色）：`windowBackgroundColor` /
    /// `controlBackgroundColor` / `textBackgroundColor` 三个语义背景色**全部解析成纯白**
    /// （`usingColorSpace(.deviceRGB)` 各通道 1.000），所以「面板比页面亮一级」
    /// 拿不到任何对比——真机截图上整页白成一片就是这么来的。
    ///
    /// 改法不是写死一个灰值（那在深色模式下方向会反），而是叠一层
    /// `Color.primary.opacity(...)`：浅色下它是黑、深色下自动是白，
    /// 「抬一级 / 沉一级」的方向在两套外观里都成立。
    static let page = Color.primary.opacity(0.045)

    /// 内容面板底：浅色模式下为纯白，压在 `page` 之上就亮一级。
    static let panel = Color(nsColor: .controlBackgroundColor)

    /// 面板内再下沉一层（代码块、内嵌列表）。
    static let recessed = Color.primary.opacity(0.09)

    /// 1pt 分隔线。
    static let hairline = Color(nsColor: .separatorColor)

    /// 非强调选中底（列表行、分段项）。
    static let selectedRow = Color(nsColor: .unemphasizedSelectedContentBackgroundColor)

    /// 文本层级。
    static let label = Color(nsColor: .labelColor)
    static let secondaryLabel = Color(nsColor: .secondaryLabelColor)
    static let tertiaryLabel = Color(nsColor: .tertiaryLabelColor)

    /// **口径层**：承载「这个数是怎么算出来的」的句子用的那一档颜色。
    ///
    /// 为什么不是 `secondaryLabel`、更不是原先的 `tertiaryLabel`：
    /// 这两档在面板底（`Surface.panel`）上的实测对比是
    /// tertiary ≈ 1.8:1、secondary ≈ 4.0:1，都够不到 WCAG 对小字正文的 4.5:1；
    /// 而这一层承载的是**可核对性的入口**——读不到它，用户就没法把界面上的数
    /// 对回 SQL（台账 `整改波次-2026-09-22` #84 的口径句）。它不是装饰。
    ///
    /// 做法与 `page` / `recessed` 同源：**不写死灰值**，取系统语义色
    /// `labelColor`（深浅两套自动成立），**层级由字号承担**（12pt，见 `Font.axCaption`），
    /// 不由降色承担。用例 `CaptionContrastTests` 把两档外观的对比比值都钉在 4.5:1 之上，
    /// 并且反向钉住「tertiary 那一档确实不达标」——否则这条闸是空的。
    static let captionLabel = Color(nsColor: .labelColor)
}

// MARK: - 圆角

/// 圆角只有四档。旧界面的 16pt 大圆角 + 描边 + 投影叠在一起是「玩具感」的来源。
enum ObservatoryRadius {
    /// 内容面板。
    static let panel: CGFloat = 10
    /// 控件与内嵌下沉区。
    static let control: CGFloat = 6
    /// 标签（Tag）与色点容器。
    static let tag: CGFloat = 5
    /// **图内标记**（柱条、色条）：不是容器，所以不参与「面板 10 / 控件 6 / 标签 5」那套层级。
    /// 第四档是被两个实测值逼出来的——同一类柱条在两张图里各写各的（2 与 3），
    /// 那就是 ADR-0008 说的「东一个西一个」。收成一颗：柱条要么全 3，要么全不是 3。
    static let mark: CGFloat = 3
}

// MARK: - 布局常量

/// 让界面「规整」的那几个数：列数、宽度、行高必须来自这里，不许各页自己凑。
enum Sizing {
    /// 内容列最大宽度。窗口再宽也居中收口，避免一行读数被拉到 2560pt。
    static let contentMaxWidth: CGFloat = 1120
    /// 侧边栏理想宽度。
    static let sidebarWidth: CGFloat = 216
    /// 指标网格默认列数：一行必须填满，不许出现落单的第六张卡。
    static let metricColumns: Int = 4
    /// 指标网格的**摘要档**列数：六格排两行三列（首页「时段累计」、时间线指标区）。
    ///
    /// 为什么要两档而不是"各页写一个数"：改之前 `metricColumns = 4`、首页写死 `columns: 3`、
    /// 安全页用默认 4 —— 三处不同档，谁也不是出处（#83）。
    /// 只有这两档：2 列的那种（菜单栏、会话详情）不是"一排指标"，是"两栏字段"，
    /// 它自己就是版面，不该混进这一族。
    static let summaryColumns: Int = 3
    /// 指标网格列间距。
    static let metricGutter: CGFloat = 16
    /// 列表行最小高度（可点击行的触控下限）。
    static let rowMinHeight: CGFloat = 32
    /// 图表默认高度。
    static let chartHeight: CGFloat = 180
    /// 迷你图（行内 sparkline）高度。
    static let sparklineHeight: CGFloat = 28
}

// MARK: - 排版阶梯

/// 七级阶梯。**层级靠字号与字重，不靠容器**——这是本次重构的核心手法。
///
/// ⚠️ 界面文案以中文为主，因此**不使用** `textCase(.uppercase)` 与拉丁字距（tracking）
/// 作为标签层级的表达：CJK 加字距会散架。标签层级只靠「11pt + 次级色」。
extension Font {
    /// 页面主标题（每个页面只允许一个）。
    static let axPage: Font = .system(size: 28, weight: .regular)
    /// 本页最重要的那一个数（每个页面只允许一个）。
    static let axHero: Font = .system(size: 40, weight: .regular).monospacedDigit()
    /// 次级指标数值。
    static let axMetric: Font = .system(size: 22, weight: .regular).monospacedDigit()
    /// 面板/小节标题。
    static let axSection: Font = .system(size: 13, weight: .semibold)
    /// 小号标签（指标名、字段名）。
    static let axLabel: Font = .system(size: 11, weight: .medium)
    /// 正文。
    static let axBody: Font = .system(size: 13, weight: .regular)
    /// 口径层：**承载信息**的次级句子（「这个数是怎么算出来的」、单位、趋势幅度）。
    ///
    /// 与 `axMeta` 的分工不是"谁大一号"，是**两种射程**：
    /// `axCaption` 配 `Surface.captionLabel`，用在读不到就算丢信息的地方；
    /// `axMeta` 配 `secondaryLabel` / `tertiaryLabel`，用在纯装饰性的次要信息
    /// （行尾时间戳、示例注释、图例的重复说明）。
    /// 12pt 而不是 13pt：它必须比正文小一档（不然和正文分不出主次），
    /// 但颜色与正文同档 —— 「层级靠字号，不靠降色」，见 `Surface.captionLabel`。
    static let axCaption: Font = .system(size: 12, weight: .regular)
    /// 次要说明、时间戳、行尾元信息。
    static let axMeta: Font = .system(size: 11, weight: .regular)
    /// 等宽：命令行、路径、diff。
    static let axMono: Font = .system(size: 12, weight: .regular, design: .monospaced)
    /// 等宽小字：表格里的代码标识。
    static let axMetaMono: Font = .system(size: 11, weight: .regular, design: .monospaced)
}

// MARK: - 排版辅助

extension View {
    /// 标签层：11pt 次级色。指标名、字段名统一用它，不再配彩色图标。
    func axLabelStyle() -> some View {
        self.font(.axLabel).foregroundStyle(Surface.secondaryLabel)
    }

    /// 元信息层：11pt 三级色。
    func axMetaStyle() -> some View {
        self.font(.axMeta).foregroundStyle(Surface.tertiaryLabel)
    }

    /// 口径层：12pt + 与正文同档的颜色。
    ///
    /// 【什么时候必须用它，什么时候不该用】只要这句话是在回答
    /// 「这个数是怎么算出来的 / 窗口是哪个 / 单位是什么 / 哪些没算进来」，就用它；
    /// 只是给一屏里已经读得到的东西再补一句装饰（示例注释、图例复述、行尾时间戳），
    /// 留在 `axMetaStyle()`——把每一句都提上来，等于把所有句子都降成同一档。
    func axCaptionStyle() -> some View {
        self.font(.axCaption).foregroundStyle(Surface.captionLabel)
    }
}

// MARK: - 动效

enum ObservatoryMotion {
    /// 数值变化。
    static let value: Animation = .snappy(duration: 0.25)
}
