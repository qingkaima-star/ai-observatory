//
//  SettingsGeneralPane.swift
//  AIObservatoryUI / Settings
//
//  Owner: WS-QUIET-1（子代理 C）
//  ─────────────────────────────────────────────────────────
//  通用分段：外观（AppTheme → 真实 preferredColorScheme）、菜单栏 Extra、开机自启、引擎状态与启停。
//  所有写路径统一走 model.binding(...) → SettingsModel.update(_:)，不直接改 draft。
//
//  排版：三组 `SettingsGroup`（白底面板 + 小节标题 + 左标签右控件的行），
//  组内 8pt、组间 32pt（`Spacing.section`），组内行之间 `Hairline()`。
//  容器是**非懒** `VStack`：这里只有三组、十几行，数量天然有界，而卡里的
//  `Picker` 是 `.segmented` / `.menu` 一类控件——本仓实测过「懒容器里放 `.menu` 控件」
//  会滚动自旋、RSS 只涨不落，所以这一页一律不懒。
//
//  分组顺序按「生效代价」从低到高：外观（本窗口即时）→ 菜单栏与登录（要重启 / 未接入）
//  → 观测引擎（运行时动作）。原先那条「常驻说明 + 当前生效」的重复自述已上移到页面级
//  `SettingsView.sessionPanel`，这里不再抄第二遍。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor
struct SettingsGeneralPane: View {

    @Bindable private var model: SettingsModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    private var language: AppLanguage { UILanguage.current }

    init(model: SettingsModel) {
        self._model = Bindable(model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            if model.observedProjectCount == 0, !model.isLoading, model.errorMessage == nil {
                SettingsHintLine(text: SettingsCopy.noProjectsHint.text())
            }

            appearanceGroup
            menuBarGroup
            engineGroup
        }
    }

    // MARK: - 外观

    private var appearanceGroup: some View {
        SettingsGroup(
            SettingsCopy.appearanceGroup.text(),
            subtitle: SettingsCopy.appearanceSubtitle.text()) {
            SettingsRow(SettingsCopy.themeRow.text()) {
                Picker(SettingsCopy.themeRow.text(), selection: model.binding(\.theme)) {
                    ForEach(AppTheme.allCases) { theme in
                        Text(theme.displayName).tag(theme)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
            InlineStat(
                SettingsCopy.themeAppliesRow.text(),
                // 「（nil）」是实现侧的说法（不往宿主传 colorScheme override），
                // 直接印给用户只会让人以为设置读到了空值。
                value: model.draft.theme == .system
                    ? SettingsCopy.themeFollowsSystem.text()
                    : SettingsCopy.themeForced.format(.resolved(), model.draft.theme.displayName)
                // ⚠️ 英文下这一格会写成 "Forced 深色"：值来自 §3 冻结区的
                // `AppTheme.displayName`（DomainModels.swift:1133），本车道无权迁。已请拍。
            )
        }
    }

    // MARK: - 菜单栏与登录

    private var menuBarGroup: some View {
        SettingsGroup(SettingsCopy.menuBarGroup.text(), subtitle: SettingsCopy.menuBarGroupSubtitle.text()) {
            SettingsToggleRow(
                title: SettingsCopy.menuBarToggleTitle.text(),
                detail: SettingsCopy.menuBarToggleDetail.text(),
                isOn: model.binding(\.enableMenuBarExtra),
                caveat: SettingsCopy.menuBarToggleCaveat.text()
            )

            // 明确把「本进程真正声明了什么」和「草稿是什么」分开写：
            // 只有一个 Toggle 时，用户拨完只会以为已经生效（ADR-0006 #14 的原始症状）。
            InlineStat(SettingsCopy.menuBarThisLaunch.text(), value: model.menuBarDeclaredAtLaunchText(language))

            Hairline()

            SettingsToggleRow(
                title: SettingsCopy.launchAtLoginTitle.text(),
                detail: SettingsModel.launchAtLoginDetail(language),
                isOn: model.binding(\.launchAtLogin),
                caveat: SettingsCopy.launchAtLoginCaveat.text()
            )
        }
    }

    // MARK: - 引擎

    private var engineGroup: some View {
        SettingsGroup(
            SettingsCopy.engineGroup.text(),
            subtitle: SettingsCopy.engineGroupSubtitle.text()) {
            // 只留一条节奏读数。原先这里是两个并排的旋钮
            // （「性能采样」+「进程扫描」），而引擎唯一那条循环只读后者 ——
            // 前者是个没有生产者的字段，摆在真旋钮旁边会让用户以为采集有两档可调。
            InlineStat(SettingsCopy.samplingCadence.text(), value: model.processScanIntervalText(language))

            Hairline()

            HStack(spacing: Spacing.sm) {
                Button {
                    toggleEngine()
                } label: {
                    Label(
                        model.isEngineRunning ? SettingsCopy.stopEngine.text() : SettingsCopy.startEngine.text(),
                        systemImage: model.isEngineRunning ? "stop.circle.fill" : "play.circle.fill"
                    )
                }
                .controlSize(.small)

                Button {
                    rescan()
                } label: {
                    Label(SettingsCopy.rescan.text(), systemImage: "arrow.triangle.2.circlepath")
                }
                .controlSize(.small)

                Spacer(minLength: Spacing.sm)

                Text(model.isEngineRunning ? SettingsCopy.engineRunningHint.text() : SettingsCopy.engineStoppedHint.text())
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .fixedSize()
            }
            .frame(minHeight: Sizing.rowMinHeight)
        } trailing: {
            engineStateReadout
        }
    }

    /// 引擎状态：色点来自 `ObservatoryTheme.color(for:)`（功能色），文字 11pt。
    private var engineStateReadout: some View {
        HStack(spacing: Spacing.xs) {
            Circle()
                .fill(ObservatoryTheme.color(for: model.engineState))
                .frame(width: 5, height: 5)
                .accessibilityHidden(true)
            Text(model.engineStateName)
                .font(.axMeta)
                .foregroundStyle(Surface.label)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SettingsCopy.engineStatePrefix.format(.resolved(), model.engineStateName))
    }

    // MARK: - 行为

    private func toggleEngine() {
        Task {
            if let shell {
                await shell.toggleEngine()
            } else {
                await model.toggleEngine()
            }
        }
    }

    private func rescan() {
        Task {
            if let shell {
                await shell.rescan()
            } else {
                await model.rescan()
            }
        }
    }
}

// MARK: - Previews

#Preview("设置 · 通用") {
    ObservatoryPreview.screen { runtime in
        SettingsGeneralPane(model: SettingsModel(runtime: SettingsPreviewSamples.runtime(runtime)))
    }
}

#Preview("设置 · 通用（空）") {
    ObservatoryPreview.screen(empty: true) { runtime in
        SettingsGeneralPane(model: SettingsModel(runtime: runtime))
    }
}
