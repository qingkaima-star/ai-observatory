//
//  JSONExporter.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（子代理 A）
//
//  机读 JSON 导出器：`{schemaVersion, generatedAt, exportedBy, kind, counts, items}` envelope
//  + 逐条编码、逐条落盘的记录数组。
//
//  设计约束（《导出层接口》§0 铁律 / §2A 契约）：
//   1. 顶层 6 个键的顺序**手工**决定（写序即顺序），不靠反射，也不靠 JSONEncoder 的键排序；
//   2. 每条记录一个显式 `CodingKeys` 的私有 DTO，值全部取 Core 模型的真实字段；
//      日期先经 `ExportDateEncoder` 变 ISO8601 字符串（不使用 `dateEncodingStrategy`），
//      缺失的可选值 → JSON `null`（不是空串）；
//   3. `items` 逐条 `encode` → 逐条 `writer.write`，条间只写分隔符、数组括号手写：
//      10 000 条的峰值内存 = 「一条记录 + 一个写入阈值」，绝不在内存里拼完整文档；
//   4. 记录侧所有字符串叶子（含 UUID 串、枚举 rawValue、ISO8601 时间串）编码前一律过 `redactor`
//      —— `ExportSchema` 的列定义不脱敏，脱敏是导出器的责任；
//      envelope 的四个标量是本层常量 + 注入时间的 ISO8601 形态，不承载被审计数据，故不再过；
//   5. 时间只来自 `request.generatedAt`（本文件不读墙钟、不取系统运行时长），
//      因此「同一输入 + 同一注入时间 → 两次输出字节完全相同」恒成立；
//   6. 记录编码器恒含 `.sortedKeys`，是否再叠加 `.prettyPrinted` 跟随 `request.jsonPrettyPrinted`；
//      `"` 与 `\` 的转义全部交给 `JSONEncoder`，本文件不手写任何转义。
//

import Foundation
import AIObservatoryCore

// MARK: - 排版

/// 顶层 envelope 的空白排版：pretty 开关只改变空白，键序与语义完全不变。
///
/// 紧凑模式一个字节空白都不加；美化模式按「顶层 2 空格、数组元素 4 空格」缩进，
/// 并把单条记录的 pretty 输出整体推进元素层级（见 ``indented(_:)``）。
private struct JSONExportLayout {
    /// 裸 LF 字节：JSON 字符串内部的换行必然是 `\n` 转义，故裸 LF 只可能是结构空白。
    private static let lineFeedByte: UInt8 = 0x0A

    let pretty: Bool
    /// 文档起始（含第一个成员之前的换行与缩进）。
    let documentOpen: String
    /// 文档收尾（含结尾换行，便于 `cat` 与 diff）。
    let documentClose: String
    /// 顶层成员之间的分隔。
    let memberGap: String
    /// 键与值之间的分隔。
    let keyGap: String
    /// `"items"` 之后、第一个元素之前的起始空白。
    let arrayOpen: String
    /// 元素之间的分隔。
    let itemGap: String
    /// 最后一个元素之后、`]` 之前的收尾空白。
    let arrayClose: String
    /// 单条记录需要补齐的缩进（把 `JSONEncoder` 从 0 列开始的输出推进 items 层级）。
    let itemIndent: String

    init(pretty: Bool) {
        self.pretty = pretty
        if pretty {
            self.documentOpen = "{\n  "
            self.documentClose = "\n}\n"
            self.memberGap = ",\n  "
            self.keyGap = ": "
            self.arrayOpen = "[\n    "
            self.itemGap = ",\n    "
            self.arrayClose = "\n  ]"
            self.itemIndent = "    "
        } else {
            self.documentOpen = "{"
            self.documentClose = "}\n"
            self.memberGap = ","
            self.keyGap = ":"
            self.arrayOpen = "["
            self.itemGap = ","
            self.arrayClose = "]"
            self.itemIndent = ""
        }
    }

    /// 常量 ASCII 骨架片段的 UTF-8 字节（这些片段里没有需要转义的字符，值一律走 `JSONEncoder`）。
    func bytes(_ text: String) -> Data { Data(text.utf8) }

    /// `"name"` + 键值分隔符。顶层键名是本层定义的常量，不需要转义。
    func keyBytes(_ name: String) -> Data { bytes("\"" + name + "\"" + keyGap) }

    /// 把 `JSONEncoder` pretty 输出的单条记录整体缩进到 items 元素层级。
    ///
    /// 只按裸 `0x0A` 插入空白：数据字节里不可能出现裸 LF（UTF-8 续字节均 ≥ 0x80，
    /// JSON 字符串内的换行是 `\n` 转义），因此该变换只动排版、不动内容。
    func indented(_ data: Data) -> Data {
        guard pretty, itemIndent.isEmpty == false else { return data }
        let indent = Data(itemIndent.utf8)
        var result = Data(capacity: data.count + data.count / 4 + 16)
        for byte in data {
            result.append(byte)
            if byte == Self.lineFeedByte { result.append(indent) }
        }
        return result
    }
}

/// 一次 ``JSONExporter/write(records:kind:request:redactor:to:)`` 调用期间的装配。
///
/// 生命周期限于单个函数调用栈，因此不跨隔离域；`JSONEncoder` 在这里只被顺序使用。
/// 全部字符串叶子的脱敏都从这里出发 —— DTO 不直接碰 `ExportRedactor`，避免漏掉某个字段。
private struct JSONExportContext {
    let kind: ExportKind
    /// 运行中会话时长的终点（来自 `request.generatedAt`）。
    let referenceDate: Date
    let dates: ExportDateEncoder
    let redactor: ExportRedactor
    let encoder: JSONEncoder
    let layout: JSONExportLayout

    /// 必选字符串叶子。
    func text(_ value: String) -> String { redactor.redact(value) }

    /// 时间叶子：先 `ExportDateEncoder` 变 ISO8601 字符串，再过脱敏器。
    ///
    /// ISO8601 里不可能藏凭据形态（该变换实际是恒等映射），但「字符串叶子一律过脱敏器」
    /// 这条铁律不留例外，免得将来加字段时漏掉。
    func date(_ value: Date) -> String { redactor.redact(dates.string(value)) }

    /// 可选字符串叶子：`nil` 与空串都落成 JSON `null`（空串占位是 CSV 的语义）。
    func optionalText(_ value: String?) -> String? {
        guard let value, value.isEmpty == false else { return nil }
        return redactor.redact(value)
    }

    /// 可选 UUID：转稳定字符串形式，`nil` → `null`。
    func optionalID(_ value: UUID?) -> String? { optionalText(value?.uuidString) }

    /// 可选时间：ISO8601 字符串（先经 `ExportDateEncoder`，不使用 `dateEncodingStrategy`），
    /// `nil` → `null`。
    func optionalDate(_ value: Date?) -> String? {
        guard let value else { return nil }
        return date(value)
    }

    /// 字符串数组叶子：逐元素脱敏，空数组 → `[]`。
    func textList(_ values: [String]) -> [String] { values.map { redactor.redact($0) } }
}

// MARK: - 导出器

/// 审计记录的 JSON（机读）导出器。
///
/// 输出恒为单个 envelope：`schemaVersion`、`generatedAt`、`exportedBy`、`kind`、`counts`、`items`
/// 六个键按此固定顺序出现，`items` 内是该 `kind` 的全部（过滤后）记录。
public enum JSONExporter {

    // MARK: 公开出口

    /// 流式写出一个 JSON 文档：envelope 手工按固定键序拼装，记录逐条编码、逐条写入。
    ///
    /// 记录先经 `request.filtered(records:for:)`（按 kind 取组 + 时间范围 + 确定性排序 + 截断），
    /// 因此调用方可以整包丢进全部记录；对已过滤过的输入重复调用结果不变。
    /// 空记录集写出 `"items": []`，整体仍是合法 JSON。本函数不调用 `writer.finish()`。
    ///
    /// - Parameters:
    ///   - records: 待导出记录（可混杂多种 kind，只输出与 `kind` 匹配的部分）。
    ///   - kind: 目标记录类型；非记录类（`.report`）抛 ``ExportError/unsupportedCombination(format:kind:)``。
    ///   - request: 导出参数；`generatedAt` 是唯一时间来源，`jsonPrettyPrinted` 决定空白排版。
    ///   - redactor: 生效的脱敏器；每个字符串叶子写出前都过一遍（`.disabled` 时原样保留）。
    ///   - writer: 已就绪的写入器，由调用方负责 `finish()`。
    /// - Throws: ``ExportError/unsupportedCombination(format:kind:)``（`.report`）、
    ///   ``ExportError/encodingFailed(kind:reason:)``（DTO 无法编码为 JSON 文本），
    ///   以及写入器自身的 IO 错误（原样上抛，不吞）。
    public static func write(records: [ExportRecord], kind: ExportKind, request: ExportRequest,
                             redactor: ExportRedactor, to writer: inout ExportWriter) throws {
        guard kind.isRecordKind else {
            throw ExportError.unsupportedCombination(format: .json, kind: kind)
        }
        let scoped = request.filtered(records: records, for: kind)
        let context = JSONExportContext(
            kind: kind,
            referenceDate: request.generatedAt,
            dates: ExportDateEncoder(),
            redactor: redactor,
            encoder: recordEncoder(prettyPrinted: request.jsonPrettyPrinted),
            layout: JSONExportLayout(pretty: request.jsonPrettyPrinted)
        )
        // envelope 标量与 counts 恒为紧凑片段：与记录数组的 pretty 开关无关，便于人眼核对。
        let scalarEncoder = recordEncoder(prettyPrinted: false)
        let layout = context.layout

        try writer.write(layout.bytes(layout.documentOpen))

        try writer.write(layout.keyBytes("schemaVersion"))
        try writer.write(fragment(ExportConstants.schemaVersion, context: context, encoder: scalarEncoder))

        try writer.write(layout.bytes(layout.memberGap))
        try writer.write(layout.keyBytes("generatedAt"))
        try writer.write(fragment(context.dates.string(request.generatedAt), context: context,
                                  encoder: scalarEncoder))

        try writer.write(layout.bytes(layout.memberGap))
        try writer.write(layout.keyBytes("exportedBy"))
        try writer.write(fragment(ExportConstants.exportedBy, context: context, encoder: scalarEncoder))

        try writer.write(layout.bytes(layout.memberGap))
        try writer.write(layout.keyBytes("kind"))
        try writer.write(fragment(kind.rawValue, context: context, encoder: scalarEncoder))

        // counts 只统计真正写出的那一批（与 items 同源，故 total == items.count）。
        let counts = try countsData(for: scoped, context: context, encoder: scalarEncoder)
        try writer.write(layout.bytes(layout.memberGap))
        try writer.write(layout.keyBytes("counts"))
        try writer.write(counts)

        try writer.write(layout.bytes(layout.memberGap))
        try writer.write(layout.keyBytes("items"))
        if scoped.isEmpty {
            try writer.write(layout.bytes("[]"))
        } else {
            try writer.write(layout.bytes(layout.arrayOpen))
            var wroteItem = false
            for record in scoped {
                guard let itemBytes = try itemData(for: record, context: context) else { continue }
                if wroteItem { try writer.write(layout.bytes(layout.itemGap)) }
                wroteItem = true
                try writer.write(itemBytes)
            }
            try writer.write(layout.bytes(layout.arrayClose))
        }

        try writer.write(layout.bytes(layout.documentClose))
    }

    /// 便捷出口：写入 memory sink 后返回完整字节（小数据量与测试用）。
    ///
    /// 与 ``write(records:kind:request:redactor:to:)`` 对同一输入产出**完全相同**的字节。
    ///
    /// - Parameters:
    ///   - records: 待导出记录（可混杂多种 kind）。
    ///   - kind: 目标记录类型；非记录类（`.report`）抛 ``ExportError/unsupportedCombination(format:kind:)``。
    ///   - request: 导出参数（时间、pretty 开关、过滤条件）。
    ///   - redactor: 生效的脱敏器，默认 ``ExportRedactor/standard``。
    /// - Returns: 完整的 JSON 文件内容（合法 JSON，UTF-8）。
    /// - Throws: 同 ``write(records:kind:request:redactor:to:)``；memory sink 只做内存聚合，
    ///   正常不会抛 IO 错误。
    public static func data(records: [ExportRecord], kind: ExportKind, request: ExportRequest,
                            redactor: ExportRedactor = .standard) throws -> Data {
        var writer = ExportWriter.memory()
        try write(records: records, kind: kind, request: request, redactor: redactor, to: &writer)
        try writer.finish()
        return try writer.collectedData()
    }

    // MARK: 编码

    /// 记录编码器：`.sortedKeys` 恒开（键序与 DTO 字段声明顺序无关，跨运行确定），
    /// pretty 由请求决定。
    private static func recordEncoder(prettyPrinted: Bool) -> JSONEncoder {
        let encoder = JSONEncoder()
        var formatting: JSONEncoder.OutputFormatting = [.sortedKeys]
        if prettyPrinted { formatting.insert(.prettyPrinted) }
        encoder.outputFormatting = formatting
        return encoder
    }

    /// 把一个标量 / 字典编码为 JSON 片段（顶层键值、counts）。
    private static func fragment<T: Encodable>(_ value: T, context: JSONExportContext,
                                               encoder: JSONEncoder) throws -> Data {
        do {
            return try encoder.encode(value)
        } catch {
            throw ExportError.encodingFailed(kind: context.kind, reason: describeEncodingError(error))
        }
    }

    /// 单条记录 → DTO → JSON 字节（pretty 模式下补齐缩进）。
    ///
    /// - Returns: 记录类型与 `kind` 不匹配时返回 `nil`（调用方跳过该条）。
    ///   正常路径下 `request.filtered(records:for:)` 已保证匹配。
    private static func itemData(for record: ExportRecord, context: JSONExportContext) throws -> Data? {
        switch context.kind {
        case .sessions:
            guard let model = record.session else { return nil }
            return try encodeDTO(ExportSessionDTO(model, context: context), context: context)
        case .timeline:
            guard let model = record.event else { return nil }
            return try encodeDTO(ExportEventDTO(model, context: context), context: context)
        case .fileChanges:
            guard let model = record.fileChange else { return nil }
            return try encodeDTO(ExportFileChangeDTO(model, context: context), context: context)
        case .commands:
            guard let model = record.command else { return nil }
            return try encodeDTO(ExportCommandDTO(model, context: context), context: context)
        case .riskEvents:
            guard let model = record.riskEvent else { return nil }
            return try encodeDTO(ExportRiskEventDTO(model, context: context), context: context)
        case .report:
            throw ExportError.unsupportedCombination(format: .json, kind: .report)
        }
    }

    /// DTO → 文本字节，并把底层编码错误转成携带 kind 的 ``ExportError/encodingFailed(kind:reason:)``。
    private static func encodeDTO<T: Encodable>(_ dto: T, context: JSONExportContext) throws -> Data {
        do {
            return context.layout.indented(try context.encoder.encode(dto))
        } catch {
            throw ExportError.encodingFailed(kind: context.kind, reason: describeEncodingError(error))
        }
    }

    // MARK: counts

    /// `{"total":N,"byAgentKind":{...},"byRiskLevel":{...}}`。
    ///
    /// 只列出出现过的键（空切片时为 `{}`），字典键序由 `.sortedKeys` 决定 → 字节确定。
    private static func countsData(for records: [ExportRecord], context: JSONExportContext,
                                  encoder: JSONEncoder) throws -> Data {
        var byAgentKind: [String: Int] = [:]
        var byRiskLevel: [String: Int] = [:]
        byAgentKind.reserveCapacity(records.count)
        byRiskLevel.reserveCapacity(records.count)
        for record in records {
            byAgentKind[record.agentKind.rawValue, default: 0] += 1
            byRiskLevel[record.riskLevel.rawValue, default: 0] += 1
        }
        let total = try fragment(records.count, context: context, encoder: encoder)
        let agents = try fragment(byAgentKind, context: context, encoder: encoder)
        let risks = try fragment(byRiskLevel, context: context, encoder: encoder)
        let layout = context.layout
        var result = layout.bytes(#"{"total":"#)
        result.append(total)
        result.append(layout.bytes(#","byAgentKind":"#))
        result.append(agents)
        result.append(layout.bytes(#","byRiskLevel":"#))
        result.append(risks)
        result.append(layout.bytes("}"))
        return result
    }

    // MARK: 诊断

    /// 底层错误 → 简短原因串（`localizedDescription` 为空时退回 `String(describing:)`）。
    private static func describeEncodingError(_ error: Error) -> String {
        let localized = error.localizedDescription
        return localized.isEmpty ? String(describing: error) : localized
    }
}

// MARK: - DTO

/// `.sessions` 的 JSON 形态。显式 `CodingKeys`，键名与 `ExportSchema` 列名一一对应。
private struct ExportSessionDTO: Encodable {
    let sessionID: String
    let displayIndex: Int
    let agentKind: String
    let title: String
    let projectPath: String?
    let startedAt: String
    let endedAt: String?
    let durationSeconds: Double
    let outcome: String
    let modifiedFiles: Int
    let createdFiles: Int
    let deletedFiles: Int
    let commands: Int
    let failedCommands: Int
    let cpuSeconds: Double
    let peakCPUPercent: Double
    let peakMemoryBytes: UInt64
    let estimatedTokens: Int
    let riskEvents: Int

    enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case displayIndex = "display_index"
        case agentKind = "agent_kind"
        case title
        case projectPath = "project_path"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case durationSeconds = "duration_seconds"
        case outcome
        case modifiedFiles = "modified_files"
        case createdFiles = "created_files"
        case deletedFiles = "deleted_files"
        case commands
        case failedCommands = "failed_commands"
        case cpuSeconds = "cpu_seconds"
        case peakCPUPercent = "peak_cpu_percent"
        case peakMemoryBytes = "peak_memory_bytes"
        case estimatedTokens = "estimated_tokens"
        case riskEvents = "risk_events"
    }

    /// 手写 encode：编译器合成版本对 nil 可选值走 `encodeIfPresent` 会省略键，
    /// 破坏「缺失 → 显式 `null`、每条 item 键集合恒等于 ExportSchema 字段名」契约 —— 勿退回合成版。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.displayIndex, forKey: .displayIndex)
        try container.encode(self.agentKind, forKey: .agentKind)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.projectPath, forKey: .projectPath)
        try container.encode(self.startedAt, forKey: .startedAt)
        try container.encode(self.endedAt, forKey: .endedAt)
        try container.encode(self.durationSeconds, forKey: .durationSeconds)
        try container.encode(self.outcome, forKey: .outcome)
        try container.encode(self.modifiedFiles, forKey: .modifiedFiles)
        try container.encode(self.createdFiles, forKey: .createdFiles)
        try container.encode(self.deletedFiles, forKey: .deletedFiles)
        try container.encode(self.commands, forKey: .commands)
        try container.encode(self.failedCommands, forKey: .failedCommands)
        try container.encode(self.cpuSeconds, forKey: .cpuSeconds)
        try container.encode(self.peakCPUPercent, forKey: .peakCPUPercent)
        try container.encode(self.peakMemoryBytes, forKey: .peakMemoryBytes)
        try container.encode(self.estimatedTokens, forKey: .estimatedTokens)
        try container.encode(self.riskEvents, forKey: .riskEvents)
    }

    /// 由 Core 模型装配。
    ///
    /// - Parameters:
    ///   - session: 会话模型（字段唯一真相）。
    ///   - context: 本次导出的装配（注入时间 / 日期编码器 / 脱敏器）。
    init(_ session: AgentSession, context: JSONExportContext) {
        self.sessionID = context.text(session.id.uuidString)
        self.displayIndex = session.displayIndex
        self.agentKind = context.text(session.kind.rawValue)
        self.title = context.text(session.title)
        self.projectPath = context.optionalText(session.projectPath)
        self.startedAt = context.date(session.startedAt)
        // 未结束的会话 → null（不是空串）；运行中时长用注入的 generatedAt 算，绝不读墙钟。
        self.endedAt = context.optionalDate(session.endedAt)
        self.durationSeconds = session.duration(until: context.referenceDate)
        self.outcome = context.text(session.outcome.rawValue)
        self.modifiedFiles = session.modifiedFileCount
        self.createdFiles = session.createdFileCount
        self.deletedFiles = session.deletedFileCount
        self.commands = session.commandCount
        self.failedCommands = session.failedCommandCount
        self.cpuSeconds = session.cpuSeconds
        self.peakCPUPercent = session.peakCPUPercent
        self.peakMemoryBytes = session.peakMemoryBytes
        self.estimatedTokens = session.estimatedTokens
        self.riskEvents = session.riskEventCount
    }
}

/// `.timeline` 的 JSON 形态。
private struct ExportEventDTO: Encodable {
    let eventID: String
    let timestamp: String
    let sessionID: String?
    let agentKind: String
    let operationKind: String
    let title: String
    let summary: String
    let filePath: String?
    let command: String?
    let exitCode: Int?
    let durationSeconds: Double?
    let riskLevel: String
    let projectPath: String?
    let cpuSeconds: Double
    let memoryBytes: UInt64
    let bytesRead: UInt64
    let bytesWritten: UInt64

    enum CodingKeys: String, CodingKey {
        case eventID = "event_id"
        case timestamp
        case sessionID = "session_id"
        case agentKind = "agent_kind"
        case operationKind = "operation_kind"
        case title
        case summary
        case filePath = "file_path"
        case command
        case exitCode = "exit_code"
        case durationSeconds = "duration_seconds"
        case riskLevel = "risk_level"
        case projectPath = "project_path"
        case cpuSeconds = "cpu_seconds"
        case memoryBytes = "memory_bytes"
        case bytesRead = "bytes_read"
        case bytesWritten = "bytes_written"
    }

    /// 手写 encode：合成版本会省略 nil 键，破坏「缺失 → 显式 null」契约 —— 勿退回合成版。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.eventID, forKey: .eventID)
        try container.encode(self.timestamp, forKey: .timestamp)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.agentKind, forKey: .agentKind)
        try container.encode(self.operationKind, forKey: .operationKind)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.summary, forKey: .summary)
        try container.encode(self.filePath, forKey: .filePath)
        try container.encode(self.command, forKey: .command)
        try container.encode(self.exitCode, forKey: .exitCode)
        try container.encode(self.durationSeconds, forKey: .durationSeconds)
        try container.encode(self.riskLevel, forKey: .riskLevel)
        try container.encode(self.projectPath, forKey: .projectPath)
        try container.encode(self.cpuSeconds, forKey: .cpuSeconds)
        try container.encode(self.memoryBytes, forKey: .memoryBytes)
        try container.encode(self.bytesRead, forKey: .bytesRead)
        try container.encode(self.bytesWritten, forKey: .bytesWritten)
    }

    /// 由 Core 模型装配。
    ///
    /// - Parameters:
    ///   - event: 时间线事件模型。
    ///   - context: 本次导出的装配。
    init(_ event: TimelineEvent, context: JSONExportContext) {
        self.eventID = context.text(event.id.uuidString)
        self.timestamp = context.date(event.timestamp)
        self.sessionID = context.optionalID(event.sessionID)
        self.agentKind = context.text(event.agentKind.rawValue)
        self.operationKind = context.text(event.kind.rawValue)
        self.title = context.text(event.title)
        self.summary = context.text(event.summary)
        self.filePath = context.optionalText(event.filePath)
        self.command = context.optionalText(event.command)
        self.exitCode = event.exitCode.map(Int.init)
        self.durationSeconds = event.durationSeconds
        self.riskLevel = context.text(event.riskLevel.rawValue)
        self.projectPath = context.optionalText(event.projectPath)
        self.cpuSeconds = event.cost.cpuSeconds
        self.memoryBytes = event.cost.memoryBytes
        self.bytesRead = event.cost.bytesRead
        self.bytesWritten = event.cost.bytesWritten
    }
}

/// `.fileChanges` 的 JSON 形态。
private struct ExportFileChangeDTO: Encodable {
    let changeID: String
    let timestamp: String
    let path: String
    let previousPath: String?
    let changeKind: String
    let agentKind: String
    let sessionID: String?
    let sizeBytes: UInt64
    let previousSizeBytes: UInt64?
    let isText: Bool
    let linesAdded: Int
    let linesRemoved: Int
    let riskLevel: String
    let projectPath: String?

    enum CodingKeys: String, CodingKey {
        case changeID = "change_id"
        case timestamp
        case path
        case previousPath = "previous_path"
        case changeKind = "change_kind"
        case agentKind = "agent_kind"
        case sessionID = "session_id"
        case sizeBytes = "size_bytes"
        case previousSizeBytes = "previous_size_bytes"
        case isText = "is_text"
        case linesAdded = "lines_added"
        case linesRemoved = "lines_removed"
        case riskLevel = "risk_level"
        case projectPath = "project_path"
    }

    /// 手写 encode：合成版本会省略 nil 键，破坏「缺失 → 显式 null」契约 —— 勿退回合成版。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.changeID, forKey: .changeID)
        try container.encode(self.timestamp, forKey: .timestamp)
        try container.encode(self.path, forKey: .path)
        try container.encode(self.previousPath, forKey: .previousPath)
        try container.encode(self.changeKind, forKey: .changeKind)
        try container.encode(self.agentKind, forKey: .agentKind)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.sizeBytes, forKey: .sizeBytes)
        try container.encode(self.previousSizeBytes, forKey: .previousSizeBytes)
        try container.encode(self.isText, forKey: .isText)
        try container.encode(self.linesAdded, forKey: .linesAdded)
        try container.encode(self.linesRemoved, forKey: .linesRemoved)
        try container.encode(self.riskLevel, forKey: .riskLevel)
        try container.encode(self.projectPath, forKey: .projectPath)
    }

    /// 由 Core 模型装配。
    ///
    /// - Parameters:
    ///   - change: 文件变更模型。
    ///   - context: 本次导出的装配。
    init(_ change: FileChange, context: JSONExportContext) {
        self.changeID = context.text(change.id.uuidString)
        self.timestamp = context.date(change.timestamp)
        self.path = context.text(change.path)
        self.previousPath = context.optionalText(change.previousPath)
        self.changeKind = context.text(change.kind.rawValue)
        self.agentKind = context.text(change.agentKind.rawValue)
        self.sessionID = context.optionalID(change.sessionID)
        self.sizeBytes = change.sizeBytes
        self.previousSizeBytes = change.previousSizeBytes
        self.isText = change.isText
        self.linesAdded = change.linesAdded
        self.linesRemoved = change.linesRemoved
        self.riskLevel = context.text(change.riskLevel.rawValue)
        self.projectPath = context.optionalText(change.projectPath)
    }
}

/// `.commands` 的 JSON 形态。`arguments` 保留为字符串数组（逐元素脱敏）。
private struct ExportCommandDTO: Encodable {
    let commandID: String
    let startedAt: String
    let endedAt: String?
    let executable: String
    let arguments: [String]
    let commandLine: String
    let workingDirectory: String?
    let agentKind: String
    let sessionID: String?
    let exitCode: Int?
    let outcome: String
    let isDestructive: Bool
    let requiresConfirmation: Bool
    let riskLevel: String
    let projectPath: String?

    enum CodingKeys: String, CodingKey {
        case commandID = "command_id"
        case startedAt = "started_at"
        case endedAt = "ended_at"
        case executable
        case arguments
        case commandLine = "command_line"
        case workingDirectory = "working_directory"
        case agentKind = "agent_kind"
        case sessionID = "session_id"
        case exitCode = "exit_code"
        case outcome
        case isDestructive = "is_destructive"
        case requiresConfirmation = "requires_confirmation"
        case riskLevel = "risk_level"
        case projectPath = "project_path"
    }

    /// 手写 encode：合成版本会省略 nil 键，破坏「缺失 → 显式 null」契约 —— 勿退回合成版。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.commandID, forKey: .commandID)
        try container.encode(self.startedAt, forKey: .startedAt)
        try container.encode(self.endedAt, forKey: .endedAt)
        try container.encode(self.executable, forKey: .executable)
        try container.encode(self.arguments, forKey: .arguments)
        try container.encode(self.commandLine, forKey: .commandLine)
        try container.encode(self.workingDirectory, forKey: .workingDirectory)
        try container.encode(self.agentKind, forKey: .agentKind)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.exitCode, forKey: .exitCode)
        try container.encode(self.outcome, forKey: .outcome)
        try container.encode(self.isDestructive, forKey: .isDestructive)
        try container.encode(self.requiresConfirmation, forKey: .requiresConfirmation)
        try container.encode(self.riskLevel, forKey: .riskLevel)
        try container.encode(self.projectPath, forKey: .projectPath)
    }

    /// 由 Core 模型装配。
    ///
    /// - Parameters:
    ///   - command: 命令记录模型。
    ///   - context: 本次导出的装配。
    init(_ command: CommandRecord, context: JSONExportContext) {
        self.commandID = context.text(command.id.uuidString)
        self.startedAt = context.date(command.startedAt)
        self.endedAt = context.optionalDate(command.endedAt)
        self.executable = context.text(command.executable)
        self.arguments = context.textList(command.arguments)
        self.commandLine = context.text(command.commandLine)
        self.workingDirectory = context.optionalText(command.workingDirectory)
        self.agentKind = context.text(command.agentKind.rawValue)
        self.sessionID = context.optionalID(command.sessionID)
        self.exitCode = command.exitCode.map(Int.init)
        self.outcome = context.text(command.outcome.rawValue)
        self.isDestructive = command.isDestructive
        self.requiresConfirmation = command.requiresConfirmation
        self.riskLevel = context.text(command.riskLevel.rawValue)
        self.projectPath = context.optionalText(command.projectPath)
    }
}

/// `.riskEvents` 的 JSON 形态。
private struct ExportRiskEventDTO: Encodable {
    let riskID: String
    let timestamp: String
    let level: String
    let category: String
    let title: String
    let detail: String
    let agentKind: String
    let sessionID: String?
    let command: String?
    let filePaths: [String]
    let requiresConfirmation: Bool
    let isAcknowledged: Bool
    let matchedRuleID: String?

    enum CodingKeys: String, CodingKey {
        case riskID = "risk_id"
        case timestamp
        case level
        case category
        case title
        case detail
        case agentKind = "agent_kind"
        case sessionID = "session_id"
        case command
        case filePaths = "file_paths"
        case requiresConfirmation = "requires_confirmation"
        case isAcknowledged = "is_acknowledged"
        case matchedRuleID = "matched_rule_id"
    }

    /// 手写 encode：合成版本会省略 nil 键，破坏「缺失 → 显式 null」契约 —— 勿退回合成版。
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.riskID, forKey: .riskID)
        try container.encode(self.timestamp, forKey: .timestamp)
        try container.encode(self.level, forKey: .level)
        try container.encode(self.category, forKey: .category)
        try container.encode(self.title, forKey: .title)
        try container.encode(self.detail, forKey: .detail)
        try container.encode(self.agentKind, forKey: .agentKind)
        try container.encode(self.sessionID, forKey: .sessionID)
        try container.encode(self.command, forKey: .command)
        try container.encode(self.filePaths, forKey: .filePaths)
        try container.encode(self.requiresConfirmation, forKey: .requiresConfirmation)
        try container.encode(self.isAcknowledged, forKey: .isAcknowledged)
        try container.encode(self.matchedRuleID, forKey: .matchedRuleID)
    }

    /// 由 Core 模型装配。
    ///
    /// - Parameters:
    ///   - risk: 风险事件模型。
    ///   - context: 本次导出的装配。
    init(_ risk: RiskEvent, context: JSONExportContext) {
        self.riskID = context.text(risk.id.uuidString)
        self.timestamp = context.date(risk.timestamp)
        self.level = context.text(risk.level.rawValue)
        self.category = context.text(risk.category.rawValue)
        self.title = context.text(risk.title)
        self.detail = context.text(risk.detail)
        self.agentKind = context.text(risk.agentKind.rawValue)
        self.sessionID = context.optionalID(risk.sessionID)
        self.command = context.optionalText(risk.command)
        self.filePaths = context.textList(risk.filePaths)
        self.requiresConfirmation = risk.requiresConfirmation
        self.isAcknowledged = risk.isAcknowledged
        self.matchedRuleID = context.optionalText(risk.matchedRuleID)
    }
}
