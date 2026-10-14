//
//  ThermalPowerReader.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Telemetry
//  ─────────────────────────────────────────────────────────
//  温度/功耗读取。本机为 Apple Silicon（M 系列），SMC key 与 Intel 不同，
//  且系统级功耗没有公开 API。
//  ⚠️ 严禁伪造：任何一项拿不到就返回 nil，绝不以估算值填充。
//
//  功耗：macOS 没有公开的整机功耗 API（`IOPMCopyPowerSourceInfo` 只有电池/适配器的
//  Voltage/Amperage 一类），所以**恒返回 nil**。这不是"这次没读到"，是这台机器读不到。
//
//  温度：本实现走 `IORegistryEntryCreateCFProperty(AppleSMC, "TC0C"…)`。
//  2026-09-20 实测把口径钉死（`ioreg -l -n AppleSMC | grep -c '"TC0C"'` 等七个候选键
//  **命中全为 0**）：SMC 的键值不在 IORegistry 属性里，要走 `AppleSMCClient` 的
//  user client（`IOConnectCallMethod` + kSMCReadKey 选择子，键与值是打包结构体，
//  且多数键返回 `AppleSMC` 私有的 `data` 而非 `NSNumber`）。
//  ⇒ 也就是说这条通道**恒取不到温度**，而旧实现每 tick 为此付
//  1 次 `IOServiceGetMatchingService` + 7 次注定为 NULL 的 `IORegistryEntryCreateCFProperty`
//  + 1 次 `IOObjectRelease`（9 个系统调用，零产出）。AGENTS §6 的合法杠杆之一就是"少做 syscall"。
//
//  改法：**只探一次**。
//   · 首轮把候选键走一遍；全空 ⇒ 记住"此通道本机不可得"，之后**一次 IOKit 都不调**；
//   · 命中某键 ⇒ 记住那个键，并且**每轮重读**（温度是随时间变的量，
//     缓存一个温度值等于把上一轮的读数当这一轮的报——那才是撒谎）。
//   · 换机器/换系统版本不需要重启进程之外的动作：探测状态只影响"要不要再试"，
//     不影响"试到的值是不是当前的"。
//

import Foundation
import IOKit
import os
import AIObservatoryCore

/// 尝试读取整机温度(°C)与功耗(W)。
///
/// - 温度：见文件头——当前通道在本机恒不可得，故实际恒 `nil`；探测结果按进程缓存一次。
/// - 功耗：固定 `nil`，**禁止编造**。
public struct ThermalPowerReader: Sendable {

    /// 候选 SMC 温度键（Intel 机型常见 + Apple Silicon 上曾出现过的两个）。
    static let candidateTemperatureKeys = ["TC0C", "TC0D", "TC0E", "Tp01", "Tp09", "Te05", "Tm02"]

    /// 探测结果。`probedKey` 命中时每轮重读该键；`channelHasNoKeys` 后不再调 IORegistry。
    private struct ProbeState: Sendable {
        /// 已命中、每轮要重读的键；`nil` = 尚未探测或未命中。
        var probedKey: String?
        /// 已经把所有候选键试过一遍且全空 ⇒ 本机此通道不可得。
        var channelHasNoKeys = false
    }

    private let state = OSAllocatedUnfairLock(initialState: ProbeState())
    /// 单键读取，注入以便在单测里按**调用次数**断言"第二次不再试"（不靠墙钟）。
    private let readKey: @Sendable (String) -> Double?

    public init() {
        self.readKey = ThermalPowerReader.ioRegistryKey
    }

    /// 注入版：`readKey` 给一个键返回其温度（`nil` = 取不到）。
    /// 只给用例用——生产入口是 `init()`，它绑的是真实的 IORegistry 通道。
    init(readKey: @escaping @Sendable (String) -> Double?) {
        self.readKey = readKey
    }

    /// 读取 `(thermalCelsius, powerWatts)`；读不到的项为 `nil`。
    public func read() -> (thermalCelsius: Double?, powerWatts: Double?) {
        return (thermalCelsius: readTemperature(), powerWatts: nil)
    }

    /// 当前状态是否为「此通道本机不可得」（诊断与用例断言用）。
    public var temperatureChannelUnavailable: Bool {
        state.withLock { $0.channelHasNoKeys }
    }

    private func readTemperature() -> Double? {
        let known = state.withLock { $0 }
        if known.channelHasNoKeys { return nil }
        // 已命中过：每轮重读同一个键。温度是随时间变的量，缓存它的值等于拿上一轮的
        // 读数冒充这一轮 ⇒ 只缓存"哪个键有值"，不缓存值。
        if let key = known.probedKey { return readKey(key) }

        var hit: (key: String, value: Double)?
        for key in Self.candidateTemperatureKeys {
            guard let value = readKey(key), value.isFinite else { continue }
            hit = (key, value)
            break
        }
        let hitKey = hit?.key
        state.withLock { s in
            if let hitKey { s.probedKey = hitKey } else { s.channelHasNoKeys = true }
        }
        // 两个线程同时落在"还没探过"的窗口里，各多付一轮候选键读取——
        // 上界是一轮 7 次，且只在进程生命周期开始时可能发生一次，不为它加锁外的复杂度。
        return hit?.value
    }

    /// 真实通道：IORegistry 属性读取。
    ///
    /// ⚠️ 这条通道在 Apple Silicon 上取不到 SMC 键（见文件头）。留着它是因为
    /// 它在**某些 Intel 机型**上确实能拿到部分 `TC0x`，届时探测会命中并自动转为每轮重读。
    private static func ioRegistryKey(_ key: String) -> Double? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let raw = IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)
        else { return nil }
        // IORegistryEntryCreateCFProperty 的返回值带 +1 引用，takeRetainedValue 平衡。
        let value = raw.takeRetainedValue()
        // SMC 温度值以 °C 形式存储（CFNumber / float），直接取 double。
        return (value as? NSNumber)?.doubleValue
    }
}
