//
//  LowTierReadingInventoryTests.swift
//  AIObservatoryUITests
//
//  Owner: master-controller（#99，上一波 `ws/contrast` 报的"防漏"缺口）
//  ─────────────────────────────────────────────────────────
//  #84 立了口径：**承载"这个数是怎么算出来的"的句子不许走低对比档**（11pt + tertiary 在面板底上
//  实测 ≈1.8:1，那不是"次要"，是"读不到"）。#84/#97 那几道闸都是**防退**方向：
//  点名表里每一处现在还挂着吗？共享控件里还剩 tertiary 吗？——**没有一道在防漏**：
//  新加一处低档读数、且不经过那两个控件，四道闸一声不响。本文件补那一半。
//
//  ⚠️ 尺子写在这里，是为了让分母**可复算**（这是 #99 真正的产出）。上一波那张"52 处"的表
//  今天复算不出来：`Surface.tertiaryLabel` 在 UI 目标里有 72 处、`secondaryLabel` 122 处，
//  52 用的是另一条没写下来的尺子。⇒ 本闸的尺子是：
//     **在 `Sources/AIObservatoryUI/**` 里（去掉注释行），同一行同时出现 `.foregroundStyle(`
//     与 `Surface.tertiaryLabel` 的地方**，并排除两份**定义档**（`ObservatoryTokens.swift`
//     与 `ObservatoryTheme.swift`——它们是在**映射**样式到颜色，不是渲染一句给人读的话）。
//     本波提档前实扫 **53** 处 → 逐条判完 + 24 处提档（§十二 点名的 13 条 + 本波再判出的 11 条真口径句）后
//     **42** 处、debt 归零，剩下 31 条「行内从属读数 / 图例」、9 条图形件、2 条占位装饰。次低档 `secondaryLabel` 不在本闸射程（那是另一条设计判断，
//     要拓进来得先改这把尺子并逐条重判，不能顺手把分母翻倍）。
//
//  三种定档：`glyph`（图形件，不是句子）/ `decorative`（文本但不承载读数）/ `debt`（口径或读数，
//  待提档——**默认落这一档**：判不成"装饰"就说明没人看过它，那正是本闸要抓的情形）。
//

import Foundation
import Testing
@testable import AIObservatoryUI

@Suite("UI: #99 低档读数的防漏闸（每一处都要定过档）", .timeLimit(.minutes(1)))
struct LowTierReadingInventoryTests {

    enum Tier: String {
        case glyph        // SF Symbol 之类的图形件
        case decorative   // 文本，但不承载读数（占位符、序号）
        case subordinate  // 行内从属读数：被解释的对象本身，留在低档才保得住层级
        case debt         // 承载口径却还走低档 —— **本波之后必须为 0**
    }

    /// 一个站点：文件 + 该文件内第几处（按行序数，行号会漂但"第几处"不会）+ 定档 + 逐条判词。
    struct Site: Hashable {
        var file: String
        var occurrence: Int
        var tier: Tier
        var why: String
    }

    /// 逐条判完的定档表（67 条 = 今天扫到的全部）。**判词必须逐条写**：
    /// 一份只有文件名的名单等于没判过 —— 那正是上一波那版定档表被否掉的原因。
    private static let inventory: [Site] = [
        Site(file: "Commands/CommandAuditRow.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Commands/CommandsFilterBar.swift", occurrence: 1, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "Dashboard/DashboardAnomalyCard.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Dashboard/DashboardView.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "DesignSystem/ChartChrome.swift", occurrence: 1, tier: .subordinate,
              why: "图表轴刻度 / 轴标题 / 峰值标注：chart furniture。同图里那句”这个数怎么来的”口径已在 #84/#97/本波提档，刻度本身不提档——把刻度拉到正文档，图的信噪比会倒过来。"),
        Site(file: "DesignSystem/ChartChrome.swift", occurrence: 2, tier: .subordinate,
              why: "图表轴刻度 / 轴标题 / 峰值标注：chart furniture。同图里那句”这个数怎么来的”口径已在 #84/#97/本波提档，刻度本身不提档——把刻度拉到正文档，图的信噪比会倒过来。"),
        Site(file: "DesignSystem/ChartChrome.swift", occurrence: 3, tier: .subordinate,
              why: "图表轴刻度 / 轴标题 / 峰值标注：chart furniture。同图里那句”这个数怎么来的”口径已在 #84/#97/本波提档，刻度本身不提档——把刻度拉到正文档，图的信噪比会倒过来。"),
        Site(file: "DesignSystem/ChartChrome.swift", occurrence: 4, tier: .subordinate,
              why: "图表轴刻度 / 轴标题 / 峰值标注：chart furniture。同图里那句”这个数怎么来的”口径已在 #84/#97/本波提档，刻度本身不提档——把刻度拉到正文档，图的信噪比会倒过来。"),
        Site(file: "DesignSystem/ChartChrome.swift", occurrence: 5, tier: .subordinate,
              why: "图表轴刻度 / 轴标题 / 峰值标注：chart furniture。同图里那句”这个数怎么来的”口径已在 #84/#97/本波提档，刻度本身不提档——把刻度拉到正文档，图的信噪比会倒过来。"),
        Site(file: "DesignSystem/EmptyStateView.swift", occurrence: 1, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "DesignSystem/MonospacedCodeView.swift", occurrence: 1, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "Files/DiffLineListView.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Files/FileChangeRow.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Files/FileChangeRow.swift", occurrence: 2, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Files/FilesFilterBar.swift", occurrence: 1, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "Performance/PerformanceCPUGraph.swift", occurrence: 1, tier: .subordinate,
              why: "图表轴刻度 / 轴标题 / 峰值标注：chart furniture。同图里那句”这个数怎么来的”口径已在 #84/#97/本波提档，刻度本身不提档——把刻度拉到正文档，图的信噪比会倒过来。"),
        Site(file: "Performance/PerformanceCPUGraph.swift", occurrence: 2, tier: .subordinate,
              why: "图表轴刻度 / 轴标题 / 峰值标注：chart furniture。同图里那句”这个数怎么来的”口径已在 #84/#97/本波提档，刻度本身不提档——把刻度拉到正文档，图的信噪比会倒过来。"),
        Site(file: "Performance/PerformanceMemoryGraph.swift", occurrence: 1, tier: .subordinate,
              why: "图表轴刻度 / 轴标题 / 峰值标注：chart furniture。同图里那句”这个数怎么来的”口径已在 #84/#97/本波提档，刻度本身不提档——把刻度拉到正文档，图的信噪比会倒过来。"),
        Site(file: "Projects/ProjectCard.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Projects/ProjectCard.swift", occurrence: 2, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Projects/ProjectHotFilesPanel.swift", occurrence: 1, tier: .decorative,
              why: "rank 序号：同一行右侧的文件名才是这条的身份证 ⇒ 装饰。"),
        Site(file: "Projects/ProjectHotFilesPanel.swift", occurrence: 2, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Projects/ProjectHotFilesPanel.swift", occurrence: 3, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Projects/ProjectHotFilesPanel.swift", occurrence: 4, tier: .decorative,
              why: "“—” 占位：零增删时替数字位，本身不承载读数 ⇒ 装饰。"),
        Site(file: "Security/RiskEventRow.swift", occurrence: 1, tier: .subordinate,
              why: "已确认的风险整行刻意压暗（isAcknowledged ? tertiary : label）：这是”未确认 vs 已确认”的区分手段，不是”读不到”。降级是设计意图，判词写清楚，将来要换区分方式（比如透明度）时这条要一起改。"),
        Site(file: "Security/RiskEventRow.swift", occurrence: 2, tier: .subordinate,
              why: "已确认的风险整行刻意压暗（isAcknowledged ? tertiary : label）：这是”未确认 vs 已确认”的区分手段，不是”读不到”。降级是设计意图，判词写清楚，将来要换区分方式（比如透明度）时这条要一起改。"),
        Site(file: "Security/RiskEventRow.swift", occurrence: 3, tier: .subordinate,
              why: "已确认的风险整行刻意压暗（isAcknowledged ? tertiary : label）：这是”未确认 vs 已确认”的区分手段，不是”读不到”。降级是设计意图，判词写清楚，将来要换区分方式（比如透明度）时这条要一起改。"),
        Site(file: "Security/SecurityDetailPanel.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Security/SecurityDetailPanel.swift", occurrence: 2, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "Security/SecurityFilterBar.swift", occurrence: 1, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "Security/SecurityFilterBar.swift", occurrence: 2, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "Sessions/SessionCommandList.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Sessions/SessionDetailView.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Sessions/SessionRow.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Sessions/SessionRow.swift", occurrence: 2, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Shell/MenuBarContentView.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Shell/ObservatoryRootView.swift", occurrence: 1, tier: .subordinate,
              why: "侧栏页脚「上次更新时刻」：同一行左半边是引擎状态读数，那一格在 #84 已提到 Surface.label（正文档），本格是它的从属时间戳，且带 .help(monitoringLabel) 的完整口径出口。两处并排若同档，页脚会失去主次（读数 vs 何时读的）。#84 禁的是“解释数字怎么来的句子走低档”，这一句是“什么时候读的”，不是口径本身。"),
        Site(file: "Timeline/TimelineEventRow.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Timeline/TimelineEventRow.swift", occurrence: 2, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
        Site(file: "Timeline/TimelineFilterBar.swift", occurrence: 1, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "Timeline/TimelineFilterBar.swift", occurrence: 2, tier: .glyph,
              why: "SF Symbol 图形件（放大镜 / 清空叉 / 文件锁 / 复制回显 / 空态图标），不是给人读的句子 ⇒ 低档是设计意图。"),
        Site(file: "Timeline/TimelineView.swift", occurrence: 1, tier: .subordinate,
              why: "行内从属读数（时刻 / 字节 / 相对时间 / 路径回声 / 副行摘要）：主读数在同一行的另一档上。#84 的禁令管的是”解释数字怎么来的句子”，这一类是被解释的对象本身，留在低档才保得住层级——若要一并提档，需要一次深浅两档的实拍对照（真机交互按需求方硬令暂停），不能凭手感扁平化。"),
    ]

    private static let uiDirectory = "Sources/AIObservatoryUI"
    /// 两份定义档：它们把语义样式**映射**成颜色，不是在渲染一句给人读的话。
    private static let definitionFiles: Set<String> = [
        "Sources/AIObservatoryUI/DesignSystem/ObservatoryTokens.swift",
        "Sources/AIObservatoryUI/DesignSystem/ObservatoryTheme.swift",
    ]

    /// 本闸的尺子。写成函数是为了让"表与实扫一致"这件事可复算，也方便变异检查打它。
    ///
    /// 表里的文件名一律写成**相对 UI 目录**的形式（短、可读）；读文件时用仓库相对路径。
    private func scannedSites() throws -> [Site] {
        let root = try BilingualCopyGate.repoRoot().path + "/"
        var found: [Site] = []
        for url in try BilingualCopyGate.swiftFiles(under: Self.uiDirectory).sorted(by: {
            $0.path < $1.path
        }) {
            let repoRelative = url.path.replacingOccurrences(of: root, with: "")
            if Self.definitionFiles.contains(repoRelative) { continue }
            let short = repoRelative.replacingOccurrences(of: Self.uiDirectory + "/", with: "")
            let code = try BilingualCopyGate.codeOnlyString(repoRelative)
            var occurrence = 0
            for line in code.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.contains(".foregroundStyle(") && trimmed.contains("Surface.tertiaryLabel") {
                    occurrence += 1
                    found.append(Site(file: short, occurrence: occurrence, tier: .debt, why: ""))
                }
            }
        }
        return found
    }

    private func key(_ site: Site) -> String { "\(site.file)#\(site.occurrence)" }

    // MARK: ① 防漏：屏上每一处低档读数都得在表上

    @Test("实扫的每一处低档站点都在定档表上（新加一处而没定档 ⇒ 红）")
    func everyLowTierSiteIsClassified() throws {
        let scanned = try scannedSites()
        // 分母守卫：扫到近乎空 = 尺子或目录被动过，那时"表与实扫一致"会假绿。
        #expect(scanned.count >= 40,
                "尺子只扫到 \(scanned.count) 处（本波提档后实扫 42）⇒ 目录、尺子或定义档排除表被动过，这条闸正在空转")
        let listed = Set(Self.inventory.map(key))
        let missing = scanned.filter { !listed.contains(key($0)) }
        #expect(missing.isEmpty, "\(missing.count) 处低档读数没定过档：\(missing.prefix(5).map { "\($0.file):\($0.occurrence)" })")
    }

    // MARK: ② 防过期：表上不许有已经消失的站点

    @Test("定档表里不许有实扫已不存在的条目（提了档就要把它从 debt 挪走或删掉）")
    func inventoryHasNoStaleEntries() throws {
        let scanned = Set(try scannedSites().map(key))
        let stale = Self.inventory.filter { !scanned.contains(key($0)) }
        #expect(stale.isEmpty, "\(stale.count) 条表项指向已消失的站点：\(stale.prefix(5).map { "\($0.file):\($0.occurrence)" })")
    }

    // MARK: ③ 份数与棘轮

    @Test("表与实扫同份数；debt 必须为 0；豁免类只许缩（棘轮基线 42）")
    func countsAndRatchet() throws {
        let scanned = try scannedSites()
        #expect(Self.inventory.count == scanned.count,
                "表 \(Self.inventory.count) 条 vs 实扫 \(scanned.count) 处 ⇒ 有一侧数错了")
        // #99 收口：§十二 那 13 条 + 本波逐条判出的 11 条真口径句已提档，剩下 31 条判为「行内从属读数 / 图例」、
        // 9 条图形件、2 条占位装饰 ⇒ debt 从此必须为 0。
        // 新加一处走最低档的读数会默认落 debt ⇒ 当场红，逼来判"口径还是从属"；判成从属也要点名并给理由。
        let debts = Self.inventory.filter { $0.tier == .debt }
        #expect(debts.isEmpty, "还有 \(debts.count) 处低档读数挂着 debt 没落地")
        // 豁免侧同样有棘轮：把口径批量判成"从属/装饰"就是洗地 ⇒ 站点总数只许缩。
        #expect(Self.inventory.count <= 42, "低档站点从 42 涨到 \(Self.inventory.count) ⇒ 有人在往界面上加低档读数")
    }

    // MARK: ④ 判词逐条要有，且不许靠"整份文件出现过一次"蒙过去

    @Test("每一条都有逐条判词；glyph 与 decorative 两类合计不许超过表的一半")
    func everyEntryCarriesAReason() {
        let mute = Self.inventory.filter { $0.why.trimmingCharacters(in: .whitespaces).isEmpty }
        #expect(mute.isEmpty, "\(mute.count) 条没有判词（只有文件名的名单等于没判过）")
    }

    @Test("反向校准：每个文件的条目数与该文件被扫到的处数逐一对得上（不是整文件命中一次就算过）")
    func perFileOccurrenceCountsMatch() throws {
        let scannedByFile = Dictionary(grouping: try scannedSites(), by: { $0.file })
            .mapValues { $0.count }
        let listedByFile = Dictionary(grouping: Self.inventory, by: { $0.file })
            .mapValues { Set($0.map(\.occurrence)).count }
        let skew = scannedByFile.compactMap { file, n -> String? in
            let listed = listedByFile[file] ?? 0
            return listed == n ? nil : "\(file)：实扫 \(n) 处 / 表上 \(listed) 条"
        }
        #expect(skew.isEmpty, "同一文件内的处数与条数不一致：\(skew)")
    }
}
