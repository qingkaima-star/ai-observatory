//
//  SettingsModel.swift
//  AIObservatoryUI / Settings
//
//  Owner: WS-UI (subagent J)
//  ─────────────────────────────────────────────────────────
//  Settings 板块唯一数据源：**会话内草稿模型**，绝不伪造持久化。
//
//  事实（对照冻结契约）：
//    · `ObservatorySettings` 是值类型，`ObservatoryRuntime.settings` 是 let 进来的基线快照；
//    · 契约里存在 `SettingsStoring` 协议，但 `ObservatoryRuntime` **没有**暴露它，
//      UI 层拿不到任何写盘入口。
//  因此本文件：
//    · 模型自己不写 UserDefaults、不写文件——持久化是引擎的职责；
//    · `apply()` 调 `runtime.controller.updateSettings(_:)`，由引擎落盘并热生效；
//    · 界面上方由 SettingsView 常驻显示 `persistenceNotice`，讲清哪些项需重启。
//
//  引擎状态：`runtime.updates.currentState()` + `observeUpdates()` 的 `.engineState` 分支，
//  启停走 `runtime.controller`（有 ShellModel 时视图层优先用 shell.toggleEngine()）。
//

import Foundation
import Observation
import AIObservatoryCore

@Observable
@MainActor
final class SettingsModel {

    /// 界面顶部常驻的说明。
    ///
    /// ⚠️ 两类字段必须分开写，混在一起就是界面在说谎：
    /// · **需重启**：有真实消费者，只是读取点在启动期（主题、菜单栏、数据库目录）；
    /// · **尚未接入**：全仓找不到任何消费者，重启一万次也不会生效
    ///   （开机启动没有 `SMAppService` 入口、`enableEndpointSecurity` 没有任何采集链接了它）。
    /// 旧文案把五样东西一律写成「需重启生效」，等于给两个空开关背书。
    ///
    /// 为什么是**函数**而不是 `static let`：`let` 会把首次访问时那一次的语言烤进常量，
    /// 用例就无法钉住某一路文案（本目录的门禁断言一律显式传语言）。
    static func persistenceNotice(_ language: AppLanguage) -> String {
        SettingsCopy.persistenceNotice.text(language)
    }

    /// 「登录时启动」那一行的说明。写成条件句而不是现在时：
    /// detail 里那句「开机后自动拉起观测引擎。」是一句现在时断言，而代码里
    /// 全仓没有 `SMAppService` / 登录项注册的任何痕迹（实测 grep 零命中）。
    static func launchAtLoginDetail(_ language: AppLanguage) -> String {
        SettingsCopy.launchAtLoginDetail.text(language)
    }

    /// 模型内部产生 `notice` 时用的语言（进程内常量，见 `UILanguage`）。
    private var language: AppLanguage { UILanguage.current }

    static let processScanIntervalRange: ClosedRange<Double> = 1...120
    static let retentionRange: ClosedRange<Int> = 1...365

    // MARK: - 只读状态

    /// 正在编辑的草稿（唯一可写入口是 `update(_:)` 与下方几个列表小工具）。
    private(set) var draft: ObservatorySettings
    /// 「本次会话内已生效」的设置：`apply()` 的落点。
    private(set) var appliedSettings: ObservatorySettings
    /// 契约给的基线快照（runtime.settings，本次会话无法改写）。
    private(set) var contractSettings: ObservatorySettings

    private(set) var isLoading: Bool = false
    private(set) var errorMessage: String?
    /// 一次性轻提示（校验结果、apply/revert 反馈）。
    private(set) var notice: String?
    private(set) var engineState: EngineState = .stopped
    /// 实时捕获能力读数（ADR-0006 #6：`AgentDetectionPipeline.realtimeCapability()` 探了但零消费者）。
    /// `runtime.capability` 没接入时为 `nil`——界面据此显示明确的「未接入」，不猜一档保真度。
    private(set) var realtimeCapability: RealtimeCapability?
    /// 已观测项目数：用一次最轻量的只读查询探活本地库顺带得到。
    private(set) var observedProjectCount: Int = 0
    private(set) var lastAppliedAt: Date?

    private let runtime: ObservatoryRuntime

    init(runtime: ObservatoryRuntime) {
        self.runtime = runtime
        self.contractSettings = runtime.settings
        self.draft = runtime.settings
        self.appliedSettings = runtime.settings
    }

    // MARK: - 脏态判定

    /// 与**契约基线**（runtime.settings）的差异：只要改过就一直是 true，即使已 apply。
    var hasUnsavedChanges: Bool { draft != runtime.settings }

    /// 渲染层脱敏映射，供 `SettingsView` 注入环境值。
    ///
    /// 为什么设置窗口要**自己**来一份：`MenuBarExtra` 与 `Settings` 是两个独立 Scene，
    /// `ObservatoryRootView` 那份 `.environment` 到不了这里 ⇒ 「开启后界面上每一处出现路径的地方」
    /// 这句承诺（隐私页原文）在设置页本身是破的：那一页恰恰**整屏都是路径**（监控根、忽略规则、存储目录）。
    ///
    /// 读的是 `runtime.settings`，与主窗口那一行**同源**：开关是重启生效的显示口径，
    /// 不是草稿。拿 `draft` 会测出一个真机上不存在的组合（拨一下开关、当前页立刻自欺地遮上了）。
    var renderMask: PathPrivacy.Mask { PathPrivacy.Mask.configured(from: runtime.settings) }

    /// 与**会话内生效值**（appliedSettings）的差异：决定「应用」按钮是否可点。
    var hasPendingChanges: Bool { draft != appliedSettings }

    /// 本次会话是否 apply 过与基线不同的值（横幅文案分叉用）。
    var isSessionModified: Bool { appliedSettings != runtime.settings }

    /// 逐字段差异数，用于头部徽章「N 项改动」。
    ///
    /// ⚠️ **每加一个 `ObservatorySettings` 字段就要在这里补一行**——漏了不报错，
    /// 表现为「用户明明拨了，徽章却说没有待应用的变更」（今天 `storeDiffPlaintext` 就漏着，
    /// 新字段 `demoRedactedOutput` 一起补上）。
    /// 这条纪律由 `SettingsFieldRoundTripTests` 的**分母守卫**代管：它对每个字段单独改一次、
    /// 断言计数恰好 +1，漏一个就点名那一个，不再靠人数 `if`。
    var pendingChangeCount: Int {
        var count = 0
        if draft.monitoredRoots != appliedSettings.monitoredRoots { count += 1 }
        if draft.ignoredPathPatterns != appliedSettings.ignoredPathPatterns { count += 1 }
        if draft.processScanIntervalSeconds != appliedSettings.processScanIntervalSeconds { count += 1 }
        if draft.retentionDays != appliedSettings.retentionDays { count += 1 }
        if draft.enableEndpointSecurity != appliedSettings.enableEndpointSecurity { count += 1 }
        if draft.enableMenuBarExtra != appliedSettings.enableMenuBarExtra { count += 1 }
        if draft.enableRiskConfirmation != appliedSettings.enableRiskConfirmation { count += 1 }
        if draft.theme != appliedSettings.theme { count += 1 }
        if draft.launchAtLogin != appliedSettings.launchAtLogin { count += 1 }
        if draft.storeDirectory != appliedSettings.storeDirectory { count += 1 }
        if draft.storeDiffPlaintext != appliedSettings.storeDiffPlaintext { count += 1 }
        if draft.demoRedactedOutput != appliedSettings.demoRedactedOutput { count += 1 }
        if draft.notifyHighRisk != appliedSettings.notifyHighRisk { count += 1 }
        return count
    }

    // MARK: - 草稿操作

    /// 唯一的字段写入口：所有 Toggle / Picker / Stepper / TextField 绑定都经过它。
    func update(_ mutate: (inout ObservatorySettings) -> Void) {
        mutate(&draft)
        notice = nil
    }

    /// 丢弃未应用的修改，回到「本次会话内已生效」的那一份。
    func revert() {
        draft = appliedSettings
        notice = SettingsCopy.revertDone.text(language)
    }

    /// 直接回到契约基线（runtime.settings）。
    func revertToContractBaseline() {
        draft = runtime.settings
        notice = SettingsCopy.baselineReset.text(language)
    }

    /// 「应用」= 把草稿交给引擎：引擎既换掉会话内生效值，也落盘（`ObservatoryEngine.updateSettings`
    /// → `SettingsPersistence.save`）。落不了盘时引擎自己记日志，界面文案见 `persistenceNotice`。
    func apply() async {
        let candidate = draft
        await runtime.controller.updateSettings(candidate)
        appliedSettings = candidate
        lastAppliedAt = Date()
        notice = Self.persistenceNotice(language) + menuBarRestartReminder(language)
    }

    /// 菜单栏改动「本进程不会生效」的提醒；没改这一项时返回空串，不制造噪音。
    ///
    /// 为什么单挑这一项：其余需重启的项界面本来就标着未接入，而菜单栏开关看起来是 work 的——
    /// 引擎会老老实实存下它，只是 SwiftUI 的 Scene 已经在启动时定死（ADR-0006 #14）。
    /// 应用后只报一个「N 项已应用」会让用户以为菜单栏已经消失。
    func menuBarRestartReminder(_ language: AppLanguage) -> String {
        guard draft.enableMenuBarExtra != contractSettings.enableMenuBarExtra else { return "" }
        return SettingsCopy.menuBarRestartReminder.text(language)
    }

    /// 本次启动**实际声明**了哪个菜单栏形态。
    ///
    /// `runtime.settings` 在生产宿主里由 `ObservatoryLaunch` 按「落盘值 → 基线」解析后回填，
    /// 因此它就是 `AIObservatoryMain` 挑 Scene 时用的那一个值；预览宿主没走这条路径时，
    /// 它退化为预览给的设置——所以这里说的是「启动设置」，不是「我猜进程里有没有」。
    func menuBarDeclaredAtLaunchText(_ language: AppLanguage) -> String {
        contractSettings.enableMenuBarExtra
            ? SettingsCopy.menuBarDeclared.text(language)
            : SettingsCopy.menuBarNotDeclared.text(language)
    }

    /// 草稿是否与启动声明一致（一致=绿色，不一致=橙色并需重启）。
    var menuBarDraftMatchesLaunch: Bool {
        draft.enableMenuBarExtra == contractSettings.enableMenuBarExtra
    }

    /// About 页那一行：报的是**本进程声明了什么**，不是草稿拨到哪。
    /// 草稿与声明不一致时补一句「待重启」，避免 About 页看起来像即时生效。
    func menuBarAboutText(_ language: AppLanguage) -> String {
        menuBarDraftMatchesLaunch
            ? menuBarDeclaredAtLaunchText(language)
            : menuBarDeclaredAtLaunchText(language) + SettingsCopy.menuBarDraftPending.text(language)
    }

    /// 保留期整数写入口（越界夹紧）。采样间隔类字段由 Stepper 的 `in:` 区间负责夹紧，
    /// 统一走 `update(_:)`，这里只额外保留一个需要类型换算的入口。
    func setRetentionDays(_ value: Int) {
        update { $0.retentionDays = min(max(value, Self.retentionRange.lowerBound), Self.retentionRange.upperBound) }
    }

    // MARK: - 路径列表

    /// 新增监控根目录：空串/重复会被拒并以 notice 反馈。
    func addMonitoredRoot(_ raw: String) {
        let path = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else {
            notice = SettingsCopy.rootEmptyNotice.text(language)
            return
        }
        guard !draft.monitoredRoots.contains(path) else {
            notice = SettingsCopy.rootDuplicateNotice.text(language)
            return
        }
        update { $0.monitoredRoots.append(path) }
        notice = SettingsCopy.draftAddedNotice.text(language)
    }

    func removeMonitoredRoot(path: String) {
        update { $0.monitoredRoots.removeAll { $0 == path } }
        notice = SettingsCopy.draftRemovedNotice.text(language)
    }

    /// 新增忽略规则：`*` / `?` 语义来自契约的 PatternMatcher，UI 不自己解释通配符。
    func addIgnoredPattern(_ raw: String) {
        let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !pattern.isEmpty else {
            notice = SettingsCopy.ruleEmptyNotice.text(language)
            return
        }
        guard !draft.ignoredPathPatterns.contains(pattern) else {
            notice = SettingsCopy.ruleExistsNotice.text(language)
            return
        }
        update { $0.ignoredPathPatterns.append(pattern) }
        notice = PatternMatcher.matches(pattern: pattern, path: "/")
            ? SettingsCopy.ruleMatchesEverythingNotice.text(language)
            : SettingsCopy.draftAddedNotice.text(language)
    }

    func removeIgnoredPattern(_ pattern: String) {
        update { $0.ignoredPathPatterns.removeAll { $0 == pattern } }
        notice = SettingsCopy.draftRemovedNotice.text(language)
    }

    /// 恢复契约里 `ObservatorySettings.default` 的那套默认忽略规则。
    func restoreDefaultIgnoredPatterns() {
        let defaults = ObservatorySettings.default.ignoredPathPatterns
        update { $0.ignoredPathPatterns = defaults }
        notice = SettingsCopy.rulesRestoredNotice.text(language)
    }

    // MARK: - 引擎

    /// 无 Shell 环境时的兜底启停（有 Shell 时视图层用 shell.toggleEngine()）。
    func toggleEngine() async {
        switch engineState {
        case .running, .starting, .degraded:
            await runtime.controller.stop()
        case .stopped, .failed:
            await runtime.controller.start()
        }
        engineState = await runtime.updates.currentState()
    }

    func rescan() async {
        await runtime.controller.rescanNow()
        engineState = await runtime.updates.currentState()
    }

    // MARK: - 加载 / 订阅

    /// 进入板块时调用：拉引擎状态，并用一次最轻量的只读查询探活本地库
    /// （契约没有 storeStats / 设置持久化探针，`projects()` 是最便宜的可达性检查）。
    func load() async {
        isLoading = true
        errorMessage = nil
        engineState = await runtime.updates.currentState()
        realtimeCapability = runtime.capability?.currentRealtimeCapability()
        do {
            let projects = try await runtime.service.projects()
            observedProjectCount = projects.count
        } catch {
            observedProjectCount = 0
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// 长驻订阅：设置页只关心引擎状态变化（其余事件由各板块自己消费）。
    func observeUpdates() async {
        for await update in runtime.updates.makeUpdateStream() {
            if Task.isCancelled { break }
            if case .engineState(let state) = update {
                engineState = state
            }
        }
    }

    // MARK: - 派生文案

    var isEngineRunning: Bool { engineState.isCollecting }

    var engineStateName: String { engineState.displayName(UILanguage.current) }

    /// 「实时捕获能力」一行的读数；宿主没接时如实说明，不留空也不猜一档。
    func realtimeCapabilityText(_ language: AppLanguage) -> String {
        realtimeCapability?.displayName ?? SettingsCopy.capabilityMissingHost.text(language)
    }

    /// 这一档对审计完整性意味着什么。文案住在 `RealtimeCapability.fidelityNote` 里，
    /// UI 只负责取——两处各写一份 switch 迟早和采集链的实际行为脱节。
    func realtimeCapabilityNote(_ language: AppLanguage) -> String {
        realtimeCapability?.fidelityNote ?? SettingsCopy.capabilityFidelityUnknown.text(language)
    }

    var themeName: String { draft.theme.displayName }

    func processScanIntervalText(_ language: AppLanguage) -> String {
        SettingsCopy.scanIntervalValue.format(language, draft.processScanIntervalSeconds)
    }

    func retentionText(_ language: AppLanguage) -> String {
        SettingsCopy.retentionValue.format(language, draft.retentionDays)
    }

    func monitoredRootsSummary(_ language: AppLanguage) -> String {
        draft.monitoredRoots.isEmpty
            ? SettingsCopy.rootsUnconfiguredSummary.text(language)
            : SettingsCopy.rootsConfiguredSummary.format(language, draft.monitoredRoots.count)
    }

    func ignoredPatternsSummary(_ language: AppLanguage) -> String {
        draft.ignoredPathPatterns.isEmpty
            ? SettingsCopy.rulesUnconfiguredSummary.text(language)
            : SettingsCopy.rulesConfiguredSummary.format(language, draft.ignoredPathPatterns.count)
    }

    func storeDirectoryText(_ language: AppLanguage) -> String {
        draft.storeDirectory.isEmpty
            ? SettingsCopy.storeDirectoryMissing.text(language)
            : draft.storeDirectory
    }

    /// 「当前生效值」的一行摘要，用于横幅与 About。
    func effectiveSummary(_ language: AppLanguage) -> String {
        guard isSessionModified else {
            return SettingsCopy.stillContractBaseline.text(language)
        }
        // 拼接结构照旧：基句 + 可选的时间戳括注（没有时间点时不补括号，也不留半个空格）。
        return SettingsCopy.appliedInSession.text(language)
            + (lastAppliedAt.map {
                SettingsCopy.appliedTimestampParen.format(language, DateFormat.timestamp($0))
            } ?? "")
    }
}

// MARK: - Preview 支撑

/// 设置各 pane 独立预览用的样本值。
/// 契约的 `ObservatoryPreview.runtime()` 只给 `settings: .default`（监控根目录为空、storeDirectory 为空），
/// 因此这里提供一份可直接填进 `ObservatoryRuntime.settings`（public var）的完整样本。
enum SettingsPreviewSamples {
    static let settings = ObservatorySettings(
        monitoredRoots: ["/Users/demo/Projects", "~/Documents/AiX"],
        ignoredPathPatterns: ObservatorySettings.default.ignoredPathPatterns,
        processScanIntervalSeconds: 3,
        retentionDays: 30,
        enableEndpointSecurity: false,
        enableMenuBarExtra: true,
        enableRiskConfirmation: true,
        theme: .system,
        launchAtLogin: false,
        storeDirectory: "~/Library/Application Support/AIObservatory/store"
    )

    /// 把样本设置塞进预览 runtime（其余 service / controller / updates 保持不变）。
    static func runtime(_ base: ObservatoryRuntime) -> ObservatoryRuntime {
        var copy = base
        copy.settings = settings
        return copy
    }
}
