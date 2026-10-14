//
//  TimelineEventDetail.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent C) → WS-QUIET-1 (subagent A) 改版
//  选中事件的详情面板：挂在 `TimelineView` 的 `.inspector(isPresented:)` 那一列，
//  给完整字段、命令行、涉及文件、资源开销与会话标识（只在本板块内读完，不跳去别的页面）。
//
//  【quiet 改版改了什么】
//  - 字号全部落到 ax 阶梯：原来这里同时出现 headline / callout / caption / caption2
//    四档非系统阶梯字号，详情读起来像三张不同应用的拼盘。
//  - 事实行改 `InlineStat`（左标签右值，基座已定死 11pt + 次级色），
//    删掉自造的 `field()`：那个 `frame(width: 64)` + 非阶梯小字号就是「不规整」本身。
//  - 颜色只留功能色：退出码的「主色 / 红」二值染色与敏感路径的橙色警示图标换成
//    文案自述（「1（失败）」）与 `Tag(tone: .critical)`；风险等级由 `RiskBadge` 承担。
//  - 底色只允许 `Panel` / `Panel.recessed` / `Surface.*` 三档，列背景用 `Surface.page`。
//

import SwiftUI
import AppKit
import AIObservatoryCore

/// 单条事件的详情面板（inspector 列内容）。
@MainActor struct TimelineEventDetail: View {

    let event: TimelineEvent
    private let onClose: () -> Void

    /// #81：这一条事件的取证出口走带条件跳转，需要写外壳的路由状态。
    @Environment(ShellModel.self) private var shell: ShellModel?

    @State private var copiedText: String?

    init(event: TimelineEvent, onClose: @escaping () -> Void = {}) {
        self.event = event
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            SectionHeader(TimelineCopy.detailTitle.text(language), subtitle: event.kind.displayName) {
                Button(TimelineCopy.detailClose.text(language), action: onClose)
                    .controlSize(.small)
                    .accessibilityLabel(TimelineCopy.detailCloseA11y.text(language))
            }

            // ⚠️ 本栏目唯一被允许的滚动容器：它在 inspector 那一列里，
            // **不在 `ObservatoryPage` 里面**（那一页由基座自己滚），所以不构成双滚动。
            // 详情字段在 300–420pt 宽的窄列里必然超一屏，不滚就只能截断。
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    headline
                    factPanel
                    commandBlock
                    pathBlock
                    evidenceJumpBlock
                    costPanel
                    sessionBlock
                }
                .padding(.bottom, Spacing.lg)
            }
        }
        .padding(Spacing.md)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Surface.page)
        .accessibilityLabel(TimelineCopy.detailTitle.text(language))
    }

    // MARK: - 标题

    private var headline: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(demoRedaction.scrub(event.title))
                .font(.axSection)
                .foregroundStyle(Surface.label)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !event.summary.isEmpty {
                Text(demoRedaction.scrub(event.summary))
                    .font(.axBody)
                    .foregroundStyle(Surface.secondaryLabel)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: Spacing.md) {
                AgentChip(kind: event.agentKind)
                // 风险始终由 `RiskBadge` 说：等级名跟着色点一起显示，`low` 不上色
                //（基座的三档色判定），详情里不再重复一遍字段行。
                RiskBadge(event.riskLevel, prominent: event.riskLevel >= .high)
                Spacer(minLength: Spacing.none)
            }
        }
    }

    // MARK: - 事实

    /// 事实区。口径写死在标签上：时间戳是事件时间，退出码只有命令事件才有。
    private var factPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                InlineStat(TimelineCopy.detailTimeLabel.text(language), value: DateFormat.timestamp(event.timestamp))
                InlineStat(TimelineCopy.detailKindLabel.text(language), value: event.kind.displayName)
                InlineStat(AgentNaming.fieldLabel.text(language),
                           value: AgentNaming.name(kind: event.agentKind, form: .full, language))
                // #47-B 判据②：整句原因上屏（同一句也在 `AgentChip` 的 tooltip 里，
                // 但 hover 不算"能展开"——键盘与读屏用户展不开）。
                AttributionReasonNote(kind: event.agentKind)
                InlineStat(TimelineCopy.detailDurationLabel.text(language),
                           value: event.durationSeconds.map { DurationFormat.compact($0) } ?? "—")
                if event.kind == .commandExecuted {
                    // 命令事件才谈退出码；退码为 nil 是「引擎还没回填」，
                    // 显示成「—」会被读成「没有退出码这件事」，所以把话说明白。
                    InlineStat(TimelineCopy.detailExitCodeLabel.text(language), value: exitCodeText)
                }
                InlineStat(TimelineCopy.detailProjectLabel.text(language),
                       value: demoRedaction.scrub(event.projectPath ?? "—"))
            }
        }
    }

    private var exitCodeText: String {
        guard let exitCode = event.exitCode else {
            return TimelineCopy.detailExitCodeUnfilled.text(language)
        }
        return exitCode == 0
            ? TimelineCopy.detailExitCodeZero.text(language)
            : TimelineCopy.detailExitCodeFailed.format(language, exitCode)
    }

    // MARK: - 命令

    @ViewBuilder private var commandBlock: some View {
        if let command = event.command, !command.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(TimelineCopy.detailCommandTitle.text(language))
                    .axLabelStyle()
                MonospacedCodeView(command, maxLines: 10, showsCopyButton: true)
            }
        }
    }

    // MARK: - 文件路径

    @ViewBuilder private var pathBlock: some View {
        if let path = event.filePath, !path.isEmpty {
            Panel.recessed {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(TimelineCopy.detailFilePathTitle.text(language))
                        .axLabelStyle()
                    FilePathText(path: path, mode: .middleEllipsis)
                    if PathHeuristics.isSensitive(path) {
                        // 敏感路径是「会改变读者判断」的信号，所以给它色点，但不再画三角警示图标
                        //（旧版那个橙色图标是装饰色，而且与风险徽标的橙撞成一团）。
                        Tag(TimelineCopy.detailSensitivePathTag.text(language), tone: .critical)
                    }
                }
            }
        }
    }

    // MARK: - 取证出口（#81：这一条事件的三类条件跟着跳过去）

    /// 这一条事件能不能映射成文件页的变更种类。
    ///
    /// 只有文件那四类可以：文件页没有「执行命令」「风险」这些种类，
    /// 把不存在的条件塞过去会得到一个恒假的过滤器（结果集凭空归零，比不筛更坏）。
    /// 所以那一颗按钮**只在映射得到时出现**，而不是出现了再悄悄少带一项。
    private var fileEventKind: OperationKind? {
        switch event.kind {
        case .fileCreated, .fileModified, .fileDeleted, .fileRenamed: return event.kind
        default: return nil
        }
    }

    @ViewBuilder private var evidenceJumpBlock: some View {
        let hasSession = event.sessionID != nil
        if hasSession || fileEventKind != nil {
            HStack(spacing: Spacing.sm) {
                if let kind = fileEventKind {
                    Button {
                        shell?.jump(JumpIntent(target: .files,
                                               projectPath: event.projectPath,
                                               sessionID: event.sessionID,
                                               eventKinds: [kind],
                                               timeRange: shell?.timeRange))
                    } label: {
                        Label(TimelineCopy.detailJumpToFileChanges.text(language), systemImage: "doc.on.doc")
                    }
                }
                if let sessionID = event.sessionID {
                    Button {
                        shell?.jump(JumpIntent(target: .sessions,
                                               projectPath: event.projectPath,
                                               sessionID: sessionID,
                                               timeRange: shell?.timeRange))
                    } label: {
                        Label(TimelineCopy.detailJumpToSession.text(language), systemImage: "list.bullet.rectangle")
                    }
                }
                Spacer(minLength: Spacing.none)
            }
            .controlSize(.small)
        }
    }

    // MARK: - 资源开销

    private var costPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(TimelineCopy.detailCostTitle.text(language),
                              subtitle: TimelineCopy.detailCostSubtitle.text(language))
                InlineStat(TimelineCopy.detailCPUTimeLabel.text(language), value: DurationFormat.compact(event.cost.cpuSeconds))
                InlineStat(TimelineCopy.detailMemoryLabel.text(language), value: ByteFormat.humanReadable(event.cost.memoryBytes))
                InlineStat(TimelineCopy.detailReadLabel.text(language), value: ByteFormat.humanReadable(event.cost.bytesRead))
                InlineStat(TimelineCopy.detailWriteLabel.text(language), value: ByteFormat.humanReadable(event.cost.bytesWritten))
                if event.cost == .zero {
                    // 「没采到」与「真的是 0」是两种显示 —— 不许合并。
                    // #84：这一句是**这条读数的口径**（0 到底是不是 0），不是装饰，
                    // 所以走口径层而不是原先的 `axMetaStyle()`（11pt + 三级色 ≈1.8:1）。
                    Text(TimelineCopy.detailZeroCostNote.text(language))
                        .axCaptionStyle()
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    // MARK: - 会话

    private var sessionBlock: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            Text(TimelineCopy.detailSessionTitle.text(language))
                .axLabelStyle()
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text("Session  \(abbreviated(event.sessionID))")
                        .font(.axMetaMono)
                        .foregroundStyle(Surface.secondaryLabel)
                    Text("Agent    \(abbreviated(event.agentID))")
                        .font(.axMetaMono)
                        .foregroundStyle(Surface.secondaryLabel)
                }
                Spacer(minLength: Spacing.xs)
                Button {
                    copyToPasteboard(plainTextDump)
                } label: {
                    Label(copiedText ?? TimelineCopy.copyAction.text(language),
                          systemImage: copiedText == nil ? "doc.on.doc" : "checkmark")
                }
                .controlSize(.small)
            }
        }
    }

    /// 本次启动的语言（`UILanguage` 一处解析，见其注释）。
    private var language: AppLanguage { UILanguage.current }

    // MARK: - Helpers

    private func abbreviated(_ id: UUID?) -> String {
        guard let id else { return "—" }
        let full = id.uuidString
        return String(full.prefix(8)) + "…"
    }

    /// #64：这一段是**会进剪贴板、离开本 App** 的（`copyToPasteboard`）。
    /// 原来 `file:` / `project:` / `command:` / `summary` 四条直出绝对路径，
    /// 开着脱敏复制一次就把家目录贴进别人的聊天窗口——比屏上那格严重。
    @Environment(\.demoRedaction) private var demoRedaction

    private var plainTextDump: String {
        var lines: [String] = [
            "[\(DateFormat.timestamp(event.timestamp))] \(AgentNaming.name(kind: event.agentKind, form: .full)) · \(event.kind.displayName)",
            demoRedaction.scrub(event.title)   // #89：整份复制出去的转储里唯独它没掩
        ]
        if !event.summary.isEmpty { lines.append(demoRedaction.scrub(event.summary)) }
        if let command = event.command { lines.append("command: \(demoRedaction.scrub(command))") }
        if let path = event.filePath { lines.append("file: \(demoRedaction.scrub(path))") }
        if let exitCode = event.exitCode { lines.append("exit code: \(exitCode)") }
        if let duration = event.durationSeconds { lines.append("duration: \(DurationFormat.compact(duration))") }
        lines.append("risk: \(event.riskLevel.displayName)")
        lines.append("cost: cpu \(DurationFormat.compact(event.cost.cpuSeconds)), memory \(ByteFormat.humanReadable(event.cost.memoryBytes)), read \(ByteFormat.humanReadable(event.cost.bytesRead)), write \(ByteFormat.humanReadable(event.cost.bytesWritten))")
        lines.append("session: \(event.sessionID.map(\.uuidString) ?? "—")")
        lines.append("agent: \(event.agentID.map(\.uuidString) ?? "—")")
        if let project = event.projectPath { lines.append("project: \(demoRedaction.scrub(project))") }
        return lines.joined(separator: "\n")
    }

    private func copyToPasteboard(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let ok = pasteboard.setString(text, forType: .string)
        copiedText = ok ? TimelineCopy.copySucceeded.text(language) : TimelineCopy.copyFailed.text(language)
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            guard !Task.isCancelled else { return }
            copiedText = nil
        }
    }
}

// MARK: - Previews

#Preview("时间线详情") {
    TimelineEventDetail(event: TimelineEvent(
        agentKind: .claudeCode,
        kind: .commandExecuted,
        title: "执行 rm -rf ./build",
        summary: "在工作目录内执行递归删除，命中破坏性规则 R-004。",
        filePath: "/Users/demo/AiX/build",
        command: "rm -rf ./build",
        exitCode: 1,
        durationSeconds: 3.4,
        cost: ResourceCost(cpuSeconds: 1.2, memoryBytes: 38_000_000, bytesRead: 900_000, bytesWritten: 0),
        riskLevel: .high,
        projectPath: "/Users/demo/AiX"
    ))
    .frame(width: 340, height: 640)
}
