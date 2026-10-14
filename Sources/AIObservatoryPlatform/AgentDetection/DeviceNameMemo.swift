//
//  DeviceNameMemo.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Platform
//  ─────────────────────────────────────────────────────────
//  「终端设备号 → `/dev` 字符设备名」的记忆化解析。
//
//  为什么要有它：`LibprocProcessInspector.inspect` 对每条带 tty 的进程记录调一次
//  `devname(e_tdev, S_IFCHR)`，而 1ms 采样实测它的叶帧是 **`lstat`**——
//  `devname_r` 会去遍历设备表解析符号链接。真机一个 tick 里这类解析占全进程在算时间的
//  约 9%（90 / 1034 条采样），是「全表扫描」那一段里第三贵的单项。
//
//  而设备号到名字的映射是**整机的属性，不是进程的属性**：一次开机期间它就那么多条目，
//  几百条记录反复解析的其实是同一个数。按设备号记忆化后，一轮最多付一次真解析。
//

import Foundation
import os.lock

/// 设备号 → 终端设备名的记忆化解析器。
///
/// 可注入 `resolver`，所以「同一个设备号一轮只解析一次」这条不依赖真机进程表就能单测。
struct DeviceNameMemo: Sendable {

    /// 默认解析器：`devname`，会去遍历设备表并解析符号链接（实测叶帧落在 `lstat`），
    /// 这正是被记忆化掉的那部分成本。沿用采集链既有的同一个调用点，不换语义。
    ///
    /// ⚠️ `devname` 返回的是**静态缓冲**，本就非线程安全；这里立刻拷出字节，并且记忆化把
    /// 一个 tick 里的调用次数从「每条带 tty 的记录一次」压到「每个设备号一次」，只是把
    /// 这个既有隐患摊薄，不是修掉它。要真修得换成 `devname_r`（本机签名与 POSIX 不一致）。
    static let devnameResolver: @Sendable (UInt32) -> String? = { dev in
        guard dev != 0, let pointer = devname(Int32(bitPattern: dev), S_IFCHR) else { return nil }
        var bytes: [UInt8] = []
        var index = 0
        while index < 64, pointer[index] != 0 {
            bytes.append(UInt8(bitPattern: pointer[index]))
            index += 1
        }
        let name = String(decoding: bytes, as: UTF8.self)
        return name.isEmpty ? nil : name
    }

    private struct State: Sendable {
        var names: [UInt32: String] = [:]
        /// 解析不出名字的设备号也要记一笔，否则每轮都会重问一次注定没有答案的问题。
        var knownUnnamed: Set<UInt32> = []
        var resolutions = 0
        var lookups = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let resolver: @Sendable (UInt32) -> String?

    /// - Parameter resolver: 真正的解析实现，测试可换成计数桩。
    init(resolver: @escaping @Sendable (UInt32) -> String? = DeviceNameMemo.devnameResolver) {
        self.resolver = resolver
    }

    /// 设备号对应的终端名（如 `ttys003`）；同一个设备号只会向 `resolver` 问一次。
    ///
    /// - Parameter deviceNumber: `proc_bsdinfo.e_tdev`。0 表示没有控制终端，直接返回 nil。
    func name(forDeviceNumber deviceNumber: UInt32) -> String? {
        guard deviceNumber != 0 else { return nil }
        let memoized = lock.withLock { state -> (hit: Bool, value: String?) in
            state.lookups += 1
            if let name = state.names[deviceNumber] { return (true, name) }
            if state.knownUnnamed.contains(deviceNumber) { return (true, nil) }
            return (false, nil)
        }
        guard !memoized.hit else { return memoized.value }

        let read = resolver(deviceNumber)
        lock.withLock { state in
            state.resolutions += 1
            if let read {
                state.names[deviceNumber] = read
            } else {
                state.knownUnnamed.insert(deviceNumber)
            }
        }
        return read
    }

    /// 真正调用解析器的次数（= 不同设备号个数）。
    var resolutionCount: Int { lock.withLock { $0.resolutions } }

    /// 被查询的总次数。
    var lookupCount: Int { lock.withLock { $0.lookups } }
}
