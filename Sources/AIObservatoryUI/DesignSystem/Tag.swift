//
//  Tag.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  状态标签的统一画法：**色点 + 文字**，无底色、无描边。
//
//  旧版 `RiskBadge` 与 `AgentChip` 各自画了一个带 8% 填充 + 35% 描边的胶囊，
//  一屏出现十几个这样的胶囊时，界面就被切成了一堆按钮——这是「拥挤」的直接来源。
//  色点保留了「一眼扫到异常」的能力，胶囊壳子去掉后行高与视线噪声都下来了。
//

import SwiftUI

/// 标签色调。只有五档，与 `ObservatoryColor` 一一对应。
enum TagTone: Sendable {
    case neutral
    case accent
    case positive
    case caution
    case critical

    var color: Color {
        switch self {
        case .neutral:  return Surface.secondaryLabel
        case .accent:   return ObservatoryColor.accent
        case .positive: return ObservatoryColor.positive
        case .caution:  return ObservatoryColor.caution
        case .critical: return ObservatoryColor.critical
        }
    }
}

/// 色点 + 文字的状态标签。
struct Tag: View {
    private let text: String
    private let tone: TagTone
    private let showsDot: Bool
    private let prominent: Bool

    init(_ text: String, tone: TagTone = .neutral, showsDot: Bool = true, prominent: Bool = false) {
        self.text = text
        self.tone = tone
        self.showsDot = showsDot
        self.prominent = prominent
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            if showsDot {
                Circle()
                    .fill(tone.color)
                    .frame(width: 5, height: 5)
                    .accessibilityHidden(true)
            }
            Text(text)
                .font(prominent ? .axSection : .axMeta)
                .foregroundStyle(prominent ? tone.color : Surface.label)
                .lineLimit(1)
                .textCase(nil)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview("Tag 五档") {
    HStack(spacing: Spacing.lg) {
        Tag("中性")
        Tag("强调", tone: .accent)
        Tag("正常", tone: .positive)
        Tag("留意", tone: .caution)
        Tag("危险", tone: .critical)
    }
    .padding(Spacing.lg)
}
