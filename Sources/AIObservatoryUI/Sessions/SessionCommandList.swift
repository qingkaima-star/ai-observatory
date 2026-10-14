//
//  SessionCommandList.swift
//  AIObservatoryUI / Sessions
//
//  Owner: WS-UI (subagent I)
//  会话详情的命令记录面板：等宽命令行 + 退出码 + 耗时 + 破坏性/需确认标记，支持本地「只看危险命令」。
//  数据由 `SessionsModel` 通过 `CommandQuery(sessionID:)` 拉取，本视图为纯展示 + 本地二次过滤。
//  ─────────────────────────────────────────────────────────
//  【quiet 改版要点】旧版每条命令一张 `Panel(padding: .sm)` 小卡，卡里再挂两个
//  外加「需确认」「破坏性」两枚描边胶囊（8% 色调填充 + 1pt 描边），
//  退出码还要按成败染绿/染红——一屏 200 条命令就是 200 个盒子 + 400 个胶囊。
//  现在整个列表只有一个 `Panel`，行与行之间用 `Hairline()` 分隔，状态一律 `Tag`（色点 + 文字）。
//  「只看危险命令」是**本面板**的开关，所以留在 `SectionHeader` 的 trailing，不再上浮到页面标题行。
//
//  ⚠️ 命令行数上界是 `SessionsModel.commandPageSize`（有界），所以这里用**非懒** `VStack`：
//  懒容器在这里省不到东西，反而会反复回收 `MonospacedCodeView` 里的横向滚动条。
//

import SwiftUI
import AIObservatoryCore

@MainActor struct SessionCommandList: View {

    private let commands: [CommandRecord]
    private let isLoading: Bool
    private let errorMessage: String?

    @State private var destructiveOnly: Bool = false

    init(commands: [CommandRecord], isLoading: Bool = false, errorMessage: String? = nil) {
        self.commands = commands
        self.isLoading = isLoading
        self.errorMessage = errorMessage
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    SessionsCopy.commandsTitle.text(language),
                    subtitle: headerSubtitle) {
                    Toggle(isOn: Binding(
                        get: { destructiveOnly },
                        set: { destructiveOnly = $0 }
                    )) {
                        Label(SessionsCopy.commandsDangerousOnly.text(language), systemImage: "exclamationmark.octagon")
                    }
                    .toggleStyle(.button)
                    .controlSize(.mini)
                    .fixedSize()
                    .help(SessionsCopy.commandsDangerousOnlyHelp.text(language))
                }

                content
            }
        }
    }

    // MARK: - 内容

    @ViewBuilder private var content: some View {
        if isLoading && commands.isEmpty {
            loadingRow
        } else if visibleRecords.isEmpty {
            emptyRow
        } else {
            let rows = Array(visibleRecords.enumerated())
            VStack(alignment: .leading, spacing: Spacing.none) {
                ForEach(rows, id: \.element.id) { index, record in
                    SessionCommandRow(record: record)
                    if index < rows.count - 1 {
                        Hairline(inset: Spacing.xs)
                    }
                }
            }
        }

        if let errorMessage, !errorMessage.isEmpty {
            Label(errorMessage, systemImage: "exclamationmark.triangle")
                .font(.axMeta)
                .foregroundStyle(ObservatoryColor.caution)
        }
    }

    // MARK: - 数据

    private var visibleRecords: [CommandRecord] {
        guard destructiveOnly else { return commands }
        return commands.filter { $0.isDestructive }
    }

    private var destructiveCount: Int { commands.lazy.filter { $0.isDestructive }.count }

    private var failureCount: Int { commands.lazy.filter { $0.outcome == .failure }.count }

    /// 三个数字的口径都是「本会话已加载的命令明细」，上界 `SessionsModel.commandPageSize`。
    private var headerSubtitle: String {
        if commands.isEmpty {
                return isLoading ? SessionsCopy.commandsLoading.text(language)
                                 : SessionsCopy.commandsNoneCaptured.text(language)
            }
        return SessionsCopy.commandsProgress.copy.format(language, commands.count, failureCount, destructiveCount)
    }

    // MARK: - 状态行

    private var loadingRow: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView().controlSize(.small)
            Text(SessionsCopy.commandsReading.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            Spacer(minLength: Spacing.none)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Sizing.rowMinHeight)
    }

    private var emptyRow: some View {
        EmptyStateView(
            destructiveOnly ? SessionsCopy.commandsNoDangerous.text(language)
                              : SessionsCopy.commandsNoExecutions.text(language),
            systemImage: destructiveOnly ? "shield.lefthalf.filled" : "terminal",
            message: destructiveOnly
                ? SessionsCopy.commandsDangerousFilteredAll.copy.format(language, commands.count)
                : SessionsCopy.commandsPollingNote.text(language),
            fills: false
        ) {
            if destructiveOnly {
                Button(SessionsCopy.commandsShowAll.text(language)) { destructiveOnly = false }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 单条命令

@MainActor struct SessionCommandRow: View {

    let record: CommandRecord
    /// #89：正文那格（`MonospacedCodeView`，组件内已掩）之外，读屏这一句是自己拼的。
    @Environment(\.demoRedaction) private var demoRedaction

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            MonospacedCodeView(record.commandLine, maxLines: 2, showsCopyButton: true)
            metaRow
        }
        .padding(.vertical, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
    }

    /// 行尾元信息：结果 `Tag` + 退出码 + 耗时 + 工作目录 + 标记，全部 11pt，不画框不上装饰色。
    private var metaRow: some View {
        HStack(spacing: Spacing.sm) {
            Tag(record.outcome.displayName(UILanguage.current), tone: .commandOutcome(record.outcome))
                .fixedSize()

            if let exitCode = record.exitCode {
                // 退出码是**数据**不是第二套状态色：颜色已由上面的 Tag 承担。
                Text("exit \(exitCode)")
                    .font(.axMetaMono)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
            }

            if let duration = record.duration {
                Text(SessionsCopy.commandsTook.copy.format(language, DurationFormat.compact(max(0, duration))))
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
            }

            if let workdir = record.workingDirectory, !workdir.isEmpty {
                FilePathText(path: workdir, mode: .lastTwoComponents)
                    .lineLimit(1)
                    .frame(maxWidth: 180, alignment: .leading)
            }

            Spacer(minLength: Spacing.xs)

            if record.isDestructive {
                Tag(SessionsCopy.commandsDestructiveTag.text(language), tone: .critical)
                    .fixedSize()
            }

            if record.requiresConfirmation {
                Tag(SessionsCopy.commandsNeedsConfirmTag.text(language), tone: .neutral)
                    .fixedSize()
            }

            Text(DateFormat.time(record.startedAt))
                .font(.axMetaMono)
                .monospacedDigit()
                .foregroundStyle(Surface.tertiaryLabel)
                .fixedSize()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilitySummary: String {
        var parts = [
            SessionsCopy.commandsA11yLine.copy.format(language, record.commandLine),
            AgentNaming.name(kind: record.agentKind, form: .compact),
            record.outcome.displayName(UILanguage.current),
            DateFormat.timestamp(record.startedAt)
        ]
        if let exitCode = record.exitCode { parts.append(SessionsCopy.commandsA11yExitCode.copy.format(language, exitCode)) }
        if let duration = record.duration {
                parts.append(SessionsCopy.commandsA11yTook.copy.format(language, DurationFormat.compact(max(0, duration))))
            }
        if record.isDestructive { parts.append(SessionsCopy.commandsA11yDestructive.text(language)) }
        // #89：整句交给 `scrub`——命令行在**句中**，而 `Mask.apply` 只认"整串以某个根开头"，
        // 后者正是 #64 的漏因。
        return demoRedaction.scrub(parts.joined(separator: "，"))
    }
}

// MARK: - Previews

#Preview("SessionCommandList") {
    let now = Date()
    Panel {
        SessionCommandList(commands: [
            CommandRecord(
                executable: "rm",
                arguments: ["-rf", "./DerivedData"],
                workingDirectory: "/Users/demo/Projects/Mona",
                agentKind: .claudeCode,
                startedAt: now.addingTimeInterval(-120),
                endedAt: now.addingTimeInterval(-118),
                exitCode: 0,
                outcome: .success,
                isDestructive: true,
                riskLevel: .high
            ),
            CommandRecord(
                executable: "swift",
                arguments: ["test", "--parallel"],
                workingDirectory: "/Users/demo/Projects/Mona",
                agentKind: .openAICodex,
                startedAt: now.addingTimeInterval(-60),
                endedAt: now.addingTimeInterval(-12),
                exitCode: 1,
                outcome: .failure,
                requiresConfirmation: true
            ),
            CommandRecord(
                executable: "git",
                arguments: ["push", "origin", "ws/ui"],
                agentKind: .genericCLIAgent,
                startedAt: now.addingTimeInterval(-30),
                outcome: .running
            )
        ])
    }
    .padding(Spacing.lg)
    .frame(width: 560, alignment: .leading)
    .background(Surface.page)
}

private extension SessionCommandList {
    var language: AppLanguage { UILanguage.current }
}

private extension SessionCommandRow {
    var language: AppLanguage { UILanguage.current }
}
