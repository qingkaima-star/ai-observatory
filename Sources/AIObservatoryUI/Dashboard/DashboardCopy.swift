//
//  DashboardCopy.swift
//  AIObservatoryUI / Dashboard
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  今日概览页全部用户可见文案（含 Swift Charts 的 `.value(...)` 轴标签与读屏拼句）。
//  形状与 `SessionsCopy` 同一份式：每条**直接声明成 `NamedCopy`**（名字写在常量行上），
//  清单 `bilingualCopy` 只列标识符；漏列由门禁③ `everyDeclaredEntryIsListed` 数处数堵住。
//  三条迁移口径（只迁进眼睛的字 / 中文侧逐字不动 / 多参数 %1$@/%2$d）见 `ShellCopy` 文件头。
//
//  【为什么 Charts 的 `.value("秒数", …)` 也算文案】那个标签会进图例与 VoiceOver 的
//  图元描述（不是 key）；英文态留着"秒数"就是半截中文上屏。轴的单位一律走表。
//
//  ⚠️ 与 Shell/Timeline 同样的语言残留交回：`agent.displayName` / `detectedVia.displayName` /
//  `finding.severity.displayName` 等来自 Core 与 Insights 的枚举名仍是中文。
//

import Foundation
import AIObservatoryCore

/// 今日概览页的用户可见文案表。
enum DashboardCopy {

    // MARK: 活跃 Agent 卡（`DashboardActiveAgentsList`）

    static let agentsTitle = NamedCopy("dashboard.agents.title",
                                       LocalizedString(zh: "当前运行中的 Agent", en: "Agents running now"))
    /// 卡片的**口径句**（不带数）：数只在「当前状态」那一格出现一次（#85）。
    /// 空与非空两档都用它——"引擎正在轮询进程表"在两档下都是真话，
    /// 而旧版在非空时改成"%1$d 个进程正在被观测"，那个数与上面那格的读数**是同一个数**
    /// （两处都取 `activeAgents`），于是首屏同一个数印了两遍、还换了个名字。
    static let agentsPolling = NamedCopy("dashboard.agents.polling",
                                         LocalizedString(zh: "引擎正在轮询进程表", en: "The engine is polling the process table"))
    /// 「当前状态」格的副标题：读数本身是全表快照，就必须写明它**不随所选区间变**（#75 裁定 3）。
    /// 这句的主语是"库里那条快照"而不是"此刻在跑"——大数已经说了此刻在跑几个，
    /// 副标题再用一个近似说法报另一个数，读者只会以为这两句在说同一件事（#85）。
    static let currentRunningCaption = NamedCopy("dashboard.current.runningCaption", LocalizedString(
        zh: "库内快照 %1$d 个（全表在跑，不限所选区间）",
        en: "%1$d in the whole-table snapshot (running, not scoped to the window)"))
    static let currentStatusSubtitle = NamedCopy("dashboard.group.currentStatusSubtitle", LocalizedString(
        zh: "与所选区间无关", en: "Independent of the selected window"))
    static let agentsEmptyTitle = NamedCopy("dashboard.agents.emptyTitle", LocalizedString(
        zh: "当前没有运行中的 Agent", en: "No agents are running right now"))
    static let agentsEmptyMessage = NamedCopy("dashboard.agents.emptyMessage", LocalizedString(
        zh: "启动任意受支持的 CLI 或编辑器 Agent 后，进程会立即出现在这里。",
        en: "Start a supported CLI or editor agent and the process shows up here right away."))
    static let agentsLongestUptime = NamedCopy("dashboard.agents.longestUptime", LocalizedString(
        zh: "最长存活 %@", en: "Longest running %@" ))
    static let agentMemory = NamedCopy("dashboard.agent.memory", LocalizedString(zh: "内存", en: "Memory"))
    static let agentUptime = NamedCopy("dashboard.agent.uptime", LocalizedString(zh: "运行时长", en: "Uptime"))
    /// 读屏那一整句：七个操作数全走位置参数（`SidebarNamingTests` 同款理由——
    /// 英文的语序会把"CPU/内存/运行时长"三个读数挪到别的位置，裸 `%@` 必然串位）。
    static let agentA11yLine = NamedCopy("dashboard.agent.a11yLine", LocalizedString(
        zh: "%1$@，%2$@，PID %3$d，启动 %4$@，CPU %5$@，内存 %6$@，运行时长 %7$@",
        en: "%1$@, %2$@, PID %3$d, started %4$@, CPU %5$@, %6$@ memory, running for %7$@"))
    static let agentStartedAt = NamedCopy("dashboard.agent.startedAt",
                                          LocalizedString(zh: "启动 %@", en: "Started %@"))
    static let agentParentPID = NamedCopy("dashboard.agent.parentPID",
                                          LocalizedString(zh: "父 PID %1$d", en: "Parent PID %1$d"))
    static let agentDetectedVia = NamedCopy("dashboard.agent.detectedVia",
                                            LocalizedString(zh: "识别：%@", en: "Detected via: %@"))
    static let agentStateRunning = NamedCopy("dashboard.agent.state.running",
                                             LocalizedString(zh: "运行中", en: "running"))
    static let agentStateIdle = NamedCopy("dashboard.agent.state.idle",
                                          LocalizedString(zh: "空闲", en: "idle"))
    static let agentStateTerminated = NamedCopy("dashboard.agent.state.terminated",
                                                LocalizedString(zh: "已退出", en: "exited"))

    // MARK: Agent 时长读数（`DashboardAgentShareReadout`，#80 之前是环形图）

    static let shareTitle = NamedCopy("dashboard.share.title",
                                      LocalizedString(zh: "Agent 时长占比", en: "Share of agent time"))
    static let shareByDuration = NamedCopy("dashboard.share.byDuration",
                                           LocalizedString(zh: "按活跃时长统计", en: "By active duration"))
    static let shareBySessions = NamedCopy("dashboard.share.bySessions", LocalizedString(
        zh: "尚无时长，按会话数统计", en: "No durations yet, so by session count"))
    static let shareEmptyTitle = NamedCopy("dashboard.share.emptyTitle", LocalizedString(
        zh: "这个窗口没有会话记录", en: "No session records in this window"))
    static let shareEmptyMessage = NamedCopy("dashboard.share.emptyMessage", LocalizedString(
        zh: "出现第一个会话之后，这里会按 Agent 列出各自的时长与占比。",
        en: "Once the first session appears, each agent's duration and share of the window shows here."))
    /// 每一行的绝对量。**没有百分比**：百分比在单序列那一档是假读数，只能另走一条式子。
    static let shareRowSummary = NamedCopy("dashboard.share.rowSummary", LocalizedString(
        zh: "%1$d 个会话 · %2$@", en: "Sessions: %1$d · %2$@"))
    static let shareMoreAgents = NamedCopy("dashboard.share.moreAgents", LocalizedString(
        zh: "另有 %1$d 种 Agent 未列出", en: "%1$d more not listed"))
    /// 标题右侧那一句按**有记录的种数**给（#80 的判据就是这一列）。
    static let shareKindsRecorded = NamedCopy("dashboard.share.kindsRecorded", LocalizedString(
        zh: "有记录 %1$d 种", en: "%1$d kinds recorded"))
    static let shareKindsSingle = NamedCopy("dashboard.share.kindsSingle", LocalizedString(
        zh: "有记录 1 种", en: "1 kind recorded"))
    static let shareKindsNone = NamedCopy("dashboard.share.kindsNone",
                                          LocalizedString(zh: "无记录", en: "no records"))
    /// 单序列那一档的解释句：不印占比是**处置**，为什么什么都不印是**口径**，两句都要在屏上。
    static let shareSingleSeriesNote = NamedCopy("dashboard.share.singleSeriesNote", LocalizedString(
        zh: "本窗口只有一种 Agent 有记录：它占全部，所以这里不报百分比，只报绝对量。",
        en: "Only one agent kind has records in this window. It holds everything, so no percentage is reported — absolute values only."))
    /// 读屏那一行：有占比与没占比是两句话，合成一句就得给单序列编一个 100 %。
    static let shareRowA11yWithShare = NamedCopy("dashboard.share.rowA11yWithShare", LocalizedString(
        zh: "%1$@：%2$d 个会话 · %3$@ · 占比 %4$@",
        en: "%1$@: %2$d sessions, %3$@ of active time, %4$@ of the window"))
    static let shareRowA11yNoShare = NamedCopy("dashboard.share.rowA11yNoShare", LocalizedString(
        zh: "%1$@：%2$d 个会话 · %3$@（唯一一家有记录，不算占比）",
        en: "%1$@: %2$d sessions, %3$@ of active time (only agent kind with records, no share computed)"))

    /// 副标题那一句：分母用的是时长还是会话数，界面上不许含糊。
    static func shareMeasureNote(_ language: AppLanguage, durationBased: Bool) -> String {
        (durationBased ? shareByDuration : shareBySessions).text(language)
    }

    /// 标题右侧的种数读数（`.multipleSeries` 走带参数那一条）。
    static func shareKindSummary(_ language: AppLanguage, kinds: Int) -> String {
        switch kinds {
        case 0: return shareKindsNone.text(language)
        case 1: return shareKindsSingle.text(language)
        default: return shareKindsRecorded.copy.format(language, kinds)
        }
    }

    /// 一行的读屏句子：有没有占比，走的是两条不同的句子（`percentText == nil` 就是没有）。
    static func shareRowA11y(
        _ language: AppLanguage,
        kind: AgentKind,
        sessions: Int,
        durationText: String,
        percentText: String?
    ) -> String {
        if let percentText {
            return shareRowA11yWithShare.copy.format(
                language, kind.displayName, sessions, durationText, percentText)
        }
        return shareRowA11yNoShare.copy.format(language, kind.displayName, sessions, durationText)
    }

    /// 环标题带窗口：不写窗口就等于让"占比"悬着一个没着落的分母。
    static func shareWindowedTitle(_ language: AppLanguage, windowCaption: String) -> String {
        shareTitle.text(language) + " · " + windowCaption
    }

    // MARK: 异常卡（`DashboardAnomalyCard`）

    static let anomalyTitle = NamedCopy("dashboard.anomaly.title",
                                        LocalizedString(zh: "异常检测", en: "Anomaly detection"))
    static let anomalyNotWired = NamedCopy("dashboard.anomaly.notWired", LocalizedString(
        zh: "分析层未接入时不做任何判定", en: "No verdicts while the analysis layer is not wired in"))
    static let anomalyWindow = NamedCopy("dashboard.anomaly.window", LocalizedString(
        zh: "与自身基线比对（z-score）· %@", en: "Compared with its own baseline (z-score) · %@"))
    static let anomalyWindowPlain = NamedCopy("dashboard.anomaly.windowPlain", LocalizedString(
        zh: "与自身基线比对（z-score）", en: "Compared with its own baseline (z-score)"))
    static let anomalyHiddenRest = NamedCopy("dashboard.anomaly.hiddenRest", LocalizedString(
        zh: "另有 %1$d 处异常未展示（本卡片只列最近 %2$d 条）",
        en: "%1$d more hidden (this card lists only the newest %2$d)"))
    static let anomalyStaleScan = NamedCopy("dashboard.anomaly.staleScan", LocalizedString(
        zh: "异常扫描未完成，以下是上一轮结果：%@",
        en: "The anomaly scan did not finish; these are the previous round's results: %@"))
    static let anomalyA11y = NamedCopy("dashboard.anomaly.a11y", LocalizedString(
        zh: "异常：%1$@，%2$@，%3$@", en: "Anomaly: %1$@, %2$@, %3$@"))

    // MARK: 24 小时活动（`DashboardHourlyActivityChart`）

    /// 柱图标题按**实际档位**给（#75 裁定 9）。旧文案写死「24 小时活动」，
    /// 而窗口一过 36 小时，画的格子既不是 24 个、也不按小时——标题与读数不符。
    static let hourlyTitleHourly = NamedCopy("dashboard.hourly.titleHourly",
                                             LocalizedString(zh: "活动趋势 · 按小时", en: "Activity trend · by hour"))
    static let hourlyTitleDaily = NamedCopy("dashboard.hourly.titleDaily",
                                            LocalizedString(zh: "活动趋势 · 按自然日", en: "Activity trend · by day"))
    static let hourlySubtitleHourly = NamedCopy("dashboard.hourly.subtitleHourly", LocalizedString(
        zh: "每格一小时 · %1$@", en: "Each bar is one hour · %1$@"))
    static let hourlySubtitleDaily = NamedCopy("dashboard.hourly.subtitleDaily", LocalizedString(
        zh: "每格一个自然日 · %1$@", en: "Each bar is a calendar day · %1$@"))

    /// 标题的唯一出处：档位由载荷给（`DashboardStats.bucketSpan`），界面不自己判窗口宽度。
    static func hourlyTitle(_ language: AppLanguage, bucketSpan: ActivityBucketSpan) -> String {
        (bucketSpan == .naturalDay ? hourlyTitleDaily : hourlyTitleHourly).text(language)
    }

    /// 副标题第二句带窗口端点：读数该让人看出它是按哪一段算的。
    static func hourlySubtitle(
        _ language: AppLanguage,
        bucketSpan: ActivityBucketSpan,
        windowCaption: String
    ) -> String {
        let entry = bucketSpan == .naturalDay ? hourlySubtitleDaily : hourlySubtitleHourly
        return entry.copy.format(language, windowCaption)
    }
    static let hourlyEventCount = NamedCopy("dashboard.hourly.eventCount",
                                            LocalizedString(zh: "%1$d 次行为", en: "Actions: %1$d"))
    static let hourlyEmptyTitle = NamedCopy("dashboard.hourly.emptyTitle", LocalizedString(
        zh: "这段时间还没有行为", en: "No activity in this window yet"))
    static let hourlyEmptyMessage = NamedCopy("dashboard.hourly.emptyMessage", LocalizedString(
        zh: "引擎采集到文件改动或命令执行后，柱状图会实时长高。",
        en: "Bars grow as the engine captures file changes and command runs."))
    static let hourlyAxisHour = NamedCopy("dashboard.hourly.axisHour",
                                          LocalizedString(zh: "小时", en: "Hour"))
    /// 柱图 x 列的语义标签（进 VoiceOver 的图元描述 ⇒ 也是文案，随档位给）。
    static let hourlyAxisDay = NamedCopy("dashboard.hourly.axisDay",
                                         LocalizedString(zh: "自然日", en: "Day"))
    static let hourlyBarA11y = NamedCopy("dashboard.hourly.barA11y", LocalizedString(
        zh: "%1$@ 这一格 %2$d 次行为", en: "%1$@: %2$d logged actions"))
    static let hourlyDayRange = NamedCopy("dashboard.hourly.dayRange", LocalizedString(
        zh: "%1$@ 起至 %2$@", en: "%1$@ through %2$@"))
    static let hourlyAxisEvents = NamedCopy("dashboard.hourly.axisEvents",
                                            LocalizedString(zh: "事件数", en: "Events"))
    static let hourlyA11y = NamedCopy("dashboard.hourly.a11y", LocalizedString(
        zh: "活动趋势柱状图，共 %1$d 次行为", en: "Activity trend bar chart, %1$d in total"))
    /// 「:00」是小时档专用的写法；#75 之后同一格可能是自然日，标签由模型按档位给。
    static let hourlyBusiest = NamedCopy("dashboard.hourly.busiest", LocalizedString(
        zh: "最忙一格 %1$@ · %2$d 次", en: "Busiest bucket %1$@ · %2$d logged"))
    static let hourlyLastEvent = NamedCopy("dashboard.hourly.lastEvent",
                                           LocalizedString(zh: "最近事件 %@", en: "Last event %@"))

    // MARK: 今日概览主读数（`DashboardView` / `DashboardModel`）

    static let pageSubtitle = NamedCopy("dashboard.page.subtitle", LocalizedString(
        zh: "%1$@ · 范围：%2$@", en: "%1$@ · Range: %2$@"))
    static let pageA11y = NamedCopy("dashboard.page.a11y", LocalizedString(zh: "仪表盘", en: "Dashboard"))
    /// 两组读数的分组标题（#75 裁定 3：当前状态与时段累计分开卖）。
    static let currentStatusTitle = NamedCopy("dashboard.group.currentStatus",
                                              LocalizedString(zh: "当前状态", en: "Current state"))
    static let periodTotalTitle = NamedCopy("dashboard.group.periodTotal",
                                            LocalizedString(zh: "时段累计", en: "Totals for the window"))
    /// 窗口口径三种式子：有起有终 / 只有起点 / 全开（「全部」）。
    static let windowBetween = NamedCopy("dashboard.window.between",
                                         LocalizedString(zh: "%1$@ — %2$@", en: "%1$@ to %2$@"))
    static let windowSince = NamedCopy("dashboard.window.since",
                                       LocalizedString(zh: "自 %1$@ 起", en: "Since %1$@"))
    static let windowAll = NamedCopy("dashboard.window.all",
                                     LocalizedString(zh: "全部时间", en: "All time"))
    static let tileActiveDuration = NamedCopy("dashboard.tile.activeDuration",
                                              LocalizedString(zh: "活跃总时长", en: "Total active time"))
    /// 「活跃总时长」那格的副标题。**两处窗口都得写**：
    ///   · 累计的是"落在所选区间内新建"的会话（选 7 天时不是"今日"）；
    ///   · 还没结束的会话长度算到哪个时刻（`settledAt`），不写就等于让人以为在跑实时数。
    /// 旧文案两处都缺，真机上就出现过「区间总时长 0s」并排「某进程运行时长 6h5m」的自相矛盾。
    static let activeDurationCaption = NamedCopy("dashboard.tile.activeDurationCaption", LocalizedString(
        zh: "区间内新建的会话累计 · 未结算会话算到 %1$@ · Agent 峰值内存 %2$@",
        en: "Summed over sessions created in the window · open sessions counted up to %1$@ · peak agent memory %2$@"))
    /// 「今日」在选 1h / 7 天 / 全部时都是错的窗口 ⇒ 中性化成"区间内新建"。
    static let tileWindowSessions = NamedCopy("dashboard.tile.windowSessions",
                                              LocalizedString(zh: "区间内新建会话", en: "Sessions created in window"))
    static let tileWindowSessionsCaption = NamedCopy("dashboard.tile.windowSessionsCaption", LocalizedString(
        zh: "新建会话数 · %1$@", en: "New sessions · %1$@"))
    /// 「当前状态」那一格的**标题**。这里原来直接复用下面那张列表卡的标题
    /// （`dashboard.agents.title`「当前运行中的 Agent」），于是同一个七字标题在一屏里出现两次，
    /// 而两处说的不是一回事：下面那张是**清单**（都有谁），这一格是**读数**（几个）。
    /// #85「重复标题只留一个出处」点名的就是这一对 ⇒ 一格一个名字。
    /// （旧版这一格副标题写作"活跃 Agent N"，与卡片标题"当前运行中的 Agent"是同一件事的两个名字，
    /// 那一条文案已随 `liveAgentsCaption` 一起删除。）
    static let tileCurrentRunning = NamedCopy("dashboard.tile.currentRunning", LocalizedString(
        zh: "在跑的 Agent 数", en: "Count of running agents"))
    static let tileFileChanges = NamedCopy("dashboard.tile.fileChanges",
                                          LocalizedString(zh: "文件变更", en: "File changes"))
    static let fileTripleCaption = NamedCopy("dashboard.tile.fileTripleCaption", LocalizedString(
        zh: "修改 %1$d · 新建 %2$d · 删除 %3$d", en: "%1$d modified · %2$d created · %3$d deleted"))
    static let tileCommands = NamedCopy("dashboard.tile.commands",
                                        LocalizedString(zh: "执行命令", en: "Commands run"))
    static let failedCommandsCaption = NamedCopy("dashboard.tile.failedCommands",
                                                 LocalizedString(zh: "失败 %1$d 次", en: "Failed %1$d times"))
    /// 这一格的**主体写在标题里**（#96）。改前它叫"CPU 占用 / CPU load"，而取数那一格
    /// 只算 `perf_samples` 里挂着会话的采样（`ObservatoryStore+Queries.dashboardPerformanceRollup`
    /// 的 `session_id IS NOT NULL`）——那既不是整机 CPU（整机在 `system_perf` 另一张表），
    /// 也不是全部 Agent 采样（还没归到会话的那部分不计）。一个不带主体的名字，
    /// 读的人只能猜是哪一种，而"需求方要求区分整机 vs Agent 开销"要的正是这个词。
    static let tileCPU = NamedCopy("dashboard.tile.cpu",
                                   LocalizedString(zh: "Agent CPU 均值", en: "Average agent CPU"))
    static let peakCPUCaption = NamedCopy("dashboard.tile.peakCPU",
                                          LocalizedString(zh: "峰值 %@", en: "Peak %@"))
    static let tileRisks = NamedCopy("dashboard.tile.risks",
                                     LocalizedString(zh: "风险事件", en: "Risk events"))
    static let highRiskCaption = NamedCopy("dashboard.tile.highRisk",
                                           LocalizedString(zh: "高危 %1$d 起", en: "%1$d high severity"))
    static let anomalySince = NamedCopy("dashboard.anomaly.since",
                                        LocalizedString(zh: "自 %@ 起", en: "since %@"))
    static let recentRiskTitle = NamedCopy("dashboard.risk.title",
                                           LocalizedString(zh: "最近风险", en: "Recent risks"))
    static let recentRiskSubtitle = NamedCopy("dashboard.risk.subtitle", LocalizedString(
        zh: "命中规则的行为，按等级优先展示", en: "Actions that matched a rule, worst first"))
    static let riskNoneLabel = NamedCopy("dashboard.risk.none", LocalizedString(
        zh: "本范围内没有触发风险规则", en: "No risk rule matched in this range"))
    static let loadingTitle = NamedCopy("dashboard.loading.title",
                                        LocalizedString(zh: "正在读取本地观测库", en: "Reading the local observation store"))
    static let loadingNote = NamedCopy("dashboard.loading.note", LocalizedString(
        zh: "首次进入会聚合本范围内的会话、事件与风险。",
        en: "The first visit aggregates sessions, events and risks for this range."))
    static let emptyTitle = NamedCopy("dashboard.empty.title",
                                      LocalizedString(zh: "今天还没有 AI 活动", en: "No AI activity today"))
    static let emptyMessage = NamedCopy("dashboard.empty.message", LocalizedString(
        zh: "观测引擎正在监听进程与文件变化。当有 AI Agent 修改文件或执行命令时，指标与图表会实时更新。",
        en: "The observatory engine is watching processes and file changes. Metrics and charts update as soon as an AI agent edits a file or runs a command."))
    static let rescan = NamedCopy("dashboard.empty.rescan", LocalizedString(zh: "重新扫描", en: "Rescan"))
    static let errorTitle = NamedCopy("dashboard.error.title",
                                      LocalizedString(zh: "读取观测数据失败", en: "Could not read the observation data"))
    static let retry = NamedCopy("dashboard.error.retry", LocalizedString(zh: "重试", en: "Retry"))

    // MARK: - 集中清单（门禁遍历这一份）

    // MARK: agents 组文案（6 条，key 前缀 agents.* / current.*）
    static let agentsCopy: [NamedCopy] = [
        agentsTitle,
        agentsPolling,
        currentRunningCaption,
        agentsEmptyTitle,
        agentsEmptyMessage,
        agentsLongestUptime,
    ]

    // MARK: agent 组文案（9 条，key 前缀 agent.*）
    static let agentCopy: [NamedCopy] = [
        agentMemory,
        agentUptime,
        agentA11yLine,
        agentStartedAt,
        agentParentPID,
        agentDetectedVia,
        agentStateRunning,
        agentStateIdle,
        agentStateTerminated,
    ]

    // MARK: share 组文案（13 条，key 前缀 share.*）
    static let shareCopy: [NamedCopy] = [
        shareTitle,
        shareByDuration,
        shareBySessions,
        shareEmptyTitle,
        shareEmptyMessage,
        shareRowSummary,
        shareMoreAgents,
        shareKindsRecorded,
        shareKindsSingle,
        shareKindsNone,
        shareSingleSeriesNote,
        shareRowA11yWithShare,
        shareRowA11yNoShare,
    ]

    // MARK: anomaly 组文案（7 条，key 前缀 anomaly.*）
    static let anomalyCopy: [NamedCopy] = [
        anomalyTitle,
        anomalyNotWired,
        anomalyWindow,
        anomalyWindowPlain,
        anomalyHiddenRest,
        anomalyStaleScan,
        anomalyA11y,
    ]

    // MARK: hourly 组文案（10 条，key 前缀 hourly.*）
    static let hourlyCopy: [NamedCopy] = [
        hourlyTitleHourly,
        hourlyTitleDaily,
        hourlySubtitleHourly,
        hourlySubtitleDaily,
        hourlyEventCount,
        hourlyEmptyTitle,
        hourlyEmptyMessage,
        hourlyAxisHour,
        hourlyAxisDay,
        hourlyBarA11y,
        hourlyDayRange,
        hourlyAxisEvents,
        hourlyA11y,
        hourlyBusiest,
        hourlyLastEvent,
    ]

    // MARK: page 组文案（1 条，key 前缀 page.*）
    static let pageCopy: [NamedCopy] = [
        pageSubtitle,
    ]

    // MARK: page2 组文案（1 条，key 前缀 page.*）
    static let page2Copy: [NamedCopy] = [
        pageA11y,
    ]

    // MARK: tile 组文案（2 条，key 前缀 tile.*）
    static let tileCopy: [NamedCopy] = [
        tileActiveDuration,
        tileCurrentRunning,
    ]

    // MARK: active 组文案（1 条，key 前缀 active.*）
    static let activeCopy: [NamedCopy] = [
        activeDurationCaption,
    ]

    // MARK: tile2 组文案（2 条，key 前缀 tile.*）
    static let tile2Copy: [NamedCopy] = [
        tileWindowSessions,
        tileWindowSessionsCaption,
    ]

    // MARK: tile3 组文案（1 条，key 前缀 tile.*）
    static let tile3Copy: [NamedCopy] = [
        tileFileChanges,
    ]

    // MARK: file 组文案（1 条，key 前缀 file.*）
    static let fileCopy: [NamedCopy] = [
        fileTripleCaption,
    ]

    // MARK: tile4 组文案（1 条，key 前缀 tile.*）
    static let tile4Copy: [NamedCopy] = [
        tileCommands,
    ]

    // MARK: failed 组文案（1 条，key 前缀 failed.*）
    static let failedCopy: [NamedCopy] = [
        failedCommandsCaption,
    ]

    // MARK: tile5 组文案（1 条，key 前缀 tile.*）
    static let tile5Copy: [NamedCopy] = [
        tileCPU,
    ]

    // MARK: peak 组文案（1 条，key 前缀 peak.*）
    static let peakCopy: [NamedCopy] = [
        peakCPUCaption,
    ]

    // MARK: tile6 组文案（1 条，key 前缀 tile.*）
    static let tile6Copy: [NamedCopy] = [
        tileRisks,
    ]

    // MARK: high 组文案（1 条，key 前缀 high.*）
    static let highCopy: [NamedCopy] = [
        highRiskCaption,
    ]

    // MARK: anomaly2 组文案（1 条，key 前缀 anomaly.*）
    static let anomaly2Copy: [NamedCopy] = [
        anomalySince,
    ]

    // MARK: recent2 组文案（2 条，key 前缀 recent.*）
    static let recent2Copy: [NamedCopy] = [
        recentRiskTitle,
        recentRiskSubtitle,
    ]

    // MARK: risk 组文案（1 条，key 前缀 risk.*）
    static let riskCopy: [NamedCopy] = [
        riskNoneLabel,
    ]

    // MARK: loading 组文案（2 条，key 前缀 loading.*）
    static let loadingCopy: [NamedCopy] = [
        loadingTitle,
        loadingNote,
    ]

    // MARK: empty 组文案（2 条，key 前缀 empty.*）
    static let emptyCopy: [NamedCopy] = [
        emptyTitle,
        emptyMessage,
    ]

    // MARK: rescan 组文案（1 条，key 前缀 rescan.*）
    static let rescanCopy: [NamedCopy] = [
        rescan,
    ]

    // MARK: error 组文案（1 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        errorTitle,
    ]

    // MARK: retry 组文案（1 条，key 前缀 retry.*）
    static let retryCopy: [NamedCopy] = [
        retry,
    ]

    /// 漏列的漏洞由 `DashboardBilingualCopyGateTests.everyDeclaredEntryIsListed` 堵
    /// （数本文件 `= NamedCopy(` 的处数 == 清单条数）。
    // MARK: window / 分组 组文案（#75 新增，key 前缀 window.* 与 group.currentStatus*）
    static let windowCopy: [NamedCopy] = [
        currentStatusTitle,
        currentStatusSubtitle,
        periodTotalTitle,
        windowBetween,
        windowSince,
        windowAll,
    ]

    static let bilingualCopy: [NamedCopy] =
        agentsCopy
        + agentCopy
        + shareCopy
        + anomalyCopy
        + windowCopy
        + hourlyCopy
        + pageCopy
        + page2Copy
        + tileCopy
        + activeCopy
        + tile2Copy
        + tile3Copy
        + fileCopy
        + tile4Copy
        + failedCopy
        + tile5Copy
        + peakCopy
        + tile6Copy
        + highCopy
        + anomaly2Copy
        + recent2Copy
        + riskCopy
        + loadingCopy
        + emptyCopy
        + rescanCopy
        + errorCopy
        + retryCopy

}
