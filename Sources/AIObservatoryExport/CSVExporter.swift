//
//  CSVExporter.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（子代理 B）
//
//  RFC 4180 CSV 写出器：给 Excel / Numbers 直接打开的审计表。
//
//  设计约束（对齐《导出层接口》§0 铁律 + §2B 契约）：
//   · 表头与列取值全部来自 `ExportColumn`（ExportSchema 是唯一真相），本文件不硬编码列名；
//   · 列定义**不脱敏**，脱敏在本导出器写出前对每个单元统一施加（`redactor` 参数驱动）；
//   · 逐行调用 `ExportWriter.write(_:)`，绝不在内存里拼完整文档（大输入靠写入器分块）；
//   · 行尾恒为 `\r\n`（含最后一行），因此同输入 → 同字节，跨平台一致；
//   · 绝不读墙钟：时间只来自 `request.generatedAt` / 列定义注入的 referenceDate；
//   · 手写转义：只按 `,` `"` CR LF 四个标量判定，不用任何 CSV 黑盒 API。
//

import Foundation

/// 审计记录的 CSV（RFC 4180）导出器。
public enum CSVExporter {
    // MARK: - 常量（RFC 4180 的四个「必须加引号」标量按数值写死，避开 grapheme cluster 陷阱）

    /// 字段分隔符。
    private static let separator: Character = ","
    /// 行尾：统一 CRLF，Excel/Numbers 与 POSIX 工具都能读。
    private static let lineEnding = "\r\n"
    /// `,`
    private static let commaValue: UInt32 = 0x2C
    /// `"`
    private static let quoteValue: UInt32 = 0x22
    /// CR
    private static let carriageReturnValue: UInt32 = 0x0D
    /// LF
    private static let lineFeedValue: UInt32 = 0x0A
    /// UTF-8 BOM：Excel 靠它把无 BOM 的中文 CSV 认成 UTF-8（开关来自 `request.csvIncludesByteOrderMark`）。
    private static let utf8ByteOrderMark: [UInt8] = [0xEF, 0xBB, 0xBF]

    // MARK: - 单元转义

    /// 单个 CSV 字段的 RFC 4180 转义。
    ///
    /// 含 `,` `"` CR LF 任一字符时整体用 `"` 包裹，并把内部每个 `"` 双写成 `""`；
    /// 不含这些字符时**原样返回**（`\t` 不需要引号，往返也不丢失）。
    /// - Parameter field: 未转义的原始文本。
    /// - Returns: 可直接落盘的 CSV 单元文本。
    public static func escape(_ field: String) -> String {
        // requiresQuoting 按 UTF-32 标量判定：`"\r\n"` 在 Swift 里是**一个** Character
        // （UAX #29 规则 GB3），若按 Character 迭代，CR 与 LF 会被同一个 Character 吞掉而漏判。
        guard requiresQuoting(field) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 把若干字段拼成一行 CSV，**结尾已含 `\r\n`**。
    ///
    /// 每个字段都会经 `escape(_:)`，因此调用方只需传未转义的原始值。
    /// - Parameter fields: 同一行的全部单元（顺序即列顺序）。
    /// - Returns: 形如 `a,"b,c"\r\n` 的单行文本。
    public static func row(_ fields: [String]) -> String {
        var estimated = fields.count * 4 + lineEnding.utf8.count
        for field in fields { estimated += field.utf8.count }
        var result = ""
        result.reserveCapacity(estimated)
        for (index, field) in fields.enumerated() {
            if index > 0 { result.append(separator) }
            result.append(escape(field))
        }
        result.append(lineEnding)
        return result
    }

    // MARK: - 流式写出

    /// 流式写出一个 CSV 表：BOM（可选）+ 表头 + 每条记录一行。
    ///
    /// 记录先经 `request.filtered(records:for:)`（按 kind 取组 + 时间范围 + 确定性排序 + 截断），
    /// 因此调用方可以整包丢进全部记录；对已经过滤过的输入重复调用结果不变。
    /// 每行调用一次 `writer.write(_:)`，本函数不在内存里累积整个文档。
    /// - Parameters:
    ///   - records: 待导出记录（可混杂多种 kind，只取与 `kind` 匹配的部分）。
    ///   - kind: 目标表类型；非记录类（`.report`）抛 `ExportError.unsupportedCombination`。
    ///   - request: 导出参数（BOM 开关、时间范围、上限、注入时间）。
    ///   - redactor: 生效的脱敏器；每个单元值都过一遍，列定义本身不脱敏。
    ///   - columns: 实际写出的列（顺序即表头顺序）；空数组抛 `ExportError.invalidRequest`。
    ///   - writer: 已就绪的写入器，由调用方负责 `finish()`。
    public static func write(records: [ExportRecord], kind: ExportKind, request: ExportRequest,
                             redactor: ExportRedactor, columns: [ExportColumn],
                             to writer: inout ExportWriter) throws {
        guard kind.isRecordKind else { throw ExportError.unsupportedCombination(format: .csv, kind: kind) }
        guard !columns.isEmpty else {
            throw ExportError.invalidRequest(ExportCopy.reasonCSVNeedsColumns.renderedNow(kind.rawValue))
        }

        if request.csvIncludesByteOrderMark {
            // 必须是文件最前 3 字节，且整个文档只出现这一次。
            try writer.write(Data(utf8ByteOrderMark))
        }

        // 表头 = 所选列的 title，与数据行同样过 escape。
        try writer.write(row(columns.map { $0.title }))

        let scoped = request.filtered(records: records, for: kind)
        for record in scoped {
            var cells: [String] = []
            cells.reserveCapacity(columns.count)
            for column in columns {
                // 记录类型与列不匹配时列自身返回 ExportConstants.missingValue，无需强解包。
                cells.append(redactor.redact(column.value(record)))
            }
            try writer.write(row(cells))
        }
    }

    /// 便捷出口：一次调用拿到完整 CSV 字节（内存 sink，走默认分块阈值）。
    ///
    /// 与 `write(records:kind:request:redactor:columns:to:)` 对同一输入产出**完全相同**的字节。
    /// - Parameters:
    ///   - records: 待导出记录（可混杂多种 kind）。
    ///   - kind: 目标表类型。
    ///   - request: 导出参数；`columns == nil` 时列选择来自 `request.columns(for: kind)`。
    ///   - redactor: 生效的脱敏器，默认 `.standard`。
    ///   - columns: 显式列覆盖，`nil` 表示按请求选择。
    /// - Returns: 完整的 CSV 文件内容。
    public static func data(records: [ExportRecord], kind: ExportKind, request: ExportRequest,
                            redactor: ExportRedactor = .standard,
                            columns: [ExportColumn]? = nil) throws -> Data {
        guard kind.isRecordKind else { throw ExportError.unsupportedCombination(format: .csv, kind: kind) }
        let resolvedColumns: [ExportColumn]
        if let columns {
            resolvedColumns = columns
        } else {
            resolvedColumns = try request.columns(for: kind)
        }
        var writer = ExportWriter.memory()
        try write(records: records, kind: kind, request: request, redactor: redactor,
                  columns: resolvedColumns, to: &writer)
        try writer.finish()
        return try writer.collectedData()
    }

    // MARK: - 私有工具

    /// 是否需要整体加引号：只看 RFC 4180 的四个字符。
    private static func requiresQuoting(_ field: String) -> Bool {
        for scalar in field.unicodeScalars where isSpecialScalar(scalar) { return true }
        return false
    }

    /// 标量是否为 `,` `"` CR LF 之一。
    private static func isSpecialScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        return value == commaValue || value == quoteValue
            || value == carriageReturnValue || value == lineFeedValue
    }
}
