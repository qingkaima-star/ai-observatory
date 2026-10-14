//
//  DashboardEmptyStateAndSingleSourceTests.swift
//  Tests/AIObservatoryUITests
//
//  Owner: ws/summary（#85 重复标题与空态定高）
//  ─────────────────────────────────────────────────────────
//  #85 的两条判据都能写成"数得出来的东西"，所以这里一条也不做成"打开页面没崩"：
//
//  ① **空态不许钉死高度**。改前四处定高：`DashboardView` 空态 `minHeight: 260`、
//     柱图空态 180、异常卡 140、占比环 204 —— 首屏四张"什么都没有"的卡吃掉近 800 pt。
//     收高之后要防两件事：
//       · 有人把定高又加回空态那一支 ⇒ 逐支查"空态那一段里不许出现高度"；
//       · 有人拿"把图压扁 / 少画点"当省留白的路 ⇒ 正向钉一遍：有数据那一支的
//         `Sizing.chartHeight` 与 `BarMark` 的数据点写法一个都没少。
//     再把"面板内空"统一成基座的 `fills: false` 那一档：每个文件里空卡数与 `fills:false`
//     处数对齐 ⇒ 新加一张不写 `fills` 的空卡当场红（默认值是 `true`，会把面板撑满）。
//
//  ② **一个数、一个名字，只留一个出处**。台账第六节 S.3 点名的四对：
//     「活跃总时长」tile vs 环中心标签 / 页头「最近事件 N」vs 趋势卡那颗 /
//     「风险事件」tile vs「最近风险」panel 那颗「N 起」/
//     「当前运行中的 Agent」panel vs「活跃 Agent N」「N 个进程正在被观测」。
//     这里钉的是**不许回去**：同一个表达式在视图里只许出现一次，两个区块不许共用同一个标题。
//     再补一条通用的：**表里不许躺死文案**——只声明、只列进清单、没有任何调用点的条目，
//     正是"两处名字改了一处"留下的残骸（这一笔就清掉四条）。
//
//  尺子为什么取源码级而不是真无障碍树：同 `DashboardInformationArchitectureTests` 的头注
//  （`A11yTree.windowTexts()` 读的是本进程**所有**窗口，与并行的开窗套件互相污染）。
//  而且这一条问的是"同一个数出现几处"——读屏文本集合会把同一段里的两次重复并成一句，
//  数不出重复。项目里视图树与源码级两种先例都有，本套件取源码级。
//
//  ⚠️ 期望值全部手推（每个数的出处 = 1、首页空卡 = 5 张、空态分支里高度 = 0 处），
//     不是从实现反推出来的数字。
//

import Foundation
import Testing
@testable import AIObservatoryUI

@MainActor
@Suite("UI: #85 空态不钉高度 + 一个数只留一个出处", .timeLimit(.minutes(2)))
struct DashboardEmptyStateAndSingleSourceTests {

    private static let directory = "Sources/AIObservatoryUI/Dashboard"
    private static let tableFile = "Sources/AIObservatoryUI/Dashboard/DashboardCopy.swift"

    private let view = "Sources/AIObservatoryUI/Dashboard/DashboardView.swift"
    private let hourly = "Sources/AIObservatoryUI/Dashboard/DashboardHourlyActivityChart.swift"
    private let anomaly = "Sources/AIObservatoryUI/Dashboard/DashboardAnomalyCard.swift"
    private let share = "Sources/AIObservatoryUI/Dashboard/DashboardAgentShareReadout.swift"
    private let agents = "Sources/AIObservatoryUI/Dashboard/DashboardActiveAgentsList.swift"

    // MARK: - ① 空态定高

    @Test("五个空态分支都不许出现高度：空着的卡不占一页")
    func emptyStateBranchesCarryNoHeight() throws {
        // (文件, 空态那一支的起点锚, 该支结束之后的第一个成员锚)
        // ⚠️ 锚点必须**唯一定位到那一支**：`share` 那一条原先只写 `case.noData:`，结果先命中
        // 上面 `Shape.kinds` 里同名的 `case .noData: return 0`，于是把 `barHeight` 那条私有常量
        // 读成了"空态钉了高度"而误报——第一轮变异检查抓出来的就是这一处。
        let branches: [(file: String, start: String, end: String)] = [
            (view, "varemptyCard:someView{", "funcerrorCard("),
            (hourly, "ifhasActivity{chartfooter}else{", "privatevarchart:someView{"),
            (anomaly, "varemptyBody:someView{", "funcfailureRow("),
            (share, "switchSelf.shape(of:shares){case.noData:", "default:"),
            (agents, "ifagents.isEmpty{", "}else{"),
        ]
        for entry in branches {
            let code = try squeezed(entry.file)
            let branch = try Self.branch(after: entry.start, before: entry.end, in: code, file: entry.file)
            // 判据按**小写**取词：`maxHeight` 里那五个字母是大写开头的 `Height`，
            // 直接 `contains("height")` 数不到它 —— 第一轮变异检查（给空态加 `.frame(maxHeight:.infinity)`）
            // 就是这么从这条用例底下溜过去的，而"垂直撑满"恰恰是空态最该禁的那一种。
            let lowered = branch.lowercased()
            #expect(!lowered.contains("height"),
                    "\(entry.file) 的空态那一支又钉了高度（含 maxHeight）：\(branch)")
        }
    }

    @Test("全目录零数字高度：`frame(height: 260)` 那一类写法一处都不许留")
    func noNumericHeightsAnywhereInThePage() throws {
        for file in [view, hourly, anomaly, share, agents] {
            let code = try squeezed(file)
            for banned in ["frame(height:", "frame(minHeight:", "frame(maxHeight:"] {
                let hits = Self.numericHits(of: banned, in: code)
                #expect(hits.isEmpty, "\(file)：\(banned) 后面跟了数字字面量 \(hits)")
            }
            // 那条被删掉的私有常量也不许被"改个名又请回来"。
            #expect(!code.contains("emptyStateHeight"), "\(file)：空态定高的那条常量又回来了")
        }
    }

    @Test("面板内空一律走基座的 `fills: false`；首页五张空卡一张都不许漏")
    func everyEmptyStateIsTheCompactKind() throws {
        var total = 0
        for file in [view, hourly, anomaly, share, agents] {
            let code = try squeezed(file)
            let cards = Self.occurrences(of: "EmptyStateView(", in: code)
            let compact = Self.occurrences(of: "fills:false", in: code)
            #expect(cards == compact,
                    "\(file)：\(cards) 张空卡只对得上 \(compact) 处 `fills:false` ⇒ 有一张在撑高")
            total += cards
        }
        // 手推：首页五个空位（页面空态、柱图空态、异常卡空态、占比读数空态、Agent 列表空态）。
        #expect(total == 5, "首页空卡数量变了：\(total) 张")
    }

    @Test("省留白没省在读数上：柱图有数据那一支的图高与数据点一个没少")
    func theChartKeepsItsHeightAndItsPointsWhenThereIsData() throws {
        let code = try squeezed(hourly)
        // 空态收高之后，"整页看起来空了"只可能是因为图自己被压扁 ⇒ 正向钉一遍。
        let chart = try Self.branch(after: "privatevarchart:someView{",
                                    before: "privatevarfooter:someView{", in: code, file: hourly)
        #expect(Self.occurrences(of: ".frame(height:Sizing.chartHeight)", in: chart) == 1,
                "有数据那一支的图高必须仍钉在 Sizing.chartHeight（收高≠压扁图）")
        #expect(code.contains("BarMark(x:.value(axisColumnLabel,point.slot)"),
                "柱图的数据点写法变了 ⇒ 上面那条图高判据射程为零")
    }

    // MARK: - ② 一个数 / 一个名字，一个出处

    @Test("「风险事件」「最近事件」各只有一个出处：tile 与它下面那张卡不再并卖同一个数")
    func riskAndEventCountsHaveASingleSource() throws {
        let code = try squeezed(view)
        #expect(Self.occurrences(of: "stats.riskEventCount", in: code) == 1,
                "「风险事件」这个数在 DashboardView 里出现不止一次 ⇒「风险事件」tile 与「最近风险」panel 又在并卖")
        #expect(Self.occurrences(of: "model.hourlyEventTotal", in: code) == 1,
                "页头那颗「最近事件 N」与趋势卡自己那颗是同一个数，只许留一处")
        // 文案侧：调用点删了，条目必须跟着删——留下的是"下一次重复"的温床。
        let table = try tableText()
        for gone in ["recentRiskCount", "recentEventCount", "liveAgentsCaption",
                     "agentsObservedCaption", "agentsObserved"] {
            #expect(!table.contains("static let \(gone) = NamedCopy("),
                    "调用点已经删了，文案还留在表里：\(gone)")
        }
    }

    @Test("两个区块两个名字：清单卡标题不再被「当前状态」那格借用")
    func theListCardAndTheStatusTileHaveDifferentNames() throws {
        let listCode = try squeezed(agents)
        let viewCode = try squeezed(view)
        #expect(Self.occurrences(of: "agentsTitle", in: listCode) == 1, "清单卡标题的出处应当只有一处")
        #expect(!viewCode.contains("agentsTitle"),
                "第 3 档那格又去借第 2 档清单卡的标题 ⇒ 同一个标题一屏两遍")
        #expect(Self.occurrences(of: "tileCurrentRunning", in: viewCode) == 1,
                "「当前状态」那格必须有它自己的名字")
    }

    @Test("清单卡副标题只写口径不写数：那个数在第 3 档只出现一次")
    func theListCardSubtitleCarriesNoCount() throws {
        let code = try squeezed(agents)
        let header = try Self.branch(after: "SectionHeader(", before: "Text(uptimeSummary)",
                                     in: code, file: agents)
        #expect(!header.contains("count"), "清单卡标题区又自带一个数：\(header)")
        #expect(header.contains("agentsPolling"), "副标题必须仍是那句口径（引擎正在轮询进程表）")
    }

    @Test("同名只此一处：「活跃总时长」「当前运行中的 Agent」在文案表里各占一条")
    func sharedHeadingsAppearOnceInTheTable() throws {
        let lines = try tableText().split(separator: "\n").map { BilingualCopyGate.codeOnly($0) }
        for phrase in ["活跃总时长", "Total active time", "当前运行中的 Agent"] {
            let hits = lines.filter { $0.contains(phrase) }
            // 手推：只有它那一条声明行。多一条就是"同一个名字挂了两个地方"。
            #expect(hits.count == 1, "「\(phrase)」在文案表里出现 \(hits.count) 次，应为 1 次：\(hits)")
        }
    }

    @Test("表里不许躺死文案：每条声明都得有调用点（清单区与声明行本身不算）")
    func noDeclaredCopyWithoutACallSite() throws {
        // 份数下限：这条是 `HardcodedChineseRatchetTests.everyDirectoryGateDeclaresAFileCountFloor`
        // 要求按目录扫文件的套件都带的守卫——目录一旦改名，这里扫到 0 份，
        // 下面那条"死文案"判据会永远绿（本仓那一族：局部全绿、合起来是假话）。
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 7,
                "Dashboard 目录只扫到这么几份 .swift ⇒ 下面那条判据射程为零")
        var hay = ""
        for file in try BilingualCopyGate.swiftFiles(under: Self.directory) {
            let relative = "Sources/AIObservatoryUI/Dashboard/\(file.lastPathComponent)"
            // 剥注释/跳预览之后**先按行筛，再压空白**：压完就没有行可言了，
            // "把声明行剔掉"这件事必须在还有行的时候做（第一轮变异检查：
            // 先压空白再 filter 分隔符是 "\n"，等于什么都没筛，死文案从声明行自己身上"找到"了调用点）。
            var lines = try BilingualCopyGate.codeOnlyString(relative).split(separator: "\n")
                .filter { !$0.contains("= NamedCopy(") }
            if file.lastPathComponent == "DashboardCopy.swift" {
                // 「集中清单」那一段只是把名字列给门禁③遍历，不算调用点。
                let cut = lines.firstIndex { $0.contains("static let agentsCopy") } ?? lines.count
                lines = Array(lines[..<cut])
            }
            hay += lines.joined(separator: "\n")
        }
        // 取**标识符全集**再判成员，而不是 `hay.contains(name)`：后者会把"名字是别的词的子串"
        // 当成调用点（`rescan` 就藏在 `rescanNow` 里），那又是另一种假绿。
        let tokens = Set(hay.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "_" })
            .map(String.init))

        let declared = try declaredNames()
        #expect(declared.count >= 70, "只数出 \(declared.count) 条声明 ⇒ 解析方式跟表对不上了")
        let dead = declared.filter { !tokens.contains($0) }
        #expect(dead.isEmpty,
                "这 \(dead.count) 条文案没有任何调用点（改了调用点却没删文案）：\(dead)")
    }

    // MARK: - 源码取词小工具（与 `DashboardInformationArchitectureTests` 同一把尺子）

    private func squeezed(_ file: String) throws -> String {
        let code = try BilingualCopyGate.codeOnlyString(file)
        return code.split(whereSeparator: \.isWhitespace).joined()
    }

    private func tableText() throws -> String {
        let url = try BilingualCopyGate.repoRoot().appending(path: Self.tableFile)
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 文案表里声明的条目名（与门禁③ `declaredNamedCopyCount` 同一把尺子：同一行的
    /// `static let … = NamedCopy(`）。
    private func declaredNames() throws -> [String] {
        try tableText().split(separator: "\n").map { BilingualCopyGate.codeOnly($0) }.compactMap { line in
            guard line.contains("static let"), line.contains("= NamedCopy(") else { return nil }
            return line.components(separatedBy: "static let").last?
                .components(separatedBy: "=").first?.trimmingCharacters(in: .whitespaces)
        }
    }

    private static func branch(after start: String, before end: String, in code: String,
                               file: String) throws -> String {
        let opened = try #require(code.range(of: start), "\(file)：源码里找不到锚点 \(start)")
        let tail = code[opened.upperBound...]
        let closed = try #require(tail.range(of: end), "\(file)：锚点 \(start) 之后找不到收尾 \(end)")
        return String(tail[..<closed.lowerBound])
    }

    /// `needle` 之后紧跟一个数字的所有命中（"不许出现数字高度"用这条）。
    private static func numericHits(of needle: String, in code: String) -> [String] {
        var hits: [String] = []
        var search = code.startIndex
        while let found = code.range(of: needle, range: search..<code.endIndex) {
            let after = code[found.upperBound...]
            if let first = after.first, first.isNumber { hits.append(String(after.prefix(12))) }
            search = found.upperBound
        }
        return hits
    }

    private static func occurrences(of needle: String, in code: String) -> Int {
        var search = code.startIndex
        var count = 0
        while let found = code.range(of: needle, range: search..<code.endIndex) {
            count += 1
            search = found.upperBound
        }
        return count
    }
}
