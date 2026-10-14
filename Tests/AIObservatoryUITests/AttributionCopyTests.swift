//
//  AttributionCopyTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · #47-B 界面侧）
//  ─────────────────────────────────────────────────────────
//  把总控 04:47 裁定的三条硬判据变成可执行断言。判据原文写在
//  `Sources/AIObservatoryUI/DesignSystem/AttributionCopy.swift` 文件头。
//
//  为什么长这样：① 与 ③ 是**措辞**约束，只能拿字符串钉；② 是**可达性**约束，
//  光测函数证不了"原因真的在某一屏上读得到"，所以 ② 拆成两半——
//  版面那一半用源码级接线检查钉（详情面必须真的排了 `AttributionReasonNote`），
//  最后一眼仍以真机截图为准（中英各一张，见交付块）。
//
//  ⚠️ 反向禁句一律**先剥注释再查**，而且禁句表里不许出现我自己句子里有的词：
//  「不代表这台机器上没有 Agent 在动」这句话本身就含"没有 Agent 在动"六个字，
//  拿它当禁句会自己抓自己（本仓犯过三次）。所以 ③ 的正向断言是"必须带否定标记"。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: #47-B「未能归属到某个 Agent」三条判据", .timeLimit(.minutes(2)))
struct AttributionCopyTests {

    private static let languages: [AppLanguage] = [.chineseSimplified, .english]

    // MARK: 表本身

    @Test("归属文案表无缺陷、名字不重复、两语都真的给了")
    func tableIsSound() {
        #expect(copyProblems(in: AttributionCopy.bilingualCopy).isEmpty)
        #expect(duplicateCopyNames(in: AttributionCopy.bilingualCopy).isEmpty)
        let untranslated = AttributionCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }
        #expect(untranslated.map(\.name) == [])
        #expect(AttributionCopy.bilingualCopy.filter { $0.copy.english.containsHan }.isEmpty)
    }

    // MARK: 判据①：那一列不许出现裸 `Unknown`

    @Test("判据①：`.unknown` 两语、紧凑与非紧凑都不给裸 Unknown")
    func unknownChipNeverSaysBareUnknown() {
        for language in Self.languages {
            for compact in [true, false] {
                let label = AttributionCopy.label(kind: .unknown, compact: compact, language)
                #expect(!label.isEmpty)
                // Core 那两个原值是 "Unknown Agent" / 切首词后的 "Unknown"——两个都不许出现。
                #expect(!label.contains("Unknown"), "\(language) compact=\(compact) 仍是 \(label)")
                #expect(!label.contains("未知"), "\(language) compact=\(compact) 仍是 \(label)")
                // 「必须点名归不到谁」只对**非紧凑**那一版成立：紧凑格位宽 ~86 pt，
                // 中文 4 字放不下宾语（判据②把整句与原因放在详情面和 tooltip 里）。
                // 原来这条对两种形态都查，等于要求列里塞下整句 ⇒ 断言本身错了，
                // 不是实现错了；改完仍然钉住紧凑态不许退化成裸状态词 + 长度上限。
                if !compact {
                    #expect(label.contains("Agent") || label.contains("agent"), "\(label)")
                }
            }
        }
        // 紧凑位宽：列只有 ~86 pt（`TimelineMetrics.agentColumnWidth` 104 − 图标 − 间距）。
        #expect(AttributionCopy.label(kind: .unknown, compact: true, .chineseSimplified).count <= 5)
    }

    @Test("判据①：其它 Agent 的名字一个都没被顺手改掉")
    func knownKindsStillUseTheirOwnNames() {
        for kind in AgentKind.allCases where kind != .unknown {
            for language in Self.languages {
                #expect(AttributionCopy.label(kind: kind, compact: true, language) == kind.displayName)
                #expect(AttributionCopy.label(kind: kind, compact: false, language) == kind.displayName)
            }
        }
    }

    /// 走**真实渲染路径**（`AgentChip.displayedName`）而不是只测文案函数。
    /// 原来这里是一条源码级"分支顺序"检查，被变异测试证明是假的：把 `.unknown` 分支整段删掉，
    /// 它仍然绿——因为 `.help(...)` 那行里也有 `isUnattributed(kind)`，顺序判断被它骗过了。
    /// ⇒ 判据①钉在纯函数上，行为可测；源码只额外钉一句"视图确实调它"。
    /// #82 之后那条切首词的分支已经不存在，这一族用例因此同时钉两件事：
    /// 未归属走归属标签（原判据①）、已知 kind 紧凑态**不再被切**（`AgentNamingTests`）。
    // `AgentChip` 是 View ⇒ 它的静态取词方法天然是 main-actor 隔离的。
    // 用例要走的正是**这条真实路径**（不是另抽一个 nonisolated 的纯函数来测），
    // 所以把测试本身标成 @MainActor，而不是把生产代码的隔离性放宽来迁就测试。
    @Test("判据①：AgentChip 的真实取词路径不出裸 Unknown")
    @MainActor
    func renderedPathNeverShowsBareUnknown() {
        let compactZh = AttributionCopy.labelCompact.text(.chineseSimplified)
        let compactEn = AttributionCopy.labelCompact.text(.english)
        let fullZh = AttributionCopy.labelFull.text(.chineseSimplified)
        let fullEn = AttributionCopy.labelFull.text(.english)

        let compactOut = AgentChip.displayedName(kind: .unknown, displayName: nil, compact: true)
        #expect(!compactOut.contains("Unknown"), "\(compactOut)")
        #expect([compactZh, compactEn].contains(compactOut),
                "紧凑态没有走归属标签，而是走了切首词：\(compactOut)")

        let fullOut = AgentChip.displayedName(kind: .unknown, displayName: nil, compact: false)
        #expect([fullZh, fullEn].contains(fullOut), "非紧凑态没走整句标签：\(fullOut)")

        // 调用点会把自己那份 `kind.displayName`（"Unknown Agent"）当 displayName 传进来
        // （`TimelineEventDetail` 就是）。未归属态必须**无视**它，否则判据①从后门漏掉。
        let withExplicit = AgentChip.displayedName(
            kind: .unknown, displayName: "Unknown Agent", compact: true
        )
        #expect(withExplicit == compactOut,
                "显式 displayName 绕过了归属标签：\(withExplicit)")
    }

    @Test("判据①：视图确实走 displayedName，没有第二条取词路")
    func chipBodyUsesTheSinglePath() throws {
        let chip = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/DesignSystem/AgentChip.swift"
        )
        #expect(chip.contains("Self.displayedName(kind: kind, displayName: displayName, compact: compact)"),
                "AgentChip 不再经过 displayedName ⇒ 判据①的用例测的是死代码")
        // 【#82 把这一条改**强**了，不是改松】
        // 改前这里是 `cuts == 1`：整份文件里 `split(separator: " ")` 恰好一处，
        // 那条就是紧凑态的"切首词"——未归属分支挡得住它，但**产品名自己被切掉了**
        // （`OpenAI Codex CLI` → `OpenAI`）。#82 的口径是删掉这种即兴截断，
        // 于是"恰好一处"变成了必须守不住的旧尺子。现在钉的是 **0 处**：
        // chip 里根本不许存在切词路，判据①不需要再靠"分支顺序"去保护任何东西。
        // 0 比 1 更严：任何一处复活（包括有人新加一处）都会红，而 `== 1` 会放过
        // "删掉旧的、加新的"这种漂移动作。同族名是否真的不再被切，
        // 由 `AgentNamingTests` 那一族按**输出值**钉（不只数写法）。
        let cuts = chip.components(separatedBy: "split(separator: \" \")").count - 1
        #expect(cuts == 0, "chip 里有 \(cuts) 处切词路：#82 之后一处都不许存在")
    }

    // MARK: 判据②：可读的一句 + 能展开原因

    @Test("判据②：整句标签说得清对象，原因句给出可核对的机制")
    func labelAndReasonAreReadable() {
        let fullZh = AttributionCopy.labelFull.text(.chineseSimplified)
        #expect(fullZh == "未能归属到某个 Agent")
        #expect(AttributionCopy.labelFull.text(.english) == "Not attributed to an agent")
        let reason = AttributionCopy.reason.text(.chineseSimplified)
        // 三个具体线索必须都在：没 tty、宿主命令行只有自身路径、cwd 是 `/`。
        #expect(reason.contains("tty"), "\(reason)")
        #expect(reason.contains("命令行"), "\(reason)")
        #expect(reason.contains("工作目录"), "\(reason)")
        #expect(reason.contains("`/`"), "\(reason)")
    }

    @Test("判据②：原因在三个详情面都真的排上屏（不只 hover）")
    func reasonIsOnScreenNotOnlyInTooltip() throws {
        let surfaces = [
            "Sources/AIObservatoryUI/Security/SecurityDetailPanel.swift",
            "Sources/AIObservatoryUI/Security/SecurityConfirmationSheet.swift",
            "Sources/AIObservatoryUI/Timeline/TimelineEventDetail.swift",
        ]
        for file in surfaces {
            let code = try BilingualCopyGate.codeOnlyString(file)
            #expect(code.contains("AttributionReasonNote(kind:"), "\(file) 没把原因句排上版面")
            // 【#82 把这一条改**强**了，不是改松】原来钉的是 `AttributionCopy.label(kind:`，
            // 那是"没直接读 `kind.displayName`"的代理判据；#82 之后取词只有一个入口，
            // 所以这里同时要求两件事：走 `AgentNaming.name`（入口唯一）**且**写明 `form: .full`
            // （详情面给整句，不许有人图省事把它换成紧凑标签——那正是判据②要杀的"看不见那句解释"）。
            // 旧尺子放得过"入口之外另起一处 label 调用"，新尺子不放。
            #expect(code.contains("AgentNaming.name(kind:"),
                    "\(file) 的 Agent 那一格没走归一层 ⇒ 同一记录又要出现两个名字")
            #expect(code.contains("form: .full"),
                    "\(file) 的 Agent 那一格没写明整句形态 ⇒ 详情面可能退回短标签")
        }
        // tooltip 是**补充**通道（鼠标），不是唯一通道。
        let chip = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryUI/DesignSystem/AgentChip.swift")
        #expect(chip.contains(".help(AttributionCopy.isUnattributed(kind)"), "chip 上的原因 tooltip 被摘了")
    }

    @Test("判据②：`AttributionReasonNote` 只在未归属时占版面")
    func noteRendersOnlyForUnknown() {
        // 已知 Agent 的记录不许凭空多出一段解释（那会把"归属"那一屏变成说教）。
        #expect(AttributionCopy.isUnattributed(.unknown))
        #expect(!AttributionCopy.isUnattributed(.claudeCode))
        #expect(!AttributionCopy.isUnattributed(.genericCLIAgent))
    }

    // MARK: 判据③：两个"不许"

    @Test("判据③：原因句不指向用户配置（ICR-0006 约束①同一条）")
    func reasonNeverBlamesUserConfiguration() {
        let banned = ["配置", "忽略规则", "监控根", "未开启", "设置里", "permission"]
        for language in Self.languages {
            let reason = AttributionCopy.reason.text(language)
            for phrase in banned {
                #expect(!reason.contains(phrase),
                        "\(language) 的原因句里出现「\(phrase)」⇒ 把采集面的边界写成了用户的错")
            }
        }
    }

    @Test("判据③：原因句必须自带「不是这台机器上没人」的否定标记")
    func reasonDeniesTheNoAgentsReading() {
        // 正向断言而不是禁句：本句本身就含"没有 Agent 在动"六个字（在否定短语里），
        // 拿它当禁句会自己抓自己。要求它**带否定前缀**才是判据要的形状。
        #expect(AttributionCopy.reason.text(.chineseSimplified).contains("不代表"))
        #expect(AttributionCopy.reason.text(.english).contains("not a claim"))
    }

    @Test("判据③：不编造「没检出 / 检出了但归不了因」的区分")
    func reasonDoesNotInventACauseSplit() {
        // 今天数据侧只有 `AgentKind.unknown` 一个值（`ws/engaudit` 的 ICR 未批）。
        // 所以机制只能作为**举例**出现，不能断言"这一条就是 GUI 宿主拉起的"。
        let zh = AttributionCopy.reason.text(.chineseSimplified)
        let en = AttributionCopy.reason.text(.english)
        #expect(zh.contains("例如"), "\(zh)")
        #expect(en.lowercased().contains("for example"), "\(en)")
        // 也不许出现只有两个值才配得上的分类词。
        for phrase in ["这一条是", "该会话由", "原因是", "because this record"] {
            #expect(!zh.contains(phrase) && !en.lowercased().contains(phrase.lowercased()),
                    "原因句把举例写成了对这一条的诊断：\(phrase)")
        }
    }
}
