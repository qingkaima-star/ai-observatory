//
//  CommandBehaviorRulesSystemMutation.swift
//  Rules
//
//  Owner: WS-Agent（由 CommandBehaviorRules.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import AIObservatoryCore
// MARK: - 20. Remote script pipe execution

/// 20. 管道执行解释器输入（`risk.command.remote-script-pipe-execution`）。
///
/// 等级以 L1 为准（只升不降）；管道首段是网络抓取器时基线提到 HIGH；
/// 同窗口存在被提权包装的管道执行 → CRITICAL。
public struct CMDRemoteScriptPipeExecutionRule: AgentRiskRule {

    /// 规则身份。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.remote-script-pipe-execution",
        family: .commandBehavior,
        category: .dangerousCommand,
        title: "把管道输入直接交给解释器执行",
        rationaleTemplate: "窗口内 {count} 条命令把管道输入直接交给解释器执行（{commands}）{sourceNote}，未经验证的代码随即运行。",
        defaultLevel: .medium,
        requiresConfirmation: true,
        summary: "复用 isPipeToInterpreter；等级优先取 L1 结论，来源为网络抓取器时至少 HIGH，叠加提权包装时 CRITICAL。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 本条显式复用 L1 的单命令分级。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 同一窗口只出一条：`remote-script-pipe`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let pipes = CommandRuleSupport.samples(in: window).filter { classifier.isPipeToInterpreter($0.facts) }
        guard let head = pipes.first else { return [] }

        let remote = pipes.contains(where: { Self.isRemoteSourced($0.facts) })
        let escalated = pipes.contains { $0.facts.privilegeWrapper != nil }
        let baseline: RiskLevel = escalated ? .critical : (remote ? .high : .medium)
        let level = CommandRuleSupport.level(baseline: baseline, upstream: pipes.map(\.upstream))
        return [makeFinding(from: RiskFindingDraft(
            level: level,
            detail: identity.rationale(filling: [
                "count": String(pipes.count),
                "commands": CommandRuleSupport.commandList(of: pipes),
                "sourceNote": remote ? "，且输入来自网络抓取器" : "（本地管道，未见网络来源）"
            ]),
            confidence: remote ? 0.9 : 0.7,
            timestamp: head.record.startedAt,
            filePaths: CommandRuleSupport.targetPaths(of: pipes),
            command: CommandRuleSupport.representative(of: pipes)?.facts.commandLine,
            sessionID: window.sessionID,
            agentID: head.record.agentID ?? window.agentIDs.first,
            agentKind: CommandRuleSupport.agentKind(for: head, window: window),
            suppressionKey: "remote-script-pipe",
            evidenceCount: pipes.count,
            evidenceSpan: CommandRuleSupport.span(of: pipes)
        ))]
    }

    /// 抓取器名单：`curl` / `wget` 等。
    static let fetchers: Set<String> = [
        "curl", "wget", "fetch", "axel", "aria2c", "lwp-request", "nc", "ncat",
        "socat", "scp", "sftp", "ftp", "tftp", "gsutil", "s3cmd"
    ]

    /// 管道输入是否来自网络：只看管道首段的可执行名与实参的 scheme 前缀
    /// （结构化 argv 判断，不重做 L1 的 `curl.*\|.*sh` 正则）。
    static func isRemoteSourced(_ facts: RiskCommandFacts) -> Bool {
        if let first = facts.pipelines.first, let head = first.split(separator: " ").first {
            if fetchers.contains(RiskPathAnalyzer.fileName(of: String(head)).lowercased()) { return true }
        }
        return facts.hasOperandBeginning(with: "http://")
            || facts.hasOperandBeginning(with: "https://")
            || facts.hasOperandBeginning(with: "ftp://")
    }
}

// MARK: - 21. Service or kernel mutation

/// 21. 系统服务 / 内核参数变更（`risk.command.service-or-kernel-mutation`）。
public struct CMDServiceOrKernelMutationRule: AgentRiskRule {

    /// 规则身份。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.service-or-kernel-mutation",
        family: .commandBehavior,
        category: .systemFileModification,
        title: "变更了系统服务或内核参数",
        rationaleTemplate: "子命令 {subcommand} 共 {count} 次改动系统服务/内核状态（{commands}），影响面超出本会话。",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "复用 isServiceOrKernelOperation（launchctl bootout|unload|bootstrap、systemctl mask|disable、kextload、sysctl -w、nvram、softwareupdate -f），按子命令分桶。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 结构性规则；等级仍与 L1（如 `launchctl unload` 已判 MEDIUM）取 max。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 按子命令分桶：`service-kernel-mutation:<子命令>`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let hits = CommandRuleSupport.samples(in: window).filter { sample in
            classifier.isServiceOrKernelOperation(sample.facts) && !Self.isReadOnlyIntrospection(sample.facts)
        }
        guard !hits.isEmpty else { return [] }

        return CommandRuleSupport.group(hits) { $0.facts.subcommand ?? $0.facts.effectiveExecutable }.map { bucket in
            let level = CommandRuleSupport.level(baseline: .high, upstream: bucket.samples.map(\.upstream))
            let head = bucket.samples.first
            return makeFinding(from: RiskFindingDraft(
                level: level,
                detail: identity.rationale(filling: [
                    "subcommand": bucket.label,
                    "count": String(bucket.samples.count),
                    "commands": CommandRuleSupport.commandList(of: bucket.samples)
                ]),
                confidence: 0.85,
                timestamp: head?.record.startedAt ?? window.start,
                filePaths: CommandRuleSupport.targetPaths(of: bucket.samples),
                command: CommandRuleSupport.representative(of: bucket.samples)?.facts.commandLine,
                sessionID: window.sessionID,
                agentID: head?.record.agentID ?? window.agentIDs.first,
                agentKind: head.map { CommandRuleSupport.agentKind(for: $0, window: window) } ?? window.agentKind,
                suppressionKey: "service-kernel-mutation:\(bucket.label)",
                evidenceCount: bucket.samples.count,
                evidenceSpan: CommandRuleSupport.span(of: bucket.samples)
            ))
        }
    }

    /// 只读内省（`sysctl hw.ncpu`、`nvram` 无赋值）不算变更。
    ///
    /// TODO(contract-gap): `isServiceOrKernelOperation` 对 `sysctl`/`nvram` 无条件返回 true，
    /// 这里按 argv 实参是否含赋值（`key=value`）或写/删选项（`-w`/`-d`）抑制只读形态。
    static func isReadOnlyIntrospection(_ facts: RiskCommandFacts) -> Bool {
        switch facts.effectiveExecutable {
        case "sysctl":
            return !facts.hasShortFlag("w") && !facts.operands.contains(where: { $0.contains("=") })
        case "nvram":
            return !facts.hasShortFlag("d") && !facts.operands.contains(where: { $0.contains("=") })
        default:
            return false
        }
    }
}

// MARK: - 22. Security settings mutation

/// 22. 安全策略配置被改动（`risk.command.security-settings-mutation`）。
public struct CMDSecuritySettingsMutationRule: AgentRiskRule {

    /// 规则身份：一律 CRITICAL 并要求确认。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.security-settings-mutation",
        family: .commandBehavior,
        category: .systemFileModification,
        title: "改动了系统安全策略",
        rationaleTemplate: "{tool} 共 {count} 次改动防火墙/SIP/Gatekeeper/TCC 等安全策略（{commands}），系统防护被削弱。",
        defaultLevel: .critical,
        requiresConfirmation: true,
        summary: "复用 isSecuritySettingMutation：pfctl、socketfilterfw、csrutil、spctl --disable、tccutil、networksetup …firewall、defaults …gatekeeper、security delete-keychain。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 结构性规则；L1（如 `csrutil disable` 已判 CRITICAL）只做等级叠加校验。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 按可执行名分桶：`security-settings-mutation:<可执行名>`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let hits = CommandRuleSupport.samples(in: window).filter { sample in
            classifier.isSecuritySettingMutation(sample.facts)
                || Self.isSpctlDisable(sample.facts)
                || Self.isNetworkSetupFirewallMutation(sample.facts)
        }
        guard !hits.isEmpty else { return [] }

        return CommandRuleSupport.group(hits) { $0.facts.effectiveExecutable }.map { bucket in
            let level = CommandRuleSupport.level(baseline: .critical, upstream: bucket.samples.map(\.upstream))
            let head = bucket.samples.first
            return makeFinding(from: RiskFindingDraft(
                level: level,
                detail: identity.rationale(filling: [
                    "tool": bucket.label,
                    "count": String(bucket.samples.count),
                    "commands": CommandRuleSupport.commandList(of: bucket.samples)
                ]),
                // 单次改动已足够 CRITICAL；达到 `securityMutationCount` 说明是成系列操作，置信度更高。
                confidence: bucket.samples.count >= window.thresholds.securityMutationCount ? 0.95 : 0.88,
                timestamp: head?.record.startedAt ?? window.start,
                filePaths: CommandRuleSupport.targetPaths(of: bucket.samples),
                command: CommandRuleSupport.representative(of: bucket.samples)?.facts.commandLine,
                sessionID: window.sessionID,
                agentID: head?.record.agentID ?? window.agentIDs.first,
                agentKind: head.map { CommandRuleSupport.agentKind(for: $0, window: window) } ?? window.agentKind,
                suppressionKey: "security-settings-mutation:\(bucket.label)",
                evidenceCount: bucket.samples.count,
                evidenceSpan: CommandRuleSupport.span(of: bucket.samples)
            ))
        }
    }

    /// `spctl --disable` / `spctl --master-disable`：只有长选项、没有位置实参。
    ///
    /// TODO(contract-gap): `isSecuritySettingMutation` 的 spctl 分支只看 `subcommand`
    /// （首个非选项实参），因此纯长选项形式检不到。
    static func isSpctlDisable(_ facts: RiskCommandFacts) -> Bool {
        guard facts.effectiveExecutable == "spctl" else { return false }
        return facts.hasLongFlag("disable") || facts.hasLongFlag("master-disable")
    }

    /// `networksetup -setfirewallstate …`：该 token 以单横线开头，会被归入短选项而被丢弃。
    ///
    /// TODO(contract-gap): 期望 `isSecuritySettingMutation` 对 networksetup 比较完整 token 而非 `operands`。
    static func isNetworkSetupFirewallMutation(_ facts: RiskCommandFacts) -> Bool {
        guard facts.effectiveExecutable == "networksetup" else { return false }
        return facts.effectiveArguments.contains { argument in
            let token = argument.lowercased()
            return token.contains("firewall") && !token.hasPrefix("-get")
        }
    }
}

