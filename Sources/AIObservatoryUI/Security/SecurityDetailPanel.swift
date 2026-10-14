//
//  SecurityDetailPanel.swift
//  AIObservatoryUI / Security
//
//  Owner: WS-UI → WS-QUIET-3（本轮按 ADR-0007 重排到「quiet」语言）
//  职责：风险事件详情 —— 判定依据、命中命令、涉及路径（含敏感路径标注）、确认动作。
//
//  刻意**不套外层 `Panel`、也不自带 `ScrollView`**：
//  本视图自己就是若干个 `Panel`（判定依据 / 触发命令 / 涉及路径 / 归属），
//  再包一层会得到「白底里嵌白底」——两级同色容器互相抵消，什么都分隔不了；
//  而 `ObservatoryPage` 已经是滚动容器，内层再放一个就是嵌套滚动（见 `SecurityView` 文件头）。
//  行内的路径与命令是**无上限**的内容（一条事件可能命中几十个路径），
//  所以它们只在自己的 Panel 里用 `prefix` 截断，不靠第二个滚动条。
//

import SwiftUI
import AIObservatoryCore

/// 右侧风险详情面板。
@MainActor
struct SecurityDetailPanel: View {
    let event: RiskEvent
    var onAcknowledge: (() -> Void)?
    var onDefer: (() -> Void)?
    var canJumpToTimeline: Bool = false
    var onJumpToTimeline: (() -> Void)?

    private var language: AppLanguage { UILanguage.current }
    /// #64：`event.detail` 是规则依据句，里面**就是**那条被命中的绝对路径
    /// （`SensitiveLocationRules` 把路径拼进依据），所以这一格是风险页的主要出口。
    @Environment(\.demoRedaction) private var demoRedaction
    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            header
            Panel {
                VStack(alignment: .leading, spacing: Spacing.md) {
                    SectionHeader(SecurityCopy.rationaleTitle.text())
                    Text(SecurityCopy.rationale(demoRedaction.scrub(event.detail)))
                        .font(.axBody)
                        .foregroundStyle(Surface.label)
                        .fixedSize(horizontal: false, vertical: true)
                    if let ruleID = event.matchedRuleID {
                        Hairline()
                        InlineStat(SecurityCopy.matchedRuleTitle.text(), value: ruleID)
                    }
                }
            }
            if let command = event.command, !command.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SectionHeader(SecurityCopy.triggeredCommand.text(language))
                        MonospacedCodeView(command, maxLines: 4)
                    }
                }
            }
            if !event.filePaths.isEmpty {
                Panel {
                    VStack(alignment: .leading, spacing: Spacing.sm) {
                        SectionHeader(
                            SecurityCopy.involvedPaths.text(language),
                            subtitle: SecurityCopy.countedItems(event.filePaths.count, language))
                        ForEach(event.filePaths.prefix(Self.pathRowLimit), id: \.self) { path in
                            pathRow(path)
                        }
                        if event.filePaths.count > Self.pathRowLimit {
                            Hairline()
                            Text(SecurityCopy.morePathsUnlisted.format(language, event.filePaths.count - Self.pathRowLimit))
                                .axCaptionStyle()
                        }
                    }
                }
            }
            attribution
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 详情里最多列几条路径：再多是滚也看不完的噪声，完整清单走导出。
    private static let pathRowLimit = 12

    // MARK: 片段

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            HStack(spacing: Spacing.sm) {
                RiskBadge(event.level, prominent: true)
                Text(event.category.displayName)
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                Spacer(minLength: Spacing.sm)
                Text(DateFormat.timestamp(event.timestamp))
                    .font(.axMetaMono)
                    .monospacedDigit()
                    .foregroundStyle(Surface.tertiaryLabel)
            }
            Text(demoRedaction.scrub(event.title))
                .font(.axSection)
                .foregroundStyle(Surface.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pathRow(_ path: String) -> some View {
        let sensitive = PathHeuristics.isSensitive(path)
        return HStack(spacing: Spacing.sm) {
            Image(systemName: sensitive ? "lock.open.trianglebadge.exclamationmark" : "doc.text")
                .font(.axMeta)
                .foregroundStyle(sensitive ? ObservatoryColor.critical : Surface.tertiaryLabel)
            FilePathText(path: path)
            if sensitive {
                Text(SecurityCopy.sensitivePathTitle.text(language))
                    .font(.axLabel)
                    .foregroundStyle(ObservatoryColor.critical)
            }
        }
    }

    private var attribution: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(SecurityCopy.attributionTitle.text(language))
                Grid(alignment: .leading, horizontalSpacing: Spacing.lg, verticalSpacing: Spacing.sm) {
                    GridRow {
                        InlineStat(AgentNaming.fieldLabel.text(language),
                                   value: AgentNaming.name(kind: event.agentKind, form: .full, language))
                        InlineStat(
                            SecurityCopy.statusTitle.text(language),
                            value: event.isAcknowledged ? SecurityCopy.acknowledged.text(language)
                                : SecurityCopy.statusPending.text(language))
                    }
                    GridRow {
                        InlineStat(SecurityCopy.fileCountTitle.text(language), value: "\(event.filePaths.count)")
                        InlineStat(
                            SecurityCopy.sessionTitle.text(language),
                            value: event.sessionID == nil ? SecurityCopy.sessionUnattributed.text(language)
                                : SecurityCopy.sessionAttributed.text(language))
                    }
                }
                // #47-B 判据②：原因必须**能展开**，而 tooltip 只有鼠标展得开。
                // 这一格是"点一行看详情"那一屏，所以整句原因排在这里，不只在 hover 里。
                AttributionReasonNote(kind: event.agentKind)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: Spacing.sm) {
            if !event.isAcknowledged {
                Button {
                    onAcknowledge?()
                } label: {
                    Text(SecurityCopy.markAcknowledged.text(language))
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(onAcknowledge == nil)

                if event.requiresConfirmation {
                    Button(SecurityCopy.laterButton.text(language)) { onDefer?() }
                        .buttonStyle(.bordered)
                }
            } else {
                Text(SecurityCopy.alreadyAcknowledged.text(language))
                    .font(.axBody)
                    .foregroundStyle(ObservatoryColor.positive)
            }

            if canJumpToTimeline, let onJumpToTimeline {
                Spacer(minLength: Spacing.sm)
                Button(SecurityCopy.viewInTimeline.text(language), action: onJumpToTimeline)
                    .buttonStyle(.link)
            }
        }
        .controlSize(.regular)
    }
}

#Preview("SecurityDetailPanel") {
    ScrollView {
        SecurityDetailPanel(
            event: RiskEvent(
                timestamp: Date(timeIntervalSince1970: 1_800_000_000),
                level: .high,
                category: .sensitivePathAccess,
                title: "写入受保护目录",
                detail: "目标路径命中敏感目录规则（~/.ssh、~/.aws 等）。",
                agentKind: .claudeCode,
                command: "printf 'x' >> ~/.ssh/authorized_keys",
                filePaths: [
                    "/Users/demo/.ssh/authorized_keys",
                    "/Users/demo/.aws/credentials",
                ],
                matchedRuleID: "R-SENS-02"
            ),
            onAcknowledge: {},
            canJumpToTimeline: false
        )
        .padding(Spacing.xl)
    }
    .frame(width: 620, height: 720)
    .background(Surface.page)
}
