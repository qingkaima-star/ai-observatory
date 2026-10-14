//
//  TimelineEventRow.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent C) → WS-QUIET-1 (subagent A) 改版
//  时间线单条事件：**一行账本式记录** —— 左侧对齐的时间/Agent/操作图标，中间标题，
//  右侧行尾元信息（操作类型 / 时长 / 退出码 / 风险）。
//
//  【为什么把卡片拆掉】旧版每条事件是一张 `Panel` 白卡，卡里再套摘要、命令行、
//  文件路径、资源开销展开按钮，一屏十几张卡 ⇒ 每张卡都在争主注意力（「拥挤」「没有主次」），
//  而且卡底 + 2pt 强调色描边 + `Color.accentColor.opacity(0.10)` 的选中填充
//  全是自造语义（旧 `body` 里的三处 `.fill(x.opacity(0.1x))`）。
//  现在：底色只由外层 `Panel` 提供一层，行间 `Hairline()` 分隔，
//  选中底用系统语义色 `Surface.selectedRow`，状态一律 `Tag` / `RiskBadge`（色点 + 文字）。
//  摘要全文、命令行、路径、资源开销都退到详情面板（`.inspector`）里 ——
//  那里是读一条事件的场合，行只负责「扫」。
//
//  ⚠️ 密度 `Picker` **不许**出现在这一行里：本仓实测过「懒栈容器里放含 `.menu`
//  Picker 的卡 ⇒ 滚动自旋、停手不回落、RSS +142 MB/10s、CPU 108%」。它在外层的
//  `SectionHeader` trailing，那里不在懒容器里。
//

import SwiftUI
import AIObservatoryCore

// MARK: - Metrics

/// 时间线行的列几何。**每一档都只是 `Column` 的语义别名**（#83）：
/// 本页读得出"时间列 / Agent 列"这些名字，但宽度只能有一个出处——
/// 改前这里是 62 / 104 / 16 / 240 四个**写死的数**，与性能页的 82 / 60 / 78
/// 说的是同一族列却各拿一把尺。
/// 前三列定宽 ⇒ 整栏像账本一样对齐（用户原话「不规整」的正面解法），
/// 尾部元信息右对齐，长度随内容。
enum TimelineMetrics {
    /// `HH:mm:ss` 等宽时间列宽。
    static let timeColumnWidth: CGFloat = Column.time
    /// Agent 身份列宽（`AgentChip` 紧凑态：图标 + 产品名，#82 之后不再切首词）。
    static let agentColumnWidth: CGFloat = Column.agentIdentity
    /// 操作类型图标列宽。
    static let symbolColumnWidth: CGFloat = Column.glyph
    /// 标题右侧「补充线索」列的宽度上限（文件名 / 命令首行 / 摘要三选一）。
    /// 给它封顶，尾部的状态类读数才始终右对齐在同一条竖线上。
    static let detailColumnWidth: CGFloat = Column.detail
    /// 行与行之间分隔线的左缩进。取 `Spacing.sm` 是因为行本身有 8pt 横向内边距，
    /// 这样 hairline 的左端正好对齐时间列的文字起点（账本式分隔线，不贴面板边）。
    static let hairlineInset: CGFloat = Spacing.sm
    /// 密度选择器（分段控件）的宽度 —— 它在事件流 `SectionHeader` 的 trailing，不在行里。
    static let densityPickerWidth: CGFloat = 132
}

// MARK: - Row

/// 时间线的一行事件记录。整行可点，点击 = 选中该事件（驱动详情 inspector）。
@MainActor struct TimelineEventRow: View {

    let event: TimelineEvent
    /// #64：无障碍汇总里的 `filePath` 与命令行是绝对路径。
    @Environment(\.demoRedaction) private var demoRedaction
    var density: TimelineDensity = .comfortable
    var isSelected: Bool = false
    var action: (() -> Void)?

    @MainActor init(
        event: TimelineEvent,
        density: TimelineDensity = .comfortable,
        isSelected: Bool = false,
        action: (() -> Void)? = nil
    ) {
        self.event = event
        self.density = density
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        Button {
            action?()
        } label: {
            row
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        // #11：`.plain` → 全站同一份悬停/按下档（`DesignSystem/InteractiveFeedback.swift`）。
        .buttonStyle(.axPressable)
        .padding(.horizontal, Spacing.sm)
        .padding(.vertical, density.rowVerticalPadding)
        .frame(minHeight: Sizing.rowMinHeight, alignment: .center)
        .background(isSelected ? Surface.selectedRow : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: 一行

    private var row: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(DateFormat.time(event.timestamp))
                .font(.axMetaMono)
                .monospacedDigit()
                .foregroundStyle(Surface.secondaryLabel)
                .axLeadingColumn(TimelineMetrics.timeColumnWidth)

            AgentChip(kind: event.agentKind, compact: true)
                .axLeadingColumn(TimelineMetrics.agentColumnWidth)

            Image(systemName: event.kind.sfSymbolName)
                .font(.axMeta)
                .foregroundStyle(ObservatoryTheme.color(for: event.kind))
                .axGlyphColumn(TimelineMetrics.symbolColumnWidth)
                .accessibilityHidden(true)

            Text(demoRedaction.scrub(event.title))
                .font(.axBody)
                .foregroundStyle(Surface.label)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            if density.showsExtendedContent {
                detailSegment
            }

            Spacer(minLength: Spacing.sm)

            trailingMeta
        }
    }

    /// 标题右侧的补充线索：有文件给文件名，没文件有命令给命令首行，都没有就给摘要。
    /// 三者互斥，一行里最多出现一个，避免中部区域把标题挤没。
    /// 颜色不再往 `FilePathText` 上覆写 —— 它自带 `Surface.label` + 等宽 + 可选中 + tooltip，
    /// 外层再挂一次 `foregroundStyle` 是死代码（内层 Text 的显式色会赢）。
    @ViewBuilder private var detailSegment: some View {
        if let path = event.filePath, !path.isEmpty {
            FilePathText(path: path, mode: .fileNameOnly)
                .frame(maxWidth: TimelineMetrics.detailColumnWidth, alignment: .trailing)
        } else if let command = event.command, !command.isEmpty {
            Text(demoRedaction.scrub(command.components(separatedBy: .newlines).first ?? command))
                .font(.axMetaMono)
                .foregroundStyle(Surface.tertiaryLabel)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: TimelineMetrics.detailColumnWidth, alignment: .trailing)
        } else if !event.summary.isEmpty {
            Text(demoRedaction.scrub(event.summary))
                .font(.axMeta)
                .foregroundStyle(Surface.tertiaryLabel)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: TimelineMetrics.detailColumnWidth, alignment: .trailing)
        }
    }

    // MARK: 行尾元信息

    @ViewBuilder private var trailingMeta: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
            if density.showsExtendedContent {
                Text(event.kind.displayName)
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)

                if let duration = event.durationSeconds {
                    Text(DurationFormat.compact(duration))
                        .font(.axMeta)
                        .axNumberColumn(Column.duration)
                        .foregroundStyle(Surface.secondaryLabel)
                        .fixedSize(horizontal: true, vertical: false)
                }
            }

            if let exitCode = event.exitCode {
                exitTag(exitCode)
            }

            if event.riskLevel > .low {
                RiskBadge(event.riskLevel, prominent: event.riskLevel >= .high)
            }
        }
    }

    /// 退出码：命令审计的核心信号。成功只上色点（`Tag` 默认文字保持主文本色）；
    /// 失败时连文字一起染色（`prominent`），因为「这条命令失败了」是唯一值得抢注意力
    /// 的行尾信号，而码值本身已经写在文字里，不靠颜色传达。
    private func exitTag(_ exitCode: Int32) -> some View {
        Tag(
            "exit \(exitCode)",
            tone: exitCode == 0 ? .positive : .critical,
            prominent: exitCode != 0
        )
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(
            exitCode == 0
                ? TimelineCopy.exitSucceeded.text(language)
                : TimelineCopy.exitFailed.format(language, exitCode)
        )
    }

    // MARK: - 无障碍

    /// 整行读屏那一句。八段拼一句，所以**分隔符也是文案**：英文态用全角「，」会被
    /// VoiceOver 念成一个额外的停顿（`TimelineCopy.a11yJoiner`）。
    private var accessibilitySummary: String {
        var parts: [String] = [
            DateFormat.timestamp(event.timestamp),
            AgentNaming.name(kind: event.agentKind, form: .compact),
            event.kind.displayName,
            event.title
        ]
        // #64（无障碍树那一支抓出来的）：屏上那行 summary 脱了敏，**VoiceOver 念的这一份没脱**。
        if !event.summary.isEmpty { parts.append(demoRedaction.scrub(event.summary)) }
        if let path = event.filePath { parts.append(demoRedaction.scrub(path)) }
        if let command = event.command { parts.append(TimelineCopy.a11yCommand.format(language, demoRedaction.scrub(command))) }
        if let exitCode = event.exitCode { parts.append(TimelineCopy.a11yExitCode.format(language, exitCode)) }
        if let duration = event.durationSeconds {
            parts.append(TimelineCopy.a11yDuration.format(language, DurationFormat.compact(duration)))
        }
        if event.riskLevel > .low {
            parts.append(TimelineCopy.a11yRisk.format(language, event.riskLevel.displayName))
        }
        return parts.joined(separator: TimelineCopy.a11yJoiner.text(language))
    }

    /// 本次启动的语言（`UILanguage` 一处解析，见其注释）。
    private var language: AppLanguage { UILanguage.current }
}

// MARK: - Previews

/// 预览数据写成 `func` 而不是全局 `let`：Swift 6 下全局存储属性要额外证明并发安全，
/// 而这三条事件只是预览脚手架。
private func previewTimelineEvents() -> [TimelineEvent] {
    [
        TimelineEvent(
            agentKind: .claudeCode,
            kind: .fileModified,
            title: "修改 TimelineView.swift",
            summary: "重写页面骨架为 ObservatoryPage。",
            filePath: "/Users/demo/AiX/Sources/AIObservatoryUI/Timeline/TimelineView.swift",
            riskLevel: .low
        ),
        TimelineEvent(
            agentKind: .openAICodex,
            kind: .commandExecuted,
            title: "执行 rm -rf ./build",
            summary: "在工作目录内执行递归删除，命中破坏性规则 R-004。",
            command: "rm -rf ./build",
            exitCode: 1,
            durationSeconds: 3.4,
            cost: ResourceCost(cpuSeconds: 1.2, memoryBytes: 38_000_000, bytesRead: 900_000, bytesWritten: 0),
            riskLevel: .high
        ),
        TimelineEvent(
            agentKind: .cursorAgent,
            kind: .riskDetected,
            title: "读取凭据文件",
            summary: "命中凭据读取规则。",
            filePath: "/Users/demo/.ssh/id_rsa",
            riskLevel: .critical
        ),
    ]
}

#Preview("时间线行 · 舒适 / 紧凑 / 选中") {
    Panel {
        VStack(alignment: .leading, spacing: Spacing.none) {
            SectionHeader("事件流", subtitle: "舒适档：行尾挂操作类型、时长与退出码")
                .padding(.bottom, Spacing.sm)
            // 舒适档第二行是选中态：选中只换 `Surface.selectedRow` 底，不描边。
            ForEach(Array(previewTimelineEvents().enumerated()), id: \.element.id) { index, event in
                if index > 0 { Hairline(inset: TimelineMetrics.hairlineInset) }
                TimelineEventRow(event: event, isSelected: index == 1)
            }
            SectionHeader("事件流", subtitle: "紧凑档：只留时间 / Agent / 标题 / 风险")
                .padding([.top, .bottom], Spacing.sm)
            ForEach(Array(previewTimelineEvents().enumerated()), id: \.element.id) { index, event in
                if index > 0 { Hairline(inset: TimelineMetrics.hairlineInset) }
                TimelineEventRow(event: event, density: .compact)
            }
        }
    }
    .padding(Spacing.xl)
    .frame(width: 860)
    .background(Surface.page)
}
