//
//  ExportRequest.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（主代理 · 共享脊柱，子代理只读）
//

import Foundation
import AIObservatoryCore

/// 输出落点。`allowedRoots` 必填 —— 导出层永不猜测用户能写哪里，
/// 也因此可以拒绝 `~`、`/System`、`/` 这类越界目标。
public struct ExportDestination: Sendable, Hashable {
    public var directory: URL
    public var baseName: String
    public var allowedRoots: [URL]

    public init(directory: URL, baseName: String = "ai-observatory", allowedRoots: [URL]) {
        self.directory = directory
        self.baseName = baseName
        self.allowedRoots = allowedRoots
    }

    /// `<directory>/<baseName>-<kind>[-report]-<stamp>.<ext>`
    public func fileURL(for kind: ExportKind, format: ExportFormat, stamp: String) -> URL {
        let suffix = kind == .report ? "report" : kind.defaultFileName
        let name = "\(baseName)-\(suffix)-\(stamp).\(format.fileExtension)"
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}

/// 一次导出请求的全部参数。
///
/// `generatedAt` 由调用方注入（默认 `Date()`）：测试传固定时间即可获得字节可重现的输出。
public struct ExportRequest: Sendable, Hashable {
    public var format: ExportFormat
    /// 记录类 kind 列表；`.report` 只能与 `.markdown` 一起出现。
    public var kinds: [ExportKind]
    /// `nil` = 全字段；否则按 `ExportSchema` 校验并保序。
    public var selectedFieldNames: [String]?
    public var dateRange: DateRangeFilter
    public var maximumRecordsPerKind: Int?
    public var generatedAt: Date
    public var redactionEnabled: Bool
    /// #64：演示/脉敏输出的**路径映射**，随请求一路带下去（与 `interfaceLanguage` 同一种装配）。
    /// 默认 `.off` = 恒等 ⇒ 不显式传就和今天逐字一致；开关的真值由装配点从启动设置解析。
    public var pathMask: PathPrivacy.Mask
    public var csvIncludesByteOrderMark: Bool
    public var jsonPrettyPrinted: Bool
    public var destination: ExportDestination
    /// **人读产物（Markdown 报告）的正文语言**，在请求构造时定死、随请求一路带下去，
    /// 落盘后不再回改（IFR 裁定 2）。默认取进程当前语言；装配点要别的语言就显式传。
    /// JSON / CSV 不受它影响：那两种是机器可读的，列名与 rawValue 恒为 ASCII。
    public var interfaceLanguage: AppLanguage

    public init(
        format: ExportFormat,
        kinds: [ExportKind],
        selectedFieldNames: [String]? = nil,
        dateRange: DateRangeFilter = .unbounded,
        maximumRecordsPerKind: Int? = nil,
        generatedAt: Date = Date(),
        redactionEnabled: Bool = true,
        pathMask: PathPrivacy.Mask = .off,
        csvIncludesByteOrderMark: Bool = false,
        jsonPrettyPrinted: Bool = true,
        interfaceLanguage: AppLanguage = .resolved(),
        destination: ExportDestination
    ) {
        self.format = format
        self.kinds = kinds
        self.selectedFieldNames = selectedFieldNames
        self.dateRange = dateRange
        self.maximumRecordsPerKind = maximumRecordsPerKind
        self.generatedAt = generatedAt
        self.redactionEnabled = redactionEnabled
        self.pathMask = pathMask
        self.csvIncludesByteOrderMark = csvIncludesByteOrderMark
        self.jsonPrettyPrinted = jsonPrettyPrinted
        self.interfaceLanguage = interfaceLanguage
        self.destination = destination
    }

    /// 按 `redactionEnabled` 生效的脱敏器由调用方（`ExportCoordinator`）解析后注入，
    /// 本文件不引用 `ExportRedactor`，以保持脊柱独立可编译。
    ///
    /// 单文件导出时使用的文件名时间戳。
    public var fileStamp: String { ExportDateEncoder().fileStamp(generatedAt) }

    public func validate() throws {
        guard !kinds.isEmpty else { throw ExportError.invalidRequest(ExportCopy.reasonEmptyKinds.text()) }
        if let limit = maximumRecordsPerKind, limit < 0 {
            throw ExportError.invalidRequest(ExportCopy.reasonNegativeLimit.text())
        }
        if let names = selectedFieldNames, names.isEmpty {
            throw ExportError.invalidRequest(ExportCopy.reasonEmptySelectedFields.text())
        }
        for kind in kinds where !kind.supportedFormats.contains(format) {
            throw ExportError.unsupportedCombination(format: format, kind: kind)
        }
    }

    /// 过滤 + 确定性排序 + 截断：CSV / JSON / Markdown 共用，三者记录顺序因此一致。
    public func filtered(records: [ExportRecord], for kind: ExportKind) -> [ExportRecord] {
        var slice = records.filter { $0.kind == kind && dateRange.contains($0.timestamp) }
        slice.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp < rhs.timestamp }
            return lhs.stableIdentifier < rhs.stableIdentifier
        }
        if let limit = maximumRecordsPerKind {
            // 保留最近的 limit 条（时间倒序取，再还原升序），与 UI 的 newestFirst 语义一致。
            if limit >= 0, slice.count > limit {
                slice = Array(slice.suffix(limit))
            }
        }
        return slice
    }

    /// 该 kind 实际要写出的列。默认以 `generatedAt` 作为运行中会话的时长终点（不读墙钟）。
    public func columns(for kind: ExportKind, referenceDate: Date? = nil) throws -> [ExportColumn] {
        try ExportSchema.columns(for: kind, selected: selectedFieldNames,
                                referenceDate: referenceDate ?? generatedAt)
    }
}
