//
//  AttributionCopy.swift
//  AIObservatoryUI / DesignSystem
//
//  Owner: WS-UI（uicopy · #47-B 界面侧）
//  ─────────────────────────────────────────────────────────
//  「这条记录归不到任何 Agent 名下」这件事在界面上怎么说。
//
//  【为什么要单独一张表，而不是塞进 SecurityCopy / TimelineCopy】渲染它的是
//  `AgentChip`（DesignSystem 的共享控件，15 个文件在用：风险列表、时间线行、会话行、
//  文件行、命令页、项目卡、概览…）。文案放进任何一个板块的表里，其它板块就得跨板块读，
//  或者各自抄一份——抄一份就是本仓头号缺陷族（第二个出处必分叉）。
//  共享控件的措辞跟着控件走，这是 `ReadoutCopy` 立下的同一条例外。
//
//  【三条硬判据落在代码上的位置】
//  ① 那一列不许出现裸 `Unknown`：`AgentChip` 紧凑态原来是拿 `kind.displayName`
//     **切首词**（"Unknown Agent" → "Unknown"）。`.unknown` 一律走本表的标签，
//     不再经过切词。用例 `unknownChipNeverSaysBareUnknown` 钉住。
//  ② 可读的一句 + 能展开原因：紧凑列位宽只有 ~86 pt（`TimelineMetrics.agentColumnWidth`
//     104 pt 减图标与间距），放不下整句 ⇒ 列里给短标签、`.help` 给原因，
//     **整句标签与原因同时上屏**在三个详情面（风险详情、确认面板、事件详情）。
//     hover 才算"能展开"是不够的（键盘与读屏用户展不开），所以详情那一行是主路径。
//  ③ 原因不许写成"用户没配置监控根"（ICR-0006 约束①同一条），也不许暗示
//     "这台机器上没有 Agent 在动"。用例把这两条禁句钉成反向断言。
//
//  ⚠️ 今天数据侧只有 `AgentKind.unknown` 一个值，**分不出**「没检出」与「检出了但归不了因」
//  （`ws/engaudit` 的 ICR 还没批）。所以原因句写成"有些记录没有可用的线索（例如…）"，
//  用**举例**而不是断言这一条就是 GUI 宿主拉起的——那是要拿数据换的，现在没有那个数据。
//

import Foundation
import SwiftUI
import AIObservatoryCore

/// 「未能归属到某个 Agent」的措辞。只服务共享控件 `AgentChip` 与三个详情面的归属格。
enum AttributionCopy {

    /// 列内短标签（紧凑态）。位宽 ~86 pt，中文 4 字、英文单词级。
    ///
    /// ⚠️ 英文 "Unattributed" 12 字符，在**风险列表**那一格遇到长标题时会被截成
    /// `Unattribut…`（时间线那一格定宽 104 pt，完整）。没有换更短的英文词：
    /// "No agent" 一类写法会被读成"这台机器上没有 Agent"，正撞判据③。
    /// 要治的是那一格的让位顺序（标题该先让），已作为遗留项交回总控。
    static let labelCompact = NamedCopy("attribution.label.compact",
                                        LocalizedString(zh: "未能归属", en: "Unattributed"))

    /// 整句标签：详情面与读屏用（②里那句"可读的『未能归属到某个 Agent』"）。
    static let labelFull = NamedCopy("attribution.label.full",
                                     LocalizedString(zh: "未能归属到某个 Agent",
                                                     en: "Not attributed to an agent"))

    /// 可展开的原因。两个"不许"都写在句子里：不指向用户配置，也不指向"机器上没人"。
    static let reason = NamedCopy("attribution.reason", LocalizedString(
        zh: "这条记录未能归属到某个 Agent。识别 Agent 靠进程树与命令行，有些记录没有可用的线索"
              + "（例如由图形界面（GUI）宿主拉起的会话：没有 tty、宿主命令行只有它自己的路径、"
              + "工作目录是 `/`），因此落不到任何 Agent 名下。这是采集面的边界，"
              + "不代表这台机器上没有 Agent 在动。",
        en: "This record could not be attributed to an agent. Agents are identified from the process "
            + "tree and command lines, and some records carry no usable clue (for example sessions "
            + "started by a graphical (GUI) host: no tty, a host command line that is only the host's "
            + "own path, and a working directory of `/`), so they never resolve to an agent. "
            + "That is a limit of what can be observed — not a claim that no agents are running."
    ))

    /// Agent 身份的显示名。`.unknown` 走本表，其余仍走 `AgentKind.displayName`（唯一出处）。
    static func label(kind: AgentKind, compact: Bool, _ language: AppLanguage = UILanguage.current) -> String {
        guard kind == .unknown else { return kind.displayName }
        return compact ? labelCompact.text(language) : labelFull.text(language)
    }

    /// 原因句的展口。函数名与常量 `reason` 分开写：同名只靠参数表区分，
    /// 读代码的人会先怀疑自己看错了哪一个。
    static func reasonText(_ language: AppLanguage = UILanguage.current) -> String {
        reason.text(language)
    }

    /// 这一格是不是"未归属"态（详情面据此决定要不要把原因句排上屏）。
    static func isUnattributed(_ kind: AgentKind) -> Bool { kind == .unknown }

    // MARK: 归属缺口那一格（#54 / ICR-0009 界面侧）
    //
    // 三条硬约束直接落在文案上，逐条有用例（`AttributionGapPanelTests`）：
    // ① `nil` 与 `total == 0` 分开说（"没有读数" ≠ "一条都没漏"，ICR-0006 同一条约束）；
    // ② 每一句都带「本次运行内」——这份账不落库、重启归零，写成历史数就是假数；
    // ③ **只数不判**：措辞只描述引擎实际走过的分支，不出现"应该/建议/配置/责任"任何一个。
    //
    // 英文侧全部避开「数字紧跟复数名词」（`%d changes` 形）：要么名词前置、要么数字落在括号或
    // 破折号后面。`s`/`ms` 这类单位缩写是合法例外（窄豁免 + 校准用例 `a927c87`）。

    static let gapTitle = NamedCopy("attribution.gap.title", LocalizedString(
        zh: "本次运行内的归属缺口", en: "Attribution gaps in this run"))
    /// 排序口径句：**说的次序必须等于 `AttributionGapPanel.visibleReasons` 实际给的次序**（按 `Reason.rank`，
    /// 不是按条数）。这一句先前写的是「按条数排」，而代码按 `rank` 排 ⇒ 界面声称了一件它没做的事，
    /// 由 `subtitleOrderClaimMatchesTheRows` 钉住（用例里有反例数据：两种次序可区分）。
    static let gapSubtitle = NamedCopy("attribution.gap.subtitle", LocalizedString(
        zh: "只数不判：引擎实际给出的未归属机制，按固定次序列出",
        en: "Counts only — the mechanisms the engine actually reported, in a fixed order"))
    /// `currentAttributionGap() == nil`：引擎还没处理过文件事件。
    static let gapNoReading = NamedCopy("attribution.gap.noReading", LocalizedString(
        zh: "本次运行尚无归属读数：引擎还没处理过文件事件。",
        en: "No attribution reading in this run: the engine has not processed a file event yet."))
    /// `total == 0`：有读数，且一条都没漏。
    static let gapNothingMissing = NamedCopy("attribution.gap.nothingMissing", LocalizedString(
        zh: "本次运行内的文件变更全部归上了因（%1$d 条）。",
        en: "Every file change in this run was attributed (%1$d)."))
    /// 一行：机制名 + 条数。数字不紧跟英文名词，见上面那条口径。
    static let gapRow = NamedCopy("attribution.gap.row", LocalizedString(
        zh: "%1$@：%2$d 条", en: "%1$@ — %2$d"))
    static let gapTotalRow = NamedCopy("attribution.gap.totalRow", LocalizedString(
        zh: "合计 %1$d 条", en: "Total: %1$d"))

    /// 四个机制的名字。rawValue 不进数据侧，界面查表渲染（ICR-0008 口径）。
    static let gapReasonNothingDetected = NamedCopy("attribution.gap.reason.nothingDetected", LocalizedString(
        zh: "本次运行内注册表里一个 Agent 都没有",
        en: "The agent registry held no entries in this run"))
    static let gapReasonWorkingDirectoryUnusable = NamedCopy("attribution.gap.reason.workingDirectoryUnusable", LocalizedString(
        zh: "候选 Agent 的工作目录不足以当归属根（如 `/`、家目录）",
        en: "A candidate's working directory was too shallow to attribute (for example `/` or the home folder)"))
    static let gapReasonDetectedWithoutWorkingDirectory = NamedCopy("attribution.gap.reason.detectedWithoutWorkingDirectory", LocalizedString(
        zh: "有候选，但拿不到工作目录读数",
        en: "Candidates existed but no working directory could be read"))
    static let gapReasonOutsideEveryWorkingDirectory = NamedCopy("attribution.gap.reason.outsideEveryWorkingDirectory", LocalizedString(
        zh: "路径不在任何候选的工作目录下",
        en: "The path sat under none of the candidates' working directories"))

    static func gapReasonLabel(_ reason: AttributionGap.Reason, _ language: AppLanguage = UILanguage.current) -> String {
        switch reason {
        case .nothingDetected:                return gapReasonNothingDetected.text(language)
        case .workingDirectoryUnusable:       return gapReasonWorkingDirectoryUnusable.text(language)
        case .detectedWithoutWorkingDirectory: return gapReasonDetectedWithoutWorkingDirectory.text(language)
        case .outsideEveryWorkingDirectory:   return gapReasonOutsideEveryWorkingDirectory.text(language)
        }
    }

    // MARK: - 集中清单（门禁遍历这一份）

    // MARK: label 组文案（2 条，key 前缀 label.*）
    static let labelCopy: [NamedCopy] = [
        labelCompact,
        labelFull,
    ]

    // MARK: reason 组文案（1 条，key 前缀 reason.*）
    static let reasonCopy: [NamedCopy] = [
        reason,
    ]

    // MARK: gap 组文案（10 条，key 前缀 gap.*）
    static let gapCopy: [NamedCopy] = [
        gapTitle,
        gapSubtitle,
        gapNoReading,
        gapNothingMissing,
        gapRow,
        gapTotalRow,
        gapReasonNothingDetected,
        gapReasonWorkingDirectoryUnusable,
        gapReasonDetectedWithoutWorkingDirectory,
        gapReasonOutsideEveryWorkingDirectory,
    ]

    static let bilingualCopy: [NamedCopy] =
        labelCopy
        + reasonCopy
        + gapCopy

}

/// 原因句的**上屏形态**：只在未归属时出现，整段可读、可选中。
///
/// 为什么要有这个视图而不是各面板自己写一段 `if`：判据②要的是"能展开原因"，
/// 而 tooltip 只有鼠标能展开——键盘与读屏用户展不开。所以三个详情面（风险详情、
/// 确认面板、事件详情）都必须把这句排进版面；一处定义 ⇒ 三处不会各写一套措辞。
@MainActor struct AttributionReasonNote: View {
    private let kind: AgentKind

    init(kind: AgentKind) { self.kind = kind }

    var body: some View {
        if AttributionCopy.isUnattributed(kind) {
            Text(AttributionCopy.reasonText())
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }
}
