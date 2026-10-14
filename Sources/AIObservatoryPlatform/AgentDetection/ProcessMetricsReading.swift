//
//  ProcessMetricsReading.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-ProcScan
//  ─────────────────────────────────────────────────────────
//  「只按给定 pid 取 CPU/内存」的能力协议。
//
//  为什么要有它：`ProcessInspecting` 只有 `scanProcesses()` 这一个取数入口（跨层契约，
//  冻结区），而 `ProcessMetricsSampler.sampleProcesses(pids:)` 要的是**几个** pid 的
//  CPU% 与 RSS。用前者实现后者就得「全表重扫 ~820 个进程 × 每 pid 5 次内核调用，
//  再按 pid 过滤」——真机每 tick 因此多付约 20 ms，而它要的只有个位数的进程。
//  本能力让真实采集器直接回答「这几个 pid」，把全表扫描留给确实需要全表的调用方。
//
//  放在 Platform（而不是 `AIObservatoryCore/Contracts`）是有意的：这是平台采集器的
//  一项可选能力，不是跨层数据契约，改它不该牵动冻结区。
//

import Foundation
import AIObservatoryCore

/// 能按 pid 精确读取进程资源数值的采集器。
///
/// 实现方应当**只**为给定的 pid 付出代价；拿不到的 pid 直接不出现在结果里
/// （不要补 0 —— 0 会被下游当成「这个 Agent 真的没占 CPU」）。
public protocol ProcessMetricsReading: Sendable {

    /// 给定 pid 集合的 CPU% 与内存占用。
    ///
    /// - Parameter pids: 需要读数的进程号。空数组表示不读任何进程（返回空字典）。
    /// - Returns: pid → 采样值；取不到的 pid 不在字典里。
    func metrics(for pids: [Int32]) -> [Int32: ProcessSample]
}
