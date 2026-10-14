//
//  DashboardShareReadoutTests.swift
//  Tests/AIObservatoryUITests
//
//  Owner: ws/summary（#80 占比环改紧凑读数）
//  ─────────────────────────────────────────────────────────
//  旧的那张 `SectorMark` 环给的是**假读数**：载荷按 `AgentKind` 逐种分组、
//  没有记录的种类不进表（`ObservatoryStore+Queries.swift` 的 `agentShares(for:until:)`），
//  所以"只有一种 Agent 跑过"是常态；那种情况下环必为一整圈、图例那一条恒印 100.0 %，
//  而 `totalSeconds` 全 0 时旧实现还用 `max(1, sessionCount)` 凑分母。
//
//  本套件钉的是**读数形状**，不是"没崩"：
//    ① 单序列不许出现 100 %（连百分比这个位置都不许有）；
//    ② 无数据 ≠ 100 %，也 ≠ 0 %：它必须是"无数据"那一档，一行都不摆；
//    ③ 多序列的百分比 = 手推的分数（分母只含有记录那些条），且加起来是 100 %；
//    ④ 没有兜底分母：全 0 的条目不参与、不制造 1；
//    ⑤ 环与其中心那行「活跃总时长」都不回来了（#85：同一个数只留一个出处）。
//
//  ⚠️ 期望值全部手推（7200 / 3600 / 1500 / 420 那一组是把分数写在纸上算的），
//     不是从实现返回值抄回来的。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

@MainActor
@Suite("UI: #80 Agent 时长紧凑读数（单序列不印 100 %、无数据明写无数据）")
struct DashboardShareReadoutTests {

    private static let claude = AgentUsageShare(kind: .claudeCode, sessionCount: 6, totalSeconds: 7_200)
    private static let cursor = AgentUsageShare(kind: .cursorAgent, sessionCount: 3, totalSeconds: 3_600)
    private static let codex = AgentUsageShare(kind: .openAICodex, sessionCount: 2, totalSeconds: 1_500)
    private static let generic = AgentUsageShare(kind: .genericCLIAgent, sessionCount: 1, totalSeconds: 420)
    /// 载荷里出现过、但一场会话都没有：它不能把"单序列"撑成"两家"。
    private static let emptyRow = AgentUsageShare(kind: .cursorAgent, sessionCount: 0, totalSeconds: 0)

    // MARK: ① 单序列

    @Test("只有一种 Agent 有记录 ⇒ 形状是单序列，那一行**没有百分比**可印")
    func singleSeriesCarriesNoPercentageAtAll() {
        let shares = [Self.claude]
        #expect(DashboardAgentShareReadout.shape(of: shares) == .singleSeries)

        let rows = DashboardAgentShareReadout.rows(for: shares)
        #expect(rows.count == 1)
        // 判据的核心不是"百分比是不是 100"，而是**这一档压根不给百分比**：
        // 100 % 是恒真命题，删掉它才对；把 nil 写成 0 % 同样是假读数（那是"查过，一点没有"）。
        #expect(rows[0].sharePercent == nil,
                "单序列又给出占比了：\(String(describing: rows[0].sharePercent))")

        // 绝对量必须还在（不印占比不等于不报数）。
        #expect(rows[0].sessionCount == 6)
        #expect(rows[0].durationText == "2h0m")   // 7 200 s = 2 小时整
    }

    @Test("两行载荷里只有一行有记录 ⇒ 仍是单序列，空的那行不许把占比算成 100 / 0")
    func aZeroRowDoesNotTurnOneSeriesIntoTwo() {
        let shares = [Self.claude, Self.emptyRow]
        #expect(DashboardAgentShareReadout.shape(of: shares) == .singleSeries,
                "有记录的种数把 0 会话那条也算进去了 ⇒ 又回到「一整圈 + 100 %」")
        let rows = DashboardAgentShareReadout.rows(for: shares)
        #expect(rows.count == 1)
        #expect(rows.allSatisfy { $0.sharePercent == nil })
    }

    // MARK: ② 无数据

    @Test("没有会话记录 ⇒ 形状是无数据、一行都不摆（既不是 100 % 也不是 0 %）")
    func noDataIsItsOwnShapeAndRendersNoRows() {
        for shares in [[], [Self.emptyRow]] {
            #expect(DashboardAgentShareReadout.shape(of: shares) == .noData)
            let rows = DashboardAgentShareReadout.rows(for: shares)
            #expect(rows.isEmpty, "无数据还排了 \(rows.count) 行 ⇒ 那一行只能印出一个凭空的百分比")
            #expect(!DashboardAgentShareReadout.usesDuration(shares))
        }
    }

    // MARK: ③ 多序列：分数手推

    @Test("两家有记录 ⇒ 7200∶3600 = 66.7 % ∶ 33.3 %（手推），分母只含有记录那些")
    func twoSeriesReportHandComputedShares() {
        let shares = [Self.claude, Self.cursor]
        #expect(DashboardAgentShareReadout.shape(of: shares) == .multipleSeries(kinds: 2))
        let rows = DashboardAgentShareReadout.rows(for: shares)
        #expect(rows.map(\.kind) == [.claudeCode, .cursorAgent], "行序按时长降序：\(rows.map(\.kind))")
        // 手推：总时长 10 800 s。7 200 / 10 800 = 2/3 ⇒ 66.7 %；3 600 / 10 800 = 1/3 ⇒ 33.3 %。
        let texts = rows.map { $0.sharePercent.map { PercentFormat.short($0, fractionDigits: 1) } }
        #expect(texts == ["66.7%", "33.3%"], "占比与手推值不符：\(texts)")
        let sum = rows.compactMap(\.sharePercent).reduce(0, +)
        #expect(abs(sum - 100) < 0.001, "占比之和 \(sum) 不是 100 ⇒ 分母掺了别的东西")
    }

    @Test("四家有记录 ⇒ 7200/3600/1500/420 的手推占比 56.6 / 28.3 / 11.8 / 3.3")
    func fourSeriesMatchHandComputedTable() {
        let shares = [Self.generic, Self.codex, Self.cursor, Self.claude]   // 故意乱序喂进去
        let rows = DashboardAgentShareReadout.rows(for: shares)
        #expect(DashboardAgentShareReadout.shape(of: shares) == .multipleSeries(kinds: 4))
        // 总 12 720 s。7 200→0.5660→56.6 %；3 600→0.2830→28.3 %；1 500→0.1179→11.8 %；420→0.0330→3.3 %。
        #expect(rows.map(\.kind) == [.claudeCode, .cursorAgent, .openAICodex, .genericCLIAgent],
                "行序没按时长降序：\(rows.map(\.kind))")
        let texts = rows.map { $0.sharePercent.map { PercentFormat.short($0, fractionDigits: 1) } }
        #expect(texts == ["56.6%", "28.3%", "11.8%", "3.3%"], "占比表与手推值不符：\(texts)")
    }

    @Test("时长全为 0 但有会话 ⇒ 分母换成会话数并明写这一档（3∶1 ⇒ 75 % / 25 %）")
    func sessionCountMeasureIsDeclaredNotSilentlySwapped() {
        let shares = [
            AgentUsageShare(kind: .claudeCode, sessionCount: 3, totalSeconds: 0),
            AgentUsageShare(kind: .cursorAgent, sessionCount: 1, totalSeconds: 0),
        ]
        #expect(!DashboardAgentShareReadout.usesDuration(shares))
        #expect(DashboardAgentShareReadout.shape(of: shares) == .multipleSeries(kinds: 2))
        let rows = DashboardAgentShareReadout.rows(for: shares)
        let texts = rows.map { $0.sharePercent.map { PercentFormat.short($0, fractionDigits: 1) } }
        #expect(texts == ["75.0%", "25.0%"], "按会话数档的占比不符：\(texts)")
        #expect(rows.allSatisfy { $0.durationText == "0s" })
    }

    // MARK: ④ 不许有兜底分母

    @Test("度量函数没有 `max(1, …)` 那一档兜底：0 就是 0，不凑分母")
    func metricHasNoInflatedDenominator() {
        let zero = AgentUsageShare(kind: .claudeCode, sessionCount: 0, totalSeconds: 0)
        #expect(DashboardAgentShareReadout.metric(zero, durationBased: true) == 0)
        #expect(DashboardAgentShareReadout.metric(zero, durationBased: false) == 0)
        // 兜底写法（`max(1, sessionCount)`）会把这一条变成 1 ⇒ 除出来的百分比是编的。
        #expect(DashboardAgentShareReadout.metric(zero, durationBased: true) != 1)
        #expect(DashboardAgentShareReadout.metric(zero, durationBased: false) != 1)
        #expect(DashboardAgentShareReadout.hasRecord(zero) == false)
        #expect(DashboardAgentShareReadout.hasRecord(
            AgentUsageShare(kind: .claudeCode, sessionCount: 1, totalSeconds: 0)))
    }

    // MARK: ⑥ 复核 #80：把"仍然合法的 100 %"与"当初那个假 100 %"区分开

    @Test("两家有记录、但只有一家有时长 ⇒ 100 %/0 % 是真读数（分母明写是时长），不是当初那个恒真命题")
    func aRealHundredPercentStillRequiresTwoRecordedKinds() {
        // 复核 #80 时挖出来的边界：当初的环在**只有一种 Agent 有记录**时也印 100.0 %，
        // 那一句是恒真命题（"它占全部"）⇒ 现在那一档根本不给百分比（见①）。
        // 但这里这一档不一样：两家都有记录，只是其中一家的时长恰好是 0（会话开了还没结算出时长）。
        // 分母 = 有记录那些种的时长之和 = 10 800 s，A 占满 ⇒ 100 %，B 占 0 % ——
        // 0 % 那一条自己就证明了这不是"除了 100 % 什么都不说"的同义反复。
        let shares = [
            AgentUsageShare(kind: .claudeCode, sessionCount: 3, totalSeconds: 10_800),
            AgentUsageShare(kind: .cursorAgent, sessionCount: 2, totalSeconds: 0),
        ]
        #expect(DashboardAgentShareReadout.shape(of: shares) == .multipleSeries(kinds: 2),
                "有记录的种数不该把 0 时长那条丢掉：会话数就是它的记录")
        #expect(DashboardAgentShareReadout.usesDuration(shares), "有任何时长 ⇒ 分母走时长")
        let rows = DashboardAgentShareReadout.rows(for: shares)
        let texts = rows.map { $0.sharePercent.map { PercentFormat.short($0, fractionDigits: 1) } }
        #expect(texts == ["100.0%", "0.0%"], "这一档的占比与手推值不符：\(texts)")
        // 0 % 那一行必须**还在**：把它当"没有记录"偷偷丢掉，就又回到只剩一家、恒印 100 % 的老路。
        #expect(rows.count == 2, "0 时长那条被丢了 ⇒ 屏上只剩一家，100 % 又变成同义反复")
    }

    @Test("占比只在分母为 0 时不给；有分母就不许把 0 % 那一行藏起来")
    func aZeroShareRowIsReportedRatherThanDropped() {
        let rows = DashboardAgentShareReadout.rows(for: [
            AgentUsageShare(kind: .claudeCode, sessionCount: 3, totalSeconds: 10_800),
            AgentUsageShare(kind: .cursorAgent, sessionCount: 2, totalSeconds: 0),
        ])
        // 变异探针认这一格：把 `total > 0` 写成 `total > 0 && value > 0`，
        // 0 % 那条就变成 nil（屏上少一行、百分比之和照样 100 %，看着更"干净"，但是假读数）。
        #expect(rows[1].sharePercent == 0, "0 % 那一行被当成没有占比了：\(String(describing: rows[1].sharePercent))")
    }

    // MARK: ⑤ 环不回来，重复标题也不回来

    @Test("源码里既没有 `SectorMark` 也没有兜底分母，且没新增自绘坐标轴")
    func theRingAndTheFallbackAreGone() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Dashboard/DashboardAgentShareReadout.swift")
        for banned in ["SectorMark", "Chart(", "chartLegend", "max(1,", "chartXAxis", "chartYAxis",
                       "import Charts"] {
            #expect(!code.contains(banned), "紧凑读数里又出现了 \(banned)：环/兜底/自绘轴不能复活")
        }
        // 固定尺寸的圆环卡死了窄窗口（旧文件头就记着真机上图例被压成单字一列）。
        #expect(!code.contains("156"), "又给读数钉了 156pt 的固定尺寸")
    }

    @Test("「活跃总时长」这一屏只剩一个出处：读数卡里不许再有那五个字")
    func activeDurationTitleHasOneSourceOnly() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Dashboard/DashboardAgentShareReadout.swift")
        let table = try String(
            contentsOf: BilingualCopyGate.repoRoot()
                .appending(path: "Sources/AIObservatoryUI/Dashboard/DashboardCopy.swift"),
            encoding: .utf8)
        // 中文与英文两侧都不许在 share.* 那一段里再出现「活跃总时长 / Total active time」。
        let shareSection = table.components(separatedBy: "// MARK: Agent 时长读数")
            .last?.components(separatedBy: "// MARK: 异常卡").first ?? ""
        #expect(!shareSection.contains("活跃总时长"), "环中心那个标签还在文案表里")
        #expect(!shareSection.contains("Total active time"), "英文侧同一条也要一起清掉")
        #expect(!code.contains("活跃总时长"), "读数卡自己又把总时长报了一遍（hero 格已经报了）")
        // 唯一的出处仍然是时段累计第一格。
        #expect(DashboardCopy.tileActiveDuration.text(.chineseSimplified) == "活跃总时长")
    }
}
