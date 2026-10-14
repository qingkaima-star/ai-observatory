//
//  ColumnAlignmentTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/consistency（批 3 · #83 表格与数字列对齐）
//  ─────────────────────────────────────────────────────────
//  治的病：**列宽四页各一档、数字列连档都没有。**
//  本仓没有 `Table`/`LabeledContent`，列对齐全靠 `HStack + .frame(width:)` 手搓。
//  改之前实测（台账 整改波次-2026-09-22 第六节 C）：
//    `TimelineEventRow` 62/104/16/240、`PerformanceSessionBreakdown` 82/60/78、
//    `DashboardActiveAgentsList` 三列共用 88 且数字 `.leading`、`ProjectHotFilesPanel`
//    rank 20 `.trailing`；`CommandAuditRow` / `FileChangeRow` / `RiskEventRow`
//    三个数字列**无定宽**，只靠 `Spacer` 推右 ⇒ 跨行不成列。
//  两个同名的东西（"时间列"）在两张表里差 20pt，两个不同名的东西
//  （`readoutColumnWidth` 与 `cpuColumnWidth`）说的却是同一件事。
//
//  七道闸，各挡一种退化：
//  ① 行表里不许再出现 `.frame(width: <数字>)`，页内别名必须等于 `Column` 的某一档
//     （挡"下一个数从地里长出来"）。
//  ② 同一族列在**跨页**处必须等值（挡"收了又漂回去"——这一条钉的是值，不是文件名）。
//  ③ 数字列一律走 `axNumberColumn`，其实现里 `monospacedDigit` 与 `.trailing` 都要在场
//     （挡"只在某页顺手写个 .leading"）。
//  ④ `MetricGrid` 的列数不许是裸数字，只有点名豁免的三处例外
//     （菜单栏 2 列、会话详情 2 列、首页「当前状态」那组只有 1 格）。
//  ⑤ 反向：不许有人用 `Table`/`LabeledContent` 把取数路径重写一遍（#83 的边界）。
//  ⑥ **复核补的洞**：① 的射程是那七张行表，而"定宽 + 末位对齐"这一式在行表之外还活着
//     五格（菜单栏读数 46/62、diff 行号 44/44/36）——全 UI 扫描、零豁免。
//  ⑦ 那五格接的档位要**真的在调用点上**，且新档不许与既有数字档撞值。
//
//  ⚠️ 前三道都是**源码级接线**检查：视图没有测试宿主（本仓既有做法，
//  见 `AttributionCopyTests` 同一手法），只测令牌值证不了"某一页真的引用了它"。
//

import Foundation
import Testing
@testable import AIObservatoryUI

// `PerformanceSessionBreakdown.timeColumnWidth` 那几颗挂在 `View` 结构体上，
// 而 `View` 天然是 main-actor 隔离的 ⇒ 引用它们的用例必须同隔离（同 `AttributionCopyTests`
// 为 `AgentChip.displayedName` 做的选择：把用例标上隔离，而不是放宽生产代码的隔离性）。
@MainActor
@Suite("UI: #83 列宽与数字列对齐只有一个档位源", .timeLimit(.minutes(1)))
struct ColumnAlignmentTests {

    /// 这一批行表：列几何必须全部从 `Column` 取。
    private static let rowFiles: [String] = [
        "Sources/AIObservatoryUI/Timeline/TimelineEventRow.swift",
        "Sources/AIObservatoryUI/Performance/PerformanceSessionBreakdown.swift",
        "Sources/AIObservatoryUI/Dashboard/DashboardActiveAgentsList.swift",
        "Sources/AIObservatoryUI/Projects/ProjectHotFilesPanel.swift",
        "Sources/AIObservatoryUI/Commands/CommandAuditRow.swift",
        "Sources/AIObservatoryUI/Files/FileChangeRow.swift",
        "Sources/AIObservatoryUI/Security/RiskEventRow.swift",
    ]

    // MARK: ① 列宽只有一个出处

    @Test("七张行表里不许再出现写死的列宽，页内别名必须指向 Column 的某一档")
    func rowTablesTakeTheirWidthsFromTheTokenSource() throws {
        for relative in Self.rowFiles {
            let lines = try codeLines(relative)
            let hardcoded = lines.filter { $0.contains(".frame(width: ") && $0.hasDigitAfterFrameWidth }
            #expect(hardcoded.isEmpty,
                    "\(relative) 还有 \(hardcoded.count) 处写死列宽：\n\(hardcoded.joined(separator: "\n"))")
            let aliases = lines.filter { $0.contains("ColumnWidth: CGFloat =") || $0.contains("columnWidth: CGFloat =") }
            for alias in aliases where !alias.contains("Column.") {
                Issue.record("\(relative) 的列宽别名没取档位：\(alias)")
            }
            // 别名之外还得**真的用到**档位：只在常量里改个数、调用点留着旧的字面量，
            // 上面那条就抓不到（本仓"门禁看着在、射程盖不到"那一族）。
            #expect(lines.contains { $0.contains("axNumberColumn(") || $0.contains("axLeadingColumn(")
                    || $0.contains("axGlyphColumn(") },
                    "\(relative) 一个列修饰符都没用 ⇒ 这一页的对齐又回到各自手写")
        }
    }

    // MARK: ② 同一族列跨页等值

    @Test("同一族列在四页里等值（改前：时间列 62 与 82 并存、三列共用 88）")
    func sameFamilyColumnsAgreeAcrossPages() {
        #expect(TimelineMetrics.timeColumnWidth == Column.time)
        #expect(PerformanceSessionBreakdown.timeColumnWidth == Column.time)
        #expect(PerformanceSessionBreakdown.cpuColumnWidth == Column.percent)
        #expect(PerformanceSessionBreakdown.memoryColumnWidth == Column.memory)
        #expect(TimelineMetrics.agentColumnWidth == Column.agentIdentity)
        #expect(TimelineMetrics.symbolColumnWidth == Column.glyph)
        #expect(TimelineMetrics.detailColumnWidth == Column.detail)
        // 档位本身要互不相同（"统一"不等于"所有列同一个宽度"）：
        // 88 一档三用是改前的形状，那一档现在按内容拆成了百分比 / 内存 / 时长三档。
        let tiers: [CGFloat] = [Column.count, Column.percent, Column.duration,
                                Column.memory, Column.delta, Column.exitCode]
        #expect(Set(tiers).count == tiers.count, "数字档撞在一起了：\(tiers)")
    }

    // MARK: ③ 数字列同一对齐方向

    @Test("axNumberColumn = 等宽数字 + 末位对齐，且数字列的写法只许是它")
    func numberColumnsAllRunTheSameModifier() throws {
        let source = try codeLines("Sources/AIObservatoryUI/DesignSystem/Columns.swift")
            .joined(separator: "\n")
        #expect(source.contains("func axNumberColumn"), "档位源里没有数字列修饰符")
        #expect(source.contains(".monospacedDigit()"), "数字列没带等宽数字")
        #expect(source.contains("alignment: .trailing"), "数字列没统一成末位对齐")
        // 行表里不许再出现"数字列左对齐"那一式（改前三处共用 88 + .leading）。
        for relative in Self.rowFiles {
            let lines = try codeLines(relative)
            let leadingNumbers = lines.filter {
                $0.contains(".frame(width: ") && $0.contains("alignment: .leading")
            }
            #expect(leadingNumbers.isEmpty,
                    "\(relative) 还有定宽列自己写 .leading：\n\(leadingNumbers.joined(separator: "\n"))")
        }
    }

    // MARK: ④ 指标网格列数同一族

    /// 点名豁免：这三处不是"一排指标"，是各自窄版面里的字段排布。
    /// 豁免按 (文件, 那一行) 点名，且**反向要求那一行还在**——
    /// 改了实现却留着豁免，等于给下一处漏写档位的人留了个空位。
    private static let columnCountExemptions: [(file: String, needle: String)] = [
        ("Sources/AIObservatoryUI/Shell/MenuBarContentView.swift", "columns: 2"),
        ("Sources/AIObservatoryUI/Sessions/SessionDetailView.swift", "columns: 2"),
        ("Sources/AIObservatoryUI/Dashboard/DashboardView.swift", "columns: 1"),
    ]

    @Test("MetricGrid 的列数只从 Sizing 取；三处窄版面点名豁免且必须还在")
    func metricGridColumnCountsComeFromTokens() throws {
        // 份数下限：全 UI 扫描必须先证明"扫到了东西"，目录改名之后扫 0 份还报绿
        // 是本仓那一族（同 `HardcodedChineseRatchetTests` 的覆盖面闸）。
        #expect(try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI").count >= 100,
                "UI 目录读不到预期份数 ⇒ 这条闸扫的是空气")
        var offenders: [String] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = relativePath(of: url)
            guard !Self.columnCountExemptions.contains(where: { $0.file == relative }) else { continue }
            for line in try codeLines(relative) where line.contains("columns: ") {
                if line.hasDigitAfterKeyword("columns: ") { offenders.append("\(relative) → \(line)") }
            }
        }
        #expect(offenders.isEmpty, "又有人给指标网格写裸列数：\n\(offenders.joined(separator: "\n"))")

        // 正向：首页与时间线的"两行三列"用摘要档，安全页用默认档。
        let dashboard = try codeLines("Sources/AIObservatoryUI/Dashboard/DashboardView.swift")
            .joined(separator: "\n")
        #expect(dashboard.contains("columns: Sizing.summaryColumns"), "首页六格没接摘要档")
        let timeline = try codeLines("Sources/AIObservatoryUI/Timeline/TimelineView.swift")
            .joined(separator: "\n")
        #expect(timeline.contains("columns: Sizing.summaryColumns"), "时间线指标区没接摘要档")
        #expect(Sizing.metricColumns == 4 && Sizing.summaryColumns == 3)
        // 反向校准：豁免清单里那三行必须还在源码里（改完不收回去 = 豁免失效）。
        for exemption in Self.columnCountExemptions {
            let text = try codeLines(exemption.file).joined(separator: "\n")
            #expect(text.contains(exemption.needle),
                    "豁免清单里这条已经不在了 ⇒ 来删条目：\(exemption.file) ← \(exemption.needle)")
        }
    }

    // MARK: ⑤ 边界：不许借对齐之名重写取数路径

    @Test("没有引入 Table / LabeledContent（#83 的口径只做档位统一，不重写取数）")
    func noSecondTableImplementation() throws {
        var hits: [String] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let text = try codeLines(relativePath(of: url)).joined(separator: "\n")
            if text.contains("Table(") || text.contains("LabeledContent") {
                hits.append(url.lastPathComponent)
            }
        }
        #expect(hits.isEmpty, "列对齐整改里混进了新容器：\(hits)")
    }

    // MARK: ⑥ 「数字列」的射程不止那七张行表（#83 复核补的洞）

    /// 复核 #83 时现扫出来的两处：判据收的是"那七张行表"，而"定宽 + 末位对齐"这一式
    /// 在行表之外还活着五格——菜单栏读数两格（46 / 62）与 diff 的行号列（44 / 44 / 36）。
    /// 62 正是时间列改档之前的旧值（`Column.time` 现在是 68），44 与 36 是**同一个东西**
    /// （行号）在同一个文件的两种排法里各写各的。
    /// 这一道闸不给豁免：整个 UI 里"定宽 + `.trailing`"的数字格必须走 `axNumberColumn(档)`。
    @Test("全 UI 里『定宽 + 末位对齐』的数字格一处不剩（行表之外也算）")
    func trailingFixedWidthCellsAreAllOnATier() throws {
        var strays: [String] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = relativePath(of: url)
            for line in try codeLines(relative)
            where line.contains(".frame(width: ") && line.contains("alignment: .trailing")
                    && line.hasDigitAfterFrameWidth {
                strays.append("\(relative) → \(line)")
            }
        }
        #expect(strays.isEmpty,
                "又有一格数字列绕开档位自己写宽度：\n\(strays.joined(separator: "\n"))")
    }

    @Test("复核补的两处真的接在档位上（菜单栏两格 + diff 行号三格）")
    func lateTiersAreActuallyWired() throws {
        let menu = try codeLines("Sources/AIObservatoryUI/Shell/MenuBarContentView.swift")
        #expect(menu.contains { $0.contains("axNumberColumn(Column.percent)") },
                "菜单栏的 CPU 那一格没接百分比档")
        #expect(menu.contains { $0.contains("axNumberColumn(Column.memory)") },
                "菜单栏的内存那一格没接内存档")
        let diff = try codeLines("Sources/AIObservatoryUI/Files/DiffLineListView.swift")
            .joined(separator: "\n")
        let wired = diff.components(separatedBy: "axNumberColumn(Column.count)").count - 1
        #expect(wired == 3,
                "diff 的行号列只接了档位 \(wired) 处（应为 3：统一视图两格 + 并排视图一格）")
        // 同一个东西在两种排法里必须是同一个数（改前 44 与 36 并存）。
        #expect(Column.count == 44, "计数档改了值 ⇒ 行号那三格跟着漂，先回这里改注释")
        // 档位不许悄悄变多（#83 的反面是"12 个数装 11 件事"）。
        #expect(Column.allTiers.count == 11, "列档变成 \(Column.allTiers.count) 颗了 ⇒ 加档要写理由")
    }

    // MARK: 尺子

    private func codeLines(_ relative: String) throws -> [String] {
        try BilingualCopyGate.codeOnlyString(relative).split(separator: "\n").map(String.init)
    }

    /// 枚举回来的绝对路径 → 仓库相对路径（`BilingualCopyGate` 的读法都按相对路径收）。
    private func relativePath(of url: URL) -> String {
        "Sources/AIObservatoryUI/" + (url.path.components(separatedBy: "Sources/AIObservatoryUI/").last ?? "")
    }
}

private extension String {
    /// `.frame(width: 62…` 这一式：关键字之后第一个非空字符是数字。
    var hasDigitAfterFrameWidth: Bool {
        digitAfter(".frame(width: ")
    }

    func hasDigitAfterKeyword(_ keyword: String) -> Bool {
        digitAfter(keyword)
    }

    private func digitAfter(_ keyword: String) -> Bool {
        guard let found = range(of: keyword) else { return false }
        let tail = self[found.upperBound...]
        return tail.first.map { $0.isNumber } ?? false
    }
}
