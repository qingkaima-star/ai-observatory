//
//  RedactionSurfaceTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-finisher（#64 演示脉敏的渲染面收口）
//  ─────────────────────────────────────────────────────────
//  #61 的验收是**逐格**钉的：`FilePathText` 那一咽喉有 8 条用例、`Mask.apply` 有 6 条，
//  全绿，而实拍（`ai-observatory/tmp/shots/redact-on-files.png`）上明晃晃写着
//  「剔除 2 条：/ (过浅：受保护根)、/Users/dev (过浅：受保护根)」——开关开着，家目录还在屏上。
//  **逐格断言就是这次的漏因**：它只能证明"被钉过的那一格"干净。
//
//  这一支换成两把尺：
//   ① **整页枚举**（行为）：拿一份带合成家目录 `/Users/dev` 的输入，把这一页能渲染出的
//      整串文本枚举出来，断言**整页**不含该前缀；同时断言"关掉时它确实在"——
//      否则"没含"可能只是夹具里根本没有路径（那是假绿）。
//   ② **出口闸**（源码级，带分母）：任何把"路径来源"喂进"人眼/辅助技术出口"的一行，
//      必须同时带着映射。新增一行 `Text(change.path)` 当场红。
//      分母守卫：扫到的文件数与命中数都断言非零——空扫描也会 exit 0，这个坑本仓踩过。
//
//  ⚠️ 用例里一律用 `FixturePaths.home`（`/Users/dev`），不写本机家目录（门禁 G1/G4）。
//

import Testing
import Foundation
import SwiftUI
@testable import AIObservatoryCore
@testable import AIObservatoryUI
import AIObservatoryTestSupport

@Suite("UI: #64 采集面整页枚举 + 路径出口闸")
struct RedactionSurfaceTests {

    private static let home = FixturePaths.home                 // "/Users/dev"
    private static let root = FixturePaths.projectRoot          // "/Users/dev/Projects/AiX"

    private static let on = PathPrivacy.Mask(home: home, projectRoots: [root])

    // MARK: - ① 整页枚举：采集面那一行（#64 的实拍漏因）

    /// 一条"引擎剔除了家目录本身"的实况——正是实拍那一跑的形状。
    private static func liveWithHome() -> MonitoringScope {
        MonitoringScope(
            keptRoots: [root],
            dropped: [
                MonitoringScope.Dropped(path: "/", reason: .protectedRoot),
                MonitoringScope.Dropped(path: home, reason: .protectedRoot),
                MonitoringScope.Dropped(path: "\(home)/Downloads",
                                        reason: .matchedIgnoredPattern,
                                        matchedRule: "\(home)/Downloads/**"),
            ],
            resolvedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private static func scope(mask: PathPrivacy.Mask) -> CaptureScope {
        CaptureScope(live: liveWithHome(), rangeName: "今天", mask: mask)
    }

    @Test("开启后：采集面整行（含剔除清单与命中的忽略规则）不含合成家目录")
    func captureLineHidesTheHome() {
        let line = Self.scope(mask: Self.on).coverageLine(language: .chineseSimplified)
        #expect(!line.contains(Self.home), "开关开着，采集面这一行仍印出家目录：\(line)")
        // 结构不许消失：两条剔除仍然点名两条，总数仍然报全。
        #expect(line.contains(PathPrivacy.Mask.homePlaceholder), "换成占位符了吗：\(line)")
        #expect(line.contains("剔除 3 条"), "收口把条数改掉了：\(line)")
        // 与项目根同源的根要换成 `<project>`，不是 `~`（最长优先那条规则）。
        #expect(line.contains(PathPrivacy.Mask.projectPlaceholder) == false
                    || line.contains(Self.root),
                "项目根被剥成了 ~ ⇒ 最长优先失效：\(line)")
    }

    @Test("反向自证：关掉时同一条输入**逐字**带着家目录（证明是映射在起作用，不是夹具没路径）")
    func captureLineLeaksWhenOff() {
        let line = Self.scope(mask: .off).coverageLine(language: .chineseSimplified)
        #expect(line.contains(Self.home),
                "关掉后这一行里没有 \(Self.home) ⇒ 夹具根本没造出这条路径，上面那条断言是假绿")
        #expect(line.contains("\(Self.home)/Downloads"))
        #expect(line.contains("matchedRule") == false)
    }

    @Test("空态那一条走的是同一句：`explanation` 也不许带家目录")
    func emptyStateExplanationHidesTheHome() {
        let availability = CaptureAvailability.nothingInScope(Self.scope(mask: Self.on))
        let text = availability.headline(language: .chineseSimplified)
            + availability.explanation(language: .chineseSimplified)
        #expect(!text.contains(Self.home), "空态说明里还留着家目录：\(text)")
    }

    @Test("英文态同一把尺：换语言不换来不脱敏")
    func englishUsesTheSameMask() {
        let line = Self.scope(mask: Self.on).coverageLine(language: .english)
        #expect(!line.contains(Self.home), "英文态漏了：\(line)")
    }

    // MARK: - ② 生产侧接线：映射是从启动设置解析来的，不是用例自己造的

    /// 行为用例证不了"生产那一条路上真带着映射"——#61 的开关就是这么变成装饰的（ADR-0006）。
    @Test("生产接线：FilesModel 造采集面时带上启动设置解析出的映射")
    func filesModelWiresTheMask() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Files/FilesModel.swift")
        #expect(code.contains("PathPrivacy.Mask.configured(from: runtime.settings)"),
                "FilesModel 没带映射 ⇒ 采集面那一行在真机上仍是原文（#64 的实拍形状）")
        #expect(code.contains("CaptureScope(live:"),
                "采集面读数不再由 FilesModel 产出？接线断言的锚点已失效，请同步这一支")
    }

    /// #64 ③（界面侧）：关掉映射不许静默——设置页那一行必须**随开关换话**。
    @Test("设置页两态都说明当前状态（关掉时是警告，不是留白）")
    func settingsPageAnnouncesBothStates() throws {
        let pane = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Settings/SettingsPrivacyPane.swift")
        #expect(pane.contains("model.draft.demoRedactedOutput"),
                "那一行没有跟着开关走 ⇒ 它写的是固定文案，不是状态")
        #expect(pane.contains("demoToggleOffNotice") && pane.contains("demoToggleOnNotice"),
                "两态文案少了一边 ⇒ 有一态是静默的")
    }

    // MARK: - ③ 出口闸：路径来源 → 人眼/辅助技术出口，必须带映射

    /// 会**渲染出人可见文本**的出口。只在这些出口上要求脱敏，
    /// 因为 `change.path == other.path`、字典键、过滤器里的路径都不是"给人读的那一份"。
    private static let sinks: [String] = [
        "Text(", ".help(", ".accessibilityLabel(", ".accessibilityValue(",
        "SectionHeader(", "MonospacedCodeView(", "setString(", "InlineStat(",
    ]

    /// 装着**绝对路径**的来源。名字里带 path 但值是文件名的（`fileName`）不在列。
    /// `summary` / `detail` 也算：引擎把路径拼进了那两句
    /// （`TimelineAggregator` 的 `[change.path]` + 「原路径 …」、`SensitiveLocationRules`
    /// 的依据句），所以"看起来只是文案"的两格里其实躺着完整路径。
    private static let sources: [String] = [
        ".path", "filePath", "projectPath", "workingDirectory",
        "deletingLastPathComponent", "storeDirectory", "sensitivePrefixes",
        "event.summary", "event.detail", "change.path", "row.path",
    ]

    /// 同一个来源名、但值**不是**路径的用法：条数与函数声明。
    /// 不排掉的话闸会一直红在无关行上，而"永远红的闸"等于没有闸。
    private static let notAPath: [String] = [".count", "func "]

    /// 一行里出现即算"已经过映射"。
    private static let maskers: [String] = [
        "demoRedaction", "mask.scrub", "pathMask", "FilePathText",
        "apply(to:", "scrub(", "deabsolutized",
    ]

    @Test("出口闸：任何把绝对路径喂进可见文本出口的一行都必须带映射（含分母守卫）")
    func pathSinksAreMasked() throws {
        let root = try BilingualCopyGate.repoRoot()
        let prefix = root.path + "/"
        let files = try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI")
            .map { String($0.path.dropFirst(prefix.count)) }
        // 分母守卫：扫描本身要有东西可扫，否则"零违规"是空话。
        #expect(files.count > 60, "只扫到 \(files.count) 个 UI 源文件 ⇒ 扫描路径是坏的，这条闸没有分母")

        let sinks = Self.sinks, sources = Self.sources, maskers = Self.maskers
        let notAPath = Self.notAPath
        var offenders: [String] = []
        var checked = 0
        for file in files {
            let code = try BilingualCopyGate.codeOnlyString(file)
            #expect(!code.isEmpty, "\(file) 剥注释后为空 ⇒ 出口闸扫不到它")
            for (index, line) in code.split(separator: "\n").enumerated() {
                let text = String(line)
                guard sinks.contains(where: text.contains),
                      sources.contains(where: text.contains),
                      notAPath.contains(where: text.contains) == false
                else { continue }
                checked += 1
                if maskers.contains(where: text.contains) { continue }
                offenders.append("\(file):\(index + 1)  \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(checked > 0, "一条路径出口都没扫到 ⇒ 出口/来源清单已失效，这条闸是空转的")
        let report = offenders.joined(separator: "\n")
        #expect(offenders.isEmpty,
                "有 \(offenders.count) 处路径出口没脱敏（开着 #61 的开关也会上屏）：\n\(report)")
    }
}
