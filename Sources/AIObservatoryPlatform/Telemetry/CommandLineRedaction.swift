//
//  CommandLineRedaction.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Engine / ws-engaudit
//
//  命令行 argv 的**凭据脱敏**，落点在「argv 被转成可持久化记录」的那一刻
//  （`CommandInferenceEngine.inferCommands` 与 `AgentHookEvent.commandRecord`）。
//  AGENTS §7 写的是「禁止采集……密钥」，而 argv 里躺着 `Authorization: Bearer sk-…`、
//  `-u user:pass`、`--password=x`、`AWS_SECRET_ACCESS_KEY=…` 这类东西：真机自查
//  （2026-09-21，release 包 UUID `67EC68FA-1390-3594-BDFD-799A516CCAE8`）证实四种形态
//  全部原样进了 `commands.arguments_json`，并顺带进了 `commands.search_text` 与
//  `events` 的 title/command/search_text——那些行会随导出流到用户交给别人的文件里。
//
//  ## 三条不变式（每条都有用例钉着，见 Tests/…/CommandLineRedactionTests.swift）
//
//  1. **脱敏不是删数据**：参数个数、顺序、命令名、被遮蔽的位置全部保留。
//     审计要能回答「跑过一条带 `Authorization` 头的 curl」，只是拿不到那把 key。
//     判据里绝不允许出现「含敏感词就整条不存」——那是把审计事实一起丢掉。
//  2. **幂等**：`redact(redact(x)) == redact(x)`。占位符 `‹redacted:kind›` 里的字符
//     落在凭据字符集之外（`‹›` 不是），且 `redact` 开头还有一道 `isAlreadyRedacted` 短路，
//     所以第二遍扫到同一个位置时什么也不掩。
//  3. **只掩值、保留键名**：与导出层 `ExportRedactor` 同一词汇（`‹redacted:kind›`），
//     两边不各造一套标记。
//
//  ## 为什么不在导出层解决
//
//  `ExportRedactor` 是**文本**形态的脱敏器，只在写导出文件那一刻生效，而且用户可以关掉
//  （`ExportRequest.redactionEnabled == false` 是设计能力）。数据库里的原文一旦落下就永远在：
//  留存期默认 30 天、迁移会带着走、`search_text` 也已经是派生好的列。
//  凭据必须**在入库之前**就不是明文。两层因此互补，不重复：这一层管「库里就没有」，
//  导出那层管「连路径、用户名这类审计对象也一并掩掉凭据形态」。
//  漂移风险如实记在这里：两张规则表分处两个模块，`Package.swift` 是冻结区、
//  Platform 依赖只有 `AIObservatoryCore`（见其 target 声明），拿不到 `AIObservatoryExport`，
//  所以规则表无法共用一份。合入后应由总控决定把凭据形态词汇收到 Core 还是 Export。
//
//  ## 不做的事
//
//  不用 `NSRegularExpression`：本仓对它的 `Sendable` 已有明确取舍（见
//  `DestructiveCommandRules.swift` 文件头），而这里要的只是「找子串 + 吃字符集」，
//  手写扫描比正则更好证明幂等与区间不重叠。
//

import Foundation

/// 命令行 argv 的凭据脱敏器。纯函数、无共享可变状态。
public enum CommandLineRedaction {

    /// 占位符前后缀，与 `ExportConstants.redactionPrefix/Suffix` 逐字一致。
    static let placeholderPrefix = "‹redacted:"
    static let placeholderSuffix = "›"

    /// 一条被掩掉的凭据的形态（rawValue 是稳定 ASCII，直接进占位符）。
    public enum Marker: String, CaseIterable, Sendable, Hashable {
        /// `Authorization` / `X-API-Key` 这类头里冒号之后的值（scheme 词保留）。
        case authorizationHeader = "authorization_header"
        /// 裸 `Bearer <token>` / `Basic <credentials>`（scheme 词保留）。
        case bearerToken = "bearer_token"
        /// `sk-…` / `sk-proj-…` / `sk_live_…`（OpenAI 风格）。
        case openAIKey = "openai_key"
        /// `ghp_…` / `gho_…` / `github_pat_…`。
        case githubToken = "github_token"
        /// `AKIA…` / `ASIA…`（AWS access key id）。
        case awsAccessKey = "aws_access_key"
        /// `xoxb-…` / `xoxp-…` / `xapp-…`。
        case slackToken = "slack_token"
        /// `AIza…`（Google API key）。
        case googleAPIKey = "google_api_key"
        /// `--password=` / `-u` 之类命令行开关的口令值。
        case passwordAssignment = "password_assignment"
        /// `--token=` / `--api-key=` 之类命令行开关的 key 值。
        case tokenAssignment = "token_assignment"
        /// 内联环境变量赋值 `AWS_SECRET_ACCESS_KEY=…`（键名像凭据、值形态不特定）。
        case envFileValue = "env_file_value"
        /// `-u user:pass` / `scheme://user:pass@host` 里冒号之后的口令（用户名保留）。
        case basicAuth = "basic_auth"

        /// 重叠区间的择优权重：数字越小越具体，越先被接受。
        ///
        /// 与导出层同一条取向：`api_key=sk-…` 归 `openai_key`（形态特定的键赢过泛化的赋值形态）。
        /// 一处**刻意**差别：`Authorization: Bearer sk-…` 这里留下
        /// `Authorization: Bearer ‹redacted:openai_key›`，而导出层把冒号之后整段归
        /// `authorization_header`——库里这一层要保住「哪个头、哪种 scheme」这类审计事实。
        var precedence: Int {
            switch self {
            case .openAIKey, .githubToken, .awsAccessKey, .slackToken, .googleAPIKey: 0
            case .authorizationHeader: 1
            case .bearerToken, .passwordAssignment, .tokenAssignment, .envFileValue, .basicAuth: 2
            }
        }
    }

    /// 占位符文本，例如 `‹redacted:openai_key›`。
    public static func placeholder(for marker: Marker) -> String {
        placeholderPrefix + marker.rawValue + placeholderSuffix
    }

    // MARK: - 主入口

    /// 掩掉一条 argv 里的凭据。
    ///
    /// - 返回数组与入参**等长**、逐位置对应；不需要改的元素**逐字符原样**返回
    ///   （不 trim、不改引号、不动大小写）。
    /// - `--password x` 这类「值在下一个元素里」的开关：只有**紧跟其后的那一个**元素被掩
    ///   （空的就不掩，状态照样消费掉，绝不外溢到再下一个参数）。
    /// - `-u user:pass` 分写时保留 `user:` 那半截，只掩口令。
    public static func redact(arguments: [String]) -> [String] {
        guard !arguments.isEmpty else { return [] }
        var result: [String] = []
        result.reserveCapacity(arguments.count)
        var pending: Marker?
        for argument in arguments {
            if let marker = pending {
                pending = nil
                if !argument.isEmpty {
                    result.append(maskValue(argument, as: marker))
                    continue
                }
            }
            result.append(redact(argument))
            pending = standaloneValueFlag(in: argument)
        }
        return result
    }

    /// 掩掉一段自由文本里的凭据形态（单个 argv 元素，或 hook 自然键里的那条命令行）。
    ///
    /// 无凭据时逐字符原样返回；已含占位符的文本原样返回（幂等）。
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty, !isRedacted(text) else { return text }
        let regions = maskRegions(in: text)
        guard !regions.isEmpty else { return text }
        var result = ""
        result.reserveCapacity(text.utf8.count + regions.count * 24)
        var cursor = text.startIndex
        for region in regions {
            if region.range.lowerBound > cursor {
                result += text[cursor..<region.range.lowerBound]
            }
            result += placeholder(for: region.marker)
            cursor = region.range.upperBound
        }
        if cursor < text.endIndex {
            result += text[cursor...]
        }
        return result
    }

    /// 文本里出现的凭据形态，按首次出现位置排序、去重。
    ///
    /// 界面提示与测试都用它回答「这条命令里确有凭据」，而不是靠人读一遍。
    public static func markers(in text: String) -> [Marker] {
        var seen: Set<Marker> = []
        var result: [Marker] = []
        for region in maskRegions(in: text) where seen.insert(region.marker).inserted {
            result.append(region.marker)
        }
        return result
    }

    /// 是否已经是脱敏后的文本（含任意占位符）。
    public static func isRedacted(_ text: String) -> Bool {
        text.range(of: placeholderPrefix) != nil
    }

    // MARK: - 内部：区域扫描

    /// 文本里一段待掩区域。
    struct Region: Sendable {
        var range: Range<String.Index>
        var marker: Marker
    }

    /// 扫出全部候选区域，按「具体形态优先、同权重取更靠左」择优，返回互不重叠、按位置升序的区域。
    ///
    /// 被跳过的候选必然落在已接受区间之内 ⇒ 不会有凭据片段从缝里漏出去。
    static func maskRegions(in text: String) -> [Region] {
        guard !text.isEmpty, !isRedacted(text) else { return [] }
        var candidates: [Region] = []
        candidates += shapeRegions(in: text)
        candidates += headerRegions(in: text)
        candidates += schemeRegions(in: text)
        candidates += assignmentRegions(in: text)
        candidates += credentialPairRegions(in: text)
        candidates += userInfoRegions(in: text)
        candidates.sort { lhs, rhs in
            if lhs.marker.precedence != rhs.marker.precedence {
                return lhs.marker.precedence < rhs.marker.precedence
            }
            if lhs.range.lowerBound != rhs.range.lowerBound {
                return lhs.range.lowerBound < rhs.range.lowerBound
            }
            return lhs.range.upperBound > rhs.range.upperBound
        }
        var accepted: [Region] = []
        for candidate in candidates where !candidate.range.isEmpty {
            if accepted.contains(where: { $0.range.overlaps(candidate.range) }) { continue }
            accepted.append(candidate)
        }
        return accepted.sorted { $0.range.lowerBound < $1.range.lowerBound }
    }

    /// 已知前缀的高熵键：`sk-…` / `ghp_…` / `AKIA…` / `xoxb-…` / `AIza…`。
    ///
    /// 每条都要求前缀左边不是字母或数字：`risk-level`、`task-id` 里也含 `sk-` / `k-`，
    /// 没有这道边界就会把普通参数掩掉（过掩比漏掩更难发现，因为它悄悄丢审计事实）。
    private static func shapeRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        for shape in shapePrefixes {
            var cursor = text.startIndex
            while let found = text.range(of: shape.prefix, range: cursor..<text.endIndex) {
                cursor = text.index(after: found.lowerBound)
                guard hasWordBoundary(before: found.lowerBound, in: text) else { continue }
                let run = runStarting(at: found.lowerBound, in: text, minLength: shape.minLength)
                guard let run else { continue }
                regions.append(Region(range: run, marker: shape.marker))
            }
        }
        return regions
    }

    /// 头字段形态：`Authorization: Bearer x`、`X-API-Key: x`（也接受 `=` 分隔）。键名保留。
    private static func headerRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        for header in headerNames {
            var cursor = text.startIndex
            while let found = text.range(of: header, options: [.caseInsensitive], range: cursor..<text.endIndex) {
                cursor = text.index(after: found.lowerBound)
                guard hasWordBoundary(before: found.lowerBound, in: text),
                      let value = valueAfterSeparator(found.upperBound, in: text) else { continue }
                regions.append(Region(range: value, marker: .authorizationHeader))
            }
        }
        return regions
    }

    /// 裸 `Bearer <token>` / `Basic <credentials>`：scheme 词保留，只掩后面的值。
    private static func schemeRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        for scheme in authenticationSchemes {
            var cursor = text.startIndex
            while let found = text.range(of: scheme, options: [.caseInsensitive], range: cursor..<text.endIndex) {
                cursor = text.index(after: found.lowerBound)
                guard hasWordBoundary(before: found.lowerBound, in: text),
                      hasWordBoundary(after: found.upperBound, in: text) else { continue }
                let start = skipWhitespace(found.upperBound, in: text)
                guard let run = runStarting(at: start, in: text, minLength: 8) else { continue }
                regions.append(Region(range: run, marker: .bearerToken))
            }
        }
        return regions
    }

    /// 赋值形态：`--password=x`、`AWS_SECRET_ACCESS_KEY=wJal…`、`api_key=sk-…`。
    ///
    /// 值被引号包住时掩引号**内部**，引号本身留着——参数是怎么写的这个形状不丢。
    private static func assignmentRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        var cursor = text.startIndex
        while let equal = text.range(of: "=", range: cursor..<text.endIndex) {
            cursor = equal.upperBound
            guard let name = nameEnding(before: equal.lowerBound, in: text),
                  looksLikeSecretName(String(text[name])) else { continue }
            guard let value = assignmentValue(after: equal.upperBound, in: text) else { continue }
            regions.append(Region(range: value, marker: assignmentMarker(for: String(text[name]))))
        }
        return regions
    }

    /// 成对凭据：`-u user:pass`、`--user user:pass`、`-uuser:pass`（用户名保留）。
    private static func credentialPairRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        for flag in userFlags {
            var cursor = text.startIndex
            while let found = text.range(of: flag, options: [.caseInsensitive], range: cursor..<text.endIndex) {
                cursor = text.index(after: found.lowerBound)
                guard hasFlagBoundary(before: found.lowerBound, in: text) else { continue }
                var valueStart = found.upperBound
                if valueStart < text.endIndex, text[valueStart] == "=" {
                    valueStart = text.index(after: valueStart)
                }
                guard let password = userPassPair(at: valueStart, in: text) else { continue }
                regions.append(Region(range: password, marker: .basicAuth))
            }
        }
        return regions
    }

    /// URL 里的 userinfo：`scheme://user:pass@host`（host 与 user 留着）。
    private static func userInfoRegions(in text: String) -> [Region] {
        var regions: [Region] = []
        var cursor = text.startIndex
        while let separator = text.range(of: "://", range: cursor..<text.endIndex) {
            cursor = separator.upperBound
            var index = separator.upperBound
            var colon: String.Index?
            while index < text.endIndex {
                let character = text[index]
                if character == "@" {
                    if let colon {
                        regions.append(Region(range: text.index(after: colon)..<index, marker: .basicAuth))
                    }
                    break
                }
                if character == ":" {
                    if colon != nil { break }   // 第二个冒号：不是干净的 user:pass，不猜
                    colon = index
                } else if character == "/" || character == "?" || character == "#" || character == " " {
                    break
                }
                index = text.index(after: index)
            }
        }
        return regions
    }

    // MARK: - 内部：字符与判定小工具

    /// 掩一个「值就在这个元素里」的段落。
    ///
    /// `userFlags`（`-u` / `--user`）后面那一格：**用户名是审计对象**（README 明写用户名不脱敏），
    /// 所以只有带冒号的 `user:pass` 才掩冒号之后那一段；没有冒号就说明这一格里根本没有凭据，
    /// 原样留着。口令单独占一格（`--password x`）时没有这种可留的部分，整格替换。
    private static func maskValue(_ text: String, as marker: Marker) -> String {
        guard !isRedacted(text) else { return text }
        if marker == .basicAuth {
            guard let colon = text.firstIndex(of: ":") else { return text }
            guard colon > text.startIndex else { return placeholder(for: marker) }
            return String(text[..<colon]) + ":" + placeholder(for: marker)
        }
        return placeholder(for: marker)
    }

    private static func hasWordBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        return !isWordCharacter(text[text.index(before: index)])
    }

    private static func hasWordBoundary(after index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        return !isWordCharacter(text[index])
    }

    /// 开关左边界的判据比单词边界更严：`-` 也算「粘在别的词上」。
    /// 否则 `--user` 里的那个 `-u` 会被当成一次独立的短开关命中。
    private static func hasFlagBoundary(before index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        let previous = text[text.index(before: index)]
        return !isWordCharacter(previous) && previous != "-" && previous != "/"
    }

    /// 从 `index` 起吃一段凭据字符集，长度不足 `minLength` 则不算。
    private static func runStarting(
        at index: String.Index,
        in text: String,
        minLength: Int
    ) -> Range<String.Index>? {
        var end = index
        var count = 0
        while end < text.endIndex, isCredentialCharacter(text[end]) {
            end = text.index(after: end)
            count += 1
        }
        return count >= minLength ? index..<end : nil
    }

    /// 冒号 / 等号之后的值：跳过分隔符、空白与可选的 scheme 词（`Bearer`、`Basic`）。
    private static func valueAfterSeparator(
        _ index: String.Index,
        in text: String
    ) -> Range<String.Index>? {
        guard index < text.endIndex, text[index] == ":" || text[index] == "=" else { return nil }
        let afterSeparator = skipWhitespace(text.index(after: index), in: text)
        var valueStart = afterSeparator
        if let scheme = authenticationSchemes.first,
           let found = text.range(of: scheme, options: [.caseInsensitive], range: afterSeparator..<text.endIndex),
           found.lowerBound == afterSeparator,
           hasWordBoundary(after: found.upperBound, in: text) {
            valueStart = skipWhitespace(found.upperBound, in: text)
        }
        return runStarting(at: valueStart, in: text, minLength: 4)
    }

    /// 赋值号之后的值：引号内（保留引号本身）或一段凭据字符。
    private static func assignmentValue(
        after index: String.Index,
        in text: String
    ) -> Range<String.Index>? {
        guard index < text.endIndex else { return nil }
        let head = text[index]
        if head == "\"" || head == "'" {
            let opening = text.index(after: index)
            var cursor = opening
            while cursor < text.endIndex, text[cursor] != head {
                cursor = text.index(after: cursor)
            }
            return cursor > opening ? opening..<cursor : nil
        }
        if head == " " || head == "\t" { return nil }   // `--password x` 分写形态由 argv 层处理
        return runStarting(at: index, in: text, minLength: 1)
    }

    /// `-u` 之后的 `user:pass`，返回 `pass` 那一段。
    private static func userPassPair(at index: String.Index, in text: String) -> Range<String.Index>? {
        var cursor = skipQuotation(skipWhitespace(index, in: text), in: text)
        while cursor < text.endIndex, text[cursor] != ":", text[cursor] != " " {
            cursor = text.index(after: cursor)
        }
        guard cursor < text.endIndex, text[cursor] == ":" else { return nil }
        return runStarting(at: text.index(after: cursor), in: text, minLength: 1)
    }

    private static func skipQuotation(_ index: String.Index, in text: String) -> String.Index {
        guard index < text.endIndex, text[index] == "\"" || text[index] == "'" else { return index }
        return text.index(after: index)
    }

    private static func skipWhitespace(_ index: String.Index, in text: String) -> String.Index {
        var cursor = index
        while cursor < text.endIndex, text[cursor] == " " || text[cursor] == "\t" {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    /// 结尾于 `index` 的最大「名字」片段（`AWS_SECRET_ACCESS_KEY=` 里的键名那一截）。
    private static func nameEnding(before index: String.Index, in text: String) -> Range<String.Index>? {
        var start = index
        var count = 0
        while start > text.startIndex {
            let candidate = text.index(before: start)
            guard isNameCharacter(text[candidate]) else { break }
            start = candidate
            count += 1
        }
        return count > 0 ? start..<index : nil
    }

    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    static func isNameCharacter(_ character: Character) -> Bool {
        isWordCharacter(character) || character == "_" || character == "-" || character == "."
    }

    /// 凭据字符集：各类 key 与 base64 会用到 `+ / =`，但**不含** `:`、`@`、引号与空白，
    /// 所以扫描会在这些位置自然停下。
    static func isCredentialCharacter(_ character: Character) -> Bool {
        isWordCharacter(character) || character == "_" || character == "-" || character == "."
            || character == "+" || character == "/" || character == "="
    }

    // MARK: - 内部：词表

    private struct ShapePrefix: Sendable {
        var prefix: String
        /// 整段（前缀 + 值）的最小长度：太短的 `AKIA` / `AIza` 只是普通词的一部分。
        var minLength: Int
        var marker: Marker
    }

    /// 已知凭据前缀（大小写敏感，照各厂商原样）。
    private static let shapePrefixes: [ShapePrefix] = [
        ShapePrefix(prefix: "sk_live_", minLength: 12, marker: .openAIKey),
        ShapePrefix(prefix: "sk_test_", minLength: 12, marker: .openAIKey),
        ShapePrefix(prefix: "sk-proj-", minLength: 12, marker: .openAIKey),
        ShapePrefix(prefix: "sk-", minLength: 8, marker: .openAIKey),
        ShapePrefix(prefix: "github_pat_", minLength: 16, marker: .githubToken),
        ShapePrefix(prefix: "ghp_", minLength: 16, marker: .githubToken),
        ShapePrefix(prefix: "gho_", minLength: 16, marker: .githubToken),
        ShapePrefix(prefix: "ghu_", minLength: 16, marker: .githubToken),
        ShapePrefix(prefix: "ghs_", minLength: 16, marker: .githubToken),
        ShapePrefix(prefix: "ghr_", minLength: 16, marker: .githubToken),
        ShapePrefix(prefix: "xoxb-", minLength: 12, marker: .slackToken),
        ShapePrefix(prefix: "xoxp-", minLength: 12, marker: .slackToken),
        ShapePrefix(prefix: "xoxa-", minLength: 12, marker: .slackToken),
        ShapePrefix(prefix: "xapp-", minLength: 12, marker: .slackToken),
        ShapePrefix(prefix: "AKIA", minLength: 16, marker: .awsAccessKey),
        ShapePrefix(prefix: "ASIA", minLength: 16, marker: .awsAccessKey),
        ShapePrefix(prefix: "AIza", minLength: 24, marker: .googleAPIKey),
    ]

    private static let headerNames: [String] = [
        "proxy-authorization", "authorization", "x-api-key", "x-auth-token",
        "api-key", "x-amz-security-token", "private-token",
    ]

    private static let authenticationSchemes: [String] = ["bearer", "basic", "token", "digest"]

    /// 值单独占一个 argv 元素的口令型开关。
    static let passwordFlags: Set<String> = [
        "--password", "--passwd", "--pwd", "--pass", "--netrc-pass", "--netrc-password",
    ]

    /// 值单独占一个 argv 元素的 key/token 型开关。
    static let tokenFlags: Set<String> = [
        "--token", "--access-token", "--refresh-token", "--id-token", "--auth-token",
        "--api-key", "--apikey", "--secret", "--secret-key", "--client-secret",
        "--access-key", "--private-key", "--session-key",
    ]

    /// 值单独占一个 argv 元素的「用户名:口令」开关。
    static let userFlags: [String] = ["--user", "--username", "-u"]

    /// 归一化后算凭据键名的完整名字（小写、去掉 `-` 与 `_`）。
    static let exactSecretNames: Set<String> = [
        "key", "token", "secret", "password", "passwd", "pwd", "pass", "bearer",
        "authorization", "credential", "credentials", "apikey", "secretkey",
        "accesskey", "authtoken", "privatekey", "sessionkey", "clientsecret",
        "refreshtoken", "accesstoken", "idtoken",
    ]

    /// 只有含这些片段的名字才算凭据键名。刻意**不含**裸 `auth` 与裸 `key`：
    /// `--author=` 是 git 的常用开关，`--key-path=` 是路径，按裸子串误伤就是把审计事实掩掉。
    static let secretNameFragments: [String] = [
        "password", "passwd", "credential", "secret", "token", "apikey",
        "accesskey", "privatekey", "sessionkey", "authtoken",
    ]
}

// MARK: - 判定

extension CommandLineRedaction {

    /// 名字是否像一把凭据。归一化 = 小写、去掉 `-` 与 `_`（前导 `-` 因此一并消失）。
    static func looksLikeSecretName(_ rawName: String) -> Bool {
        let normalized = normalizeName(rawName)
        guard !normalized.isEmpty else { return false }
        if exactSecretNames.contains(normalized) { return true }
        return secretNameFragments.contains { normalized.contains($0) }
    }

    static func normalizeName(_ rawName: String) -> String {
        rawName.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
    }

    private static func assignmentMarker(for rawName: String) -> Marker {
        let normalized = normalizeName(rawName)
        if rawName.hasPrefix("-") {
            return normalized.contains("password") || normalized.contains("passwd") || normalized == "pwd"
                ? .passwordAssignment : .tokenAssignment
        }
        return .envFileValue
    }

    /// 这个 argv 元素是不是「值在下一个元素里」的凭据开关。
    static func standaloneValueFlag(in argument: String) -> Marker? {
        guard !argument.isEmpty, argument.hasPrefix("-") else { return nil }
        let lowered = argument.lowercased()
        if passwordFlags.contains(lowered) { return .passwordAssignment }
        if tokenFlags.contains(lowered) { return .tokenAssignment }
        if userFlags.contains(lowered) { return .basicAuth }
        return nil
    }
}
