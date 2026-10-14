//
//  RiskWindowRetentionTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine
//  ─────────────────────────────────────────────────────────
//  钉住「每轮留下多少不释放」（简报 §1.3）里落在本车道的那部分。
//
//  机制（读码 + 真机读数）：风险层的会话窗口是 `[sessionID.uuidString: WindowState]`，
//  `maxFactsPerKind = 512` 只管**单个键内**的条数，对**键的个数**完全无效；而一条已结算的
//  会话再也不会被喂 ⇒ 它那最坏 512×4 条胖值类型（路径 / argv / diff 摘要）加四个 `Set<UUID>`
//  与一张节流表会一直躺在字典里到引擎停机。会话数一涨（简报 §1.4 真机出现过 11 秒内 1 → 15），
//  驻留量就跟着涨且不收敛——这与「`leaks` 只报 14 KB 而同一报告存活工作集 1 GB」的形态一致：
//  不是没释放的对象，是不收敛的驻留。
//
//  期望值全部按策略参数手算成字面量（条数、时刻、淘汰次序都能用笔算复核），不从实现读回。
//

import Foundation
import Testing
@testable import AIObservatoryEngine
import AIObservatoryCore

private enum RiskClock {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static func after(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }
}

private func riskPolicy(
    retention: TimeInterval = 600,
    perKind: Int = 512,
    windows: Int = 64
) -> RiskPipeline.BufferPolicy {
    RiskPipeline.BufferPolicy(retention: retention, maxFactsPerKind: perKind, maxActiveWindows: windows)
}

private func sample(sessionID: UUID, agentID: UUID, at date: Date) -> PerformanceSample {
    PerformanceSample(timestamp: date, sessionID: sessionID, agentID: agentID, cpuPercent: 10, memoryBytes: 1_048_576)
}

private func deletion(_ index: Int, sessionID: UUID, at date: Date) -> FileChange {
    FileChange(
        path: "/Users/testhost/Projects/Mona/obsolete-\(index).txt",
        kind: .deleted,
        timestamp: date,
        agentID: UUID(),
        sessionID: sessionID
    )
}

@Suite("§1.3 风险窗口的驻留上界与裁剪口径", .timeLimit(.minutes(1)))
struct RiskWindowRetentionTests {

    @Test("窗口个数封顶：喂 200 个会话键后只剩 maxActiveWindows 个")
    func bucketCountIsCapped() {
        // 手算：cap = 8，喂 200 个不同会话键 ⇒ 恰好留 8 个。改前会留 200 个且不收敛。
        let pipeline = RiskPipeline(bufferPolicy: riskPolicy(perKind: 4, windows: 8))
        for index in 0..<200 {
            let sessionID = UUID()
            pipeline.noteSample(sample(sessionID: sessionID, agentID: UUID(), at: RiskClock.after(Double(index))),
                                sessionID: sessionID, agentKind: .claudeCode)
        }
        #expect(pipeline.activeWindowCount() == 8, "封顶失效就退回「随进程见过的会话数线性增长」")
    }

    @Test("被淘汰的键整份窗口消失，之后再被喂会以新窗口重建（去重集合不拦它）")
    func evictedKeyIsRebuildable() {
        let pipeline = RiskPipeline(bufferPolicy: riskPolicy(perKind: 4, windows: 1))
        let first = UUID()
        let firstSample = sample(sessionID: first, agentID: UUID(), at: RiskClock.after(0))
        pipeline.noteSample(firstSample, sessionID: first, agentKind: .claudeCode)
        #expect(pipeline.factCount(forKey: RiskPipeline.windowKey(sessionID: first, agentKind: .claudeCode)) == 1)

        // 喂第二个键 ⇒ cap = 1 ⇒ 第一个键被淘汰。
        let second = UUID()
        pipeline.noteSample(sample(sessionID: second, agentID: UUID(), at: RiskClock.after(10)),
                            sessionID: second, agentKind: .claudeCode)
        #expect(pipeline.activeWindowCount() == 1)
        #expect(pipeline.factCount(forKey: RiskPipeline.windowKey(sessionID: first, agentKind: .claudeCode)) == 0)

        // **同一条采样对象**（同一个 id）再喂回来必须能重新入窗：
        // 淘汰是把整个 WindowState（含四个去重 Set）一起丢掉，不会留下「id 见过所以永不入窗」的暗伤。
        pipeline.noteSample(firstSample, sessionID: first, agentKind: .claudeCode)
        #expect(pipeline.factCount(forKey: RiskPipeline.windowKey(sessionID: first, agentKind: .claudeCode)) == 1)
    }

    @Test("单键内裁剪：超过 maxFactsPerKind 只留时间最新的 4 条")
    func perKindTrimmingKeepsNewest() {
        let pipeline = RiskPipeline(bufferPolicy: riskPolicy(perKind: 4, windows: 4))
        let sessionID = UUID()
        let key = RiskPipeline.windowKey(sessionID: sessionID, agentKind: .claudeCode)
        // 手算：t = 0/10/20/30/40/50/60/70/80/90 共 10 条，全部在 600 秒保留窗内
        // （以最新的 90 为「现在」，最旧 0 的 age = 90 ≤ 600）⇒ 只有条数上限起作用 → 4。
        for index in 0..<10 {
            pipeline.noteSample(sample(sessionID: sessionID, agentID: UUID(), at: RiskClock.after(Double(index) * 10)),
                                sessionID: sessionID, agentKind: .claudeCode)
        }
        #expect(pipeline.factCount(forKey: key) == 4)

        // 再来一条更新的 ⇒ 滑入一条滑出一条，仍是 4 而不是 5。
        pipeline.noteSample(sample(sessionID: sessionID, agentID: UUID(), at: RiskClock.after(100)),
                            sessionID: sessionID, agentKind: .claudeCode)
        #expect(pipeline.factCount(forKey: key) == 4)
    }

    @Test("保留窗滑出：过期者丢、未过期者留；age 恰好等于 retention 时留在窗内")
    func retentionSlideBoundary() {
        let sessionID = UUID()
        let agentID = UUID()
        let key = RiskPipeline.windowKey(sessionID: sessionID, agentKind: .claudeCode)

        // retention = 60：t=0 与 t=100 → age 100 > 60 丢；t=100 留 → 1 条。
        let expired = RiskPipeline(bufferPolicy: riskPolicy(retention: 60, windows: 4))
        expired.noteSample(sample(sessionID: sessionID, agentID: agentID, at: RiskClock.after(0)),
                           sessionID: sessionID, agentKind: .claudeCode)
        expired.noteSample(sample(sessionID: sessionID, agentID: agentID, at: RiskClock.after(100)),
                           sessionID: sessionID, agentKind: .claudeCode)
        #expect(expired.factCount(forKey: key) == 1)

        // 边界：age 恰好 60 → 判据是 `<=`（与改动前逐字相同）→ 两条都留。
        let boundary = RiskPipeline(bufferPolicy: riskPolicy(retention: 60, windows: 4))
        boundary.noteSample(sample(sessionID: sessionID, agentID: agentID, at: RiskClock.after(40)),
                            sessionID: sessionID, agentKind: .claudeCode)
        boundary.noteSample(sample(sessionID: sessionID, agentID: agentID, at: RiskClock.after(100)),
                            sessionID: sessionID, agentKind: .claudeCode)
        #expect(boundary.factCount(forKey: key) == 2)
    }

    @Test("窗口空了立刻摘键：一条事实都没有时不留下空壳")
    func emptyWindowIsNotRetained() {
        let pipeline = RiskPipeline(bufferPolicy: riskPolicy(perKind: 4, windows: 4))
        let risks = pipeline.evaluate(RiskContext(event: nil, command: nil, fileChange: nil,
                                                 agentKind: .claudeCode, sessionID: UUID()))
        #expect(risks.isEmpty)
        #expect(pipeline.activeWindowCount() == 0, "空壳键会一直躺在字典里，是化石驻留的另一半来源")
    }

    @Test("封顶不吃本轮产出：正在进料的键永不被淘汰")
    func capNeverEvictsCurrentFeed() {
        let pipeline = RiskPipeline(bufferPolicy: riskPolicy(perKind: 512, windows: 1))
        let sessionID = UUID()
        // 手算：同一条会话 50 条采样（t = 0…490，全在 600 秒窗内）⇒ 50 条全部驻留。
        for index in 0..<50 {
            pipeline.noteSample(sample(sessionID: sessionID, agentID: UUID(), at: RiskClock.after(Double(index) * 10)),
                                sessionID: sessionID, agentKind: .claudeCode)
        }
        #expect(pipeline.activeWindowCount() == 1)
        #expect(pipeline.factCount(forKey: RiskPipeline.windowKey(sessionID: sessionID, agentKind: .claudeCode)) == 50)
    }

    /// 影子基线：把「不封顶」的实现当对照，钉住「封顶只治驻留、不改判定」。
    /// 42 次删除 → 1 条 `risk.destructive.mass-deletion-window` 是既有套件已钉的口径，
    /// 这里用 3 个会话各投 42 次，比两份产出的**语义字段**（不是整对象，`id` 是确定性的但
    /// 夹具里的 FileChange 各自新建 UUID，故只比可比字段）。
    @Test("会话数不超过上限时，产出与「不封顶」的影子基线逐条一致")
    func capDoesNotChangeFindingsWithinLimit() {
        func feed(windows: Int) -> [(rule: String, session: UUID, level: RiskLevel, evidence: Int)] {
            let pipeline = RiskPipeline(bufferPolicy: riskPolicy(windows: windows))
            var produced: [(rule: String, session: UUID, level: RiskLevel, evidence: Int)] = []
            for _ in 0..<3 {
                let sessionID = UUID()
                for index in 0..<42 {
                    produced.append(contentsOf: pipeline.evaluate(RiskContext(
                        fileChange: deletion(index, sessionID: sessionID, at: RiskClock.after(Double(index))),
                        agentKind: .claudeCode, sessionID: sessionID
                    )).map { ($0.matchedRuleID ?? "-", $0.sessionID ?? sessionID, $0.level, $0.filePaths.count) })
                }
            }
            #expect(pipeline.activeWindowCount() == 3, "夹具自检：3 个会话键都该活着")
            return produced
        }

        let unbounded = feed(windows: .max)
        let bounded = feed(windows: 64)
        // 非空洞自检：这个夹具必须真的产出过 finding，否则「两份相等」是恒真式。
        #expect(!unbounded.isEmpty, "夹具没有产出任何风险事件，这条断言就恒真")
        #expect(unbounded.count == bounded.count)
        // 会话是随机 UUID，两份调用之间对不上号 ⇒ 只比与身份无关的那部分（规则、等级、证据条数）。
        #expect(unbounded.map(\.rule) == bounded.map(\.rule))
        #expect(unbounded.map(\.level) == bounded.map(\.level))
        #expect(unbounded.map(\.evidence) == bounded.map(\.evidence))
    }
}
