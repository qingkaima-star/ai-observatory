//
//  CommandsCopy.swift
//  AIObservatoryUI / Commands
//
//  Owner: WS-l10nb（B3 最后三页 · 命令审计）
//  ─────────────────────────────────────────────────────────
//  命令审计页全部**用户可见**文案（含 VoiceOver 读到的 `.accessibilityLabel`、`.help`
//  与 tooltip），按 IFR 裁定 3(a) 集中声明成一份 `bilingualCopy`，
//  门禁见 `CommandsBilingualCopyGateTests`。
//
//  迁移口径与 `ShellCopy`/`TimelineCopy` 完全一致（四条：只迁进眼睛/读屏的字、中文侧逐字
//  不动、多参数用 `%1$@`/`%2$d`、英文一律数量中性），这里不重复推导。语言在
//  `UILanguage.current` 一处解析。
//
//  【本页特有的两件事】
//  1. 「成功 / 失败 / 结果未知」这三个词在**四处**出现：结果分桶名、指标区 `InlineStat`
//     标签、结果分布摘要、详情里的 Tag。它们只声明一次（`succeeded`/`failed`/`unknownResult`），
//     第二处出处必然分叉——尤其「结果未知」是本页最硬的那条诚实规则的说法。
//  2. 结果分布摘要保持**原有的拼接形状**（三个标签各带一个数，中间「 · 」），
//     只把字面来源换成文案表。它被 `CommandsModelTests` 逐字断言，改结构等于改口径。
//
//  ⚠️ 英文态仍会混排的位置（不在本车道绕过，理由同 `ShellCopy` 文件头那条交回）：
//  `CommandOutcome.displayName`、`AgentKind.displayName`
//  写在 `Core/Contracts/**`（§3 冻结区），所以「执行状态」那一格与时间范围菜单在英文态
//  还是中文。本页**不**在 UI 侧另抄一份状态名。
//

import Foundation
import AIObservatoryCore

/// 命令审计页的用户可见文案表（B3）。
enum CommandsCopy {

    // MARK: 结果三态（分桶名 / 指标标签 / 摘要 / Tag 的唯一出处）

    static let succeeded = LocalizedString(zh: "成功", en: "Succeeded")
    static let failed = LocalizedString(zh: "失败", en: "Failed")
    /// 没采到退出码时的统一说法：既不是成功也不是失败（`CommandAuditFormat` 与 Tag 共用）。
    static let unknownResult = LocalizedString(zh: "结果未知", en: "Result unknown")

    // MARK: 结果过滤器（`CommandExitFilter`）

    static let filterAllResults = LocalizedString(zh: "全部结果", en: "All results")
    // 「失败」这一格的标签直接复用 `failed`（同页只有一个出处，见上面的四条口径）；
    // 这里曾有一条 `filterFailedOrTerminated`「失败或终止」——#76 把 `.terminated`
    // 移出失败格之后，那个标签描述的桶已经不存在 ⇒ 整条删掉，不留着让下一个人以为
    // 「终止」还有一格可筛（口径见 `CommandExitFilter`）。
    static let filterRunningOrUnknown = LocalizedString(zh: "运行中 / 未知", en: "Running / unknown")

    // MARK: 行内与读屏（`CommandAuditFormat.summary`）

    static let durationPrefix = LocalizedString(zh: "耗时 %@", en: "Took %@")

    // MARK: 页头与工具栏

    static let loadMore = LocalizedString(zh: "加载更多", en: "Load more")
    static let reload = LocalizedString(zh: "重新读取", en: "Reload")
    static let retry = LocalizedString(zh: "重试", en: "Retry")
    static let reset = LocalizedString(zh: "重置", en: "Reset")

    // MARK: 指标区

    static let statRunning = LocalizedString(zh: "进行中", en: "In progress")
    static let statUnloaded = LocalizedString(zh: "未加载", en: "Not loaded")
    static let statMeasuredDuration = LocalizedString(zh: "累计耗时", en: "Total measured time")
    /// 这句是**口径说明**而不是装饰：它承诺「没有 endedAt 的一条也不计入」，
    /// 英文不许缩成 "Sum of durations"。
    static let measuredDurationHelp = LocalizedString(
        zh: "只累计采到结束时间的命令；没有 endedAt 的一条也不计入，不猜时长",
        en: "Sums only commands whose end time was captured. Not one row without an endedAt is "
            + "counted — durations are never guessed."
    )
    static let tileFailedTitle = LocalizedString(zh: "失败命令", en: "Failed commands")
    /// 英文侧真机英文态在 2 行夹断里放不下 85 字符（截成 "open a r…"）⇒ 收成 64 字符，
    /// 「非 0」「只数本页已加载」「往下查详情」三件事都保住。
    static let tileFailedCaption = LocalizedString(
        zh: "退出码非 0。只数本页已加载的命令，往下查详情。",
        en: "Non-zero exit codes; only rows loaded here — open one for detail."
    )
    static let tileTotalTitle = LocalizedString(zh: "命令总数", en: "Total commands")
    /// 「结果未知」这格与 `unknownResult` 同词同义 ⇒ 不另立常量、不另立清单条目（一处出处）。
    static let tileUnknownCaption = LocalizedString(
        zh: "没采到退出码：不计成功也不计失败（已加载内）",
        en: "No exit code captured: counted as neither success nor failure (within what is loaded)."
    )
    static let tileDestructiveTitle = LocalizedString(zh: "破坏性命令", en: "Destructive commands")
    static let tileDestructiveCaption = LocalizedString(
        zh: "标记为不可逆的（只数本页已加载的）",
        en: "Flagged as irreversible (only rows loaded on this page)."
    )

    // MARK: 加载 / 空 / 错误三态

    static let loadingEarlierRows = LocalizedString(zh: "正在载入更早的命令…", en: "Loading earlier commands…")
    static let loadingAudit = LocalizedString(zh: "正在读取命令审计…", en: "Reading command audit…")
    static let emptyNoDataTitle = LocalizedString(zh: "还没有采到命令", en: "No commands captured yet")
    static let emptyNoDataMessage = LocalizedString(
        zh: "引擎识别到 AI Agent 在终端里执行的命令后才会写入审计。当前库里一条命令记录都没有。",
        en: "Commands enter the audit only once the engine recognizes an AI agent running them in a "
            + "terminal. The local store holds no command records at all right now."
    )
    static let rescanNow = LocalizedString(zh: "立即重新扫描", en: "Rescan now")
    static let emptyFilteredTitle = LocalizedString(zh: "当前筛选下没有命令", en: "No commands under the current filters")
    /// 括号里的时间范围名取自 `ObservatoryTimeRange.displayName`（冻结区，仍是中文）⇒
    /// 英文态这句会夹一个中文范围名。两个参数按位置写：英文把范围名挪到后面也不串位。
    static let emptyFilteredMessage = LocalizedString(
        zh: "已启用 %1$d 项过滤条件（时间范围「%2$@」），放宽它们就能看到历史命令。",
        en: "Active filters: %1$d (time range “%2$@”). Loosen them to see earlier commands."
    )
    static let resetFilters = LocalizedString(zh: "重置过滤器", en: "Reset filters")
    static let emptyRangeTitle = LocalizedString(zh: "「%@」没有命令记录", en: "No command records in “%@”")
    /// 英文侧不写 "Switch to All"：那个标签在英文态仍然是中文（见文件头 ⚠️），
    /// 承诺一个界面此刻不存在的英文词就是把话说错了。
    static let emptyRangeMessage = LocalizedString(
        zh: "这段时间内没有采到命令，而且当前也没有启用其他筛选条件。可以切到「全部」查看更早的命令。",
        en: "No commands were captured during this period, and no other filters are active. "
            + "Widen the time range to see earlier commands."
    )
    static let viewAllTime = LocalizedString(zh: "查看全部时间", en: "View all time")
    static let readFailedTitle = LocalizedString(zh: "命令审计读取失败", en: "Failed to read command audit")
    static let staleReadTag = LocalizedString(zh: "本轮读取未完成", en: "This read did not complete")

    // MARK: 列表行

    static let rowDurationHelp = LocalizedString(zh: "耗时；没有结束时间就是「—」",
                                                 en: "Duration; “—” when no end time was captured")
    static let tagDestructive = LocalizedString(zh: "破坏性", en: "Destructive")
    static let tagRequiresConfirmation = LocalizedString(zh: "需确认", en: "Needs confirmation")
    /// 两条标记都不成立时才落这一枚：它是「没有要处理的」这个结论的说法，不是装饰。
    static let tagRoutine = LocalizedString(zh: "常规命令", en: "Routine command")

    // MARK: 详情面板

    static let detailUnselectedTitle = LocalizedString(zh: "没有选中命令", en: "No command selected")
    static let detailUnselectedMessage = LocalizedString(
        zh: "在左侧列表里选一条命令，这里会给出它的退出结果、耗时与执行上下文。",
        en: "Select a command in the list on the left to see its exit result, duration and execution context."
    )
    static let detailHeader = LocalizedString(zh: "命令详情", en: "Command details")
    static let commandLineSection = LocalizedString(zh: "命令行", en: "Command line")
    /// 中文是「N 个参数」，英文写成名词前置的 "Arguments: N"——"%d arguments" 在 1 时就是
    /// "1 arguments"（复数没有机制，见 `ShellCopy` 文件头那条）。
    static let argumentCount = LocalizedString(zh: "%d 个参数", en: "Arguments: %d")
    static let factsSection = LocalizedString(zh: "审计要素", en: "Audit facts")
    static let factsSubtitle = LocalizedString(zh: "命令 · 退出结果 · 耗时",
                                               en: "Command · exit result · duration")
    static let fieldExitResult = LocalizedString(zh: "退出结果", en: "Exit result")
    static let fieldExecutionState = LocalizedString(zh: "执行状态", en: "Execution state")
    static let fieldDuration = LocalizedString(zh: "耗时", en: "Duration")
    static let fieldStartedAt = LocalizedString(zh: "开始时间", en: "Start time")
    static let fieldEndedAt = LocalizedString(zh: "结束时间", en: "End time")
    /// 两条诚实说明原文保留（本页最硬的一条：不把成败猜成任何一侧）。
    static let noExitCodeNote = LocalizedString(
        zh: "没有采到退出码：结果未知，界面不把成败猜成任何一侧。",
        en: "No exit code was captured: the outcome is unknown, and the interface does not guess "
            + "either side of success or failure."
    )
    static let tagNonZeroExit = LocalizedString(zh: "退出码非 0", en: "Exit code is non-zero")
    static let nonZeroExitNote = LocalizedString(zh: "这条命令没有正常结束。",
                                                  en: "This command did not finish normally.")
    static let contextSection = LocalizedString(zh: "执行上下文", en: "Execution context")
    static let fieldWorkingDirectory = LocalizedString(zh: "工作目录", en: "Working directory")
    static let fieldProject = LocalizedString(zh: "所属项目", en: "Project")
    static let fieldSession = LocalizedString(zh: "所属会话", en: "Session")
    static let focusSession = LocalizedString(zh: "只看这个会话的命令", en: "Show only this session's commands")
    static let focusSessionHelp = LocalizedString(zh: "把命令列表收窄到会话 %@",
                                                   en: "Narrow the command list to session %@")
    /// #81：这一条命令的对外取证出口（→ 时间线，带上这一条会话）。
    static let jumpToTimeline = LocalizedString(zh: "在时间线看这一条会话",
                                                en: "See this session in timeline")
    static let sessionUnlinked = LocalizedString(zh: "未关联会话（采集时未归属）",
                                                 en: "No linked session (unattributed at capture time)")
    static let resolving = LocalizedString(zh: "正在读取…", en: "Reading…")
    static let unnamedSession = LocalizedString(zh: "未命名会话", en: "Untitled session")

    // MARK: 过滤条

    static let a11yTimeRange = LocalizedString(zh: "时间范围", en: "Time range")
    static let allAgents = LocalizedString(zh: "全部 Agent", en: "All agents")
    static let a11yAgentKind = LocalizedString(zh: "Agent 类型", en: "Agent type")
    static let destructiveOnlyToggle = LocalizedString(zh: "只看危险命令", en: "Show only destructive commands")
    static let sortNewestFirst = LocalizedString(zh: "最新在前", en: "Newest first")
    static let sortOldestFirst = LocalizedString(zh: "最早在前", en: "Oldest first")
    static let a11ySortDirection = LocalizedString(zh: "排序方向", en: "Sort direction")
    static let searchPrompt = LocalizedString(zh: "搜索命令行，例如 git push / rm -rf…",
                                              en: "Search command lines, e.g. git push / rm -rf…")
    static let a11yClearSearch = LocalizedString(zh: "清空搜索", en: "Clear search")
    static let sessionChipHelp = LocalizedString(zh: "当前只看这一条会话的命令，点击取消",
                                                 en: "Only this session's commands are shown. Press to clear.")
    static let a11yClearSessionFilter = LocalizedString(zh: "取消会话过滤", en: "Clear session filter")
    /// 「N 个 Agent」英文写成 "Agents: N"（同上，躲开 "1 Agents"）。
    static let agentKindCount = LocalizedString(zh: "%d 个 Agent", en: "Agents: %d")

    // MARK: 模型读数（`CommandsModel`）

    /// 分子是本页已加载、分母是服务端总数（不同口径），所以英文不许缩成一个含糊的 "n/N"。
    static let progressText = LocalizedString(zh: "共 %1$d 条命令 · 已加载 %2$d",
                                              en: "Commands: %1$d · loaded %2$d")

    // MARK: outcome 组文案（3 条，key 前缀 outcome.*）
    static let outcomeCopy: [NamedCopy] = [
        NamedCopy("commands.outcome.succeeded", succeeded),
        NamedCopy("commands.outcome.failed", failed),
        NamedCopy("commands.outcome.unknownResult", unknownResult),
    ]

    // MARK: filter 组文案（2 条，key 前缀 filter.*）
    static let filterCopy: [NamedCopy] = [
        NamedCopy("commands.filter.allResults", filterAllResults),
        NamedCopy("commands.filter.runningOrUnknown", filterRunningOrUnknown),
    ]

    // MARK: row 组文案（1 条，key 前缀 row.*）
    static let rowCopy: [NamedCopy] = [
        NamedCopy("commands.row.durationPrefix", durationPrefix),
    ]

    // MARK: toolbar 组文案（4 条，key 前缀 toolbar.*）
    static let toolbarCopy: [NamedCopy] = [
        NamedCopy("commands.toolbar.loadMore", loadMore),
        NamedCopy("commands.toolbar.reload", reload),
        NamedCopy("commands.toolbar.retry", retry),
        NamedCopy("commands.toolbar.reset", reset),
    ]

    // MARK: metric 组文案（4 条，key 前缀 metric.*）
    static let metricCopy: [NamedCopy] = [
        NamedCopy("commands.metric.running", statRunning),
        NamedCopy("commands.metric.unloaded", statUnloaded),
        NamedCopy("commands.metric.measuredDuration", statMeasuredDuration),
        NamedCopy("commands.metric.measuredDurationHelp", measuredDurationHelp),
    ]

    // MARK: tile 组文案（6 条，key 前缀 tile.*）
    static let tileCopy: [NamedCopy] = [
        NamedCopy("commands.tile.failedTitle", tileFailedTitle),
        NamedCopy("commands.tile.failedCaption", tileFailedCaption),
        NamedCopy("commands.tile.totalTitle", tileTotalTitle),
        NamedCopy("commands.tile.unknownCaption", tileUnknownCaption),
        NamedCopy("commands.tile.destructiveTitle", tileDestructiveTitle),
        NamedCopy("commands.tile.destructiveCaption", tileDestructiveCaption),
    ]

    // MARK: state 组文案（2 条，key 前缀 state.*）
    static let stateCopy: [NamedCopy] = [
        NamedCopy("commands.state.loadingEarlierRows", loadingEarlierRows),
        NamedCopy("commands.state.loadingAudit", loadingAudit),
    ]

    // MARK: empty 组文案（9 条，key 前缀 empty.*）
    static let emptyCopy: [NamedCopy] = [
        NamedCopy("commands.empty.noDataTitle", emptyNoDataTitle),
        NamedCopy("commands.empty.noDataMessage", emptyNoDataMessage),
        NamedCopy("commands.empty.rescanNow", rescanNow),
        NamedCopy("commands.empty.filteredTitle", emptyFilteredTitle),
        NamedCopy("commands.empty.filteredMessage", emptyFilteredMessage),
        NamedCopy("commands.empty.resetFilters", resetFilters),
        NamedCopy("commands.empty.rangeTitle", emptyRangeTitle),
        NamedCopy("commands.empty.rangeMessage", emptyRangeMessage),
        NamedCopy("commands.empty.viewAllTime", viewAllTime),
    ]

    // MARK: error 组文案（2 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        NamedCopy("commands.error.readFailedTitle", readFailedTitle),
        NamedCopy("commands.error.staleReadTag", staleReadTag),
    ]

    // MARK: row2 组文案（4 条，key 前缀 row.*）
    static let row2Copy: [NamedCopy] = [
        NamedCopy("commands.row.durationHelp", rowDurationHelp),
        NamedCopy("commands.row.destructiveTag", tagDestructive),
        NamedCopy("commands.row.requiresConfirmationTag", tagRequiresConfirmation),
        NamedCopy("commands.row.routineTag", tagRoutine),
    ]

    // MARK: detail 组文案（25 条，key 前缀 detail.*）
    static let detailCopy: [NamedCopy] = [
        NamedCopy("commands.detail.unselectedTitle", detailUnselectedTitle),
        NamedCopy("commands.detail.unselectedMessage", detailUnselectedMessage),
        NamedCopy("commands.detail.header", detailHeader),
        NamedCopy("commands.detail.commandLineSection", commandLineSection),
        NamedCopy("commands.detail.argumentCount", argumentCount),
        NamedCopy("commands.detail.factsSection", factsSection),
        NamedCopy("commands.detail.factsSubtitle", factsSubtitle),
        NamedCopy("commands.detail.fieldExitResult", fieldExitResult),
        NamedCopy("commands.detail.fieldExecutionState", fieldExecutionState),
        NamedCopy("commands.detail.fieldDuration", fieldDuration),
        NamedCopy("commands.detail.fieldStartedAt", fieldStartedAt),
        NamedCopy("commands.detail.fieldEndedAt", fieldEndedAt),
        NamedCopy("commands.detail.noExitCodeNote", noExitCodeNote),
        NamedCopy("commands.detail.tagNonZeroExit", tagNonZeroExit),
        NamedCopy("commands.detail.nonZeroExitNote", nonZeroExitNote),
        NamedCopy("commands.detail.contextSection", contextSection),
        NamedCopy("commands.detail.fieldWorkingDirectory", fieldWorkingDirectory),
        NamedCopy("commands.detail.fieldProject", fieldProject),
        NamedCopy("commands.detail.fieldSession", fieldSession),
        NamedCopy("commands.detail.focusSession", focusSession),
        NamedCopy("commands.detail.focusSessionHelp", focusSessionHelp),
        NamedCopy("commands.detail.jumpToTimeline", jumpToTimeline),
        NamedCopy("commands.detail.sessionUnlinked", sessionUnlinked),
        NamedCopy("commands.detail.resolving", resolving),
        NamedCopy("commands.detail.unnamedSession", unnamedSession),
    ]

    // MARK: filterBar 组文案（12 条，key 前缀 filterBar.*）
    static let filterBarCopy: [NamedCopy] = [
        NamedCopy("commands.filterBar.a11yTimeRange", a11yTimeRange),
        NamedCopy("commands.filterBar.allAgents", allAgents),
        NamedCopy("commands.filterBar.a11yAgentKind", a11yAgentKind),
        NamedCopy("commands.filterBar.destructiveOnly", destructiveOnlyToggle),
        NamedCopy("commands.filterBar.newestFirst", sortNewestFirst),
        NamedCopy("commands.filterBar.oldestFirst", sortOldestFirst),
        NamedCopy("commands.filterBar.a11ySortDirection", a11ySortDirection),
        NamedCopy("commands.filterBar.searchPrompt", searchPrompt),
        NamedCopy("commands.filterBar.a11yClearSearch", a11yClearSearch),
        NamedCopy("commands.filterBar.sessionChipHelp", sessionChipHelp),
        NamedCopy("commands.filterBar.a11yClearSessionFilter", a11yClearSessionFilter),
        NamedCopy("commands.filterBar.agentKindCount", agentKindCount),
    ]

    // MARK: model 组文案（1 条，key 前缀 model.*）
    static let modelCopy: [NamedCopy] = [
        NamedCopy("commands.model.progressText", progressText),
    ]

    /// 本目录全部用户可见文案。**门禁用例遍历它断言 `copyProblems` 为空**。
    static let bilingualCopy: [NamedCopy] =
        outcomeCopy
        + filterCopy
        + rowCopy
        + toolbarCopy
        + metricCopy
        + tileCopy
        + stateCopy
        + emptyCopy
        + errorCopy
        + row2Copy
        + detailCopy
        + filterBarCopy
        + modelCopy

}
