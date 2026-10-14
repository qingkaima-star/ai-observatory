//
//  DomainModels+ProjectsDashboard.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 冻结契约（与 `DomainModels.swift` 同一份契约，只按实体族分文件）。
//  此文件由项目总控维护。任何并行工作流都 **禁止修改本文件**。
//  如需扩展，请在自己的私有目录中扩展，或向总控提交契约变更请求。
//
//  ⚠️ 例外（2026-09-22 总控**点名**授权，台账「整改波次-2026-09-22」§三.1）：
//  `ws/range` 车道为 #75「Dashboard 接真区间」获准改本文件的 **Dashboard 实体族**一处
//  （`DashboardStats` / `HourlyActivity` 与它需要的分桶字段），同文件其它契约
//  （`AgentContribution` / `FileHeat` / `ProjectActivity` / `AppTheme`）一行未动、也仍禁止改动。
//  交付块须贴 public 声明行的多重集 diff 证明射程。
//
//  Owner: master-controller
//  由 DomainModels.swift 原样搬来（#66，总控点名授权）：只搬不改，声明与字面量逐字未动。
//

import Foundation
// MARK: - Project Activity Map

public struct AgentContribution: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var kind: AgentKind
    public var relativeShare: Double
    public var eventCount: Int

    /// 同 ``FileHeat``：身份来自 Agent 种类（`kind.rawValue` 是稳定的字符串枚举），不来自「这次谁算的」。
    public init(id: UUID? = nil, kind: AgentKind, relativeShare: Double, eventCount: Int) {
        self.id = id ?? StableID.uuid(namespace: "agentcontribution", key: kind.rawValue)
        self.kind = kind
        self.relativeShare = relativeShare
        self.eventCount = eventCount
    }
}

public struct FileHeat: Identifiable, Codable, Sendable, Hashable {
    public var id: UUID
    public var path: String
    public var changeCount: Int
    public var linesAdded: Int
    public var linesRemoved: Int
    public var lastTouchedAt: Date
    /// 归一化综合热度 `0...1`，由 `AIObservatoryInsights.HotFileScorer` 算出。
    ///
    /// 可选是为了兼容旧数据：没有它时 UI 退化为按 `changeCount` 排序。
    /// 只报「改了几次」看不出「哪个文件真正值得看」——反复改 3 次的老文件
    /// 和 1 小时被改 20 次的活跃文件，前者数字大但后者才是风险与关注点所在。
    public var score: Double?

    /// `id` 默认由 `path` 推导（见 ``StableID``）：同一文件的同一份热度统计在两轮聚合之间
    /// 必须是同一个身份，否则 `projects` 行会被无意义重写、导出失去字节确定性、`ForEach` 抖动。
    public init(id: UUID? = nil, path: String, changeCount: Int, linesAdded: Int = 0, linesRemoved: Int = 0, lastTouchedAt: Date = Date(), score: Double? = nil) {
        self.id = id ?? StableID.uuid(namespace: "fileheat", key: path)
        self.path = path
        self.changeCount = changeCount
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
        self.lastTouchedAt = lastTouchedAt
        self.score = score
    }

    public var fileName: String { (path as NSString).lastPathComponent }
}

/// 项目级 AI 活动地图。
public struct ProjectActivity: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var path: String
    public var fileChangeCount: Int
    public var commandCount: Int
    public var sessionCount: Int
    public var riskEventCount: Int
    public var codeGrowthLines: Int
    public var codeShrinkLines: Int
    public var agentContributions: [AgentContribution]
    public var hotFiles: [FileHeat]
    public var firstSeenAt: Date
    public var lastSeenAt: Date

    public init(
        id: String,
        name: String,
        path: String,
        fileChangeCount: Int = 0,
        commandCount: Int = 0,
        sessionCount: Int = 0,
        riskEventCount: Int = 0,
        codeGrowthLines: Int = 0,
        codeShrinkLines: Int = 0,
        agentContributions: [AgentContribution] = [],
        hotFiles: [FileHeat] = [],
        firstSeenAt: Date = Date(),
        lastSeenAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.path = path
        self.fileChangeCount = fileChangeCount
        self.commandCount = commandCount
        self.sessionCount = sessionCount
        self.riskEventCount = riskEventCount
        self.codeGrowthLines = codeGrowthLines
        self.codeShrinkLines = codeShrinkLines
        self.agentContributions = agentContributions
        self.hotFiles = hotFiles
        self.firstSeenAt = firstSeenAt
        self.lastSeenAt = lastSeenAt
    }

    public static func identity(path: String) -> String { path }
}

// MARK: - Dashboard

/// 活动柱图的**分桶粒度**（#75，台账裁定 9）。
///
/// 只有两档，按窗口宽度换档：窗口 ≤ 36 小时用小时桶，> 36 小时用自然日桶。
/// 为什么要有这个字段而不是让界面自己判断：粒度一旦有两处判断（取数一处、画图一处），
/// 就会出现"取数按日、标题写小时"那种读数与标签不符——那正是 #75 要修的病。
/// 取数侧是唯一生产者，界面只跟随它。
public enum ActivityBucketSpan: String, Codable, Sendable, Hashable, CaseIterable {
    /// 小时桶：`HourlyActivity.hour` 是自锚点起算的**小时偏移**（0 基）。
    /// 「今天」那一档的锚点就是当地零点 ⇒ 序号 == `Calendar.current` 的时（0…23），与改造前逐字相同。
    case hourOfDay
    /// 自然日桶：`HourlyActivity.hour` 是**带符号的天偏移**（锚点 = `DashboardStats.date`
    /// 所在自然日零点），桶起点 = `date(byAdding: .day, value: hour, to: 锚点)`，往回数是负数。
    case naturalDay

    /// 该档对应的 `Calendar` 粒度：取数侧数桶序号、界面侧还原桶起点都用它，
    /// 免得两边各写一份 `switch`（两把尺子）。
    public var calendarUnit: Calendar.Component {
        switch self {
        case .hourOfDay: return .hour
        case .naturalDay: return .day
        }
    }
}

/// 活动柱图的一个桶。
///
/// ⚠️ 类型名里的 "Hourly" 是**历史名**：#75 之后它的桶可以是小时也可以是自然日
/// （见 `DashboardStats.bucketSpan`），`hour` 字段因此是「桶序号」而不是「几点」——
/// 小时档下它是自锚点起的小时偏移（「今天」那一档锚点 = 当地零点，于是恰好等于 0…23 的时），
/// 日档下它是自锚点起的天偏移。
/// 改名会牵动内存参照实现（§3 冻结区）里按标签构造 `DashboardStats` 的那几行，
/// 不在 #75 的授权射程内，故留名改口径并把注释写清楚。
public struct HourlyActivity: Identifiable, Codable, Sendable, Hashable {
    public var id: Int { hour }
    /// 桶序号，语义由 `DashboardStats.bucketSpan` 决定（见上面的类型注释）。
    public var hour: Int
    public var eventCount: Int
    public var cpuAverage: Double

    public init(hour: Int, eventCount: Int, cpuAverage: Double) {
        self.hour = hour
        self.eventCount = eventCount
        self.cpuAverage = cpuAverage
    }
}

public struct AgentUsageShare: Identifiable, Codable, Sendable, Hashable {
    public var id: AgentKind { kind }
    public var kind: AgentKind
    /// 该 Agent 在**统计窗口内**新建的会话数。
    public var sessionCount: Int
    /// 这些会话在**统计窗口内**累计的时长（未结算的算到 `DashboardStats.date`）。
    public var totalSeconds: Double

    public init(kind: AgentKind, sessionCount: Int, totalSeconds: Double) {
        self.kind = kind
        self.sessionCount = sessionCount
        self.totalSeconds = totalSeconds
    }
}

/// Dashboard 的一次聚合读数。**字段分两类，别再混卖**（#75，台账裁定 3）：
///
/// · **时段累计**：`sessionCount` / `totalActiveSeconds` / `files*` / `commandsExecuted` /
///   `failedCommands` / `risk*` / `average*` / `peak*` / `hourlyActivity` / `agentShares`
///   —— 全部落在 `dashboardStats(settledAt:within:)` 传进来的那个窗口里。
/// · **当前状态快照**：只有 `activeAgentCount`（全表 `state = 'running'`，**不限窗口**）。
///   它跟窗口无关，所以界面必须单独分组显示，也不许跟任何实时列表的长度取大比较。
///
/// 窗口本身不在载荷里重复携带：调用方手里就有那个 `DateRangeFilter`，
/// 载荷只带**分桶口径**（`bucketSpan`）与结算时刻（`date`）——
/// 把同一个窗口在两处各存一份，早晚变成两个数字。
public struct DashboardStats: Codable, Sendable, Hashable {
    /// 结算时刻：未结算会话的 `duration(until:)` 算到这里（= 查询给它的 `settledAt`）。
    public var date: Date
    /// 时段累计：窗口内**新建**的会话数（按 `started_at` 落窗口）。
    public var sessionCount: Int
    public var totalActiveSeconds: Double
    public var filesModified: Int
    public var filesCreated: Int
    public var filesDeleted: Int
    public var commandsExecuted: Int
    public var failedCommands: Int
    public var riskEventCount: Int
    public var highRiskEventCount: Int
    public var averageCPUPercent: Double
    public var peakCPUPercent: Double
    public var peakMemoryBytes: UInt64
    /// **当前状态快照**，不是时段累计：全表 `state = 'running'` 的 Agent 行数，**与查询窗口无关**。
    ///
    /// 换档时刻读它就够了，别拿它跟"窗口内出现过几个 Agent"比大小（#75 取消的正是那种取大）。
    /// ⚠️ 名字里的歧义（"active" 到底是当前还是累计）由 `runningAgentSnapshotCount` 承担，
    /// 本字段名留着是因为内存参照实现按标签构造它，改名要动 §3 冻结区另一份文件。
    public var activeAgentCount: Int
    /// 时段累计：窗口内的活动分桶（粒度见 `bucketSpan`）。
    public var hourlyActivity: [HourlyActivity]
    /// 时段累计：窗口内各 Agent 的会话数与时长占比。
    public var agentShares: [AgentUsageShare]
    /// `hourlyActivity` 的桶粒度（#75，裁定 9）：≤ 36 h 窗口是小时桶，更宽是自然日桶。
    /// 缺省 = 小时桶 ⇒ 只实现"某一天"的 conformer（内存参照实现）不改一行仍与改造前逐字同形。
    ///
    /// **桶锚点不另外携带**（载荷里再放一份窗口，等于给同一个数留两个出处），认法一条：
    ///   · 小时档：锚点 = 窗口起点落到整点 ⇒「今天」那档锚点就是当地零点，序号恰好 == 时；
    ///   · 自然日档：锚点 = `date`（结算时刻）所在自然日的零点 ⇒ 序号是**带符号的天偏移**，
    ///     往回数第七天是 `-7`，今天那格是 `0`。
    /// 取数侧按这条规则补齐连续格子，读的一侧按同一条规则还原日期；
    /// 两侧不许各算一套，由 `DashboardRangeParityTests` 钉住。
    public var bucketSpan: ActivityBucketSpan

    public init(
        date: Date = Date(),
        sessionCount: Int = 0,
        totalActiveSeconds: Double = 0,
        filesModified: Int = 0,
        filesCreated: Int = 0,
        filesDeleted: Int = 0,
        commandsExecuted: Int = 0,
        failedCommands: Int = 0,
        riskEventCount: Int = 0,
        highRiskEventCount: Int = 0,
        averageCPUPercent: Double = 0,
        peakCPUPercent: Double = 0,
        peakMemoryBytes: UInt64 = 0,
        activeAgentCount: Int = 0,
        hourlyActivity: [HourlyActivity] = [],
        agentShares: [AgentUsageShare] = [],
        bucketSpan: ActivityBucketSpan = .hourOfDay
    ) {
        self.date = date
        self.sessionCount = sessionCount
        self.totalActiveSeconds = totalActiveSeconds
        self.filesModified = filesModified
        self.filesCreated = filesCreated
        self.filesDeleted = filesDeleted
        self.commandsExecuted = commandsExecuted
        self.failedCommands = failedCommands
        self.riskEventCount = riskEventCount
        self.highRiskEventCount = highRiskEventCount
        self.averageCPUPercent = averageCPUPercent
        self.peakCPUPercent = peakCPUPercent
        self.peakMemoryBytes = peakMemoryBytes
        self.activeAgentCount = activeAgentCount
        self.hourlyActivity = hourlyActivity
        self.agentShares = agentShares
        self.bucketSpan = bucketSpan
    }

    /// 「当前状态」那一类的**实名**（#75 裁定 9 的命名分离）：此刻在跑的 Agent 数。
    ///
    /// 新代码与界面一律读这个；`activeAgentCount` 是同值的旧名，留着只为不牵动
    /// 内存参照实现与别的车道的构造点。唯一真值仍是 `activeAgentCount` 这一个存储，
    /// 所以这里只是转发，不存在第二把尺子。
    public var runningAgentSnapshotCount: Int { activeAgentCount }

    public static let empty = DashboardStats()
}

// MARK: - App Theme

public enum AppTheme: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case system
    case light
    case dark

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .light:  return "浅色"
        case .dark:   return "深色"
        }
    }
}
