//
//  TimelineCopy.swift
//  AIObservatoryUI / Timeline
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  时间线页全部**用户可见**文案（含 VoiceOver 读到的 `.accessibilityLabel`），
//  按 IFR 裁定 3(a) 集中声明成一份 `bilingualCopy`，门禁见 `TimelineBilingualCopyGateTests`。
//
//  口径与 `ShellCopy` 完全一致（三条：只迁进眼睛/读屏的字、中文侧逐字不动、多参数用
//  `%1$@`/`%2$d`），这里不重复。语言在 `UILanguage.current` 一处解析。
//
//  【一条只有读屏才知道的账】`accessibilitySummary` 用「，」把八段拼成一句。
//  它不在任何汉字扫描的射程里（分隔符自己没有汉字），但 VoiceOver 在英文态会把它念成
//  带全角停顿的混排。所以分隔符也算文案，跟着语言走（同 `InsightCopy` 的连接符）。
//

import Foundation
import AIObservatoryCore

/// 时间线页的用户可见文案表（B3）。
enum TimelineCopy {

    // MARK: 行密度档位

    static let densityComfortable = LocalizedString(zh: "舒适", en: "Comfortable")
    static let densityCompact = LocalizedString(zh: "紧凑", en: "Compact")

    // MARK: 事件行（含读屏）

    static let exitSucceeded = LocalizedString(zh: "命令成功退出", en: "Command exited successfully")
    static let exitFailed = LocalizedString(zh: "命令以退出码 %1$d 失败",
                                            en: "Command failed with exit code %1$d")
    static let a11yCommand = LocalizedString(zh: "命令 %@", en: "Command %@")
    static let a11yExitCode = LocalizedString(zh: "退出码 %1$d", en: "Exit code %1$d")
    static let a11yDuration = LocalizedString(zh: "耗时 %@", en: "Took %@")
    static let a11yRisk = LocalizedString(zh: "风险 %@", en: "Risk %@")
    /// 读屏那一句的分段符：中文全角逗号、英文半角，英文里全角逗号会被念成一个停顿。
    static let a11yJoiner = LocalizedString(zh: "，", en: ", ")

    // MARK: 载入进度（`TimelineModel.loadedProgressText`）

    /// 「已加载 n / 共 N」：分子是本页已加载、分母是服务端总数，两个数是**不同口径**，
    /// 所以这一句不许在英文里缩成一个含糊的 "n/N"。
    /// ⚠️ 顺序按位置参数写死：英文把"of"放在中间，裸 `%d` 会把分子分母念反。
    static let loadedProgress = LocalizedString(zh: "已加载 %1$d / 共 %2$d", en: "Loaded %1$d of %2$d")

    // MARK: 过滤控件（`TimelineFilterControls`）

    static let filterGroupLabel = LocalizedString(zh: "时间线过滤器", en: "Timeline filters")
    static let filterSearchPrompt = LocalizedString(zh: "搜索标题、摘要、路径或命令",
                                                    en: "Search titles, paths or commands")
    static let filterClearSearch = LocalizedString(zh: "清空搜索", en: "Clear search")
    /// tooltip 里的 `EventQuery.dateRange` 是**代码标识符**，不译（HIG：不要把符号名翻成英文单词，
    /// 用户拿它去搜代码/问客服时才对得上）。
    static let filterTimeRangeHelp = LocalizedString(zh: "时间范围 → EventQuery.dateRange",
                                                     en: "Time range → EventQuery.dateRange")
    static let filterTimeRange = LocalizedString(zh: "时间范围", en: "Time range")
    static let filterMenu = LocalizedString(zh: "筛选", en: "Filter")
    static let filterMenuHelp = LocalizedString(zh: "Agent / 操作类型 / 只看风险 / 重置 → EventQuery",
                                                en: "Agents / action types / high risks / reset → EventQuery")
    static let filterBadgeCount = LocalizedString(zh: "%1$d 项筛选生效", en: "%1$d active")
    static let filterMenuLabel = LocalizedString(zh: "筛选条件，生效 %1$d 项",
                                                 en: "Filters, %1$d active")
    static let filterAllAgents = LocalizedString(zh: "全部 Agent", en: "All agents")
    static let filterAgentCount = LocalizedString(zh: "%1$d 个 Agent", en: "%1$d agents")
    static let filterAgentFallback = LocalizedString(zh: "Agent", en: "Agent")
    static let filterAllKinds = LocalizedString(zh: "全部操作", en: "All actions")
    static let filterKindCount = LocalizedString(zh: "%1$d 类操作", en: "%1$d action types")
    static let filterKindFallback = LocalizedString(zh: "操作", en: "Action")
    static let filterRiskOnly = LocalizedString(zh: "只看风险 ≥ HIGH", en: "High risks only")
    static let filterRiskOnlyHelp = LocalizedString(zh: "只保留 HIGH 及以上风险事件 → EventQuery.minimumRisk",
                                                    en: "Keeps only HIGH-and-above risk events → EventQuery.minimumRisk")
    static let filterReset = LocalizedString(zh: "重置筛选", en: "Reset filters")
    static let filterResetHelp = LocalizedString(zh: "清空全部过滤条件（含时间范围回到「全部」）",
                                                 en: "Clears every filter (the time range goes back to All)")

    // MARK: 事件详情（inspector）

    static let detailTitle = LocalizedString(zh: "事件详情", en: "Event detail")
    static let detailClose = LocalizedString(zh: "关闭", en: "Close")
    static let detailCloseA11y = LocalizedString(zh: "关闭事件详情", en: "Close event detail")
    static let detailTimeLabel = LocalizedString(zh: "时间", en: "Time")
    static let detailKindLabel = LocalizedString(zh: "类型", en: "Action")
    static let detailDurationLabel = LocalizedString(zh: "时长", en: "Duration")
    static let detailExitCodeLabel = LocalizedString(zh: "退出码", en: "Exit code")
    static let detailProjectLabel = LocalizedString(zh: "项目", en: "Project")
    /// 退出码为 nil = 引擎还没回填，不是"没有退出码这件事"。这句在两种语言里都必须说明白，
    /// 不能缩成 "—"（那是本仓反复犯过的"用符号代替口径"）。
    static let detailExitCodeUnfilled = LocalizedString(zh: "未回填", en: "not reported yet")
    static let detailExitCodeZero = LocalizedString(zh: "0（成功）", en: "0 (succeeded)")
    static let detailExitCodeFailed = LocalizedString(zh: "%1$d（失败）", en: "%1$d (failed)")
    static let detailCommandTitle = LocalizedString(zh: "执行的命令", en: "Command run")
    static let detailFilePathTitle = LocalizedString(zh: "涉及文件", en: "File involved")
    static let detailSensitivePathTag = LocalizedString(zh: "敏感路径", en: "Sensitive path")
    /// #81 的取证出口：中文点明「这一类 / 这条」，因为跳过去之后结果集真的被筛小了，
    /// 措辞含糊就等于让目的地板块替用户重新猜一遍自己看到的是什么。
    static let detailJumpToFileChanges = LocalizedString(zh: "在文件板块看这一类变更",
                                                        en: "See this change kind on the Files board")
    static let detailJumpToSession = LocalizedString(zh: "看这条会话", en: "See this session")
    static let detailCostTitle = LocalizedString(zh: "资源开销", en: "Resource cost")
    static let detailCostSubtitle = LocalizedString(zh: "该事件被观测到的进程开销快照",
                                                    en: "Process overhead captured for this event")
    static let detailCPUTimeLabel = LocalizedString(zh: "CPU 时间", en: "CPU time")
    static let detailMemoryLabel = LocalizedString(zh: "内存", en: "Memory")
    static let detailReadLabel = LocalizedString(zh: "读取", en: "Read")
    static let detailWriteLabel = LocalizedString(zh: "写入", en: "Written")
    /// 「没采到」≠「真的是 0」：这句是那一格的诚实口径，英文同样不许缩水。
    static let detailZeroCostNote = LocalizedString(
        zh: "四项全为 0：这条事件没有采到开销样本，不等于它没有消耗。",
        en: "All four are 0: no cost sample was captured for this event, which is not the same as it costing nothing."
    )
    static let detailSessionTitle = LocalizedString(zh: "会话 / Agent 实例", en: "Session / agent instance")
    static let copyAction = LocalizedString(zh: "复制", en: "Copy")
    static let copySucceeded = LocalizedString(zh: "已复制", en: "Copied")
    static let copyFailed = LocalizedString(zh: "复制失败", en: "Copy failed")

    // MARK: 量词（英文没有对应物，所以**不进表**）

    /// 中文的"176 条 / 3 处 / 5 类"在英文里就是"176 / 3 / 5"——量词不翻译，翻成
    /// "176 items" 会和卡片标题里的同一个名词排两遍。
    ///
    /// ⚠️ 为什么不写成 `LocalizedString(zh: "条", en: "")`：`englishEmpty` 是门禁刻意用来
    /// 抓"没译"的，而这里的英文侧**本来就该是空**，两者会被混成一类，下一个人只会去补一个
    /// 假名词把门禁喂绿。所以量词单独走这个函数，中文侧的字面量留在本文件（门禁②把
    /// 文案表所在文件整文件排除，这是四目录共同的口径）。
    static func measureWord(_ chinese: String, _ language: AppLanguage) -> String {
        language == .chineseSimplified ? chinese : ""
    }

    /// 三个量词各一个具名展口（字面量留在本文件，理由见上）。
    static func unitItems(_ language: AppLanguage) -> String { measureWord("条", language) }
    static func unitLocations(_ language: AppLanguage) -> String { measureWord("处", language) }
    static func unitTypes(_ language: AppLanguage) -> String { measureWord("类", language) }

    // MARK: 页面骨架（`TimelineView`）

    static let pageSubtitle = LocalizedString(zh: "范围：%1$@ · 每次载入 %2$d 条",
                                              en: "Range: %1$@ · %2$d loaded per page")
    static let noSelectionTitle = LocalizedString(zh: "没有选中事件", en: "No event selected")
    static let noSelectionMessage = LocalizedString(zh: "在事件流里点一条记录，完整字段会出现在这一列。",
                                                    en: "Click a record in the stream and its full fields appear here.")
    static let heroTitle = LocalizedString(zh: "行为事件总数", en: "Total behaviour events")
    static let daysCoveredLabel = LocalizedString(zh: "覆盖天数", en: "Days covered")
    static let daysCoveredValue = LocalizedString(zh: "%1$d 天", en: "%1$d")
    static let filterCountLabel = LocalizedString(zh: "筛选条件", en: "Filters")
    static let filterCountValue = LocalizedString(zh: "%1$d 项生效", en: "%1$d active")
    static let metricsTitle = LocalizedString(zh: "本页读数", en: "On this page")
    static let metricsSubtitle = LocalizedString(zh: "以下六项只统计本页已加载的事件，不是服务端总数",
                                                 en: "These six cover only the events loaded on this page, not the server total")

    // MARK: 六个次级读数

    static let riskTileTitle = LocalizedString(zh: "风险事件", en: "Risk events")
    static let riskTileCaption = LocalizedString(zh: "风险 ≥ medium 的条数，其中 critical %1$d 条",
                                                 en: "Events rated medium or higher, %1$d of them critical")
    static let busiestTileTitle = LocalizedString(zh: "最活跃时段", en: "Busiest hour")
    static let busiestTileUnit = LocalizedString(zh: "%1$d 条", en: "%1$d logged")
    static let busiestTileCaption = LocalizedString(zh: "按整点小时分桶最密的一格，不代表全库最忙时段",
                                                    en: "The densest hour bucket here, not the busiest hour overall")
    static let busiestTileEmptyCaption = LocalizedString(zh: "本页还没有事件可分桶",
                                                         en: "No events on this page to bucket yet")
    static let commandTileTitle = LocalizedString(zh: "命令执行", en: "Commands run")
    static let commandTileCaption = LocalizedString(
        zh: "本页加载到的执行命令，失败 %1$d 条（退出码非 0，未回填的不计）",
        en: "Commands captured on this page, %1$d failed (non-zero exit code; ones not yet reported are excluded)"
    )
    static let fileTileTitle = LocalizedString(zh: "文件变更", en: "File changes")
    static let fileTileCaption = LocalizedString(
        zh: "创建 / 修改 / 删除 / 重命名合计，其中删除 %1$d 处",
        en: "Added, edited, deleted and renamed combined, %1$d of them deletions"
    )
    static let agentTileTitle = LocalizedString(zh: "涉及 Agent", en: "Agents seen")
    static let agentTileCaption = LocalizedString(
        zh: "出现过的 Agent 类型数，按类型去重（不是实例数）",
        en: "Distinct agent types seen, deduplicated by type rather than by instance"
    )
    static let spanTileTitle = LocalizedString(zh: "已加载跨度", en: "Loaded span")
    static let spanTileCaptionPaged = LocalizedString(zh: "最早与最晚一条之间的间隔，更早的要翻页",
                                                      en: "Interval between the earliest and latest event here; earlier ones need another page")
    static let spanTileCaptionAll = LocalizedString(zh: "最早与最晚一条之间的间隔（本页已含全部）",
                                                    en: "Interval between the earliest and latest event (this page holds them all)")

    // MARK: 事件流、分组与翻页

    static let streamTitle = LocalizedString(zh: "事件流", en: "Event stream")
    static let streamSubtitle = LocalizedString(zh: "按天分组 · %1$@ · 每组只列已加载的事件",
                                                en: "Grouped by day · %@ · each group lists only loaded events")
    static let dayGroupCount = LocalizedString(zh: "%1$d 条", en: "%1$d logged")
    static let dayRiskCount = LocalizedString(zh: "%1$d 条风险", en: "%1$d risky")
    static let dayToday = LocalizedString(zh: "今天", en: "Today")
    static let dayYesterday = LocalizedString(zh: "昨天", en: "Yesterday")
    static let dayEarlier = LocalizedString(zh: "更早", en: "Earlier")
    static let dayUnknown = LocalizedString(zh: "日期", en: "Date")
    static let loadingEarlier = LocalizedString(zh: "正在载入更早的事件…", en: "Loading earlier events…")
    static let loadEarlier = LocalizedString(zh: "载入更早", en: "Load earlier")
    static let reachedOldest = LocalizedString(zh: "已到最早事件", en: "Reached the earliest event")

    // MARK: 密度选择器

    static let densityLabel = LocalizedString(zh: "密度", en: "Density")
    static let densityHelp = LocalizedString(
        zh: "行密度：只调节行尾元信息的多寡，事件行恒为一行",
        en: "Row density: changes only how much trailing metadata a row carries; an event row is always one line"
    )
    static let densityA11yLabel = LocalizedString(zh: "事件流密度", en: "Event stream density")

    // MARK: 加载 / 空 / 错误

    static let loadingTitle = LocalizedString(zh: "正在读取时间线…", en: "Reading the timeline…")
    static let loadingNote = LocalizedString(
        zh: "首次进入会按当前范围取首页 %1$d 条，之后由引擎增量推流。",
        en: "The first visit loads the newest %1$d events for the current range; after that the engine pushes increments."
    )
    static let emptyTitle = LocalizedString(zh: "暂无匹配的行为事件", en: "No matching events")
    static let emptyFilteredMessage = LocalizedString(
        zh: "当前筛选条件下没有事件（服务端匹配 %1$d 条），试试放宽条件。",
        en: "No events match the current filters (%1$d matched on the server). Try widening them."
    )
    static let emptyNoDataMessage = LocalizedString(
        zh: "观测引擎尚未捕获到 AI Agent 行为。启动引擎后，事件会实时出现在这里。",
        en: "The observatory engine has not captured any AI agent behaviour yet. Start it and events appear here live."
    )
    static let resetFilters = LocalizedString(zh: "重置筛选", en: "Reset filters")
    static let errorTitle = LocalizedString(zh: "时间线读取失败", en: "Timeline read failed")
    static let retry = LocalizedString(zh: "重试", en: "Retry")

    // MARK: - 集中清单（门禁遍历这一份）

    // MARK: density 组文案（2 条，key 前缀 density.*）
    static let densityCopy: [NamedCopy] = [
        NamedCopy("timeline.density.comfortable", densityComfortable),
        NamedCopy("timeline.density.compact", densityCompact),
    ]

    // MARK: row 组文案（7 条，key 前缀 row.*）
    static let rowCopy: [NamedCopy] = [
        NamedCopy("timeline.row.exitSucceeded", exitSucceeded),
        NamedCopy("timeline.row.exitFailed", exitFailed),
        NamedCopy("timeline.row.a11yCommand", a11yCommand),
        NamedCopy("timeline.row.a11yExitCode", a11yExitCode),
        NamedCopy("timeline.row.a11yDuration", a11yDuration),
        NamedCopy("timeline.row.a11yRisk", a11yRisk),
        NamedCopy("timeline.row.a11yJoiner", a11yJoiner),
    ]

    // MARK: misc 组文案（1 条，key 前缀 misc.*）
    static let miscCopy: [NamedCopy] = [
        NamedCopy("timeline.loadedProgress", loadedProgress),
    ]

    // MARK: filter 组文案（19 条，key 前缀 filter.*）
    static let filterCopy: [NamedCopy] = [
        NamedCopy("timeline.filter.groupLabel", filterGroupLabel),
        NamedCopy("timeline.filter.searchPrompt", filterSearchPrompt),
        NamedCopy("timeline.filter.clearSearch", filterClearSearch),
        NamedCopy("timeline.filter.timeRangeHelp", filterTimeRangeHelp),
        NamedCopy("timeline.filter.timeRange", filterTimeRange),
        NamedCopy("timeline.filter.menu", filterMenu),
        NamedCopy("timeline.filter.menuHelp", filterMenuHelp),
        NamedCopy("timeline.filter.badgeCount", filterBadgeCount),
        NamedCopy("timeline.filter.menuLabel", filterMenuLabel),
        NamedCopy("timeline.filter.allAgents", filterAllAgents),
        NamedCopy("timeline.filter.agentCount", filterAgentCount),
        NamedCopy("timeline.filter.agentFallback", filterAgentFallback),
        NamedCopy("timeline.filter.allKinds", filterAllKinds),
        NamedCopy("timeline.filter.kindCount", filterKindCount),
        NamedCopy("timeline.filter.kindFallback", filterKindFallback),
        NamedCopy("timeline.filter.riskOnly", filterRiskOnly),
        NamedCopy("timeline.filter.riskOnlyHelp", filterRiskOnlyHelp),
        NamedCopy("timeline.filter.reset", filterReset),
        NamedCopy("timeline.filter.resetHelp", filterResetHelp),
    ]

    // MARK: detail 组文案（22 条，key 前缀 detail.*）
    static let detailCopy: [NamedCopy] = [
        NamedCopy("timeline.detail.title", detailTitle),
        NamedCopy("timeline.detail.close", detailClose),
        NamedCopy("timeline.detail.closeA11y", detailCloseA11y),
        NamedCopy("timeline.detail.timeLabel", detailTimeLabel),
        NamedCopy("timeline.detail.kindLabel", detailKindLabel),
        NamedCopy("timeline.detail.durationLabel", detailDurationLabel),
        NamedCopy("timeline.detail.exitCodeLabel", detailExitCodeLabel),
        NamedCopy("timeline.detail.projectLabel", detailProjectLabel),
        NamedCopy("timeline.detail.exitCodeUnfilled", detailExitCodeUnfilled),
        NamedCopy("timeline.detail.exitCodeZero", detailExitCodeZero),
        NamedCopy("timeline.detail.exitCodeFailed", detailExitCodeFailed),
        NamedCopy("timeline.detail.commandTitle", detailCommandTitle),
        NamedCopy("timeline.detail.filePathTitle", detailFilePathTitle),
        NamedCopy("timeline.detail.sensitivePathTag", detailSensitivePathTag),
        NamedCopy("timeline.detail.jumpToFileChanges", detailJumpToFileChanges),
        NamedCopy("timeline.detail.jumpToSession", detailJumpToSession),
        NamedCopy("timeline.detail.costTitle", detailCostTitle),
        NamedCopy("timeline.detail.costSubtitle", detailCostSubtitle),
        NamedCopy("timeline.detail.cpuTimeLabel", detailCPUTimeLabel),
        NamedCopy("timeline.detail.memoryLabel", detailMemoryLabel),
        NamedCopy("timeline.detail.readLabel", detailReadLabel),
        NamedCopy("timeline.detail.writeLabel", detailWriteLabel),
        NamedCopy("timeline.detail.zeroCostNote", detailZeroCostNote),
        NamedCopy("timeline.detail.sessionTitle", detailSessionTitle),
    ]

    // MARK: copy 组文案（3 条，key 前缀 copy.*）
    static let copyCopy: [NamedCopy] = [
        NamedCopy("timeline.copy.action", copyAction),
        NamedCopy("timeline.copy.succeeded", copySucceeded),
        NamedCopy("timeline.copy.failed", copyFailed),
    ]

    // MARK: page 组文案（3 条，key 前缀 page.*）
    static let pageCopy: [NamedCopy] = [
        NamedCopy("timeline.page.subtitle", pageSubtitle),
        NamedCopy("timeline.page.noSelectionTitle", noSelectionTitle),
        NamedCopy("timeline.page.noSelectionMessage", noSelectionMessage),
    ]

    // MARK: hero 组文案（1 条，key 前缀 hero.*）
    static let heroCopy: [NamedCopy] = [
        NamedCopy("timeline.hero.title", heroTitle),
    ]

    // MARK: stat 组文案（4 条，key 前缀 stat.*）
    static let statCopy: [NamedCopy] = [
        NamedCopy("timeline.stat.daysCoveredLabel", daysCoveredLabel),
        NamedCopy("timeline.stat.daysCoveredValue", daysCoveredValue),
        NamedCopy("timeline.stat.filterCountLabel", filterCountLabel),
        NamedCopy("timeline.stat.filterCountValue", filterCountValue),
    ]

    // MARK: metrics 组文案（2 条，key 前缀 metrics.*）
    static let metricsCopy: [NamedCopy] = [
        NamedCopy("timeline.metrics.title", metricsTitle),
        NamedCopy("timeline.metrics.subtitle", metricsSubtitle),
    ]

    // MARK: tile 组文案（15 条，key 前缀 tile.*）
    static let tileCopy: [NamedCopy] = [
        NamedCopy("timeline.tile.riskTitle", riskTileTitle),
        NamedCopy("timeline.tile.riskCaption", riskTileCaption),
        NamedCopy("timeline.tile.busiestTitle", busiestTileTitle),
        NamedCopy("timeline.tile.busiestUnit", busiestTileUnit),
        NamedCopy("timeline.tile.busiestCaption", busiestTileCaption),
        NamedCopy("timeline.tile.busiestEmptyCaption", busiestTileEmptyCaption),
        NamedCopy("timeline.tile.commandTitle", commandTileTitle),
        NamedCopy("timeline.tile.commandCaption", commandTileCaption),
        NamedCopy("timeline.tile.fileTitle", fileTileTitle),
        NamedCopy("timeline.tile.fileCaption", fileTileCaption),
        NamedCopy("timeline.tile.agentTitle", agentTileTitle),
        NamedCopy("timeline.tile.agentCaption", agentTileCaption),
        NamedCopy("timeline.tile.spanTitle", spanTileTitle),
        NamedCopy("timeline.tile.spanCaptionPaged", spanTileCaptionPaged),
        NamedCopy("timeline.tile.spanCaptionAll", spanTileCaptionAll),
    ]

    // MARK: stream 组文案（2 条，key 前缀 stream.*）
    static let streamCopy: [NamedCopy] = [
        NamedCopy("timeline.stream.title", streamTitle),
        NamedCopy("timeline.stream.subtitle", streamSubtitle),
    ]

    // MARK: day 组文案（6 条，key 前缀 day.*）
    static let dayCopy: [NamedCopy] = [
        NamedCopy("timeline.day.groupCount", dayGroupCount),
        NamedCopy("timeline.day.riskCount", dayRiskCount),
        NamedCopy("timeline.day.today", dayToday),
        NamedCopy("timeline.day.yesterday", dayYesterday),
        NamedCopy("timeline.day.earlier", dayEarlier),
        NamedCopy("timeline.day.unknown", dayUnknown),
    ]

    // MARK: page2 组文案（3 条，key 前缀 page.*）
    static let page2Copy: [NamedCopy] = [
        NamedCopy("timeline.page.loadingEarlier", loadingEarlier),
        NamedCopy("timeline.page.loadEarlier", loadEarlier),
        NamedCopy("timeline.page.reachedOldest", reachedOldest),
    ]

    // MARK: density2 组文案（3 条，key 前缀 density.*）
    static let density2Copy: [NamedCopy] = [
        NamedCopy("timeline.density.label", densityLabel),
        NamedCopy("timeline.density.help", densityHelp),
        NamedCopy("timeline.density.a11yLabel", densityA11yLabel),
    ]

    // MARK: loading 组文案（2 条，key 前缀 loading.*）
    static let loadingCopy: [NamedCopy] = [
        NamedCopy("timeline.loading.title", loadingTitle),
        NamedCopy("timeline.loading.note", loadingNote),
    ]

    // MARK: empty 组文案（4 条，key 前缀 empty.*）
    static let emptyCopy: [NamedCopy] = [
        NamedCopy("timeline.empty.title", emptyTitle),
        NamedCopy("timeline.empty.filteredMessage", emptyFilteredMessage),
        NamedCopy("timeline.empty.noDataMessage", emptyNoDataMessage),
        NamedCopy("timeline.empty.resetFilters", resetFilters),
    ]

    // MARK: error 组文案（2 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        NamedCopy("timeline.error.title", errorTitle),
        NamedCopy("timeline.error.retry", retry),
    ]

    static let bilingualCopy: [NamedCopy] =
        densityCopy
        + rowCopy
        + miscCopy
        + filterCopy
        + detailCopy
        + copyCopy
        + pageCopy
        + heroCopy
        + statCopy
        + metricsCopy
        + tileCopy
        + streamCopy
        + dayCopy
        + page2Copy
        + density2Copy
        + loadingCopy
        + emptyCopy
        + errorCopy

}
