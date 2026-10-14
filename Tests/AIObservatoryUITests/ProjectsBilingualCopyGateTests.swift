//
//  ProjectsBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10nb（B3 最后三页 · 项目地图）
//  ─────────────────────────────────────────────────────────
//  与 `CommandsBilingualCopyGateTests` 同一套七道门禁（口径推导写在那份文件头，不重复）。
//  本页特有的两件事：
//   ① 量词最重（个 / 次 / 起 / 条 / 种 共 11 处）——它们**故意不进表**，
//      所以「声明数 == 清单数」这条把它们排除在外是刻意的，见 `ProjectsCopy.measureWord`；
//   ② 两条读屏长句（项目卡 8 个参数、热区行 6 个参数）是本页最容易串位的地方，
//      所以除了门禁，还各钉一条**手推英文字面量**的用例。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 项目页双语门禁（表合格 + 全列进清单 + 无复数硬伤 + 表真喂到屏上）", .timeLimit(.minutes(2)))
struct ProjectsBilingualCopyGateTests {

    private static let directory = "Sources/AIObservatoryUI/Projects"
    private static let tableFile = "Sources/AIObservatoryUI/Projects/ProjectsCopy.swift"

    /// 允许两语逐字同串的条目：本表没有。
    private static let sharedStringAllowlist: [String] = []

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: ProjectsCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: ProjectsCopy.bilingualCopy).isEmpty)
    }

    @Test("每条声明过的文案都列进了清单（漏列 = 门禁看不见这一条）")
    func everyDeclaredEntryIsListed() throws {
        let declared = try B3PageCopyGate.declaredTemplateCount(in: Self.tableFile)
        #expect(declared == ProjectsCopy.bilingualCopy.count,
                "表文件声明了 \(declared) 条 LocalizedString，清单只有 \(ProjectsCopy.bilingualCopy.count) 条")
    }

    /// 现值 **110** 条（`grep -c 'NamedCopy("projects\.'` 与 `grep -c 'static let .* = LocalizedString('`
    /// 同为 110；量词走 `measureWord`/`counted` 不进表，见文件头①）。
    @Test("清单非空")
    func tablePopulated() {
        #expect(ProjectsCopy.bilingualCopy.count >= 105,
                "清单只剩 \(ProjectsCopy.bilingualCopy.count) 条 ⇒ 有人删了表却没删调用点")
    }

    @Test("每条都真的译了：英文不与中文逐字相同（例外清单点名）")
    func everyEntryTranslated() {
        let untranslated = ProjectsCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }
        #expect(untranslated.map(\.name) == [])
        let shared = ProjectsCopy.bilingualCopy
            .filter { $0.copy.english == $0.copy.chineseSimplified }
            .map(\.name)
        #expect(shared.sorted() == Self.sharedStringAllowlist.sorted(),
                "两语同串的条目和例外清单对不上：实际 \(shared)，清单 \(Self.sharedStringAllowlist)")
    }

    @Test("英文侧不残留汉字（半截英文 = 没译完）")
    func englishHasNoResidualChinese() {
        let mixed = ProjectsCopy.bilingualCopy.filter { $0.copy.english.containsHan }
        #expect(mixed.map(\.name) == [], "英文里夹着汉字：\(mixed.map(\.name))")
    }

    @Test("英文侧没有「数字紧跟复数名词」（复数没有机制，只能靠写法）")
    func englishAvoidsPluralTrap() {
        let traps = B3PageCopyGate.pluralTrapNames(in: ProjectsCopy.bilingualCopy)
        #expect(traps == [], "这些条目的英文是 \"%d 名词s\" 形状：\(traps)")
    }

    @Test("Projects 目录里不再有写死的中文文案（注释与预览区除外）")
    func noHardcodedChineseOutsideTheTable() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 11,
                "Projects 目录读不到预期数量的文件")
        let strays = try BilingualCopyGate.chineseLiterals(
            under: Self.directory, excluding: ["ProjectsCopy.swift"]
        )
        #expect(strays.isEmpty,
                "这 \(strays.count) 行还写着中文，没走 ProjectsCopy：\n\(strays.joined(separator: "\n"))")
    }

    // MARK: 量词与读屏长句（本页最容易被"顺手补个名词"改坏的两处）

    /// 量词在英文侧**本来就该是空**：这里钉住"补了就红"，而不是等人去实拍。
    @Test("量词两语言各自是什么：英文侧空，中文侧留着")
    func measureWordsAreEmptyInEnglish() {
        #expect(ProjectsCopy.unitProjects(.english) == "")
        #expect(ProjectsCopy.unitTimes(.english) == "")
        #expect(ProjectsCopy.unitRisks(.english) == "")
        #expect(ProjectsCopy.unitProjects(.chineseSimplified) == "个")
        #expect(ProjectsCopy.countedTimes(24, .chineseSimplified) == "24 次")
        #expect(ProjectsCopy.countedTimes(24, .english) == "24")
        #expect(ProjectsCopy.countedRows(1, .english) == "1")
    }

    /// 项目卡 8 个参数、热区行 6 个参数：顺序与类型按位置钉死（手推字面量）。
    @Test("两条读屏长句在英文侧逐字是什么（参数顺序按位置）")
    func accessibilitySentencesRenderInPositionalOrder() {
        #expect(ProjectsCopy.cardA11ySummary.format(
            .english, "Mona", "/work/mona", 12, 3, 2, 1, "Just now", "Agent share: Claude Code 60%"
        ) == "Project Mona. Path /work/mona. File changes 12. Commands 3. "
            + "Sessions 2. Risks 1. Last activity Just now. Agent share: Claude Code 60%")
        #expect(ProjectsCopy.heatA11ySummary.format(
            .english, 2, "/work/mona/Package.swift", 5, 60, 12, "18 minutes ago"
        ) == "Rank 2. Path /work/mona/Package.swift. Changes 5. Added 60. Removed 12. "
            + "Last change 18 minutes ago")
        // 中文侧同一批槽位必须逐字回到改版前那串话。
        #expect(ProjectsCopy.cardA11ySummary.format(
            .chineseSimplified, "Mona", "/work/mona", 12, 3, 2, 1, "刚刚", "Agent 贡献占比：Claude Code 60%"
        ) == "项目 Mona，路径 /work/mona，文件变更 12 次，命令 3 次，会话 2 个，风险 1 起，"
            + "最后活动 刚刚。Agent 贡献占比：Claude Code 60%")
    }
}
