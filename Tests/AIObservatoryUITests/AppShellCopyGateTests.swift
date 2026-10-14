//
//  AppShellCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: master-controller（#72 的门禁半句）
//  ─────────────────────────────────────────────────────────
//  双语门禁此前**一堵墙都没盖住 `Sources/AIObservatoryApp/`**：中央棘轮与九道按目录门禁
//  的扫描根都在 `Sources/AIObservatoryUI/**`（grep `AIObservatoryApp` 在
//  `HardcodedChineseRatchetTests.swift` 里 0 命中）。于是菜单命令、`NSSavePanel` 标题与按钮、
//  错误弹框在英文态下满屏中文，而套件全绿——"门禁在、射程不在"那一族里最省事的一种：**整个 target 没被扫**。
//
//  ⚠️ 一条已知缺口，不偷偷改判：`AppShellCopy` 那张表按**文件名**豁免
//  （与其它 12 份 `*Copy.swift` 同一待遇），所以往它里面塞一条裸 `String` 中文不会被这里抓到。
//  本文件下面的 `exemptTableIsReallyATable` 就是钉这一点的：那份文件里除 `LocalizedString(zh:en:)`
//  与 `NamedCopy` 之外的中文行，一旦冒出来就红。
//

import Foundation
import Testing

// 中文判据用本 target 尺子文件里的 `String.containsHan`（`BilingualCopyGateSupport.swift:173`），
// 不在这里再写一份：两份中文判定一定会飘，而且新写的那份通常更松。

@Suite("App target 双语门禁（射程补上 AIObservatoryApp）")
struct AppShellCopyGateTests {

    /// 扫描根。写成一个常量是为了让"目录改名"这件事变成用例红，而不是扫描悄悄变 0 份文件。
    static let directory = "Sources/AIObservatoryApp"

    /// 文案表按文件名豁免（与中央棘轮同一约定）。
    static let exemptTable = "AppShellCopy.swift"

    /// 这一页实际存在的 `.swift` 份数下限（**普查结果不是余量**：少一个文件要连原因一起改这一格）。
    static let fileFloor = 6

    @Test("App target 里没有裸中文字面量（菜单 / 系统面板 / 弹框全部走表）")
    func noStrayChineseInAppTarget() throws {
        let files = try BilingualCopyGate.swiftFiles(under: Self.directory)
        #expect(files.count >= Self.fileFloor,
                "只扫到 \(files.count) 份文件（下限 \(Self.fileFloor)）⇒ 目录被改名或文件被搬走，这条门禁正在对空集讲话")
        let strays = try BilingualCopyGate.chineseLiterals(
            under: Self.directory, excluding: [Self.exemptTable])
        #expect(strays.isEmpty, "英文态会露中文的裸字面量：\(strays)")
    }

    /// 反向自证：尺子喂一段真含中文的源码必须抓到，否则上面的"零命中"只是尺子瞎了。
    @Test("反向探针：同一段中文喂进尺子必须报出来（证明零命中不是空转）")
    func rulerFiresOnKnownChinese() {
        let snippet = """
        import SwiftUI
        struct Panel {
            var title: String { "导出失败" }
        }
        """
        let found = BilingualCopyGate.chineseLiterals(in: snippet, fileName: "Probe.swift")
        #expect(found.count == 1, "尺子对已知中文报了 \(found.count) 条：\(found)")
    }

    /// 豁免是**按文件名**给的，所以那张表里除双语文案之外不许有别的东西藏中文。
    @Test("被豁免的那份表里不许长出\"不是文案对\"的中文（豁免只给表，不给借口）")
    func exemptTableIsReallyATable() throws {
        let text = try BilingualCopyGate.codeOnlyString(
            "\(Self.directory)/\(Self.exemptTable)")
        // `codeOnlyString` 给的是 String；`containsHan` 是尺子文件里 `extension String` 的成员，
        // 所以按行切完要落回 String（Substring 上没有，编译器会当场拒绝而不是静默宽松）。
        let offenders = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { line in
                guard line.containsHan else { return false }
                let t = line.trimmingCharacters(in: .whitespaces)
                // 允许的形态只有三种：成对文案的两侧、清单里挂名字、多行字符串的续写。
                return !(t.contains("zh:") || t.contains("en:") || t.contains("NamedCopy(")
                         || t.hasPrefix("+ \""))
            }
        #expect(offenders.isEmpty,
                "豁免文件里出现不带 zh:/en: 的中文行（豁免是给文案对的，不是给裸常量的）：\(offenders)")
    }
}
