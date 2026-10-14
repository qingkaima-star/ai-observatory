//
//  BilingualCopyGateRulerTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  量那把尺子本身。起因是一次**变异测试**：我往 `DashboardView.swift` 末尾
//  （预览块**之后**）塞了一行 `private let 探针 = "写死中文"`，B3 的门禁②全绿。
//  当时的规则是"遇到第一个预览标记就判到文件尾"，而本仓的文件尾部正是
//  `private extension …`、helper 往后长的地方 ⇒ 那条规则等于给每个文件的尾巴开了后门，
//  而"界面在说谎"是这个项目的主要缺陷类别。改成按大括号配对只跳预览块本身之后，
//  同一枚探针当场变红（当场录在这里，不靠下次再想起来做变异）。
//
//  这里喂的是**内存里的源码片段**，不碰磁盘：尺子的行为不该取决于一真实文件长什么样。
//

import Foundation
import Testing
@testable import AIObservatoryUI

@Suite("UI: 双语门禁的扫描尺子自测（预览块只跳块本身）", .timeLimit(.minutes(1)))
struct BilingualCopyGateRulerTests {

    private func strays(_ source: String) -> [String] {
        BilingualCopyGate.chineseLiterals(in: source, fileName: "Probe.swift")
    }

    @Test("预览块内的假数据不报，块**之后**的写死中文必须报")
    func probeAfterPreviewBlockIsCaught() {
        let source = """
        struct Row: View {
            var body: some View { Text(copy) }
        }

        // MARK: - Previews

        #Preview("某页") {
            Panel { Text("这是给 Canvas 的假数据") }
        }

        private let 探针 = "加在文件尾的真写死中文"
        """
        let found = strays(source)
        #expect(found.count == 1, "实际报出来：\(found)")
        #expect(found[0].contains("探针"), "\(found[0])")
    }

    @Test("缩进写的 #Preview 字样不算边界")
    func indentedPreviewDoesNotOpenAnExemption() {
        let source = """
        struct Row: View {
            var body: some View {
                // #Preview 注释里提一句不算
                Text("缩进块里出现的写死中文")
            }
        }
        """
        let found = strays(source)
        #expect(found.count == 1, "实际报出来：\(found)")
        #expect(found[0].contains("写死中文"), "\(found[0])")
    }

    @Test("顶格的 preview 脚手架函数整块豁免，闭合之后的行照判")
    func previewScaffoldingFunctionIsExemptOnlyItsOwnBlock() {
        let source = """
        private func previewEvents() -> [String] {
            ["修改 TimelineView.swift", "读取凭据文件"]
        }

        let 又一个探针 = "块外"
        """
        let found = strays(source)
        #expect(found.count == 1, "实际报出来：\(found)")
        #expect(found[0].contains("又一个探针"), "\(found[0])")
    }

    @Test("整行注释与行尾注释都不算上屏文案")
    func commentsAreNotCopy() {
        let source = """
        // 整行注释里的中文
        /// 文档注释里的中文
        let label = "copy" // 行尾注释里的中文
        """
        #expect(strays(source).isEmpty, "误报：\(strays(source))")
    }
}
