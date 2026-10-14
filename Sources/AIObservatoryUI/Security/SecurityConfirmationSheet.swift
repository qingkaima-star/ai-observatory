//
//  SecurityConfirmationSheet.swift
//  AIObservatoryUI / Security
//
//  Owner: WS-UI → WS-QUIET-3（本轮按 ADR-0007 重排到「quiet」语言）
//  职责：requiresConfirmation 事件的模态确认卡 —— 必须人工点击才会调用
//        runtime.controller.acknowledgeRiskEvent(id:)（经 SecurityModel.acknowledge）。
//
//  这一层是**真正浮起的层**：系统给它的底与高度就是它该有的样子，
//  所以我们只摆内容，**不自己加 `.shadow`**（三条禁令之一：
//  投影只属于 sheet / menu / popover 这类浮层，而那是系统画的）。
//
//  旧版卡头那个 28pt、按等级染色的类别 SF 图标已删：
//  等级就在旁边 `RiskBadge` 上写着，图标不携带任何读者能解码的信息，
//  只把一张确认卡染成红/橙——那正是「东一个西一个」。
//

import SwiftUI
import AIObservatoryCore

/// 风险确认模态卡。
@MainActor
struct SecurityConfirmationSheet: View {

    /// #64：确认弹窗里的依据句 `event.detail` 就是那条被命中的绝对路径。
    @Environment(\.demoRedaction) private var demoRedaction
    @Bindable private var model: SecurityModel
    let event: RiskEvent

    init(model: SecurityModel, event: RiskEvent) {
        _model = Bindable(model)
        self.event = event
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.lg) {
            header
            Panel {
                VStack(alignment: .leading, spacing: Spacing.sm) {
                    Text(SecurityCopy.rationaleTitle.text())
                        .font(.axSection)
                        .foregroundStyle(Surface.label)
                    Text(SecurityCopy.rationale(demoRedaction.scrub(event.detail)))
                        .font(.axBody)
                        .foregroundStyle(Surface.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    if let command = event.command, !command.isEmpty {
                        Hairline()
                        MonospacedCodeView(command, maxLines: 4)
                    }
                    if !event.filePaths.isEmpty {
                        Hairline()
                        VStack(alignment: .leading, spacing: Spacing.xs) {
                            ForEach(event.filePaths.prefix(5), id: \.self) { path in
                                HStack(spacing: Spacing.xs) {
                                    Image(systemName: PathHeuristics.isSensitive(path) ? "lock.open" : "doc.text")
                                        .font(.axMeta)
                                        .foregroundStyle(
                                            PathHeuristics.isSensitive(path)
                                                ? ObservatoryColor.critical
                                                : Surface.tertiaryLabel)
                                    FilePathText(path: path)
                                }
                            }
                            if event.filePaths.count > 5 {
                                Text(SecurityCopy.morePaths.format(.resolved(), String(event.filePaths.count - 5)))
                                    .axCaptionStyle()   // #99：这句承载口径，曾在最低档（≈1.8:1）
                            }
                        }
                    }
                }
            }
            meta
            actions
        }
        .padding(Spacing.lg)
        .frame(width: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                RiskBadge(event.level, prominent: true)
                Text(event.category.displayName)
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                Spacer(minLength: Spacing.none)
            }
            Text(demoRedaction.scrub(event.title))
                .font(.axSection)
                .foregroundStyle(Surface.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var meta: some View {
        VStack(spacing: Spacing.xs) {
            InlineStat(AgentNaming.fieldLabel.text(),
                       value: AgentNaming.name(kind: event.agentKind, form: .full))
            // 确认面板是用户**按下「我已确认」之前**最后读的那一屏：
            // 如果这一条归不到任何 Agent，那句话必须在这里就能读到，
            // 而不是等他再去详情面板找（#47-B 判据②）。
            AttributionReasonNote(kind: event.agentKind)
            InlineStat(SecurityCopy.timeLabel.text(), value: DateFormat.timestamp(event.timestamp))
            if let ruleID = event.matchedRuleID {
                InlineStat(SecurityCopy.matchedRuleTitle.text(), value: ruleID)
            }
        }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: Spacing.sm) {
            Text(SecurityCopy.acknowledgeNote.text())
                .fixedSize(horizontal: false, vertical: true)
                .axCaptionStyle()
            // #77：这张卡**自己**的失败提示。它是模态层，盖在页面上方，
            // 所以页面那一档的横幅修好了也不等于这里看得见 —— 必须就地显示一句。
            // 句子不在这儿拼：`SecurityModel.acknowledge` 已经把
            // `SecurityCopy.ackSaveFailed`（「确认没有保存：底层原因」）写进 `errorMessage`，
            // 这里只读那一个出处；`errorOrigin == .acknowledgement` 是「这一张卡的
            // 上一次确认被 store 拒了」的充分条件（换一张卡时 `confirmationTarget` 的
            // `didSet` 会把它清掉，见 `SecurityModel`）。
            if model.errorOrigin == .acknowledgement, let message = model.errorMessage {
                SecurityErrorNotice(title: message)
            }
            HStack(spacing: Spacing.sm) {
                Button {
                    Task { @MainActor in
                        // ⚠️ 这个返回值就是全部区别。旧写法是
                        // `Task { await model.acknowledge(event:) }` —— 返回的 `false`
                        // 被就地丢弃，于是「没落库」与「落库成功」在这张卡上长得一模一样。
                        // 现在它决定界面状态：
                        //   成功 ⇒ `acknowledge` 收掉 `confirmationTarget`，卡随之消失；
                        //   失败 ⇒ 卡**必须**留在屏幕上并显示原因。这里显式钉住它，
                        //          而不是依赖"恰好没人清空"——同一轮里能清掉它的路有两条
                        //          （`presentNextConfirmation(after:)` 与实时增量 ingest）。
                        //          同一个 id 的回钉不会撤掉提示（见 `didSet` 的 id 比较）。
                        let saved = await model.acknowledge(event: event)
                        if saved == false, model.confirmationTarget?.id != event.id {
                            model.confirmationTarget = event
                        }
                    }
                } label: {
                    Text(SecurityCopy.acknowledgeButton.text())
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)

                Button(SecurityCopy.laterButton.text()) {
                    model.presentNextConfirmation(after: event)
                }
                .buttonStyle(.bordered)

                Button(SecurityCopy.ignoreKindButton.text()) {
                    model.confirmationTarget = nil
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Surface.secondaryLabel)
            }
        }
    }
}

#Preview("风险确认卡") {
    SecurityConfirmationSheet(
        model: SecurityModel(runtime: ObservatoryPreview.runtime()),
        event: RiskEvent(
            timestamp: Date(timeIntervalSince1970: 1_800_000_000),
            level: .critical,
            category: .massDeletion,
            title: "批量删除工作区文件",
            detail: "一次操作删除 14 个受观测文件，命中批量删除规则。",
            agentKind: .openAICodex,
            command: "git clean -fdx",
            filePaths: ["/Users/demo/Projects/AiX/a.ts", "/Users/demo/Projects/AiX/b.ts"],
            requiresConfirmation: true,
            matchedRuleID: "R-MASSDEL-01"
        )
    )
    .padding(Spacing.xl)
}
