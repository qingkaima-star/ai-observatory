//
//  SwiftDataObservatoryStore+PerfRiskProjects.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-Engine（由 SwiftDataObservatoryStore+Queries.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import SwiftData
import AIObservatoryCore

extension SwiftDataObservatoryStore {

    /// 某会话的性能采样：无分页，`timestamp ASC, id ASC`（**id 是升序**，
    /// 对齐 SQL 的 `ORDER BY timestamp ASC, id ASC`，与分页查询的 `id DESC` 不同）。
    ///
    /// `sessionID` 为 NULL 的行永不匹配：谓词里的 `String? == String` 与 SQL 的
    /// `session_id = ?` 同样把 NULL 排除在外。
    public func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        let text = sessionID.uuidString
        let records = try context.fetch(FetchDescriptor<SDPerformanceSample>(
            predicate: #Predicate<SDPerformanceSample> { $0.sessionID == text },
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.rowID)]
        ))
        return records.compactMap { $0.domainValue() }
    }

    /// 某会话**最新 `limit` 条**采样，返回按时间升序（#38；与 SQLite 侧同一条 DESC-then-reverse 口径）。
    public func performanceSamples(sessionID: UUID, limit: Int) async throws -> [PerformanceSample] {
        guard limit > 0 else { return [] }
        let text = sessionID.uuidString
        var descriptor = FetchDescriptor<SDPerformanceSample>(
            predicate: #Predicate<SDPerformanceSample> { $0.sessionID == text },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse), SortDescriptor(\.rowID, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let records = try context.fetch(descriptor)
        return records.compactMap { $0.domainValue() }.reversed()
    }

    /// 整机性能采样：`timestamp >= date`（基准实现只有下界，没有上界），
    /// `timestamp ASC, id ASC`，无分页。
    ///
    /// ⚠️ 整段捞回（#38）：这条是冻结契约成员，签名不能改；带上限的读法见下面
    /// `systemPerformance(since:limit:)`。
    public func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        let records = try context.fetch(FetchDescriptor<SDSystemPerformanceSample>(
            predicate: #Predicate<SDSystemPerformanceSample> { $0.timestamp >= date },
            sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.rowID)]
        ))
        return records.compactMap { $0.domainValue() }
    }

    /// 保留期内**最新 `limit` 条**整机采样，返回按时间升序（#38，与 SQLite 侧同名方法同口径）。
    ///
    /// `limit <= 0` 返回空数组，不把非正数交给 `FetchDescriptor(limit:)`——那层的
    /// 「0 = 不限制」语义与 SQLite 的 `LIMIT -1` 一样，都会把要修的退化重新敞开。
    public func systemPerformance(since date: Date, limit: Int) async throws -> [SystemPerformanceSample] {
        guard limit > 0 else { return [] }
        // `FetchDescriptor` 的构造参数里没有 limit（SDK 里 `fetchLimit` 是可写属性），
        // 所以先建描述符再设上限——别以为少写了一行就退化成全表，`fetchLimit` 为 nil 才是不设限。
        var descriptor = FetchDescriptor<SDSystemPerformanceSample>(
            predicate: #Predicate<SDSystemPerformanceSample> { $0.timestamp >= date },
            sortBy: [SortDescriptor(\.timestamp, order: .reverse), SortDescriptor(\.rowID, order: .reverse)]
        )
        descriptor.fetchLimit = limit
        let records = try context.fetch(descriptor)
        return records.compactMap { $0.domainValue() }.reversed()
    }

    /// 风险事件分页：`timestamp` 闭区间 + `levels` / `categories` / `agentKinds` 集合
    /// + `sessionID` 精确相等 + `projectPath`（归属边：风险 → 会话 → 项目）
    /// + `unacknowledgedOnly` → `isAcknowledged == false`（仅当开关为真）+ 字面子串搜索。
    ///
    /// 排序 = `timestamp`（方向随 `query.sort`）+ `id` 恒降序。
    ///
    /// `projectPath` 这一维与 SQLite 侧同一条口径：`SDRiskEvent` 没有项目列（风险行自己
    /// 不挂项目），于是「哪些风险属于这个项目」= 「这些风险挂的那条会话属于这个项目」，
    /// 用的就是 `SDSession.projectPath` 那一条既有边（`sessions.riskEventCount` 的派生
    /// 走的是同一条）。`sessionID` 为 nil 的风险行在任何项目条件下都不匹配。
    /// 那条会话 id 集合**只在带了项目条件时**才取（不在每 tick 的默认路径上），
    /// 且它属于本条查询的一部分：`riskEvents(matching:)` 仍然只被界面调用一次。
    public func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        let lower = query.dateRange.start ?? .distantPast
        let upper = query.dateRange.end ?? .distantFuture
        let levels = sortedRawValues(query.levels)
        let categories = sortedRawValues(query.categories)
        let agentKinds = sortedRawValues(query.agentKinds)
        let unacknowledgedOnly = query.unacknowledgedOnly
        let needle = query.searchText.lowercased()
        // 「这次查询带了项目条件」单独记一份：不能拿「集合为空」当判据——
        // 一个**还没有任何会话**的项目，它的会话集合就是空的，那筛出来的应当是零条风险，
        // 而不是「条件没生效、整表照给」。
        let projectScoped = query.projectPath != nil
        var projectSessionIDs: Set<String> = []
        if let projectPath = query.projectPath {
            projectSessionIDs = Set(try context.fetch(FetchDescriptor<SDSession>(
                predicate: #Predicate<SDSession> { session in session.projectPath == projectPath }
            )).map(\.rowID))
        }
        let sort: [SortDescriptor<SDRiskEvent>] = [
            SortDescriptor(\.timestamp, order: query.sort.descending ? .reverse : .forward),
            SortDescriptor(\.rowID, order: .reverse),
        ]
        let map: (SDRiskEvent) -> RiskEvent? = { row in row.domainValue() }
        let passes: (RiskEvent) -> Bool = {
            Self.matches($0, query: query, projectSessionIDs: projectSessionIDs)
        }

        if let sessionText = query.sessionID?.uuidString {
            // 臂 S：下推 时间 + 会话 + levels + categories；
            // 留给 Swift：agentKinds、unacknowledgedOnly、searchText、projectPath。
            let filter = #Predicate<SDRiskEvent> { risk in
                risk.timestamp >= lower
                    && risk.timestamp <= upper
                    && risk.sessionID == sessionText
                    && (levels.isEmpty || levels.contains(risk.level))
                    && (categories.isEmpty || categories.contains(risk.category))
            }
            return try page(
                FetchDescriptor<SDRiskEvent>(predicate: filter, sortBy: sort),
                limit: query.limit, offset: query.offset,
                complete: needle.isEmpty && agentKinds.isEmpty && !unacknowledgedOnly && !projectScoped,
                map: map, passes: passes
            )
        }
        // 臂 G：`unacknowledgedOnly` 是界面默认（待办风险列表），优先占位；
        // 留给 Swift：agentKinds、searchText、projectPath。（三个集合 `IN` 同时下推会越过谓词上限。）
        let filter = #Predicate<SDRiskEvent> { risk in
            risk.timestamp >= lower
                && risk.timestamp <= upper
                && (levels.isEmpty || levels.contains(risk.level))
                && (categories.isEmpty || categories.contains(risk.category))
                && (!unacknowledgedOnly || risk.isAcknowledged == false)
                // ↑ 布尔开关的哨兵**必须**写成 `!flag || 列 == 值`。写成 `flag || 列 == 值`
                //   会在 flag 为假时退化成「只取列 == 值 的行」，即过滤条件反过来——
                //   对照测试抓到过这个错（已确认的风险整条消失）。
        }
        return try page(
            FetchDescriptor<SDRiskEvent>(predicate: filter, sortBy: sort),
            limit: query.limit, offset: query.offset,
            complete: needle.isEmpty && agentKinds.isEmpty && !projectScoped,
            map: map, passes: passes
        )
    }

    /// 全部项目：`lastSeenAt DESC`，tie-break `id ASC`（id 就是 path 字符串）；
    /// 无分页，方向逐条对齐 SQL，保证多次调用顺序一致。
    public func projects() async throws -> [ProjectActivity] {
        let records = try context.fetch(FetchDescriptor<SDProject>(
            sortBy: [SortDescriptor(\.lastSeenAt, order: .reverse), SortDescriptor(\.rowID)]
        ))
        return records.compactMap { $0.domainValue() }
    }

    /// 指定项目在区间内的活动：先按 `path` **精确**取项目行（无则 nil），然后**只重算**
    /// `fileChangeCount` / `commandCount` / `codeGrowthLines` / `codeShrinkLines` 四个字段，
    /// 其余字段（name / sessionCount / riskEventCount / agentContributions / hotFiles /
    /// firstSeenAt / lastSeenAt）沿用库里的行值——与基准实现完全一致。
    ///
    /// 两个 lines 求和在 Swift 侧累加：SwiftData 没有聚合，而
    /// `propertiesToFetch: .init(sumOf:)` 未在本 SDK 的能力测试里验证过，用它就是在赌
    /// 编译与下推都成立。惰性批量扫描语义相同，且无行时和为 0（== SQL 的 `COALESCE(SUM(…), 0)`）。
    public func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        let pathText = path
        guard let record = try firstRow(of: SDProject.self, where: #Predicate<SDProject> {
            $0.path == pathText
        }), var project = record.domainValue() else { return nil }

        let lower = dateRange.start ?? .distantPast
        let upper = dateRange.end ?? .distantFuture

        let changeFilter = #Predicate<SDFileChange> { change in
            change.projectPath == pathText
                && change.timestamp >= lower
                && change.timestamp <= upper
        }
        project.fileChangeCount = try context.fetchCount(FetchDescriptor<SDFileChange>(predicate: changeFilter))

        var growthLines = 0
        var shrinkLines = 0
        // SQL 侧是 `SUM(lines_added)`；SwiftData 没有可用的聚合谓词，改为分块累加
        // （排序只为游标稳定）。溢出风险与 SQLite 的 Int64 列同级：行数 × 行增量远小于 Int.max。
        try forEachChunk(
            FetchDescriptor<SDFileChange>(
                predicate: changeFilter,
                sortBy: [SortDescriptor(\.timestamp), SortDescriptor(\.rowID)]
            )
        ) { change in
            growthLines += change.linesAdded
            shrinkLines += change.linesRemoved
        }
        project.codeGrowthLines = growthLines
        project.codeShrinkLines = shrinkLines

        project.commandCount = try context.fetchCount(FetchDescriptor<SDCommand>(
            predicate: #Predicate<SDCommand> { command in
                command.projectPath == pathText
                    && command.startedAt >= lower
                    && command.startedAt <= upper
            }
        ))
        return project
    }


}
