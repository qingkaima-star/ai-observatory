//
//  SettingsView.swift
//  AIObservatoryUI / Settings
//
//  Owner: WS-QUIET-1（子代理 C）
//  ─────────────────────────────────────────────────────────
//  设置板块入口：一个 `ObservatoryPage` + 四个分段内容。
//
//  与旧版的三处结构区别：
//    1. 旧：四个分段做成带 SF 图标的系统页签，外层再自拼骨架
//       → 新：页面只有一个标题行，分段切换是标题行右侧**一个控件**（在懒容器之外，
//          所以 `.menu` 样式安全）；页面底 / 1120 收口 / 32 边距全部交给 `ObservatoryPage`。
//    2. 旧：加载中 / 探活失败 四条分段各画一份（`SettingsStateStrip` ×4）
//       → 新：这两条是**页面级**事实，只上屏一次；各分段只保留自己那句空态提示。
//    3. 旧：「撤销 / 应用」在标题行、「N 项已应用」另做一张底部大卡
//       → 新：提交条（`N 项改动` + 撤销 + 应用）留在标题行右侧，
//          会话口径（生效状态 / 引擎 / 上次应用 + 常驻的 `persistenceNotice`）合成一个面板。
//
//  本页**没有** `.hero`：它不像概览页有一个「要不要继续往下看」的主读数，
//  造一个只会是装饰。层级由 `.axSection`（分组名）/ `.axBody`（设置项名）/
//  `.axMeta`（说明与限制）三档承担，分区由 `Panel` 与页面底的一级背景差承担。
//
//  草稿模型见 SettingsModel.swift：所有写路径统一走 `update(_:)`，
//  本文件末尾额外提供 SwiftUI 侧的桥（Binding 助手 + AppTheme → ColorScheme），
//  让 SettingsModel.swift 保持只依赖 Foundation/Observation/Core。
//

import SwiftUI
import Observation
import AIObservatoryCore

// MARK: - 分段

/// 设置分段。声明在视图层：分段选择属于界面状态。
///
/// 旧版每段一个 SF 图标（`symbol`），只服务页签装饰、读不出信息，参数已删。
enum SettingsPane: String, CaseIterable, Identifiable {
    case general
    case privacy
    case storage
    case about

    var id: String { rawValue }

    var title: String { title(UILanguage.current) }

    var subtitle: String { subtitle(UILanguage.current) }

    func title(_ language: AppLanguage) -> String {
        switch self {
        case .general:  return SettingsCopy.paneGeneral.text(language)
        case .privacy:  return SettingsCopy.panePrivacy.text(language)
        case .storage:  return SettingsCopy.paneStorage.text(language)
        case .about:    return SettingsCopy.paneAbout.text(language)
        }
    }

    /// 当前分段讲什么。旧版这份文案写好了却没有任何地方显示，现在钉在标题行下方一行。
    func subtitle(_ language: AppLanguage) -> String {
        switch self {
        case .general:  return SettingsCopy.paneSubtitleGeneral.text(language)
        case .privacy:  return SettingsCopy.paneSubtitlePrivacy.text(language)
        case .storage:  return SettingsCopy.paneSubtitleStorage.text(language)
        case .about:    return SettingsCopy.paneSubtitleAbout.text(language)
        }
    }
}

// MARK: - 入口视图

@MainActor
public struct SettingsView: View {

    @State private var model: SettingsModel
    @State private var pane: SettingsPane = .general
    @Environment(ShellModel.self) private var shell: ShellModel?
    /// #89：错误面板那一句是 `error.localizedDescription`，本仓的存储错误里带着库文件绝对路径。
    @Environment(\.demoRedaction) private var demoRedaction

    public init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: SettingsModel(runtime: runtime))
    }

    public var body: some View {
        ObservatoryPage(
            SidebarSection.settings.title,
            subtitle: SettingsCopy.pageSubtitle.format(UILanguage.current, model.effectiveSummary(UILanguage.current))
        ) {
            pageControls
        } content: {
            // 页面级三态：整个板块只有这一份，不再逐段重复。
            if model.isLoading {
                loadingLine
            }

            if let message = model.errorMessage {
                errorPanel(message)
            }

            sessionPanel

            VStack(alignment: .leading, spacing: Spacing.md) {
                Text(pane.subtitle)
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                paneContent
            }
        }
        .preferredColorScheme(model.preferredColorScheme)
        // #89 ①-b：设置页是**独立 Scene**（`Settings { SettingsView(runtime:) }`），
        // 主窗口那份环境值进不来 ⇒ 不在这里注入，开关开着这一屏仍整屏原样列路径。
        .environment(\.demoRedaction, model.renderMask)
        .task {
            // 先登记订阅，再拉快照：反过来时 `load()` 这段 await 窗口里引擎推的
            // `.engineState` 会整个错过，界面停在进页之前的状态（与 DashboardView 同一处坑）。
            async let watching: Void = model.observeUpdates()
            await model.load()
            _ = await watching
        }
        .refreshable { await model.load() }
        .accessibilityLabel(SidebarSection.settings.title)
    }

    @ViewBuilder private var paneContent: some View {
        switch pane {
        case .general:  SettingsGeneralPane(model: model)
        case .privacy:  SettingsPrivacyPane(model: model)
        case .storage:  SettingsStoragePane(model: model)
        case .about:    SettingsAboutPane(model: model)
        }
    }

    // MARK: - 标题行右侧：分段切换 + 提交条

    /// 「应用 / 撤销」这条改动提交条留在标题行，不再做成底部大卡片。
    /// 计数文案沿用 `N 项改动`，口径是 `pendingChangeCount`（与**会话内生效值**的差异）。
    private var pageControls: some View {
        HStack(spacing: Spacing.sm) {
            Picker(SettingsCopy.panePickerLabel.text(UILanguage.current), selection: $pane) {
                ForEach(SettingsPane.allCases) { target in
                    Text(target.title).tag(target)
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .accessibilityLabel(SettingsCopy.a11ySwitchPane.text(UILanguage.current))

            // 判据用计数本身，不用 `hasUnsavedChanges`：后者比的是「草稿 ≠ 契约基线」，
            // 而 `pendingChangeCount` 比的是「草稿 ≠ 会话内生效值」。apply 之后前者仍为真、
            // 后者已归零，照旧写法会长期挂着一句「0 项改动」。
            if model.pendingChangeCount > 0 {
                Text(SettingsCopy.pendingChanges.format(UILanguage.current, model.pendingChangeCount))
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
            }

            Button(SettingsCopy.revert.text(UILanguage.current)) {
                model.revert()
            }
            .controlSize(.small)
            .disabled(!model.hasPendingChanges)

            Button(SettingsCopy.apply.text(UILanguage.current)) {
                Task { await model.apply() }
            }
            .controlSize(.small)
            .buttonStyle(.borderedProminent)
            .disabled(!model.hasPendingChanges)

            moreMenu
        }
    }

    /// 两个低频动作。旧版这里还挂着「跳到某分段」，与标题行的分段选择器重复，已删。
    private var moreMenu: some View {
        Menu {
            Button(SettingsCopy.resetToBaseline.text(UILanguage.current)) {
                model.revertToContractBaseline()
            }
            Button(SettingsCopy.rescanMachine.text(UILanguage.current)) {
                Task {
                    if let shell { await shell.rescan() } else { await model.rescan() }
                }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel(SettingsCopy.a11yMoreActions.text(UILanguage.current))
    }

    // MARK: - 页面级三态

    private var loadingLine: some View {
        HStack(spacing: Spacing.sm) {
            ProgressView()
                .controlSize(.small)
            Text(SettingsCopy.loadingLine.text(UILanguage.current))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            Spacer(minLength: Spacing.none)
        }
    }

    private func errorPanel(_ message: String) -> some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    SettingsCopy.probeFailedTitle.text(UILanguage.current),
                    subtitle: SettingsCopy.probeFailedSubtitle.text(UILanguage.current)) {
                    Button(SettingsCopy.retry.text(UILanguage.current)) {
                        Task { await model.load() }
                    }
                    .controlSize(.small)
                }
                Hairline()
                Text(demoRedaction.scrub(message))
                    .font(.axMetaMono)
                    .foregroundStyle(Surface.secondaryLabel)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - 本会话与持久化

    /// 常驻说明 + 一次性反馈 + 会话口径读数收成一个面板。
    ///
    /// `SettingsModel.persistenceNotice` 是这一页最重要的一句实话（哪些项要重启、
    /// 落盘落在哪）。旧版把它抄了三遍（横幅 / 通用页脚注 / 关于页草稿快照），
    /// 现在页面级一处 + 关于页草稿快照旁一处（那处讲的是「这份 JSON 会落到哪」，语境不同）。
    private var sessionPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(SettingsCopy.sessionPersistenceTitle.text(UILanguage.current),
                              subtitle: SettingsModel.persistenceNotice(UILanguage.current))

                Hairline()
                // 「生效状态」不再重复一遍——它已经在页面标题行的副标题里（`effectiveSummary`）。
                // 这一行是另一个口径：草稿 vs 启动基线，apply 之后两者会分开。
                InlineStat(SettingsCopy.vsLaunchBaseline.text(UILanguage.current),
                           value: model.hasUnsavedChanges ? SettingsCopy.draftDiverged.text(UILanguage.current)
                                : SettingsCopy.draftIsBaseline.text(UILanguage.current))
                Hairline()
                InlineStat(SettingsCopy.engineLabel.text(UILanguage.current), value: model.engineStateName)
                Hairline()
                InlineStat(SettingsCopy.observedProjects.text(UILanguage.current), value: "\(model.observedProjectCount)")
                Hairline()
                InlineStat(SettingsCopy.lastApplied.text(UILanguage.current),
                           value: model.lastAppliedAt.map { DateFormat.timestamp($0) }
                               ?? SettingsCopy.neverApplied.text(UILanguage.current))

                if let notice = model.notice {
                    Hairline()
                    Text(notice)
                        .font(.axBody)
                        .foregroundStyle(Surface.label)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

// MARK: - 分组与设置行（四个 pane 共用）

/// 分组容器：白底 `Panel` + 小节标题 + 若干行，行与行之间 `Hairline()`。
///
/// 分组成员自己写 `Hairline()`，因为这个基座刻意不做「自动插线」：
/// 哪些行之间该断、哪两行属于同一语义块，只有调用点看得清。
///
/// 形参顺序刻意是 `content` 在前、`trailing` 带默认值在后，这样调用点写成
/// `SettingsGroup("标题", subtitle: "…") { 行 ; 行 }`，需要标题右侧放一个读数时
/// 再补 `trailing: { … }` —— 与 `ObservatoryPage` 的多尾闭包规矩一致（第一个 unlabeled
/// 闭包按声明序绑定，写反了编不过）。
struct SettingsGroup<Content: View, Trailing: View>: View {
    private let title: String
    private let subtitle: String?
    private let trailing: Trailing
    private let content: Content

    init(_ title: String,
         subtitle: String? = nil,
         @ViewBuilder content: () -> Content,
         @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.title = title
        self.subtitle = subtitle
        self.content = content()
        self.trailing = trailing()
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(title, subtitle: subtitle) {
                    trailing
                }
                Hairline()
                content
            }
        }
    }
}

/// 一条设置行：**左标签右控件**（`InlineStat` 的镜像布局）。
///
/// - 左：标题（`.axBody`）+ 可选说明（`.axMeta` 次级色）+ 可选限制（`.axMeta`，但用
///   **primary** 色）。限制那行是本页最容易被扫过去的东西，所以给它比说明更重的一档
///   颜色，而不是靠彩色图标或橙点——那条规矩写在 `ObservatoryTokens` 的三条铁律里。
/// - 右：`Toggle` / `Picker` / `Stepper` 等真控件；行高下限 `Sizing.rowMinHeight`。
///
/// 不画框、不做胶囊填充：分组内的行由 `Hairline()` 分隔。
struct SettingsRow<Control: View>: View {
    private let title: String
    private let detail: String?
    private let caveat: String?
    private let control: Control

    init(_ title: String,
         detail: String? = nil,
         caveat: String? = nil,
         @ViewBuilder control: () -> Control = { EmptyView() }) {
        self.title = title
        self.detail = detail
        self.caveat = caveat
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.md) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                Text(title)
                    .font(.axBody)
                    .foregroundStyle(Surface.label)
                if let detail {
                    Text(detail)
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let caveat {
                    Text(caveat)
                        .font(.axMeta)
                        .foregroundStyle(Surface.label)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Spacing.md)
            control
        }
        .frame(minHeight: Sizing.rowMinHeight, alignment: .leading)
        // 刻意不写 `.accessibilityElement(children: .combine)`（旧版这里有）：
        // 合并会把行右侧那个 `Toggle` 一起吞成一个静态元素，VoiceOver 只剩能读不能开。
        // 左列三段文本 + 控件自带的 label，本来就是更好的朗读顺序。
    }
}

/// 一个开关节：把 `SettingsRow` 的控件位填上真正的 `Toggle`。
///
/// 旧版这一行还带一个 `systemImage` 彩色图标（开关拨到哪它就换色），
/// 图标不携带任何读者能解码的信息，参数一并删掉。
struct SettingsToggleRow: View {
    private let title: String
    private let detail: String
    private let caveat: String?
    @Binding private var isOn: Bool

    init(title: String,
         detail: String,
         isOn: Binding<Bool>,
         caveat: String? = nil) {
        self.title = title
        self.detail = detail
        self.caveat = caveat
        self._isOn = isOn
    }

    var body: some View {
        SettingsRow(title, detail: detail, caveat: caveat) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.switch)
                .labelsHidden()
                .accessibilityLabel(title)
        }
    }
}

/// 各分段自己那句空态提示。
///
/// 旧版这里叫 `SettingsStateStrip`，四个分段各画一份「加载中 / 探活失败」——
/// 那是同一件页面级事实被抄四遍。那两条已上移到 `SettingsView`，这里只剩分段特有的一行，
/// 所以名字也换成了它真正的职责。
struct SettingsHintLine: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.axMeta)
            .foregroundStyle(Surface.secondaryLabel)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel(SettingsCopy.a11yHintPrefix.format(UILanguage.current, text))
    }
}

// MARK: - SwiftUI 侧桥（放在视图文件里，SettingsModel.swift 保持不依赖 SwiftUI）

@MainActor
extension SettingsModel {

    /// 把界面控件绑到草稿的某个字段：读走 `draft`，写统一经 `update(_:)`。
    /// 因此 `draft` 对外仍是 private(set)，不存在绕过草稿模型的写路径。
    func binding<Value>(_ keyPath: WritableKeyPath<ObservatorySettings, Value>) -> Binding<Value> {
        Binding(
            get: { self.draft[keyPath: keyPath] },
            set: { newValue in self.update { $0[keyPath: keyPath] = newValue } }
        )
    }

    /// AppTheme → SwiftUI ColorScheme：system 交回系统（nil），light/dark 真实生效。
    ///
    /// 委托给 `AppTheme.preferredColorScheme`（`DesignSystem/ThemeApplication.swift`）：
    /// 设置页与本进程的场景根（App 层）必须用**同一份映射**，否则两处会漂移——
    /// 本仓已经因为「同一件事两个口径」出过事故（`SettingsPersistence` 那段类型级注释的由头）。
    var preferredColorScheme: ColorScheme? {
        draft.theme.preferredColorScheme
    }

    /// 保留期天数的 Int 桥接：写路径经 `setRetentionDays` 夹紧，避免界面各处重复写区间。
    var retentionDaysBinding: Binding<Int> {
        Binding(
            get: { self.draft.retentionDays },
            set: { newValue in self.setRetentionDays(newValue) }
        )
    }
}

// MARK: - Previews

#Preview("设置（有数据）") {
    ObservatoryPreview.screen { runtime in
        SettingsView(runtime: SettingsPreviewSamples.runtime(runtime))
    }
}

#Preview("设置（空 runtime）") {
    ObservatoryPreview.screen(empty: true) { runtime in
        SettingsView(runtime: runtime)
    }
}
