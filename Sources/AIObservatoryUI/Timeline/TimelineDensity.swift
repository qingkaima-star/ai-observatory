//
//  TimelineDensity.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent C) → WS-QUIET-1 (subagent A) 改版
//  时间线行密度档位：控制台视图信息量极大，必须让用户自己调节一屏能看多少条。
//
//  quiet 改版后的语义收窄了一档：**事件行永远只有一行**（旧版是「摘要 + 卡片」两行式，
//  一屏十几张白卡就是「拥挤」的来源）。密度现在只调节
//  「这一行的行尾还挂多少元信息」，不再调节行数，也不再画轴上的圆点
//  ——竖向轨道在懒栈容器里靠每行自己画线，行高一变就断，而且那是我们自造的框。
//

import SwiftUI
import AIObservatoryCore

/// 时间线事件流的呈现密度。
enum TimelineDensity: String, CaseIterable, Identifiable {
    /// 单行 + 完整行尾元信息（摘要 / 操作类型 / 时长 / 退出码）。
    case comfortable
    /// 单行 + 最小元信息（时间 / Agent / 标题 / 风险），一屏能塞下的条数最多。
    case compact

    var id: String { rawValue }

    var displayName: String { displayName(UILanguage.current) }

    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .comfortable: return TimelineCopy.densityComfortable.text(language)
        case .compact:     return TimelineCopy.densityCompact.text(language)
        }
    }

    /// 供 `Picker` 使用的 SF Symbol。
    var symbol: String {
        switch self {
        case .comfortable: return "list.bullet.rectangle"
        case .compact:     return "list.bullet.below.rectangle"
        }
    }

    /// 是否渲染行尾的扩展元信息（摘要 / 操作类型 / 时长 / 退出码）。
    var showsExtendedContent: Bool { self == .comfortable }

    /// 行内纵向留白：紧凑档把行高压到 `Sizing.rowMinHeight` 这一档，舒适档留出呼吸。
    var rowVerticalPadding: CGFloat {
        switch self {
        case .comfortable: return Spacing.sm
        case .compact:     return Spacing.xs
        }
    }
}
