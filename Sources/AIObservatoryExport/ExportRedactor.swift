//
//  ExportRedactor.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（子代理 D）
//
//  导出层唯一的「凭据形态」脱敏器：JSON / CSV / Markdown 写盘前，命令参数、文件路径、
//  风险详情等自由文本都过这里，把秘钥形态替换成 `‹redacted:kind›`，原始值一个字符都不留。
//
//  设计约束（与导出层接口 §0 / §2-D 对齐）：
//  1. **只掩值、保留键名**：`password=hunter2` → `password=‹redacted:password_assignment›`，
//     CSV/JSON 侧仍可按键分析；
//  2. **幂等**：任何规则都不会吃掉一个已成型占位符的开头（见 `isAlreadyRedacted`），
//     所以 `redact(redact(x)) == redact(x)`；
//  3. **重叠择优**：规则按「具体度」排序（数组下标即优先级），重叠时先落地的区间覆盖后到的，
//     于是 `.env` 的 `KEY=sk-…` 归 `openai_key` 而非泛化的 `env_file_value`，
//     `Authorization: Bearer sk-…` 整段归 `authorization_header`；被跳过的候选区间必然
//     完全落在已接受区间之内，故不会有凭据片段残留；
//  4. **纯值语义**：规则表是 `String` 字面量 + `UInt` 选项，`ExportRedactor` 因此天然 `Sendable`，
//     可以作为 `static let` 被后台导出队列共享；正则在每次调用时按需编译（并用小写字面量粗筛，
//     绝大多数无凭据字段一条正则都不用编译），从而避免对非 `Sendable` 的
//     `NSRegularExpression` 使用 `nonisolated(unsafe)`；
//  5. 不读墙钟、不 `try!`、不 `@unchecked Sendable`、不改写调用方传入的字面量之外的任何字节。
//

import Foundation
import AIObservatoryCore

/// 被识别的凭据形态。`rawValue` 是稳定 ASCII，直接出现在占位符里，属于导出文件的一部分。
public enum RedactionKind: String, Codable, Sendable, CaseIterable, Hashable {
    /// `sk-…` / `sk-proj-…`（OpenAI 风格）。
    case openAIKey = "openai_key"
    /// `ghp_…` / `gho_…` / `github_pat_…`。
    case githubToken = "github_token"
    /// `AKIA` + 16 位大写基数字（AWS access key id）。
    case awsAccessKey = "aws_access_key"
    /// `xoxb-…` / `xoxp-…` / `xapp-…`。
    case slackToken = "slack_token"
    /// `-----BEGIN … PRIVATE KEY-----` 整段（含 base64 正文与结尾行）。
    case privateKey = "private_key"
    /// `Authorization: …` 冒号之后的整个值（键名保留）。
    case authorizationHeader = "authorization_header"
    /// 裸 `Bearer <token>`（`Bearer` 前缀保留）。
    case bearerToken = "bearer_token"
    /// `password=` / `passwd=` / `pwd=` 的值。
    case passwordAssignment = "password_assignment"
    /// `token=` / `access_token=` / `api_key=` / `key=` 的值。
    case tokenAssignment = "token_assignment"
    /// `.env` 形态行的值（键名含 SECRET/KEY/TOKEN/… 但值本身不匹配更具体形态时）。
    case envFileValue = "env_file_value"
    /// `sk_live_…` / `sk_test_…`（Stripe 风格，与 `sk-` 规则天然不冲突）。
    case stripeSecret = "stripe_secret"
}

/// 导出脱敏器。无共享可变状态；同一实例可被多个导出任务并发调用。
public struct ExportRedactor: Sendable {
    /// 启用全部规则的默认实例（`ExportRequest.redactionEnabled == true` 时使用）。
    ///
    /// 不含路径映射 ⇒ 导出件里的绝对路径**原样保留**（今天的行为）。
    /// 需要演示/脉敏输出时用 `standard(pathMask:)`，别在调用方再拼一份字符串处理——
    /// #64 的教训就是"界面遮一份、导出另算一份"，最后哪份都没算全。
    public static let standard = ExportRedactor(enabled: true)

    /// 关闭脱敏的实例：`redact` 原样返回，用于用户显式确认风险的场景。
    public static let disabled = ExportRedactor(enabled: false)

    /// 带路径映射的实例（#64）：凭据照旧折，**另外**把属于这台机器的路径换成占位符。
    /// 映射关掉（`.off`）时与 `standard` 逐字一致。
    public static func standard(pathMask: PathPrivacy.Mask) -> ExportRedactor {
        ExportRedactor(enabled: true, pathMask: pathMask)
    }

    /// #64 ③：这份导出件里的路径**有没有**被换成占位符。
    /// 报告页脚要用它写一行可审计的提示——"不脱敏"不许静默（与 CLI 侧 `--no-redact` 同一条口径）。
    public var isPathMasked: Bool { !pathMask.isOff }

    /// 是否生效。`false` 时 `redact` 为恒等映射（`detectedKinds(in:)` 仍会报告命中，便于预检）。
    public var isEnabled: Bool { self.enabled }

    /// #64：导出件里的路径映射。默认 `.off` = 恒等 ⇒ 不传就和今天逐字一致。
    private let pathMask: PathPrivacy.Mask
    private let enabled: Bool
    private let rules: [Rule]

    /// 私有构造：只有 `standard` / `disabled` 两种装配，避免调用方造出半开状态。
    private init(enabled: Bool, pathMask: PathPrivacy.Mask = .off) {
        self.enabled = enabled
        self.pathMask = pathMask
        self.rules = Self.ruleTable
    }

    // MARK: - Public API

    /// 用 `ExportConstants` 的前后缀拼出占位符，例如 `‹redacted:openai_key›`。
    public static func placeholder(for kind: RedactionKind) -> String {
        ExportConstants.redactionPrefix + kind.rawValue + ExportConstants.redactionSuffix
    }

    /// 脱敏一段文本。无凭据且无路径映射命中时**逐字符原样返回**（含中文、emoji、组合字符、`|`、`,`、`"`、反斜杠）。
    public func redact(_ text: String) -> String {
        let stripped = stripCredentials(text)
        // 顺序：**先折凭据、再换路径占位符**。反过来会让凭据正则看见被改写的串，
        // 而占位符 `‹redacted:…›` 不含 `/`，`scrub` 对它恒等 ⇒ 两步互不干扰。
        return pathMask.scrub(stripped)
    }

    private func stripCredentials(_ text: String) -> String {
        guard self.isEnabled, !text.isEmpty else { return text }
        let accepted = self.acceptedCandidates(in: text)
        guard accepted.isEmpty == false else { return text }

        var result = ""
        result.reserveCapacity(text.utf16.count + accepted.count * 16)
        var cursor = text.startIndex
        for candidate in accepted {
            if candidate.range.lowerBound > cursor {
                result += text[cursor..<candidate.range.lowerBound]
            }
            result += Self.placeholder(for: candidate.kind)
            cursor = candidate.range.upperBound
        }
        if cursor < text.endIndex {
            result += text[cursor...]
        }
        return result
    }

    /// 可选文本：`nil` 原样为 `nil`，非 `nil` 走 `redact(_:)`。
    public func redact(_ text: String?) -> String? {
        guard let text else { return nil }
        return self.redact(text)
    }

    /// 命中的全部形态：按首次出现位置排序、去重（重叠计数允许，故 `Authorization: Bearer sk-…`
    /// 会同时报告 `authorization_header`、`bearer_token`、`openai_key`）。
    public func detectedKinds(in text: String) -> [RedactionKind] {
        guard !text.isEmpty else { return [] }
        let ordered = self.candidates(in: text).sorted { Self.firstAppearanceOrder($0, $1) }
        var seen = Set<RedactionKind>()
        var result: [RedactionKind] = []
        for candidate in ordered where seen.insert(candidate.kind).inserted {
            result.append(candidate.kind)
        }
        return result
    }

    // MARK: - Matching internals

    /// 单条规则。全部字段为值类型，故 `Rule` 是 `Sendable`，整张表可以放进 `static let`。
    private struct Rule: Sendable {
        let kind: RedactionKind
        let pattern: String
        /// 参与替换的捕获组编号；`0` 表示整段匹配本身就是凭据。
        let valueGroup: Int
        /// `NSRegularExpression.Options` 的原始位掩码（存 `UInt` 以保持 `Sendable`）。
        let options: UInt
        /// 粗筛字面量（小写）：文本小写后不含其中任何一个，则该规则不参与、也不编译正则。
        let triggers: [String]
        /// 规则表下标即优先级，越小越具体、越先落地。
        let priority: Int
    }

    /// 一次候选命中：`location` / `end` 为 UTF-16 码元（用于重叠判定），`range` 为 String 区间（用于切片）。
    private struct Candidate {
        let kind: RedactionKind
        let priority: Int
        let matchLocation: Int
        let location: Int
        let end: Int
        let range: Range<String.Index>
    }

    /// 规则表：顺序 = 具体度优先级。修改顺序会改变重叠裁决结果，请连带复核测试。
    private static let ruleTable: [Rule] = {
        let caseInsensitive = NSRegularExpression.Options.caseInsensitive.rawValue
        let multilineAnchors = NSRegularExpression.Options.anchorsMatchLines.rawValue
        let table: [(RedactionKind, String, Int, UInt, [String])] = [
            (.privateKey,
             #"-----BEGIN[A-Z0-9 _-]*PRIVATE KEY-----[\s\S]*?(?:-----END[A-Z0-9 _-]*PRIVATE KEY-----|$)"#,
             0, caseInsensitive, ["-----begin"]),
            (.authorizationHeader,
             // 值延伸到「结构分隔符」为止（`,` `;` `&` 引号 反引号 换行），
             // 不再一路吞到行尾 —— 否则 `curl -H "Authorization: …" -d password=…` 里
             // 后半段的审计证据会被过度脱敏整段抹掉（隐私仍优先：宁可多掩不可漏，但不许吞掉相邻字段）。
             #"\bauthorization[ \t]*:([ \t]*[^\r\n,;&\x22\x27\x60]+)"#,
             1, caseInsensitive, ["authorization"]),
            (.stripeSecret,
             #"(?<![A-Za-z0-9])sk_(?:live|test)_[A-Za-z0-9_]{16,}"#,
             0, 0, ["sk_live_", "sk_test_"]),
            (.openAIKey,
             #"(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{16,}"#,
             0, 0, ["sk-"]),
            (.githubToken,
             #"(?<![A-Za-z0-9])(?:gh[pousr]_[A-Za-z0-9_]{16,}|github_pat_[A-Za-z0-9_]{16,})"#,
             0, 0, ["ghp_", "gho_", "ghu_", "ghs_", "ghr_", "github_pat_"]),
            (.awsAccessKey,
             #"AKIA[A-Z0-9]{16,}"#,
             0, 0, ["akia"]),
            (.slackToken,
             #"(?<![A-Za-z0-9])(?:xox[baprs]|xapp)-[A-Za-z0-9_-]{6,}"#,
             0, 0, ["xoxb-", "xoxp-", "xoxa-", "xoxr-", "xoxs-", "xapp-"]),
            (.bearerToken,
             #"\bbearer[ \t]+([A-Za-z0-9._~+/=-]{3,})"#,
             1, caseInsensitive, ["bearer"]),
            (.passwordAssignment,
             #"(?<![A-Za-z0-9_])(?:password|passwd|pwd)[ \t]*=([ \t]*(?:\x22[^\x22]*\x22|'[^']*'|[^\s,;&\x22\x60]+))"#,
             1, caseInsensitive, ["password", "passwd", "pwd"]),
            (.tokenAssignment,
             #"(?<![A-Za-z0-9_])(?:access_token|refresh_token|id_token|auth_token|api_key|apikey|secret_key|client_secret|token|secret|key)[ \t]*=([ \t]*(?:\x22[^\x22]*\x22|'[^']*'|[^\s,;&\x22\x60]+))"#,
             1, caseInsensitive, ["token", "key", "secret"]),
            // 键名必须是「整段 SCREAMING_SNAKE 片段」命中敏感词（`SOME_KEY`、`DB_PASSWORD`），
            // 这样 `monkey=banana`、`KEYRING=unset` 这类正常文本不会被误伤；值必须含非空白字符。
            (.envFileValue,
             #"^[ \t]*(?:export[ \t]+)?(?:[A-Za-z0-9]+_)*(?:SECRET|KEY|TOKEN|PASSWORD|PASSWD|PWD|AUTH|CREDENTIAL|CERT)(?:_[A-Za-z0-9]+)*[ \t]*=([ \t]*\S[^\r\n]*)"#,
             1, caseInsensitive | multilineAnchors, ["="]),
        ]
        return table.enumerated().map { index, entry in
            Rule(kind: entry.0, pattern: entry.1, valueGroup: entry.2, options: entry.3,
                 triggers: entry.4, priority: index)
        }
    }()

    /// 收集全部规则的候选命中（不做重叠裁决），已脱敏区间与无法安全转换 UTF-16 区间的候选被丢弃。
    private func candidates(in text: String) -> [Candidate] {
        let source = text as NSString
        let haystack = text.lowercased()
        let fullRange = NSRange(location: 0, length: source.length)
        var result: [Candidate] = []
        result.reserveCapacity(8)

        for rule in self.rules {
            guard rule.triggers.contains(where: { haystack.range(of: $0) != nil }) else { continue }
            guard let expression = Self.expression(for: rule) else { continue }
            for match in expression.matches(in: text, options: [], range: fullRange) {
                let target = match.range(at: rule.valueGroup)
                guard target.location != NSNotFound, target.length > 0 else { continue }
                // 幂等保护：值（去掉前导空白）已经是占位符开头则跳过，绝不二次包裹。
                guard Self.isAlreadyRedacted(source.substring(with: target)) == false else { continue }
                guard let range = Self.stringRange(for: target, in: text, utf16Length: source.length)
                else { continue }   // 字素边界无法对齐：跳过该 match，不崩溃
                result.append(Candidate(kind: rule.kind, priority: rule.priority,
                                        matchLocation: match.range.location,
                                        location: target.location,
                                        end: target.location + target.length,
                                        range: range))
            }
        }
        return result
    }

    /// 重叠裁决：按（优先级, 匹配起点, 区间长度降序）依次落地，与已选区间相交者丢弃。
    private func acceptedCandidates(in text: String) -> [Candidate] {
        let ordered = self.candidates(in: text).sorted { Self.selectionOrder($0, $1) }
        var accepted: [Candidate] = []
        accepted.reserveCapacity(ordered.count)
        for candidate in ordered {
            let conflicts = accepted.contains { candidate.location < $0.end && $0.location < candidate.end }
            if conflicts == false { accepted.append(candidate) }
        }
        return accepted.sorted { lhs, rhs in lhs.location < rhs.location }
    }

    /// 选择顺序：越具体越先、越靠前越先、越长越先；末位以 kind 保证严格全序（结果确定性）。
    private static func selectionOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.priority != rhs.priority { return lhs.priority < rhs.priority }
        if lhs.matchLocation != rhs.matchLocation { return lhs.matchLocation < rhs.matchLocation }
        let lhsLength = lhs.end - lhs.location
        let rhsLength = rhs.end - rhs.location
        if lhsLength != rhsLength { return lhsLength > rhsLength }
        if lhs.location != rhs.location { return lhs.location < rhs.location }
        return lhs.kind.rawValue < rhs.kind.rawValue
    }

    /// 报告顺序：按凭据在原句中的出现位置，同位置按具体度。
    private static func firstAppearanceOrder(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
        if lhs.matchLocation != rhs.matchLocation { return lhs.matchLocation < rhs.matchLocation }
        return selectionOrder(lhs, rhs)
    }

    /// 常量模式编译。失败只可能是规则表自身笔误（测试会覆盖每条规则）；
    /// 这里返回 `nil` 让调用方跳过该条规则，而不是 `try!` 崩溃整次导出。
    private static func expression(for rule: Rule) -> NSRegularExpression? {
        let options = NSRegularExpression.Options(rawValue: rule.options)
        return try? NSRegularExpression(pattern: rule.pattern, options: options)
    }

    /// 值（忽略前导空白）是否已以占位符前缀开头。
    private static func isAlreadyRedacted(_ value: String) -> Bool {
        value.drop { $0 == " " || $0 == "\t" }.hasPrefix(ExportConstants.redactionPrefix)
    }

    /// UTF-16 区间 → `String` 区间。端点落在字素簇中间时 `Range(_:in:)` 返回 `nil`，
    /// 此时最多向外推 2 个码元（一个代理对的宽度）重试——宁可多掩一码元，也不留下残片；
    /// 仍失败则返回 `nil`，由调用方跳过该 match。
    private static func stringRange(for target: NSRange, in text: String,
                                    utf16Length: Int) -> Range<String.Index>? {
        let upper = target.location + target.length
        for shift in 0...2 {
            let lower = max(0, target.location - shift)
            let limit = min(utf16Length, upper + shift)
            guard limit > lower else { continue }
            if let range = Range(NSRange(location: lower, length: limit - lower), in: text) {
                return range
            }
        }
        return nil
    }
}
