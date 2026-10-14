//
//  StableIDTests.swift
//  AIObservatoryCoreTests
//
//  Owner: master-controller
//
//  守的是派生聚合值的身份稳定性：`FileHeat` / `AgentContribution` 过去每轮聚合再生成一次
//  `UUID()`，导致 `projects` 行的 JSON 在无数据变化时也被改写、导出失去字节确定性。
//

import Foundation
import Testing
@testable import AIObservatoryCore

@Suite("Core: 聚合值身份稳定（F1）")
struct StableIDTests {

    @Test("同输入同输出：命名空间与 key 都参与，不同命名空间不撞车")
    func deterministicAndNamespaced() {
        #expect(StableID.uuid(namespace: "fileheat", key: "/a/b.swift")
                == StableID.uuid(namespace: "fileheat", key: "/a/b.swift"))
        #expect(StableID.uuid(namespace: "fileheat", key: "/a/b.swift")
                != StableID.uuid(namespace: "fileheat", key: "/a/c.swift"))
        #expect(StableID.uuid(namespace: "fileheat", key: "x")
                != StableID.uuid(namespace: "agentcontribution", key: "x"))
    }

    @Test("补齐 version/variant 位：是合法的 RFC 4122 UUID")
    func carriesVersionAndVariantBits() {
        let id = StableID.uuid(namespace: "fileheat", key: "/x")
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        #expect(bytes[6] & 0xF0 == 0x50)
        #expect(bytes[8] & 0xC0 == 0x80)
    }

    @Test("热度条目按路径稳定：重复构造不产生新身份")
    func fileHeatIdentityFollowsPath() {
        let first = FileHeat(path: "/repo/Sources/a.swift", changeCount: 3,
                             linesAdded: 10, linesRemoved: 2)
        let second = FileHeat(path: "/repo/Sources/a.swift", changeCount: 9,
                              linesAdded: 40, linesRemoved: 8)
        let other = FileHeat(path: "/repo/Sources/b.swift", changeCount: 3,
                             linesAdded: 10, linesRemoved: 2)
        #expect(first.id == second.id)
        #expect(first.id != other.id)
    }

    @Test("贡献项按 Agent 种类稳定")
    func contributionIdentityFollowsKind() {
        #expect(AgentContribution(kind: .claudeCode, relativeShare: 0.2, eventCount: 3).id
                == AgentContribution(kind: .claudeCode, relativeShare: 0.7, eventCount: 90).id)
        #expect(AgentContribution(kind: .claudeCode, relativeShare: 0.2, eventCount: 3).id
                != AgentContribution(kind: .openAICodex, relativeShare: 0.2, eventCount: 3).id)
    }

    @Test("JSON 可重复：语义不变时两次编码字节一致（导出确定性的前提）")
    func jsonIsReproducible() throws {
        let heats = [FileHeat(path: "/repo/a.swift", changeCount: 3, linesAdded: 10, linesRemoved: 2,
                              lastTouchedAt: Date(timeIntervalSince1970: 1_800_000_000), score: 0.42),
                     FileHeat(path: "/repo/b.swift", changeCount: 1, linesAdded: 1, lastTouchedAt: Date(timeIntervalSince1970: 1_800_000_000))]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let first = try encoder.encode(heats)
        let rebuilt = heats.map {
            FileHeat(path: $0.path, changeCount: $0.changeCount, linesAdded: $0.linesAdded,
                     linesRemoved: $0.linesRemoved, lastTouchedAt: $0.lastTouchedAt, score: $0.score)
        }
        #expect(try encoder.encode(rebuilt) == first)
    }

    @Test("显式传入的 id 不被覆盖")
    func explicitIDWins() {
        let pinned = UUID(uuidString: "00000007-0000-0000-0000-000000000007") ?? UUID()
        #expect(FileHeat(id: pinned, path: "/repo/a.swift", changeCount: 1).id == pinned)
        #expect(AgentContribution(id: pinned, kind: .aiderCLI, relativeShare: 1, eventCount: 1).id == pinned)
    }
}
