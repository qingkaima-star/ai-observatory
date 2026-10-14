//
//  ExportDiagnostics.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（主代理 · 共享脊柱，子代理只读）
//
//  错误按「可恢复 / 不可恢复」分区：可恢复项由调用方（UI 或命令行）提示用户修正，
//  不可恢复项必须原样向上抛，禁止在任何导出器里 catch 后忽略。
//

import Foundation
import AIObservatoryCore

/// 导出层错误。全部携带可定位的上下文（路径 / 字段名 / kind）。
public enum ExportError: Error, Sendable, Hashable, LocalizedError {
    // MARK: 可恢复（调用方可修正后重试）

    /// 选择了该 kind 不存在的字段。
    case unknownFieldName(field: String, kind: ExportKind)
    /// `.report` 没有列式字段，不能做字段选择。
    case unsupportedFieldSelection(kind: ExportKind)
    /// 过滤后没有任何记录（导出仍会产出表头/空数组，此错误供严格模式使用）。
    case emptySelection(kind: ExportKind)
    /// 该 kind 不支持该格式（如 `.report` 用 CSV）。
    case unsupportedCombination(format: ExportFormat, kind: ExportKind)
    /// 请求本身不合法（空 kinds、负数上限等）。
    case invalidRequest(String)
    /// 脱敏器内部失败；调用方可选择 `redactionEnabled = false` 重试，但必须显式确认风险。
    case redactionFailed(reason: String)

    // MARK: 不可恢复（环境 / IO）

    /// 目标路径被禁止（家目录、`~/…` 未展开形式、`/System`、`/` 等）。
    case pathForbidden(String)
    /// 目标路径落在允许的根目录之外。
    case pathOutsideAllowedRoots(path: String, roots: [String])
    /// 无法创建文件或父目录。
    case cannotCreateFile(path: String, reason: String)
    /// 文件已创建但拿不到写入句柄。
    case cannotOpenFileHandle(path: String)
    /// 写入失败（磁盘满 / 权限）。
    case writeFailed(path: String, bytes: Int, reason: String)
    /// 编码失败（DTO → JSON）。
    case encodingFailed(kind: ExportKind, reason: String)
    /// 写入器已 finish，禁止继续写。
    case alreadyFinished(path: String)

    /// 是否可由调用方修正后重试。
    public var isRecoverable: Bool {
        switch self {
        case .unknownFieldName, .unsupportedFieldSelection, .emptySelection,
             .unsupportedCombination, .invalidRequest, .redactionFailed:
            return true
        case .pathForbidden, .pathOutsideAllowedRoots, .cannotCreateFile,
             .cannotOpenFileHandle, .writeFailed, .encodingFailed, .alreadyFinished:
            return false
        }
    }

    /// 修正建议。⚠️ 当前**零消费者**（`localizedDescription` 不含它，App 弹框只取
    /// `errorDescription`），内容也是给读代码的人用的指令 ⇒ 翻它不是为了现在显示，
    /// 而是让"将来要上屏的提示"从第一天就是双语的。登记在 ``ExportCopy`` 的
    /// `export.suggest.*` 13 条里，门禁一样管它们。
    public var recoverySuggestion: String {
        let language = AppLanguage.resolved()
        switch self {
        case let .unknownFieldName(field, kind):
            return ExportCopy.suggestUnknownFieldName.format(language, kind.rawValue, field)
        case let .unsupportedFieldSelection(kind):
            return ExportCopy.suggestUnsupportedFieldSelection.format(language, kind.rawValue)
        case let .emptySelection(kind):
            return ExportCopy.suggestEmptySelection.format(language, kind.rawValue)
        case let .unsupportedCombination(format, kind):
            return ExportCopy.suggestUnsupportedCombination.format(
                language, kind.rawValue, format.rawValue,
                kind.supportedFormats.map(\.rawValue).joined(separator: "/")
            )
        case let .invalidRequest(why):
            return ExportCopy.suggestInvalidRequest.format(language, why)
        case let .redactionFailed(reason):
            return ExportCopy.suggestRedactionFailed.format(language, reason)
        case let .pathForbidden(path):
            return ExportCopy.suggestPathForbidden.format(language, path)
        case let .pathOutsideAllowedRoots(path, roots):
            return ExportCopy.suggestPathOutsideAllowedRoots.format(language, path, roots.joined(separator: ", "))
        case let .cannotCreateFile(path, reason):
            return ExportCopy.suggestCannotCreateFile.format(language, path, reason)
        case let .cannotOpenFileHandle(path):
            return ExportCopy.suggestCannotOpenFileHandle.format(language, path)
        case let .writeFailed(path, bytes, reason):
            return ExportCopy.suggestWriteFailed.format(language, ExportText.integer(bytes), path, reason)
        case let .encodingFailed(kind, reason):
            return ExportCopy.suggestEncodingFailed.format(language, kind.rawValue, reason)
        case let .alreadyFinished(path):
            return ExportCopy.suggestAlreadyFinished.format(language, path)
        }
    }

    /// 用户可见的错误句：`AIObservatoryApp/ObservatoryExporting.swift` 把它塞进
    /// `NSAlert.informativeText` ⇒ **显示时**按进程语言取（错误不入库，切语言即生效）。
    ///
    /// 与 `recoverySuggestion` 的分工：那里是「请从 `ExportSchema.fieldNames(for:)` 选字段」
    /// 这类只有读代码的人才用得上的指令，且全仓零消费者（`localizedDescription` 不含它）
    /// ⇒ 不翻，理由记在交付块。
    public var errorDescription: String? {
        let language = AppLanguage.resolved()
        switch self {
        case let .unknownFieldName(field, kind):
            return ExportCopy.errorUnknownFieldName.format(language, kind.rawValue, field)
        case let .unsupportedFieldSelection(kind):
            return ExportCopy.errorUnsupportedFieldSelection.format(language, kind.rawValue)
        case let .emptySelection(kind):
            return ExportCopy.errorEmptySelection.format(language, kind.rawValue)
        case let .unsupportedCombination(format, kind):
            return ExportCopy.errorUnsupportedCombination.format(language, kind.rawValue, format.rawValue)
        case let .invalidRequest(why):
            return ExportCopy.errorInvalidRequest.format(language, why)
        case let .redactionFailed(reason):
            return ExportCopy.errorRedactionFailed.format(language, reason)
        case let .pathForbidden(path):
            return ExportCopy.errorPathForbidden.format(language, path)
        case let .pathOutsideAllowedRoots(path, _):
            return ExportCopy.errorPathOutsideAllowedRoots.format(language, path)
        case let .cannotCreateFile(path, reason):
            return ExportCopy.errorCannotCreateFile.format(language, path, reason)
        case let .cannotOpenFileHandle(path):
            return ExportCopy.errorCannotOpenFileHandle.format(language, path)
        case let .writeFailed(path, bytes, reason):
            return ExportCopy.errorWriteFailed.format(language, path, ExportText.integer(bytes), reason)
        case let .encodingFailed(kind, reason):
            return ExportCopy.errorEncodingFailed.format(language, kind.rawValue, reason)
        case let .alreadyFinished(path):
            return ExportCopy.errorAlreadyFinished.format(language, path)
        }
    }
}
