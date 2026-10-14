//
//  TickCPUClockTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-Platform
//  ─────────────────────────────────────────────────────────
//  `TickCPUClock` 的回归钉桩。
//
//  钉的缺陷（AGENTS §6 的「性能与语义同一个根」那一类）：一个 tick 里有两个入口都要
//  CPU 占用率——全表快照 `scanProcesses()` 与按 pid 精确取数 `metrics(for:)`。改前它们
//  共用一份「上一次读数」，第二个入口看到的是**第一个入口几十毫秒前**写下的基准，
//  于是求差窗口塌缩成那几十毫秒：落库的 Agent CPU% 变成「那 20 ms 的占用率」而不是
//  整轮 3 s 的——而它还是「资源滥用」规则的输入。
//
//  本文件钉的是这个时钟的口径（也是它唯一要保证的事）：**一个 tick 只有一份基准**。
//   · `beginTick()` 把上一 tick 的观测提交为基准；
//   · 同一 tick 内对同一个 pid 问几次都返回**同一个数**（第二次直接复用第一次的结果），
//     所以两个入口不可能再互相把对方的基准「刷新」掉；
//   · 求差窗口 = 本次读数与**上一 tick** 读数之间的墙钟跨度。
//
//  期望值都是旁算出来的字面量（算式写在每条断言旁边），不是跑一遍实现把吐出来的数抄进来。
//  这里的浮点相等是安全的：被断言的商都是「可精确表示的两个整数相除、结果也可精确表示」
//  （100 × 150e6 = 1.5e10 与 3e9 都在 double 的精确整数区间里，商 5 精确）。
//  取「上界截断」与「不猜」那两条分支时用的是 `== 0` / `== 200.0`，同样不含容差。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

@Suite("TickCPUClock：一个 tick 只有一份基准", .timeLimit(.minutes(1)))
struct TickCPUClockTests {

    /// 十步一条的时间线——口径要连起来看才有意义：单看任何一步都能被「恒返回 0」糊过去，
    /// 连起来才同时钉住「首无基准不猜」「同 tick 恒等」「换 tick 才推进基准」「倒退只归零」。
    @Test("十步时间线：无基准 / 同 tick 恒等 / 提交为基准 / 累计倒退")
    func timeline() {
        let clock = TickCPUClock(coreCount: 4)          // 封顶 100 × 4 = 400
        let pid: Int32 = 4242

        // 第 1 步：开第一个 tick（此时没有任何基准）。
        clock.beginTick()

        // 第 2 步：期望 **nil（本轮无基线）**。上一 tick 没有这个 pid 的读数 ⇒ 不猜，
        // 也**不许报 0%**——0% 会被下游读成「这一轮真的没占 CPU」。
        let v2 = clock.observe(pid: pid, cumulativeNanos: 1_000_000_000, wallNanos: 10_000_000_000)
        #expect(v2 == nil, "第 2 步：上一 tick 没有基准时必须返回 nil，而不是拿本次读数自己猜一个占用率，也不能塌成 0%")

        // 第 3 步：期望 **还是 nil**，且必须**就是第 2 步算出的那个值**。
        // 这条是同 tick 恒等的前半：实现若把第 2 步当成新基准，这里会算出
        // 100 × (5e9 − 1e9) / (11e9 − 10e9) = 400（封顶后），而不是「无基线」。
        let v3 = clock.observe(pid: pid, cumulativeNanos: 5_000_000_000, wallNanos: 11_000_000_000)
        #expect(v3 == v2, "第 3 步：同一 tick 内第二次问同一个 pid 必须返回第一次算出的值")
        #expect(v3 == nil, "第 3 步：同 tick 内不许把同 tick 的读数当基准（否则这里会拿到一个虚高的数）")

        // 第 4 步：提交第 2 步那条（cum 1e9 / wall 10e9）为基准。
        clock.beginTick()

        // 第 5 步：期望 5.0。Δcpu = 1.15e9 − 1e9 = 150e6 ns；Δwall = 13e9 − 10e9 = 3e9 ns
        // ⇒ 100 × 150e6 / 3e9 = 5。分母是**跨 tick 的整段**墙钟（这里就是 3 s 量级）。
        let v5 = clock.observe(pid: pid, cumulativeNanos: 1_150_000_000, wallNanos: 13_000_000_000)
        #expect(v5 == 5.0, "第 5 步：求差窗口必须是一个完整 tick（Δwall = 3e9 ns）⇒ 5.0")

        // 第 6 步：期望仍是 5.0——这条就是「两个入口不再互相刷基准」的可执行含义。
        // 改前的形状：第二个入口拿第 5 步刚写下的读数当基准，Δwall 变成 20e9−13e9=7e9、
        // Δcpu 变成 8e9 ⇒ 114.28…；同 tick 恒等后第二次问只能原样返回第 5 步的数。
        let v6 = clock.observe(pid: pid, cumulativeNanos: 9_000_000_000, wallNanos: 20_000_000_000)
        #expect(v6 == v5, "第 6 步：同 tick 内第二个入口问同一个 pid 必须拿到同一个数（改前正是在这儿把基准刷掉）")
        #expect(v6 == 5.0, "第 6 步：同上，期望值 5.0 由第 5 步的算式旁算得出，与实现无关")

        // 第 7 步：期望 nil。另一个 pid 在上一 tick 没有基准 ⇒ 不猜、不报 0%。
        let v7 = clock.observe(pid: 4343, cumulativeNanos: 1_000_000_000, wallNanos: 13_000_000_000)
        #expect(v7 == nil, "第 7 步：上一 tick 没见过的 pid 必须返回 nil")

        // 第 8 步：基准换成第 5 步那条（cum 1.15e9 / wall 13e9）。
        // 注意第 6 步那条更大的读数**不该**成为基准——它只是同 tick 内的第二次询问。
        clock.beginTick()

        // 第 9 步：期望 10.0。Δcpu = 1.45e9 − 1.15e9 = 300e6；Δwall = 16e9 − 13e9 = 3e9
        // ⇒ 100 × 300e6 / 3e9 = 10。若第 8 步错误地把第 6 步（9e9/20e9）当了基准，
        // 这里会走「累计倒退」分支拿到 0，或拿到别的数——两种都失败。
        let v9 = clock.observe(pid: pid, cumulativeNanos: 1_450_000_000, wallNanos: 16_000_000_000)
        #expect(v9 == 10.0, "第 9 步：基准必须是上一 tick 的那一条 ⇒ Δcpu 300e6 / Δwall 3e9 = 10.0")

        // 第 10 步：期望 nil。累计 CPU 时间倒退（pid 被复用给了新进程）⇒ 只许「无基线」，
        // 不许负数、不许虚高，也不许塌成 0%（那仍然是拿死进程的历史在说话）。
        // 改前的形状：`cpuHistory` 按 pid 键且从不裁剪 ⇒ 这里会拿死进程的 1.45e9 当基准，
        // 若新进程累计恰好更大（例如 5e9），算出 100×(5e9−1.45e9)/3e9 = 118.3%。
        clock.beginTick()
        let v10 = clock.observe(pid: pid, cumulativeNanos: 1_000_000_000, wallNanos: 19_000_000_000)
        #expect(v10 == nil, "第 10 步：累计时间倒退 ⇒ nil（负数、虚高与 0% 都不接受）")
    }

    /// 钉的是「封顶」这条口径：多核进程一次 tick 里可以跑到 >100%，但落库值不得超过
    /// 100 × 核心数——否则「资源滥用」规则会拿到一个物理上不存在的百分比。
    @Test("封顶：原始值 266.66… 被截到 100 × coreCount = 200")
    func capsAtCoreCount() {
        let clock = TickCPUClock(coreCount: 2)          // 上限 2 × 100 = 200
        clock.beginTick()
        #expect(
            clock.observe(pid: 7, cumulativeNanos: 0, wallNanos: 0) == nil,
            "第一个 tick 没有基准 ⇒ nil（这条是对照，别让封顶逻辑顺带把首值改了）"
        )

        clock.beginTick()
        // 原始值 = 100 × (8e9 − 0) / (3e9 − 0) = 266.666…，上限 200 ⇒ 期望恰好 200.0。
        let percent = clock.observe(pid: 7, cumulativeNanos: 8_000_000_000, wallNanos: 3_000_000_000)
        #expect(percent == 200.0, "Δcpu 8e9 / Δwall 3e9 的原始值 266.66… 必须被截到 100 × 2 = 200.0")
    }

    /// 钉的是「除零」这条：同一个单调时刻问两次（`wallNanos > base.wallNanos` 不成立）时
    /// 必须返回 nil，而不是 NaN / inf——NaN 一旦进了 `perf_samples`，下游所有阈值比较都恒假，
    /// 「资源滥用」规则会静默失效；而 0 会让「没算出来」看起来像「真的没用 CPU」。
    @Test("墙钟窗口为 0 ⇒ 无基线（既不除零，也不塌成 0%）")
    func zeroWallWindowIsNilNotNaN() {
        let clock = TickCPUClock(coreCount: 4)
        clock.beginTick()
        #expect(clock.observe(pid: 9, cumulativeNanos: 100, wallNanos: 5_000_000_000) == nil, "首 tick 无基准 ⇒ nil")

        clock.beginTick()
        // Δwall = 5e9 − 5e9 = 0 ⇒ 窗口不成立，期望 nil（NaN / inf / 0% 三种都不可接受）。
        let percent = clock.observe(pid: 9, cumulativeNanos: 200, wallNanos: 5_000_000_000)
        #expect(percent == nil, "墙钟没往前走时不许除，也不许报 0%")
    }

    /// 钉的是「一个 tick 一个 pid 只观测一次」：本 tick 的记录表按 pid 计数。
    /// 若第二次询问又记一笔，下一 tick 的基准就成了「同 tick 内的后一次读数」，
    /// 求差窗口又塌回两次询问之间——正是这次要修的那个缺陷的另一半。
    @Test("同 tick 内重复观测同一个 pid 不再多记一笔（3 个 pid ⇒ 计数 3）")
    func recordsOneEntryPerPIDPerTick() {
        let clock = TickCPUClock(coreCount: 4)
        clock.beginTick()
        _ = clock.observe(pid: 1, cumulativeNanos: 1_000_000, wallNanos: 1_000_000_000)
        _ = clock.observe(pid: 2, cumulativeNanos: 1_000_000, wallNanos: 1_000_000_000)
        _ = clock.observe(pid: 3, cumulativeNanos: 1_000_000, wallNanos: 1_000_000_000)
        _ = clock.observe(pid: 1, cumulativeNanos: 2_000_000, wallNanos: 1_100_000_000)
        _ = clock.observe(pid: 1, cumulativeNanos: 3_000_000, wallNanos: 1_200_000_000)
        // pid 1、2、3 各一个条目：pid 1 被问了 3 次，只记 1 笔 ⇒ 期望 3。
        #expect(clock.pendingObservationCount == 3, "一个 tick 内每个 pid 只该记一笔（问 3 次的 pid 1 仍只占一笔）")
    }

    /// 钉的是「跨 tick 不共享 pending」：`beginTick` 之后本 tick 一笔都还没有。
    /// 若 pending 不清空，新 tick 的第一次询问会直接命中上一 tick 算好的旧值，
    /// 于是每个 pid 的占用率永远停在第一轮那一次的结果上。
    @Test("beginTick 之后 pending 归零（上一 tick 观测过 3 个 pid 也不带进来）")
    func pendingDoesNotCrossTicks() {
        let clock = TickCPUClock(coreCount: 4)
        clock.beginTick()
        _ = clock.observe(pid: 1, cumulativeNanos: 1_000_000, wallNanos: 1_000_000_000)
        _ = clock.observe(pid: 2, cumulativeNanos: 1_000_000, wallNanos: 1_000_000_000)
        _ = clock.observe(pid: 3, cumulativeNanos: 1_000_000, wallNanos: 1_000_000_000)
        #expect(clock.pendingObservationCount == 3, "上一 tick 记了 3 笔（这条不成立时下面那条 0 就是假的）")

        clock.beginTick()
        #expect(clock.pendingObservationCount == 0, "新 tick 必须是空记录：pending 不能跨 tick 共享")
    }

    /// 钉的是「**pid 被复用给一个新进程时，绝不拿死进程的累计时间算差**」。
    ///
    /// 期望值由算术旁算，与实现无关：
    ///  · tick1：pid 5 累计 50_000_000 ns（0.05 s）@ wall 0 ⇒ 本轮无基线（`nil`），
    ///    但这条读数会在下一 tick 成为基准；
    ///  · tick2：这一轮快照里**没有** pid 5（它正好死了）⇒ 它的基准随整表替换一起死掉；
    ///  · tick3：pid 5 被复用给一个新进程，已累计 5_000_000_000 ns @ wall 20_000_000_000。
    /// 改前那份「按 pid 键、从不裁剪」的 `cpuHistory` 在这里会拿死进程的 0.05 s 当基准：
    /// Δcpu = 5e9 − 5e7 = 4.95e9，Δwall = 2e10 − 0 = 2e10
    /// ⇒ 100 × 4.95e9 / 2e10 = **24.75%** —— 一个不属于任何进程的读数
    ///   （新进程寿命只有 2 s，可那个窗口里它压根没活满；死进程又早已不在）。
    /// 正确输出只能是 `nil`：本轮无基线。
    @Test("pid 复用：绝不拿死进程的累计时间算差（改前会算出 24.75% 这个不属于任何进程的数）")
    func reusedPIDDoesNotInheritDeadProcessBaseline() {
        let clock = TickCPUClock(coreCount: 4)
        let reused: Int32 = 5

        clock.beginTick()
        #expect(clock.observe(pid: reused, cumulativeNanos: 50_000_000, wallNanos: 0) == nil)

        // tick2：这一轮没见过 pid 5（它死了）。什么都不观测。
        clock.beginTick()

        // tick3：同一个 pid 号现在是另一个进程了。
        clock.beginTick()
        #expect(
            clock.observe(pid: reused, cumulativeNanos: 5_000_000_000, wallNanos: 20_000_000_000) == nil,
            "pid 复用 ⇒ 上一 tick 没见过它就没有基线；拿死进程的累计时间算差会得出 24.75%"
        )
    }

    /// 钉的是「基线表按 tick **整表替换** ⇒ 不随 pid churn 无界增长」。
    ///
    /// 期望值旁算：每 tick 观测 200 个**全新** pid（模拟不断生灭），跑 5 个 tick 共 1000 个
    /// 不同 pid。整表替换的口径意味着基准的规模被「一轮进程数」钉住 ⇒
    /// 第 2~5 tick 开始时 `baselineCount` 恒为 **200**（只有上一 tick 那 200 个），
    /// 而不是累计的 400/600/800/1000。改前 `cpuHistory` 只增不删 ⇒ 这里会是 800。
    @Test("5 个 tick × 每 tick 200 个新 pid：基线表恒 200 条，不累计到 800")
    func baselineTableIsReplacedNotAccumulated() {
        let clock = TickCPUClock(coreCount: 4)
        let perTick = 200

        for tick in 0..<5 {
            clock.beginTick()
            // 整表替换发生在 beginTick 里 ⇒ 第 1 个 tick 之前什么都没有，之后恒等于上一轮条数。
            #expect(
                clock.baselineCount == (tick == 0 ? 0 : perTick),
                "第 \(tick + 1) 个 tick 开始时基线表应为 \(tick == 0 ? 0 : perTick) 条"
            )
            for j in 0..<perTick {
                let pid = Int32(tick * perTick + j)
                _ = clock.observe(
                    pid: pid,
                    cumulativeNanos: UInt64(1_000_000 + tick),
                    wallNanos: UInt64(tick) * 3_000_000_000
                )
            }
        }
        // 第 1 个 tick 的 pid 0 到第 5 个 tick 早已没有基准 ⇒ nil（不是 0%，也不是拿
        // 后面某一轮的读数硬凑）。
        #expect(clock.observe(pid: 0, cumulativeNanos: 9_000_000_000, wallNanos: 42_000_000_000) == nil)
    }
}

// MARK: - 接线：真实采集器两个入口共用一份基准

/// A 组的用例喂的是假读数，删掉 `LibprocProcessInspector` 里的 `cpuClock` 接线它们照样绿。
/// 这一条走真机采集器与真进程表，证明「生产真的走到这个时钟」。
@Suite("TickCPUClock 接线：真实采集器的两个入口在同一 tick 给出同一个数", .timeLimit(.minutes(1)))
struct TickCPUClockWiringTests {

    /// 求差窗口 = 一整轮，而不是「两次入口之间那几微秒」。
    ///
    /// 步骤：建基准 → 本进程实心自旋 ≥ 250 ms → 再扫一轮拿 A → **同一轮内**立刻按 pid
    /// 再取一次拿 B → 断言 A == B 且 A > 5.0。
    ///
    /// 改前的形状（这条就是不许放宽的那一点）：`metrics(for:)` 拿的是第三步刚被
    /// `scanProcesses()` 写下的读数当基准，Δwall 只有几微秒、Δcpu 接近 0 ⇒ **B ≈ 0**，
    /// 而 A 是一个完整 tick 的占用率（这里 ≈ 100，因为整个窗口都在自旋）——两者不等。
    /// 只断言 A == B 会有一种蒙对的方式：两个入口都是 0（求差窗口塌缩到极小时两边都算成 0
    /// 也可能出现），所以额外断言 A > 5.0：本进程在窗口里满速烧了一个核，占用率必须体现出来。
    @Test("整轮自旋 250 ms：全表扫描与按 pid 取数的 CPU% 逐位相等且明显非零")
    func bothEntrancesAgreeWithinOneTick() async throws {
        let inspector = LibprocProcessInspector()
        let mine = Int32(ProcessInfo.processInfo.processIdentifier)

        // 第一步：建立基准。采集器是新建的，时钟里没有任何上一 tick 读数 ⇒ 本轮一律 0
        // （「不猜」那条在真实链路上的样子）。
        let baseline = await inspector.scanProcesses()
        let baselineRecord = try #require(
            baseline.first { $0.pid == mine },
            "全表快照里没有本进程 ⇒ 这条用例的前提（能观测到自己）不成立"
        )
        #expect(baselineRecord.cpuPercent == 0, "第一个 tick 没有基准 ⇒ 0，不许猜")

        // 第二步：实心自旋 ≥ 250 ms。⚠️ 不能用 `Thread.sleep` / `Task.sleep`——
        // 睡眠不产生 CPU 时间，那样 A 会接近 0，A == B 就成了「两个 0 相等」的空断言。
        // 循环按墙钟判退出（一定终止），每 10_000 次内层迭代才问一次时钟。
        let spinStart = DispatchTime.now().uptimeNanoseconds
        let spinBudgetNanos: UInt64 = 250_000_000
        var acc: UInt64 = 0x9E37_79B9_7F4A_7C15
        repeat {
            for _ in 0..<10_000 { acc = (acc &<< 7) ^ ((acc &>> 9) &+ 0x2722_0A95) }
        } while DispatchTime.now().uptimeNanoseconds &- spinStart < spinBudgetNanos
        let spunNanos = DispatchTime.now().uptimeNanoseconds &- spinStart
        #expect(spunNanos >= 250_000_000, "自旋窗口必须 ≥ 250 ms（判据是墙钟，这里应当恒成立；失败说明时钟用法错了）")
        #expect(acc != 0x9E37_79B9_7F4A_7C15, "自旋累加器没动 ⇒ 循环被优化掉了，A > 5.0 就失去意义")

        // 第三步：再扫一轮，A = 本进程这一轮的占用率（求差窗口 = 整轮：自旋 + 一轮扫描开销）。
        let records = await inspector.scanProcesses()
        let record = try #require(
            records.first { $0.pid == mine },
            "第二次全表扫描里没有本进程 ⇒ 无法比较两个入口"
        )
        let a = record.cpuPercent
        // A 的量级可旁算：分子 ≈ 自旋那 250 ms 的 CPU（单线程满速 ≈ 1 核），
        // 分母 ≈ 自旋 + 上一轮扫描耗时，所以 A 接近 100 但必然小于 100 × 核心数。
        // 这里只断言它明显大于 0（> 5.0），把「两个入口都是 0」那种蒙对排除掉。
        #expect(a > 5.0, "整轮都在烧一个核 ⇒ A 必须远大于 0（实测应在 1 核 ≈ 100 的量级），拿到 \(a) 说明求差窗口又塌了")

        // 第四步：**同一轮内**立刻按 pid 再取一次。B 必须与 A 逐位相等。
        let sample = try #require(
            inspector.metrics(for: [mine])[mine],
            "按 pid 取数读不到本进程 ⇒ 无法比较两个入口"
        )
        let b = sample.cpuPercent
        #expect(
            a == b,
            """
            同 tick 恒等被破坏：全表口径 \(a) vs 按 pid 口径 \(b)。 \
            B 明显小于 A ⇒ 第二个入口又拿本轮扫描写下的读数当了基准\
            （求差窗口塌缩成两次入口之间那几微秒）。
            """
        )
        #expect(b > 5.0, "按 pid 取数的那条路径也必须拿到整轮占用率，\(b)")
    }
}
