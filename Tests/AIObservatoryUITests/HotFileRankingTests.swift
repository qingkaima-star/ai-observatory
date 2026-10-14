//
//  HotFileRankingTests.swift
//  AIObservatoryUITests
//
//  Owner: master-controller
//
//  第一个 UI 层用例，守的是「多因子热度算了但界面没用上」这类缺陷：
//  只要面板回到按 `changeCount` 排序，这里立刻红。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryUI

private let baseline = Date(timeIntervalSince1970: 1_800_000_000)

private func heat(_ path: String,
                  changes: Int,
                  age: TimeInterval,
                  score: Double?) -> FileHeat {
    FileHeat(path: path,
             changeCount: changes,
             linesAdded: changes,
             linesRemoved: 0,
             lastTouchedAt: baseline.addingTimeInterval(-age),
             score: score)
}

@Suite("UI: 热点榜排序口径")
struct HotFileRankingTests {

    @Test("综合分优先于原始计数：40 天前改了 40 次的老文件不该压过今天改了 8 次的活跃文件")
    func scoreOutranksRawCount() {
        let stale = heat("/repo/Legacy.swift", changes: 40,
                         age: 40 * 24 * 3600, score: 0.12)
        let active = heat("/repo/Today.swift", changes: 8,
                          age: 60, score: 0.85)
        let ranked = HotFileRanking.ranked([stale, active], limit: 10)
        #expect(ranked.map(\.path) == ["/repo/Today.swift", "/repo/Legacy.swift"])
        #expect(HotFileRanking.intensity(of: active, ranked: ranked) == 1.0)
        #expect(HotFileRanking.intensity(of: stale, ranked: ranked) < 0.3)
    }

    @Test("没有分数时退回改动次数（旧数据与未接 Insights 的上游仍可排序）")
    func fallsBackToChangeCount() {
        let a = heat("/repo/a.swift", changes: 3, age: 10, score: nil)
        let b = heat("/repo/b.swift", changes: 9, age: 10, score: nil)
        #expect(HotFileRanking.ranked([a, b], limit: 10).map(\.path) == ["/repo/b.swift", "/repo/a.swift"])
    }

    @Test("同分时按改动次数、再按最近触碰时间决出全序（结果与输入顺序无关）")
    func tiesAreFullyOrdered() {
        let x = heat("/repo/x.swift", changes: 5, age: 100, score: 0.5)
        let y = heat("/repo/y.swift", changes: 5, age: 10, score: 0.5)
        let z = heat("/repo/z.swift", changes: 9, age: 100, score: 0.5)
        let forward = HotFileRanking.ranked([x, y, z], limit: 10).map(\.path)
        let backward = HotFileRanking.ranked([z, y, x], limit: 10).map(\.path)
        #expect(forward == backward)
        #expect(forward == ["/repo/z.swift", "/repo/y.swift", "/repo/x.swift"])
    }

    @Test("limit 生效且下限为 1；空榜强度不出 NaN")
    func limitsAndEmptyAreSafe() {
        let many = (1...30).map { heat("/repo/f\($0).swift", changes: $0, age: 0, score: Double($0) / 30) }
        #expect(HotFileRanking.ranked(many, limit: 12).count == 12)
        #expect(HotFileRanking.ranked(many, limit: 0).count == 1)
        #expect(HotFileRanking.maxWeight(of: []).isFinite)
        #expect(HotFileRanking.intensity(of: many[0], ranked: []).isFinite)
    }

    @Test("强度恒落在 0...1（越界分数也夹住）")
    func intensityIsClamped() {
        let hot = heat("/repo/hot.swift", changes: 1, age: 0, score: 1.9)
        let cold = heat("/repo/cold.swift", changes: 1, age: 0, score: -0.4)
        let ranked = HotFileRanking.ranked([hot, cold], limit: 5)
        for item in ranked {
            let value = HotFileRanking.intensity(of: item, ranked: ranked)
            #expect((0...1).contains(value))
        }
    }
}
