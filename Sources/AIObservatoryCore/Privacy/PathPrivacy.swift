//
//  PathPrivacy.swift
//  AIObservatoryCore / Privacy
//
//  Owner: WS-l10n（#61 渲染层脱敏）+ #64（把口径收到一处）
//  ─────────────────────────────────────────────────────────
//  「一条绝对路径怎样才算漏出去了」这个问题，全仓只有**这一处**回答。
//
//  为什么放在 Core 而不是 UI：#64 要收的四个面分属三个模块——
//  界面（UI）、导出件（AIObservatoryExport）、通知正文（AIObservatoryPlatform），
//  而它们只共同依赖 Core。放任何一个下游模块里，另外两个就得再写一份，
//  那正是 #64 的成因（#59 在 Platform 里折了一份路径，#61 在 UI 里遮了一份，
//  两边都不认得对方，于是"开关开着，家目录还在屏上"）。
//
//  两把策略、**一把尺子**：先由 `pathRuns(in:)` 唯一地决定"文本里哪一段是路径"，
//  再由策略决定那段变成什么——
//   · `deabsolutized(_:)`：折成 `…/<末段>`（#59 通知正文的既有口径，一个字都不改）；
//   · `PathPrivacy.Mask.scrub(_:)`：换成 `~` / `<project>` 占位符，**保留余下结构**。
//  新增第三种显示形式时请复用 `rewritingRuns`，不要再写第二个分词器。
//
//  ⚠️ 与 #61 的三条铁口径同样适用于这里：**只在渲染层，绝不在落库前**。
//  库里必须仍是原始绝对路径（#41 写入时冻结）；这里改的是"给人读的那一份"。
//

import Foundation

// MARK: - 唯一的路径识别

/// 「文本里哪一段是路径」的唯一判定。
public enum PathPrivacy {

    /// 一段路径在文本里的位置与内容。
    public struct Run: Equatable, Sendable {
        public let range: Range<String.Index>
        /// 原文里的那一段，一定以 `/` 开头。
        public let text: String

        public init(range: Range<String.Index>, text: String) {
            self.range = range
            self.text = text
        }
    }

    /// 路径串**不许**包含的字符：空白、引号与括号类定界符、以及中文句子里的标点。
    /// 为什么要连中文标点一起算：采集面那行是「剔除 2 条：/ …、/Users/dev (过浅：受保护根)」，
    /// 只按空格分词的话 `、/Users/dev` 会连同前面的顿号被当成一个 token，
    /// 于是"路径"永远匹配不上——#64 的漏网面有一半是这个形状造成的。
    static let runTerminators: Set<Character> = [
        " ", "\t", "\n", "\r", "\u{000B}", "\u{000C}",
        "\"", "'", "`", "\u{201C}", "\u{201D}", "\u{2018}", "\u{2019}",
        "(", ")", "[", "]", "{", "}", "<", ">",
        ",", ";", "|", "&", "\\",
        "\u{3001}", "\u{3002}", "\u{FF0C}", "\u{FF1B}", "\u{FF1A}",
        "\u{FF08}", "\u{FF09}", "\u{3010}", "\u{3011}", "\u{300A}", "\u{300B}",
    ]

    /// 扫出文本里所有以 `/` 开头的极大道。
    ///
    /// 只认**绝对**路径：`relative/dir/file` 里没有以 `/` 开头的极大道 ⇒ 不动它。
    /// `//` 开头的（UNC / 重复分隔符）同样算一段，交给策略处理。
    public static func pathRuns(in text: String) -> [Run] {
        guard text.contains("/") else { return [] }
        var runs: [Run] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "/" else {
                cursor = text.index(after: cursor)
                continue
            }
            var end = cursor
            while end < text.endIndex, !runTerminators.contains(text[end]) {
                end = text.index(after: end)
            }
            // 末尾的分隔符（`/a/b/` 的最后一个斜杠）留着一起交给策略，
            // 因为"是不是目录"这件事本身是审计信息，不该在这里替它决定。
            runs.append(Run(range: cursor..<end, text: String(text[cursor..<end])))
            cursor = end
        }
        return runs
    }

    /// 把每个路径段交给 `policy` 改写，其余字符原样保留。
    /// 空文本、无路径 ⇒ 恒等（不复制、不重排）。
    static func rewritingRuns(in text: String, _ policy: (String) -> String) -> String {
        let runs = pathRuns(in: text)
        guard !runs.isEmpty else { return text }
        var out = ""
        out.reserveCapacity(text.count)
        var cursor = text.startIndex
        for run in runs {
            out += text[cursor..<run.range.lowerBound]
            out += policy(run.text)
            cursor = run.range.upperBound
        }
        out += text[cursor...]
        return out
    }

    /// #59 的既有口径：绝对路径只留末段（`rm -rf /Users/x/secrets` → `rm -rf …/secrets`）。
    /// 保住"对什么动手"的语义，同时不泄漏本机目录结构。
    ///
    /// 与改造前的逐字差别：分词从「按空格切」换成 `pathRuns`，因此
    /// `--out=/Users/x/a` 这类"路径粘在别的字符后面"的写法现在也被折掉（原来整串
    /// 因为含 `/` 而被折成 `…/a`，把 `--out=` 一起丢了；现在只折路径那一段）。
    /// 方向是**更严**，不是更松。
    public static func deabsolutized(_ text: String) -> String {
        rewritingRuns(in: text) { run in
            let leaf = run.split(separator: "/", omittingEmptySubsequences: true).last.map(String.init) ?? ""
            return leaf.isEmpty ? "…/" : "…/\(leaf)"
        }
    }

    // MARK: - 演示/脉敏输出映射（#61 → #64）

    /// 路径映射。**原名 `PathPrivacy.Mask`，#71 把它并进 `PathPrivacy` 命名空间**：
    /// 它已经被 `AIObservatoryExport`（导出件）、`AIObservatoryPlatform`（通知正文）、
    /// `AIObservatoryApp`（装配点）与 `AIObservatoryCLI`（只读命令行）的 public 签名引用，
    /// 而 `Demo*` 是**界面的演示语汇**——住在 Core 里，下一个读到它的人会当是测试粉饰而绕过，
    /// 于是长出第二份分词（#56/#49 那一族「有生产者零消费者」就是这么产生的）。
    /// 现在它与 `pathRuns` / `deabsolutized` 同一个屋檐下、同一把尺。**不留 typealias 过渡**。
    ///
    /// 一份脱敏映射。**空 = 关闭**（见 `off`）。
    /// `Hashable`：这份映射会被塞进 `CaptureScope` 这类值类型里当身份的一部分
    /// （`@Observable` 靠赋值判等，两份相同映射必须算同一个值，否则界面白刷新）。
    public struct Mask: Equatable, Hashable, Sendable {
        /// 用户主目录的**绝对**前缀（例如 `/Users/dev`）。`nil` 表示不掩家目录。
        public let home: String?
        /// 项目根前缀，按**最长优先**匹配（嵌套仓库时短的那个不该先命中）。
        public let projectRoots: [String]

        public init(home: String?, projectRoots: [String]) {
            self.home = home
            self.projectRoots = projectRoots
        }

        /// 关闭：恒等映射。
        public static let off = Mask(home: nil, projectRoots: [])

        public var isOff: Bool { home == nil && projectRoots.isEmpty }

        /// 家目录占位符与项目根占位符都是**语言中性**的字面量（`~` / `<project>`），
        /// 不是句子、没有单复数、没有量词 ⇒ 故意不进任何 `*Copy` 文案表。
        public static let homePlaceholder = "~"
        public static let projectPlaceholder = "<project>"

        /// 把一条**整串就是路径**的值换成给人读的那一份。
        ///
        /// ⚠️ 路径出现在句子里时请用 `scrub(_:)`：`apply` 只认"整串以该前缀开头"，
        /// 「剔除 1 条：/Users/dev (过浅)」这种串它会原样退回——那正是 #64 的漏因。
        public func apply(to path: String) -> String {
            if isOff || path.isEmpty { return path }
            // 先项目根后家目录：项目根通常更深（`/Users/dev/Documents/AiX`），
            // 反过来会把 `/Users/dev` 先吃掉，剩下 `~/Documents/AiX` 而不是 `<project>`。
            for root in Self.sortedRoots(projectRoots) where !root.isEmpty {
                guard let rest = Self.strip(root, from: path) else { continue }
                return Self.projectPlaceholder + rest
            }
            if let home, let rest = Self.strip(home, from: path) {
                return Self.homePlaceholder + rest
            }
            return path
        }

        /// 把**任意文本**里嵌着的每一条绝对路径换成占位符形式，其余字符一个字不动。
        ///
        /// 这是 #64 的主干：采集面说明、无障碍汇总、剪贴板转储、导出正文、通知正文
        /// 全都是"路径在句中"的形状，只有这一条能盖住。
        /// 关掉时恒等；命中不了配置前缀的路径（`/etc/hosts`、`/`）也恒等——
        /// 本映射的语义是"把属于这台机器的路径换成占位符"，不是"藏掉一切斜杠"。
        public func scrub(_ text: String) -> String {
            guard !isOff, !text.isEmpty else { return text }
            return PathPrivacy.rewritingRuns(in: text) { [self] run in apply(to: run) }
        }

        /// 剥掉前缀，返回**带前导分隔符**的余下部分；不是该前缀的子孙则返回 nil。
        /// 为什么要"整段边界"而不是 `hasPrefix`：`/Users/deve` 不该被当成 `/Users/dev` 的孩子。
        public static func strip(_ prefix: String, from path: String) -> String? {
            guard path == prefix || path.hasPrefix(prefix) else { return nil }
            let rest = String(path.dropFirst(prefix.count))
            if rest.isEmpty { return "" }
            guard rest.hasPrefix("/") else { return nil }
            return rest
        }

        /// 这条路径落在哪个根里 ⇒ 返回那一个占位符；哪都不落 ⇒ `nil`。
        /// 与 `apply(to:)` 同源（同一份最长优先排序），所以「`nil`」与「`apply` 没改它」是同一件事。
        public func placeholderCovering(_ path: String) -> String? {
            guard !isOff, !path.isEmpty else { return nil }
            for root in Self.sortedRoots(projectRoots) where !root.isEmpty {
                if Self.strip(root, from: path) != nil { return Self.projectPlaceholder }
            }
            if let home, Self.strip(home, from: path) != nil { return Self.homePlaceholder }
            return nil
        }

        /// 占位符感知地取路径末尾若干段——**窄列里放得下，又不撒谎**的那一份。
        ///
        /// 治的病（#89 ①）：`FilePathText` 的「末两级」原来是「先 `apply`、再把结果按 `/` 切两段」。
        /// `apply` 把前缀换成了 `~`，切两段干的第一件事就是把 `~` 扔掉
        /// ⇒ 屏上出现 `Documents/mona`。那不是一个相对路径，它是 `~/Documents/mona` 被截掉了标记，
        /// 而读的人无从知道前面还藏着什么。**开关开着，本机目录结构照样上屏**。
        ///
        /// 三条规则：
        ///  · 映射关闭、或路径不属于任何根 ⇒ 与「按 `/` 取末 `components` 段」**逐字一致**；
        ///  · 整条路径就是那个根（`/Users/dev` → `~`）⇒ 只出占位符，不编造子目录；
        ///  · 被占位符覆盖 ⇒ **占位符永远排在最前**，其下最多再给 `components - 1` 个真名，
        ///    少给的用 `…` 明说（不是悄悄吃掉）。
        ///
        /// 为什么被覆盖时只留一个真名（`components == 2` ⇒ `~/…/mona`）而不是两个：
        /// 这一档的目的是窄列里能区分「哪一条」，占位符 + 末段已经做到；
        /// 多给的那一段属于被遮住的根下面的真实结构，而"要不要露出这层结构"应当由
        /// `middleEllipsis`（完整映射串）与 `.help` 承担，不该由截断模式偷偷决定。
        public func tail(_ path: String, components: Int) -> String {
            guard components > 0 else { return path }
            guard let placeholder = placeholderCovering(path) else {
                return Self.plainTail(apply(to: path), components: components)
            }
            let masked = apply(to: path)
            guard masked != placeholder else { return placeholder }
            let below = masked.dropFirst(placeholder.count).split(separator: "/", omittingEmptySubsequences: true)
            if components == 1 { return below.last.map(String.init) ?? placeholder }
            let kept = below.suffix(components - 1)
            let joined = kept.joined(separator: "/")
            return kept.count == below.count
                ? "\(placeholder)/\(joined)"
                : "\(placeholder)/…/\(joined)"
        }

        /// 不带占位符语义的末段截取（映射关闭时的既有形状，一行都不改）。
        static func plainTail(_ value: String, components: Int) -> String {
            let parts = value.split(separator: "/", omittingEmptySubsequences: true).suffix(components)
            return parts.isEmpty ? value : parts.joined(separator: "/")
        }

        /// 最长优先：嵌套仓库时短的那个不许抢。
        static func sortedRoots(_ roots: [String]) -> [String] {
            roots.count > 1 ? roots.sorted { $0.count > $1.count } : roots
        }
    }
}

extension PathPrivacy.Mask {
    /// 从**启动时解析好的设置**造一份映射。开关关掉 ⇒ `.off`（恒等，输出与今天逐字一致）。
    ///
    /// `home` 留成可注入：默认取宿主家目录，但用例一律显式传合成值——
    /// 一是测试不许依赖跑它的那台机器长什么样，二是本仓门禁 G1/G4 不许源码里出现个人绝对路径
    /// （`NSHomeDirectory()` 属于"断言家目录语义"的合规用法，见 `Scripts/verify.sh` 末尾口径）。
    ///
    /// 监控根要先展开 `~` 再比：用户输的可能是 `~/Documents/AiX`，
    /// 而库里存的是展开后的绝对路径（契约 `PathHeuristics` 在使用处展开），
    /// 不展开就永远匹配不上，占位符形同虚设。
    public static func configured(from settings: ObservatorySettings,
                                  home: String = NSHomeDirectory()) -> PathPrivacy.Mask {
        guard settings.demoRedactedOutput else { return .off }
        return PathPrivacy.Mask(
            home: home,
            projectRoots: settings.monitoredRoots.map { Self.expanded($0, home: home) }
        )
    }

    /// `~` / `~/x` 按**给定的 home** 展开，不用 `NSString.expandingTildeInPath`：
    /// 后者读的是当前进程的家目录，那样用例就没法拿合成家目录测。
    public static func expanded(_ root: String, home: String) -> String {
        if root == "~" { return home }
        guard root.hasPrefix("~/") else { return root }
        return home + root.dropFirst(1)
    }
}
