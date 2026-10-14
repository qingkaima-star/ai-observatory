//
//  DomainModels+Timeline.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 冻结契约（与 `DomainModels.swift` 同一份契约，只按实体族分文件）。
//  此文件由项目总控维护。任何并行工作流都 **禁止修改本文件**。
//  如需扩展，请在自己的私有目录中扩展，或向总控提交契约变更请求。
//
//  Owner: master-controller
//  由 DomainModels.swift 原样搬来（#66，总控点名授权）：只搬不改，声明与字面量逐字未动。
//

import Foundation
// MARK: - Timeline

public enum OperationKind: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case agentStarted
    case agentStopped
    case fileCreated
    case fileModified
    case fileDeleted
    case fileRenamed
    case fileRead
    case commandExecuted
    case gitOperation
    case networkRequest
    case systemModification
    case riskDetected
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .agentStarted:       return "Agent 启动"
        case .agentStopped:       return "Agent 退出"
        case .fileCreated:        return "创建文件"
        case .fileModified:       return "修改文件"
        case .fileDeleted:        return "删除文件"
        case .fileRenamed:        return "重命名"
        case .fileRead:           return "读取文件"
        case .commandExecuted:    return "执行命令"
        case .gitOperation:       return "Git 操作"
        case .networkRequest:     return "网络请求"
        case .systemModification: return "系统变更"
        case .riskDetected:       return "风险事件"
        case .unknown:            return "其他操作"
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .agentStarted:       return "play.circle"
        case .agentStopped:       return "stop.circle"
        case .fileCreated:        return "doc.badge.plus"
        case .fileModified:       return "pencil.and.outline"
        case .fileDeleted:        return "trash"
        case .fileRenamed:        return "arrow.triangle.2.circlepath"
        case .fileRead:           return "doc.text.magnifyingglass"
        case .commandExecuted:    return "terminal"
        case .gitOperation:       return "arrow.triangle.branch"
        case .networkRequest:     return "network"
        case .systemModification: return "gearshape.2"
        case .riskDetected:       return "exclamationmark.triangle"
        case .unknown:            return "circle.dashed"
        }
    }
}

/// 该事件消耗的资源。
public struct ResourceCost: Codable, Sendable, Hashable {
    public var cpuSeconds: Double
    public var memoryBytes: UInt64
    public var bytesRead: UInt64
    public var bytesWritten: UInt64

    public init(cpuSeconds: Double = 0, memoryBytes: UInt64 = 0, bytesRead: UInt64 = 0, bytesWritten: UInt64 = 0) {
        self.cpuSeconds = cpuSeconds
        self.memoryBytes = memoryBytes
        self.bytesRead = bytesRead
        self.bytesWritten = bytesWritten
    }

    public static let zero = ResourceCost()
}

/// 时间线上的一条 AI 行为事件。
public struct TimelineEvent: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var timestamp: Date
    public var sessionID: UUID?
    public var agentID: UUID?
    public var agentKind: AgentKind
    public var kind: OperationKind
    public var title: String
    public var summary: String
    public var filePath: String?
    public var command: String?
    public var exitCode: Int32?
    public var durationSeconds: Double?
    public var cost: ResourceCost
    public var riskLevel: RiskLevel
    public var projectPath: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: UUID? = nil,
        agentID: UUID? = nil,
        agentKind: AgentKind = .unknown,
        kind: OperationKind,
        title: String,
        summary: String = "",
        filePath: String? = nil,
        command: String? = nil,
        exitCode: Int32? = nil,
        durationSeconds: Double? = nil,
        cost: ResourceCost = .zero,
        riskLevel: RiskLevel = .low,
        projectPath: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.agentID = agentID
        self.agentKind = agentKind
        self.kind = kind
        self.title = title
        self.summary = summary
        self.filePath = filePath
        self.command = command
        self.exitCode = exitCode
        self.durationSeconds = durationSeconds
        self.cost = cost
        self.riskLevel = riskLevel
        self.projectPath = projectPath
    }
}
