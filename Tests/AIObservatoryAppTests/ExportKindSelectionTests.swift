//
//  ExportKindSelectionTests.swift
//  AIObservatoryApp
//
//  Owner: 总控（组合根 / 导出入口）
//  ─────────────────────────────────────────────────────────
//  钉住「界面挑的 kind」与「导出层认的 kind」必须一致。
//  这条用例存在的原因是主入口真塌过一次：`ObservatoryExporting.kinds(for:)` 无条件
//  返回 5 个只支持 JSON/CSV 的记录 kind，而菜单 ⌘⇧E 用默认 `.markdown`，
//  于是 `ExportRequest.validate()` 第一个组合就抛 `unsupportedCombination`
//  —— 用户按「导出 AI 活动记录」得到的是"导出失败"弹框 + 空目录。
//  两侧各自单看都是绿的，只有"界面挑出来的 kinds 拿去建 ExportRequest"这一步能抓到。
//

import Foundation
import Testing
@testable import AIObservatoryApp
import AIObservatoryCore
import AIObservatoryExport
import AIObservatoryTestSupport

@Suite("App: 导出入口的格式 ↔ kind 映射", .timeLimit(.minutes(1)))
struct ExportKindSelectionTests {

    private static func request(
        _ format: ActivityExportRequest.Format
    ) -> ExportRequest {
        let directory = URL(fileURLWithPath: Scratch.path("export-kind-selection"), isDirectory: true)
        return ExportRequest(
            format: ObservatoryExporting.exportFormat(for: format),
            kinds: ObservatoryExporting.kinds(for: format),
            dateRange: .unbounded,
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            redactionEnabled: true,
            destination: ExportDestination(directory: directory, allowedRoots: [directory])
        )
    }

    @Test("三种格式各自挑出来的 kinds 都能通过导出层校验（主入口不再必失败）")
    func selectedKindsPassValidation() {
        for format in [ActivityExportRequest.Format.markdown, .json, .csv] {
            #expect(throws: Never.self) {
                try Self.request(format).validate()
            }
        }
    }

    @Test("Markdown 只导叙述报告这一个 kind（不是 6 个混在一起）")
    func markdownSelectsReportOnly() {
        // 手推字面量：`.report.supportedFormats == [.markdown]`，其余 5 个都不含 markdown。
        #expect(ObservatoryExporting.kinds(for: .markdown) == [.report])
    }

    @Test("JSON / CSV 导五个记录 kind，且不含只有 Markdown 支持的 .report")
    func recordFormatsSelectFiveRecordKinds() {
        let expected: [ExportKind] = [.sessions, .timeline, .fileChanges, .commands, .riskEvents]
        #expect(ObservatoryExporting.kinds(for: .json) == expected)
        #expect(ObservatoryExporting.kinds(for: .csv) == expected)
    }

    @Test("任何格式都不许挑出空 kinds（空 kinds 会被 validate 直接拒）")
    func neverEmpty() {
        for format in [ActivityExportRequest.Format.markdown, .json, .csv] {
            #expect(
                !ObservatoryExporting.kinds(for: format).isEmpty,
                "\(format.rawValue) 挑出了空 kinds ⇒ 校验会在『kinds 不能为空』上抛错"
            )
        }
    }
}
