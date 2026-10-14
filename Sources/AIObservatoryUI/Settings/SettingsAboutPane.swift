//
//  SettingsAboutPane.swift
//  AIObservatoryUI / Settings
//
//  Owner: WS-QUIET-1（子代理 C）
//  ─────────────────────────────────────────────────────────
//  关于分段：身份与版本占位、隐私声明、引擎当前按什么在跑、契约层格式化工具的真实小样例、
//  草稿快照与署名。
//  版本走 Bundle.main 读取 + 明确标注占位（SwiftPM 环境下 Bundle 不含 App 信息）。
//
//  排版：六组 `SettingsGroup`，组内 `Hairline()`，容器**非懒** `VStack`。
//  旧版这里有一个 40pt 的 `binoculars.fill` 装饰大图标 + `.title3` 应用名——
//  那是本页唯一的「假主次」：图标不携带信息，字号却和真正的读数抢位。两处都删掉，
//  应用名交给 `SectionHeader`（13pt 半粗，与别的分组同一档），版本交给 `InlineStat`。
//  这一页没有、也不该有 `.hero`。
//
//  分组顺序：先「这是什么版本」→「数据的边界在哪」→「引擎现在按什么在跑」
//  →「这一页改的东西长什么样（草稿快照）」→「契约格式化工具的真输出」（纯参考件，压到最后）
//  → 署名。旧版把格式化样例插在引擎与草稿之间，读下来在「事实」与「参考」之间跳了一次。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor
struct SettingsAboutPane: View {

    @Bindable private var model: SettingsModel

    init(model: SettingsModel) {
        self._model = Bindable(model)
    }

    /// 示例时间戳，用于展示契约格式化工具的真实输出。
    private static let sampleDate = Date(timeIntervalSince1970: 1_700_000_000)
    private static let sampleSeconds: TimeInterval = 9_125

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            if model.observedProjectCount == 0, !model.isLoading, model.errorMessage == nil {
                SettingsHintLine(text: SettingsCopy.aboutEmptyHint.text(language))
            }

            identityGroup
            privacyGroup
            engineGroup
            draftSnapshotGroup
            formattingGroup
            creditGroup
        }
    }

    // MARK: - 身份

    private var identityGroup: some View {
        SettingsGroup("AiX", subtitle: SettingsCopy.aboutIdentitySubtitle.text(language)) {
            InlineStat(SettingsCopy.aboutVersionRow.text(language), value: versionText)
            Hairline()
            InlineStat(SettingsCopy.aboutHostRow.text(language),
                       value: SettingsCopy.aboutHostValue.text(language))
            Hairline()
            InlineStat(SettingsCopy.aboutScopeRow.text(language),
                       value: SettingsCopy.aboutScopeValue.format(language,
                                                                  model.draft.monitoredRoots.count,
                                                                  model.observedProjectCount))
        }
    }

    private var versionText: String {
        let placeholder = SettingsCopy.aboutVersionPlaceholder.text(language)
        let short = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? placeholder
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? placeholder
        return SettingsCopy.aboutVersionValue.format(language, short, build)
    }

    // MARK: - 隐私声明

    private var privacyGroup: some View {
        SettingsGroup(SettingsCopy.aboutPrivacyGroup.text(language)) {
            Text(SettingsCopy.localOnlyStatement.text(language))
                .font(.axBody)
                .foregroundStyle(Surface.label)
            Text(SettingsCopy.aboutNoTelemetryStatement.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
            Hairline()
            InlineStat(SettingsCopy.aboutRetentionRow.text(language), value: model.retentionText(language))
        }
    }

    // MARK: - 引擎与设置的口径

    private var engineGroup: some View {
        SettingsGroup(SettingsCopy.aboutEngineGroup.text(language),
                      subtitle: SettingsCopy.aboutEngineGroupSubtitle.text(language)) {
            // 「性能采样」那一档已删：它对应的设置字段没有任何引擎侧生产者，
            // 与「进程扫描」并排会让用户以为采集有两档可调（见 GeneralPane 同处注释）。
            InlineStat(SettingsCopy.samplingCadence.text(language), value: model.processScanIntervalText(language))
            Hairline()
            InlineStat(SettingsCopy.themeRow.text(language), value: model.themeName)
            Hairline()
            InlineStat("Endpoint Security",
                       value: model.draft.enableEndpointSecurity
                           ? SettingsCopy.aboutESDraftOn.text(language)
                           : SettingsCopy.aboutOff.text(language))
            Hairline()
            // 这一行与上面三行**不是同一个口径**：`menuBarAboutText` 读的是启动声明，
            // 草稿与声明不一致时它自己会补「（草稿待重启）」。放在组内最后一行 + 标题行写清口径，
            // 免得这一页看起来像「四行都在报现状」。
            InlineStat(SettingsCopy.aboutMenuBarRow.text(language), value: model.menuBarAboutText(language))
        }
    }

    // MARK: - 草稿快照

    private var draftSnapshotGroup: some View {
        SettingsGroup(
            SettingsCopy.aboutDraftSnapshotGroup.text(language),
            subtitle: model.hasPendingChanges
                ? SettingsCopy.aboutPendingUnapplied.format(language, model.pendingChangeCount)
                : SettingsCopy.draftMatchesLive.text(language)) {
            MonospacedCodeView(draftDump, maxLines: 12, showsCopyButton: true)

            Text(SettingsModel.persistenceNotice(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            Text(model.isSessionModified
                     ? SettingsCopy.aboutAppliedThisSession.text(language)
                     : SettingsCopy.aboutBaselineRuntimeSettings.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
        }
    }

    /// 用契约的 Codable 把草稿序列化出来，UI 不手搓字段列表。
    private var draftDump: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(model.draft),
              let text = String(data: data, encoding: .utf8) else {
            return SettingsCopy.aboutDraftEncodeFailed.text(language)
        }
        return text
    }

    // MARK: - 格式化样例

    private var formattingGroup: some View {
        SettingsGroup(SettingsCopy.aboutFormattingGroup.text(language),
                      subtitle: SettingsCopy.aboutFormattingGroupSubtitle.text(language)) {
            ForEach(Array(formatSamples.enumerated()), id: \.offset) { index, sample in
                if index > 0 {
                    Hairline()
                }
                SettingsSampleRow(label: sample.label, value: sample.value)
            }
        }
    }

    /// 样例数组在 body 之外算一次：`@ViewBuilder` 里不留构造工作。
    private var formatSamples: [(label: String, value: String)] {
        [
            ("DateFormat.day", DateFormat.day(Self.sampleDate)),
            ("DateFormat.timestamp", DateFormat.timestamp(Self.sampleDate)),
            ("DurationFormat.humanReadable(9125)", DurationFormat.humanReadable(Self.sampleSeconds)),
            ("DurationFormat.compact(9125)", DurationFormat.compact(Self.sampleSeconds)),
            ("PercentFormat.short(18.42, 1)", PercentFormat.short(18.42, fractionDigits: 1)),
            ("ByteFormat.humanReadable(3.2GB)", ByteFormat.humanReadable(UInt64(3_435_973_836))),
        ]
    }

    // MARK: - 署名

    private var creditGroup: some View {
        SettingsGroup(SettingsCopy.aboutCreditGroup.text(language)) {
            InlineStat("Owner", value: "WS-UI")
            Hairline()
            InlineStat(SettingsCopy.aboutContractRow.text(language),
                       value: "DomainModels / ServiceProtocols · frozen scaffold-v0")
            Hairline()
            InlineStat(SettingsCopy.aboutThisPaneRow.text(language),
                       value: SettingsCopy.aboutThisPaneValue.text(language))
            Text(SettingsCopy.aboutNoNewPersistencePath.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - 样例行

/// 「键 = 值」等宽样例行。
private struct SettingsSampleRow: View {
    let label: String
    let value: String

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(.axMetaMono)
                .foregroundStyle(Surface.secondaryLabel)
            Spacer(minLength: Spacing.md)
            Text(value)
                .font(.axBody)
                .monospacedDigit()
                .foregroundStyle(Surface.label)
                .textSelection(.enabled)
        }
        .frame(minHeight: Sizing.rowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(SettingsCopy.aboutA11yEquals.format(language, label, value))
    }
}

// MARK: - Previews

#Preview("设置 · 关于") {
    ObservatoryPreview.screen { runtime in
        SettingsAboutPane(model: SettingsModel(runtime: SettingsPreviewSamples.runtime(runtime)))
    }
}

#Preview("设置 · 关于（空）") {
    ObservatoryPreview.screen(empty: true) { runtime in
        SettingsAboutPane(model: SettingsModel(runtime: runtime))
    }
}
