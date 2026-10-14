//
//  FileChangeRow.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (QUIET-2)
//  ─────────────────────────────────────────────────────────
//  文件变更列表行：单行 + 尾元信息，行间 `Hairline()`，不画框不填充。
//
//  旧版是「类型色点 + 两行（文件名/目录 + 增删 + 时间）+ 圆角卡 + 描边 + 选中色填充」，
//  拥挤且在深色下发脏。现在：第一行文件名 + 尾部元信息（增删行数 / 时间 / Agent / 风险），
//  状态用 `Tag` / `RiskBadge`（色点 + 文字），不再有胶囊底色或描边。
//
//  增删行数是 diff 功能色（绿/红），保留；类型只用一枚 `Tag` 携带，不再用彩色圆点。
//

import SwiftUI
import AIObservatoryCore

@MainActor struct FileChangeRow: View {

    let change: FileChange
    var isSelected: Bool = false
    var action: (() -> Void)?
    /// #61/#64 演示脱敏。默认 `.off` = 恒等 ⇒ 没注入时与今天逐字一致。
    @Environment(\.demoRedaction) private var demoRedaction

    init(change: FileChange, isSelected: Bool = false, action: (() -> Void)? = nil) {
        self.change = change
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(change.fileName)
                    .font(.axBody)
                    .foregroundStyle(Surface.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .strikethrough(change.kind == .deleted)

                Spacer(minLength: Spacing.sm)

                meta
            }
            .frame(minHeight: Sizing.rowMinHeight)

            Hairline()
        }
        .padding(.vertical, Spacing.xs)
        // 选中只换底色，不描边、不加彩色填充。
        .background(isSelected ? Surface.selectedRow : Color.clear)
        .contentShape(Rectangle())
        // #11：与 `SessionRow` / `CommandAuditRow` / `ProjectCard` 同步换成整块可点的共用处理
        // （原来是 `.onTapGesture`：没有悬停、没有按下、Tab 走不到）。
        .axPressable(when: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - 尾元信息

    /// 行尾：类型 Tag → 增删行数 → 时间 → Agent → 风险。
    /// 抽成独立 `some View` 压住类型检查，并避免行内出现第二种状态表达。
    ///
    /// 【#83】增删行数 / 时间 / Agent 三格原先一律无定宽（只靠 `Spacer` 推右），
    /// 行间不同名同宽 ⇒ 同一列是锯齿状的。现在宽度只从 `Column` 取。
    private var meta: some View {
        HStack(spacing: Spacing.sm) {
            kindTag

            lineDelta

            Text(DateFormat.time(change.timestamp))
                .font(.axMeta)
                .axNumberColumn(Column.time)
                .foregroundStyle(Surface.tertiaryLabel)

            AgentChip(kind: change.agentKind, compact: true)
                .axLeadingColumn(Column.agentIdentity)

            if change.riskLevel > .low {
                RiskBadge(change.riskLevel, prominent: change.riskLevel >= .high)
            }
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    /// 变更类型：用 `Tag`（色点 + 文字）携带，不再用彩色圆点。
    @ViewBuilder private var kindTag: some View {
        switch change.kind {
        case .created:   Tag(FilesCopy.kindCreated.text(), tone: .positive)
        case .deleted:   Tag(FilesCopy.kindDeleted.text(), tone: .critical)
        case .renamed:   Tag(FilesCopy.kindRenamed.text(), tone: .neutral)
        case .modified:  Tag(FilesCopy.kindModified.text(), tone: .neutral)
        case .unknown:   EmptyView()
        }
    }

    /// 增删行数：diff 的「新增绿 / 删除红」是全应用保留的功能色之一（契约 §2）。
    private var lineDelta: some View {
        HStack(spacing: Spacing.xs) {
            if change.linesAdded > 0 {
                Text("+\(change.linesAdded)")
                    .foregroundStyle(ObservatoryColor.positive)
            }
            if change.linesRemoved > 0 {
                Text("-\(change.linesRemoved)")
                    .foregroundStyle(ObservatoryColor.critical)
            }
            if change.linesAdded == 0, change.linesRemoved == 0 {
                Text(ByteFormat.humanReadable(change.sizeBytes))
                    .foregroundStyle(Surface.tertiaryLabel)
            }
        }
        .font(.axMeta)
        .axNumberColumn(Column.delta)
    }

    private var accessibilitySummary: String {
        var parts = [
            change.kind.displayName,
            change.fileName,
            // #64：VoiceOver 念的这一份和屏上的像素是同一个出口——开着脱敏却把绝对路径
            // 读给辅助技术，等于开关只糊住了眼睛。走 `scrub`：整串就是路径，`apply` 够用，
            // 但和句中路径共用一把尺更省事（口径见 `PathPrivacy`）。
            demoRedaction.scrub(change.path),
            DateFormat.timestamp(change.timestamp),
            AgentNaming.name(kind: change.agentKind, form: .compact)
        ]
        parts.append(FilesCopy.lineDelta.format(.resolved(), String(change.linesAdded),
                                                String(change.linesRemoved)))
        if change.riskLevel > .low {
            parts.append(FilesCopy.riskPrefix.format(.resolved(), change.riskLevel.displayName))
        }
        return parts.joined(separator: FilesCopy.clauseJoiner.text())
    }
}
