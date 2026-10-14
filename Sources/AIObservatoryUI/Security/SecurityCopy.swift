//
//  SecurityCopy.swift
//  AIObservatoryUI / Security
//
//  Owner: WS-UI（uicopy · #49）
//  ─────────────────────────────────────────────────────────
//  风险板块里「这条为什么被判定成这个等级」那一段的**唯一措辞出处**。
//
//  要治的病：同一件东西在两个面板叫两个名字——
//  · 详情面板那一节标题叫「判定依据」，而**确认面板**叫「事件详情」；
//  · 规则号在详情面板写「命中规则」，在确认面板写「规则」；
//  · 空态那句「规则未提供额外说明。」在两个文件里各打了一份字面量。
//  确认面板是用户在**按下「我已确认」之前**最后读的那一屏（需求⑧「危险操作要确认」），
//  它和详情面板说的是同一件事却换一套词，用户就会怀疑自己看的是另一块信息。
//  三处收成一个常量之后，B3 双语迁移也只需要翻一条。
//

import Foundation
import AIObservatoryCore

/// 风险页（`Security/**`）的措辞表，**一个目录一张表**（B3 形状）。
/// 只服务本目录的面板；跨板块要复用时先确认说的是同一件事，别把不相干的句子塞进来。
///
/// 本表由 uicopy 在 #49 建（当时是三个 `String` 常量，注释里写着
/// "B3 双语迁移也只需要翻一条"），`ws/l10n` 在 B3 里把它接成 `LocalizedString` 并扩到确认卡。
enum SecurityCopy {

    /// 那一节的标题。详情面板与确认面板**共用**。
    static let rationaleTitle = LocalizedString(zh: "判定依据", en: "Why this was flagged")

    /// 规则号那一格的标签。两处共用（原来一处写「命中规则」、一处写「规则」）。
    static let matchedRuleTitle = LocalizedString(zh: "命中规则", en: "Matched rule")

    /// 规则没给出任何依据句时的如实空态——不留白，也不替规则编一句理由。
    static let missingRationale = LocalizedString(zh: "规则未提供额外说明。",
                                                       en: "The rule provided no further explanation.")

    /// 依据正文：`RiskEvent.detail`（由规则侧 `rationale(filling:)` 渲染出来的整句）。
    static func rationale(_ detail: String) -> String {
        detail.isAllBlank ? missingRationale.text() : detail
    }
    // MARK: - 确认卡（用户按下「我已确认」之前最后读的那一屏）

    /// 未列出的路径数。中文有量词「个路径」，英文**不补**："and 1 more" 数量中性，
    /// 写成 "1 more paths" 就是复数硬伤（B3 实测：复数没有机制，只能靠写法）。
    static let morePaths = LocalizedString(zh: "另有 %1$@ 个路径", en: "and %1$@ more")
    static let timeLabel = LocalizedString(zh: "时间", en: "Time")
    /// 这句是确认面板的关键承诺，英文必须同样说清"只标记、不删数据"，
    /// 不能缩成 "This will be marked as handled"（丢掉了"不删采集记录"那一半）。
    static let acknowledgeNote = LocalizedString(
        zh: "确认后该事件在本地标记为已处置，不会删除任何采集记录。",
        en: "Acknowledging marks this event as handled on this Mac. It does not delete any collected record."
    )
    /// 中文用第一人称「我已确认」是刻意的确认摩擦；英文按 macOS 安全对话框的惯用按钮词，
    /// 不用 "I have acknowledged"（英文按钮写整句第一人称反而不像系统）。
    static let acknowledgeButton = LocalizedString(zh: "我已确认", en: "Acknowledge")
    static let laterButton = LocalizedString(zh: "稍后处理", en: "Handle Later")
    static let ignoreKindButton = LocalizedString(zh: "忽略此类提醒", en: "Ignore This Kind of Alert")

    // MARK: - 以下 #56 后续（总控 07:5x 裁定 (c)）：Security 余下 63 行硬中文
    // 建表时（#49 / B3）只迁了「判定依据」那一段与确认卡，本页其余面板一直是裸中文字面量，
    // 而 `SecurityBilingualCopyGateTests` 没有「目录内不许写死中文」那道 ⇒ 全绿着没人发现。
    // 逐条口径写在该条上方；`morePaths` / `laterButton` / `timeLabel` 是既有项，直接复用不另立。

    // 行尾标记与读屏
    static let awaitingHelp = LocalizedString(zh: "等待人工确认", en: "Awaiting manual confirmation")
    /// 行尾文字标记与指标区那一格同词 ⇒ 一个出处（第二个出处必分叉）。
    static let acknowledged = LocalizedString(zh: "已确认", en: "Acknowledged")
    /// 读屏拼句的尾巴：中文「，已确认」，英文半角逗号 + 过去分词。
    static let ackSuffix = LocalizedString(zh: "，已确认", en: ", acknowledged")

    // 详情面板
    static let triggeredCommand = LocalizedString(zh: "触发命令", en: "Triggering command")
    static let involvedPaths = LocalizedString(zh: "涉及路径", en: "Paths involved")
    static let sensitivePathTitle = LocalizedString(zh: "敏感路径", en: "Sensitive path")
    /// 「另有 N 个路径未列出」：英文写成 "%1$d more not listed"，数量中性（"1 paths" 是硬伤）。
    static let morePathsUnlisted = LocalizedString(zh: "另有 %1$d 个路径未列出",
                                                   en: "%1$d more not listed")
    /// 量词「项」单独挂在数字后面：中文留、英文空（理由见 `TimelineCopy.measureWord`）。
    static func countedItems(_ value: Int, _ language: AppLanguage) -> String {
        language == .chineseSimplified ? "\(value) 项" : "\(value)"
    }
    static let attributionTitle = LocalizedString(zh: "归属", en: "Attribution")
    static let statusTitle = LocalizedString(zh: "状态", en: "Status")
    static let statusPending = LocalizedString(zh: "待处理", en: "Awaiting review")
    static let fileCountTitle = LocalizedString(zh: "文件数", en: "File count")
    static let sessionTitle = LocalizedString(zh: "会话", en: "Session")
    static let sessionUnattributed = LocalizedString(zh: "未归属", en: "Not attributed")
    static let sessionAttributed = LocalizedString(zh: "已归属", en: "Attributed")
    static let markAcknowledged = LocalizedString(zh: "标记已确认", en: "Mark acknowledged")
    static let alreadyAcknowledged = LocalizedString(zh: "该事件已确认",
                                                     en: "This event is already acknowledged")
    static let viewInTimeline = LocalizedString(zh: "在时间线中查看", en: "View in the timeline")

    // 状态条与过滤条
    static let loadSummary = LocalizedString(
        zh: "共 %1$d 条 · 已加载 %2$d · 已确认 %3$d",
        en: "Total %1$d · loaded %2$d · acknowledged %3$d"
    )
    static let filterTitle = LocalizedString(zh: "过滤", en: "Filter")
    static let filterSubtitle = LocalizedString(zh: "条件变化即重新查询", en: "Every change re-queries")
    static let reset = LocalizedString(zh: "重置", en: "Reset")
    static let unacknowledgedOnly = LocalizedString(zh: "只看未确认", en: "Unacknowledged only")
    static let levelTitle = LocalizedString(zh: "等级", en: "Level")
    static let hitOfTotal = LocalizedString(zh: "命中 %1$d / 共 %2$d", en: "Matched %1$d of %2$d")
    static let searchPrompt = LocalizedString(zh: "搜索标题 / 详情 / 命令",
                                              en: "Search titles / details / commands")
    static let clearCategories = LocalizedString(zh: "清空类别", en: "Clear categories")
    static let categoriesTitle = LocalizedString(zh: "类别", en: "Categories")
    static let categoriesCount = LocalizedString(zh: "类别 · %d", en: "Categories · %d")
    static let levelCountA11y = LocalizedString(zh: "等级 %1$@，%2$d 条",
                                                en: "Level %1$@ — %2$d in total")
    static let ackSaveFailed = LocalizedString(zh: "确认没有保存：%@",
                                               en: "Confirmation was not saved: %@")

    // 指标区五格（标题 + 口径句成对；口径句里的数字全部名词前置）
    static let pendingHighHero = LocalizedString(zh: "高危待处置 %d", en: "High risk awaiting action: %d")
    static let tilePendingHigh = LocalizedString(zh: "高危待处置", en: "High risk awaiting action")
    /// 这句把「只按已加载判等级」写死在界面上：不写就会有人拿全库命中数当真结论。
    static let tilePendingHighCaption = LocalizedString(
        zh: "等级 ≥ 高 且未确认 · 按已加载的 %1$d 条统计（全库命中 %2$d 条，未加载部分不逐条判等级）",
        en: "Level ≥ high and unacknowledged · judged over the %1$d rows loaded here "
            + "(the store holds %2$d in total; unloaded rows are not judged one by one)"
    )
    static let tileAllPending = LocalizedString(zh: "全部待确认", en: "All awaiting confirmation")
    static let tileAllPendingCaption = LocalizedString(zh: "含各等级，未过滤", en: "All levels, unfiltered")
    static let tileToday = LocalizedString(zh: "今日风险", en: "Today's risks")
    static let tileTodayCaption = LocalizedString(zh: "独立小查询，不受当前过滤影响",
                                                  en: "A separate query, unaffected by the current filters")
    static let tileSensitive = LocalizedString(zh: "敏感路径命中", en: "Sensitive path hits")
    static let tileSensitiveCaption = LocalizedString(zh: "事件涉及受保护目录",
                                                      en: "Events touching protected directories")
    static let tileAcknowledgedCaption = LocalizedString(zh: "本机标记为已处置",
                                                         en: "Marked handled on this Mac")

    // 列表与三态
    static let listTitle = LocalizedString(zh: "风险事件", en: "Risk events")
    static let listSubtitle = LocalizedString(zh: "按时间倒序 · 点一行看详情",
                                              en: "Newest first · select a row for detail")
    static let loadingRow = LocalizedString(zh: "加载中…", en: "Loading…")
    static let loadMoreCount = LocalizedString(zh: "加载更多（共 %d 条）", en: "Load more (%d total)")
    static let markAllAcknowledged = LocalizedString(zh: "全部标记已确认", en: "Mark all acknowledged")
    static let clearFilters = LocalizedString(zh: "清除过滤", en: "Clear filters")
    static let reviewConfirmation = LocalizedString(zh: "重新查看确认卡…", en: "Review the confirmation card…")
    static let selectEventTitle = LocalizedString(zh: "选择一条风险事件", en: "Select a risk event")
    static let selectEventMessage = LocalizedString(
        zh: "左侧列表选中后，这里显示判定依据、触发命令与涉及路径。",
        en: "Once you pick a row on the left, this shows why it was flagged, the triggering command "
            + "and the paths involved."
    )
    static let readingEvents = LocalizedString(zh: "正在读取风险事件…", en: "Reading risk events…")
    static let readFailedTitle = LocalizedString(zh: "无法读取风险事件", en: "Can't read risk events")
    /// #77：列表**非空**、但最近一次读取失败时挂在行之上的那一句标题。
    /// 不能复用 `readFailedTitle`「无法读取风险事件」：那一格接管的是整页空态，
    /// 而这里行还在下面滚 —— 只说「无法读取」会把「屏幕上这些是什么」漏掉，
    /// 用户会以为列表空了。说法与 `SessionsCopy.errorStale` 一致（两页同一个意思同一句话）。
    /// 确认落库失败**不**走这一条：那一句由 `ackSaveFailed` 原样上屏，不设第二个出处。
    static let errorStaleBelowTitle = LocalizedString(
        zh: "最近一次读取失败，下面显示的是上一次成功加载的结果",
        en: "The last read failed; what is shown below is the previous successful load"
    )
    static let retry = LocalizedString(zh: "重试", en: "Retry")
    static let emptyFilteredTitle = LocalizedString(zh: "当前过滤条件下没有风险",
                                                    en: "No risks under the current filters")
    static let emptyFilteredMessage = LocalizedString(zh: "试着放宽时间范围或清除过滤条件。",
                                                      en: "Try widening the time range or clearing the filters.")
    static let emptyNoRiskTitle = LocalizedString(zh: "尚未发现风险事件", en: "No risk events found yet")
    static let emptyNoRiskMessage = LocalizedString(
        zh: "观测引擎会在 Agent 执行删除、提权、敏感路径写入等行为时实时告警。",
        en: "The engine raises events live when an agent deletes, escalates privileges, "
            + "or writes to sensitive paths."
    )
    static let rescanNow = LocalizedString(zh: "立即重新扫描", en: "Rescan now")

    // MARK: rationale 组文案（3 条，key 前缀 rationale.*）
    static let rationaleCopy: [NamedCopy] = [
        NamedCopy("security.rationale.title", rationaleTitle),
        NamedCopy("security.rationale.matchedRule", matchedRuleTitle),
        NamedCopy("security.rationale.missing", missingRationale),
    ]

    // MARK: confirm 组文案（6 条，key 前缀 confirm.*）
    static let confirmCopy: [NamedCopy] = [
        NamedCopy("security.confirm.morePaths", morePaths),
        NamedCopy("security.confirm.time", timeLabel),
        NamedCopy("security.confirm.acknowledgeNote", acknowledgeNote),
        NamedCopy("security.confirm.acknowledgeButton", acknowledgeButton),
        NamedCopy("security.confirm.laterButton", laterButton),
        NamedCopy("security.confirm.ignoreKindButton", ignoreKindButton),
    ]

    // MARK: row 组文案（3 条，key 前缀 row.*）
    static let rowCopy: [NamedCopy] = [
        NamedCopy("security.row.awaitingHelp", awaitingHelp),
        NamedCopy("security.row.acknowledged", acknowledged),
        NamedCopy("security.row.ackSuffix", ackSuffix),
    ]

    // MARK: detail 组文案（14 条，key 前缀 detail.*）
    static let detailCopy: [NamedCopy] = [
        NamedCopy("security.detail.triggeredCommand", triggeredCommand),
        NamedCopy("security.detail.involvedPaths", involvedPaths),
        NamedCopy("security.detail.sensitivePath", sensitivePathTitle),
        NamedCopy("security.detail.attribution", attributionTitle),
        NamedCopy("security.detail.morePathsUnlisted", morePathsUnlisted),
        NamedCopy("security.detail.status", statusTitle),
        NamedCopy("security.detail.statusPending", statusPending),
        NamedCopy("security.detail.fileCount", fileCountTitle),
        NamedCopy("security.detail.session", sessionTitle),
        NamedCopy("security.detail.sessionUnattributed", sessionUnattributed),
        NamedCopy("security.detail.sessionAttributed", sessionAttributed),
        NamedCopy("security.detail.markAcknowledged", markAcknowledged),
        NamedCopy("security.detail.alreadyAcknowledged", alreadyAcknowledged),
        NamedCopy("security.detail.viewInTimeline", viewInTimeline),
    ]

    // MARK: bar 组文案（12 条，key 前缀 bar.*）
    static let barCopy: [NamedCopy] = [
        NamedCopy("security.bar.loadSummary", loadSummary),
        NamedCopy("security.bar.filterTitle", filterTitle),
        NamedCopy("security.bar.filterSubtitle", filterSubtitle),
        NamedCopy("security.bar.reset", reset),
        NamedCopy("security.bar.unacknowledgedOnly", unacknowledgedOnly),
        NamedCopy("security.bar.level", levelTitle),
        NamedCopy("security.bar.hitOfTotal", hitOfTotal),
        NamedCopy("security.bar.searchPrompt", searchPrompt),
        NamedCopy("security.bar.clearCategories", clearCategories),
        NamedCopy("security.bar.categories", categoriesTitle),
        NamedCopy("security.bar.categoriesCount", categoriesCount),
        NamedCopy("security.bar.levelCountA11y", levelCountA11y),
    ]

    // MARK: model 组文案（1 条，key 前缀 model.*）
    static let modelCopy: [NamedCopy] = [
        NamedCopy("security.model.ackSaveFailed", ackSaveFailed),
    ]

    // MARK: metric 组文案（10 条，key 前缀 metric.*）
    static let metricCopy: [NamedCopy] = [
        NamedCopy("security.metric.pendingHighHero", pendingHighHero),
        NamedCopy("security.metric.pendingHigh", tilePendingHigh),
        NamedCopy("security.metric.pendingHighCaption", tilePendingHighCaption),
        NamedCopy("security.metric.allPending", tileAllPending),
        NamedCopy("security.metric.allPendingCaption", tileAllPendingCaption),
        NamedCopy("security.metric.today", tileToday),
        NamedCopy("security.metric.todayCaption", tileTodayCaption),
        NamedCopy("security.metric.sensitive", tileSensitive),
        NamedCopy("security.metric.sensitiveCaption", tileSensitiveCaption),
        NamedCopy("security.metric.acknowledgedCaption", tileAcknowledgedCaption),
    ]

    // MARK: list 组文案（7 条，key 前缀 list.*）
    static let listCopy: [NamedCopy] = [
        NamedCopy("security.list.title", listTitle),
        NamedCopy("security.list.subtitle", listSubtitle),
        NamedCopy("security.list.loadingRow", loadingRow),
        NamedCopy("security.list.loadMoreCount", loadMoreCount),
        NamedCopy("security.list.markAll", markAllAcknowledged),
        NamedCopy("security.list.clearFilters", clearFilters),
        NamedCopy("security.list.reviewConfirmation", reviewConfirmation),
    ]

    // MARK: empty 组文案（2 条，key 前缀 empty.*）
    static let emptyCopy: [NamedCopy] = [
        NamedCopy("security.empty.selectTitle", selectEventTitle),
        NamedCopy("security.empty.selectMessage", selectEventMessage),
    ]

    // MARK: state 组文案（1 条，key 前缀 state.*）
    static let stateCopy: [NamedCopy] = [
        NamedCopy("security.state.readingEvents", readingEvents),
    ]

    // MARK: error 组文案（3 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        NamedCopy("security.error.readFailedTitle", readFailedTitle),
        NamedCopy("security.error.staleBelowTitle", errorStaleBelowTitle),
        NamedCopy("security.error.retry", retry),
    ]

    // MARK: empty2 组文案（5 条，key 前缀 empty.*）
    static let empty2Copy: [NamedCopy] = [
        NamedCopy("security.empty.filteredTitle", emptyFilteredTitle),
        NamedCopy("security.empty.filteredMessage", emptyFilteredMessage),
        NamedCopy("security.empty.noRiskTitle", emptyNoRiskTitle),
        NamedCopy("security.empty.noRiskMessage", emptyNoRiskMessage),
        NamedCopy("security.empty.rescanNow", rescanNow),
    ]

    /// 本目录全部用户可见文案。条数由门禁用例量，不靠手数。
    static let bilingualCopy: [NamedCopy] =
        rationaleCopy
        + confirmCopy
        + rowCopy
        + detailCopy
        + barCopy
        + modelCopy
        + metricCopy
        + listCopy
        + emptyCopy
        + stateCopy
        + errorCopy
        + empty2Copy

}
