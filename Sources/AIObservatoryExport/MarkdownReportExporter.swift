//
//  MarkdownReportExporter.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（子代理 C）
//
//  人读 Markdown 审计报告：给用户与安全负责人看的最终产物（不是机器可读表）。
//
//  设计约束（对齐《导出层接口》§0 铁律 + §2C 契约）：
//   · UTF-8、行尾恒为 "\n"；表格单元一律 `ExportText.markdownCell`，
//     自由文本先 `ExportText.oneLine` 折叠换行，保证表格结构不被内容击穿；
//   · **正文语言在导出时定死**（`Input.interfaceLanguage`，默认取进程当前语言），
//     并作为「报告语言 / Report language」写进文档头：英文用户拿到中文报告时，
//     第一行就能看出这是语言选择而不是翻译坏了（IFR 裁定 2）。字面文字全部来自
//     ``ExportCopy``，本文件不就地写中文；
//   · **流式写出**：每行一次 `ExportWriter.write`，本文件不在内存里拼完整文档；
//     `report(...)` 只是 memory sink 之上的一层薄封装，因此与 `write(...)` 内容逐字节一致；
//   · **绝不读墙钟**：全文唯一时间源是 `input.generatedAt`；运行中会话的时长走契约的
//     `AgentSession.duration(until:)`，日期串一律 `ExportDateEncoder`（固定 UTC、无小数秒）；
//   · 全部自由文本（会话标题、命令、风险详情、文件路径）先 `redactor.redact` 再入表；
//   · 聚合是纯函数，并且记录先按 (`timestamp`, `stableIdentifier`) 归一排序，
//     所以输出与传入数组的顺序无关：同一 `Input` 两次 `report(...)` 字符串完全相同。
//

import Foundation
import AIObservatoryCore

/// 人读 Markdown 审计报告导出器（概览 / Top 热文件 / 危险命令与高风险事件 / 逐会话摘要）。
public enum MarkdownReportExporter {

    // MARK: - 输入

    /// 一次报告生成的全部输入。全部为值类型，可跨并发域传递。
    public struct Input: Sendable {
        /// 审计记录（可混杂多种 kind；先按 `dateRange` 过滤，再聚合与分章节写出）。
        public var records: [ExportRecord]
        /// 项目级活动地图，供「最常被改动的文件」跨项目聚合。
        public var projects: [ProjectActivity]
        /// 报告生成时刻：本文件唯一的时间源（不读墙钟）。
        public var generatedAt: Date
        /// 统计区间（闭区间，语义同 `DateRangeFilter.contains`），作用于 `records`。
        /// `projects` 的聚合由上游按区间完成，此处不再二次过滤。
        public var dateRange: DateRangeFilter
        /// 本报告正文的语言：**导出时刻定死**，写进文件后不再随系统语言变
        /// （IFR 裁定 2 第一步）。默认取进程语言，装配点要别的语言就显式传。
        public var interfaceLanguage: AppLanguage

        /// 构造报告输入。
        /// - Parameters:
        ///   - records: 审计记录集合（混杂 kind 亦可）。
        ///   - projects: 项目活动地图，默认空。
        ///   - generatedAt: 报告生成时刻，必须显式注入。
        ///   - dateRange: 统计区间，默认 `.unbounded`（不限）。
        ///   - interfaceLanguage: 正文语言，默认按进程当前语言（`AppLanguage.resolved()`）。
        public init(records: [ExportRecord], projects: [ProjectActivity] = [],
                    generatedAt: Date, dateRange: DateRangeFilter = .unbounded,
                    interfaceLanguage: AppLanguage = .resolved()) {
            self.records = records
            self.projects = projects
            self.generatedAt = generatedAt
            self.dateRange = dateRange
            self.interfaceLanguage = interfaceLanguage
        }
    }

    // MARK: - 常量

    /// 行尾：Markdown 文档统一 LF（区别于 CSV 的 CRLF）。
    private static let lineEnding = "\n"
    /// 可选字段为 `nil` 时的单元占位符（区别于「空字符串」这个真实值）。
    /// 这是排版符号、不是文案 ⇒ 两语言同值，不进 ``ExportCopy``。
    private static let noValue = "—"

    // 其余全部字面文字（标题 / 标签 / 列名 / 脚注）在 ``ExportCopy`` 里成对声明，
    // 由 `Input.interfaceLanguage` 选路 —— 本文件不再就地写中文。

    // MARK: - 公开出口

    /// 流式写出完整审计报告：每个章节边算边写，一次只写一行。
    ///
    /// 记录先按 `input.dateRange` 过滤，再按 (`timestamp`, `stableIdentifier`) 归一排序，
    /// 因此同一 `Input`（无论数组顺序如何）产出逐字节相同的文本。
    /// 所有自由文本在写之前都过 `redactor`；时间只来自 `input.generatedAt`。
    /// - Parameters:
    ///   - input: 报告输入。
    ///   - redactor: 生效的脱敏器（`.disabled` 时原文照出，属调用方显式确认的行为）。
    ///   - writer: 已就绪的写入器；**由调用方负责 `finish()`**。
    public static func write(input: Input, redactor: ExportRedactor, to writer: inout ExportWriter) throws {
        let encoder = ExportDateEncoder()
        let language = input.interfaceLanguage
        let scoped = scopedRecords(input)
        let metrics = aggregate(scoped)

        try writeHeader(input: input, language: language, metrics: metrics, encoder: encoder,
                        redactor: redactor, to: &writer)
        try writeOverview(metrics: metrics, projectCount: input.projects.count,
                          language: language, to: &writer)
        try writeHotFiles(projects: input.projects, language: language, encoder: encoder,
                          redactor: redactor, to: &writer)
        try writeDangerSection(scoped: scoped, language: language, encoder: encoder,
                               redactor: redactor, to: &writer)
        try writeSessionSection(sessions: scoped.compactMap { $0.session }, generatedAt: input.generatedAt,
                                language: language, encoder: encoder, redactor: redactor, to: &writer)
        try writeFooter(redactor: redactor, language: language, to: &writer)
    }

    /// 便捷出口：把报告写进内存 sink 后整体返回，用于小文档与测试。
    ///
    /// 与 `write(input:redactor:to:)` 对同一 `Input` 产出**完全相同**的文本
    /// （本方法就是它的一次调用 + UTF-8 解码）。
    /// - Parameters:
    ///   - input: 报告输入。
    ///   - redactor: 生效的脱敏器，默认 `.standard`。
    /// - Returns: 完整 Markdown 报告（以 `"\n"` 结尾）。
    public static func report(input: Input, redactor: ExportRedactor = .standard) throws -> String {
        var writer = ExportWriter.memory()
        try write(input: input, redactor: redactor, to: &writer)
        try writer.finish()
        let data = try writer.collectedData()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - 记录归一与聚合

    /// 归一后的记录集：先按统计区间过滤，再按 (`timestamp`, `stableIdentifier`) 升序排序。
    ///
    /// 有了这个全序，聚合顺序与章节顺序都不再依赖传入数组的顺序，浮点求和顺序也唯一 ——
    /// 这是「同输入同字节」的前提。
    private static func scopedRecords(_ input: Input) -> [ExportRecord] {
        let kept = input.records.filter { input.dateRange.contains($0.timestamp) }
        return kept.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.stableIdentifier < rhs.stableIdentifier
        }
    }

    /// 概览章节的聚合结果（纯值类型，不持有外部状态）。
    private struct ReportMetrics {
        var recordCount = 0
        var sessionCount = 0
        var eventCount = 0
        var fileChangeCount = 0
        var commandCount = 0
        var riskEventCount = 0
        var highRiskRecordCount = 0
        var destructiveCommandCount = 0
        var hasSessions = false
        var sessionCPUSeconds = 0.0
        var sessionPeakMemoryBytes: UInt64 = 0
        var eventCPUSeconds = 0.0
        var eventPeakMemoryBytes: UInt64 = 0

        /// 总 CPU 秒：有会话记录时取会话聚合值之和，否则退化到时间线事件消耗之和。
        var cpuSeconds: Double { hasSessions ? sessionCPUSeconds : eventCPUSeconds }

        /// 峰值内存字节：口径同 `cpuSeconds`（会话峰值取最大）。
        var peakMemoryBytes: UInt64 { hasSessions ? sessionPeakMemoryBytes : eventPeakMemoryBytes }
    }

    /// 单遍聚合。NaN / Infinity 的样本值被跳过（不让脏数据污染整张表）。
    private static func aggregate(_ records: [ExportRecord]) -> ReportMetrics {
        var metrics = ReportMetrics()
        for record in records {
            metrics.recordCount += 1
            if record.riskLevel >= .high { metrics.highRiskRecordCount += 1 }
            switch record {
            case let .session(session):
                metrics.sessionCount += 1
                metrics.hasSessions = true
                if session.cpuSeconds.isFinite { metrics.sessionCPUSeconds += session.cpuSeconds }
                metrics.sessionPeakMemoryBytes = max(metrics.sessionPeakMemoryBytes, session.peakMemoryBytes)
            case let .event(event):
                metrics.eventCount += 1
                if event.cost.cpuSeconds.isFinite { metrics.eventCPUSeconds += event.cost.cpuSeconds }
                metrics.eventPeakMemoryBytes = max(metrics.eventPeakMemoryBytes, event.cost.memoryBytes)
            case .fileChange:
                metrics.fileChangeCount += 1
            case let .command(command):
                metrics.commandCount += 1
                if command.isDestructive { metrics.destructiveCommandCount += 1 }
            case .riskEvent:
                metrics.riskEventCount += 1
            }
        }
        return metrics
    }

    // MARK: - 章节 1：文档头

    private static func writeHeader(input: Input, language: AppLanguage, metrics: ReportMetrics,
                                    encoder: ExportDateEncoder, redactor: ExportRedactor,
                                    to writer: inout ExportWriter) throws {
        try emit(ExportCopy.reportDocumentTitle.text(language), to: &writer)
        try emit(to: &writer)
        try emit(ExportCopy.reportGeneratedAt.format(language, encoder.string(input.generatedAt)), to: &writer)
        try emit(ExportCopy.reportDateRange.format(language,
                                                   rangeEndpoint(input.dateRange.start, language: language, encoder: encoder),
                                                   rangeEndpoint(input.dateRange.end, language: language, encoder: encoder)),
                 to: &writer)
        try emit(ExportCopy.reportIncludedRecords.format(language,
                                                         ExportText.integer(metrics.recordCount),
                                                         ExportText.integer(input.records.count - metrics.recordCount)),
                 to: &writer)
        try emit(ExportCopy.reportLanguage.format(language, languageName(language)), to: &writer)
        try emit(ExportCopy.reportSource.format(language, ExportConstants.exportedBy), to: &writer)
        if redactor.isEnabled == false {
            try emit(ExportCopy.reportRedactionOffWarning.text(language), to: &writer)
        }
        try emit(to: &writer)
    }

    /// 报告语言的自称名，**按报告语言取**（英文报告写 "English"，中文报告写「英文」都不写错）。
    private static func languageName(_ language: AppLanguage) -> String {
        switch language {
        case .chineseSimplified: return ExportCopy.languageNameChinese.text(language)
        case .english:           return ExportCopy.languageNameEnglish.text(language)
        }
    }

    /// 区间端点文本：`nil` → 「不限」。
    private static func rangeEndpoint(_ date: Date?, language: AppLanguage, encoder: ExportDateEncoder) -> String {
        guard let date else { return ExportCopy.reportUnbounded.text(language) }
        return encoder.string(date)
    }

    // MARK: - 章节 2：概览表

    private static func writeOverview(metrics: ReportMetrics, projectCount: Int, language: AppLanguage,
                                      to writer: inout ExportWriter) throws {
        try emit(ExportCopy.reportOverviewTitle.text(language), to: &writer)
        try emit(to: &writer)
        try emitTableRow([ExportCopy.reportMetricColumn.text(language), ExportCopy.reportValueColumn.text(language)],
                         to: &writer)
        try emitTableSeparator(columnCount: 2, to: &writer)
        let rows: [(String, String)] = [
            (ExportCopy.reportOverviewSessions.text(language), ExportText.integer(metrics.sessionCount)),
            (ExportCopy.reportOverviewEvents.text(language), ExportText.integer(metrics.eventCount)),
            (ExportCopy.reportOverviewFileChanges.text(language), ExportText.integer(metrics.fileChangeCount)),
            (ExportCopy.reportOverviewCommands.text(language), ExportText.integer(metrics.commandCount)),
            (ExportCopy.reportOverviewRiskEvents.text(language), ExportText.integer(metrics.riskEventCount)),
            (ExportCopy.reportOverviewHighRiskRecords.text(language), ExportText.integer(metrics.highRiskRecordCount)),
            (ExportCopy.reportOverviewDestructiveCommands.text(language),
             ExportText.integer(metrics.destructiveCommandCount)),
            (ExportCopy.reportOverviewCPUSeconds.text(language),
             ExportText.double(metrics.cpuSeconds, fractionDigits: 3)),
            (ExportCopy.reportOverviewPeakMemory.text(language), ExportText.bytes(metrics.peakMemoryBytes)),
            (ExportCopy.reportOverviewProjects.text(language), ExportText.integer(projectCount)),
        ]
        for row in rows {
            try emitTableRow([row.0, row.1], to: &writer)
        }
        try emit(to: &writer)
        try emit(ExportCopy.reportOverviewNote.text(language), to: &writer)
        try emit(to: &writer)
    }

    // MARK: - 章节 3：Top 热文件

    /// 跨项目合并后的热文件（同 `path` 合并计数）。
    private struct HotFileRow {
        var path: String
        var changeCount: Int
        var linesAdded: Int
        var linesRemoved: Int
        var lastTouchedAt: Date
    }

    private static func writeHotFiles(projects: [ProjectActivity], language: AppLanguage,
                                      encoder: ExportDateEncoder,
                                      redactor: ExportRedactor, to writer: inout ExportWriter) throws {
        try emit(ExportCopy.reportHotFilesTitle.text(language), to: &writer)
        try emit(to: &writer)
        let rows = mergedHotFiles(from: projects)
        guard rows.isEmpty == false else {
            try emit(ExportCopy.reportNone.text(language), to: &writer)
            try emit(to: &writer)
            return
        }
        try emitTableRow([
            ExportCopy.reportPathColumn.text(language),
            ExportCopy.reportChangeCountColumn.text(language),
            ExportCopy.reportLinesAddedColumn.text(language),
            ExportCopy.reportLinesRemovedColumn.text(language),
            ExportCopy.reportLastTouchedColumn.text(language),
        ], to: &writer)
        try emitTableSeparator(columnCount: 5, to: &writer)
        for row in rows.prefix(ExportConstants.reportTopFiles) {
            try emitTableRow([
                redactor.redact(row.path),
                ExportText.integer(row.changeCount),
                ExportText.integer(row.linesAdded),
                ExportText.integer(row.linesRemoved),
                encoder.string(row.lastTouchedAt),
            ], to: &writer)
        }
        try emit(to: &writer)
    }

    /// 跨 `projects` 按 `path` 合并 `FileHeat`：计数与行数相加、最近改动取最大，
    /// 再按 `changeCount` 降序、同值按 `path` 升序排列（`path` 是字典键，故全序唯一）。
    private static func mergedHotFiles(from projects: [ProjectActivity]) -> [HotFileRow] {
        var merged: [String: HotFileRow] = [:]
        for project in projects {
            for heat in project.hotFiles {
                guard var existing = merged[heat.path] else {
                    merged[heat.path] = HotFileRow(path: heat.path, changeCount: heat.changeCount,
                                                   linesAdded: heat.linesAdded,
                                                   linesRemoved: heat.linesRemoved,
                                                   lastTouchedAt: heat.lastTouchedAt)
                    continue
                }
                existing.changeCount += heat.changeCount
                existing.linesAdded += heat.linesAdded
                existing.linesRemoved += heat.linesRemoved
                if heat.lastTouchedAt > existing.lastTouchedAt { existing.lastTouchedAt = heat.lastTouchedAt }
                merged[heat.path] = existing
            }
        }
        return merged.values.sorted { lhs, rhs in
            if lhs.changeCount != rhs.changeCount { return lhs.changeCount > rhs.changeCount }
            return lhs.path < rhs.path
        }
    }

    // MARK: - 章节 4：危险命令与高风险事件

    private static func writeDangerSection(scoped: [ExportRecord], language: AppLanguage,
                                           encoder: ExportDateEncoder,
                                           redactor: ExportRedactor, to writer: inout ExportWriter) throws {
        try emit(ExportCopy.reportDangerTitle.text(language), to: &writer)
        try emit(to: &writer)
        try writeDangerTable(
            heading: ExportCopy.reportDangerCommandsHeading,
            columns: [ExportCopy.reportStartedAtColumn, ExportCopy.reportAgentColumn,
                      ExportCopy.reportCommandLineColumn, ExportCopy.reportRiskLevelColumn,
                      ExportCopy.reportExitCodeColumn, ExportCopy.reportRequiresConfirmationColumn,
            ].map { $0.text(language) },
            rows: dangerCommandRows(dangerCommands(from: scoped), encoder: encoder, redactor: redactor),
            language: language, to: &writer
        )
        try writeDangerTable(
            heading: ExportCopy.reportHighRiskEventsHeading,
            columns: [ExportCopy.reportTimeColumn, ExportCopy.reportLevelColumn,
                      ExportCopy.reportCategoryColumn, ExportCopy.reportTitleColumn,
                      ExportCopy.reportDetailColumn, ExportCopy.reportRelatedCommandColumn,
                      ExportCopy.reportFilesInvolvedColumn,
            ].map { $0.text(language) },
            rows: highRiskEventRows(highRiskEvents(from: scoped), encoder: encoder, redactor: redactor),
            language: language, to: &writer
        )
        try writeDangerTable(
            heading: ExportCopy.reportHighRiskOperationsHeading,
            columns: [ExportCopy.reportTimeColumn, ExportCopy.reportAgentColumn,
                      ExportCopy.reportOperationColumn, ExportCopy.reportTitleColumn,
                      ExportCopy.reportSummaryColumn, ExportCopy.reportCommandColumn,
            ].map { $0.text(language) },
            rows: riskyOperationRows(highRiskOperations(from: scoped), encoder: encoder, redactor: redactor),
            language: language, to: &writer
        )
    }

    /// 危险段的一张表：标题 → 空行 →（无行则「无」）表头 → 分隔 → 逐行 → 截断说明 → 空行。
    /// 三张表唯一的差别只有列名与行映射，形状一致 ⇒ 收成一个渲染器，字节序列与三处内联时逐格相同。
    private static func writeDangerTable(heading: LocalizedString, columns: [String], rows: [[String]],
                                         language: AppLanguage, to writer: inout ExportWriter) throws {
        try emit(heading.text(language), to: &writer)
        try emit(to: &writer)
        if rows.isEmpty {
            try emit(ExportCopy.reportNone.text(language), to: &writer)
            try emit(to: &writer)
            return
        }
        try emitTableRow(columns, to: &writer)
        try emitTableSeparator(columnCount: columns.count, to: &writer)
        for row in truncated(rows) {
            try emitTableRow(row, to: &writer)
        }
        try writeTruncationNote(total: rows.count, language: language, to: &writer)
        try emit(to: &writer)
    }

    /// 破坏性 / 高风险命令：时间升序，同刻按 `id` 定序（保证报告逐字节可复现）。
    private static func dangerCommands(from scoped: [ExportRecord]) -> [CommandRecord] {
        scoped.compactMap(\.command)
            .filter { $0.isDestructive || $0.riskLevel >= .high }
            .sorted { lhs, rhs in
                if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func dangerCommandRows(_ commands: [CommandRecord], encoder: ExportDateEncoder,
                                          redactor: ExportRedactor) -> [[String]] {
        commands.map { command in
            [
                encoder.string(command.startedAt),
                command.agentKind.displayName,
                redactor.redact(command.commandLine),
                command.riskLevel.displayName,
                exitCodeText(command.exitCode),
                ExportText.boolean(command.requiresConfirmation),
            ]
        }
    }

    /// 高风险风险事件：时间升序，同刻按 `id` 定序。
    private static func highRiskEvents(from scoped: [ExportRecord]) -> [RiskEvent] {
        scoped.compactMap(\.riskEvent)
            .filter { $0.level >= .high }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func highRiskEventRows(_ events: [RiskEvent], encoder: ExportDateEncoder,
                                         redactor: ExportRedactor) -> [[String]] {
        events.map { event in
            [
                encoder.string(event.timestamp),
                event.level.displayName,
                event.category.displayName,
                redactor.redact(event.title),
                redactor.redact(event.detail),
                event.command.map { redactor.redact($0) } ?? noValue,
                ExportText.list(event.filePaths.map { redactor.redact($0) }),
            ]
        }
    }

    /// 高风险时间线操作：时间升序，同刻按 `id` 定序。
    private static func highRiskOperations(from scoped: [ExportRecord]) -> [TimelineEvent] {
        scoped.compactMap(\.event)
            .filter { $0.riskLevel >= .high }
            .sorted { lhs, rhs in
                if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
                return lhs.id.uuidString < rhs.id.uuidString
            }
    }

    private static func riskyOperationRows(_ operations: [TimelineEvent], encoder: ExportDateEncoder,
                                           redactor: ExportRedactor) -> [[String]] {
        operations.map { event in
            [
                encoder.string(event.timestamp),
                event.agentKind.displayName,
                event.kind.displayName,
                redactor.redact(event.title),
                redactor.redact(event.summary),
                event.command.map { redactor.redact($0) } ?? noValue,
            ]
        }
    }

    /// 上限截断：超出 ``ExportConstants/reportDangerousCommands`` 时保留**最近**的若干条
    /// （与 `ExportRequest.filtered` 「保留最近 limit 条」同口径）。入参须已按时间升序。
    private static func truncated<T>(_ items: [T]) -> [T] {
        let limit = ExportConstants.reportDangerousCommands
        guard items.count > limit else { return items }
        return Array(items.suffix(limit))
    }

    /// 超出 `ExportConstants.reportDangerousCommands` 时如实标注（保留最近若干条，与 CSV/JSON 侧同口径）。
    private static func writeTruncationNote(total: Int, language: AppLanguage, to writer: inout ExportWriter) throws {
        let limit = ExportConstants.reportDangerousCommands
        guard total > limit else { return }
        try emit(to: &writer)
        try emit(ExportCopy.reportTruncationNote.format(language,
                                                        ExportText.integer(total),
                                                        ExportText.integer(limit)), to: &writer)
    }

    /// 退出码文本：`nil` → 「—」（运行中或未取得）。
    private static func exitCodeText(_ code: Int32?) -> String {
        guard let code else { return noValue }
        return ExportText.integer(Int(code))
    }

    // MARK: - 章节 5：逐会话摘要

    private static func writeSessionSection(sessions: [AgentSession], generatedAt: Date, language: AppLanguage,
                                            encoder: ExportDateEncoder, redactor: ExportRedactor,
                                            to writer: inout ExportWriter) throws {
        try emit(ExportCopy.reportSessionsTitle.text(language), to: &writer)
        try emit(to: &writer)
        let ordered = sessions.sorted { lhs, rhs in
            if lhs.startedAt != rhs.startedAt { return lhs.startedAt < rhs.startedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        guard ordered.isEmpty == false else {
            try emit(ExportCopy.reportNone.text(language), to: &writer)
            try emit(to: &writer)
            return
        }
        for session in ordered {
            try writeSession(session, generatedAt: generatedAt, language: language,
                             encoder: encoder, redactor: redactor, to: &writer)
        }
    }

    /// 单个会话摘要段。标题中的会话名是自由文本 → 先 `oneLine` 再 `redact`。
    private static func writeSession(_ session: AgentSession, generatedAt: Date, language: AppLanguage,
                                     encoder: ExportDateEncoder, redactor: ExportRedactor,
                                     to writer: inout ExportWriter) throws {
        let running = session.endedAt == nil
        let title = redactor.redact(ExportText.oneLine(session.title))
        let heading = title.isEmpty ? ExportCopy.reportNoTitle.text(language) : title
        try emit(ExportCopy.reportSessionHeading.format(language,
                                                        ExportText.integer(session.displayIndex),
                                                        session.kind.displayName, heading), to: &writer)
        try emit(to: &writer)
        try emit(ExportCopy.reportSessionStartedEnded.format(language,
                                                             encoder.string(session.startedAt),
                                                             running ? ExportCopy.reportRunning.text(language)
                                                                     : encoder.string(session.endedAt)),
                 to: &writer)
        try emit(ExportCopy.reportSessionDuration.format(language,
                                                         durationText(of: session, generatedAt: generatedAt,
                                                                      language: language)), to: &writer)
        try emit(ExportCopy.reportSessionProject.format(language,
                                                        session.projectPath.map { redactor.redact(ExportText.oneLine($0)) }
                                                        ?? noValue), to: &writer)
        try emit(ExportCopy.reportSessionFiles.format(language,
                                                      ExportText.integer(session.createdFileCount),
                                                      ExportText.integer(session.modifiedFileCount),
                                                      ExportText.integer(session.deletedFileCount)), to: &writer)
        try emit(ExportCopy.reportSessionCommands.format(language,
                                                         ExportText.integer(session.commandCount),
                                                         ExportText.integer(session.failedCommandCount)), to: &writer)
        try emit(ExportCopy.reportSessionRiskEvents.format(language,
                                                           ExportText.integer(session.riskEventCount)), to: &writer)
        try emit(ExportCopy.reportSessionResources.format(language,
                                                          ExportText.double(session.cpuSeconds, fractionDigits: 3),
                                                          ExportText.bytes(session.peakMemoryBytes),
                                                          ExportText.integer(session.estimatedTokens)), to: &writer)
        try emit(ExportCopy.reportSessionOutcome.format(language, session.outcome.displayName), to: &writer)
        try emit(to: &writer)
    }

    /// 会话时长（秒）：已结束用 `endedAt - startedAt`，运行中用契约的
    /// `duration(until: generatedAt)` —— 这是本文件不读墙钟的关键点。
    private static func duration(of session: AgentSession, generatedAt: Date) -> TimeInterval {
        if let endedAt = session.endedAt {
            return max(0, endedAt.timeIntervalSince(session.startedAt))
        }
        return session.duration(until: generatedAt)
    }

    /// 时长文本，运行中额外标注「进行中 / in progress」。
    private static func durationText(of session: AgentSession, generatedAt: Date,
                                     language: AppLanguage) -> String {
        let seconds = duration(of: session, generatedAt: generatedAt)
        let text = ExportCopy.reportDurationSeconds.format(language,
                                                           ExportText.double(seconds, fractionDigits: 1))
        return session.endedAt == nil
            ? ExportCopy.reportRunningDuration.format(language, text, ExportCopy.reportRunning.text(language))
            : text
    }

    // MARK: - 页脚

    private static func writeFooter(redactor: ExportRedactor, language: AppLanguage,
                                    to writer: inout ExportWriter) throws {
        try emit("---", to: &writer)
        try emit(to: &writer)
        try emit(ExportCopy.reportFooterTimestamps.text(language), to: &writer)
        try emit(ExportCopy.reportFooterRedaction.format(language, redactionStateText(redactor, language)),
                 to: &writer)
        try emit(ExportCopy.reportFooterStreaming.text(language), to: &writer)
    }

    private static func redactionStateText(_ redactor: ExportRedactor, _ language: AppLanguage) -> String {
        let credential = redactor.isEnabled
            ? ExportCopy.reportRedactionEnabled.text(language)
            : ExportCopy.reportRedactionDisabled.text(language)
        // 凭据与路径是**两个开关**，所以两个状态都要报：只报凭据的话，
        // 一份"凭据已折、路径全裸"的报告看起来像是都处理过了。
        let paths = redactor.isPathMasked
            ? ExportCopy.reportPathsMasked.text(language)
            : ExportCopy.reportPathsUnmasked.text(language)
        return "\(credential) · \(paths)"
    }

    // MARK: - 写出工具

    /// 写一行（自动补 `"\n"`）。
    private static func emit(_ line: String = "", to writer: inout ExportWriter) throws {
        try writer.write(line + lineEnding)
    }

    /// 写一个 Markdown 表格行：每个单元都过 `ExportText.markdownCell`
    /// （折叠换行 + 转义 `|`），因此正文里的竖线不会撕开表格。
    private static func emitTableRow(_ cells: [String], to writer: inout ExportWriter) throws {
        var line = "|"
        for cell in cells {
            line += " " + ExportText.markdownCell(cell) + " |"
        }
        try emit(line, to: &writer)
    }

    /// 写表格分隔行（`| --- | --- |`）。
    private static func emitTableSeparator(columnCount: Int, to writer: inout ExportWriter) throws {
        var line = "|"
        for _ in 0..<max(0, columnCount) { line += " --- |" }
        try emit(line, to: &writer)
    }
}
