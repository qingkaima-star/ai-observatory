//
//  CommandAuditRow.swift
//  Commands
//
//  Owner: WS-UI（由 CommandsView.swift 原样搬来：只按职责分文件，行为未变。）
//

import SwiftUI
import Observation
import AIObservatoryCore
// MARK: - 列表行

/// 一条被审计的命令，**单行**：命令行（等宽、middle 截断）+ 尾部元信息。
///
/// 旧版是「8pt 状态点 + 最多两行命令行 + 一整排元信息」= 两行拥挤，
/// 而且同一条「结果」既用圆点又用文字说了两遍。现在状态点删除，
/// 结果的判定改由 `exit N` 文字本身携带 `ObservatoryTheme.color(for: outcome)` 承担。
@MainActor struct CommandAuditRow: View {

    let record: CommandRecord
    /// #89：命令行是这一页的主内容，而它的原文里就是绝对路径。屏上、tooltip、读屏三处
    /// 用同一把尺：掩的是**拼好的那一条**，不是逐字段（逐字段会漏掉摘要句里的那一份）。
    @Environment(\.demoRedaction) private var demoRedaction
    var isSelected: Bool = false
    var action: (() -> Void)?

    init(record: CommandRecord, isSelected: Bool = false, action: (() -> Void)? = nil) {
        self.record = record
        self.isSelected = isSelected
        self.action = action
    }

    var body: some View {
        VStack(spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(demoRedaction.scrub(record.commandLine))
                    .font(.axMono)
                    .foregroundStyle(Surface.label)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(demoRedaction.scrub(record.commandLine))

                Spacer(minLength: Spacing.sm)

                CommandAuditRowMeta(record: record)
            }
            .frame(minHeight: Sizing.rowMinHeight)

            Hairline()
        }
        .padding(.vertical, Spacing.xs)
        // 选中只换底色，不描边、不加彩色填充（旧版 accentColor.opacity(0.14) + strokeBorder）。
        .background(isSelected ? Surface.selectedRow : Color.clear)
        .contentShape(Rectangle())
        // #11：整块可点走共用处理（原来是 `.onTapGesture`，Tab 走不到那一族）。
        .axPressable(when: action)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(demoRedaction.scrub(CommandAuditFormat.summary(of: record)))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// 行尾元信息：标记 / 退出码 / 耗时 / Agent。
/// 抽成独立 `struct` 是为了压住类型检查时间，同时避免行内出现第二种状态表达。
///
/// **这里没有时间列**：命令行才是本页读者要认的东西，而尾部元信息是 `.fixedSize()`
/// 的——多一列就把命令行压到只剩二十几个字符（真机截图实测 `swift build…isable-sandbox`
/// 这种读不出来的样子）。时刻在详情面板的头部与「开始时间」字段里都还在。
///
/// 【#83】这四格里原先有**三格没有定宽**（退出码 / 耗时 / Agent），只靠外层 `Spacer`
/// 推右 ⇒ 每行尾部的长度由内容决定，同一列在行间是锯齿状的。现在宽度一律取 `Column`
/// （这一族的宽度常量不能放进 `CommandAuditFormat`——那个 enum 在 `CommandsModel.swift`
/// 里，Model 文件不是本页道的面）。
@MainActor struct CommandAuditRowMeta: View {

    let record: CommandRecord

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        HStack(spacing: Spacing.sm) {
            marker

            // 退出结果：颜色只认 outcome 这一处判定，没采到码就是中性，绝不假绿。
            Text(CommandAuditFormat.exitText(of: record))
                .font(.axMeta)
                .contentTransition(.numericText())
                .axNumberColumn(Column.exitCode)
                .foregroundStyle(ObservatoryTheme.color(for: record.outcome))
                .help(CommandAuditFormat.exitText(of: record))

            Text(CommandAuditFormat.durationText(of: record))
                .font(.axMeta)
                .axNumberColumn(Column.duration)
                .foregroundStyle(Surface.tertiaryLabel)
                .help(CommandsCopy.rowDurationHelp.text(language))

            AgentChip(kind: record.agentKind, compact: true)
                .axLeadingColumn(Column.agentIdentity)
        }
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityElement(children: .combine)
    }

    /// 至多一个标记，按「最需要看见」排序：破坏性 > 需确认 > 风险等级。
    /// 三者都不成立时什么都不画——旧版每条命令挂三个胶囊是噪声。
    @ViewBuilder private var marker: some View {
        if record.isDestructive {
            Tag(CommandsCopy.tagDestructive.text(language), tone: .critical)
        } else if record.requiresConfirmation {
            Tag(CommandsCopy.tagRequiresConfirmation.text(language), tone: .caution)
        } else if record.riskLevel > .low {
            RiskBadge(record.riskLevel, prominent: record.riskLevel >= .high)
        }
    }
}
