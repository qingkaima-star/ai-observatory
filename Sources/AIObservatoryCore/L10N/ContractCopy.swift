//
//  ContractCopy.swift
//  AIObservatoryCore / L10N
//
//  Owner: master-controller（#67：契约层状态名的双语化）
//  ─────────────────────────────────────────────────────────
//  这里放的是**契约枚举的名字**，不是界面文案：`EngineState`、`SessionOutcome`、
//  `AttributionGap.Reason`、`CommandOutcome` 这些 `displayName` 此前是
//  `Core/Contracts/**`（§3 冻结区）里的裸中文字面量 ⇒ 英文态下外壳、会话行、
//  归属缺口那几处会夹进中文原因词（界面侧早在 `CaptureAvailability.swift:128` 记过这条，
//  当时只能记，因为名字在冻结区）。
//
//  为什么名字放 L10N 而不是就地写两路字符串：
//   · 界面层**不许再抄一份状态名**——第二个出处必然分叉（`ShellCopy.swift:31` 那条拒绝抄的理由成立，
//     它给的出路也正是这一条：把名字收到一个两界都读得到的地方）；
//   · `Core/L10N` 不是冻结区，而 `Core/Contracts` 是 ⇒ 契约文件里只留**一行转发**，
//     冻结区的改动面压到最小；
//   · 放这儿还能被 `bilingualCopy` 那套门禁遍历（缺译 / 假双语 / 串位都查得到），
//     散在 `switch` 里返回字面量就没人查。
//
//  ⚠️ 一处**照抄现状**的不对称，别在这里顺手改：`CommandOutcome` 的中文侧四条本来就是英文
//  （Success / Failure / Terminated / Unknown），只有 `.running` 是"运行中" ⇒ 中文态下
//  命令结果标签 4 英 1 中。本文件只**保真**（改语义要单独决策，见 #73），
//  所以这几条的 zh 与 en 逐字相同——那不含汉字，不会被"假双语"判据拦下，是刻意的。
//

import Foundation

/// 契约层枚举的用户可见名字。
public enum ContractCopy {

    // MARK: - 引擎状态（外壳、菜单栏、设置页都挂它）

    public static let engineStopped = LocalizedString(zh: "已停止", en: "Stopped")
    public static let engineStarting = LocalizedString(zh: "启动中", en: "Starting")
    public static let engineRunning = LocalizedString(zh: "运行中", en: "Running")
    public static let engineDegraded = LocalizedString(zh: "降级运行", en: "Degraded")
    public static let engineFailed = LocalizedString(zh: "异常", en: "Failed")

    // MARK: - 会话结果

    public static let sessionRunning = LocalizedString(zh: "进行中", en: "In progress")
    public static let sessionSuccess = LocalizedString(zh: "成功", en: "Succeeded")
    public static let sessionFailed = LocalizedString(zh: "失败", en: "Failed")
    public static let sessionInterrupted = LocalizedString(zh: "中断", en: "Interrupted")
    public static let sessionUnknown = LocalizedString(zh: "未知", en: "Unknown")

    // MARK: - 被剔除的监控根的原因（文件页"采集面"那一行）

    /// ⚠️ 这**不是** `AttributionGap.Reason`（未归属的机制原因）——那一个没有 `displayName`，
    /// 名字本来就在界面的 `AttributionCopy` 里双语化过。两个 `Reason` 同名不同物，
    /// 起名字时别把它们混成一种（本仓有过"把别的系统的消费者当成这个字段的消费者"的教训）。
    public static let droppedProtectedRoot = LocalizedString(zh: "过浅：受保护根", en: "Too shallow: protected root")
    public static let droppedIgnoredPattern = LocalizedString(zh: "命中忽略规则", en: "Matched an ignored-path rule")
    public static let droppedEmptyPath = LocalizedString(zh: "空路径", en: "Empty path")
    public static let droppedShadowed =
        LocalizedString(zh: "已被更浅的监控根覆盖", en: "Covered by a shallower monitored root")

    // MARK: - 命令结果（中文侧照抄现状，见文件头那条 ⚠️）

    public static let commandRunning = LocalizedString(zh: "运行中", en: "Running")
    public static let commandSuccess = LocalizedString(zh: "Success", en: "Success")
    public static let commandFailure = LocalizedString(zh: "Failure", en: "Failure")
    public static let commandTerminated = LocalizedString(zh: "Terminated", en: "Terminated")
    public static let commandUnknown = LocalizedString(zh: "Unknown", en: "Unknown")

    // MARK: - 识别信号（Agent 是靠什么被认出来的）

    public static let signalProcessName = LocalizedString(zh: "进程名", en: "Process name")
    public static let signalExecutablePath = LocalizedString(zh: "可执行文件路径", en: "Executable path")
    /// 中文侧本来就是英文（技术标识），照抄不改。
    public static let signalBundleIdentifier = LocalizedString(zh: "Bundle Identifier", en: "Bundle Identifier")
    public static let signalParentProcessTree = LocalizedString(zh: "父子进程树", en: "Parent-process tree")
    public static let signalTerminalSession = LocalizedString(zh: "终端会话", en: "Terminal session")
    public static let signalArgumentSignature = LocalizedString(zh: "命令行特征", en: "Argument signature")
    public static let signalUnknown = LocalizedString(zh: "未知信号", en: "Unknown signal")

    /// 本文件全部文案，交给门禁用例遍历（缺译 / 假双语 / 串位 / 类型不一致）。
    public static let bilingualCopy: [NamedCopy] = [
        NamedCopy("contract.engine.stopped", engineStopped),
        NamedCopy("contract.engine.starting", engineStarting),
        NamedCopy("contract.engine.running", engineRunning),
        NamedCopy("contract.engine.degraded", engineDegraded),
        NamedCopy("contract.engine.failed", engineFailed),
        NamedCopy("contract.session.running", sessionRunning),
        NamedCopy("contract.session.success", sessionSuccess),
        NamedCopy("contract.session.failed", sessionFailed),
        NamedCopy("contract.session.interrupted", sessionInterrupted),
        NamedCopy("contract.session.unknown", sessionUnknown),
        NamedCopy("contract.dropped.protectedRoot", droppedProtectedRoot),
        NamedCopy("contract.dropped.ignoredPattern", droppedIgnoredPattern),
        NamedCopy("contract.dropped.emptyPath", droppedEmptyPath),
        NamedCopy("contract.dropped.shadowed", droppedShadowed),
        NamedCopy("contract.command.running", commandRunning),
        NamedCopy("contract.command.success", commandSuccess),
        NamedCopy("contract.command.failure", commandFailure),
        NamedCopy("contract.command.terminated", commandTerminated),
        NamedCopy("contract.command.unknown", commandUnknown),
        NamedCopy("contract.signal.processName", signalProcessName),
        NamedCopy("contract.signal.executablePath", signalExecutablePath),
        NamedCopy("contract.signal.bundleIdentifier", signalBundleIdentifier),
        NamedCopy("contract.signal.parentProcessTree", signalParentProcessTree),
        NamedCopy("contract.signal.terminalSession", signalTerminalSession),
        NamedCopy("contract.signal.argumentSignature", signalArgumentSignature),
        NamedCopy("contract.signal.unknown", signalUnknown),
    ]
}
