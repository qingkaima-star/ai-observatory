//
//  DestructiveCommandRules.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Telemetry / WS-Platform（本轮只加「同一条命令一条不漏的粗筛」，分级结果一字未动）
//
//  破坏性命令规则库与分级。实现 `CommandAuditing.classify(command:)` 所需的
//  风险判定：规则库 ≥ 20 条，并检测命令参数中的敏感路径（复用 PathHeuristics.isSensitive）。
//
//  性能口径：`classify` 是个**纯函数**，但它每条命令都要跑一遍全表（33 条规则、其中 31 次
//  `contains` + 2 次正则，再加一次按空格把整条命令行切成 [String]），于是 145 个候选就是
//  17.64 ms（每候选 121 µs）。本文件只做两件事消掉这份常数：
//   · 正则规则先过一段「模式里必须出现的字面量」粗筛（同 `ExportRedactor` 的 triggers 手法，
//     见 ExportRedactor.swift:19-22）——绝大多数命令行因此**一次正则都不发起**；
//   · 把每次调用都在重建的值提到 `static let`（写类动词表 / 引号字符集 / 粗筛表）。
//  没有把 `NSRegularExpression` 存进 `static let`：本车道不许跑编译，无法核实本机 SDK 是否
//  给它标了 `Sendable`；而本仓对同一问题已有明确取舍——不为它动用 `nonisolated(unsafe)`，
//  改用字面量粗筛（ExportRedactor.swift:19-22）。粗筛之后正则的编译成本只在真含
//  curl/wget 的命令行上出现，量级是个位数条。
//

import Foundation
import AIObservatoryCore

/// 破坏性命令规则库与命令分级引擎。
public struct DestructiveCommandRules: Sendable {

    /// 单条规则定义。
    public struct Rule: Sendable, Identifiable {
        public var id: String
        /// 匹配模式：substring 为包含匹配，regex 为正则匹配（均已小写化，大小写不敏感）。
        public var pattern: String
        public var kind: MatchKind
        public var level: RiskLevel
        public var category: RiskCategory
        public var isDestructive: Bool
        public var requiresConfirmation: Bool

        public enum MatchKind: Sendable {
            case substring
            case regex
        }

        public init(id: String, pattern: String, kind: MatchKind, level: RiskLevel, category: RiskCategory,
                    isDestructive: Bool, requiresConfirmation: Bool) {
            self.id = id
            self.pattern = pattern
            self.kind = kind
            self.level = level
            self.category = category
            self.isDestructive = isDestructive
            self.requiresConfirmation = requiresConfirmation
        }
    }

    public init() {}

    /// 完整规则库（≥ 20 条）。小写化以便于大小写不敏感匹配。
    public static let rules: [Rule] = [
        // —— 批量/递归删除 ——
        Rule(id: "rm-recursive-force", pattern: "rm -rf", kind: .substring, level: .high,
             category: .massDeletion, isDestructive: true, requiresConfirmation: true),
        Rule(id: "rm-force-recursive", pattern: "rm -fr", kind: .substring, level: .high,
             category: .massDeletion, isDestructive: true, requiresConfirmation: true),
        Rule(id: "rm-recursive", pattern: "rm -r ", kind: .substring, level: .medium,
             category: .massDeletion, isDestructive: true, requiresConfirmation: true),
        Rule(id: "rm-recursive-cap", pattern: "rm -r\t", kind: .substring, level: .medium,
             category: .massDeletion, isDestructive: true, requiresConfirmation: true),
        Rule(id: "rm-big-r", pattern: "rm -R ", kind: .substring, level: .medium,
             category: .massDeletion, isDestructive: true, requiresConfirmation: true),
        Rule(id: "crontab-remove", pattern: "crontab -r", kind: .substring, level: .high,
             category: .massDeletion, isDestructive: true, requiresConfirmation: true),

        // —— 原始磁盘写入 ——
        Rule(id: "dd-if", pattern: "dd if=", kind: .substring, level: .critical,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),
        Rule(id: "dd-of-dev", pattern: "dd of=/dev/", kind: .substring, level: .critical,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),
        Rule(id: "mkfs", pattern: "mkfs", kind: .substring, level: .critical,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),

        // —— 重定向覆写块设备 ——
        Rule(id: "redirect-disk", pattern: "> /dev/disk", kind: .substring, level: .critical,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),
        Rule(id: "redirect-rdisk", pattern: "> /dev/rdisk", kind: .substring, level: .critical,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),

        // —— 远程代码执行 ——
        Rule(id: "curl-pipe-shell", pattern: #"curl[ \t].*\|.*(sh|bash|zsh)"#, kind: .regex, level: .high,
             category: .dangerousCommand, isDestructive: false, requiresConfirmation: true),
        Rule(id: "wget-pipe-shell", pattern: #"wget[ \t].*\|.*(sh|bash|zsh)"#, kind: .regex, level: .high,
             category: .dangerousCommand, isDestructive: false, requiresConfirmation: true),

        // —— 权限变更 ——
        Rule(id: "chmod-777-recursive", pattern: "chmod -r 777", kind: .substring, level: .high,
             category: .privilegeEscalation, isDestructive: false, requiresConfirmation: true),
        Rule(id: "chmod-777", pattern: "chmod 777", kind: .substring, level: .medium,
             category: .privilegeEscalation, isDestructive: false, requiresConfirmation: true),
        Rule(id: "chown-recursive", pattern: "chown -r", kind: .substring, level: .medium,
             category: .privilegeEscalation, isDestructive: false, requiresConfirmation: true),

        // —— 提权 ——
        Rule(id: "sudo", pattern: "sudo", kind: .substring, level: .medium,
             category: .privilegeEscalation, isDestructive: false, requiresConfirmation: true),
        Rule(id: "csrutil-disable", pattern: "csrutil disable", kind: .substring, level: .critical,
             category: .privilegeEscalation, isDestructive: true, requiresConfirmation: true),

        // —— Git 危险操作 ——
        Rule(id: "git-push-force", pattern: "git push --force", kind: .substring, level: .high,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),
        Rule(id: "git-push-f", pattern: "git push -f", kind: .substring, level: .high,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),

        // —— 系统服务与配置 ——
        Rule(id: "launchctl-unload", pattern: "launchctl unload", kind: .substring, level: .medium,
             category: .systemFileModification, isDestructive: false, requiresConfirmation: false),
        Rule(id: "launchctl-load", pattern: "launchctl load", kind: .substring, level: .medium,
             category: .systemFileModification, isDestructive: false, requiresConfirmation: false),
        Rule(id: "defaults-delete", pattern: "defaults delete", kind: .substring, level: .medium,
             category: .systemFileModification, isDestructive: true, requiresConfirmation: true),

        // —— 进程终止 ——
        Rule(id: "killall-9", pattern: "killall -9", kind: .substring, level: .high,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),
        Rule(id: "kill-9", pattern: "kill -9", kind: .substring, level: .high,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),

        // —— 磁盘工具 ——
        Rule(id: "diskutil-erasedisk", pattern: "diskutil erasedisk", kind: .substring, level: .critical,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),
        Rule(id: "diskutil-zerodisk", pattern: "diskutil zerodisk", kind: .substring, level: .critical,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),
        Rule(id: "diskutil-partitiondisk", pattern: "diskutil partitiondisk", kind: .substring, level: .critical,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true),

        // —— 关机/重启/分叉炸弹 ——
        Rule(id: "shutdown", pattern: "shutdown", kind: .substring, level: .critical,
             category: .systemFileModification, isDestructive: true, requiresConfirmation: true),
        Rule(id: "reboot", pattern: "reboot", kind: .substring, level: .critical,
             category: .systemFileModification, isDestructive: true, requiresConfirmation: true),
        Rule(id: "halt", pattern: "halt", kind: .substring, level: .critical,
             category: .systemFileModification, isDestructive: true, requiresConfirmation: true),
        Rule(id: "fork-bomb", pattern: ":(){", kind: .substring, level: .critical,
             category: .resourceAbuse, isDestructive: true, requiresConfirmation: true),

        // —— 危险截断 ——
        Rule(id: "truncate-zero", pattern: "truncate -s 0", kind: .substring, level: .medium,
             category: .dangerousCommand, isDestructive: true, requiresConfirmation: true)
    ]

    // MARK: - 每次调用都在重建、其实一次就够的东西

    /// 一条规则配上它的粗筛字面量。字段全是值类型 ⇒ 整张表可以放进 `static let`。
    private struct MatchableRule: Sendable {
        let rule: Rule
        /// 仅 `.regex` 规则可能有值：该模式匹配时文本里**必然出现**的一段字面量。
        /// `nil` 表示这条要么不参与正则、要么开头就是元字符而粗筛不了。
        let regexLiteral: String?
    }

    /// 匹配用的表：与 `rules` **同序**（分级取最高风险时，同分按表序先出现者胜，顺序即语义）。
    /// 成员之间互访写成限定名，是为了让这张表的初始化只依赖 `rules` 这一个常量。
    private static let matchableRules: [MatchableRule] = DestructiveCommandRules.rules.map { rule in
        MatchableRule(
            rule: rule,
            regexLiteral: rule.kind == .regex
                ? DestructiveCommandRules.literalPrefix(ofPattern: rule.pattern) : nil
        )
    }

    /// 只有这些「写类动词」开头的命令才参与敏感路径判定。
    ///
    /// 提到 `static let` 前它是一条**每次调用**都要重新分配的字面量数组，
    /// 而且判定用的是 `Array.contains`（逐个字符串比较）；换成集合后是 O(1)。
    /// 语义不变：仍然是「basename 是否等于其中之一」。
    private static let writeVerbs: Set<String> = [
        "rm", "mv", "cp", "dd", "chmod", "chown", "touch", "truncate", "ln", "tee", "rsync"
    ]

    /// `detectSensitivePath` 要剥掉的引号字符集（原来每次调用现场构造一个 `CharacterSet`）。
    private static let quoteCharacters = CharacterSet(charactersIn: "\"'")

    /// 取一条正则模式**开头那段纯字面量**，用作「文本里必须出现」的粗筛条件。
    ///
    /// 为什么可以这么筛：这些模式都未锚定，要匹配就必须在某个位置整段出现这段字面量——
    /// 所以「字面量不在」是「模式不匹配」的充分条件，粗筛**不可能**改变任何一条命令的分级。
    /// 两处保守：
    ///  · 一遇元字符（`. ^ $ * [ ] | ( ) { } ? + \ \`）就停，后面的部分一概不要——
    ///    特别是 `.`：它匹配任意字符，把 `x.y` 当字面量筛会漏掉 `xay`，那才是真改变分级；
    ///  · 若元字符是量词（`*` `+` `?` `{`），把最后一个字面字符也去掉——`cu?rl` 能匹配
    ///    `crl`，此时 "cu" 不是必要条件而 "c" 是。
    /// - Returns: 可用于粗筛的字面量；返回 `nil` 表示这条模式粗筛不了（照旧每次都真跑正则）。
    private static func literalPrefix(ofPattern pattern: String) -> String? {
        var literal = ""
        var index = pattern.startIndex
        while index < pattern.endIndex {
            let character = pattern[index]
            if "^$.[]|?*+(){}\\".contains(character) { break }
            literal.append(character)
            index = pattern.index(after: index)
        }
        // 量词作用在它前面那个字符上 ⇒ 那个字符不是必需的，一并让掉。
        if !literal.isEmpty, index < pattern.endIndex, "*+?{".contains(pattern[index]) {
            literal.removeLast()
        }
        // 粗筛比的是 `classify` 里那份**已小写**的文本（`matches` 也拿这份），所以字面量
        // 必须同样小写——否则将来加一条含大写的 `.regex` 模式，粗筛会把该命中的命令筛掉，
        // 那是漏判而不是慢判。当前表内两条（curl/wget）本来就是小写，这一步对它们恒等。
        return literal.isEmpty ? nil : literal.lowercased()
    }

    /// 判定命令的破坏性等级。取命中的最高风险规则；无规则命中时再检测敏感路径参数。
    public func classify(command: String) -> CommandClassification {
        let lowered = command.lowercased()
        var best: Rule?
        // 走 `matchableRules` 而不是 `rules`：**同序**，所以「同分先表序者胜」的裁决不变。
        for candidate in Self.matchableRules {
            // 粗筛：这段字面量是该正则模式匹配的**必要条件**，文本里没有 ⇒ 必然不匹配，
            // 于是这一条连一次正则都不必发起（可靠性论证见 `literalPrefix(ofPattern:)`）。
            if let literal = candidate.regexLiteral, !lowered.contains(literal) { continue }
            if matches(rule: candidate.rule, text: lowered) {
                if let current = best {
                    if candidate.rule.level.rank > current.level.rank { best = candidate.rule }
                } else {
                    best = candidate.rule
                }
            }
        }

        // 无显式规则命中时，若命令是写类操作且参数命中敏感路径，则升级为敏感目录访问。
        if best == nil, let sensitive = detectSensitivePath(command: lowered) {
            return CommandClassification(
                isDestructive: true,
                requiresConfirmation: true,
                level: sensitive,
                category: .sensitivePathAccess
            )
        }

        guard let matched = best else { return .benign }
        return CommandClassification(
            isDestructive: matched.isDestructive,
            requiresConfirmation: matched.requiresConfirmation,
            level: matched.level,
            category: matched.category
        )
    }

    // MARK: - 匹配辅助

    private func matches(rule: Rule, text: String) -> Bool {
        switch rule.kind {
        case .substring:
            return text.contains(rule.pattern)
        case .regex:
            return (text as NSString).range(of: rule.pattern, options: .regularExpression).location != NSNotFound
        }
    }

    /// 仅对写类命令检测其参数是否命中敏感路径（复用契约中的 `PathHeuristics.isSensitive`）。
    ///
    /// 这条是 `classify` 里唯一「每条**良性**命令都会走到」的一段（规则没命中就来这儿再试一次），
    /// 所以它的分配成本直接乘在候选数上。改法只做两件不改判定结果的事：
    ///  · head 用 `drop(while:)` / `prefix(while:)` 就地取，先不为整条命令行切出数组；
    ///  · 参数逐个过一遍**必要条件**再分配：`PathHeuristics.sensitivePrefixes` 全是绝对路径，
    ///    而 `expandingTildeInPath` 只会把开头的 `~` 换掉、不会凭空造出 `/` ⇒ 去掉引号之后
    ///    既不以 `/` 也不以 `~` 开头的参数必然不命中，直接跳过，不必为它构造 String。
    private func detectSensitivePath(command: String) -> RiskLevel? {
        // `split` 默认丢掉空片段 ⇒ head 是「第一段非空白」；下面用 drop/prefix 取到同一个值。
        let head = command.drop { $0 == " " }.prefix { $0 != " " }
        guard !head.isEmpty else { return nil }
        let basename = URL(fileURLWithPath: String(head)).lastPathComponent.lowercased()
        guard Self.writeVerbs.contains(basename) else { return nil }

        // 与改前一样：连 head 自己在内，每个参数都参与判定。
        for token in command.split(separator: " ") {
            let trimmedHead = token.drop { $0 == "\"" || $0 == "'" }
            guard trimmedHead.first == "/" || trimmedHead.first == "~" else { continue }
            let path = String(token).trimmingCharacters(in: Self.quoteCharacters)
            if PathHeuristics.isSensitive(path) {
                return .high
            }
        }
        return nil
    }
}
