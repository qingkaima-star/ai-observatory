//
//  DetectionStrategies.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Agent / WS-Detect / WS-Platform
//  ─────────────────────────────────────────────────────────
//  实现 `AgentDetectionStrategy` 的多个策略，按置信度从高到低排列：
//
//    exePath > bundleID > processName > argumentSignature
//           > parentProcessTree > terminalSession
//
//  各策略相互独立、无副作用，便于单测。Pipeline 按此顺序串联，
//  命中即返回（首次命中优先，呼应「高置信信号优先」）。
//
//  三条卫生规则（由 `DetectionHygiene` 统一提供，真机实测教训）：
//   1. 系统进程（/System、/usr/libexec、/usr/sbin、`*.xpc`）一律返回 nil；
//   2. 签名只在路径分量 / argv token 边界上命中，不做裸子串；
//   3. 拿不到可执行路径时不凭 argv 给 ≥0.5 的置信度。
//
//  性能口径（WS-Platform 2026-09-20）：这七条策略对**每条**进程记录都可能被调用，
//  release 实测「只跑策略链」占 22.6 ms/tick。因此：
//   · 每条策略在 `init` 里把用得到的那几列签名预编译好（`AgentSignaturePlan`），
//     逐记录只付匹配本身的代价，不再反复切同一个常量串；
//   · 一条记录内重复算的常量值（如「当前进程的分量序列」）提出来算一次；
//   · `BundleIdentifierStrategy` 的 Info.plist 读取按**包路径**记忆化
//     （`AppBundleIdentifierMemo`），1082 条记录只有 75 个不同 `.app`。
//   · 七条策略各自的「系统进程闸门」guard **一律保留**：单条策略被直接调用时
//     （单测、外部复用）语义必须与整条链一致。整链跑之前 pipeline 还会先算一次闸门。
//

import Foundation
import AIObservatoryCore

// MARK: - 内部工具

/// 该进程名是否含有给定的辅助类 token（`tokens` 必须是**小写**形态）。
private func nameHasAnyToken(_ record: ProcessRecord, _ tokens: [String]) -> Bool {
    let haystack = DetectionHygiene.nameTokens(of: record.name)
    return tokens.contains { token in haystack.contains(token) }
}

/// 「辅助 / 渲染」类进程名 token——小写形态预先备好，避免逐记录 `lowercased()`。
private let helperProcessNameTokens: [String] = [
    "helper", "renderer", "worker", "gpu", "utility", "browser", "node", "crashpad"
]

/// 从 argv 的分量序列中推断具体的 Agent 种类（仅返回具体类型，不含 generic/unknown）。
///
/// - Parameter values: `DetectionHygiene.componentValues(of: argv)` 的结果，
///   由调用方算好后传入（同一次判定里还要用它做 generic 兜底，不该切两遍）。
private func specificKind(fromComponentValues values: [[String]], plan: AgentSignaturePlan) -> AgentKind? {
    for entry in plan.entries where entry.kind != .genericCLIAgent && entry.kind != .unknown {
        for token in entry.argumentSignatures where DetectionHygiene.matches(token, in: values) {
            return entry.kind
        }
    }
    return nil
}

/// 已知终端模拟器的 `.app` 包名（用于 terminalSession 策略）。
private let terminalAppNames = [
    "Terminal.app", "iTerm.app", "iTerm2.app", "Warp.app",
    "Alacritty.app", "kitty.app", "Ghostty.app", "Hyper.app"
]

/// 同上，预编译形态：常量串只切一次（旧写法是每条记录的每个祖先 × 8 个包名各切一遍）。
private let compiledTerminalAppNames: [DetectionHygiene.CompiledSignature] =
    terminalAppNames.map(DetectionHygiene.compileSignature)

/// 终端会话兜底用的通用关键字（仍按 token 边界命中，不是裸子串）。
private let genericAgentTokens: [String] = ["agent", "claude", "codex", "gemini", "aider", "copilot"]

/// 同上，预编译形态。
private let compiledGenericAgentTokens: [DetectionHygiene.CompiledSignature] =
    genericAgentTokens.map(DetectionHygiene.compileSignature)

/// 判断某个祖先进程是否属于终端模拟器。
///
/// 终端模拟器确实住在 `/System/Library/CoreServices/Terminal.app`，所以这里**不能**
/// 套系统进程闸门——闸门排除的是「被检出的进程」，不是「宿主环境」。
private func isTerminal(_ record: ProcessRecord) -> Bool {
    let values = DetectionHygiene.componentValues(of: [record.executablePath, record.name])
    return compiledTerminalAppNames.contains { DetectionHygiene.matches($0, in: values) }
}

/// 进程名是否属于某种「辅助/渲染」类子进程（用于父树归属）。
private func isHelperProcess(_ record: ProcessRecord) -> Bool {
    if nameHasAnyToken(record, helperProcessNameTokens) { return true }
    // 分量整段等于 "helpers" 才算（原写法 `containsCI(整条路径, "Helpers/")` 是裸子串）。
    return DetectionHygiene.componentValues(of: record.executablePath).contains { $0.contains("helpers") }
}

// MARK: - 1. 可执行路径策略（exePath）

/// 依据可执行文件路径判定 Agent。置信度最高（0.92）。
///
/// `pathFragments` 的锚定语义见 `DetectionHygiene.matches`：
/// 单个分量且不像 bundle 名的片段（`/codex`、`/claude`）是「可执行文件名」，必须命中路径的
/// 最后一个分量——`…/Resources/codex/browser_crashpad_handler` 与 `~/projects/codex/notes.md`
/// 都不再命中；多分量布局（`Cursor.app/Contents/MacOS/Cursor`）与 bundle 名按连续分量命中。
public struct ExecutablePathStrategy: AgentDetectionStrategy {
    public let name = "ExecutablePath"

    /// 特征库的预编译视图（本策略只用 `pathFragments` 那一列）。
    /// 表是静态的，编译一次即可——旧写法每条记录都对全部签名重新 `lowercased()` + 切段。
    private let plan = AgentSignaturePlan(AgentSignatureDatabase.shared)

    /// `pathFragments` 各签名首段的词干集：路径不含任何词干时整条策略直接落空。
    private let stems: DetectionHygiene.SignatureStems

    public init() {
        stems = DetectionHygiene.SignatureStems(plan.entries.flatMap(\.pathFragments))
    }

    public func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        let path = record.executablePath
        guard !path.isEmpty else { return nil }
        guard !DetectionHygiene.isSystemProcessPath(path) else { return nil }
        // 快速否证（WS-Platform #55）：路径里连某个签名的首段都不含 ⇒ 七条分量匹配必然全空。
        // 与下面的完整判定同为「首段须为子串」这一必要条件的推论，故检出面逐字不变。
        guard stems.couldMatch(in: [path]) else { return nil }

        let values = DetectionHygiene.componentValues(of: path)
        for entry in plan.entries where !entry.pathFragments.isEmpty {
            let hit = entry.pathFragments.contains { fragment in
                DetectionHygiene.matches(fragment, in: values)
            }
            if hit {
                return AgentDetectionResult(kind: entry.kind, signal: .executablePath, confidence: 0.92)
            }
        }
        return nil
    }
}

// MARK: - 2. Bundle Identifier 策略（bundleID）

/// 依据 macOS 应用的 Bundle Identifier 判定 Agent（GUI 应用，0.95）。
///
/// 反向域名按「段」匹配：`com.windsurf` 命中 `com.windsurf.ai`，
/// 但不命中 `com.example.windsurf`。
///
/// 取 Bundle Identifier 的口径（WS-Platform 2026-09-20）：以
/// `DetectionHygiene.enclosingAppBundle` 得到的**最外层** `.app` 为键向 `memo` 要一次，
/// 命中缓存即不再碰磁盘。这与管线归并用的键是同一个键集（实测 1082 条记录 → 75 个键）。
/// 不在任何 `.app` 内的进程（终端 CLI、守护进程）拿不到 bundle 路径 → 返回 nil，
/// 与旧写法「路径里没有 `.app/` 就不判定」一致。
public struct BundleIdentifierStrategy: AgentDetectionStrategy {
    public let name = "BundleIdentifier"

    /// 特征库的预编译视图（本策略只用 `bundleIdentifiers` 那一列）。
    private let plan = AgentSignaturePlan(AgentSignatureDatabase.shared)

    /// `.app` 包路径 → Bundle Identifier 的记忆化读取器。
    private let appBundleIDs: AppBundleIdentifierMemo

    /// - Parameter bundleIDs: 包路径 → Identifier 的记忆化读取器；默认新建一个
    ///   （`defaultStrategies` 是 `static let`，因此默认链上的这一个活到进程结束）。
    ///   测试可注入计数桩，用来钉住「同一个包一轮只读一次」。
    public init(bundleIDs: AppBundleIdentifierMemo = AppBundleIdentifierMemo()) {
        self.appBundleIDs = bundleIDs
    }

    public func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { return nil }
        // 归并口径同一个键：最外层 .app。内嵌 helper bundle（`Code Helper.app`、
        // `Codex (Renderer).app`）不再各自读一次 Info.plist。
        guard let bundlePath = DetectionHygiene.enclosingAppBundle(record.executablePath) else { return nil }
        guard let bid = appBundleIDs.identifier(forAppBundle: bundlePath) else { return nil }

        for entry in plan.entries where !entry.bundleIdentifiers.isEmpty {
            if entry.bundleIdentifiers.contains(where: {
                DetectionHygiene.matchesBundleIdentifier($0, bundleID: bid)
            }) {
                return AgentDetectionResult(kind: entry.kind, signal: .bundleIdentifier, confidence: 0.95)
            }
        }
        return nil
    }
}

// MARK: - 3. 进程名策略（processName）

/// 依据进程名（comm，≤16 字符）精确/前缀匹配判定 Agent（0.7）。
public struct ProcessNameStrategy: AgentDetectionStrategy {
    public let name = "ProcessName"

    /// 特征库的预编译视图（本策略只用已小写的 `processNames` / `processNamePrefixes`）。
    /// 旧写法每条记录要对表里每个常量名各做一次 `lowercased()`。
    private let plan = AgentSignaturePlan(AgentSignatureDatabase.shared)

    public init() {}

    public func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        let name = record.name
        guard !name.isEmpty else { return nil }
        guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { return nil }
        let lower = name.lowercased()
        for entry in plan.entries {
            if entry.processNames.contains(lower) {
                return AgentDetectionResult(kind: entry.kind, signal: .processName, confidence: 0.7)
            }
            if entry.processNamePrefixes.contains(where: { lower.hasPrefix($0) }) {
                return AgentDetectionResult(kind: entry.kind, signal: .processName, confidence: 0.7)
            }
        }
        return nil
    }
}

// MARK: - 4. 命令行参数策略（argumentSignature）

/// 依据 argv / 可执行路径中的特征字符串判定 Agent（0.72）。
/// 典型场景：`node /usr/local/bin/claude …` 这类进程名只是 `node`、
/// 但命令行带有 `claude` 特征。
///
/// 匹配落在 argv token 边界上：签名 `"cursor"` 认 token `cursor` / `cursor.app`，
/// 不认 `CursorUIViewService`（真机上它曾被裸子串判成 Cursor Agent）。
/// 可执行路径取不到时不产出——身份不能建立在猜出来的数据上。
public struct ArgumentSignatureStrategy: AgentDetectionStrategy {
    public let name = "ArgumentSignature"

    /// 特征库的预编译视图（本策略只用 `argumentSignatures` 那一列）。
    private let plan = AgentSignaturePlan(AgentSignatureDatabase.shared)

    /// `argumentSignatures` 各签名首段的词干集。本策略要对每条非系统记录的**全部 argv**
    /// 切分量（真机一轮约 1074 个 token），而其中绝大多数 token 与 Agent 词汇毫无交集——
    /// 逐 token 切分是「每-tick 检出」里最大的一笔（#55 实测 ≈15 ms/轮）。词干否证把这整段
    /// 挡在「原始串里连一个签名首段都没有」的记录之外，只对候选付切分代价。
    private let stems: DetectionHygiene.SignatureStems

    public init() {
        stems = DetectionHygiene.SignatureStems(plan.entries.flatMap(\.argumentSignatures))
    }

    public func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        guard !record.executablePath.isEmpty else { return nil }
        guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { return nil }

        let rawValues = record.arguments + [record.executablePath]
        // 快速否证：见 `SignatureStems`。必要条件是「命中的原始值必含某签名首段子串」。
        guard stems.couldMatch(in: rawValues) else { return nil }

        let values = DetectionHygiene.componentValues(of: rawValues)
        for entry in plan.entries where !entry.argumentSignatures.isEmpty {
            if entry.argumentSignatures.contains(where: { DetectionHygiene.matches($0, in: values) }) {
                return AgentDetectionResult(kind: entry.kind, signal: .argumentSignature, confidence: 0.72)
            }
        }
        return nil
    }
}

// MARK: - 5. 父子进程树策略（parentProcessTree）

/// 依据祖先链判定：若某 GUI Agent（Cursor/Windsurf/VS Code）拉起了
/// 辅助/渲染类子进程，将其归属为该 Agent（0.45）。避免把普通子进程误判。
///
/// 纯辅助进程（crashpad handler、XPC 服务、内嵌 helper bundle）不在这里成行：
/// 它们与宿主同属一个 bundle，由 `AgentDetectionPipeline` 归并进宿主身份。
public struct ParentProcessTreeStrategy: AgentDetectionStrategy {
    public let name = "ParentProcessTree"

    /// 三种 GUI Agent 的预编译匹配材料，顺序即旧实现里 `guiKinds` 的顺序
    /// （`.cursorAgent` → `.windsurf` → `.vscodeCopilot`），判定优先级因此不变。
    ///
    /// 旧写法在「每层祖先 × 每种 kind」的循环体里各做一次 `signature(for:)`
    /// 线性扫描 + 签名切分；这里在 `init` 里一次性取好并编译。
    private let guiEntries: [AgentSignaturePlan.Entry] = {
        let plan = AgentSignaturePlan(AgentSignatureDatabase.shared)
        let guiKinds: [AgentKind] = [.cursorAgent, .windsurf, .vscodeCopilot]
        return guiKinds.compactMap { plan.entry(for: $0) }
    }()

    public init() {}

    public func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { return nil }
        guard !DetectionHygiene.isPureHelperProcess(record) else { return nil }

        // 「当前进程的分量序列」对一条记录是常量：需要时算一次就复用。
        // 旧写法把它放在 3 层祖先 × 3 种 kind 的循环体内，最多重复切 9 遍。
        var recordValues: [[String]]?

        // 只看最近 3 层祖先。祖先链一路向上会撞到终端/编辑器宿主，
        // 而「某个编辑器是我进程 distant ancestor」并不代表「我是这个编辑器的 AI 助手」——
        // 那只会把编辑器里跑起来的编译进程全部误判成 Agent。
        for ancestor in context.ancestors.prefix(3) {
            let ancestorValues = DetectionHygiene.componentValues(of: [ancestor.executablePath, ancestor.name])
            let ancestorName = ancestor.name.lowercased()   // 三种 kind 共用，旧写法每种各算一次
            for entry in guiEntries {
                let matchedAncestor =
                    entry.appBundleNames.contains(where: { DetectionHygiene.matches($0, in: ancestorValues) })
                    || entry.processNames.contains(ancestorName)
                    || entry.processNamePrefixes.contains(where: { ancestorName.hasPrefix($0) })
                guard matchedAncestor else { continue }

                // 当前进程须是该 GUI 应用的子进程（同包）或辅助类进程。
                let values = recordValues
                    ?? DetectionHygiene.componentValues(of: [record.executablePath, record.name])
                recordValues = values
                let sameApp = entry.appBundleNames.contains(where: {
                    DetectionHygiene.matches($0, in: values)
                })
                if sameApp || isHelperProcess(record) {
                    return AgentDetectionResult(kind: entry.kind, signal: .parentProcessTree, confidence: 0.45)
                }
            }
        }
        return nil
    }
}

// MARK: - 6. 终端会话策略（terminalSession）

/// 依据「挂在终端 + 祖先为终端模拟器 + 命令行含 Agent 特征」判定（0.5）。
/// 作为 argumentSignature 的互补路径，信号语义明确地区分于其它策略。
///
/// 0.5 是本策略的置信度，因此它同样受「拿不到可执行路径就不产出」约束：
/// 只看 argv 的判定无法区分「Agent」与「命令行里提到了 agent 的普通进程」。
public struct TerminalSessionStrategy: AgentDetectionStrategy {
    public let name = "TerminalSession"

    /// 特征库的预编译视图（本策略只用 `argumentSignatures` 那一列）。
    private let plan = AgentSignaturePlan(AgentSignatureDatabase.shared)

    public init() {}

    public func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        guard !record.executablePath.isEmpty else { return nil }
        guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { return nil }

        // 必须挂在某个终端上，且祖先链中存在终端模拟器。
        guard record.tty != nil || !context.ancestors.isEmpty else { return nil }
        let hasTerminalAncestor = context.ancestors.contains(where: isTerminal)
        guard hasTerminalAncestor else { return nil }

        // argv 是这个策略**唯一**的证据来源：空 argv 时下面两条分支都不可能命中，
        // 因此不必再切一遍分量（分量序列为空 ⇔ 所有匹配都是 false）。
        let values = DetectionHygiene.componentValues(of: record.arguments)
        guard !values.isEmpty else { return nil }

        if let kind = specificKind(fromComponentValues: values, plan: plan) {
            return AgentDetectionResult(kind: kind, signal: .terminalSession, confidence: 0.5)
        }
        // 宽泛兜底：终端里跑的、命令行带通用 agent 关键字（仍按 token 边界）。
        if compiledGenericAgentTokens.contains(where: { DetectionHygiene.matches($0, in: values) }) {
            return AgentDetectionResult(kind: .genericCLIAgent, signal: .terminalSession, confidence: 0.5)
        }
        return nil
    }
}

// MARK: - 7. 自带脚本运行时的 .app 宿主（bundleScriptHost）

/// 依据「一个 `.app` 内的进程，把一个**位于该 bundle 之外**的 JS 入口文件当参数拉起」判定
/// 该 bundle 是一个自带插件/扩展运行时的 Agent 宿主（0.5，`genericCLIAgent`）。
///
/// 为什么要有这一条（#47，总控 2026-09-21 裁定「不能靠父进程是 Terminal」）：
/// 真机上一批正在干活的会话**不是**终端里跑的 CLI——它们的宿主是一个 GUI 应用，
/// 由 launchd 直接拉起，`ps -o tty=` 是 `??`、argv 只有可执行路径本身（argc=1）。
/// `TerminalSessionStrategy` 的两道门（祖先须含终端模拟器、argv 里须有特征 token）对这一族
/// 永远不成立，逐格实测见 `AppHostedSessionBlindSpotTests`。
///
/// 判据为什么长成这样（三条各挡一类误报，都是**结构**而不是产品名）：
///  · **自身在 `.app` 内** —— 排除 `/usr/local/bin/node /x/y/plugin.mjs` 这类已经在别的策略里
///    按签名认过的普通 node 进程，也排除任何系统路径（上面那道闸门管）。
///  · **参数里有一个 JS 入口文件**（`.js` / `.cjs` / `.mjs`，且不是 `-` 开头的开关）——
///    Electron 应用平时只把 `app.asar` 交给运行时自己加载，argv 里不会出现脚本；
///    显式把一个 JS 文件当参数拉起，是"宿主在装载外部代码"的形态。
///    真机 Xcode 那两条命中的是 `.py`（构建脚本），按 JS 收口后天然排除。
///  · **该脚本在 bundle 之外** —— 这一条挡掉"应用跑自己的引导脚本"：VS Code 的
///    `Contents/Resources/app/out/cli.js` 在包内，不算装载外部代码。
///
/// 置信度 0.5 与终端兜底同级，且**排在策略链最后**：任何具体签名都优先于它。
/// 产出的是 `genericCLIAgent`（契约里的"其他终端 Agent"）而不是某个具体产品——
/// 这一格只能说"这里有一个自带运行时的宿主在跑 Agent 负载"，说不出是谁。
///
/// ⚠️ 它解决的是"检出与命令采集"这一半；**不解决文件归因**：宿主 cwd 通常是 `/`，
/// 被 `MonitoringRootResolver.isUsableAttributionRoot` 挡掉（真机实测 `lsof -d cwd` = `/`），
/// 所以 `file_changes.agent_kind` 仍会是 `unknown`。那半件事要的是会话级工作目录，见认领板 #47 的 D。
public struct BundleScriptHostStrategy: AgentDetectionStrategy {
    public let name = "BundleScriptHost"

    /// JS 入口文件的后缀（**只认小写**）。
    ///
    /// 不做 `lowercased()`：这条策略要对每个 `.app` 内进程的每个参数走一遍（Electron 一族
    /// 动辄四十个参数），而大写后缀的入口文件真机今天没见过。宁可漏检，也不在热路径上
    /// 为它开一次分配——漏检的代价是"这一格仍报 unknown"，误报的代价是假证据。
    private static let scriptSuffixes: [String] = [".js", ".cjs", ".mjs"]

    public init() {}

    public func detect(_ record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        guard !record.executablePath.isEmpty else { return nil }
        guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { return nil }
        // 自身必须住在某个 .app 里：这条判据说的是"这个 bundle 装载了外部代码"。
        guard let bundlePath = DetectionHygiene.enclosingAppBundle(record.executablePath) else { return nil }

        for argument in record.arguments {
            guard !argument.isEmpty, !argument.hasPrefix("-") else { continue }
            guard Self.scriptSuffixes.contains(where: { argument.hasSuffix($0) }) else { continue }
            // 包内的脚本是应用自己的引导代码，不算"装载外部代码"。
            if argument.hasPrefix(bundlePath) { continue }
            return AgentDetectionResult(kind: .genericCLIAgent, signal: .argumentSignature, confidence: 0.5)
        }
        return nil
    }
}
