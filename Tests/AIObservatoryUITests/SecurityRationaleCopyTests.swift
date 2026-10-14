//
//  SecurityRationaleCopyTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · #49）
//  ─────────────────────────────────────────────────────────
//  #49 要的是「这条为什么被判成 HIGH / 需确认」在屏上读得到。
//  复核结论先摆着：**依据句本身早就上屏了**——规则侧 `RiskRuleIdentity.rationale(filling:)`
//  渲染成整句写进 `RiskEvent.detail`，详情面板与确认面板都画它（真机图为证，见交付块）。
//  本车道真正能收的是那一层的**三个分叉名**：同一节内容在两个面板一个叫「判定依据」、
//  一个叫「事件详情」；规则号一处叫「命中规则」一处叫「规则」；空态句两份字面量。
//  确认面板是按下「我已确认」之前最后读的一屏（需求⑧），换一套词就等于让用户怀疑
//  自己看的是另一块信息。
//
//  ⚠️ 本文件能证明与不能证明的（照 `RiskLevelDistinguishabilityTests` 的规矩写清楚）：
//  能证明——两个面板读的是同一个常量、且读的是契约字段 `event.detail`；
//  不能证明——规则真的把句子写进了 `detail`。那是 `AIObservatoryRiskRules` 侧的事，
//  而 UI 测试目标的依赖闭包里**没有**那个模块（只有 UI + Core + TestSupport），
//  在这里 import 它是编不过的。那一条由**真机旁证**负责：
//  `tmp/uicopy-probe/risk-detail.png` 上「判定依据」那一节读到的整句
//  「内存峰值 9.33 GB 超过阈值 2.00 GB（…） (confidence 85%)」就是规则渲染出来的，
//  并且同一句在库里的 `risk_events.detail` 里能查到（两侧同源，不是界面自己写的）。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

@Suite("UI: 风险判定依据的措辞与接线（#49）", .timeLimit(.minutes(1)))
struct SecurityRationaleCopyTests {

    // MARK: 措辞本身

    @Test("三个标签 = 手推字面量")
    func copyIsPinned() {
        #expect(SecurityCopy.rationaleTitle.text(.chineseSimplified) == "判定依据")
        #expect(SecurityCopy.matchedRuleTitle.text(.chineseSimplified) == "命中规则")
        #expect(SecurityCopy.missingRationale.text(.chineseSimplified) == "规则未提供额外说明。")
    }

    @Test("空 detail 给空态；非空 detail **原样**透出，界面不加一句自己的解释")
    func rationalePassesThroughUnchanged() {
        #expect(SecurityCopy.rationale("") == "规则未提供额外说明。")
        #expect(SecurityCopy.rationale("   ") == "规则未提供额外说明。")
        let sentence = "内存峰值 9.33 GB 超过阈值 2.00 GB（来自性能采样）。 (confidence 85%)"
        #expect(SecurityCopy.rationale(sentence) == sentence)
        // 界面不许把规则的句子和自造的理由混排（那正是 #49 要避免的那类谎）。
        #expect(!SecurityCopy.rationale(sentence).contains("可能"))
    }

    // MARK: 接线

    @Test("两个面板都读同一套常量，且都画契约字段 `event.detail`")
    func bothSurfacesShareTheCopyAndTheField() throws {
        let sheet = try codeOnly("Sources/AIObservatoryUI/Security/SecurityConfirmationSheet.swift")
        let panel = try codeOnly("Sources/AIObservatoryUI/Security/SecurityDetailPanel.swift")
        for (name, text) in [("确认面板", sheet), ("详情面板", panel)] {
            #expect(text.contains("SecurityCopy.rationaleTitle"), "\(name) 没共用节标题")
            #expect(text.contains("SecurityCopy.rationale("), "\(name) 没共用依据正文")
            #expect(text.contains("SecurityCopy.matchedRuleTitle"), "\(name) 没共用规则号标签")
            #expect(text.contains("event.detail"), "\(name) 不再画 RiskEvent.detail")
        }
        // 分叉名不许回来。
        #expect(!sheet.contains("事件详情"), "确认面板又叫回「事件详情」了")
        #expect(!sheet.contains("InlineStat(\"规则\""), "确认面板的规则号标签又叫回「规则」")
        // 空态句只许有一份字面量（在 SecurityCopy 里）。
        #expect(!sheet.contains("\"规则未提供额外说明。\""), "确认面板又自带一份空态字面量")
        #expect(!panel.contains("\"规则未提供额外说明。\""), "详情面板又自带一份空态字面量")
    }

    @Test("确认路径上依据句不许被摘掉（需求⑧：确认之前必须读得到）")
    func confirmationSheetStillShowsTheRationale() throws {
        // 这一格是 #49 的落点本体：确认按钮与依据句必须在同一个视图里，
        // 否则用户就回到「对着一个徽标按按钮」。
        let sheet = try source("Sources/AIObservatoryUI/Security/SecurityConfirmationSheet.swift")
        // #64 把锚点从 `SecurityCopy.rationale(event.detail)` 收成 `SecurityCopy.rationale(`：
        // 原来那一版把**实参的拼法**一起钉死了，而 #64 正是来改实参的（依据句里就是绝对路径，
        // 必须过映射）。这里要钉的是"确认面板里有共用依据句、且排在确认按钮之前"，
        // 不是"括号里一个字符都不许变"。同一文件 `bothSurfacesShareTheCopyAndTheField`
        // 仍然逐字要求 `event.detail` 出现在这一页 ⇒ 换成别的字段照样红。
        let rationale = sheet.range(of: "SecurityCopy.rationale(")
        let confirm = sheet.range(of: "我已确认")
        #expect(rationale != nil, "确认面板里没有依据句了")
        #expect(confirm != nil, "确认按钮不见了")
        if let rationale, let confirm {
            #expect(rationale.lowerBound < confirm.lowerBound, "依据句排到确认按钮之后了")
        }
    }

    // MARK: 工具

    private enum RationaleError: Error { case noRepoRoot }

    private static func repoRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) else {
            throw RationaleError.noRepoRoot
        }
        return url
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: try Self.repoRoot().appending(path: relative), encoding: .utf8)
    }

    /// 只看代码行：解释「原来分叉成什么样」的注释里就带着那些被禁的词。
    private func codeOnly(_ relative: String) throws -> String {
        try source(relative).split(separator: "\n")
            .map { line in String(line.components(separatedBy: " //").first ?? "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
