//
//  TimelineBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  与 `ShellBilingualCopyGateTests` 同一套两道门禁（表合格 / 表真喂到屏上），
//  尺子在 `BilingualCopyGateSupport.swift` 里共用一份——四目录各自实现一遍必然飘。
//  本文件只负责时间线那一目录的**例外清单**：哪些条目允许两语同串。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 时间线双语门禁（表合格 + 表真喂到屏上）", .timeLimit(.minutes(2)))
struct TimelineBilingualCopyGateTests {

    private static let directory = "Sources/AIObservatoryUI/Timeline"

    /// 允许两语逐字同串的条目，连同**为什么**：
    /// `filter.agentFallback` 是"一个 Agent 都没选中且取不到名字"时的兜底标签，
    /// 两侧都只能是 "Agent" 这个技术名本身（把它译成"代理"反而与界面别处的 Agent 撞口径）。
    private static let sharedStringAllowlist: [String] = ["timeline.filter.agentFallback"]

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: TimelineCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: TimelineCopy.bilingualCopy).isEmpty)
    }

    /// 现值 **101** 条：密度两档 + 事件行读屏 6 + 载入进度 + 过滤控件 21 + 事件详情 26
    /// + 页面骨架/六个次级读数/事件流/分组/翻页/密度/加载/空/错误。
    /// （原来写 73 是凭记忆数的，`grep -c NamedCopy\("timeline\.` 实测 101。）
    @Test("清单非空")
    func tablePopulated() {
        #expect(TimelineCopy.bilingualCopy.count >= 100,
                "清单只剩 \(TimelineCopy.bilingualCopy.count) 条 ⇒ 有人删了表却没删调用点")
    }

    @Test("每条都真的译了：英文不与中文逐字相同（例外清单点名）")
    func everyEntryTranslated() {
        let untranslated = TimelineCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }
        #expect(untranslated.map(\.name) == [])
        let shared = TimelineCopy.bilingualCopy
            .filter { $0.copy.english == $0.copy.chineseSimplified }
            .map(\.name)
        #expect(shared.sorted() == Self.sharedStringAllowlist.sorted(),
                "两语同串的条目和例外清单对不上：实际 \(shared)，清单 \(Self.sharedStringAllowlist)")
    }

    @Test("英文侧不残留汉字（半截英文 = 没译完）")
    func englishHasNoResidualChinese() {
        let mixed = TimelineCopy.bilingualCopy.filter { $0.copy.english.containsHan }
        #expect(mixed.map(\.name) == [], "英文里夹着汉字：\(mixed.map(\.name))")
    }

    @Test("Timeline 目录里不再有写死的中文文案（注释与预览区除外）")
    func noHardcodedChineseOutsideTheTable() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 6,
                "Timeline 目录读不到预期数量的文件")
        let strays = try BilingualCopyGate.chineseLiterals(
            under: Self.directory, excluding: ["TimelineCopy.swift"]
        )
        #expect(strays.isEmpty,
                "这 \(strays.count) 行还写着中文，没走 TimelineCopy：\n\(strays.joined(separator: "\n"))")
    }
}
