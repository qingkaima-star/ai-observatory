//
//  NamedCopy.swift
//  AIObservatoryCore — L10N
//
//  Owner: WS-l10n（双语迁移 B1）
//  ─────────────────────────────────────────────────────────
//  机制层的 `LocalizedString` 是**就地构造的值**，没有中心清单可遍历 ⇒ 缺译只能等人看见。
//  `IFR-i18n-string-catalog.md` 裁定 3 选了 (a) 集中声明：每个模块暴露
//  `static let bilingualCopy: [NamedCopy]`，门禁用例遍历它断言 `problems.isEmpty`。
//  选 (a) 而不是源码扫描 / String Catalog 的理由见那份裁定，本文件不复述。
//
//  为什么放 Core 而不是各模块自己声明一份：`NamedCopy` 只是「带名字的一对文案」，
//  Export / Insights / Platform / RiskRules / UI 都要用；各写一份 = 五份同名类型 +
//  门禁断言只能各管各的。放 L10N（不是 `Contracts/**`）不碰 §3 冻结区。
//

import Foundation

/// 一条**有名字**的文案对。名字只服务于门禁报告：出问题时要能指到源码里的哪一条，
/// 而不是打出「第 47 条英文为空」让人去数数组下标。
public struct NamedCopy: Sendable, Hashable {

    /// 稳定标识，约定用 `<模块>.<语义名>`（如 `export.report.overviewTitle`）。
    /// 不用 `#function` 之类推导：那会把名字和调用点耦合在同一个文件里，
    /// 而清单需要跨文件排序与检索。
    public let name: String

    public let copy: LocalizedString

    public init(_ name: String, _ copy: LocalizedString) {
        self.name = name
        self.copy = copy
    }

    /// 本条文案的缺陷清单，转发自 `LocalizedString.problems`。
    public var problems: [LocalizedString.CopyProblem] { copy.problems }

    /// 渲染某语言的文案（透传，写在用例与调用点里更短）。
    public func text(_ language: AppLanguage = .resolved()) -> String { copy.text(language) }
}

/// 一批文案的缺陷汇总：`[(名字, 问题)]`，空数组 = 全部门禁通过。
///
/// 单独列成函数是为了让各模块的门禁用例**只写断言、不各自实现遍历**
/// （每个模块自己写一遍循环，五份会飘）。它只报告，不"修好"任何一条。
public func copyProblems(in copies: [NamedCopy]) -> [(name: String, problems: [LocalizedString.CopyProblem])] {
    copies.compactMap { entry in
        let found = entry.problems
        return found.isEmpty ? nil : (entry.name, found)
    }
}

/// 一批文案里重复出现的名字。
///
/// 名字重复 = 门禁报告里两条不同文案共用一个标签，读报告的人会被指到错的那条。
/// 这是集中声明这套机制自己的失败模式，所以也要机器查，不能靠自觉。
public func duplicateCopyNames(in copies: [NamedCopy]) -> [String] {
    var seen: Set<String> = []
    var duplicates: Set<String> = []
    for entry in copies where !seen.insert(entry.name).inserted {
        duplicates.insert(entry.name)
    }
    return duplicates.sorted()
}
