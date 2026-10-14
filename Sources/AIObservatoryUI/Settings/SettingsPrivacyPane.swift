//
//  SettingsPrivacyPane.swift
//  AIObservatoryUI / Settings
//
//  Owner: WS-QUIET-1（子代理 C）
//  ─────────────────────────────────────────────────────────
//  隐私与安全分段：风险确认开关、diff 明文开关（#15：关掉后引擎不再把逐行正文写库）、
//  Endpoint Security 开关（附真实授权门槛说明）+ 采集保真度读数、本地保留期、本机数据边界声明。
//  保留期用整数 Stepper（区间来自 SettingsModel.retentionRange，界面不各写魔法边界）。
//
//  排版：五组 `SettingsGroup`，组内行之间 `Hairline()`，容器是**非懒** `VStack`
//  （数量有界；且组里有 `.segmented` / `.stepper` 真控件，懒容器是本仓实测过的死法）。
//
//  分组顺序按**数据生命周期**：采不采（风险确认打断与否）→ 采多细（diff 正文）
//  → 用什么精度采（Endpoint Security + 实时捕获能力）→ 留多久（保留期）→ 落在哪（数据边界）。
//  旧版把「留多久」插在「采多细」和「精度」之间，读下来要先跳一次话题。
//
//  本页的实话密度最高，一句都不许因为「排版清爽」而被删：
//  三条 caveat（ES 未接入 / 菜单栏需重启 / 保留期只管以后写什么）都以 `SettingsRow`
//  的 caveat 位上屏，用 primary 色 11pt，比说明更重而不是更花。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor
struct SettingsPrivacyPane: View {

    @Bindable private var model: SettingsModel

    init(model: SettingsModel) {
        self._model = Bindable(model)
    }

    private var language: AppLanguage { UILanguage.current }
    /// #64：这一页把**库文件位置**与**敏感前缀清单**都摆在屏上，两者都是真实绝对路径。
    @Environment(\.demoRedaction) private var demoRedaction

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            if model.observedProjectCount == 0, !model.isLoading, model.errorMessage == nil {
                SettingsHintLine(text: SettingsCopy.noEventsYet.text(language))
            }

            riskConfirmationGroup
            notificationGroup
            diffPlaintextGroup
            demoGroup
            endpointSecurityGroup
            retentionGroup
            localOnlyGroup
        }
    }

    // MARK: - 风险确认

    private var riskConfirmationGroup: some View {
        SettingsGroup(SettingsCopy.riskGroup.text(language), subtitle: SettingsCopy.riskGroupSubtitle.text(language)) {
            SettingsToggleRow(
                title: SettingsCopy.riskToggleTitle.text(language),
                detail: SettingsCopy.riskToggleDetail.text(language),
                isOn: model.binding(\.enableRiskConfirmation)
            )

            Hairline()

            HStack(spacing: Spacing.sm) {
                ForEach(RiskLevel.allCases) { level in
                    RiskBadge(level, prominent: level >= .high)
                }
                Spacer(minLength: Spacing.sm)
                Text(model.draft.enableRiskConfirmation ? SettingsCopy.riskStateInterrupts.text(language)
                        : SettingsCopy.riskStateRecordsOnly.text(language))
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .fixedSize()
            }
            .frame(minHeight: Sizing.rowMinHeight)
        }
    }

    // MARK: - 高危实时通知（#59）

    /// 开关的真消费者在 App 侧订阅引导里（`RiskNotificationBootstrap` 每次投递前读
    /// `runtime.settings.notifyHighRisk` 喂进 `RiskNotificationCoordinator.isEnabled`）。
    /// ⚠️ 本行**不做**「未授权」实时徽标：授权态要从 `UNUserNotificationCenter` 回传到设置模型，
    /// 是一条独立的 App→UI 接缝（见 ICR-0011 落地记录），此处文案先如实写明"未授权时一律不发"。
    private var notificationGroup: some View {
        SettingsGroup(SettingsCopy.notifyGroup.text(language), subtitle: SettingsCopy.notifyGroupSubtitle.text(language)) {
            SettingsToggleRow(
                title: SettingsCopy.notifyToggleTitle.text(language),
                detail: SettingsCopy.notifyToggleDetail.text(language),
                isOn: model.binding(\.notifyHighRisk)
            )

            Hairline()

            Text(SettingsCopy.notifyRestartNote.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, Spacing.xs)
        }
    }

    // MARK: - Diff 明文

    /// 隐私 §7 要求「diff 所需的最小片段且需可关闭」。这个开关确实被引擎读取
    /// （`ObservatoryEngine.makeFileChange` 每条事件都查一次），不是摆在面板上的装饰。
    private var diffPlaintextGroup: some View {
        SettingsGroup(SettingsCopy.diffGroup.text(language), subtitle: SettingsCopy.diffGroupSubtitle.text(language)) {
            SettingsToggleRow(
                title: SettingsCopy.diffToggleTitle.text(language),
                detail: SettingsCopy.diffToggleDetail.text(language),
                isOn: model.binding(\.storeDiffPlaintext)
            )
            Text(SettingsCopy.diffNotRetroactive.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.label)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - 演示输出

    /// #61 的开关。**有真消费者**：`ObservatoryRootView` 用它造
    /// `PathPrivacy.Mask` 注进环境，`FilePathText` 那一咽喉读它。
    /// 生效时机如实写在 caveat 里（启动时读 ⇒ 重启生效），不写成即时。
    private var demoGroup: some View {
        SettingsGroup(SettingsCopy.demoGroup.text(language),
                      subtitle: SettingsCopy.demoGroupSubtitle.text(language)) {
            SettingsToggleRow(
                title: SettingsCopy.demoToggleTitle.text(language),
                detail: SettingsCopy.demoToggleDetail.text(language),
                isOn: model.binding(\.demoRedactedOutput),
                caveat: SettingsCopy.demoToggleCaveat.text(language)
            )
            // #64 ③：两态都要说出口。关掉时这一行是**警告**而不是留白——
            // "屏上没看见路径"和"没泄漏路径"是两件事，静默就是替后者背书。
            Text(model.draft.demoRedactedOutput
                    ? SettingsCopy.demoToggleOnNotice.text(language)
                    : SettingsCopy.demoToggleOffNotice.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Endpoint Security 与采集保真度

    private var endpointSecurityGroup: some View {
        SettingsGroup(
            "Endpoint Security",
            subtitle: SettingsCopy.esGroupSubtitle.text(language)) {
            SettingsToggleRow(
                title: SettingsCopy.esToggleTitle.text(language),
                detail: SettingsCopy.esToggleDetail.text(language),
                isOn: model.binding(\.enableEndpointSecurity),
                caveat: SettingsCopy.esCaveat.text(language)
            )

            Hairline()

            // 采集保真度读数（ADR-0006 #6）。为什么放在这一组里：
            // 上面那个开关讲的是「能不能拿到更高的保真度」，这里讲的是「现在实际是什么保真度」；
            // 分开放会让用户以为两者是同一件事。文案取自 RealtimeCapability.fidelityNote，
            // 界面不另写一份 switch。
            InlineStat(SettingsCopy.realtimeCapabilityLabel.text(language), value: model.realtimeCapabilityText(language))
            Text(model.realtimeCapabilityNote(language))
                .font(.axMeta)
                .foregroundStyle(Surface.label)
                .fixedSize(horizontal: false, vertical: true)

            Hairline()

            Text(SettingsCopy.sensitivePrefixNote.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            MonospacedCodeView(
                // #64：这份清单是**展开过的真实前缀**（`PathHeuristics` 里带家目录的那些），
                // 而 `MonospacedCodeView` 还带一个复制按钮 ⇒ 和剪贴板那条同一个严重度。
                demoRedaction.scrub(PathHeuristics.sensitivePrefixes.prefix(6).joined(separator: "\n")),
                maxLines: 6,
                showsCopyButton: false
            )
        }
    }

    // MARK: - 保留期

    private var retentionGroup: some View {
        SettingsGroup(SettingsCopy.retentionGroup.text(language), subtitle: SettingsCopy.retentionGroupSubtitle.text(language)) {
            SettingsRow(
                SettingsCopy.retentionDays.text(language),
                detail: SettingsCopy.retentionStepDetail.format(
                    language, SettingsModel.retentionRange.lowerBound, SettingsModel.retentionRange.upperBound)
            ) {
                HStack(spacing: Spacing.sm) {
                    Text(model.retentionText(language))
                        .font(.axMetric)
                        .monospacedDigit()
                        .foregroundStyle(Surface.label)
                        .contentTransition(.numericText())
                        .animation(ObservatoryMotion.value, value: model.draft.retentionDays)
                    Stepper(value: model.retentionDaysBinding,
                            in: SettingsModel.retentionRange,
                            step: 1) {
                        Text(SettingsCopy.retentionDays.text(language))
                    }
                    .labelsHidden()
                    .fixedSize()
                }
            }

            Hairline()

            InlineStat(
                SettingsCopy.currentDraft.text(language),
                value: model.draft.retentionDays == model.appliedSettings.retentionDays
                    ? SettingsCopy.draftMatchesLive.text(language)
                    : SettingsCopy.draftChangedUnapplied.text(language))
        }
    }

    // MARK: - 本机数据声明

    private var localOnlyGroup: some View {
        SettingsGroup(SettingsCopy.dataBoundaryGroup.text(language)) {
            Text(SettingsCopy.localOnlyStatement.text(language))
                .font(.axBody)
                .foregroundStyle(Surface.label)
            Text(SettingsCopy.storePathsStatement.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            Hairline()

            InlineStat(SettingsCopy.storeDirectoryLabel.text(language), value: demoRedaction.scrub(model.storeDirectoryText(language)))
        }
    }
}

// MARK: - Previews

#Preview("设置 · 隐私与安全") {
    ObservatoryPreview.screen { runtime in
        SettingsPrivacyPane(model: SettingsModel(runtime: SettingsPreviewSamples.runtime(runtime)))
    }
}

#Preview("设置 · 隐私与安全（空）") {
    ObservatoryPreview.screen(empty: true) { runtime in
        SettingsPrivacyPane(model: SettingsModel(runtime: runtime))
    }
}
