//
//  TickStageLedger.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Platform（性能收尾线 ws/perfclose）
//  ─────────────────────────────────────────────────────────
//  AGENTS §6 把「空闲 CPU < 3%」换算成「每 tick ≤ 周期 × 3% = 90 ms」之后，超标与否
//  必须是一笔**可对账的加总**：各阶段加起来要等于实测每 tick，对不上就是漏了项。
//
//  为什么已有的 `PlatformTickBreakdownTests` 不能当那笔账（两条都是硬伤）：
//   1. 它测的是**墙钟**，而 §6 的判据口径是「累计 CPU 时间差 ÷ 墙钟差」。
//      墙钟含阻塞等待，且本仓已明确「不要用墙钟当性能预算尺子」（#22 拆过一次错尺）。
//   2. 它只覆盖 `ObservatoryEngine.runTick()` 九个阶段里的五个（scan / detect /
//      inferCommands / sampleSystem / sampleProcesses 那三段合起来算 detect 与 ingest 的
//      一部分），**完全没有** storeReady、ingestAgents 与三段落库、syncProjects、prune
//      —— 而 B10 记下「app 级 396 ms/tick 而链上只拆出 ≈68 ms」那笔缺口时，缺的正是
//      没被量的那几段。拿缺项的表去减总数，造出的「无归属开销」根本不是一段真实存在的
//      工作，只是没量。
//
//  本账目的做法：**恒等式**，不是"逐项估到差不多"。
//   · 每段记的是**本进程累计 CPU 时间**（`getrusage(RUSAGE_SELF)`）在该段两端的差值；
//   · 同时记「本账目存活期间进程一共烧掉多少 CPU」；
//   · 于是 `未归属 = 进程总量 − Σ阶段` **恒成立且恒 ≥ 0**（各段互不重叠、都在窗口内）。
//     ⇒ 漏项不会被读成"达标"：它表现为一列明写着「未归属多少 ms」的余额。
//     余额大 = 有活没进账，先补项；余额 ≈ 0 = 账对上了，可以逐段动手改。
//
//  ⚠️ 三条口径限制（用数前必须知道，别把它们当第四类结论）：
//   · `RUSAGE_SELF` 记**全进程所有线程**。某段若与后台工作（批量写入线程、文件事件流、
//     界面渲染）在墙上重叠，那部分 CPU 会被记进"当时正开着的那一段"。恒等式仍成立
//     （不会加总超出真实总量），只是阶段之间的**分界偏软**。
//   · 嵌套的工作不单独入账：风险评定发生在 `ingestCommands` / `ingestPerformance` 内部，
//     因此算在父段里。要拆它得先拆生产调用结构，不在这把尺子的范围。
//   · `snapshot()` **不改状态**：中途结账时正在跑的那一段还没闭合，它会出现在
//     「未归属」里而不是它自己的阶段里。判定用的一律在 `endTick()` 之后取。
//   · 仪器自身开销按构造有界：一个 tick 固定 `boundaryCountPerTick` 次读数，
//     没有字典增长、没有 IO。这条按**调用次数**断言（见 TickStageLedgerTests），
//     不按墙钟断言——墙钟在别人的负载下不是结论。
//

import Foundation
import os   // `OSAllocatedUnfairLock` 在 `os` 模块里（同目录的 SelfProcessSampler 同口径）

/// 一个 tick 里引擎真实经过的阶段。**顺序即 `ObservatoryEngine.runTick()` 里的顺序**。
///
/// 用枚举而不是任意字符串，是为了让「有没有漏项」成为可核对的事实：
/// 账目快照保证含 `allCases` 的每一个键（没跑到的是 0），加总才是「九段之和」
/// 而不是"量到的那几段之和"。
public enum TickStage: String, CaseIterable, Sendable, Codable {
    /// 解析 Store（首 tick 含建库与迁移，之后各轮共享同一 `Task` 结果）。
    case storeReady
    /// 全表进程扫描（`proc_listpids` + 逐 pid 取数）。
    case scanProcesses
    /// Agent 识别管线（含策略链，走同一份快照回放）。
    case detectAgents
    /// 会话收口 + Agent/会话落库 + 时间线事件 + 广播。
    case ingestAgents
    /// 命令推断 + 逐条落库 + 单事件风险评定。
    case ingestCommands
    /// 整机与按 pid 采样 + 逐 Agent 落库 + 采样类风险评定。
    case ingestPerformance
    /// 项目地图聚合（有触发闸门，空闲 tick 通常为 0）。
    case syncProjects
    /// 保留期清理（默认 24 h 一次，多数 tick 为 0）。
    case prune
    /// tick 收尾：成功/失败计数与状态迁移。
    case settling
}

/// 一次快照：一笔对得上的账。
public struct TickAccount: Sendable, Equatable {

    /// 已完整跑完的 tick 数（`endTick()` 的次数）。
    public var tickCount: Int
    /// 各阶段**已闭合**的累计 CPU 毫秒。保证含 `TickStage.allCases` 的每一个键。
    public var stageCPUMilliseconds: [TickStage: Double]
    /// 各阶段被开启的次数（边界计数）。
    ///
    /// 这是"有没有漏项"的**确定性**判据：一个 tick 里每段都恰好被开启一次 ⇒
    /// 每个计数都等于 `tickCount`。少了某个 `mark()` 不会让恒等式失效（那段的 CPU
    /// 会被并进相邻段），但会让那一列的计数掉下来 ⇒ 当场红，不需要靠余额阈值猜。
    public var stageMarkCounts: [TickStage: Int]
    /// 本账目存活期间进程烧掉的 CPU 毫秒总量。
    public var processCPUMilliseconds: Double

    public init(
        tickCount: Int,
        stageCPUMilliseconds: [TickStage: Double],
        stageMarkCounts: [TickStage: Int] = [:],
        processCPUMilliseconds: Double
    ) {
        self.tickCount = tickCount
        self.stageCPUMilliseconds = stageCPUMilliseconds
        self.stageMarkCounts = stageMarkCounts
        self.processCPUMilliseconds = processCPUMilliseconds
    }

    /// 每个阶段是否都被开启了 `tickCount` 次（漏项的可见证据）。
    public var isStageCoverageComplete: Bool {
        guard tickCount > 0 else { return false }
        return TickStage.allCases.allSatisfy { (stageMarkCounts[$0] ?? 0) == tickCount }
    }

    /// 计数与 tick 数不一致的阶段（按 `TickStage` 顺序，供失败信息直接点名）。
    public var stagesWithWrongMarkCount: [TickStage] {
        TickStage.allCases.filter { (stageMarkCounts[$0] ?? 0) != tickCount }
    }

    /// 已入账（归属到某个阶段）的 CPU 毫秒。
    public var attributedCPUMilliseconds: Double {
        stageCPUMilliseconds.values.reduce(0) { $0 + $1 }
    }

    /// **未归属余额** = 进程总量 − 已入账。含"当前尚未闭合的那一段"。
    /// 负数只可能来自时钟倒退，钳到 0，并由 `isClockInconsistent` 如实报出。
    public var unattributedCPUMilliseconds: Double {
        max(0, processCPUMilliseconds - attributedCPUMilliseconds)
    }

    /// 是否出现「阶段之和 > 进程总量」——读数时钟倒退的可见证据。
    public var isClockInconsistent: Bool {
        attributedCPUMilliseconds - processCPUMilliseconds > 1e-9
    }

    /// 每 tick 的已入账 CPU 毫秒。`tickCount == 0` 时返回 0（不是 NaN，不假装量过）。
    public var attributedMSPerTick: Double {
        guard tickCount > 0 else { return 0 }
        return attributedCPUMilliseconds / Double(tickCount)
    }

    /// 每 tick 的未归属 CPU 毫秒。
    public var unattributedMSPerTick: Double {
        guard tickCount > 0 else { return 0 }
        return unattributedCPUMilliseconds / Double(tickCount)
    }

    /// 某一阶段的每-tick 毫秒。
    public func msPerTick(_ stage: TickStage) -> Double {
        guard tickCount > 0 else { return 0 }
        return (stageCPUMilliseconds[stage] ?? 0) / Double(tickCount)
    }

    /// §6 的换算：预算 = 采样周期 × 3%，单位毫秒。周期 3 s ⇒ 90 ms/tick。
    public static func budgetMSPerTick(cycleSeconds: Double) -> Double {
        max(0, cycleSeconds) * 0.03 * 1000
    }

    /// **已入账**部分是否超过 §6 的每-tick 预算。
    ///
    /// 判「这一轮到底超没超」要用 `isOverBudgetIncludingUnattributed`：只看已入账会把
    /// 漏项当成余量，而那正是本文件开头要说的那种错。
    public func isOverBudget(cycleSeconds: Double) -> Bool {
        guard tickCount > 0 else { return false }
        return attributedMSPerTick > Self.budgetMSPerTick(cycleSeconds: cycleSeconds)
    }

    /// 含未归属余额的判定：进程实测的每-tick CPU 是否超预算。
    public func isOverBudgetIncludingUnattributed(cycleSeconds: Double) -> Bool {
        guard tickCount > 0 else { return false }
        return processCPUMilliseconds / Double(tickCount)
            > Self.budgetMSPerTick(cycleSeconds: cycleSeconds)
    }
}

/// 按阶段记本进程 CPU 时间差的账本。
///
/// 线程安全（`OSAllocatedUnfairLock`），不做 IO、不分配堆内存（除字典本身的桶）。
/// 读数函数可注入 ⇒ 「九段之和等于总量」「首段不吞上一轮尾巴」「同一次结账只读这么多次」
/// 这些口径都能用**手推字面量**断言，不依赖真进程、也不依赖墙钟。
public struct TickStageLedger: Sendable {

    /// 一个 tick 内的读数边界数：`beginTick` + 8 次 `mark` + `endTick`。
    /// 这是仪器自身开销的上界（每边界一次 `getrusage`，无其它系统调用）。
    public static let boundaryCountPerTick = TickStage.allCases.count + 1

    /// 默认读数器：本进程累计 CPU 秒（用户态 + 核心态，**不含子进程**）。
    ///
    /// 单独开一个 `static func` 而不是把 `SelfProcessSampler.cpuSeconds` 直接写成默认值：
    /// 后者是 internal，Swift 不允许 public 初始化器的默认参数引用内部成员。
    public static func selfCPUSeconds() -> Double {
        SelfProcessSampler.cpuSeconds()
    }

    private struct State: Sendable {
        var startedCPUSeconds: Double?
        var openStage: TickStage?
        var openCPUSeconds: Double
        var stages: [TickStage: Double]
        var markCounts: [TickStage: Int]
        var tickCount: Int
    }

    private let lock: OSAllocatedUnfairLock<State>
    private let cpuSeconds: @Sendable () -> Double

    /// - Parameter cpuSeconds: 累计 CPU 秒读数器，默认 `SelfProcessSampler` 那条
    ///   （`getrusage(RUSAGE_SELF)`，不含子进程）；注入以便用字面量时钟做口径测试。
    public init(cpuSeconds: @escaping @Sendable () -> Double = TickStageLedger.selfCPUSeconds) {
        self.cpuSeconds = cpuSeconds
        var stages: [TickStage: Double] = [:]
        var counts: [TickStage: Int] = [:]
        for stage in TickStage.allCases {
            stages[stage] = 0
            counts[stage] = 0
        }
        self.lock = OSAllocatedUnfairLock(initialState: State(
            startedCPUSeconds: nil, openStage: nil, openCPUSeconds: 0,
            stages: stages, markCounts: counts, tickCount: 0
        ))
    }

    /// 开一个新 tick：闭合上一轮的 `settling` 段，进入 `storeReady`。
    public func beginTick() {
        advance(to: .storeReady)
    }

    /// 闭合上一段、开启 `stage` 段。
    ///
    /// 在没有开着的段时调用（漏了 `beginTick`，或上一段已被 `endTick` 闭合）：
    /// 只记录起点，**不臆造归属**——把一段 CPU 挂到一个没开过的父段上，等于凭空造阶段名。
    public func mark(_ stage: TickStage) {
        advance(to: stage)
    }

    /// 闭合 `settling` 段并计入一个完整 tick。
    public func endTick() {
        let now = cpuSeconds()
        lock.withLock { state in
            closeOpenSegment(in: &state, at: now)
            state.tickCount += 1
        }
    }

    /// 结账。**不改状态**：当前未闭合的那一段留在「未归属」里，下次闭合时才归位。
    public func snapshot() -> TickAccount {
        let now = cpuSeconds()
        return lock.withLock { state in
            let milliseconds = state.stages.mapValues { $0 * 1000 }
            let process = max(0, now - (state.startedCPUSeconds ?? now)) * 1000
            var stageMS: [TickStage: Double] = [:]
            var counts: [TickStage: Int] = [:]
            for stage in TickStage.allCases {
                stageMS[stage] = milliseconds[stage] ?? 0
                counts[stage] = state.markCounts[stage] ?? 0
            }
            return TickAccount(
                tickCount: state.tickCount,
                stageCPUMilliseconds: stageMS,
                stageMarkCounts: counts,
                processCPUMilliseconds: process
            )
        }
    }

    /// 已完整跑完的 tick 数（诊断与「一轮只结一次账」的断言用）。
    public var tickCount: Int {
        lock.withLock { $0.tickCount }
    }

    private func advance(to next: TickStage) {
        let now = cpuSeconds()
        lock.withLock { state in
            if state.startedCPUSeconds == nil { state.startedCPUSeconds = now }
            closeOpenSegment(in: &state, at: now)
            state.openStage = next
            state.markCounts[next, default: 0] += 1
        }
    }

    /// 把 `[openCPUSeconds, now]` 记进当前开着的段，并让开段状态归零。
    private func closeOpenSegment(in state: inout State, at now: Double) {
        if let open = state.openStage {
            state.stages[open, default: 0] += max(0, now - state.openCPUSeconds)
        }
        state.openStage = nil
        state.openCPUSeconds = now
    }
}
