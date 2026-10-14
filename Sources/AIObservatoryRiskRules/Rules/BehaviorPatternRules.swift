//
//  BehaviorPatternRules.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk —— D 行为模式族
//
//  本文件实现 D 族 7 条会话级「行为模式」聚合规则（id 前缀 `risk.pattern.*`，全局编号 27…33）：
//
//   27. `off-hours-high-frequency`     —— 非工作时间内的活动密度异常
//   28. `repeated-file-thrashing`      —— 同一路径被抖动式反复修改
//   29. `cross-project-boundary-write` —— 写入越到另一个已知项目根
//   30. `sustained-cpu-peak`           —— 连续采样构成的 CPU 高峰
//   31. `excessive-memory-peak`        —— 内存峰值超阈值
//   32. `long-running-command`         —— 超长前台命令（伴破坏性则升级）
//   33. `bulk-read-then-egress`        —— 先批量读取、后出现网络请求的外发模式
//
//  实现约束（与 A/B/C 族一致，全部为纯函数）：
//   · 不读 `Date()`、不访问文件系统、不用随机数、不读环境变量，也不 import Platform/Engine/Store。
//     home / calendar / start / end / thresholds / `otherProjectRoots` 一律取自注入的 `RiskFactWindow`；
//     需要路径判定复用 `RiskPathAnalyzer` / `RiskCommandFacts` / `RiskCommandClassifier`。
//   · 命中时间戳一律来自证据事实（时间簇起点、采样时间、命令 `startedAt`、事件时间），
//     只有在证据本身不带时间戳时（`AgentSession.peakMemoryBytes`）才回落到会话边界，并标注 TODO。
//   · 每条规则内部按 `suppressionKey` 折叠为一条（`RiskFinding.merged(with:)`，等级只升不降），
//     输出前按 (时间, 抑制键) 稳定排序，因此同一窗口重复评估产出逐字节相同的结果。
//

import Foundation
import AIObservatoryCore

// MARK: - Shared helpers

/// 一条「写」证据：文件写类变更，或写意图命令命中的目标路径。
private struct BPTWriteEvidence {
    /// 已用注入 home 归一化的绝对路径。
    var path: String
    /// 证据时间（变更时间戳 / 命令开始时间）。
    var timestamp: Date
    /// 命令来源的原始文本；文件类证据为 nil。
    var command: String?
    /// 事实自带的会话 ID，可能为 nil。
    var sessionID: UUID?
    /// 事实自带的 Agent 实例 ID，可能为 nil。
    var agentID: UUID?
    /// 事实自带的 Agent 类型。
    var agentKind: AgentKind
}

/// D 族规则共用的纯函数工具。文件私有，不进入模块公共 API。
private enum BPTSupport {

    /// 会写入 / 删除其路径参数的可执行名（已剥掉 `sudo` 等包装器后的真实命令名）。
    /// `RiskCommandClassifier.writeTargets` 只做结构性过滤、不回答"读还是写"，故本族自带这张小意图表。
    static let writeIntentExecutables: Set<String> = [
        "rm", "rmdir", "unlink", "shred", "mv", "cp", "dd", "tee", "touch", "truncate",
        "install", "rsync", "tar", "unzip", "ditto", "ln", "chmod", "chown", "chgrp",
        "patch", "sed", "launchctl", "defaults", "security", "kextload", "pfctl",
        "tccutil", "nvram", "spctl"
    ]

    /// 判定"批量读取"所需的**不同路径**条数下限。
    /// TODO(contract-gap): `RiskThresholds` 未提供"批量读取路径数"与"外发字节数"阈值字段，
    /// 本族先按规则文档固化字面量 20，待基础设施补 `bulkReadPathCount` / `egressBytes` 后改为注入。
    static let bulkReadPathFloor = 20

    /// 用注入的 home 归一化路径（避免 `RiskPathAnalyzer` 无 home 参数的重载读到真实 `NSHomeDirectory()`）。
    static func normalized(_ path: String, in window: RiskFactWindow) -> String {
        RiskPathAnalyzer.normalized(path, homeDirectory: window.homeDirectory)
    }

    /// 置信度裁剪到 0.5…0.95 之间。
    static func confidence(_ value: Double) -> Double {
        Swift.min(Swift.max(value, 0.5), 0.95)
    }

    /// 证据越多置信度越高（每条 +0.005，最多按 40 条计）。
    static func confidence(base: Double, evidence count: Int) -> Double {
        confidence(base + Double(Swift.min(Swift.max(count, 1), 40)) * 0.005)
    }

    /// 去重 + 字典序 + 截断的路径列表，保证 `filePaths` 与 detail 的确定性。
    static func paths(_ values: [String], limit: Int = 8) -> [String] {
        Array(Set(values).sorted().prefix(limit))
    }

    /// 路径摘要文本（超过 1 条时标注总数）。
    static func pathSummary(_ values: [String], fallback: String) -> String {
        guard let first = values.first else { return fallback }
        if values.count <= 1 { return first }
        return first + " 等 \(values.count) 个路径"
    }

    /// 秒数可读文本。
    static func secondText(_ value: TimeInterval) -> String {
        String(format: "%.0f", value) + " 秒"
    }

    /// 一位小数的速率/比例文本。
    static func rateText(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// 百分比文本（输入为 0…100 的百分数）。
    static func percentText(_ percent: Double) -> String {
        String(format: "%.0f", percent)
    }

    /// 字节数可读文本。
    static func byteText(_ value: UInt64) -> String {
        let bytes = Double(value)
        if bytes >= 1_073_741_824 { return String(format: "%.2f GB", bytes / 1_073_741_824) }
        if bytes >= 1_048_576 { return String(format: "%.1f MB", bytes / 1_048_576) }
        if bytes >= 1_024 { return String(format: "%.0f KB", bytes / 1_024) }
        return "\(value) 字节"
    }

    /// 用注入的日历渲染 `yyyy-MM-dd HH:mm:ss`（不读墙钟、不依赖设备时区）。
    static func clockText(_ date: Date, in window: RiskFactWindow) -> String {
        let parts = window.calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0,
            parts.second ?? 0
        )
    }

    /// 事实自带的 Agent 类型优先；未标注（`.unknown`）时回落到窗口级 Agent 类型。
    static func kind(_ kind: AgentKind, in window: RiskFactWindow) -> AgentKind {
        kind == .unknown ? window.agentKind : kind
    }

    /// 汇总窗口内的「写」证据：文件写类变更（新建 / 修改 / 重命名）+ 写意图命令的目标路径。
    static func writeEvidence(in window: RiskFactWindow) -> [BPTWriteEvidence] {
        var out: [BPTWriteEvidence] = []

        for change in window.writes {
            let path = normalized(change.path, in: window)
            guard !path.isEmpty else { continue }
            out.append(BPTWriteEvidence(
                path: path,
                timestamp: change.timestamp,
                command: nil,
                sessionID: change.sessionID,
                agentID: change.agentID,
                agentKind: change.agentKind
            ))
        }

        let classifier = RiskCommandClassifier()
        for record in window.sortedCommands {
            let facts = RiskCommandFacts(record, homeDirectory: window.homeDirectory)
            guard writeIntentExecutables.contains(facts.effectiveExecutable) else { continue }
            for target in classifier.writeTargets(facts) {
                let path = normalized(target, in: window)
                guard !path.isEmpty else { continue }
                out.append(BPTWriteEvidence(
                    path: path,
                    timestamp: record.startedAt,
                    command: record.commandLine,
                    sessionID: record.sessionID,
                    agentID: record.agentID,
                    agentKind: record.agentKind
                ))
            }
        }

        return out.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            if lhs.path != rhs.path { return lhs.path < rhs.path }
            return (lhs.command ?? "") < (rhs.command ?? "")
        }
    }

    /// 同抑制键折叠为一条，再按 (时间, 抑制键) 稳定排序，保证跨批次确定性。
    static func finalize(_ findings: [RiskFinding]) -> [RiskFinding] {
        guard !findings.isEmpty else { return [] }
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
        let collapsed = order.compactMap { buckets[$0] }
        return collapsed.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.suppressionKey < rhs.suppressionKey
        }
    }
}

// MARK: - 27. 非工作时间高频活动

/// `risk.pattern.off-hours-high-frequency` —— 非工作时间内的活动密度过高。
///
/// 对**全部已排序事件**按 `thresholds.massDeletionSpan`（默认 60 秒）贪心聚簇；
/// 簇起点落在 `window.isOffHours(_:)` 区间、且簇内每分钟事件数 ≥ `thresholds.offHoursEventRate` 时命中。
/// 由于簇跨度恒 ≤ span，"每分钟 ≥ 阈值" 实际等价于"簇内条数 ≥ 阈值"，
/// 故另加一条 `簇内条数 ≥ ceil(offHoursEventRate)` 的下限：
/// `RiskCluster.ratePerSecond` 在单元素簇（跨度为 0）时按条数返回，
/// 缺这条下限会把"深夜只留下 1 条事件"误报成高密度。
public struct BPTOffHoursHighFrequencyRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.pattern.off-hours-high-frequency",
        family: .activityPattern,
        category: .unknown,
        title: "非工作时间高频活动",
        rationaleTemplate: "{hour} 时段（非工作时间）的 {span} 内产生了 {count} 条事件，平均每分钟 {rate} 条，超过密度阈值 {threshold} 条（簇起点 {cluster}）。",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "非工作时间（默认 23:00–06:00）内出现每分钟事件数超过阈值的密集活动。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 活动密度结论与本规则自带的阈值有关，不复用上游命令分级。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(defersToTelemetryClassification: false)
    }

    /// 每个命中的非工作时间事件簇产出 1 条 MEDIUM 命中。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let events = window.sortedEvents
        guard !events.isEmpty else { return [] }
        let rateThreshold = window.thresholds.offHoursEventRate
        guard rateThreshold > 0 else { return [] }
        let span = window.thresholds.massDeletionSpan
        guard span > 0 else { return [] }
        let minimumCount = Swift.max(2, Int(rateThreshold.rounded(.up)))
        let sessionID = window.sessionID
        let agentID = window.agentIDs.first

        var findings: [RiskFinding] = []
        for cluster in window.temporalClusters(events, span: span, timestamp: { $0.timestamp }) {
            guard cluster.count >= minimumCount, window.isOffHours(cluster.start) else { continue }
            let perMinute = cluster.ratePerSecond * 60
            guard perMinute >= rateThreshold else { continue }
            let hour = window.hour(of: cluster.start)
            findings.append(makeFinding(from: RiskFindingDraft(
                level: .medium,
                detail: identity.rationale(filling: [
                    "hour": String(format: "%02d:00", hour),
                    "span": BPTSupport.secondText(span),
                    "count": String(cluster.count),
                    "rate": BPTSupport.rateText(perMinute),
                    "threshold": BPTSupport.rateText(rateThreshold),
                    "cluster": String(Int(cluster.start.timeIntervalSince1970))
                ]),
                confidence: BPTSupport.confidence(base: 0.6, evidence: cluster.count),
                timestamp: cluster.start,
                filePaths: BPTSupport.paths(
                    cluster.items.compactMap(\.filePath).map { BPTSupport.normalized($0, in: window) }
                ),
                command: cluster.items.lazy.compactMap(\.command).first,
                sessionID: sessionID,
                agentID: agentID,
                agentKind: window.agentKind,
                suppressionKey: "off-hours:\(Int(cluster.start.timeIntervalSince1970)):\(hour)",
                evidenceCount: cluster.count,
                evidenceSpan: cluster.span
            )))
        }
        return BPTSupport.finalize(findings)
    }
}

// MARK: - 28. 同一文件抖动式反复修改

/// `risk.pattern.repeated-file-thrashing` —— 同一路径在短窗内被反复 `.modified`。
///
/// 以 `window.modifications` 按归一化路径分组，组内再按 `thresholds.repeatedEditSpan` 聚簇；
/// 簇内次数 ≥ `thresholds.repeatedEditCount` 命中 MEDIUM，≥ 3 倍阈值升 HIGH。
/// `suppressionKey = file-thrashing:<归一化路径>`，因此同一文件的所有抖动只报 1 条。
public struct BPTRepeatedFileThrashingRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.pattern.repeated-file-thrashing",
        family: .activityPattern,
        category: .unknown,
        title: "同一文件反复抖动修改",
        rationaleTemplate: "{path} 在 {span} 内被反复修改 {count} 次，达到抖动阈值 {threshold} 次。",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "同一路径在短时间窗内被反复改写，通常说明 Agent 陷入自我纠错式的编辑循环。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 只针对写类事实；抖动判定只看文件变更计数，不消费上游命令分级。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(defersToTelemetryClassification: false, requiresWriteEvidence: true)
    }

    /// 每个命中的路径簇产出 1 条命中（同一文件的多个簇按抑制键折叠）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let modifications = window.modifications
        guard !modifications.isEmpty else { return [] }
        let required = Swift.max(2, window.thresholds.repeatedEditCount)
        let span = window.thresholds.repeatedEditSpan
        guard span > 0 else { return [] }
        let windowSessionID = window.sessionID
        let windowAgentID = window.agentIDs.first

        var buckets: [String: [FileChange]] = [:]
        for change in modifications {
            let path = BPTSupport.normalized(change.path, in: window)
            guard !path.isEmpty else { continue }
            buckets[path, default: []].append(change)
        }

        var findings: [RiskFinding] = []
        for path in buckets.keys.sorted() {
            guard let items = buckets[path] else { continue }
            for cluster in window.temporalClusters(items, span: span, timestamp: { $0.timestamp }) {
                guard cluster.count >= required else { continue }
                let level: RiskLevel = cluster.count >= required * 3 ? .high : .medium
                findings.append(makeFinding(from: RiskFindingDraft(
                    level: level,
                    detail: identity.rationale(filling: [
                        "path": path,
                        "span": BPTSupport.secondText(span),
                        "count": String(cluster.count),
                        "threshold": String(required)
                    ]),
                    confidence: BPTSupport.confidence(base: 0.7, evidence: cluster.count),
                    timestamp: cluster.start,
                    filePaths: [path],
                    command: nil,
                    sessionID: windowSessionID,
                    agentID: cluster.items.lazy.compactMap(\.agentID).first ?? windowAgentID,
                    agentKind: window.agentKind,
                    suppressionKey: "file-thrashing:" + path,
                    evidenceCount: cluster.count,
                    evidenceSpan: cluster.span
                )))
            }
        }
        return BPTSupport.finalize(findings)
    }
}

// MARK: - 29. 跨项目边界写入

/// `risk.pattern.cross-project-boundary-write` —— 写入落在**另一个已知项目根**内。
///
/// 判定式为 `!window.isWithinAllowedWriteRoots(path) && window.isWithinOtherProjectRoot(path)`，
/// 根目录取自 `window.matchingOtherProjectRoot(for:)`（`otherProjectRoots` 由调用方注入，本文件不扫盘）。
/// 证据源为 `window.writes`（新建 / 修改 / 重命名）加上写意图命令的目标路径。
/// 等级 HIGH，`requiresConfirmation` 由 `makeFinding` 对 HIGH 及以上自动置真。
/// `suppressionKey = cross-project-write:<otherRoot>`，同一目标根只报 1 条。
public struct BPTCrossProjectBoundaryWriteRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.pattern.cross-project-boundary-write",
        family: .activityPattern,
        category: .sensitivePathAccess,
        title: "跨项目边界写入",
        rationaleTemplate: "写入落在本会话允许范围之外的另一个项目根 {root}：{path}（证据 {count} 条）{note}",
        defaultLevel: .high,
        requiresConfirmation: true,
        summary: "会话把内容写进了另一个项目的根目录，越出了本项目边界，需人工确认。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 不消费上游命令分级；也**不**声明 `requiresWriteEvidence`：
    /// `RiskAssessor` 的预筛只看 `FileChange` 写/删事实，而本规则还要覆盖
    /// "只有写意图命令、没有文件变更事实"的场景，声明该开关会被误筛掉。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(defersToTelemetryClassification: false)
    }

    /// 每个被越界写入的其他项目根产出 1 条 HIGH 命中。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let evidences = BPTSupport.writeEvidence(in: window)
        guard !evidences.isEmpty, !window.otherProjectRoots.isEmpty else { return [] }

        var buckets: [String: [BPTWriteEvidence]] = [:]
        var order: [String] = []
        for evidence in evidences {
            guard !window.isWithinAllowedWriteRoots(evidence.path) else { continue }
            guard window.isWithinOtherProjectRoot(evidence.path) else { continue }
            guard let root = window.matchingOtherProjectRoot(for: evidence.path) else { continue }
            if buckets[root] == nil { order.append(root) }
            buckets[root, default: []].append(evidence)
        }

        var findings: [RiskFinding] = []
        for root in order {
            guard let items = buckets[root], let first = items.first, let last = items.last else { continue }
            let involved = BPTSupport.paths(items.map(\.path))
            let note: String
            if let commandText = items.lazy.compactMap(\.command).first {
                note = "，其中包含写意图命令 \(commandText)"
            } else {
                note = ""
            }
            let span = last.timestamp.timeIntervalSince(first.timestamp)
            findings.append(makeFinding(from: RiskFindingDraft(
                level: .high,
                detail: identity.rationale(filling: [
                    "root": root,
                    "path": BPTSupport.pathSummary(involved, fallback: root),
                    "count": String(items.count),
                    "note": note
                ]),
                confidence: BPTSupport.confidence(base: 0.85, evidence: items.count),
                timestamp: first.timestamp,
                filePaths: involved,
                command: items.lazy.compactMap(\.command).first,
                sessionID: first.sessionID ?? window.sessionID,
                agentID: first.agentID ?? window.agentIDs.first,
                agentKind: BPTSupport.kind(first.agentKind, in: window),
                suppressionKey: "cross-project-write:" + root,
                evidenceCount: items.count,
                evidenceSpan: span > 0 ? span : nil
            )))
        }
        return BPTSupport.finalize(findings)
    }
}

// MARK: - 30. 持续 CPU 高峰

/// `risk.pattern.sustained-cpu-peak` —— 连续采样构成的 CPU 高峰。
///
/// 采样按所属会话 / Agent 分流（`suppressionKey = sustained-cpu:<sessionID 或 agentID 或 "session">`），
/// 每条流内把"相邻且均 ≥ `thresholds.sustainedCPUPercent`"的采样切成运行段；
/// 段时长 = 段内相邻采样的时间差累加（即末减首）+ 段尾一个 `thresholds.sampleInterval` 兜底，
/// 因此单点采样也带一个采样间隔的时长。累计 ≥ `thresholds.sustainedCPUSeconds` 判 MEDIUM，
/// ≥ 2 倍判 HIGH。
public struct BPTSustainedCPUPeakRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.pattern.sustained-cpu-peak",
        family: .activityPattern,
        category: .resourceAbuse,
        title: "持续 CPU 高峰",
        rationaleTemplate: "CPU 连续 {duration} 保持在 {percent}% 以上（阈值 {threshold} 秒，采样 {count} 个）。",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "连续的性能采样显示某会话的 Agent 长时间高占用 CPU，可能失控或死循环。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 资源类结论与上游命令分级无关。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(defersToTelemetryClassification: false)
    }

    /// 每条采样流的每个超标运行段产出 1 条命中（同流内多段按抑制键折叠）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        guard !window.samples.isEmpty else { return [] }
        let limit = window.thresholds.sustainedCPUPercent
        let requiredSeconds = window.thresholds.sustainedCPUSeconds
        guard limit > 0, requiredSeconds > 0 else { return [] }
        let interval = Swift.max(window.thresholds.sampleInterval, 0)
        let windowSessionID = window.sessionID
        let windowAgentID = window.agentIDs.first

        var streams: [String: [PerformanceSample]] = [:]
        var order: [String] = []
        for sample in window.sortedSamples {
            let key = Self.streamKey(for: sample, windowSessionID: windowSessionID)
            if streams[key] == nil { order.append(key) }
            streams[key, default: []].append(sample)
        }

        var findings: [RiskFinding] = []
        for key in order {
            guard let items = streams[key] else { continue }
            for run in Self.highCPURuns(items, atOrAbove: limit) {
                guard let first = run.first, let last = run.last else { continue }
                let gap = Swift.max(last.timestamp.timeIntervalSince(first.timestamp), 0)
                let duration = run.count > 1 ? gap + interval : interval
                guard duration >= requiredSeconds else { continue }
                let level: RiskLevel = duration >= requiredSeconds * 2 ? .high : .medium
                let peakPercent = run.map(\.cpuPercent).max() ?? last.cpuPercent
                findings.append(makeFinding(from: RiskFindingDraft(
                    level: level,
                    detail: identity.rationale(filling: [
                        "duration": BPTSupport.secondText(duration),
                        "percent": BPTSupport.percentText(peakPercent),
                        "threshold": BPTSupport.secondText(requiredSeconds),
                        "count": String(run.count)
                    ]),
                    confidence: BPTSupport.confidence(base: 0.7, evidence: run.count),
                    timestamp: first.timestamp,
                    filePaths: [],
                    command: nil,
                    sessionID: first.sessionID ?? windowSessionID,
                    agentID: first.agentID ?? windowAgentID,
                    agentKind: window.agentKind,
                    suppressionKey: "sustained-cpu:" + key,
                    evidenceCount: run.count,
                    evidenceSpan: duration > 0 ? duration : nil
                )))
            }
        }
        return BPTSupport.finalize(findings)
    }

    /// 采样流标识：优先采样自带 sessionID，其次窗口 sessionID，再次 agentID，最后 "session"。
    fileprivate static func streamKey(for sample: PerformanceSample, windowSessionID: UUID?) -> String {
        if let id = sample.sessionID ?? windowSessionID { return id.uuidString }
        if let id = sample.agentID { return "agent:" + id.uuidString }
        return "session"
    }

    /// 把一条已排序的采样流切成"连续高 CPU"运行段（遇到未超标采样即断段）。
    fileprivate static func highCPURuns(
        _ samples: [PerformanceSample],
        atOrAbove limit: Double
    ) -> [[PerformanceSample]] {
        var runs: [[PerformanceSample]] = []
        var current: [PerformanceSample] = []
        for sample in samples {
            if sample.cpuPercent >= limit {
                current.append(sample)
                continue
            }
            if !current.isEmpty {
                runs.append(current)
                current = []
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs
    }
}

// MARK: - 31. 内存峰值超限

/// `risk.pattern.excessive-memory-peak` —— 采样峰值或会话峰值内存超过阈值。
///
/// 峰值取 `window.samples` 里的最大 `memoryBytes` 与 `session.peakMemoryBytes` 的更高者：
/// ≥ `thresholds.peakMemoryBytes` 判 MEDIUM，≥ 2 倍判 HIGH。
/// `suppressionKey = excessive-memory`，整个窗口只报 1 条。
///
/// ⚠️ **口径：这里的内存是「Agent 进程 ∪ 其全部子进程在同一时刻的合计」，不是单进程。**
/// 这是 #23 有意改的（此前子进程的 CPU/内存每 tick 采完就丢，会话级开销只报了父进程），
/// 所以 `thresholds.peakMemoryBytes` 这个阈值**必须按树合计来理解**：
/// 真机实测一个 Codex 会话有 17+ 个子进程，报出「内存峰值 5.11 GB」时那是整棵树的量，
/// 按单进程去读会得出"某个进程吃了 5 GB"的错误结论（#30 的起因）。
/// 想按单进程判，**另开一条规则**，不要改这条的语义——那会让历史事件的口径漂移。
/// 也不要为了"数字好看"把采样退回只算父进程，那正是 #23 修掉的缺陷。
public struct BPTExcessiveMemoryPeakRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.pattern.excessive-memory-peak",
        family: .activityPattern,
        category: .resourceAbuse,
        title: "内存峰值超限",
        rationaleTemplate: "内存峰值 {peak} 超过阈值 {threshold}（{source}，超限采样 {count} 个）。",
        defaultLevel: .medium,
        requiresConfirmation: false,
        summary: "会话内存峰值（Agent 与其子进程同时刻合计）达到阈值的 1 倍（MEDIUM）或 2 倍（HIGH），提示内存泄漏或无界缓存。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 资源类结论与上游命令分级无关。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(defersToTelemetryClassification: false)
    }

    /// 命中时产出至多 1 条命中（采样证据优先于会话汇总值）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let floorBytes = window.thresholds.peakMemoryBytes
        guard floorBytes > 0 else { return [] }
        let threshold = Double(floorBytes)

        var samplePeak: UInt64 = 0
        var samplePeakAt: Date?
        var overCount = 0
        var firstOverAt: Date?
        var lastOverAt: Date?
        for sample in window.sortedSamples {
            if samplePeakAt == nil || sample.memoryBytes > samplePeak {
                samplePeak = sample.memoryBytes
                samplePeakAt = sample.timestamp
            }
            if Double(sample.memoryBytes) >= threshold {
                overCount += 1
                if firstOverAt == nil { firstOverAt = sample.timestamp }
                lastOverAt = sample.timestamp
            }
        }
        let sessionPeak = window.session?.peakMemoryBytes ?? 0
        let peak = Swift.max(samplePeak, sessionPeak)
        guard peak > 0, Double(peak) >= threshold else { return [] }

        let level: RiskLevel = Double(peak) >= threshold * 2 ? .high : .medium
        let fromSamples = samplePeak >= sessionPeak
        // 口径必须出现在用户看到的这一行里：#23 之后数值是「Agent ∪ 子进程」的同时刻合计，
        // 只写"来自性能采样"会被读成单进程（真机实测有会话报 5.11 GB，其实是 17+ 个进程的树）。
        let source = fromSamples
            ? "来自性能采样，口径为 Agent 与其子进程同时刻合计"
            : "来自会话汇总值，口径同上"

        // TODO(contract-gap): `AgentSession.peakMemoryBytes` 没有配对的采样时间戳字段，
        // 只有会话汇总值可用时只能退化到会话边界时间（仍是事实派生，不读墙钟）。
        let timestamp: Date
        if !fromSamples, let session = window.session {
            timestamp = session.endedAt ?? session.startedAt
        } else if let at = samplePeakAt {
            timestamp = at
        } else {
            timestamp = window.start
        }

        var span: TimeInterval?
        if let first = firstOverAt, let last = lastOverAt {
            let value = last.timeIntervalSince(first)
            span = value > 0 ? value : nil
        }

        let draft = RiskFindingDraft(
            level: level,
            detail: identity.rationale(filling: [
                "peak": BPTSupport.byteText(peak),
                "threshold": BPTSupport.byteText(floorBytes),
                "source": source,
                "count": String(overCount > 0 ? overCount : 1)
            ]),
            confidence: fromSamples ? 0.85 : 0.7,
            timestamp: timestamp,
            filePaths: [],
            command: nil,
            sessionID: window.sessionID,
            agentID: window.agentIDs.first,
            agentKind: window.agentKind,
            suppressionKey: "excessive-memory",
            evidenceCount: overCount > 0 ? overCount : 1,
            evidenceSpan: span
        )
        return BPTSupport.finalize([makeFinding(from: draft)])
    }
}

// MARK: - 32. 超长前台命令

/// `risk.pattern.long-running-command` —— 命令运行时长超过 `thresholds.longRunningCommandSeconds`。
///
/// 时长取 `CommandRecord.duration`（未结束的命令为 nil，按 0 处理，即本条只针对已结束命令）。
/// 基础等级 LOW；若 `window.classification(for:)` 把同一命令判为破坏性，则升 MEDIUM。
/// `suppressionKey = long-running-command:<command.id.uuidString>`，一条命令一条命中。
public struct BPTLongRunningCommandRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.pattern.long-running-command",
        family: .activityPattern,
        category: .resourceAbuse,
        title: "超长前台命令",
        rationaleTemplate: "命令 {command} 运行了 {duration}，超过长时命令阈值 {threshold}{note}。",
        defaultLevel: .low,
        requiresConfirmation: false,
        summary: "单条命令占用前台时间超过阈值；若该命令同时被上游判为破坏性则升为 MEDIUM。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 破坏性判定复用上游（Telemetry / 已落库）的命令分级结论。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(defersToTelemetryClassification: true)
    }

    /// 每条超时命令产出 1 条命中。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let limit = window.thresholds.longRunningCommandSeconds
        guard limit > 0, !window.commands.isEmpty else { return [] }

        let classifier = RiskCommandClassifier()
        var findings: [RiskFinding] = []
        for record in window.sortedCommands {
            guard let seconds = record.duration, seconds >= limit else { continue }
            let classification = window.classification(for: record)
            let isDestructive = classification?.isDestructive == true
            let level: RiskLevel = isDestructive ? .medium : .low
            let note = isDestructive ? "，且上游已判定为破坏性操作" : ""
            var involvedPaths: [String] = []
            if isDestructive {
                let facts = RiskCommandFacts(record, homeDirectory: window.homeDirectory)
                involvedPaths = BPTSupport.paths(classifier.writeTargets(facts))
            }
            findings.append(makeFinding(from: RiskFindingDraft(
                level: level,
                detail: identity.rationale(filling: [
                    "command": record.commandLine,
                    "duration": BPTSupport.secondText(seconds),
                    "threshold": BPTSupport.secondText(limit),
                    "note": note
                ]),
                confidence: BPTSupport.confidence(base: isDestructive ? 0.85 : 0.75, evidence: 1),
                timestamp: record.startedAt,
                filePaths: involvedPaths,
                command: record.commandLine,
                sessionID: record.sessionID ?? window.sessionID,
                agentID: record.agentID ?? window.agentIDs.first,
                agentKind: BPTSupport.kind(record.agentKind, in: window),
                suppressionKey: "long-running-command:" + record.id.uuidString,
                evidenceCount: 1,
                evidenceSpan: seconds > 0 ? seconds : nil
            )))
        }
        return BPTSupport.finalize(findings)
    }
}

// MARK: - 33. 批量读取后外发

/// `risk.pattern.bulk-read-then-egress` —— 先批量读取、随后出现网络请求。
///
/// 读取事实取 `window.readEvents`（`OperationKind.fileRead` 的 `filePath`；
/// 契约层没有独立的"读取"记录类型，故本族不再扩展其它来源）。
/// 按已排序序列推进：不同路径数首次达到 `BPTSupport.bulkReadPathFloor`（20）的时刻记为"批量读取完成"，
/// 之后（严格晚于该时刻）存在 `OperationKind.networkRequest` 事件即命中 HIGH。
/// 时间先后完全由已排序序列决定，因此结果确定；外发事件带 `cost` 字节数时提高置信度。
public struct BPTBulkReadThenEgressRule: AgentRiskRule {

    /// 规则静态身份。
    public static let ruleIdentity = RiskRuleIdentity(
        id: "risk.pattern.bulk-read-then-egress",
        family: .activityPattern,
        category: .networkExfiltration,
        title: "批量读取后网络外发",
        rationaleTemplate: "窗口内读取了 {count} 个不同路径（判定阈值 {threshold} 个），随后在 {egress} 出现网络请求：{target}（传输量 {bytes}）。构成批量读取后外发的数据外发模式。",
        defaultLevel: .high,
        requiresConfirmation: false,
        summary: "短时间内读取大量不同文件，之后出现网络请求，符合凭据/源码打包外发的行为链。"
    )

    /// 无存储状态的规则，可直接构造。
    public init() {}

    /// 规则身份（转发到本类型的静态常量）。
    public var identity: RiskRuleIdentity { Self.ruleIdentity }

    /// 行为链判定完全基于窗口内事件序列，不依赖命令分级。
    public var preferences: RiskRulePreferences {
        RiskRulePreferences(defersToTelemetryClassification: false)
    }

    /// 命中时产出 1 条 HIGH 命中（时间戳取外发事件）。
    public func findings(in window: RiskFactWindow) -> [RiskFinding] {
        let reads = window.readEvents
        let required = Swift.max(2, BPTSupport.bulkReadPathFloor)
        guard reads.count >= required else { return [] }

        var seen = Set<String>()
        var orderedPaths: [String] = []
        var firstReadAt: Date?
        var bulkCompletedAt: Date?
        for event in reads {
            guard let raw = event.filePath, !raw.isEmpty else { continue }
            let path = BPTSupport.normalized(raw, in: window)
            guard !path.isEmpty, !seen.contains(path) else { continue }
            seen.insert(path)
            if firstReadAt == nil { firstReadAt = event.timestamp }
            orderedPaths.append(path)
            if bulkCompletedAt == nil, orderedPaths.count >= required {
                bulkCompletedAt = event.timestamp
            }
        }
        guard let completedAt = bulkCompletedAt, let startedAt = firstReadAt else { return [] }

        var egressEvent: TimelineEvent?
        for event in window.sortedEvents where event.kind == .networkRequest {
            if event.timestamp > completedAt {
                egressEvent = event
                break
            }
        }
        guard let egress = egressEvent else { return [] }

        let egressBytes = Swift.max(egress.cost.bytesRead, egress.cost.bytesWritten)
        let target = egress.command ?? (egress.summary.isEmpty ? egress.title : egress.summary)
        let span = Swift.max(egress.timestamp.timeIntervalSince(startedAt), 0)
        let draft = RiskFindingDraft(
            level: .high,
            detail: identity.rationale(filling: [
                "count": String(orderedPaths.count),
                "threshold": String(required),
                "egress": BPTSupport.clockText(egress.timestamp, in: window),
                "target": target,
                "bytes": BPTSupport.byteText(egressBytes)
            ]),
            confidence: BPTSupport.confidence(base: egressBytes > 0 ? 0.85 : 0.75, evidence: orderedPaths.count),
            timestamp: egress.timestamp,
            filePaths: Array(orderedPaths.prefix(12)),
            command: egress.command,
            sessionID: egress.sessionID ?? window.sessionID,
            agentID: egress.agentID ?? window.agentIDs.first,
            agentKind: BPTSupport.kind(egress.agentKind, in: window),
            suppressionKey: "bulk-read-then-egress",
            evidenceCount: orderedPaths.count + 1,
            evidenceSpan: span > 0 ? span : nil
        )
        return BPTSupport.finalize([makeFinding(from: draft)])
    }
}

// MARK: - Family façade

/// D 行为模式。规则 id 前缀 `risk.pattern.*`。
public enum BehaviorPatternRules: Sendable {

    /// 本族全部规则，按声明顺序参与聚合（聚合层负责排序与去重）。
    public static let all: [any AgentRiskRule] = [
        BPTOffHoursHighFrequencyRule(),
        BPTRepeatedFileThrashingRule(),
        BPTCrossProjectBoundaryWriteRule(),
        BPTSustainedCPUPeakRule(),
        BPTExcessiveMemoryPeakRule(),
        BPTLongRunningCommandRule(),
        BPTBulkReadThenEgressRule()
    ]
}
