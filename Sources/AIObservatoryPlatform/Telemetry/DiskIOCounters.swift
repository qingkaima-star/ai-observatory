//
//  DiskIOCounters.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Telemetry
//
//  磁盘 I/O 累计量读取（IOKit）与两次采样求差求吞吐。
//  只读累计计数器，绝不 shell out 到 iostat（违反低开销原则）。
//

import Foundation
import IOKit
import AIObservatoryCore

/// 某一时刻的磁盘累计读写字节数快照（自开机以来的累计值）。
public struct DiskTotals: Sendable {
    var readBytes: UInt64
    var writeBytes: UInt64
    var timestamp: Date

    static let zero = DiskTotals(readBytes: 0, writeBytes: 0, timestamp: Date())
}

/// 通过 IOKit `IOBlockStorageDriver` 的 `Statistics` 字典读取整机磁盘累计读写字节数。
///
/// 该字典的 `"Bytes (Read)"` / `"Bytes (Write)"` 为自开机以来的累计值，
/// 两次采样求差再除以时间差即得吞吐（字节/秒）。首次无历史时速率归零。
public struct DiskIOCounters: Sendable {

    public init() {}

    /// 读取自开机以来的累计磁盘读写字节数（全卷 IOKit 汇总）。
    public func readCumulative() -> DiskTotals {
        var readTotal: UInt64 = 0
        var writeTotal: UInt64 = 0

        // IOServiceMatching 返回由调用方负责释放的字典；IOServiceGetMatchingServices
        // 内部会自行消耗该字典，无需我们再 release。
        let matching = IOServiceMatching("IOBlockStorageDriver")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return DiskTotals.zero
        }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            let kr = IORegistryEntryCreateCFProperties(service, &props, kCFAllocatorDefault, 0)
            if kr == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                // CFNumber → NSNumber → UInt64，避免与 Swift 字面量类型推断不匹配。
                if let r = (stats["Bytes (Read)"] as? NSNumber)?.uint64Value { readTotal += r }
                if let w = (stats["Bytes (Write)"] as? NSNumber)?.uint64Value { writeTotal += w }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }
        IOObjectRelease(iterator)

        return DiskTotals(readBytes: readTotal, writeBytes: writeTotal, timestamp: Date())
    }

    /// 两次累计值之差 / 时间差 → 吞吐（字节/秒）。
    /// 计数器单调递增，若当前值小于历史值（理论上不会）则按 0 处理；时间差 ≤ 0 返回 0。
    public static func rate(from previous: DiskTotals, to current: DiskTotals) -> (read: Double, write: Double) {
        let dt = current.timestamp.timeIntervalSince(previous.timestamp)
        guard dt > 0 else { return (0, 0) }
        let dr = current.readBytes >= previous.readBytes
            ? Double(current.readBytes - previous.readBytes) : 0
        let dw = current.writeBytes >= previous.writeBytes
            ? Double(current.writeBytes - previous.writeBytes) : 0
        return (dr / dt, dw / dt)
    }
}
