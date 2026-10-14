//
//  CommandsBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10nb（B3 最后三页 · 命令审计）
//  ─────────────────────────────────────────────────────────
//  命令页的门禁，六道：表合格 / 名字不重复 / **每条声明都列进清单** / 清单非空 /
//  每条真译了 / 英文侧无残留汉字 / 目录里不再写死中文，外加一条本车道自加的
//  「英文侧不许有数字紧跟复数名词」。
//
//  为什么第③条是本车道新加的：本车道的表沿用 `SettingsCopy` 那份式（先声明常量、
//  清单再挂名字），于是**漏列一条既不编译失败也不测试失败**，门禁从此看不见那一条，
//  而界面照常渲染它。`SessionsCopy` 用反向式（名字写在常量行上）也有同一漏洞，
//  所以那里有 `declaredNamedCopyCount`；这里数的是 `= LocalizedString(` 的处数。
//
//  为什么加「复数硬伤」这一把：英文没有复数机制（`LocalizedString` 只有一对模板，
//  没有 `plural:` 分支），"1 sessions" 这类只有在**命中一条**时才出现，
//  前几页是靠英文态实拍才抓到 5 处——逐字断言看不出来。写成本车道三份表共用的尺子
//  （`B3PageCopyGateSupport`），本车道自己先受约束。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 命令页双语门禁（表合格 + 全列进清单 + 无复数硬伤 + 表真喂到屏上）", .timeLimit(.minutes(2)))
struct CommandsBilingualCopyGateTests {

    private static let directory = "Sources/AIObservatoryUI/Commands"
    private static let tableFile = "Sources/AIObservatoryUI/Commands/CommandsCopy.swift"

    /// 允许两语逐字同串的条目：本表没有（要加就得连同理由写在这里）。
    private static let sharedStringAllowlist: [String] = []

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: CommandsCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: CommandsCopy.bilingualCopy).isEmpty)
    }

    @Test("每条声明过的文案都列进了清单（漏列 = 门禁看不见这一条）")
    func everyDeclaredEntryIsListed() throws {
        let declared = try B3PageCopyGate.declaredTemplateCount(in: Self.tableFile)
        #expect(declared == CommandsCopy.bilingualCopy.count,
                "表文件声明了 \(declared) 条 LocalizedString，清单只有 \(CommandsCopy.bilingualCopy.count) 条")
    }

    /// 现值 **75** 条：`grep -c 'NamedCopy("commands\.' CommandsCopy.swift` 与
    /// `grep -c 'static let .* = LocalizedString('` 两边都是 75（上界由上一条用例钉死，
    /// 这里只当下界用——删表不删调用点时会掉到 75 以下）。
    @Test("清单非空")
    func tablePopulated() {
        #expect(CommandsCopy.bilingualCopy.count >= 70,
                "清单只剩 \(CommandsCopy.bilingualCopy.count) 条 ⇒ 有人删了表却没删调用点")
    }

    @Test("每条都真的译了：英文不与中文逐字相同（例外清单点名）")
    func everyEntryTranslated() {
        let untranslated = CommandsCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }
        #expect(untranslated.map(\.name) == [])
        let shared = CommandsCopy.bilingualCopy
            .filter { $0.copy.english == $0.copy.chineseSimplified }
            .map(\.name)
        #expect(shared.sorted() == Self.sharedStringAllowlist.sorted(),
                "两语同串的条目和例外清单对不上：实际 \(shared)，清单 \(Self.sharedStringAllowlist)")
    }

    @Test("英文侧不残留汉字（半截英文 = 没译完）")
    func englishHasNoResidualChinese() {
        let mixed = CommandsCopy.bilingualCopy.filter { $0.copy.english.containsHan }
        #expect(mixed.map(\.name) == [], "英文里夹着汉字：\(mixed.map(\.name))")
    }

    @Test("英文侧没有「数字紧跟复数名词」（复数没有机制，只能靠写法）")
    func englishAvoidsPluralTrap() {
        let traps = B3PageCopyGate.pluralTrapNames(in: CommandsCopy.bilingualCopy)
        #expect(traps == [], "这些条目的英文是 \"%d 名词s\" 形状，命中一条时渲染成 1 xxxs：\(traps)")
    }

    @Test("Commands 目录里不再有写死的中文文案（注释与预览区除外）")
    func noHardcodedChineseOutsideTheTable() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 3,
                "Commands 目录读不到预期数量的文件")
        let strays = try BilingualCopyGate.chineseLiterals(
            under: Self.directory, excluding: ["CommandsCopy.swift"]
        )
        #expect(strays.isEmpty,
                "这 \(strays.count) 行还写着中文，没走 CommandsCopy：\n\(strays.joined(separator: "\n"))")
    }

    // MARK: 承重读数的英文侧（手推字面量，两语言各一把仪器）

    /// 「结果未知 / 进度 / 结果分布」是本页最硬的三条诚实说法，中文侧由
    /// `CommandsModelTests` 逐字钉着；这里补英文侧，缺了这一路就只有实拍看得见。
    /// 三条字面量都是**手推**的（不是跑一遍抄回来的），所以拼错槽位、漏空格都会红。
    @Test("承重读数的英文侧逐字是什么")
    func loadBearingReadoutsInEnglish() {
        #expect(CommandsCopy.unknownResult.text(.english) == "Result unknown")
        #expect(CommandsCopy.fieldExitResult.text(.english) == "Exit result")
        #expect(CommandsCopy.noExitCodeNote.text(.english).hasPrefix("No exit code was captured"))
        #expect(CommandsCopy.durationPrefix.format(.english, "2h30m") == "Took 2h30m")
        #expect(CommandsCopy.argumentCount.format(.english, 3) == "Arguments: 3")
        #expect(CommandsCopy.argumentCount.format(.english, 1) == "Arguments: 1")
        #expect(CommandsCopy.agentKindCount.format(.english, 1) == "Agents: 1")
        #expect(CommandsCopy.emptyFilteredMessage.format(.english, 2, "Today")
                == "Active filters: 2 (time range “Today”). Loosen them to see earlier commands.")
    }
}
