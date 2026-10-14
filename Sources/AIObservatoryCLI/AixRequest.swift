//
//  AixRequest.swift
//  AIObservatoryCLI
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  `aix` 的参数解析。**手搓，不引 swift-argument-parser**：
//  本包今天零外部依赖，引一个就要在解析期拉网络，违反 AGENTS.md §7「禁止网络」，
//  并让「CI 全绿」从此多一个外部前提（ICR-0012 §一 有账）。
//

import Foundation
import AIObservatoryCore

/// 一条 `aix` 命令解析后的全部意图。
public struct AixRequest: Sendable, Hashable {
    /// 子命令。七条与派单原文一一对应。
    public enum Command: String, CaseIterable, Sendable {
        case agents
        case sessions
        case timeline
        case files
        case commands
        case risk
        case report
    }

    /// `report` 的正文格式。`--json` 与 `--format json` 同义。
    public enum ReportFormat: String, Sendable {
        case md
        case json
    }

    public var command: Command
    /// 机器可读输出（stdout 只放数据，诊断走 stderr）。
    public var json: Bool
    /// **凭据脱敏（`ExportRedactor.standard`）默认开**（ICR-0012 总控裁定 20:0x 把提案的默认值反过来了）：
    /// 本条需求的原话是「给 AI 自己使用」，CLI 输出会被整段贴进模型上下文 —— 凭据一旦进上下文
    /// 就已出本机边界，所以"默认不脱敏"在这条路径上是**数据外泄默认值**，不是中性值。
    public var redactCredentials: Bool
    /// **路径遮罩**（#61 那套：家目录绝对前缀 → `~`）默认关，`--redact` 才开。
    /// 它是给人看演示用的显示层映射，**不是安全边界**；与凭据脱敏语义不同 ⇒ 两个独立开关，不并成一个 flag。
    public var maskPaths: Bool
    /// 只看未归属的文件变更。
    public var unattributedOnly: Bool
    /// 风险等级过滤：精确匹配该等级（`level IN (…)`），不做「及以上」的臆造口径。
    public var level: RiskLevel?
    /// 表格里最多显示多少行；`nil` = 不限（`report` 用它收集全量）。
    public var limit: Int?
    /// 起始时间过滤（含）。
    public var since: Date?
    /// 显式数据目录，优先级最高；给了它就跳过 ADR-0003 链。
    public var dataDir: String?
    public var reportFormat: ReportFormat?

    /// 表格默认行数。超过它一定在输出里写明「共 N 行，已截断」，不让截断看起来像全貌。
    public static let defaultRowLimit = 200

    public init(
        command: Command,
        json: Bool = false,
        redactCredentials: Bool = true,
        maskPaths: Bool = false,
        unattributedOnly: Bool = false,
        level: RiskLevel? = nil,
        limit: Int? = defaultRowLimit,
        since: Date? = nil,
        dataDir: String? = nil,
        reportFormat: ReportFormat? = nil
    ) {
        self.command = command
        self.json = json
        self.redactCredentials = redactCredentials
        self.maskPaths = maskPaths
        self.unattributedOnly = unattributedOnly
        self.level = level
        self.limit = limit
        self.since = since
        self.dataDir = dataDir
        self.reportFormat = reportFormat
    }
}

/// 参数错误 ⇒ 一律退 2（前置条件不满足），且会把可用参数打到 stderr。
///
/// ⚠️ 必须自己实现 `LocalizedError`：否则 `error.localizedDescription` 给出的是
/// 「The operation couldn't be completed. (AIObservatoryCLI.AixUsageError error 1.)」——
/// 探针实测抓到过，用户看到的是天书，具体原因（哪个参数、错在哪）全丢了。
public struct AixUsageError: Error, Equatable, Sendable, LocalizedError {
    public var reason: String
    public init(_ reason: String) { self.reason = reason }
    public var errorDescription: String? { reason }
}

public enum AixArguments {
    /// 解析 argv（不含可执行文件名）。
    public static func parse(_ arguments: [String]) throws -> AixRequest {
        guard let head = arguments.first, !head.hasPrefix("-") else {
            throw AixUsageError(
                arguments.isEmpty
                    ? "缺少子命令。可用：\(AixRequest.Command.allCases.map(\.rawValue).joined(separator: " / "))"
                    : "子命令必须出现在选项之前；收到「\(arguments.first ?? "")」。"
            )
        }
        guard let command = AixRequest.Command(rawValue: head) else {
            throw AixUsageError("未知子命令「\(head)」。可用：\(AixRequest.Command.allCases.map(\.rawValue).joined(separator: " / "))")
        }
        var request = AixRequest(command: command)
        var index = arguments.index(after: arguments.startIndex)
        while index < arguments.endIndex {
            let token = arguments[index]
            index = arguments.index(after: index)
            func value() throws -> String {
                guard index < arguments.endIndex else { throw AixUsageError("\(token) 需要一个值") }
                defer { index = arguments.index(after: index) }
                return arguments[index]
            }
            switch token {
            case "--json":
                request.json = true
            case "--redact":
                request.maskPaths = true
            case "--no-redact":
                request.redactCredentials = false
            case "--unattributed":
                guard command == .files else { throw AixUsageError("\(token) 只对 files 有效") }
                request.unattributedOnly = true
            case "--level":
                guard command == .risk else { throw AixUsageError("\(token) 只对 risk 有效") }
                let raw = try value()
                guard let level = RiskLevel(rawValue: raw) else {
                    throw AixUsageError("--level 取 low|medium|high|critical，收到「\(raw)」")
                }
                request.level = level
            case "--format":
                guard command == .report else { throw AixUsageError("\(token) 只对 report 有效") }
                let raw = try value()
                guard let format = AixRequest.ReportFormat(rawValue: raw) else {
                    throw AixUsageError("--format 取 md|json，收到「\(raw)」")
                }
                request.reportFormat = format
                if format == .json { request.json = true }
            case "--limit":
                let raw = try value()
                guard let parsed = Int(raw), parsed > 0 else {
                    throw AixUsageError("--limit 要一个正整数，收到「\(raw)」")
                }
                request.limit = parsed
            case "--all":
                request.limit = nil
            case "--since":
                let raw = try value()
                guard let date = Self.parseDate(raw) else {
                    throw AixUsageError("--since 要 ISO 8601（如 2026-09-21 或 2026-09-21T18:30:00Z），收到「\(raw)」")
                }
                request.since = date
            case "--data-dir":
                request.dataDir = try value()
            default:
                throw AixUsageError("未知选项「\(token)」（`aix \(command.rawValue) --help` 看可用参数）")
            }
        }
        return request
    }

    /// `--since` 接受纯日期与带时区的时间戳两种写法。
    static func parseDate(_ raw: String) -> Date? {
        let full = ISO8601DateFormatter()
        full.formatOptions = [.withInternetDateTime]
        if let date = full.date(from: raw) { return date }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = TimeZone.current
        day.dateFormat = "yyyy-MM-dd"
        return day.date(from: raw)
    }

    /// 各子命令的参数说明，用于 `--help` 与错误提示。
    public static func help(for command: AixRequest.Command?) -> String {
        var lines: [String] = []
        lines.append("用法：aix <子命令> [选项]")
        lines.append("")
        lines.append("子命令（全部只读：不开写事务、不跑采集、不改设置、不删数据）：")
        lines.append("  agents      当前活跃的 Agent（state 为 running 或 idle）")
        lines.append("  sessions    会话清单")
        lines.append("  timeline    时间线事件")
        lines.append("  files       文件变更（--unattributed 只看未归属）")
        lines.append("  commands    命令审计")
        lines.append("  risk        风险事件（--level low|medium|high|critical）")
        lines.append("  report      审计报告（复用导出层；--format md|json）")
        lines.append("")
        lines.append("通用选项：")
        lines.append("  --json          结构化输出到 stdout；诊断与状态标记走 stderr")
        lines.append("  --no-redact     关闭凭据脱敏（默认**开**：输出会被贴进模型上下文，凭据出去就收不回）")
        lines.append("                    关闭时输出里留一行可审计提示，不静默出原文")
        lines.append("  --redact        路径遮罩：把家目录/项目根换成 ~ 与 <project>（默认关，#61 那套显示层映射）")
        lines.append("  --limit N       最多显示 N 行（默认 \(AixRequest.defaultRowLimit)）；--all 不限")
        lines.append("  --since <日期>  起始时间（YYYY-MM-DD 或 ISO 8601）")
        lines.append("  --data-dir <目录> 指定数据目录（跳过 ADR-0003 优先级链）")
        lines.append("")
        lines.append("退出码：0 正常 / 1 库存在但查无结果或表为空 / 2 前置条件不满足（无库、参数错、库版本不符）")
        lines.append("")
        lines.append("只读边界（实测出来的，别当成宣传）：")
        lines.append("  · 不改主库内容；库版本与本工具不符时直接退 2，绝不代 AiX 迁移你的库")
        lines.append("  · 但留下未合并 WAL 的那一次读取会把 WAL 合并进主库（checkpoint），并在 stderr 自报")
        lines.append("  · 要免掉那一步需要 Store 提供只读打开：ICR-0012 §三 C2")
        if let command { lines.append("\n（当前子命令：\(command.rawValue)）") }
        return lines.joined(separator: "\n") + "\n"
    }
}
