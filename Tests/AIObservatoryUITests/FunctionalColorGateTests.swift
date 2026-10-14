//
//  FunctionalColorGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · P2 两套颜色口径）
//  ─────────────────────────────────────────────────────────
//  `AnalysisPresentation.verdictTint` 原来自带一套 `.green/.yellow/.red/.gray`，
//  与 `ObservatoryTheme` 的功能色并存 ⇒ 同一屏上「需关注」的橙和「中风险」的橙
//  不是同一个出处，而 `.yellow` / `.gray` 压根不在 `ObservatoryColor` 那五档里。
//
//  现在收成一处。三条闸：
//    ① 健康四档的色 = 手推字面量；
//    ② **全仓**除 `ObservatoryTheme.swift` 之外不许再出现裸系统色（这条才是治本的——
//       它拦的是"下一次再自造一套"，不是这一次改完的值）；
//    ③ 与 `RiskLevelDistinguishabilityTests` 同一个前提：共用颜色的两档，
//       文字必须能单独分开它们（ADR-0008：颜色只回答「要不要现在处理」）。
//

import Foundation
import SwiftUI
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

@MainActor
@Suite("UI: 功能色只有一个出处", .timeLimit(.minutes(1)))
struct FunctionalColorGateTests {

    private func snapshot(_ verdict: ProjectHealthSnapshot.Verdict) -> ProjectHealthState {
        .resolved(ProjectHealthSnapshot(
            projectPath: "/Users/demo/Projects/Mona",
            riskCounts: .none,
            anomalyCount: 0,
            efficiencyScore: nil,
            verdict: verdict,
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ))
    }

    // MARK: ① 健康四档

    @Test("健康结论四档 = 手推字面量（watch 从黄改成与风险同源的橙）")
    func verdictColorsArePinned() {
        #expect(ObservatoryTheme.color(for: ProjectHealthSnapshot.Verdict.healthy) == Color.green)
        #expect(ObservatoryTheme.color(for: ProjectHealthSnapshot.Verdict.watch) == Color.orange)
        #expect(ObservatoryTheme.color(for: ProjectHealthSnapshot.Verdict.atRisk) == Color.red)
        #expect(ObservatoryTheme.color(for: ProjectHealthSnapshot.Verdict.insufficientData)
            == Surface.secondaryLabel)
        // 「数据不足」绝不能落绿：它是「没查出来」，不是「查过没事」。
        #expect(ObservatoryTheme.color(for: ProjectHealthSnapshot.Verdict.insufficientData)
            != ObservatoryTheme.color(for: ProjectHealthSnapshot.Verdict.healthy))
    }

    @Test("verdictTint 只是转发令牌层，不再自带第二套色")
    func tintDelegatesToTheTheme() {
        for verdict in ProjectHealthSnapshot.Verdict.allCases {
            #expect(AnalysisPresentation.verdictTint(snapshot(verdict))
                == ObservatoryTheme.color(for: verdict))
        }
        // 三种「没有结论」的状态一律中性，且与数据不足同档（都不该暗示任何健康度）。
        let neutral = ObservatoryColor.neutral
        #expect(AnalysisPresentation.verdictTint(.notWired) == neutral)
        #expect(AnalysisPresentation.verdictTint(.unavailable) == neutral)
        #expect(AnalysisPresentation.verdictTint(.failed("x")) == neutral)
    }

    @Test("「需关注」的橙与「中风险」的橙是同一个常量（两把尺的原始形状）")
    func watchSharesTheRiskOrange() {
        #expect(AnalysisPresentation.verdictTint(snapshot(.watch))
            == ObservatoryTheme.color(for: RiskLevel.medium))
        #expect(AnalysisPresentation.verdictTint(snapshot(.atRisk))
            == ObservatoryTheme.color(for: RiskLevel.critical))
    }

    // MARK: ③ 共色必须有文字冗余

    @Test("共用颜色的结论档，结论名必须互不相同（颜色不是唯一通道）")
    func sharedColorVerdictsAreNamedApart() {
        let verdicts = ProjectHealthSnapshot.Verdict.allCases
        for a in verdicts {
            #expect(!a.displayName.isEmpty, "\(a) 没有可用的结论名")
            for b in verdicts where a != b {
                if ObservatoryTheme.color(for: a) == ObservatoryTheme.color(for: b) {
                    #expect(a.displayName != b.displayName,
                            "\(a) 与 \(b) 同色同名：只剩颜色一个通道")
                }
            }
        }
    }

    // MARK: ② 全仓唯一出处

    @Test("除 ObservatoryTheme.swift 外，UI 里不许出现裸系统色")
    func systemColorsAreOnlyUsedInTheTheme() throws {
        let root = try repoRoot()
        let ui = root.appending(path: "Sources/AIObservatoryUI")
        guard let enumerator = FileManager.default.enumerator(
            at: ui,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        let paletteNames = ["green", "yellow", "red", "gray", "grey", "orange", "blue", "purple", "pink"]
        var offenders: [String] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "swift" else { continue }
            // 令牌层自己就是那五档的定义处，允许（也仅允许）在这里出现 `Color.red` 这种写法。
            if file.lastPathComponent == "ObservatoryTheme.swift" { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, raw) in text.split(separator: "\n").enumerated() {
                // 「 // 」之后是行文，不是代码（整行注释同上，一并跳掉）。
                // 用「空格+//」而不是「//」来切，免得把 "https://…" 这类字面量切坏。
                let body = raw.components(separatedBy: " //").first ?? ""
                let line = body.trimmingCharacters(in: .whitespaces)
                if line.hasPrefix("//") || line.hasPrefix("*") { continue }
                guard let hit = paletteNames.first(where: { name in
                    // 命中 `.red` / `Color.red` / `.foregroundStyle(.green)` 这类**取色**写法；
                    // `.greenish` 那种后面还跟着字母的不算（本仓没有，但别给它留误报）。
                    guard let dot = line.range(of: ".\(name)") else { return false }
                    let tail = line[dot.upperBound...]
                    return tail.isEmpty || !(tail.first!.isLetter || tail.first!.isNumber)
                }) else { continue }
                offenders.append("\(file.lastPathComponent):\(index + 1) .\(hit)")
            }
        }
        #expect(offenders.isEmpty, "第二套功能色：\(offenders)")
    }

    /// 色只染图标不足以自证——结论名必须与它一起上屏（ADR-0008 的「始终跟着显示」）。
    @Test("健康卡片在着色的符号旁边确实写着结论名")
    func tintedSymbolIsNeverTheOnlyChannel() throws {
        let card = try source("Sources/AIObservatoryUI/Projects/ProjectHealthCard.swift")
        let squeezed = card.split(whereSeparator: \.isWhitespace).joined()
        #expect(squeezed.contains("AnalysisPresentation.verdictTint(state)"))
        #expect(squeezed.contains("AnalysisPresentation.healthTitle(state)"),
                "结论名没上屏 ⇒ 颜色成了唯一通道")
    }

    // MARK: 路径

    private enum ColorGateError: Error { case noRepoRoot }

    private func repoRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) else {
            throw ColorGateError.noRepoRoot
        }
        return url
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: try repoRoot().appending(path: relative), encoding: .utf8)
    }
}
