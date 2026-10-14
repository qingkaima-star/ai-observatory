//
//  DashboardBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  今日概览页的三道门禁。形状与 `SessionsBilingualCopyGateTests` 相同——两份表都是
//  "名字写在常量行上"的那一式，所以需要"声明数 == 清单条数"这一道；
//  `ShellCopy`/`TimelineCopy` 那两份式子（Localized 常量 + 清单里再写一次名字）不需要，
//  漏列会在编译期报未使用。尺子统一在 `BilingualCopyGateSupport`，四目录共用一把。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 今日概览双语门禁（表合格 + 全列进清单 + 表真喂到屏上）", .timeLimit(.minutes(2)))
struct DashboardBilingualCopyGateTests {

    private static let directory = "Sources/AIObservatoryUI/Dashboard"
    private static let tableFile = "Sources/AIObservatoryUI/Dashboard/DashboardCopy.swift"

    /// 允许两语逐字同串的条目：本表没有。要加就得连同理由写在这里。
    private static let sharedStringAllowlist: [String] = []

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: DashboardCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: DashboardCopy.bilingualCopy).isEmpty)
    }

    @Test("每条声明过的文案都列进了清单（漏列 = 门禁看不见这一条）")
    func everyDeclaredEntryIsListed() throws {
        let declared = try BilingualCopyGate.declaredNamedCopyCount(in: Self.tableFile)
        #expect(declared == DashboardCopy.bilingualCopy.count,
                "表文件声明了 \(declared) 条 NamedCopy，清单只有 \(DashboardCopy.bilingualCopy.count) 条")
    }

    @Test("清单非空")
    func tablePopulated() {
        #expect(DashboardCopy.bilingualCopy.count >= 70,
                "清单只剩 \(DashboardCopy.bilingualCopy.count) 条 ⇒ 有人删了表却没删调用点")
    }

    @Test("每条都真的译了：英文不与中文逐字相同（例外清单点名）")
    func everyEntryTranslated() {
        let untranslated = DashboardCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }
        #expect(untranslated.map(\.name) == [])
        let shared = DashboardCopy.bilingualCopy
            .filter { $0.copy.english == $0.copy.chineseSimplified }
            .map(\.name)
        #expect(shared.sorted() == Self.sharedStringAllowlist.sorted(),
                "两语同串的条目和例外清单对不上：实际 \(shared)，清单 \(Self.sharedStringAllowlist)")
    }

    @Test("英文侧不残留汉字（半截英文 = 没译完）")
    func englishHasNoResidualChinese() {
        let mixed = DashboardCopy.bilingualCopy.filter { $0.copy.english.containsHan }
        #expect(mixed.map(\.name) == [], "英文里夹着汉字：\(mixed.map(\.name))")
    }

    @Test("Dashboard 目录里不再有写死的中文文案（注释与预览区除外）")
    func noHardcodedChineseOutsideTheTable() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 6,
                "Dashboard 目录读不到预期数量的文件")
        let strays = try BilingualCopyGate.chineseLiterals(
            under: Self.directory, excluding: ["DashboardCopy.swift"]
        )
        #expect(strays.isEmpty,
                "这 \(strays.count) 行还写着中文，没走 DashboardCopy：\n\(strays.joined(separator: "\n"))")
    }
}
