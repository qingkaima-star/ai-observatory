//
//  SettingsCopy.swift
//  AIObservatoryUI / Settings
//
//  Owner: WS-l10n（B3 后半 · 设置目录）
//  ─────────────────────────────────────────────────────────
//  设置页「通用」分区的用户可见文案。**为什么一个目录一张表而不是全 UI 一张**：
//  UI 只有一个 target（88 个文件），`ws/uicopy` 与我同时在改它；
//  共享一张 `UICopy.swift` 必然撞车（两个人往同一个数组里加行）。
//  按目录切表 ⇒ 每张表只被它的目录改，跨车道零交集。
//
//  ⚠️ 一条围栏事实：本页**选项本身的名字**（跟随系统 / 浅色 / 深色）不在这里，
//  它们在 `Core/Contracts/DomainModels.swift:1133` 的 `AppTheme.displayName`（§3 冻结区）。
//  所以英文下这一段会渲染成 "Forced 深色" —— 标签是英文、值是中文。
//  已作为请拍项交回总控，不在本车道里绕过。
//
//  英文按 macOS 设置页的写法（Sentence case 标题、动词开头按钮、说明句完整成句），
//  不是逐字对译。每条的取舍写在该条上方。
//

import Foundation
import AIObservatoryCore

/// 设置目录的用户可见文案表。
enum SettingsCopy {

    // MARK: - 外观

    static let appearanceGroup = LocalizedString(zh: "外观", en: "Appearance")
    /// 「本窗口即时预览 / 整个 App 重启后生效」是现状的如实说法（见 `ThemeApplication.swift` 头），
    /// 英文也必须同样承认"只有这个窗口即时"，不能翻成 "changes apply instantly"。
    static let appearanceSubtitle = LocalizedString(
        zh: "本窗口即时预览；整个 App 的外观在重启后生效（沿用启动时落盘的主题）",
        en: "Previewed live in this window. The rest of the app keeps the theme saved at launch until you relaunch."
    )
    static let themeRow = LocalizedString(zh: "主题", en: "Theme")
    static let themeAppliesRow = LocalizedString(zh: "生效方式", en: "How it applies")
    /// 「不覆盖深浅色」是机制事实（不往宿主传 colorScheme override），保留在括号里。
    static let themeFollowsSystem = LocalizedString(
        zh: "跟随系统（不覆盖深浅色）",
        en: "Follow the system (no light/dark override)"
    )
    static let themeForced = LocalizedString(zh: "强制 %1$@", en: "Forced %1$@")

    // MARK: - 菜单栏与登录

    static let menuBarGroup = LocalizedString(zh: "菜单栏与登录", en: "Menu Bar and Login")
    static let menuBarGroupSubtitle = LocalizedString(
        zh: "两项都只影响宿主 App 的装配方式",
        en: "Both of these only change how the host app is assembled."
    )
    static let menuBarToggleTitle = LocalizedString(zh: "显示菜单栏 Extra", en: "Show Menu Bar Extra")
    /// 三句合一句会读不动，英文也保持"是什么 / 为什么不能即时 / 所以只落盘"三段。
    static let menuBarToggleDetail = LocalizedString(
        zh: "在系统菜单栏常驻今日概览与快速跳转。菜单栏在启动时按上次保存的值声明，"
            + "SwiftUI 的 Scene 建好之后无法增删，所以这里改动只写入本机设置。",
        en: "Keeps today's overview and quick jumps resident in the menu bar. The menu bar is declared at "
            + "launch from the value saved last time, and SwiftUI cannot add or remove a Scene after launch — "
            + "so changes here only write to local settings."
    )
    static let menuBarToggleCaveat = LocalizedString(
        zh: "需重启生效：应用只把改动落盘，本进程的菜单栏不会变。重启后才看得到结果。",
        en: "Requires relaunch: applying writes the change to disk but leaves this process's menu bar alone. "
            + "You'll see the result after restarting."
    )
    static let menuBarThisLaunch = LocalizedString(zh: "本次启动", en: "This launch")
    static let launchAtLoginTitle = LocalizedString(zh: "登录时启动", en: "Launch at Login")
    /// 「待系统接口接入」不许被翻成进行时断言（英文 "Starts at login" 会承诺一件没实现的事）。
    static let launchAtLoginCaveat = LocalizedString(
        zh: "待系统接口接入：契约未提供 SMAppService 入口，当前只记录草稿值。",
        en: "Not wired to the system yet: the contract exposes no SMAppService entry point, so only the "
            + "draft value is recorded."
    )

    // MARK: - 观测引擎

    static let engineGroup = LocalizedString(zh: "观测引擎", en: "Observatory Engine")
    static let engineGroupSubtitle = LocalizedString(
        zh: "启停走 ShellModel / runtime.controller，状态来自 updates 流",
        en: "Start and stop go through the runtime controller (`ShellModel`); the status comes from the updates stream."
    )
    static let samplingCadence = LocalizedString(zh: "采集节奏", en: "Sampling cadence")
    static let stopEngine = LocalizedString(zh: "停止引擎", en: "Stop Engine")
    static let startEngine = LocalizedString(zh: "启动引擎", en: "Start Engine")
    static let rescan = LocalizedString(zh: "重新扫描", en: "Rescan")
    static let engineRunningHint = LocalizedString(
        zh: "引擎在跑，界面会持续收到增量事件",
        en: "The engine is running; the interface keeps receiving incremental events."
    )
    static let engineStoppedHint = LocalizedString(
        zh: "引擎已停，界面不再更新",
        en: "The engine is stopped; the interface no longer updates."
    )
    static let engineStatePrefix = LocalizedString(zh: "引擎状态 %1$@", en: "Engine status %1$@")
    static let noProjectsHint = LocalizedString(
        zh: "引擎尚未观测到任何项目：让任意 AI Agent 改动一个文件，或点下方「重新扫描」。",
        en: "No projects observed yet: let any AI agent change a file, or press Rescan below."
    )

    // MARK: - 以下 #56 后续（总控 07:5x 裁定 (c)）：Settings 余下 143 行硬中文
    // 建表时只迁了「通用」分区，其余四块面板（分段标题 / 页头与持久化格 / 隐私 / 存储 / 关于）
    // 一直是裸字面量，而 `SettingsBilingualCopyTests` 没有「目录内不许写死中文」那道 ⇒ 全绿。

    // 分段标题与"这一分段讲什么"（`SettingsPane`，钉在标题行下方一行）
    static let paneGeneral = LocalizedString(zh: "通用", en: "General")
    static let panePrivacy = LocalizedString(zh: "隐私与安全", en: "Privacy and Security")
    static let paneStorage = LocalizedString(zh: "存储与采集", en: "Storage and Collection")
    static let paneAbout = LocalizedString(zh: "关于", en: "About")
    static let paneSubtitleGeneral = LocalizedString(zh: "外观、菜单栏与引擎开关",
                                                     en: "Appearance, menu bar and engine switches")
    static let paneSubtitlePrivacy = LocalizedString(
        zh: "风险确认、Diff 明文、Endpoint Security、保留期",
        en: "Risk confirmation, diff plaintext, Endpoint Security and retention"
    )
    static let paneSubtitleStorage = LocalizedString(zh: "监控根目录、忽略规则、采样频率",
                                                     en: "Monitored roots, ignore rules and sampling rate")
    static let paneSubtitleAbout = LocalizedString(zh: "版本、隐私声明与格式样例",
                                                   en: "Version, privacy statement and format samples")

    // 页头与标题行控件
    static let pageSubtitle = LocalizedString(
        zh: "观测引擎与界面偏好 · %@",
        en: "Observatory engine and interface preferences · %@"
    )
    static let panePickerLabel = LocalizedString(zh: "分段", en: "Section")
    static let a11ySwitchPane = LocalizedString(zh: "切换设置分段", en: "Switch settings section")
    /// 「N 项改动」英文写成名词前置："%d changes pending" 在 1 时就是 "1 changes"。
    static let pendingChanges = LocalizedString(zh: "%d 项改动", en: "Pending changes: %d")
    static let revert = LocalizedString(zh: "撤销", en: "Revert")
    static let apply = LocalizedString(zh: "应用", en: "Apply")
    static let resetToBaseline = LocalizedString(zh: "重置草稿为契约基线",
                                                 en: "Reset the draft to the contract baseline")
    static let rescanMachine = LocalizedString(zh: "重新扫描本机", en: "Rescan this machine")
    static let a11yMoreActions = LocalizedString(zh: "更多设置操作", en: "More settings actions")
    static let loadingLine = LocalizedString(zh: "正在读取引擎状态与本地库…",
                                             en: "Reading engine state and the local store…")
    static let probeFailedTitle = LocalizedString(zh: "本地观测库探活失败",
                                                  en: "The local store probe failed")
    /// 这句承诺"设置项仍然可以改"，英文不许缩成 "unavailable"（会让人以为整页坏了）。
    static let probeFailedSubtitle = LocalizedString(
        zh: "设置项仍然可以改，但下面这些读数拿不到库侧数据。",
        en: "You can still change settings here, but the readings below have no store data behind them."
    )
    static let retry = LocalizedString(zh: "重试", en: "Retry")

    // 「本会话与持久化」那一格（口径与标题行的 `effectiveSummary` 不同，两行不重复）
    static let sessionPersistenceTitle = LocalizedString(zh: "本会话与持久化",
                                                         en: "This Session and Persistence")
    static let vsLaunchBaseline = LocalizedString(zh: "与启动基线", en: "Versus the launch baseline")
    static let draftDiverged = LocalizedString(zh: "草稿已偏离", en: "Draft has diverged")
    static let draftIsBaseline = LocalizedString(zh: "草稿即基线", en: "Draft equals the baseline")
    static let engineLabel = LocalizedString(zh: "引擎", en: "Engine")
    static let observedProjects = LocalizedString(zh: "已观测项目", en: "Projects observed")
    static let lastApplied = LocalizedString(zh: "上次应用", en: "Last applied")
    static let neverApplied = LocalizedString(zh: "本会话尚未应用", en: "Not applied yet this session")
    static let a11yHintPrefix = LocalizedString(zh: "提示：%@", en: "Hint: %@")

    // MARK: 隐私与安全面板（组标题 + 每个开关的"是什么 / 关了会怎样 / 为什么现在不生效"）

    static let noEventsYet = LocalizedString(
        zh: "本地库还没有事件，保留期暂时不产生任何回收动作。",
        en: "The local store has no events yet, so the retention cutoff has nothing to reclaim."
    )
    static let riskGroup = LocalizedString(zh: "风险确认", en: "Risk Confirmation")
    static let riskGroupSubtitle = LocalizedString(zh: "高危行为是否需要人工点确认",
                                                   en: "Whether high-risk actions need a manual confirmation")
    static let riskToggleTitle = LocalizedString(zh: "高危事件需人工确认",
                                                 en: "High-risk events need confirmation")
    static let riskToggleDetail = LocalizedString(
        zh: "开启后，HIGH / CRITICAL 事件在安全板块保留待确认态；关闭则只记录不打断。",
        en: "When on, HIGH / CRITICAL events stay awaiting confirmation on the Security board; "
            + "when off they are only recorded, never interrupting."
    )
    static let riskStateInterrupts = LocalizedString(zh: "≥ HIGH 会打断", en: "Interrupts at ≥ HIGH")
    static let riskStateRecordsOnly = LocalizedString(zh: "全部只记录", en: "Everything is only recorded")
    // #59 高危实时通知。文案不许承诺"即时/后台一定送达"——受系统授权与"重启生效"两个前提约束。
    static let notifyGroup = LocalizedString(zh: "高危实时通知", en: "High-Risk Notifications")
    static let notifyGroupSubtitle = LocalizedString(
        zh: "HIGH / CRITICAL 事件发一条 macOS 通知",
        en: "Post a macOS notification for HIGH / CRITICAL events")
    static let notifyToggleTitle = LocalizedString(zh: "高危事件发系统通知", en: "Notify on high-risk events")
    static let notifyToggleDetail = LocalizedString(
        zh: "关闭后不再弹系统通知（事件仍记录在安全板块）。通知正文只含等级、Agent 名与去路径、"
            + "脱敏后的命令摘要，不含完整路径与凭据。改此开关需重启生效；且需系统允许本 App 发送通知，"
            + "未授权时一律不发。",
        en: "When off, no system notification is posted (events are still recorded on the Security board). "
            + "The notification body carries only the level, agent name and a path-stripped, redacted "
            + "command summary — never full paths or credentials. Changes apply on relaunch, and macOS must "
            + "permit this app to notify; when unauthorized, nothing is sent.")
    static let notifyRestartNote = LocalizedString(
        zh: "改后重启生效（与主题、菜单栏同档）。",
        en: "Applies after relaunch (same as theme and the menu bar).")
    static let diffGroup = LocalizedString(zh: "Diff 明文", en: "Diff Plaintext")
    static let diffGroupSubtitle = LocalizedString(zh: "Before/After 的逐行正文是否写进本地库",
                                                   en: "Whether the per-line Before/After body is written to the store")
    static let diffToggleTitle = LocalizedString(zh: "Diff 正文入库", en: "Store diff bodies")
    /// 这句列了三样"关掉之后仍然保留"的东西（行数 / 改前来源 / 指纹），英文一个都不许掉，
    /// 否则读者会以为关掉开关等于把改前内容也抹了。
    static let diffToggleDetail = LocalizedString(
        zh: "关闭后只保留增删行数、改前内容的来源与内容指纹，逐行正文不再写库；下一条文件事件即用新值。",
        en: "When off, only the added/removed line counts, the provenance of the pre-change content "
            + "and content fingerprints are kept; per-line bodies stop being written. "
            + "The next file event already uses the new value."
    )
    static let diffNotRetroactive = LocalizedString(
        zh: "不追溯：已经入库的正文不会因为关闭而消失，本开关只管以后写什么。",
        en: "Not retroactive: bodies already in the store do not disappear when this is turned off. "
            + "The switch only governs what gets written from here on."
    )
    static let esGroupSubtitle = LocalizedString(zh: "系统级事件流，精度更高但需要系统授权",
                                                 en: "A system-level event stream: more precise, but needs authorization")
    static let esToggleTitle = LocalizedString(zh: "启用 Endpoint Security 采集",
                                               en: "Collect via Endpoint Security")
    static let esToggleDetail = LocalizedString(
        zh: "依赖系统扩展与 Entitlement：需在「系统设置 → 隐私与安全性」批准，并可能要求重启。",
        en: "Depends on a system extension and an entitlement: approve it in System Settings "
            + "→ Privacy & Security, and a reboot may be required."
    )
    /// 「即使批准也不会开始采集」是这一格最反直觉的一句，英文必须同样硬：
    /// 翻成 "requires approval" 就把"批准了也没用"说成了"批准就有用"。
    static let esCaveat = LocalizedString(
        zh: "当前版本未接入：即使批准也不会开始采集（`EndpointSecurityMonitor` 尚未装配进采集链）。"
            + "契约也没有授权状态查询，开关只记录草稿值。",
        en: "Not wired in this build: approving it will not start collection "
            + "(`EndpointSecurityMonitor` is not assembled into the capture chain). "
            + "The contract also exposes no authorization-state query, so this switch only records a draft value."
    )
    static let realtimeCapabilityLabel = LocalizedString(zh: "实时捕获能力", en: "Live capture capability")
    static let sensitivePrefixNote = LocalizedString(
        zh: "敏感前缀（来自契约 PathHeuristics.sensitivePrefixes）",
        en: "Sensitive prefixes (from the contract's PathHeuristics.sensitivePrefixes)"
    )
    /// 「演示输出」那一组。三条措辞各自钉一件事，别在后续改动里糊成一团：
    /// 组名说**这是什么**、detail 说**换在哪几处**、caveat 同时说**库里没改**与**要重启**。
    /// 少了"库里没改"这句，用户会以为开了之后历史也被脱敏（那是 #41 口径的反面）；
    /// 少了"要重启"这句，就是 ADR-0006 那个「有人拨、没人读」的老病。
    static let demoGroup = LocalizedString(zh: "演示输出", en: "Demo Output")
    static let demoGroupSubtitle = LocalizedString(
        zh: "只在给人读的那一份字符串上换占位符",
        en: "Placeholders appear only in what gets rendered"
    )
    static let demoToggleTitle = LocalizedString(
        zh: "演示/脉敏输出（路径换占位符）",
        en: "Demo output (mask paths with placeholders)"
    )
    /// #64：原来这句承诺了「界面路径列**与导出报告**」，而导出侧当时一个字都没接
    /// （ADR-0006 那个病：文案替没接上的消费者背书）。现在界面这一面**真的**全接上了
    /// ——不只是路径列：采集面说明、会话与项目的无障碍读数、Diff 副标题、
    /// 风险依据句、时间线剪贴板转储，全部走同一份映射（`PathPrivacy`）。
    /// 上一轮总控要求"没接线就不许写在脸上"，所以那句"与导出报告"被收回过；
    /// 装配点那行已由总控 `4e58abd` 落地（并有 `ExportPathMaskWiringTests` 钉着），
    /// 承诺按现状写回——但**要连着写清它和凭据脱敏是两个开关**，只开这一个不动那个。
    static let demoToggleDetail = LocalizedString(
        zh: "开启后，界面上每一处出现路径的地方（路径列、采集面说明、无障碍读数、"
            + "Diff 副标题、复制出去的转储）以及导出报告里的路径，都把本机主目录显示成 `~`、"
            + "监控根显示成 `<project>`；用于截图与对外分享。导出报告只在同时开启导出脱敏时生效。",
        en: "Everywhere a path reaches the screen — path columns, the capture-scope line, "
            + "accessibility read-outs, the diff subtitle, and text you copy out — and in exported "
            + "reports, this Mac's home directory renders as `~` and monitored roots as "
            + "`<project>`. Meant for screenshots and sharing. Exported reports honour this only "
            + "while export redaction is on."
    )
    /// #64 ③：开关的两态都要在屏上说得出口。关掉时那句是警告——
    /// 不能让人以为"没看见路径"就是"没泄漏路径"。
    static let demoToggleOnNotice = LocalizedString(
        zh: "当前开启：屏上每一处路径都是占位符。",
        en: "On now: every path on screen is a placeholder.")
    static let demoToggleOffNotice = LocalizedString(
        zh: "当前关闭：屏上与剪贴板里的路径都是本机原始绝对路径。",
        en: "Off now: paths on screen and on the pasteboard are this machine's raw absolute paths.")
    static let demoToggleCaveat = LocalizedString(
        zh: "库里存的仍是原始绝对路径：审计历史不可追溯改写，本开关只改显示。"
            + "渲染层在启动时读这份设置，改动要重启后生效。",
        en: "The database still stores the original absolute paths: audit history is never rewritten, "
            + "this switch only changes how things render. The rendering layer reads this setting at "
            + "launch, so a relaunch is required."
    )
    static let retentionGroup = LocalizedString(zh: "本地保留期", en: "Local Retention")
    static let retentionGroupSubtitle = LocalizedString(zh: "超期的事件与样本由引擎回收",
                                                        en: "The engine reclaims events and samples past the cutoff")
    static let retentionDays = LocalizedString(zh: "保留天数", en: "Retention days")
    static let retentionStepDetail = LocalizedString(zh: "整数步进：%1$d–%2$d 天",
                                                     en: "Whole-day steps: %1$d–%2$d")
    static let currentDraft = LocalizedString(zh: "当前草稿", en: "Current Draft")
    /// 「与会话内生效值一致」在关于页那一格也出现 ⇒ 一个出处。
    static let draftMatchesLive = LocalizedString(zh: "与会话内生效值一致",
                                                  en: "Matches the values live in this session")
    static let draftChangedUnapplied = LocalizedString(zh: "已改动，未应用", en: "Changed, not applied")
    static let dataBoundaryGroup = LocalizedString(zh: "数据边界", en: "Data Boundaries")
    /// 关于页那一格用的是同一句话 ⇒ 同一常量（第二个出处必分叉）。
    static let localOnlyStatement = LocalizedString(zh: "所有数据仅存本机，无任何网络上传。",
                                                    en: "All data stays on this Mac. Nothing is uploaded.")
    static let storePathsStatement = LocalizedString(
        zh: "观测库、事件与 diff 都写在本机 store 目录；本板块不发任何网络请求，"
            + "也没有遥测上报开关——因为没有上报路径。",
        en: "The observatory database, events and diffs are all written to the local store directory. "
            + "This pane makes no network requests and offers no telemetry toggle, because there is "
            + "no upload path at all."
    )
    static let storeDirectoryLabel = LocalizedString(zh: "Store 目录", en: "Store directory")

    // MARK: 存储与采集面板

    static let noRootsHint = LocalizedString(
        zh: "未配置监控根目录：引擎只能按内置策略回溯仓库根，覆盖面有限。",
        en: "No monitored roots: the engine can only infer repository roots by its built-in policy, "
            + "so coverage is limited."
    )
    static let monitoredRootsGroup = LocalizedString(zh: "监控根目录", en: "Monitored Roots")
    static let emptyRootsTitle = LocalizedString(zh: "还没有监控根目录", en: "No monitored roots yet")
    static let emptyRootsMessage = LocalizedString(
        zh: "添加若干目录后，引擎只会观测落在这些目录下的 AI 活动。",
        en: "Once you add directories, the engine observes only the AI activity landing under them."
    )
    static let addDocuments = LocalizedString(zh: "添加 ~/Documents", en: "Add ~/Documents")
    static let kindDirectory = LocalizedString(zh: "目录", en: "Directory")
    static let kindSuspectedFile = LocalizedString(zh: "疑似文件路径", en: "Looks like a file path")
    static let rootPlaceholder = LocalizedString(zh: "新增根目录，例如 ~/Projects 或 /Volumes/Work",
                                                 en: "Add a root, e.g. ~/Projects or /Volumes/Work")
    static let addAction = LocalizedString(zh: "添加", en: "Add")
    /// 这句说明"列表里存的是原样"，英文不许翻成"会自动展开"（那是使用处的行为，不是列表的）。
    static let tildeNote = LocalizedString(
        zh: "提示：`~` 会由契约的 PathHeuristics 在使用处展开，列表里保留你输入的原样。",
        en: "Note: `~` is expanded where it is used, by the contract's PathHeuristics. "
            + "The list keeps exactly what you typed."
    )
    static let ignoreRulesGroup = LocalizedString(zh: "忽略路径规则", en: "Ignored Path Rules")
    /// 判定权在契约，UI 不另写一套匹配——这句是"为什么这里不解释规则细节"的理由，英文要保住。
    static let ignoreRulesNote = LocalizedString(
        zh: "`*` 匹配任意长度字符，`?` 匹配单个字符；命中判定完全交给契约的 PatternMatcher，"
            + "UI 不另写一套匹配。",
        en: "`*` matches any run of characters and `?` a single one; the match itself is left entirely "
            + "to the contract's PatternMatcher — the UI does not keep a second implementation."
    )
    static let emptyRulesTitle = LocalizedString(zh: "没有忽略规则", en: "No ignore rules")
    static let emptyRulesMessage = LocalizedString(
        zh: "构建产物、缓存与依赖目录都会进入观测范围，噪声会明显变大。",
        en: "Build products, caches and dependency directories all fall inside the observation scope, "
            + "so the noise gets noticeably louder."
    )
    static let restoreContractDefaults = LocalizedString(zh: "恢复契约默认规则",
                                                         en: "Restore the contract defaults")
    static let rulePlaceholder = LocalizedString(zh: "新增规则，例如 */Carthage/*",
                                                 en: "Add a rule, e.g. */Carthage/*")
    static let restoreDefaults = LocalizedString(zh: "恢复默认", en: "Restore Defaults")
    static let samplingGroup = LocalizedString(zh: "采样频率", en: "Sampling Rate")
    static let samplingGroupSubtitle = LocalizedString(zh: "越小越精确，也越费电",
                                                       en: "Smaller is more precise, and costs more power")
    static let scanIntervalTitle = LocalizedString(zh: "进程扫描间隔", en: "Process scan interval")
    static let scanIntervalDetail = LocalizedString(zh: "区间 %1$d–%2$d 秒，步进 1 秒",
                                                    en: "Range %1$d–%2$d s, stepping by 1 s")
    static let storeReadonlySubtitle = LocalizedString(
        zh: "只读展示：契约没有开放写入口，改它不会落盘",
        en: "Read-only: the contract exposes no write path, so editing this would not persist"
    )
    static let storeEmptyValue = LocalizedString(zh: "（runtime.settings.storeDirectory 为空）",
                                                 en: "(runtime.settings.storeDirectory is empty)")
    static let writableLabel = LocalizedString(zh: "可写", en: "Writable")
    static let writableNoValue = LocalizedString(zh: "否（待总控开放 SettingsStoring）",
                                                 en: "No (awaiting a SettingsStoring seam)")
    static let probeHits = LocalizedString(zh: "示例路径可命中", en: "The sample path matches")
    static let probeMisses = LocalizedString(zh: "示例路径未命中", en: "The sample path does not match")
    static let a11yDeletePath = LocalizedString(zh: "删除 %@", en: "Delete %@")
    static let deleteHelp = LocalizedString(zh: "删除这条记录（只影响草稿）",
                                            en: "Delete this entry (affects the draft only)")
    /// 量词「条」：中文留、英文空（理由见 `TimelineCopy.measureWord`），故意不进表。
    static func countedRows(_ value: Int, _ language: AppLanguage) -> String {
        language == .chineseSimplified ? "\(value) 条" : "\(value)"
    }

    // MARK: 关于面板

    static let aboutEmptyHint = LocalizedString(
        zh: "本地库还没有项目数据，关于页的统计全为 0。",
        en: "The local database has no project data yet, so every count on this page is 0."
    )
    /// "AiX" 是产品名、不含中文 ⇒ 分组标题不需要条目；副标题里那句「数据只存本机」要说的是
    /// 边界，不是"这台 Mac 是数据存储地"，所以英文写 "data stays local" 而不是 "stored on this Mac"。
    static let aboutIdentitySubtitle = LocalizedString(
        zh: "macOS 本机观测台 · 数据只存本机",
        en: "A local macOS observatory · data stays on this Mac"
    )
    static let aboutVersionRow = LocalizedString(zh: "版本", en: "Version")
    static let aboutHostRow = LocalizedString(zh: "宿主", en: "Host")
    static let aboutHostValue = LocalizedString(zh: "AIObservatoryApp（SwiftPM 多 target）",
                                                en: "AIObservatoryApp (multi-target SwiftPM)")
    static let aboutScopeRow = LocalizedString(zh: "观测范围", en: "Observation scope")
    /// 「N 个根目录 · M 个项目」：英文没有单复数机制（见文件头），
    /// 写成 "%1$d root directories" 会在 1 的时候错，所以改成「标签: 数」的中性形状。
    static let aboutScopeValue = LocalizedString(zh: "%1$d 个根目录 · %2$d 个项目",
                                                 en: "Roots: %1$d · Projects: %2$d")
    static let aboutVersionPlaceholder = LocalizedString(zh: "占位", en: "placeholder")
    /// 「占位待宿主注入」是本 App 的真实状态（SwiftPM 下 Bundle 不含 App 信息），
    /// 英文不许翻成一个看起来正常的版本号。
    static let aboutVersionValue = LocalizedString(
        zh: "%1$@ (%2$@) · SwiftPM 下 Bundle 无 App 信息，占位待宿主注入",
        en: "%1$@ (%2$@) · A SwiftPM Bundle carries no app info, so this is a placeholder awaiting the host"
    )
    static let aboutPrivacyGroup = LocalizedString(zh: "隐私声明", en: "Privacy Statement")
    /// 三个「没有」是本板块存在的理由（没有开关因为根本没有路径），英文要同样把因果说完。
    static let aboutNoTelemetryStatement = LocalizedString(
        zh: "没有遥测、没有崩溃上报、没有云同步：本板块也不提供这些开关，因为契约里根本没有上报路径。"
            + "风险与命令审计数据全部落在本机 store 目录。",
        en: "No telemetry, no crash reporting, no cloud sync — and this pane offers no switch for them, "
            + "because the contract has no upload path at all. Risk and command audit data all land in "
            + "the local store directory."
    )
    static let aboutRetentionRow = LocalizedString(zh: "保留期", en: "Retention")
    static let aboutEngineGroup = LocalizedString(zh: "引擎", en: "Engine")
    /// 这句是在**划口径**：前三行是草稿、最后一行是启动声明。英文要是把它翻成
    /// "current engine state" 就正好说反了（那一组恰恰有四行不报现状）。
    static let aboutEngineGroupSubtitle = LocalizedString(
        zh: "前三行是草稿值，拨一下就变；最后一行报的是本进程启动时声明了什么",
        en: "The first three rows are draft values and change as you toggle them. "
            + "The last row reports what this process declared at launch."
    )
    static let aboutESDraftOn = LocalizedString(zh: "草稿开启（本版本未接入）",
                                                en: "On in the draft (not wired in this build)")
    static let aboutOff = LocalizedString(zh: "关闭", en: "Off")
    static let aboutMenuBarRow = LocalizedString(zh: "菜单栏 Extra", en: "Menu bar extra")
    static let aboutDraftSnapshotGroup = LocalizedString(zh: "当前草稿快照", en: "Current Draft Snapshot")
    /// 「有 N 项未应用」同上：避开 "%d items"，用「未应用: N」的中性形状。
    static let aboutPendingUnapplied = LocalizedString(zh: "有 %1$d 项未应用", en: "Unapplied: %1$d")
    static let aboutAppliedThisSession = LocalizedString(zh: "本会话已应用", en: "Applied in this session")
    static let aboutBaselineRuntimeSettings = LocalizedString(zh: "基线 runtime.settings",
                                                              en: "Baseline runtime.settings")
    static let aboutDraftEncodeFailed = LocalizedString(zh: "（草稿序列化失败）",
                                                         en: "(the draft failed to encode)")
    static let aboutFormattingGroup = LocalizedString(zh: "格式化样例", en: "Formatting Samples")
    static let aboutFormattingGroupSubtitle = LocalizedString(
        zh: "契约 DateFormat / DurationFormat 的真实输出",
        en: "Real output from the contract's DateFormat / DurationFormat"
    )
    static let aboutCreditGroup = LocalizedString(zh: "署名", en: "Credits")
    static let aboutContractRow = LocalizedString(zh: "契约", en: "Contract")
    static let aboutThisPaneRow = LocalizedString(zh: "本板块", en: "This pane")
    static let aboutThisPaneValue = LocalizedString(zh: "Projects 视图层 + Settings 全套",
                                                    en: "The Projects view layer plus all of Settings")
    static let aboutNoNewPersistencePath = LocalizedString(
        zh: "Projects 与 Settings 都不新增任何持久化路径：数据一律经 AIObservatoryCore 的只读契约查询。",
        en: "Neither Projects nor Settings adds a persistence path: every read goes through "
            + "AIObservatoryCore's read-only contract queries."
    )
    /// 样例行的无障碍标签：中文说「键 等于 值」，英文用这一行本来就长成的 `=`（VoiceOver 念作
    /// "equals"）。为什么不是单词：复数尺子会把格式符后面任何以 `s` 收尾的词判成
    /// "%d sessions" 那一类硬伤，而 "equals"/"yields"/"shows" 全中招 —— 换符号是这一行的原形状，
    /// 不是绕开门禁。
    static let aboutA11yEquals = LocalizedString(zh: "%1$@ 等于 %2$@", en: "%1$@ = %2$@")

    // MARK: 设置数据模型（顶部常驻说明、一次性提示、派生读数）

    /// 顶部常驻那句。**三档口径必须分开**：已生效 / 需重启 / 根本没接入。
    /// 英文若把后两档糊成 "takes effect after a relaunch" 就等于给两个空开关背书
    /// （中文原文特意分成两个分句，就是为了这个）。
    static let persistenceNotice = LocalizedString(
        zh: "设置已应用到运行中的引擎并保存到本机数据目录；主题、菜单栏与数据库目录需重启生效；"
            + "开机启动与 EndpointSecurity 尚未接入系统接口，改它们不会有任何效果（只记录草稿）。",
        en: "Settings are applied to the running engine and saved to the local data directory. "
            + "Theme, the menu bar and the database directory need a relaunch. Launch at login and "
            + "EndpointSecurity are not wired to any system API, so changing them does nothing at all "
            + "— only the draft value is recorded."
    )
    static let launchAtLoginDetail = LocalizedString(
        zh: "开机后自动拉起观测引擎——尚未接入系统登录项，当前不会生效。",
        en: "Brings up the observatory engine after you log in — not wired to the system login items, "
            + "so it does nothing today."
    )
    static let revertDone = LocalizedString(
        zh: "已丢弃未应用的修改，回到本次会话内生效的设置。",
        en: "Discarded the unapplied changes and went back to the settings live in this session."
    )
    static let baselineReset = LocalizedString(
        zh: "草稿已重置为契约基线（runtime.settings）。",
        en: "The draft was reset to the contract baseline (runtime.settings)."
    )
    /// 「本进程不变」是这条提醒的全部价值，英文不许软成 "may require a restart"。
    static let menuBarRestartReminder = LocalizedString(
        zh: "其中「显示菜单栏 Extra」与本次启动的声明不一致：本进程不变，重启后生效。",
        en: "Among them, \"Show Menu Bar Extra\" differs from what this process declared at launch: "
            + "nothing changes now — it takes effect after a relaunch."
    )
    static let menuBarDeclared = LocalizedString(zh: "已声明菜单栏", en: "Menu bar declared")
    static let menuBarNotDeclared = LocalizedString(zh: "未声明菜单栏", en: "Menu bar not declared")
    /// 后缀直接拼在上面那句后面 ⇒ 英文自带前导空格，中文用全角括号。
    static let menuBarDraftPending = LocalizedString(zh: "（草稿待重启）", en: " (draft needs a relaunch)")
    static let rootEmptyNotice = LocalizedString(zh: "监控根目录不能为空。",
                                                 en: "A monitored root cannot be empty.")
    static let rootDuplicateNotice = LocalizedString(zh: "该根目录已在监控列表里。",
                                                     en: "That root is already in the monitored list.")
    /// 「点『应用』后本次会话内生效」是这一页最容易忘的一步，英文要保住那个动作名
    /// （按钮的英文侧就叫 Apply，见 `apply`）。
    static let draftAddedNotice = LocalizedString(
        zh: "已加入草稿，点「应用」后本次会话内生效。",
        en: "Added to the draft. Press Apply and it takes effect for this session."
    )
    static let draftRemovedNotice = LocalizedString(
        zh: "已从草稿移除，点「应用」后本次会话内生效。",
        en: "Removed from the draft. Press Apply and it takes effect for this session."
    )
    static let ruleEmptyNotice = LocalizedString(zh: "忽略规则不能为空。",
                                                 en: "An ignore rule cannot be empty.")
    static let ruleExistsNotice = LocalizedString(zh: "该规则已存在。", en: "That rule already exists.")
    static let ruleMatchesEverythingNotice = LocalizedString(
        zh: "该规则会命中所有路径（含根目录），相当于停止观测——点「应用」前请确认。",
        en: "This rule matches every path, roots included — which is effectively stopping observation. "
            + "Check it before pressing Apply."
    )
    static let rulesRestoredNotice = LocalizedString(
        zh: "已恢复契约默认忽略规则（.build / node_modules / Caches / DerivedData 等）。",
        en: "Restored the contract's default ignore rules (.build / node_modules / Caches / DerivedData "
            + "and so on)."
    )
    static let capabilityMissingHost = LocalizedString(
        zh: "未接入：本宿主没有提供能力读数",
        en: "Not wired: this host exposes no capability reading"
    )
    /// 「不知道」不等于「全量」是这句的落点，英文翻成 "unknown means full" 会把警告说反。
    static let capabilityFidelityUnknown = LocalizedString(
        zh: "引擎未暴露 realtimeCapability()，所以这里不声明采集保真度："
            + "「不知道」不等于「全量」，命令审计请按可能漏采来看待。",
        en: "The engine does not expose realtimeCapability(), so no capture fidelity is claimed here: "
            + "\"not known\" is not \"complete\" — read command auditing as possibly partial."
    )
    static let scanIntervalValue = LocalizedString(zh: "%.1f 秒", en: "%.1f s")
    /// 「N 天」：英文侧 "%1$d days" 会命中复数尺子（1 天时错），而这一行的标签已经是
    /// Retention / Retention days ⇒ 用与 `retentionStepDetail`（"Whole-day steps"）同一档的
    /// 单位缩写 `d`，既不带复数也不重复标签。
    static let retentionValue = LocalizedString(zh: "%1$d 天", en: "%1$d d")
    static let rootsUnconfiguredSummary = LocalizedString(
        zh: "未配置：引擎将按内置策略推断仓库根",
        en: "Not configured: the engine infers repository roots by its built-in policy"
    )
    /// 「已配置 N 条」的量词英文本就该空 ⇒ 用「标签: 数」的中性形状（同上，避免 "%1$d roots"）。
    static let rootsConfiguredSummary = LocalizedString(zh: "已配置 %1$d 条", en: "Configured: %1$d")
    static let rulesUnconfiguredSummary = LocalizedString(zh: "未配置：不忽略任何路径",
                                                          en: "Not configured: no path is ignored")
    static let rulesConfiguredSummary = LocalizedString(zh: "已配置 %1$d 条规则",
                                                        en: "Rules configured: %1$d")
    static let storeDirectoryMissing = LocalizedString(
        zh: "（未由宿主提供，契约尚未开放写入入口）",
        en: "(not supplied by the host; the contract opens no write seam yet)"
    )
    static let appliedInSession = LocalizedString(zh: "会话内已应用", en: "Applied in this session")
    /// 时间戳括注：中文全角紧贴，英文要自带一个前导空格（否则 "session(Nov 14)" 挤成一团）。
    static let appliedTimestampParen = LocalizedString(zh: "（%@）", en: " (%@)")
    static let stillContractBaseline = LocalizedString(zh: "仍为契约基线 runtime.settings",
                                                       en: "Still the contract baseline runtime.settings")


    // MARK: appearance 组文案（6 条，key 前缀 appearance.*）
    static let appearanceCopy: [NamedCopy] = [
        NamedCopy("settings.appearance.group", appearanceGroup),
        NamedCopy("settings.appearance.subtitle", appearanceSubtitle),
        NamedCopy("settings.appearance.themeRow", themeRow),
        NamedCopy("settings.appearance.appliesRow", themeAppliesRow),
        NamedCopy("settings.appearance.followsSystem", themeFollowsSystem),
        NamedCopy("settings.appearance.forced", themeForced),
    ]

    // MARK: menuBar 组文案（6 条，key 前缀 menuBar.*）
    static let menuBarCopy: [NamedCopy] = [
        NamedCopy("settings.menuBar.group", menuBarGroup),
        NamedCopy("settings.menuBar.subtitle", menuBarGroupSubtitle),
        NamedCopy("settings.menuBar.toggleTitle", menuBarToggleTitle),
        NamedCopy("settings.menuBar.toggleDetail", menuBarToggleDetail),
        NamedCopy("settings.menuBar.toggleCaveat", menuBarToggleCaveat),
        NamedCopy("settings.menuBar.thisLaunch", menuBarThisLaunch),
    ]

    // MARK: login 组文案（2 条，key 前缀 login.*）
    static let loginCopy: [NamedCopy] = [
        NamedCopy("settings.login.launchTitle", launchAtLoginTitle),
        NamedCopy("settings.login.notWiredCaveat", launchAtLoginCaveat),
    ]

    // MARK: engine 组文案（10 条，key 前缀 engine.*）
    static let engineCopy: [NamedCopy] = [
        NamedCopy("settings.engine.group", engineGroup),
        NamedCopy("settings.engine.subtitle", engineGroupSubtitle),
        NamedCopy("settings.engine.samplingCadence", samplingCadence),
        NamedCopy("settings.engine.stop", stopEngine),
        NamedCopy("settings.engine.start", startEngine),
        NamedCopy("settings.engine.rescan", rescan),
        NamedCopy("settings.engine.runningHint", engineRunningHint),
        NamedCopy("settings.engine.stoppedHint", engineStoppedHint),
        NamedCopy("settings.engine.statePrefix", engineStatePrefix),
        NamedCopy("settings.engine.noProjectsHint", noProjectsHint),
    ]

    // MARK: pane 组文案（8 条，key 前缀 pane.*）
    static let paneCopy: [NamedCopy] = [
        NamedCopy("settings.pane.general", paneGeneral),
        NamedCopy("settings.pane.privacy", panePrivacy),
        NamedCopy("settings.pane.storage", paneStorage),
        NamedCopy("settings.pane.about", paneAbout),
        NamedCopy("settings.pane.subtitleGeneral", paneSubtitleGeneral),
        NamedCopy("settings.pane.subtitlePrivacy", paneSubtitlePrivacy),
        NamedCopy("settings.pane.subtitleStorage", paneSubtitleStorage),
        NamedCopy("settings.pane.subtitleAbout", paneSubtitleAbout),
    ]

    // MARK: page 组文案（10 条，key 前缀 page.*）
    static let pageCopy: [NamedCopy] = [
        NamedCopy("settings.page.subtitle", pageSubtitle),
        NamedCopy("settings.page.panePickerLabel", panePickerLabel),
        NamedCopy("settings.page.a11ySwitchPane", a11ySwitchPane),
        NamedCopy("settings.page.pendingChanges", pendingChanges),
        NamedCopy("settings.page.revert", revert),
        NamedCopy("settings.page.apply", apply),
        NamedCopy("settings.page.resetToBaseline", resetToBaseline),
        NamedCopy("settings.page.rescanMachine", rescanMachine),
        NamedCopy("settings.page.a11yMoreActions", a11yMoreActions),
        NamedCopy("settings.page.loadingLine", loadingLine),
    ]

    // MARK: error 组文案（2 条，key 前缀 error.*）
    static let errorCopy: [NamedCopy] = [
        NamedCopy("settings.error.probeFailedTitle", probeFailedTitle),
        NamedCopy("settings.error.probeFailedSubtitle", probeFailedSubtitle),
    ]

    // MARK: page2 组文案（1 条，key 前缀 page.*）
    static let page2Copy: [NamedCopy] = [
        NamedCopy("settings.page.retry", retry),
    ]

    // MARK: session 组文案（8 条，key 前缀 session.*）
    static let sessionCopy: [NamedCopy] = [
        NamedCopy("settings.session.title", sessionPersistenceTitle),
        NamedCopy("settings.session.vsLaunchBaseline", vsLaunchBaseline),
        NamedCopy("settings.session.draftDiverged", draftDiverged),
        NamedCopy("settings.session.draftIsBaseline", draftIsBaseline),
        NamedCopy("settings.session.engineLabel", engineLabel),
        NamedCopy("settings.session.observedProjects", observedProjects),
        NamedCopy("settings.session.lastApplied", lastApplied),
        NamedCopy("settings.session.neverApplied", neverApplied),
    ]

    // MARK: hint 组文案（1 条，key 前缀 hint.*）
    static let hintCopy: [NamedCopy] = [
        NamedCopy("settings.hint.a11yPrefix", a11yHintPrefix),
    ]

    // MARK: privacy 组文案（39 条，key 前缀 privacy.*）
    static let privacyCopy: [NamedCopy] = [

        NamedCopy("settings.privacy.noEventsYet", noEventsYet),
        NamedCopy("settings.privacy.riskGroup", riskGroup),
        NamedCopy("settings.privacy.riskGroupSubtitle", riskGroupSubtitle),
        NamedCopy("settings.privacy.riskToggleTitle", riskToggleTitle),
        NamedCopy("settings.privacy.riskToggleDetail", riskToggleDetail),
        NamedCopy("settings.privacy.riskStateInterrupts", riskStateInterrupts),
        NamedCopy("settings.privacy.riskStateRecordsOnly", riskStateRecordsOnly),
        NamedCopy("settings.privacy.notifyGroup", notifyGroup),
        NamedCopy("settings.privacy.notifyGroupSubtitle", notifyGroupSubtitle),
        NamedCopy("settings.privacy.notifyToggleTitle", notifyToggleTitle),
        NamedCopy("settings.privacy.notifyToggleDetail", notifyToggleDetail),
        NamedCopy("settings.privacy.notifyRestartNote", notifyRestartNote),
        NamedCopy("settings.privacy.diffGroup", diffGroup),
        NamedCopy("settings.privacy.diffGroupSubtitle", diffGroupSubtitle),
        NamedCopy("settings.privacy.diffToggleTitle", diffToggleTitle),
        NamedCopy("settings.privacy.diffToggleDetail", diffToggleDetail),
        NamedCopy("settings.privacy.diffNotRetroactive", diffNotRetroactive),
        NamedCopy("settings.privacy.esGroupSubtitle", esGroupSubtitle),
        NamedCopy("settings.privacy.esToggleTitle", esToggleTitle),
        NamedCopy("settings.privacy.esToggleDetail", esToggleDetail),
        NamedCopy("settings.privacy.esCaveat", esCaveat),
        NamedCopy("settings.privacy.realtimeCapability", realtimeCapabilityLabel),
        NamedCopy("settings.privacy.sensitivePrefixNote", sensitivePrefixNote),
        NamedCopy("settings.privacy.demoGroup", demoGroup),
        NamedCopy("settings.privacy.demoGroupSubtitle", demoGroupSubtitle),
        NamedCopy("settings.privacy.demoToggleTitle", demoToggleTitle),
        NamedCopy("settings.privacy.demoToggleDetail", demoToggleDetail),
        NamedCopy("settings.privacy.demoToggleOnNotice", demoToggleOnNotice),
        NamedCopy("settings.privacy.demoToggleOffNotice", demoToggleOffNotice),
        NamedCopy("settings.privacy.demoToggleCaveat", demoToggleCaveat),
        NamedCopy("settings.privacy.retentionGroup", retentionGroup),
        NamedCopy("settings.privacy.retentionGroupSubtitle", retentionGroupSubtitle),
        NamedCopy("settings.privacy.retentionDays", retentionDays),
        NamedCopy("settings.privacy.retentionStepDetail", retentionStepDetail),
        NamedCopy("settings.privacy.currentDraft", currentDraft),
        NamedCopy("settings.privacy.draftMatchesLive", draftMatchesLive),
        NamedCopy("settings.privacy.draftChangedUnapplied", draftChangedUnapplied),
        NamedCopy("settings.privacy.dataBoundaryGroup", dataBoundaryGroup),
        NamedCopy("settings.privacy.localOnlyStatement", localOnlyStatement),
        NamedCopy("settings.privacy.storePathsStatement", storePathsStatement),
        NamedCopy("settings.privacy.storeDirectoryLabel", storeDirectoryLabel),
    ]

    // MARK: storage 组文案（29 条，key 前缀 storage.*）
    static let storageCopy: [NamedCopy] = [

        NamedCopy("settings.storage.noRootsHint", noRootsHint),
        NamedCopy("settings.storage.monitoredRootsGroup", monitoredRootsGroup),
        NamedCopy("settings.storage.emptyRootsTitle", emptyRootsTitle),
        NamedCopy("settings.storage.emptyRootsMessage", emptyRootsMessage),
        NamedCopy("settings.storage.addDocuments", addDocuments),
        NamedCopy("settings.storage.kindDirectory", kindDirectory),
        NamedCopy("settings.storage.kindSuspectedFile", kindSuspectedFile),
        NamedCopy("settings.storage.rootPlaceholder", rootPlaceholder),
        NamedCopy("settings.storage.addAction", addAction),
        NamedCopy("settings.storage.tildeNote", tildeNote),
        NamedCopy("settings.storage.ignoreRulesGroup", ignoreRulesGroup),
        NamedCopy("settings.storage.ignoreRulesNote", ignoreRulesNote),
        NamedCopy("settings.storage.emptyRulesTitle", emptyRulesTitle),
        NamedCopy("settings.storage.emptyRulesMessage", emptyRulesMessage),
        NamedCopy("settings.storage.restoreContractDefaults", restoreContractDefaults),
        NamedCopy("settings.storage.rulePlaceholder", rulePlaceholder),
        NamedCopy("settings.storage.restoreDefaults", restoreDefaults),
        NamedCopy("settings.storage.samplingGroup", samplingGroup),
        NamedCopy("settings.storage.samplingGroupSubtitle", samplingGroupSubtitle),
        NamedCopy("settings.storage.scanIntervalTitle", scanIntervalTitle),
        NamedCopy("settings.storage.scanIntervalDetail", scanIntervalDetail),
        NamedCopy("settings.storage.storeReadonlySubtitle", storeReadonlySubtitle),
        NamedCopy("settings.storage.storeEmptyValue", storeEmptyValue),
        NamedCopy("settings.storage.writableLabel", writableLabel),
        NamedCopy("settings.storage.writableNoValue", writableNoValue),
        NamedCopy("settings.storage.probeHits", probeHits),
        NamedCopy("settings.storage.probeMisses", probeMisses),
        NamedCopy("settings.storage.a11yDeletePath", a11yDeletePath),
        NamedCopy("settings.storage.deleteHelp", deleteHelp),
    ]

    // MARK: about 组文案（30 条，key 前缀 about.*）
    static let aboutCopy: [NamedCopy] = [

        NamedCopy("settings.about.emptyHint", aboutEmptyHint),
        NamedCopy("settings.about.identitySubtitle", aboutIdentitySubtitle),
        NamedCopy("settings.about.versionRow", aboutVersionRow),
        NamedCopy("settings.about.hostRow", aboutHostRow),
        NamedCopy("settings.about.hostValue", aboutHostValue),
        NamedCopy("settings.about.scopeRow", aboutScopeRow),
        NamedCopy("settings.about.scopeValue", aboutScopeValue),
        NamedCopy("settings.about.versionPlaceholder", aboutVersionPlaceholder),
        NamedCopy("settings.about.versionValue", aboutVersionValue),
        NamedCopy("settings.about.privacyGroup", aboutPrivacyGroup),
        NamedCopy("settings.about.noTelemetryStatement", aboutNoTelemetryStatement),
        NamedCopy("settings.about.retentionRow", aboutRetentionRow),
        NamedCopy("settings.about.engineGroup", aboutEngineGroup),
        NamedCopy("settings.about.engineGroupSubtitle", aboutEngineGroupSubtitle),
        NamedCopy("settings.about.esDraftOn", aboutESDraftOn),
        NamedCopy("settings.about.off", aboutOff),
        NamedCopy("settings.about.menuBarRow", aboutMenuBarRow),
        NamedCopy("settings.about.draftSnapshotGroup", aboutDraftSnapshotGroup),
        NamedCopy("settings.about.pendingUnapplied", aboutPendingUnapplied),
        NamedCopy("settings.about.appliedThisSession", aboutAppliedThisSession),
        NamedCopy("settings.about.baselineRuntimeSettings", aboutBaselineRuntimeSettings),
        NamedCopy("settings.about.draftEncodeFailed", aboutDraftEncodeFailed),
        NamedCopy("settings.about.formattingGroup", aboutFormattingGroup),
        NamedCopy("settings.about.formattingGroupSubtitle", aboutFormattingGroupSubtitle),
        NamedCopy("settings.about.creditGroup", aboutCreditGroup),
        NamedCopy("settings.about.contractRow", aboutContractRow),
        NamedCopy("settings.about.thisPaneRow", aboutThisPaneRow),
        NamedCopy("settings.about.thisPaneValue", aboutThisPaneValue),
        NamedCopy("settings.about.noNewPersistencePath", aboutNoNewPersistencePath),
        NamedCopy("settings.about.a11yEquals", aboutA11yEquals),
    ]

    // MARK: model 组文案（28 条，key 前缀 model.*）
    static let modelCopy: [NamedCopy] = [

        NamedCopy("settings.model.persistenceNotice", persistenceNotice),
        NamedCopy("settings.model.launchAtLoginDetail", launchAtLoginDetail),
        NamedCopy("settings.model.revertDone", revertDone),
        NamedCopy("settings.model.baselineReset", baselineReset),
        NamedCopy("settings.model.menuBarRestartReminder", menuBarRestartReminder),
        NamedCopy("settings.model.menuBarDeclared", menuBarDeclared),
        NamedCopy("settings.model.menuBarNotDeclared", menuBarNotDeclared),
        NamedCopy("settings.model.menuBarDraftPending", menuBarDraftPending),
        NamedCopy("settings.model.rootEmptyNotice", rootEmptyNotice),
        NamedCopy("settings.model.rootDuplicateNotice", rootDuplicateNotice),
        NamedCopy("settings.model.draftAddedNotice", draftAddedNotice),
        NamedCopy("settings.model.draftRemovedNotice", draftRemovedNotice),
        NamedCopy("settings.model.ruleEmptyNotice", ruleEmptyNotice),
        NamedCopy("settings.model.ruleExistsNotice", ruleExistsNotice),
        NamedCopy("settings.model.ruleMatchesEverythingNotice", ruleMatchesEverythingNotice),
        NamedCopy("settings.model.rulesRestoredNotice", rulesRestoredNotice),
        NamedCopy("settings.model.capabilityMissingHost", capabilityMissingHost),
        NamedCopy("settings.model.capabilityFidelityUnknown", capabilityFidelityUnknown),
        NamedCopy("settings.model.scanIntervalValue", scanIntervalValue),
        NamedCopy("settings.model.retentionValue", retentionValue),
        NamedCopy("settings.model.rootsUnconfiguredSummary", rootsUnconfiguredSummary),
        NamedCopy("settings.model.rootsConfiguredSummary", rootsConfiguredSummary),
        NamedCopy("settings.model.rulesUnconfiguredSummary", rulesUnconfiguredSummary),
        NamedCopy("settings.model.rulesConfiguredSummary", rulesConfiguredSummary),
        NamedCopy("settings.model.storeDirectoryMissing", storeDirectoryMissing),
        NamedCopy("settings.model.appliedInSession", appliedInSession),
        NamedCopy("settings.model.appliedTimestampParen", appliedTimestampParen),
        NamedCopy("settings.model.stillContractBaseline", stillContractBaseline),
    ]

    /// 本目录全部用户可见文案。**门禁用例遍历它断言 `copyProblems` 为空**。
    static let bilingualCopy: [NamedCopy] =
        appearanceCopy
        + menuBarCopy
        + loginCopy
        + engineCopy
        + paneCopy
        + pageCopy
        + errorCopy
        + page2Copy
        + sessionCopy
        + hintCopy
        + privacyCopy
        + storageCopy
        + aboutCopy
        + modelCopy

}
