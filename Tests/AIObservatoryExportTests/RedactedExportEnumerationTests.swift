//
//  RedactedExportEnumerationTests.swift
//  AIObservatoryExportTests
//
//  Owner: WS-finisher（#64 演示脉敏 · 导出面）
//  ─────────────────────────────────────────────────────────
//  设置页那句 caveat 已经写了「屏上路径列**与导出报告**」都换成 `~` / `<project>`。
//  今天导出侧一个字都没接——那句话就是 ADR-0006 那个病：文案承诺了，消费者不在。
//  这一支把「整件导出产物」枚举出来验，而不是挑几列看：
//   ① Markdown 报告**整篇**不含合成家目录；
//   ② 五种 kind 的**每一列 × 每一条记录**过一遍脱敏器，逐格枚举；
//   ③ 反向自证：同一份夹具在**没开映射**时确实带着 `/Users/dev`——
//      否则 ①② 的"没含"可能只是夹具里压根没这条路径（那是假绿）。
//
//  ⚠️ 夹具用 `ReportFixtures`（与逐字断言那一批同一份），路径来自
//  `FixturePaths`（`/Users/dev/…`），不写本机家目录。
//

import Testing
import Foundation
@testable import AIObservatoryExport
@testable import AIObservatoryCore
import AIObservatoryTestSupport

@Suite("Export: #64 导出件的整页枚举（映射开启后整件产物不含家目录）")
struct RedactedExportEnumerationTests {

    private static let home = FixturePaths.home
    private static let root = FixturePaths.projectRoot
    private static let mask = PathPrivacy.Mask(home: home, projectRoots: [root])

    private static let kinds: [ExportKind] = [
        .sessions, .timeline, .fileChanges, .commands, .riskEvents,
    ]

    @Test("Markdown 报告整篇：开启后不含合成家目录，且占位符真的出现了")
    func wholeReportHidesTheHome() throws {
        let input = ReportFixtures.richInput
        let masked = try MarkdownReportExporter.report(input: input,
                                                       redactor: .standard(pathMask: Self.mask))
        #expect(!masked.contains(Self.home), "导出报告里还留着 \(Self.home)：\n\(masked)")
        #expect(masked.contains(PathPrivacy.Mask.homePlaceholder)
                    || masked.contains(PathPrivacy.Mask.projectPlaceholder),
                "整篇里没有任一占位符 ⇒ 映射根本没作用到导出件（那 ① 是空转）")

        // 反向自证：同一份输入、同一套代码，不传映射时家目录必须在。
        let plain = try MarkdownReportExporter.report(input: input)
        #expect(plain.contains(Self.home),
                "夹具里根本没有 \(Self.home) ⇒ 上面那条断言没有对象，是假绿")
    }

    @Test("逐格枚举：五种 kind 的每一列 × 每一条记录，开启后都不含合成家目录")
    func everyColumnOfEveryRecordIsMasked() throws {
        let records = ReportFixtures.richInput.records
        let on = ExportRedactor.standard(pathMask: Self.mask)
        let off = ExportRedactor.standard
        var checked = 0
        var hitsWhenOff = 0

        for kind in Self.kinds {
            let scoped = records.filter { $0.kind == kind }
            guard !scoped.isEmpty else { continue }
            let columns = try ExportSchema.columns(for: kind)
            for record in scoped {
                for column in columns {
                    checked += 1
                    let shown = on.redact(column.value(record))
                    #expect(!shown.contains(Self.home),
                            "\(kind)/\(column.name) 开着映射仍带家目录：\(shown)")
                    if off.redact(column.value(record)).contains(Self.home) { hitsWhenOff += 1 }
                }
            }
        }
        // 分母守卫：扫了几格、其中几格本来带路径——两个数都要非零，否则这条闸是空转的。
        #expect(checked > 50, "只枚举到 \(checked) 格 ⇒ 夹具或列清单没吃到，这条闸没有分母")
        #expect(hitsWhenOff > 0,
                "关掉映射时没有任何一格带 \(Self.home) ⇒ 上面那条『开启后不含』是假绿")
    }

    @Test("③ 不脱敏不许静默：报告页脚两态都要写出路径状态")
    func footerStatesThePathRedactionBothWays() throws {
        let input = ReportFixtures.richInput
        let masked = try MarkdownReportExporter.report(
            input: input, redactor: .standard(pathMask: Self.mask))
        let raw = try MarkdownReportExporter.report(input: input)   // 默认 = 不映射
        #expect(masked.contains("路径已按演示输出脱敏") || masked.contains("paths masked"),
                "开启时页脚没写路径状态：拿这份文件的人无从判断")
        #expect(raw.contains("路径未脱敏") || raw.contains("paths NOT masked"),
                "关掉时页脚静默 ⇒ 一份满是原始绝对路径的报告看起来像处理过了")
        // 两态必须**不同**：同一条文案就是没在报状态。
        #expect(masked != raw, "两态页脚逐字相同 ⇒ 那行状态是装饰")
    }

    @Test("凭据脱敏关掉时不许偷偷换路径（`redactionEnabled` 是唯一开关）")
    func pathMaskFollowsTheRedactionSwitch() throws {
        let request = ExportRequest(format: .markdown, kinds: [.report],
                                    generatedAt: ReportFixtures.generatedAt,
                                    redactionEnabled: false, pathMask: Self.mask,
                                    destination: ExportDestination(
                                        directory: ReportFixtures.scratchBase,
                                        allowedRoots: [ReportFixtures.scratchRoot]))
        #expect(request.redactor.redact("\(Self.home)/secrets.txt") == "\(Self.home)/secrets.txt",
                "用户显式要原始件时偷偷换掉了路径 ⇒ 那是替他做他没同意的决定")
    }
}
