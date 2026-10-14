//
//  ProjectMapperHeatIntegrationTests.swift
//  AIObservatoryEngineTests
//
//  Owner: master-controller
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore

/// 证明项目地图的热度**确实换成了 Insights 的多因子评分**。
///
/// 只看「旧断言仍通过」不能证明接线生效——那可能只是新算法在这批夹具上
/// 恰好给出同样顺序。因此这里构造一个朴素计数与多因子评分**必然分歧**的场景：
/// 一个很久以前被改了很多次的文件，对比一个刚刚被改了几次的活跃文件。
@Suite("项目地图热度：已接上 Insights 多因子评分")
struct ProjectMapperHeatIntegrationTests {

    private let projectRoot = "/Users/demo/Projects/Mona"

    private func change(path: String, at timestamp: Date, agent: AgentKind = .claudeCode) -> FileChange {
        FileChange(
            path: "\(projectRoot)/\(path)",
            kind: .modified,
            timestamp: timestamp,
            agentKind: agent,
            linesAdded: 5,
            linesRemoved: 2
        )
    }

    @Test("热度分数确实超越原始计数：同改动次数由新近度区分")
    func scoreReflectsMoreThanCount() throws {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        // 两个文件改动次数完全相同（各 3 次），只有新近度不同。
        // 若热度仍按 changeCount 排，两者分数必然相等；出现分差即证明评分已接上多因子。
        var changes: [FileChange] = []
        for index in 0..<3 {
            changes.append(change(path: "Stale.swift", at: reference.addingTimeInterval(-30 * 24 * 3600 + TimeInterval(index))))
        }
        for index in 0..<3 {
            changes.append(change(path: "Fresh.swift", at: reference.addingTimeInterval(-120 + TimeInterval(index))))
        }

        let mapper = ProjectMapper(resolver: { _ in self.projectRoot })
        let activity = try #require(mapper.aggregate(
            changes: changes, commands: [], events: [], sessions: [], risks: []
        ).first)

        let stale = try #require(activity.hotFiles.first { $0.path.hasSuffix("Stale.swift") })
        let fresh = try #require(activity.hotFiles.first { $0.path.hasSuffix("Fresh.swift") })
        #expect(stale.changeCount == fresh.changeCount, "夹具应当让两者改动次数相同")
        let staleScore = try #require(stale.score)
        let freshScore = try #require(fresh.score)
        #expect(freshScore > staleScore, "新近度应让 Fresh 领先：\(freshScore) vs \(staleScore)")

        // 排序必须与分数同向（而不是与计数同向）。
        let scores = activity.hotFiles.compactMap(\.score)
        #expect(scores == scores.sorted(by: >), "hotFiles 未按 score 降序")
    }

    /// 已知缺陷（未修，见 Vault 工单）：`FileHeat.id` / `AgentContribution.id`
    /// 每次聚合都重新随机生成，导致 `ProjectActivity` 跨调用不相等。
    /// 因此这里比较**有语义的字段**，而不是整对象相等。
    @Test("同一批数据重复聚合：语义结果完全一致")
    func aggregationIsDeterministic() throws {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let changes = (0..<12).map { index in
            change(path: index.isMultiple(of: 2) ? "A.swift" : "B.swift",
                   at: reference.addingTimeInterval(TimeInterval(-index * 37)))
        }
        let mapper = ProjectMapper(resolver: { _ in self.projectRoot })
        let first = try #require(mapper.aggregate(changes: changes, commands: [], events: [], sessions: [], risks: []).first)
        let second = try #require(mapper.aggregate(changes: changes, commands: [], events: [], sessions: [], risks: []).first)

        #expect(first.hotFiles.map(\.path) == second.hotFiles.map(\.path))
        #expect(first.hotFiles.map(\.changeCount) == second.hotFiles.map(\.changeCount))
        #expect(first.hotFiles.map(\.score) == second.hotFiles.map(\.score))
        #expect(first.fileChangeCount == second.fileChangeCount)
        #expect(first.lastSeenAt == second.lastSeenAt)
    }

    @Test("每条热文件都带上归一化分数")
    func everyHeatCarriesScore() throws {
        let reference = Date(timeIntervalSince1970: 1_700_000_000)
        let changes = [
            change(path: "A.swift", at: reference.addingTimeInterval(-10)),
            change(path: "A.swift", at: reference.addingTimeInterval(-5)),
            change(path: "B.swift", at: reference.addingTimeInterval(-1))
        ]
        let mapper = ProjectMapper(resolver: { _ in self.projectRoot })
        let activity = try #require(mapper.aggregate(
            changes: changes, commands: [], events: [], sessions: [], risks: []
        ).first)

        #expect(!activity.hotFiles.isEmpty)
        for heat in activity.hotFiles {
            let score = try #require(heat.score, "热文件缺少 score：\(heat.path)")
            #expect((0...1).contains(score), "score 应归一化到 0...1，实得 \(score)")
        }
    }
}
