//
//  SessionRow.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent I)
//  会话列表行：**单行**（结果状态 + #编号 + 标题 + 行尾元信息 + 起始时刻）。
//  计数一律来自 `SessionCounters`（服务端快照 + 实时增量），数字变化用 numericText 动效。
//  ─────────────────────────────────────────────────────────
//  【quiet 改版要点】原来是两行式：第一行编号 + 标题 + 风险胶囊 + Agent，
//  第二行项目路径 + 三个**各带一个彩色 SF 图标**的计数 + 时刻。
//  删掉的东西正是旧界面「拥挤、脏、没有主次」的来源：
//    · `.fill(Color.accentColor.opacity(0.14))` 的自造选中底 → `Surface.selectedRow`
//    · 进行中会话那圈 35% 色调的彩色描边环 → 状态由 `Tag`（色点 + 文字）承担
//    · 风险计数的橙色 8% 胶囊底 → `Tag(tone: .caution)`
//    · 文件/命令计数前的蓝、紫、红图标（图标不携带信息，只在制造色噪）→ 合并成一行文本元信息
//  行本身不画框、不填充、不加投影；分隔由调用方的 `Hairline()` 负责。
//

import SwiftUI
import AIObservatoryCore

@MainActor struct SessionRow: View {

    let session: AgentSession
    var counters: SessionCounters = SessionCounters()
    var isSelected: Bool = false
    var action: (() -> Void)?
    /// #64：会话行的无障碍汇总原来直接 append `session.projectPath`（绝对路径）。
    @Environment(\.demoRedaction) private var demoRedaction

    init(session: AgentSession,
         counters: SessionCounters = SessionCounters(),
         isSelected: Bool = false,
         action: (() -> Void)? = nil) {
        self.session = session
        self.counters = counters
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Tag(session.outcome.displayName(UILanguage.current), tone: .sessionOutcome(session.outcome))
                .fixedSize()

            Text(session.displayIndex > 0 ? "#\(session.displayIndex)" : "#—")
                .font(.axMetaMono)
                .monospacedDigit()
                .foregroundStyle(Surface.secondaryLabel)
                .frame(minWidth: 36, alignment: .leading)

            // 标题吃掉剩余宽度、**只在这里截断**。原来的排法是「标题 + AgentChip + Spacer +
            // 尾部三列 fixedSize」：标题不压缩、尾部又不肯让，窄列表下真机截图实测
            // 行尾「风险 1」被面板右边缘裁掉。Agent 名本来就写在标题里
            // （空标题时回落到 #82 的归一层，见 `AgentNaming`），再挂一个 `AgentChip` 是同一行说两遍。
            Text(demoRedaction.scrub(session.title.isEmpty
                    ? AgentNaming.name(kind: session.kind, form: .compact, language)
                    : session.title))
                .font(.axBody)
                .foregroundStyle(Surface.label)
                .lineLimit(1)
                .truncationMode(.tail)
                // 上面那句注释承诺「标题吃掉剩余宽度、**只在这里**截断」，但没有定级就兑现不了：
                // 标题与行尾元信息同为默认定级，行被挤窄时 SwiftUI 完全可以给标题 0 宽，
                // 于是整行只剩「项目 · 时长 · 文件 · 命令」——主标识消失。
                // 定级到 1 把"谁先让位"写成代码：**元信息先截断，标题最后动**。
                .layoutPriority(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            trailingMeta

            startedAtText

            if counters.riskEvents > 0 {
                // 风险**事件**条数：色点 + 文字，等级明细在事件里，这里只回答「要不要点开」。
                Tag(SessionsCopy.rowRiskTag.copy.format(language, counters.riskEvents), tone: .caution)
                    .fixedSize()
                    .accessibilityLabel(SessionsCopy.rowRiskA11y.copy.format(language, counters.riskEvents))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Sizing.rowMinHeight)
        .padding(.vertical, Spacing.xs)
        .background(isSelected ? Surface.selectedRow : Color.clear)
        .contentShape(Rectangle())
        // #11：这一行原先是 `.onTapGesture` —— 它是这四种可点写法里最坏的一种：
        // 悬停无反馈、按下无反馈、**Tab 走不到**（不是控件）、光标永远是箭头。
        // 换成共用的 `axPressable(when:)` 之后，"点这行"这件事在四张列表行里长得一模一样。
        .axPressable(when: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - 行尾元信息

    /// 项目 / 时长 / 文件 / 命令合并成**一行文本**而不是四个带色图标：
    /// 这一档读数不承担主次，只承担「扫一眼判断要不要点开」。
    /// #74 ②：原来四段读数 `joined(separator: " · ")` 成**一个** `Text` 再 `.truncationMode(.middle)`
    /// ⇒ 挤窄时从整条腰上断，实拍里出现 `1h13…`、`12m…s`、`33m….s` 这种把时长劈成半截的读法
    /// （时长与数字是这行里唯一"断一个字就看不懂"的部分，项目名反而可以中间省略）。
    /// 现在按**段的性质**分开定策略：只有项目名允许中间省略并可压缩，
    /// 时长 / 文件 / 命令三段 `fixedSize` ⇒ 要么整段在、要么整段没，绝不出现半截数字。
    private var trailingMeta: some View {
        HStack(spacing: Spacing.xs) {
            if let project = metaProject {
                Text(project)
                    .truncationMode(.middle)
            }
            Text(DurationFormat.compact(liveDuration)).fixedSize()
            Text(SessionsCopy.rowA11yFiles.copy.format(language, counters.touchedFiles)).fixedSize()
            Text(counters.failedCommands > 0
                    ? SessionsCopy.rowA11yCommandsFailed.copy.format(language, counters.commands, counters.failedCommands)
                    : SessionsCopy.rowA11yCommands.copy.format(language, counters.commands))
                .fixedSize()
        }
        .font(.axMeta)
        .monospacedDigit()
        .contentTransition(.numericText())
        .foregroundStyle(Surface.tertiaryLabel)
        .lineLimit(1)
    }

    /// 项目名（路径最后一段）。空项目就不占位。
    private var metaProject: String? {
        guard let path = session.projectPath, !path.isEmpty else { return nil }
        return (path as NSString).lastPathComponent
    }

    /// 起始时刻：这一列在每行同一位置、等宽，所以「按时间扫」能对齐成一条线。
    private var startedAtText: some View {
        Text(DateFormat.time(session.startedAt))
            .font(.axMetaMono)
            .monospacedDigit()
            .foregroundStyle(Surface.tertiaryLabel)
            .fixedSize()
    }

    // MARK: - 数据

    /// 进行中会话的时长随墙钟推进（`endedAt == nil` 时 `AgentSession.duration` 取当前时刻）。
    private var liveDuration: TimeInterval { max(0, session.duration) }

    private var accessibilitySummary: String {
        var parts = [
            session.displayIndex > 0
                ? SessionsCopy.rowA11yNumbered.copy.format(language, session.displayIndex)
                : SessionsCopy.rowA11yUnnumbered.text(language),
            AgentNaming.name(kind: session.kind, form: .compact, language),
            session.title,
            session.outcome.displayName(UILanguage.current),
            SessionsCopy.rowA11yDuration.copy.format(language, DurationFormat.compact(liveDuration))
        ]
        parts.append(SessionsCopy.rowA11ySummary.copy.format(
                    language, counters.touchedFiles, counters.commands, counters.failedCommands
                ))
        if counters.riskEvents > 0 {
                    parts.append(SessionsCopy.rowA11yRiskEvents.copy.format(language, counters.riskEvents))
                }
        if let path = session.projectPath { parts.append(demoRedaction.scrub(path)) }
        return parts.joined(separator: "，")
    }
}

// MARK: - Previews

private struct SessionRowPreviewList: View {
    private let rows: [AgentSession] = [
        AgentSession(
            displayIndex: 102,
            kind: .claudeCode,
            title: "Claude Code · 重构与测试闭环 #102",
            projectPath: "/Users/demo/Projects/Mona",
            startedAt: Date().addingTimeInterval(-3_000),
            endedAt: Date(),
            modifiedFileCount: 12,
            createdFileCount: 3,
            deletedFileCount: 1,
            commandCount: 24,
            failedCommandCount: 2,
            estimatedTokens: 182_400,
            riskEventCount: 2,
            outcome: .success
        ),
        AgentSession(
            displayIndex: 103,
            kind: .openAICodex,
            title: "OpenAI Codex CLI · 依赖升级",
            startedAt: Date().addingTimeInterval(-600),
            commandCount: 6,
            outcome: .running
        ),
        AgentSession(
            kind: .unknown,
            title: "",
            projectPath: "/Users/demo/Projects/Aurora",
            startedAt: Date().addingTimeInterval(-120),
            endedAt: Date().addingTimeInterval(-30),
            outcome: .interrupted
        )
    ]

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader("会话列表", subtitle: "共 102 · 已加载 3")
                Hairline()
                ForEach(Array(rows.enumerated()), id: \.element.id) { index, session in
                    SessionRow(
                        session: session,
                        counters: previewCounters(for: session),
                        isSelected: index == 1
                    )
                    if index < rows.count - 1 { Hairline() }
                }
            }
        }
        .padding(Spacing.lg)
        .frame(width: 620, alignment: .leading)
        .background(Surface.page)
    }

    private func previewCounters(for session: AgentSession) -> SessionCounters {
        SessionCounters(
            created: session.createdFileCount,
            modified: session.modifiedFileCount,
            deleted: session.deletedFileCount,
            commands: session.commandCount,
            failedCommands: session.failedCommandCount,
            riskEvents: session.riskEventCount
        )
    }
}

#Preview("SessionRow 单行状态") {
    SessionRowPreviewList()
}

private extension SessionRow {
    var language: AppLanguage { UILanguage.current }
}
