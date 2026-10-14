//
//  DomainModels.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 冻结契约。
//  此文件由项目总控维护。任何并行工作流（workstream）都 **禁止修改本文件**。
//  如需扩展，请在自己的私有目录中扩展，或向总控提交契约变更请求。
//
//  Owner: master-controller
//  Frozen at: scaffold-v0
//

import Foundation

// MARK: - Agent Identity

/// 被审计的 AI Agent 种类。
public enum AgentKind: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case claudeCode
    case openAICodex
    case cursorAgent
    case vscodeCopilot
    case windsurf
    case geminiCLI
    case aiderCLI
    case genericCLIAgent
    case unknown

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .claudeCode:      return "Claude Code"
        case .openAICodex:     return "OpenAI Codex CLI"
        case .cursorAgent:     return "Cursor Agent"
        case .vscodeCopilot:   return "VS Code AI Extension"
        case .windsurf:        return "Windsurf"
        case .geminiCLI:       return "Gemini CLI"
        case .aiderCLI:        return "Aider"
        case .genericCLIAgent: return "Terminal Agent"
        case .unknown:         return "Unknown Agent"
        }
    }

    /// SF Symbol，UI 直接使用。
    public var sfSymbolName: String {
        switch self {
        case .claudeCode:      return "sparkle"
        case .openAICodex:     return "chevron.left.forwardslash.chevron.right"
        case .cursorAgent:     return "cursorarrow.rays"
        case .vscodeCopilot:   return "curlybraces"
        case .windsurf:        return "wind"
        case .geminiCLI:       return "diamond"
        case .aiderCLI:        return "wand.and.stars"
        case .genericCLIAgent: return "terminal"
        case .unknown:         return "questionmark.circle"
        }
    }
}

public enum AgentRunState: String, Codable, Sendable, CaseIterable, Hashable {
    case running
    case idle
    case terminated
}

/// 一个被观测到的 Agent 进程实例。
public struct AgentInstance: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: AgentKind
    public var pid: Int32
    public var parentPID: Int32?
    public var displayName: String
    public var executablePath: String
    public var workingDirectory: String?
    public var bundleIdentifier: String?
    public var tty: String?
    public var startedAt: Date
    public var lastSeenAt: Date
    public var state: AgentRunState
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var childPIDs: [Int32]
    public var detectedVia: DetectionSignal

    public init(
        id: UUID = UUID(),
        kind: AgentKind,
        pid: Int32,
        parentPID: Int32? = nil,
        displayName: String,
        executablePath: String,
        workingDirectory: String? = nil,
        bundleIdentifier: String? = nil,
        tty: String? = nil,
        startedAt: Date,
        lastSeenAt: Date = Date(),
        state: AgentRunState = .running,
        cpuPercent: Double = 0,
        memoryBytes: UInt64 = 0,
        childPIDs: [Int32] = [],
        detectedVia: DetectionSignal = .unknown
    ) {
        self.id = id
        self.kind = kind
        self.pid = pid
        self.parentPID = parentPID
        self.displayName = displayName
        self.executablePath = executablePath
        self.workingDirectory = workingDirectory
        self.bundleIdentifier = bundleIdentifier
        self.tty = tty
        self.startedAt = startedAt
        self.lastSeenAt = lastSeenAt
        self.state = state
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.childPIDs = childPIDs
        self.detectedVia = detectedVia
    }

    public var uptime: TimeInterval { max(0, lastSeenAt.timeIntervalSince(startedAt)) }
}

/// 识别该 Agent 所依赖的信号，便于 UI 展示"我们是如何认定的"。
public enum DetectionSignal: String, Codable, Sendable, CaseIterable, Hashable {
    case processName
    case executablePath
    case bundleIdentifier
    case parentProcessTree
    case terminalSession
    case argumentSignature
    case unknown

    /// 中文口径（既有调用点与用例不变）。界面渲染请用 `displayName(_:)`（#67）。
    public var displayName: String { displayName(.chineseSimplified) }

    /// 唯一出处在 `ContractCopy`，这里只转发。
    public func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .processName:        return ContractCopy.signalProcessName.text(language)
        case .executablePath:     return ContractCopy.signalExecutablePath.text(language)
        case .bundleIdentifier:   return ContractCopy.signalBundleIdentifier.text(language)
        case .parentProcessTree:  return ContractCopy.signalParentProcessTree.text(language)
        case .terminalSession:    return ContractCopy.signalTerminalSession.text(language)
        case .argumentSignature:  return ContractCopy.signalArgumentSignature.text(language)
        case .unknown:            return ContractCopy.signalUnknown.text(language)
        }
    }
}

// MARK: - Session

public enum SessionOutcome: String, Codable, Sendable, CaseIterable, Hashable {
    case running
    case success
    case failed
    case interrupted
    case unknown

    /// 中文口径（既有调用点与用例不变）。界面渲染请用 `displayName(_:)`（#67）。
    public var displayName: String { displayName(.chineseSimplified) }

    /// 唯一出处在 `ContractCopy`，这里只转发。
    public func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .running:     return ContractCopy.sessionRunning.text(language)
        case .success:     return ContractCopy.sessionSuccess.text(language)
        case .failed:      return ContractCopy.sessionFailed.text(language)
        case .interrupted: return ContractCopy.sessionInterrupted.text(language)
        case .unknown:     return ContractCopy.sessionUnknown.text(language)
        }
    }
}

/// 一次 AI 使用会话（Session #102 之类的实体）。
public struct AgentSession: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var displayIndex: Int
    public var kind: AgentKind
    public var agentID: UUID?
    public var title: String
    public var projectPath: String?
    public var startedAt: Date
    public var endedAt: Date?
    public var modifiedFileCount: Int
    public var createdFileCount: Int
    public var deletedFileCount: Int
    public var commandCount: Int
    public var failedCommandCount: Int
    public var cpuSeconds: Double
    public var peakCPUPercent: Double
    public var peakMemoryBytes: UInt64
    public var estimatedTokens: Int
    public var riskEventCount: Int
    public var outcome: SessionOutcome

    public init(
        id: UUID = UUID(),
        displayIndex: Int = 0,
        kind: AgentKind,
        agentID: UUID? = nil,
        title: String = "",
        projectPath: String? = nil,
        startedAt: Date,
        endedAt: Date? = nil,
        modifiedFileCount: Int = 0,
        createdFileCount: Int = 0,
        deletedFileCount: Int = 0,
        commandCount: Int = 0,
        failedCommandCount: Int = 0,
        cpuSeconds: Double = 0,
        peakCPUPercent: Double = 0,
        peakMemoryBytes: UInt64 = 0,
        estimatedTokens: Int = 0,
        riskEventCount: Int = 0,
        outcome: SessionOutcome = .running
    ) {
        self.id = id
        self.displayIndex = displayIndex
        self.kind = kind
        self.agentID = agentID
        self.title = title
        self.projectPath = projectPath
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.modifiedFileCount = modifiedFileCount
        self.createdFileCount = createdFileCount
        self.deletedFileCount = deletedFileCount
        self.commandCount = commandCount
        self.failedCommandCount = failedCommandCount
        self.cpuSeconds = cpuSeconds
        self.peakCPUPercent = peakCPUPercent
        self.peakMemoryBytes = peakMemoryBytes
        self.estimatedTokens = estimatedTokens
        self.riskEventCount = riskEventCount
        self.outcome = outcome
    }

    public var duration: TimeInterval {
        duration(until: Date())
    }

    /// 以指定时刻为终点的会话时长。
    ///
    /// 运行中的会话（`endedAt == nil`）需要一个「当前时间」才能算出时长。
    /// 直接读墙钟会让统计结果依赖测试运行的时刻——凌晨跑测试时
    /// 样本会话会被算成负时长。统计路径一律使用本方法并传入注入的时间。
    /// - Parameter referenceDate: 计算运行中会话时的终点。
    /// - Returns: 非负的已持续秒数。
    public func duration(until referenceDate: Date) -> TimeInterval {
        max(0, (endedAt ?? referenceDate).timeIntervalSince(startedAt))
    }

    public var isActive: Bool { endedAt == nil }
}





