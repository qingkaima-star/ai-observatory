//
//  SidebarNavigationTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · P2 键盘导航）
//  ─────────────────────────────────────────────────────────
//  两件事：① ⌘1–⌘8 的键位表必须与侧栏**看得见**的顺序一致，且设置故意不给；
//  ② 一个 keyEquivalent 只能有一个 owner——这条原来就是红的（⇧⌘R 同时挂在
//  工具栏按钮与「观测」菜单项上，两处行为还不完全一样）。
//
//  键位**真的能按动**不是用例能证明的（那要跑起来的 App），所以本文件同时留了一条
//  源码级接线检查；实机按下 ⌘2 并核验窗口标题的证据在交付块里
//  （`AiX-Vault/03-进度日志/2026-09-20-性能.md` uicopy 一段）。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 板块直达键与快捷键唯一 owner", .timeLimit(.minutes(1)))
struct SidebarNavigationTests {

    // MARK: ① 键位表

    @Test("九个板块的 ⌘数字 = 手推字面量（设置故意没有）")
    func navigationKeyTable() {
        #expect(SidebarSection.allCases.map { "\($0.rawValue):\($0.navigationKey.map(String.init) ?? "无")" } == [
            "dashboard:1", "sessions:2", "timeline:3", "commands:4", "files:5",
            "performance:6", "security:7", "projects:8", "settings:无",
        ])
    }

    @Test("键位等于侧栏里的可见顺序（用户是拿手指在栏上数的）")
    func keysMatchVisibleSidebarOrder() {
        let visible = SidebarGroup.allCases.flatMap(\.sections)
        #expect(visible.count == 9)
        for (index, section) in visible.enumerated() {
            let expected = index < 8 ? Character("\(index + 1)") : nil
            #expect(section.navigationKey == expected,
                    "侧栏第 \(index + 1) 格是 \(section.rawValue)，键位却给了 \(String(describing: section.navigationKey))")
        }
    }

    @Test("键位互不重复、只用 1–8、不出现 ⌘9")
    func keysAreUniqueAndStopAtEight() {
        let keys = SidebarSection.allCases.compactMap(\.navigationKey)
        #expect(Set(keys).count == 8)
        #expect(keys.sorted().map(String.init) == ["1", "2", "3", "4", "5", "6", "7", "8"])
        #expect(SidebarSection.settings.navigationKey == nil, "设置走 ⌘, ，不该再有 ⌘9")
    }

    @Test("tooltip 把快捷键带上屏（HIG：快捷方式要可发现）")
    func tooltipDisclosesTheShortcut() {
        // 两语各自钉一遍：括号是文案的一部分，英文侧写成全角「（⌘1）」就是混排缺陷。
        #expect(SidebarSection.dashboard.shortcutHint(.chineseSimplified) == "（⌘1）")
        #expect(SidebarSection.projects.shortcutHint(.chineseSimplified) == "（⌘8）")
        #expect(SidebarSection.dashboard.shortcutHint(.english) == " (⌘1)")
        #expect(SidebarSection.projects.shortcutHint(.english) == " (⌘8)")
        #expect(SidebarSection.settings.shortcutHint(.chineseSimplified) == "")
        #expect(SidebarSection.settings.shortcutHint(.english) == "")
        // subtitle + hint 拼出来的整句仍是这一格自己的话（不许把别格的键位带进来）。
        #expect((SidebarSection.files.subtitle(.chineseSimplified)
                    + SidebarSection.files.shortcutHint(.chineseSimplified))
            == "文件增删改与 Before/After Diff（⌘5）")
        #expect((SidebarSection.files.subtitle(.english) + SidebarSection.files.shortcutHint(.english))
            == "File additions, edits and Before/After diffs (⌘5)")
    }

    /// ⌘1–⌘8 的 owner 从视图搬进 App 的 `CommandGroup(after: .sidebar)`（ICR-0005）：
    /// 视图级 `keyboardShortcut` **不出现在菜单栏里**，用户只能靠 tooltip 猜有这些键。
    /// 这条用例因此反过来钉两件事：菜单那一份必须在，视图那一份必须**已经删干净**——
    /// 两边都在就是同一个键两个 owner，行为取决于焦点，是最难查的一类"看起来能用"。
    @Test("⌘数字的唯一 owner 是 App 的侧栏命令组，视图里那份已删净")
    func navigationShortcutsAreOwnedByTheMenu() throws {
        let app = try Self.source("Sources/AIObservatoryApp/AIObservatoryApp.swift")
        let squeezedApp = app.split(whereSeparator: \.isWhitespace).joined()
        #expect(squeezedApp.contains("CommandGroup(after:.sidebar)"),
                "⌘1–⌘8 不在侧栏命令组里 ⇒ 菜单栏看不到这些键（就是 ICR-0005 那个可发现性缺口）")
        #expect(squeezedApp.contains("ForEach(SidebarSection.allCases)"),
                "菜单项不再是枚举板块 ⇒ 新增板块会静默漏掉一条快捷键")
        #expect(squeezedApp.contains("ifletkey=section.navigationKey")
                && squeezedApp.contains(".keyboardShortcut(KeyEquivalent(key),modifiers:.command)"),
                "键位不再从 navigationKey 单一出处取（会重新分叉出第二张键位表）")
        #expect(squeezedApp.contains("Button(section.title){shell.select(section)}"),
                "菜单项没有走 shell.select ⇒ 切了页而侧栏高亮不会动")

        let view = try Self.source("Sources/AIObservatoryUI/Shell/ObservatoryRootView.swift")
        let squeezedView = view.split(whereSeparator: \.isWhitespace).joined()
        #expect(squeezedView.contains("Button{shell.select(section)}label:{Label(section.title"),
                "侧栏行不再是带 action 的 Button ⇒ 点击与选中走的是两条路径")
        #expect(!squeezedView.contains("keyboardShortcut("),
                "视图里又挂了一份 ⌘数字 ⇒ 同一个键两个 owner")
    }

    // MARK: ② 一个 keyEquivalent 只能有一个 owner

    @Test("全仓没有重复的键盘快捷键绑定")
    func noDuplicateKeyboardShortcuts() throws {
        let found = try Self.shortcutBindings()
        // 按「键 + 修饰键集合」归堆：⌘R 与 ⇧⌘R 是两个不同的键位，不冲突；
        // 同一形状出现两次才是这条要拦的（⇧⌘R 原来正是这样被绑了两遍）。
        var owners: [String: [String]] = [:]
        for binding in found {
            owners["\(binding.key) ← \(binding.modifiers)", default: []]
                .append("\(binding.file):\(binding.line)")
        }
        let duplicates = owners.filter { $0.value.count > 1 }
        #expect(duplicates.isEmpty, "同一个键位有多个 owner：\(duplicates)")
        // 现状手推（不含侧栏那八条 `KeyEquivalent(key)`，它们由上面的键位表用例负责）：
        // 「观测」菜单两条，`.defaultAction`（Return）不是字符键位、不进表。
        #expect(owners.keys.sorted() == ["e ← command+shift", "r ← command+shift"],
                "实际表：\(owners.keys.sorted())")
        #expect(found.count == 2)
    }

    /// 本车道摘掉工具栏那一份 ⇧⌘R 之后，全仓只能剩「观测」菜单那一条。
    @Test("⇧⌘R 只剩一个 owner：工具栏那份已经摘掉")
    func rescanShortcutHasSingleOwner() throws {
        let toolbar = try Self.source("Sources/AIObservatoryUI/Shell/ToolbarContent.swift")
        #expect(!toolbar.contains(".keyboardShortcut("), "工具栏又自己挂了一遍快捷键")
        // tooltip 仍然要写这个键——它是「观测」菜单给的，用户看得到才是可发现性。
        // B3 之后这条文案搬进了 `ShellCopy`（双语表），所以断言分两半：
        // ① 值本身两语都还带着 ⇧⌘R（**直接查渲染出来的字符串**，比原来扫源码更强：
        //    扫源码只能证明"文件里写过"，证不出按钮真的读到它）；
        // ② 工具栏那一行确实挂的是这条文案，而不是重新写死的字面量。
        #expect(ShellCopy.rescanTooltip.text(.chineseSimplified)
            == "立即重新扫描（⇧⌘R · 见「观测」菜单）")
        #expect(ShellCopy.rescanTooltip.text(.english).contains("⇧⌘R"),
                "英文 tooltip 丢了键位：\(ShellCopy.rescanTooltip.text(.english))")
        let squeezed = toolbar.split(whereSeparator: \.isWhitespace).joined()
        #expect(squeezed.contains(".help(ShellCopy.rescanTooltip.text(UILanguage.current))"),
                "重新扫描按钮的 tooltip 不再走 ShellCopy.rescanTooltip（会重新分叉成写死字面量）")
    }

    // MARK: 解析

    /// 扫 `Sources/**.swift` 里所有 `.keyboardShortcut("x", modifiers: …)` 形式的绑定。
    /// 只认带字符字面量的那种（`KeyEquivalent(key)` 与 `.defaultAction` 都跳过）——
    /// 侧栏那八条由上面的键位表用例负责。
    private static func shortcutBindings() throws -> [(file: String, line: Int, key: String, modifiers: String)] {
        let root = try repoRoot()
        guard let enumerator = FileManager.default.enumerator(
            at: root.appending(path: "Sources"),
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var found: [(file: String, line: Int, key: String, modifiers: String)] = []
        for case let file as URL in enumerator {
            guard file.pathExtension == "swift" else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            let text = try String(contentsOf: file, encoding: .utf8)
            for (index, line) in text.split(separator: "\n").enumerated() {
                guard line.contains("keyboardShortcut"),
                      let open = line.firstIndex(of: "(") else { continue }
                let rest = line[line.index(after: open)...]
                // 只认 `("x", …)` 这种带字符字面量的；`.defaultAction` / `KeyEquivalent(key)` 跳过。
                guard let firstQuote = rest.firstIndex(of: "\""),
                      let secondQuote = rest[rest.index(after: firstQuote)...].firstIndex(of: "\""),
                      rest[rest.index(after: firstQuote)..<secondQuote].count == 1
                else { continue }
                let key = String(rest[rest.index(after: firstQuote)..<secondQuote])
                let tail = rest[rest.index(after: secondQuote)...]
                let mods = ["command", "option", "control", "shift"].filter { tail.contains($0) }.sorted()
                found.append((relative, index + 1, key, mods.joined(separator: "+")))
            }
        }
        return found
    }

    private static func source(_ relative: String) throws -> String {
        try String(contentsOf: try repoRoot().appending(path: relative), encoding: .utf8)
    }

    private enum NavError: Error { case noRepoRoot }

    private static func repoRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) else {
            throw NavError.noRepoRoot
        }
        return url
    }
}
