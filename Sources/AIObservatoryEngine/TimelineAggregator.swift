//
//  TimelineAggregator.swift
//  AIObservatoryEngine — 时间线聚合子模块
//
//  Owner: WS-Engine
//  Sub-owner: C
//
//  ─────────────────────────────────────────────────────────
//  采集器原始产出（AgentInstance / FileChange / CommandRecord / RiskEvent /
//  ResourceCost）→ `TimelineEvent`。**纯函数、无状态**：会话归属、去抖、
//  累计统计都由 `SessionLifecycleManager` 负责，本类型只做映射与字段透传。
//
//  ## 映射表
//  | 输入 | OperationKind |
//  | --- | --- |
//  | `AgentInstance` 上线 | `.agentStarted` |
//  | `AgentInstance` 下线 | `.agentStopped` |
//  | `FileChange.created`  | `.fileCreated` |
//  | `FileChange.modified` | `.fileModified` |
//  | `FileChange.deleted`  | `.fileDeleted` |
//  | `FileChange.renamed`  | `.fileRenamed` |
//  | `FileChange.unknown`  | `.unknown` |
//  | `CommandRecord`，`executable` 为 `git` | `.gitOperation` |
//  | 其余 `CommandRecord`（含 `curl`/`wget`/`nc` 等网络类命令）| `.commandExecuted` |
//  | `RiskEvent` | `.riskDetected` |
//
//  > 网络类命令**不**映射为 `.networkRequest`：该 kind 只留给真正的网络事件
//  > （由网络计数器采集器产出），命令一律保持 `.commandExecuted`，避免过度设计。
//
//  ## 字段口径
//  · `sessionID` / `agentID` / `agentKind` 全部从入参透传，入参缺失就是 nil，不猜测。
//    `agentStarted` / `agentStopped` 由 manager 事后补 `sessionID`（本类型不知道会话）。
//  · `projectPath` 由 `ProjectMapper.projectPath(for:)` 补齐；命中忽略规则 → nil；
//    映射不出来时退回入参自带的 `projectPath`（可能为 nil）。
//  · `cost`：只有进程级快照能给出 `memoryBytes`，其余场景一律 `ResourceCost.zero`，
//    绝不凭空填 cpuSeconds。
//  · 命令事件的 `riskLevel` 取「传入值与命令自带值的较高者」，外部风险管线可覆盖上调。
//

import Foundation
import AIObservatoryCore

/// 采集器原始产出 → `TimelineEvent`；纯函数，不持状态。
public struct TimelineAggregator: Sendable {

    private let projectMapper: ProjectMapper

    /// 以项目映射器初始化（默认 `ProjectMapper()`）。
    public init(projectMapper: ProjectMapper = ProjectMapper()) {
        self.projectMapper = projectMapper
    }

    // MARK: - Agent presence

    /// Agent 上线事件。`cost` 只带该时刻实测到的常驻内存，`cpuSeconds` 为 0（无区间依据）。
    public func agentStarted(_ agent: AgentInstance, at date: Date) -> TimelineEvent {
        TimelineEvent(
            timestamp: date,
            agentID: agent.id,
            agentKind: agent.kind,
            kind: .agentStarted,
            title: "\(OperationKind.agentStarted.displayName) · \(agent.displayName)",
            summary: "pid \(agent.pid) · 识别依据：\(agent.detectedVia.displayName)",
            cost: Self.instantaneousCost(of: agent),
            projectPath: resolvedProjectPath(for: agent.workingDirectory, fallback: nil)
        )
    }

    /// Agent 下线事件；`summary` 内给出从 `startedAt` 到 `date` 的存活时长。
    public func agentStopped(_ agent: AgentInstance, at date: Date) -> TimelineEvent {
        let lifetime = max(0, date.timeIntervalSince(agent.startedAt))
        return TimelineEvent(
            timestamp: date,
            agentID: agent.id,
            agentKind: agent.kind,
            kind: .agentStopped,
            title: "\(OperationKind.agentStopped.displayName) · \(agent.displayName)",
            summary: "pid \(agent.pid) · 存活 \(DurationFormat.compact(lifetime))",
            cost: Self.instantaneousCost(of: agent),
            projectPath: resolvedProjectPath(for: agent.workingDirectory, fallback: nil)
        )
    }

    // MARK: - Collector outputs

    /// 文件变更 → 事件；`kind` 映射见文件头表格，`riskLevel` 透传。
    public func event(for change: FileChange) -> TimelineEvent {
        let operation = Self.operationKind(for: change.kind)
        return TimelineEvent(
            timestamp: change.timestamp,
            sessionID: change.sessionID,
            agentID: change.agentID,
            agentKind: change.agentKind,
            kind: operation,
            title: "\(operation.displayName) · \(change.fileName)",
            summary: Self.fileSummary(for: change),
            filePath: change.path,
            riskLevel: change.riskLevel,
            projectPath: resolvedProjectPath(for: change.path, fallback: change.projectPath)
        )
    }

    /// 命令 → 事件；`git` 归为 `.gitOperation`，其余（含网络类命令）为 `.commandExecuted`。
    ///
    /// - Parameter riskLevel: 外部风险管线给出的等级；与命令自带等级取较高者。
    public func event(for command: CommandRecord, riskLevel: RiskLevel = .low) -> TimelineEvent {
        TimelineEvent(
            timestamp: command.startedAt,
            sessionID: command.sessionID,
            agentID: command.agentID,
            agentKind: command.agentKind,
            kind: Self.isGit(command) ? .gitOperation : .commandExecuted,
            title: command.commandLine,
            summary: Self.commandSummary(for: command),
            command: command.commandLine,
            exitCode: command.exitCode,
            durationSeconds: command.duration,
            riskLevel: max(riskLevel, command.riskLevel),
            projectPath: resolvedProjectPath(for: command.workingDirectory, fallback: command.projectPath)
        )
    }

    /// 风险事件 → `.riskDetected` 事件；`filePath` 取首个受影响路径，`projectPath` 由它推出。
    ///
    /// id **不是随机数**，而是从 `risk.id` 派生（`risk.id` 本身由 `RiskPipeline` 的幂等键
    /// 确定性算出）。理由是真机证据：同一条 finding 被重评再产出时，`risk_events` 那边
    /// 因为 id 稳定只有 2 行，而这边每次都新建一行，一条「内存峰值超限」刷出 **43** 行。
    /// 时间线的身份应当等于「哪一条风险」，不是「这次是谁算出来的」。
    public func event(for risk: RiskEvent) -> TimelineEvent {
        let firstPath = risk.filePaths.first
        return TimelineEvent(
            id: Self.eventID(for: risk),
            timestamp: risk.timestamp,
            sessionID: risk.sessionID,
            agentID: risk.agentID,
            agentKind: risk.agentKind,
            kind: .riskDetected,
            title: risk.title,
            summary: Self.riskSummary(for: risk),
            filePath: firstPath,
            command: risk.command,
            riskLevel: risk.level,
            projectPath: resolvedProjectPath(for: firstPath, fallback: nil)
        )
    }

    // MARK: - Resource attribution

    /// 把进程级资源按 agent 的 CPU 占比等比缩放，归因到 Session。
    ///
    /// `agentCPUShare` 越界会先收敛到 0…1（NaN / 负数 → 0）；
    /// 非有限的输入分量按 0 处理，绝不放大未知数据。
    public func attributedCost(processCost: ResourceCost, agentCPUShare: Double) -> ResourceCost {
        let share = Self.clampedShare(agentCPUShare)
        return ResourceCost(
            cpuSeconds: Self.sanitized(processCost.cpuSeconds) * share,
            memoryBytes: Self.scaled(processCost.memoryBytes, by: share),
            bytesRead: Self.scaled(processCost.bytesRead, by: share),
            bytesWritten: Self.scaled(processCost.bytesWritten, by: share)
        )
    }

    /// 由风险 id 派生时间线行 id：同输入同输出，跨进程、跨重放都稳定。
    public static func eventID(for risk: RiskEvent) -> UUID {
        StableID.uuid(namespace: "risktimeline", key: risk.id.uuidString)
    }

    /// 把任意比例收敛到 0…1；NaN / 无穷 / 负数一律 0。
    public static func clampedShare(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return min(1, value)
    }

    // MARK: - Mapping helpers

    /// `FileChangeKind → OperationKind` 映射表。
    private static func operationKind(for kind: FileChangeKind) -> OperationKind {
        switch kind {
        case .created:  return .fileCreated
        case .modified: return .fileModified
        case .deleted:  return .fileDeleted
        case .renamed:  return .fileRenamed
        case .unknown:  return .unknown
        }
    }

    /// 是否 git 命令：`executable` 为 `git`（或其绝对路径的 lastPathComponent）。
    private static func isGit(_ command: CommandRecord) -> Bool {
        let executable = command.executable
        guard !executable.isEmpty else { return false }
        if executable == "git" { return true }
        return (executable as NSString).lastPathComponent.lowercased() == "git"
    }

    /// 文件事件摘要：路径 + 行增删 + 重命名原路径；没有的数据不编造。
    private static func fileSummary(for change: FileChange) -> String {
        var parts: [String] = [change.path]
        if let previous = change.previousPath, previous != change.path {
            parts.append("原路径 \(previous)")
        }
        if change.linesAdded > 0 || change.linesRemoved > 0 {
            parts.append("+\(change.linesAdded) −\(change.linesRemoved) 行")
        }
        return parts.joined(separator: " · ")
    }

    /// 命令事件摘要：退出码 + 耗时；无数据不编造。
    private static func commandSummary(for command: CommandRecord) -> String {
        var parts: [String] = []
        if let exitCode = command.exitCode {
            parts.append("退出码 \(exitCode)")
        } else if command.outcome == .running {
            parts.append("仍在运行")
        }
        if let duration = command.duration, duration.isFinite, duration >= 0 {
            parts.append("耗时 \(DurationFormat.compact(duration))")
        }
        if let workingDirectory = command.workingDirectory, !workingDirectory.isEmpty {
            parts.append("cwd \(workingDirectory)")
        }
        return parts.joined(separator: " · ")
    }

    /// 风险事件摘要：detail 为空时退回到分类名。
    private static func riskSummary(for risk: RiskEvent) -> String {
        if !risk.detail.isEmpty { return risk.detail }
        if let rule = risk.matchedRuleID, !rule.isEmpty { return risk.category.displayName + "（规则 \(rule)）" }
        return risk.category.displayName
    }

    /// 进程快照能给出的瞬时资源：仅内存驻留量，cpu/IO 无区间依据故为 0。
    private static func instantaneousCost(of agent: AgentInstance) -> ResourceCost {
        ResourceCost(cpuSeconds: 0, memoryBytes: agent.memoryBytes, bytesRead: 0, bytesWritten: 0)
    }

    /// 项目路径解析：忽略命中 → nil；映射失败 → 回落到入参自带值，
    /// 但**回落值同样要过项目根可用性守卫**——否则一条 `projectPath = '/'` 的记录会绕过
    /// `ProjectMapper` 那道守卫，把全盘世界写成时间线行的归属项目。
    private func resolvedProjectPath(for path: String?, fallback: String?) -> String? {
        guard let path, !path.isEmpty else { return ProjectMapper.usableRoot(for: fallback) }
        if projectMapper.isIgnored(path) { return nil }
        return projectMapper.projectPath(for: path) ?? ProjectMapper.usableRoot(for: fallback)
    }

    /// 非有限值按 0 处理。
    private static func sanitized(_ value: Double) -> Double {
        guard value.isFinite, value > 0 else { return 0 }
        return value
    }

    /// UInt64 分量按比例缩放（`share` 已在 0…1，结果不可能溢出）。
    private static func scaled(_ value: UInt64, by share: Double) -> UInt64 {
        guard value > 0, share > 0 else { return 0 }
        let product = Double(value) * share
        guard product.isFinite, product > 0 else { return 0 }
        guard product < Double(UInt64.max) else { return value }
        return UInt64(product.rounded(.down))
    }
}
