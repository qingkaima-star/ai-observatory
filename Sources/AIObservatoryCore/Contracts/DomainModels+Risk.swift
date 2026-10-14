//
//  DomainModels+Risk.swift
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
// MARK: - Security / Risk

public enum RiskLevel: String, Codable, Sendable, CaseIterable, Identifiable, Hashable, Comparable {
    case low
    case medium
    case high
    case critical

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .low:      return "LOW"
        case .medium:   return "MEDIUM"
        case .high:     return "HIGH"
        case .critical: return "CRITICAL"
        }
    }

    public var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    public static func < (lhs: RiskLevel, rhs: RiskLevel) -> Bool { lhs.rank < rhs.rank }
}

public enum RiskCategory: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case massDeletion
    case sensitivePathAccess
    case systemFileModification
    case dangerousCommand
    case credentialExposure
    case privilegeEscalation
    case networkExfiltration
    case resourceAbuse
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .massDeletion:          return "批量删除"
        case .sensitivePathAccess:   return "敏感目录访问"
        case .systemFileModification:return "系统文件修改"
        case .dangerousCommand:      return "危险命令"
        case .credentialExposure:    return "凭据风险"
        case .privilegeEscalation:   return "提权行为"
        case .networkExfiltration:   return "数据外发"
        case .resourceAbuse:         return "资源滥用"
        case .unknown:               return "其他风险"
        }
    }

    public var sfSymbolName: String {
        switch self {
        case .massDeletion:           return "trash.slash"
        case .sensitivePathAccess:    return "lock.open.trianglebadge.exclamationmark"
        case .systemFileModification: return "gearshape.badge.xmark"
        case .dangerousCommand:       return "exclamationmark.octagon"
        case .credentialExposure:     return "key.slash"
        case .privilegeEscalation:    return "person.badge.key"
        case .networkExfiltration:    return "arrow.up.right.circle"
        case .resourceAbuse:          return "flame"
        case .unknown:                return "questionmark.diamond"
        }
    }
}

public struct RiskEvent: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var timestamp: Date
    public var level: RiskLevel
    public var category: RiskCategory
    public var title: String
    public var detail: String
    public var agentID: UUID?
    public var agentKind: AgentKind
    public var sessionID: UUID?
    public var command: String?
    public var filePaths: [String]
    public var requiresConfirmation: Bool
    public var isAcknowledged: Bool
    public var matchedRuleID: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: RiskLevel,
        category: RiskCategory,
        title: String,
        detail: String = "",
        agentID: UUID? = nil,
        agentKind: AgentKind = .unknown,
        sessionID: UUID? = nil,
        command: String? = nil,
        filePaths: [String] = [],
        requiresConfirmation: Bool = false,
        isAcknowledged: Bool = false,
        matchedRuleID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.title = title
        self.detail = detail
        self.agentID = agentID
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.command = command
        self.filePaths = filePaths
        self.requiresConfirmation = requiresConfirmation
        self.isAcknowledged = isAcknowledged
        self.matchedRuleID = matchedRuleID
    }
}
