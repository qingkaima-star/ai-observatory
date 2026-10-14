//
//  ExitChannelInventory.swift
//  AIObservatoryUITests
//
//  Owner: WS-exitlist（#89 出口脉敏清单）
//  ─────────────────────────────────────────────────────────
//  「哪些出口会把本机真实路径 / 命令 / 凭据带出去」的**唯一清单**。
//
//  为什么是一段代码而不是一份 markdown：文档不会红。#64 的教训写得很清楚——
//  逐格断言全绿，而实拍上明晃晃挂着 `/Users/dev`，因为「被钉过的那一格干净」从来
//  不等于「这一页干净」。清单要在**有人新加一个出口却不登记**时当场判红，
//  它就必须住在测试里。
//
//  三把尺（用例在 `ExitChannelInventoryTests.swift`）：
//   ① 份数与分母：总条数、各面条数、「登记为不遮」的条数全部钉死。加一条要同时改数字，
//      改数字的人会看见这张表。
//   ② 接线针：每条指着源码里那一行遮罩调用（`anchors` 剥注释后逐字比）。
//      遮罩被重构掉 ⇒ 红。`docAnchors` 允许命中注释：口径注释被删也值得红一次。
//   ③ 证据针：`evidence` 指着 `Tests/` 里一条**真的**用例（文件名 + 用例名片段）。
//      指着不存在的用例 ⇒ 红。这一把是防"表写得很漂亮而没人测过"。
//
//  ⚠️ `offBehavior` 不许留空：开关关掉时这一格输出什么，是这张表存在的理由之一。
//  ⚠️ 两个 flag 不许合并：凭据脱敏是安全边界（默认开），路径遮罩是演示显示口径（默认关）。
//

import Foundation

// MARK: - 清单的一格

/// 一个「信息离开本 App」的出口。
struct ExitChannel: Hashable {

    /// 离开的方式。`ui` 之外都不经过屏幕，因此**更**容易漏（没人看得见）。
    enum Surface: String, CaseIterable {
        case ui, clipboard, export, notification, cli, store, log
    }

    /// 这一格装的是什么。`countOrID` 与 `leafNameOnly` 是「看着像路径出口但其实不承重」那两类——
    /// 它们**必须写在表里**，否则下一手只能重新推断一次（推断会飘，本仓为此付过学费）。
    enum Payload: String {
        case absolutePath
        case commandLine
        case credential
        case structuredDump   // 整份设置草稿的 JSON
        case leafNameOnly     // 只有末段名
        case countOrID        // 数字、`R-004` 这类规则编号
        case databaseTruth    // 库里那份原文：按 #41 冻结，遮它是错的
    }

    /// 接的是哪一把遮罩。
    enum MaskKind: String {
        /// 视图读 `@Environment(\.demoRedaction)`，对**拼好的整句**做 `scrub`。
        case environmentScrub
        /// 走 `FilePathText`（组件内 `apply` + `Mask.tail`）。
        case filePathText
        /// 组件自带遮罩（`MonospacedCodeView` / `SectionHeader` / `EmptyStateView`）。
        case componentOwned
        /// 导出件的 `ExportRedactor.redact`（凭据与路径同一把）。
        case exportRedactor
        /// 通知正文那一条：`PathPrivacy.deabsolutized`（只留末段，比占位符更严）。
        case deabsolutized
        /// **没有遮罩**：要么按设计不该遮（`store`），要么是本单交回总控的越界项。
        case none
    }

    /// 由哪个开关决定。**两个 flag 不许合并**（派单硬约束）。
    enum PrivacyFlag: String {
        case pathMask              // `demoRedactedOutput`，默认关
        case credentialRedaction   // `ExportRequest.redactionEnabled`，默认开
        case cliPathRedact         // CLI `--redact`
        case cliCredentialRedact   // CLI `--no-redact`
        case alwaysOn              // 没有开关，永远遮（通知正文）
        case none                  // 不受任何开关影响
    }

    let id: String
    let surface: Surface
    /// 人话：这一格在哪一屏 / 哪个件。
    let place: String
    let payloads: [Payload]
    let mask: MaskKind
    let flag: PrivacyFlag
    /// 源码级接线针 `"文件|代码片段"`：剥注释后必须命中。
    let anchors: [String]
    /// 口径级针 `"文件|片段"`：允许命中注释。
    let docAnchors: [String]
    /// `"测试文件|用例名片段"`；空串 = 本单没有行为证据（理由必须写在 `offBehavior` 里）。
    let evidence: String
    /// 开关关掉时这一格输出什么。不许空。
    let offBehavior: String

    /// 这一格会不会把这台机器的形状带出去。
    var carriesSensitivePayload: Bool {
        payloads.contains(.absolutePath) || payloads.contains(.commandLine)
            || payloads.contains(.credential) || payloads.contains(.structuredDump)
    }

    var isCovered: Bool { mask != .none }
}

// MARK: - 清单本体

enum ExitChannelInventory {

    /// 紧凑构造：条目写成一行可读的数据，而不是二十行键名。
    private static func ch(
        _ id: String, _ surface: ExitChannel.Surface, _ place: String,
        _ payloads: [ExitChannel.Payload], _ mask: ExitChannel.MaskKind,
        _ flag: ExitChannel.PrivacyFlag,
        anchors: [String] = [], docAnchors: [String] = [],
        evidence: String = "", off: String
    ) -> ExitChannel {
        ExitChannel(id: id, surface: surface, place: place, payloads: payloads, mask: mask,
                    flag: flag, anchors: anchors, docAnchors: docAnchors, evidence: evidence,
                    offBehavior: off)
    }

    static let channels: [ExitChannel] = [

        // ───────────────────────── 界面 · 概览
        ch("ui.dashboard.agentWorkingDirectory", .ui,
           "概览页「常驻 Agent」那一行的工作目录（末两级）",
           [.absolutePath], .filePathText, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Dashboard/DashboardActiveAgentsList.swift|FilePathText(path: workingDirectory, mode: .lastTwoComponents)"],
           evidence: "Tests/AIObservatoryUITests/PathPrivacyMaskTests.swift|末两级不许扔掉占位符",
           off: "关闭 ⇒ 与今天逐字一致：按 `/` 取末两段原样上屏。派单例子里那一串 `Users/<本机用户名>` 就是这一档"
                + "（Agent 的 cwd 恰好是家目录本身，末两级正好等于整个家目录）"),
        ch("ui.dashboard.riskRowTitle", .ui,
           "概览页风险事件那一行的标题",
           [.countOrID], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Dashboard/DashboardView.swift|Text(demoRedaction.scrub(risk.title))"],
           off: "关闭 ⇒ 原文（今天的规则标题不含路径，`scrub` 对它是恒等）。登记它是因为这一族统一走整句遮罩"),
        ch("ui.dashboard.anomalySummary", .ui,
           "概览页异常卡片的一行 + 念给 VoiceOver 那一句",
           [.countOrID], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Dashboard/DashboardAnomalyCard.swift|Text(demoRedaction.scrub(finding.summary))"],
           off: "关闭 ⇒ 原文（今天只有数字，但同一个类型里就躺着 `AnomalyFinding.projectPath`）"),

        // ───────────────────────── 界面 · 命令审计
        ch("ui.commands.rowCommandLine", .ui,
           "命令页每一行的命令行（正文与 tooltip 两条出口）",
           [.commandLine, .absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Commands/CommandAuditRow.swift|Text(demoRedaction.scrub(record.commandLine))",
                     "Sources/AIObservatoryUI/Commands/CommandAuditRow.swift|.help(demoRedaction.scrub(record.commandLine))"],
           evidence: "Tests/AIObservatoryUITests/RenderedPageRedactionTests.swift|关掉映射时",
           off: "关闭 ⇒ 整条命令行原文（`rm -rf /Users/…` 的目标路径就在这一行）"),
        ch("ui.commands.rowA11y", .ui,
           "命令页每一行念给 VoiceOver 的摘要（整句拼）",
           [.commandLine], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Commands/CommandAuditRow.swift|.accessibilityLabel(demoRedaction.scrub(CommandAuditFormat.summary(of: record)))"],
           off: "关闭 ⇒ 摘要整句原文。耳朵是这条页面的另一张屏"),
        ch("ui.commands.detailCommandBlock", .ui,
           "命令详情整块命令行（`MonospacedCodeView`，带复制按钮）",
           [.commandLine, .absolutePath], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/DesignSystem/MonospacedCodeView.swift|private var scrubbed: String { demoRedaction.scrub(text) }"],
           evidence: "Tests/AIObservatoryUITests/ComponentRedactionTests.swift|等宽代码块",
           off: "关闭 ⇒ 屏上与剪贴板都是原文，与改造前逐字一致"),
        ch("ui.commands.detailPaths", .ui,
           "命令详情的 工作目录 与 项目路径 两行",
           [.absolutePath], .filePathText, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Commands/CommandsDetailView.swift|FilePathText("],
           off: "关闭 ⇒ 完整绝对路径 / 末两级原文"),
        ch("ui.commands.errorAndStaleBanner", .ui,
           "命令页错误面板（副标题）与「陈旧读数」横幅",
           [.absolutePath], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/DesignSystem/SectionHeader.swift|Text(demoRedaction.scrub(subtitle))",
                     "Sources/AIObservatoryUI/Commands/CommandsView.swift|Text(demoRedaction.scrub(message))"],
           off: "关闭 ⇒ `error.localizedDescription` 原文（本仓的存储错误里带库文件绝对路径）"),

        // ───────────────────────── 界面 · 会话
        ch("ui.sessions.rowTitle", .ui,
           "会话列表每一行的标题",
           [.countOrID], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionRow.swift|Text(demoRedaction.scrub(session.title.isEmpty"],
           off: "关闭 ⇒ 原文（今天的会话标题是「Agent 名 · 时间」，`SessionLifecycleManager` 造的）"),
        ch("ui.sessions.rowA11y", .ui,
           "会话行念给 VoiceOver 的汇总（含项目路径）",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionRow.swift|parts.append(demoRedaction.scrub(path))"],
           off: "关闭 ⇒ 汇总里带完整 `session.projectPath`"),
        ch("ui.sessions.leafProjectName", .ui,
           "会话行 / 筛选片 / 概览统计 / 性能页选择器里的**项目目录名**",
           [.leafNameOnly], .none, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionFilterBar.swift|lastPathComponent"],
           off: "两态都只出末段名 ⇒ 故意不接遮罩：末段名与通知正文的 `…/<leaf>` 是同一口径，"
                + "遮它会把「哪个项目」这行信息整个抹掉"),
        ch("ui.sessions.commandRowBody", .ui,
           "会话详情「命令」页签每一行的命令行（带复制）",
           [.commandLine], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionCommandList.swift|MonospacedCodeView(record.commandLine"],
           evidence: "Tests/AIObservatoryUITests/ComponentRedactionTests.swift|等宽代码块",
           off: "关闭 ⇒ 原文"),
        ch("ui.sessions.commandRowA11y", .ui,
           "会话命令每一行的读屏句（命令行在句中）",
           [.commandLine], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionCommandList.swift|demoRedaction.scrub(parts.joined(separator: \"，\"))"],
           off: "关闭 ⇒ 整句原文"),
        ch("ui.sessions.commandRowWorkdir", .ui,
           "会话命令每一行的工作目录（末两级）",
           [.absolutePath], .filePathText, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionCommandList.swift|FilePathText(path: workdir, mode: .lastTwoComponents)"],
           off: "关闭 ⇒ 末两级原文"),
        ch("ui.sessions.detailEventRow", .ui,
           "会话详情事件行的 标题 / 命令行 / 文件路径 / 读屏句",
           [.commandLine, .absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionDetailView.swift|Text(demoRedaction.scrub(event.title))",
                     "Sources/AIObservatoryUI/Sessions/SessionDetailView.swift|Text(demoRedaction.scrub(command))",
                     "Sources/AIObservatoryUI/Sessions/SessionDetailView.swift|demoRedaction.scrub(parts.joined(separator: \"，\"))"],
           off: "关闭 ⇒ 原文"),
        ch("ui.sessions.errorPanel", .ui,
           "会话页错误面板那一句",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionsView.swift|Text(demoRedaction.scrub(message))"],
           off: "关闭 ⇒ 原文"),
        ch("ui.sessions.filterTooltip", .ui,
           "筛选条「项目」那颗片的 tooltip（完整项目路径）",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionFilterBar.swift|.help(demoRedaction.scrub(SessionsCopy.filterProjectHelp"],
           off: "关闭 ⇒ 完整项目路径（按钮标题只给末段名，所以这一格是那颗片上唯一带全路径的地方）"),
        ch("ui.sessions.changeRowPath", .ui,
           "会话详情的文件变更行（文件名 + 绝对父目录）",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Sessions/SessionChangeListView.swift|demoRedaction.scrub"],
           off: "关闭 ⇒ 原文"),

        // ───────────────────────── 界面 · 时间线
        ch("ui.timeline.rowTitle", .ui,
           "时间线每一行的标题（命令事件的标题就是整条命令行）",
           [.commandLine, .absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Timeline/TimelineEventRow.swift|Text(demoRedaction.scrub(event.title))"],
           evidence: "Tests/AIObservatoryUITests/RenderedPageRedactionTests.swift|时间线页整棵树不含真实家目录",
           off: "关闭 ⇒ 原文"),
        ch("ui.timeline.rowCommandFirstLine", .ui,
           "时间线每一行 detail 段的命令行首行",
           [.commandLine], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Timeline/TimelineEventRow.swift|Text(demoRedaction.scrub(command.components(separatedBy: .newlines)"],
           off: "关闭 ⇒ 首行原文。先截行再遮与先遮再截同结果：换行是路径段的终止符"),
        ch("ui.timeline.rowA11y", .ui,
           "时间线每一行念给 VoiceOver 的汇总",
           [.commandLine, .absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Timeline/TimelineEventRow.swift|demoRedaction.scrub"],
           off: "关闭 ⇒ 原文"),
        ch("ui.timeline.detailHeadline", .ui,
           "时间线详情面板的标题",
           [.commandLine], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Timeline/TimelineEventDetail.swift|Text(demoRedaction.scrub(event.title))"],
           evidence: "Tests/AIObservatoryUITests/RenderedPageRedactionTests.swift|详情面板",
           off: "关闭 ⇒ 原文"),
        ch("ui.timeline.detailCommandBlock", .ui,
           "时间线详情的命令块（`MonospacedCodeView`，带复制）",
           [.commandLine], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Timeline/TimelineEventDetail.swift|MonospacedCodeView(command"],
           off: "关闭 ⇒ 原文"),

        // ───────────────────────── 剪贴板（屏外出口，没人看得见）
        ch("clipboard.timelineDump", .clipboard,
           "时间线详情「复制为纯文本」那份转储",
           [.commandLine, .absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Timeline/TimelineEventDetail.swift|demoRedaction.scrub(event.title)"],
           evidence: "Tests/AIObservatoryUITests/RenderedPageRedactionTests.swift|详情面板",
           off: "关闭 ⇒ 整份转储原文。这一条是**最容易外流**的：粘贴目标常常是模型上下文，"
                + "而它以前只有 `summary`/`command`/`file` 三行遮过，`event.title` 那行是原文"),
        ch("clipboard.monospacedCopyButton", .clipboard,
           "等宽代码块右上角那颗复制按钮（命令详情 / 会话命令 / 安全详情 / 设置草稿）",
           [.commandLine, .absolutePath, .structuredDump], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/DesignSystem/MonospacedCodeView.swift|pasteboard.setString(scrubbed"],
           evidence: "Tests/AIObservatoryUITests/ComponentRedactionTests.swift|复制出去的那一份",
           off: "关闭 ⇒ 剪贴板拿到原文。修在组件里而不是七个调用点，因为调用点包不住这条出口"),

        // ───────────────────────── 界面 · 文件
        ch("ui.files.coverageLine", .ui,
           "文件页常驻那一行「采集面」：被剔除的根 + 命中的忽略规则",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Files/FilesModel.swift|PathPrivacy.Mask.configured(from: runtime.settings)",
                     "Sources/AIObservatoryUI/Files/CaptureAvailability.swift|mask.scrub(entry.path)"],
           evidence: "Tests/AIObservatoryUITests/RedactionSurfaceTests.swift|采集面整行",
           off: "关闭 ⇒ 实拍里那句「剔除 2 条：… /Users/dev」的形状（#64 的原始漏因，本单复核：已接上）"),
        ch("ui.files.emptyStateExplanation", .ui,
           "文件页空态说明（同一句采集面的第二条渲染路径）",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Files/CaptureAvailability.swift|scope.coverageLine(language: language)"],
           evidence: "Tests/AIObservatoryUITests/RedactionSurfaceTests.swift|空态那一条走的是同一句",
           off: "关闭 ⇒ 原文"),
        ch("ui.files.changeRowPath", .ui,
           "文件页每一行的路径与读屏句",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Files/FileChangeRow.swift|demoRedaction.scrub"],
           evidence: "Tests/AIObservatoryUITests/RenderedPageRedactionTests.swift|文件页**全部**含路径的格子",
           off: "关闭 ⇒ 原文"),
        ch("ui.files.diffRenamedFrom", .ui,
           "Diff 头部「从 …」（重命名前的完整路径，整句拼进本地化文案）",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Files/DiffView.swift|Text(demoRedaction.scrub(FilesCopy.diffRenamedFrom"],
           evidence: "Tests/AIObservatoryUITests/PageEnumerationTests.swift|重命名",
           off: "关闭 ⇒ 原文。#89 ② 的同族：整句不经过 `FilePathText`，所以必须掩在拼好之后"),
        ch("ui.files.diffSubtitle", .ui,
           "Diff 头部副标题（当前变更的完整路径）",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Files/DiffView.swift|demoRedaction.scrub(model.diff?.path ?? change.path)"],
           off: "关闭 ⇒ 原文"),
        ch("ui.files.diffLineContent", .ui,
           "Diff 正文每一行的**文件内容**",
           [.databaseTruth], .none, .none,
           anchors: ["Sources/AIObservatoryUI/Files/DiffLineListView.swift|Text(line.text)"],
           off: "两态都原文：文件正文不是「这台机器的目录布局」，遮它等于毁掉这一页唯一的证据。"
                + "登记它是因为它长得像路径出口，下一手不必再推断一次"),
        ch("ui.files.loadFailedPanel", .ui,
           "文件页错误面板（`SectionHeader` 副标题）",
           [.absolutePath], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Files/FilesView.swift|errorPanel("],
           off: "关闭 ⇒ 原文"),

        // ───────────────────────── 界面 · 项目
        ch("ui.projects.cardPath", .ui,
           "项目卡片的路径行（含按同组冲突深度算出来的标签）",
           [.absolutePath], .filePathText, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Projects/ProjectCard.swift|FilePathText(path: project.path, label: pathLabel"],
           evidence: "Tests/AIObservatoryUITests/PathPrivacyMaskTests.swift|环境默认值就是关闭",
           off: "关闭 ⇒ 原文。#64 修的就是「标签原样返回」这条后门：冲突够多时标签会长成完整路径"),
        ch("ui.projects.cardA11y", .ui,
           "项目卡片念给 VoiceOver 的整句（含 `project.path`）",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Projects/ProjectCard.swift|demoRedaction.scrub(ProjectsCopy.cardA11ySummary.format("],
           off: "关闭 ⇒ 整句原文"),
        ch("ui.projects.heatRow", .ui,
           "热门文件榜每一行的路径（末两级）与读屏整句",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Projects/ProjectHotFilesPanel.swift|demoRedaction.scrub(ProjectsCopy.heatA11ySummary.format(",
                     "Sources/AIObservatoryUI/Projects/ProjectHotFilesPanel.swift|FilePathText(path: heat.path, mode: .lastTwoComponents)"],
           off: "关闭 ⇒ 原文"),

        // ───────────────────────── 界面 · 安全
        ch("ui.security.eventTitles", .ui,
           "风险事件行 / 详情面板 / 确认面板的标题",
           [.countOrID], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Security/RiskEventRow.swift|Text(demoRedaction.scrub(event.title))",
                     "Sources/AIObservatoryUI/Security/SecurityDetailPanel.swift|Text(demoRedaction.scrub(event.title))",
                     "Sources/AIObservatoryUI/Security/SecurityConfirmationSheet.swift|Text(demoRedaction.scrub(event.title))"],
           off: "关闭 ⇒ 原文（今天标题由规则身份给，静态句、不含路径）"),
        ch("ui.security.commandBlock", .ui,
           "风险详情与确认面板的触发命令",
           [.commandLine], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Security/SecurityDetailPanel.swift|MonospacedCodeView(command",
                     "Sources/AIObservatoryUI/Security/SecurityConfirmationSheet.swift|MonospacedCodeView(command"],
           off: "关闭 ⇒ 整条命令原文（`rm -rf` 的原始目标就在这）"),
        ch("ui.security.filePathList", .ui,
           "风险详情涉及的文件清单",
           [.absolutePath], .filePathText, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Security/SecurityDetailPanel.swift|FilePathText("],
           off: "关闭 ⇒ 原文"),
        ch("ui.security.matchedRuleID", .ui,
           "风险详情的「命中规则」那一格",
           [.countOrID], .none, .none,
           anchors: ["Sources/AIObservatoryUI/Security/SecurityDetailPanel.swift|value: ruleID"],
           off: "两态都原文：值是 `R-004` 这类规则编号（`SampleData` 与库里同一形状），不是路径"),

        // ───────────────────────── 界面 · 设置（**独立 Scene**）
        ch("ui.settings.sceneInjection", .ui,
           "⌘, 设置窗口**整个 Scene** 的映射注入",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Settings/SettingsView.swift|demoRedaction, model.renderMask",
                     "Sources/AIObservatoryUI/Settings/SettingsModel.swift|PathPrivacy.Mask.configured(from: runtime.settings)"],
           evidence: "Tests/AIObservatoryUITests/SceneInjectionTests.swift|每一个 Scene 根",
           off: "关闭 ⇒ 整屏监控根 / 忽略规则 / 存储目录原文（这一页本来就以路径为主体）。"
                + "**改造前开着也是原文**：主窗口那份 `.environment` 进不了另一个 Scene——这就是派单说的「射程不到」"),
        ch("ui.settings.privacyPaneCopy", .ui,
           "隐私页那行「开启后每一处出现路径的地方」的承诺文案 + 受保护根清单",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Settings/SettingsPrivacyPane.swift|demoRedaction.scrub"],
           evidence: "Tests/AIObservatoryUITests/PathPrivacyMaskTests.swift|真消费者接线",
           off: "关闭 ⇒ 原文，且那一行改口说「当前不遮」"),
        ch("ui.settings.storageDraftDump", .ui,
           "关于页「当前设置草稿」的 JSON 转储（带复制按钮）",
           [.structuredDump, .absolutePath], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Settings/SettingsAboutPane.swift|MonospacedCodeView(draftDump"],
           evidence: "Tests/AIObservatoryUITests/ComponentRedactionTests.swift|等宽代码块",
           off: "关闭 ⇒ 整份 JSON 原文，`monitoredRoots` 与 `storeDirectory` 逐条躺在里面"),
        ch("ui.settings.storeDirectory", .ui,
           "存储页的库目录（`MonospacedCodeView`）",
           [.absolutePath], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Settings/SettingsStoragePane.swift|MonospacedCodeView("],
           off: "关闭 ⇒ 原文"),
        ch("ui.settings.errorPanel", .ui,
           "设置页探活失败那一句",
           [.absolutePath], .environmentScrub, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Settings/SettingsView.swift|Text(demoRedaction.scrub(message))"],
           off: "关闭 ⇒ 原文"),

        // ───────────────────────── 界面 · 菜单栏 与 共用组件
        ch("ui.menuBar.window", .ui,
           "菜单栏（MenuBarExtra）窗口那一格",
           [.countOrID], .none, .pathMask,
           anchors: ["Sources/AIObservatoryUI/Shell/MenuBarContentView.swift|Text(ByteFormat"],
           evidence: "Tests/AIObservatoryUITests/SceneInjectionTests.swift|菜单栏那一格不显示路径",
           off: "两态都一样：这一格只有引擎状态、Agent 计数、CPU 与内存，**没有一个路径出口**。"
                + "所以不往这里注入映射（没有消费者的开关就是装饰）；上面那条用例负责在有人加路径行时判红"),
        ch("ui.shared.filePathText", .ui,
           "共用组件：路径行（正文 / tooltip / 读屏 三条出口，全站十几格吃它）",
           [.absolutePath], .filePathText, .pathMask,
           anchors: ["Sources/AIObservatoryUI/DesignSystem/InlineStat.swift|.help(masked)",
                     "Sources/AIObservatoryUI/DesignSystem/InlineStat.swift|demoRedaction.tail(path, components: 2)"],
           evidence: "Tests/AIObservatoryUITests/PathPrivacyMaskTests.swift|FilePathText 的截断交给",
           off: "关闭 ⇒ 与旧的 `split.suffix(n)` 逐字一致"),
        ch("ui.shared.monospacedCodeView", .ui,
           "共用组件：等宽命令/代码块（屏上 + 剪贴板两条出口）",
           [.commandLine, .absolutePath, .structuredDump], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/DesignSystem/MonospacedCodeView.swift|private var scrubbed: String { demoRedaction.scrub(text) }"],
           evidence: "Tests/AIObservatoryUITests/ComponentRedactionTests.swift|等宽代码块",
           off: "关闭 ⇒ 恒等映射，与改造前逐字一致"),
        ch("ui.shared.sectionHeader", .ui,
           "共用组件：分组标题与副标题（两页的错误面板把 `localizedDescription` 递到这里）",
           [.absolutePath], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/DesignSystem/SectionHeader.swift|Text(demoRedaction.scrub(title))"],
           evidence: "Tests/AIObservatoryUITests/ComponentRedactionTests.swift|分组标题",
           off: "关闭 ⇒ 恒等"),
        ch("ui.shared.emptyStateView", .ui,
           "共用组件：空态与错误态那两行（九页复用）",
           [.absolutePath], .componentOwned, .pathMask,
           anchors: ["Sources/AIObservatoryUI/DesignSystem/EmptyStateView.swift|Text(demoRedaction.scrub(message))"],
           evidence: "Tests/AIObservatoryUITests/ComponentRedactionTests.swift|空态",
           off: "关闭 ⇒ 恒等"),

        // ───────────────────────── 导出件
        ch("export.json.records", .export,
           "JSON 导出：五类记录的每一个字段",
           [.absolutePath, .commandLine, .credential], .exportRedactor, .pathMask,
           anchors: ["Sources/AIObservatoryExport/ExportCoordinator.swift|redactionEnabled ? .standard(pathMask: pathMask) : .disabled"],
           evidence: "Tests/AIObservatoryExportTests/RedactedExportEnumerationTests.swift|逐格枚举：五种 kind 的每一列",
           off: "凭据脱敏默认开；路径遮罩默认关 ⇒ 导出件里是原始绝对路径"),
        ch("export.csv.cells", .export,
           "CSV 导出：每一个数据格",
           [.absolutePath, .commandLine, .credential], .exportRedactor, .pathMask,
           anchors: ["Sources/AIObservatoryExport/CSVExporter.swift|redactor.redact("],
           evidence: "Tests/AIObservatoryExportTests/RedactedExportEnumerationTests.swift|逐格枚举：五种 kind 的每一列",
           off: "同上：路径两态、凭据默认遮"),
        ch("export.markdown.report", .export,
           "Markdown 报告：热文件榜路径列、危险命令表、会话块",
           [.absolutePath, .commandLine], .exportRedactor, .pathMask,
           anchors: ["Sources/AIObservatoryExport/MarkdownReportExporter.swift|redactor.redact("],
           evidence: "Tests/AIObservatoryExportTests/RedactedExportEnumerationTests.swift|Markdown 报告整篇",
           off: "同上"),
        ch("export.redactionStateNotice", .export,
           "报告页脚那行「本文档的路径有没有脱敏」+ 关闭时的警告行",
           [.countOrID], .exportRedactor, .pathMask,
           anchors: ["Sources/AIObservatoryExport/MarkdownReportExporter.swift|redactionStateText",
                     "Sources/AIObservatoryExport/ExportRedactor.swift|public var isPathMasked"],
           evidence: "Tests/AIObservatoryExportTests/RedactedExportEnumerationTests.swift|不脱敏不许静默",
           off: "**不许静默**：关掉时页脚明写「路径未脱敏：本文档含本机原始绝对路径」"),
        ch("export.credentialSwitchIndependence", .export,
           "两个 flag 的独立性：关掉凭据脱敏不许偷偷把路径也放出来",
           [.credential, .absolutePath], .exportRedactor, .credentialRedaction,
           anchors: ["Sources/AIObservatoryExport/ExportCoordinator.swift|redactionEnabled"],
           evidence: "Tests/AIObservatoryExportTests/RedactedExportEnumerationTests.swift|不许偷偷换路径",
           off: "`redactionEnabled == false` ⇒ 整个 redactor 恒等（含路径），这是唯一一条能让路径突破遮罩的路径"),
        ch("export.failureAlert", .export,
           "导出失败弹窗（`NSAlert.informativeText` = 错误原文）",
           [.absolutePath], .none, .none,
           anchors: ["Sources/AIObservatoryApp/ObservatoryExporting.swift|informativeText",
                     "Sources/AIObservatoryExport/ExportDiagnostics.swift|pathForbidden"],
           off: "两态都原文 ⇒ **越界项**：App 层是冻结区，本车道只登记不改，见交付报告的 ICR"),
        ch("export.fileNameAndTarget", .export,
           "导出文件名与写盘目录",
           [.countOrID], .none, .none,
           anchors: ["Sources/AIObservatoryExport/ExportWriter.swift|ExportPathPolicy",
                     "Sources/AIObservatoryExport/ExportRequest.swift|baseName"],
           evidence: "Tests/AIObservatoryExportTests/ExportWriterTests.swift|危险路径",
           off: "两态都原文：文件名是 `ai-observatory-<kind>-<stamp>`，本来就不含宿主路径"),

        // ───────────────────────── 系统通知
        ch("notification.body", .notification,
           "高危事件通知正文（Agent · 命令摘要 · 时间）",
           [.commandLine], .deabsolutized, .alwaysOn,
           anchors: ["Sources/AIObservatoryPlatform/Notifications/RiskNotificationCoordinator.swift|PathPrivacy.deabsolutized(command)"],
           evidence: "Tests/AIObservatoryPlatformTests/Notifications/NotificationPathEnumerationTests.swift|正文整串",
           off: "通知**没有开关**：永远折成 `…/<末段>`（比占位符更严的一把），`filePaths` 与 `detail` 根本不进正文"),

        // ───────────────────────── CLI
        ch("cli.stdout.table", .cli,
           "`aix agents|sessions|timeline|files|commands|risk` 的人类可读表",
           [.absolutePath, .commandLine], .environmentScrub, .cliPathRedact,
           anchors: ["Sources/AIObservatoryCLI/Aix.swift|mask.scrub(output.stdout)"],
           evidence: "Tests/AIObservatoryCLITests/AixCLITests.swift|路径遮罩（#61 那套）默认关",
           off: "默认关 ⇒ 表里是库内原文；`--redact` 才遮。CLI **不读** `demoRedactedOutput`："
                + "那是界面自己的显示偏好，拿它再挡一道会让 flag 有一半概率是空开关"),
        ch("cli.stdout.json", .cli,
           "`--json` 五类记录（走导出层）",
           [.absolutePath, .commandLine, .credential], .exportRedactor, .cliCredentialRedact,
           anchors: ["Sources/AIObservatoryCLI/Aix.swift|JSONExporter.data(records:"],
           evidence: "Tests/AIObservatoryCLITests/AixCLITests.swift|凭据脱敏**默认开**",
           off: "凭据默认遮；`--no-redact` 时 stderr 必须打 `AIX_CREDENTIAL_REDACTION_OFF` 那一行"),
        ch("cli.stdout.agentsEnvelope", .cli,
           "`aix agents --json` 的外壳（导出层没有 agents 这一类）",
           [.absolutePath], .environmentScrub, .cliPathRedact,
           anchors: ["Sources/AIObservatoryCLI/Aix.swift|\"workingDirectory\""],
           evidence: "Tests/AIObservatoryCLITests/AixCLITests.swift|agents 的 JSON 是 CLI 自有 v1",
           off: "默认关 ⇒ `workingDirectory` 原文。路径遮罩靠整段 stdout 的 `scrub`，"
                + "凭据这一格不经 `ExportRedactor`（`AgentInstance` 里没有凭据字段）"),
        ch("cli.stdout.dbPathFooter", .cli,
           "表尾那行「库：<db 绝对路径>」",
           [.absolutePath], .environmentScrub, .cliPathRedact,
           anchors: ["Sources/AIObservatoryCLI/Aix.swift|库："],
           off: "默认关 ⇒ 原文；`--redact` 时被整段 stdout 遮罩顺带盖住"),
        ch("cli.stderr.precondition", .cli,
           "前置条件失败的 stderr（库不存在 / 不是观测库 / 版本不符 / 不可读）",
           [.absolutePath], .none, .none,
           anchors: ["Sources/AIObservatoryCLI/AixStore.swift|notAnObservatoryStore"],
           off: "两态都原文：失败在 `finish()` **之前**返回，而遮罩只做 stdout ⇒ **越界项**，见交付报告的 ICR"),

        // ───────────────────────── 落库与日志（「不遮」是设计）
        ch("store.database", .store,
           "SQLite 库里的路径与命令行",
           [.databaseTruth, .absolutePath, .commandLine], .none, .none,
           docAnchors: ["Sources/AIObservatoryCore/Privacy/PathPrivacy.swift|只在渲染层，绝不在落库前"],
           evidence: "Tests/AIObservatoryEngineTests/CommandCredentialPersistenceTests.swift|导出侧不再有第二道防线兜底",
           off: "两态都原文，且**必须**原文（#41：写入时冻结）。遮它是把审计证据改掉"),
        ch("log.unified.publicPaths", .log,
           "统一日志里以 `.public` 打出的监控根与库目录",
           [.absolutePath], .none, .none,
           anchors: ["Sources/AIObservatoryEngine/MonitoringRootResolver.swift|privacy: .public"],
           off: "两态都原文，且没有任何开关管它 ⇒ 交回总控。本机 `log show` 对任何 subsystem 都返 0 行，"
                + "所以这条既是设计缺口也是**未验证**项"),
    ]

    // MARK: 分组

    static func count(on surface: ExitChannel.Surface) -> Int {
        channels.filter { $0.surface == surface }.count
    }

    /// 「登记为不遮」的那几条：每一条都要有理由，理由不许空。
    static var uncovered: [ExitChannel] { channels.filter { !$0.isCovered } }

    /// 这一处出口扫描结果是否已经在表上。
    ///
    /// 只拿「登记为**不遮**的界面出口」的接线针当豁免——已经遮过的那些不需要豁免
    /// （闸看见 `scrub` 就放行了），拿它们当豁免会把同一跨度里的另一处未遮出口也放掉。
    /// 针比的是**调用跨度**而不是单行：登记时写的常常是那一格的主体行。
    static func isRegistered(_ hit: ExitGate.Finding) -> Bool {
        uncovered.filter { $0.surface == .ui }.contains { channel in
            channel.anchors.contains { anchor in
                let parts = anchor.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, parts[1].isEmpty == false else { return false }
                return hit.file.hasSuffix(parts[0]) && hit.context.contains(parts[1])
            }
        }
    }

    /// 敏感出口里**没被任何遮罩接住**的那几条——这张子表就是"还欠多少"。
    static var uncoveredSensitive: [ExitChannel] {
        uncovered.filter { $0.carriesSensitivePayload }
    }
}
