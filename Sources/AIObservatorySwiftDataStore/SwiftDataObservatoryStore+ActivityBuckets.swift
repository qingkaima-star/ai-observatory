//
//  SwiftDataObservatoryStore+ActivityBuckets.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-Engine（由 SwiftDataObservatoryStore+Queries.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import SwiftData
import AIObservatoryCore

extension SwiftDataObservatoryStore {

    /// 8) 分桶合并：事件计数与 CPU 均值按**桶起点**对齐，再折成 `DashboardStats` 的桶序号
    ///    （无数据的格子 eventCount = 0、cpuAverage = 0，UI 不必自己补洞）。
    ///
    ///    口径与 SQLite 侧**同源**（裁定 9：≤ 36 h 小时桶，> 36 h 自然日桶）：
    ///    那边把分组下推成 `GROUP BY` + `strftime(... , 'localtime')`，这一边没有聚合，
    ///    只能在分块扫描里用 `Calendar.current` 归到桶起点；两侧读的是同一份 tzdata，
    ///    逐格相同由 `DashboardHourlyBucketParityTests` / `DashboardRangeParityTests` 钉住。
    ///    锚点 = 窗口起点的整点 / 零点；窗口没有起点（「全部」）时用第一个有数据的桶起点。
    ///    补齐只补到窗口末（「今天」那一档因此仍是整 24 格，与改造前逐格相同），
    ///    并且**至少**覆盖到最后一个有数据的桶——落在右端点上的那一行不许被补零挤掉。
    static func activityBuckets(
        eventBuckets: [Date: Int],
        perfBuckets: [Date: HourBucket],
        span: ActivityBucketSpan,
        range: DateRangeFilter,
        settledAt: Date,
        calendar: Calendar = .current
    ) -> (points: [HourlyActivity], anchor: Date) {
        // 锚点只有一条，而且界面能自己复算（这才不需要在载荷里再塞一个 anchor）：
        //   · 日档 = 结算时刻所在自然日的零点 ⇒ 桶序号是**带符号的天偏移**（往回数是负的）；
        //   · 小时档 = 窗口起点落到整点 ⇒「今天」那一档锚点就是当日零点，
        //     序号恰好等于 0…23 的时，与改造前逐格相同。
        let anchor = span == .naturalDay
            ? calendar.startOfDay(for: settledAt)
            : floorBucketStart(range.start ?? settledAt, span: span, calendar: calendar)

        var merged: [Int: HourBucket] = [:]
        for (start, count) in eventBuckets {
            let index = bucketIndex(from: anchor, to: start, span: span, calendar: calendar)
            merged[index, default: HourBucket()].eventCount += count
        }
        for (start, bucket) in perfBuckets {
            let index = bucketIndex(from: anchor, to: start, span: span, calendar: calendar)
            var entry = merged[index] ?? HourBucket()
            entry.cpuSum = bucket.cpuSum
            entry.cpuSampleCount = bucket.cpuSampleCount
            merged[index] = entry
        }

        let padded = paddedSlots(merged.keys, span: span, range: range, settledAt: settledAt,
                                 anchor: anchor, calendar: calendar)
        let points: [HourlyActivity] = padded.map { slot in
            let bucket = merged[slot] ?? HourBucket()
            let cpuAverage = bucket.cpuSampleCount > 0
                ? bucket.cpuSum / Double(bucket.cpuSampleCount)
                : 0
            return HourlyActivity(hour: slot, eventCount: bucket.eventCount, cpuAverage: cpuAverage)
        }
        return (points, anchor)
    }

    /// 补齐：把散落的有数据桶铺成一段**连续**的序号区间（空格子 eventCount = 0）。
    /// 边界只由窗口与数据决定，界面按同一条规则复算起点，所以载荷里不必再放一个锚点。
    /// 与 SQLite 侧同一条实现，逐字同形。
    private static func paddedSlots(
        _ populated: some Sequence<Int>,
        span: ActivityBucketSpan,
        range: DateRangeFilter,
        settledAt: Date,
        anchor: Date,
        calendar: Calendar
    ) -> [Int] {
        let present = Array(populated)
        let endLimit = paddingEnd(range: range, settledAt: settledAt, span: span, calendar: calendar)
        let endSlot = bucketIndex(from: anchor, to: endLimit, span: span, calendar: calendar)
        let lastSlot = max(present.max() ?? endSlot, endSlot)
        let firstSlot: Int
        if span == .naturalDay {
            let windowSlot = range.start.map { bucketIndex(from: anchor, to: $0, span: span, calendar: calendar) }
            firstSlot = min(present.min() ?? lastSlot, windowSlot ?? lastSlot)
        } else {
            firstSlot = min(present.min() ?? 0, 0)
        }
        guard lastSlot >= firstSlot else { return [] }
        let count = min(lastSlot - firstSlot + 1, maxActivityBuckets)
        guard count > 0 else { return [] }
        return Array(firstSlot..<(firstSlot + count))
    }

    /// 补齐的右边界（三条口径，与 SQLite 侧的 `paddingEnd` 逐字同一条）：
    ///   · 窗口没有终点（「全部」）→ 结算时刻；
    ///   · 终点**正好落在桶边界**上 → 退一格（`DateRangeFilter.today` 的右端点是次日零点，
    ///     不退就吐 25 格，改掉改造前「今天 = 整 0…23 共 24 条」的形状）；
    ///   · 其余取 `min(终点, 结算时刻)`。
    private static func paddingEnd(
        range: DateRangeFilter,
        settledAt: Date,
        span: ActivityBucketSpan,
        calendar: Calendar
    ) -> Date {
        guard let end = range.end else { return settledAt }
        if floorBucketStart(end, span: span, calendar: calendar) == end {
            return calendarDate(byAdding: -1, to: end, span: span, calendar: calendar)
        }
        return min(end, settledAt)
    }

    /// 窗口宽度 → 桶粒度（裁定 9）：**≤ 36 h 小时桶，> 36 h 自然日桶**；
    /// 没有起点或没有终点的窗口（「全部」）一律日桶——否则小时桶的个数没有上界。
    /// 与 SQLite 侧同一条判断，逐字同形（两个后端不许各拿一把尺子）。
    static func bucketSpan(for range: DateRangeFilter) -> ActivityBucketSpan {
        guard let start = range.start, let end = range.end else { return .naturalDay }
        return end.timeIntervalSince(start) <= 36 * 3600 ? .hourOfDay : .naturalDay
    }

    /// 桶序号：锚点到该起点之间隔了几个粒度单位（`Calendar` 数，不做秒除，§5）。
    static func bucketIndex(
        from anchor: Date,
        to start: Date,
        span: ActivityBucketSpan,
        calendar: Calendar = .current
    ) -> Int {
        let unit = span.calendarUnit
        let floored = floorBucketStart(start, span: span, calendar: calendar)
        // 带符号：日档的锚点是结算那天，往回数的格子必须是负数（界面用同一个数往回推日期）。
        return calendar.dateComponents([unit], from: anchor, to: floored).value(for: unit) ?? 0
    }

    /// 把时刻落到它所属的桶起点（小时档 = 整点，日档 = `startOfDay`）。
    static func floorBucketStart(_ date: Date, span: ActivityBucketSpan, calendar: Calendar = .current) -> Date {
        span == .hourOfDay ? floorToHour(date, calendar: calendar) : calendar.startOfDay(for: date)
    }

    static func calendarDate(
        byAdding steps: Int,
        to anchor: Date,
        span: ActivityBucketSpan,
        calendar: Calendar = .current
    ) -> Date {
        calendar.date(byAdding: span.calendarUnit, value: steps, to: anchor) ?? anchor
    }

    static func floorToHour(_ date: Date, calendar: Calendar = .current) -> Date {
        let parts: Set<Calendar.Component> = [.year, .month, .day, .hour]
        return calendar.date(from: calendar.dateComponents(parts, from: date)) ?? date
    }

    /// 一次聚合最多回多少格：日档下等于一年。触到上限时少画格子、不伪造数字。
    static let maxActivityBuckets = 366

    /// 按 Agent 种类聚合**窗口内**新建的会话：没有任何一场会话的种类不进表（与 SQLite / InMemory 一致）。
    static func agentShares(for sessions: [AgentSession], until date: Date) -> [AgentUsageShare] {
        AgentKind.allCases.compactMap { kind -> AgentUsageShare? in
            let matched = sessions.filter { $0.kind == kind }
            guard !matched.isEmpty else { return nil }
            return AgentUsageShare(
                kind: kind,
                sessionCount: matched.count,
                totalSeconds: matched.reduce(0) { $0 + $1.duration(until: date) }
            )
        }
    }


}
