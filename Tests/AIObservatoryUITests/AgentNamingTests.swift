//
//  AgentNamingTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/consistency（批 3 · #82 工具命名归一，只在 UI 层）
//  ─────────────────────────────────────────────────────────
//  治的病：**同一个 Agent 在界面上可以有两个名字。**
//  改前三套身份源并存、没有归一层：`AgentKind.displayName`（英文产品名）、
//  `AgentInstance.displayName`（探测到的原始进程名 `claude`/`codex`/`cursor`）、
//  以及 `AgentChip.displayedName` 在紧凑态**切首词**。结果就是同一列里
//  `Claude Code` 与 `Claude`、`OpenAI Codex CLI` 与 `OpenAI` 并排——
//  被切掉的那半恰恰是区别本身。另有 4 处 `InlineStat("Agent", …)` 裸字面量、
//  3 处过滤条 fallback `"Agent"`、1 处图表轴标签 `"Agent"`。
//
//  四道闸：
//  ① **值**：已知 kind 在紧凑态与非紧凑态输出**同一个串**，且等于产品名。
//     这一条是唯一能挡住"把切词换个写法复活"（`.prefix(6)`、`components(separatedBy:).first`
//     都不再是 `split(separator: " ")`，只数写法挡不住）。
//  ② **来源唯一**：原始进程名永远进不了身份串（走真实渲染路径 `AgentChip.displayedName`）。
//  ③ **写法**：全 UI 代码行里 `split(separator: " ")` 一处都不许有（含"第二条切词路"）。
//  ④ **裸字面量**：`"Agent"` 这个字面量只许出现在文案表里，或出现在点名豁免的
//     两个过滤条文件里；豁免按 (文件, 行) 点名，且**反向要求那一行还在**。
//     —— 那两处按本波硬边界（各页 Model 与过滤条不归本车道）**没收口**，登记在这里
//     是为了让它不是一个静默的洞：改好了必须来删条目，删不掉条目就说明它又长回来了。
//
//  收口这一笔（本车道接手 372a859 那半笔）再加三道：
//  ⑤ **默认语言**：三颗取词函数的默认参数必须是进程内缓存的 `UILanguage.current`，
//     不许是每次调用的 `AppLanguage.resolved()`（两颗取值完全相同 ⇒ 只有源码级断言挡得住，
//     而这一颗是每行、每 tick 都要过的）。
//  ⑥ **出口唯一（`agentKind`）**：UI 代码行里 `agentKind.displayName` 必须为 0，不给豁免。
//  ⑦ **出口唯一（其它形状）**：`kind.displayName` 里属于 Agent 的那些，除归一层本体与
//     点名豁免（过滤条 / Model / 首页文案表 / 预览夹具）之外一处不许有；
//     豁免逐条反向要求原文还在，并封顶条目数（只许减不许增）。
//
//  ⚠️ 本文件**不动 `Contracts/**` 的 `displayName`**（#82 边界：那条双语流在 main 上跑）。
//  ①②钉的正是"UI 层收口之后 Contracts 一个字节都不用改"这件事。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: #82 Agent 展示名只有一个入口，且不再被即兴截断", .timeLimit(.minutes(1)))
struct AgentNamingTests {

    private static let languages: [AppLanguage] = [.chineseSimplified, .english]

    // MARK: ① 紧凑态不再切首词

    @Test("已知 kind：紧凑态与非紧凑态同名，且逐字等于产品名（一个词都没被切掉）")
    @MainActor
    func compactFormStopsCuttingFirstWord() {
        for kind in AgentKind.allCases where !AttributionCopy.isUnattributed(kind) {
            let full = AgentNaming.name(kind: kind, form: .full)
            let compact = AgentNaming.name(kind: kind, form: .compact)
            #expect(full == kind.displayName, "\(kind) 的展示名不是产品名：\(full)")
            #expect(compact == full,
                    "\(kind) 紧凑态被改了名字：\(compact) vs \(full) ⇒ #82 之后形态不许改名")
            // 词数不变是"没被切"的最小可核对形状（"OpenAI Codex CLI" 不许变 "OpenAI"）。
            #expect(compact.split(separator: " ").count == full.split(separator: " ").count)
        }
        // 两个曾经被切得最明显的，逐字钉住（名字写死在这里 = 手推的期望，不是实现现在长什么样）。
        #expect(AgentNaming.name(kind: .claudeCode, form: .compact) == "Claude Code")
        #expect(AgentNaming.name(kind: .openAICodex, form: .compact) == "OpenAI Codex CLI")
    }

    @Test("未归属那一族仍然两态分开（#47-B 判据①没被 #82 顺手做没）")
    @MainActor
    func unattributedKeepsTwoForms() {
        let compact = AgentNaming.name(kind: .unknown, form: .compact)
        let full = AgentNaming.name(kind: .unknown, form: .full)
        #expect(compact != full, "两态同名 ⇒ 那一格又要塞整句，或者又只剩一个词")
        #expect(compact == AttributionCopy.labelCompact.text(.resolved()))
        #expect(full == AttributionCopy.labelFull.text(.resolved()))
        #expect(!compact.contains("Unknown") && !full.contains("Unknown"))
    }

    // MARK: ② 原始进程名进不了身份串

    /// 走**真实渲染路径**（`AgentChip.displayedName`）而不是只测 `AgentNaming`：
    /// 调用点传进来的 `displayName` 正是探测到的进程名（`claude`/`codex`），
    /// 它一旦还能覆盖身份串，①就只是纸面口径。
    @Test("原始进程名不参与身份串：传 claude 也叫 Claude Code")
    @MainActor
    func processNameNeverBecomesIdentity() {
        #expect(AgentChip.displayedName(kind: .claudeCode, displayName: "claude", compact: false)
                == "Claude Code")
        #expect(AgentChip.displayedName(kind: .openAICodex, displayName: "codex", compact: true)
                == "OpenAI Codex CLI")
        #expect(AgentChip.displayedName(kind: .cursorAgent, displayName: "Cursor Agent", compact: true)
                == "Cursor Agent")
        // 它唯一的去处是 tooltip 那一句。
        let hint = AgentNaming.processNameTooltip("claude", .chineseSimplified)
        #expect(hint.contains("claude") && hint.contains("进程名"), "\(hint)")
        let hintEn = AgentNaming.processNameTooltip("claude", .english)
        #expect(hintEn.lowercased().contains("claude") && hintEn.lowercased().contains("process"),
                "\(hintEn)")
    }

    // MARK: ③ 写法：不许有第二条切词路

    @Test("全 UI 代码行里没有一处按空格切词（切首词不许以别的写法复活）")
    func noWordCuttingAnywhereInUI() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI").count >= 100,
                "UI 目录读不到预期份数 ⇒ 这条闸扫的是空气")
        var offenders: [String] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = "Sources/AIObservatoryUI/" + (url.path.components(separatedBy: "Sources/AIObservatoryUI/").last ?? "")
            let code = try BilingualCopyGate.codeOnlyString(relative)
            if code.contains("split(separator: \" \")") { offenders.append(relative) }
        }
        #expect(offenders.isEmpty, "切词路复活了：\(offenders)")
    }

    // MARK: ④ 裸字面量「Agent」

    /// 本波硬边界之外、因此**没收口**的两处（各页过滤条不归本车道）。
    /// 改好一处就必须来删一条，删不干净 = 这条豁免在替人掩盖。
    private static let bareLabelExemptions: [(file: String, needle: String)] = [
        ("Sources/AIObservatoryUI/Files/FilesFilterBar.swift", "agentKinds.first?.displayName ?? \"Agent\""),
        ("Sources/AIObservatoryUI/Commands/CommandsFilterBar.swift", "agentKinds.first?.displayName ?? \"Agent\""),
    ]

    @Test("「Agent」这个标签只剩文案表与两处点名的过滤条豁免")
    func bareAgentLiteralsAreAccountedFor() throws {
        var strays: [String] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = "Sources/AIObservatoryUI/" + (url.path.components(separatedBy: "Sources/AIObservatoryUI/").last ?? "")
            let exempt = Self.bareLabelExemptions.contains { $0.file == relative }
            let tables = relative.hasSuffix("Copy.swift") || relative.hasSuffix("AgentNaming.swift")
            for line in try BilingualCopyGate.codeOnlyString(relative).split(separator: "\n") {
                guard line.replacingOccurrences(of: " ", with: "").contains("\"Agent\"") else { continue }
                if tables || exempt { continue }
                strays.append("\(relative) → \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(strays.isEmpty,
                "又有裸的 \"Agent\" 字面量上屏（应走 AgentNaming.fieldLabel）：\(strays)")
        for exemption in Self.bareLabelExemptions {
            let text = try BilingualCopyGate.codeOnlyString(exemption.file)
            #expect(text.contains(exemption.needle),
                    "豁免清单里这条已经不在了 ⇒ 已经修好，来删条目：\(exemption.file)")
        }
    }

    // MARK: 表本身

    @Test("AgentNaming 的双语表合格：无缺陷、名字不重复、两语同串只有点名的那一条")
    func tableIsSound() {
        #expect(copyProblems(in: AgentNaming.bilingualCopy).isEmpty)
        #expect(duplicateCopyNames(in: AgentNaming.bilingualCopy).isEmpty)
        let shared = AgentNaming.bilingualCopy
            .filter { $0.copy.english == $0.copy.chineseSimplified }
            .map(\.name)
        #expect(shared == ["design.agent.fieldLabel"],
                "两语同串的条目和口径对不上：\(shared)（「Agent」是类别名，别的都要译）")
        // 含中文的那条必须有英文侧，否则英文态上屏的是半截中文。
        for entry in AgentNaming.bilingualCopy where entry.copy.chineseSimplified.containsHan {
            #expect(!entry.copy.english.containsHan, "\(entry.name) 英文侧没译")
        }
        for language in Self.languages {
            #expect(!AgentNaming.fieldLabel.text(language).isEmpty)
        }
    }

    // MARK: ⑤ 取词不许每次调用都去解析系统语言

    /// 本车道的第一版把三处默认参数写成 `AppLanguage.resolved()`，那是**每行、每 tick**
    /// 都解析一次 `Locale.preferredLanguages`（`AgentChip` 每一行过一次取词，首页活跃
    /// Agent 列表跟着刷新）。口径写在 `Shell/ShellCopy.swift:43-52`（`UILanguage` 文件头：
    /// 语言只跟随系统、进程内解析一次），共享控件必须照同一把尺。
    /// 值上两条完全等价（`UILanguage.current == .resolved()`），所以**只有源码级断言挡得住**：
    /// 把默认参数换回 `.resolved()`，行为测试一条都不会红。
    @Test("归一层的默认语言是进程内缓存的那一颗，不是每次调用的系统偏好解析")
    func languageDefaultsAreTheCachedOne() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/DesignSystem/AgentNaming.swift")
        let perCall = code.split(separator: "\n").filter { $0.contains("= .resolved()") }
        #expect(perCall.isEmpty,
                "取词函数里又有每次调用的语言解析（应写 `= UILanguage.current`）：\n\(perCall)")
        let cached = code.split(separator: "\n").filter { $0.contains("= UILanguage.current") }.count
        // 三颗取词函数：name / processNameTooltip / reasonText。少一颗 = 那颗退回每调用解析。
        #expect(cached == 3, "取词函数只有 \(cached) 颗用缓存语言（应为 3 颗）⇒ 有一颗漂回去了")
    }

    // MARK: ⑥⑦ 身份串只有一个出处（含点名豁免）

    /// 全 UI 代码行里 `agentKind.displayName` 必须**一个都不剩**（记录 / 事件 / 变更 / 命令
    /// 这一族是台账点名的那批出口：四张详情面、六处读屏、剪贴板那一份）。
    /// 这一条不给任何豁免：`agentKind` 这个属性名只属于 AgentKind，不存在误伤。
    @Test("UI 代码行里不许再直接读 `agentKind.displayName`（身份串只有一个出处）")
    func agentKindDisplayNameIsGoneFromUI() throws {
        var strays: [String] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = "Sources/AIObservatoryUI/" + (url.path.components(separatedBy: "Sources/AIObservatoryUI/").last ?? "")
            for line in try BilingualCopyGate.codeOnlyString(relative).split(separator: "\n")
            where line.contains("agentKind.displayName") {
                strays.append("\(relative) → \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(strays.isEmpty,
                "又有格子绕过 `AgentNaming.name` 直接读产品名：\(strays)")
    }

    /// 台账那批之外的 AgentKind 取词，按**本波硬边界**没收口（各页 Model 与过滤条不归本车道，
    /// `Dashboard/**` 只许改视图与卡片）。登记成点名豁免，是为了让它不是静默的洞：
    /// 每一条都反向要求那一行还在——改好了必须来删条目，删不掉就说明它又长回来了。
    /// （`Files` / `Commands` 那两条过滤条的裸 `"Agent"` 字面量在 ④ 的清单里，同一条理由。）
    private static let identityExemptions: [(file: String, needle: String)] = [
        // 五页的 Agent 筛选菜单（过滤条，硬边界外）
        ("Sources/AIObservatoryUI/Files/FilesFilterBar.swift", "\"\\(kind.displayName)  (\\(model.eventCount(for: kind)))\""),
        ("Sources/AIObservatoryUI/Files/FilesFilterBar.swift", "kind.displayName,"),
        ("Sources/AIObservatoryUI/Commands/CommandsFilterBar.swift", "kind.displayName,"),
        ("Sources/AIObservatoryUI/Sessions/SessionFilterBar.swift", "kind.displayName,"),
        ("Sources/AIObservatoryUI/Timeline/TimelineFilterBar.swift", "Label(kind.displayName"),
        ("Sources/AIObservatoryUI/Projects/ProjectsView.swift", "kind.displayName,"),
        // 搜索命中用的 haystack 与排序键：不上屏，但仍是第二个出处（Model 硬边界外）
        ("Sources/AIObservatoryUI/Sessions/SessionsModel.swift", "session.kind.displayName"),
        ("Sources/AIObservatoryUI/Performance/PerformanceModel.swift", "session.kind.displayName"),
        ("Sources/AIObservatoryUI/Projects/ProjectModelExtensions.swift", "lhs.kind.displayName < rhs.kind.displayName"),
        // 首页占比读数的读屏句（`Dashboard/**` 只许改视图与卡片，这份是文案表）
        ("Sources/AIObservatoryUI/Dashboard/DashboardCopy.swift", "language, kind.displayName, sessions"),
    ]

    /// `kind.displayName` 这个形状里,**哪些前缀不是 Agent**（同名的还有事件种类 /
    /// 文件变更种类 / 异常种类）：它们各自有自己的枚举，与 #82 无关，扫到就跳。
    private static let notAnAgentReceivers = ["event.kind.", "change.kind.", "row.kind.", "finding.kind."]

    @Test("点名豁免的清单逐条还在，且 UI 里没有清单之外的第二处 Agent 取词")
    func identityExemptionsAreStillExact() throws {
        for exemption in Self.identityExemptions {
            let code = try BilingualCopyGate.codeOnlyString(exemption.file)
            #expect(code.contains(exemption.needle),
                    "豁免清单里这条已经不在了 ⇒ 已经修好，来删条目：\(exemption.file) 找 \(exemption.needle)")
        }
        // 归一层本体（唯一出口 + 未归属那一族的分支）与预览夹具的其余几行。
        let sanctioned: Set<String> = Set(Self.identityExemptions.map(\.file))
            .union([
                "Sources/AIObservatoryUI/DesignSystem/AgentNaming.swift",
                "Sources/AIObservatoryUI/DesignSystem/AttributionCopy.swift",
                "Sources/AIObservatoryUI/DesignSystem/ObservatoryPreviewSupport.swift",
            ])
        var strays: [String] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI") {
            let relative = "Sources/AIObservatoryUI/" + (url.path.components(separatedBy: "Sources/AIObservatoryUI/").last ?? "")
            guard !sanctioned.contains(relative) else { continue }
            for line in try BilingualCopyGate.codeOnlyString(relative).split(separator: "\n")
            where line.contains("kind.displayName")
                    && !Self.notAnAgentReceivers.contains(where: line.contains) {
                strays.append("\(relative) → \(line.trimmingCharacters(in: .whitespaces))")
            }
        }
        #expect(strays.isEmpty,
                "又开出一处绕过归一层的 Agent 取词（先问能不能写成 `AgentNaming.name`）：\(strays)")
        // 豁免表本身不许悄悄长胖：这一族只该减不该增。
        #expect(Self.identityExemptions.count <= 11,
                "豁免条目 \(Self.identityExemptions.count) 条 ⇒ 有新的取词出口，停下来回报总控")
    }
}
