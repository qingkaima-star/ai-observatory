//
//  SessionDetailView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent I)
//  会话详情栏（挂在 `SessionsView` 的 `.inspector` 上）：概览读数（时长/文件/命令/失败/Token/峰值 CPU/
//  峰值内存/风险）+ 元信息 + 分段页签（命令记录 / 事件摘要）。命令与事件由 `SessionsModel` 按 sessionID 懒加载。
//  ─────────────────────────────────────────────────────────
//  【quiet 改版要点】
//    · 概览区原来是「最小宽 168 的自适应列 + 懒网格」—— 宽窄一变就重排、
//      最后一行常留孤卡，正是「不规整 + 孤卡」的元凶。改成定列 `MetricGrid(_:columns: 2)`，
//      读数数量恒为 8 ⇒ 4 行填满，没有孤卡。
//    · 删掉自造的那层 3% 主色底（假语义色，深浅两套都会脏）与结果徽章的
//      描边胶囊（10% 色调填充 + 1pt 描边），
//      结果状态改由 `Tag`（色点 + 文字）承担。
//    · 详情栏的底改 `Surface.page`：`Panel` 的白底只有压在差一级的页底上才读得出分区。
//  本视图在 `ObservatoryPage` **外面**，所以这里的 `ScrollView` 不是第二个滚动条——
//  inspector 那一列是自成一个滚动区的。
//

import SwiftUI
import Observation
import AIObservatoryCore

// MARK: - Value formatting

/// 详情面板的数值文案（统一口径，便于 Preview 与实盘一致）。
enum SessionsValueFormat {
    static func tokens(_ value: Int) -> String {
        guard value >= 0 else { return "—" }
        if value >= 1_000_000 { return String(format: "%.1fM", Double(value) / 1_000_000) }
        if value >= 1_000 { return String(format: "%.1fk", Double(value) / 1_000) }
        return "\(value)"
    }

    static func count(_ value: Int) -> String {
        value >= 0 ? "\(value)" : "—"
    }
}

// MARK: - View

@MainActor struct SessionDetailView: View {

    @Bindable private var model: SessionsModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(model: SessionsModel) {
        self._model = Bindable(model)
    }

    var body: some View {
        Group {
            if let session = model.selected {
                detail(for: session)
            } else if model.isLoading || model.isLoadingDetail {
                loadingState
            } else {
                EmptyStateView(
                    SessionsCopy.detailPickTitle.text(language),
                    systemImage: "list.bullet.rectangle.portrait",
                    message: SessionsCopy.detailPickMessage.text(language)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Surface.page)
    }

    // MARK: - 详情主体

    private func detail(for session: AgentSession) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.md) {
                overviewPanel(for: session)
                metaCard(for: session)
                tabPicker
                tabContent
            }
            .padding(Spacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 头部 + 概览读数（一个面板，不拆成两盒）

    private func overviewPanel(for session: AgentSession) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionHeader(
                    session.title.isEmpty
                        ? AgentNaming.name(kind: session.kind, form: .full, language)
                        : session.title,
                    subtitle: headerSubtitle(for: session)) {
                    HStack(spacing: Spacing.sm) {
                        AgentChip(kind: session.kind)
                        Tag(session.outcome.displayName(UILanguage.current), tone: .sessionOutcome(session.outcome))
                            .fixedSize()
                            .accessibilityLabel(SessionsCopy.detailA11yOutcome.copy.format(language, session.outcome.displayName(UILanguage.current)))
                    }
                }

                Hairline()

                // 八个读数**同一档 22pt** 时，详情栏自己就成了「没有主次」的第二页
                // （16:58 真机截图实测：八个数互相抢，还压过了页面 hero）。
                // 详情栏只回答一个问题——「这次会话跑了多久」，所以只有 `时长` 留在
                // `.metric`(22pt)，其余降到 `.compact`(13pt 半粗)：口径文字一格没少。
                // #74 ①：这一格里装的是**两列**读数，而 inspector 的列宽上限只有 420pt
                // ⇒ 窗口收窄时右列（「峰值 CPU」「明细见安全板块」「33 条 · 上限 50」）被窗口右边界
                // **裁掉**而不是折下去。变宽实验：1280 宽被裁、1437 宽全露 ⇒ 内容比列宽。
                // 修法是把"装不下"交给布局自己判：先试两列，放不下就降成一列。
                // ⚠️ 不准用"把 max 调大"掩盖 —— 那只是把裁切推到更宽的窗口上。
                ViewThatFits(in: .horizontal) {
                    MetricGrid(detailMetrics(for: session), columns: 2) { metric in
                        metricTile(metric)
                    }
                    MetricGrid(detailMetrics(for: session), columns: 1) { metric in
                        metricTile(metric)
                    }
                }
            }
        }
    }

    /// 一格读数。两列与一列两种排布共用同一份，避免"改了一列那支忘另一支"。
    @MainActor private func metricTile(_ metric: SessionDetailMetric) -> some View {
        StatTile(
            title: metric.title,
            value: metric.value,
            unit: metric.unit,
            caption: metric.caption,
            emphasis: metric.id == 0 ? .metric : .compact
        )
    }

    /// 头部副标题：编号 + Agent + 观测时长；时长口径写死在字面上，避免被读成「墙钟跨度」。
    private func headerSubtitle(for session: AgentSession) -> String {
        var parts: [String] = []
        if session.displayIndex > 0 { parts.append("#\(session.displayIndex)") }
        parts.append(AgentNaming.name(kind: session.kind, form: .full, language))
        parts.append(SessionsCopy.detailObservedFor.copy.format(
                    language, DurationFormat.humanReadable(model.duration(for: session))))
        return parts.joined(separator: " · ")
    }

    /// 八格读数，恒为 8 ⇒ `columns: 2` 时 4 行正好填满。
    private func detailMetrics(for session: AgentSession) -> [SessionDetailMetric] {
        let counters = model.counters(for: session)
        let readout = failedCommandReadout(for: counters)
        return [
            SessionDetailMetric(
                id: 0,
                title: SessionsCopy.detailTileDuration.text(language),
                value: DurationFormat.compact(model.duration(for: session)),
                caption: session.endedAt == nil ? SessionsCopy.detailRunning.text(language)
                                             : SessionsCopy.detailEnded.text(language)
            ),
            SessionDetailMetric(
                id: 1,
                title: SessionsCopy.detailTileFileChanges.text(language),
                value: SessionsValueFormat.count(counters.touchedFiles),
                unit: SessionsCopy.unitLocations(language),
                caption: SessionsCopy.detailFileBreakdown.copy.format(language, counters.created, counters.modified, counters.deleted)
            ),
            SessionDetailMetric(
                id: 2,
                title: SessionsCopy.detailTileCommands.text(language),
                value: SessionsValueFormat.count(counters.commands),
                caption: SessionsCopy.detailCommandsLoaded.copy.format(language, model.commands.count)
            ),
            SessionDetailMetric(
                id: 3,
                title: SessionsCopy.detailTileFailedCommands.text(language),
                value: SessionsValueFormat.count(counters.failedCommands),
                caption: readout.caption
            ),
            SessionDetailMetric(
                id: 4,
                title: SessionsCopy.detailTileTokens.text(language),
                value: SessionsValueFormat.tokens(session.estimatedTokens),
                caption: SessionsCopy.detailCPUSeconds.copy.format(language, DurationFormat.compact(session.cpuSeconds))
            ),
            SessionDetailMetric(
                id: 5,
                title: SessionsCopy.detailTilePeakCPU.text(language),
                value: PercentFormat.short(session.peakCPUPercent, fractionDigits: 1),
                caption: SessionsCopy.detailPeakCPUHelp.text(language)
            ),
            SessionDetailMetric(
                id: 6,
                title: SessionsCopy.detailTilePeakMemory.text(language),
                value: ByteFormat.humanReadable(session.peakMemoryBytes),
                caption: SessionsCopy.detailPeakMemoryHelp.text(language)
            ),
            SessionDetailMetric(
                id: 7,
                title: SessionsCopy.detailTileRisks.text(language),
                value: SessionsValueFormat.count(counters.riskEvents),
                caption: counters.riskEvents > 0 ? SessionsCopy.detailRiskSeeSecurity.text(language)
                                             : SessionsCopy.detailRiskNone.text(language)
            ),
        ]
    }

    /// 「失败命令 0」有两种完全不同的含义：**真的全部成功**，和**根本没采到退出码**。
    /// 口径抽到 ``CommandResultReadout``，那里有「拿不到退出码就不许说全部通过」的回归用例。
    ///
    /// 旧版这里还会把瓷贴染成绿/红/灰，但 `StatTile` 的数值本来不上色（颜色只属于 `Tag`），
    /// 那个 tint 计算出来后压根没被用出去。红线由 `CommandResultReadoutTests` 守着，
    /// 删掉的是死代码，不是约束。
    private func failedCommandReadout(for counters: SessionCounters) -> CommandResultReadout {
        CommandResultReader.read(
            failedCommands: counters.failedCommands,
            totalCommands: counters.commands,
            loadedOutcomes: model.commands.map(\.outcome)
        )
    }

    // MARK: - 元信息卡

    private func metaCard(for session: AgentSession) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(SessionsCopy.detailMetadata.text(language))

                VStack(alignment: .leading, spacing: Spacing.none) {
                    projectRow(session)

                    Hairline()
                    InlineStat(SessionsCopy.detailStartedAt.text(language), value: DateFormat.timestamp(session.startedAt))
                    Hairline()
                    InlineStat(SessionsCopy.detailEndedAt.text(language),
                               value: session.endedAt.map { DateFormat.timestamp($0) } ?? "—")
                    Hairline()
                    InlineStat(SessionsCopy.detailActiveWindow.text(language), value: model.timeRangeText(for: session))
                    Hairline()
                    InlineStat(SessionsCopy.detailObservedLabel.text(language),
                               value: DurationFormat.humanReadable(model.duration(for: session)),
                               emphasized: true)
                    Hairline()
                    InlineStat(SessionsCopy.detailEventPreview.text(language),
                               value: eventPreviewText(for: session))
                }
            }
        }
    }

    /// 项目路径 + 「聚焦此项目」+ 这一条会话的两个取证出口。
    ///
    /// 那两个出口走 `shell.jump(...)`（#81）：会话 id 与项目路径一起带过去，
    /// 目的地在第一次取数之前把它们落进自己那条 `*Query` ⇒ 看到的确实是**这一条会话**的
    /// 事件 / 文件变更，而不是全量列表。时间区间带的是本页正在用的那一份（口径行刚说过什么，
    /// 跳过去就还是什么）。
    private func projectRow(_ session: AgentSession) -> some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                if let path = session.projectPath, !path.isEmpty {
                    FilePathText(path: path, mode: .middleEllipsis)
                    Spacer(minLength: Spacing.sm)
                    Button(SessionsCopy.detailFocusProject.text(language)) {
                        Task { await model.focusProject(session) }
                    }
                    .controlSize(.mini)
                    .disabled(model.query.projectPath == path)
                } else {
                    Text(SessionsCopy.detailNoProject.text(language))
                        .axCaptionStyle()   // #99：口径句提档（原 .axMeta + tertiary）
                    Spacer(minLength: Spacing.none)
                }
            }

            // #74 ①：作用域**说一次**就够了。原来三颗按钮各带一遍「看这一条会话的…」，
            // 在详情面板那点宽度里全部截断成同一串字 ⇒ 三个入口视觉上无法区分
            // （"界面说半截话"那一族，同 #46 把空路径渲染成两个空格）。
            // 限定语义没删：可见文案缩短、这行说明承担作用域、完整句子进 .accessibilityLabel。
            Text(SessionsCopy.detailJumpScopeCaption.text(language))
                .axCaptionStyle()   // #99：口径句提档（原 .axMeta + tertiary）

            HStack(spacing: Spacing.sm) {
                Button(SessionsCopy.detailJumpToTimeline.text(language)) {
                    shell?.jump(JumpIntent(target: .timeline,
                                           projectPath: session.projectPath,
                                           sessionID: session.id,
                                           timeRange: model.timeRange))
                }
                .accessibilityLabel(SessionsCopy.detailJumpToTimelineA11y.text(language))
                Button(SessionsCopy.detailJumpToFileChanges.text(language)) {
                    shell?.jump(JumpIntent(target: .files,
                                           projectPath: session.projectPath,
                                           sessionID: session.id,
                                           timeRange: model.timeRange))
                }
                .accessibilityLabel(SessionsCopy.detailJumpToFileChangesA11y.text(language))
                // #81：命令页那一格同样收得下这一条会话（`CommandQuery.sessionID`）。
                // 少了这颗，「这条会话里跑过哪些命令」这一问就只能跳到命令页
                // 再手打一遍过滤条件。项目条件这一格收不下（`CommandQuery` 没有
                // `projectPath` 字段）⇒ 不假装带了它，见 `EvidenceJumpWiring` 里那段的注释。
                Button(SessionsCopy.detailJumpToCommands.text(language)) {
                    shell?.jump(JumpIntent(target: .commands,
                                           sessionID: session.id,
                                           timeRange: model.timeRange))
                }
                .accessibilityLabel(SessionsCopy.detailJumpToCommandsA11y.text(language))
                Spacer(minLength: Spacing.none)
            }
            .controlSize(.mini)
            // 键盘：这三颗是标准 `Button` ⇒ Tab 走到、Return 按下即可，不需要鼠标。
            // 「看得到焦点在哪」由 `FocusStyleGateTests` 那一族整体守着，这里不各自发明样式。
        }
        .frame(minHeight: Sizing.rowMinHeight)
    }

    /// 「事件预览」是**上限**而不是总数：详情只拉 `eventPreviewCount` 条，实时增量还可能更多。
    private func eventPreviewText(for session: AgentSession) -> String {
        let shown = max(model.counters(for: session).events, model.events.count)
        return SessionsCopy.detailEventCountCap.copy.format(language, shown, SessionsModel.eventPreviewCount)
    }

    // MARK: - 页签

    private var tabPicker: some View {
        Picker(SessionsCopy.detailTabsLabel.text(language), selection: Binding(
            get: { model.detailTab },
            set: { model.setDetailTab($0) }
        )) {
            ForEach(SessionsDetailTab.allCases) { tab in
                Text(tab.displayName).tag(tab)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .accessibilityLabel(SessionsCopy.detailTabsLabel.text(language))
    }

    @ViewBuilder private var tabContent: some View {
        switch model.detailTab {
        case .commands:
            SessionCommandList(
                commands: model.commands,
                isLoading: model.isLoadingDetail,
                errorMessage: model.detailErrorMessage
            )
        case .events:
            eventSummarySection
        case .changes:
            SessionChangeListView(model: model)
        }
    }

    private var eventSummarySection: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    SessionsCopy.detailEventsTitle.text(language),
                    subtitle: SessionsCopy.detailEventsSubtitle.copy.format(language, SessionsModel.eventPreviewCount))

                if model.isLoadingDetail && model.events.isEmpty {
                    HStack(spacing: Spacing.sm) {
                        ProgressView().controlSize(.small)
                        Text(SessionsCopy.detailEventsReading.text(language))
                            .font(.axMeta)
                            .foregroundStyle(Surface.secondaryLabel)
                        Spacer(minLength: Spacing.none)
                    }
                    .frame(minHeight: Sizing.rowMinHeight)
                } else if model.events.isEmpty {
                    EmptyStateView(
                        SessionsCopy.detailEventsEmptyTitle.text(language),
                        systemImage: "waveform.path",
                        message: SessionsCopy.detailEventsEmptyMessage.text(language),
                        fills: false
                    )
                } else {
                    // 条数上界是 SessionsModel.eventPreviewCount ⇒ 用非懒 VStack。
                    let rows = Array(model.events.enumerated())
                    VStack(alignment: .leading, spacing: Spacing.none) {
                        ForEach(rows, id: \.element.id) { index, event in
                            SessionEventRow(event: event)
                            if index < rows.count - 1 {
                                Hairline(inset: Spacing.xs)
                            }
                        }
                    }
                }

                if let message = model.detailErrorMessage, !message.isEmpty {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.axMeta)
                        .foregroundStyle(ObservatoryColor.caution)
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: Spacing.md) {
            ProgressView()
            Text(SessionsCopy.detailReading.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 概览读数的一格

/// 详情概览的一格读数。`MetricGrid` 要 `Identifiable` 的数据，所以把读数收成值类型，
/// 「有几格」与「怎么排」就此分开——原来是八个 `StatTile` 直接摊在自适应列的懒网格里，
/// 谁落单看不出来。
private struct SessionDetailMetric: Identifiable {
    let id: Int
    let title: String
    let value: String
    var unit: String = ""
    var caption: String?
}

// MARK: - 事件行

@MainActor struct SessionEventRow: View {

    /// #64：`event.summary` 是引擎把 `[路径]` 拼进去的一句话 ⇒ 这一格是会话详情里
    /// 绝对路径出屏最多的一处（屏上的行与 VoiceOver 的汇总共用它）。
    @Environment(\.demoRedaction) private var demoRedaction

    let event: TimelineEvent

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(demoRedaction.scrub(event.title))
                    .font(.axBody)
                    .foregroundStyle(Surface.label)
                    .lineLimit(1)
                Spacer(minLength: Spacing.xs)
                if event.riskLevel > .low {
                    RiskBadge(event.riskLevel, prominent: event.riskLevel >= .high)
                        .fixedSize()
                }
                Text(DateFormat.time(event.timestamp))
                    .font(.axMetaMono)
                    .monospacedDigit()
                    .foregroundStyle(Surface.tertiaryLabel)
                    .fixedSize()
            }

            metaRow

            if !event.summary.isEmpty {
                Text(demoRedaction.scrub(event.summary))
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// 行尾元信息：操作类型 + 路径/命令行 + 退出码 + 耗时，一行放不下就中段省略。
    private var metaRow: some View {
        HStack(spacing: Spacing.sm) {
            Text(event.kind.displayName)
                .font(.axMeta)
                .foregroundStyle(ObservatoryTheme.color(for: event.kind))
                .fixedSize()

            if let path = event.filePath, !path.isEmpty {
                FilePathText(path: path, mode: .lastTwoComponents)
                    .frame(maxWidth: 180, alignment: .leading)
            }

            if let command = event.command, !command.isEmpty {
                Text(demoRedaction.scrub(command))
                    .font(.axMetaMono)
                    .foregroundStyle(Surface.secondaryLabel)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: Spacing.xs)

            if let exitCode = event.exitCode {
                // 退出码是数据，颜色已由同一行的 `RiskBadge` / 类型承担。
                Text("exit \(exitCode)")
                    .font(.axMetaMono)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
            }

            if let seconds = event.durationSeconds {
                Text(SessionsCopy.detailTook.copy.format(language, DurationFormat.compact(max(0, seconds))))
                    .font(.axMeta)
                    .monospacedDigit()
                    .axCaptionStyle()   // #99：口径句提档
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilitySummary: String {
        var parts = [
            event.kind.displayName,
            event.title,
            DateFormat.timestamp(event.timestamp),
            AgentNaming.name(kind: event.agentKind, form: .full, language)
        ]
        if !event.summary.isEmpty { parts.append(event.summary) }
        if event.riskLevel > .low {
                    parts.append(SessionsCopy.detailA11yRisk.copy.format(language, event.riskLevel.displayName))
                }
        // #89：读屏那一份是**整句**（title 与 summary 里躺着完整路径与命令行），掩在拼好之后。
        return demoRedaction.scrub(parts.joined(separator: "，"))
    }
}

// MARK: - Previews

private struct SessionDetailPreviewHost: View {
    let runtime: ObservatoryRuntime

    var body: some View {
        SessionDetailView(model: SessionsModel(runtime: runtime))
            .frame(width: 360)
            .frame(maxHeight: .infinity)
    }
}

#Preview("SessionDetailView 未选中") {
    // 空运行时 → 校验详情栏不会出现白屏，给出选择引导。
    ObservatoryPreview.screen(empty: true) { runtime in
        SessionDetailPreviewHost(runtime: runtime)
    }
}

#Preview("SessionEventRow") {
    let now = Date()
    Panel {
        VStack(alignment: .leading, spacing: Spacing.none) {
            SessionEventRow(event: TimelineEvent(
                timestamp: now,
                sessionID: UUID(),
                agentKind: .claudeCode,
                kind: .commandExecuted,
                title: "执行命令 swift test",
                summary: "12 个用例通过，用时 3.2 秒",
                command: "swift test --parallel",
                exitCode: 0,
                durationSeconds: 3.2,
                riskLevel: .low
            ))
            Hairline(inset: Spacing.xs)
            SessionEventRow(event: TimelineEvent(
                timestamp: now.addingTimeInterval(-30),
                agentKind: .openAICodex,
                kind: .fileDeleted,
                title: "批量删除构建产物",
                summary: "删除 DerivedData 下 148 个文件",
                filePath: "/Users/demo/Projects/Mona/.build/x86_64-apple-macosx/debug/module.cache",
                riskLevel: .high
            ))
        }
    }
    .padding(Spacing.lg)
    .frame(width: 460, alignment: .leading)
    .background(Surface.page)
}

private extension SessionDetailView {
    var language: AppLanguage { UILanguage.current }
}

private extension SessionEventRow {
    var language: AppLanguage { UILanguage.current }
}
