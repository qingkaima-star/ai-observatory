//
//  ObservatorySchema.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-SwiftData
//
//  SwiftData 后端的 schema 真相源：与 SQLite 后端 `StoreSchema` 的 11 张表一一对应。
//
//  ── 与 SQLite 后端的对齐规则（可切换的前提）────────────────────────────────
//  · **列集合逐字对齐**：每张表的每一列都在对应 `@Model` 里有同名语义的属性，
//    包含 SQLite 侧的**预计算列**（`search_text`、`risk_rank` / `level_rank`）。
//    预计算列不是冗余：`#Predicate` 无法调用 `RiskLevel.rank` 这类 Swift 计算属性，
//    也无法在 SQL 侧做大小写折叠，所以它们必须落库，两个后端才可能查出同一批行。
//  · **枚举存 TEXT rawValue**、**日期用 `Date`**（SwiftData 以 REAL
//    `timeIntervalSinceReferenceDate` 落盘，与 SQLite 侧 `StoreValues.date` 同口径）、
//  · **`UInt64` 存成有符号 `Int`**（bit-pattern 往返，见 `SwiftDataValues.integer(from:)`），
//    与 `StoreValues.uint64` 的 `Int64(bitPattern:)` 一致。
//  · **JSON 列表存成 JSON 文本 String**，而不是 Codable transformable 属性：
//    这样 SQLite 库里的 `*_json TEXT` 列可以**逐字节搬过来**，迁移不需要重新编码，
//    也不必赌 SwiftData 对任意 Codable 结构体的支持边界。
//  · **没有 `@Relationship`**：SQLite 侧只有 TEXT 外键列 + 索引，没有 FOREIGN KEY 约束，
//    因此删父表不会级联。用标量 id 列而不是关系，两个端的删除语义才一致。
//
//  ── 并发 ────────────────────────────────────────────────────────────────────
//  `@Model` 类**不是** `Sendable`，因此全部标 `internal`：它们永不出现在本模块的
//  公共 API 签名里，跨 actor 边界只传 `AIObservatoryCore` 的值类型领域模型。
//  把 `@Model` 关在模块内，是「SwiftData 与 Swift 6 严格并发共存」的关键一步。
//

import Foundation
import SwiftData
import AIObservatoryCore

// MARK: - agents

/// 对应 SQLite `agents` 表：一个被观测到的 Agent 进程实例。
@Model
final class SDAgent {
    @Attribute(.unique) var rowID: String
    var kind: String
    var pid: Int
    var parentPID: Int?
    var displayName: String
    var executablePath: String
    var workingDirectory: String?
    var bundleIdentifier: String?
    var tty: String?
    var startedAt: Date
    var lastSeenAt: Date
    var state: String
    var cpuPercent: Double
    /// `AgentInstance.memoryBytes` 的 bit-pattern（SQLite: `memory_bytes INTEGER`）。
    var memoryBytes: Int
    var childPIDsJSON: String
    var detectedVia: String

    init(_ agent: AgentInstance) {
        rowID = agent.id.uuidString
        kind = agent.kind.rawValue
        pid = Int(agent.pid)
        parentPID = agent.parentPID.map { Int($0) }
        displayName = agent.displayName
        executablePath = agent.executablePath
        workingDirectory = agent.workingDirectory
        bundleIdentifier = agent.bundleIdentifier
        tty = agent.tty
        startedAt = agent.startedAt
        lastSeenAt = agent.lastSeenAt
        state = agent.state.rawValue
        cpuPercent = agent.cpuPercent
        memoryBytes = SwiftDataValues.integer(from: agent.memoryBytes)
        childPIDsJSON = SwiftDataValues.json(agent.childPIDs)
        detectedVia = agent.detectedVia.rawValue
    }
}

// MARK: - sessions

/// 对应 SQLite `sessions` 表：一次 AI 使用会话。
@Model
final class SDSession {
    @Attribute(.unique) var rowID: String
    var displayIndex: Int
    var kind: String
    var agentID: String?
    var title: String
    var projectPath: String?
    var startedAt: Date
    var endedAt: Date?
    var modifiedFileCount: Int
    var createdFileCount: Int
    var deletedFileCount: Int
    var commandCount: Int
    var failedCommandCount: Int
    var cpuSeconds: Double
    var peakCPUPercent: Double
    var peakMemoryBytes: Int
    var estimatedTokens: Int
    var riskEventCount: Int
    var outcome: String
    var searchText: String

    init(_ session: AgentSession) {
        rowID = session.id.uuidString
        displayIndex = session.displayIndex
        kind = session.kind.rawValue
        agentID = session.agentID?.uuidString
        title = session.title
        projectPath = session.projectPath
        startedAt = session.startedAt
        endedAt = session.endedAt
        modifiedFileCount = session.modifiedFileCount
        createdFileCount = session.createdFileCount
        deletedFileCount = session.deletedFileCount
        commandCount = session.commandCount
        failedCommandCount = session.failedCommandCount
        cpuSeconds = session.cpuSeconds
        peakCPUPercent = session.peakCPUPercent
        peakMemoryBytes = SwiftDataValues.integer(from: session.peakMemoryBytes)
        estimatedTokens = session.estimatedTokens
        riskEventCount = session.riskEventCount
        outcome = session.outcome.rawValue
        searchText = SwiftDataSearchText.session(session)
    }
}

// MARK: - events

/// 对应 SQLite `events` 表：时间线上的一条 AI 行为事件。
@Model
final class SDEvent {
    @Attribute(.unique) var rowID: String
    var timestamp: Date
    var sessionID: String?
    var agentID: String?
    var agentKind: String
    var kind: String
    var title: String
    var summary: String
    var filePath: String?
    var command: String?
    var exitCode: Int?
    var durationSeconds: Double?
    var costCPUSeconds: Double
    var costMemoryBytes: Int
    var costBytesRead: Int
    var costBytesWritten: Int
    var riskLevel: String
    var riskRank: Int
    var projectPath: String?
    var searchText: String

    init(_ event: TimelineEvent) {
        rowID = event.id.uuidString
        timestamp = event.timestamp
        sessionID = event.sessionID?.uuidString
        agentID = event.agentID?.uuidString
        agentKind = event.agentKind.rawValue
        kind = event.kind.rawValue
        title = event.title
        summary = event.summary
        filePath = event.filePath
        command = event.command
        exitCode = event.exitCode.map { Int($0) }
        durationSeconds = event.durationSeconds
        costCPUSeconds = event.cost.cpuSeconds
        costMemoryBytes = SwiftDataValues.integer(from: event.cost.memoryBytes)
        costBytesRead = SwiftDataValues.integer(from: event.cost.bytesRead)
        costBytesWritten = SwiftDataValues.integer(from: event.cost.bytesWritten)
        riskLevel = event.riskLevel.rawValue
        riskRank = event.riskLevel.rank
        projectPath = event.projectPath
        searchText = SwiftDataSearchText.event(event)
    }
}

// MARK: - file_changes

/// 对应 SQLite `file_changes` 表。
@Model
final class SDFileChange {
    @Attribute(.unique) var rowID: String
    var path: String
    var previousPath: String?
    var kind: String
    var timestamp: Date
    var agentID: String?
    var sessionID: String?
    var agentKind: String
    var sizeBytes: Int
    var previousSizeBytes: Int?
    var isText: Bool
    var linesAdded: Int
    var linesRemoved: Int
    var riskLevel: String
    var riskRank: Int
    var projectPath: String?
    var searchText: String

    init(_ change: FileChange) {
        rowID = change.id.uuidString
        path = change.path
        previousPath = change.previousPath
        kind = change.kind.rawValue
        timestamp = change.timestamp
        agentID = change.agentID?.uuidString
        sessionID = change.sessionID?.uuidString
        agentKind = change.agentKind.rawValue
        sizeBytes = SwiftDataValues.integer(from: change.sizeBytes)
        previousSizeBytes = change.previousSizeBytes.map { SwiftDataValues.integer(from: $0) }
        isText = change.isText
        linesAdded = change.linesAdded
        linesRemoved = change.linesRemoved
        riskLevel = change.riskLevel.rawValue
        riskRank = change.riskLevel.rank
        projectPath = change.projectPath
        searchText = SwiftDataSearchText.fileChange(change)
    }
}

// MARK: - diffs

/// 对应 SQLite `diffs` 表（`change_id` 唯一）。
@Model
final class SDDiff {
    @Attribute(.unique) var rowID: String
    /// 所属 `FileChange.id`。SQLite 侧是 `change_id TEXT NOT NULL UNIQUE`。
    @Attribute(.unique) var changeID: String
    var path: String
    var previousPath: String?
    var kind: String
    var linesJSON: String
    var linesAdded: Int
    var linesRemoved: Int
    var isBinary: Bool
    var isTruncated: Bool
    var capturedAt: Date
    /// 对应 SQLite `diffs.baseline_source`（v4，可空）。Optional 而非带默认值：
    /// 自动迁移给老行填的正是 nil，写成非 Optional 会让「没记过」与「记成某个值」混成一谈。
    var baselineSource: String?
    /// 对应 SQLite `diffs.baseline_captured_at`（v4，可空）。
    var baselineCapturedAt: Date?
    /// 对应 SQLite `diffs.plaintext_stored`（v4，可空）。nil = 老行，那时正文一定在。
    var plaintextStored: Bool?

    /// - Parameter changeID: 归属的文件变更 id。约定与 SQLite 后端一致：`diff.id == changeID`
    ///   （参考实现 `InMemoryObservatoryService` 用 `diff.id` 当 changeID 索引）。
    init(_ diff: FileDiff, changeID: UUID) {
        rowID = diff.id.uuidString
        self.changeID = changeID.uuidString
        path = diff.path
        previousPath = diff.previousPath
        kind = diff.kind.rawValue
        linesJSON = SwiftDataValues.json(diff.lines)
        linesAdded = diff.linesAdded
        linesRemoved = diff.linesRemoved
        isBinary = diff.isBinary
        isTruncated = diff.isTruncated
        capturedAt = diff.capturedAt
        baselineSource = diff.baselineSource.rawValue
        baselineCapturedAt = diff.baselineCapturedAt
        plaintextStored = diff.plaintextStored
    }
}

// MARK: - commands

/// 对应 SQLite `commands` 表：一条终端命令审计记录。
@Model
final class SDCommand {
    @Attribute(.unique) var rowID: String
    var executable: String
    var argumentsJSON: String
    var workingDirectory: String?
    var agentID: String?
    var sessionID: String?
    var agentKind: String
    var startedAt: Date
    var endedAt: Date?
    var exitCode: Int?
    var outcome: String
    var isDestructive: Bool
    var requiresConfirmation: Bool
    var riskLevel: String
    var riskRank: Int
    var projectPath: String?
    var searchText: String

    init(_ record: CommandRecord) {
        rowID = record.id.uuidString
        executable = record.executable
        argumentsJSON = SwiftDataValues.json(record.arguments)
        workingDirectory = record.workingDirectory
        agentID = record.agentID?.uuidString
        sessionID = record.sessionID?.uuidString
        agentKind = record.agentKind.rawValue
        startedAt = record.startedAt
        endedAt = record.endedAt
        exitCode = record.exitCode.map { Int($0) }
        outcome = record.outcome.rawValue
        isDestructive = record.isDestructive
        requiresConfirmation = record.requiresConfirmation
        riskLevel = record.riskLevel.rawValue
        riskRank = record.riskLevel.rank
        projectPath = record.projectPath
        searchText = SwiftDataSearchText.command(record)
    }
}

// MARK: - perf_samples

/// 对应 SQLite `perf_samples` 表：会话级性能采样。
@Model
final class SDPerformanceSample {
    @Attribute(.unique) var rowID: String
    var timestamp: Date
    var sessionID: String?
    var agentID: String?
    var cpuPercent: Double
    var memoryBytes: Int
    var gpuPercent: Double?
    var diskReadBytesPerSecond: Double
    var diskWriteBytesPerSecond: Double
    var networkBytesIn: Int
    var networkBytesOut: Int
    var thermalCelsius: Double?
    var powerWatts: Double?

    init(_ sample: PerformanceSample) {
        rowID = sample.id.uuidString
        timestamp = sample.timestamp
        sessionID = sample.sessionID?.uuidString
        agentID = sample.agentID?.uuidString
        cpuPercent = sample.cpuPercent
        memoryBytes = SwiftDataValues.integer(from: sample.memoryBytes)
        gpuPercent = sample.gpuPercent
        diskReadBytesPerSecond = sample.diskReadBytesPerSecond
        diskWriteBytesPerSecond = sample.diskWriteBytesPerSecond
        networkBytesIn = SwiftDataValues.integer(from: sample.networkBytesIn)
        networkBytesOut = SwiftDataValues.integer(from: sample.networkBytesOut)
        thermalCelsius = sample.thermalCelsius
        powerWatts = sample.powerWatts
    }
}

// MARK: - system_perf

/// 对应 SQLite `system_perf` 表：整机性能采样。
///
/// 末尾四个属性来自 `StoreSchema` v3（`system-perf-network-gpu`）。它们**必须可空**：
/// v3 之前写入的行这四列是 NULL，读回来要还是 `nil`（「当时没采这个指标」），
/// 塌成 `0` 会被界面念成「真的没有流量 / GPU 空闲」。
@Model
final class SDSystemPerformanceSample {
    @Attribute(.unique) var rowID: String
    var timestamp: Date
    var cpuTotalPercent: Double
    var cpuSystemPercent: Double
    var cpuUserPercent: Double
    var memoryUsedBytes: Int
    var memoryTotalBytes: Int
    var diskReadBytesPerSecond: Double
    var diskWriteBytesPerSecond: Double
    var loadAverage1m: Double
    var thermalCelsius: Double?
    var powerWatts: Double?
    var networkInBytesPerSecond: Double?
    var networkOutBytesPerSecond: Double?
    /// `NetworkRateAvailability.rawValue`；`nil` = 拿到了速率。
    var networkAvailability: String?
    var gpuPercent: Double?

    init(_ sample: SystemPerformanceSample) {
        rowID = sample.id.uuidString
        timestamp = sample.timestamp
        cpuTotalPercent = sample.cpuTotalPercent
        cpuSystemPercent = sample.cpuSystemPercent
        cpuUserPercent = sample.cpuUserPercent
        memoryUsedBytes = SwiftDataValues.integer(from: sample.memoryUsedBytes)
        memoryTotalBytes = SwiftDataValues.integer(from: sample.memoryTotalBytes)
        diskReadBytesPerSecond = sample.diskReadBytesPerSecond
        diskWriteBytesPerSecond = sample.diskWriteBytesPerSecond
        loadAverage1m = sample.loadAverage1m
        thermalCelsius = sample.thermalCelsius
        powerWatts = sample.powerWatts
        networkInBytesPerSecond = sample.networkInBytesPerSecond
        networkOutBytesPerSecond = sample.networkOutBytesPerSecond
        networkAvailability = sample.networkAvailability?.rawValue
        gpuPercent = sample.gpuActivityPercent
    }
}

// MARK: - risk_events

/// 对应 SQLite `risk_events` 表。
@Model
final class SDRiskEvent {
    @Attribute(.unique) var rowID: String
    var timestamp: Date
    var level: String
    var levelRank: Int
    var category: String
    var title: String
    var detail: String
    var agentID: String?
    var agentKind: String
    var sessionID: String?
    var command: String?
    var filePathsJSON: String
    var requiresConfirmation: Bool
    var isAcknowledged: Bool
    var matchedRuleID: String?
    var searchText: String

    init(_ risk: RiskEvent) {
        rowID = risk.id.uuidString
        timestamp = risk.timestamp
        level = risk.level.rawValue
        levelRank = risk.level.rank
        category = risk.category.rawValue
        title = risk.title
        detail = risk.detail
        agentID = risk.agentID?.uuidString
        agentKind = risk.agentKind.rawValue
        sessionID = risk.sessionID?.uuidString
        command = risk.command
        filePathsJSON = SwiftDataValues.json(risk.filePaths)
        requiresConfirmation = risk.requiresConfirmation
        isAcknowledged = risk.isAcknowledged
        matchedRuleID = risk.matchedRuleID
        searchText = SwiftDataSearchText.risk(risk)
    }
}

// MARK: - projects

/// 对应 SQLite `projects` 表：项目级 AI 活动地图。
@Model
final class SDProject {
    /// `ProjectActivity.id`（就是 path 字符串，非 UUID）。
    @Attribute(.unique) var rowID: String
    var name: String
    var path: String
    var fileChangeCount: Int
    var commandCount: Int
    var sessionCount: Int
    var riskEventCount: Int
    var codeGrowthLines: Int
    var codeShrinkLines: Int
    var agentContributionsJSON: String
    var hotFilesJSON: String
    var firstSeenAt: Date
    var lastSeenAt: Date

    init(_ project: ProjectActivity) {
        rowID = project.id
        name = project.name
        path = project.path
        fileChangeCount = project.fileChangeCount
        commandCount = project.commandCount
        sessionCount = project.sessionCount
        riskEventCount = project.riskEventCount
        codeGrowthLines = project.codeGrowthLines
        codeShrinkLines = project.codeShrinkLines
        agentContributionsJSON = SwiftDataValues.json(project.agentContributions)
        hotFilesJSON = SwiftDataValues.json(project.hotFiles)
        firstSeenAt = project.firstSeenAt
        lastSeenAt = project.lastSeenAt
    }
}

// MARK: - file_snapshots

/// 对应 SQLite `file_snapshots` 表：文件内容快照（哈希/大小/行数）。
@Model
final class SDFileSnapshot {
    @Attribute(.unique) var rowID: String
    var path: String
    var contentHash: String
    var sizeBytes: Int
    var lineCount: Int
    var capturedAt: Date

    init(_ snapshot: FileSnapshot) {
        rowID = snapshot.id.uuidString
        path = snapshot.path
        contentHash = snapshot.contentHash
        sizeBytes = SwiftDataValues.integer(from: snapshot.sizeBytes)
        lineCount = snapshot.lineCount
        capturedAt = snapshot.capturedAt
    }
}

// MARK: - Schema 注册表

/// 一次删除/计数操作的目标实体描述。
enum SwiftDataEntity {

    /// 按时间列批量清理的实体（顺序即删除顺序：先子后父，对齐 `StoreSchema.prunable`）。
    case fileSnapshots
    case diffs
    case perfSamples
    case events
    case fileChanges
    case commands
    case riskEvents
    case systemPerf
    case sessions
    case agents
    case projects

    /// SQLite 侧的表名，仅用于 `rowCount(table:)` / `prune` 结果字典的 key，
    /// 让调用方在两个后端之间看到同一套标识符。
    var tableName: String {
        switch self {
        case .fileSnapshots: "file_snapshots"
        case .diffs: "diffs"
        case .perfSamples: "perf_samples"
        case .events: "events"
        case .fileChanges: "file_changes"
        case .commands: "commands"
        case .riskEvents: "risk_events"
        case .systemPerf: "system_perf"
        case .sessions: "sessions"
        case .agents: "agents"
        case .projects: "projects"
        }
    }

    /// 保留期清理使用的时间列（SQLite 列名口径），与 `StoreSchema.prunable` 逐字一致。
    var timestampColumn: String {
        switch self {
        case .fileSnapshots, .diffs: "captured_at"
        case .perfSamples, .events, .fileChanges, .riskEvents, .systemPerf: "timestamp"
        case .sessions, .commands: "started_at"
        case .agents, .projects: "last_seen_at"
        }
    }
}

/// SwiftData 后端的 schema 定义：实体清单与清理顺序。
enum ObservatorySchema {

    /// 全部 11 个实体，顺序与 `StoreSchema.allTables` 一致（反向）。
    static var models: [any PersistentModel.Type] {
        [
            SDFileSnapshot.self,
            SDDiff.self,
            SDPerformanceSample.self,
            SDEvent.self,
            SDFileChange.self,
            SDCommand.self,
            SDRiskEvent.self,
            SDSystemPerformanceSample.self,
            SDSession.self,
            SDAgent.self,
            SDProject.self,
        ]
    }

    /// 供 `ModelContainer` 使用的 schema。
    static var schema: Schema { Schema(models) }

    /// 保留期清理顺序（先子后父）。
    static let prunable: [SwiftDataEntity] = [
        .fileSnapshots, .diffs, .perfSamples, .events, .fileChanges,
        .commands, .riskEvents, .systemPerf, .sessions, .agents, .projects,
    ]

    /// `rowCount(table:)` 唯一合法的表名白名单。
    static let allTableNames: [String] = prunable.map(\.tableName)
}
