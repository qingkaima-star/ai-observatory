//
//  DomainModels+Files.swift
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
// MARK: - File Tracking

public enum FileChangeKind: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case created
    case modified
    case deleted
    case renamed
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .created:  return "Created"
        case .modified: return "Modified"
        case .deleted:  return "Deleted"
        case .renamed:  return "Renamed"
        case .unknown:  return "Unknown"
        }
    }
}

public struct FileChange: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var path: String
    public var previousPath: String?
    public var kind: FileChangeKind
    public var timestamp: Date
    public var agentID: UUID?
    public var sessionID: UUID?
    public var agentKind: AgentKind
    public var sizeBytes: UInt64
    public var previousSizeBytes: UInt64?
    public var isText: Bool
    public var linesAdded: Int
    public var linesRemoved: Int
    public var riskLevel: RiskLevel
    public var projectPath: String?

    public init(
        id: UUID = UUID(),
        path: String,
        previousPath: String? = nil,
        kind: FileChangeKind,
        timestamp: Date = Date(),
        agentID: UUID? = nil,
        sessionID: UUID? = nil,
        agentKind: AgentKind = .unknown,
        sizeBytes: UInt64 = 0,
        previousSizeBytes: UInt64? = nil,
        isText: Bool = true,
        linesAdded: Int = 0,
        linesRemoved: Int = 0,
        riskLevel: RiskLevel = .low,
        projectPath: String? = nil
    ) {
        self.id = id
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.timestamp = timestamp
        self.agentID = agentID
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.sizeBytes = sizeBytes
        self.previousSizeBytes = previousSizeBytes
        self.isText = isText
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.riskLevel = riskLevel
        self.projectPath = projectPath
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// 文件内容快照（用于 Before/After Diff）。
public struct FileSnapshot: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var path: String
    public var contentHash: String
    public var sizeBytes: UInt64
    public var capturedAt: Date
    public var lineCount: Int

    public init(id: UUID = UUID(), path: String, contentHash: String, sizeBytes: UInt64, capturedAt: Date = Date(), lineCount: Int = 0) {
        self.id = id
        self.path = path
        self.contentHash = contentHash
        self.sizeBytes = sizeBytes
        self.capturedAt = capturedAt
        self.lineCount = lineCount
    }
}

/// 单行 Diff。
public struct DiffLine: Identifiable, Codable, Sendable, Hashable {
    public enum Style: String, Codable, Sendable, Hashable {
        case context, added, removed, hunkHeader, meta
    }
    public var id: UUID
    public var style: Style
    public var text: String
    public var oldLineNumber: Int?
    public var newLineNumber: Int?

    public init(id: UUID = UUID(), style: Style, text: String, oldLineNumber: Int? = nil, newLineNumber: Int? = nil) {
        self.id = id
        self.style = style
        self.text = text
        self.oldLineNumber = oldLineNumber
        self.newLineNumber = newLineNumber
    }
}

/// 「改前内容」是从哪来的——决定 UI 怎么措辞，绝不许让读者猜。
public enum DiffBaselineSource: String, Codable, Sendable, Hashable {
    /// 与上一次观测到该路径时的版本对比（缓存命中）
    case lastObserved
    /// 首次观测到该路径，没有可比版本（单边 diff）
    case unavailableFirstSighting
    /// 不适用（删除/重命名等没有新内容的变更）
    case notApplicable
}

public struct FileDiff: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var path: String
    public var previousPath: String?
    public var kind: FileChangeKind
    public var lines: [DiffLine]
    public var linesAdded: Int
    public var linesRemoved: Int
    public var isBinary: Bool
    public var isTruncated: Bool
    public var capturedAt: Date
    /// 这份 diff 的「改前内容」是从哪来的。呈现层必须按它决定措辞，
    /// 不得再从「行数为 0」「行为空」反推——那正是本轮要修掉的那类谎。
    public var baselineSource: DiffBaselineSource
    /// `baselineSource == .lastObserved` 时那份「上次观测」的时刻；其余情形为 nil。
    public var baselineCapturedAt: Date?
    /// `lines` 里是否真的存着文件内容明文。关掉隐私开关（`ObservatorySettings.storeDiffPlaintext`）
    /// 后仍会留下这条 diff 与增删统计，此时它是 false —— 呈现层必须照实说「明文已按设置关闭」，
    /// 不许把这行显示成「这次改动没有产生差异」。
    public var plaintextStored: Bool

    public init(
        id: UUID = UUID(),
        path: String,
        previousPath: String? = nil,
        kind: FileChangeKind,
        lines: [DiffLine] = [],
        linesAdded: Int = 0,
        linesRemoved: Int = 0,
        isBinary: Bool = false,
        isTruncated: Bool = false,
        capturedAt: Date = Date(),
        baselineSource: DiffBaselineSource = .notApplicable,
        baselineCapturedAt: Date? = nil,
        plaintextStored: Bool = true
    ) {
        self.id = id
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.lines = lines
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.isBinary = isBinary
        self.isTruncated = isTruncated
        self.capturedAt = capturedAt
        self.baselineSource = baselineSource
        self.baselineCapturedAt = baselineCapturedAt
        self.plaintextStored = plaintextStored
    }

    /// 键名逐字固定：`diffs` 表与任何写过盘的 `FileDiff` JSON 用的就是这些键。
    private enum CodingKeys: String, CodingKey {
        case id
        case path
        case previousPath
        case kind
        case lines
        case linesAdded
        case linesRemoved
        case isBinary
        case isTruncated
        case capturedAt
        case baselineSource
        case baselineCapturedAt
        case plaintextStored
    }

    /// **向后兼容的解码**：缺溯源键不报错，按「不可比」解释。
    ///
    /// 为什么要手写：Swift 合成的 `Decodable` 不会拿属性默认值补缺失的键，非 Optional 的
    /// `baselineSource` 不在 JSON 里就抛 `keyNotFound`；而 `diffs.lines_json` 那侧的策略是
    /// 「解不开就丢整行，绝不伪造空 diff」——两者一叠加，**加一个字段就等于让所有老 diff 消失**。
    /// 回落值选 `.unavailableFirstSighting` 而不是 `.notApplicable`，因为写这些老数据的代码
    /// `oldText` 恒为 `nil`（见 `ObservatoryEngine.makeFileChange` 的改动前形态），
    /// 它们客观上全是单边 diff；`.notApplicable` 说的是「这类变更根本没有新内容」，那是另一件事。
    /// 未登记的 rawValue 走同一条降级路径：认不出来源就按「不可比」呈现，
    /// 也不许让一条 diff 因为来源无法识别而整个读不出来（那会让 UI 显示成「没有 diff」）。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.path = try container.decode(String.self, forKey: .path)
        self.previousPath = try container.decodeIfPresent(String.self, forKey: .previousPath)
        self.kind = try container.decode(FileChangeKind.self, forKey: .kind)
        self.lines = try container.decode([DiffLine].self, forKey: .lines)
        self.linesAdded = try container.decode(Int.self, forKey: .linesAdded)
        self.linesRemoved = try container.decode(Int.self, forKey: .linesRemoved)
        self.isBinary = try container.decode(Bool.self, forKey: .isBinary)
        self.isTruncated = try container.decode(Bool.self, forKey: .isTruncated)
        self.capturedAt = try container.decode(Date.self, forKey: .capturedAt)
        let storedSource = try container.decodeIfPresent(String.self, forKey: .baselineSource)
        self.baselineSource = storedSource.flatMap(DiffBaselineSource.init(rawValue:)) ?? .unavailableFirstSighting
        self.baselineCapturedAt = try container.decodeIfPresent(Date.self, forKey: .baselineCapturedAt)
        // 缺键 ⇒ v4 之前写的行，那时候正文是唯一存在的形状 ⇒ true 是事实，不是猜测。
        self.plaintextStored = try container.decodeIfPresent(Bool.self, forKey: .plaintextStored) ?? true
    }
}
