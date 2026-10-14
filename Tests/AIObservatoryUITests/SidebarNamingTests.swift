//
//  SidebarNamingTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · P1 同一目的地两个名字）
//  ─────────────────────────────────────────────────────────
//  钉住「板块名只有一个出处」这件事。缺陷形状：同一个目的地有**三套**名字——
//  侧栏 `SidebarSection.title`（英文）、`boardTitle`（中文）、各页
//  `ObservatoryPage("…")` 里手写的第三套中文，于是「操作时间线 / 行为时间线」
//  「终端命令审计 / 命令审计」「文件行为 / 文件变更」在屏幕上同时存在。
//  收成一个属性后有**四个出口**读它：侧栏行、页内 hero、`.navigationTitle`（= 窗口标题栏）、
//  `.accessibilityLabel`（读屏听到的页名）。
//
//  为什么用例长这样：光断言 `title` 的值只能证明**一处**没跑掉，同源这件事要能
//  在**改回去**时变红，就得逐行去读那九个页面源文件和那张 shell 表——
//  它们是同一句话的另两个出口，任何一处重新写字面量，三处同源当场破。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 板块名同源（侧栏 / 页内 hero / 窗口标题栏 / 读屏标签）", .timeLimit(.minutes(1)))
struct SidebarNamingTests {

    /// 九条「板块 → 该页外层容器文件」的对应，顺序即侧栏展示顺序。
    private static let pageFiles: [(section: SidebarSection, file: String)] = [
        (.dashboard, "Sources/AIObservatoryUI/Dashboard/DashboardView.swift"),
        (.sessions, "Sources/AIObservatoryUI/Sessions/SessionsView.swift"),
        (.timeline, "Sources/AIObservatoryUI/Timeline/TimelineView.swift"),
        (.commands, "Sources/AIObservatoryUI/Commands/CommandsView.swift"),
        (.files, "Sources/AIObservatoryUI/Files/FilesView.swift"),
        (.performance, "Sources/AIObservatoryUI/Performance/PerformanceView.swift"),
        (.security, "Sources/AIObservatoryUI/Security/SecurityView.swift"),
        (.projects, "Sources/AIObservatoryUI/Projects/ProjectsView.swift"),
        (.settings, "Sources/AIObservatoryUI/Settings/SettingsView.swift"),
    ]

    // MARK: 值本身

    /// 【为什么这里**必须**显式传语言】B3 起 `section.title` 跟随宿主系统语言，
    /// 而测试进程的语言 = 跑测试那台机器的语言。原来那两条写字面量中文的用例
    /// 在中文机器上是绿的、换到英文机器会红（且红得像是"标题被人改了"）。
    /// ⇒ 逐字断言一律走 `title(_:)`，中文英文各钉一遍，宿主语言无关。
    @Test("九个板块名两语各自 = 手推字面量（逐位，含顺序）")
    func titlesAreExactlyTheseNineNamesInBothLanguages() {
        #expect(SidebarSection.allCases.map { $0.title(.chineseSimplified) } == [
            "今日概览", "AI 会话", "行为时间线", "命令审计", "文件变更",
            "系统性能", "安全风险", "项目活动地图", "设置",
        ])
        // 英文侧按 macOS 侧栏的写法取短名（Today / Settings），不是逐字对译；
        // 大小写是 HIG 的句首大写口径，见 `ShellCopy.sectionTitleCopy` 上方那段。
        #expect(SidebarSection.allCases.map { $0.title(.english) } == [
            "Today", "AI sessions", "Activity timeline", "Command audit", "File changes",
            "Performance", "Security risks", "Project activity map", "Settings",
        ])
    }

    @Test("两语各自互不相同、非空，且没有一个退化成英文 rawValue")
    func titlesAreDistinctAndNotRawValues() {
        for language in [AppLanguage.chineseSimplified, .english] {
            let titles = SidebarSection.allCases.map { $0.title(language) }
            #expect(Set(titles).count == 9, "\(language) 板块名重复：\(titles)")
            #expect(Set(titles).count == Set(titles.map { $0.lowercased() }).count,
                    "\(language) 板块名只在大小写上不同 ⇒ 护栏按整串比对时容易看漏：\(titles)")
            for section in SidebarSection.allCases {
                let title = section.title(language)
                #expect(!title.isEmpty)
                // rawValue 是路由键（也是 AIOBSERVATORY_SECTION 的取值），不是给人看的名字。
                #expect(title != section.rawValue, "\(section.rawValue) 漏回英文")
                switch language {
                case .chineseSimplified:
                    // 侧栏定宽 216 pt（`Sizing.sidebarWidth`）⇒ 6 个汉字以上要换行，
                    // 「项目活动地图」正好压在上限，再长就得改宽度而不是改名字。
                    #expect(title.count <= 6, "\(title) 超出侧栏宽度预算")
                case .english:
                    // 英文侧不能照抄 6：ASCII 每字符约 6.5 pt，216 pt 减图标与左右内边距
                    // 后还能放 ~26 个字符。这里钉 20（现值最长是 "Project Activity Map"），
                    // 是一条**只紧不松**的棘轮：真机有没有顶破仍以英文态实拍为准。
                    #expect(title.count <= 20, "\(title) 超出侧栏宽度预算")
                    // 英文侧混进汉字 = 这条根本没译完，护栏按整串比对时看不出来。
                    #expect(!title.containsHan, "\(title) 里混着汉字")
                }
            }
        }
    }

    /// 跨语言也要互不撞名：护栏拿窗口标题判断落在哪一页，
    /// 中文那套的一个名字撞上英文那套的一个名字，就等于两个板块共用一个标题。
    @Test("18 条板块名（九板块 × 两语言）两两互不相同")
    func titlesAreDistinctAcrossLanguages() {
        let all = SidebarSection.allCases.flatMap { [$0.title(.chineseSimplified), $0.title(.english)] }
        #expect(all.count == 18)
        #expect(Set(all).count == 18, "跨语言撞名：\(all)")
    }

    @Test("boardTitle 这个第二属性已经不存在：全模块 grep 只剩注释")
    func thereIsNoSecondTitleProperty() throws {
        let root = try Self.repoRoot()
        let url = root.appending(path: "Sources/AIObservatoryUI")
        let files = try Self.swiftFiles(under: url)
        var hits: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in text.split(separator: "\n") where line.contains("boardTitle") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                // 注释里提它是有意的（讲清为什么收成一个）；**代码里**再出现就是第二出处复活。
                if !trimmed.hasPrefix("///") && !trimmed.hasPrefix("//") && !trimmed.hasPrefix("*") {
                    hits.append("\(file.lastPathComponent):\(trimmed)")
                }
            }
        }
        #expect(hits.isEmpty, "boardTitle 又有人读了：\(hits)")
    }

    // MARK: 同源——页内 hero / 窗口标题栏不许自带字面量

    /// 一整页的全部 Swift 源（按目录枚举，不按文件名清单）：#66 之后一页可能有好几份文件。
    /// 用枚举而不是清单，是为了让"再拆一份新文件"自动进射程，而不是等人想起要往清单里补一行。
    /// 返回 (相对路径, 内容)——反向检查要能指认**是哪一份**文件写的字面量，不然报错信息只会指着容器文件。
    private static func pageDirectorySources(_ root: URL, container relative: String) throws -> [(file: String, text: String)] {
        let directory = URL(fileURLWithPath: relative, relativeTo: root).deletingLastPathComponent()
        let files = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey]
        ).filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
        #expect(!files.isEmpty, "\(directory.path)：枚举不到 .swift ⇒ 这一页的路径写错了")
        return try files.map { url in
            let name = "\(relative.split(separator: "/").dropLast().joined(separator: "/"))/\(url.lastPathComponent)"
            return (name, try String(contentsOf: url, encoding: .utf8))
        }
    }

    /// 已知存量：整页扫描新暴露出来的"把板块名写死在页里"。
    /// 逐条精确到「文件 + 整行」——修好一处就必须删一条，删不掉的豁免会自己判红（见下面的反向校准）。
    private static let knownStrayTitleRestatements: [(file: String, line: String)] = [
        ("Sources/AIObservatoryUI/Sessions/SessionFilterBar.swift", "Text(\"AI 会话\").font(.axPage)"),
    ]

    @Test("九个页面把标题交给 SidebarSection，不再自带字面量")
    func everyPageTakesItsTitleFromTheEnum() throws {
        let root = try Self.repoRoot()
        for (section, relative) in Self.pageFiles {
            let text = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
            // 反向检查要扫**整页目录**：#66 把一页拆成多份文件（如 Commands 拆出
            // CommandAuditRow / CommandsDetailView / CommandsFilterBar）之后，只看外层容器
            // 那份就等于把剩下几份放行进盲区。正向那条仍钉容器文件（`ObservatoryPage(` 只该出现在入口）。
            let pageSources = try Self.pageDirectorySources(root, container: relative)
            // 压掉空白再比：`ObservatoryPage(` 与实参可能换行，也可能同一行带 subtitle。
            let squeezed = text.split(whereSeparator: \.isWhitespace).joined()
            #expect(
                squeezed.contains("ObservatoryPage(SidebarSection.\(section.rawValue).title"),
                "\(relative)：ObservatoryPage 首参不是 SidebarSection.\(section.rawValue).title"
            )
            // 反向：那一页不许再把同一个词写成字符串字面量——**任何**一处、**两种语言**。
            // 页内 hero 与 `.navigationTitle` 走的是同一个 `title` 参数，但 VoiceOver 读的是
            // `.accessibilityLabel(...)`，那是同一句话的第四个出口：它一旦另写字面量，
            // 读屏用户听到的页名就和眼睛看到的不是一回事（实测三处）。
            // 英文侧同样要查：B3 之后"把名字写死在页里"最自然的复活方式，就是有人在页里
            // 直接补一个 `"Activity Timeline"`——中文侧的查法看不见它，而它会让那一页
            // 永远不回中文。`#Preview("命令审计")` 例外：那是 Canvas 的标签、要编译期字面量，且不进产物。
            for title in [section.title(.chineseSimplified), section.title(.english)] {
                let quoted = "\"\(title)\""
                let strays = pageSources.flatMap { entry -> [(file: String, line: String)] in
                    entry.text.split(separator: "\n").map(String.init)
                        .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#Preview") }
                        .filter { $0.contains(quoted) }
                        .map { (entry.file, $0.trimmingCharacters(in: .whitespaces)) }
                }
                let unexpected = strays.filter { s in
                    !Self.knownStrayTitleRestatements.contains { $0.file == s.file && $0.line == s.line }
                }
                #expect(
                    unexpected.isEmpty,
                    "仍把 \(quoted) 写死在页里的字面量（整页目录扫描）→ \(unexpected)"
                )
            }
        }
        // 反向校准：豁免清单不许留源码里已经不存在的条目。修好一处就必须来删一条，
        // 否则"豁免"会变成第二个盲区（本仓在别的棘轮上栽过同一次）。
        for known in Self.knownStrayTitleRestatements {
            let text = try String(contentsOf: root.appending(path: known.file), encoding: .utf8)
            #expect(
                text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.contains(known.line),
                "豁免清单里这条已经不在了 ⇒ 已经修好，来删条目：\(known.file) ← \(known.line)"
            )
        }
    }

    @Test("侧栏行与窗口标题栏读的是同一个属性")
    func sidebarRowAndWindowShareOneProperty() throws {
        let root = try Self.repoRoot()
        let sidebar = try String(
            contentsOf: root.appending(path: "Sources/AIObservatoryUI/Shell/ObservatoryRootView.swift"),
            encoding: .utf8
        ).split(whereSeparator: \.isWhitespace).joined()
        let page = try String(
            contentsOf: root.appending(path: "Sources/AIObservatoryUI/DesignSystem/Page.swift"),
            encoding: .utf8
        ).split(whereSeparator: \.isWhitespace).joined()
        // 侧栏：Label(section.title, …)；窗口：ObservatoryPage 的 title → .navigationTitle(title)
        #expect(sidebar.contains("Label(section.title,systemImage:section.symbol)"))
        #expect(page.contains(".navigationTitle(title)"))
        // 且 Page.swift 里除了这一处不许有第二个 navigationTitle
        let count = page.components(separatedBy: ".navigationTitle(").count - 1
        #expect(count == 1, "页面骨架里冒出 \(count) 个 navigationTitle")
    }

    // MARK: 同源——真机护栏那张表

    /// 护栏表在 B3 之后**每板块两行**（中文 + 英文），因为窗口标题跟随系统语言，
    /// 而护栏问的是"这个实例落在哪一页"。这里钉四件事，一条都不能少：
    /// ① 表里恰好九个板块；② 每个板块**恰好两条**（少一条 = 另一种语言的实例被判废）；
    /// ③ 两条逐字等于枚举的 `title(.chineseSimplified)` / `title(.english)`，**顺序也要求**；
    /// ④ 十八条跨板块跨语言互不相同（撞名 = 护栏失去区分能力）。
    @Test("measure-pages.sh 的 board_title 表与本枚举两语逐字相等")
    func measurePagesTableMatchesTitles() throws {
        let script = try Self.repoRoot().appending(path: "Tools/UIProbe/measure-pages.sh")
        let text = try String(contentsOf: script, encoding: .utf8)
        let table = try Self.boardTitleTable(text)
        #expect(Set(table.keys).count == 9, "表里应恰好九个板块，实得 \(table.keys.count)：\(table)")
        var allTitles: [String] = []
        for section in SidebarSection.allCases {
            let rows = table[section.rawValue] ?? []
            #expect(
                rows == [section.title(.chineseSimplified), section.title(.english)],
                "护栏表 \(section.rawValue) 读到 \(rows)，应为 [中文, 英文] 两条"
            )
            allTitles.append(contentsOf: rows)
        }
        #expect(allTitles.count == 18)
        #expect(Set(allTitles).count == 18, "护栏表里有两个板块共用同一串标题：\(allTitles)")
    }

    // MARK: 表解析

    /// 抽出 `board_title()` 里每个板块的**全部**标题（按出现顺序）。
    /// 一个 arm 可以跨两行（`dashboard) echo "今日概览"` + 续行 `echo "Today" ;;`），
    /// 所以按"遇到 `key)` 就换当前 key、之后的每个 `"…"` 都归它"来扫；
    /// `*)` 是缺省分支（回空串），不算数据。
    private static func boardTitleTable(_ text: String) throws -> [String: [String]] {
        var table: [String: [String]] = [:]
        var inside = false
        var currentKey: String?
        for raw in text.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("board_title()") { inside = true; continue }
            guard inside else { continue }
            if line == "}" { break }
            if line.isEmpty || line.hasPrefix("#") { continue }
            // `case "$1" in` 是分支头，`"$1"` 是变量不是标题；`*)` 是缺省分支（回空串）。
            // 两种都不许把后面遇到的 `"…"` 记到上一个板块名下。
            if line.hasPrefix("case ") || line.hasPrefix("*)") { currentKey = nil; continue }
            if let close = line.firstIndex(of: ")") {
                let key = String(line[line.startIndex..<close]).trimmingCharacters(in: .whitespaces)
                if !key.isEmpty, key.first?.isLetter == true { currentKey = key }
            }
            for value in quotedValues(in: line) {
                guard let currentKey else { throw NamingError.missingValue(line) }
                table[currentKey, default: []].append(value)
            }
        }
        return table
    }

    /// 一行里所有成对的 `"…"` 内容（表里没有转义引号，按成对切即可）。
    private static func quotedValues(in line: String) -> [String] {
        var values: [String] = []
        var rest = line[...]
        while let first = rest.firstIndex(of: "\"") {
            let afterOpen = rest.index(after: first)
            guard let last = rest[afterOpen...].firstIndex(of: "\"") else { break }
            let value = String(rest[afterOpen..<last])
            if !value.isEmpty { values.append(value) }
            rest = rest[rest.index(after: last)...]
        }
        return values
    }

    private enum NamingError: Error {
        case missingValue(String)
        case noRepoRoot(String)
    }

    // MARK: 路径

    /// 用 `#filePath` 反推仓库根（同 `AIObservatoryTestSupport.Scratch`，不写宿主绝对路径）。
    private static func repoRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        guard FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) else {
            throw NamingError.noRepoRoot(url.path)
        }
        return url
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )
        guard let enumerator else { return [] }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }
}
