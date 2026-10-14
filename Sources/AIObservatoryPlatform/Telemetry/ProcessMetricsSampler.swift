//
//  ProcessMetricsSampler.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Telemetry
//
//  进程级性能采样。复用注入的 `ProcessInspecting`（来自 WS-Agent 的进程枚举），
//  不在此自行实现一套 libproc 枚举，避免与 WS-Agent 重复。
//

import Foundation
import AIObservatoryCore

/// 针对指定 PID 集合的进程级采样器。
///
/// 采集器若具备 `ProcessMetricsReading` 能力就按 pid 精确取数；否则退回
/// `ProcessInspecting.scanProcesses()` 全表快照再按 PID 过滤（老口径，语义不变）。
/// 空集合表示采样全部进程。
public struct ProcessMetricsSampler: Sendable {

    private let inspector: any ProcessInspecting

    public init(inspector: any ProcessInspecting) {
        self.inspector = inspector
    }

    /// 采样给定 PID 集合的 CPU% 与内存占用；空集合表示采样全部进程。
    public func sampleProcesses(pids: [Int32]) async -> [Int32: ProcessSample] {
        // 只要这几个 pid 却走全表，代价是整机 ~820 个进程各 5 次内核调用（其中 argv 那一项
        // 会把全机 argv+envp 复制 ~550 KiB）。真实采集器实现了 `ProcessMetricsReading`，
        // 于是这条只在桩/第三方采集器上走到。
        // `pids` 为空是契约里的「采样全部」，那次全表是必须的，不能省。
        if !pids.isEmpty, let reader = inspector as? any ProcessMetricsReading {
            return reader.metrics(for: pids)
        }
        let records = await inspector.scanProcesses()
        let wanted = Set(pids)
        var result: [Int32: ProcessSample] = [:]
        for record in records where wanted.isEmpty || wanted.contains(record.pid) {
            result[record.pid] = ProcessSample(
                pid: record.pid,
                cpuPercent: record.cpuPercent,
                memoryBytes: record.memoryBytes
            )
        }
        return result
    }
}
