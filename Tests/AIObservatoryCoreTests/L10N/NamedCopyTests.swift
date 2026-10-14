//
//  NamedCopyTests.swift
//  AIObservatoryCoreTests — L10N
//
//  Owner: WS-l10n（双语迁移 B1）
//  ─────────────────────────────────────────────────────────
//  裁定 3 选的「集中声明」这条路，本身要有用例：`copyProblems` 与 `duplicateCopyNames`
//  是五个模块门禁用例共用的两把尺子，它们数错 = 每个模块的门禁一起变成假的。
//
//  这里刻意用**手造的坏文案**当输入：只喂好文案的用例证明不了网眼存在。
//

import Testing
import Foundation
@testable import AIObservatoryCore

@Suite("L10N：集中声明与门禁汇总")
struct NamedCopyTests {

    @Test("好文案汇总为空")
    func cleanTableReportsNothing() {
        let copies = [
            NamedCopy("a.plain", LocalizedString(zh: "会话", en: "Sessions")),
            NamedCopy("a.formatted", LocalizedString(zh: "共 %1$@ 条", en: "%1$@ items")),
        ]
        #expect(copyProblems(in: copies).isEmpty)
        #expect(duplicateCopyNames(in: copies).isEmpty)
    }

    /// 报告必须**带上名字**：五条缺陷混在一起、不知道是哪一条，门禁就退化成一句"有问题"。
    @Test("缺陷汇总按名字点名")
    func problemsAreAttributedByName() {
        let copies = [
            NamedCopy("ok", LocalizedString(zh: "命令", en: "Commands")),
            NamedCopy("missing-english", LocalizedString(zh: "风险事件", en: "")),
            NamedCopy("not-translated", LocalizedString(zh: "文件变更", en: "文件变更")),
            NamedCopy("swapped-slots", LocalizedString(zh: "%1$@ 与 %@ 个", en: "%1$@ and %2$@ items")),
        ]
        let reported = copyProblems(in: copies)
        #expect(reported.map(\.name) == ["missing-english", "not-translated", "swapped-slots"])
        #expect(reported[0].problems == [.englishEmpty])
        #expect(reported[1].problems == [.englishSameAsChinese])
        #expect(reported[2].problems.contains(.placeholdersNotPositional))
    }

    @Test("重名会被列出来，且只列重复的那一个")
    func duplicatesAreListedOnce() {
        let copies = [
            NamedCopy("dup", LocalizedString(zh: "甲", en: "A")),
            NamedCopy("dup", LocalizedString(zh: "乙", en: "B")),
            NamedCopy("unique", LocalizedString(zh: "丙", en: "C")),
        ]
        #expect(duplicateCopyNames(in: copies) == ["dup"])
    }

    @Test("名字进、文案出：text 与 problems 都是转发的那一条")
    func accessorsForwardToThePair() {
        let entry = NamedCopy("x", LocalizedString(zh: "峰值内存字节", en: "Peak memory (bytes)"))
        #expect(entry.text(.english) == "Peak memory (bytes)")
        #expect(entry.text(.chineseSimplified) == "峰值内存字节")
        #expect(entry.problems.isEmpty)
        // 转发性：缺陷判定不因包了一层名字而改变。
        let bad = NamedCopy("y", LocalizedString(zh: "同一句话", en: "同一句话"))
        #expect(bad.problems == bad.copy.problems)
        #expect(bad.problems == [.englishSameAsChinese])
    }
}
