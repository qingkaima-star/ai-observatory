//
//  PerformanceBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10nb（B3 最后三页 · 性能）
//  ─────────────────────────────────────────────────────────
//  与 `CommandsBilingualCopyGateTests` 同一套七道门禁（推导写在那份文件头）。
//  本页另有两条只属于它的检查：
//   ① **图例与 `series` 取值同源**——`ChartLegend(label:)` 和 `series: .value(…, 值)` 必须是
//      同一条文案；两处各译一次就会出现「线叫 User、图例叫 user」的第二出处（本仓头号缺陷族）。
//   ② **Swift Charts 的 `.value(标签, …)` 不许残留中文**——轴标签会进图例与 VoiceOver
//      （同 `DashboardCopy` 立的口径），而它长得很像"给编译器看的键名"，最容易漏。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 性能页双语门禁（表合格 + 全列进清单 + 图例同源 + 表真喂到屏上）", .timeLimit(.minutes(2)))
struct PerformanceBilingualCopyGateTests {

    private static let directory = "Sources/AIObservatoryUI/Performance"
    private static let tableFile = "Sources/AIObservatoryUI/Performance/PerformanceCopy.swift"

    /// 允许两语逐字同串的条目：本表没有。
    private static let sharedStringAllowlist: [String] = []

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: PerformanceCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: PerformanceCopy.bilingualCopy).isEmpty)
    }

    @Test("每条声明过的文案都列进了清单（漏列 = 门禁看不见这一条）")
    func everyDeclaredEntryIsListed() throws {
        let declared = try B3PageCopyGate.declaredTemplateCount(in: Self.tableFile)
        #expect(declared == PerformanceCopy.bilingualCopy.count,
                "表文件声明了 \(declared) 条 LocalizedString，清单只有 \(PerformanceCopy.bilingualCopy.count) 条")
    }

    /// 现值 **128** 条：`grep -c 'NamedCopy("performance\.'` 与
    /// `grep -c 'static let .* = LocalizedString('` 同为 128（量词走 `countedItems` 不进表）。
    @Test("清单非空")
    func tablePopulated() {
        #expect(PerformanceCopy.bilingualCopy.count >= 120,
                "清单只剩 \(PerformanceCopy.bilingualCopy.count) 条 ⇒ 有人删了表却没删调用点")
    }

    @Test("每条都真的译了：英文不与中文逐字相同（例外清单点名）")
    func everyEntryTranslated() {
        let untranslated = PerformanceCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }
        #expect(untranslated.map(\.name) == [])
        let shared = PerformanceCopy.bilingualCopy
            .filter { $0.copy.english == $0.copy.chineseSimplified }
            .map(\.name)
        #expect(shared.sorted() == Self.sharedStringAllowlist.sorted(),
                "两语同串的条目和例外清单对不上：实际 \(shared)，清单 \(Self.sharedStringAllowlist)")
    }

    @Test("英文侧不残留汉字（半截英文 = 没译完）")
    func englishHasNoResidualChinese() {
        let mixed = PerformanceCopy.bilingualCopy.filter { $0.copy.english.containsHan }
        #expect(mixed.map(\.name) == [], "英文里夹着汉字：\(mixed.map(\.name))")
    }

    @Test("英文侧没有「数字紧跟复数名词」（复数没有机制，只能靠写法）")
    func englishAvoidsPluralTrap() {
        let traps = B3PageCopyGate.pluralTrapNames(in: PerformanceCopy.bilingualCopy)
        #expect(traps == [], "这些条目的英文是 \"%d 名词s\" 形状：\(traps)")
    }

    @Test("Performance 目录里不再有写死的中文文案（注释与预览脚手架除外）")
    func noHardcodedChineseOutsideTheTable() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 13,
                "Performance 目录读不到预期数量的文件")
        let strays = try BilingualCopyGate.chineseLiterals(
            under: Self.directory, excluding: ["PerformanceCopy.swift"]
        )
        #expect(strays.isEmpty,
                "这 \(strays.count) 行还写着中文，没走 PerformanceCopy：\n\(strays.joined(separator: "\n"))")
    }

    // MARK: 本页特有

    /// 图例与 `series` 取值必须来自**同一条**文案：`ChartLegendIdentityTests` 管 id 不撞，
    /// 这条管名字同不同源——不同源就是同一根线有两个名字，英文态最明显。
    @Test("四张图的图例名与 series 取值同一条出处（两语言都同）")
    func legendLabelsShareOneSourceWithSeriesValues() throws {
        let code = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryUI/Performance/PerformanceCPUGraph.swift")
        #expect(code.contains("label: PerformanceCopy.cpuUser.text(language)")
                && code.contains("PerformanceCopy.cpuUser.text(language)"),
                "CPU 图的「用户」在图例与 series 里不再是同一条文案")
        let disk = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryUI/Performance/PerformanceDiskIOGraph.swift")
        #expect(disk.contains("label: PerformanceCopy.diskRead.text(language)")
                && disk.contains("PerformanceCopy.diskRead.text(language)"),
                "磁盘 IO 图的「读取」两处不同源")
        let net = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryUI/Performance/PerformanceNetworkGraph.swift")
        #expect(net.contains("label: PerformanceCopy.networkDown.text(language)")
                && net.contains("PerformanceCopy.networkDown.text(language)"),
                "网络图的「下行」两处不同源")
    }

    /// 单位一律写成单复数同形的缩写（`s` / `MB` / `GB`）：这一页全是"数字 + 单位"，
    /// 拼成 "seconds" 就一定会在某个窗口长度上渲染成 "1 seconds"。
    @Test("时长与节拍用缩写单位，英文侧不出现 spelled-out seconds")
    func durationsUsePluralInvariantUnits() {
        // %.0f 的实参必须是 Double：喂 Int 会得到 0（这条一开始就喂错了，是用例的错）。
        #expect(PerformanceCopy.intervalWholeSeconds.format(.english, 3.0) == "3 s")
        #expect(PerformanceCopy.intervalFractionSeconds.format(.english, 0.4) == "0.4 s")
        #expect(PerformanceCopy.verdictWindowForming.format(.english, 47)
                == "Window only 47 s — no verdict yet")
        #expect(PerformanceCopy.selfVerdictNeedsWindow.format(.english, 60)
                == " Needs a window of at least 60 s to judge.")
        #expect(PerformanceCopy.selfCadenceFragment.format(.english, "12") == " · averaging 12 s per sample")
        #expect(!PerformanceCopy.bilingualCopy.contains { $0.copy.english.contains("seconds") },
                "英文侧写了 spelled-out seconds ⇒ 命中一秒时就是 1 seconds")
    }

    /// 达标结论行的**拼接结构**不许动：CPU 句 + 内存句 + 至多一个追加片段，
    /// 空格位置逐字对账（`SelfProcessGaugeTests` 钉中文侧，这里钉片段边界）。
    @Test("达标结论由两段拼成，追加片段各自带前导空格")
    func verdictLineKeepsItsFragmentBoundaries() {
        #expect(PerformanceCopy.selfVerdictCPU.text(.english).hasSuffix(" "))
        #expect(PerformanceCopy.selfVerdictCPU.text(.chineseSimplified).hasSuffix("。"))
        for fragment in [PerformanceCopy.selfVerdictNeedsWindow,
                         PerformanceCopy.selfVerdictNoSystemSample,
                         PerformanceCopy.selfVerdictBusyMachine] {
            #expect(fragment.text(.chineseSimplified).hasPrefix(" "), "追加片段的前导空格会决定句号位置")
            #expect(fragment.text(.english).hasPrefix(" "))
        }
    }
}
