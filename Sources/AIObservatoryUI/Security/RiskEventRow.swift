//
//  RiskEventRow.swift
//  AIObservatoryUI / Security
//
//  Owner: WS-UI → WS-QUIET-3（本轮按 ADR-0007 重排到「quiet」语言）
//  职责：单条风险事件的列表行 —— **一行**：等级 + 标题 + 行尾元信息。
//
//  与旧版的区别就是本次重构的缩影。旧版一条三行（标题 / 元信息 / 命令），
//  并且同时用**四种**手段表达「等级」：3pt 色条、按等级染色的 SF 图标、
//  `RiskBadge`、行尾再挂一次 `RiskBadge`；类别还被包进一颗带底色的胶囊。
//  一屏二十行读下来，页面被切成一堆小按钮——那就是「拥挤」与「没有主次」的字面来源。
//  现在等级只由 `RiskBadge`（色点 + 等级名）表达一次，
//  命令、类别、详情一律挪进右侧详情面板（那里本来就有，不需要行内重复）。
//
//  【#11 · 2026-09-22】这一行的"能点"从此与全站同一份：`Button` 的样式由 `.plain`
//  换成 `DesignSystem/InteractiveFeedback.swift` 里的 `.axPressable`
//  （悬停 / 按下同一档，焦点环仍由系统画）。判据见 `InteractionFeedbackTests`。
//

import SwiftUI
import AIObservatoryCore

/// 风险事件列表行。
@MainActor
struct RiskEventRow: View {

    /// #89：这一格上屏的是"一条活动"的自由文本，与时间线行同源 ⇒ 统一交给 `scrub`
    /// （今天这些句子里没有绝对路径，但"有没有"由生产侧决定，不该要求每个视图记得看一眼）。
    @Environment(\.demoRedaction) private var demoRedaction
    let event: RiskEvent
    var isSelected: Bool = false
    var action: (() -> Void)?

    private var language: AppLanguage { UILanguage.current }
    var body: some View {
        Button {
            action?()
        } label: {
            HStack(spacing: Spacing.sm) {
                // 等级名**无条件**显示，且这一处是本行唯一的等级通道。
                // `ObservatoryTheme.tone(for:)` 让 medium 与 high 共用橙色（ADR-0008 §2），
                // 所以任何「等级 ≥ 某档才画文字」的条件都会让这两级在列表里长得一样。
                // 回归用例：`Tests/AIObservatoryUITests/RiskLevelDistinguishabilityTests.swift`
                // 钉的是令牌层（同色必须异名），视图层没有测试宿主——改这一行要人工复核。
                RiskBadge(event.level)
                Text(demoRedaction.scrub(event.title))
                    .font(.axBody)
                    .foregroundStyle(event.isAcknowledged ? Surface.tertiaryLabel : Surface.label)
                    .lineLimit(1)
                Spacer(minLength: Spacing.sm)
                trailingMeta
            }
            .padding(.vertical, Spacing.xs)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        // #11：原来是 `.plain`（只有按下有反馈，悬停没有、光标不变手型）。
        // 现在与首页那格带 action 的 `StatTile`、其余三张列表行共用同一份反馈档。
        .buttonStyle(.axPressable)
        // 选中底用系统语义色 `Surface.selectedRow`（非强调选中），不写 accentColor.opacity：
        // 自己调一个 14% 的强调色底，深浅两套下观感完全不同，而且它不携带任何信息。
        .background(
            isSelected ? Surface.selectedRow : Color.clear,
            in: RoundedRectangle(cornerRadius: ObservatoryRadius.control, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityLabel(accessibilityText)
    }

    /// 行尾元信息：Agent 身份（图标 + 名字，不上色）、待确认提示、时间。
    ///
    /// 【#83】Agent 与时间两格定宽（`Column`），改前只有外层 `Spacer` 推右 ⇒
    /// 标题一长，这两格就整列跟着挪，二十行读下来右侧是一条折线。
    private var trailingMeta: some View {
        HStack(spacing: Spacing.sm) {
            if event.requiresConfirmation && !event.isAcknowledged {
                // 「需要人工点一下」会改变读者下一步动作，所以占一个图标；
                // 「已确认」不占图标，它走行尾那个文字标记（见下）。
                Image(systemName: "questionmark.circle")
                    .font(.axMeta)
                    .foregroundStyle(ObservatoryColor.caution)
                    .help(SecurityCopy.awaitingHelp.text(language))
            }
            // 「已确认」必须有文字通道。只把标题降到 tertiary 灰 = 又造一个
            // 「只有颜色能分辨」的状态，与基座在 b364ceb 修掉的是同一类毛病。
            if event.isAcknowledged {
                Text(SecurityCopy.acknowledged.text(language))
                    .font(.axMeta)
                    .foregroundStyle(Surface.tertiaryLabel)
            }
            AgentChip(kind: event.agentKind, compact: true)
                .axLeadingColumn(Column.agentIdentity)
            Text(DateFormat.time(event.timestamp))
                .font(.axMetaMono)
                .axNumberColumn(Column.time)
                .foregroundStyle(Surface.tertiaryLabel)
        }
    }

    private var accessibilityText: String {
        "\(event.level.displayName)，\(event.category.displayName)，\(event.title)"
            + (event.isAcknowledged ? SecurityCopy.ackSuffix.text(language) : "")
    }
}

#Preview("RiskEventRow 三态") {
    VStack(spacing: Spacing.none) {
        RiskEventRow(event: previewEvent(.critical, acknowledged: false))
        Hairline()
        RiskEventRow(event: previewEvent(.high, acknowledged: false), isSelected: true)
        Hairline()
        RiskEventRow(event: previewEvent(.low, acknowledged: true))
        Hairline()
    }
    .padding(Spacing.lg)
    .background(Surface.panel)
}

/// 只给上面那个 `#Preview` 喂假数据（同 `ProjectCardPreviewSamples` 那一族）。
/// 标识符里带 Preview 是有意的：双语门禁按括号配对跳过预览脚手架，而样例值不进产物。
private func previewEvent(_ level: RiskLevel, acknowledged: Bool) -> RiskEvent {
    RiskEvent(
        timestamp: Date(timeIntervalSince1970: 1_800_000_000),
        level: level,
        category: .dangerousCommand,
        title: "递归强制删除工作区内文件",
        detail: "rm -rf 指向仓库根目录",
        agentKind: .openAICodex,
        command: "rm -rf /Users/demo/Projects/AiX",
        requiresConfirmation: level >= .high,
        isAcknowledged: acknowledged
    )
}
