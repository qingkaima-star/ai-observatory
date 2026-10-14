//
//  ReadoutEconomyTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · 全站「同一个数说几遍」口径）
//  ─────────────────────────────────────────────────────────
//  总控 2026-09-21 定的全站口径：**一个数字在一屏内只许出现两次**——
//    ① hero / 概览那一次（口径 caption 附在它下面）；
//    ② 需要操作语义时那一次（如分页的「已加载 M / 共 N」）。
//  其余复述一律删。措辞统一成「服务端匹配总数 · 与分页无关」，
//  不许再有「且已全部加载到本页」这种**只在特定分页状态下才真**的说法
//  （分页状态一变文案没跟着变，就是界面在说谎）。
//
//  ⚠️ 这条闸量的是「代码里把同一个量插进字符串几处」，它是**棘轮不是证明**：
//  互斥分支（空态 vs 有数据）会让 textual 计数高于同屏数，所以每一行都在注释里
//  写清那几个位点分别是谁、为什么同屏不超过两次。新增一处就必须重新审一次并改数字——
//  这正是这条用例的作用：它不给"顺手再写一遍"留活口。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

@Suite("UI: 全站读数经济性（一个数一屏最多两次）", .timeLimit(.minutes(2)))
struct ReadoutEconomyTests {

    // MARK: 措辞

    @Test("全站措辞 = 手推字面量，且只有一个出处")
    func canonicalWordingHasOneSource() throws {
        #expect(ReadoutCopy.serverTotalCaption == "服务端匹配总数 · 与分页无关")
        // 这句话在别处再打一遍字面量 = 第二个出处，改口径时必然漏改。
        var offenders: [String] = []
        for (file, line) in try codeLines(under: "Sources/AIObservatoryUI") {
            if file.hasSuffix("DesignSystem/ReadoutCopy.swift") { continue }
            if line.contains("服务端匹配总数 · 与分页无关") { offenders.append(file) }
        }
        #expect(offenders.isEmpty, "第二处字面量：\(offenders)")
    }

    @Test("禁句不许回到屏上：「已全部加载到本页」这类条件性说法")
    func conditionalClaimsAreBanned() throws {
        let banned = ["已全部加载到本页", "还没加载到本页", "服务端匹配总数，"]
        var hits: [String] = []
        for (file, line) in try codeLines(under: "Sources/AIObservatoryUI") {
            for phrase in banned where line.contains(phrase) {
                hits.append("\(file) → \(phrase)")
            }
        }
        #expect(hits.isEmpty, "条件性口径句回到了代码里：\(hits)")
    }

    @Test("五页的 hero 口径都走同一个常量")
    func everyServerTotalCaptionUsesTheConstant() throws {
        // Sessions / Timeline / Commands / Files 四页有「服务端匹配总数」这一格口径；
        // Projects 页没有服务端分页（一次拉全表），所以不在名单里。
        let pages = [
            "Sessions/SessionsView.swift", "Timeline/TimelineView.swift",
            "Commands/CommandsView.swift", "Files/FilesView.swift",
        ]
        for page in pages {
            let text = try source("Sources/AIObservatoryUI/\(page)")
            #expect(text.contains("ReadoutCopy.serverTotalCaption"), "\(page) 没接常量")
        }
    }

    // MARK: 每页位点预算（审计结论钉在这张表里）

    @Test("各页把同一个量插进字符串的处数 = 审计值")
    func renderSiteBudgetPerPage() throws {
        let table: [(page: String, quantity: String, expected: Int, sites: String)] = [
            ("Timeline", "model.totalCount", 3,
             "hero 大数 + 空态那句「服务端匹配 N 条」（两者互斥：空态分支不画 hero）"
             + "+ 模型里那句「已加载 M / 共 N」（只被本节标题读一次，见下面 loadedProgressText）"),
            ("Timeline", "model.events.count", 1,
             "只剩模型里那句「已加载 M / 共 N」（② 分页位点）。hero 那行原来还排着一个"
             + "「本页已加载 M 条」，全部加载完时同一串数字会在屏上出现三次 ⇒ 已删，"
             + "见 removedRestatementsStayRemoved"),
            ("Timeline", "model.loadedProgressText", 1,
             "只被本节标题 `streamSubtitle` 读一次（流末尾那句「已到最早事件 · …」已去掉数字）"),
            ("Timeline", "model.activeFilterCount", 4,
             "屏上两处：过滤条那颗 chip + hero 那行 InlineStat；另两处是 `.accessibilityLabel`"
             + "（读屏会念，不画在屏上）"),
            ("Commands", "model.totalCount", 2,
             "页头 `progressText`「共 N 条命令 · 已加载 M」（在模型里）+「命令总数」那格大数"),
            ("Commands", "model.records.count", 1,
             "只在模型的 `progressText` 里；三个 tile caption 里那个「已加载 N 条」已删（口径由页头说）"),
            ("Commands", "model.progressText", 1,
             "页头一处；loading 面板里那句一模一样的复述已删"),
            ("Files", "model.totalCount", 1,
             "页头「共 N 个变更」；hero caption 改走常量后不再重复这个数"),
            ("Files", "model.changes.count", 1, "hero caption 的「已加载 N 条事件去重」"),
            ("Projects", "model.projects.count", 2,
             "页头「可见 X / 共 N 个项目」+ 全被筛掉那句；hero caption 的数已删"),
            ("Projects", "model.filteredProjects.count", 2, "页头 + hero 大数（① 与 ②）"),
            ("Projects", "model.liveProjectCount", 1,
             "「实时命中 N 个项目」那一格；订阅状态那颗 Tag 只报状态不报数"),
        ]
        for row in table {
            // **整页文本一起扫**，不逐行：B3 迁移把多参数 `format(...)` 的实参表换行了
            // （`ProjectsView.swift:71-72` 就是 `format(language,\n  a, b)`），
            // 逐行扫会把"实参在下一行"的位点数成 0 ⇒ 棘轮会因为**排版**变松。
            // 这与"预览豁免按括号配对而不是判到文件尾"是同一条教训：
            // 按行切的仪器，换个写法就能悄悄漏掉。
            let text = try codeLines(under: "Sources/AIObservatoryUI/\(row.page)").map(\.line).joined(separator: "\n")
            let hits = displaySites(in: text, quantityName: row.quantity)
            #expect(hits == row.expected,
                    "\(row.page) 的 \(row.quantity) 有 \(hits) 处（审计值 \(row.expected)：\(row.sites)）")
        }
    }

    /// 这一行把那个量**插进字符串**了几次。两种写法都要认，否则 B3 双语迁移会把
    /// 棘轮读成"位点减少了"：
    /// ① `\(model.totalCount)` —— 迁移前的唯一写法；
    /// ② `SomeCopy.someCount.format(language, model.totalCount)` —— 迁移后位置参数入位
    ///    （派单要求②：多参数一律 `%1$@`/`%2$d`，裸插值不允许）。
    /// 刻意**不数** `if model.activeFilterCount > 0` 这类条件表达式：本用例问的是
    /// "这个数字被排上屏几次"，条件判断不上屏。把它算进来会让每一次加判断都要重审全表。
    private func displaySites(in text: String, quantityName: String) -> Int {
        let bare = quantityName.hasPrefix("model.")
            ? String(quantityName.dropFirst("model.".count)) : quantityName
        var hits = 0
        for needle in Set([quantityName, bare]) { hits += occurrences(text, "\\(\(needle))") }
        var cursorFrom = text.startIndex
        while let found = text.range(of: "format(", range: cursorFrom..<text.endIndex) {
            // 括号配对切实参表，允许跨行；本仓 `format` 实参里没有字符串内的裸括号。
            var depth = 1
            var cursor = found.upperBound
            while cursor < text.endIndex, depth > 0 {
                let ch = text[cursor]
                if ch == "(" { depth += 1 }
                else if ch == ")" { depth -= 1; if depth == 0 { break } }
                cursor = text.index(after: cursor)
            }
            let arguments = String(text[found.upperBound..<cursor])
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "model.", with: "")
            hits += standaloneOccurrences(arguments, bare)
            cursorFrom = found.upperBound
        }
        return hits
    }

    /// 只数"独立出现"的名字：前面接字母/数字/下划线/点的一律不算。
    /// 少了这条，`Text(...format(language, bucket.events.count))` 会被当成
    /// `model.events.count` 的位点——可那是"某一天分组有几条"，跟"本页已加载多少条"
    /// 是两个不同的量，混数会让棘轮在别人加一行分组计数时无故变红。
    private func standaloneOccurrences(_ haystack: String, _ name: String) -> Int {
        var count = 0
        var search = haystack.startIndex
        while let found = haystack.range(of: name, range: search..<haystack.endIndex) {
            let before = found.lowerBound
            let isStandalone = before == haystack.startIndex
                || { let c = haystack[haystack.index(before, offsetBy: -1)]
                    return !c.isLetter && !c.isNumber && c != "_" && c != "." }()
            if isStandalone { count += 1 }
            search = found.upperBound
        }
        return count
    }

    @Test("健康卡里那三个派生数只报一遍（breakdown 三格），detail 行不再复述")
    func healthCardNumbersAppearOnce() throws {
        let detail = AnalysisPresentation.healthDetail(.resolved(ProjectHealthSnapshot(
            projectPath: "/Users/demo/Projects/Mona",
            riskCounts: AnalysisRiskCounts(critical: 1, high: 2, medium: 3, low: 4),
            anomalyCount: 2, efficiencyScore: 0.5,
            verdict: .watch, generatedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )))
        #expect(!detail.contains("风险"), "\(detail)")
        #expect(!detail.contains("异常"), "\(detail)")
        #expect(!detail.contains("单位产出"), "\(detail)")
        #expect(detail.hasPrefix("分析于 "), "\(detail)")
        // 而三个数确实还在——由同一张卡上方的 breakdown 三格报（删了就是丢信息）。
        let card = try source("Sources/AIObservatoryUI/Projects/ProjectHealthCard.swift")
        #expect(card.contains("riskBreakdownText"))
        #expect(card.contains("anomalyText"))
        #expect(card.contains("efficiencyText"))
    }

    @Test("删掉的复述不许长回来：过滤条尾签与 loading 面板那句")
    func removedRestatementsStayRemoved() throws {
        // ⚠️ 只看代码行：这几处**为什么删**的解释注释里就带着被删的那几个字
        // （「还有 N 条未加载」），拿整份文件比就会自己抓自己。
        // 命令页扫**整个目录**：#66 把它拆成 CommandsView / CommandAuditRow /
        // CommandsDetailView / CommandsFilterBar 四份，只盯容器那份 = 把另三份放进盲区。
        let commands = try codeOnlyDirectory("Sources/AIObservatoryUI/Commands")
        #expect(!commands.contains("countLabel"), "过滤条尾部那个「N 条命令」又回来了")
        #expect(!commands.contains("Text(\"条命令\")"), "服务端总数的第三次出现回来了")
        let timeline = try codeOnly("Sources/AIObservatoryUI/Timeline/TimelineView.swift")
        #expect(!timeline.contains("条未加载"), "流末尾那个未加载数回来了")
        #expect(!timeline.contains("已到最早事件 ·"), "「已到最早事件」后面又挂了计数")
        // hero 那一行不许再排「本页已加载 M 条」：M 归流标题（② 分页位点）。
        // 全部加载完的那一屏会让同一串数字出现三次（真机 01:57 实拍过）。
        // 上面那张预算表也会红（`events.count` 从 1 变 2）——这条是给**读日志的人**看的：
        // 表只报"处数不对"，这一条直接说出是哪一格长回来了。
        #expect(!timeline.contains("InlineStat(\"本页已加载\""), "hero 行又排了已加载条数")
    }

    // MARK: 扫描工具

    private enum EconomyError: Error { case noRepoRoot, unreadable(String) }

    /// 该目录下所有**非注释**代码行（整行注释与「空格+//」之后的行文都不算上屏字符串）。
    private func codeLines(under relative: String) throws -> [(file: String, line: String)] {
        let root = try repoRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root.appending(path: relative),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var out: [(file: String, line: String)] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "swift" else { continue }
            let relativePath = String(file.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: file, encoding: .utf8)
            for raw in text.split(separator: "\n") {
                let body = raw.components(separatedBy: " //").first ?? ""
                let trimmed = body.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") { continue }
                out.append((relativePath, body))
            }
        }
        return out
    }

    private func occurrences(_ haystack: String, _ needle: String) -> Int {
        var count = 0
        var search = haystack.startIndex
        while let found = haystack.range(of: needle, range: search..<haystack.endIndex) {
            count += 1
            search = found.upperBound
        }
        return count
    }

    /// 整份文件的**代码行**（注释与行文都不算）。
    /// 整页目录的代码行拼接（按枚举、不按文件名清单）——见 `removedRestatementsStayRemoved` 的用法。
    private func codeOnlyDirectory(_ relativeDirectory: String) throws -> String {
        let directory = try repoRoot().appending(path: relativeDirectory)
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        #expect(!files.isEmpty, "\(relativeDirectory)：枚举不到 .swift ⇒ 路径写错了")
        return try files
            .map { try codeOnly("\(relativeDirectory)/\($0.lastPathComponent)") }
            .joined(separator: "\n")
    }

    private func codeOnly(_ relative: String) throws -> String {        let text = try source(relative)
        return text.split(separator: "\n")
            .map { line in String(line.components(separatedBy: " //").first ?? "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: try repoRoot().appending(path: relative), encoding: .utf8)
    }

    private func repoRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) else {
            throw EconomyError.noRepoRoot
        }
        return url
    }
}
