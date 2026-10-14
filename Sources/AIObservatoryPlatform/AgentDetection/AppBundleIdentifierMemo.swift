//
//  AppBundleIdentifierMemo.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Platform
//  ─────────────────────────────────────────────────────────
//  「一个 `.app` 包路径 → 它的 Bundle Identifier」的记忆化读取。
//
//  为什么要有它：`BundleIdentifierStrategy` 原先对**每条进程记录**各调一次
//  `Bundle(url:)`，而 `-[NSBundle initWithPath:]` 会做 symlink 解析与 Info.plist 读取
//  （1ms 采样实测把叶帧打在 `lstat` / `_NSResolveSymlinksInPathUsingC` 上）。
//  真机一个 tick 的 1082 条记录里只有 **75 个不同的 `.app` 路径**——同一个应用的十几个
//  helper 各自要把同一个 Info.plist 读一遍。
//
//  口径：
//   · 按**包路径**去重，而不是按进程：Bundle Identifier 是包的属性，不是进程的属性；
//   · **读不到也记一笔**（负缓存）：没有 Info.plist 的包每轮重读仍然什么也读不到；
//   · 超过 `capacity` 个不同路径时整表作废重新学，代价上限可算，不无界增长。
//

import Foundation
import os.lock

/// `.app` 包路径 → Bundle Identifier 的记忆化读取器。
///
/// 可注入 `reader`，因此「同一个包一轮只读一次」这条能在真机计时之前就被单测钉住
/// （计时只证明它便宜，证明确实少读了）。
public struct AppBundleIdentifierMemo: Sendable {

    /// 默认读取器：本地读该包的 Info.plist，无网络。
    public static let diskReader: @Sendable (String) -> String? = { path in
        Bundle(url: URL(fileURLWithPath: path))?.bundleIdentifier
    }

    private struct State: Sendable {
        /// 读到了 Identifier 的包。
        var identifiers: [String: String] = [:]
        /// 确认「这个包读不出 Identifier」的包——不记这一笔，无 Info.plist 的包每轮都会重读。
        var knownWithoutIdentifier: Set<String> = []
        var diskReads = 0
        var lookups = 0
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())
    private let capacity: Int
    private let reader: @Sendable (String) -> String?

    /// - Parameters:
    ///   - capacity: 最多记忆多少个不同的包路径；超出即整表作废（防无界增长）。
    ///   - reader: 真正的读取实现，测试可换成计数桩。
    public init(
        capacity: Int = 256,
        reader: @escaping @Sendable (String) -> String? = AppBundleIdentifierMemo.diskReader
    ) {
        self.capacity = max(1, capacity)
        self.reader = reader
    }

    /// 取某个 `.app` 包路径的 Bundle Identifier；同一个路径只会向 `reader` 问一次。
    ///
    /// - Parameter bundlePath: **最外层** `.app` 的路径（见 `DetectionHygiene.enclosingAppBundle`）。
    /// - Returns: 读到的 Bundle Identifier；该包没有 Info.plist 或读不出时为 `nil`。
    public func identifier(forAppBundle bundlePath: String) -> String? {
        let memoized = lock.withLock { state -> (hit: Bool, value: String?) in
            state.lookups += 1
            if state.identifiers.count + state.knownWithoutIdentifier.count > capacity {
                state.identifiers.removeAll(keepingCapacity: false)
                state.knownWithoutIdentifier.removeAll(keepingCapacity: false)
            }
            if let id = state.identifiers[bundlePath] { return (true, id) }
            if state.knownWithoutIdentifier.contains(bundlePath) { return (true, nil) }
            return (false, nil)
        }
        guard !memoized.hit else { return memoized.value }

        let read = reader(bundlePath)
        lock.withLock { state in
            state.diskReads += 1
            if let read {
                state.identifiers[bundlePath] = read
            } else {
                state.knownWithoutIdentifier.insert(bundlePath)
            }
        }
        return read
    }

    /// 向真实读取器问了几次（= 不同包路径的个数；命中缓存不计数）。
    public var diskReads: Int { lock.withLock { $0.diskReads } }

    /// 被查询的总次数（= 走到这条策略的进程记录数）。
    public var lookups: Int { lock.withLock { $0.lookups } }
}
