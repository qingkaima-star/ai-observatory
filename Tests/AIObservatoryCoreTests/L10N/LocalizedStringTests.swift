//
//  LocalizedStringTests.swift
//  AIObservatoryCoreTests — L10N
//
//  Owner: WS-i18n（双语机制层）
//  ─────────────────────────────────────────────────────────
//  期望值全部手推（不是"跑一遍把输出抄回来"）。重点在两类本仓容易翻车的地方：
//   · **串位**：中英语句成分顺序不同，位置参数用错就把值塞进别人的槽；
//   · **假双语**：英文那一路其实是中文没译，切了语言看起来一切正常。
//  `%%` 转义、宽度/精度标志这些"解析器容易数错"的形状单独占用例——
//  数错会把好文案判成缺陷（假红），或把坏文案判成没问题（假绿）。
//

import Testing
import Foundation
@testable import AIObservatoryCore

@Suite("L10N：语言解析（只跟随系统）")
struct AppLanguageResolutionTests {

    @Test(arguments: [
        // (系统偏好串, 期望语言, 为什么)
        (["en"], AppLanguage.english, "纯英文"),
        (["en-CN", "zh-Hans"], .english, "取第一个认识的语言，后面不回头看"),
        (["zh-Hans-CN"], .chineseSimplified, "简体带地区后缀"),
        (["zh-Hant"], .chineseSimplified, "繁体已知取舍：落简体文案，比落英文更接近能读的"),
        (["fr", "de"], .chineseSimplified, "全不认识 ⇒ 兜底到唯一有全量文案的语言"),
        ([], .chineseSimplified, "空列表也兜底，不给 nil 也不崩"),
        (["fr", "en-GB"], .english, "跳过不认识的，继续往后找"),
        (["ja-JP"], .chineseSimplified, "日语不算英文，宁可给中文"),
    ])
    func resolvesPreferredIdentifiers(preferred: [String], expected: AppLanguage, why: String) {
        // 注释必须是 `Comment`（字面量或插值串），传一个 String 变量进去编译不过。
        #expect(
            AppLanguage.resolved(from: preferred) == expected,
            "\(preferred) ⇒ 期望 \(expected.rawValue)：\(why)"
        )
    }

    @Test("兜底语言必须是已具备全量文案的那个")
    func fallbackHasCompleteCopy() {
        // 若哪天英文补齐了，这条会红着提醒改 `hasCompleteCopy` 与兜底方向，而不是静默换语言。
        #expect(AppLanguage.chineseSimplified.hasCompleteCopy)
        #expect(!AppLanguage.english.hasCompleteCopy)
    }
}

@Suite("L10N：一对文案的取值与渲染")
struct LocalizedStringTests {

    @Test("取值拿对的那一路")
    func textSelectsLanguage() {
        let copy = LocalizedString(zh: "已确认", en: "Acknowledged")
        #expect(copy.text(.chineseSimplified) == "已确认")
        #expect(copy.text(.english) == "Acknowledged")
    }

    /// 这条是机制层存在的理由：中文把数量放前面、英文把命令放前面，
    /// 靠 `%1$` / `%2$` 位置下标各归各位，而不是靠调用方记得换参数顺序。
    @Test("位置参数：同一组实参在两种语序下都落对槽")
    func positionalFormattingKeepsArgumentsInSlots() {
        let copy = LocalizedString(
            zh: "%1$d 条命令已确认（%2$@）",
            en: "%2$@ acknowledged across %1$d commands"
        )
        #expect(copy.format(.chineseSimplified, arguments: [3, "rm -rf"]) == "3 条命令已确认（rm -rf）")
        #expect(copy.format(.english, arguments: [3, "rm -rf"]) == "rm -rf acknowledged across 3 commands")
        #expect(copy.problems.isEmpty, "\(copy.problems)")
    }

    @Test("单个参数允许裸写说明符，不强制位置下标")
    func singlePlaceholderNeedsNoPosition() {
        let copy = LocalizedString(zh: "共 %d 条", en: "%d items in total")
        #expect(copy.problems.isEmpty, "\(copy.problems)")
        #expect(copy.format(.chineseSimplified, 12) == "共 12 条")
        #expect(copy.format(.english, 12) == "12 items in total")
    }

    @Test("`%%` 是转义，不得被数成参数")
    func escapedPercentIsNotAnArgument() {
        let copy = LocalizedString(zh: "已用 %d%% 内存", en: "Used %d%% of memory")
        #expect(LocalizedString.specs(in: copy.chineseSimplified).count == 1)
        #expect(LocalizedString.specs(in: copy.english).count == 1)
        #expect(copy.problems.isEmpty, "\(copy.problems)")
        #expect(copy.format(.chineseSimplified, 42) == "已用 42% 内存")
        #expect(copy.format(.english, 42) == "Used 42% of memory")
    }

    @Test("宽度与精度标志解析不能数错说明符")
    func widthAndPrecisionFlagsParse() {
        let copy = LocalizedString(zh: "增长 %1$+5.2f 行/时", en: "Growth %1$+5.2f lines/hour")
        #expect(LocalizedString.specs(in: copy.chineseSimplified) == [.init(position: 1, type: "f")])
        #expect(copy.problems.isEmpty, "\(copy.problems)")
    }

    @Test("英文与中文逐字相同且含中文 ⇒ 未译")
    func untranslatedCopyIsCaught() {
        #expect(LocalizedString(zh: "高风险操作", en: "高风险操作").problems == [.englishSameAsChinese])
        #expect(LocalizedString(zh: "已确认", en: "").problems == [.englishEmpty])
        // 反向保护：命令名、路径、纯符号本来就两语言同串，不许被误判成"未译"（假红）。
        #expect(LocalizedString(zh: "rm -rf", en: "rm -rf").problems.isEmpty)
        #expect(LocalizedString(zh: "~/Library", en: "~/Library").problems.isEmpty)
    }

    @Test("两语言参数个数不等 ⇒ 必有一种语言渲染错位")
    func placeholderCountMismatchIsCaught() {
        let copy = LocalizedString(zh: "%1$@ 触发了 %2$d 条规则", en: "Triggered %1$d rules")
        #expect(copy.problems == [.placeholderCountMismatch(chinese: 2, english: 1)])
    }

    @Test("多参数却没有位置下标 ⇒ 换语言会串位")
    func multiArgumentCopyMustBePositional() {
        let copy = LocalizedString(zh: "%@ 产生了 %d 次删除", en: "%d deletions by %@")
        // 除"未位置化"本身，串位的后果也必须一起报出来：两语言同一槽位类型相反。
        #expect(
            copy.problems == [
                .placeholdersNotPositional,
                .placeholderTypeMismatch(position: 1, chinese: "@", english: "d"),
                .placeholderTypeMismatch(position: 2, chinese: "d", english: "@"),
            ],
            "\(copy.problems)"
        )
    }

    @Test("同一槽位两语言类型不同 ⇒ 读到错类型")
    func placeholderTypeMismatchIsCaught() {
        let copy = LocalizedString(zh: "%1$d 条（%2$@）", en: "%1$@ (%2$d)")
        #expect(copy.problems.contains(.placeholderTypeMismatch(position: 1, chinese: "d", english: "@")))
    }

    /// 把"不做 `ExpressibleByStringLiteral`"这条设计决定变成可回归的断言：
    /// 一旦有人为了方便加上了字面量兼容，`let s: LocalizedString = "已确认"` 就能编译通过，
    /// 于是缺译静默通过——本仓库最难发现的那一类形状。
    @Test("LocalizedString 不得接受裸字符串字面量")
    func refusesStringLiteralCoercion() {
        #expect(LocalizedString.self as? any ExpressibleByStringLiteral.Type == nil)
    }
}
