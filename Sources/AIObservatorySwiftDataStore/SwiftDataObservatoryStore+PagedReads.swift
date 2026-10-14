//
//  SwiftDataObservatoryStore+PagedReads.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-Engine（由 SwiftDataObservatoryStore+Queries.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import SwiftData
import AIObservatoryCore

extension SwiftDataObservatoryStore {

    /// 会话分页：`startedAt` 闭区间 + `agentKinds` / `outcomes` 集合（空集合不过滤）
    /// + `projectPath` 精确相等（nil 不过滤）+ `searchText` 对预计算小写列取字面子串。
    ///
    /// 排序 = `startedAt`（方向随 `query.sort`）+ `id` 恒降序；`totalCount` 是过滤后、
    /// 分页前的总数，`offset` 原样回传。
    public func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        let lower = query.dateRange.start ?? .distantPast
        let upper = query.dateRange.end ?? .distantFuture
        let kinds = sortedRawValues(query.agentKinds)
        let outcomes = sortedRawValues(query.outcomes)
        let projectPath = query.projectPath ?? ""
        let needle = query.searchText.lowercased()
        let filter = #Predicate<SDSession> { session in
            session.startedAt >= lower
                && session.startedAt <= upper
                && (kinds.isEmpty || kinds.contains(session.kind))
                && (outcomes.isEmpty || outcomes.contains(session.outcome))
                && (projectPath.isEmpty || session.projectPath == projectPath)
                && (needle.isEmpty || session.searchText.contains(needle))
        }
        let descriptor = FetchDescriptor<SDSession>(
            predicate: filter,
            sortBy: [
                SortDescriptor(\.startedAt, order: query.sort.descending ? .reverse : .forward),
                SortDescriptor(\.rowID, order: .reverse),
            ]
        )
        // 显式写出 `map` 的入/出参类型：泛型 `Element` 由闭包签名钉死，而不是靠返回类型倒推。
        // 会话 6 个维度刚好装进一条谓词（时间区间占 2 个子句），因此恒为存储层分页。
        return try page(
            descriptor,
            limit: query.limit,
            offset: query.offset,
            complete: true,
            map: { (row: SDSession) -> AgentSession? in row.domainValue() }
        )
    }

    /// 单条会话；id 不存在或该行无法还原为领域模型时返回 nil（不伪造）。
    public func session(id: UUID) async throws -> AgentSession? {
        let text = id.uuidString
        guard let record = try firstRow(of: SDSession.self, where: #Predicate<SDSession> {
            $0.rowID == text
        }) else { return nil }
        return record.domainValue()
    }

    /// 事件分页：`timestamp` 闭区间 + `kinds` / `agentKinds` 集合 + `sessionID` /
    /// `projectPath` 精确相等 + `riskRank >= Int(query.minimumRisk.rank)` + 字面子串搜索。
    ///
    /// 风险阈值比的是写入侧预计算的 INTEGER 列（谓词里调不动 `RiskLevel.rank`）。
    /// 排序 = `timestamp`（方向随 `query.sort`）+ `id` 恒降序。
    ///
    /// **为什么分两条臂**：`#Predicate` 的展开是一条 `&&` 表达式，实测**超过 6 个子句
    /// 就编译不出来**（"unable to type-check this expression in reasonable time"，
    /// 见 WS-SwiftData 简报里的探针结论）。事件有 7 个维度（时间区间占 2 个子句），
    /// 一条谓词装不下，于是按「本次查询实际用了哪些维度」挑一条能装下的臂，
    /// 剩下 1–2 个维度交给 Swift 侧细筛（语义照抄冻结基准，一条不差）。
    public func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        let lower = query.dateRange.start ?? .distantPast
        let upper = query.dateRange.end ?? .distantFuture
        let kinds = sortedRawValues(query.kinds)
        let agentKinds = sortedRawValues(query.agentKinds)
        let projectPath = query.projectPath ?? ""
        let minimumRiskRank = Int(query.minimumRisk.rank)
        let needle = query.searchText.lowercased()
        let sort: [SortDescriptor<SDEvent>] = [
            SortDescriptor(\.timestamp, order: query.sort.descending ? .reverse : .forward),
            SortDescriptor(\.rowID, order: .reverse),
        ]
        let map: (SDEvent) -> TimelineEvent? = { row in row.domainValue() }
        let passes: (TimelineEvent) -> Bool = { Self.matches($0, query: query) }

        if let sessionText = query.sessionID?.uuidString {
            // 臂 S（看单个会话的时间线）：下推 时间 + 会话 + 两个集合 + 风险；
            // 留给 Swift 侧：projectPath（同会话内几乎同项目）、searchText。
            let filter = #Predicate<SDEvent> { event in
                event.timestamp >= lower
                    && event.timestamp <= upper
                    && event.sessionID == sessionText
                    && (kinds.isEmpty || kinds.contains(event.kind))
                    && (agentKinds.isEmpty || agentKinds.contains(event.agentKind))
                    && event.riskRank >= minimumRiskRank
            }
            return try page(
                FetchDescriptor<SDEvent>(predicate: filter, sortBy: sort),
                limit: query.limit, offset: query.offset,
                complete: needle.isEmpty && projectPath.isEmpty,
                map: map, passes: passes
            )
        }
        // 臂 G（全局时间线）：下推 时间 + 两个集合 + 风险 + 搜索；留给 Swift 侧：projectPath。
        let filter = #Predicate<SDEvent> { event in
            event.timestamp >= lower
                && event.timestamp <= upper
                && (kinds.isEmpty || kinds.contains(event.kind))
                && (agentKinds.isEmpty || agentKinds.contains(event.agentKind))
                && event.riskRank >= minimumRiskRank
                && (needle.isEmpty || event.searchText.contains(needle))
        }
        return try page(
            FetchDescriptor<SDEvent>(predicate: filter, sortBy: sort),
            limit: query.limit, offset: query.offset,
            complete: projectPath.isEmpty,
            map: map, passes: passes
        )
    }

    /// 文件变更分页：`timestamp` 闭区间 + `kinds` / `agentKinds` 集合 + `sessionID` /
    /// `projectPath` 精确相等 + `pathPrefix` 前缀（nil 或空串不过滤）+ 字面子串搜索
    /// （该表的 haystack 就是 `path.lowercased()`）。
    ///
    /// 排序 = `timestamp`（方向随 `query.sort`）+ `id` 恒降序。
    /// 7 个维度装不进一条谓词（上限 6 个子句），按臂下推，其余交给 Swift 细筛。
    public func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        let lower = query.dateRange.start ?? .distantPast
        let upper = query.dateRange.end ?? .distantFuture
        let kinds = sortedRawValues(query.kinds)
        let agentKinds = sortedRawValues(query.agentKinds)
        let projectPath = query.projectPath ?? ""
        let prefix = query.pathPrefix ?? ""
        let needle = query.searchText.lowercased()
        let sort: [SortDescriptor<SDFileChange>] = [
            SortDescriptor(\.timestamp, order: query.sort.descending ? .reverse : .forward),
            SortDescriptor(\.rowID, order: .reverse),
        ]
        let map: (SDFileChange) -> FileChange? = { row in row.domainValue() }
        let passes: (FileChange) -> Bool = { Self.matches($0, query: query) }

        if let sessionText = query.sessionID?.uuidString {
            // 臂 S：下推 时间 + 会话 + 两个集合 + 路径前缀；留给 Swift：projectPath、searchText。
            let filter = #Predicate<SDFileChange> { change in
                change.timestamp >= lower
                    && change.timestamp <= upper
                    && change.sessionID == sessionText
                    && (kinds.isEmpty || kinds.contains(change.kind))
                    && (agentKinds.isEmpty || agentKinds.contains(change.agentKind))
                    && (prefix.isEmpty || change.path.starts(with: prefix))
            }
            return try page(
                FetchDescriptor<SDFileChange>(predicate: filter, sortBy: sort),
                limit: query.limit, offset: query.offset,
                complete: needle.isEmpty && projectPath.isEmpty,
                map: map, passes: passes
            )
        }
        // 臂 G：下推 时间 + 两个集合 + 路径前缀 + 搜索；留给 Swift：projectPath。
        let filter = #Predicate<SDFileChange> { change in
            change.timestamp >= lower
                && change.timestamp <= upper
                && (kinds.isEmpty || kinds.contains(change.kind))
                && (agentKinds.isEmpty || agentKinds.contains(change.agentKind))
                && (prefix.isEmpty || change.path.starts(with: prefix))
                && (needle.isEmpty || change.searchText.contains(needle))
        }
        return try page(
            FetchDescriptor<SDFileChange>(predicate: filter, sortBy: sort),
            limit: query.limit, offset: query.offset,
            complete: projectPath.isEmpty,
            map: map, passes: passes
        )
    }

    /// 某次文件变更的 diff：按 `changeID` 取唯一行（本 SDK 无 `fetchOne`，取 limit 1）。
    ///
    /// 无行、或 `linesJSON` 解不出来时返回 nil——宁可让 UI 显示「无 diff」，
    /// 也不伪造一个空 diff 假装看过这次变更。
    public func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        let text = changeID.uuidString
        guard let record = try firstRow(of: SDDiff.self, where: #Predicate<SDDiff> {
            $0.changeID == text
        }) else { return nil }
        return record.domainValue()
    }

    /// 命令分页：`startedAt` 闭区间 + `agentKinds` / `outcomes` 集合 + `sessionID` 精确相等
    /// + `projectPath` 精确相等 + `destructiveOnly` → `isDestructive == true`（仅当开关为真）
    /// + 字面子串搜索（haystack 是 `commandLine.lowercased()`）。
    ///
    /// 排序 = `startedAt`（方向随 `query.sort`）+ `id` 恒降序。
    /// `projectPath` 与事件/文件那两族同处：不进谓词（六个子句的上限装不下第六维），
    /// 交给 Swift 侧细筛，判据照抄冻结基准的「精确相等、NULL 永不匹配」。
    public func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        let lower = query.dateRange.start ?? .distantPast
        let upper = query.dateRange.end ?? .distantFuture
        let agentKinds = sortedRawValues(query.agentKinds)
        let outcomes = sortedRawValues(query.outcomes)
        let destructiveOnly = query.destructiveOnly
        let projectPath = query.projectPath ?? ""
        let needle = query.searchText.lowercased()
        // #86：`exit_code != 0` 这一维，两臂都下推（可空整数按 `flag ||` 写法，flag 假时整段恒真）。
        let nonZeroExit = query.withNonZeroExitCode
        // 「仅当开关为真才追加条件」在谓词里只能写成 `flag || 列 == 值`：flag 为假时整段恒真。
        let sort: [SortDescriptor<SDCommand>] = [
            SortDescriptor(\.startedAt, order: query.sort.descending ? .reverse : .forward),
            SortDescriptor(\.rowID, order: .reverse),
        ]
        let map: (SDCommand) -> CommandRecord? = { row in row.domainValue() }
        let passes: (CommandRecord) -> Bool = { Self.matches($0, query: query) }

        if nonZeroExit, let sessionText = query.sessionID?.uuidString {
            // 臂 S2（#86）：带「退出码非零」这一维的会话查询走这一支。
            // 臂 S 装不下第六个子句——加进去之后 `#Predicate` 宏当场报
            // "the compiler is unable to type-check this expression in reasonable time"（实测），
            // 所以这一支**只下推 时间 + 会话 + 退出码**，把 `agentKinds` / `outcomes` 两个集合
            // 交给 Swift 侧 `matches`。代价可以接受：这一支挑出来的行本来就是
            // 「该会话里退出码非零」那一小把，而 `complete: false` 那条路径是按 `chunkSize`
            // 分块流式读的（#38 那轮的修法），不会把整个会话的命令行一次倒进内存。
            let filter = #Predicate<SDCommand> { command in
                command.startedAt >= lower
                    && command.startedAt <= upper
                    && command.sessionID == sessionText
                    && (command.exitCode ?? 0) != 0
            }
            return try page(
                FetchDescriptor<SDCommand>(predicate: filter, sortBy: sort),
                limit: query.limit, offset: query.offset,
                complete: false,
                map: map, passes: passes
            )
        }
        if let sessionText = query.sessionID?.uuidString {
            // 臂 S：下推 时间 + 会话 + 两个集合；留给 Swift：destructiveOnly、searchText、projectPath。
            // （这一臂再加 searchText 就越过谓词类型检查上限——可空列相等比较比 Int
            //   比较贵得多，同样的子句数在别的臂能过、这里过不了。）
            let filter = #Predicate<SDCommand> { command in
                command.startedAt >= lower
                    && command.startedAt <= upper
                    && command.sessionID == sessionText
                    && (agentKinds.isEmpty || agentKinds.contains(command.agentKind))
                    && (outcomes.isEmpty || outcomes.contains(command.outcome))
            }
            return try page(
                FetchDescriptor<SDCommand>(predicate: filter, sortBy: sort),
                limit: query.limit, offset: query.offset,
                complete: !destructiveOnly && needle.isEmpty && projectPath.isEmpty && !nonZeroExit,
                map: map, passes: passes
            )
        }
        // 臂 G：下推 时间 + 两个集合 + 搜索；留给 Swift：destructiveOnly、projectPath。
        // 「布尔标志」这一子句加不进去——同样 6 个子句，带 `flag || 列 == true` 就过不了
        // 类型检查（谓词成本按节点算，不是只按子句数）。
        let filter = #Predicate<SDCommand> { command in
            command.startedAt >= lower
                && command.startedAt <= upper
                && (agentKinds.isEmpty || agentKinds.contains(command.agentKind))
                && (outcomes.isEmpty || outcomes.contains(command.outcome))
                && (needle.isEmpty || command.searchText.contains(needle))
        }
        return try page(
            FetchDescriptor<SDCommand>(predicate: filter, sortBy: sort),
            limit: query.limit, offset: query.offset,
            complete: !destructiveOnly && projectPath.isEmpty && !nonZeroExit,
            map: map, passes: passes
        )
    }


}
