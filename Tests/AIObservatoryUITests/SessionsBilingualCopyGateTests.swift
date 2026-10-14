//
//  SessionsBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  会话页的三道门禁（同 `ShellBilingualCopyGateTests` 两道，多一道这一页特有的）：
//  ① 表合格；② 表真喂到屏上；③ **声明了的每一条都真的列进清单**。
//  ③ 是 `SessionsCopy` 那份"名字写在常量行上"的形状换来的新漏洞：清单只列标识符，
//  漏列一个不会编译失败，只会让门禁看不见那一条 ⇒ 数声明处数与清单条数是否相等。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 会话页双语门禁（表合格 + 全列进清单 + 表真喂到屏上）", .timeLimit(.minutes(2)))
struct SessionsBilingualCopyGateTests {

    private static let directory = "Sources/AIObservatoryUI/Sessions"
    private static let tableFile = "Sources/AIObservatoryUI/Sessions/SessionsCopy.swift"

    /// 允许两语逐字同串的条目：本表没有。要加就得连同理由写在这里。
    private static let sharedStringAllowlist: [String] = []

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: SessionsCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: SessionsCopy.bilingualCopy).isEmpty)
    }

    @Test("每条声明过的文案都列进了清单（漏列 = 门禁看不见这一条）")
    func everyDeclaredEntryIsListed() throws {
        let declared = try BilingualCopyGate.declaredNamedCopyCount(in: Self.tableFile)
        #expect(declared == SessionsCopy.bilingualCopy.count,
                "表文件声明了 \(declared) 条 NamedCopy，清单只有 \(SessionsCopy.bilingualCopy.count) 条")
    }

    @Test("清单非空")
    func tablePopulated() {
        #expect(SessionsCopy.bilingualCopy.count >= 130,
                "清单只剩 \(SessionsCopy.bilingualCopy.count) 条 ⇒ 有人删了表却没删调用点")
    }

    @Test("每条都真的译了：英文不与中文逐字相同（例外清单点名）")
    func everyEntryTranslated() {
        let untranslated = SessionsCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }
        #expect(untranslated.map(\.name) == [])
        let shared = SessionsCopy.bilingualCopy
            .filter { $0.copy.english == $0.copy.chineseSimplified }
            .map(\.name)
        #expect(shared.sorted() == Self.sharedStringAllowlist.sorted(),
                "两语同串的条目和例外清单对不上：实际 \(shared)，清单 \(Self.sharedStringAllowlist)")
    }

    @Test("英文侧不残留汉字（半截英文 = 没译完）")
    func englishHasNoResidualChinese() {
        let mixed = SessionsCopy.bilingualCopy.filter { $0.copy.english.containsHan }
        #expect(mixed.map(\.name) == [], "英文里夹着汉字：\(mixed.map(\.name))")
    }

    @Test("Sessions 目录里不再有写死的中文文案（注释与预览区除外）")
    func noHardcodedChineseOutsideTheTable() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 7,
                "Sessions 目录读不到预期数量的文件")
        let strays = try BilingualCopyGate.chineseLiterals(
            under: Self.directory, excluding: ["SessionsCopy.swift"]
        )
        #expect(strays.isEmpty,
                "这 \(strays.count) 行还写着中文，没走 SessionsCopy：\n\(strays.joined(separator: "\n"))")
    }
}
