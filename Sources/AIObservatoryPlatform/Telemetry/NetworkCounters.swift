//
//  NetworkCounters.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Telemetry / WS-Perf
//
//  整机网络累计计数器读取（getifaddrs）+ 两次采样差分求**速率**（字节/秒）。
//  按接口分别保存快照，因此「counter 回绕」与「接口消失」都能被识别出来。
//  差分是纯函数（`rate(previous:current:)`），不碰内核，可单测。
//  绝不 shell out 到 nettop / ipstate（违反低开销原则）。
//

import Foundation
import AIObservatoryCore

// MARK: - Snapshots

/// 单个网络接口某一时刻的累计收发字节数（自开机/自驱动加载以来的累计值）。
///
/// 底层 `ifi_ibytes` / `ifi_obytes` 是 32 位计数器，约每 4 GiB 回绕一次，
/// 所以「新值 < 旧值」是常态而非异常，必须显式处理。
public struct NetworkInterfaceTotals: Sendable, Hashable {
    public var inBytes: UInt64
    public var outBytes: UInt64

    public init(inBytes: UInt64, outBytes: UInt64) {
        self.inBytes = inBytes
        self.outBytes = outBytes
    }
}

/// 某一时刻的整机网络累计快照，按接口名分别保存。
///
/// 只存总量就无法区分「真的没流量」与「网卡重连导致计数器归零」——
/// 后者会让下一轮差分算出巨大的假峰值。
///
/// ## 采集范围（隐私口径，改动请同步 `Documentation/PRIVACY.md` §2.3）
/// 读的是**本机所有非回环接口**的累计收发字节数与**接口名**（`en0` / `utun3` 这类），
/// 经 `getifaddrs` 取自内核计数器：
/// - **不区分是哪个 Agent 进程发的**——macOS 没有公开的非 root 按进程网络字节 API，
///   所以这是整机量，任何把它归因到某个会话/进程的显示都是错的；
/// - 不含对端地址、端口、URL、包内容；不建立任何 socket，不产生任何网络流量；
/// - 落库位置与其余遥测相同，只在本机 `~/Library/Application Support/…` 的 SQLite 里。
public struct NetworkTotals: Sendable, Hashable {
    /// 接口名 → 累计收发；回环（lo0）与无 `ifa_data` 的接口不在此列。
    public var perInterface: [String: NetworkInterfaceTotals]
    public var timestamp: Date

    public init(perInterface: [String: NetworkInterfaceTotals], timestamp: Date) {
        self.perInterface = perInterface
        self.timestamp = timestamp
    }

    /// 自开机以来的累计接收字节数（所有非回环接口之和）。
    public var inBytes: UInt64 { perInterface.values.reduce(0) { $0 + $1.inBytes } }

    /// 自开机以来的累计发送字节数（所有非回环接口之和）。
    public var outBytes: UInt64 { perInterface.values.reduce(0) { $0 + $1.outBytes } }
}

// MARK: - Rate & outcome

/// 一次差分得到的整机网络速率，单位字节/秒。
public struct NetworkRate: Sendable, Hashable {
    public var inputBytesPerSecond: Double
    public var outputBytesPerSecond: Double

    public init(inputBytesPerSecond: Double, outputBytesPerSecond: Double) {
        self.inputBytesPerSecond = inputBytesPerSecond
        self.outputBytesPerSecond = outputBytesPerSecond
    }

    /// 收 + 发，用于单一标量（峰值/排序）场景。
    public var totalBytesPerSecond: Double { inputBytesPerSecond + outputBytesPerSecond }
}

/// 差分结果：要么有速率，要么有明确的不可得原因。
///
/// 原因直接用 Core 的 `NetworkRateAvailability`（case 名与本层判定一一对应）：
/// 再造一个同义枚举，迟早会长出「两边各有对方没有的 case」那种只在真机才暴露的缝，
/// 而且白多一层映射。
///
/// 没有 `.zero` 这种取值：零流量与采不到是两件事，混为一谈正是审计指出的缺陷。
public enum NetworkSampleOutcome: Sendable, Hashable {
    case available(NetworkRate)
    case unavailable(NetworkRateAvailability)

    public var rate: NetworkRate? {
        if case .available(let rate) = self { return rate }
        return nil
    }

    /// 拿到速率时为 `nil`，拿不到时给出可显示的原因。落库那两个可选字段就取自这里。
    public var availability: NetworkRateAvailability? {
        if case .unavailable(let reason) = self { return reason }
        return nil
    }
}

// MARK: - Reader

/// 通过 `getifaddrs` 遍历 AF_LINK 接口累加累计收发字节数，两次采样求差得速率。
public struct NetworkCounters: Sendable {

    /// 回环接口不计入整机流量。
    static let excludedInterfaces: Set<String> = ["lo0"]

    public init() {}

    /// 读取按接口拆分的累计网络字节数；读不到返回 `nil`（不返回假的全零快照）。
    public func readCumulative() -> NetworkTotals? {
        var perInterface: [String: NetworkInterfaceTotals] = [:]

        var ifa: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifa) == 0, let head = ifa else { return nil }
        defer { freeifaddrs(ifa) }

        var cursor = head
        while true {
            let entry = cursor.pointee
            // sa_family == AF_LINK 才是承载 ifi_ibytes/ifi_obytes 的接口数据。
            if let addr = entry.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) {
                let name = String(cString: entry.ifa_name)
                if !Self.excludedInterfaces.contains(name), let dataPtr = entry.ifa_data {
                    // ifa_data 是 raw 指针，实际指向 if_data 布局。
                    let data = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    let incoming = UInt64(data.ifi_ibytes)
                    let outgoing = UInt64(data.ifi_obytes)
                    // 同名接口出现多条 AF_LINK 记录时取累加中较大的一份，避免重复计数。
                    if let existing = perInterface[name] {
                        perInterface[name] = NetworkInterfaceTotals(
                            inBytes: max(existing.inBytes, incoming),
                            outBytes: max(existing.outBytes, outgoing)
                        )
                    } else {
                        perInterface[name] = NetworkInterfaceTotals(inBytes: incoming, outBytes: outgoing)
                    }
                }
            }
            guard let next = entry.ifa_next else { break }
            cursor = next
        }

        guard !perInterface.isEmpty else { return nil }
        return NetworkTotals(perInterface: perInterface, timestamp: Date())
    }

    /// 纯函数：两次累计快照 → 速率，或明确的不可得原因。
    ///
    /// 任一线上接口回退或消失，整轮判为不可信（此时只能低估或虚高，二选一都不诚实），
    /// 调用方把基线换成 `current` 后下一轮即恢复。
    public static func rate(previous: NetworkTotals?, current: NetworkTotals) -> NetworkSampleOutcome {
        guard !current.perInterface.isEmpty else { return .unavailable(.countersUnreadable) }
        guard let previous else { return .unavailable(.awaitingFirstSample) }

        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0 else { return .unavailable(.noElapsedTime) }

        for name in previous.perInterface.keys where current.perInterface[name] == nil {
            return .unavailable(.interfaceRemoved)
        }

        var deltaIn: UInt64 = 0
        var deltaOut: UInt64 = 0
        for (name, now) in current.perInterface {
            guard let before = previous.perInterface[name] else {
                // 新出现的接口本轮贡献 0 增量：它的累计值含本次窗口之前的流量，计入会虚高。
                continue
            }
            guard now.inBytes >= before.inBytes, now.outBytes >= before.outBytes else {
                return .unavailable(.counterRegression)
            }
            deltaIn += now.inBytes - before.inBytes
            deltaOut += now.outBytes - before.outBytes
        }

        return .available(NetworkRate(
            inputBytesPerSecond: Double(deltaIn) / elapsed,
            outputBytesPerSecond: Double(deltaOut) / elapsed
        ))
    }
}
