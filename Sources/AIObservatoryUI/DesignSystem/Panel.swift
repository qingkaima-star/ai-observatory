//
//  Panel.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  内容容器：替代旧的玻璃卡（`ultraThinMaterial` 卡底，随本次重写删除）。
//
//  与旧卡片的三处区别，就是本次重构的全部手法：
//    旧：ultraThinMaterial 底 + 16pt 圆角 + 1pt 描边 + 12pt 投影  → 叠在桌面上糊成灰泥
//    新：与页面差一级的纯色底 + 10pt 圆角 + 无描边 + **无投影**    → 分隔靠留白，不靠线
//
//  需要「一组读数」但不想要第二层容器时，用 `.plain`（无底）配合 `Hairline`。
//

import SwiftUI

/// 内容面板。默认 `panel` 底色（浅色模式下为白），无边框、无投影、无材质。
struct Panel<Content: View>: View {
    private enum Tone {
        case panel, recessed, plain
    }

    private let padding: CGFloat
    private let radius: CGFloat
    private let tone: Tone
    private let content: Content

    private init(padding: CGFloat, radius: CGFloat, tone: Tone, @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.radius = radius
        self.tone = tone
        self.content = content()
    }

    /// 白底面板：放在页面灰之上，构成界面的主要分区。
    init(padding: CGFloat = Spacing.lg,
         radius: CGFloat = ObservatoryRadius.panel,
         @ViewBuilder content: () -> Content) {
        self.init(padding: padding, radius: radius, tone: .panel, content: content)
    }

    /// 面板内的下沉区（代码块、内嵌列表），比面板再暗一级。
    static func recessed(padding: CGFloat = Spacing.md,
                         radius: CGFloat = ObservatoryRadius.control,
                         @ViewBuilder content: () -> Content) -> some View {
        Panel(padding: padding, radius: radius, tone: .recessed, content: content)
    }

    /// 无底容器：只负责内边距与对齐，不引入第二层视觉边界。
    static func plain(padding: CGFloat = Spacing.md,
                      @ViewBuilder content: () -> Content) -> some View {
        Panel(padding: padding, radius: 0, tone: .plain, content: content)
    }

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fillColor, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    /// `.plain` 用 `Color.clear` 占位：只保留内边距与对齐，不引入第二层视觉边界。
    private var fillColor: Color {
        switch tone {
        case .panel:    return Surface.panel
        case .recessed: return Surface.recessed
        case .plain:    return Color.clear
        }
    }
}

// MARK: - 分隔线

/// 1pt 分隔线。**只用于面板内部的行与行之间**；面板之间靠 `Spacing.section` 留白分隔。
struct Hairline: View {
    private let inset: CGFloat
    private let vertical: Bool

    init(inset: CGFloat = 0, vertical: Bool = false) {
        self.inset = inset
        self.vertical = vertical
    }

    var body: some View {
        if vertical {
            Rectangle()
                .fill(Surface.hairline)
                .frame(width: 1)
                .padding(.vertical, inset)
                .accessibilityHidden(true)
        } else {
            Rectangle()
                .fill(Surface.hairline)
                .frame(height: 1)
                .padding(.horizontal, inset)
                .accessibilityHidden(true)
        }
    }
}

// MARK: - 指标网格

/// 定宽等分网格：解决「5 张卡一行、第 6 张孤零零挂在下一行」。
///
/// 用非懒的 `Grid`：指标数量天然有界，懒容器在这里省不到任何东西，
/// 反而会在滚动时反复回收卡片（本仓已因此踩过一次滚动自旋 + RSS 不回落）。
struct MetricGrid<Data, Content>: View where Data: RandomAccessCollection, Data.Element: Identifiable, Content: View {
    private let data: Data
    private let columns: Int
    private let content: (Data.Element) -> Content

    init(_ data: Data, columns: Int = Sizing.metricColumns, @ViewBuilder content: @escaping (Data.Element) -> Content) {
        self.data = data
        self.columns = max(1, columns)
        self.content = content
    }

    var body: some View {
        // 2026-09-23 真机截图改的：四列瓷贴的**理想宽度**约 880pt（单列下限 ~210），
        // 而会话页在 1280 宽的窗口里只剩 ~764（侧栏 216 + 检查器 min 300 先拿走）⇒
        // `Grid` 不会自己换行，于是整页顶着理想宽度溢出，把侧栏与检查器各裁掉一条边。
        // 用 `ViewThatFits` 按**真实可用宽度**退档：放得下请求列数就用它，放不下退到两列。
        // （不留单列档：#83 那道闸禁裸列数，而真实最窄档——1080 窗口开检查器、中栏约 735pt——
        //   两列的理想宽 ~636 已经放得下，单列档没有服务对象。）
        // 宽屏（≥ ~900pt 可用）仍然四列，视觉与今天逐字一致；窄屏换行而不是裁切。
        ViewThatFits(in: .horizontal) {
            grid(columns: columns)
            grid(columns: max(2, columns / 2))
        }
    }

    private func grid(columns: Int) -> some View {
        Grid(alignment: .leading, horizontalSpacing: Sizing.metricGutter, verticalSpacing: Spacing.md) {
            ForEach(Array(rows(for: columns).enumerated()), id: \.offset) { _, row in
                GridRow {
                    ForEach(row.cells) { cell in
                        content(cell.value)
                    }
                    ForEach(row.spacers) { _ in
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                }
            }
        }
    }

    /// 按列数切行，末行用空格补齐，保证列宽在整张表里始终对齐。
    private func rows(for columns: Int) -> [MetricRow<Data.Element>] {
        let all = Array(data)
        var result: [MetricRow<Data.Element>] = []
        var index = 0
        while index < all.count {
            let end = min(index + columns, all.count)
            result.append(MetricRow(Array(all[index..<end]), columns: columns))
            index = end
        }
        return result
    }
}

// 行/格辅助类型必须放在 MetricGrid **外面**：`View` 是 @MainActor 隔离的，
// 写在里面的嵌套类型会连带变成 main-actor 隔离，`.map(Cell.init)` 就会被判
// 「在隔离闭包里捕获非 Sendable 元类型」（40 条 #SendableMetatypes 警告的根因）。

private struct MetricCell<Element: Identifiable>: Identifiable {
    let value: Element
    var id: Element.ID { value.id }
}

private struct MetricSpacer: Identifiable {
    let index: Int
    var id: Int { index }
}

private struct MetricRow<Element: Identifiable> {
    let cells: [MetricCell<Element>]
    let spacers: [MetricSpacer]

    init(_ elements: [Element], columns: Int) {
        // 用 for 循环而不是 `elements.map(MetricCell.init)`：
        // 传泛型类型的 `.init` 会捕获 `Element.Type`，而非 Sendable 类型的元类型
        // 不能进 main-actor 闭包（Swift 6 的 #SendableMetatypes）。
        var built: [MetricCell<Element>] = []
        built.reserveCapacity(elements.count)
        for element in elements {
            built.append(MetricCell(value: element))
        }
        self.cells = built
        self.spacers = (0..<max(0, columns - elements.count)).map { MetricSpacer(index: $0) }
    }
}

#Preview("Panel 三种底色") {
    VStack(alignment: .leading, spacing: Spacing.section) {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                Text("面板 panel").font(.axSection)
                Text("与页面差一级，无描边、无投影、无材质。").font(.axBody).foregroundStyle(Surface.secondaryLabel)
            }
        }
        Panel.recessed {
            Text("下沉区 recessed：面板内的代码块与内嵌列表").font(.axMeta)
        }
        Panel.plain {
            Text("无底 plain：只给内边距，不引入第二层边界").font(.axMeta)
        }
        Hairline()
        Text("Hairline 只出现在面板内部行之间。").font(.axMeta).foregroundStyle(Surface.tertiaryLabel)
    }
    .padding(Spacing.xl)
    .background(Surface.page)
}

#Preview("MetricGrid 列对齐") {
    MetricGrid(DemoMetric.sample, columns: 4) { item in
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(item.title).font(.axLabel).foregroundStyle(Surface.secondaryLabel)
            Text(item.value).font(.axMetric)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    .padding(Spacing.lg)
    .background(Surface.panel)
}

private struct DemoMetric: Identifiable {
    let id: Int
    let title: String
    let value: String

    static let sample: [DemoMetric] = (1...6).map { .init(id: $0, title: "指标 \($0)", value: "\($0 * 12)") }
}
