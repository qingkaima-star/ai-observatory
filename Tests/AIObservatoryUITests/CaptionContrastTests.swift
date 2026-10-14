//
//  CaptionContrastTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/consistency（批 3 · #84 关键说明的对比度）
//  ─────────────────────────────────────────────────────────
//  治的病：**承载「这个数是怎么算出来的」的句子跑在最低对比档。**
//  `StatTile` 的 caption 与 `SectionHeader` 的 subtitle 原先都是 `.axMeta`(11pt)
//  + `Surface.tertiaryLabel`，而首页每一句口径都从这两个控件过
//  （六个 tile、「服务端匹配总数 · 与分页无关」、窗口 caption、占比环那句「为什么不印百分比」）。
//  tertiary 在面板底上的实测对比是 ~1.8:1 —— 小字（11pt）在这种对比下不是"次要"，
//  是"读不到"。可核对性的入口被画成了装饰。
//
//  口径（台账 `整改波次-2026-09-22` 第六节 C / #84）：
//  **承载"这个数怎么来的"的句子不许走低对比档**；纯装饰性次要信息可以留低档。
//
//  为什么把用例长成这三道闸（缺一道都会留活口）：
//  ① **数值闸**：口径层的对比比值在**深浅两套外观**下都必须 ≥ 4.5:1（WCAG 小字门槛），
//     并且严格高于 tertiary / secondary 两档。这一条同时是反向校准——
//     把 `Surface.captionLabel` 改回 `tertiaryLabel` 会当场红，而不是"看起来还行"。
//     两档外观都要量：已知 macOS 26 浅色下 `window/control/text` 三个语义背景色
//     全部解析成纯白（`ObservatoryTokens.swift:26-34`），浅色侧是最坏情况；
//     深色侧则是 `secondaryLabel` **碰巧**能过线的地方——所以"够不够"只能按档比，
//     不能按"这一档以前能用"推断。
//  ② **控件闸**：`StatTile` / `SectionHeader` 这两个共享控件里**一个 `tertiaryLabel` 都不许剩**。
//     只测令牌测不到这个：控件的某个分支被换回低档，令牌值不会变。
//  ③ **接线闸**：不经过这两个控件、自己直接排版口径句的那几处（点名在下面那张表里），
//     每一处的渲染块必须走 `axCaptionStyle()`。只查"文件里出现过 axCaptionStyle"
//     会被"用在别的句子上"骗过去，所以按**那一处 copy 常量的行**切块来查。
//     表里的文件必须还在（反向校准）：改名 = 从名单上消失 = 用例红，而不是静默失去覆盖。
//
//  ⚠️ 这三道闸量不了"人眼上屏那一眼"。实拍判读记在车道回报里
//  （`Tools/UIProbe` 深浅各一遍，图存 `tmp/`，不入库）。
//

import Foundation
import AppKit
import SwiftUI
import Testing
@testable import AIObservatoryUI

@MainActor
@Suite("UI: #84 口径句的对比档（承载信息的句子不许走低对比层）", .timeLimit(.minutes(1)))
struct CaptionContrastTests {

    /// WCAG 2.1 对小字正文的最低对比要求（12pt 属"普通文本"档）。
    private static let minimumRatio = 4.5

    // MARK: ① 数值闸：两档外观都要过线

    @Test("口径层在深浅两套外观下的对比都 ≥ 4.5:1，且严格高于被换掉的两档")
    func captionTierClearsTheBarInBothAppearances() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let caption = ratio(Surface.captionLabel, on: Surface.panel, in: appearance)
            let tertiary = ratio(Surface.tertiaryLabel, on: Surface.panel, in: appearance)
            let secondary = ratio(Surface.secondaryLabel, on: Surface.panel, in: appearance)
            #expect(caption >= Self.minimumRatio,
                    "\(appearance.rawValue) 下口径层只有 \(caption)：承载信息的句子读不到")
            // 反向校准：这一档必须**确实**比它换掉的两档高。
            // 少掉这两句，把 captionLabel 改成 tertiaryLabel 时上面那条也会红，
            // 但"改成 secondaryLabel"这种半退让就只有这里挡得住。
            #expect(caption > tertiary,
                    "\(appearance.rawValue)：口径层与最低档同为 \(caption) ⇒ 换了个名字没换档")
            #expect(caption > secondary,
                    "\(appearance.rawValue)：口径层没有高于次级档（\(caption) vs \(secondary)）")
            // 最低档确实不达标——这条是"为什么这次非改不可"的证据，不是装饰性断言。
            #expect(tertiary < Self.minimumRatio,
                    "\(appearance.rawValue)：tertiary 涨到 \(tertiary) ⇒ 系统语义色变了，本用例的判据要重审")
        }
    }

    @Test("口径层与正文同色、且不是写死的灰值")
    func captionTierIsASemanticColorNotAnInventedGray() throws {
        // 同一个语义色 = 深浅两套自动成立；写死灰值在深色下方向会反（`ObservatoryTokens.swift:31-33`）。
        #expect(Surface.captionLabel == Surface.label)
        let tokens = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/DesignSystem/ObservatoryTokens.swift")
        let line = tokens.split(separator: "\n").first { $0.contains("static let captionLabel") } ?? ""
        #expect(line.contains("nsColor"), "口径层不再是系统语义色：\(line)")
        // 全 DesignSystem 里不许出现自造色值（新加的令牌尤其不许）。
        // 份数下限：按目录扫的门禁必须自己声明分母，否则目录改名之后它扫 0 份还报绿
        // （`HardcodedChineseRatchetTests` 的覆盖面闸管的就是这一族）。
        #expect(try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI/DesignSystem").count >= 20,
                "DesignSystem 目录读不到预期份数 ⇒ 这条闸扫的是空气")
        var offenders: [String] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI/DesignSystem") {
            let code = try BilingualCopyGate.codeOnlyString(
                "Sources/AIObservatoryUI/DesignSystem/\(url.lastPathComponent)")
            for needle in ["Color(red:", "Color(white:", "Color(hue:", "NSColor(white:", "Color(.sRGB"]
            where code.contains(needle) {
                offenders.append("\(url.lastPathComponent) → \(needle)")
            }
        }
        #expect(offenders.isEmpty, "写死的灰值回到了令牌层：\(offenders)")
    }

    // MARK: ② 控件闸：两个共享控件里不留最低档

    @Test("StatTile 与 SectionHeader：口径层走 axCaptionStyle，控件内一个 tertiary 都不剩")
    func sharedControlsHaveNoLowContrastTierLeft() throws {
        for relative in [
            "Sources/AIObservatoryUI/DesignSystem/StatTile.swift",
            "Sources/AIObservatoryUI/DesignSystem/SectionHeader.swift",
        ] {
            let code = try BilingualCopyGate.codeOnlyString(relative)
            #expect(code.contains(".axCaptionStyle()"), "\(relative) 的口径层没接上 axCaptionStyle")
            #expect(!code.contains("tertiaryLabel"),
                    "\(relative) 里还有 \(code.components(separatedBy: "tertiaryLabel").count - 1) 处最低档")
        }
        // 排版阶梯本身也得真的多出一档（只改颜色不改字号 = 与正文完全同档，主次又没了）。
        let tokens = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/DesignSystem/ObservatoryTokens.swift")
        #expect(tokens.contains("static let axCaption: Font = .system(size: 12"))
        #expect(tokens.contains("func axCaptionStyle()"))
    }

    // MARK: ③ 接线闸：自己排口径句的那几处

    /// (文件, 那一处用的 copy 常量)。**名单按名点，不按"整份文件里出现过一次"**——
    /// 后者会被同一文件里别处的 `axCaptionStyle()` 顶掉（本仓在按行切的仪器上栽过三次）。
    private static let directRenderSites: [(file: String, copy: String)] = [
        ("Sources/AIObservatoryUI/Timeline/TimelineEventDetail.swift", "detailZeroCostNote"),
        ("Sources/AIObservatoryUI/Dashboard/DashboardAgentShareReadout.swift", "shareMoreAgents"),
        ("Sources/AIObservatoryUI/Dashboard/DashboardAgentShareReadout.swift", "shareSingleSeriesNote"),
        ("Sources/AIObservatoryUI/Performance/PerformanceSessionBreakdown.swift", "breakdownScopeNote"),
        ("Sources/AIObservatoryUI/Performance/PerformanceSessionBreakdown.swift", "recentRowsNote"),
        ("Sources/AIObservatoryUI/Security/SecurityDetailPanel.swift", "morePathsUnlisted"),
        ("Sources/AIObservatoryUI/Security/SecurityConfirmationSheet.swift", "acknowledgeNote"),
        // #97：异常卡上那两句。`observedExpectedText` 是"实测 vs 期望"——这条异常凭什么成立
        // 就写在那半句里；`anomalyStaleScan` 说的是"上面的读数是旧扫描的结果"，
        // 它决定读者要不要信这一屏。两句都在最低档 ⇒ 可核对性的入口画成了点缀。
        ("Sources/AIObservatoryUI/Dashboard/DashboardAnomalyCard.swift", "observedExpectedText"),
        ("Sources/AIObservatoryUI/Dashboard/DashboardAnomalyCard.swift", "anomalyStaleScan"),
        // 同一张卡的第三处：`trailingNote`「还有 N 条未列全」。前两处是我落的，这一处是
        // 车道 `ws/contrast` 对着 main 逐行比出来的**真增量**（我第一遍只提了两句就收工）。
        ("Sources/AIObservatoryUI/Dashboard/DashboardAnomalyCard.swift", "trailingNote"),
    ]

    @Test("直接排口径句的每一处都走口径层（按那一处的行切块）")
    func directRenderSitesUseTheCaptionTier() throws {
        // 分母自己声明：这张名单是"点名列"，少一条就是少一处覆盖，
        // 而按名切的写法本身不会为"某一处不见了"而红（它只会在**文件**改名时红）。
        #expect(Self.directRenderSites.count >= 10,
                "接线名单只剩 \(Self.directRenderSites.count) 处（本波收口时是 10 处）⇒ 有人悄悄减了覆盖面")
        for site in Self.directRenderSites {
            let lines = try codeLines(site.file)
            guard let index = lines.firstIndex(where: { $0.contains(site.copy) }) else {
                Issue.record("\(site.file) 里找不到 \(site.copy) ⇒ 名单失效，来复核这一处还在不在")
                continue
            }
            // 那一处往后 5 行之内必须挂上口径层（SwiftUI 的修饰符链就在这个长度里）。
            let block = lines[index..<min(lines.count, index + 5)].joined(separator: "\n")
            #expect(block.contains("axCaptionStyle()"),
                    "\(site.file) 的 \(site.copy) 还挂在低对比档上：\n\(block)")
            #expect(!block.contains("tertiaryLabel") && !block.contains("axMetaStyle()"),
                    "\(site.file) 的 \(site.copy) 同块里仍有最低档：\n\(block)")
        }
    }

    @Test("柱图页脚整条走口径层（分桶窗口 / 最忙 / 最近事件）")
    func hourlyFooterRunsOnTheCaptionTier() throws {
        let lines = try codeLines("Sources/AIObservatoryUI/Dashboard/DashboardHourlyActivityChart.swift")
        guard let start = lines.firstIndex(where: { $0.contains("private var footer") }) else {
            Issue.record("柱图没有 footer 了 ⇒ 这一处口径句子跑到哪儿去了？来复核")
            return
        }
        // 页脚到下一个 `private` 成员为止（HStack 的修饰符挂在块尾）。
        let end = lines[(start + 1)...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces)
            .hasPrefix("private ") }) ?? min(lines.count, start + 40)
        let block = lines[start..<end].joined(separator: "\n")
        #expect(block.contains("axCaptionStyle()"), "页脚那条口径没走口径层：\n\(block)")
        #expect(!block.contains("tertiaryLabel"), "页脚里还有一截挂在最低档：\n\(block)")
    }

    @Test("纯装饰的次要信息**没有**被顺手全提上来（口径的另一半）")
    func decorativeMetaStaysOnTheLowerTier() throws {
        // 把每一句都提成口径档 = 所有句子回到同一档 = 主次又没了，
        // 那才是这次整改最容易被做反的方向。行尾时间戳这类留在 `axMeta`：
        let row = try codeLines("Sources/AIObservatoryUI/Timeline/TimelineEventRow.swift")
            .joined(separator: "\n")
        #expect(row.contains("font(.axMetaMono)") || row.contains("font(.axMeta)"),
                "时间线行的行尾元信息被整体提档 ⇒ 这一屏又变成同一档字号")
    }

    // MARK: 尺子

    /// 前景（可能带 alpha）叠在不透明背景上之后的 WCAG 对比比值。
    private func ratio(_ foreground: Color, on background: Color, in name: NSAppearance.Name) -> Double {
        let fg = resolve(foreground, in: name)
        let bg = resolve(background, in: name)
        return contrast(blend(fg, over: bg), bg)
    }

    private func resolve(_ color: Color, in name: NSAppearance.Name) -> NSColor {
        let appearance = NSAppearance(named: name)!
        var out = NSColor(color)
        appearance.performAsCurrentDrawingAppearance {
            // sRGB 而不是 deviceRGB：WCAG 的相对亮度公式定义在 sRGB 上，
            // 全部数值落到同一个色彩空间才不会拿 device 的数去比 sRGB 的公式。
            out = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return out
    }

    /// sRGB 通道上做 alpha 合成（与屏幕上量到的近似一致：文本半透明压在面板底上）。
    private func blend(_ fg: NSColor, over bg: NSColor) -> NSColor {
        let a = max(0, min(1, fg.alphaComponent))
        return NSColor(
            srgbRed: fg.redComponent * a + bg.redComponent * (1 - a),
            green: fg.greenComponent * a + bg.greenComponent * (1 - a),
            blue: fg.blueComponent * a + bg.blueComponent * (1 - a),
            alpha: 1
        )
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        let high = max(la, lb)
        let low = min(la, lb)
        return (high + 0.05) / (low + 0.05)
    }

    private func luminance(_ color: NSColor) -> Double {
        func channel(_ raw: CGFloat) -> Double {
            let v = Double(raw)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
    }

    /// 一份文件的**代码行**（整行注释与「空格+//」之后的行文都不算）。
    private func codeLines(_ relative: String) throws -> [String] {
        try BilingualCopyGate.codeOnlyString(relative).split(separator: "\n").map(String.init)
    }
}
