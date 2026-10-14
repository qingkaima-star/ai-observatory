//
//  DashboardRangePassBenchmark.swift
//  Tests/AIObservatorySwiftDataStoreTests
//
//  Owner: master-controller（#93）
//  ─────────────────────────────────────────────────────────
//  ⚠️ **代码级**测量，不是真机验证。这条量的是"首页每一轮刷新向存储层问的那两问，
//  在『今天 / 7 天 / 全部』三档下各扫多少行、花多少时间"。它**不**替代真机读数，
//  也不给任何性能回归线（阈值一个都不设）——#75 那轮之后，"宽档到底贵多少"一直是空白，
//  本文件的产出就是**把那张表填上**，并让它可复算。
//
//  为什么可以只测存储层：`DashboardModel.load(live:)` 一次 pass 发四问
//  （`DashboardModel.swift:349` 那段 `async let`），其中**只有两问吃时间区间**：
//     · `dashboardStats(settledAt:within:)`
//     · `riskEvents(matching: RiskQuery(dateRange:limit:))`
//  另外两问（`activeAgents()`、`updates.currentState()`）与区间无关 ⇒ 三档之间它们恒等，
//  量了也不回答这个问题。所以"UI 每 pass 的区间成本" = 这两问之和。
//
//  本机实测（2026-09-23 本机，负载 5–20，取 5 次最小值；夹具 120 条/天 × 30 天）：
//     今天 120 行 ⇒ stats 0.11 ms + risk 0.07 ms = **0.18 ms**
//     7 天  841 行 ⇒ stats 0.32 ms + risk 0.28 ms = **0.60 ms**
//     全部 3 600 行 ⇒ stats 1.13 ms + risk 1.07 ms = **2.20 ms**
//  ⇒ 行数 ×30、这两问只贵 ×12（**次线性**）；绝对量级仍在毫秒档 ⇒ "宽档把首页拖垮"这条
//    在本机这个规模下**不成立**，#75 当年被压到的不是这两问。真机每 pass 的其余常数（渲染、
//    增量合并、分析层）不在本文件射程，别拿这张表替它们说话。
//
//  单变量的成立条件（这才是本文件真正的内容）：夹具按**每天等量**生成，
//  于是"7 天档扫的行数"必须是"今天档"的整 7 倍、"全部档"是 30 倍——**这个比例是先写死再量的**，
//  对不上就是夹具串了档，那测出来的时间差没有解释力（本仓吃过多次"分母没人能复算"的亏）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

@Suite("存储层：#93 首页 pass 在三档区间下的行数量级（代码级）", .serialized, .timeLimit(.minutes(3)))
struct DashboardRangePassBenchmark {

    /// 夹具的时间跨度与每日密度。**改这两个数就等于换了一道题**，下面的比例断言会当场拦住。
    private static let days = 30
    private static let perDay = 120

    private static let settledAt = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func range(_ offset: Int, _ second: Int) -> Date {
        settledAt.addingTimeInterval(-Double(offset) * 86_400 + Double(second) * 60)
    }

    /// 三档：今天 / 最近 7 天 / 全部。区间语义与界面用的那几个工厂**同一份**（不另造一把尺）。
    private static var tiers: [(name: String, range: DateRangeFilter)] {
        [("今天", .today(settledAt)), ("7天", .lastHours(7 * 24, now: settledAt)), ("全部", .unbounded)]
    }

    @MainActor private static func seededStore() async throws -> ObservatoryStore {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let agent = UUID()
        let session = AgentSession(kind: .claudeCode, title: "区间基准会话",
                                   projectPath: "/Users/dev/bench",
                                   startedAt: range(days, 0), modifiedFileCount: perDay,
                                   commandCount: perDay / 4, outcome: .running)
        try await store.upsertSessions([session])
        var risks: [RiskEvent] = []
        for day in 0..<days {
            for index in 0..<perDay {
                let at = range(day, index)
                await store.append(TimelineEvent(timestamp: at,
                                                 agentID: agent, agentKind: .claudeCode,
                                                 kind: .fileModified,
                                                 title: "第 \(day) 天第 \(index) 条",
                                                 summary: "区间基准事件",
                                                 projectPath: "/Users/dev/bench"))
                if index % 4 == 0 {
                    await store.append(FileChange(path: "/Users/dev/bench/Sources/F\(day)_\(index).swift",
                                                  kind: .modified, timestamp: at,
                                                  agentID: agent, agentKind: .claudeCode,
                                                  linesAdded: index, linesRemoved: 1))
                    await store.append(CommandRecord(executable: "git", arguments: ["status"],
                                                     agentID: agent, startedAt: at,
                                                     endedAt: at.addingTimeInterval(2),
                                                     exitCode: 0, outcome: .success))
                }
                if index % 20 == 0 {
                    risks.append(RiskEvent(timestamp: at, level: .high, category: .dangerousCommand,
                                           title: "基准高风险", detail: "夹具",
                                           agentID: agent, agentKind: .claudeCode))
                }
                await store.append(SystemPerformanceSample(timestamp: at, cpuTotalPercent: 40,
                                                           cpuSystemPercent: 10, cpuUserPercent: 30,
                                                           memoryUsedBytes: 4_000_000_000,
                                                           memoryTotalBytes: 16_000_000_000,
                                                           diskReadBytesPerSecond: 1_000,
                                                           diskWriteBytesPerSecond: 2_000,
                                                           loadAverage1m: 2))
            }
        }
        try await store.recordRisks(risks)
        await store.flush()
        return store
    }

    /// 取 5 次里的**最小值**：本机 load 常年 5–20，中位数照样被别的进程抬高，
    /// 最小值是这台机器能给出的最接近"没有外来干扰"的数。这不是回归线，只是**同一把尺的读法**。
    private static func bestOf(_ body: () async throws -> Void, runs: Int = 5) async throws -> Double {
        let clock = ContinuousClock()
        var best = Double.greatestFiniteMagnitude
        for _ in 0..<runs {
            let start = clock.now
            try await body()
            let parts = start.duration(to: clock.now).components   // 读**一次**：两次取时刻会把差算成 0
            best = min(best, Double(parts.seconds) + Double(parts.attoseconds) / 1e18)
        }
        return best
    }

    @Test("三档各扫多少行、这两问各花多少 ms——表打出来，比例算式钉住")
    func rowScalingAndPassCost() async throws {
        let store = try await Self.seededStore()

        var table: [String] = []
        var eventsByTier: [Int] = []
        for tier in Self.tiers {
            // 行数量：与计时**分开**问一次，免得把 COUNT 的开销算进 pass 里。
            let rows = try await store.events(matching: EventQuery(dateRange: tier.range, limit: 1))
            let eventRows = rows.totalCount
            eventsByTier.append(eventRows)

            let statsSeconds = try await Self.bestOf {
                _ = try await store.dashboardStats(settledAt: Self.settledAt, within: tier.range)
            }
            let riskSeconds = try await Self.bestOf {
                _ = try await store.riskEvents(matching: RiskQuery(dateRange: tier.range, limit: 200))
            }
            let stats = try await store.dashboardStats(settledAt: Self.settledAt, within: tier.range)
            table.append("\(tier.name):事件行\(eventRows)｜stats \(String(format: "%.2f", statsSeconds * 1_000))ms"
                         + "｜risk \(String(format: "%.2f", riskSeconds * 1_000))ms"
                         + "｜合计 \(String(format: "%.2f", (statsSeconds + riskSeconds) * 1_000))ms"
                         + "→ 会话\(stats.sessionCount) 变更\(stats.filesModified) 命令\(stats.commandsExecuted) 高危\(stats.highRiskEventCount)")
        }
        print("#93 代码级 pass 对账（每天等量 \(Self.perDay) 条 × \(Self.days) 天）：" + table.joined(separator: " ⏐ "))

        // ① 单变量成立：三档的事件行数必须是 1× / 7× / 30× 的关系（夹具按天等量生成的定义）。
        let today = eventsByTier[0], week = eventsByTier[1], all = eventsByTier[2]
        #expect(today == Self.perDay, "今天档应有 \(Self.perDay) 行（一天的量），实得 \(today) ⇒ 夹具串了档")
        // 7 天档实测 841 = 120×7 **+1**：`DateRangeFilter.contains` 的语义是**两端闭区间**
        // （契约里明写的约定），所以正好落在 `start` 上的那一颗也被算进来。
        // 这个 +1 就是那条语义的读数——哪天它变成半开区间，这里会红着提醒（那是一次数值口径变更，不是笔误）。
        #expect(week == today * 7 + 1,
                "7 天档应是 120×7 再多加边界那一颗（\(today * 7 + 1)），实得 \(week) ⇒ 区间没承重或边界语义变了，时间差没有解释力")
        #expect(all == today * Self.days, "全部档应是今天的 \(Self.days) 倍（\(today * Self.days)），实得 \(all)")

        // ② 区间真的在收窄聚合结果（不是"三档算出同一个数"的那种假基准）。
        let statsToday = try await store.dashboardStats(settledAt: Self.settledAt, within: Self.tiers[0].range)
        let statsAll = try await store.dashboardStats(settledAt: Self.settledAt, within: Self.tiers[2].range)
        #expect(statsAll.filesModified > statsToday.filesModified,
                "全部档的变更数 \(statsAll.filesModified) 没超过今天档 \(statsToday.filesModified) ⇒ 区间没进到 SQL 里")
        // 单调包含：今天 ⊆ 7 天 ⊆ 全部，同一列必须单调。
        let statsWeek = try await store.dashboardStats(settledAt: Self.settledAt, within: Self.tiers[1].range)
        #expect(statsToday.commandsExecuted <= statsWeek.commandsExecuted
                && statsWeek.commandsExecuted <= statsAll.commandsExecuted,
                "命令数在三档间不单调（\(statsToday.commandsExecuted)/\(statsWeek.commandsExecuted)/\(statsAll.commandsExecuted)）⇒ 区间边界算错")
    }
}
