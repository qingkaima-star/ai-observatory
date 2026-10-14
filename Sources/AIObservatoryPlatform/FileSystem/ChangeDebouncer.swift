//
//  ChangeDebouncer.swift
//  AIObservatoryPlatform — FileSystem 子模块
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  按路径做时间窗合并（默认 400 ms）。AI 写文件常 5–20 次/秒，
//  同一路径在窗口内的多次事件只输出 1 条；不同路径各自独立计时。
//
//  两个「字节」口径必须分清（这是本文件唯一的语义难点）：
//  · 输出事件的 `sizeBytes` = 窗口内**最后一次真实 stat 到的文件大小**，不是累加值。
//    FSEvents 只给路径，字节只能来自 stat；把同一个文件的多次 stat 结果相加
//    得到的数既不是「最终大小」也不是「写入量」，没有物理意义。
//  · 「窗口内累计观测字节 + 合并次数」才是真正有用的观测量，
//    由 `CoalescingStat` + `stat(forPath:)` 显式暴露，flush 之后为 nil。
//
//  驱动方式：每个路径的首条事件启动一个 `Task` + `Task.sleep(window)` 定时器，
//  到点放行；`flushAll()` 立即放行全部并取消对应定时器（幂等，可重复调用）。
//

import Foundation
import AIObservatoryCore

// MARK: - 观测统计

/// 一个去抖窗口内对**同一路径**的累计观测结果。
///
/// 只在事件仍被缓冲（未放行）时可见：`flush` / `flushAll` 之后 `stat(forPath:)` 返回 `nil`。
public struct CoalescingStat: Sendable, Hashable {

    /// 合并进这条输出的事件条数（含首条，因此恒 >= 1）。
    public var mergeCount: Int

    /// 窗口内每次观测到的 `sizeBytes` 之和。
    ///
    /// 语义是「累计观测字节」：对同一路径的多次 `modified`，它近似反映这段时间的写入活动量。
    /// stat 失败（`sizeBytes == 0`）的观测按 0 计入 —— 不猜测任何数值。
    public var bytesObserved: UInt64

    /// 创建统计值。
    /// - Parameters:
    ///   - mergeCount: 合并条数（含首条）。
    ///   - bytesObserved: 累计观测字节。
    public init(mergeCount: Int, bytesObserved: UInt64) {
        self.mergeCount = mergeCount
        self.bytesObserved = bytesObserved
    }
}

// MARK: - 去抖器

/// 把高频的文件事件按路径合并、按时间窗去抖后再「放行」的组件。
///
/// 用法：把从 FSEvents 等来源收到的 `RawFileSystemEvent` 喂给 `feed(_:)`，
/// 合并结果会通过构造时传入的 `AsyncStream` continuation 输出。
///
/// 并发说明：本类型是 `actor`，所有可变状态都在隔离域内，无需额外加锁。
/// 输出顺序 = 各路径定时器的到点顺序（同一路径只会有一条），
/// 因此**上游必须已经串行化**（`FSEventsWatcher` 用单消费者 FIFO 管道保证）。
public actor ChangeDebouncer {

    /// 单个路径在窗口内的待合并状态。
    private struct PendingEntry {
        var event: RawFileSystemEvent
        /// 已合并的事件条数（含首条）。
        var mergeCount: Int
        /// 累计观测字节（含首条）。
        var bytesObserved: UInt64

        /// 创建首条事件的缓冲项。
        init(first event: RawFileSystemEvent) {
            self.event = event
            self.mergeCount = 1
            self.bytesObserved = event.sizeBytes
        }

        /// 全量成员初始化。
        ///
        /// 必须显式写出来：一旦声明了 `init(first:)`，Swift 就不再自动合成成员级初始化器，
        /// `merging(with:)` 里的 `PendingEntry(event:mergeCount:bytesObserved:)` 会编译失败。
        init(event: RawFileSystemEvent, mergeCount: Int, bytesObserved: UInt64) {
            self.event = event
            self.mergeCount = mergeCount
            self.bytesObserved = bytesObserved
        }

        /// 将另一条（同一路径的）事件合并进来。
        ///
        /// 合并规则：
        /// - 种类优先级 `deleted > created > renamed > modified`（消失最要紧，其次才是新增/改名）。
        /// - 时间戳取最新一条。
        /// - `sizeBytes` = 最后一次**真实**观测到的大小；`sizeBytes == 0` 只代表「stat 失败 / 无信息」，
        ///   此时保留窗口内上一个真实大小（除非本次是 `deleted` —— 文件确实没了，0 才是真值）。
        /// - `mergeCount` 递增、`bytesObserved` 累加，经 `CoalescingStat` 暴露。
        func merging(with other: RawFileSystemEvent) -> PendingEntry {
            let newKind: FileChangeKind
            if event.kind == .deleted || other.kind == .deleted {
                newKind = .deleted
            } else if event.kind == .created || other.kind == .created {
                newKind = .created
            } else if event.kind == .renamed || other.kind == .renamed {
                newKind = .renamed
            } else {
                newKind = .modified
            }

            let resolvedSize: UInt64
            if newKind == .deleted {
                resolvedSize = 0
            } else if other.sizeBytes > 0 {
                resolvedSize = other.sizeBytes
            } else {
                resolvedSize = event.sizeBytes
            }

            let merged = RawFileSystemEvent(
                path: event.path,
                previousPath: other.previousPath ?? event.previousPath,
                kind: newKind,
                timestamp: other.timestamp,
                isDirectory: event.isDirectory,
                sizeBytes: resolvedSize
            )
            return PendingEntry(
                event: merged,
                mergeCount: mergeCount + 1,
                bytesObserved: bytesObserved &+ other.sizeBytes
            )
        }
    }

    /// 去抖窗口（秒）。
    public let window: TimeInterval

    private var pending: [String: PendingEntry] = [:]
    private var flushTasks: [String: Task<Void, Never>] = [:]
    private let output: AsyncStream<RawFileSystemEvent>.Continuation

    /// 创建去抖器。
    /// - Parameters:
    ///   - window: 去抖窗口，默认 0.4 秒。
    ///   - output: 合并后事件输出的 continuation。调用方负责在它之后 `finish()`
    ///     （去抖器本身不结束流，避免「先 finish 再 yield」的竞态）。
    public init(window: TimeInterval = 0.4, output: AsyncStream<RawFileSystemEvent>.Continuation) {
        self.window = window
        self.output = output
    }

    /// 喂入一条原始事件。
    ///
    /// 某路径的首条事件启动窗口定时器；窗口内的后续事件只做合并（只输出 1 条）。
    public func feed(_ event: RawFileSystemEvent) {
        let key = event.path
        if let existing = pending[key] {
            pending[key] = existing.merging(with: event)
        } else {
            pending[key] = PendingEntry(first: event)
            let w = window
            flushTasks[key] = Task { [weak self] in
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: UInt64(max(0, w) * 1_000_000_000))
                // 被取消（例如 flushAll 已提前放行）时绝不能再放行一次。
                guard !Task.isCancelled else { return }
                await self?.flush(key: key)
            }
        }
    }

    /// 当前仍在窗口内的路径集合（诊断 / 测试用，顺序不保证）。
    public func pendingPaths() -> [String] {
        Array(pending.keys)
    }

    /// 查询某路径在当前窗口内的累计观测；不在窗口内（含已被放行）时返回 `nil`。
    public func stat(forPath path: String) -> CoalescingStat? {
        guard let entry = pending[path] else { return nil }
        return CoalescingStat(mergeCount: entry.mergeCount, bytesObserved: entry.bytesObserved)
    }

    /// 立即放行某路径的待合并事件（若仍在窗口内）。重复调用无副作用。
    private func flush(key: String) {
        flushTasks[key]?.cancel()
        flushTasks[key] = nil
        guard let entry = pending[key] else { return }
        pending[key] = nil
        output.yield(entry.event)
    }

    /// 立即放行所有仍在窗口内的待合并事件（用于停止前刷新）。
    ///
    /// 幂等：第二次调用时缓冲区已空，不会再放行任何东西。
    public func flushAll() {
        let keys = Array(pending.keys)
        for key in keys { flush(key: key) }
    }
}
