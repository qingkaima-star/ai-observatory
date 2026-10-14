//
//  SwiftDataObservatoryStore+Queries.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-SwiftData
//
//  `ObservatoryService` 的只读查询在 SwiftData 后端的实现：协议 13 个方法里的 12 个。
//  剩下的 `activeAgents()` 已在 `SwiftDataObservatoryStore.swift` 的「辅助查询」段实现，
//  本文件刻意不重复声明（actor 同名成员重定义会编译失败）。
//
//  ── 对齐规则来源 ────────────────────────────────────────────────────────────
//  本文件**逐条镜像** `Sources/AIObservatoryStore/ObservatoryStore+Queries.swift`
//  （SQLite 后端，已真机验证）。它才是语义真相源，而它的每条 SQL 规则又来自冻结的
//  行为基准 `Sources/AIObservatoryTestSupport/InMemoryObservatoryService.swift`。
//  「可切换后端」只有在两个实现返回同一批行、同一顺序、同一计数时才成立，所以：
//    · 分页 = 两条查询：`fetchCount`（**同一个过滤谓词、不带 limit/offset**）给出
//      「过滤后、分页前」的总数；再 `fetch` 同谓词 + `fetchLimit`/`fetchOffset` 取页内行。
//      `Page.offset` 原样回传 `query.offset`。
//    · 负的 limit/offset 收敛为 0（SQL 侧写作 `max(limit, 0)`）。
//    · `Set<枚举>` 空集合 = 不过滤；非空 = `IN`，入参数组按 rawValue 升序（`Set` 的迭代
//      顺序随进程变化，只有排序后才能保证两个后端拿到同一份入参、从而在同一时刻分页出
//      同一批行）。
//    · `DateRangeFilter` 两端**闭区间**。`#Predicate` 不能条件性地省略子句，所以 nil 端用
//      `.distantPast` / `.distantFuture` 当哨兵：它们在 REF 时间轴上远在真实数据之外，
//      比较结果与「不写这条条件」等价。
//    · 搜索：needle 在 Swift 侧 `.lowercased()`（写入侧的 `searchText` 列已是小写
//      haystack），空串跳过该条件。`$0.searchText.contains(needle)` 已实测按**字面**子串
//      匹配（`%` / `_` 不是通配符），与 SQL 的 `instr(search_text, ?) > 0` 同结果
//      —— 判据见 `SwiftDataPredicateCapabilityTests` 第 4、10、11 条。
//    · `projectPath` 是**精确相等**（不是前缀）；只有 `pathPrefix` 用前缀，且必须是
//      `starts(with:)`（`hasPrefix(_:)` 在本 SDK 的谓词宏里编译不过）。
//    · 风险阈值比预计算的 INTEGER 列（`riskRank` / `levelRank`），不比枚举字符串：
//      `#Predicate` 无法调用 `RiskLevel.rank` 这类 Swift 计算属性。
//    · 行还原一律 `records.compactMap { $0.domainValue() }`：枚举 rawValue 认不出、
//      id 不是 UUID、或 diff 的 `linesJSON` 坏掉的行**直接丢弃**，绝不伪造默认值
//      （与 SQL 侧 `StoreRows` 同一口径）。
//
//  ── 排序 ────────────────────────────────────────────────────────────────────
//    · 分页类：时间列方向随 `query.sort.descending`，tie-breaker **恒为 `id` 降序**
//      （对齐 SQL 的 `ORDER BY <时间列> DESC|ASC, id DESC`，让 offset 翻页成为稳定游标）。
//    · 非分页列表的 id 方向各不相同，逐条对齐 SQL，不可照抄分页：
//      `performanceSamples` 与 `systemPerformance` 都是 `timestamp ASC, id ASC`；
//      `projects` 是 `lastSeenAt DESC, id ASC`。
//
//  ── 无聚合 ≠ 无语义 ─────────────────────────────────────────────────────────
//  SwiftData 不暴露 `CASE WHEN` / `SUM`，所以 `dashboardStats` 与 `projectActivity` 里
//  SQL 的一条聚合查询在这里变成「多条 `fetchCount`」（计数）或「一次惰性批量扫描」
//  （求和/求均值，`batchSize: Self.chunkSize`，绝不把整表物化）。数值口径与 SQL 相同。
//
//  注：tie-break 一律写 `SortDescriptor(\.rowID, …)`，**不能**写 `\.id`。
//  `PersistentModel` 自带 `id: PersistentIdentifier`，而它也是 `Comparable`，所以
//  `SortDescriptor(\.id)` 会静默选中框架内部对象 id，而不是那个存 uuidString 的 String 列——
//  与 SQLite 的 `ORDER BY …, id DESC` 就对不上，同刻行的顺序两后端会不一致（直接对照实测翻车）。
//  为此 schema 里那一列名为 `rowID`，让 `\.id` 只剩一个候选；
//  `SwiftDataPredicateCapabilityTests` 第 12 条把这个陷阱钉死。
//

import Foundation
import SwiftData
import AIObservatoryCore

// MARK: - ObservatoryService

extension SwiftDataObservatoryStore: ObservatoryService {

    /// 旧口径：只做"某一天"（`.today(date)` 闭区间），原样转交区间版
    /// （与 SQLite 侧同形；保留是为了满足 `ObservatoryService` 的既有契约成员）。
    public func dashboardStats(for date: Date) async throws -> DashboardStats {
        try await dashboardStats(settledAt: date, within: .today(date))
    }

    /// **时段累计**：会话按 `startedAt`、事件 / 文件 / 风险 / 性能按 `timestamp`、命令按 `startedAt`
    /// 落入 `range` 的**闭区间**（端点真进查询谓词，与 SQLite 侧同形）；只有 `activeAgentCount`
    /// 是**当前状态快照**——它统计**全表** `state == running`，与窗口无关（与 SQLite / InMemory 一致），
    /// #75 起界面单独分组显示它，不再和时段累计并排同格混卖。
    ///
    /// 活动分桶按窗口宽度换档（裁定 9）：**≤ 36 h 小时桶，> 36 h 自然日桶**。
    ///
    /// 三类文件计数、命令总数与失败数、风险总数与高风险数（`levelRank >= RiskLevel.high.rank`）
    /// 各用一条 `fetchCount`；CPU 均值/峰值与分桶来自一次惰性批量扫描。
    /// 所有时长都用注入的 `settledAt` 结算（`duration(until:)`），**不读墙钟**——否则同一批数据
    /// 在不同时刻查询会得到不同的仪表板数值。
    ///
    /// - Throws: 底层 SwiftData 错误（`fetch` / `fetchCount` 失败）。
    ///
    /// 本体只负责「按段取数 → 组装」；每段一条私有助手，口径注释跟着自己那段走
    /// （与 SQLite 侧 `ObservatoryStore+Queries.dashboardStats` 同形，便于逐段对照）。
    public func dashboardStats(settledAt: Date, within range: DateRangeFilter) async throws -> DashboardStats {
        let span = Self.bucketSpan(for: range)
        let lower = range.start ?? .distantPast
        let upper = range.end ?? .distantFuture

        let windowSessions = try await dashboardDaySessions(from: lower, to: upper)
        let eventBuckets = try await dashboardEventBuckets(from: lower, to: upper, span: span)
        let files = try await dashboardFileKindCounts(from: lower, to: upper)
        let commands = try await dashboardCommandCounts(from: lower, to: upper)
        let risks = try await dashboardRiskCounts(from: lower, to: upper)
        let perf = try await dashboardPerformanceRollup(from: lower, to: upper, span: span)
        let activeAgentCount = try await dashboardActiveAgentCount()
        let buckets = Self.activityBuckets(
            eventBuckets: eventBuckets,
            perfBuckets: perf.buckets,
            span: span,
            range: range,
            settledAt: settledAt
        )

        let totalActiveSeconds = windowSessions.reduce(0.0) { $0 + $1.duration(until: settledAt) }
        let averageCPUPercent = perf.sampleCount > 0 ? perf.cpuSum / Double(perf.sampleCount) : 0
        let agentShares = Self.agentShares(for: windowSessions, until: settledAt)

        return DashboardStats(
            date: settledAt,
            sessionCount: windowSessions.count,
            totalActiveSeconds: totalActiveSeconds,
            filesModified: files.modified,
            filesCreated: files.created,
            filesDeleted: files.deleted,
            commandsExecuted: commands.executed,
            failedCommands: commands.failed,
            riskEventCount: risks.total,
            highRiskEventCount: risks.high,
            averageCPUPercent: averageCPUPercent,
            peakCPUPercent: perf.peakCPUPercent ?? 0,
            peakMemoryBytes: perf.peakMemoryBytes ?? 0,
            activeAgentCount: activeAgentCount,
            hourlyActivity: buckets.points,
            agentShares: agentShares,
            bucketSpan: span
        )
    }

    /// 1) 会话：`duration(until:)` 要 startedAt/endedAt、agentShares 要 kind → 整行还原。
    ///    SQL 侧的 `ORDER BY started_at ASC, id ASC` 一并保留（顺序不外泄，但保持可对照）。
    private func dashboardDaySessions(from lower: Date, to upper: Date) async throws -> [AgentSession] {
        try context.fetch(FetchDescriptor<SDSession>(
            predicate: #Predicate<SDSession> { session in
                session.startedAt >= lower && session.startedAt <= upper
            },
            sortBy: [SortDescriptor(\.startedAt), SortDescriptor(\.rowID)]
        )).compactMap { $0.domainValue() }
    }

    /// 2) 事件分桶只需要 timestamp 一列 → 分块游标遍历，不把整张 events 拉进内存。
    ///    排序只为游标稳定，计数与行序无关。返回值按**桶起点**归并（粒度见 `span`），
    ///    序号与补齐交给 `activityBuckets`。
    ///
    ///    ⚠️ SQLite 侧这一格已经下推成 `GROUP BY`（每轮一个桶一行）；本后端**做不到等价**：
    ///    SwiftData 没有聚合/分组取数，只能把行数留在 O(窗口内事件数)。这里能收的是**解码**——
    ///    `SDEvent` 带 title / summary / search_text 三段文本，为一列时间物化整行是白付全文的账，
    ///    所以限定 `propertiesToFetch`。牌上如实写"省解码不省行数"，不假装与 SQL 侧同形状。
    ///    分桶口径与参照实现同源（`Calendar.current`），改这里不会造成后端间偏移。
    private func dashboardEventBuckets(from lower: Date, to upper: Date, span: ActivityBucketSpan) async throws
        -> [Date: Int] {
        var buckets: [Date: Int] = [:]
        var eventDescriptor = FetchDescriptor<SDEvent>(
            predicate: #Predicate<SDEvent> { event in
                event.timestamp >= lower && event.timestamp <= upper
            },
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.rowID)]
        )
        eventDescriptor.propertiesToFetch = [\SDEvent.timestamp]
        try forEachChunk(eventDescriptor) { event in
            let start = Self.floorBucketStart(event.timestamp, span: span)
            buckets[start, default: 0] += 1
        }
        return buckets
    }

    /// 3) 文件变更三类计数：SQL 是一条 `CASE WHEN` 聚合，这里是三条只差 kind 的 COUNT。
    private func dashboardFileKindCounts(from lower: Date, to upper: Date) async throws
        -> (modified: Int, created: Int, deleted: Int) {
        let modifiedKind = FileChangeKind.modified.rawValue
        let createdKind = FileChangeKind.created.rawValue
        let deletedKind = FileChangeKind.deleted.rawValue
        let filesModified = try context.fetchCount(FetchDescriptor<SDFileChange>(
            predicate: #Predicate<SDFileChange> { change in
                change.timestamp >= lower && change.timestamp <= upper && change.kind == modifiedKind
            }
        ))
        let filesCreated = try context.fetchCount(FetchDescriptor<SDFileChange>(
            predicate: #Predicate<SDFileChange> { change in
                change.timestamp >= lower && change.timestamp <= upper && change.kind == createdKind
            }
        ))
        return (
            modified: filesModified,
            created: filesCreated,
            deleted: try context.fetchCount(FetchDescriptor<SDFileChange>(
                predicate: #Predicate<SDFileChange> { change in
                    change.timestamp >= lower && change.timestamp <= upper && change.kind == deletedKind
                }
            ))
        )
    }

    /// 4) 命令：总数 + 失败数（按 startedAt 取窗口）。
    private func dashboardCommandCounts(from lower: Date, to upper: Date) async throws
        -> (executed: Int, failed: Int) {
        let failureOutcome = CommandOutcome.failure.rawValue
        let commandsExecuted = try context.fetchCount(FetchDescriptor<SDCommand>(
            predicate: #Predicate<SDCommand> { command in
                command.startedAt >= lower && command.startedAt <= upper
            }
        ))
        return (
            executed: commandsExecuted,
            failed: try context.fetchCount(FetchDescriptor<SDCommand>(
                predicate: #Predicate<SDCommand> { command in
                    command.startedAt >= lower && command.startedAt <= upper
                        && command.outcome == failureOutcome
                }
            ))
        )
    }

    /// 5) 风险：总数 + 高风险数（`levelRank >= RiskLevel.high.rank` == `level >= .high`）。
    private func dashboardRiskCounts(from lower: Date, to upper: Date) async throws -> (total: Int, high: Int) {
        let highRiskRank = Int(RiskLevel.high.rank)
        let riskEventCount = try context.fetchCount(FetchDescriptor<SDRiskEvent>(
            predicate: #Predicate<SDRiskEvent> { risk in
                risk.timestamp >= lower && risk.timestamp <= upper
            }
        ))
        return (
            total: riskEventCount,
            high: try context.fetchCount(FetchDescriptor<SDRiskEvent>(
                predicate: #Predicate<SDRiskEvent> { risk in
                    risk.timestamp >= lower && risk.timestamp <= upper && risk.levelRank >= highRiskRank
                }
            ))
        )
    }

    /// 会话级性能采样的结算结果：四个标量 + 按**桶起点**归并的 CPU 桶。
    private struct PerformanceRollup {
        var sampleCount = 0
        var cpuSum: Double = 0
        var peakCPUPercent: Double?
        var peakMemoryBytes: UInt64?
        var buckets: [Date: HourBucket] = [:]
    }

    /// 6) 会话级性能采样：均值 / 峰值 / 分桶共用这一条分块扫描。
    ///    SQL 侧对「缺列的行」记账时跳过；这三个属性在 schema 里是非可选列，
    ///    所以取到的每一行都必然入账，不存在伪造。
    ///    与事件那一格同理，这里限定 `propertiesToFetch` 到用得到的四列：
    ///    聚合下推在本后端做不到（无 GROUP BY），但四个标量与各档的格子都不需要
    ///    `SDPerformanceSample` 的 gpu / 磁盘 / 网络 / 温度 / 功率那几列。会话外键这一列
    ///    #96 起要被谓词读（它就是那把主体锁），省不掉了。
    private func dashboardPerformanceRollup(from lower: Date, to upper: Date, span: ActivityBucketSpan) async throws
        -> PerformanceRollup {
        var perfDescriptor = FetchDescriptor<SDPerformanceSample>(
            predicate: #Predicate<SDPerformanceSample> { sample in
                // 与 SQLite 侧同一条主体锁（理由写在 `ObservatoryStore+Queries.dashboardPerformanceRollup`）：
                // 没挂上会话的采样没有归属对象，不进这一格。
                sample.timestamp >= lower && sample.timestamp <= upper && sample.sessionID != nil
            },
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.rowID)]
        )
        perfDescriptor.propertiesToFetch = [
            \SDPerformanceSample.timestamp,
            \SDPerformanceSample.sessionID,
            \SDPerformanceSample.cpuPercent,
            \SDPerformanceSample.memoryBytes,
        ]
        var rollup = PerformanceRollup()
        try forEachChunk(perfDescriptor) { sample in
            rollup.cpuSum += sample.cpuPercent
            rollup.sampleCount += 1
            rollup.peakCPUPercent = max(rollup.peakCPUPercent ?? sample.cpuPercent, sample.cpuPercent)
            // 磁盘上是 Int 的 bit-pattern，还原口径与 `StoreRows.uint64(_:)` 相同。
            let memoryBytes = SwiftDataValues.uint64(from: sample.memoryBytes)
            rollup.peakMemoryBytes = max(rollup.peakMemoryBytes ?? memoryBytes, memoryBytes)
            let start = Self.floorBucketStart(sample.timestamp, span: span)
            var bucket = rollup.buckets[start] ?? HourBucket()
            bucket.cpuSum += sample.cpuPercent
            bucket.cpuSampleCount += 1
            rollup.buckets[start] = bucket
        }
        return rollup
    }

    /// 7) **当前状态快照**（不是时段累计）：全表 `state == running` 的行数，与查询窗口无关。
    ///    #75 起界面单独分组显示它，也不许跟实时进程列表的长度取大（`max(累计, 快照)` 已取消）。
    private func dashboardActiveAgentCount() async throws -> Int {
        let runningState = AgentRunState.running.rawValue
        return try context.fetchCount(FetchDescriptor<SDAgent>(
            predicate: #Predicate<SDAgent> { agent in agent.state == runningState }
        ))
    }

    // MARK: - 私有：Swift 侧细筛判据
    //
    // 逐条照抄冻结基准 `InMemoryObservatoryService` 的对应 `filter` 闭包——包括
    // 「空 Set = 不过滤」「`projectPath` 精确相等」「haystack 在 Swift 侧小写化」这三条。
    // 扫描路径用它兜住没能下推的维度，所以**必须**是全维度判据：哪怕谓词已经筛过一遍，
    // 这里重复判一次也无害，而漏判一个维度就会让两个后端查出不同的行。

    /// 事件全维度判据。
    static func matches(_ event: TimelineEvent, query: EventQuery) -> Bool {
        guard query.dateRange.contains(event.timestamp) else { return false }
        if !query.kinds.isEmpty, !query.kinds.contains(event.kind) { return false }
        if !query.agentKinds.isEmpty, !query.agentKinds.contains(event.agentKind) { return false }
        if let sessionID = query.sessionID, event.sessionID != sessionID { return false }
        if let project = query.projectPath, event.projectPath != project { return false }
        if event.riskLevel < query.minimumRisk { return false }
        if !query.searchText.isEmpty,
           !SwiftDataSearchText.event(event).contains(query.searchText.lowercased()) { return false }
        return true
    }

    /// 文件变更全维度判据。
    static func matches(_ change: FileChange, query: FileChangeQuery) -> Bool {
        guard query.dateRange.contains(change.timestamp) else { return false }
        if !query.kinds.isEmpty, !query.kinds.contains(change.kind) { return false }
        if !query.agentKinds.isEmpty, !query.agentKinds.contains(change.agentKind) { return false }
        if let sessionID = query.sessionID, change.sessionID != sessionID { return false }
        if let project = query.projectPath, change.projectPath != project { return false }
        if let prefix = query.pathPrefix, !change.path.hasPrefix(prefix) { return false }
        if !query.searchText.isEmpty,
           !SwiftDataSearchText.fileChange(change).contains(query.searchText.lowercased()) { return false }
        return true
    }

    /// 命令全维度判据。
    static func matches(_ record: CommandRecord, query: CommandQuery) -> Bool {
        guard query.dateRange.contains(record.startedAt) else { return false }
        if !query.agentKinds.isEmpty, !query.agentKinds.contains(record.agentKind) { return false }
        if let sessionID = query.sessionID, record.sessionID != sessionID { return false }
        if let project = query.projectPath, record.projectPath != project { return false }
        if !query.outcomes.isEmpty, !query.outcomes.contains(record.outcome) { return false }
        if query.destructiveOnly, !record.isDestructive { return false }
        if !query.searchText.isEmpty,
           !SwiftDataSearchText.command(record).contains(query.searchText.lowercased()) { return false }
        return true
    }

    /// 风险事件全维度判据。
    ///
    /// `projectPath` 这条与 SQLite 侧同口径：风险行自己不挂项目，走「风险 → 会话 → 项目」
    /// 那条既有归属边（见 `riskEvents(matching:)`）。`projectSessionIDs` 是「属于本项目的那批
    /// 会话 rowID」，只在 `query.projectPath != nil` 时被读。`sessionID` 为 nil 的风险行
    /// 在任何项目条件下都不匹配。
    static func matches(
        _ risk: RiskEvent, query: RiskQuery, projectSessionIDs: Set<String> = []
    ) -> Bool {
        guard query.dateRange.contains(risk.timestamp) else { return false }
        if !query.levels.isEmpty, !query.levels.contains(risk.level) { return false }
        if !query.categories.isEmpty, !query.categories.contains(risk.category) { return false }
        if !query.agentKinds.isEmpty, !query.agentKinds.contains(risk.agentKind) { return false }
        if let sessionID = query.sessionID, risk.sessionID != sessionID { return false }
        if query.projectPath != nil,
           !(risk.sessionID.map { projectSessionIDs.contains($0.uuidString) } ?? false) { return false }
        if query.unacknowledgedOnly, risk.isAcknowledged { return false }
        if !query.searchText.isEmpty,
           !SwiftDataSearchText.risk(risk).contains(query.searchText.lowercased()) { return false }
        return true
    }

    // MARK: - 私有：分页与单行取数

    /// 存储层分页：`totalCount` 用**只带过滤谓词、不带 limit/offset** 的 `fetchCount`
    /// （过滤后、分页前），页内行给同一个 descriptor 补上 `fetchLimit`/`fetchOffset`。
    ///
    /// 只在谓词已经覆盖**全部**过滤维度时使用，否则 totalCount 与 items 会来自不同集合。
    /// 负 limit/offset 收敛为 0：SQL 侧写作 `max(…, 0)`，而基准实现的
    /// `prefix(-1)`/`dropFirst(-1)` 会直接崩——两侧统一成 0 才谈得上可切换。
    /// 映射失败的行被 `compactMap` 丢弃，因此 `items.count` 可能小于页内行数，
    /// 而 `totalCount` 仍是存储层的行数（与 SQLite 侧的同一差异，不做补偿）。
    private func pagedPage<Model: PersistentModel, Element: Sendable & Codable>(
        _ descriptor: FetchDescriptor<Model>,
        limit: Int,
        offset: Int,
        map: (Model) -> Element?
    ) throws -> Page<Element> {
        let totalCount = try context.fetchCount(descriptor)
        let clampedLimit = max(limit, 0)
        // `fetchLimit = 0` 在 SwiftData 里是「不限」而不是「零行」，会把整表倒给调用方；
        // SQLite 侧 `LIMIT 0` 是空页。两侧必须一致，所以这里直接短路。
        guard clampedLimit > 0 else {
            return Page(items: [], totalCount: totalCount, offset: offset)
        }
        var paged = descriptor
        paged.fetchLimit = clampedLimit
        paged.fetchOffset = max(offset, 0)
        return Page(
            items: try context.fetch(paged).compactMap(map),
            totalCount: totalCount,
            offset: offset
        )
    }

    /// 分块游标扫描 + Swift 侧细筛。
    ///
    /// 只在「谓词没能覆盖全部过滤维度」时走（见各查询里的 `complete` 判定）。语义仍然精确：
    /// 谓词是细筛集合的**超集**（只会多带行，不会漏行），而 `passes` 逐条照抄冻结基准的判据。
    /// 代价从 `O(log n + 页长)` 变成 `O(谓词命中行数)`；内存由 `chunkSize` 钉住——
    /// 每轮只物化一块 `@Model`，绝不一次拉全表。
    private func scannedPage<Model: PersistentModel, Element: Sendable & Codable>(
        _ descriptor: FetchDescriptor<Model>,
        limit: Int,
        offset: Int,
        map: (Model) -> Element?,
        passes: (Element) -> Bool
    ) throws -> Page<Element> {
        let clampedLimit = max(limit, 0)
        let clampedOffset = max(offset, 0)
        var items: [Element] = []
        var totalCount = 0
        var scanned = 0
        while true {
            var chunk = descriptor
            chunk.fetchLimit = Self.chunkSize
            chunk.fetchOffset = scanned
            let rows = try context.fetch(chunk)
            if rows.isEmpty { break }
            scanned += rows.count
            for element in rows.compactMap(map) where passes(element) {
                totalCount += 1
                if totalCount > clampedOffset, items.count < clampedLimit {
                    items.append(element)
                }
            }
            if rows.count < Self.chunkSize { break }
        }
        return Page(items: items, totalCount: totalCount, offset: offset)
    }

    /// 两条路径的分派器。
    ///
    /// `complete` 必须如实回答「这条查询的每个过滤维度都进了谓词吗」：
    /// - true  → 存储层分页（快路径，默认时间线/大数据列表都走这里）；
    /// - false → 游标扫描 + 细筛（语义不变，成本上升）。
    ///
    /// 判错的后果是静默少行，所以每个调用点都把留在 Swift 侧的维度写在注释里。
    func page<Model: PersistentModel, Element: Sendable & Codable>(
        _ descriptor: FetchDescriptor<Model>,
        limit: Int,
        offset: Int,
        complete: Bool,
        map: (Model) -> Element?,
        passes: (Element) -> Bool = { _ in true }
    ) throws -> Page<Element> {
        if complete {
            return try pagedPage(descriptor, limit: limit, offset: offset, map: map)
        }
        return try scannedPage(descriptor, limit: limit, offset: offset, map: map, passes: passes)
    }

    /// 按 `chunkSize` 分块走完一个 descriptor，逐行交给 `body`，不一次物化整表。
    ///
    /// 没用 `ModelContext.fetch(_:batchSize:)`：本 SDK 的内存库上它直接抛
    /// `SwiftDataError.includePendingChangesWithBatchSize`（实测），所以退回
    /// `fetchLimit`/`fetchOffset` 游标。**调用方必须给 descriptor 一个确定的排序**，
    /// 否则 OFFSET 翻页会跳行或重复——游标语义依赖行序稳定。
    func forEachChunk<Model: PersistentModel>(
        _ descriptor: FetchDescriptor<Model>,
        _ body: (Model) throws -> Void
    ) throws {
        var offset = 0
        while true {
            var chunk = descriptor
            chunk.fetchLimit = Self.chunkSize
            chunk.fetchOffset = offset
            let rows = try context.fetch(chunk)
            if rows.isEmpty { return }
            for row in rows { try body(row) }
            offset += rows.count
            if rows.count < Self.chunkSize { return }
        }
    }

    /// 按谓词取一行：本 SDK 的 `ModelContext` **没有** `fetchOne`，只能 `fetchLimit = 1` + `first`
    /// （因此也不会为了取一条而物化整表）。
    func firstRow<Model: PersistentModel>(
        of type: Model.Type,
        where predicate: Predicate<Model>
    ) throws -> Model? {
        var descriptor = FetchDescriptor<Model>(predicate: predicate)
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }
}

// MARK: - 内部工具

/// hourly 分桶累加器（事件计数 + CPU 求和/求均值），字段口径与 SQLite 侧的同名私有类型一致。
struct HourBucket {
    var eventCount = 0
    var cpuSum: Double = 0
    var cpuSampleCount = 0
}

/// `Set<枚举>` → 按 rawValue 升序的捕获数组：空数组即「不过滤」哨兵
/// （`#Predicate` 里的 `array.isEmpty || array.contains($0.col)`），非空即 SQL 的 `IN (…)`。
func sortedRawValues<Value: RawRepresentable & Hashable>(_ values: Set<Value>) -> [String]
where Value.RawValue == String {
    values.map(\.rawValue).sorted()
}
