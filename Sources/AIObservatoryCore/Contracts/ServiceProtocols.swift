//
//  ServiceProtocols.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 冻结契约。禁止并行工作流修改。
//
//  这是整个系统的"插座"：
//    · Engine 负责实现      ObservatoryService / ObservatoryControlling / ObservatoryEventStreaming
//    · UI    只依赖协议      （因此 UI 与 Engine 可以完全并行开发）
//    · Platform 各采集器实现 CollectorContracts.swift 中的协议
//

import Foundation

// MARK: - Service

/// 只读查询门面。UI 层的唯一数据入口。
public protocol ObservatoryService: Sendable {
    /// **单日**聚合的旧口径。⚠️ 新代码不要用：它把"选哪一天"和"算到几时"塞进同一个 `Date`，
    /// 于是选「7 天」时算出来的还是某一天（#75 修的正是这个）。
    ///
    /// 留着是因为它是 `ObservatoryService` 的既有契约成员，且内存参照实现
    /// （`AIObservatoryTestSupport`，§3 冻结区）只实现这一条；
    /// 两个真后端把它退化转交给区间版（窗口 = `.today(date)`，与改造前逐字同口径）。
    func dashboardStats(for date: Date) async throws -> DashboardStats
    /// **时段累计**聚合：区间内的会话 / 事件 / 文件 / 命令 / 风险 / 采样按 `range` 的
    /// **闭区间**取数（端点真进 SQL `ts >= ? AND ts <= ?`，与另六个板块同形），
    /// 活动分桶覆盖整个区间。
    ///
    /// 默认实现退化成"那一天"（见下面那条 MARK 的注释）：**只有把取数真正下推到窗口的后端
    /// 才必须重写它**，两个真后端各自重写了；漏重写是无声的，所以
    /// `DashboardRangeParityTests` 拿 1 小时 / 24 小时 / 7 天三档逐格钉住（同 ICR-0007 那条护栏的形状）。
    ///
    /// - Parameter settledAt: 只服务一件事：**还没结算的会话长度算到哪个时刻**
    ///   （`duration(until:)` 对 `endedAt == nil` 的会话要用它）。它不再承担"选哪一天"：
    ///   传区间末或"现在"，两者都必须晚于未结算会话的 `startedAt`，否则时长会被夹成 0。
    /// - Parameter range: 统计窗口；`.unbounded` = 不限。
    func dashboardStats(settledAt: Date, within range: DateRangeFilter) async throws -> DashboardStats
    func activeAgents() async throws -> [AgentInstance]
    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession>
    func session(id: UUID) async throws -> AgentSession?
    func events(matching query: EventQuery) async throws -> Page<TimelineEvent>
    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange>
    func fileDiff(for changeID: UUID) async throws -> FileDiff?
    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord>
    /// 某会话在**整个保留期内**的性能采样（时间升序，无上限）。
    ///
    /// ⚠️ 重消费者（界面、分析）必须走 `performanceSamples(sessionID:limit:)`（ICR-0007）。
    /// 本成员保留只服务一个场景：**导出全量**——那时确实需要每一行。
    /// 3 s 一拍 × 30 天保留期是 86 万行量级，刷一次页就重建一遍这个数量的对象。
    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample]
    /// 保留期内**全部**整机采样（时间升序，无上限）。⚠️ 同上：重消费者走 `systemPerformance(since:limit:)`。
    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample]
    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent>
    func projects() async throws -> [ProjectActivity]
    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity?

    // MARK: 带上限的取数（ICR-0007）

    /// 某会话**最新 `limit` 条**采样，返回仍按时间升序。
    ///
    /// 界面那三处（`PerformanceModel` 的整机/会话读数）与 `PerformanceSessionBreakdown`
    /// 要的就是这条：截断必须发生在**取数层**（SQL 的 `ORDER BY … DESC LIMIT ?`、
    /// SwiftData 的 `fetchLimit`），而不是把整段捞回后再 `suffix(n)`。
    /// `limit <= 0` 必须返回空数组——两个真后端都是这么实现的，理由见下面默认实现的注释。
    func performanceSamples(sessionID: UUID, limit: Int) async throws -> [PerformanceSample]
    /// 保留期内**最新 `limit` 条**整机采样，返回按时间升序。语义与上面同构。
    func systemPerformance(since date: Date, limit: Int) async throws -> [SystemPerformanceSample]
}

// MARK: - 区间聚合的退化桥（#75）

public extension ObservatoryService {

    /// 默认实现 = 把区间丢掉、只按 `settledAt` 那一天算（= #75 改造前的行为）。
    ///
    /// 为什么允许"丢掉"：`ObservatoryService` 的 conformer 里除了两个真后端，还有
    /// 内存参照实现（§3 冻结区）、界面预览桩和别的车道的测试替身——它们各自只实现了
    /// 单日版。给新成员配一条默认实现，它们不改一行就仍满足契约，这与下面
    /// `performanceSamples(sessionID:limit:)` 那条默认实现是同一条理由（ICR-0007）。
    ///
    /// ⚠️ **这条桥本身就是被修掉的那个形状**：两个真后端各自重写了它，把窗口下推进查询。
    /// 忘了重写是**无声的**（读数看起来只是偏小），所以 `DashboardRangeParityTests`
    /// 用 1 小时 / 24 小时 / 7 天三档钉住两个真后端各给不同窗口。
    /// 单日版仍留在契约里 ⇒ 这里不存在"互相转调转到无穷"的死角。
    func dashboardStats(settledAt: Date, within range: DateRangeFilter) async throws -> DashboardStats {
        try await dashboardStats(for: settledAt)
    }
}

// MARK: - 带上限取数的默认实现

public extension ObservatoryService {

    /// 默认实现 = 转调无界版再取尾部 `limit` 条。**存在意义是让既有的 conformer
    /// （内存参考实现、界面预览桩、测试替身）不改一行也能满足新契约成员**——
    /// 否则加一个协议成员就要同时改四个不属于本车道的文件。
    ///
    /// ⚠️ 这条默认实现**本身就是要被修掉的那个形状**：它先整段解码再截断，
    /// 省不下任何分配。两个真后端（`ObservatoryStore`、`SwiftDataObservatoryStore`）
    /// 各自重写了它，把截断推到查询里；那件事由
    /// `BoundedPerformanceReadContractTests` 用成本比值钉住——
    /// **默认实现不能变成"有定义没生产者"的第二位成员，反过来也一样：
    /// 有了默认实现之后，忘了重写是无声的**，所以那条用例是这条默认实现的配套闸门，不是可选项。
    func performanceSamples(sessionID: UUID, limit: Int) async throws -> [PerformanceSample] {
        guard limit > 0 else { return [] }
        return Array(try await performanceSamples(sessionID: sessionID).suffix(limit))
    }

    /// 同上。`limit <= 0` 返回空数组而不是"不设限"：SQLite 的 `LIMIT -1` 与 SwiftData 的
    /// `fetchLimit = 0` 都是"取全部"，把非正数直传下去正好重新敞开这条要修的退化。
    func systemPerformance(since date: Date, limit: Int) async throws -> [SystemPerformanceSample] {
        guard limit > 0 else { return [] }
        return Array(try await systemPerformance(since: date).suffix(limit))
    }
}

// MARK: - Control

/// 生命周期控制。
public protocol ObservatoryControlling: Sendable {
    func start() async
    func stop() async
    func rescanNow() async
    /// 标记风险事件为已确认。**抛错 = 没有落库**，调用方不得据此更新界面状态。
    ///
    /// 为什么是 `throws` 而不是"失败只记日志"：原先协议不抛错，引擎把失败吞进
    /// `os_log`，而 `SecurityModel.acknowledge` 紧接着无条件 `markAcknowledged`
    /// ⇒ 用户看到"已确认"，库里那条仍是未确认，**重启就翻回去**。
    /// 风险确认是需求⑧ 的处置动作，"以为处置过了"比"报错说没处置成"严重得多。
    func acknowledgeRiskEvent(id: UUID) async throws

    /// 应用新设置：持久化并让可热生效的项立即起作用。
    ///
    /// 没有这个入口时，设置面板改完只活在 UI 本地副本里，既不生效也不跨启动保留。
    /// 实现方应把设置写入自身数据目录，并在下一轮采集就用新值，而不是要求重启。
    ///
    /// 能热生效的项：采样与扫描间隔、保留天数、监控根、忽略路径规则、风险确认开关、
    /// diff 明文开关（`storeDiffPlaintext`，下一条文件事件就用新值；它只管**以后**写什么，
    /// 已经落库的明文不会因此被抹掉——那需要另一次清理动作，别指望这个开关做删除）。
    /// 需要重启才生效的项（实现方需在文档里讲清，不得假装已生效）：
    /// 主题、开机启动、EndpointSecurity、菜单栏、数据库目录。
    /// - Parameter settings: 完整的新设置快照。
    func updateSettings(_ settings: ObservatorySettings) async
}

// MARK: - Live Updates

/// 实时推送。UI 订阅此流以刷新界面。
public enum ObservatoryUpdate: Sendable, Hashable {
    case timelineEvent(TimelineEvent)
    case agents([AgentInstance])
    case sessions([AgentSession])
    case fileChange(FileChange)
    case command(CommandRecord)
    case performance(PerformanceSample)
    case risk(RiskEvent)
    case dashboard(DashboardStats)
    case engineState(EngineState)
}

public enum EngineState: String, Sendable, Codable, Hashable {
    case stopped
    case starting
    case running
    case degraded
    case failed

    /// 中文口径（既有调用点与用例的口径，逐字未变）。
    ///
    /// ⚠️ 界面渲染请用 `displayName(_:)` 并显式传语言：本值是裸中文，英文态会夹中文（#67）。
    public var displayName: String { displayName(.chineseSimplified) }

    /// 名字的唯一出处是 `Core/L10N/ContractCopy.swift`（非冻结区），这里只转发。
    /// `switch` 覆盖全部 case ⇒ 新增状态漏译是**编译错误**，不是等人在英文态看见。
    public func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .stopped:  return ContractCopy.engineStopped.text(language)
        case .starting: return ContractCopy.engineStarting.text(language)
        case .running:  return ContractCopy.engineRunning.text(language)
        case .degraded: return ContractCopy.engineDegraded.text(language)
        case .failed:   return ContractCopy.engineFailed.text(language)
        }
    }
}

public protocol ObservatoryEventStreaming: Sendable {
    /// 每次调用返回一条独立的订阅流。
    func makeUpdateStream() -> AsyncStream<ObservatoryUpdate>
    func currentState() async -> EngineState
}

// MARK: - Settings

public struct ObservatorySettings: Codable, Sendable, Equatable, Hashable {
    public var monitoredRoots: [String]
    public var ignoredPathPatterns: [String]
    /// 一轮采集的间隔。**引擎唯一那条循环（`ObservatoryEngine.startScanLoop`）读的就是这个值**，
    /// 而 `runTick()` 一支里就含「Agent → 命令 → 性能 → 项目 → 保留期」。
    ///
    /// 这里曾经有过第二个字段 `sampleIntervalSeconds`（默认 2），命名上像是"性能采样间隔"，
    /// 但**引擎侧从来没有人读它**——它只驱动 UI 的刷新节奏和一句"引擎每 2 秒采样一次"的文案，
    /// 而真实节奏是 3 秒。留两个名字相近、只有一个有生产者的字段，等于留一处必然漂移，
    /// 所以删掉；性能页改读本字段。删键对旧设置文件是安全的：`CodingKeys` 里没有的键
    /// 会被 `JSONDecoder` 直接忽略（`SettingsDecodingCompatibilityTests` 里有回归）。
    public var processScanIntervalSeconds: Double
    public var retentionDays: Int
    public var enableEndpointSecurity: Bool
    public var enableMenuBarExtra: Bool
    public var enableRiskConfirmation: Bool
    public var theme: AppTheme
    public var launchAtLogin: Bool
    public var storeDirectory: String
    /// 是否把 diff 的文件内容明文落库。默认 true = 维持历史行为。
    /// 关掉之后仍写：所属变更、增删行数、`baselineSource` 与内容指纹（`file_snapshots`），
    /// 只是 `lines` 清空并把 `plaintextStored` 标成 false —— 面板要说「明文已按设置关闭」。
    public var storeDiffPlaintext: Bool
    /// #61 演示/脉敏（脱敏）输出。**只影响给人读的那一份字符串**（界面路径列、导出报告），
    /// 库里存的仍是原始绝对路径——审计历史不可追溯改写（#41「写入时冻结」、
    /// `README.md:178`「能少采，不能采了再遮」）。默认 false ⇒ 没打开之前所有输出与今天逐字一致。
    ///
    /// ⚠️ 加这个字段时**三处必须同改**（字段 / `CodingKeys` / 下面手写 `init(from:)`）：
    /// 只漏第三处不报错、不崩，表现为「用户拨了、存了、重启回到默认」，
    /// 是 ADR-0006「有人拨、没人读」的镜像变体「**有人拨、没人存**」。
    /// 制度性护栏：`Tests/AIObservatoryEngineTests/SettingsFieldRoundTripTests.swift`。
    public var demoRedactedOutput: Bool
    /// #59 高危操作实时通知。为 true 时，出现 HIGH / CRITICAL 风险事件会发一条 macOS 用户通知
    /// （内容 = 等级/类别/Agent 名/命令摘要/时间，**摘要先去绝对路径再过 #34 凭据脱敏，绝不含完整路径**）。
    /// 默认 true：需求原文要「危险操作需要确认」，默认关等于没这功能。
    /// 投递与去重判定在 `AIObservatoryPlatform.RiskNotificationCoordinator`；本字段是它的真消费者来源
    /// （关掉 ⇒ 协调器判 `.disabledBySetting`、零投递，见其用例）。
    /// 生效时机：**重启生效**——`ObservatoryRuntime.settings` 是冻结的值快照、非可观察，
    /// 与 `theme` / `enableMenuBarExtra` 同档，面板文案须如实写「改后重启生效」，不得假装热切换。
    ///
    /// ⚠️ 与 `demoRedactedOutput` 同规：字段 / `CodingKeys` / 手写 `init(from:)` 三处必须同改
    /// （漏第三处 ⇒ 「拨了重启静默回落 true」，不报错）；护栏 `SettingsFieldRoundTripTests` /
    /// `SettingsFieldCoverageTests` 当场拓红。
    public var notifyHighRisk: Bool

    public init(
        monitoredRoots: [String] = [],
        ignoredPathPatterns: [String] = [],
        processScanIntervalSeconds: Double = 3,
        retentionDays: Int = 30,
        enableEndpointSecurity: Bool = false,
        enableMenuBarExtra: Bool = true,
        enableRiskConfirmation: Bool = true,
        theme: AppTheme = .system,
        launchAtLogin: Bool = false,
        storeDirectory: String = "",
        storeDiffPlaintext: Bool = true,
        demoRedactedOutput: Bool = false,
        notifyHighRisk: Bool = true
    ) {
        self.monitoredRoots = monitoredRoots
        self.ignoredPathPatterns = ignoredPathPatterns
        self.processScanIntervalSeconds = processScanIntervalSeconds
        self.retentionDays = retentionDays
        self.enableEndpointSecurity = enableEndpointSecurity
        self.enableMenuBarExtra = enableMenuBarExtra
        self.enableRiskConfirmation = enableRiskConfirmation
        self.theme = theme
        self.launchAtLogin = launchAtLogin
        self.storeDirectory = storeDirectory
        self.storeDiffPlaintext = storeDiffPlaintext
        self.demoRedactedOutput = demoRedactedOutput
        self.notifyHighRisk = notifyHighRisk
    }

    public static let `default` = ObservatorySettings(
        monitoredRoots: [],
        ignoredPathPatterns: [
            "*/Library/Caches/*",
            "*/.build/*",
            "*/node_modules/*",
            "*/.git/objects/*",
            "*/DerivedData/*",
            "*.tmp"
        ]
    )

    /// 键名逐字固定：**已经写在用户磁盘上的 `settings.json` 用的就是这些键**，
    /// 改任何一个都等于让老文件读不出来。新增字段请往后面加，不要重命名既有键。
    ///
    /// 但**删键是安全的**，和改名不是一回事：不在 `CodingKeys` 里的键会被 `JSONDecoder`
    /// 直接跳过，老文件里残留的 `sampleIntervalSeconds` 因此只是被忽略，不会解码失败、
    /// 也不会触发 `SettingsPersistence.restore` 那条「文件损坏 ⇒ 全部回落默认」的路径。
    /// （`SettingsDecodingCompatibilityTests` 里有一条专门钉这件事。）
    private enum CodingKeys: String, CodingKey {
        case monitoredRoots
        case ignoredPathPatterns
        case processScanIntervalSeconds
        case retentionDays
        case enableEndpointSecurity
        case enableMenuBarExtra
        case enableRiskConfirmation
        case theme
        case launchAtLogin
        case storeDirectory
        case storeDiffPlaintext
        case demoRedactedOutput
        case notifyHighRisk
    }

    /// **向后兼容的解码**：缺字段不报错，逐项回落到 `ObservatorySettings.default`。
    ///
    /// 为什么要手写：Swift 合成的 `Decodable` **不会**用属性默认值去补缺失的键——
    /// 非 Optional 的键一旦不在 JSON 里就抛 `keyNotFound`。而调用方
    /// （`SettingsPersistence.restore`）在 catch 里把任何解码失败都当成「文件损坏」并返回 `nil`，
    /// 于是**给这个 struct 加一个新字段，就会让所有老用户的全部设置被静默重置回默认值**。
    /// 默认值只在 `default` 一处定义，避免 `init` 与解码器两边各写一份、日后走偏。
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let baseline = ObservatorySettings.default
        self.init(
            monitoredRoots: try container.decodeIfPresent([String].self, forKey: .monitoredRoots)
                ?? baseline.monitoredRoots,
            ignoredPathPatterns: try container.decodeIfPresent([String].self, forKey: .ignoredPathPatterns)
                ?? baseline.ignoredPathPatterns,
            processScanIntervalSeconds: try container.decodeIfPresent(
                Double.self, forKey: .processScanIntervalSeconds
            ) ?? baseline.processScanIntervalSeconds,
            retentionDays: try container.decodeIfPresent(Int.self, forKey: .retentionDays)
                ?? baseline.retentionDays,
            enableEndpointSecurity: try container.decodeIfPresent(Bool.self, forKey: .enableEndpointSecurity)
                ?? baseline.enableEndpointSecurity,
            enableMenuBarExtra: try container.decodeIfPresent(Bool.self, forKey: .enableMenuBarExtra)
                ?? baseline.enableMenuBarExtra,
            enableRiskConfirmation: try container.decodeIfPresent(Bool.self, forKey: .enableRiskConfirmation)
                ?? baseline.enableRiskConfirmation,
            theme: try container.decodeIfPresent(AppTheme.self, forKey: .theme)
                ?? baseline.theme,
            launchAtLogin: try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin)
                ?? baseline.launchAtLogin,
            storeDirectory: try container.decodeIfPresent(String.self, forKey: .storeDirectory)
                ?? baseline.storeDirectory,
            // 缺键回落 true：老用户的 settings.json 从没要求过「不要明文」，
            // 按 false 解码会让他们在升级后突然看不见 diff 内容。
            storeDiffPlaintext: try container.decodeIfPresent(Bool.self, forKey: .storeDiffPlaintext)
                ?? baseline.storeDiffPlaintext,
            // 缺键回落 false：老用户的 settings.json 从没要求过演示输出。
            // 回落 true 等于让人升级之后界面悄悄把路径换成占位符——那是改读数语义，不是加功能。
            demoRedactedOutput: try container.decodeIfPresent(Bool.self, forKey: .demoRedactedOutput)
                ?? baseline.demoRedactedOutput,
            // 缺键回落 true（= baseline）：#59 需求要「危险操作需要确认」，默认开才有意义。
            // 与字段默认同一出处（`ObservatorySettings.default`），不在这另写常量以免走偏。
            notifyHighRisk: try container.decodeIfPresent(Bool.self, forKey: .notifyHighRisk)
                ?? baseline.notifyHighRisk
        )
    }
}

public protocol SettingsStoring: Sendable {
    func load() async -> ObservatorySettings
    func save(_ settings: ObservatorySettings) async
}

// MARK: - Errors

public enum ObservatoryError: Error, Sendable, LocalizedError, Equatable {
    case notRunning
    case storeUnavailable(String)
    case collectorUnavailable(String)
    case permissionDenied(String)
    case invalidQuery(String)
    case unsupported(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning:                 return "观测引擎未运行"
        case .storeUnavailable(let why):  return "本地存储不可用：\(why)"
        case .collectorUnavailable(let w):return "采集器不可用：\(w)"
        case .permissionDenied(let what): return "缺少权限：\(what)"
        case .invalidQuery(let why):      return "查询非法：\(why)"
        case .unsupported(let what):      return "当前环境不支持：\(what)"
        }
    }
}

// MARK: - 采集面实况（ICR-0006）

/// 引擎**这一轮实际**采用的监控范围，以及被剔除的根与原因。
///
/// 为什么要有这个类型：文件页的空态以前只能说半句实话——「比监控根更浅的目录会被采集侧
/// 判为不可用而跳过，但跳过了哪几条界面读不到」。审计工具说"看不到"，得说得出**为什么**
/// 看不到；只报"有这回事"等于把一条默默丢数据的规则藏起来。
///
/// ⚠️ 唯一来源必须是引擎解析时的那一份：界面**不许**自己复刻 `isProtected` 之类的判断，
/// 两个来源就会变成两把尺子（ICR-0003 方案 A 的教训）。
public struct MonitoringScope: Sendable, Hashable {

    /// 被剔除的原因。每个 case 都对应解析循环里一条真实存在的分支——
    /// **没有"没有权限"这一档**：采集侧目前根本没有 TCC/`EACCES` 分支，
    /// 把 skip 说成权限问题就是替一件没发生的事编理由。
    public enum Reason: String, Sendable, Hashable {
        /// 等于 `/`、当前用户家目录或家目录的父目录（`isProtected` 命中）。
        case protectedRoot
        /// 命中用户配置的忽略路径规则。
        case matchedIgnoredPattern
        /// 配置里是一条空路径。
        case emptyPath
        /// 被一个更浅的推导根覆盖（去冗余，不是丢数据）。
        case shadowedByShallowerRoot

        /// 中文口径（既有调用点与用例不变）。界面渲染请用 `displayName(_:)`（#67）。
        public var displayName: String { displayName(.chineseSimplified) }

        /// 唯一出处在 `ContractCopy`，这里只转发；`switch` 覆盖全 case ⇒ 新增原因漏译是编译错误。
        public func displayName(_ language: AppLanguage) -> String {
            switch self {
            case .protectedRoot: return ContractCopy.droppedProtectedRoot.text(language)
            case .matchedIgnoredPattern: return ContractCopy.droppedIgnoredPattern.text(language)
            case .emptyPath: return ContractCopy.droppedEmptyPath.text(language)
            case .shadowedByShallowerRoot: return ContractCopy.droppedShadowed.text(language)
            }
        }
    }

    public struct Dropped: Sendable, Hashable {
        public var path: String
        public var reason: Reason
        /// `matchedIgnoredPattern` 时给出命中的那条规则本身，其余为 nil。
        public var matchedRule: String?

        public init(path: String, reason: Reason, matchedRule: String? = nil) {
            self.path = path
            self.reason = reason
            self.matchedRule = matchedRule
        }
    }

    /// 这一轮真正交给 watcher 的根（升序）。
    public var keptRoots: [String]
    public var dropped: [Dropped]
    public var resolvedAt: Date

    public init(keptRoots: [String], dropped: [Dropped], resolvedAt: Date) {
        self.keptRoots = keptRoots
        self.dropped = dropped
        self.resolvedAt = resolvedAt
    }
}

/// 采集面实况的只读出口。与 `ActivityExportControlling` / `AnomalyAnalyzing` 同形状：
/// 引擎实现、App 层装配进 `ObservatoryRuntime`，界面不依赖 Engine 模块。
public protocol MonitoringScopeReporting: Sendable {
    /// 最近一轮解析出的范围；引擎还没跑过任何一轮时返回 nil
    /// （界面须如实说"尚无采集面读数"，不许画成"没有配置监控根"）。
    func currentMonitoringScope() async -> MonitoringScope?
}

// MARK: - 未归属的机制分布（ICR-0009）

/// 一条文件变更**没能归到某个 Agent 名下**的机制。
///
/// 与 `MonitoringScope.Dropped` 同一个模式：判定发生在引擎里，界面只能报引擎**实际**给出的结论，
/// 不许在界面上复刻一份"看起来为什么会漏"。四个 case 一一对应
/// `ObservatoryEngine.attributedAgent(forPath:)` 返回 nil 的四条出口——
/// **不新增任何判断**，只是把已经走过的分支数出来，所以这里不存在"有定义没生产者"的成员。
public struct AttributionGap: Sendable, Hashable, Codable {

    /// 未归属的机制。rawValue 是稳定标识；界面文案由它查表，**不进数据侧**
    /// （与 ICR-0008 那条"别把渲染结果当事实存"同一口径）。
    public enum Reason: String, CaseIterable, Sendable, Hashable, Codable {
        /// 注册表里一个 Agent 都没有 ⇒ 没有任何候选可参与归因。
        case nothingDetected
        /// 有候选，但没有任何一个拿得到工作目录读数（`PROC_PIDVNODEPATHINFO` 失败/无权限）。
        case detectedWithoutWorkingDirectory
        /// 有候选、也拿到了工作目录，但那个目录**不足以当归属根**（`/`、家目录这类太浅的根，
        /// 见 `MonitoringRootResolver.isUsableAttributionRoot`）。GUI 宿主拉起会话今天走的就是这条。
        case workingDirectoryUnusable
        /// 候选的工作目录都可用，只是**这条路径不在任何一个名下**——唯一"确实不属于谁"的那种。
        case outsideEveryWorkingDirectory

        /// 界面排序用的稳定次序（不依赖 `CaseIterable` 的反射顺序）。
        public var rank: Int {
            switch self {
            case .nothingDetected:                return 0
            case .workingDirectoryUnusable:       return 1
            case .detectedWithoutWorkingDirectory: return 2
            case .outsideEveryWorkingDirectory:   return 3
            }
        }
    }

    /// 各机制的条数。缺项按 0 计。
    public var counts: [Reason: Int]

    public init(counts: [Reason: Int] = [:]) {
        self.counts = counts
    }

    /// 未归属总条数。恒等式 `counts.values.reduce(0,+) == total` 由引擎侧保证，
    /// 并有用例钉住（每条未归属恰好记一个机制，见 `AttributionGapTests`）。
    public var total: Int { counts.values.reduce(0, +) }

    public func count(of reason: Reason) -> Int { counts[reason] ?? 0 }

    public static let empty = AttributionGap()
}

public protocol AttributionGapReporting: Sendable {
    /// **本次运行内**累计的未归属机制分布。
    ///
    /// 引擎还没处理过任何文件事件时返回 nil——"没有读数"与"一条都没漏"是两件事，
    /// 界面须分别说清（ICR-0006 同一条约束）。计数不落库、随进程重启归零，
    /// 所以界面那句必须带"本次运行内"的限定，不许写成保留期内的历史总数。
    func currentAttributionGap() async -> AttributionGap?
}
