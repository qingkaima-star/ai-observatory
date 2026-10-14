//
//  CommandBehaviorRules.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk —— C 命令行为族
//
//  C 族：会话级「命令行为」聚合判定（11 条，规则 id 前缀 `risk.command.*`）。
//
//  与 L1 的分层（见 `01-架构/风险规则库接口.md` 第 0 节）：
//   · L1 `Platform/Telemetry/DestructiveCommandRules`（33 条）已经对**单条命令文本**
//     做过正则/子串分级（`rm -rf`、`curl | sh`、`sudo`…）。本文件**不重复**任何命令文本正则，
//     也不 import Platform（target 依赖只有 `AIObservatoryCore`）。
//   · 单命令结论一律经 `RiskFactWindow.classification(for:)` 复用：优先调用方经
//     `telemetryClassifications` 传入的 L1 结果，否则退化为 `CommandRecord` 自带的
//     `isDestructive / riskLevel / requiresConfirmation`。
//   · 本文件只做 L1 做不到的两件事：
//       1) 用 `RiskCommandFacts` + `RiskCommandClassifier` 的**结构化 argv 谓词**
//          （可执行名 / 子命令 / 短长选项 / 目标路径）回答"这条命令在会话里做了哪一类事"；
//       2) **跨命令**的会话级判定：次数、组合、失败后升级、与文件事实的关联。
//   · 等级合成只升不降：见 `CommandRuleSupport.level(baseline:upstream:)`。
//
//  纯函数：不 IO、不 `Date()`、不随机、不读环境变量。排序全部来自
//  `window.sortedCommands`（时间升序、同刻按 id 字典序），分桶顺序为"该桶首次出现的时间顺序"，
//  因此同一 `RiskFactWindow` 两次 `findings(in:)` 结果逐字节相等。
//

import Foundation
import AIObservatoryCore

// MARK: - 16. Privilege escalation burst

/// 16. 会话内提权执行成串出现（`risk.command.privilege-escalation-burst`）。
///
/// 只统计 `facts.privilegeWrapper != nil` 的命令条数（结构化 argv 谓词），
/// 单命令的危险度仍由 L1 给出并经 `window.classification(for:)` 复用。
public struct CMDPrivilegeEscalationBurstRule: AgentRiskRule {

    /// 规则身份：单次提权 → MEDIUM；达到 `privilegeEscalationCount` → HIGH。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.privilege-escalation-burst",
        family: .commandBehavior,
        category: .privilegeEscalation,
        title: "会话内反复以提权方式执行命令",
        rationaleTemplate: "窗口内出现 {count} 条提权执行（{wrapper} 包装；成串阈值 {threshold}）。代表性命令：{commands}。",
        defaultLevel: .medium,
        requiresConfirmation: true,
        summary: "统计窗口内 sudo/doas/pkexec/su 包装的命令条数：单条 MEDIUM，达到阈值升 HIGH；等级叠加复用 L1 结论。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 复用 L1 的提权分级做等级合成。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 同一窗口只出一条：`privilege-escalation-burst:<次数分档>`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let escalated = CommandRuleSupport.samples(in: window).filter { $0.facts.privilegeWrapper != nil }
        guard let head = escalated.first else { return [] }
        let threshold = Swift.max(1, window.thresholds.privilegeEscalationCount)
        let reached = escalated.count >= threshold
        let level = CommandRuleSupport.level(
            baseline: reached ? .high : .medium,
            upstream: escalated.map(\.upstream)
        )
        return [makeFinding(from: RiskFindingDraft(
            level: level,
            detail: identity.rationale(filling: [
                "count": String(escalated.count),
                "threshold": String(threshold),
                "wrapper": CommandRuleSupport.wrapperLabel(of: escalated),
                "commands": CommandRuleSupport.commandList(of: escalated)
            ]),
            confidence: reached ? 0.85 : 0.6,
            timestamp: head.record.startedAt,
            filePaths: CommandRuleSupport.targetPaths(of: escalated),
            command: CommandRuleSupport.representative(of: escalated)?.facts.commandLine,
            sessionID: window.sessionID,
            agentID: head.record.agentID ?? window.agentIDs.first,
            agentKind: CommandRuleSupport.agentKind(for: head, window: window),
            suppressionKey: "privilege-escalation-burst:\(Self.band(count: escalated.count, threshold: threshold))",
            evidenceCount: escalated.count,
            evidenceSpan: CommandRuleSupport.span(of: escalated)
        ))]
    }

    /// 次数分档（同时保证同窗口同档只出一条）。
    static func band(count: Int, threshold: Int) -> String {
        if count >= threshold * 3 { return "surge" }
        if count >= threshold { return "burst" }
        return "single"
    }
}

// MARK: - 17. Irreversible git operation

/// 17. 不可逆 Git 操作（`risk.command.irreversible-git-operation`）。
///
/// 结构性谓词 `isGitHistoryRewrite` / `isGitRemoteDestruction` 命中即 HIGH；
/// 远端引用被删除（`push --delete`、`push origin :main`）升 CRITICAL。按子命令分桶，每桶一条。
public struct CMDIrreversibleGitOperationRule: AgentRiskRule {

    /// 规则身份。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.irreversible-git-operation",
        family: .commandBehavior,
        category: .dangerousCommand,
        title: "执行了不可逆的 Git 操作",
        rationaleTemplate: "Git 子命令 {subcommand} 共 {count} 次会重写或丢弃历史/远端引用（{commands}），本地无法简单撤销。",
        defaultLevel: .high,
        requiresConfirmation: true,
        summary: "按 git 子命令分桶复用 isGitHistoryRewrite/isGitRemoteDestruction；删除远端引用时升为 CRITICAL。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 复用 L1（例如 `git push --force` 已由 L1 判 HIGH/破坏性）做等级叠加。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 命中子命令逐条产出：`irreversible-git:<子命令>`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let hits = CommandRuleSupport.samples(in: window).filter { sample in
            classifier.isGitHistoryRewrite(sample.facts)
                || classifier.isGitRemoteDestruction(sample.facts)
                || Self.deletesLocalReference(sample.facts)
        }
        guard !hits.isEmpty else { return [] }

        return CommandRuleSupport.group(hits) { sample in sample.facts.subcommand ?? "other" }.map { bucket in
            let remote = bucket.samples.contains { classifier.isGitRemoteDestruction($0.facts) }
            let level = CommandRuleSupport.level(
                baseline: remote ? .critical : .high,
                upstream: bucket.samples.map(\.upstream)
            )
            let head = bucket.samples.first
            return makeFinding(from: RiskFindingDraft(
                level: level,
                detail: identity.rationale(filling: [
                    "subcommand": bucket.label,
                    "count": String(bucket.samples.count),
                    "commands": CommandRuleSupport.commandList(of: bucket.samples)
                ]),
                confidence: remote ? 0.95 : 0.9,
                timestamp: head?.record.startedAt ?? window.start,
                filePaths: CommandRuleSupport.targetPaths(of: bucket.samples),
                command: CommandRuleSupport.representative(of: bucket.samples)?.facts.commandLine,
                sessionID: window.sessionID,
                agentID: head?.record.agentID ?? window.agentIDs.first,
                agentKind: head.map { CommandRuleSupport.agentKind(for: $0, window: window) } ?? window.agentKind,
                suppressionKey: "irreversible-git:\(bucket.label)",
                evidenceCount: bucket.samples.count,
                evidenceSpan: CommandRuleSupport.span(of: bucket.samples)
            ))
        }
    }

    /// `git branch -D <name>` / `git tag -d <name>`。
    ///
    /// TODO(contract-gap): `RiskCommandFacts` 把 `-D` 归入 `shortFlags`，
    /// 因此 `isGitHistoryRewrite` 中 `operands.contains("-D")` 分支永不成立；
    /// 期望上游分类器改为比较短选项。此处只做同源的 argv 结构补判，不匹配命令文本。
    static func deletesLocalReference(_ facts: RiskCommandFacts) -> Bool {
        guard facts.effectiveExecutable == "git" else { return false }
        guard let subcommand = facts.subcommand else { return false }
        guard ["branch", "tag"].contains(subcommand) else { return false }
        return facts.hasShortFlag("D") || facts.hasShortFlag("d")
    }
}

// MARK: - 18. Working tree discard

/// 18. 丢弃未提交的工作区内容（`risk.command.working-tree-discard`）。
///
/// 与 17 的区别：本条只在**同窗口存在未提交的修改/创建事实**时才命中，
/// 是"命令 × 文件事实"的跨层关联判定，单看命令文本无法得出。
public struct CMDWorkingTreeDiscardRule: AgentRiskRule {

    /// 规则身份：存在脏工作区时 MEDIUM，窗口内另有删除事实时 HIGH。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.working-tree-discard",
        family: .commandBehavior,
        category: .dangerousCommand,
        title: "丢弃了尚未提交的工作区改动",
        rationaleTemplate: "{count} 条 git 命令会抹掉未提交的工作区内容（{commands}）；同窗口有 {dirty} 条未提交的修改/创建事实{deletionNote}，这些内容无法通过 Git 找回。",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "isGitWorkingTreeDiscard 与窗口内修改/创建事实关联；窗口内还有删除事实时升 HIGH。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 纯结构 + 文件事实关联，不需要 L1 文本结论来决定等级。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(defersToTelemetryClassification: false, requiresWriteEvidence: true)
    }

    /// 无状态规则。
    public init() {}

    /// 同一窗口只出一条：`working-tree-discard`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let discards = CommandRuleSupport.samples(in: window).filter { classifier.isGitWorkingTreeDiscard($0.facts) }
        guard let head = discards.first else { return [] }

        // TODO(contract-gap): 窗口没有"git 脏状态"字段，用同窗口的修改/创建事实近似
        // "尚未提交的改动"，并假定它们与丢弃动作属于同一工作区（无法核对仓库路径）。
        let uncommitted = window.modifications + window.creations
        guard !uncommitted.isEmpty else { return [] }
        let deletions = window.deletions

        let level = CommandRuleSupport.level(
            baseline: deletions.isEmpty ? .medium : .high,
            upstream: discards.map(\.upstream)
        )
        return [makeFinding(from: RiskFindingDraft(
            level: level,
            detail: identity.rationale(filling: [
                "count": String(discards.count),
                "dirty": String(uncommitted.count),
                "deletionNote": deletions.isEmpty ? "" : "、另有 \(deletions.count) 条删除事实",
                "commands": CommandRuleSupport.commandList(of: discards)
            ]),
            confidence: deletions.isEmpty ? 0.75 : 0.85,
            timestamp: head.record.startedAt,
            filePaths: CommandRuleSupport.paths(of: uncommitted),
            command: CommandRuleSupport.representative(of: discards)?.facts.commandLine,
            sessionID: window.sessionID,
            agentID: head.record.agentID ?? window.agentIDs.first,
            agentKind: CommandRuleSupport.agentKind(for: head, window: window),
            suppressionKey: "working-tree-discard",
            evidenceCount: discards.count + uncommitted.count,
            evidenceSpan: CommandRuleSupport.span(of: discards)
        ))]
    }
}

// MARK: - 19. Package source tamper

/// 19. 包管理器源 / 工具链配置被篡改（`risk.command.package-source-tamper`）。
public struct CMDPackageSourceTamperRule: AgentRiskRule {

    /// 规则身份。
    public static let identity = RiskRuleIdentity(
        id: "risk.command.package-source-tamper",
        family: .commandBehavior,
        category: .dangerousCommand,
        title: "改动了包管理器源或工具链持久配置",
        rationaleTemplate: "{tool} 的包源或工具链配置被改动，共 {count} 次（{commands}），后续依赖可能来自非官方源。",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "复用 isPackageSourceTamper / isToolchainConfigMutation：npm/pnpm/yarn config set registry、pip --index-url/--trusted-host、brew tap、cargo login|publish、gem push 等，按工具分桶。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.identity }

    /// 结构性规则，但仍与 L1 合流取更高等级。
    public var preferences: RiskRulePreferences { RiskRulePreferences(defersToTelemetryClassification: true) }

    /// 无状态规则。
    public init() {}

    /// 按可执行名分桶：`package-source-tamper:<可执行名>`。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.commands.isEmpty else { return [] }
        let classifier = CommandRuleSupport.classifier
        let hits = CommandRuleSupport.samples(in: window).filter { sample in
            classifier.isPackageSourceTamper(sample.facts) || classifier.isToolchainConfigMutation(sample.facts)
        }
        guard !hits.isEmpty else { return [] }

        return CommandRuleSupport.group(hits) { $0.facts.effectiveExecutable }.map { bucket in
            let level = CommandRuleSupport.level(baseline: .high, upstream: bucket.samples.map(\.upstream))
            let head = bucket.samples.first
            return makeFinding(from: RiskFindingDraft(
                level: level,
                detail: identity.rationale(filling: [
                    "tool": bucket.label,
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
                suppressionKey: "package-source-tamper:\(bucket.label)",
                evidenceCount: bucket.samples.count,
                evidenceSpan: CommandRuleSupport.span(of: bucket.samples)
            ))
        }
    }
}

// MARK: - Family façade

/// C 命令行为。规则 id 前缀 `risk.command.*`。
public enum CommandBehaviorRules: Sendable {

    /// 本族全部规则，按声明顺序参与聚合（聚合层负责排序与去重）。
    public static let all: [any AgentRiskRule] = [
        CMDPrivilegeEscalationBurstRule(),
        CMDIrreversibleGitOperationRule(),
        CMDWorkingTreeDiscardRule(),
        CMDPackageSourceTamperRule(),
        CMDRemoteScriptPipeExecutionRule(),
        CMDServiceOrKernelMutationRule(),
        CMDSecuritySettingsMutationRule(),
        CMDRecursivePermissionBroadeningRule(),
        CMDVolumeErasureRule(),
        CMDConfirmationBypassRule(),
        CMDEscalatingRetryAfterFailureRule()
    ]
}
