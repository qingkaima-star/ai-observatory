//
//  ExportCoordinator.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（主代理）
//
//  导出编排：把「请求 + 数据来源」拆成每 kind 一个文件，逐文件流式写出。
//  本文件是唯一允许触碰 `ObservatoryService` 协议的地方 —— 导出层因此仍然只依赖 Core 契约。
//

import Foundation
import AIObservatoryCore

/// 一个已落盘的导出产物。
public struct ExportedArtifact: Sendable, Hashable {
    public var url: URL
    public var kind: ExportKind
    public var format: ExportFormat
    /// 该文件写出的记录条数（`.report` 为参与聚合的记录总数）。
    public var recordCount: Int
    public var bytesWritten: Int
    /// 分块次数；`> 1` 即证明未一次性拼完整文档。
    public var chunkCount: Int

    public init(url: URL, kind: ExportKind, format: ExportFormat,
                recordCount: Int, bytesWritten: Int, chunkCount: Int) {
        self.url = url
        self.kind = kind
        self.format = format
        self.recordCount = recordCount
        self.bytesWritten = bytesWritten
        self.chunkCount = chunkCount
    }
}

/// 请求实际生效的脱敏器：`redactionEnabled` 是唯一开关，导出器自己不猜默认值。
///
/// #64：路径映射**只在开启凭据脱敏时**生效——这不是漏，是刻意的：
/// `redactionEnabled == false` 是用户显式确认过"要原始件"（`ExportRedactor.disabled` 的文档就这么写），
/// 那时再偷偷改写路径等于替用户做他没同意的决定。演示开关要作用到导出件，
/// 两个开关都得开着；设置页的 caveat 文案按这一条写。
extension ExportRequest {
    public var redactor: ExportRedactor {
        redactionEnabled ? .standard(pathMask: pathMask) : .disabled
    }
}

/// 把 `ExportRequest` 变成磁盘上的导出文件。
public struct ExportCoordinator: Sendable {
    /// 单次 flush 的缓冲阈值（字节）。调小只是分块更多，不改变输出字节。
    public var chunkThresholdBytes: Int

    public init(chunkThresholdBytes: Int = ExportConstants.defaultChunkThresholdBytes) {
        self.chunkThresholdBytes = max(1, chunkThresholdBytes)
    }

    /// 用调用方给出的记录执行导出。
    ///
    /// 每个 `kind` 产出一个文件（多表导出因此天然分文件）；`.report` 在 `format == .markdown` 时产出报告。
    /// - Parameters:
    ///   - request: 导出参数；`destination.allowedRoots` 决定可写目录，越界即抛错。
    ///   - records: 全部候选记录（内部按 kind 分组、按 `dateRange` 过滤、确定性排序）。
    ///   - projects: 报告用的项目活动地图；非 `.report` 导出可省略。
    /// - Returns: 按 `request.kinds` 顺序排列的产物清单。
    /// - Throws: ``ExportError``；写盘失败时原样上抛，不静默丢弃。
    public func run(_ request: ExportRequest, records: [ExportRecord],
                    projects: [ProjectActivity] = []) throws -> [ExportedArtifact] {
        try request.validate()
        var artifacts: [ExportedArtifact] = []
        for kind in request.kinds {
            artifacts.append(try write(kind: kind, request: request, records: records, projects: projects))
        }
        return artifacts
    }

    /// 从只读服务分页拉取后导出（UI / 菜单栏「导出报告」走这条路径）。
    ///
    /// 分页按 `oldestFirst` 升序，保证同一数据集的导出顺序与 `records:` 版本一致。
    /// - Parameter pageSize: 每页条数；每页是一次 `async` 查询，避免一次性把全库读进内存。
    public func run(_ request: ExportRequest, service: any ObservatoryService,
                    pageSize: Int = 500) async throws -> [ExportedArtifact] {
        try request.validate()
        let size = max(1, pageSize)
        // 要收哪些 kind 的记录：**不只是"这次要写成文件的 kinds"**。
        // `.report` 的概览是从传进来的 records 里算的（见 `write(kind:records:)` 里
        // `case (.markdown, .report)` 那五路 `filtered(records:for:)`），
        // 而 Markdown 导出按 `supportedFormats` 只会选 `.report` 一个 kind ⇒
        // 若只收集 `request.kinds`，报告就拿不到任何记录，
        // 产出一份"0 会话 / 0 事件 / 0 风险"的空壳报告（只有项目数是单独查的，所以非 0）。
        // 2026-09-21 由 `ExportEndToEndTests` 抓到：同一次导出的 JSON 里有 3 条风险。
        var kindsToCollect = request.kinds.filter(\.isRecordKind)
        if request.kinds.contains(.report) {
            for kind in ExportKind.reportSourceKinds where !kindsToCollect.contains(kind) {
                kindsToCollect.append(kind)
            }
        }
        var records: [ExportRecord] = []
        for kind in kindsToCollect {
            records += try await collect(kind: kind, request: request, service: service, pageSize: size)
        }
        let projects: [ProjectActivity]
        if request.format == .markdown && request.kinds.contains(.report) {
            projects = try await service.projects()
        } else {
            projects = []
        }
        return try run(request, records: records, projects: projects)
    }

    // MARK: - 单文件写出

    private func write(kind: ExportKind, request: ExportRequest, records: [ExportRecord],
                       projects: [ProjectActivity]) throws -> ExportedArtifact {
        let url = request.destination.fileURL(for: kind, format: request.format, stamp: request.fileStamp)
        var writer = try ExportWriter.file(url, allowedRoots: request.destination.allowedRoots,
                                           chunkThresholdBytes: chunkThresholdBytes)
        let redactor = request.redactor
        let scoped: [ExportRecord]
        do {
            switch (request.format, kind) {
            case (.markdown, .report):
                scoped = request.filtered(records: records, for: .sessions)
                    + request.filtered(records: records, for: .timeline)
                    + request.filtered(records: records, for: .fileChanges)
                    + request.filtered(records: records, for: .commands)
                    + request.filtered(records: records, for: .riskEvents)
                try MarkdownReportExporter.write(
                    input: MarkdownReportExporter.Input(records: scoped, projects: projects,
                                                        generatedAt: request.generatedAt,
                                                        dateRange: request.dateRange,
                                                        interfaceLanguage: request.interfaceLanguage),
                    redactor: redactor, to: &writer)
            case (.json, _):
                scoped = request.filtered(records: records, for: kind)
                try JSONExporter.write(records: scoped, kind: kind, request: request,
                                       redactor: redactor, to: &writer)
            case (.csv, _):
                scoped = request.filtered(records: records, for: kind)
                try CSVExporter.write(records: scoped, kind: kind, request: request, redactor: redactor,
                                      columns: try request.columns(for: kind), to: &writer)
            default:
                throw ExportError.unsupportedCombination(format: request.format, kind: kind)
            }
            try writer.finish()
        } catch {
            // 关闭句柄是收尾动作；这里只尽力 flush，原始错误必须原样上抛（不吞异常）。
            try? writer.finish()
            throw error
        }
        return ExportedArtifact(url: url, kind: kind, format: request.format,
                                recordCount: scoped.count,
                                bytesWritten: writer.bytesWritten, chunkCount: writer.chunkCount)
    }

    // MARK: - 分页采集

    /// 从只读服务按 kind 分页采集记录（过滤与写出顺序的归一交给 `ExportRequest.filtered`）。
    ///
    /// 公开它是因为**这条分页逻辑只能有一份**：2026-09-21 那次「报告拿到 0 条记录」的空壳缺陷
    /// 就长在"收集哪些 kind"与"写出哪些 kind"不是一回事上（见 `run(_:service:)` 里那段注释）。
    /// 任何要把库里的记录喂给导出器某个出口的消费方（命令行、未来的定时导出）都必须走这里，
    /// 不要再写第二份分页采集。`pageSize` 是一次查询的行数，不是总量上限。
    public func collect(kind: ExportKind, request: ExportRequest, service: any ObservatoryService,
                        pageSize: Int) async throws -> [ExportRecord] {
        let range = request.dateRange
        // 有上限时按「最新优先」分页：拿到最新的 limit 条即可停止，不必扫全表；
        // 无上限时按时间升序流式取全量。两种情形的最终写出顺序都由 `filtered()` 归一为升序。
        let sort: AIObservatoryCore.SortOrder =
            request.maximumRecordsPerKind == nil ? .oldestFirst : .newestFirst
        var collected: [ExportRecord] = []
        var offset = 0
        // 页数上限：即使后端 `hasMore` 写错也不会把这里变成死循环。
        var pagesRemaining = 10_000
        while pagesRemaining > 0 {
            pagesRemaining -= 1
            let taken: Int
            switch kind {
            case .sessions:
                let page = try await service.sessions(matching: SessionQuery(
                    dateRange: range, limit: pageSize, offset: offset, sort: sort))
                collected += page.items.map { ExportRecord.session($0) }
                taken = page.items.count
                if page.totalCount <= offset + taken || !page.hasMore || taken == 0 { return collected }
            case .timeline:
                let page = try await service.events(matching: EventQuery(
                    dateRange: range, limit: pageSize, offset: offset, sort: sort))
                collected += page.items.map { ExportRecord.event($0) }
                taken = page.items.count
                if page.totalCount <= offset + taken || !page.hasMore || taken == 0 { return collected }
            case .fileChanges:
                let page = try await service.fileChanges(matching: FileChangeQuery(
                    dateRange: range, limit: pageSize, offset: offset, sort: sort))
                collected += page.items.map { ExportRecord.fileChange($0) }
                taken = page.items.count
                if page.totalCount <= offset + taken || !page.hasMore || taken == 0 { return collected }
            case .commands:
                let page = try await service.commands(matching: CommandQuery(
                    dateRange: range, limit: pageSize, offset: offset, sort: sort))
                collected += page.items.map { ExportRecord.command($0) }
                taken = page.items.count
                if page.totalCount <= offset + taken || !page.hasMore || taken == 0 { return collected }
            case .riskEvents:
                let page = try await service.riskEvents(matching: RiskQuery(
                    dateRange: range, limit: pageSize, offset: offset, sort: sort))
                collected += page.items.map { ExportRecord.riskEvent($0) }
                taken = page.items.count
                if page.totalCount <= offset + taken || !page.hasMore || taken == 0 { return collected }
            case .report:
                return []
            }
            offset += taken
            if let limit = request.maximumRecordsPerKind, collected.count >= limit { return collected }
        }
        return collected
    }
}
