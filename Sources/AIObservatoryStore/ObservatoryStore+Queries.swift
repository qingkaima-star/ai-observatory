//
//  ObservatoryStore+Queries.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine
//  Sub-owner: E
//
//  `ObservatoryService` 只读查询在 SQLite 后端的实现（INTERFACE.md §6E）。
//
//  行为基准（冻结、只读）：Sources/AIObservatoryTestSupport/InMemoryObservatoryService.swift
//  每个 Swift 闭包谓词都逐条移植成 SQL，规则如下：
//    · 分页 = 两条 SQL：`SELECT COUNT(*)`（**过滤后、分页前**总数）+ `… LIMIT ? OFFSET ?`（页内行）；
//      `Page.offset` 原样回传 `query.offset`。
//    · `Set<枚举>` 空集合 = 不过滤；非空 = `col IN (?,?,…)`，参数按 rawValue 升序（结果确定）。
//    · `DateRangeFilter.contains` 两端闭区间 → `ts >= start AND ts <= end`；nil 端跳过该条件。
//    · searchText：用写入侧预计算的小写 `search_text` 列 + `instr(search_text, ?) > 0`，
//      needle 在 Swift 侧 `.lowercased()`（SQLite `lower()` 仅 ASCII）；空串跳过谓词。禁止 LIKE/lower()。
//    · `projectPath` 精确相等（非前缀）；`pathPrefix` nil/空串不过滤，否则 `instr(path, ?) = 1`。
//    · `EventQuery.minimumRisk` 比 INTEGER rank：`risk_rank >= Int(minimumRisk.rank)`。
//    · `destructiveOnly` → `is_destructive = 1`；`unacknowledgedOnly` → `is_acknowledged = 0`。
//    · 排序：时间列 DESC/ASC + `id DESC` tie-breaker（稳定分页游标）。
//    · hourly / daily 分桶在 SQL 侧 `GROUP BY` 完成（#75 裁定 9：窗口 ≤ 36 h 用小时桶，
//      > 36 h 用自然日桶），但桶口径**必须**与参照实现的
//      `Calendar.current.component(.hour:)` 逐格相同 ⇒ `strftime(格式, ts+纪元常数,
//      'unixepoch', 'localtime')`（裸 strftime 是 UTC 口径）；小时档的格式带日期
//      （`%Y-%m-%d %H`），否则滚动 24 小时窗口会把昨天和今天的同一小时并成一格。
//      分组键只是标签，桶起点由 `MIN(timestamp)` 带回，序号在 Swift 侧用 `Calendar` 数。
//      「今天」那一档仍是固定输出 0…23 共 24 条。
//      这条等式的另一侧由 `DashboardHourlyBucketParityTests` 逐格钉住。
//
//  两条硬约束：
//    1. 行还原**全部**走 B 的 `StoreRows` 映射器；映射失败的行直接跳过（compactMap），绝不伪造默认值。
//    2. 表名只取 `StoreSchema.Table` 编译期常量，所有**值**一律 `?` 绑定，零用户输入拼接。
//
//  注：`activeAgents()` 同属 `ObservatoryService`，但按 INTERFACE.md §5 的分工由 B 在
//  `ObservatoryStore.swift` 的「辅助查询」段实现；本文件刻意不重复声明（actor 同名成员重定义会编译失败）。
//

import Foundation
import AIObservatoryCore

/// 表名别名：全部引用 B 的编译期白名单常量，本文件不出现裸表名字符串。
private typealias Table = StoreSchema.Table

// MARK: - 分页 / 聚合查询

extension ObservatoryStore {

    /// 旧口径：只做"某一天"（`.today(date)` 闭区间），原样转交区间版。
    ///
    /// 保留它是为了满足 `ObservatoryService` 的既有契约成员（内存参照实现只实现这一条）；
    /// 新取数一律走 `dashboardStats(settledAt:within:)`。
    public func dashboardStats(for date: Date) async throws -> DashboardStats {
        try await dashboardStats(settledAt: date, within: .today(date))
    }

    /// **时段累计**：口径逐条对齐 `InMemoryObservatoryService` 的同名段（会话按 `started_at`、
    /// 事件 / 文件 / 命令 / 风险 / 采样按各自时间列，全部落在 `range` 的**闭区间**里，端点真进 SQL）；
    /// 只有 `activeAgentCount` 是**当前状态快照**（全表 `state = 'running'`，**不限窗口**，
    /// 与 InMemory 的 `s.agents` 同口径）——#75 起它被如实标成"快照"，界面也单独分组显示，
    /// 不再和时段累计并排同格混卖。SQL 失败时抛出底层 `SQLiteDatabase.Error`。
    ///
    /// 活动分桶按窗口宽度换档（裁定 9）：**≤ 36 h 小时桶，> 36 h 自然日桶**。
    ///
    /// 本体只负责「按段取数 → 组装」；每段一条私有助手，口径注释跟着自己那段走。
    public func dashboardStats(settledAt: Date, within range: DateRangeFilter) async throws -> DashboardStats {
        let span = Self.bucketSpan(for: range)
        let daySessions = try await dashboardDaySessions(in: range)
        let eventBucketRows = try await dashboardEventBucketRows(in: range, span: span)
        let files = try await dashboardFileKindCounts(in: range)
        let commands = try await dashboardCommandCounts(in: range)
        let risks = try await dashboardRiskCounts(in: range)
        let perf = try await dashboardPerformanceRollup(in: range, span: span)
        let activeAgentCount = try await dashboardActiveAgentCount()
        let buckets = Self.activityBuckets(
            eventRows: eventBucketRows,
            perfBuckets: perf.buckets,
            span: span,
            range: range,
            settledAt: settledAt
        )

        // 统计路径一律用注入的时刻结算（`duration(until:)`），不读墙钟：
        // 否则同一批数据在不同时刻查询会得到不同的仪表板数值。
        let totalActiveSeconds = daySessions.reduce(0.0) { $0 + $1.duration(until: settledAt) }
        let averageCPUPercent = perf.sampleCount > 0 ? perf.cpuSum / Double(perf.sampleCount) : 0
        let agentShares = Self.agentShares(for: daySessions, until: settledAt)

        return DashboardStats(
            date: settledAt,
            sessionCount: daySessions.count,
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

    /// 1) 会话：需要 startedAt / endedAt / kind 全字段，因此整行还原（duration 不做任何 clamp）。
    private func dashboardDaySessions(in range: DateRangeFilter) async throws -> [AgentSession] {
        var sessionFilter = SQLWhere()
        sessionFilter.addRange("started_at", range)
        let sessionRows = try await database.rows(
            "SELECT * FROM \(Table.sessions)\(sessionFilter.clause) ORDER BY started_at ASC, id ASC",
            arguments: sessionFilter.arguments
        )
        return sessionRows.compactMap { StoreRows.session(from: $0) }
    }

    /// 2) 事件分桶：**SQL 侧 `GROUP BY`** 出「桶 → 条数」，一行一个桶（小时档 ≤ 37 行、
    ///    日档最多 366 行），而不是"每条事件一行"。
    ///    改前这里拉今日每一条事件的 timestamp 回 Swift 逐行分桶（真库实测今日 4 209 条，
    ///    风暴跑时 8 840 条），而它们全部只是要加进 24 个格子——每一轮刷新付一次
    ///    「几千行解码 + 几千次 `Calendar.component`」的钱。
    ///
    ///    桶口径必须与参照实现同源，而参照实现（`InMemoryObservatoryService:152`、
    ///    `SwiftDataObservatoryStore+Queries.swift:101`）用的是 `Calendar.current`：
    ///    裸 `strftime('%H', …)` 是 **UTC** 口径，会把 08:00 的事件记进 0 点格子。
    ///    库里存的是 ReferenceDate 秒（`Row.date(_:)` 的注释说明这是刻意的：不做纪元换算
    ///    才能让 Date 逐位往返），所以 SQL 侧先加回 unix 纪元常数、再交给 `localtime`
    ///    修饰符按**系统 tzdata** 定桶——与 Foundation 读的是同一份时区数据。
    ///    `MIN(timestamp)` 把「这一桶的真实起点」带回来，桶序号在 Swift 侧用 `Calendar`
    ///    相对锚点数（见 `activityBuckets`），所以夏令时那 23 / 25 小时的一天不会错格，
    ///    也不违反 §5「禁止手写时间戳算术」。
    ///    按桶起点升序返回：窗口没有起点时，第一行就是锚点候选。
    private func dashboardEventBucketRows(in range: DateRangeFilter, span: ActivityBucketSpan) async throws
        -> [SQLiteRow] {
        var eventFilter = SQLWhere()
        eventFilter.addRange("timestamp", range)
        return try await database.rows(
            """
            SELECT \(Self.localBucketKey("timestamp", span: span)) AS bucket_key,
                   MIN(timestamp) AS bucket_min,
                   COUNT(*) AS event_count
              FROM \(Table.events)\(eventFilter.clause)
             GROUP BY bucket_key
             ORDER BY bucket_key ASC
            """,
            arguments: eventFilter.arguments
        )
    }

    /// 3) 文件变更三类计数：一次聚合查询（CASE WHEN 的参数在 WHERE 之前出现，故排在前面）。
    private func dashboardFileKindCounts(in range: DateRangeFilter) async throws
        -> (modified: Int, created: Int, deleted: Int) {
        var fileFilter = SQLWhere()
        fileFilter.addRange("timestamp", range)
        let fileRow = try await database.optionalRow(
            """
            SELECT COALESCE(SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), 0) AS modified_count,
                   COALESCE(SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), 0) AS created_count,
                   COALESCE(SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), 0) AS deleted_count
              FROM \(Table.fileChanges)\(fileFilter.clause)
            """,
            arguments: [
                .text(FileChangeKind.modified.rawValue),
                .text(FileChangeKind.created.rawValue),
                .text(FileChangeKind.deleted.rawValue),
            ] + fileFilter.arguments
        )
        return (
            modified: fileRow?.int("modified_count") ?? 0,
            created: fileRow?.int("created_count") ?? 0,
            deleted: fileRow?.int("deleted_count") ?? 0
        )
    }

    /// 4) 命令：总数 + 失败数（InMemory 按 startedAt 取窗口）。
    private func dashboardCommandCounts(in range: DateRangeFilter) async throws
        -> (executed: Int, failed: Int) {
        var commandFilter = SQLWhere()
        commandFilter.addRange("started_at", range)
        let commandRow = try await database.optionalRow(
            """
            SELECT COUNT(*) AS total_count,
                   COALESCE(SUM(CASE WHEN outcome = ? THEN 1 ELSE 0 END), 0) AS failed_count
              FROM \(Table.commands)\(commandFilter.clause)
            """,
            arguments: [.text(CommandOutcome.failure.rawValue)] + commandFilter.arguments
        )
        return (
            executed: commandRow?.int("total_count") ?? 0,
            failed: commandRow?.int("failed_count") ?? 0
        )
    }

    /// 5) 风险：总数 + 高风险数（level_rank >= RiskLevel.high.rank，等价于 InMemory 的 `level >= .high`）。
    private func dashboardRiskCounts(in range: DateRangeFilter) async throws -> (total: Int, high: Int) {
        var riskFilter = SQLWhere()
        riskFilter.addRange("timestamp", range)
        let riskRow = try await database.optionalRow(
            """
            SELECT COUNT(*) AS total_count,
                   COALESCE(SUM(CASE WHEN level_rank >= ? THEN 1 ELSE 0 END), 0) AS high_count
              FROM \(Table.riskEvents)\(riskFilter.clause)
            """,
            arguments: [.integer(Int64(RiskLevel.high.rank))] + riskFilter.arguments
        )
        return (
            total: riskRow?.int("total_count") ?? 0,
            high: riskRow?.int("high_count") ?? 0
        )
    }

    /// 会话级性能采样的结算结果：四个标量 + 按**桶起点**归并的 CPU 桶。
    private struct PerformanceRollup {
        var sampleCount = 0
        var cpuSum: Double = 0
        var peakCPUPercent: Double?
        var peakMemoryBytes: UInt64?
        var buckets: [(start: Date, cpuSum: Double, cpuSampleCount: Int)] = []
    }

    /// 6) 会话级性能采样：全局均值 / 峰值一条聚合，分桶的 cpu 均值一条 `GROUP BY`。
    ///    与事件那两条同理：改前两次都要把今日全部采样行拉回来（真库 2 166 条，
    ///    3 秒一拍一天就是数万条），只为算出四个标量加 24 个格子的和。
    ///
    ///    入账集合与逐行版本相同：改前的 guard「缺列的行不入账」在这里是空转的——
    ///    `timestamp / cpu_percent / memory_bytes` 三列在 schema 里都声明 NOT NULL
    ///    （`StoreSchema.swift:339/342/343`），不存在"取不到就不入账"的行。
    ///    峰值内存那条比较的是**有符号** Int64，而列值是 UInt64 的 bit-pattern；
    ///    两者只在 ≥ 2^63 字节（8 EiB）时才可能分开，实际内存远到不了。
    private func dashboardPerformanceRollup(in range: DateRangeFilter, span: ActivityBucketSpan) async throws
        -> PerformanceRollup {
        var perfFilter = SQLWhere()
        perfFilter.addRange("timestamp", range)
        // 主体锁、不是顺手加的过滤：`session_id IS NULL` 的采样没有归属对象（Agent 未归到会话时引擎就会落，
        // `ObservatoryEngine+Ingestion.swift:208`），放它进来这格会无声地从"被观测 Agent 的 CPU"变成"Agent + 无主样本"。
        perfFilter.add("session_id IS NOT NULL")
        let perfGlobalRow = try await database.optionalRow(
            """
            SELECT COUNT(*) AS sample_count,
                   SUM(cpu_percent) AS cpu_sum,
                   MAX(cpu_percent) AS peak_cpu,
                   MAX(memory_bytes) AS peak_memory
              FROM \(Table.perfSamples)\(perfFilter.clause)
            """,
            arguments: perfFilter.arguments
        )
        var rollup = PerformanceRollup(
            sampleCount: perfGlobalRow?.int("sample_count") ?? 0,
            cpuSum: perfGlobalRow?.double("cpu_sum") ?? 0,
            peakCPUPercent: perfGlobalRow?.double("peak_cpu"),
            peakMemoryBytes: perfGlobalRow?.uint64("peak_memory")
        )
        let perfBucketRows = try await database.rows(
            """
            SELECT \(Self.localBucketKey("timestamp", span: span)) AS bucket_key,
                   MIN(timestamp) AS bucket_min,
                   COUNT(*) AS sample_count,
                   SUM(cpu_percent) AS cpu_sum
              FROM \(Table.perfSamples)\(perfFilter.clause)
             GROUP BY bucket_key
             ORDER BY bucket_key ASC
            """,
            arguments: perfFilter.arguments
        )
        for row in perfBucketRows {
            guard let minSeconds = row.double("bucket_min"),
                  let count = row.int("sample_count")
            else { continue }   // 缺列的桶不入账（不伪造）
            rollup.buckets.append((
                start: Date(timeIntervalSinceReferenceDate: minSeconds),
                cpuSum: row.double("cpu_sum") ?? 0,
                cpuSampleCount: count
            ))
        }
        return rollup
    }

    /// 7) **当前状态快照**（不是时段累计）：全表 `state = 'running'` 的行数，与查询窗口无关
    ///    （与 InMemory 的 `s.agents` 口径一致）。#75 起界面把它单独分组显示，
    ///    也不许跟实时进程列表的长度取大——取消的就是那种 `max(累计, 快照)`。
    private func dashboardActiveAgentCount() async throws -> Int {
        try await database.scalarInt(
            "SELECT COUNT(*) FROM \(Table.agents) WHERE state = ?",
            arguments: [.text(AgentRunState.running.rawValue)]
        ) ?? 0
    }

    /// 8) 分桶合并：事件计数与 CPU 均值按**桶起点**对齐，再折成 `DashboardStats` 的桶序号。
    ///    两条 `GROUP BY` 各回一行一个桶 ⇒ 这里的循环次数与窗口内事件数无关。
    ///
    ///    口径（裁定 9）：`span` 决定粒度；锚点 = 窗口起点的整点 / 零点，窗口没有起点
    ///    （「全部」）时用第一个有数据的桶起点。桶序号 = 锚点到桶起点隔了几个粒度单位，
    ///    用 `Calendar.dateComponents` 数而不是秒差 ⇒ 夏令时那 23 / 25 小时的一天不错格。
    ///    补齐只补到窗口末（「今天」那一档因此仍是整 24 格，与改造前逐格相同），
    ///    并且**至少**覆盖到最后一个有数据的桶——落在右端点上的那一行不许被补零挤掉。
    private static func activityBuckets(
        eventRows: [SQLiteRow],
        perfBuckets: [(start: Date, cpuSum: Double, cpuSampleCount: Int)],
        span: ActivityBucketSpan,
        range: DateRangeFilter,
        settledAt: Date,
        calendar: Calendar = .current
    ) -> (points: [HourlyActivity], anchor: Date) {
        var eventBuckets: [(start: Date, count: Int)] = []
        eventBuckets.reserveCapacity(eventRows.count)
        for row in eventRows {
            guard let minSeconds = row.double("bucket_min"), let count = row.int("event_count") else { continue }
            eventBuckets.append((start: Date(timeIntervalSinceReferenceDate: minSeconds), count: count))
        }

        // 锚点只有一条，而且界面能自己复算（这才不需要在载荷里再塞一个 anchor）：
        //   · 日档 = 结算时刻所在自然日的零点 ⇒ 桶序号是**带符号的天偏移**（往回数是负的）；
        //   · 小时档 = 窗口起点落到整点 ⇒「今天」那一档锚点就是当日零点，
        //     序号恰好等于 0…23 的时，与改造前逐格相同。
        let anchor = span == .naturalDay
            ? calendar.startOfDay(for: settledAt)
            : floorBucketStart(range.start ?? settledAt, span: span, calendar: calendar)

        var merged: [Int: HourBucket] = [:]
        for bucket in eventBuckets {
            let index = bucketIndex(from: anchor, to: bucket.start, span: span, calendar: calendar)
            merged[index, default: HourBucket()].eventCount += bucket.count
        }
        for bucket in perfBuckets {
            let index = bucketIndex(from: anchor, to: bucket.start, span: span, calendar: calendar)
            var entry = merged[index] ?? HourBucket()
            entry.cpuSum = bucket.cpuSum                        // 与改前同：一个桶只有这一条聚合
            entry.cpuSampleCount = bucket.cpuSampleCount
            merged[index] = entry
        }

        let padded = paddedSlots(merged.keys, span: span, range: range, settledAt: settledAt,
                                 anchor: anchor, calendar: calendar)
        let points: [HourlyActivity] = padded.map { slot in
            let bucket = merged[slot] ?? HourBucket()
            let cpuAverage = bucket.cpuSampleCount > 0
                ? bucket.cpuSum / Double(bucket.cpuSampleCount)
                : 0
            return HourlyActivity(hour: slot, eventCount: bucket.eventCount, cpuAverage: cpuAverage)
        }
        return (points, anchor)
    }

    /// 补齐：把散落的有数据桶铺成一段**连续**的序号区间（空格子 eventCount = 0）。
    /// 边界只由窗口与数据决定，界面按同一条规则复算起点，所以载荷里不必再放一个锚点。
    ///   · 日档往两边都补：窗口起点那天 ⇄ 结算那天（「全部」没有起点 ⇒ 只补到最早有数据那天）；
    ///   · 小时档从锚点（= 窗口起点整点）补到窗口末；
    ///   · 至少覆盖最后一个有数据的格子——落在右端点上的那一行不许被补零挤掉；
    ///   · 最多 `maxActivityBuckets` 格：触到上限时少画格子、不伪造数字。
    private static func paddedSlots(
        _ populated: some Sequence<Int>,
        span: ActivityBucketSpan,
        range: DateRangeFilter,
        settledAt: Date,
        anchor: Date,
        calendar: Calendar
    ) -> [Int] {
        let present = Array(populated)
        let endLimit = paddingEnd(range: range, settledAt: settledAt, span: span, calendar: calendar)
        let lastSlot = max(present.max() ?? bucketIndex(from: anchor, to: endLimit, span: span, calendar: calendar),
                           bucketIndex(from: anchor, to: endLimit, span: span, calendar: calendar))
        let firstSlot: Int
        if span == .naturalDay {
            let windowSlot = range.start.map { bucketIndex(from: anchor, to: $0, span: span, calendar: calendar) }
            firstSlot = min(present.min() ?? lastSlot, windowSlot ?? lastSlot)
        } else {
            firstSlot = min(present.min() ?? 0, 0)
        }
        guard lastSlot >= firstSlot else { return [] }
        let count = min(lastSlot - firstSlot + 1, maxActivityBuckets)
        guard count > 0 else { return [] }
        return Array(firstSlot..<(firstSlot + count))
    }

    /// 补齐的右边界（三条口径，两侧后端逐字同一条）：
    ///   · 窗口没有终点（「全部」）→ 结算时刻；
    ///   · 终点**正好落在桶边界**上 → 退一格。`DateRangeFilter.today` 给的右端点是**次日零点**，
    ///     那是"开区间意义上的次日零点"（`contains` 写的是闭区间，但产品上「今天」= 当日 24 格），
    ///     不退这一格就会吐 0…24 共 25 格，把改造前"固定 0…23 共 24 条"的形状改掉
    ///     （`StoreParityTests` 的「今天」档整 24 格那条判据就是钉这个的）；
    ///   · 其余情况取 `min(终点, 结算时刻)`：结算之后的格子不画。
    private static func paddingEnd(
        range: DateRangeFilter,
        settledAt: Date,
        span: ActivityBucketSpan,
        calendar: Calendar
    ) -> Date {
        guard let end = range.end else { return settledAt }
        if floorBucketStart(end, span: span, calendar: calendar) == end {
            return calendarDate(byAdding: -1, to: end, span: span, calendar: calendar)
        }
        return min(end, settledAt)
    }

    /// 窗口宽度 → 桶粒度（裁定 9）：**≤ 36 h 小时桶，> 36 h 自然日桶**。
    /// 没有起点或没有终点的窗口（「全部」）一律日桶——否则小时桶的个数没有上界。
    private static func bucketSpan(for range: DateRangeFilter) -> ActivityBucketSpan {
        guard let start = range.start, let end = range.end else { return .naturalDay }
        return end.timeIntervalSince(start) <= 36 * 3600 ? .hourOfDay : .naturalDay
    }

    /// 桶序号：锚点到该起点之间隔了几个粒度单位（`Calendar` 数，不做秒除）。
    private static func bucketIndex(
        from anchor: Date,
        to start: Date,
        span: ActivityBucketSpan,
        calendar: Calendar = .current
    ) -> Int {
        let unit = span.calendarUnit
        let floored = floorBucketStart(start, span: span, calendar: calendar)
        // 带符号：日档的锚点是结算那天，往回数的格子必须是负数（界面用同一个数往回推日期）。
        return calendar.dateComponents([unit], from: anchor, to: floored).value(for: unit) ?? 0
    }

    /// 把时刻落到它所属的桶起点（小时档 = 整点，日档 = `startOfDay`）。
    private static func floorBucketStart(_ date: Date, span: ActivityBucketSpan, calendar: Calendar = .current) -> Date {
        span == .hourOfDay ? floorToHour(date, calendar: calendar) : calendar.startOfDay(for: date)
    }

    /// 锚点往后数 `steps` 个粒度单位（与 `bucketIndex` 互逆，补齐格子边界用）。
    private static func calendarDate(
        byAdding steps: Int,
        to anchor: Date,
        span: ActivityBucketSpan,
        calendar: Calendar = .current
    ) -> Date {
        calendar.date(byAdding: span.calendarUnit, value: steps, to: anchor) ?? anchor
    }

    /// `Calendar` 里「这一小时」的起点（§5 不许手写 `ts - ts % 3600`）。
    private static func floorToHour(_ date: Date, calendar: Calendar = .current) -> Date {
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour]
        return calendar.date(from: calendar.dateComponents(parts, from: date)) ?? date
    }

    /// 一次聚合最多回多少格：日档下等于一年，超过它要把保留期调到一年以上。
    /// 触到上限时**少画格子、不伪造数字**，口径写在这一句与卡片副标题里。
    private static let maxActivityBuckets = 366

    /// 按 Agent 种类聚合**窗口内**新建的会话：没有任何一场会话的种类不进表（与 InMemory 一致）。
    private static func agentShares(for sessions: [AgentSession], until date: Date) -> [AgentUsageShare] {
        AgentKind.allCases.compactMap { kind -> AgentUsageShare? in
            let matched = sessions.filter { $0.kind == kind }
            guard !matched.isEmpty else { return nil }
            return AgentUsageShare(
                kind: kind,
                sessionCount: matched.count,
                totalSeconds: matched.reduce(0) { $0 + $1.duration(until: date) }
            )
        }
    }

    /// 会话分页：`started_at` 闭区间 + kind/outcome 集合 + projectPath 精确 + search_text 子串。
    public func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        var filter = SQLWhere()
        filter.addRange("started_at", query.dateRange)
        filter.addIn("kind", query.agentKinds)
        filter.addIn("outcome", query.outcomes)
        filter.addEqual("project_path", query.projectPath)
        filter.addSearchText("search_text", query.searchText)
        let page = try await pagedRows(
            table: Table.sessions,
            filter: filter,
            orderColumn: "started_at",
            limit: query.limit,
            offset: query.offset,
            descending: query.sort.descending
        )
        return Page(
            items: page.rows.compactMap { StoreRows.session(from: $0) },
            totalCount: page.totalCount,
            offset: query.offset
        )
    }

    /// 单条会话；id 不存在或该行无法还原时返回 nil。
    public func session(id: UUID) async throws -> AgentSession? {
        guard let row = try await database.optionalRow(
            "SELECT * FROM \(Table.sessions) WHERE id = ? LIMIT 1",
            arguments: [.text(id.uuidString)]
        ) else { return nil }
        return StoreRows.session(from: row)
    }

    /// 事件分页：kinds/agentKinds/sessionID/projectPath + `risk_rank >= minimumRisk.rank` + search_text。
    public func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        var filter = SQLWhere()
        filter.addRange("timestamp", query.dateRange)
        filter.addIn("kind", query.kinds)
        filter.addIn("agent_kind", query.agentKinds)
        filter.addEqual("session_id", query.sessionID)
        filter.addEqual("project_path", query.projectPath)
        filter.add("risk_rank >= ?", [.integer(Int64(query.minimumRisk.rank))])
        filter.addSearchText("search_text", query.searchText)
        let page = try await pagedRows(
            table: Table.events,
            filter: filter,
            orderColumn: "timestamp",
            limit: query.limit,
            offset: query.offset,
            descending: query.sort.descending
        )
        return Page(
            items: page.rows.compactMap { StoreRows.event(from: $0) },
            totalCount: page.totalCount,
            offset: query.offset
        )
    }

    /// 文件变更分页：含 `pathPrefix`（`instr(path, ?) = 1`）；search_text 建列即 `path.lowercased()`。
    public func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        var filter = SQLWhere()
        filter.addRange("timestamp", query.dateRange)
        filter.addIn("kind", query.kinds)
        filter.addIn("agent_kind", query.agentKinds)
        filter.addEqual("session_id", query.sessionID)
        filter.addEqual("project_path", query.projectPath)
        filter.addPathPrefix("path", query.pathPrefix)
        filter.addSearchText("search_text", query.searchText)
        let page = try await pagedRows(
            table: Table.fileChanges,
            filter: filter,
            orderColumn: "timestamp",
            limit: query.limit,
            offset: query.offset,
            descending: query.sort.descending
        )
        return Page(
            items: page.rows.compactMap { StoreRows.fileChange(from: $0) },
            totalCount: page.totalCount,
            offset: query.offset
        )
    }

    /// 某次文件变更的 diff：走 `diffs.change_id` 唯一索引；无行或 `lines_json` 损坏返回 nil（不伪造）。
    public func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        guard let row = try await database.optionalRow(
            "SELECT * FROM \(Table.diffs) WHERE change_id = ? LIMIT 1",
            arguments: [.text(changeID.uuidString)]
        ) else { return nil }
        return StoreRows.diff(from: row)
    }

    /// 命令分页：agentKinds/sessionID/projectPath/outcomes + `destructiveOnly` → `is_destructive = 1` + search_text。
    public func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        var filter = SQLWhere()
        filter.addRange("started_at", query.dateRange)
        filter.addIn("agent_kind", query.agentKinds)
        filter.addEqual("session_id", query.sessionID)
        filter.addEqual("project_path", query.projectPath)
        filter.addIn("outcome", query.outcomes)
        if query.withNonZeroExitCode {
            filter.add("exit_code IS NOT NULL AND exit_code <> 0")
        }
        filter.addFlag("is_destructive", query.destructiveOnly, value: 1)
        filter.addSearchText("search_text", query.searchText)
        let page = try await pagedRows(
            table: Table.commands,
            filter: filter,
            orderColumn: "started_at",
            limit: query.limit,
            offset: query.offset,
            descending: query.sort.descending
        )
        return Page(
            items: page.rows.compactMap { StoreRows.command(from: $0) },
            totalCount: page.totalCount,
            offset: query.offset
        )
    }

    /// 某会话的性能采样：无分页、时间升序；`session_id` 为 NULL 的行永不匹配（与 InMemory 的 `==` 一致）。
    ///
    /// ⚠️ 这条会把该会话在**整个保留期内**的采样一次捞回（`perf_samples` 每 tick 一行，
    /// 30 天 = 86 万行量级），而唯一的界面消费者只取最后 1 000 条 ⇒ 用下面带 `limit` 的那条
    /// （#38）。本条保留是因为**导出全量**确实要每一行；契约上已写明
    /// 「重消费者必须走 `limit:` 变体」（ICR-0007 第 4 条），所以界面不再走这条。
    public func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        let rows = try await database.rows(
            "SELECT * FROM \(Table.perfSamples) WHERE session_id = ? ORDER BY timestamp ASC, id ASC",
            arguments: [.text(sessionID.uuidString)]
        )
        return rows.compactMap { StoreRows.performanceSample(from: $0) }
    }

    /// 某会话**最新 `limit` 条**性能采样，返回仍按时间升序（#38）。
    ///
    /// 口径与 `performanceSamples(sessionID:)` 逐字相同（同一谓词、同一序），只是先
    /// `DESC LIMIT` 取尾部再翻回来 ⇒ 两者在样本数不超过 `limit` 时结果完全一致。
    /// `limit <= 0` 返回空数组：**不**把非正数交给 SQL——SQLite 的 `LIMIT -1` 语义是"不设限"，
    /// 那正好把这条要修的"悄悄退化成全表"重新敞开。
    public func performanceSamples(sessionID: UUID, limit: Int) async throws -> [PerformanceSample] {
        guard limit > 0 else { return [] }
        let rows = try await database.rows(
            """
            SELECT * FROM \(Table.perfSamples) WHERE session_id = ?
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
            """,
            arguments: [.text(sessionID.uuidString), .integer(Int64(limit))]
        )
        return rows.compactMap { StoreRows.performanceSample(from: $0) }.reversed()
    }

    /// 整机性能采样：`timestamp >= date`（InMemory 只有下界），时间升序，无分页。
    public func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        let rows = try await database.rows(
            "SELECT * FROM \(Table.systemPerf) WHERE timestamp >= ? ORDER BY timestamp ASC, id ASC",
            arguments: [.real(date.timeIntervalSinceReferenceDate)]
        )
        return rows.compactMap { StoreRows.systemPerformanceSample(from: $0) }
    }

    /// 保留期内**最新 `limit` 条**整机采样，返回按时间升序（#38）。
    ///
    /// 与 `systemPerformance(since:)` 同谓词、同序，只是 `DESC LIMIT` 取尾再翻回；
    /// `limit <= 0` 返回空数组（理由见 `performanceSamples(sessionID:limit:)`）。
    /// 无样本带 NULL `session_id` 的问题：这条本来就不按会话筛。
    public func systemPerformance(since date: Date, limit: Int) async throws -> [SystemPerformanceSample] {
        guard limit > 0 else { return [] }
        let rows = try await database.rows(
            """
            SELECT * FROM \(Table.systemPerf) WHERE timestamp >= ?
            ORDER BY timestamp DESC, id DESC
            LIMIT ?
            """,
            arguments: [.real(date.timeIntervalSinceReferenceDate), .integer(Int64(limit))]
        )
        return rows.compactMap { StoreRows.systemPerformanceSample(from: $0) }.reversed()
    }

    /// 风险事件分页：levels/categories/agentKinds 用 IN + `unacknowledgedOnly` → `is_acknowledged = 0`。
    ///
    /// `projectPath` 走的是**归属边**而不是本表列：`risk_events` 没有 `project_path`
    /// （风险行自己不挂项目），口径 = 「风险经 `session_id` 落到会话、会话经 `project_path`
    /// 落到项目」，与 `recomputeSessionRiskCount`（`sessions.risk_event_count` 的唯一写入口）
    /// 同一条边。于是 `session_id` 为 NULL 的风险行在任何项目条件下都不匹配（`IN` 与 `=` 同规则）。
    /// 仍是**一条** SQL：子查询在同一句里，不为此多发一次取数。
    public func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        var filter = SQLWhere()
        filter.addRange("timestamp", query.dateRange)
        filter.addIn("level", query.levels)
        filter.addIn("category", query.categories)
        filter.addIn("agent_kind", query.agentKinds)
        filter.addEqual("session_id", query.sessionID)
        if let projectPath = query.projectPath {
            filter.add(
                "session_id IN (SELECT id FROM \(Table.sessions) WHERE project_path = ?)",
                [.text(projectPath)]
            )
        }
        filter.addFlag("is_acknowledged", query.unacknowledgedOnly, value: 0)
        filter.addSearchText("search_text", query.searchText)
        let page = try await pagedRows(
            table: Table.riskEvents,
            filter: filter,
            orderColumn: "timestamp",
            limit: query.limit,
            offset: query.offset,
            descending: query.sort.descending
        )
        return Page(
            items: page.rows.compactMap { StoreRows.riskEvent(from: $0) },
            totalCount: page.totalCount,
            offset: query.offset
        )
    }

    /// 全部项目：`last_seen_at DESC`，tie-break `id ASC`（保证多次调用顺序一致）。
    public func projects() async throws -> [ProjectActivity] {
        let rows = try await database.rows(
            "SELECT * FROM \(Table.projects) ORDER BY last_seen_at DESC, id ASC"
        )
        return rows.compactMap { StoreRows.project(from: $0) }
    }

    /// 指定项目在区间内的活动：先按 path 精确取项目行（无则 nil），再**只重算**
    /// `fileChangeCount` / `commandCount` / `codeGrowthLines` / `codeShrinkLines` 四个字段，
    /// 其余字段沿用库里的行值（与 InMemory 完全一致；NULL 的 SUM 记 0）。
    public func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        guard let row = try await database.optionalRow(
            "SELECT * FROM \(Table.projects) WHERE path = ? LIMIT 1",
            arguments: [.text(path)]
        ), var project = StoreRows.project(from: row) else { return nil }

        var changeFilter = SQLWhere()
        changeFilter.addEqual("project_path", path)
        changeFilter.addRange("timestamp", dateRange)
        let changeRow = try await database.optionalRow(
            """
            SELECT COUNT(*) AS change_count,
                   COALESCE(SUM(lines_added), 0) AS growth_lines,
                   COALESCE(SUM(lines_removed), 0) AS shrink_lines
              FROM \(Table.fileChanges)\(changeFilter.clause)
            """,
            arguments: changeFilter.arguments
        )
        project.fileChangeCount = changeRow?.int("change_count") ?? 0
        project.codeGrowthLines = changeRow?.int("growth_lines") ?? 0
        project.codeShrinkLines = changeRow?.int("shrink_lines") ?? 0

        var commandFilter = SQLWhere()
        commandFilter.addEqual("project_path", path)
        commandFilter.addRange("started_at", dateRange)
        project.commandCount = try await database.scalarInt(
            "SELECT COUNT(*) FROM \(Table.commands)\(commandFilter.clause)",
            arguments: commandFilter.arguments
        ) ?? 0

        return project
    }

    // MARK: - 分页执行（两条 SQL）

    /// 用同一个 WHERE 跑两条 SQL：过滤后总数 + 排序分页后的行。
    ///
    /// `ORDER BY <时间列> DESC|ASC, id DESC` 的 tie-breaker 不改变 InMemory 对照结果
    /// （其数据时间戳互不相同），但让 offset 翻页变成稳定游标。
    /// 负数 limit/offset 在 InMemory 侧会让 `prefix`/`dropFirst` 崩溃，这里收敛为 0。
    private func pagedRows(
        table: String,
        filter: SQLWhere,
        orderColumn: String,
        limit: Int,
        offset: Int,
        descending: Bool
    ) async throws -> (rows: [SQLiteRow], totalCount: Int) {
        let totalCount = try await database.scalarInt(
            "SELECT COUNT(*) FROM \(table)\(filter.clause)",
            arguments: filter.arguments
        ) ?? 0
        let rows = try await database.rows(
            """
            SELECT * FROM \(table)\(filter.clause)
            ORDER BY \(orderColumn) \(descending ? "DESC" : "ASC"), id DESC
            LIMIT ? OFFSET ?
            """,
            arguments: filter.arguments + [
                .integer(Int64(max(limit, 0))),
                .integer(Int64(max(offset, 0))),
            ]
        )
        return (rows, totalCount)
    }
}

// MARK: - 内部工具

/// hourly 分桶累加器（事件计数 + CPU 求和/求均值）。
private struct HourBucket {
    var eventCount = 0
    var cpuSum: Double = 0
    var cpuSampleCount = 0
}

private extension ObservatoryStore {

    /// ReferenceDate（2001-01-01 00:00:00 UTC）在 unix 纪元里的秒数。
    /// 库里存的是 ReferenceDate 秒，SQL 的日期函数按 unix 秒解释（`'unixepoch'`），差的就是这个常数。
    static let referenceDateUnixSeconds: Double = 978_307_200

    /// 「这条记录属于当地时间的哪一小时 / 哪一天」的 SQL 表达式（#75 裁定 9 的两档）。
    ///
    /// `localtime` 让 SQLite 走系统 tzdata（与 `Calendar.current` 同一份数据），
    /// 因此带夏令时/半小时偏移的时区也和参照实现同格子；不写 `localtime` 就是 UTC 口径。
    /// 小时档必须带**日期**一起分组：只取 `%H` 会把「昨天 15 点」和「今天 15 点」并成一格，
    /// 而「最近 24 小时」这类滚动窗口天天同时跨两个日历日——那正是读数与标签不符。
    /// 键本身只是分组标签，真实起点由同一条查询的 `MIN(timestamp)` 给出，
    /// 序号在 Swift 侧用 `Calendar` 数（见 `activityBuckets`）。
    /// 常数按编译期字面量拼进 SQL 而不是绑定：它出现在 SELECT 列表里，会排在 `SQLWhere`
    /// 的 WHERE 参数**之前**，绑进去就得手工维护绑定顺序，而拼的是一个编译期常量、不是值。
    private static func localBucketKey(_ column: String, span: ActivityBucketSpan) -> String {
        let format = span == .hourOfDay ? "%Y-%m-%d %H" : "%Y-%m-%d"
        return "strftime('\(format)', \(column) + \(referenceDateUnixSeconds), 'unixepoch', 'localtime')"
    }
}

/// WHERE 子句累加器：文本片段只含列名与运算符，**所有值**都作为 `SQLiteValue` 参数按顺序绑定。
private struct SQLWhere {

    private var conditions: [String] = []
    private var boundArguments: [SQLiteValue] = []

    /// 与 `clause` 中 `?` 出现顺序一一对应的绑定参数。
    var arguments: [SQLiteValue] { boundArguments }

    /// 拼好的 ` WHERE a AND b …` 片段；无条件下返回空串。
    var clause: String {
        conditions.isEmpty ? "" : " WHERE " + conditions.joined(separator: " AND ")
    }

    /// 追加一条布尔条件及其参数（参数个数须与 `?` 个数一致）。
    mutating func add(_ sql: String, _ args: [SQLiteValue] = []) {
        conditions.append(sql)
        boundArguments.append(contentsOf: args)
    }

    /// 日期闭区间：`col >= start AND col <= end`；nil 端跳过（对齐 `DateRangeFilter.contains`）。
    mutating func addRange(_ column: String, _ range: DateRangeFilter) {
        if let start = range.start {
            add("\(column) >= ?", [.real(start.timeIntervalSinceReferenceDate)])
        }
        if let end = range.end {
            add("\(column) <= ?", [.real(end.timeIntervalSinceReferenceDate)])
        }
    }

    /// 集合过滤：空集合 = 不过滤；非空 = `col IN (?,?,…)`，参数按 rawValue 升序保证确定性。
    mutating func addIn<Value: RawRepresentable & Hashable>(_ column: String, _ values: Set<Value>)
    where Value.RawValue == String {
        guard !values.isEmpty else { return }
        let sorted = values.sorted { $0.rawValue < $1.rawValue }
        let placeholders = Array(repeating: "?", count: sorted.count).joined(separator: ", ")
        add("\(column) IN (\(placeholders))", sorted.map { .text($0.rawValue) })
    }

    /// 可选字符串精确相等（nil = 不过滤）。列值为 NULL 的行被 `=` 天然排除，与 InMemory 的 `!=` 判定一致。
    mutating func addEqual(_ column: String, _ value: String?) {
        guard let value else { return }
        add("\(column) = ?", [.text(value)])
    }

    /// 可选 UUID 精确相等（以写入侧的 `uuidString` 文本比较；nil = 不过滤）。
    mutating func addEqual(_ column: String, _ value: UUID?) {
        guard let value else { return }
        add("\(column) = ?", [.text(value.uuidString)])
    }

    /// 0/1 标志位条件：仅当 `enabled` 为真时追加 `col = value`（如 `is_destructive = 1`）。
    mutating func addFlag(_ column: String, _ enabled: Bool, value: Int) {
        guard enabled else { return }
        add("\(column) = ?", [.integer(Int64(value))])
    }

    /// 路径前缀：nil 或空串 = 不过滤；否则 `instr(col, ?) = 1`（等价于 Swift `hasPrefix`）。
    mutating func addPathPrefix(_ column: String, _ prefix: String?) {
        guard let prefix, !prefix.isEmpty else { return }
        add("instr(\(column), ?) = 1", [.text(prefix)])
    }

    /// 搜索文本：空串 = 不过滤；否则 `instr(search_text, ?) > 0`，needle 在 Swift 侧小写化。
    mutating func addSearchText(_ column: String, _ text: String) {
        guard !text.isEmpty else { return }
        add("instr(\(column), ?) > 0", [.text(text.lowercased())])
    }
}
