//
//  SessionsCopy.swift
//  AIObservatoryUI / Sessions
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  会话页（列表 / 详情 / 过滤条 / 命令子列表 / 结果读数）全部用户可见文案。
//  口径三条同 `ShellCopy` 文件头，不重复。
//
//  【形状与 Shell/Timeline 有一处不同，故意的】这里每条**直接声明成 `NamedCopy`**
//  （名字写在常量那一行），而不是"先 LocalizedString、再在清单里列一遍名字"：
//  会话页有 110 条，两份清单会把这一页的 diff 撑成两倍，而名字与常量的对应关系
//  在单份写法里是**结构性的**（不可能表和常量对不上）。
//  要统一成 Shell/Timeline 那种两份式，是一次纯机械改动，交给总控定（见交付块）。
//
//  取文案：无参数用 `.text(language)`；带参数用 `.copy.format(language, …)`
//  （`NamedCopy` 上没有 format，走它转发的 `LocalizedString`）。
//
//  ⚠️ 这一页大量读数挂在 `session.outcome.displayName` / `riskLevel.displayName` /
//  `kind.displayName` 上，它们写在 `AIObservatoryCore/Contracts/**`（§3），仍是中文
//  ——同 `ShellCopy` 文件头那条交回，英文态会混排，本车道不在 UI 侧另抄一份。
//

import Foundation
import AIObservatoryCore

/// 会话页的用户可见文案表。
enum SessionsCopy {

    // MARK: 量词（英文没有对应物，理由见 `TimelineCopy.measureWord`）

    static func measureWord(_ chinese: String, _ language: AppLanguage) -> String {
        language == .chineseSimplified ? chinese : ""
    }

    static func unitItems(_ language: AppLanguage) -> String { measureWord("条", language) }
    static func unitLocations(_ language: AppLanguage) -> String { measureWord("处", language) }
    static func unitSessions(_ language: AppLanguage) -> String { measureWord("个", language) }

    // MARK: 命令结果读数（`CommandResultReadout`）

    static let resultSomeFailed = NamedCopy("sessions.result.someFailed", LocalizedString(
        zh: "%1$d 条失败，建议复核退出码", en: "%1$d failed — worth re-checking the exit codes"))
    static let resultNoCommands = NamedCopy("sessions.result.noCommands",
                                            LocalizedString(zh: "无命令记录", en: "No command records"))
    static let resultPartiallyLoaded = NamedCopy("sessions.result.partiallyLoaded", LocalizedString(
        zh: "结果未知 · 仅加载 %1$d/%2$d 条", en: "Outcome unknown · only %1$d of %2$d loaded"))
    static let resultNothingResolved = NamedCopy("sessions.result.nothingResolved", LocalizedString(
        zh: "结果未知 · 未采到退出码", en: "Outcome unknown · no exit codes"))
    static let resultPartiallyResolved = NamedCopy("sessions.result.partiallyResolved", LocalizedString(
        zh: "部分结果未知 · %1$d/%2$d 条有退出码", en: "Some outcomes unknown · %1$d of %2$d with an exit code"))
    static let resultAllPassed = NamedCopy("sessions.result.allPassed",
                                           LocalizedString(zh: "全部通过", en: "All passed"))

    // MARK: 命令子列表（`SessionCommandList`）

    static let commandsTitle = NamedCopy("sessions.commands.title",
                                         LocalizedString(zh: "命令记录", en: "Command log"))
    static let commandsDangerousOnly = NamedCopy("sessions.commands.dangerousOnly",
                                                 LocalizedString(zh: "只看危险命令", en: "Dangerous commands only"))
    static let commandsDangerousOnlyHelp = NamedCopy("sessions.commands.dangerousOnlyHelp", LocalizedString(
        zh: "只列出命中破坏性判定的命令；判定来自风险规则，不是本地猜测",
        en: "Lists only commands that matched a destructive verdict — it comes from the risk rules, not a local guess"))
    static let commandsLoading = NamedCopy("sessions.commands.loading",
                                           LocalizedString(zh: "正在读取…", en: "Reading…"))
    static let commandsNoneCaptured = NamedCopy("sessions.commands.noneCaptured", LocalizedString(
        zh: "本次会话没有捕获到命令", en: "No commands were captured for this session"))
    static let commandsProgress = NamedCopy("sessions.commands.progress", LocalizedString(
        zh: "已加载 %1$d 条 · 失败 %2$d · 危险 %3$d",
        en: "%1$d loaded · %2$d failed · %3$d destructive"))
    static let commandsReading = NamedCopy("sessions.commands.reading",
                                           LocalizedString(zh: "正在读取命令记录…", en: "Reading the command log…"))
    static let commandsNoDangerous = NamedCopy("sessions.commands.noDangerous", LocalizedString(
        zh: "本次会话没有危险命令", en: "No dangerous commands in this session"))
    static let commandsNoExecutions = NamedCopy("sessions.commands.noExecutions", LocalizedString(
        zh: "本次会话没有捕获到命令执行", en: "No command executions were captured for this session"))
    static let commandsDangerousFilteredAll = NamedCopy("sessions.commands.dangerousFilteredAll", LocalizedString(
        zh: "「只看危险命令」筛掉了全部 %1$d 条已加载命令。破坏性判定来自风险规则。",
        en: "“Dangerous commands only” filtered out all %1$d loaded commands. The destructive verdict comes from the risk rules."))
    static let commandsPollingNote = NamedCopy("sessions.commands.pollingNote", LocalizedString(
        zh: "命令审计靠轮询进程快照，短于一档采样间隔的命令可能采不到。",
        en: "Command auditing polls process snapshots, so a command shorter than one sampling interval may be missed."))
    static let commandsShowAll = NamedCopy("sessions.commands.showAll",
                                           LocalizedString(zh: "查看全部命令", en: "Show all commands"))
    static let commandsTook = NamedCopy("sessions.commands.took", LocalizedString(zh: "耗时 %@", en: "Took %@"))
    static let commandsDestructiveTag = NamedCopy("sessions.commands.destructiveTag",
                                                  LocalizedString(zh: "破坏性", en: "Destructive"))
    static let commandsNeedsConfirmTag = NamedCopy("sessions.commands.needsConfirmTag",
                                                   LocalizedString(zh: "需确认", en: "Needs confirmation"))
    static let commandsA11yLine = NamedCopy("sessions.commands.a11yLine",
                                            LocalizedString(zh: "命令 %@", en: "Command %@"))
    static let commandsA11yExitCode = NamedCopy("sessions.commands.a11yExitCode",
                                                LocalizedString(zh: "退出码 %1$d", en: "Exit code %1$d"))
    static let commandsA11yTook = NamedCopy("sessions.commands.a11yTook",
                                            LocalizedString(zh: "耗时 %@", en: "Took %@"))
    static let commandsA11yDestructive = NamedCopy("sessions.commands.a11yDestructive",
                                                   LocalizedString(zh: "破坏性命令", en: "Destructive command"))

    // MARK: 详情（`SessionDetailView`）

    static let detailPickTitle = NamedCopy("sessions.detail.pickTitle",
                                           LocalizedString(zh: "选择一个会话", en: "Select a session"))
    static let detailPickMessage = NamedCopy("sessions.detail.pickMessage", LocalizedString(
        zh: "从会话列表挑一次 AI 使用会话，这里会展开它的耗时、文件改动、命令记录与事件摘要。",
        en: "Pick an AI session from the list; its duration, file changes, command log and event summary expand here."))
    static let detailA11yOutcome = NamedCopy("sessions.detail.a11yOutcome",
                                             LocalizedString(zh: "结果 %@", en: "Outcome %@"))
    static let detailObservedFor = NamedCopy("sessions.detail.observedFor",
                                             LocalizedString(zh: "观测时长 %@", en: "Observed for %@"))
    static let detailTileDuration = NamedCopy("sessions.detail.tile.duration",
                                              LocalizedString(zh: "时长", en: "Duration"))
    static let detailTileFileChanges = NamedCopy("sessions.detail.tile.fileChanges",
                                                 LocalizedString(zh: "文件改动", en: "File changes"))
    static let detailTileCommands = NamedCopy("sessions.detail.tile.commands",
                                              LocalizedString(zh: "命令执行", en: "Commands run"))
    static let detailTileFailedCommands = NamedCopy("sessions.detail.tile.failedCommands",
                                                    LocalizedString(zh: "失败命令", en: "Failed commands"))
    static let detailTileTokens = NamedCopy("sessions.detail.tile.tokens",
                                            LocalizedString(zh: "估算 Token", en: "Estimated tokens"))
    static let detailTilePeakCPU = NamedCopy("sessions.detail.tile.peakCPU",
                                             LocalizedString(zh: "峰值 CPU", en: "Peak CPU"))
    static let detailTilePeakMemory = NamedCopy("sessions.detail.tile.peakMemory",
                                                LocalizedString(zh: "峰值内存", en: "Peak memory"))
    static let detailTileRisks = NamedCopy("sessions.detail.tile.risks",
                                           LocalizedString(zh: "风险事件", en: "Risk events"))
    static let detailRunning = NamedCopy("sessions.detail.running",
                                         LocalizedString(zh: "进行中", en: "In progress"))
    static let detailEnded = NamedCopy("sessions.detail.ended", LocalizedString(zh: "已结束", en: "Ended"))
    static let detailFileBreakdown = NamedCopy("sessions.detail.fileBreakdown", LocalizedString(
        zh: "新建 %1$d · 修改 %2$d · 删除 %3$d", en: "%1$d created · %2$d modified · %3$d deleted"))
    // MARK: - 本次改动清单（#60）
    //
    // 三条回滚口径各一条文案：**"未版本控制"与"问不到"不许共用一句**，
    // 也不许有任何一条被读成"干净"（文件头第 2 条决定，用例 `SessionChangeInventoryHonestyTests` 判）。

    static let tabChanges = NamedCopy("sessions.tab.changes", LocalizedString(
        zh: "改动清单", en: "Changes"))
    static let changesTitle = NamedCopy("sessions.changes.title", LocalizedString(
        zh: "本次改动清单", en: "This session's changes"))
    static let changesSummary = NamedCopy("sessions.changes.summary", LocalizedString(
        zh: "%1$d 次改动 · %2$d 个文件", en: "%1$d changes · %2$d files"))
    static let changesPartial = NamedCopy("sessions.changes.partial", LocalizedString(
        zh: "仅前 %1$d 条（服务端共 %2$d 行）", en: "First %1$d only (server reports %2$d rows)"))
    static let changesEmpty = NamedCopy("sessions.changes.empty", LocalizedString(
        zh: "这个会话没有记录到文件改动", en: "No file changes recorded for this session"))
    static let changesError = NamedCopy("sessions.changes.error", LocalizedString(
        zh: "清单读取失败：%1$@", en: "Could not load the list: %1$@"))
    static let changesUncommittedCount = NamedCopy("sessions.changes.uncommittedCount", LocalizedString(
        zh: "%1$d 条尚未提交", en: "%1$d not committed"))
    static let rollbackUncommitted = NamedCopy("sessions.changes.rollback.uncommitted", LocalizedString(
        zh: "未提交 · 可退回", en: "Uncommitted · revertible"))
    static let rollbackCommitted = NamedCopy("sessions.changes.rollback.committed", LocalizedString(
        zh: "已提交", en: "Committed"))
    static let rollbackNotVersioned = NamedCopy("sessions.changes.rollback.notVersioned", LocalizedString(
        zh: "无版本控制，无法回滚", en: "No version control · cannot revert"))
    static let rollbackUnknown = NamedCopy("sessions.changes.rollback.unknown", LocalizedString(
        zh: "未能确认版本状态", en: "Version state could not be checked"))
    static let diffEntry = NamedCopy("sessions.changes.diffEntry", LocalizedString(
        zh: "改前 / 改后", en: "Before / after"))
    static let diffUnavailable = NamedCopy("sessions.changes.diffUnavailable", LocalizedString(
        zh: "该条没有留存前后内容", en: "No stored before/after for this change"))
    static let diffLoading = NamedCopy("sessions.changes.diffLoading", LocalizedString(
        zh: "正在取前后内容…", en: "Loading before/after…"))
    static let diffMeta = NamedCopy("sessions.changes.diffMeta", LocalizedString(
        zh: "前文 %1$d 行 · 后文 %2$d 行 · +%3$d −%4$d", en: "before %1$d lines · after %2$d lines · +%3$d −%4$d"))
    static let diffTruncated = NamedCopy("sessions.changes.diffTruncated", LocalizedString(
        zh: "（内容被截断）", en: " (truncated)"))
    static let diffBinary = NamedCopy("sessions.changes.diffBinary", LocalizedString(
        zh: "（二进制文件，无逐行对照）", en: " (binary, no line-by-line view)"))

    static let detailCommandsLoaded = NamedCopy("sessions.detail.commandsLoaded", LocalizedString(
        zh: "已加载明细 %1$d 条", en: "Loaded rows: %1$d"))
    static let detailCPUSeconds = NamedCopy("sessions.detail.cpuSeconds", LocalizedString(
        zh: "CPU 累计 %@", en: "%@ of CPU in total"))
    static let detailPeakCPUHelp = NamedCopy("sessions.detail.peakCPUHelp",
                                             LocalizedString(zh: "按采样窗口取最大", en: "Largest sampling window"))
    static let detailPeakMemoryHelp = NamedCopy("sessions.detail.peakMemoryHelp",
                                                LocalizedString(zh: "常驻内存峰值", en: "Peak resident memory"))
    static let detailRiskSeeSecurity = NamedCopy("sessions.detail.riskSeeSecurity", LocalizedString(
        zh: "明细见安全板块", en: "See the Security board for the details"))
    static let detailRiskNone = NamedCopy("sessions.detail.riskNone", LocalizedString(
        zh: "未触发风险规则", en: "No risk rule matched"))
    static let detailMetadata = NamedCopy("sessions.detail.metadata",
                                          LocalizedString(zh: "元信息", en: "Metadata"))
    static let detailStartedAt = NamedCopy("sessions.detail.startedAt",
                                           LocalizedString(zh: "开始时间", en: "Started"))
    static let detailEndedAt = NamedCopy("sessions.detail.endedAt", LocalizedString(zh: "结束时间", en: "Ended at"))
    static let detailActiveWindow = NamedCopy("sessions.detail.activeWindow",
                                              LocalizedString(zh: "活跃区间", en: "Active window"))
    static let detailObservedLabel = NamedCopy("sessions.detail.observedLabel",
                                               LocalizedString(zh: "观测时长", en: "Observed"))
    static let detailEventPreview = NamedCopy("sessions.detail.eventPreview",
                                              LocalizedString(zh: "事件预览", en: "Event preview"))
    static let detailFocusProject = NamedCopy("sessions.detail.focusProject",
                                              LocalizedString(zh: "聚焦此项目", en: "Focus this project"))
    /// #81 的三个取证出口。**#74 ① 改了可见文案**：三条原本都带「看这一条会话的」前缀，
    /// 在详情面板那点宽度里**全部截断成同一串「看这一条会话…」**⇒ 三个按钮视觉上无法区分，
    /// 这正是"界面说半截话"那一族（同 #46 把空路径渲染成两个空格）。
    /// 作用域那层信息**没有删**，只是换个地方说一次：
    ///   · 可见文案缩到互相分辨得开的「事件 / 文件变更 / 命令」（配 SF Symbol）；
    ///   · 「只看这一条会话」由上面那行 ``detailJumpScopeCaption`` 承担（说一次，不在三颗按钮上重复三遍）；
    ///   · 完整语义进每颗按钮的 `.accessibilityLabel`（读屏拿到的仍是整句）。
    static let detailJumpScopeCaption = NamedCopy("sessions.detail.jumpScopeCaption", LocalizedString(
        zh: "以下三个入口都只看这一条会话", en: "All three show only this session"))
    static let detailJumpToTimeline = NamedCopy("sessions.detail.jumpToTimeline",
                                                LocalizedString(zh: "事件", en: "Events"))
    static let detailJumpToFileChanges = NamedCopy("sessions.detail.jumpToFileChanges",
                                                   LocalizedString(zh: "文件变更", en: "File changes"))
    static let detailJumpToCommands = NamedCopy("sessions.detail.jumpToCommands",
                                                LocalizedString(zh: "命令", en: "Commands"))
    /// 完整语义（读屏用）。措辞保留 #81 那条"全量还是这一条"的回答。
    static let detailJumpToTimelineA11y = NamedCopy("sessions.detail.jumpToTimeline.a11y",
                                                    LocalizedString(zh: "看这一条会话的事件",
                                                                    en: "View this session's events"))
    static let detailJumpToFileChangesA11y = NamedCopy("sessions.detail.jumpToFileChanges.a11y",
                                                       LocalizedString(zh: "看这一条会话的文件变更",
                                                                       en: "View this session's file changes"))
    static let detailJumpToCommandsA11y = NamedCopy("sessions.detail.jumpToCommands.a11y",
                                                    LocalizedString(zh: "看这一条会话的命令",
                                                                    en: "View this session's commands"))
    static let detailNoProject = NamedCopy("sessions.detail.noProject",
                                           LocalizedString(zh: "未关联项目", en: "No project linked"))
    static let detailEventCountCap = NamedCopy("sessions.detail.eventCountCap", LocalizedString(
        zh: "%1$d 条 · 上限 %2$d", en: "Shown %1$d of %2$d"))
    static let detailTabsLabel = NamedCopy("sessions.detail.tabsLabel",
                                           LocalizedString(zh: "详情页签", en: "Detail tabs"))
    static let detailEventsTitle = NamedCopy("sessions.detail.eventsTitle",
                                             LocalizedString(zh: "事件摘要", en: "Event summary"))
    static let detailEventsSubtitle = NamedCopy("sessions.detail.eventsSubtitle", LocalizedString(
        zh: "按时间倒序展示本会话最近 %1$d 条行为事件",
        en: "Behaviour events, newest first (up to %1$d)"))
    static let detailEventsReading = NamedCopy("sessions.detail.eventsReading",
                                               LocalizedString(zh: "正在读取事件…", en: "Reading events…"))
    static let detailEventsEmptyTitle = NamedCopy("sessions.detail.eventsEmptyTitle", LocalizedString(
        zh: "本会话暂未捕获到行为事件", en: "No behaviour events captured for this session yet"))
    static let detailEventsEmptyMessage = NamedCopy("sessions.detail.eventsEmptyMessage", LocalizedString(
        zh: "引擎按采样间隔记录行为；短于一档间隔的动作可能没有成条事件。",
        en: "The engine records behaviour one sampling interval at a time; an action shorter than that may never become an event."))
    static let detailReading = NamedCopy("sessions.detail.reading",
                                         LocalizedString(zh: "正在读取会话详情…", en: "Reading session details…"))
    static let detailTook = NamedCopy("sessions.detail.took", LocalizedString(zh: "耗时 %@", en: "Took %@"))
    static let detailA11yRisk = NamedCopy("sessions.detail.a11yRisk",
                                          LocalizedString(zh: "风险 %@", en: "Risk %@"))

    // MARK: 过滤条（`SessionFilterBar`）

    static let filterTimeRange = NamedCopy("sessions.filter.timeRange",
                                           LocalizedString(zh: "时间范围", en: "Time range"))
    static let filterResetAll = NamedCopy("sessions.filter.resetAll",
                                          LocalizedString(zh: "重置全部过滤", en: "Reset all filters"))
    static let filterGroupA11y = NamedCopy("sessions.filter.groupA11y",
                                           LocalizedString(zh: "会话过滤条件", en: "Session filters"))
    static let filterMenu = NamedCopy("sessions.filter.menu", LocalizedString(zh: "筛选", en: "Filter"))
    static let filterMenuCounted = NamedCopy("sessions.filter.menuCounted",
                                             LocalizedString(zh: "筛选 · %1$d", en: "Filter · %1$d"))
    static let filterAllAgents = NamedCopy("sessions.filter.allAgents",
                                           LocalizedString(zh: "全部 Agent", en: "All agents"))
    static let filterAllOutcomes = NamedCopy("sessions.filter.allOutcomes",
                                             LocalizedString(zh: "全部状态", en: "Any status"))
    static let filterOutcomeRow = NamedCopy("sessions.filter.outcomeRow", LocalizedString(
        zh: "%1$@ · 已加载 %2$d", en: "%1$@ · %2$d loaded"))
    static let filterRiskyOnly = NamedCopy("sessions.filter.riskyOnly", LocalizedString(
        zh: "只看有风险（本地筛已加载行）", en: "Risky only (filters the loaded rows locally)"))
    static let filterNewestFirst = NamedCopy("sessions.filter.newestFirst",
                                             LocalizedString(zh: "最新在前", en: "Newest first"))
    static let filterOldestFirst = NamedCopy("sessions.filter.oldestFirst",
                                             LocalizedString(zh: "最早在前", en: "Oldest first"))
    static let filterClearProject = NamedCopy("sessions.filter.clearProject", LocalizedString(
        zh: "取消项目过滤：%1$@", en: "Clear the project filter: %@"))
    static let filterProjectHelp = NamedCopy("sessions.filter.projectHelp", LocalizedString(
        zh: "项目过滤：%1$@，点击取消", en: "Project filter: %@ — click to clear"))
    static let filterSearchPrompt = NamedCopy("sessions.filter.searchPrompt", LocalizedString(
        zh: "搜索会话标题 / 项目 / Agent", en: "Search session titles / projects / agents"))
    static let filterSearchA11y = NamedCopy("sessions.filter.searchA11y",
                                            LocalizedString(zh: "搜索会话", en: "Search sessions"))

    // MARK: 列表行（`SessionRow`）

    static let rowRiskTag = NamedCopy("sessions.row.riskTag", LocalizedString(zh: "风险 %1$d", en: "Risk %1$d"))
    static let rowRiskA11y = NamedCopy("sessions.row.riskA11y",
                                       LocalizedString(zh: "%1$d 项风险事件", en: "Risk events: %1$d"))
    static let rowA11yFiles = NamedCopy("sessions.row.a11yFiles",
                                        LocalizedString(zh: "文件 %1$d", en: "Files: %1$d"))
    static let rowA11yCommandsFailed = NamedCopy("sessions.row.a11yCommandsFailed", LocalizedString(
        zh: "命令 %1$d·失败 %2$d", en: "Commands: %1$d · failed: %2$d"))
    static let rowA11yCommands = NamedCopy("sessions.row.a11yCommands",
                                           LocalizedString(zh: "命令 %1$d", en: "Commands: %1$d"))
    static let rowA11yNumbered = NamedCopy("sessions.row.a11yNumbered",
                                           LocalizedString(zh: "会话 #%1$d", en: "Session #%1$d"))
    static let rowA11yUnnumbered = NamedCopy("sessions.row.a11yUnnumbered",
                                             LocalizedString(zh: "未编号会话", en: "Unnumbered session"))
    static let rowA11yDuration = NamedCopy("sessions.row.a11yDuration",
                                           LocalizedString(zh: "时长 %@", en: "Duration %@"))
    static let rowA11ySummary = NamedCopy("sessions.row.a11ySummary", LocalizedString(
        zh: "文件改动 %1$d，命令 %2$d，失败 %3$d",
        en: "File changes: %1$d · commands: %2$d · failed: %3$d"))
    static let rowA11yRiskEvents = NamedCopy("sessions.row.a11yRiskEvents",
                                             LocalizedString(zh: "风险事件 %1$d", en: "Risk events: %1$d"))

    // MARK: 模型读数（`SessionsModel`）

    static let tabCommands = NamedCopy("sessions.tab.commands",
                                       LocalizedString(zh: "命令记录", en: "Command log"))
    static let tabEvents = NamedCopy("sessions.tab.events",
                                     LocalizedString(zh: "事件摘要", en: "Event summary"))
    static let statUnloadedLabel = NamedCopy("sessions.stat.unloadedLabel",
                                             LocalizedString(zh: "未加载", en: "Not loaded"))
    static let statUnloadedValue = NamedCopy("sessions.stat.unloadedValue",
                                             LocalizedString(zh: "%1$d 个", en: "%1$d"))
    static let statFilterLabel = NamedCopy("sessions.stat.filterLabel",
                                           LocalizedString(zh: "过滤条件", en: "Filters"))
    static let statSortLabel = NamedCopy("sessions.stat.sortLabel", LocalizedString(zh: "排序", en: "Sort"))
    static let statFiltersActive = NamedCopy("sessions.stat.filtersActive",
                                             LocalizedString(zh: "%1$d 项生效", en: "%1$d active"))
    static let statProject = NamedCopy("sessions.stat.project", LocalizedString(zh: "项目 %@", en: "Project %@"))
    static let statFilterOff = NamedCopy("sessions.stat.filterOff", LocalizedString(zh: "未启用", en: "None"))
    static let progressTotalLoaded = NamedCopy("sessions.progress.totalLoaded", LocalizedString(
        zh: "共 %1$d · 已加载 %2$d", en: "%1$d in total · %2$d loaded"))
    static let progressRiskyShown = NamedCopy("sessions.progress.riskyShown", LocalizedString(
        zh: "共 %1$d · 已加载 %2$d · 「只看有风险」下显示 %3$d",
        en: "%1$d in total · %2$d loaded · “Risky only” shows %3$d"))
    static let timeRangeRunning = NamedCopy("sessions.timeRange.running",
                                            LocalizedString(zh: "%1$@ → 进行中", en: "%1$@ → in progress"))

    // MARK: 列表页骨架（`SessionsView`）

    static let pageSubtitle = NamedCopy("sessions.page.subtitle", LocalizedString(
        zh: "%1$@ · 每页最多加载 %2$d 个", en: "%1$@ · up to %2$d per page"))
    static let heroTitle = NamedCopy("sessions.hero.title",
                                     LocalizedString(zh: "会话总数", en: "Total sessions"))
    static let totalsTitle = NamedCopy("sessions.totals.title",
                                       LocalizedString(zh: "已加载会话的合计", en: "Totals for loaded sessions"))
    static let totalsSubtitle = NamedCopy("sessions.totals.subtitle", LocalizedString(
        zh: "只统计本页已加载的 %1$d 个会话，载入更早之后这些数字会跟着变",
        en: "Covers only the %1$d sessions loaded on this page; loading earlier changes these totals"))
    static let totalsRisky = NamedCopy("sessions.totals.risky",
                                       LocalizedString(zh: "有风险事件", en: "With risk events"))
    static let totalsRiskyValue = NamedCopy("sessions.totals.riskyValue",
                                            LocalizedString(zh: "%1$d 个会话", en: "%1$d with risks"))
    static let totalsRunning = NamedCopy("sessions.totals.running",
                                         LocalizedString(zh: "进行中", en: "In progress"))
    static let totalsRunningCaption = NamedCopy("sessions.totals.runningCaption", LocalizedString(
        zh: "进程仍在观测范围内", en: "Its process is still inside the observation window"))
    static let totalsDuration = NamedCopy("sessions.totals.duration",
                                          LocalizedString(zh: "累计时长", en: "Total duration"))
    static let totalsDurationCaption = NamedCopy("sessions.totals.durationCaption", LocalizedString(
        zh: "求和 · 进行中的算到当前时刻",
        en: "Summed · running counts up to now"))
    static let totalsCommands = NamedCopy("sessions.totals.commands",
                                          LocalizedString(zh: "命令执行", en: "Commands run"))
    static let totalsCommandsCaption = NamedCopy("sessions.totals.commandsCaption",
                                                 LocalizedString(zh: "失败 %1$d 条", en: "%1$d failed"))
    static let totalsFiles = NamedCopy("sessions.totals.files",
                                       LocalizedString(zh: "文件改动", en: "File changes"))
    static let listTitle = NamedCopy("sessions.list.title",
                                     LocalizedString(zh: "会话列表", en: "Session list"))
    static let listLoadingEarlier = NamedCopy("sessions.list.loadingEarlier", LocalizedString(
        zh: "正在载入更早的会话…", en: "Loading earlier sessions…"))
    static let listLoadEarlier = NamedCopy("sessions.list.loadEarlier",
                                           LocalizedString(zh: "载入更早", en: "Load earlier"))
    static let listLoadEarlierHelp = NamedCopy("sessions.list.loadEarlierHelp", LocalizedString(
        zh: "再拉一页（%1$d 个）更早的会话，按当前排序方向续接",
        en: "Fetches one more page of %1$d earlier sessions, continuing in the current sort direction"))
    static let listKeyboardHint = NamedCopy("sessions.list.keyboardHint", LocalizedString(
        zh: "详情随选中展开 · ↑ / ↓ 换选中",
        en: "Details expand for the selection · ↑ / ↓ moves the selection"))
    static let exportLabel = NamedCopy("sessions.export.label", LocalizedString(zh: "导出", en: "Export"))
    static let exportHelp = NamedCopy("sessions.export.help", LocalizedString(
        zh: "导出当前时间范围内的活动记录；默认对路径与命令做脱敏",
        en: "Exports the activity inside the current time range; paths and commands are redacted by default"))
    static let loadingTitle = NamedCopy("sessions.loading.title",
                                        LocalizedString(zh: "正在读取 AI 会话…", en: "Reading AI sessions…"))
    static let emptyNoSessionTitle = NamedCopy("sessions.empty.noneTitle",
                                               LocalizedString(zh: "还没有观测到任何会话", en: "No sessions observed yet"))
    static let emptyNoSessionMessage = NamedCopy("sessions.empty.noneMessage", LocalizedString(
        zh: "引擎在检测到 AI Agent 启动后会为每次使用建立会话。若 Agent 早已在运行，可点「立即重新扫描」补建基线。",
        en: "The engine opens a session each time it detects an AI agent starting. If the agent was already running, press Rescan now to backfill a baseline."))
    static let rescanNow = NamedCopy("sessions.rescan",
                                     LocalizedString(zh: "立即重新扫描", en: "Rescan now"))
    static let emptyFilteredTitle = NamedCopy("sessions.empty.filteredTitle", LocalizedString(
        zh: "没有符合条件的会话", en: "No sessions match these filters"))
    static let emptyFilteredMessage = NamedCopy("sessions.empty.filteredMessage", LocalizedString(
        zh: "已启用 %1$d 项过滤条件（时间范围「%2$@」），把它们放宽后就能看到历史会话。",
        en: "Active filters: %1$d (time range “%2$@”). Widen them and past sessions appear."))
    static let resetFilters = NamedCopy("sessions.empty.resetFilters",
                                        LocalizedString(zh: "重置过滤器", en: "Reset filters"))
    static let emptyRangeTitle = NamedCopy("sessions.empty.rangeTitle",
                                           LocalizedString(zh: "「%@」没有会话", en: "No sessions in “%@”"))
    static let emptyRangeMessage = NamedCopy("sessions.empty.rangeMessage", LocalizedString(
        zh: "这段时间内引擎没有记录到 AI 使用会话。可以切到「全部」查看更早的会话，或让引擎重新扫描一次。",
        en: "The engine recorded no AI sessions in this window. Switch to “All” for earlier sessions, or let the engine rescan once."))
    static let showAllTime = NamedCopy("sessions.empty.showAllTime",
                                       LocalizedString(zh: "查看全部时间", en: "Show all time"))
    static let errorFull = NamedCopy("sessions.error.full",
                                     LocalizedString(zh: "会话读取失败", en: "Session read failed"))
    static let errorStale = NamedCopy("sessions.error.stale", LocalizedString(
        zh: "最近一次读取失败，下面显示的是上一次成功加载的结果",
        en: "The last read failed; what is shown below is the previous successful load"))
    static let retry = NamedCopy("sessions.error.retry", LocalizedString(zh: "重试", en: "Retry"))

    // MARK: - 集中清单（门禁遍历这一份）

    // MARK: result 组文案（6 条，key 前缀 result.*）
    static let resultCopy: [NamedCopy] = [
        resultSomeFailed,
        resultNoCommands,
        resultPartiallyLoaded,
        resultNothingResolved,
        resultPartiallyResolved,
        resultAllPassed,
    ]

    // MARK: commands 组文案（19 条，key 前缀 commands.*）
    static let commandsCopy: [NamedCopy] = [
        commandsTitle,
        commandsDangerousOnly,
        commandsDangerousOnlyHelp,
        commandsLoading,
        commandsNoneCaptured,
        commandsProgress,
        commandsReading,
        commandsNoDangerous,
        commandsNoExecutions,
        commandsDangerousFilteredAll,
        commandsPollingNote,
        commandsShowAll,
        commandsTook,
        commandsDestructiveTag,
        commandsNeedsConfirmTag,
        commandsA11yLine,
        commandsA11yExitCode,
        commandsA11yTook,
        commandsA11yDestructive,
    ]

    // MARK: tab 组文案（1 条，key 前缀 tab.*）
    static let tabCopy: [NamedCopy] = [
        tabChanges,
    ]

    // MARK: changes 组文案（6 条，key 前缀 changes.*）
    static let changesCopy: [NamedCopy] = [
        changesTitle,
        changesSummary,
        changesPartial,
        changesEmpty,
        changesError,
        changesUncommittedCount,
    ]

    // MARK: rollback 组文案（4 条，key 前缀 rollback.*）
    static let rollbackCopy: [NamedCopy] = [
        rollbackUncommitted,
        rollbackCommitted,
        rollbackNotVersioned,
        rollbackUnknown,
    ]

    // MARK: diff 组文案（6 条，key 前缀 diff.*）
    static let diffCopy: [NamedCopy] = [
        diffEntry,
        diffUnavailable,
        diffLoading,
        diffMeta,
        diffTruncated,
        diffBinary,
    ]

    // MARK: detail 组文案（40 条，key 前缀 detail.*）
    static let detailCopy: [NamedCopy] = [
        detailPickTitle,
        detailPickMessage,
        detailA11yOutcome,
        detailObservedFor,
        detailTileDuration,
        detailTileFileChanges,
        detailTileCommands,
        detailTileFailedCommands,
        detailTileTokens,
        detailTilePeakCPU,
        detailTilePeakMemory,
        detailTileRisks,
        detailRunning,
        detailEnded,
        detailFileBreakdown,
        detailCommandsLoaded,
        detailCPUSeconds,
        detailPeakCPUHelp,
        detailPeakMemoryHelp,
        detailRiskSeeSecurity,
        detailRiskNone,
        detailMetadata,
        detailJumpScopeCaption,
        detailJumpToTimelineA11y,
        detailJumpToFileChangesA11y,
        detailJumpToCommandsA11y,
        detailStartedAt,
        detailEndedAt,
        detailActiveWindow,
        detailObservedLabel,
        detailEventPreview,
        detailFocusProject,
        detailJumpToTimeline,
        detailJumpToFileChanges,
        detailJumpToCommands,
        detailNoProject,
        detailEventCountCap,
        detailTabsLabel,
        detailEventsTitle,
        detailEventsSubtitle,
        detailEventsReading,
        detailEventsEmptyTitle,
        detailEventsEmptyMessage,
        detailReading,
        detailTook,
        detailA11yRisk,
    ]

    // MARK: filter 组文案（15 条，key 前缀 filter.*）
    static let filterCopy: [NamedCopy] = [
        filterTimeRange,
        filterResetAll,
        filterGroupA11y,
        filterMenu,
        filterMenuCounted,
        filterAllAgents,
        filterAllOutcomes,
        filterOutcomeRow,
        filterRiskyOnly,
        filterNewestFirst,
        filterOldestFirst,
        filterClearProject,
        filterProjectHelp,
        filterSearchPrompt,
        filterSearchA11y,
    ]

    // MARK: row 组文案（10 条，key 前缀 row.*）
    static let rowCopy: [NamedCopy] = [
        rowRiskTag,
        rowRiskA11y,
        rowA11yFiles,
        rowA11yCommandsFailed,
        rowA11yCommands,
        rowA11yNumbered,
        rowA11yUnnumbered,
        rowA11yDuration,
        rowA11ySummary,
        rowA11yRiskEvents,
    ]

    // MARK: tab2 组文案（2 条，key 前缀 tab.*）
    static let tab2Copy: [NamedCopy] = [
        tabCommands,
        tabEvents,
    ]

    // MARK: stat 组文案（7 条，key 前缀 stat.*）
    static let statCopy: [NamedCopy] = [
        statUnloadedLabel,
        statUnloadedValue,
        statFilterLabel,
        statSortLabel,
        statFiltersActive,
        statProject,
        statFilterOff,
    ]

    // MARK: progress 组文案（2 条，key 前缀 progress.*）
    static let progressCopy: [NamedCopy] = [
        progressTotalLoaded,
        progressRiskyShown,
    ]

    // MARK: time 组文案（1 条，key 前缀 time.*）
    static let timeCopy: [NamedCopy] = [
        timeRangeRunning,
    ]

    // MARK: page 组文案（1 条，key 前缀 page.*）
    static let pageCopy: [NamedCopy] = [
        pageSubtitle,
    ]

    // MARK: hero 组文案（1 条，key 前缀 hero.*）
    static let heroCopy: [NamedCopy] = [
        heroTitle,
    ]

    // MARK: totals 组文案（11 条，key 前缀 totals.*）
    static let totalsCopy: [NamedCopy] = [
        totalsTitle,
        totalsSubtitle,
        totalsRisky,
        totalsRiskyValue,
        totalsRunning,
        totalsRunningCaption,
        totalsDuration,
        totalsDurationCaption,
        totalsCommands,
        totalsCommandsCaption,
        totalsFiles,
    ]

    // MARK: list 组文案（5 条，key 前缀 list.*）
    static let listCopy: [NamedCopy] = [
        listTitle,
        listLoadingEarlier,
        listLoadEarlier,
        listLoadEarlierHelp,
        listKeyboardHint,
    ]

    // MARK: export 组文案（2 条，key 前缀 export.*）
    static let exportCopy: [NamedCopy] = [
        exportLabel,
        exportHelp,
    ]

    // MARK: loading 组文案（1 条，key 前缀 loading.*）
    static let loadingCopy: [NamedCopy] = [
        loadingTitle,
    ]

    // MARK: empty 组文案（2 条，key 前缀 empty.*）
    static let emptyCopy: [NamedCopy] = [
        emptyNoSessionTitle,
        emptyNoSessionMessage,
    ]

    // MARK: rescan 组文案（1 条，key 前缀 rescan.*）
    static let rescanCopy: [NamedCopy] = [
        rescanNow,
    ]

    // MARK: empty2 组文案（2 条，key 前缀 empty.*）
    static let empty2Copy: [NamedCopy] = [
        emptyFilteredTitle,
        emptyFilteredMessage,
    ]

    // MARK: reset 组文案（1 条，key 前缀 reset.*）
    static let resetCopy: [NamedCopy] = [
        resetFilters,
    ]

    // MARK: empty3 组文案（2 条，key 前缀 empty.*）
    static let empty3Copy: [NamedCopy] = [
        emptyRangeTitle,
        emptyRangeMessage,
    ]

    // MARK: show 组文案（1 条，key 前缀 show.*）
    static let showCopy: [NamedCopy] = [
        showAllTime,
    ]

    // MARK: error 组文案（2 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        errorFull,
        errorStale,
    ]

    // MARK: retry 组文案（1 条，key 前缀 retry.*）
    static let retryCopy: [NamedCopy] = [
        retry,
    ]

    /// 清单就是"上面那些常量的名字"这一份列表。漏列的漏洞由门禁③堵：
    /// `SessionsBilingualCopyGateTests` 数本文件里 `static let … = NamedCopy(` 的处数，
    /// 与这个数组的条数必须相等 ⇒ 加一条文案而不登记，用例当场红。
    static let bilingualCopy: [NamedCopy] =
        resultCopy
        + commandsCopy
        + tabCopy
        + changesCopy
        + rollbackCopy
        + diffCopy
        + detailCopy
        + filterCopy
        + rowCopy
        + tab2Copy
        + statCopy
        + progressCopy
        + timeCopy
        + pageCopy
        + heroCopy
        + totalsCopy
        + listCopy
        + exportCopy
        + loadingCopy
        + emptyCopy
        + rescanCopy
        + empty2Copy
        + resetCopy
        + empty3Copy
        + showCopy
        + errorCopy
        + retryCopy

}
