//
//  InteractionFeedbackTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/feedback（批 3 最后一格 · #11 交互反馈一致性）
//  ─────────────────────────────────────────────────────────
//  治的病：**"这个元素能不能点"在界面上没有一种统一说法。**
//  改前先把 `Sources/AIObservatoryUI/` 数了一遍（下表就是这一格的"改前"，用例 ①② 钉的就是它）：
//    · `.onTapGesture`        4 处 —— SessionRow / FileChangeRow / CommandAuditRow / ProjectCard。
//      悬停无、按下无、Tab 走不到、光标不变手型：四种可点写法里唯一"连自己是控件都没说"的一种。
//    · `.buttonStyle(.plain)` 10 处 —— 带 action 的 `StatTile`（私有 `OptionalTap`）、
//      五页搜索框的"清除"、风险行、时间线行、侧栏行。有按下、**没有悬停**。
//    · `.hoverEffect`         0 处、`.onHover` 0 处 —— 全站没人写过悬停档。
//    · `.focusable`           1 处 —— 会话列表容器（为了让 ↑/↓ 有落点，不是可点元素的反馈）。
//  而不可点的读数块（首页那四格没 action 的 `StatTile`）与可点的那三格**长得一模一样**，
//  区分只靠"有没有被包进 Button"——`DesignSystem/StatTile.swift` 改前那一段私有 `OptionalTap`
//  就是那个形状。
//
//  口径（台账 `整改波次-2026-09-22` 第六节 C 末尾那一格 + 第八节"明写未交付"第 1 条）：
//  **同样的可点样子、同样的一致反馈**。不新增跳转出口（#81 已打通，那是既成事实）、
//  不改任何取数（裁定 5）、不新造视觉语言（裁定 4/12：quiet 基座，棘轮 `0/6/5` 逐字持平）。
//
//  五道闸，各挡一种退化：
//  ① **可点清单 == 共用处理的消费者清单**（文件集合、份数、总数三个数都进判据，
//     零消费者直接红；名单里的文件改名/被删也红）。这一条是防
//     "共用处理声明了但没人用"那一族缺陷的尺——本波已经栽过三次。
//  ② **不许有第二种可点写法**：`.onTapGesture` 归零、`.buttonStyle(.plain)` 只剩点名豁免的
//     侧栏那一处、`.onHover` 只许住在共用实现里（别处再写一份 = 又开一个悬停档）。
//  ③ **两档真的有两档**：悬停/按下在深浅两套外观下的偏离量都 > 0，且按下严格深于悬停；
//     并且这两个值**只有一个出处**（其余文件一个都不许引用）。
//  ④ **带 action 的 `StatTile` 与不带 action 的可区分**：可点那一支必须真的排上 `Button`
//     + 共用样式，不可点那一支必须"什么都不加"（源码级，与 ③ 的数值闸合起来才是
//     "看得出差别"）。反向钉首页那一段真的把 `tile.action` 传了下来——
//     不然这一格测的是空气。
//  ⑤ **没有新造视觉语言**：新那份实现里不许出现阴影 / 材质 / 自造灰值 / 新圆角档
//     （与 `ratchet-quiet-design.sh` 的三条禁令同源，这里是它在本格文件上的局部版）。
//
//  ⚠️ 这五道闸都量不了"人眼上屏那一眼"与"键盘走一遍"。
//  实拍与键盘走查（Tab 到每个可点元素 / Return 触发 / Esc 清除）记在车道回报里，
//  图存 `tmp/`、不入库（台账 #89：实拍会带出常驻 agent 目录尾段，现有脱敏开关射程不到）。
//

import Foundation
import AppKit
import SwiftUI
import Testing
@testable import AIObservatoryUI

@MainActor
@Suite("UI: #11 交互反馈一致性（同可点同反馈）", .timeLimit(.minutes(1)))
struct InteractionFeedbackTests {

    /// 共用处理 `axPressable` 的**全部**消费者：整块可点那一族，一共 12 处、12 个文件。
    /// 顺序即台账里"改前"的四种写法被收进来的次序：读数块 → 列表行 → 搜索框那颗"清除"。
    private static let pressableSites: [String] = [
        "Sources/AIObservatoryUI/DesignSystem/StatTile.swift",
        "Sources/AIObservatoryUI/Security/RiskEventRow.swift",
        "Sources/AIObservatoryUI/Timeline/TimelineEventRow.swift",
        "Sources/AIObservatoryUI/Sessions/SessionRow.swift",
        "Sources/AIObservatoryUI/Files/FileChangeRow.swift",
        "Sources/AIObservatoryUI/Commands/CommandAuditRow.swift",
        "Sources/AIObservatoryUI/Projects/ProjectCard.swift",
        "Sources/AIObservatoryUI/Timeline/TimelineFilterBar.swift",
        "Sources/AIObservatoryUI/Files/FilesFilterBar.swift",
        "Sources/AIObservatoryUI/Commands/CommandsFilterBar.swift",
        "Sources/AIObservatoryUI/Security/SecurityFilterBar.swift",
        "Sources/AIObservatoryUI/Projects/ProjectsView.swift",
        // #98：首页那三类行/格接上取证出口之后，可点落点从 12 处长到 15 处。
        // 风险行与异常行原先**整屏没有出口**（行是纯读数），现在是真按钮 ⇒ 必须同反馈。
        "Sources/AIObservatoryUI/Dashboard/DashboardView.swift",
        "Sources/AIObservatoryUI/Dashboard/DashboardActiveAgentsList.swift",
        "Sources/AIObservatoryUI/Dashboard/DashboardAnomalyCard.swift",
    ]

    /// 点名豁免：`.buttonStyle(.plain)` 允许留在这一个文件的这一种容器里，**份数 1**。
    ///
    /// 理由不是"忘了改"：侧栏行住在 `List(selection:)` 里，悬停底与选中底都由这张列表自己画，
    /// 再叠一层自绘底就是同一次悬停两处反馈，而且会盖掉"这一行是当前板块"那一档系统语义。
    /// 它本来就是真 `Button` ⇒ 焦点环、手型光标、Return 触发三样都在，缺的只有悬停底色。
    private static let plainStyleExemptions: [String: Int] = [
        "Sources/AIObservatoryUI/Shell/ObservatoryRootView.swift": 1,
    ]

    // MARK: ① 可点清单 == 消费者清单

    @Test("可点清单与共用处理的消费者清单逐字相等（15 处 / 15 个文件，零消费者不许通过）")
    func clickableInventoryEqualsConsumerInventory() throws {
        // 分母自证：按目录扫的门禁必须先证明目录读得到预期份数，
        // 否则目录改名之后它扫 0 份还报绿（`HardcodedChineseRatchetTests` 的覆盖面闸管的就是这一族）。
        let allFiles = try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI")
        #expect(allFiles.count >= 100,
                "整个 UI 只读到 \(allFiles.count) 份文件 ⇒ 这条闸扫的是空气，先修扫描")

        var found: [String: Int] = [:]
        for url in allFiles {
            let relative = relativePath(of: url)
            let code = try codeOnly(relative)
            let hits = occurrences(code, "axPressable")
            // 定义文件自己不算消费者（它声明 `axPressable(when:)` 与 `.axPressable` 两处）。
            if relative == Self.definitionFile { continue }
            if hits > 0 { found[relative] = hits }
        }

        // 正向：名单里每一处都必须**真的**接上，且各 1 份。
        for site in Self.pressableSites {
            #expect(found[site] == 1,
                    "\(site) 接了 \(found[site] ?? 0) 份共用处理（应为 1 份）⇒ 名单与实际脱节")
        }
        // 反向：接上了却没在名单里的（新页随手加一处 = 名单失效，必须显式登记）。
        let undeclared = Set(found.keys).subtracting(Self.pressableSites)
        #expect(undeclared.isEmpty, "出现了没登记的可点落点：\(undeclared.sorted())")
        // 总数与"零消费者"这一族：名单非空、份数加总正好等于处数。
        #expect(Self.pressableSites.count == 15, "可点清单本身变成 \(Self.pressableSites.count) 条了")
        let total = found.values.reduce(0, +)
        #expect(total == 15, "共用处理的实际消费份数是 \(total)，与清单的 15 不符")
        #expect(total > 0, "一份消费者都没有 ⇒ 这份共用处理只是声明了没用")
    }

    // MARK: ② 不许有第二种可点写法

    @Test("整块可点只剩一种写法：onTapGesture 归零、plain 只剩点名豁免、悬停档只有一处实现")
    func noSecondWayToBeClickable() throws {
        let lines = try allCodeLines()
        let tap = lines.filter { $0.line.contains(".onTapGesture") }
        let tapText = tap.map { "\($0.file): \($0.line)" }.joined(separator: "\n")
        #expect(tap.isEmpty,
                "又出现 `.onTapGesture`（改前 4 处，那是一种没有任何反馈、Tab 走不到的可点写法）：\(tapText)")

        var plain: [String] = []
        for site in lines where site.line.contains(".buttonStyle(.plain)") {
            plain.append(site.file)
        }
        #expect(plain.count == 1, "`.buttonStyle(.plain)` 现在有 \(plain.count) 处（豁免名单只给了 1 处）：\(plain)")
        #expect(plain.allSatisfy { Self.plainStyleExemptions.keys.contains($0) },
                "`.plain` 出现在没豁免的文件上：\(plain)")

        // 悬停档只许住在共用实现里：别处再 `.onHover` 一次 = 第二个悬停档，正是要治的病。
        let hover = lines.filter { $0.line.contains(".onHover") }
        #expect(hover.count == 1 && hover.first?.file == Self.definitionFile,
                "`.onHover` 现在有 \(hover.count) 处：\(hover.map { $0.file }.sorted())")
        #expect(lines.filter { $0.line.contains(".hoverEffect") }.isEmpty,
                "`.hoverEffect` 是触屏那套的反馈档，本 App 不用它表达可点")

        // `.focusable` 改前那唯一一处是会话列表容器的 ↑/↓ 落点，本格没动它，也不许新增。
        let focusable = lines.filter { $0.line.contains(".focusable") }
        #expect(focusable.map(\.file) == ["Sources/AIObservatoryUI/Sessions/SessionsView.swift"],
                "`.focusable` 的落点变了：\(focusable.map(\.file))")
    }

    // MARK: ③ 两档真的有两档，而且只有一个出处

    @Test("悬停/按下两档在深浅两套外观下的偏离量都 > 0，且按下严格深于悬停")
    func theTwoTiersAreActuallyTwoTiers() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let panel = luminanceOf(Surface.panel, in: appearance)
            let hover = deviation(Feedback.hoverTint, from: panel, in: appearance)
            let press = deviation(Feedback.pressTint, from: panel, in: appearance)
            // 悬停必须看得见：偏离量为 0 就是"停上去什么也没发生"，那正是改前的样子。
            #expect(hover > 0.002, "\(appearance.rawValue)：悬停档偏离 \(hover) ≈ 0 ⇒ 悬停没有反馈")
            #expect(press > hover,
                    "\(appearance.rawValue)：按下 \(press) 不比悬停 \(hover) 深 ⇒ 按下这一通道没有信息")
            // 与 `CaptionContrastTests` 同一手法：把"够不够看得见"变成一个可核对的数。
            let ratio = contrastRatio(Feedback.hoverTint, against: Surface.panel, in: appearance)
            #expect(ratio >= 1.05,
                    "\(appearance.rawValue)：悬停档与面板底的对比只有 \(ratio)，太浅等于没有")
        }
    }

    @Test("两档底色只有一个出处，且都是语义色叠 alpha（不写死灰值）")
    func tintTiersHaveASingleSourceAndAreSemantic() throws {
        let definition = try codeOnly(Self.definitionFile)
        // 语义色 + alpha：浅色下是黑、深色下自动是白，"抬一级"的方向在两套外观里都成立。
        // 写死灰值会在深色模式下方向反掉（`ObservatoryTokens.swift:26-34` 那条实测）。
        #expect(occurrences(definition, "Color.primary.opacity") == 2,
                "共用反馈里的底色不是两档 `Color.primary.opacity`，数到 \(occurrences(definition, "Color.primary.opacity")) 处")
        // 反向：其余 UI 文件一个都不许直接引用这两档（引用了就绕过了唯一那份处理）。
        for site in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = relativePath(of: site)
            if relative == Self.definitionFile { continue }
            let code = try codeOnly(relative)
            #expect(!code.contains("Feedback.hoverTint") && !code.contains("Feedback.pressTint"),
                    "\(relative) 直接引用了悬停/按下档 ⇒ 它在共用处理之外自己画了一版反馈")
        }
        // 圆角取既有档位，不另起一档。
        #expect(definition.contains("ObservatoryRadius.control"))
    }

    // MARK: ④ 带 action 的 StatTile 与不带 action 的可区分

    @Test("带 action 的 StatTile 走共用处理、不带 action 的那一支什么都不加")
    func actionableStatTileDiffersFromPlainReadout() throws {
        let tile = try codeOnly("Sources/AIObservatoryUI/DesignSystem/StatTile.swift")
        // 可点与否只由这一条判断决定（改前那里是一份文件私有的 `OptionalTap`）。
        #expect(occurrences(tile, ".axPressable(when: action)") == 1,
                "StatTile 不再把可点性交给唯一的判据 ⇒ 「有没有被包进 Button」又变成隐形线")
        #expect(!tile.contains("OptionalTap"),
                "那份私有的 `OptionalTap` 回来了 ⇒ 可点与否又变成屏上看不出来的隐形线")
        #expect(!tile.contains(".buttonStyle("), "StatTile 自己挑了样式 ⇒ 不再与全站同一份")

        // 不可点那一支必须**真的什么都不加**：没有 Button、没有底色、没有悬停。
        let definition = try codeLines(Self.definitionFile)
        guard let start = definition.firstIndex(where: { $0.contains("func axPressable(when action:") }) else {
            Issue.record("共用处理没有「由 action 决定」那一条入口了 ⇒ 这一格测的是空气")
            return
        }
        let block = definition[start..<min(definition.count, start + 12)].joined(separator: "\n")
        guard let elseRange = block.range(of: "} else {") else {
            Issue.record("axPressable(when:) 没有「没有 action」那一条分支 ⇒ 所有读数块都会亮起来")
            return
        }
        let inactive = block[elseRange.upperBound...]
        for needle in ["Button(", "Feedback.", "onHover", "background"] where inactive.contains(needle) {
            Issue.record("没有 action 那一支加了 \(needle) ⇒ 不可点的读数块又会看起来可点")
        }
        #expect(inactive.contains("self"), "没有 action 那一支连原视图都不返回了：\(inactive)")

        // 反向：可点那一支必须真的排上真控件（悬停 / 手型光标 / 焦点环三样都挂在这上面）。
        guard let ifRange = block.range(of: "if let action") else {
            Issue.record("axPressable(when:) 的「有 action」分支不在了：\n\(block)")
            return
        }
        let activeBranch = block[ifRange.upperBound..<elseRange.lowerBound]
        #expect(activeBranch.contains("Button(action:"), "可点那一支不是真 Button ⇒ Tab 走不到")
        #expect(activeBranch.contains(".buttonStyle(.axPressable)"), "可点那一支没接共用处理")

        // 这一族在首页真的两头都跑到：`DashboardView` 把 `tile.action` 原样传下来，
        // 而那一屏 7 格里 3 格有 action、4 格没有（#79 之后"当前状态"1 格 + "时段累计"6 格）。
        let dashboard = try codeOnly("Sources/AIObservatoryUI/Dashboard/DashboardView.swift")
        #expect(dashboard.contains("action: tile.action"),
                "首页不再把 action 传给 StatTile ⇒ 上面那条可区分性在屏上没跑到")
    }

    // MARK: ⑤ 没有新造视觉语言

    @Test("共用处理本身不带阴影 / 材质 / 自造色值 / 新圆角档（quiet 基座的局部版）")
    func sharedTreatmentInventsNoNewVisualLanguage() throws {
        let definition = try codeOnly(Self.definitionFile)
        for needle in [".shadow(", "Material", "ultraThinMaterial", "textCase(.uppercase)",
                       "tracking(", "GridItem(.adaptive", "Color(red:", "Color(white:",
                       "Color(hue:", "Color(.sRGB", "NSColor(white:"] {
            #expect(!definition.contains(needle),
                    "新那份反馈里出现了 \(needle) ⇒ 这是自绘深度的回潮（`ratchet-quiet-design.sh` 的三条禁令）")
        }
        // 只有一层底：三态压在同一颗 `tint` 上，靠 `Color.clear` 占位保证布局不跳。
        #expect(occurrences(definition, ".background(") == 1,
                "共用处理自己叠了多于一层底 ⇒ 与调用方的选中底打架")
        // 动效档在 `Feedback` 里命名，不散落在调用点。
        #expect(definition.contains("static let motion: Animation"))
    }

    // MARK: 尺子

    /// 共用处理的定义文件（它自己不算消费者，也是唯一允许 `.onHover` 的地方）。
    private static let definitionFile = "Sources/AIObservatoryUI/DesignSystem/InteractiveFeedback.swift"

    /// 前景（可能带 alpha）叠在不透明背景上的相对亮度偏离量（取绝对值：
    /// 浅色下往暗走、深色下往亮走，方向本来就相反，要钉的是"偏离了多少"）。
    private func deviation(_ foreground: Color, from backgroundLuminance: Double,
                           in name: NSAppearance.Name) -> Double {
        abs(luminanceOf(blend(foreground, over: Surface.panel, in: name), in: name)
            - backgroundLuminance)
    }

    private func contrastRatio(_ foreground: Color, against background: Color,
                               in name: NSAppearance.Name) -> Double {
        let a = luminanceOf(blend(foreground, over: background, in: name), in: name)
        let b = luminanceOf(background, in: name)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private func blend(_ foreground: Color, over background: Color,
                       in name: NSAppearance.Name) -> NSColor {
        let fg = resolve(foreground, in: name)
        let bg = resolve(background, in: name)
        let a = max(0, min(1, Double(fg.alphaComponent)))
        return NSColor(
            srgbRed: Double(fg.redComponent) * a + Double(bg.redComponent) * (1 - a),
            green: Double(fg.greenComponent) * a + Double(bg.greenComponent) * (1 - a),
            blue: Double(fg.blueComponent) * a + Double(bg.blueComponent) * (1 - a),
            alpha: 1
        )
    }

    private func resolve(_ color: Color, in name: NSAppearance.Name) -> NSColor {
        let appearance = NSAppearance(named: name)!
        var out = NSColor(color)
        appearance.performAsCurrentDrawingAppearance {
            // sRGB：亮度公式定义在 sRGB 上，别拿 device 的数去比 sRGB 的公式（同 `CaptionContrastTests`）。
            out = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        }
        return out
    }

    private func luminanceOf(_ color: Color, in name: NSAppearance.Name) -> Double {
        luminanceOf(resolve(color, in: name), in: name)
    }

    private func luminanceOf(_ color: NSColor, in name: NSAppearance.Name) -> Double {
        func channel(_ raw: CGFloat) -> Double {
            let v = Double(raw)
            return v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(color.redComponent)
            + 0.7152 * channel(color.greenComponent)
            + 0.0722 * channel(color.blueComponent)
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

    private func codeOnly(_ relative: String) throws -> String {
        try BilingualCopyGate.codeOnlyString(relative)
    }

    private func codeLines(_ relative: String) throws -> [String] {
        try codeOnly(relative).split(separator: "\n").map(String.init)
    }

    /// 整个 UI 目录的非注释代码行（带文件名），给"按目录数份数"那两道闸用。
    private func allCodeLines() throws -> [(file: String, line: String)] {
        var out: [(file: String, line: String)] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = relativePath(of: url)
            for line in try codeLines(relative) { out.append((relative, line)) }
        }
        return out
    }

    /// 枚举回来的绝对路径 → 仓库相对路径（`BilingualCopyGate` 的读法都按相对路径收）。
    private func relativePath(of url: URL) -> String {
        "Sources/AIObservatoryUI/" + (url.path.components(separatedBy: "Sources/AIObservatoryUI/").last ?? "")
    }
}
