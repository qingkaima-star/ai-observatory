//
//  HotFileRanking.swift
//  AIObservatoryUI / Projects
//
//  Owner: master-controller
//  ─────────────────────────────────────────────────────────
//  热点文件榜的排序与强度计算，从 `ProjectHotFilesPanel` 里抽出来单独可测。
//
//  为什么值得抽出来：这是「算了但没用」这类缺陷唯一能被机器抓住的地方——
//  多因子热度（`FileHeat.score`）由 Insights 产出，但如果界面仍按 `changeCount` 排，
//  一个 40 天前改了 40 次的老文件会永远压过今天被改 8 次的活跃文件，
//  而后者才是用户该看的那一个。整数字段的比较也不该写成浮点相等，这里一并收口。
//

import Foundation
import AIObservatoryCore

/// 热点榜排序口径（面板与任何未来的导出/报表共用，避免出现第二套规则）。
public enum HotFileRanking {

    /// 单个文件的权重：优先用综合分；没有分数（旧数据 / 上游未接 Insights）才退回原始计数。
    public static func weight(of heat: FileHeat) -> Double {
        heat.score ?? Double(heat.changeCount)
    }

    /// 榜单：权重降序；同权重时先比改动次数，再比最近触碰时间（保证全序、可重复）。
    public static func ranked(_ heats: [FileHeat], limit: Int) -> [FileHeat] {
        heats
            .sorted { lhs, rhs in
                let left = weight(of: lhs)
                let right = weight(of: rhs)
                if left != right { return left > right }
                if lhs.changeCount != rhs.changeCount { return lhs.changeCount > rhs.changeCount }
                return lhs.lastTouchedAt > rhs.lastTouchedAt
            }
            .prefix(max(1, limit))
            .map { $0 }
    }

    /// 榜首权重（用于把强度归一化到 `0...1`）。空榜返回 1，避免除零与空条。
    public static func maxWeight(of ranked: [FileHeat]) -> Double {
        max(0.0001, ranked.map(weight(of:)).max() ?? 1)
    }

    /// 某文件在当前榜单里的强度 `0...1`。
    public static func intensity(of heat: FileHeat, ranked: [FileHeat]) -> Double {
        min(1, max(0, weight(of: heat) / maxWeight(of: ranked)))
    }
}
