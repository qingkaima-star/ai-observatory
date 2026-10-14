//
//  CollectorContracts.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 冻结契约。禁止并行工作流修改。
//
//  Platform 层各采集器必须实现以下协议。
//  UI 与 Engine 只依赖协议，因此在 stub 阶段即可整体编译通过。
//

import Foundation

// MARK: - Process

/// 一条进程快照记录。
public struct ProcessRecord: Identifiable, Codable, Sendable, Hashable {
    public var id: Int32 { pid }
    public var pid: Int32
    public var parentPID: Int32?
    public var name: String
    public var executablePath: String
    public var arguments: [String]
    public var startTime: Date?
    public var cpuPercent: Double
    public var memoryBytes: UInt64
    public var userID: UInt32
    public var bundleIdentifier: String?
    public var tty: String?
    public var workingDirectory: String?

    public init(
        pid: Int32,
        parentPID: Int32? = nil,
        name: String,
        executablePath: String = "",
        arguments: [String] = [],
        startTime: Date? = nil,
        cpuPercent: Double = 0,
        memoryBytes: UInt64 = 0,
        userID: UInt32 = 0,
        bundleIdentifier: String? = nil,
        tty: String? = nil,
        workingDirectory: String? = nil
    ) {
        self.pid = pid
        self.parentPID = parentPID
        self.name = name
        self.executablePath = executablePath
        self.arguments = arguments
        self.startTime = startTime
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
        self.userID = userID
        self.bundleIdentifier = bundleIdentifier
        self.tty = tty
        self.workingDirectory = workingDirectory
    }

    public var commandLine: String { ([name] + arguments).joined(separator: " ") }
}

public protocol ProcessInspecting: Sendable {
    /// 抓取当前时刻全量进程快照（实现应保证 O(进程数) 且低开销）。
    func scanProcesses() async -> [ProcessRecord]
}

// MARK: - Process Tree

/// 由扁平进程列表构建的进程树。
public struct ProcessTree: Sendable {
    public var roots: [TreeNode]

    public struct TreeNode: Identifiable, Sendable, Hashable {
        public var id: Int32 { record.pid }
        public var record: ProcessRecord
        public var children: [TreeNode]
        public var depth: Int

        public init(record: ProcessRecord, children: [TreeNode] = [], depth: Int = 0) {
            self.record = record
            self.children = children
            self.depth = depth
        }
    }

    public init(roots: [TreeNode] = []) { self.roots = roots }
}

/// 识别 Agent 的策略协议。多个策略按优先级串成链。
public protocol AgentDetectionStrategy: Sendable {
    var name: String { get }
    /// 命中则返回识别结果，未命中返回 nil。
    func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult?
}

public struct DetectionContext: Sendable {
    /// 祖先链（由近及远）。识别策略唯一真正读取的输入。
    ///
    /// 这里原来还有 `siblingProcesses` 与 `environment` 两个字段：
    /// 全仓**没有任何生产者写入、也没有任何策略读取**（WS-Hygiene 2026-09-20 grep 确认后交回总控删除）。
    /// `environment` 尤其重要——它对应"按环境变量白名单识别 Agent"这条从未实现的能力；
    /// 留着两个空壳字段会让人以为该能力已经在了。真要做得连同判据一起做。
    public var ancestors: [ProcessRecord]

    public init(ancestors: [ProcessRecord] = []) {
        self.ancestors = ancestors
    }
}

public struct AgentDetectionResult: Sendable, Hashable {
    public var kind: AgentKind
    public var signal: DetectionSignal
    public var confidence: Double
    public var displayName: String

    public init(kind: AgentKind, signal: DetectionSignal, confidence: Double, displayName: String? = nil) {
        self.kind = kind
        self.signal = signal
        self.confidence = confidence
        self.displayName = displayName ?? kind.displayName
    }
}

public protocol AgentDetecting: Sendable {
    /// 扫描并返回当前所有 Agent 实例。
    func detectAgents(using processSource: any ProcessInspecting) async -> [AgentInstance]
    /// 是否具备 EndpointSecurity 级别的实时能力。
    func realtimeCapability() -> RealtimeCapability
}

public enum RealtimeCapability: String, Sendable, Codable, Hashable {
    case endPointSecurity
    case processPolling
    case none

    public var displayName: String {
        switch self {
        case .endPointSecurity: return "EndpointSecurity 实时"
        case .processPolling:   return "轮询模式"
        case .none:             return "不可用"
        }
    }

    /// 这一档对**审计完整性**意味着什么——上屏用的第二行。
    ///
    /// 为什么跟着枚举走而不是写在调用方：`displayName` 与「这意味着什么」是同一个事实的两半，
    /// 拆到 UI 里就变成两处 switch，采集链一旦改动（例如 ES 真的接进来了）只会改掉一处，
    /// 界面于是继续印过期的保真度说法——本仓库的「声明了但没人喂」缺陷类的另一种形态。
    ///
    /// 口径边界（照代码事实写，不照愿景写）：本枚举描述的是**探测到的能力**，
    /// 不是**已在用的采集源**。`EndpointSecurityMonitor` 只做 `es_new_client` 探测，
    /// 全仓库没有任何 `es_subscribe`，所以 `.endPointSecurity` 那一条必须明说「仍未接入采集链」，
    /// 否则这一行本身就是新的谎。
    /// 轮询对几十毫秒级短命命令的漏采比例见 `ObservatoryEngine.Components.commandAuditor`
    /// 的注释（该处记的是 1–2%，具体数字没有在 UI 上复述：它没被测试钉住）。
    public var fidelityNote: String {
        switch self {
        case .endPointSecurity:
            return "探测到本机具备 EndpointSecurity 能力，但当前版本没有把它接进采集链："
                + "命令与文件活动依旧来自进程轮询 + Agent hook。这一行只说明「有能力」，不说明「已在用」。"
        case .processPolling:
            return "命令与文件活动来自定时进程采样与 Agent hook：几十毫秒内结束的命令大概率采不到，"
                + "采样推断出的执行结果一律是「运行中」，只有 hook 才会带真实退出码。"
                + "所以「命令审计」这一页不是全量记录。"
        case .none:
            return "没有可用的实时采集源：命令与文件活动可能整段缺失。"
                + "请把「没有记录」读成「没采到」，不要读成「没发生」。"
        }
    }
}

/// 把「当前探测到的实时能力」只读地暴露给上层（组合根 → 设置页）。
///
/// 为什么不加进 `ObservatoryService`：那是冻结契约，Store / Engine / 内存服务 / 预览服务
/// 四个实现方会同时被打破（同 `Analysis.swift` 里 `ObservatoryAnalysisProviding` 的理由）。
/// 走 `ObservatoryRuntime` 的可选成员：宿主没接时界面显示明确的「未接入」，而不是假的读数。
public protocol RealtimeCapabilityReporting: Sendable {
    /// 当前探测到的实时捕获能力。**只读探针**，不改变任何采集行为。
    func currentRealtimeCapability() -> RealtimeCapability
}

// MARK: - File System

public struct RawFileSystemEvent: Sendable, Hashable {
    public var path: String
    public var previousPath: String?
    public var kind: FileChangeKind
    public var timestamp: Date
    public var isDirectory: Bool
    public var sizeBytes: UInt64

    public init(path: String, previousPath: String? = nil, kind: FileChangeKind, timestamp: Date = Date(), isDirectory: Bool = false, sizeBytes: UInt64 = 0) {
        self.path = path
        self.previousPath = previousPath
        self.kind = kind
        self.timestamp = timestamp
        self.isDirectory = isDirectory
        self.sizeBytes = sizeBytes
    }
}

public protocol FileActivityObserving: Sendable {
    /// 开始监听，返回原始事件流。实现必须自身完成去抖与忽略规则过滤。
    func startObserving(roots: [URL], ignoredPatterns: [String]) throws -> AsyncStream<RawFileSystemEvent>
    func stopObserving() async
}

/// 文件内容快照与 Diff 能力。
public protocol FileSnapshotting: Sendable {
    func snapshot(path: String) async -> FileSnapshot?
    func readTextSnippet(path: String, maxBytes: Int) async -> String?
}

public protocol DiffComputing: Sendable {
    /// 计算两份文本的 diff（实现使用 Myers 或 LCS，不得依赖外部进程）。
    func diff(oldText: String?, newText: String?, path: String, changeKind: FileChangeKind) -> FileDiff
}

// MARK: - System Metrics

public protocol SystemMetricsSampling: Sendable {
    /// 整机采样（CPU / 内存 / 磁盘 / 温度 / 功耗）。
    func sampleSystem() async -> SystemPerformanceSample
    /// 针对指定 PID 集合的进程级采样。
    func sampleProcesses(pids: [Int32]) async -> [Int32: ProcessSample]
}

public struct ProcessSample: Sendable, Hashable {
    public var pid: Int32
    public var cpuPercent: Double
    public var memoryBytes: UInt64

    public init(pid: Int32, cpuPercent: Double, memoryBytes: UInt64) {
        self.pid = pid
        self.cpuPercent = cpuPercent
        self.memoryBytes = memoryBytes
    }
}

// MARK: - Command Audit

public protocol CommandAuditing: Sendable {
    /// 从进程树推断出被 Agent 触发的命令执行。
    func inferCommands(processes: [ProcessRecord], agents: [AgentInstance], since: Date) -> [CommandRecord]
    /// 判断命令的破坏性等级。
    func classify(command: String) -> CommandClassification
}

/// 命令级破坏性判定的结论。
///
/// ⚠️ **这里刻意没有 `reason` 字段**（ADR-0010-命令级不携带判定依据）。
/// 曾经有：`DestructiveCommandRules` 两条支路都往里写 `Rule.reason`，而产品侧消费者为 0
/// （`AgentHookEvent.commandRecord` 只搬 `isDestructive`/`requiresConfirmation`/`riskLevel`，
/// `CommandRecord` 与 `commands` 表都没有承载位）⇒ 契约成员有生产者、无人读，
/// 正是本仓头号缺陷族的新实例。
/// 需求④ 的原文是「记录的命令、执行结果、持续时间」，没有"为什么判成这一级"；
/// 需求⑧ 那条**确认路径上的依据已经在屏上**（`RiskEvent.detail`，由 RiskRules 自己的
/// `rationaleTemplate` 生成）。真要命令级依据，那是**新需求**：要动落库面 + 三后端一致性 + 迁移。
public struct CommandClassification: Sendable, Hashable {
    public var isDestructive: Bool
    public var requiresConfirmation: Bool
    public var level: RiskLevel
    public var category: RiskCategory?

    public init(isDestructive: Bool = false, requiresConfirmation: Bool = false, level: RiskLevel = .low, category: RiskCategory? = nil) {
        self.isDestructive = isDestructive
        self.requiresConfirmation = requiresConfirmation
        self.level = level
        self.category = category
    }

    public static let benign = CommandClassification()
}

// MARK: - Risk Evaluation

public protocol RiskEvaluating: Sendable {
    /// 基于行为上下文产出风险事件（可返回 0…n 条）。
    func evaluate(_ context: RiskContext) -> [RiskEvent]
    /// 供 UI 展示当前加载的规则。
    func loadedRules() -> [RiskRuleDescriptor]
}

public struct RiskContext: Sendable {
    public var event: TimelineEvent?
    public var command: CommandRecord?
    public var fileChange: FileChange?
    public var agentKind: AgentKind
    public var sessionID: UUID?
    /// 同一分钟内的关联文件变更数（用于批量删除判定）。
    public var recentFileChangeCount: Int

    public init(
        event: TimelineEvent? = nil,
        command: CommandRecord? = nil,
        fileChange: FileChange? = nil,
        agentKind: AgentKind = .unknown,
        sessionID: UUID? = nil,
        recentFileChangeCount: Int = 0
    ) {
        self.event = event
        self.command = command
        self.fileChange = fileChange
        self.agentKind = agentKind
        self.sessionID = sessionID
        self.recentFileChangeCount = recentFileChangeCount
    }
}

public struct RiskRuleDescriptor: Identifiable, Sendable, Hashable, Codable {
    public var id: String
    public var name: String
    public var category: RiskCategory
    public var level: RiskLevel
    public var summary: String

    public init(id: String, name: String, category: RiskCategory, level: RiskLevel, summary: String) {
        self.id = id
        self.name = name
        self.category = category
        self.level = level
        self.summary = summary
    }
}
