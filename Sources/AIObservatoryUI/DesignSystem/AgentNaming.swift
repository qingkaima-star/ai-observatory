//
//  AgentNaming.swift
//  AIObservatoryUI / DesignSystem
//
//  Owner: ws/consistency（批 3 · #82 工具命名归一，**只在 UI 层**）
//  ─────────────────────────────────────────────────────────
//  「这个 Agent 在界面上叫什么」的**唯一入口**。
//
//  【治的病：三套身份源并存，且没有归一层】改前实测（台账 整改波次-2026-09-22 第六节 C）：
//    · `AgentKind.displayName` —— 英文产品名（"Claude Code"、"OpenAI Codex CLI"），无语言入参；
//    · `AgentInstance.displayName` —— 探测到的**原始进程名**（`claude`/`codex`/`cursor`，
//      见 `AgentSignatureDatabase.swift:82,97,105`）；
//    · `AgentChip.displayedName` —— 紧凑态把上面两者**切首词**
//      （`String(full.split(separator: " ").first …)`）。
//  三者叠在同一列里，于是 `Claude Code` 与 `Claude`、`OpenAI Codex CLI` 与 `OpenAI`
//  并排出现——**同一个记录在详情页与列表行里换了两个名字**。产品名被切掉的第二个词
//  往往正是区别本身（"Code" 之于 Claude、"Codex CLI" 之于 OpenAI）。
//
//  【口径（#82）】
//  ① 展示名只从 `AgentKind.displayName` 来（未归属那一族仍走 `AttributionCopy`，见其文件头）；
//     **原始进程名永远不进身份串**，它只有一个去处：tooltip 里那句「进程名 claude」。
//  ② **紧凑态不再切首词**。放不下就是放不下：由版面省略号截断（`.lineLimit(1)`）
//     并在 tooltip 里给全名——截断是**可核对的**（读到"OpenAI Codex C…"知道自己在看被截的
//     全名），改名不是（"OpenAI" 会被当成另一个产品）。
//  ③ 字段标签「Agent」这种**裸字面量**走本表（双语）。改前 4 处 `InlineStat("Agent", …)`
//     + 1 处图表轴标签 + 3 处过滤条 fallback。
//  ④ **形态按射程选，不按页选**：列表行（含行内读屏那一句）用 `.compact`，
//     详情面 / 会话头部 / 复制到剪贴板那一份用 `.full`。两态取的是同一个名字，
//     只有未归属那一族给短标签还是整句不同（位宽问题，不是改名）。
//
//  【收口补记（本车道接手 372a859 那半笔）】台账点名的五类写法之外，还查出两条**同种病**的出口：
//    · 详情面「Agent」那一格的**值**直接叫 `AttributionCopy.label(...)`（三个详情面 + 会话详情三处）
//      ⇒ 绕过入口，等于留了第二个出处；现在统一走 `name(kind:form: .full)`。
//    · **读屏与剪贴板**那一份身份串还在读 `agentKind.displayName` / `session.kind.displayName`
//      / `agent.displayName`（时间线行、文件行、会话行、会话命令列表、项目卡、性能页、
//      首页活跃 Agent 行、时间线详情的复制文本）⇒ 眼睛看到「未能归属到某个 Agent」、
//      耳朵听到 "Unknown Agent"；进程名 `claude` 也被念成身份。现在同一个入口，形态跟着那一格走。
//  用例：`AgentNamingTests`（⑤ 默认语言、⑥⑦ 出口唯一）与 `AttributionCopyTests`（判据② 加强）。
//
//  ⚠️ 本文件**不动 `Contracts/**` 的 `displayName`**（#82 的边界：那条双语流在 main 上跑）。
//  这里收的只是"UI 从哪儿取名字、怎么截"。UI 之外的出口（`AIObservatoryExport` /
//  `AIObservatoryCLI` / `Insights` / 系统通知）继续直接读 `AgentKind.displayName`：
//  那是机器可读产物、不是界面身份格，#82 的射程不含它们。
//  过滤条那三处 fallback 在 `Files/**FilesFilterBar.swift` 与 `Commands/**CommandsFilterBar.swift`
//  ——按本波硬边界（各页 Model 与过滤条不归本车道）未收，已回给总控点名；
//  连同五页筛选菜单与三处 Model 的取词一起，逐条登记在 `AgentNamingTests` 的豁免清单里
//  （改好一条就得来删一条，删不掉 = 它又长回来了）。
//

import Foundation
import SwiftUI
import AIObservatoryCore

/// Agent 展示名的唯一入口。新增一处"取名字"的逻辑之前先问：它能不能表达成这里的一次调用？
enum AgentNaming {

    // MARK: 措辞（双语表）

    /// 字段标签「Agent」——详情面板那一行"这个记录属于谁"的标签。
    /// 两语同串是**有意的**：这里出现的是产品类别名，不是待译的中文词
    /// （`LocalizedString.problems` 只在"含中文且两语同串"时判未译，见其 ③ 判定）。
    static let fieldLabel = NamedCopy("design.agent.fieldLabel", LocalizedString(zh: "Agent", en: "Agent"))

    /// 原始进程名的去处：tooltip 里那一句。它不参与身份判定，只回答
    /// "我们在这台机器上实际看到的是哪个可执行名"。
    static let processNameHint = NamedCopy("design.agent.processName",
                                           LocalizedString(zh: "进程名 %@", en: "Process %@"))

    // MARK: 形态

    /// 展示形态。**两种形态取的是同一个名字**——这一条就是 #82 要立的口径：
    /// 形态只决定"未归属那一格给短标签还是整句"（位宽问题），
    /// 绝不决定"把产品名切掉一半"。
    enum Form {
        case full
        case compact

        var isCompact: Bool { self == .compact }
    }

    // MARK: 取词

    /// 这一格应该显示什么名字。
    ///
    /// 未归属那族走 `AttributionCopy`（它的判据①要的是"不许出现裸 Unknown"，
    /// 那个标签不是产品名，是一句归因结论）；其余一律 `AgentKind.displayName`，
    /// **全仓唯一一处 UI 取产品名的地方**。
    ///
    /// ⚠️ 默认语言是 `UILanguage.current`（进程内解析一次）而**不是** `AppLanguage.resolved()`：
    /// 后者每次调用都去解析 `Locale.preferredLanguages`，而这一颗函数是**每一行、每个 tick**
    /// 都要过的（`AgentChip` 走它，首页活跃 Agent 列表跟着刷新）——
    /// 口径与理由写在 `Shell/ShellCopy.swift:43-52`（`UILanguage` 的文件头），
    /// 这里照同一把尺做。用例 `AgentNamingTests` ⑤ 把它钉成源码级断言。
    static func name(kind: AgentKind,
                     form: Form = .full,
                     _ language: AppLanguage = UILanguage.current) -> String {
        if AttributionCopy.isUnattributed(kind) {
            return AttributionCopy.label(kind: kind, compact: form.isCompact, language)
        }
        return kind.displayName
    }

    /// tooltip / 详情里那句"我们看到的进程名是什么"。
    ///
    /// 与身份串分开的理由：`claude` 与 `Claude Code` 不是两个 Agent，
    /// 一个是实例读到的可执行名、一个是产品名；把它们混在同一格里，
    /// 读者就只能猜这一列到底按什么排（改前正是这个样子）。
    ///
    /// 函数名与常量 `processNameHint` **刻意不同名**（同 `AttributionCopy.reason` /
    /// `reasonText` 那条）：同名只靠参数表区分，读代码的人会先怀疑自己看错了哪一个。
    ///
    /// 默认语言与 `name(kind:form:_:)` 同一颗尺（见那里的 ⚠️：这一句也挂在每一行的 tooltip 上）。
    static func processNameTooltip(_ processName: String,
                                   _ language: AppLanguage = UILanguage.current) -> String {
        processNameHint.copy.format(language, processName)
    }

    /// 未归属那一族的原因句（与 `AgentChip` 的 tooltip 同一个出处，不另拼一句）。
    static func reasonText(_ language: AppLanguage = UILanguage.current) -> String {
        AttributionCopy.reasonText(language)
    }

    // MARK: - 集中清单（门禁遍历这一份）

    static let bilingualCopy: [NamedCopy] = [
        fieldLabel,
        processNameHint,
    ]
}
