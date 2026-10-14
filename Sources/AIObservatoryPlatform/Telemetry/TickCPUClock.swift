//
//  TickCPUClock.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Platform
//  ─────────────────────────────────────────────────────────
//  「一个进程这一轮占了多少 CPU」的求差时钟。
//
//  为什么要有它（AGENTS §6 的「性能与语义同一个根」那一类）：
//  一个 tick 里有两个入口都要 CPU 占用率——全表快照 `scanProcesses()` 与按 pid 精确
//  取数 `metrics(for:)`。它们共用一份「上一次读数」时，第二个入口看到的是**第一个入口
//  几十毫秒前**写下的基准，于是求差窗口塌缩成那几十毫秒，落库的 Agent CPU% 变成
//  「那 20 ms 的占用率」而不是整轮 3 s 的——而它还是「资源滥用」规则的输入。
//
//  本时钟的口径：**一个 tick 只有一份基准**。
//   · `beginTick` 把上一轮观测到的读数提交为基准；
//   · 同一个 tick 内对同一个 pid 问几次都返回**同一个数**（第二次直接复用第一次算出的值），
//     所以两个入口不可能再互相把对方的基准「刷新」掉；
//   · 求差窗口 = 该 pid 本次读数与**上一 tick** 读数之间的墙钟跨度，即一个 tick 的量级。
//

import Foundation
import os.lock

/// 按 tick 提交基准的 CPU 占用率时钟。
///
/// 线程安全（内部 `OSAllocatedUnfairLock`），不做任何系统调用——读数由调用方喂进来，
/// 因此「一个 tick 内恒等」「首无基准返回 0」这些口径都能在单测里构造，不需要真进程。
public struct TickCPUClock: Sendable {

    /// 一个 pid 在一次 tick 内的读数与本 tick 算出的占用率（`nil` = 本轮无基线，**不是 0%**）。
    private struct Entry: Sendable {
        var cumulativeNanos: UInt64
        var wallNanos: UInt64
        var percent: Double?
    }

    private struct State: Sendable {
        /// 上一个 tick 的读数：本 tick 所有求差的基准。
        var committed: [Int32: Entry] = [:]
        /// 本 tick 已观测过的读数（含算好的占用率，用于同 tick 恒等）。
        var pending: [Int32: Entry] = [:]
    }

    private let lock = OSAllocatedUnfairLock(initialState: State())

    /// 单个进程能报出的上限：占满全部核心 = 100% × 核心数。
    private let ceilingPercent: Double

    /// - Parameter coreCount: 参与封顶的核心数；默认取本机活跃核心数。
    public init(coreCount: Int = ProcessInfo.processInfo.activeProcessorCount) {
        self.ceilingPercent = 100.0 * Double(max(1, coreCount))
    }

    /// 开一个新 tick：把上一 tick 的观测提交为基准，并清空本 tick 的记录。
    ///
    /// 由采集链在**每轮扫描的开头**调用一次。基准时刻记在每条读数上，所以这里不需要
    /// 单独记 tick 起点；同一 tick 内重复调用会把已写入的观测立刻提交，等价于提前收尾，
    /// 调用方不该这么用。
    public func beginTick() {
        lock.withLock { state in
            state.committed = state.pending
            state.pending.removeAll(keepingCapacity: true)
        }
    }

    /// 记下一个 pid 本 tick 的累计 CPU 时间，并返回它在**最近一个完整 tick** 内的占用率（%）。
    ///
    /// - 同一 tick 内对同一 pid 的第二次、第三次调用返回**同一个值**（复用第一次算出的结果），
    ///   这正是「两个入口不再互相刷新基准」的可执行含义——包括第一次算出的是「无基线」时。
    /// - **上一 tick 没有该 pid 的读数 ⇒ 返回 `nil`，不是 0。** 「本轮没数据」与
    ///   「这一轮真的没用 CPU」是两件事，把前者报成后者是本仓主导缺陷类的变体；
    ///   而且新进程从出生到现在烧掉的 CPU 既可能是 0 也可能很多，0 恰好是最不像真的那个猜测。
    /// - pid 被复用时拿不到死进程的基线：上一 tick 没见过这个 pid ⇒ 就是无基线（见 `beginTick`）。
    /// - 累计时间倒退 ⇒ `nil`（宁可缺席，也不给一个物理上不可能的数）。
    /// - 上限 `100 × coreCount`。
    ///
    /// - Parameters:
    ///   - pid: 目标进程。
    ///   - cumulativeNanos: 该进程到本次读数为止的累计 CPU 时间（用户 + 系统），单位纳秒。
    ///   - wallNanos: 本次读数的单调时钟时刻，单位纳秒。
    /// - Returns: 占用率百分比；本轮无基线时为 `nil`。
    public func observe(pid: Int32, cumulativeNanos: UInt64, wallNanos: UInt64) -> Double? {
        lock.withLock { state in
            if let seen = state.pending[pid] { return seen.percent }

            let percent: Double?
            if let base = state.committed[pid], wallNanos > base.wallNanos,
               cumulativeNanos >= base.cumulativeNanos {
                let busyNanos = Double(cumulativeNanos - base.cumulativeNanos)
                let elapsed = Double(wallNanos - base.wallNanos)
                percent = min(100.0 * busyNanos / elapsed, ceilingPercent)
            } else {
                percent = nil
            }
            state.pending[pid] = Entry(
                cumulativeNanos: cumulativeNanos, wallNanos: wallNanos, percent: percent
            )
            return percent
        }
    }

    /// 本 tick 已观测过的 pid 数量（仅用于诊断与测试断言「一轮只观测一次」）。
    public var pendingObservationCount: Int {
        lock.withLock { $0.pending.count }
    }

    /// **当前基线表**里的 pid 数量（诊断用）。
    ///
    /// 这条是「按 pid 键的历史会不会无界增长」的可断言边界：`beginTick` 是整表替换
    /// （`committed = pending`），所以它的上界是**一轮进程数**，不随 tick 数、也不随
    /// pid  churn 累计。改前那份 `cpuHistory` 只增不删，跑一天就攒下当天所有活过的 pid。
    public var baselineCount: Int {
        lock.withLock { $0.committed.count }
    }
}
