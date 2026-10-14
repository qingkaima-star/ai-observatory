//
//  EmptyStateView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  统一空状态：小图标 + 标题 + 说明 + 可选操作，避免任何板块出现白屏。
//
//  旧版用 40pt 大图标居中铺满整页，空页比有数据的页更抢眼。现在图标退到 20pt 三级色，
//  并且区分两种占位：整页空（`fills: true`，垂直居中）与面板内空（`fills: false`，紧凑）。
//

import SwiftUI

struct EmptyStateView<Action: View>: View {
    private let title: String
    private let systemImage: String
    private let message: String
    private let fills: Bool
    private let action: Action

    /// #89：空态与错误面板这两类话术里有真实路径（`error.localizedDescription` 在本仓会把
    /// 库文件路径拼进句子：`AIObservatoryStore/SQLiteDatabase.swift:236/759`、
    /// `AIObservatorySwiftDataStore/StoreSelection.swift:160`），而这一格被九个页面复用。
    /// 掩在组件里：调用方递进来的就是"给人读的那一份"，不该要求每一页记得自己包一层。
    @Environment(\.demoRedaction) private var demoRedaction

    init(_ title: String,
         systemImage: String,
         message: String = "",
         fills: Bool = true,
         @ViewBuilder action: () -> Action = { EmptyView() }) {
        self.title = title
        self.systemImage = systemImage
        self.message = message
        self.fills = fills
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Spacing.sm) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Surface.tertiaryLabel)
            Text(demoRedaction.scrub(title))
                .font(.axSection)
                .foregroundStyle(Surface.label)
                .multilineTextAlignment(.center)
            if !message.isEmpty {
                Text(demoRedaction.scrub(message))
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if Action.self != EmptyView.self {
                action
                    .controlSize(.small)
                    .padding(.top, Spacing.xs)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(maxHeight: fills ? .infinity : nil)
        .padding(fills ? Spacing.xl : Spacing.md)
        .accessibilityElement(children: .combine)
    }
}

#Preview("EmptyStateView") {
    VStack(spacing: Spacing.lg) {
        EmptyStateView("今天还没有观测到任何活动",
                       systemImage: "sparkles",
                       message: "引擎正在监听中。当有 AI Agent 发起文件改动或执行命令时，事件会实时出现在这里。")
            .frame(height: 260)
            .background(Surface.panel)
        EmptyStateView("没有匹配的风险事件",
                       systemImage: "shield.lefthalf.filled",
                       message: "试着放宽时间范围或取消等级过滤。",
                       fills: false)
            .background(Surface.panel)
    }
    .padding(Spacing.xl)
    .background(Surface.page)
}
