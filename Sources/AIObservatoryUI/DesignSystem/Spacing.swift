//
//  Spacing.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent A)
//  全局 8pt 间距刻度：所有布局 padding / spacing 只能引用这里，禁止魔法数字。
//

import SwiftUI

enum Spacing {
    static let none: CGFloat = 0
    /// 仅允许用于「图标与紧邻文字」
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 16
    /// 面板内边距。
    static let lg: CGFloat = 24
    /// 页面左右安全边距。
    static let xl: CGFloat = 32
    /// 板块之间的垂直留白——「无界」靠它分隔，不靠线也不靠阴影。
    static let section: CGFloat = 32
    /// 仅用于页面级留白
    static let xxl: CGFloat = 48
}

#Preview("Spacing 参考") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        ForEach([(Spacing.xs, "xs 4"), (Spacing.sm, "sm 8"), (Spacing.md, "md 16"),
                 (Spacing.lg, "lg 24"), (Spacing.xl, "xl 32"), (Spacing.xxl, "xxl 48")], id: \.1) { pair in
            HStack(spacing: Spacing.sm) {
                Text(pair.1).font(.caption).frame(width: 64, alignment: .leading)
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(width: pair.0 * 4, height: 8)
            }
        }
    }
    .padding(Spacing.lg)
}
