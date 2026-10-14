//
//  ObservatoryTimeRange.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent A)
//  全局时间范围枚举：工具栏选择、各板块转成 DateRangeFilter 传给查询。
//  #67：`displayName` 原本硬编码中文且**没有语言入参** ⇒ 英文态每页头部的时间范围选择器
//  必露中文（结构事实）。现在六条中英对照集中在 ``TimeRangeCopy``，这里只转发。
//

import Foundation
import SwiftUI
import AIObservatoryCore

enum ObservatoryTimeRange: String, CaseIterable, Identifiable {
    case today
    case lastHour
    case lastSixHours
    case last24Hours
    case lastSevenDays
    case all

    var id: String { rawValue }

    /// 无语言入参的老口径：**恒为中文**。
    ///
    /// 保留它是为了让既有非用户可见的调用点与用例口径不变（#67 派单原话）。
    /// ⚠️ 用户可见的地方**不要用它** —— 走 `displayName(_ language:)` 显式传语言，
    /// 否则英文态就会像 #67 之前那样每页头部混排中文。
    /// 有一条用例（`noUserVisibleTimeRangeRendererIgnoresLanguage`）扫 UI 目录抓这个。
    var displayName: String { displayName(.chineseSimplified) }

    /// 唯一出处在 ``TimeRangeCopy``，这里只转发（与 `ContractCopy` 那一族同形）。
    func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .today:         return TimeRangeCopy.today.text(language)
        case .lastHour:      return TimeRangeCopy.lastHour.text(language)
        case .lastSixHours:  return TimeRangeCopy.lastSixHours.text(language)
        case .last24Hours:   return TimeRangeCopy.last24Hours.text(language)
        case .lastSevenDays: return TimeRangeCopy.lastSevenDays.text(language)
        case .all:           return TimeRangeCopy.all.text(language)
        }
    }

    var symbol: String {
        switch self {
        case .today:         return "sun.max"
        case .lastHour:      return "clock"
        case .lastSixHours:  return "hourglass"
        case .last24Hours:   return "clock.arrow.2.circlepath"
        case .lastSevenDays: return "calendar"
        case .all:           return "infinity"
        }
    }

    func dateRange(now: Date = Date()) -> DateRangeFilter {
        switch self {
        case .today:         return .today(now)
        case .lastHour:      return .lastHours(1, now: now)
        case .lastSixHours:  return .lastHours(6, now: now)
        case .last24Hours:   return .lastHours(24, now: now)
        case .lastSevenDays: return .lastHours(24 * 7, now: now)
        case .all:           return .unbounded
        }
    }
}

/// 时间范围选择器的六条文案（zh/en 成对，`displayName(_:)` 的唯一出处）。
///
/// 【大小写口径】英文按句首大写（HIG sentence case），不逐字对译成 "Last 24 Hours"。
enum TimeRangeCopy {
    static let today = NamedCopy("timeRange.today", LocalizedString(zh: "今天", en: "Today"))
    static let lastHour = NamedCopy("timeRange.lastHour", LocalizedString(zh: "最近 1 小时", en: "Last hour"))
    static let lastSixHours = NamedCopy("timeRange.lastSixHours",
                                        LocalizedString(zh: "最近 6 小时", en: "Last 6 hours"))
    static let last24Hours = NamedCopy("timeRange.last24Hours",
                                       LocalizedString(zh: "最近 24 小时", en: "Last 24 hours"))
    static let lastSevenDays = NamedCopy("timeRange.lastSevenDays",
                                         LocalizedString(zh: "最近 7 天", en: "Last 7 days"))
    static let all = NamedCopy("timeRange.all", LocalizedString(zh: "全部", en: "All"))

    /// 门禁遍历这一份（分母守卫按它的条数走）。
    static let bilingualCopy: [NamedCopy] = [today, lastHour, lastSixHours, last24Hours, lastSevenDays, all]
}

#Preview("ObservatoryTimeRange") {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        ForEach(ObservatoryTimeRange.allCases) { range in
            Label(range.displayName, systemImage: range.symbol)
                .font(.callout)
        }
    }
    .padding(Spacing.md)
}
