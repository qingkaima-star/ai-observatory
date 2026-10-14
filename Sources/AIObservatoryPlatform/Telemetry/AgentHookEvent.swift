//
//  AgentHookEvent.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-CmdSrc
//  ─────────────────────────────────────────────────────────
//  Agent 自己的 hook 往 `<storeDirectory>/agent-hooks/*.jsonl` 落的一行 JSON，
//  解析成领域事实 `AgentHookEvent`（见 AiX-Vault/04-决策记录/IFR-command-precision.md）。
//
//  schema（一行一条 JSON，未知字段忽略）：
//    agentKind, sessionId?, command, arguments?[], workingDirectory?,
//    startedAt, endedAt?, exitCode?, durationMs?, source, pid?, eventId?
//  时间戳接受 ISO8601 字符串（可带小数秒）或 Unix 秒数字——写法不同不该丢命令。
//
//  口径：**缺 `command` 或缺 `startedAt` 的行一律拒绝并由调用方计数**，
//  不补默认值、不猜命令文本、不伪造结局。这是审计产品能被相信的底线。
//

import Foundation
import CryptoKit
import AIObservatoryCore

/// 一条已校验的 hook 命令事件：命令文本、退出码、起止时间全部来自当事进程本身。
public struct AgentHookEvent: Sendable, Equatable {

    /// 归因到的 Agent 类型；认不出来是 `.unknown`，不做猜测。
    public var agentKind: AgentKind
    /// hook 侧的会话 id（可选，原样透传）。
    public var sessionID: UUID?
    /// 命令文本（未切分前的原样）。
    public var command: String
    /// `command` 去掉可执行文件后的参数；`arguments` 字段存在时以它为准。
    public var arguments: [String]
    public var workingDirectory: String?
    public var startedAt: Date
    /// 结束时间：`endedAt` 优先，其次由 `durationMs` 推得；都没有则 nil（= 还在跑/不知道）。
    public var endedAt: Date?
    public var exitCode: Int32?
    /// 当事进程 pid（可选，仅参与身份标识，不用于查进程表）。
    public var pid: Int32?
    /// hook 侧的事件 id；给了就作为幂等键，否则用内容自然键。
    public var eventID: String?

    public init(
        agentKind: AgentKind,
        sessionID: UUID? = nil,
        command: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        pid: Int32? = nil,
        eventID: String? = nil
    ) {
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.command = command
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.pid = pid
        self.eventID = eventID
    }

    // MARK: - 拒绝原因

    /// 一行被丢弃的原因（每种都对应 `HookAuditStats` 里的一个计数）。
    public enum Rejection: String, Sendable, Equatable, Error {
        /// 不是合法 JSON，或字段类型不对。
        case malformedJSON
        /// 缺 `command`（或只有空白）。
        case missingCommand
        /// 缺 `startedAt`，或它解析不出时间。
        case missingStartedAt
    }

    // MARK: - 解析

    /// 解析一行 hook JSONL。空白行不在此处出现（由读取器过滤）。
    public static func parse(jsonLine: String) -> Result<AgentHookEvent, Rejection> {
        guard let data = jsonLine.data(using: .utf8) else { return .failure(.malformedJSON) }
        let decoder = JSONDecoder()
        guard let line = try? decoder.decode(RawLine.self, from: data) else { return .failure(.malformedJSON) }

        let command = line.command?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !command.isEmpty else { return .failure(Rejection.missingCommand) }
        guard let startedAt = line.startedAt?.dateValue else { return .failure(Rejection.missingStartedAt) }

        var endedAt = line.endedAt?.dateValue
        if endedAt == nil, let durationMs = line.durationMs {
            endedAt = startedAt.addingTimeInterval(durationMs / 1000)
        }
        // 时钟跳变/写错的行会让耗时变成负数：只丢这一格，命令本身照记。
        if let end = endedAt, end < startedAt {
            endedAt = nil
        }

        let providedArguments = (line.arguments ?? []).filter { !$0.isEmpty }
        let argv = providedArguments.isEmpty ? Self.tokenize(command) : [Self.head(of: command)] + providedArguments

        return .success(AgentHookEvent(
            agentKind: agentKind(from: line.agentKind),
            sessionID: line.sessionID.flatMap { UUID(uuidString: $0) },
            command: command,
            arguments: Array(argv.dropFirst()),
            workingDirectory: line.workingDirectory?.isEmpty == true ? nil : line.workingDirectory,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: line.exitCode.flatMap { Int32(exactly: $0) },
            pid: line.pid.flatMap { Int32(exactly: $0) },
            eventID: line.eventID?.isEmpty == false ? line.eventID : nil
        ))
    }

    /// `source` 固定为 `"hook"`；其它值不拒（用户可能写 `"claude-hook"`），只做透传。
    static func agentKind(from text: String?) -> AgentKind {
        guard let raw = text?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { return .unknown }
        let normalized = Self.normalize(raw)
        if let exact = kindLookup[normalized] { return exact }
        if let aliased = aliases[normalized] { return aliased }
        // 前缀式写法（"claude-code/1.0"、"codex cli"）归一到已知类型；归不出来就是 unknown。
        for (alias, kind) in aliases where normalized.hasPrefix(alias) { return kind }
        return .unknown
    }

    /// 各 `AgentKind` 的规范化写法 → 类型。用字典避免 O(n) 遍历 + 手写 switch 漏 case。
    private static let kindLookup: [String: AgentKind] = Dictionary(
        AgentKind.allCases.map { (normalize($0.rawValue), $0) },
        uniquingKeysWith: { first, _ in first }
    )

    /// 用户/CLI 常见叫法。只在规范化（小写、去掉 `-` `_` 空格 `.`）之后比较。
    private static let aliases: [String: AgentKind] = [
        "claude": .claudeCode,
        "claudecode": .claudeCode,
        "claudecli": .claudeCode,
        "anthropic": .claudeCode,
        "codex": .openAICodex,
        "codexcli": .openAICodex,
        "openai": .openAICodex,
        "openaicodex": .openAICodex,
        "cursor": .cursorAgent,
        "cursoragent": .cursorAgent,
        "copilot": .vscodeCopilot,
        "githubcopilot": .vscodeCopilot,
        "vscode": .vscodeCopilot,
        "windsurf": .windsurf,
        "gemini": .geminiCLI,
        "geminicli": .geminiCLI,
        "aider": .aiderCLI,
    ]

    private static func normalize(_ text: String) -> String {
        text.lowercased().filter { $0 != "-" && $0 != "_" && $0 != " " && $0 != "." }
    }

    // MARK: - 身份与映射

    /// 幂等键：给了 `eventId` 用它，否则用内容自然键（同一次执行写两遍也只有一个键）。
    ///
    /// 命令那一段进键之前先过脱敏：这个键会被 `HookCommandAuditing` 写进
    /// `<数据目录>/agent-hooks/.offsets.json` 并长期留存，用原文等于在库里之外再留一份凭据。
    /// 脱敏是确定性函数 ⇒ 「同一次执行写两遍仍只有一个键」这条性质不变。
    public var eventKey: String {
        if let eventID { return "id:\(eventID)" }
        let milliseconds = Int64((startedAt.timeIntervalSince1970 * 1000).rounded())
        return [
            "nat",
            agentKind.rawValue,
            sessionID?.uuidString ?? "-",
            CommandLineRedaction.redact(command),
            String(milliseconds),
        ].joined(separator: "|")
    }

    /// 由 `eventKey` 派生的 name-based UUID（SHA-256，v5 位）。
    /// 内容相同 ⇒ id 相同 ⇒ 同一事件无论从哪个偏移读到多少次，落库都是同一行。
    public var recordID: UUID { Self.uuid(from: eventKey) }

    /// 退出状态三格的诚实映射：有码按码，无码但有结束时间即"知道结束了但拿不到码"，都没有就是 running。
    public var outcome: CommandOutcome {
        if let exitCode { return exitCode == 0 ? .success : .failure }
        return endedAt == nil ? .running : .unknown
    }

    /// 转成领域记录。`projectPath` 留给 Engine 的项目地图判定，这里不越权填 cwd。
    public func commandRecord(agentID: UUID?, classification: CommandClassification) -> CommandRecord {
        CommandRecord(
            id: recordID,
            executable: Self.head(of: command),
            // 与采样侧同一个落点：转成记录的这一刻起，argv 里没有凭据原文
            // （`command` 本身留着，分级与幂等键都要用真文本；见 `CommandLineRedaction`）。
            arguments: CommandLineRedaction.redact(arguments: arguments),
            workingDirectory: workingDirectory,
            agentID: agentID,
            sessionID: sessionID,
            agentKind: agentKind,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: exitCode,
            outcome: outcome,
            isDestructive: classification.isDestructive,
            requiresConfirmation: classification.requiresConfirmation,
            riskLevel: classification.level,
            projectPath: nil
        )
    }

    // MARK: - 命令文本切分

    /// 按 shell 的引号规则切 argv：引号内的空格不是分隔符。
    static func tokenize(_ text: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var insideSingleQuote = false
        var insideDoubleQuote = false
        var seeingToken = false

        for character in text.unicodeScalars {
            switch character {
            case "'":
                insideSingleQuote.toggle()
                seeingToken = true
            case "\"":
                insideDoubleQuote.toggle()
                seeingToken = true
            default:
                let isSeparator = !insideSingleQuote && !insideDoubleQuote
                    && (character == " " || character == "\t" || character == "\n" || character == "\r")
                if isSeparator {
                    if seeingToken {
                        tokens.append(current)
                        current = ""
                        seeingToken = false
                    }
                } else {
                    current.unicodeScalars.append(character)
                    seeingToken = true
                }
            }
        }
        if seeingToken { tokens.append(current) }
        return tokens
    }

    /// 可执行文件名：第一个 token；切不出来的空串退回原样。
    static func head(of text: String) -> String {
        tokenize(text).first ?? text
    }

    private static func uuid(from key: String) -> UUID {
        var bytes = [UInt8](repeating: 0, count: 16)
        for (index, value) in SHA256.hash(data: Data(key.utf8)).prefix(16).enumerated() {
            bytes[index] = value
        }
        bytes[6] = (bytes[6] & 0x0F) | 0x50   // UUID 版本号 5（name-based）
        bytes[8] = (bytes[8] & 0x3F) | 0x80   // RFC 4122 变体位
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    // MARK: - 落盘形态

    /// JSONL 的一行原样形态。字段全部可选：缺哪个都由 `parse` 决定是丢还是记。
    private struct RawLine: Decodable {
        var agentKind: String?
        var sessionID: String?
        var command: String?
        var arguments: [String]?
        var workingDirectory: String?
        var startedAt: HookTimestamp?
        var endedAt: HookTimestamp?
        var exitCode: Int?
        var durationMs: Double?
        var source: String?
        var pid: Int?
        var eventID: String?

        // 落盘字段名按 schema 用 camelCase 的小写开头写法，Swift 侧保持 `sessionID`/`eventID` 命名规范。
        enum CodingKeys: String, CodingKey {
            case agentKind
            case sessionID = "sessionId"
            case command, arguments, workingDirectory, startedAt, endedAt
            case exitCode, durationMs, source, pid
            case eventID = "eventId"
        }
    }
}

/// 时间戳字段：ISO8601 字符串（可带小数秒）或 Unix 秒数字都认。
enum HookTimestamp: Decodable {
    case text(String)
    case seconds(Double)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let text = try? container.decode(String.self) {
            self = .text(text)
            return
        }
        if let seconds = try? container.decode(Double.self) {
            self = .seconds(seconds)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "时间戳需要 ISO8601 字符串或 Unix 秒"
        )
    }

    var dateValue: Date? {
        switch self {
        case .seconds(let seconds):
            return seconds > 0 ? Date(timeIntervalSince1970: seconds) : nil
        case .text(let text):
            return AgentHookEvent.parseTimestamp(text)
        }
    }
}

extension AgentHookEvent {
    /// ISO8601 解析：先带小数秒（短命令 30–50 ms，砍掉小数会把耗时抹平），再退到整秒写法。
    public static func parseTimestamp(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let date = timestampFormatterWithFractional.date(from: trimmed) { return date }
        return timestampFormatter.date(from: trimmed)
    }

    /// `ISO8601DateFormatter` 在本 SDK 未标注 `Sendable`，但它初始化后只读、不改配置，
    /// 多线程并发 `date(from:)` 是本仓库既有用法（见 `AIObservatoryExport/ExportFormatting.swift`）。
    nonisolated(unsafe) private static let timestampFormatterWithFractional: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    nonisolated(unsafe) private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
