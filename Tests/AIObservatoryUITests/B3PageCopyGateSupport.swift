//
//  B3PageCopyGateSupport.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10nb（B3 最后三页 · Commands / Projects / Performance）
//  ─────────────────────────────────────────────────────────
//  本车道三份门禁（`Commands`/`Projects`/`Performance`）共用的两件尺子。
//  为什么不塞进 `BilingualCopyGateSupport.swift`：那是前几页（Shell/Dashboard/Sessions/
//  Timeline）在用的共用文件，`ws/uicopy` 与 `ws/l10n` 都可能回去改它——同文件撞车正是
//  IFR 排程把 B3 按目录切开的原因。尺子本身的通用部分（剥注释、扫汉字）仍然复用那一份，
//  这里只放**本车道三份表共需**的两件。
//

import Foundation
import AIObservatoryCore

enum B3PageCopyGate {

    /// 文案表文件里**声明**了多少条 `LocalizedString` 常量（数 `static let … = LocalizedString(` 的处数）。
    ///
    /// 为什么本车道要这一把（`Shell`/`Timeline` 没要）：那两份的名字只出现在 `bilingualCopy` 清单里，
    /// 漏列一条 = 那条常量没被任何代码引用，编译器至少还会让人看见它孤零零在那儿。
    /// 本车道的表沿用 `SettingsCopy` 那份式（先声明常量、清单里再挂名字），于是
    /// **漏列一条既不编译失败也不测试失败**——门禁从此看不见那一条，而界面照常渲染它。
    /// 这正是本仓头号缺陷族（声明了但没喂到判据），所以数「声明处数 == 清单条数」。
    static func declaredTemplateCount(in relativeFile: String) throws -> Int {
        let code = try BilingualCopyGate.codeOnlyString(relativeFile)
        return code.split(separator: "\n")
            .filter { $0.contains("static let") && $0.contains("= LocalizedString(") }
            .count
    }

    /// 英文侧踩「复数硬伤」的条目：格式说明符后面直接跟一个以 `s` 结尾的单词。
    ///
    /// `LocalizedString` 只有中英一对模板，没有 `plural:` 分支（那是 Core 机制层的事，
    /// 不在 B3 派单范围）。所以"%1$d sessions"在命中一条时渲染成 "1 sessions"，
    /// 母语者一眼看出是机翻——而**逐字断言看不出来**（前几页是靠英文态实拍才抓到 5 处）。
    /// 这条把它变成用例能查的形状。合法写法有三种（都不需要复数）：
    /// 名词前置 `"Sessions: %1$d"`、`"%1$d active"`、`"%1$d logged"`。
    ///
    /// 已知不覆盖：`"1 data"`、`"1 items shown"` 这类隔了词的——它只抓最常见的
    /// 「数字紧跟复数名词」形状，不假装是英文语法检查器。
    static func pluralTrapNames(in copies: [NamedCopy]) -> [String] {
        copies.filter { entry in
            pluralTrapRanges(in: entry.copy.english) != nil
        }.map(\.name)
    }

    /// 「数字 + 单位缩写」是**合法**写法（`1 s`、`15 ms` 单复数同形），所以豁免。
    /// 只放单复数同形的缩写：把 "seconds" 放进来就等于允许 "1 seconds"。
    static let siUnitExemptions: Set<String> = ["s", "ms", "µs", "ns"]

    /// 找出「格式说明符 + 以 s 结尾的英文单词」的形状，返回第一处（没有则 nil）。
    static func pluralTrapRanges(in english: String, exemptions: Set<String> = siUnitExemptions)
    -> Range<String.Index>? {
        let characters = Array(english)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            var cursor = index + 1
            guard cursor < characters.count, characters[cursor] != "%" else { index = cursor + 1; continue }
            while cursor < characters.count, characters[cursor].isNumber || characters[cursor] == "$" {
                cursor += 1
            }
            while cursor < characters.count, "-+ 0#.".contains(characters[cursor]) { cursor += 1 }
            guard cursor < characters.count, "duxF@".contains(characters[cursor]) else {
                index = max(cursor, index + 1)
                continue
            }
            cursor += 1
            // 说明符后面（允许一个空格）紧跟一个以 s 结尾的英文单词 ⇒ 复数陷阱。
            var wordStart = cursor
            if wordStart < characters.count, characters[wordStart] == " " { wordStart += 1 }
            var end = wordStart
            while end < characters.count, characters[end].isLetter { end += 1 }
            guard end > wordStart, characters[end - 1] == "s" else { index = end; continue }
            let word = String(characters[wordStart..<end])
            if exemptions.contains(word.lowercased()) { index = end; continue }
            return english.index(english.startIndex, offsetBy: cursor)..<english.index(english.startIndex, offsetBy: end)
        }
        return nil
    }
}
