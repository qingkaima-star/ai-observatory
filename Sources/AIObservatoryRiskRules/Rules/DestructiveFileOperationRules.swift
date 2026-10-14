//
//  DestructiveFileOperationRules.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk —— A 破坏性文件操作族
//
//  本文件实现 A 族 6 条会话级"破坏性文件操作"聚合规则（id 前缀 `risk.destructive.*`）：
//
//   1. `mass-deletion-window`      —— 时间簇内的批量删除（60 秒 42 次删除只报 1 条）
//   2. `directory-wipe`            —— 同一父目录被成批清空
//   3. `outside-project-write`     —— 越出允许写入根的删除（文件事实 + rm/rmdir 命令目标）
//   4. `overwrite-rewrite`         —— 覆盖式重写（大量行删除或体积大幅收缩）
//   5. `home-subtree-deletion`     —— 主目录一级子树删除（`rm -rf ~/Documents` → HIGH + 确认）
//   6. `file-truncation-burst`     —— 批量把文件截断为 0 字节
//
//  实现约束：全部为纯函数——不访问磁盘、不读取 `Date()`、不使用随机数、不 import
//  Platform/Engine/Store。命中时间戳一律来自证据事实（簇起点、变更时间、命令开始时间），
//  home 目录与阈值一律从 `RiskFactWindow` 注入。每条规则内部按 `suppressionKey`
//  自行折叠，因此同一窗口重复评估产出完全相同的结果。
//

import Foundation
import AIObservatoryCore

// MARK: - Shared helpers

/// A 族规则共用的纯函数工具。文件私有，不进入模块公共 API。
private enum DFOHelper {

    /// 视为"删除"的可执行名（已剥掉 `sudo` 等包装器后的真实命令名）。
    static let deletionExecutables: Set<String> = ["rm", "rmdir", "unlink", "shred", "wipe"]

    /// 用注入的 home 归一化路径。
    static func normalized(_ path: String, in window: RiskFactWindow) -> String {
        RiskPathAnalyzer.normalized(path, homeDirectory: window.homeDirectory)
    }

    /// 归一化后的主目录绝对路径。
    static func home(in window: RiskFactWindow) -> String {
        RiskPathAnalyzer.normalized(window.homeDirectory, homeDirectory: window.homeDirectory)
    }

    /// 路径是否就是主目录本身。
    static func isHomeRootPath(_ path: String, in window: RiskFactWindow) -> Bool {
        let full = normalized(path, in: window)
        let base = home(in: window)
        return !full.isEmpty && !base.isEmpty && full == base
    }

    /// 路径所属的 home 一级子目录（`/Users/x/Documents`）；路径不在 home 内时返回 nil。
    static func homeSubtreeRoot(of path: String, in window: RiskFactWindow) -> String? {
        let full = normalized(path, in: window)
        let base = home(in: window)
        guard !full.isEmpty, !base.isEmpty, full.hasPrefix(base + "/") else { return nil }
        let remainder = full.dropFirst(base.count + 1)
        guard let first = remainder.split(separator: "/", omittingEmptySubsequences: true).first else { return nil }
        return base + "/" + String(first)
    }

    /// 该命令是否在做删除（结构化 argv 判断，不重复 L1 的文本正则库）。
    static func isDeletionCommand(_ facts: RiskCommandFacts) -> Bool {
        if deletionExecutables.contains(facts.effectiveExecutable) { return true }
        if facts.effectiveExecutable == "find", facts.containsToken("-delete") { return true }
        if facts.effectiveExecutable == "git", facts.subcommand == "clean", facts.hasShortFlag("f") { return true }
        return false
    }

    /// 去重 + 字典序 + 截断的路径列表，保证 detail 与 `filePaths` 的确定性。
    static func paths(_ values: [String], limit: Int = 8) -> [String] {
        Array(Set(values).sorted().prefix(limit))
    }

    /// 置信度裁剪到 0.5…0.95 之间。
    static func confidence(_ value: Double) -> Double {
        Swift.min(Swift.max(value, 0.5), 0.95)
    }

    /// 证据越多置信度越高（每条 +0.005，最多按 40 条计）。
    static func confidence(base: Double, evidence count: Int) -> Double {
        confidence(base + Double(Swift.min(Swift.max(count, 1), 40)) * 0.005)
    }

    /// 两个等级里取更高的那个。
    static func higher(_ lhs: RiskLevel, _ rhs: RiskLevel) -> RiskLevel {
        lhs.rank >= rhs.rank ? lhs : rhs
    }

    /// 字节数可读文本。
    static func byteText(_ value: UInt64) -> String {
        if value >= 1_048_576 { return String(format: "%.1f MB", Double(value) / 1_048_576) }
        if value >= 1_024 { return String(format: "%.0f KB", Double(value) / 1_024) }
        return "\(value) 字节"
    }

    /// 秒数可读文本。
    static func secondText(_ value: TimeInterval) -> String {
        String(format: "%.0f", value) + " 秒"
    }

    /// 百分比可读文本。
    static func percentText(_ ratio: Double) -> String {
        String(format: "%.0f%%", Swift.min(Swift.max(ratio, 0), 1) * 100)
    }

    /// 同一抑制键只保留一条：后续命中通过 `merged(with:)` 折叠进来（等级只升不降）。
    static func collapse(_ findings: [RiskFinding]) -> [RiskFinding] {
        var order: [String] = []
        var buckets: [String: RiskFinding] = [:]
        for finding in findings {
            guard let existing = buckets[finding.suppressionKey] else {
                buckets[finding.suppressionKey] = finding
                order.append(finding.suppressionKey)
                continue
            }
            buckets[finding.suppressionKey] = existing.merged(with: finding)
        }
        return order.compactMap { buckets[$0] }
    }
}

/// 一条"越界删除"证据：文件删除事实或 rm/rmdir 命令的目标路径。
private struct DFOOutsideWriteEvidence {
    var path: String
    var parent: String
    var timestamp: Date
    var command: String?
}

/// 一条"主目录子树删除"证据。
private struct DFOHomeSubtreeEvidence {
    var subtree: String
    var targetsHomeRoot: Bool
    var path: String
    var timestamp: Date
    var command: String?
    var depth: Int
}

// MARK: - 1. Mass deletion window

/// 批量删除时间簇：在 `thresholds.massDeletionSpan` 秒内删除条数达到
/// `thresholds.massDeletionCount` 即命中，等级由 `thresholds.deletionLevel(count:)` 决定。
///
/// `suppressionKey` 取 `mass-deletion:<簇起点绝对秒>`，因此同一簇内的全部删除只产出 **1 条** 命中。
public struct DFOMassDeletionWindowRule: AgentRiskRule {

    public init() {}

    private static let ruleIdentity = RiskRuleIdentity(
        id: "risk.destructive.mass-deletion-window",
        family: .destructiveFileOperation,
        category: .massDeletion,
        title: "短时间窗口内批量删除文件",
        rationaleTemplate: "在 {span} 的窗口内连续删除了 {count} 个文件（时间簇起点 {cluster}，删除最集中的目录 {parent}，示例路径 {path}）。删除类操作需要人工确认。",
        defaultLevel: .medium,
        requiresConfirmation: true,
        summary: "同一时间簇内删除事实条数达到阈值即命中，等级随条数递增。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 等级完全由本规则按删除条数推导，不依赖上游命令分类。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(levelFloor: .low, defersToTelemetryClassification: false, requiresWriteEvidence: true)
    }

    /// 在窗口内产出批量删除命中（每个时间簇一条）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let deletions = window.deletions
        let required = Swift.max(1, window.thresholds.massDeletionCount)
        guard deletions.count >= required else { return [] }

        var findings: [RiskFinding] = []
        for cluster in window.temporalClusters(deletions, span: window.thresholds.massDeletionSpan, timestamp: { $0.timestamp }) {
            guard cluster.count >= required else { continue }
            let paths = DFOHelper.paths(cluster.items.map { DFOHelper.normalized($0.path, in: window) })
            let dominant = RiskPathAnalyzer.dominantParent(of: paths, homeDirectory: window.homeDirectory) ?? "（未知目录）"
            let level = window.thresholds.deletionLevel(count: cluster.count)
            let detail = identity.rationale(filling: [
                "count": String(cluster.count),
                "span": DFOHelper.secondText(window.thresholds.massDeletionSpan),
                "cluster": String(Int(cluster.start.timeIntervalSince1970)),
                "parent": dominant,
                "path": paths.first ?? "（无路径）",
            ])
            findings.append(makeFinding(from: RiskFindingDraft(
                level: level,
                detail: detail,
                confidence: DFOHelper.confidence(base: 0.7, evidence: cluster.count),
                timestamp: cluster.start,
                filePaths: paths,
                command: nil,
                sessionID: window.sessionID,
                agentID: window.agentIDs.first,
                agentKind: window.agentKind,
                suppressionKey: "mass-deletion:\(Int(cluster.start.timeIntervalSince1970))",
                evidenceCount: cluster.count,
                evidenceSpan: cluster.span
            )))
        }
        return DFOHelper.collapse(findings)
    }
}

// MARK: - 2. Directory wipe

/// 目录清空：同一父目录下的删除事实条数达到 `thresholds.directoryWipeCount` 即命中，等级 HIGH。
public struct DFODirectoryWipeRule: AgentRiskRule {

    public init() {}

    private static let ruleIdentity = RiskRuleIdentity(
        id: "risk.destructive.directory-wipe",
        family: .destructiveFileOperation,
        category: .massDeletion,
        title: "同一目录被成批清空",
        rationaleTemplate: "目录 {parent} 下有 {count} 个文件被删除（示例 {path}），相当于整目录清空；窗口内删除最集中的目录为 {dominant}。",
        defaultLevel: .high,
        requiresConfirmation: true,
        summary: "按父目录聚合删除事实，单目录删除条数超阈值即判为目录清空。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 删除条数是本规则的唯一依据，不消费上游命令分类。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(levelFloor: .low, defersToTelemetryClassification: false, requiresWriteEvidence: true)
    }

    /// 在窗口内产出目录清空命中（每个被清空的目录一条）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let deletions = window.deletions
        let required = Swift.max(1, window.thresholds.directoryWipeCount)
        guard deletions.count >= required else { return [] }

        var buckets: [String: [FileChange]] = [:]
        for change in deletions {
            let parent = RiskPathAnalyzer.parent(of: change.path, homeDirectory: window.homeDirectory)
            buckets[parent, default: []].append(change)
        }
        let allPaths = deletions.map { DFOHelper.normalized($0.path, in: window) }
        let dominant = RiskPathAnalyzer.dominantParent(of: allPaths, homeDirectory: window.homeDirectory) ?? "（未知目录）"

        var findings: [RiskFinding] = []
        for parent in buckets.keys.sorted() {
            guard let items = buckets[parent], items.count >= required else { continue }
            let paths = DFOHelper.paths(items.map { DFOHelper.normalized($0.path, in: window) })
            let timestamp = items.map(\.timestamp).min() ?? window.start
            let detail = identity.rationale(filling: [
                "parent": parent,
                "count": String(items.count),
                "path": paths.first ?? "（无路径）",
                "dominant": dominant,
            ])
            findings.append(makeFinding(from: RiskFindingDraft(
                level: .high,
                detail: detail,
                confidence: DFOHelper.confidence(base: 0.75, evidence: items.count),
                timestamp: timestamp,
                filePaths: paths,
                command: nil,
                sessionID: window.sessionID,
                agentID: window.agentIDs.first,
                agentKind: window.agentKind,
                suppressionKey: "directory-wipe:\(parent)",
                evidenceCount: items.count,
                evidenceSpan: span(of: items.map(\.timestamp), fallback: window.thresholds.massDeletionSpan)
            )))
        }
        return DFOHelper.collapse(findings)
    }

    /// 组内最早/最晚删除事实的时间跨度。
    private func span(of timestamps: [Date], fallback: TimeInterval) -> TimeInterval {
        guard let first = timestamps.min(), let last = timestamps.max() else { return fallback }
        let value = last.timeIntervalSince(first)
        return value > 0 ? value : 0
    }
}

// MARK: - 3. Outside project write

/// 越界删除：删除事实或 `rm`/`rmdir` 命令的目标落在 `window.allowedWriteRoots`（含
/// `trustedWriteRoots` 与会话项目根）之外。等级随越界条数递增（≥1 MEDIUM，≥5 HIGH）。
public struct DFOOutsideProjectWriteRule: AgentRiskRule {

    public init() {}

    /// 升级为 HIGH 所需的越界证据条数。
    /// TODO(contract-gap): `RiskThresholds` 暂无"越界删除条数"阈值字段，先取常量 5。
    private static let highEvidenceCount = 5
    /// 父目录分组数超过该值时折叠为一条 `mixed` 命中，避免刷屏。
    private static let parentGroupLimit = 3

    private static let ruleIdentity = RiskRuleIdentity(
        id: "risk.destructive.outside-project-write",
        family: .destructiveFileOperation,
        category: .massDeletion,
        title: "删除动作越出允许写入范围",
        rationaleTemplate: "在允许写入根之外删除了 {count} 个目标（目录 {parent}，示例 {path}{commandSuffix}），已越过会话的项目边界。",
        defaultLevel: .medium,
        requiresConfirmation: true,
        summary: "删除文件事实 + rm/rmdir 命令目标路径双重取证，按条数升级等级。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 只消费写/删类证据，命令文本分级由本规则自行按 argv 判定。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(levelFloor: .low, defersToTelemetryClassification: false, requiresWriteEvidence: true)
    }

    /// 在窗口内产出越界删除命中（按父目录分组，父目录过多时折叠为 `mixed`）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var evidence: [DFOOutsideWriteEvidence] = []

        // (a) 删除类文件事实越界。
        for change in window.deletions {
            let path = DFOHelper.normalized(change.path, in: window)
            guard !path.isEmpty, !window.isWithinAllowedWriteRoots(path) else { continue }
            evidence.append(DFOOutsideWriteEvidence(
                path: path,
                parent: RiskPathAnalyzer.parent(of: path, homeDirectory: window.homeDirectory),
                timestamp: change.timestamp,
                command: nil
            ))
        }

        // (b) rm / rmdir 等删除命令的目标路径越界。
        for command in window.sortedCommands {
            let facts = RiskCommandFacts(command, homeDirectory: window.homeDirectory)
            guard DFOHelper.isDeletionCommand(facts) else { continue }
            for target in facts.targetPaths {
                guard !target.isEmpty, !window.isWithinAllowedWriteRoots(target) else { continue }
                evidence.append(DFOOutsideWriteEvidence(
                    path: target,
                    parent: RiskPathAnalyzer.parent(of: target, homeDirectory: window.homeDirectory),
                    timestamp: command.startedAt,
                    command: facts.commandLine
                ))
            }
        }

        guard !evidence.isEmpty else { return [] }

        var buckets: [String: [DFOOutsideWriteEvidence]] = [:]
        for item in evidence {
            buckets[item.parent, default: []].append(item)
        }
        let parents = buckets.keys.sorted()

        var findings: [RiskFinding] = []
        if parents.count > Self.parentGroupLimit {
            // 父目录过于分散：折叠成一条 mixed，避免同一根因刷屏。
            findings.append(finding(label: "mixed", items: evidence, window: window))
        } else {
            for parent in parents {
                guard let items = buckets[parent], !items.isEmpty else { continue }
                findings.append(finding(label: parent, items: items, window: window))
            }
        }
        return DFOHelper.collapse(findings)
    }

    /// 把一组同父目录的越界证据转成一条命中。
    private func finding(label: String, items: [DFOOutsideWriteEvidence], window: RiskFactWindow) -> RiskFinding {
        let paths = DFOHelper.paths(items.map(\.path))
        let timestamp = items.map(\.timestamp).min() ?? window.start
        let command = items.compactMap(\.command).first
        let hitsSystemPath = items.contains { RiskPathAnalyzer.isSystemPath($0.path, homeDirectory: window.homeDirectory) }
        // 条数递增 + 落到系统目录本身即 HIGH，两者取更高。
        let level = DFOHelper.higher(
            items.count >= Self.highEvidenceCount ? .high : .medium,
            hitsSystemPath ? .high : .low
        )
        let detail = identity.rationale(filling: [
            "count": String(items.count),
            "parent": label,
            "path": paths.first ?? "（无路径）",
            "commandSuffix": command.map { "，触发命令 \($0)" } ?? "",
        ])
        return makeFinding(from: RiskFindingDraft(
            level: level,
            detail: detail,
            category: hitsSystemPath ? .systemFileModification : nil,
            title: nil,
            confidence: DFOHelper.confidence(base: 0.65, evidence: items.count),
            timestamp: timestamp,
            filePaths: paths,
            command: command,
            sessionID: window.sessionID,
            agentID: window.agentIDs.first,
            agentKind: window.agentKind,
            suppressionKey: "outside-project-deletion:\(label)",
            evidenceCount: items.count,
            evidenceSpan: span(of: items.map(\.timestamp))
        ))
    }

    /// 组内证据的时间跨度，无跨度时返回 nil。
    private func span(of timestamps: [Date]) -> TimeInterval? {
        guard let first = timestamps.min(), let last = timestamps.max() else { return nil }
        let value = last.timeIntervalSince(first)
        return value > 0 ? value : nil
    }
}

// MARK: - 4. Overwrite rewrite

/// 覆盖式重写：单条 `modified` 事实移除行数达到 `thresholds.overwriteRemovedLines`，
/// 或（有原始体积时）体积收缩比例达到 `thresholds.overwriteRatio` → MEDIUM；
/// 若该路径同时落在允许写入根之外则升为 HIGH。
public struct DFOOverwriteRewriteRule: AgentRiskRule {

    public init() {}

    private static let ruleIdentity = RiskRuleIdentity(
        id: "risk.destructive.overwrite-rewrite",
        family: .destructiveFileOperation,
        category: .massDeletion,
        title: "文件被覆盖式重写",
        rationaleTemplate: "{path} 被覆盖式重写：本次移除 {removed} 行{ratioText}，重写后剩余 {size}。原有内容可能已不可恢复。",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "按行数与体积收缩比例识别整文件重写；越界重写升级为 HIGH。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 只看写类事实，等级由本规则按证据推导。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(levelFloor: .low, defersToTelemetryClassification: false, requiresWriteEvidence: true)
    }

    /// 在窗口内产出覆盖式重写命中（每个被重写的路径一条）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var buckets: [String: [FileChange]] = [:]
        var order: [String] = []
        for change in window.modifications {
            let path = DFOHelper.normalized(change.path, in: window)
            guard !path.isEmpty, isOverwrite(change, window: window) else { continue }
            if buckets[path] == nil { order.append(path) }
            buckets[path, default: []].append(change)
        }

        var findings: [RiskFinding] = []
        for path in order {
            guard let items = buckets[path], let primary = strongest(items) else { continue }
            let outsideRoot = !window.isWithinAllowedWriteRoots(path)
            let level: RiskLevel = outsideRoot ? .high : .medium
            let removed = maxLinesRemoved(items)
            let detail = identity.rationale(filling: [
                "path": path,
                "removed": String(removed),
                "ratioText": ratioText(for: primary),
                "size": DFOHelper.byteText(primary.sizeBytes),
            ])
            findings.append(makeFinding(from: RiskFindingDraft(
                level: level,
                detail: outsideRoot ? detail + " 该路径位于允许写入根之外。" : detail,
                confidence: DFOHelper.confidence(base: outsideRoot ? 0.75 : 0.68, evidence: removed / Swift.max(1, window.thresholds.overwriteRemovedLines)),
                timestamp: items.map(\.timestamp).min() ?? window.start,
                filePaths: [path],
                command: nil,
                sessionID: window.sessionID,
                agentID: window.agentIDs.first,
                agentKind: window.agentKind,
                suppressionKey: "overwrite-rewrite:\(path)",
                evidenceCount: items.count,
                evidenceSpan: nil
            )))
        }
        return DFOHelper.collapse(findings)
    }

    /// 该次变更是否构成"覆盖式重写"。
    ///
    /// TODO(contract-gap): 契约 `FileChange` 只有 `linesAdded/linesRemoved` 与
    /// `sizeBytes/previousSizeBytes`，没有"原文件总行数"，因此 `overwriteRatio`
    /// 用**字节收缩比例**近似"移除行数占原文件行数比例"。
    private func isOverwrite(_ change: FileChange, window: RiskFactWindow) -> Bool {
        if change.linesRemoved >= Swift.max(1, window.thresholds.overwriteRemovedLines) { return true }
        guard let previous = change.previousSizeBytes, previous > 0 else { return false }
        return shrinkRatio(of: change, previous: previous) >= window.thresholds.overwriteRatio
    }

    /// 体积收缩比例（0…1），无原始体积时返回 0。
    private func shrinkRatio(of change: FileChange, previous: UInt64) -> Double {
        let before = Double(previous)
        guard before > 0 else { return 0 }
        let after = Double(change.sizeBytes)
        return Swift.max(0, (before - after) / before)
    }

    /// 理由文本里的占比片段。
    private func ratioText(for change: FileChange) -> String {
        guard let previous = change.previousSizeBytes, previous > 0 else { return "" }
        return "，体积收缩 \(DFOHelper.percentText(shrinkRatio(of: change, previous: previous)))"
            + "（原 \(DFOHelper.byteText(previous))）"
    }

    /// 同一路径的多条变更里，取证据最强的一条（先比移除行数，再比剩余体积）。
    private func strongest(_ items: [FileChange]) -> FileChange? {
        items.max { lhs, rhs in
            if lhs.linesRemoved != rhs.linesRemoved { return lhs.linesRemoved < rhs.linesRemoved }
            if lhs.sizeBytes != rhs.sizeBytes { return lhs.sizeBytes > rhs.sizeBytes }
            return lhs.timestamp < rhs.timestamp
        }
    }

    /// 同一路径各次变更里最大的移除行数。
    private func maxLinesRemoved(_ items: [FileChange]) -> Int {
        items.map(\.linesRemoved).max() ?? 0
    }
}

// MARK: - 5. Home subtree deletion

/// 主目录子树删除：删除命令或删除事实指向 home 一级子目录（`~/Documents`、`~/Desktop`、
/// `~/Pictures`、`~/Downloads`、`~/Movies`、`~/Music` 等）→ **HIGH**；
/// 命中 home 根本身（含 `rm -rf ~`）→ **CRITICAL**。本规则始终要求用户确认。
public struct DFOHomeSubtreeDeletionRule: AgentRiskRule {

    public init() {}

    private static let ruleIdentity = RiskRuleIdentity(
        id: "risk.destructive.home-subtree-deletion",
        family: .destructiveFileOperation,
        category: .massDeletion,
        title: "删除动作指向主目录子树",
        rationaleTemplate: "{count} 条删除动作指向主目录一级子目录 `{dir}`（示例 {path}{commandSuffix}），属于用户数据区，删除后通常不可恢复。",
        defaultLevel: .high,
        requiresConfirmation: true,
        summary: "home 一级子目录（Documents/Desktop/Pictures/Downloads…）的删除命令或删除事实；命中 home 根升级为 CRITICAL。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 命中即不低于 HIGH，且 `identity.requiresConfirmation` 恒为 true（AGENTS.md 第 7 条）。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(levelFloor: .high, defersToTelemetryClassification: false, requiresWriteEvidence: true)
    }

    /// 在窗口内产出主目录子树删除命中（每个一级子目录一条）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var evidence: [DFOHomeSubtreeEvidence] = []

        // (a) 删除类文件事实。
        for change in window.deletions {
            if let item = classify(change.path, window: window, timestamp: change.timestamp, command: nil) {
                evidence.append(item)
            }
        }

        // (b) 删除类命令的目标路径（`~` 用窗口注入的 homeDirectory 展开）。
        for command in window.sortedCommands {
            let facts = RiskCommandFacts(command, homeDirectory: window.homeDirectory)
            guard DFOHelper.isDeletionCommand(facts) else { continue }
            if facts.targetsHomeRoot {
                evidence.append(DFOHomeSubtreeEvidence(
                    subtree: "home",
                    targetsHomeRoot: true,
                    path: DFOHelper.home(in: window),
                    timestamp: command.startedAt,
                    command: facts.commandLine,
                    depth: 0
                ))
                continue
            }
            for target in facts.targetPaths {
                if let item = classify(target, window: window, timestamp: command.startedAt, command: facts.commandLine) {
                    evidence.append(item)
                }
            }
        }

        guard !evidence.isEmpty else { return [] }

        var buckets: [String: [DFOHomeSubtreeEvidence]] = [:]
        var order: [String] = []
        for item in evidence {
            if buckets[item.subtree] == nil { order.append(item.subtree) }
            buckets[item.subtree, default: []].append(item)
        }

        var findings: [RiskFinding] = []
        for subtree in order.sorted() {
            guard let items = buckets[subtree], let first = items.first else { continue }
            let hitsHomeRoot = items.contains { $0.targetsHomeRoot }
            let level: RiskLevel = hitsHomeRoot ? .critical : .high
            let paths = DFOHelper.paths(items.map(\.path))
            let command = items.compactMap(\.command).first
            let detail = identity.rationale(filling: [
                "dir": hitsHomeRoot ? "~（主目录本身）" : subtree,
                "count": String(items.count),
                "path": paths.first ?? "（无路径）",
                "commandSuffix": command.map { "，触发命令 \($0)" } ?? "",
            ])
            findings.append(makeFinding(from: RiskFindingDraft(
                level: level,
                detail: hitsHomeRoot ? "删除动作直接指向主目录根 \(first.path)（同窗口 \(items.count) 条证据），影响范围为用户全部数据。" : detail,
                category: hitsHomeRoot ? .systemFileModification : nil,
                title: nil,
                confidence: hitsHomeRoot ? 0.95 : DFOHelper.confidence(base: items.contains { $0.depth == 0 } ? 0.88 : 0.7, evidence: items.count),
                timestamp: items.map(\.timestamp).min() ?? window.start,
                filePaths: paths,
                command: command,
                sessionID: window.sessionID,
                agentID: window.agentIDs.first,
                agentKind: window.agentKind,
                suppressionKey: "home-subtree-deletion:\(subtree)",
                evidenceCount: items.count,
                evidenceSpan: span(of: items.map(\.timestamp))
            )))
        }
        return DFOHelper.collapse(findings)
    }

    /// 判定一条删除目标是否落在 home 一级子目录内。
    ///
    /// 一级子目录本身（`~/Documents`）恒命中；更深层的路径只有在**不落在允许写入根内**
    /// 时才命中，避免把项目内的常规删除也判成用户数据破坏。
    private func classify(
        _ rawPath: String,
        window: RiskFactWindow,
        timestamp: Date,
        command: String?
    ) -> DFOHomeSubtreeEvidence? {
        let path = DFOHelper.normalized(rawPath, in: window)
        guard !path.isEmpty else { return nil }
        if DFOHelper.isHomeRootPath(path, in: window) {
            return DFOHomeSubtreeEvidence(
                subtree: "home",
                targetsHomeRoot: true,
                path: path,
                timestamp: timestamp,
                command: command,
                depth: 0
            )
        }
        let parent = RiskPathAnalyzer.parent(of: path, homeDirectory: window.homeDirectory)
        if parent == DFOHelper.home(in: window) {
            return DFOHomeSubtreeEvidence(
                subtree: RiskPathAnalyzer.fileName(of: path),
                targetsHomeRoot: false,
                path: path,
                timestamp: timestamp,
                command: command,
                depth: 0
            )
        }
        guard !window.isWithinAllowedWriteRoots(path) else { return nil }
        guard let root = DFOHelper.homeSubtreeRoot(of: path, in: window) else { return nil }
        return DFOHomeSubtreeEvidence(
            subtree: RiskPathAnalyzer.fileName(of: root),
            targetsHomeRoot: false,
            path: path,
            timestamp: timestamp,
            command: command,
            depth: 1
        )
    }

    /// 组内证据的时间跨度，无跨度时返回 nil。
    private func span(of timestamps: [Date]) -> TimeInterval? {
        guard let first = timestamps.min(), let last = timestamps.max() else { return nil }
        let value = last.timeIntervalSince(first)
        return value > 0 ? value : nil
    }
}

// MARK: - 6. File truncation burst

/// 批量截断：窗口内被写成 0 字节的**不同路径**数 ≥ 3 → MEDIUM。
/// 证据来源为 `modified` 且 `sizeBytes == 0` 的变更，以及 `truncate` 命令的目标。
public struct DFOFileTruncationBurstRule: AgentRiskRule {

    public init() {}

    /// 判定"批量截断"所需的 0 字节路径数。
    /// TODO(contract-gap): `RiskThresholds` 暂无该阈值字段，先取常量 3。
    private static let minimumTruncatedFiles = 3

    private static let ruleIdentity = RiskRuleIdentity(
        id: "risk.destructive.file-truncation-burst",
        family: .destructiveFileOperation,
        category: .massDeletion,
        title: "批量把文件截断为空",
        rationaleTemplate: "{count} 个文件被截断为 0 字节：{path}{more}，原有内容已全部丢失。",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "统计 modified 后 sizeBytes == 0 的不同路径数（含 truncate 命令目标），达到 3 个即命中。"
    )

    /// 规则身份。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 只依赖写类事实。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(levelFloor: .low, defersToTelemetryClassification: false, requiresWriteEvidence: true)
    }

    /// 在窗口内产出 0 条或 1 条截断命中。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        var buckets: [String: Date] = [:]
        var order: [String] = []

        for change in window.modifications {
            guard change.sizeBytes == 0, change.linesAdded == 0 else { continue }
            let path = DFOHelper.normalized(change.path, in: window)
            guard !path.isEmpty, buckets[path] == nil else { continue }
            buckets[path] = change.timestamp
            order.append(path)
        }

        // `truncate -s 0 <file>` / `truncate --size 0 <file>`：命令侧证据同样计入。
        for command in window.sortedCommands {
            let facts = RiskCommandFacts(command, homeDirectory: window.homeDirectory)
            guard facts.effectiveExecutable == "truncate" else { continue }
            guard facts.operands.contains("0") || facts.hasShortFlag("s") || facts.hasLongFlag("size") else { continue }
            for target in facts.targetPaths {
                guard !target.isEmpty, buckets[target] == nil else { continue }
                buckets[target] = command.startedAt
                order.append(target)
            }
        }

        guard order.count >= Self.minimumTruncatedFiles else { return [] }

        let sorted = order.sorted()
        let shown = Array(sorted.prefix(3)).joined(separator: "、")
        let detail = identity.rationale(filling: [
            "count": String(sorted.count),
            "path": shown,
            "more": sorted.count > 3 ? " 等 \(sorted.count) 个路径" : "",
        ])
        let timestamp: Date = sorted.compactMap { buckets[$0] }.min() ?? window.start
        return [makeFinding(from: RiskFindingDraft(
            level: .medium,
            detail: detail,
            confidence: DFOHelper.confidence(base: 0.62, evidence: sorted.count),
            timestamp: timestamp,
            filePaths: DFOHelper.paths(sorted),
            command: nil,
            sessionID: window.sessionID,
            agentID: window.agentIDs.first,
            agentKind: window.agentKind,
            suppressionKey: "file-truncation",
            evidenceCount: sorted.count,
            evidenceSpan: span(of: sorted.compactMap { buckets[$0] })
        ))]
    }

    /// 证据时间跨度，无跨度时返回 nil。
    private func span(of timestamps: [Date]) -> TimeInterval? {
        guard let first = timestamps.min(), let last = timestamps.max() else { return nil }
        let value = last.timeIntervalSince(first)
        return value > 0 ? value : nil
    }
}

// MARK: - Family façade

/// A 破坏性文件操作。规则 id 前缀 `risk.destructive.*`。
public enum DestructiveFileOperationRules: Sendable {

    /// 本族全部规则，按声明顺序参与聚合（聚合层负责排序与去重）。
    public static let all: [any AgentRiskRule] = [
        DFOMassDeletionWindowRule(),
        DFODirectoryWipeRule(),
        DFOOutsideProjectWriteRule(),
        DFOOverwriteRewriteRule(),
        DFOHomeSubtreeDeletionRule(),
        DFOFileTruncationBurstRule(),
    ]
}
