//
//  RiskLevelDistinguishabilityTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-QuietUI
//  ─────────────────────────────────────────────────────────
//  钉住「风险四级压成三档色」这条决策所依赖的前提：**共用颜色的两个等级，
//  文字必须能单独把它们分开**（ADR-0008 §2 的原话是「等级名始终跟着一起显示」）。
//
//  ⚠️ 本文件钉的是令牌层与契约层的通道冗余，它**不**能证明某个行视图真的把等级名画了出来
//     （本仓 UI 测试只测纯展示函数，没有视图宿主）。视图侧那一条落在
//     `Security/RiskEventRow.swift` 的无条件 `RiskBadge` 上，改动那里请连带复核本决策。
//

import Foundation
import Testing
import SwiftUI
@testable import AIObservatoryUI
import AIObservatoryCore

@Suite("UI：风险等级的颜色冗余", .timeLimit(.minutes(1)))
struct RiskLevelDistinguishabilityTests {

    @Test("medium 与 high 确实共用橙色——所以文字是它们唯一的区分通道")
    func mediumAndHighShareOneTone() {
        #expect(ObservatoryTheme.tone(for: .medium) == .caution)
        #expect(ObservatoryTheme.tone(for: .high) == .caution)
        #expect(ObservatoryTheme.color(for: .medium) == Color.orange)
        #expect(ObservatoryTheme.color(for: .high) == Color.orange)
    }

    @Test("同色的等级：等级名必须互不相同且非空，否则合色就让它们不可读")
    func sameToneLevelsHaveDistinctNames() {
        let levels = RiskLevel.allCases
        for a in levels {
            #expect(!a.displayName.isEmpty, "\(a) 没有可用的等级名")
            for b in levels where a != b {
                let sharesTone = ObservatoryTheme.tone(for: a) == ObservatoryTheme.tone(for: b)
                if sharesTone {
                    #expect(a.displayName != b.displayName,
                            "\(a) 与 \(b) 同色同名：只剩颜色一个通道，无法区分")
                }
            }
        }
    }

    @Test("等级名逐字钉住（契约 DomainModels.swift:834-837 的四个英文字面量）")
    func displayNamesArePinned() {
        #expect(RiskLevel.low.displayName == "LOW")
        #expect(RiskLevel.medium.displayName == "MEDIUM")
        #expect(RiskLevel.high.displayName == "HIGH")
        #expect(RiskLevel.critical.displayName == "CRITICAL")
    }

    @Test("三档色的分档本身：low 中性、critical 独立、只有 medium/high 并档")
    func toneBuckets() {
        #expect(ObservatoryTheme.tone(for: .low) == .neutral)
        #expect(ObservatoryTheme.tone(for: .critical) == .critical)
        #expect(ObservatoryTheme.tone(for: .low) != ObservatoryTheme.tone(for: .medium))
        #expect(ObservatoryTheme.tone(for: .high) != ObservatoryTheme.tone(for: .critical))
    }

    /// `color(for:)` 与 `tone(for:)` 是同一个判断的两处出口；漂移会让「直接染字」的视图
    /// 与走 `Tag`/`RiskBadge` 的视图对同一等级给出不同颜色。
    @Test("两个出口不得漂移：color(for:) 必须等于 tone(for:) 所指向的色")
    func colorAndToneAgree() {
        for level in RiskLevel.allCases {
            #expect(ObservatoryTheme.color(for: level) == ObservatoryTheme.tone(for: level).color,
                    "\(level)：color(for:) 与 tone(for:) 给出了不同的色")
        }
    }
}
