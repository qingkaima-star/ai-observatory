//
//  SectionHeader.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  面板/小节标题：13pt 半粗 + 可选说明 + 右侧操作区。
//
//  【#84 · 2026-09-22】subtitle 与 `StatTile` 的 caption 是同一类句子
//  （「这一节按什么口径数」），原先同样跑 11pt + `Surface.tertiaryLabel`（实测 ≈1.8:1）。
//  现在两处一起走口径层 `axCaptionStyle()`；判据写在 `ObservatoryTokens.swift`
//  的 `Surface.captionLabel` 上，反向校准用例在 `CaptionContrastTests`。
//
//  旧版每个小节标题前挂一个 `.headline` 大小的 SF 图标，全应用 55 处——
//  图标在这里不携带任何信息（标题已经写了「风险事件」），只是把每一节的视觉重量抬到
//  和页面标题同一档，于是「没有主次」。图标参数已删除。
//

import SwiftUI

struct SectionHeader<Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing

    /// #89：副标题这一格被**每一页**用来放"这一组是什么"，而错误面板那句
    /// （`ProjectsView` / `FilesView` 的 `errorPanel`）就是把 `error.localizedDescription`
    /// 原样递进来的——本仓的存储错误里带着库文件的绝对路径。
    /// 掩在这里 ⇒ 调用方不需要记得包；调用方**已经**包过的也不冲突（`scrub` 对占位符恒等）。
    @Environment(\.demoRedaction) private var demoRedaction

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(demoRedaction.scrub(title))
                    .font(.axSection)
                    .foregroundStyle(Surface.label)
                    .textCase(nil)
                if let subtitle {
                    Text(demoRedaction.scrub(subtitle))
                        .fixedSize(horizontal: false, vertical: true)
                        .axCaptionStyle()
                }
            }
            Spacer(minLength: Spacing.sm)
            if Trailing.self != EmptyView.self {
                trailing
            }
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("SectionHeader 变体") {
    VStack(alignment: .leading, spacing: Spacing.lg) {
        SectionHeader("今日活动", subtitle: "按小时聚合的事件密度")
        SectionHeader("风险事件") {
            Button("查看全部") {}
                .controlSize(.small)
        }
        SectionHeader("纯标题")
    }
    .padding(Spacing.lg)
    .background(Surface.panel)
}
