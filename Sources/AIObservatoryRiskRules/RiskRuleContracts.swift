//
//  RiskRuleContracts.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk
//
//  会话级风险规则库的公共契约：规则族、规则身份、规则协议、判定产出（RiskFinding）。
//  本文件只定义契约，不含任何具体规则。所有类型均为值类型、无 IO、无 Date() 依赖，
//  因此规则评估可在任意线程重复执行并得到完全一致的结果。
//

import Foundation
import AIObservatoryCore

// MARK: - Rule Family

/// 规则族。用于分组展示、聚合排序与严重度地板（floor）策略。
public enum RiskRuleFamily: String, Sendable, Codable, CaseIterable, Hashable, Identifiable {
    /// A 族：破坏性文件操作（批量删除、覆盖式重写、越界删除、清空目录）。
    case destructiveFileOperation
    /// B 族：敏感位置（凭据、钥匙串、系统目录、时间机器备份、他人 home）。
    case sensitiveLocation
    /// C 族：命令行为（提权、不可逆 git、包源篡改、服务/内核与安全配置变更）。
    case commandBehavior
    /// D 族：行为模式（非工作时间高频、抖动式重复修改、资源异常）。
    case activityPattern

    public var id: String { rawValue }

    /// 中文族名，供 UI 分组标题使用。
    public var displayName: String {
        switch self {
        case .destructiveFileOperation: return "破坏性文件操作"
        case .sensitiveLocation:        return "敏感位置访问"
        case .commandBehavior:          return "命令行为"
        case .activityPattern:          return "行为模式"
        }
    }

    /// 同等级下的呈现优先级，值越大越靠前。
    public var presentationWeight: Int {
        switch self {
        case .destructiveFileOperation: return 40
        case .sensitiveLocation:        return 30
        case .commandBehavior:          return 20
        case .activityPattern:          return 10
        }
    }
}

// MARK: - Rule Identity

/// 一条规则的静态身份：`id`、`title`、理由模板、默认等级、是否需要确认。
///
/// 理由模板使用 `{key}` 占位符，由 `rationale(filling:)` 做字面替换；
/// 未提供的占位符原样保留，便于测试时定位缺失的上下文。
public struct RiskRuleIdentity: Sendable, Hashable, Identifiable {

    /// 形如 `risk.mass-deletion.window`，点分隔的族 + 规则短名，全局唯一。
    public var id: String
    public var family: RiskRuleFamily
    /// 产出到 `RiskEvent.category` 的契约分类。
    public var category: RiskCategory
    /// 短句标题，UI 列表第一行。
    public var title: String
    /// 带 `{placeholder}` 的可读理由模板。
    public var rationaleTemplate: String
    public var defaultLevel: RiskLevel
    /// 命中后是否要求用户确认（对应 AGENTS.md 第 7 条：删除类必须走确认）。
    public var requiresConfirmation: Bool
    /// 一句话说明，用于 `RiskRuleDescriptor.summary` 与规则清单页。
    public var summary: String

    public init(
        id: String,
        family: RiskRuleFamily,
        category: RiskCategory,
        title: String,
        rationaleTemplate: String,
        defaultLevel: RiskLevel,
        requiresConfirmation: Bool,
        summary: String
    ) {
        self.id = id
        self.family = family
        self.category = category
        self.title = title
        self.rationaleTemplate = rationaleTemplate
        self.defaultLevel = defaultLevel
        self.requiresConfirmation = requiresConfirmation
        self.summary = summary
    }

    /// 用给定变量渲染理由文本。键不含花括号，例如 `["count": "42"]` 渲染 `{count}`。
    public func rationale(filling values: [String: String] = [:]) -> String {
        values.reduce(rationaleTemplate) { text, pair in
            text.replacingOccurrences(of: "{" + pair.key + "}", with: pair.value)
        }
    }

    /// 转换为契约层描述符，供 `RiskEvaluating.loadedRules()` 与 UI 规则清单使用。
    public var descriptor: RiskRuleDescriptor {
        RiskRuleDescriptor(
            id: id,
            name: title,
            category: category,
            level: defaultLevel,
            summary: summary
        )
    }
}

// MARK: - Finding Draft

/// 规则实现用来描述一次命中的草稿，由 `AgentRiskRule.makeFinding(from:)` 补全身份信息。
public struct RiskFindingDraft: Sendable, Hashable {
    public var level: RiskLevel
    public var detail: String
    /// 覆盖规则默认分类（例如批量删除凭据目录时同时归为凭据风险）；nil 表示沿用规则身份。
    public var category: RiskCategory?
    /// 覆盖规则默认标题；nil 表示沿用规则身份。
    public var title: String?
    public var confidence: Double
    /// 证据时间戳。必须来自输入事实，禁止使用 `Date()`。
    public var timestamp: Date
    public var filePaths: [String]
    public var command: String?
    public var sessionID: UUID?
    public var agentID: UUID?
    public var agentKind: AgentKind
    /// 同根因抑制键：管道据此把多条命中折叠为一条。
    public var suppressionKey: String
    /// 支撑该结论的事实条数（批量删除 = 命中的删除事件数）。
    public var evidenceCount: Int
    /// 证据覆盖的时间跨度，无跨度时为 nil。
    public var evidenceSpan: TimeInterval?

    public init(
        level: RiskLevel,
        detail: String,
        category: RiskCategory? = nil,
        title: String? = nil,
        confidence: Double = 0.8,
        timestamp: Date,
        filePaths: [String] = [],
        command: String? = nil,
        sessionID: UUID? = nil,
        agentID: UUID? = nil,
        agentKind: AgentKind = .unknown,
        suppressionKey: String,
        evidenceCount: Int = 1,
        evidenceSpan: TimeInterval? = nil
    ) {
        self.level = level
        self.detail = detail
        self.category = category
        self.title = title
        self.confidence = confidence
        self.timestamp = timestamp
        self.filePaths = filePaths
        self.command = command
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentKind = agentKind
        self.suppressionKey = suppressionKey
        self.evidenceCount = evidenceCount
        self.evidenceSpan = evidenceSpan
    }
}

// MARK: - Finding

/// 一条风险判定产出。规则层输出 `RiskFinding`（含置信度与抑制键），
/// 通过 `riskEvent()` 降级为契约层的 `RiskEvent` 落库。
public struct RiskFinding: Sendable, Hashable, Identifiable {

    /// `ruleID@suppressionKey`，在同一评估批次内唯一。
    public var id: String { ruleID + "@" + suppressionKey }

    public var ruleID: String
    public var family: RiskRuleFamily
    public var category: RiskCategory
    public var level: RiskLevel
    public var title: String
    public var detail: String
    /// 0…1 之间的置信度。契约层 `RiskEvent` 无该字段，因此保留在本类型与 `detail` 中。
    public var confidence: Double
    public var requiresConfirmation: Bool
    public var timestamp: Date
    public var sessionID: UUID?
    public var agentID: UUID?
    public var agentKind: AgentKind
    public var command: String?
    public var filePaths: [String]
    public var suppressionKey: String
    public var evidenceCount: Int
    public var evidenceSpan: TimeInterval?
    /// 参与本次判定的规则数量折叠计数；聚合后 ≥ 1。
    public var suppressionCount: Int

    public init(
        ruleID: String,
        family: RiskRuleFamily,
        category: RiskCategory,
        level: RiskLevel,
        title: String,
        detail: String,
        confidence: Double,
        requiresConfirmation: Bool,
        timestamp: Date,
        sessionID: UUID?,
        agentID: UUID?,
        agentKind: AgentKind,
        command: String?,
        filePaths: [String],
        suppressionKey: String,
        evidenceCount: Int,
        evidenceSpan: TimeInterval?,
        suppressionCount: Int = 1
    ) {
        self.ruleID = ruleID
        self.family = family
        self.category = category
        self.level = level
        self.title = title
        self.detail = detail
        self.confidence = confidence
        self.requiresConfirmation = requiresConfirmation
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentKind = agentKind
        self.command = command
        self.filePaths = filePaths
        self.suppressionKey = suppressionKey
        self.evidenceCount = evidenceCount
        self.evidenceSpan = evidenceSpan
        self.suppressionCount = suppressionCount
    }

    /// 该命中的置信度，按 0…1 裁剪。
    public var clampedConfidence: Double { Swift.min(Swift.max(confidence, 0), 1) }

    /// 合并同抑制键的两条命中：等级取更高、置信度取更高、证据累加、确认要求取"或"。
    /// 聚合过程只上调不下调等级，符合"严重度不降级"的验收标准。
    public func merged(with other: RiskFinding) -> RiskFinding {
        var result = self
        if other.level.rank > result.level.rank {
            result.level = other.level
            result.title = other.title
            result.category = other.category
            result.ruleID = other.ruleID
            result.family = other.family
            result.requiresConfirmation = other.requiresConfirmation
        }
        result.confidence = Swift.max(result.confidence, other.confidence)
        result.requiresConfirmation = result.requiresConfirmation || other.requiresConfirmation
        result.evidenceCount = result.evidenceCount + other.evidenceCount
        result.suppressionCount = result.suppressionCount + other.suppressionCount
        result.filePaths = RiskFinding.mergedPaths(result.filePaths, other.filePaths)
        if result.command == nil { result.command = other.command }
        if result.timestamp > other.timestamp { result.timestamp = other.timestamp }
        result.evidenceSpan = RiskFinding.mergedSpan(
            first: (result.timestamp, result.evidenceSpan),
            second: (other.timestamp, other.evidenceSpan)
        )
        return result
    }

    private static func mergedPaths(_ lhs: [String], _ rhs: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for path in lhs + rhs where !seen.contains(path) {
            seen.insert(path)
            out.append(path)
        }
        return out.count > 12 ? Array(out.prefix(12)) : out
    }

    private static func mergedSpan(
        first: (start: Date, span: TimeInterval?),
        second: (start: Date, span: TimeInterval?)
    ) -> TimeInterval? {
        let total = (first.span ?? 0) + (second.span ?? 0)
        let distance = abs(first.start.timeIntervalSince(second.start))
        let candidate = Swift.max(total, distance)
        return candidate > 0 ? candidate : nil
    }

    /// 降级为契约层 `RiskEvent`。置信度以百分比形式追加到 `detail` 尾部，
    /// 因为 `RiskEvent` 没有置信度字段。
    public func riskEvent() -> RiskEvent {
        RiskEvent(
            timestamp: timestamp,
            level: level,
            category: category,
            title: title,
            detail: detail + " (confidence \(String(format: "%.0f%%", clampedConfidence * 100)))",
            agentID: agentID,
            agentKind: agentKind,
            sessionID: sessionID,
            command: command,
            filePaths: filePaths,
            requiresConfirmation: requiresConfirmation,
            isAcknowledged: false,
            matchedRuleID: ruleID
        )
    }
}

// MARK: - Rule Protocol

/// 一条会话级风险规则。实现必须是**纯函数**：
/// 不访问磁盘、不读取 `Date()`、不使用随机数、不依赖全局可变状态。
/// 相同 `RiskFactWindow` 输入必须产出逐字节相同的输出。
public protocol AgentRiskRule: Sendable {

    /// 规则静态身份。
    var identity: RiskRuleIdentity { get }

    /// 时间线事件的 `riskLevel` 由上游（WS-Telemetry）给出的命令分类结论。
    /// 若上游已判定为危险命令，规则应复用该结论而不是重新匹配命令文本。
    var preferences: RiskRulePreferences { get }

    /// 在给定事实窗口内产出 0…n 条命中。
    func findings(in window: RiskFactWindow) -> [RiskFinding]
}

public extension AgentRiskRule {

    /// 默认继承规则身份里声明的 `defaultLevel`，允许规则按证据强度上调（不允许下调）。
    var preferences: RiskRulePreferences { RiskRulePreferences() }

    /// 由草稿构造完整的 `RiskFinding`，标题与分类取自规则身份。
    /// 等级不会低于 `preferences.levelFloor`；HIGH 及以上自动要求确认。
    func makeFinding(from draft: RiskFindingDraft) -> RiskFinding {
        let resolvedLevel = Swift.max(draft.level, preferences.levelFloor)
        return RiskFinding(
            ruleID: identity.id,
            family: identity.family,
            category: draft.category ?? identity.category,
            level: resolvedLevel,
            title: draft.title ?? identity.title,
            detail: draft.detail,
            confidence: draft.confidence,
            requiresConfirmation: identity.requiresConfirmation || resolvedLevel.rank >= RiskLevel.high.rank,
            timestamp: draft.timestamp,
            sessionID: draft.sessionID,
            agentID: draft.agentID,
            agentKind: draft.agentKind,
            command: draft.command,
            filePaths: draft.filePaths,
            suppressionKey: draft.suppressionKey,
            evidenceCount: draft.evidenceCount,
            evidenceSpan: draft.evidenceSpan
        )
    }
}

/// 规则行为开关。
public struct RiskRulePreferences: Sendable, Hashable {

    /// 命中所需的最低等级地板。聚合层会再叠加族级地板。
    public var levelFloor: RiskLevel
    /// 为 true 时，规则复用 `RiskFactWindow.telemetryClassifications`，
    /// 避免与 `Platform/Telemetry/DestructiveCommandRules` 给出矛盾结论。
    public var defersToTelemetryClassification: Bool
    /// 规则是否只针对"写"类事实（用于窗口过滤时跳过纯读取会话）。
    public var requiresWriteEvidence: Bool

    public init(
        levelFloor: RiskLevel = .low,
        defersToTelemetryClassification: Bool = true,
        requiresWriteEvidence: Bool = false
    ) {
        self.levelFloor = levelFloor
        self.defersToTelemetryClassification = defersToTelemetryClassification
        self.requiresWriteEvidence = requiresWriteEvidence
    }
}
