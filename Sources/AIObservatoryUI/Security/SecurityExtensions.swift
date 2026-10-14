//
//  SecurityExtensions.swift
//  AIObservatoryUI / Security
//
//  Owner: WS-UI (subagent H) → WS-QUIET-3
//  职责：Security 板块的**视图层**派生成员（查询/分页/确认那套数据流留在
//        `SecurityModel.swift`，这里只做展示口径）——
//        展示排序、一次遍历的概览读数、「跳过当前条」的确认排队。
//
//  为什么把六个计数收成一次遍历（`SecurityReadouts`）：
//  旧版是六个各自独立的 `events.filter { … }` 计算属性，`@Observable` 不缓存计算属性，
//  于是一次 body 把同一个数组重过六遍；更糟的是它们**口径互相独立地漂移**——
//  `pendingCount` 与 `acknowledgedCount` 一处算 `!isAcknowledged`、
//  另一处算 `events.count - pendingCount`，加一个新计数的人不会想到要对齐。
//  现在整页只读一个快照，五个数由同一个循环产出。
//

import Foundation
import AIObservatoryCore

extension SecurityModel {
    /// 列表展示顺序：时间倒序为主，同一时刻按等级权重（critical 优先），再以标题稳定排序。
    var sortedEvents: [RiskEvent] {
        events.sorted { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            if lhs.level != rhs.level { return lhs.level > rhs.level }
            return lhs.title < rhs.title
        }
    }

    /// 需要用户确认、且尚未确认的事件（确认队列的来源）。
    var pendingConfirmationEvents: [RiskEvent] {
        events.filter { $0.requiresConfirmation && !$0.isAcknowledged }
    }

    /// 当前列表里是否还有可批量确认的条目（用于禁用「全部标记已确认」）。
    var hasPendingEvents: Bool {
        events.contains { !$0.isAcknowledged }
    }

    /// 状态条 / 页面副标题文案：`共 N 条 · 已加载 M · 已确认 K`。
    var loadSummary: String {
        let readouts = self.readouts
        return SecurityCopy.loadSummary.format(
            UILanguage.current, readouts.totalCount, readouts.loadedCount, readouts.acknowledgedCount)
    }

    /// 概览读数快照（本页唯一的取数入口，见文件头）。
    var readouts: SecurityReadouts {
        SecurityReadouts.make(from: events, loadedAs: events.count, total: totalCount, today: todayTotal)
    }

    /// 跳过 `event` 本身，把确认弹窗排队到下一条待确认事件。
    ///
    /// 契约里的 `presentNextConfirmationIfNeeded()` 总是选中队首，而「稍后处理」不会确认当前条，
    /// 直接复用会让同一条事件立刻再次弹出。这里显式排除当前条，实现逐条推进的确认队列。
    func presentNextConfirmation(after event: RiskEvent) {
        guard confirmationEnabled, confirmationTarget == nil else { return }
        confirmationTarget = pendingConfirmationEvents.first { $0.id != event.id }
    }
}

/// 概览区的一组读数，**一趟循环**产出。
///
/// 每个字段的口径都写在自己的注释里：这一页最容易出的错不是算错，
/// 而是把「按已加载这一页算的数」说成「全库的数」。
struct SecurityReadouts: Hashable {
    /// 等级 ≥ 高 **且**未确认的条数——本页的 `.hero`，唯一会改变读者动作的数。
    let pendingHighRiskCount: Int
    /// 未确认条数（含全部等级）。
    let pendingCount: Int
    /// 涉及受保护目录的事件条数（按事件计，不是按路径计）。
    let sensitivePathEventCount: Int
    /// 已确认条数：`loadedCount - pendingCount`，两者必须同源。
    let acknowledgedCount: Int
    /// 今日风险总数：来自独立小查询，**不受当前过滤条件影响**。
    let todayTotal: Int
    /// 已加载条数（`pageSize = 100`，内存上限 `eventCap`）。前面所有计数都以它为分母。
    let loadedCount: Int
    /// 全库命中条数（服务端 `COUNT`，与 `loadedCount` 不是同一个对象）。
    let totalCount: Int

    static func make(
        from events: [RiskEvent],
        loadedAs loadedCount: Int,
        total: Int,
        today: Int
    ) -> SecurityReadouts {
        var pendingHighRisk = 0
        var pending = 0
        var sensitive = 0
        for event in events {
            if !event.isAcknowledged {
                pending += 1
                if event.level >= .high { pendingHighRisk += 1 }
            }
            if event.filePaths.contains(where: PathHeuristics.isSensitive) { sensitive += 1 }
        }
        return SecurityReadouts(
            pendingHighRiskCount: pendingHighRisk,
            pendingCount: pending,
            sensitivePathEventCount: sensitive,
            acknowledgedCount: max(0, loadedCount - pending),
            todayTotal: today,
            loadedCount: loadedCount,
            totalCount: total
        )
    }
}
