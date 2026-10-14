//
//  AgentDetectionPipeline.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Agent / WS-Platform
//  ─────────────────────────────────────────────────────────
//  实现 `AgentDetecting`：串联多条检测策略，输出可被 Engine 直接消费的
//  `AgentInstance` 列表。每个实例都携带「凭什么认定它是 Agent」的
//  `detectedVia` 信号与它的全部子孙进程 `childPIDs`。
//
//  归并口径（WS-Detect）：**一个 `.app` bundle = 一个 Agent 身份**。
//  ChatGPT/Codex 桌面会话在 bundle 里放了 `Codex (Service).app`、`Codex (Renderer).app`、
//  `browser_crashpad_handler` 等十余个进程，逐进程成行会让 Session 列表、项目地图、
//  导出报告按十几倍虚高。不在任何 bundle 内的终端 CLI 进程**不被归并**——
//  每次 `claude` / `codex` 调用本身就是一次独立会话。
//
//  性能口径（WS-Platform 2026-09-20）：逐记录循环里**只算一次**系统进程闸门，
//  命中即跳过整条策略链与祖先链回溯（七条策略各自的前两行里都有同一句闸门，
//  跳过对系统路径进程是行为等价的）；每条记录的**最外层** `.app` 也只算一次，
//  归并的两个循环复用同一份结果。
//

import Foundation
import AIObservatoryCore

/// Agent 检测管线：把「进程快照 → 策略链 → AgentInstance」串起来。
public struct AgentDetectionPipeline: AgentDetecting {

    /// 策略链，按置信度从高到低排列。命中即返回（首命中优先）。
    public let strategies: [any AgentDetectionStrategy]

    /// 实时的 EndpointSecurity 能力探测器。
    private let esMonitor: EndpointSecurityMonitor.Type

    /// 使用默认策略链初始化。
    public init() {
        self.strategies = AgentDetectionPipeline.defaultStrategies
        self.esMonitor = EndpointSecurityMonitor.self
    }

    /// 注入策略链与 ES 监视器（便于测试）。
    ///
    /// - Parameters:
    ///   - strategies: 自定义策略链。
    ///   - esMonitor: ES 能力探测类型（测试可注入桩）。
    public init(
        strategies: [any AgentDetectionStrategy],
        esMonitor: EndpointSecurityMonitor.Type = EndpointSecurityMonitor.self
    ) {
        self.strategies = strategies
        self.esMonitor = esMonitor
    }

    /// 默认策略链（顺序即优先级）。
    ///
    /// - Note: 这是 `static let`，因此链上 `BundleIdentifierStrategy` 默认自带的那个
    ///   `AppBundleIdentifierMemo` 与进程同寿——`BundleIdentifierStrategy(bundleIDs:)`
    ///   走的是 init 注入，不是隐藏的单例；要独立计量或换桩就从这儿传进来。
    public static let defaultStrategies: [any AgentDetectionStrategy] = [
        ExecutablePathStrategy(),
        BundleIdentifierStrategy(),
        ProcessNameStrategy(),
        ArgumentSignatureStrategy(),
        ParentProcessTreeStrategy(),
        TerminalSessionStrategy(),
        // 最后一条：它只说"这里有一个装载外部脚本的宿主"，任何具体签名都必须先于它命中。
        BundleScriptHostStrategy()
    ]

    // MARK: - AgentDetecting

    /// 扫描并返回当前所有 Agent 实例。
    ///
    /// - Parameter processSource: 任意 `ProcessInspecting` 实现（真实或桩）。
    /// - Returns: 识别到的 `AgentInstance` 数组（无重复 pid，且**同一 `.app` bundle 只有一行**）。
    public func detectAgents(using processSource: any ProcessInspecting) async -> [AgentInstance] {
        let records = await processSource.scanProcesses()
        guard !records.isEmpty else { return [] }

        // 整轮只建一份父子索引：以前每条记录各建一次，828 pid 时是 176 ms/轮的空转。
        let tree = ProcessTreeIndex(records: records)

        // 1) 逐条走策略链。这里只记「哪些进程被检出、凭什么」，还不产出实例。
        var detections: [Int32: AgentDetectionResult] = [:]
        detections.reserveCapacity(records.count)
        for record in records {
            // **系统进程闸门整链只算一次**（WS-Platform 2026-09-20）。
            //
            // 依据：七条策略 `detect` 的前几件事里都含同一句
            // `guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { return nil }`
            // ——DetectionStrategies.swift 里逐条可核（本版本行号）：ExecutablePath 113、
            // BundleIdentifier 157、ProcessName 189、ArgumentSignature 222、ParentProcessTree 258、
            // TerminalSession 311、BundleScriptHost 376，且都以同一个 `record.executablePath` 为入参。
            // 所以命中闸门的记录**必然**七条都给 nil，跳过整链行为等价。那七句 guard 一条都不删：
            // 单条策略被直接调用时（单测 / 外部复用）语义必须与整条链一致。
            // 祖先链回溯也放在闸门之后：被跳过的记录连 `ancestors(of:)` 的数组都不必造。
            //
            // 边界：闸门只管「被检出的进程」自身。`TerminalSessionStrategy` /
            // `ParentProcessTreeStrategy` 判的是**祖先**是不是终端 / GUI 宿主，那是环境证据，
            // 不属于闸门范围——这里只 gate `record`，绝不 gate `ancestors`。
            guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { continue }

            let ancestors = tree.ancestors(of: record.pid)
            let context = DetectionContext(ancestors: ancestors)
            if let result = runStrategies(record: record, context: context) {
                detections[record.pid] = result
            }
        }
        guard !detections.isEmpty else { return [] }

        // 2) 一个 bundle 一个身份：把全快照按**最外层** `.app` 预先分组，
        //    组内成员包括那些自己没被检出的进程（App 主进程、renderer、crashpad…）——
        //    它们同属这个 Agent，构成它的 pid 集合与身份锚点。
        //    bundle 路径与 records 下标对齐，算一次供步骤 2、3 复用（旧写法两个循环各切一遍）。
        let bundlePaths: [String?] = records.map { DetectionHygiene.enclosingAppBundle($0.executablePath) }

        var membersOfBundle: [String: [ProcessRecord]] = [:]
        for (index, record) in records.enumerated() {
            guard let bundle = bundlePaths[index] else { continue }
            membersOfBundle[bundle, default: []].append(record)
        }

        // 3) 按扫描顺序产出：bundle 的**第一个**被检出成员触发该 bundle 的唯一一行，
        //    其余同 bundle 成员不再成行；不在任何 bundle 内的进程（终端 CLI）各自成行。
        var instances: [AgentInstance] = []
        var emittedBundles = Set<String>()
        for (index, record) in records.enumerated() {
            guard let result = detections[record.pid] else { continue }
            if let bundle = bundlePaths[index] {
                guard !emittedBundles.contains(bundle) else { continue }
                emittedBundles.insert(bundle)
                let members = membersOfBundle[bundle] ?? [record]
                instances.append(
                    bundleInstance(
                        bundlePath: bundle,
                        members: members,
                        detections: detections,
                        fallbackSubject: (record, result),
                        tree: tree
                    )
                )
            } else {
                instances.append(standaloneInstance(record: record, result: result, tree: tree))
            }
        }
        return instances
    }

    /// 当前是否具备 EndpointSecurity 级别的实时能力。
    ///
    /// 受限于 entitlement，绝大多数情况下返回 `.processPolling`（优雅降级）。
    public func realtimeCapability() -> RealtimeCapability {
        esMonitor.probeCapability()
    }

    // MARK: - 内部

    /// 按策略链顺序运行，返回首个命中的结果。
    private func runStrategies(record: ProcessRecord, context: DetectionContext) -> AgentDetectionResult? {
        for strategy in strategies {
            if let result = strategy.detect(record, context: context) {
                return result
            }
        }
        return nil
    }

    /// 终端里跑的 CLI：一进程一身份。
    ///
    /// 它不在任何 `.app` 内，因此**不参与归并**——每次 `claude` 调用都是独立的一次 Agent 会话，
    /// 归并会把真在跑命令的 CLI 子进程一起吞掉（工单明确禁止的那种做法）。
    private func standaloneInstance(
        record: ProcessRecord,
        result: AgentDetectionResult,
        tree: ProcessTreeIndex
    ) -> AgentInstance {
        AgentInstance(
            id: AgentIdentity.id(pid: record.pid, startedAt: record.startTime),
            kind: result.kind,
            pid: record.pid,
            parentPID: record.parentPID,
            displayName: result.displayName,
            executablePath: record.executablePath,
            workingDirectory: record.workingDirectory,
            bundleIdentifier: nil,
            tty: record.tty,
            startedAt: record.startTime ?? Date(),
            lastSeenAt: Date(),
            state: .running,
            cpuPercent: record.cpuPercent,
            memoryBytes: record.memoryBytes,
            childPIDs: tree.descendantPIDs(of: record.pid),
            detectedVia: result.signal
        )
    }

    /// 同一个 `.app` bundle 的**唯一**一行。
    ///
    /// 三份材料各自选主，理由不同：
    ///  · 身份（`id`）= bundle 路径 + **最早启动的成员**（App 本体）。运行时进程会被反复重拉，
    ///    身份若跟着它走，每轮扫描都会「结算旧会话 + 开新会话」，虚高换个形式回来。
    ///  · 展示内容（pid / 可执行路径 / tty / 资源）= **组内置信度最高的被检出进程**。
    ///    行要说清「凭哪个进程认定这是 Agent」，App 主进程本身往往不含任何 Agent 特征。
    ///  · 工作目录优先取被检出进程（GUI 主进程的 cwd 通常是 `/`，会让模块③的监控根推导落空），
    ///    取不到再退回组内第一个有 cwd 的成员。
    private func bundleInstance(
        bundlePath: String,
        members: [ProcessRecord],
        detections: [Int32: AgentDetectionResult],
        fallbackSubject: (record: ProcessRecord, result: AgentDetectionResult),
        tree: ProcessTreeIndex
    ) -> AgentInstance {
        let anchor = Self.bundleAnchor(in: members)
        let (subject, result) = Self.strongestDetection(in: members, detections: detections) ?? fallbackSubject

        var pids = Set(members.map(\.pid))
        pids.formUnion(tree.descendantPIDs(of: subject.pid))
        pids.formUnion(tree.descendantPIDs(of: anchor.pid))
        pids.remove(subject.pid)

        return AgentInstance(
            id: AgentIdentity.bundleID(bundlePath: bundlePath, anchorPID: anchor.pid, startedAt: anchor.startTime),
            kind: result.kind,
            pid: subject.pid,
            parentPID: subject.parentPID,
            displayName: result.displayName,
            executablePath: subject.executablePath,
            workingDirectory: subject.workingDirectory ?? Self.firstWorkingDirectory(in: members),
            bundleIdentifier: nil,
            tty: subject.tty,
            startedAt: anchor.startTime ?? subject.startTime ?? Date(),
            lastSeenAt: Date(),
            state: .running,
            cpuPercent: subject.cpuPercent,
            memoryBytes: subject.memoryBytes,
            childPIDs: pids.sorted(),
            detectedVia: result.signal
        )
    }

    /// bundle 的身份锚点：非纯辅助进程优先，其次启动时刻最早，最后按 pid 定序（可复现）。
    private static func bundleAnchor(in members: [ProcessRecord]) -> ProcessRecord {
        func rank(_ record: ProcessRecord) -> (helper: Int, start: Date, pid: Int32) {
            (DetectionHygiene.isPureHelperProcess(record) ? 1 : 0, record.startTime ?? .distantFuture, record.pid)
        }
        return members.min { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            if l.helper != r.helper { return l.helper < r.helper }
            if l.start != r.start { return l.start < r.start }
            return l.pid < r.pid
        } ?? members[0]
    }

    /// 组内置信度最高的被检出成员；并列时取扫描顺序里的第一个（可复现）。
    private static func strongestDetection(
        in members: [ProcessRecord],
        detections: [Int32: AgentDetectionResult]
    ) -> (record: ProcessRecord, result: AgentDetectionResult)? {
        var best: (record: ProcessRecord, result: AgentDetectionResult)?
        for member in members {
            guard let result = detections[member.pid] else { continue }
            if best == nil || result.confidence > best!.result.confidence { best = (member, result) }
        }
        return best
    }

    private static func firstWorkingDirectory(in members: [ProcessRecord]) -> String? {
        members.compactMap(\.workingDirectory).first { !$0.isEmpty }
    }
}
