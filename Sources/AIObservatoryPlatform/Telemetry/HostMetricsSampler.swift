//
//  HostMetricsSampler.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Telemetry
//
//  整机性能采样：CPU（host_statistics 两次采样求差）、内存（host_statistics64，
//  Activity Monitor 口径）、磁盘 I/O、网络、负载均值；温度/功耗走 ThermalPowerReader
//  （本机读不到则 nil）。绝不 shell out 到 top/iostat/nettop。
//

import Foundation
import IOKit
import os
import AIObservatoryCore

/// 整机性能采样器，实现 `SystemMetricsSampling.sampleSystem()`。
///
/// CPU 百分比必须两次采样求差：本类型内部用 `OSAllocatedUnfairLock` 保存上一次的
/// `host_cpu_load_info` 快照与时间戳，单次调用无法得到百分比（无历史时返回 0，
/// 这是正确行为）。`HOST_CPU_LOAD_INFO` 的 tick 跨所有核心累加，因此整机占用百分比
/// 需除以核心数并裁剪到 0…100。
public struct HostMetricsSampler: SystemMetricsSampling {

    private let processSampler: ProcessMetricsSampler
    private let disk = DiskIOCounters()
    private let thermal = ThermalPowerReader()
    private let network = NetworkCounters()
    private let gpu = GPUActivityReader()

    /// 保存上一次采样历史，用于求差。受 unfair lock 保护以满足 Swift 6 严格并发。
    private let lock: OSAllocatedUnfairLock<SamplerState>

    public init(processInspector: any ProcessInspecting) {
        self.processSampler = ProcessMetricsSampler(inspector: processInspector)
        self.lock = OSAllocatedUnfairLock(initialState: SamplerState())
    }

    public func sampleSystem() async -> SystemPerformanceSample {
        let now = Date()
        let (cpuTotal, cpuUser, cpuSystem) = sampleCPU(now: now)
        let (memUsed, memTotal) = sampleMemory()
        let (diskRead, diskWrite) = sampleDisk(now: now)
        let load = sampleLoadAverage()
        let (thermalC, power) = thermal.read()
        let network = sampleNetworkRate()
        let gpu = sampleGPUActivityPercent()

        return SystemPerformanceSample(
            timestamp: now,
            cpuTotalPercent: cpuTotal,
            cpuSystemPercent: cpuSystem,
            cpuUserPercent: cpuUser,
            memoryUsedBytes: memUsed,
            memoryTotalBytes: memTotal,
            diskReadBytesPerSecond: diskRead,
            diskWriteBytesPerSecond: diskWrite,
            loadAverage1m: load,
            thermalCelsius: thermalC,
            powerWatts: power,
            // 速率与原因互斥：拿到速率时 availability 为 nil，反之两个速率为 nil（不是 0）。
            networkInBytesPerSecond: network.rate?.inputBytesPerSecond,
            networkOutBytesPerSecond: network.rate?.outputBytesPerSecond,
            networkAvailability: network.availability,
            gpuActivityPercent: gpu
        )
    }

    public func sampleProcesses(pids: [Int32]) async -> [Int32: ProcessSample] {
        await processSampler.sampleProcesses(pids: pids)
    }

    // MARK: - 网络 / GPU

    /// 整机网络速率（字节/秒）；本轮不可信时给出原因而不是 0。
    ///
    /// 首次调用必为 `.unavailable(.awaitingFirstSample)`——没有基线可减。
    /// 采集范围与非归因口径见 `NetworkTotals` 的类型级注释（改动要同步隐私文档）。
    public func sampleNetworkRate() -> NetworkSampleOutcome {
        guard let current = network.readCumulative() else {
            return .unavailable(.countersUnreadable)
        }
        return lock.withLock { state in
            let outcome = NetworkCounters.rate(previous: state.previousNetwork, current: current)
            // 无论本轮可信与否，基线都换成当前快照：回绕/接口消失后的下一轮即可恢复，
            // 而「读不到计数器」在上面已提前返回，不会把旧基线冲掉。
            state.previousNetwork = current
            return outcome
        }
    }

    /// 整机 GPU 活动百分比（IOAccelerator 近似值，非某个 Agent 进程）；拿不到返回 `nil`。
    public func sampleGPUActivityPercent() -> Double? {
        gpu.read()
    }

    // MARK: - CPU

    private func sampleCPU(now: Date) -> (total: Double, user: Double, system: Double) {
        // host_cpu_load_info 布局：4 个 UInt32 tick 计数器（user/system/idle/nice）。
        var cpuLoad = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &cpuLoad) { ptr in
            // host_statistics 需要 natural_t/integer_t 数组视角；按 integer_t 重绑定。
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, 0, 0) }

        let snapshot = CPULoadSnapshot(
            user: cpuLoad.cpu_ticks.0,
            system: cpuLoad.cpu_ticks.1,
            idle: cpuLoad.cpu_ticks.2,
            nice: cpuLoad.cpu_ticks.3
        )

        return lock.withLock { state -> (Double, Double, Double) in
            guard let prev = state.previousCPULoad, let prevTime = state.previousTimestamp else {
                // 无历史 → 首次采样，正确返回 0。
                state.previousCPULoad = snapshot
                state.previousTimestamp = now
                return (0, 0, 0)
            }
            let elapsed = now.timeIntervalSince(prevTime)
            state.previousCPULoad = snapshot
            state.previousTimestamp = now
            guard elapsed > 0 else { return (0, 0, 0) }

            // tick 计数器单调递增，转 Int64 做差避免 UInt 回绕。
            let dUser = Double(Int64(snapshot.user) - Int64(prev.user))
            let dSystem = Double(Int64(snapshot.system) - Int64(prev.system))
            let dIdle = Double(Int64(snapshot.idle) - Int64(prev.idle))
            let dNice = Double(Int64(snapshot.nice) - Int64(prev.nice))
            let totalTicks = dUser + dSystem + dIdle + dNice
            guard totalTicks > 0 else { return (0, 0, 0) }

            let ticksPerSec = Double(sysconf(_SC_CLK_TCK))
            let coreCount = Double(max(1, ProcessInfo.processInfo.processorCount))
            // 容量 = ticks/秒 × 时长 × 核心数；busy 占比即整机占用百分比。
            let capacity = ticksPerSec * elapsed * coreCount
            let busy = dUser + dSystem + dNice
            let total = clamp((busy / capacity) * 100)
            let user = clamp((dUser / capacity) * 100)
            let system = clamp((dSystem / capacity) * 100)
            return (total, user, system)
        }
    }

    // MARK: - Memory

    private func sampleMemory() -> (used: UInt64, total: UInt64) {
        // memoryTotalBytes 直接用 ProcessInfo 交叉验证本机物理内存。
        let total = ProcessInfo.processInfo.physicalMemory

        var vmStats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &vmStats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return (0, total) }

        // Activity Monitor 口径：已用 = active + wired + compressed，乘页大小。
        // vm_statistics64 字段名：wire_count（wired）、compressor_page_count（compressed）。
        // 页大小用 sysconf(_SC_PAGESIZE) 读取，避免直接访问并发不安全的全局 var。
        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        let used = (UInt64(vmStats.active_count) + UInt64(vmStats.wire_count) + UInt64(vmStats.compressor_page_count)) * pageSize
        return (used, total)
    }

    // MARK: - Disk

    private func sampleDisk(now: Date) -> (read: Double, write: Double) {
        let current = disk.readCumulative()
        return lock.withLock { state -> (Double, Double) in
            guard let prev = state.previousDisk else {
                state.previousDisk = current
                return (0, 0)
            }
            state.previousDisk = current
            return DiskIOCounters.rate(from: prev, to: current)
        }
    }

    // MARK: - Load average

    private func sampleLoadAverage() -> Double {
        var la = [Double](repeating: 0, count: 3)
        getloadavg(&la, 3)
        return la[0]
    }

    private func clamp(_ value: Double) -> Double {
        min(max(value, 0), 100)
    }
}

/// 上一次 CPU tick 快照（Sendable：仅含 UInt32 原始值）。
private struct CPULoadSnapshot: Sendable {
    var user: UInt32
    var system: UInt32
    var idle: UInt32
    var nice: UInt32
}

/// 采样器内部可变状态（Sendable：所有字段均为值类型）。
private struct SamplerState: Sendable {
    var previousCPULoad: CPULoadSnapshot?
    var previousDisk: DiskTotals?
    var previousNetwork: NetworkTotals?
    var previousTimestamp: Date?
}
