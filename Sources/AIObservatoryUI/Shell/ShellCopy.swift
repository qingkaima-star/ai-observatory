//
//  ShellCopy.swift
//  AIObservatoryUI / Shell
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  外壳层（侧栏 / 窗口标题 / 工具栏 / 菜单栏面板 / 全局读数）的全部**用户可见**文案，
//  按 IFR 裁定 3(a) 集中声明成一份 `bilingualCopy`，门禁遍历它断言零缺陷
//  （`ShellBilingualCopyGateTests`）。
//
//  迁移口径（三条，B3 四个目录共用）：
//  1. 只迁会进眼睛/读屏的字。注释、`ObservatoryLog`、`print`、`#Preview` 的 Canvas 标签
//     一律不翻——翻注释会让 diff 读出两种意思，而 `#Preview` 不进产物。
//  2. 中文侧**逐字保留**现状。这一笔只加英文，不顺手改中文措辞：改了中文同时改了
//     真机护栏认的那串字（`Tools/UIProbe/measure-pages.sh`），两件事混在一笔里没法回滚。
//  3. 多参数一律 `%1$@` / `%2$d`。裸 `%@` 换语言会串位，`problems` 会红。
//
//  【英文没有复数机制 ⇒ 一律写数量中性】`LocalizedString` 只有一对模板，没有 `plural:` 分支
//  （那是 Core 机制层的事，不在 B3 派单范围）。所以"数字 + 名词"的槽位英文不许写 `"%1$d sessions"`：
//  命中一条时渲染成 "1 sessions"，母语者一眼看出是机翻（英文态实拍第一版就抓到 5 处：
//  "1 sessions"、"1 days"、"1 command rows loaded"、"1 risks"、"1 processes are being observed"）。
//  可用的形状有三种，都不需要复数：`"Sessions: %1$d"`（名词前置）、`"%1$d with risks"`、
//  `"%1$d logged"`。中文侧照旧带量词，不受影响。
//
//  板块名为什么是 `switch` 而不是 `[SidebarSection: LocalizedString]` 字典：
//  字典取不到键只能 `!` 或静默漏一条，而 `switch` 少一个 case 是**编译错误**。
//  新增板块时必须同时给出两种语言的这个名字，正是这套机制想要的（同 `LocalizedString`
//  不做 `ExpressibleByStringLiteral` 的理由）。
//
//  ⚠️ 一处**本车道改不动**的语言残留（交回总控，见交付块）；**#67 已收掉一半**：
//  `EngineState.displayName`、`AgentKind.displayName`
//  等一串枚举名写在 `AIObservatoryCore/Contracts/**`（§3 冻结区，也不在 B3 派给任何人的范围里），
//  仍是中文。⇒ 英文态下外壳会显示 "Engine: 已停止" 这种半截英文。这里**不**替它们补英文：
//  UI 侧再抄一份状态名就是第二个出处，而第二个出处必然分叉（本仓头号缺陷族）。
//

import Foundation
import AIObservatoryCore

/// UI 侧解析一次的语言。
///
/// 为什么缓存而不是就地 `AppLanguage.resolved()`：`resolved()` 读 `Locale.preferredLanguages`，
/// 而侧栏一行就要取 2–3 条文案，九行 + 工具栏 + 每个 tick 重算的读数会把它变成
/// 每次 body 几十次的系统偏好读取。本 App 的语言**只跟随系统、改语言要重启**
/// （见 `LocalizedString.swift` 文件头，需求方 2026-09-21 拍定不做 App 内开关），
/// 所以进程内取一次是正确语义，不是"顺手缓存"。
///
/// ⚠️ 用例不许依赖它：测试进程的语言 = 宿主系统语言。门禁与断言一律走各处的
/// `(_ language: AppLanguage)` 显式展口，要中文传 `.chineseSimplified`、要英文传 `.english`。
enum UILanguage {
    static let current: AppLanguage = .resolved()
}

/// 外壳层的用户可见文案表。
enum ShellCopy {

    // MARK: 板块名（侧栏行 / 页内 hero / 窗口标题栏 / 读屏标签的唯一出处）

    /// 英文名按 macOS 侧栏的写法取短（`Today`、`Settings`），不是逐字对译 "Today Overview"。
    ///
    /// 【大小写口径：一律句首大写（sentence case）】HIG 对 App 自己显示的文本
    /// （标签、按钮、菜单项、侧栏条目）要求 sentence case，只有专名保留大写。
    /// B3 四个目录的英文都按这一条写，所以 `Activity timeline` 而不是 `Activity Timeline`、
    /// `Show main window` 而不是 `Show Main Window`。`AI`、`Before/After`、`SMC` 这类专名/
    /// 技术名不算例外。改任何一条成 Title Case 都会让同一屏里出现两种大小写口径。
    ///
    /// 但九条**互不相同**：`Tools/UIProbe/measure-pages.sh` 靠窗口真显示的那串字判断实例
    /// 落在哪一页，两个板块撞名护栏就废了（用例 `titlesAreDistinctInBothLanguages` 钉着）。
    static func sectionTitle(_ section: SidebarSection, _ language: AppLanguage) -> String {
        sectionTitleCopy(section).text(language)
    }

    static func sectionTitleCopy(_ section: SidebarSection) -> LocalizedString {
        switch section {
        case .dashboard:   return LocalizedString(zh: "今日概览", en: "Today")
        case .sessions:    return LocalizedString(zh: "AI 会话", en: "AI sessions")
        case .timeline:    return LocalizedString(zh: "行为时间线", en: "Activity timeline")
        case .commands:    return LocalizedString(zh: "命令审计", en: "Command audit")
        case .files:       return LocalizedString(zh: "文件变更", en: "File changes")
        case .performance: return LocalizedString(zh: "系统性能", en: "Performance")
        case .security:    return LocalizedString(zh: "安全风险", en: "Security risks")
        case .projects:    return LocalizedString(zh: "项目活动地图", en: "Project activity map")
        case .settings:    return LocalizedString(zh: "设置", en: "Settings")
        }
    }

    /// 侧栏 tooltip 的正文（`SidebarRow` 的 `.help`）。
    static func sectionSubtitle(_ section: SidebarSection, _ language: AppLanguage) -> String {
        sectionSubtitleCopy(section).text(language)
    }

    /// ⚠️ 这一句只能列**这一页真给得出的东西**（原注释的两条说谎教训保留在此，双语不许把它改松）：
    /// · 总览页原写「实时曲线」，而那一页是 24 小时柱状图 + 占比环图，没有任何曲线；
    /// · 性能页原写「与温度」，而 Apple Silicon 上 SMC 拿不到温度。
    static func sectionSubtitleCopy(_ section: SidebarSection) -> LocalizedString {
        switch section {
        case .dashboard:
            return LocalizedString(zh: "AI 活动总览：时长、会话与 24 小时分布",
                                   en: "AI activity at a glance: duration, sessions and a 24-hour profile")
        case .sessions:
            return LocalizedString(zh: "会话清单、命令与资源归集",
                                   en: "Sessions with their commands and resource use")
        case .timeline:
            return LocalizedString(zh: "逐条还原 Agent 做了什么",
                                   en: "Every agent action, in order")
        case .commands:
            return LocalizedString(zh: "命令、退出结果与耗时",
                                   en: "Commands, exit results and durations")
        case .files:
            return LocalizedString(zh: "文件增删改与 Before/After Diff",
                                   en: "File additions, edits and Before/After diffs")
        case .performance:
            return LocalizedString(zh: "CPU / 内存 / 磁盘与网络速率",
                                   en: "CPU, memory, disk and network rates")
        case .security:
            return LocalizedString(zh: "风险事件与确认处置",
                                   en: "Risk events and how you handled them")
        case .projects:
            return LocalizedString(zh: "按项目聚合的 AI 足迹",
                                   en: "AI footprint grouped by project")
        case .settings:
            return LocalizedString(zh: "采集范围、频率与隐私策略",
                                   en: "What gets captured, how often, and the privacy policy")
        }
    }

    static func groupTitle(_ group: SidebarGroup, _ language: AppLanguage) -> String {
        groupTitleCopy(group).text(language)
    }

    static func groupTitleCopy(_ group: SidebarGroup) -> LocalizedString {
        switch group {
        case .overview:   return LocalizedString(zh: "总览", en: "Overview")
        case .forensics:  return LocalizedString(zh: "行为取证", en: "Forensics")
        case .resources:  return LocalizedString(zh: "资源与安全", en: "Resources & security")
        case .workspace:  return LocalizedString(zh: "工作区", en: "Workspace")
        }
    }

    // MARK: 单条文案

    /// 快捷提示的括号。中文用全角括号且不前置空格，英文用半角并留一个空格——
    /// 它是**拼在 tooltip 尾巴上的**，标点不跟着语言走就会写出「xxx（⌘1）」式的混排。
    static let shortcutHintTemplate = LocalizedString(zh: "（⌘%1$@）", en: " (⌘%1$@)")

    /// 侧栏底部引擎状态那一格的外壳。状态名本身来自 Core（见文件头那条交回）。
    static let engineStateLabel = LocalizedString(zh: "引擎 %@", en: "Engine: %@")
    static let subscriptionNotStarted = LocalizedString(zh: "订阅未启动", en: "Subscription not started")
    static let waitingForLiveEvents = LocalizedString(zh: "等待实时事件…", en: "Waiting for live events…")
    static let lastUpdatedFormat = LocalizedString(zh: "最后更新 %@", en: "Last updated %@")
    static let searchPrompt = LocalizedString(zh: "搜索会话 / 事件 / 路径",
                                              en: "Search sessions or events")

    // MARK: 工具栏

    static let timeRange = LocalizedString(zh: "时间范围", en: "Time range")
    static let globalTimeRange = LocalizedString(zh: "全局时间范围", en: "Global time range")
    static let pauseCapture = LocalizedString(zh: "暂停采集", en: "Pause capture")
    static let startCapture = LocalizedString(zh: "开始采集", en: "Start capture")
    static let pauseEngine = LocalizedString(zh: "暂停观测引擎", en: "Pause the observatory engine")
    static let startEngine = LocalizedString(zh: "启动观测引擎", en: "Start the observatory engine")
    static let rescan = LocalizedString(zh: "重新扫描", en: "Rescan")
    /// ⚠️ 这条 tooltip 里的「观测」是 App 的菜单名，菜单标题本身写在 `AIObservatoryApp.swift`
    /// （冻结区，不在本车道权限内）。`SidebarNavigationTests.rescanShortcutHasSingleOwner`
    /// 原来逐字认这串中文，迁移后改认 `shell.toolbar.rescanTooltip` 的中文侧。
    static let rescanTooltip = LocalizedString(zh: "立即重新扫描（⇧⌘R · 见「观测」菜单）",
                                               en: "Rescan now (⇧⌘R — see the Observatory menu)")

    // MARK: 菜单栏面板

    /// 品牌名不译：两种语言同一串，登记进表是为了让门禁知道"这是查过的，不是漏的"。
    static let brandName = LocalizedString(zh: "AiX", en: "AiX")
    static let activeAgents = LocalizedString(zh: "活跃 Agent", en: "Active agents")
    static let agentTotalCount = LocalizedString(zh: "共 %1$d 个", en: "%1$d total")
    static let noRunningAgents = LocalizedString(zh: "当前没有正在运行的 Agent 进程",
                                                 en: "No agent processes are running right now")
    static let openMainWindow = LocalizedString(zh: "打开主窗口", en: "Show main window")
    static let refreshTodaySummary = LocalizedString(zh: "刷新今日摘要", en: "Refresh today's summary")
    static let privacyFooter = LocalizedString(zh: "数据仅存本机 · 不上传",
                                               en: "Stored only on this Mac · never uploaded")

    // MARK: 菜单栏面板的四格读数

    static let menuStatSessions = LocalizedString(zh: "会话", en: "Sessions")
    static let menuStatFileChanges = LocalizedString(zh: "文件改动", en: "File changes")
    static let menuStatCommands = LocalizedString(zh: "命令", en: "Commands")
    static let menuStatRisks = LocalizedString(zh: "风险", en: "Risks")
    static let menuStatFileChangesCaption = LocalizedString(zh: "修改 %1$d · 新建 %2$d",
                                                            en: "%1$d modified · %2$d created")
    static let menuStatHighRiskCaption = LocalizedString(zh: "高危 %1$d 起", en: "%1$d high severity")

    // MARK: #81 带条件跳转的那一格

    /// 引导语。中文「带着跳转条件进来」说的是"这一屏是被某一次跳转筛过的"，
    /// 英文侧写成 "Filtered by a jump" 而不是 "Jump conditions"：这一格要回答的是
    /// 「我看到的还是全部吗」，不是「这个功能叫什么」。
    static let jumpConditionsLead = LocalizedString(zh: "跳转带来的条件", en: "Filtered by a jump")
    static let jumpConditionProject = LocalizedString(zh: "项目 %@", en: "Project: %@")
    static let jumpConditionSession = LocalizedString(zh: "单个会话", en: "One session")
    static let jumpConditionKinds = LocalizedString(zh: "%1$d 类事件", en: "%1$d event kinds")
    static let jumpConditionsClear = LocalizedString(zh: "清除（Esc）", en: "Clear (Esc)")
    /// 整组的读屏标签（视觉上是四个小件，读屏时要先说清这一组是什么）。
    static let jumpConditionsGroup = LocalizedString(zh: "跳转条件", en: "Jump conditions")

    // MARK: - 集中清单（门禁遍历这一份）

    static let bilingualCopy: [NamedCopy] = {
        var entries: [NamedCopy] = []
        for section in SidebarSection.allCases {
            entries.append(NamedCopy("shell.section.\(section.rawValue).title", sectionTitleCopy(section)))
            entries.append(NamedCopy("shell.section.\(section.rawValue).subtitle", sectionSubtitleCopy(section)))
        }
        for group in SidebarGroup.allCases {
            entries.append(NamedCopy("shell.group.\(group.rawValue).title", groupTitleCopy(group)))
        }
        entries.append(contentsOf: [
            NamedCopy("shell.sidebar.shortcutHint", shortcutHintTemplate),
            NamedCopy("shell.sidebar.engineState", engineStateLabel),
            NamedCopy("shell.sidebar.subscriptionNotStarted", subscriptionNotStarted),
            NamedCopy("shell.sidebar.waitingForLiveEvents", waitingForLiveEvents),
            NamedCopy("shell.sidebar.lastUpdated", lastUpdatedFormat),
            NamedCopy("shell.sidebar.searchPrompt", searchPrompt),
            NamedCopy("shell.toolbar.timeRange", timeRange),
            NamedCopy("shell.toolbar.globalTimeRange", globalTimeRange),
            NamedCopy("shell.toolbar.pauseCapture", pauseCapture),
            NamedCopy("shell.toolbar.startCapture", startCapture),
            NamedCopy("shell.toolbar.pauseEngine", pauseEngine),
            NamedCopy("shell.toolbar.startEngine", startEngine),
            NamedCopy("shell.toolbar.rescan", rescan),
            NamedCopy("shell.toolbar.rescanTooltip", rescanTooltip),
            NamedCopy("shell.menubar.brand", brandName),
            NamedCopy("shell.menubar.activeAgents", activeAgents),
            NamedCopy("shell.menubar.agentTotalCount", agentTotalCount),
            NamedCopy("shell.menubar.noRunningAgents", noRunningAgents),
            NamedCopy("shell.menubar.openMainWindow", openMainWindow),
            NamedCopy("shell.menubar.refreshTodaySummary", refreshTodaySummary),
            NamedCopy("shell.menubar.privacyFooter", privacyFooter),
            NamedCopy("shell.menubar.stat.sessions", menuStatSessions),
            NamedCopy("shell.menubar.stat.fileChanges", menuStatFileChanges),
            NamedCopy("shell.menubar.stat.commands", menuStatCommands),
            NamedCopy("shell.menubar.stat.risks", menuStatRisks),
            NamedCopy("shell.menubar.stat.fileChangesCaption", menuStatFileChangesCaption),
            NamedCopy("shell.menubar.stat.highRiskCaption", menuStatHighRiskCaption),
            NamedCopy("shell.jump.conditionsLead", jumpConditionsLead),
            NamedCopy("shell.jump.conditionProject", jumpConditionProject),
            NamedCopy("shell.jump.conditionSession", jumpConditionSession),
            NamedCopy("shell.jump.conditionKinds", jumpConditionKinds),
            NamedCopy("shell.jump.conditionsClear", jumpConditionsClear),
            NamedCopy("shell.jump.conditionsGroup", jumpConditionsGroup),
        ])
        return entries
    }()
}
