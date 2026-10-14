//
//  CommandsDetailView.swift
//  Commands
//
//  Owner: WS-UI（由 CommandsView.swift 原样搬来：只按职责分文件，行为未变。）
//

import SwiftUI
import Observation
import AIObservatoryCore
// MARK: - 详情面板

@MainActor struct CommandsDetailView: View {

    private let model: CommandsModel
    private let runtime: ObservatoryRuntime

    init(model: CommandsModel, runtime: ObservatoryRuntime) {
        self.model = model
        self.runtime = runtime
    }

    private var language: AppLanguage { UILanguage.current }

    /// 详情侧自己再套一层 `ScrollView`：它的高度由主从区的高度带钉死，因此有界，
    /// 不违反「`ScrollView` 里不嵌无限高度滚动区」。
    /// 底色不再自造（旧版 `.primary.opacity(0.03)`）——外层主从 `Panel` 已是白，
    /// 内层分块一律 `Panel.recessed` 表达下沉，不套两层白底。
    var body: some View {
        Group {
            if let record = model.selectedRecord {
                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.md) {
                        header(for: record)
                        commandBlock(for: record)
                        factsCard(for: record)
                        contextCard(for: record)
                    }
                    .padding(.vertical, Spacing.xs)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                EmptyStateView(
                    CommandsCopy.detailUnselectedTitle.text(language),
                    systemImage: "terminal",
                    message: CommandsCopy.detailUnselectedMessage.text(language)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: 头部

    /// `SectionHeader` 的字号由基座定死（13pt 半粗），调用点不再挂 `.font(.callout)`。
    /// #82：头部那一句与下面「上下文」里的 Agent 字段走**同一个入口**
    /// （改前一处读 `record.agentKind.displayName`、另一处读 `AgentChip`，
    /// 同一条记录在详情页与列表行里可以是两个名字）。
    private func header(for record: CommandRecord) -> some View {
        SectionHeader(
            CommandsCopy.detailHeader.text(language),
            subtitle: "\(AgentNaming.name(kind: record.agentKind)) · \(DateFormat.timestamp(record.startedAt))") {
            HStack(spacing: Spacing.sm) {
                if record.riskLevel > .low {
                    RiskBadge(record.riskLevel, prominent: record.riskLevel >= .high)
                }
            }
        }
    }

    /// 三块的画法统一成「标题在白底上 + 内容在 `Panel.recessed` 里」，
    /// 因此三条左边缘只有两条：标题一条、下沉盒一条，且都落在列的起点上。
    /// 旧写法把标题塞进 recessed 盒里，标题就被盒子的 16pt 内边距推进去，
    /// 而 `MonospacedCodeView` 自己带下沉底、只能留在盒外——真机截图上那两条错开的对齐线就是这么来的。
    /// `MonospacedCodeView` 自带 `Panel.recessed` 下沉，所以它外面套 `Panel.plain`（无底），
    /// 不再叠第二层 recessed——「下沉里再下沉」会叠成一块更暗的方框。
    private func commandBlock(for record: CommandRecord) -> some View {
        Panel.plain(padding: Spacing.none) {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(CommandsCopy.commandLineSection.text(language),
                              subtitle: CommandsCopy.argumentCount.format(language, record.arguments.count))
                MonospacedCodeView(record.commandLine, maxLines: 12, showsCopyButton: true)
            }
        }
    }

    // MARK: 审计三要素（命令 / 退出结果 / 耗时）

    private func factsCard(for record: CommandRecord) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(CommandsCopy.factsSection.text(language),
                          subtitle: CommandsCopy.factsSubtitle.text(language))
            Panel.recessed {
                VStack(alignment: .leading, spacing: Spacing.none) {
                    factsFields(for: record)
                    // 诚实说明（或分隔线 + 说明）只在真有话要说时出现，
                    // 正常退出的命令不留一条指向空处的 hairline。
                    outcomeNote(for: record)
                }
            }
        }
    }

    /// 字段行统一 `InlineStat`，行与行之间只允许面板内部的 `Hairline`。
    private func factsFields(for record: CommandRecord) -> some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            InlineStat(CommandsCopy.fieldExitResult.text(language),
                       value: CommandAuditFormat.exitText(of: record), emphasized: true)
            Hairline()
            InlineStat(CommandsCopy.fieldExecutionState.text(language), value: record.outcome.displayName)
            Hairline()
            InlineStat(CommandsCopy.fieldDuration.text(language), value: CommandAuditFormat.durationText(of: record))
            Hairline()
            InlineStat(CommandsCopy.fieldStartedAt.text(language), value: DateFormat.timestamp(record.startedAt))
            Hairline()
            InlineStat(CommandsCopy.fieldEndedAt.text(language), value: CommandAuditFormat.endedText(of: record))
        }
    }

    /// 两条诚实说明**原文保留**：没采到码不把成败猜成任何一侧；非 0 就明说没正常结束。
    /// 颜色只加在「退出码非 0」那条——它才是需要现在处理的那一件。
    /// 分隔线跟着说明一起出现：正常退出时这里整块不产出，不留下指向空处的线。
    @ViewBuilder private func outcomeNote(for record: CommandRecord) -> some View {
        if record.exitCode == nil {
            Hairline()
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Tag(CommandAuditFormat.unknownResultText(language), tone: .neutral)
                Text(CommandsCopy.noExitCodeNote.text(language))
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Spacing.sm)
        } else if let code = record.exitCode, code != 0 {
            Hairline()
            HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
                Tag(CommandsCopy.tagNonZeroExit.text(language), tone: .critical)
                Text(CommandsCopy.nonZeroExitNote.text(language))
                    .font(.axMeta)
                    .foregroundStyle(ObservatoryColor.critical)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, Spacing.sm)
        }
    }

    // MARK: 上下文

    private func contextCard(for record: CommandRecord) -> some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            SectionHeader(CommandsCopy.contextSection.text(language))
            Panel.recessed {
                VStack(alignment: .leading, spacing: Spacing.none) {
                    InlineStat(AgentNaming.fieldLabel.text(language),
                               value: AgentNaming.name(kind: record.agentKind))
                    Hairline()
                    pathRow(label: CommandsCopy.fieldWorkingDirectory.text(language),
                            path: record.workingDirectory, mode: .middleEllipsis)
                    Hairline()
                    pathRow(label: CommandsCopy.fieldProject.text(language),
                            path: record.projectPath, mode: .lastTwoComponents)
                    Hairline()
                    CommandSessionLink(sessionID: record.sessionID, model: model, runtime: runtime)
                        .padding(.vertical, Spacing.xs)

                    flagsRow(for: record)
                }
            }
        }
    }

    /// 详情页把「破坏性」与「需确认」**两枚都摊开**（一条命令可以同时成立），
    /// 与列表行「至多一个标记」并不矛盾：行要压高度，详情要讲全。
    /// 两者都不成立时才落「常规命令」。
    private func flagsRow(for record: CommandRecord) -> some View {
        HStack(spacing: Spacing.sm) {
            if record.isDestructive {
                Tag(CommandsCopy.tagDestructive.text(language), tone: .critical)
            }
            if record.requiresConfirmation {
                Tag(CommandsCopy.tagRequiresConfirmation.text(language), tone: .caution)
            }
            if !record.isDestructive, !record.requiresConfirmation {
                Tag(CommandsCopy.tagRoutine.text(language), tone: .positive)
            }
            Spacer(minLength: Spacing.none)
        }
        .padding(.top, Spacing.sm)
    }

    @ViewBuilder private func pathRow(label: String, path: String?, mode: FilePathText.Mode) -> some View {
        if let path, !path.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(label)
                    .font(.axLabel)
                    .foregroundStyle(Surface.secondaryLabel)
                FilePathText(path: path, mode: mode)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, Spacing.xs)
        } else {
            InlineStat(label, value: CommandAuditFormat.missingValueText)
        }
    }
}

/// 命令所属会话：标题要按 id 反查服务层，查不到就老实显示占位，不编一个名字。
@MainActor struct CommandSessionLink: View {

    private let sessionID: UUID?
    private let model: CommandsModel
    private let runtime: ObservatoryRuntime

    /// #81：这一条命令的取证出口（→ 时间线）要写外壳的路由状态。
    @Environment(ShellModel.self) private var shell: ShellModel?

    @State private var title: String?
    @State private var isResolving = false

    init(sessionID: UUID?, model: CommandsModel, runtime: ObservatoryRuntime) {
        self.sessionID = sessionID
        self.model = model
        self.runtime = runtime
    }

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let sessionID {
                HStack(spacing: Spacing.xs) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                    Text(CommandsCopy.fieldSession.text(language))
                        .font(.axLabel)
                        .foregroundStyle(Surface.secondaryLabel)
                    Spacer(minLength: Spacing.sm)
                    Text(displayTitle)
                        .font(.axBody)
                        .foregroundStyle(title == nil ? Surface.secondaryLabel : Surface.label)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                Button {
                    Task { await model.focusSession(sessionID) }
                } label: {
                    Label(CommandsCopy.focusSession.text(language),
                          systemImage: "line.3.horizontal.decrease.circle")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
                .help(CommandsCopy.focusSessionHelp.format(language, sessionID.uuidString))

                // #81：这一条命令的对外取证出口。原来这一格只有「只看此会话」（本页内收窄），
                // 用户想看的却是「这条命令是在什么现场跑的」——那一屏在时间线，
                // 而跳过去必须带着这一条会话，否则落地的还是全量。
                Button {
                    shell?.jump(JumpIntent(target: .timeline,
                                           sessionID: sessionID,
                                           timeRange: shell?.timeRange))
                } label: {
                    Label(CommandsCopy.jumpToTimeline.text(language), systemImage: "clock.arrow.circlepath")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .fixedSize()
            } else {
                InlineStat(CommandsCopy.fieldSession.text(language),
                           value: CommandsCopy.sessionUnlinked.text(language))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: sessionID) { await resolve() }
    }

    private var displayTitle: String {
        if isResolving { return CommandsCopy.resolving.text(language) }
        guard let title, !title.isEmpty else { return CommandsCopy.unnamedSession.text(language) }
        return title
    }

    private func resolve() async {
        title = nil
        guard let sessionID else {
            isResolving = false
            return
        }
        isResolving = true
        defer { isResolving = false }
        do {
            title = try await runtime.service.session(id: sessionID)?.title
        } catch {
            // 反查失败不影响命令本身的可信度：退回占位标题，不弹错误。
            title = nil
        }
    }
}
