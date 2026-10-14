//
//  DomainModels+CommandsPerformance.swift
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
// MARK: - Command Audit

public enum CommandOutcome: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case running
    case success
    case failure
    case terminated
    case unknown

    public var id: String { rawValue }

    /// 中文口径（既有调用点与用例不变）。界面渲染请用 `displayName(_:)`（#67）。
    ///
    /// ⚠️ 中文侧本来就四条英文（Success/Failure/Terminated/Unknown）+ 一条"运行中"——
    /// 这是**既有产品事实**，本函数照抄不改（改它属于文案决策，另单跟）。
    public var displayName: String { displayName(.chineseSimplified) }

    /// 唯一出处在 `ContractCopy`，这里只转发。
    public func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .running:    return ContractCopy.commandRunning.text(language)
        case .success:    return ContractCopy.commandSuccess.text(language)
        case .failure:    return ContractCopy.commandFailure.text(language)
        case .terminated: return ContractCopy.commandTerminated.text(language)
        case .unknown:    return ContractCopy.commandUnknown.text(language)
        }
    }
}

public struct CommandRecord: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var executable: String
    public var arguments: [String]
    public var workingDirectory: String?
    public var agentID: UUID?
    public var sessionID: UUID?
    public var agentKind: AgentKind
    public var startedAt: Date
    public var endedAt: Date?
    public var exitCode: Int32?
    public var outcome: CommandOutcome
    public var isDestructive: Bool
    public var requiresConfirmation: Bool
    public var riskLevel: RiskLevel
    public var projectPath: String?

    public init(
        id: UUID = UUID(),
        executable: String,
        arguments: [String] = [],
        workingDirectory: String? = nil,
        agentID: UUID? = nil,
        sessionID: UUID? = nil,
        agentKind: AgentKind = .unknown,
        startedAt: Date = Date(),
        endedAt: Date? = nil,
        exitCode: Int32? = nil,
        outcome: CommandOutcome = .running,
        isDestructive: Bool = false,
        requiresConfirmation: Bool = false,
        riskLevel: RiskLevel = .low,
        projectPath: String? = nil
    ) {
        self.id = id
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.agentID = agentID
        self.sessionID = sessionID
        self.agentKind = agentKind
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.exitCode = exitCode
        self.outcome = outcome
        self.isDestructive = isDestructive
        self.requiresConfirmation = requiresConfirmation
        self.riskLevel = riskLevel
        self.projectPath = projectPath
    }

    /// 命令行文本。
    ///
    /// `arguments` 是从 `KERN_PROCARGS2` 读出的**完整 argv**，第一项就是 `argv[0]`，
    /// 而很多程序把 `argv[0]` 写成可执行文件名本身。无脑拼 `executable + arguments`
    /// 会印成「`sleep sleep 4`」（真机 Commands 页实测就是这样）。
    /// 所以 `argv[0]` 与 `executable` 同名（或只是它的路径形式）时不重复输出。
    public var commandLine: String {
        var parts: [String] = [executable]
        if let head = arguments.first,
           head == executable || (head as NSString).lastPathComponent == executable {
            parts.append(contentsOf: arguments.dropFirst())
        } else {
            parts.append(contentsOf: arguments)
        }
        return parts.joined(separator: " ")
    }

    public var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(startedAt)
    }
}

// MARK: - Performance

/// Agent Session 绑定的性能采样。
public struct PerformanceSample: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var timestamp: Date
    public var sessionID: UUID?
    public var agentID: UUID?
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var gpuPercent: Double?
    public var diskReadBytesPerSecond: Double
    public var diskWriteBytesPerSecond: Double
    public var networkBytesIn: UInt64
    public var networkBytesOut: UInt64
    public var thermalCelsius: Double?
    public var powerWatts: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        sessionID: UUID? = nil,
        agentID: UUID? = nil,
        cpuPercent: Double = 0,
        memoryBytes: UInt64 = 0,
        gpuPercent: Double? = nil,
        diskReadBytesPerSecond: Double = 0,
        diskWriteBytesPerSecond: Double = 0,
        networkBytesIn: UInt64 = 0,
        networkBytesOut: UInt64 = 0,
        thermalCelsius: Double? = nil,
        powerWatts: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.sessionID = sessionID
        self.agentID = agentID
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.gpuPercent = gpuPercent
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.networkBytesIn = networkBytesIn
        self.networkBytesOut = networkBytesOut
        self.thermalCelsius = thermalCelsius
        self.powerWatts = powerWatts
    }
}

/// 整机性能采样（用于 Dashboard 实时曲线）。
/// 本轮整机网络速率为什么拿不到。原语与 Platform 侧的内部枚举一一对应，
/// 存在的意义是让界面能说清「等待首次采样」与「这台机器给不出」——两者都显示 0 会撒谎。
public enum NetworkRateAvailability: String, Codable, Sendable, Hashable {
    case awaitingFirstSample   // 还没采到：下一轮就有
    case noElapsedTime         // 时间差 ≤ 0（同一轮被重复采样）
    case counterRegression     // 计数器回退：32 位回绕 / 驱动重载 / 网卡重连
    case interfaceRemoved      // 上一轮的接口这一轮不见了
    case countersUnreadable    // 这台机器给不出网络计数
}

public struct SystemPerformanceSample: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var timestamp: Date
    public var cpuTotalPercent: Double
    public var cpuSystemPercent: Double
    public var cpuUserPercent: Double
    public var memoryUsedBytes: UInt64
    public var memoryTotalBytes: UInt64
    public var diskReadBytesPerSecond: Double
    public var diskWriteBytesPerSecond: Double
    public var loadAverage1m: Double
    public var thermalCelsius: Double?
    public var powerWatts: Double?

    /// 整机网络速率（字节/秒）。`nil` = 本轮拿不到，原因见 ``networkAvailability``；
    /// **`0` 是「真的没有流量」**，两者在界面上必须是不同说法。
    public var networkInBytesPerSecond: Double?
    public var networkOutBytesPerSecond: Double?
    /// 拿不到速率的原因；拿到速率时为 `nil`。
    public var networkAvailability: NetworkRateAvailability?
    /// **整机** GPU 活动近似值（IOAccelerator `PerformanceStatistics["Device Utilization %"]`），
    /// 不是某个 Agent 进程的占用——macOS 没有公开的非 root per-process GPU API。
    /// `nil` = 这台机器给不出，界面显示「不可得」，绝不做成 0%。
    public var gpuActivityPercent: Double?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        cpuTotalPercent: Double = 0,
        cpuSystemPercent: Double = 0,
        cpuUserPercent: Double = 0,
        memoryUsedBytes: UInt64 = 0,
        memoryTotalBytes: UInt64 = 0,
        diskReadBytesPerSecond: Double = 0,
        diskWriteBytesPerSecond: Double = 0,
        loadAverage1m: Double = 0,
        thermalCelsius: Double? = nil,
        powerWatts: Double? = nil,
        networkInBytesPerSecond: Double? = nil,
        networkOutBytesPerSecond: Double? = nil,
        networkAvailability: NetworkRateAvailability? = nil,
        gpuActivityPercent: Double? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.cpuTotalPercent = cpuTotalPercent
        self.cpuSystemPercent = cpuSystemPercent
        self.cpuUserPercent = cpuUserPercent
        self.memoryUsedBytes = memoryUsedBytes
        self.memoryTotalBytes = memoryTotalBytes
        self.diskReadBytesPerSecond = diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = diskWriteBytesPerSecond
        self.loadAverage1m = loadAverage1m
        self.thermalCelsius = thermalCelsius
        self.powerWatts = powerWatts
        self.networkInBytesPerSecond = networkInBytesPerSecond
        self.networkOutBytesPerSecond = networkOutBytesPerSecond
        self.networkAvailability = networkAvailability
        self.gpuActivityPercent = gpuActivityPercent
    }

    public var memoryUsageRatio: Double {
        guard memoryTotalBytes > 0 else { return 0 }
        return Double(memoryUsedBytes) / Double(memoryTotalBytes)
    }
}
