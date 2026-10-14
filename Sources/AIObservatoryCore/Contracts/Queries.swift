//
//  Queries.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 冻结契约。禁止并行工作流修改。
//

import Foundation

// MARK: - Shared Filtering

public struct DateRangeFilter: Codable, Sendable, Hashable {
    public var start: Date?
    public var end: Date?

    public init(start: Date? = nil, end: Date? = nil) {
        self.start = start
        self.end = end
    }

    public static let unbounded = DateRangeFilter()

    /// 便捷构造：最近 n 小时。
    public static func lastHours(_ hours: Double, now: Date = Date()) -> DateRangeFilter {
        DateRangeFilter(start: now.addingTimeInterval(-hours * 3600), end: now)
    }

    public static func today(_ now: Date = Date(), calendar: Calendar = .current) -> DateRangeFilter {
        let start = calendar.startOfDay(for: now)
        return DateRangeFilter(start: start, end: calendar.date(byAdding: .day, value: 1, to: start))
    }

    /// 判定时间是否落在区间内。
    /// **语义约定：start 与 end 均为闭区间**（`end` 为 nil 表示无上界）。
    /// 这样 `lastHours(2, now: now)` 能正确包含 `now` 本身。
    public func contains(_ date: Date) -> Bool {
        if let start, date < start { return false }
        if let end, date > end { return false }
        return true
    }
}

public struct SortOrder: Codable, Sendable, Hashable {
    public var descending: Bool
    public init(descending: Bool = true) { self.descending = descending }
    public static let newestFirst = SortOrder(descending: true)
    public static let oldestFirst = SortOrder(descending: false)
}

// MARK: - Session Query

public struct SessionQuery: Codable, Sendable, Hashable {
    public var dateRange: DateRangeFilter
    public var agentKinds: Set<AgentKind>
    public var outcomes: Set<SessionOutcome>
    public var projectPath: String?
    public var searchText: String
    public var limit: Int
    public var offset: Int
    public var sort: SortOrder

    public init(
        dateRange: DateRangeFilter = .unbounded,
        agentKinds: Set<AgentKind> = [],
        outcomes: Set<SessionOutcome> = [],
        projectPath: String? = nil,
        searchText: String = "",
        limit: Int = 200,
        offset: Int = 0,
        sort: SortOrder = .newestFirst
    ) {
        self.dateRange = dateRange
        self.agentKinds = agentKinds
        self.outcomes = outcomes
        self.projectPath = projectPath
        self.searchText = searchText
        self.limit = limit
        self.offset = offset
        self.sort = sort
    }

    public static let all = SessionQuery()
}

// MARK: - Event Query

public struct EventQuery: Codable, Sendable, Hashable {
    public var dateRange: DateRangeFilter
    public var kinds: Set<OperationKind>
    public var agentKinds: Set<AgentKind>
    public var sessionID: UUID?
    public var projectPath: String?
    public var minimumRisk: RiskLevel
    public var searchText: String
    public var limit: Int
    public var offset: Int
    public var sort: SortOrder

    public init(
        dateRange: DateRangeFilter = .unbounded,
        kinds: Set<OperationKind> = [],
        agentKinds: Set<AgentKind> = [],
        sessionID: UUID? = nil,
        projectPath: String? = nil,
        minimumRisk: RiskLevel = .low,
        searchText: String = "",
        limit: Int = 500,
        offset: Int = 0,
        sort: SortOrder = .newestFirst
    ) {
        self.dateRange = dateRange
        self.kinds = kinds
        self.agentKinds = agentKinds
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.minimumRisk = minimumRisk
        self.searchText = searchText
        self.limit = limit
        self.offset = offset
        self.sort = sort
    }

    public static let all = EventQuery()
}

// MARK: - File Query

public struct FileChangeQuery: Codable, Sendable, Hashable {
    public var dateRange: DateRangeFilter
    public var kinds: Set<FileChangeKind>
    public var agentKinds: Set<AgentKind>
    public var sessionID: UUID?
    public var projectPath: String?
    public var pathPrefix: String?
    public var searchText: String
    public var limit: Int
    public var offset: Int
    public var sort: SortOrder

    public init(
        dateRange: DateRangeFilter = .unbounded,
        kinds: Set<FileChangeKind> = [],
        agentKinds: Set<AgentKind> = [],
        sessionID: UUID? = nil,
        projectPath: String? = nil,
        pathPrefix: String? = nil,
        searchText: String = "",
        limit: Int = 500,
        offset: Int = 0,
        sort: SortOrder = .newestFirst
    ) {
        self.dateRange = dateRange
        self.kinds = kinds
        self.agentKinds = agentKinds
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.pathPrefix = pathPrefix
        self.searchText = searchText
        self.limit = limit
        self.offset = offset
        self.sort = sort
    }

    public static let all = FileChangeQuery()
}

// MARK: - Command Query

public struct CommandQuery: Codable, Sendable, Hashable {
    public var dateRange: DateRangeFilter
    public var agentKinds: Set<AgentKind>
    public var sessionID: UUID?
    /// 项目路径：与 `FileChangeQuery.projectPath` 同一条口径——**精确相等**（不是前缀匹配），
    /// `nil` 表示不按项目筛；`project_path` 为 NULL 的记录（没采到归属项目）在任何项目条件下都不匹配。
    /// 加这一维是为了「概览 → 证据」那一跳能把项目带进命令页（#81），字段值本身早已在库里
    /// （`commands.project_path`，与 `idx_commands_project` 索引），因此**不多一次取数**。
    public var projectPath: String?
    public var outcomes: Set<CommandOutcome>
    public var destructiveOnly: Bool
    /// 退出码非零：`exit_code IS NOT NULL AND exit_code <> 0`；`false` 表示不过滤。
    ///
    /// 为什么需要这一维（#86）：会话列上「失败命令数」的口径是
    /// `outcome == .failure || exit_code != 0`（与 `SessionLifecycleManager.isFailure`、
    /// `InsightClassifier` 同源）。后半截此前**没法单独问 SQL**，那一格只能靠内存自增——
    /// 而命令行走 `BatchWriter` 缓冲写，"投进缓冲就 +1" 在语句被丢弃时永久虚高
    /// （#78 在文件那三列治过同一个病，代价是同一条路上留了个没治的部位）。
    /// 有了这一个**原语**（不是派生语义），Engine 就能用两次 `COUNT(*)` 把那一格算出来：
    /// `失败 = #(outcome = .failure) + #(outcome ≠ .failure ∧ exit ≠ 0)`
    /// （第二次的 `outcome ≠ .failure` 用 `outcomes` 集合的补集表达，`CommandOutcome` 是 `CaseIterable`）。
    /// 故意不叫 `failedOnly`：那会把判定规则复制进契约，两份实现一旦分叉就没人报警。
    public var withNonZeroExitCode: Bool
    public var searchText: String
    public var limit: Int
    public var offset: Int
    public var sort: SortOrder

    public init(
        dateRange: DateRangeFilter = .unbounded,
        agentKinds: Set<AgentKind> = [],
        sessionID: UUID? = nil,
        projectPath: String? = nil,
        outcomes: Set<CommandOutcome> = [],
        destructiveOnly: Bool = false,
        withNonZeroExitCode: Bool = false,
        searchText: String = "",
        limit: Int = 500,
        offset: Int = 0,
        sort: SortOrder = .newestFirst
    ) {
        self.dateRange = dateRange
        self.agentKinds = agentKinds
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.outcomes = outcomes
        self.destructiveOnly = destructiveOnly
        self.withNonZeroExitCode = withNonZeroExitCode
        self.searchText = searchText
        self.limit = limit
        self.offset = offset
        self.sort = sort
    }

    public static let all = CommandQuery()
}

// MARK: - Risk Query

public struct RiskQuery: Codable, Sendable, Hashable {
    public var dateRange: DateRangeFilter
    public var levels: Set<RiskLevel>
    public var categories: Set<RiskCategory>
    public var agentKinds: Set<AgentKind>
    public var sessionID: UUID?
    /// 项目路径：只看**这个项目里**冒出来的风险（#81 概览 → 证据要带进来的那一维）。
    ///
    /// 【归属口径】风险行自己不挂项目（`RiskEvent` 无项目字段、`risk_events` 无 `project_path` 列），
    /// 它挂的是会话：口径 = 「风险经 `sessionID` 落到那条会话，会话经 `project_path` 落到项目」，
    /// 与 `sessions.risk_event_count` 那条派生边同源（`recomputeSessionRiskCount` 按
    /// `risk_events.session_id = sessions.id` 重算，是全仓唯一的风险↔会话写入口径）。
    /// 因此 `sessionID` 为 nil 的风险行在任何项目条件下都**不匹配**——与 `sessionID = ?`
    /// 那一维同一条规则，宁可少给也不猜（猜一个项目就是把没采到的归属当成事实）。
    /// `nil` = 不按项目筛。精确相等，不做前缀匹配。
    public var projectPath: String?
    public var unacknowledgedOnly: Bool
    public var searchText: String
    public var limit: Int
    public var offset: Int
    public var sort: SortOrder

    public init(
        dateRange: DateRangeFilter = .unbounded,
        levels: Set<RiskLevel> = [],
        categories: Set<RiskCategory> = [],
        agentKinds: Set<AgentKind> = [],
        sessionID: UUID? = nil,
        projectPath: String? = nil,
        unacknowledgedOnly: Bool = false,
        searchText: String = "",
        limit: Int = 300,
        offset: Int = 0,
        sort: SortOrder = .newestFirst
    ) {
        self.dateRange = dateRange
        self.levels = levels
        self.categories = categories
        self.agentKinds = agentKinds
        self.sessionID = sessionID
        self.projectPath = projectPath
        self.unacknowledgedOnly = unacknowledgedOnly
        self.searchText = searchText
        self.limit = limit
        self.offset = offset
        self.sort = sort
    }

    public static let all = RiskQuery()
}

// MARK: - Pagination

public struct Page<Element: Sendable & Codable>: Sendable, Codable {
    public var items: [Element]
    public var totalCount: Int
    public var offset: Int

    public init(items: [Element] = [], totalCount: Int = 0, offset: Int = 0) {
        self.items = items
        self.totalCount = totalCount
        self.offset = offset
    }

    public var hasMore: Bool { offset + items.count < totalCount }
}
