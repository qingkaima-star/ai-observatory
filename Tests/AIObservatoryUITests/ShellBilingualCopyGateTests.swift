//
//  ShellBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  外壳层双语的两道门禁。缺一道都会留下"看起来迁完了"的缝：
//
//  ① **表本身合格**（IFR 裁定 3(a) 的形状）：遍历 `ShellCopy.bilingualCopy` 断言零缺陷、
//     名字不重复、每条真的给了不同的英文。这一道只管"写进表的字对不对"。
//  ② **表真的喂到了屏上**：扫 `Shell/**` 的源码，除 `ShellCopy.swift` 外
//     任何代码行（去掉注释与 `#Preview` 标签后）都不许再出现汉字。
//     这一道是本仓头号缺陷族的直接防守——只有①的话，一个人可以建一份漂亮的表、
//     一条都不接，界面照旧写死中文，而①全绿。
//
//  ⚠️ 两条都不读宿主系统语言：要中文传 `.chineseSimplified`、要英文传 `.english`
//  （`UILanguage.current` 是运行时解析结果，测试进程里它等于跑测试那台机器的语言）。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 外壳层双语门禁（表合格 + 表真喂到屏上）", .timeLimit(.minutes(2)))
struct ShellBilingualCopyGateTests {

    private static let directory = "Sources/AIObservatoryUI/Shell"

    // MARK: ① 表本身

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: ShellCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: ShellCopy.bilingualCopy).isEmpty)
    }

    /// 数量下界而不是等号：删条目要红，加条目不用改用例。
    /// 现值 **49** 条 = 九板块标题 9 + 九条说明 9 + 四个分组名 4 + 单句 27。
    /// ⚠️ 这个数是**用例量出来的**，不是我数的：我先按"字面 `NamedCopy("shell.` 有 30 处"
    /// 推成 52（把两条 allCases 循环里那 3 处文本又当成 22 条另算了一遍），
    /// 把下界抬到 50 之后用例当场报 `count → 49`。同一个错我在提交信息里犯过两次
    /// （Timeline 写 73、Dashboard 写 70，实测 101 / 72）——见交付块「自己犯的错」。
    @Test("清单非空")
    func tablePopulated() {
        #expect(ShellCopy.bilingualCopy.count >= 45,
                "清单只剩 \(ShellCopy.bilingualCopy.count) 条 ⇒ 有人删了表却没删调用点")
    }

    @Test("每条都真的译了：英文不与中文逐字相同（品牌名除外，且点名）")
    func everyEntryTranslated() {
        let untranslated = ShellCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }
        #expect(untranslated.map(\.name) == [])
        // 品牌名是唯一"两语同串"的条目，单独点名，别让下一个人拿它当先例。
        let shared = ShellCopy.bilingualCopy.filter { $0.copy.english == $0.copy.chineseSimplified }
        #expect(shared.map(\.name) == ["shell.menubar.brand"],
                "又出现两语同串的条目：\(shared.map(\.name))")
    }

    @Test("英文侧不残留汉字（半截英文 = 没译完）")
    func englishHasNoResidualChinese() {
        let mixed = ShellCopy.bilingualCopy.filter { $0.copy.english.containsHan }
        #expect(mixed.map(\.name) == [], "英文里夹着汉字：\(mixed.map(\.name))")
    }

    // MARK: ② 表喂到了屏上

    @Test("Shell 目录里不再有写死的中文文案（注释与 #Preview 标签除外）")
    func noHardcodedChineseOutsideTheTable() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 5,
                "Shell 目录读不到预期数量的文件")
        let strays = try BilingualCopyGate.chineseLiterals(under: Self.directory, excluding: ["ShellCopy.swift"])
        #expect(strays.isEmpty,
                "这 \(strays.count) 行还写着中文，没走 ShellCopy：\n\(strays.joined(separator: "\n"))")
    }
}
