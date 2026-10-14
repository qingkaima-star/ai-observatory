//
//  SelfProcessSampler.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: 总控（#29：把 AiX 自己接成被观测进程）
//  ─────────────────────────────────────────────────────────
//  为什么需要这个文件：性能页现在明写着「界面当前没有测量自身开销，这里只给目标值」
//  （见 `AIObservatoryUI/Performance/PerformanceSummaryGrid.swift:98`）。
//  于是判据④ 的 3% / 200 MB **只能靠外部工具量**（`footprint -p` / `vmmap --summary` /
//  `ps -o time=`），用户无法自查，验收每次都要重搭仪器。而本进程自己的数字恰恰是最容易读的：
//  不需要 root、不需要特批 entitlement，`task_info` 与 `getrusage` 都在本进程地址空间里。
//
//  ⚠️ 两条口径必须钉住，否则这个读数会被用错（都是本项目踩过的坑）：
//
//  1. **内存取 `phys_footprint`，不是 RSS。**
//     `ps -o rss` 把多进程共享的只读框架页全记在本进程头上——实测同一时刻
//     RSS **189.6 MB** 而 `phys_footprint` 只有 **88.8 MB**（vmmap 里光
//     `ReadOnly portion of Libraries` 就 resident 620 MB）。
//     判据④ 说的是"本 App 常驻多少"，那些共享页我们退出后照样在。见 ADR-0009 裁定 1。
//
//  2. **CPU 必须"两次读数求差 ÷ 墙钟差"，单次读数没有意义。**
//     `getrusage` 给的是**累计** CPU 秒；`ps -o %cpu` 那种衰减平均会在 0.0–17.1% 之间乱跳。
//     所以这里只提供 `cpuPercent(from:to:)` 这个纯函数，由调用方决定窗口
//     （判据④ 的口径是窗口 ≥180 s，见 AGENTS.md §6）。
//     `RUSAGE_SELF` 只算**本进程**，不含子进程——与"本 App 自己花了多少"这个问题一致；
//     要进程树合计是另一码事（那是 #23 给被观测 Agent 定的口径），不要混用。
//

import Foundation
import Darwin
import os   // `OSAllocatedUnfairLock` 在 `os` 模块里（同目录的 HostMetricsSampler 也是这么引的）

/// 本进程的一次资源读数。
public struct SelfProcessReading: Sendable, Equatable, Codable {
    /// `task_vm_info.phys_footprint`（字节）。Apple 的"常驻"口径，**不是** RSS。
    public var footprintBytes: UInt64
    /// 本进程累计 CPU 时间（用户态 + 核心态，秒）。是**累计值**，必须求差才是占用率。
    public var cpuSeconds: Double
    /// 读数时刻（同时充当差值计算的分母基准）。
    public var takenAt: Date

    public init(footprintBytes: UInt64, cpuSeconds: Double, takenAt: Date) {
        self.footprintBytes = footprintBytes
        self.cpuSeconds = cpuSeconds
        self.takenAt = takenAt
    }

    public var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
}

/// 读自己。全部调用都在本进程内，无特权、无 IO、无分配热点（一次 `task_info` + 一次 `getrusage`）。
public struct SelfProcessSampler: Sendable {

    /// 上一次读数，用来算"进程存活期内的峰值 footprint"。
    /// 用 `OSAllocatedUnfairLock`（AGENTS.md §5 的共享可变状态口径）而不是 actor：
    /// 调用点在采样循环里，不希望为一次读数挂一个 await。
    private let state = OSAllocatedUnfairLock(initialState: State())

    private struct State {
        var peakFootprintBytes: UInt64 = 0
    }

    public init() {}

    /// 采一次。失败（理论上只在 flavor 不被支持时发生）时返回 0 读数而**不崩**——
    /// 观测器不能因为读不到自己的数字就把自己弄挂。
    public func sample(now: Date = Date()) -> SelfProcessReading {
        let reading = SelfProcessReading(
            footprintBytes: Self.footprintBytes(),
            cpuSeconds: Self.cpuSeconds(),
            takenAt: now
        )
        state.withLock { s in
            if reading.footprintBytes > s.peakFootprintBytes { s.peakFootprintBytes = reading.footprintBytes }
        }
        return reading
    }

    /// 自本采样器启动以来的最大 footprint。
    /// 为什么要单独报：实测 60 s 采样的 `max(样本)` 会**漏掉采样间隙的峰值**
    /// （九页扫描里稳态 76–120 MB 而 peak 188–210 MB），判据必须同时看到两者。
    public func peakFootprintBytes() -> UInt64 {
        state.withLock { $0.peakFootprintBytes }
    }

    // MARK: 底层读数

    /// `task_info(TASK_VM_INFO)` 里的 `phys_footprint`。
    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { words in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), words, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(truncatingIfNeeded: info.phys_footprint)
    }

    /// `getrusage(RUSAGE_SELF)`：本进程累计的用户态 + 核心态 CPU 秒（不含子进程）。
    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return timeInterval(usage.ru_utime) + timeInterval(usage.ru_stime)
    }

    private static func timeInterval(_ value: timeval) -> Double {
        Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
    }

    // MARK: 派生量（纯函数，便于测试）

    /// 两次读数之间的 CPU 占用率（%）。
    ///
    /// 分母是**墙钟差**，所以：
    /// - 时间没前进（同一时刻两次读数）⇒ 返回 0，而不是除零；
    /// - 累计 CPU 倒退（理论上不该发生）⇒ 返回 0，不产生负占用率。
    public static func cpuPercent(from previous: SelfProcessReading, to next: SelfProcessReading) -> Double {
        let wall = next.takenAt.timeIntervalSince(previous.takenAt)
        guard wall > 0 else { return 0 }
        let cpu = next.cpuSeconds - previous.cpuSeconds
        guard cpu > 0 else { return 0 }
        return cpu / wall * 100
    }

    /// 相对 200 MB 上限的余量（%）。正数=还有余量，负数=已超。
    /// 上限取 200 MB（AGENTS.md §6 的硬指标；目标值 120 MB 由调用方自己标）。
    public static func headroomPercent(footprintBytes: UInt64, limitMB: Double = 200) -> Double {
        let limitBytes = limitMB * 1_048_576
        guard limitBytes > 0 else { return 0 }
        return (limitBytes - Double(footprintBytes)) / limitBytes * 100
    }
}
