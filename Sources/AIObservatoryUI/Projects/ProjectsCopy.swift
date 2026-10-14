//
//  ProjectsCopy.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-l10nb（B3 最后三页 · 项目地图）
//  ─────────────────────────────────────────────────────────
//  项目地图页全部**用户可见**文案（含 Swift Charts 的 `.value(...)` 轴标签、
//  `.accessibilityLabel` 与 tooltip），按 IFR 裁定 3(a) 集中声明成一份 `bilingualCopy`，
//  门禁见 `ProjectsBilingualCopyGateTests`。
//
//  迁移口径与 `ShellCopy`/`TimelineCopy` 一致（四条：只迁进眼睛/读屏的字、中文侧逐字不动、
//  多参数用 `%1$@`/`%2$d`、英文一律数量中性）。语言在 `UILanguage.current` 一处解析。
//
//  【本页是三页里量词最重的一页】"N 个 / N 次 / N 起 / N 条 / N 种"在这里出现 11 处，
//  分两种走法，**都不许在英文侧补一个假名词**（理由见 `TimelineCopy.measureWord`）：
//   · 单独当单位挂在数字后面的（`unit:` 参数、单元格里的「24 次」）→ `measureWord` / `counted`
//     两个辅助函数，中文侧的字面量留在本文件（门禁把文案表整文件排除，四目录同一口径）；
//   · 量词嵌在整句里的（「另有 3 个文件未列入前 6 名」）→ 整句进表，英文侧写成名词前置或
//     干脆不带名词（"3 more outside the top 6"），这一条由 `pluralTrap` 用例兜着。
//
//  【读屏那两句是本页最长的模板】`ProjectCard` 的行摘要 8 个参数、`ProjectHeatRow` 6 个：
//  参数类型按位置两语言逐位对齐，英文把名词挪到数字前面也不串位。这两句中文侧
//  是从多行字符串字面量搬过来的，**逐字未动**（读屏念出来的口径与界面同一份）。
//
//  ⚠️ 英文态仍混排的位置（交回总控，同 `ShellCopy` 文件头那条，不在本车道绕过）：
//  `AgentKind.displayName` 在 `Core/Contracts/**`（§3）
//  仍是中文 ⇒ 页头「范围…」那一行、时间范围菜单与贡献图的行名在英文态夹中文。
//  另外「最活跃：<项目名>」这类值本身是数据，不参与翻译。
//

import Foundation
import AIObservatoryCore

/// 项目地图页的用户可见文案表（B3）。
enum ProjectsCopy {

    // MARK: 量词（英文没有对应物，所以**不进表**，理由见 `TimelineCopy.measureWord`）

    static func measureWord(_ chinese: String, _ language: AppLanguage) -> String {
        language == .chineseSimplified ? chinese : ""
    }

    static func unitProjects(_ language: AppLanguage) -> String { measureWord("个", language) }
    static func unitTimes(_ language: AppLanguage) -> String { measureWord("次", language) }
    static func unitRisks(_ language: AppLanguage) -> String { measureWord("起", language) }

    /// 数字 + 量词：中文「24 次」，英文只留「24」。
    /// 为什么不写成 `LocalizedString(zh: "%d 次", en: "%d")`：那样英文侧那条 "%d" 会被
    /// `englishSameAsChinese` 之外的门禁当成"没译"，下一个修的人只会去补个假名词。
    static func countedTimes(_ value: Int, _ language: AppLanguage) -> String {
        counted("次", value, language)
    }

    static func countedItems(_ value: Int, _ language: AppLanguage) -> String {
        counted("个", value, language)
    }

    static func countedRows(_ value: Int, _ language: AppLanguage) -> String {
        counted("条", value, language)
    }

    private static func counted(_ unit: String, _ value: Int, _ language: AppLanguage) -> String {
        language == .chineseSimplified ? "\(value) \(unit)" : "\(value)"
    }

    /// 读屏拼句的分段符：中文全角逗号、英文半角（全角逗号在英文态会被念成一个停顿）。
    static let a11yJoiner = LocalizedString(zh: "，", en: ", ")

    // MARK: 时间文案（`ProjectTimeText`，卡片与详情共用一份）

    static let timeJustNow = LocalizedString(zh: "刚刚", en: "Just now")
    /// 「18分钟前」的「前」是后置词，英文是后置 "ago"，顺序一致 ⇒ 单参数裸 `%@` 不串位。
    static let timeAgo = LocalizedString(zh: "%@前", en: "%@ ago")
    /// 「3天前的 14:22」英文写 "3 d ago"：`LocalizedString` 没有复数分支，
    /// "%d days ago" 在命中一天时会渲染成 "1 days ago"（见 `ShellCopy` 文件头那条）。
    static let timeDaysAgo = LocalizedString(zh: "%1$d天前的 %2$@", en: "%1$d d ago · %2$@")
    static let timeSameInstant = LocalizedString(zh: "同一时刻", en: "Same instant")

    // MARK: 排序口径（`ProjectsSortKey`）

    static let sortRecent = LocalizedString(zh: "最近活跃", en: "Most recent")
    static let sortBusiest = LocalizedString(zh: "改动最多", en: "Most changes")
    /// 「净增代码」既是排序口径也是两处字段标签（页面指标区与详情），同一个出处。
    static let netCode = LocalizedString(zh: "净增代码", en: "Net code")
    static let sortRiskFirst = LocalizedString(zh: "风险优先", en: "Risk first")

    // MARK: 净增行数口径（`ProjectDeltaText.detailed`）
    // 只换字面来源：净增在前、两个分项在括号里的结构保持原样（净增不携带好坏判断，不上色）。

    static let deltaDetailed = LocalizedString(
        zh: "%1$@ 行（新增 %2$d · 删除 %3$d）",
        en: "%1$@ net (added %2$d · removed %3$d)"
    )

    // MARK: 模型错误

    static let detailNoDataError = LocalizedString(
        zh: "该项目在当前时间范围内没有可聚合的活动数据。",
        en: "This project has no aggregatable activity in the current time range."
    )

    // MARK: 页头与指标区（`ProjectsView`）

    /// 可见 / 全量两个数一起报，口径不同 ⇒ 英文也保持 "visible X of Y" 的分开写法。
    static let pageSubtitle = LocalizedString(
        zh: "范围「%1$@」· 可见 %2$d / 共 %3$d 个项目",
        en: "Range “%1$@” · visible %2$d of %3$d"
    )
    static let statLatestActivity = LocalizedString(zh: "最近活动", en: "Latest activity")
    static let tileVisibleProjects = LocalizedString(zh: "可见项目", en: "Visible projects")
    static let tileVisibleProjectsCaption = LocalizedString(
        zh: "只算过滤后可见的；全量在标题那一行",
        en: "Counts only what the filters leave visible; the full number is on the title line."
    )
    static let tileFileChanges = LocalizedString(zh: "文件变更", en: "File changes")
    static let tileFileChangesCaption = LocalizedString(
        zh: "去重热区文件 %1$d 个", en: "Distinct hot files: %1$d"
    )
    static let tileCommands = LocalizedString(zh: "命令执行", en: "Commands run")
    static let tileCommandsCaption = LocalizedString(
        zh: "归属到可见项目的工作目录", en: "Attributed to the working directories of visible projects"
    )
    static let tileSessions = LocalizedString(zh: "AI 会话", en: "AI sessions")
    static let tileSessionsCaption = LocalizedString(zh: "最活跃：%@", en: "Busiest: %@")
    static let statLiveHits = LocalizedString(zh: "实时命中", en: "Live hits")
    static let liveHitValue = LocalizedString(zh: "%d 个项目", en: "Projects: %d")
    static let liveHitNone = LocalizedString(zh: "本周期内没有", en: "None this cycle")
    static let riskTag = LocalizedString(
        zh: "风险 %1$d 起 · 涉及 %2$d 个项目", en: "Risks: %1$d · projects: %2$d"
    )

    // MARK: 加载 / 空 / 被筛空 / 错误

    static let loadingDetailRow = LocalizedString(
        zh: "正在刷新选中项目的详情…", en: "Refreshing the selected project's detail…"
    )
    static let loadingAggregating = LocalizedString(zh: "正在聚合项目地图", en: "Aggregating the project map")
    static let loadingFirstHint = LocalizedString(
        zh: "首次进入会按「%@」拉取项目、热区文件与 Agent 贡献。",
        en: "On first entry this pulls projects, hot files and agent contributions for “%@”."
    )
    static let emptyNoActivityTitle = LocalizedString(zh: "还没有项目级活动", en: "No project-level activity yet")
    static let emptyNoActivityMessage = LocalizedString(
        zh: "引擎会把观测到的文件改动与命令归属到最近的仓库根。出现第一条 AI 改动后，"
            + "这里会列出每个项目的活跃度、Agent 占比与热区文件。",
        en: "The engine attributes observed file changes and commands to the nearest repository root. "
            + "Once the first AI change appears, this lists each project's activity, agent share and hot files."
    )
    static let rescan = LocalizedString(zh: "重新扫描", en: "Rescan")
    static let emptyFilteredTitle = LocalizedString(zh: "没有符合条件的项目", en: "No projects match the filters")
    static let emptyFilteredMessage = LocalizedString(
        zh: "共 %d 个项目被当前搜索、Agent 或时间范围过滤条件挡掉了。",
        en: "Filtered out by the current search, agent or time-range filters: %d"
    )
    static let resetFilters = LocalizedString(zh: "重置过滤条件", en: "Reset filters")
    static let readFailedTitle = LocalizedString(zh: "项目地图读取失败", en: "Failed to read the project map")
    static let retry = LocalizedString(zh: "重试", en: "Retry")

    // MARK: 过滤条

    static let timeRange = LocalizedString(zh: "时间范围", en: "Time range")
    static let allAgents = LocalizedString(zh: "全部 Agent", en: "All agents")
    static let a11yAgentFilter = LocalizedString(zh: "Agent 过滤", en: "Agent filter")
    static let a11ySortMode = LocalizedString(zh: "排序方式", en: "Sort order")
    static let searchPrompt = LocalizedString(zh: "搜索项目名或路径…", en: "Search project names or paths…")
    static let a11yClearSearch = LocalizedString(zh: "清空搜索", en: "Clear search")
    static let reset = LocalizedString(zh: "重置", en: "Reset")
    static let liveUpdatingTag = LocalizedString(zh: "实时更新", en: "Live updates")
    static let subscribedTag = LocalizedString(zh: "订阅中", en: "Subscribed")
    static let agentKindCount = LocalizedString(zh: "%d 个 Agent", en: "Agents: %d")

    // MARK: 跨项目总览

    static let overviewTitle = LocalizedString(zh: "跨项目总览", en: "Cross-project overview")
    static let overviewSubtitle = LocalizedString(
        zh: "把可见项目的贡献合并后归一化，点左侧任意项目可下钻",
        en: "Contributions merged and normalized across visible projects. "
            + "Pick any project on the left to drill in."
    )
    static let overviewChartTitle = LocalizedString(
        zh: "Agent 贡献占比（可见项目）", en: "Agent share (visible projects)"
    )
    static let overviewChartSubtitle = LocalizedString(
        zh: "同 kind 跨项目合并后归一化", en: "Same kind merged and normalized across projects"
    )
    static let globalHotFilesTitle = LocalizedString(zh: "全局热点文件", en: "Global hot files")
    static let globalHotFilesSubtitle = LocalizedString(
        zh: "跨可见项目合并，同路径取更高热度",
        en: "Merged across visible projects; the higher heat wins for the same path"
    )
    static let globalHotFilesEmpty = LocalizedString(
        zh: "把时间范围放宽一些，或让 AI Agent 先在项目里做一次改动。",
        en: "Widen the time range, or let an AI agent make one change inside a project first."
    )

    // MARK: 详情面板（`ProjectDetailView`）

    static let detailChartSubtitle = LocalizedString(
        zh: "口径：%@ · 按文件变更归属", en: "Scope: %@ · attributed by file change"
    )
    static let detailHotFilesTitle = LocalizedString(zh: "本项目热区", en: "This project's hot files")
    static let detailHotFilesEmpty = LocalizedString(
        zh: "本范围内该项目还没有落到具体文件的改动，可切换更宽的时间范围。",
        en: "No file-level changes for this project in this range yet; try a wider time range."
    )
    static let detailMapSubtitle = LocalizedString(zh: "项目级 AI 活动地图", en: "Project-level AI activity map")
    static let liveTag = LocalizedString(zh: "实时", en: "Live")
    static let reaggregate = LocalizedString(zh: "重新聚合", en: "Re-aggregate")
    static let fieldActivitySpan = LocalizedString(zh: "活动跨度", en: "Activity span")
    static let fieldLastActivity = LocalizedString(zh: "最后活动", en: "Last activity")
    static let fieldActivityWindow = LocalizedString(zh: "活动区间", en: "Activity window")
    static let jumpToFiles = LocalizedString(zh: "在文件板块看 Diff", en: "View diffs on the Files board")
    static let jumpToTimeline = LocalizedString(zh: "在时间板块看事件", en: "View events on the Timeline board")
    static let clearSelection = LocalizedString(zh: "取消选中", en: "Clear selection")
    static let reaggregatingHint = LocalizedString(
        zh: "正在按「%@」重新聚合本项目…", en: "Re-aggregating this project for “%@”…"
    )
    static let readFailedShort = LocalizedString(zh: "读取失败", en: "Read failed")
    static let detailFileChangesCaption = LocalizedString(zh: "本项目口径 %@", en: "This project, scope %@")
    static let detailCommandsCaption = LocalizedString(
        zh: "在本项目工作目录下启动", en: "Started under this project's working directory"
    )
    static let detailSessionsCaption = LocalizedString(zh: "跨度 %@", en: "Span %@")
    static let tileRiskEvents = LocalizedString(zh: "风险事件", en: "Risk events")
    static let riskCaptionSome = LocalizedString(zh: "到安全板块逐条确认", en: "Confirm them one by one on the Security board")
    static let riskCaptionNone = LocalizedString(zh: "本范围内没有触发规则", en: "No rules fired in this range")
    static let statHotFiles = LocalizedString(zh: "热区文件", en: "Hot files")

    // MARK: 健康度行（`ProjectHealthCard` 的三个分解标签；结论句本身在 `AnalysisPresentation`）

    static let healthAnomalies = LocalizedString(zh: "检出异常", en: "Anomalies detected")
    static let healthEfficiency = LocalizedString(zh: "单位产出", en: "Output per unit")

    // MARK: 最近变更

    static let recentChangesTitle = LocalizedString(zh: "最近变更", en: "Recent changes")
    static let recentChangesSubtitle = LocalizedString(
        zh: "按当前过滤条件回查本项目文件改动",
        en: "This project's file changes, re-queried under the current filters"
    )
    static let loadingChanges = LocalizedString(zh: "正在读取文件变更…", en: "Reading file changes…")
    static let emptyChangesTitle = LocalizedString(zh: "没有匹配的变更", en: "No matching changes")
    static let emptyChangesMessage = LocalizedString(
        zh: "该项目的改动可能落在更宽的时间范围内，或已被当前 Agent / 搜索条件过滤掉。",
        en: "This project's changes may fall in a wider time range, "
            + "or the current agent / search filters removed them."
    )
    static let hitFetchCapNote = LocalizedString(
        zh: "已达单次拉取上限，到文件板块可翻页查看全部",
        en: "The single-fetch cap is reached; page through everything on the Files board"
    )
    static let emptyNoMapTitle = LocalizedString(zh: "还没有项目地图", en: "No project map yet")
    static let emptyUnselectedTitle = LocalizedString(zh: "未选择项目", en: "No project selected")
    static let emptyNoMapMessage = LocalizedString(
        zh: "引擎还没有把任何文件改动归属到项目根目录。让任意 AI Agent 改动一个文件后重试，或重新扫描。",
        en: "The engine has not attributed any file change to a project root yet. "
            + "Let any AI agent edit one file and retry, or rescan."
    )
    static let emptyUnselectedMessage = LocalizedString(
        zh: "在左侧点选一个项目，这里会展开它的热区文件、Agent 贡献占比与最近变更。",
        en: "Pick a project on the left to expand its hot files, agent share and recent changes."
    )

    // MARK: 项目卡（`ProjectCard`）

    static let a11yLiveUpdate = LocalizedString(zh: "本周期内有实时更新", en: "Updated live within this cycle")
    static let riskCountTag = LocalizedString(zh: "%d 起风险", en: "Risks: %d")
    static let cardMetrics = LocalizedString(
        zh: "变更 %1$d · 命令 %2$d · 会话 %3$d",
        en: "Changes %1$d · commands %2$d · sessions %3$d"
    )
    static let shareNoData = LocalizedString(zh: "暂无 Agent 贡献数据", en: "No agent contribution data")
    static let sharePrefix = LocalizedString(zh: "Agent 贡献占比：", en: "Agent share: ")
    /// 行摘要八个参数：名字与路径两语言都在前面，数字全部名词前置（复数没有机制）。
    static let cardA11ySummary = LocalizedString(
        zh: "项目 %1$@，路径 %2$@，文件变更 %3$d 次，命令 %4$d 次，"
            + "会话 %5$d 个，风险 %6$d 起，最后活动 %7$@。%8$@",
        en: "Project %1$@. Path %2$@. File changes %3$d. Commands %4$d. "
            + "Sessions %5$d. Risks %6$d. Last activity %7$@. %8$@"
    )

    // MARK: 热区文件榜（`ProjectHotFilesPanel`）

    static let hotFilesEmptyDefault = LocalizedString(
        zh: "本范围内还没有文件改动落到这个项目上。",
        en: "No file changes have landed on this project in this range."
    )
    static let totalChangesHint = LocalizedString(zh: "累计 %d 次改动", en: "Total: %d")
    static let emptyHotFilesTitle = LocalizedString(zh: "暂无热点文件", en: "No hot files")
    /// 英文写成 "3 more outside the top 6"：`files` 一出现就是 "1 files"（复数无机制）。
    static let notInTopHint = LocalizedString(zh: "另有 %1$d 个文件未列入前 %2$d 名",
                                              en: "%1$d more outside the top %2$d")
    static let hotFilesSortSubtitle = LocalizedString(
        zh: "按综合热度排序（改动次数 × 最近程度），条形长度为相对榜首的强度",
        en: "Ranked by composite heat (change count × recency); "
            + "bar length is strength relative to the leader"
    )
    static let rankLabel = LocalizedString(zh: "第 %d 名", en: "No. %d")
    static let sensitivePath = LocalizedString(zh: "敏感路径", en: "Sensitive path")
    static let deltaLinesA11y = LocalizedString(zh: "新增 %1$d 行，删除 %2$d 行",
                                                en: "%1$d added, %2$d removed")
    static let heatA11ySummary = LocalizedString(
        zh: "第 %1$d 名，%2$@，改动 %3$d 次，新增 %4$d 行，删除 %5$d 行，最后改动 %6$@",
        en: "Rank %1$d. Path %2$@. Changes %3$d. Added %4$d. Removed %5$d. Last change %6$@"
    )

    // MARK: 贡献图（`ProjectContributionChart`）

    static let chartTitle = LocalizedString(zh: "Agent 贡献占比", en: "Agent share of contributions")
    static let chartEmptyMessage = LocalizedString(
        zh: "该项目还没有可归属到具体 Agent 的文件变更。",
        en: "This project has no file changes attributable to a specific agent yet."
    )
    /// Swift Charts 的轴标签会进图例与 VoiceOver ⇒ 算文案（同 `DashboardCopy` 的口径）。
    static let chartAxisShare = LocalizedString(zh: "占比", en: "Share")
    static let chartOtherAgents = LocalizedString(zh: "其他 Agent", en: "Other agents")
    static let chartSubtitleHint = LocalizedString(
        zh: "%1$d 种 Agent · 合计 %2$d 次事件", en: "Agent kinds: %1$d · events: %2$d"
    )
    static let chartA11yPrefix = LocalizedString(
        zh: "Agent 贡献占比柱状图：", en: "Agent contribution bar chart: "
    )
    static let chartA11yRow = LocalizedString(zh: "%1$@ %2$@，%3$d 次",
                                              en: "%1$@ %2$@ · changes %3$d")
    static let chartLegendRow = LocalizedString(zh: "%1$@ · %2$d 次 · %3$@",
                                                en: "%1$@ · %2$d · %3$@")
    static let chartTotalChanges = LocalizedString(zh: "%d 次改动", en: "Total: %d")

    // MARK: a11y 组文案（1 条，key 前缀 a11y.*）
    static let a11yCopy: [NamedCopy] = [
        NamedCopy("projects.a11y.joiner", a11yJoiner),
    ]

    // MARK: time 组文案（4 条，key 前缀 time.*）
    static let timeCopy: [NamedCopy] = [
        NamedCopy("projects.time.justNow", timeJustNow),
        NamedCopy("projects.time.ago", timeAgo),
        NamedCopy("projects.time.daysAgo", timeDaysAgo),
        NamedCopy("projects.time.sameInstant", timeSameInstant),
    ]

    // MARK: sort 组文案（4 条，key 前缀 sort.*）
    static let sortCopy: [NamedCopy] = [
        NamedCopy("projects.sort.recent", sortRecent),
        NamedCopy("projects.sort.busiest", sortBusiest),
        NamedCopy("projects.sort.netCode", netCode),
        NamedCopy("projects.sort.riskFirst", sortRiskFirst),
    ]

    // MARK: delta 组文案（1 条，key 前缀 delta.*）
    static let deltaCopy: [NamedCopy] = [
        NamedCopy("projects.delta.detailed", deltaDetailed),
    ]

    // MARK: model 组文案（1 条，key 前缀 model.*）
    static let modelCopy: [NamedCopy] = [
        NamedCopy("projects.model.detailNoDataError", detailNoDataError),
    ]

    // MARK: page 组文案（2 条，key 前缀 page.*）
    static let pageCopy: [NamedCopy] = [
        NamedCopy("projects.page.subtitle", pageSubtitle),
        NamedCopy("projects.page.statLatestActivity", statLatestActivity),
    ]

    // MARK: tile 组文案（9 条，key 前缀 tile.*）
    static let tileCopy: [NamedCopy] = [
        NamedCopy("projects.tile.visibleProjects", tileVisibleProjects),
        NamedCopy("projects.tile.visibleProjectsCaption", tileVisibleProjectsCaption),
        NamedCopy("projects.tile.fileChanges", tileFileChanges),
        NamedCopy("projects.tile.fileChangesCaption", tileFileChangesCaption),
        NamedCopy("projects.tile.commands", tileCommands),
        NamedCopy("projects.tile.commandsCaption", tileCommandsCaption),
        NamedCopy("projects.tile.sessions", tileSessions),
        NamedCopy("projects.tile.sessionsCaption", tileSessionsCaption),
        NamedCopy("projects.tile.riskEvents", tileRiskEvents),
    ]

    // MARK: stat 组文案（4 条，key 前缀 stat.*）
    static let statCopy: [NamedCopy] = [
        NamedCopy("projects.stat.liveHits", statLiveHits),
        NamedCopy("projects.stat.liveHitValue", liveHitValue),
        NamedCopy("projects.stat.liveHitNone", liveHitNone),
        NamedCopy("projects.stat.hotFiles", statHotFiles),
    ]

    // MARK: health 组文案（2 条，key 前缀 health.*）
    static let healthCopy: [NamedCopy] = [
        NamedCopy("projects.health.anomalies", healthAnomalies),
        NamedCopy("projects.health.efficiency", healthEfficiency),
    ]

    // MARK: stat2 组文案（1 条，key 前缀 stat.*）
    static let stat2Copy: [NamedCopy] = [
        NamedCopy("projects.stat.riskTag", riskTag),
    ]

    // MARK: state 组文案（3 条，key 前缀 state.*）
    static let stateCopy: [NamedCopy] = [
        NamedCopy("projects.state.loadingDetailRow", loadingDetailRow),
        NamedCopy("projects.state.loadingAggregating", loadingAggregating),
        NamedCopy("projects.state.loadingFirstHint", loadingFirstHint),
    ]

    // MARK: empty 组文案（6 条，key 前缀 empty.*）
    static let emptyCopy: [NamedCopy] = [
        NamedCopy("projects.empty.noActivityTitle", emptyNoActivityTitle),
        NamedCopy("projects.empty.noActivityMessage", emptyNoActivityMessage),
        NamedCopy("projects.empty.rescan", rescan),
        NamedCopy("projects.empty.filteredTitle", emptyFilteredTitle),
        NamedCopy("projects.empty.filteredMessage", emptyFilteredMessage),
        NamedCopy("projects.empty.resetFilters", resetFilters),
    ]

    // MARK: error 组文案（2 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        NamedCopy("projects.error.readFailedTitle", readFailedTitle),
        NamedCopy("projects.error.retry", retry),
    ]

    // MARK: filterBar 组文案（10 条，key 前缀 filterBar.*）
    static let filterBarCopy: [NamedCopy] = [
        NamedCopy("projects.filterBar.timeRange", timeRange),
        NamedCopy("projects.filterBar.allAgents", allAgents),
        NamedCopy("projects.filterBar.a11yAgentFilter", a11yAgentFilter),
        NamedCopy("projects.filterBar.a11ySortMode", a11ySortMode),
        NamedCopy("projects.filterBar.searchPrompt", searchPrompt),
        NamedCopy("projects.filterBar.a11yClearSearch", a11yClearSearch),
        NamedCopy("projects.filterBar.reset", reset),
        NamedCopy("projects.filterBar.liveUpdatingTag", liveUpdatingTag),
        NamedCopy("projects.filterBar.subscribedTag", subscribedTag),
        NamedCopy("projects.filterBar.agentKindCount", agentKindCount),
    ]

    // MARK: overview 组文案（7 条，key 前缀 overview.*）
    static let overviewCopy: [NamedCopy] = [
        NamedCopy("projects.overview.title", overviewTitle),
        NamedCopy("projects.overview.subtitle", overviewSubtitle),
        NamedCopy("projects.overview.chartTitle", overviewChartTitle),
        NamedCopy("projects.overview.chartSubtitle", overviewChartSubtitle),
        NamedCopy("projects.overview.globalHotFilesTitle", globalHotFilesTitle),
        NamedCopy("projects.overview.globalHotFilesSubtitle", globalHotFilesSubtitle),
        NamedCopy("projects.overview.globalHotFilesEmpty", globalHotFilesEmpty),
    ]

    // MARK: detail 组文案（19 条，key 前缀 detail.*）
    static let detailCopy: [NamedCopy] = [
        NamedCopy("projects.detail.chartSubtitle", detailChartSubtitle),
        NamedCopy("projects.detail.hotFilesTitle", detailHotFilesTitle),
        NamedCopy("projects.detail.hotFilesEmpty", detailHotFilesEmpty),
        NamedCopy("projects.detail.mapSubtitle", detailMapSubtitle),
        NamedCopy("projects.detail.liveTag", liveTag),
        NamedCopy("projects.detail.reaggregate", reaggregate),
        NamedCopy("projects.detail.fieldActivitySpan", fieldActivitySpan),
        NamedCopy("projects.detail.fieldLastActivity", fieldLastActivity),
        NamedCopy("projects.detail.fieldActivityWindow", fieldActivityWindow),
        NamedCopy("projects.detail.jumpToFiles", jumpToFiles),
        NamedCopy("projects.detail.jumpToTimeline", jumpToTimeline),
        NamedCopy("projects.detail.clearSelection", clearSelection),
        NamedCopy("projects.detail.reaggregatingHint", reaggregatingHint),
        NamedCopy("projects.detail.readFailedShort", readFailedShort),
        NamedCopy("projects.detail.fileChangesCaption", detailFileChangesCaption),
        NamedCopy("projects.detail.commandsCaption", detailCommandsCaption),
        NamedCopy("projects.detail.sessionsCaption", detailSessionsCaption),
        NamedCopy("projects.detail.riskCaptionSome", riskCaptionSome),
        NamedCopy("projects.detail.riskCaptionNone", riskCaptionNone),
    ]

    // MARK: recent 组文案（10 条，key 前缀 recent.*）
    static let recentCopy: [NamedCopy] = [
        NamedCopy("projects.recent.title", recentChangesTitle),
        NamedCopy("projects.recent.subtitle", recentChangesSubtitle),
        NamedCopy("projects.recent.loadingChanges", loadingChanges),
        NamedCopy("projects.recent.emptyTitle", emptyChangesTitle),
        NamedCopy("projects.recent.emptyMessage", emptyChangesMessage),
        NamedCopy("projects.recent.hitFetchCapNote", hitFetchCapNote),
        NamedCopy("projects.recent.emptyNoMapTitle", emptyNoMapTitle),
        NamedCopy("projects.recent.emptyUnselectedTitle", emptyUnselectedTitle),
        NamedCopy("projects.recent.emptyNoMapMessage", emptyNoMapMessage),
        NamedCopy("projects.recent.emptyUnselectedMessage", emptyUnselectedMessage),
    ]

    // MARK: card 组文案（6 条，key 前缀 card.*）
    static let cardCopy: [NamedCopy] = [
        NamedCopy("projects.card.a11yLiveUpdate", a11yLiveUpdate),
        NamedCopy("projects.card.riskCountTag", riskCountTag),
        NamedCopy("projects.card.metrics", cardMetrics),
        NamedCopy("projects.card.shareNoData", shareNoData),
        NamedCopy("projects.card.sharePrefix", sharePrefix),
        NamedCopy("projects.card.a11ySummary", cardA11ySummary),
    ]

    // MARK: hotFiles 组文案（9 条，key 前缀 hotFiles.*）
    static let hotFilesCopy: [NamedCopy] = [
        NamedCopy("projects.hotFiles.emptyDefault", hotFilesEmptyDefault),
        NamedCopy("projects.hotFiles.totalChangesHint", totalChangesHint),
        NamedCopy("projects.hotFiles.emptyTitle", emptyHotFilesTitle),
        NamedCopy("projects.hotFiles.notInTopHint", notInTopHint),
        NamedCopy("projects.hotFiles.sortSubtitle", hotFilesSortSubtitle),
        NamedCopy("projects.hotFiles.rankLabel", rankLabel),
        NamedCopy("projects.hotFiles.sensitivePath", sensitivePath),
        NamedCopy("projects.hotFiles.deltaLinesA11y", deltaLinesA11y),
        NamedCopy("projects.hotFiles.a11ySummary", heatA11ySummary),
    ]

    // MARK: chart 组文案（9 条，key 前缀 chart.*）
    static let chartCopy: [NamedCopy] = [
        NamedCopy("projects.chart.title", chartTitle),
        NamedCopy("projects.chart.emptyMessage", chartEmptyMessage),
        NamedCopy("projects.chart.axisShare", chartAxisShare),
        NamedCopy("projects.chart.otherAgents", chartOtherAgents),
        NamedCopy("projects.chart.subtitleHint", chartSubtitleHint),
        NamedCopy("projects.chart.a11yPrefix", chartA11yPrefix),
        NamedCopy("projects.chart.a11yRow", chartA11yRow),
        NamedCopy("projects.chart.legendRow", chartLegendRow),
        NamedCopy("projects.chart.totalChanges", chartTotalChanges),
    ]

    /// 本目录全部用户可见文案。**门禁用例遍历它断言 `copyProblems` 为空**，
    /// 并钉住「声明处数 == 清单条数」⇒ 一条文案只列一次：
    /// `netCode`（排序口径 + 两处字段标签）与 `timeRange`（过滤条读屏标签 + 详情字段标签）
    /// 语义同源，所以只挂一个名字，重复列会把另一条同名值从门禁里挤出去。
    static let bilingualCopy: [NamedCopy] =
        a11yCopy
        + timeCopy
        + sortCopy
        + deltaCopy
        + modelCopy
        + pageCopy
        + tileCopy
        + statCopy
        + healthCopy
        + stat2Copy
        + stateCopy
        + emptyCopy
        + errorCopy
        + filterBarCopy
        + overviewCopy
        + detailCopy
        + recentCopy
        + cardCopy
        + hotFilesCopy
        + chartCopy

}
