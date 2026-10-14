//
//  AixQuery.swift
//  AIObservatoryCLI
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  把 `AixRequest` 映射成契约里的 `*Query`，打 `any ObservatoryService`。
//
//  这个文件是「两个口径」的防线所在：七条命令**共用同一处**过滤器映射与同一处取数，
//  所以 `--json` 与人读表格、`report` 的正文，拿到的行集必然相同。
//  这里**一条 SQL 都没有** —— 全部走 `ObservatoryService`，SQLite / SwiftData / 内存三后端同口径。
//

import Foundation
import AIObservatoryCore
import AIObservatoryExport

/// 一次取数的结果。`matchedTotal` 是**过滤后**的总行数（不是页大小），
/// `tableTotal` 是**无过滤**的总行数 —— 只有分不清「表本来就是空」还是「条件筛没了」时才多查这一次。
public enum AixFetched: Sendable {
    /// `aix agents`：Store 侧只有「活跃（running/idle）」这一条查询，没有全量 Agent 查询，
    /// 所以 `tableTotal` 恒为 `nil` ⇒ 输出必须写成「活跃 0 个（全表行数拿不到）」而不是「库里没有 Agent」。
    case agents(rows: [AgentInstance], tableTotal: Int?)
    case rows(kind: ExportKind, records: [ExportRecord], matchedTotal: Int, tableTotal: Int?)

    public var displayedCount: Int {
        switch self {
        case .agents(let rows, _): rows.count
        case .rows(_, let records, _, _): records.count
        }
    }

    public var isEmpty: Bool { displayedCount == 0 }

    /// **不带任何过滤**的表行数；`nil` = Store 侧拿不到这个数（agents 那一格）。
    /// 它决定零行输出写成「表是空的」还是「你的条件筛没了」—— 两者不能混为一谈。
    public var tableTotal: Int? {
        switch self {
        case .agents(_, let total): total
        case .rows(_, _, _, let total): total
        }
    }

    /// 过滤后总行数。agents 那一路就是「当前活跃数」，没有额外过滤。
    public var matchedTotal: Int {
        switch self {
        case .agents(let rows, _): rows.count
        case .rows(_, _, let total, _): total
        }
    }
}

public enum AixQuery {
    /// 分页步长与导出层 `ExportCoordinator.run(_:service:)` 的默认 `pageSize` 同值。
    public static let pageSize = 500
    /// `--all`：交给 SQL 的 `LIMIT`，语义就是「不加限」。
    public static let unlimited = Int.max

    static func dateRange(_ request: AixRequest) -> DateRangeFilter {
        DateRangeFilter(start: request.since, end: nil)
    }

    /// 单一入口：请求 → 取数（页内行 + 过滤后总数）。
    static func run(_ request: AixRequest, service: any ObservatoryService) async throws -> AixFetched {
        let limit = request.limit ?? unlimited
        switch request.command {
        case .agents:
            var rows = try await service.activeAgents()
            // activeAgents() 没有过滤参数 ⇒ --since / --limit 只能在这一层收（不假装 Store 筛过）。
            if let since = request.since {
                rows = rows.filter { $0.startedAt >= since }
            }
            if limit < rows.count {
                rows = Array(rows.prefix(limit))
            }
            return .agents(rows: rows, tableTotal: nil)

        case .sessions, .timeline, .files, .commands, .risk:
            let kind = exportKind(for: request.command)
            let page = try await fetch(kind: kind, request: request, service: service,
                                       limit: limit, offset: 0)
            let records = page.records
            let total = page.totalCount
            // 空结果时才查「无过滤总数」：这一格决定输出是「库是空的」还是「你的条件筛没了」。
            let tableTotal = records.isEmpty ? try await tableRowCount(kind: kind, service: service) : nil
            return .rows(kind: kind, records: records, matchedTotal: max(total, records.count), tableTotal: tableTotal)

        case .report:
            // report 不走这一条；见 `AixRunner` 里按 kind 逐类收集。
            throw AixUsageError("report 不走单类取数")
        }
    }

    /// 子命令 → 导出层的 kind。`report` 与 `agents` 没有对应 kind（前者是文档，后者导出层没有列）。
    public static func exportKind(for command: AixRequest.Command) -> ExportKind {
        switch command {
        case .sessions: .sessions
        case .timeline: .timeline
        case .files: .fileChanges
        case .commands: .commands
        case .risk: .riskEvents
        case .agents, .report: .report
        }
    }

    private static func fetch(kind: ExportKind, request: AixRequest, service: any ObservatoryService,
                              limit: Int, offset: Int) async throws
        -> (records: [ExportRecord], totalCount: Int) {
        let range = dateRange(request)
        switch kind {
        case .sessions:
            let page = try await service.sessions(matching: SessionQuery(dateRange: range, limit: limit, offset: offset))
            return (page.items.map { ExportRecord.session($0) }, page.totalCount)
        case .timeline:
            let page = try await service.events(matching: EventQuery(dateRange: range, limit: limit, offset: offset))
            return (page.items.map { ExportRecord.event($0) }, page.totalCount)
        case .fileChanges:
            let query = FileChangeQuery(
                dateRange: range,
                agentKinds: request.unattributedOnly ? [.unknown] : [],
                limit: limit,
                offset: offset
            )
            let page = try await service.fileChanges(matching: query)
            return (page.items.map { ExportRecord.fileChange($0) }, page.totalCount)
        case .commands:
            let page = try await service.commands(matching: CommandQuery(dateRange: range, limit: limit, offset: offset))
            return (page.items.map { ExportRecord.command($0) }, page.totalCount)
        case .riskEvents:
            let query = RiskQuery(
                dateRange: range,
                levels: request.level.map { [$0] } ?? [],
                limit: limit,
                offset: offset
            )
            let page = try await service.riskEvents(matching: query)
            return (page.items.map { ExportRecord.riskEvent($0) }, page.totalCount)
        case .report:
            throw AixUsageError("report 没有单一记录类型")
        }
    }

    /// 同一类记录、**不带任何过滤条件**的总行数 ⇒ 用来把「空库」与「查无结果」分开。
    static func tableRowCount(kind: ExportKind, service: any ObservatoryService) async throws -> Int? {
        switch kind {
        case .sessions:
            try await service.sessions(matching: SessionQuery(limit: 1)).totalCount
        case .timeline:
            try await service.events(matching: EventQuery(limit: 1)).totalCount
        case .fileChanges:
            try await service.fileChanges(matching: FileChangeQuery(limit: 1)).totalCount
        case .commands:
            try await service.commands(matching: CommandQuery(limit: 1)).totalCount
        case .riskEvents:
            try await service.riskEvents(matching: RiskQuery(limit: 1)).totalCount
        case .report:
            nil
        }
    }

    /// `report` 的正文输入：五类记录一次收齐。
    ///
    /// **分页采集这件事不在这里做** —— 直接调导出层那条 `ExportCoordinator.collect(kind:request:service:pageSize:)`
    /// （ICR-0012 C1 就是为这个才批的）。理由不是洁癖：那段逻辑 2026-09-21 刚错过一次
    /// （「报告拿到 0 条记录」的空壳，案发现场见 `ExportCoordinator.swift` 里那段注释），
    /// 第二份分页采集迟早再错一次。CLI 这里只把五类凑齐、并把请求翻译成 `ExportRequest`。
    static func reportRecords(_ request: AixRequest, service: any ObservatoryService,
                              now: Date, databasePath: String) async throws -> [ExportRecord] {
        // collect 只按 kind + dateRange 筛（导出层的语义），report 也没有比 --since 更多的过滤条件可用：
        // --unattributed 只对 files 有效、--level 只对 risk 有效，report 一条都不吃。
        let directory = URL(fileURLWithPath: databasePath, isDirectory: true)
        let export = ExportRequest(format: .json, kinds: ExportKind.reportSourceKinds,
                                   dateRange: dateRange(request), generatedAt: now,
                                   redactionEnabled: request.redactCredentials,
                                   interfaceLanguage: .resolved(),
                                   destination: ExportDestination(directory: directory, baseName: "aix",
                                                                 allowedRoots: [directory]))
        let coordinator = ExportCoordinator()
        var records: [ExportRecord] = []
        for kind in ExportKind.reportSourceKinds {
            records += try await coordinator.collect(kind: kind, request: export, service: service,
                                                    pageSize: pageSize)
        }
        return records
    }
}
