//
//  LocalizedString.swift
//  AIObservatoryCore — L10N
//
//  Owner: WS-i18n（双语机制层）
//  ─────────────────────────────────────────────────────────
//  为什么要有这个文件：本 App 的界面文案此前是**裸中文字面量**（约 2 042 条用户可见），
//  全仓零本地化设施——没有 `.lproj`、没有 String Catalog、没有任何 `Locale` 读取，
//  `Packaging/Info.plist` 只声明了 `CFBundleDevelopmentRegion = zh_CN`。
//
//  为什么不是直接用 `String(localized:)` + 资源包：SwiftPM target 要带 `.lproj` 资源，
//  必须在 `Package.swift` 给 target 加 `resources: [.process(...)]` —— 而 `Package.swift`
//  是 §3 总控冻结区。⇒ 那一版走 IFR（见 AiX-Vault/04-决策记录/IFR-i18n-string-catalog.md）。
//  本文件是**不依赖冻结区就能落地**的机制层，并且把双语最容易翻车的三件事变成编译期或
//  门禁可查的约束：
//   1. **漏译**：构造点必须同时给出两种语言，且刻意不做 `ExpressibleByStringLiteral`
//      —— 否则 `let s: LocalizedString = "已确认"` 会编译通过、"英文"静默等于中文，
//      界面切了语言看起来一切正常，实际一条都没译。那是本仓最贵的一类缺陷
//      （看起来对、其实没喂）。
//   2. **串位**：中英文语序不同，把值嵌进文案必须用**位置参数**（`%1$@`、`%2$d`）。
//      裸写 `%@/%d` 的多参数文案换语言后会把值塞到错的位置上。
//   3. **乱翻译**：`problems` 把"英文与中文逐字相同（且含中文）""参数个数不等"
//      "多参数没用位置参数""同一位置两语言类型不同"列成可读条目，
//      门禁能列清单，而不是等用户看到 `%1$@` 上屏。
//
//  语言来源（需求方 2026-09-21 拍定）：**只跟随系统**，不做 App 内开关——
//  设置项必须有真实消费者（ADR-0006），而"改了要重启才生效的语言开关"与 macOS
//  常规做法（系统设置里改、App 重启即换）重复。
//
//  ⚠️ 一条与"落库"相关的口径，本机制层**只负责渲染**，不改写历史：
//  `risk_events.summary`、`timeline_events.title/summary`、导出报告文本是**写入时定死**的
//  （审计历史不可追溯改写）。切语言只影响之后新写入的行。给这条立用例的形状写在
//  `L10NTests` 文件头，接进落库路径时要一并带过去。
//

import Foundation

/// 界面语言。
public enum AppLanguage: String, CaseIterable, Sendable {
    case chineseSimplified = "zh-Hans"
    case english = "en"

    /// 按系统偏好解析。识别不了的语言一律落到简体中文。
    ///
    /// 兜底选中文而不是英文，是因为**中文是当前唯一有全量文案的语言**：
    /// 缺译时宁可让用户看到读得懂的中文，也不要看到裸 key 或半截 `%1$@`。
    /// 繁体（`zh-Hant`）同样落到简体文案——比落到英文更接近用户能读的东西，
    /// 但这是一条**已知的取舍**，不是"支持了繁体"。
    ///
    /// ⚠️ 默认参数为什么不是 `Bundle.main.preferredLocalizations`（本地化代码的常规写法）：
    /// 本 App 按裁定 1 **不带任何 `.lproj` 资源**，于是那个数组的内容来自
    /// `CFBundleDevelopmentRegion` 而不是用户偏好。实测（2026-09-21，`.worktrees/l10n/tmp/langprobe`
    /// 打成 `.app` 跑）：打包后恒为 `["zh_CN"]`，即使给进程 `-AppleLanguages '(en)'` 也不变，
    /// 而同一个进程里 `Locale.preferredLanguages` 正确给出 `["en"]`。
    /// ⇒ 用它当语言源 = 英文那一路永远走不到，且**看起来一切正常**（本仓头号缺陷族）。
    /// 将来若真的引入 `.lproj`，该改回读 bundle 的 preferredLocalizations 并删掉这条注释。
    public static func resolved(
        from preferredIdentifiers: [String] = Locale.preferredLanguages
    ) -> AppLanguage {
        for identifier in preferredIdentifiers {
            guard let code = Locale(identifier: identifier).language.languageCode?.identifier else {
                continue
            }
            switch code {
            case "en": return .english
            case "zh": return .chineseSimplified
            default: continue
            }
        }
        return .chineseSimplified
    }

    /// 本语言是否已经具备全量文案。缺译清单靠它筛，不靠人记。
    public var hasCompleteCopy: Bool { self == .chineseSimplified }
}

/// 一条文案的**一对**译文。
public struct LocalizedString: Sendable, Hashable {

    public let chineseSimplified: String
    public let english: String

    /// 构造点必须同时给两种语言（见文件头理由 1）。
    public init(zh chineseSimplified: String, en english: String) {
        self.chineseSimplified = chineseSimplified
        self.english = english
    }

    /// 取某语言的文案。
    public func text(_ language: AppLanguage = .resolved()) -> String {
        switch language {
        case .chineseSimplified: return chineseSimplified
        case .english: return english
        }
    }

    /// 带参数渲染。参数按**位置**消费，所以两条文案必须写 `%1$@` / `%2$d` 这种带下标的形式
    /// （只有一条时允许裸 `%@`）。模板里参数比传入的多时不会崩，缺位会原样留 `%n$@`——
    /// 由 `problems` 在门禁里拦，不靠运行时。
    public func format(_ language: AppLanguage, _ arguments: any CVarArg...) -> String {
        format(language, arguments: arguments)
    }

    public func format(_ language: AppLanguage, arguments: [any CVarArg]) -> String {
        String(format: text(language), locale: language.locale, arguments: arguments)
    }

    // MARK: 门禁可读的诊断

    /// 一对译文可能有的缺陷。列出来给人看，不自动"修好"。
    public enum CopyProblem: Equatable, Sendable, CustomStringConvertible {
        /// 英文为空串。
        case englishEmpty
        /// 英文与中文逐字相同且含中文 ⇒ 基本等于没译。
        case englishSameAsChinese
        /// 两语言的格式说明符个数不同 ⇒ 有一种语言会渲染出错位或 `%(null)`。
        case placeholderCountMismatch(chinese: Int, english: Int)
        /// 多于一个参数却没有用 `%n$` 位置下标 ⇒ 换语言会串位。
        case placeholdersNotPositional
        /// 第 n 个参数在两语言里类型不同（`%@` vs `%d`）⇒ 换语言会读到错类型。
        case placeholderTypeMismatch(position: Int, chinese: Character, english: Character)

        public var description: String {
            switch self {
            case .englishEmpty: return "英文文案为空"
            case .englishSameAsChinese: return "英文与中文逐字相同（未译）"
            case let .placeholderCountMismatch(c, e): return "参数个数不等：中文 \(c) 个 / 英文 \(e) 个"
            case .placeholdersNotPositional: return "多参数文案未使用位置参数（%1$@、%2$d）"
            case let .placeholderTypeMismatch(p, c, e):
                return "第 \(p) 个参数类型不一致：中文 %\(c) / 英文 %\(e)"
            }
        }
    }

    /// 本对文案的问题清单；空数组 = 门禁通过。
    public var problems: [CopyProblem] {
        var found: [CopyProblem] = []
        if english.isEmpty {
            found.append(.englishEmpty)
        } else if english == chineseSimplified, chineseSimplified.containsCJK {
            found.append(.englishSameAsChinese)
        }

        let zhSpecs = Self.specs(in: chineseSimplified)
        let enSpecs = Self.specs(in: english)
        guard zhSpecs.count == enSpecs.count else {
            found.append(.placeholderCountMismatch(chinese: zhSpecs.count, english: enSpecs.count))
            return found
        }
        guard zhSpecs.count > 1 else { return found }
        if zhSpecs.contains(where: { $0.position == nil }) || enSpecs.contains(where: { $0.position == nil }) {
            found.append(.placeholdersNotPositional)
        }
        for (index, pair) in zip(zhSpecs.sorted { $0.orderKey < $1.orderKey },
                                 enSpecs.sorted { $0.orderKey < $1.orderKey }).enumerated() {
            if pair.0.type != pair.1.type {
                found.append(.placeholderTypeMismatch(
                    position: index + 1, chinese: pair.0.type, english: pair.1.type
                ))
            }
        }
        return found
    }

    /// 一条格式说明符。
    struct Spec: Equatable {
        /// `%n$` 的 n；裸 `%@` 为 nil。
        var position: Int?
        var type: Character
        /// 排序用：有下标按下标，裸写按出现顺序接在后面。
        var orderKey: Int { position ?? .max }
    }

    /// 扫出格式串里的说明符（`%%` 是转义，不算参数）。
    static func specs(in format: String) -> [Spec] {
        var result: [Spec] = []
        let characters = Array(format)
        var index = 0
        while index < characters.count {
            guard characters[index] == "%" else { index += 1; continue }
            var cursor = index + 1
            if cursor < characters.count, characters[cursor] == "%" { index = cursor + 1; continue }
            var digits = ""
            while cursor < characters.count, characters[cursor].isNumber {
                digits.append(characters[cursor]); cursor += 1
            }
            var positional = false
            if cursor < characters.count, characters[cursor] == "$" { positional = true; cursor += 1 }
            // 跳过标志位/宽度/精度
            while cursor < characters.count, "-+ 0#".contains(characters[cursor]) { cursor += 1 }
            while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
            if cursor < characters.count, characters[cursor] == "." {
                cursor += 1
                while cursor < characters.count, characters[cursor].isNumber { cursor += 1 }
            }
            guard cursor < characters.count else { break }
            let type = characters[cursor]
            if positional, let value = Int(digits) {
                result.append(Spec(position: value, type: type))
            } else {
                result.append(Spec(position: nil, type: type))
            }
            index = cursor + 1
        }
        return result
    }
}

extension AppLanguage {
    /// 渲染用的 `Locale`。数字/日期分隔符跟着语言走，
    /// 但**不能**用 `nil`：那会让同一个格式串在不同系统区域设置下出两种样子。
    var locale: Locale {
        switch self {
        case .chineseSimplified: return Locale(identifier: "zh_CN")
        case .english: return Locale(identifier: "en_US")
        }
    }
}

extension String {
    /// 是否含中日韩表意文字（用来判"这串中文文案的英文没译"）。
    var containsCJK: Bool { unicodeScalars.contains { 0x4E00...0x9FFF ~= $0.value } }
}
