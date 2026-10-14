//
//  RiskBadge.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  风险等级标签：`Tag` 的风险语义封装（色点 + 等级名），不再画胶囊。
//

import SwiftUI
import AIObservatoryCore

struct RiskBadge: View {
    private let level: RiskLevel
    private let showsDot: Bool
    private let prominent: Bool

    init(_ level: RiskLevel, showsDot: Bool = true, prominent: Bool = false) {
        self.level = level
        self.showsDot = showsDot
        self.prominent = prominent
    }

    var body: some View {
        Tag(level.displayName, tone: ObservatoryTheme.tone(for: level),
            showsDot: showsDot, prominent: prominent)
            .accessibilityLabel("风险等级 \(level.displayName)")
    }
}

#Preview("RiskBadge 常态与强调") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.md) {
            ForEach(RiskLevel.allCases) { RiskBadge($0) }
        }
        HStack(spacing: Spacing.md) {
            ForEach(RiskLevel.allCases) { RiskBadge($0, prominent: true) }
        }
    }
    .padding(Spacing.lg)
}
