//
//  Exporting.swift
//  AIObservatoryCore
//
//  Owner: master-controller（冻结契约层）
//
//  界面发起导出时使用的意图类型。
//
//  为什么不直接用 `AIObservatoryExport` 的 `ExportRequest`：UI 只依赖 Core（这是 UI 与 Engine
//  能并行开发的前提）。让 UI 引用导出层会把它拖进一条新的依赖边；所以界面只表达
//  「导哪一段时间、什么格式、要不要脱敏」，由组合根（App）翻译成真正的导出请求。
//

import Foundation

public struct ActivityExportRequest: Sendable, Hashable {

    /// 界面上可选的导出格式。与导出层的具体编码器解耦，App 负责映射。
    public enum Format: String, CaseIterable, Identifiable, Sendable {
        case markdown
        case json
        case csv

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .markdown: return "Markdown 报告（可读）"
            case .json:     return "JSON（可再处理）"
            case .csv:      return "CSV（表格软件打开）"
            }
        }
    }

    /// 导出哪一段时间：通常就是用户当前列表上生效的时间筛选。
    public var dateRange: DateRangeFilter
    public var format: Format
    /// 默认开启：导出物往往会被转发给别人，路径与命令里的敏感内容不该跟着走。
    public var redactionEnabled: Bool

    public init(
        dateRange: DateRangeFilter = .unbounded,
        format: Format = .markdown,
        redactionEnabled: Bool = true
    ) {
        self.dateRange = dateRange
        self.format = format
        self.redactionEnabled = redactionEnabled
    }
}

/// 由组合根注入的导出执行者。`nil` 表示当前宿主（如 SwiftUI 预览）没有接导出层。
public protocol ActivityExportControlling: Sendable {
    /// 弹目录选择面板并写出所选范围；用户取消则什么都不写。
    @MainActor func export(_ request: ActivityExportRequest) async
}
