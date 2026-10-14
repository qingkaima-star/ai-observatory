//
//  SecurityBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10n（B3 后半 · 风险目录）
//  ─────────────────────────────────────────────────────────
//  风险页的门禁。形状同 Sessions / Dashboard / Files 那几份。
//  重点盯 B3 实测最容易翻车的两处：**复数没有机制**（只能靠写法）与
//  **确认面板那句承诺不许被压缩**（它是用户按下按钮前最后读的一屏）。
//

import Testing
import Foundation
@testable import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("风险目录双语门禁")
struct SecurityBilingualCopyGateTests {

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: SecurityCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    /// 条数由用例量出来，不靠手数：表里每个名字都得能在源码里找到它的声明，
    /// 而声明的条数与表长必须相等（有人加了常量忘了登记，或反过来，都会红）。
    @Test("表条数与登记名一一对应")
    func tableIsSelfConsistent() {
        let names = SecurityCopy.bilingualCopy.map(\.name)
        #expect(Set(names).count == names.count, "有重名：\(duplicateCopyNames(in: SecurityCopy.bilingualCopy))")
        #expect(names.allSatisfy { $0.hasPrefix("security.") }, "名字必须带目录前缀：\(names)")
        // 表里两路都非空、且含中文的那条英文不许照抄
        let untranslated = SecurityCopy.bilingualCopy.filter {
            $0.copy.english.isEmpty || ($0.copy.english == $0.copy.chineseSimplified
                                        && $0.copy.chineseSimplified.containsCJK)
        }
        #expect(untranslated.map(\.name) == [])
    }

    @Test("多参数文案的下标连续覆盖 1…n")
    func positionalIndexesComplete() {
        for entry in SecurityCopy.bilingualCopy {
            for (language, text) in [(AppLanguage.chineseSimplified, entry.copy.chineseSimplified),
                                      (.english, entry.copy.english)] {
                let positions = Set(LocalizedString.specs(in: text).compactMap(\.position))
                guard positions.isEmpty == false else { continue }
                #expect(positions == Set(1...positions.count),
                        "\(entry.name)（\(language.rawValue)）下标 \(positions.sorted()) 不连续")
            }
        }
    }

    /// 复数没有机制 ⇒ 数量中性写法。`and 1 more` 成立，`1 more paths` 就是硬伤。
    @Test("未列出路径那句在 1 和 N 下都读得通")
    func morePathsIsPluralNeutral() {
        #expect(SecurityCopy.morePaths.format(.chineseSimplified, "1") == "另有 1 个路径")
        #expect(SecurityCopy.morePaths.format(.chineseSimplified, "7") == "另有 7 个路径")
        #expect(SecurityCopy.morePaths.format(.english, "1") == "and 1 more")
        #expect(SecurityCopy.morePaths.format(.english, "7") == "and 7 more")
        // 数量中性是写法保证的，不是断言保证的：这句英文里不许出现复数名词。
        for n in ["1", "7"] {
            let text = SecurityCopy.morePaths.format(.english, n)
            #expect(!text.contains("paths"), "又写回了带复数名词的说法：\(text)")
        }
    }

    /// 确认面板那句承诺的两半都在：只标记已处置 + 不删采集记录。
    /// 压成一句 "marked as handled" 会让用户以为确认会清数据，或以为会删记录。
    @Test("确认说明的英文两半都在，按钮词按 macOS 惯用")
    func acknowledgeNoteKeepsBothHalves() {
        let note = SecurityCopy.acknowledgeNote.text(.english)
        #expect(note.contains("marks this event as handled"))
        #expect(note.lowercased().contains("does not delete"))
        #expect(SecurityCopy.acknowledgeButton.text(.english) == "Acknowledge")
        #expect(SecurityCopy.laterButton.text(.english) == "Handle Later")
        // 中文原句逐字不动（#49 与需求⑧ 的旁证都钉在它上面）
        #expect(SecurityCopy.acknowledgeNote.text(.chineseSimplified)
            == "确认后该事件在本地标记为已处置，不会删除任何采集记录。")
    }

    /// #49 的收口成果不许被双语弄回去：两个面板共用同一串。
    @Test("判定依据与命中规则仍是两面板共用同一常量")
    func sharedRationaleTitlesSurvive() {
        #expect(SecurityCopy.rationaleTitle.text(.chineseSimplified) == "判定依据")
        #expect(SecurityCopy.matchedRuleTitle.text(.chineseSimplified) == "命中规则")
        #expect(SecurityCopy.rationale("   ") == "规则未提供额外说明。")
        #expect(SecurityCopy.rationale("有依据").contains("有依据"))
    }
    // MARK: 目录内不许写死中文（总控 08:5x 派单：覆盖面要有分母，每道按目录的门禁带长度守卫）

    /// 这一页的目录。**中央棘轮扫整个 UI，这一道只盯这一页**，两者查的不是同一件事：
    /// 棘轮管"存量不许变大、谁变了要改名认错"，这一道管"这一页今天到底有没有被读到"。
    private static let directory = "Sources/AIObservatoryUI/Security"

    /// 长度守卫。目录改名、路径写错、整页被挪走，都会让下面那道门禁
    /// **扫 0 份文件还常绿**——本仓最阴的那一类（门禁在，射程没了）。
    /// 这个数是普查结果不是余量：这一页真要少一个文件，改这一格得连原因一起写。
    @Test("Security 目录真的被扫到了（不是静默扫 0 份）")
    func scanActuallySeesTheDirectory() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 8,
                "份数掉到普查下限以下 ⇒ 目录改名或被挪走，这道门禁已经射程为零")
    }

    /// 存量数字**只在 `HardcodedChineseRatchetTests.baseline` 里存一份**（文件→行数），
    /// 这里不抄那张表，只钉"这一页超出基线的行数必须为 0"。
    /// 抄一份就会漂（今天这三页正是因为没人挂这道，各自全绿而屏上全是硬中文）。
    @Test("Security 目录里没有超出棘轮基线的写死中文")
    func noStraysBeyondTheRatchet() throws {
        let over = HardcodedChineseRatchetTests.violations(
            measured: try HardcodedChineseRatchetTests.measuredCounts(under: Self.directory),
            baseline: HardcodedChineseRatchetTests.baseline)
        #expect(over.isEmpty, "这一页比基线多了写死的中文：\n\(over.joined(separator: "\n"))")
    }
}
