//
//  CommandBehaviorRulesDestructiveEscalation.swift
//  Rules
//
//  Owner: WS-Agent（由 CommandBehaviorRules.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import AIObservatoryCore
// MARK: - 23. Recursive permission broadening

/// 23. 递归放宽文件权限/属主（`risk.command.recursive-permission-broadening`）。
///
/// 非递归的 `chmod 777` 属 L1 文本分级职责，本条用 `isRecursivePermissionMutation`
/// 只覆盖递归形态，避免两层重复命中。
public struct CMDRecursivePermissionBroadeningRule: AgentRiskRule {

    /// 规则身份。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.recursive-permission-broadening",
        family: .commandBehavior,
        category: .privilegeEscalation,
        title: "递归放宽文件或目录权限",
        rationaleTemplate: "{count} 次递归权限/属主变更放宽了访问位（{modes}，目标 {targets}）：{commands}。",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "isRecursivePermissionMutation 且模式位含 7/2/w（chmod -R 777、o+w、a+w），或 chown/chgrp -R 改属主。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 结构性规则；与 L1 的 `chmod -r 777` 结论合流取更高。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 同一窗口只出一条：`recursive-permission`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let hits = CommandRuleSupport.samples(in: window).filter { sample in
            classifier.isRecursivePermissionMutation(sample.facts) && Self.broadensAccess(sample.facts)
        }
        guard let head = hits.first else { return [] }
        let level = CommandRuleSupport.level(baseline: .high, upstream: hits.map(\.upstream))
        let modes = Self.broadeningModes(of: hits)
        let targets = CommandRuleSupport.targetPaths(of: hits)
        return [makeFinding(from: RiskFindingDraft(
            level: level,
            detail: identity.rationale(filling: [
                "count": String(hits.count),
                "modes": modes.isEmpty ? "变更属主/递归授权" : modes.joined(separator: " "),
                "targets": targets.isEmpty ? "未在实参中识别到绝对路径" : targets.prefix(3).joined(separator: "、"),
                "commands": CommandRuleSupport.commandList(of: hits)
            ]),
            confidence: 0.85,
            timestamp: head.record.startedAt,
            filePaths: targets,
            command: CommandRuleSupport.representative(of: hits)?.facts.commandLine,
            sessionID: window.sessionID,
            agentID: head.record.agentID ?? window.agentIDs.first,
            agentKind: CommandRuleSupport.agentKind(for: head, window: window),
            suppressionKey: "recursive-permission",
            evidenceCount: hits.count,
            evidenceSpan: CommandRuleSupport.span(of: hits)
        ))]
    }

    /// 递归改属主，或递归 chmod 且模式位放宽（含 7 / 2 / `+w`）。
    static func broadensAccess(_ facts: RiskCommandFacts) -> Bool {
        if facts.effectiveExecutable == "chown" || facts.effectiveExecutable == "chgrp" { return true }
        return broadeningModes(facts).isEmpty == false
    }

    /// 该命令里放宽访问位的模式实参（八进制 `777`/`667`… 或符号 `o+w`/`a+rw`）。
    fileprivate static func broadeningModes(of samples: [CommandSample]) -> [String] {
        var modes: [String] = []
        for sample in samples {
            for mode in broadeningModes(sample.facts) where !modes.contains(mode) {
                modes.append(mode)
            }
        }
        return modes
    }

    /// 单条命令的放宽模式位实参。
    static func broadeningModes(_ facts: RiskCommandFacts) -> [String] {
        facts.operands.compactMap { operand in
            guard isModeOperand(operand) else { return nil }
            return operand.contains("7") || operand.contains("2") || operand.contains("w") ? operand : nil
        }
    }

    /// 实参是否形如权限模式（路径含 `/`、含空格或长度不符即被排除）。
    static func isModeOperand(_ operand: String) -> Bool {
        guard !operand.isEmpty, operand.count <= 5, !operand.contains("/"), !operand.contains(" ") else { return false }
        if operand.contains("+") { return true }
        guard operand.count == 3 || operand.count == 4 else { return false }
        return operand.allSatisfy { $0 >= "0" && $0 <= "7" }
    }
}

// MARK: - 24. Volume erasure

/// 24. 卷/分区抹除（`risk.command.volume-erasure`）。
public struct CMDVolumeErasureRule: AgentRiskRule {

    /// 规则身份：CRITICAL 且必须确认。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.volume-erasure",
        family: .commandBehavior,
        category: .dangerousCommand,
        title: "抹掉或重新格式化了存储卷",
        rationaleTemplate: "{count} 次抹掉/重建文件系统的操作（{commands}），目标 {targets} 上的数据不可恢复。",
        defaultLevel: .critical,
        requiresConfirmation: true,
        summary: "复用 isVolumeErasure：diskutil eraseDisk|zeroDisk|partitionDisk|reformat、mkfs、newfs、dd of=/dev/*，并补齐 diskutil 子命令变体。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 结构性规则；L1 已对 `mkfs`/`dd of=/dev/` 判 CRITICAL，此处只叠加不降级。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 同一窗口只出一条：`volume-erasure`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let hits = CommandRuleSupport.samples(in: window).filter { sample in
            classifier.isVolumeErasure(sample.facts) || Self.isDiskutilEraseVariant(sample.facts)
        }
        guard let head = hits.first else { return [] }
        let level = CommandRuleSupport.level(baseline: .critical, upstream: hits.map(\.upstream))
        let targets = CommandRuleSupport.targetPaths(of: hits)
        return [makeFinding(from: RiskFindingDraft(
            level: level,
            detail: identity.rationale(filling: [
                "count": String(hits.count),
                "commands": CommandRuleSupport.commandList(of: hits),
                "targets": targets.isEmpty ? "整卷/块设备" : targets.prefix(3).joined(separator: "、")
            ]),
            confidence: 0.95,
            timestamp: head.record.startedAt,
            filePaths: targets,
            command: CommandRuleSupport.representative(of: hits)?.facts.commandLine,
            sessionID: window.sessionID,
            agentID: head.record.agentID ?? window.agentIDs.first,
            agentKind: CommandRuleSupport.agentKind(for: head, window: window),
            suppressionKey: "volume-erasure",
            evidenceCount: hits.count,
            evidenceSpan: CommandRuleSupport.span(of: hits)
        ))]
    }

    /// `diskutil eraseVolume` / `reformat` 等分类器子命令表之外的形态。
    ///
    /// TODO(contract-gap): `isVolumeErasure` 的 diskutil 表缺 `eraseVolume`、`reformat`；
    /// 这里按 argv 子命令 token 前缀补齐（仍是结构化谓词，不匹配整条命令文本）。
    static func isDiskutilEraseVariant(_ facts: RiskCommandFacts) -> Bool {
        guard facts.effectiveExecutable == "diskutil", let subcommand = facts.subcommand else { return false }
        return subcommand.hasPrefix("erase") || subcommand.hasPrefix("zero")
            || subcommand.hasPrefix("reformat") || subcommand.contains("partition")
    }
}

// MARK: - 25. Confirmation bypass

/// 25. 成串使用自动确认/跳过确认（`risk.command.confirmation-bypass`）。
///
/// 单条命令是否危险仍由 L1 判定；本条只看会话里"反复绕开人工确认"这一行为模式，
/// 因此等级固定在 MEDIUM（不与 L1 叠加，避免和 L1 对同一条命令的结论重复刷屏）。
public struct CMDConfirmationBypassRule: AgentRiskRule {

    /// 规则身份。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.confirmation-bypass",
        family: .commandBehavior,
        category: .dangerousCommand,
        title: "反复以自动确认跳过人工作出判断",
        rationaleTemplate: "窗口内 {count} 条不可逆/破坏性命令带自动确认标志（{commands}），人工确认环节被系统性跳过。",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "带 -y/--yes/--force/--no-input/--no-confirm/-f 且结构性不可逆或 L1 判破坏性的命令 ≥ 2 次时命中（阈值取自本族固定最小值 2）。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 复用 L1 的 `isDestructive` 作为筛选输入。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 至少两次才命中；同一窗口只出一条：`confirmation-bypass`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let hits = CommandRuleSupport.samples(in: window).filter { sample in
            let irreversible = classifier.looksIrreversible(sample.facts) || (sample.upstream?.isDestructive ?? false)
            return irreversible && CommandRuleSupport.hasAutoConfirmFlag(sample.facts)
        }
        guard hits.count >= Self.minimumOccurrences, let head = hits.first else { return [] }
        return [makeFinding(from: RiskFindingDraft(
            level: .medium,
            detail: identity.rationale(filling: [
                "count": String(hits.count),
                "commands": CommandRuleSupport.commandList(of: hits)
            ]),
            confidence: hits.count >= Self.minimumOccurrences * 2 ? 0.8 : 0.7,
            timestamp: head.record.startedAt,
            filePaths: CommandRuleSupport.targetPaths(of: hits),
            command: CommandRuleSupport.representative(of: hits)?.facts.commandLine,
            sessionID: window.sessionID,
            agentID: head.record.agentID ?? window.agentIDs.first,
            agentKind: CommandRuleSupport.agentKind(for: head, window: window),
            suppressionKey: "confirmation-bypass",
            evidenceCount: hits.count,
            evidenceSpan: CommandRuleSupport.span(of: hits)
        ))]
    }

    /// 判定"成串"所需的最少条数（契约未提供该阈值字段，故固定为 2）。
    ///
    /// TODO(contract-gap): `RiskThresholds` 无 `confirmationBypassCount`，暂用常量 2。
    static let minimumOccurrences = 2
}

// MARK: - 26. Escalating retry after failure

/// 26. 失败后升级力度重试（`risk.command.escalating-retry-after-failure`）。
///
/// 纯跨命令判定：同一有效可执行名内，先有一条失败命令，其后出现力度更强的同类命令
/// （加递归/强制选项、或加提权包装）。
public struct CMDEscalatingRetryAfterFailureRule: AgentRiskRule {

    /// 规则身份。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.escalating-retry-after-failure",
        family: .commandBehavior,
        category: .dangerousCommand,
        title: "命令失败后以更强力的方式重试",
        rationaleTemplate: "{tool} 先失败（{failed}），随后力度更强地重试（新增 {signals}）：{retry}。",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "同一可执行名：失败（exitCode != 0 或 outcome 失败）之后出现评分更高的同类命令（递归/强制/提权包装）。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 结构性规则；升级后的那条命令若已被 L1 判更高等级则叠加。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 按可执行名分桶，每桶最多一条：`escalating-retry:<可执行名>`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let samples = CommandRuleSupport.samples(in: window)
        let buckets = CommandRuleSupport.group(samples) { $0.facts.effectiveExecutable }

        var findings: [RiskFinding] = []
        for bucket in buckets {
            guard let escalation = Self.firstEscalation(in: bucket.samples) else { continue }
            let failed = escalation.failed
            let retry = escalation.retry
            let level = CommandRuleSupport.level(baseline: .high, upstream: [retry.upstream])
            findings.append(makeFinding(from: RiskFindingDraft(
                level: level,
                detail: identity.rationale(filling: [
                    "tool": bucket.label,
                    "failed": failed.facts.commandLine,
                    "retry": retry.facts.commandLine,
                    "signals": CommandRuleSupport.addedStrengthSignal(from: failed, to: retry)
                ]),
                confidence: 0.8,
                timestamp: retry.record.startedAt,
                filePaths: CommandRuleSupport.targetPaths(of: [failed, retry]),
                command: retry.facts.commandLine,
                sessionID: window.sessionID,
                agentID: retry.record.agentID ?? window.agentIDs.first,
                agentKind: CommandRuleSupport.agentKind(for: retry, window: window),
                suppressionKey: "escalating-retry:\(bucket.label)",
                evidenceCount: 2,
                evidenceSpan: retry.record.startedAt.timeIntervalSince(failed.record.startedAt) > 0
                    ? retry.record.startedAt.timeIntervalSince(failed.record.startedAt)
                    : nil
            )))
        }
        return findings
    }

    /// 桶内最早的一对"失败 → 更强重试"（时间序扫描，结果确定）。
    fileprivate static func firstEscalation(in bucket: [CommandSample]) -> (failed: CommandSample, retry: CommandSample)? {
        for (index, candidate) in bucket.enumerated() where CommandRuleSupport.isFailure(candidate) {
            let strength = CommandRuleSupport.retryStrength(candidate.facts)
            for later in bucket.dropFirst(index + 1)
            where CommandRuleSupport.retryStrength(later.facts) > strength {
                return (candidate, later)
            }
        }
        return nil
    }
}

