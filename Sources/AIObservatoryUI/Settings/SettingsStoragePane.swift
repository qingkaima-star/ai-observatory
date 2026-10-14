//
//  SettingsStoragePane.swift
//  AIObservatoryUI / Settings
//
//  Owner: WS-QUIET-1（子代理 C）
//  ─────────────────────────────────────────────────────────
//  存储与采集分段：监控根目录（增删）、忽略规则（增删 + 通配符语义说明）、采样频率、store 目录只读展示。
//  通配符语义不在 UI 里重新解释——展示用的判定统一走契约的 PatternMatcher。
//
//  排版：四组 `SettingsGroup`，容器是**非懒** `VStack`（组数恒定，且组里有 Stepper；
//  懒容器 + 真控件是本仓实测过的滚动自旋死法）。
//
//  分组顺序 = 一条数据的通路：**采什么**（监控根目录）→ **不采什么**（忽略规则）
//  → **多久看一眼**（采样频率）→ **落在哪里**（Store 目录）。
//
//  旧版这里有两个自造视觉件：路径行自己套一层下沉色圆角矩形（面板里再画
//  一层边界 = 卡中卡），输入框自己叠半透黑当底。
//  现在：行与行之间只 `Hairline()`，输入框交给 `Panel.recessed` 承载。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor
struct SettingsStoragePane: View {

    private var language: AppLanguage { UILanguage.current }

    @Bindable private var model: SettingsModel

    @State private var newRoot: String = ""
    @State private var newPattern: String = ""

    init(model: SettingsModel) {
        self._model = Bindable(model)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            if model.draft.monitoredRoots.isEmpty, !model.isLoading, model.errorMessage == nil {
                SettingsHintLine(text: SettingsCopy.noRootsHint.text(language))
            }

            monitoredRootsGroup
            ignoredPatternsGroup
            intervalGroup
            storeDirectoryGroup
        }
    }

    // MARK: - 监控根目录

    private var monitoredRootsGroup: some View {
        SettingsGroup(
            SettingsCopy.monitoredRootsGroup.text(language),
            subtitle: model.monitoredRootsSummary(language)) {
            if model.draft.monitoredRoots.isEmpty {
                EmptyStateView(
                    SettingsCopy.emptyRootsTitle.text(language),
                    systemImage: "questionmark.circle",
                    message: SettingsCopy.emptyRootsMessage.text(language),
                    fills: false
                ) {
                    Button(SettingsCopy.addDocuments.text(language)) {
                        model.addMonitoredRoot("~/Documents")
                    }
                }
            } else {
                SettingsPathRows(items: model.draft.monitoredRoots) { root in
                    SettingsPathRow(
                        path: root,
                        caption: isDirectoryLike(root) ? SettingsCopy.kindDirectory.text(language) : SettingsCopy.kindSuspectedFile.text(language),
                        warns: !isDirectoryLike(root),
                        onDelete: { model.removeMonitoredRoot(path: root) }
                    )
                }
            }

            SettingsAddField(
                placeholder: SettingsCopy.rootPlaceholder.text(language),
                text: $newRoot,
                actionTitle: SettingsCopy.addAction.text(language),
                onSubmit: {
                    model.addMonitoredRoot(newRoot)
                    newRoot = ""
                }
            )

            Text(SettingsCopy.tildeNote.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        } trailing: {
            Text(SettingsCopy.countedRows(model.draft.monitoredRoots.count, language))
                .font(.axMeta)
                .monospacedDigit()
                .foregroundStyle(Surface.secondaryLabel)
        }
    }

    // MARK: - 忽略规则

    private var ignoredPatternsGroup: some View {
        SettingsGroup(
            SettingsCopy.ignoreRulesGroup.text(language),
            subtitle: model.ignoredPatternsSummary(language)) {
            Text(SettingsCopy.ignoreRulesNote.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)

            if model.draft.ignoredPathPatterns.isEmpty {
                EmptyStateView(
                    SettingsCopy.emptyRulesTitle.text(language),
                    systemImage: "circle.slash",
                    message: SettingsCopy.emptyRulesMessage.text(language),
                    fills: false
                ) {
                    Button(SettingsCopy.restoreContractDefaults.text(language)) {
                        model.restoreDefaultIgnoredPatterns()
                    }
                }
            } else {
                SettingsPathRows(items: model.draft.ignoredPathPatterns) { pattern in
                    SettingsPathRow(
                        path: pattern,
                        caption: sampleMatchText(for: pattern),
                        warns: false,
                        onDelete: { model.removeIgnoredPattern(pattern) }
                    )
                }
            }

            SettingsAddField(
                placeholder: SettingsCopy.rulePlaceholder.text(language),
                text: $newPattern,
                actionTitle: SettingsCopy.addAction.text(language),
                onSubmit: {
                    model.addIgnoredPattern(newPattern)
                    newPattern = ""
                }
            )
        } trailing: {
            Button(SettingsCopy.restoreDefaults.text(language)) {
                model.restoreDefaultIgnoredPatterns()
            }
            .controlSize(.small)
        }
    }

    // MARK: - 采样频率

    private var intervalGroup: some View {
        SettingsGroup(SettingsCopy.samplingGroup.text(language), subtitle: SettingsCopy.samplingGroupSubtitle.text(language)) {
            SettingsRow(
                SettingsCopy.scanIntervalTitle.text(language),
                detail: SettingsCopy.scanIntervalDetail.format(language,
                        SettingsModel.processScanIntervalRange.lowerBound, SettingsModel.processScanIntervalRange.upperBound)
            ) {
                HStack(spacing: Spacing.sm) {
                    Text(model.processScanIntervalText(language))
                        .font(.axMetric)
                        .monospacedDigit()
                        .foregroundStyle(Surface.label)
                        .contentTransition(.numericText())
                        .animation(ObservatoryMotion.value, value: model.draft.processScanIntervalSeconds)
                    Stepper(
                        SettingsCopy.scanIntervalTitle.text(language),
                        value: model.binding(\.processScanIntervalSeconds),
                        in: SettingsModel.processScanIntervalRange,
                        step: 1
                    )
                    .labelsHidden()
                    .fixedSize()
                }
            }
        }
    }

    // MARK: - Store 目录

    private var storeDirectoryGroup: some View {
        SettingsGroup(
            SettingsCopy.storeDirectoryLabel.text(language),
            subtitle: SettingsCopy.storeReadonlySubtitle.text(language)) {
            MonospacedCodeView(
                model.draft.storeDirectory.isEmpty
                    ? SettingsCopy.storeEmptyValue.text(language)
                    : model.draft.storeDirectory,
                maxLines: 2,
                showsCopyButton: true
            )

            InlineStat(SettingsCopy.writableLabel.text(language), value: SettingsCopy.writableNoValue.text(language))
        }
    }

    // MARK: - 小工具

    /// 粗略判断输入是否像目录（无扩展名 / 以 / 结尾），只用于给个次要提示。
    private func isDirectoryLike(_ path: String) -> Bool {
        if path.hasSuffix("/") { return true }
        let last = (path as NSString).lastPathComponent
        return !last.contains(".")
    }

    /// 用契约的 PatternMatcher 给一条规则一个「示例命中」说明，UI 不自己实现匹配。
    private func sampleMatchText(for pattern: String) -> String {
        let probe = "\(NSHomeDirectory())/Library/Caches/probe.tmp"
        return PatternMatcher.matches(pattern: pattern, path: probe) ? SettingsCopy.probeHits.text(language) : SettingsCopy.probeMisses.text(language)
    }
}

// MARK: - 行 / 输入行

/// 一个面板内的同类行（根目录 / 忽略规则）：行本身不画底，行与行之间 `Hairline()`。
///
/// 插线放在这里而不是每个调用点：同一类行之间**永远**该断，这一条没有判断余地；
/// `SettingsGroup` 里那种「哪两行属于同一语义块」的判断留给了调用点。
private struct SettingsPathRows: View {
    let items: [String]
    let makeRow: (String) -> SettingsPathRow

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            ForEach(Array(items.enumerated()), id: \.element) { index, item in
                if index > 0 {
                    Hairline()
                }
                makeRow(item)
            }
        }
    }
}

/// 一条路径或规则 + 说明 + 删除按钮。
private struct SettingsPathRow: View {

    private var language: AppLanguage { UILanguage.current }
    /// #64：删除按钮的无障碍标签把整条根目录念出来，与屏上那格不是同一份字符串。
    @Environment(\.demoRedaction) private var demoRedaction
    let path: String
    let caption: String
    /// 「疑似文件路径」这类会让这一条根目录不起作用的提示才占用留意色（走 `TagTone`，不是自造橙）。
    var warns: Bool = false
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: Spacing.sm) {
            FilePathText(path: path, mode: .middleEllipsis)
            Spacer(minLength: Spacing.sm)
            if warns {
                Tag(caption, tone: .caution)
            } else {
                Text(caption)
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
                    .fixedSize()
            }
            Button(action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .accessibilityLabel(SettingsCopy.a11yDeletePath.format(language, demoRedaction.scrub(path)))
            .help(SettingsCopy.deleteHelp.text(language))
        }
        .frame(minHeight: Sizing.rowMinHeight)
        // 不再 `.accessibilityElement(children: .combine)`（旧版写法）：
        // 合并会把行尾那个删除按钮吞成静态文本，VoiceOver 读得到路径却按不动删除。
    }
}

/// 文本输入 + 添加按钮（回车即提交）。底交给 `Panel.recessed`，不再自造灰阶。
private struct SettingsAddField: View {
    let placeholder: String
    @Binding var text: String
    let actionTitle: String
    let onSubmit: () -> Void

    init(placeholder: String, text: Binding<String>, actionTitle: String, onSubmit: @escaping () -> Void) {
        self.placeholder = placeholder
        self._text = text
        self.actionTitle = actionTitle
        self.onSubmit = onSubmit
    }

    var body: some View {
        Panel.recessed {
            HStack(spacing: Spacing.sm) {
                TextField(placeholder, text: $text)
                    .textFieldStyle(.plain)
                    .font(.axBody)
                    .frame(maxWidth: .infinity)
                    .onSubmit(submit)
                Button(actionTitle, action: submit)
                    .controlSize(.small)
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
    }

    private func submit() {
        onSubmit()
    }
}

// MARK: - Previews

#Preview("设置 · 存储与采集") {
    ObservatoryPreview.screen { runtime in
        SettingsStoragePane(model: SettingsModel(runtime: SettingsPreviewSamples.runtime(runtime)))
    }
}

#Preview("设置 · 存储与采集（空）") {
    ObservatoryPreview.screen(empty: true) { runtime in
        SettingsStoragePane(model: SettingsModel(runtime: runtime))
    }
}
