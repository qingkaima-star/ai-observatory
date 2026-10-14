//
//  GPUActivityReader.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Perf
//
//  整机 GPU 活动近似值：IOAccelerator 注册表的 `PerformanceStatistics` 字典。
//  macOS 没有公开的**按进程** GPU 占用 API，因此本读取只能代表整机。
//  读不到一律 nil——0% 与「这台机器给不出 GPU 活动」是两件事，绝不混用。
//  绝不 shell out 到 powermetrics（需要 root，且违反低开销原则）。
//

import Foundation
import IOKit
import AIObservatoryCore

/// 通过 `IOServiceMatching("IOAccelerator")` 读整机 GPU 活动百分比。
///
/// 本机（Apple Silicon，AGX 驱动）实测可读的键是
/// `PerformanceStatistics["Device Utilization %"]`（工单里写的「GPU Activity Level」
/// 是 Intel/AMD 驱动的说法，这台机器上没有这个键）。取值语义：
/// - **整机** GPU 设备繁忙度近似值，0…100，无法归因到某个 Agent 进程；
/// - 由显卡驱动自行维护，采样间隔越短抖动越大；
/// - 读不到（无 IOAccelerator 节点 / 无该键 / 越界）⇒ `nil`。
public struct GPUActivityReader: Sendable {

    /// `PerformanceStatistics` 里代表整机 GPU 繁忙度的键名。
    static let statisticKey = "Device Utilization %"

    public init() {}

    /// 读取整机 GPU 活动百分比；这台机器给不出时返回 `nil`（调用方须显示「不可得」而非 0%）。
    public func read() -> Double? {
        let matching = IOServiceMatching("IOAccelerator")
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }

        var properties: [[String: Any]] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            var dict: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &dict, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let node = dict?.takeRetainedValue() as? [String: Any] {
                properties.append(node)
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iterator)
        }

        return Self.activityPercent(from: properties)
    }

    /// 纯函数：从若干 IOAccelerator 节点属性里取第一个可用的整机 GPU 活动值。
    ///
    /// 与内核解耦，因此「键缺失 / 类型不对 / 越界 / 多节点只有一台有值」都能在单测里构造。
    public static func activityPercent(from nodes: [[String: Any]]) -> Double? {
        for node in nodes {
            guard let stats = node["PerformanceStatistics"] as? [String: Any],
                  let raw = stats[statisticKey] as? NSNumber else { continue }
            let value = raw.doubleValue
            // 越界说明这不是百分比（或驱动给了垃圾），换下一个节点，不裁剪成 0/100 冒充读数。
            guard value >= 0, value <= 100 else { continue }
            return value
        }
        return nil
    }
}
