//
//  FileTrackingTests.swift
//  AIObservatoryPlatformTests — FileSystem
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  端到端验收套件：真实 FSEvents 事件流 + 去抖器/重命名配对行为。
//
//  时序约定（重要）：
//  生产默认 latency 0.3 + debounce 0.4 + renameWindow 0.5 ⇒ 最坏时延约 0.7–1.2 s。
//  「1 秒内收到事件」这条验收用**收紧的配置**验证（latency 0.05 / debounce 0.05 /
//  renameWindow 0.2），因为验收对象是「链路是否真能把事件送出来」，而不是内核粗去抖
//  的时长；`defaultConfigWorks` 另有一条用例守住默认配置下的可用性上界。
//
//  #88（本轮硬化）：验收线判的是**产品侧**时延。`waitUntil` 除了墙钟还交出「装置自己每轮
//  sleep(20ms) 睡过头的累计秒数」，由 `expectWithinLatencyBudget` 从墙钟里减掉再判
//  （最多抵 0.5 s，三个数随失败信息一起打印 ⇒ 放宽的额度是当场量到的，不是魔数）。
//  旧写法把环境的 CPU 饿记在产品的账上：满载机器上实测 1.015 s 撞 1.0 s 线，全量 10 轮红 1 轮，
//  而红的那一次产品没有任何变化（也挡住了所有车道的「全量绿」）。
//
//  本文件不再使用会挂死的 `race(...)`：所有等待都走 `waitUntil`，最多阻塞 timeout。
//  临时目录全部建在 `Scratch.directory(...)`（当前检出自带的 `.scratch-tests/`）下并在 defer 清理。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 测试辅助

/// 事件收集器：把 `AsyncStream` 的顺序消费收敛到一个 actor 里，测试以轮询方式等待。
private actor EventCollector {
    private var events: [RawFileSystemEvent] = []

    func append(_ event: RawFileSystemEvent) {
        events.append(event)
    }

    var snapshot: [RawFileSystemEvent] { events }

    /// 失败时给出可读的事件摘要（只含 kind + 文件名 + 大小，不含内容）。
    var summary: String {
        guard !events.isEmpty else { return "<空>" }
        return events.prefix(12)
            .map { "\($0.kind.rawValue):\(($0.path as NSString).lastPathComponent)(\($0.sizeBytes))" }
            .joined(separator: ", ")
    }
}

/// `Duration` → 秒（Double），避免手写时间戳算术。
private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) * 1e-18
}

/// 轮询等待直到 `predicate` 满足或超时。
///
/// 返回第三个值 `harnessDebtSeconds` = **本装置自己睡过头的秒数**：每一轮 `Task.sleep(20 ms)`
/// 实测多久、超出名义值多少，累加起来就是「这段窗口里执行器没给我们 CPU」的量。
/// 它必须被单独交出来，因为 #88 之前那五处 1 秒绝对挂钟线把两本账混在一起判
/// （满载机器上实测 1.015 s 撞线）⇒ 环境越忙越容易红，而红的那一下产品没有任何变化。
/// 判定由 `expectWithinLatencyBudget` 把装置账减掉后再做。
///
/// 永不挂死：最多阻塞 `timeout`。
private func waitUntil(
    _ predicate: @Sendable ([RawFileSystemEvent]) -> Bool,
    on collector: EventCollector,
    timeout: Duration
) async -> (satisfied: Bool, elapsedSeconds: Double, harnessDebtSeconds: Double) {
    let clock = ContinuousClock()
    let start = clock.now
    let limit = seconds(timeout)
    let pollNominal = Duration.milliseconds(20)
    let pollNominalSeconds = seconds(pollNominal)
    var debt = 0.0
    while true {
        let events = await collector.snapshot
        let spent = seconds(start.duration(to: clock.now))
        if predicate(events) { return (true, spent, debt) }
        if spent >= limit { return (false, spent, debt) }
        let beforeSleep = clock.now
        try? await Task.sleep(for: pollNominal)
        debt += max(0, seconds(beforeSleep.duration(to: clock.now)) - pollNominalSeconds)
    }
}

/// 挂钟预算的算法，抽成纯函数是为了能被**确定性**钉住（`LatencyBudgetTests`）——
/// 端到端那几条只能证明「这次没超」，证不了「封顶真的在生效」。
///
/// - 装置欠账最多抵 `maxExcusedSeconds`（0.5 s）：不封顶就成了"机器越忙预算越大"的空断言。
/// - 抵完之后仍要求产品在 `line` 内送达 ⇒ 1 秒验收线在最坏情况下变成 1.5 秒，而不是无限。
private func latencyBudget(elapsedSeconds: Double, harnessDebtSeconds: Double,
                           line: Double, maxExcusedSeconds: Double = 0.5)
    -> (excused: Double, productSeconds: Double, withinBudget: Bool) {
    let excused = min(max(harnessDebtSeconds, 0), min(maxExcusedSeconds, elapsedSeconds))
    let product = elapsedSeconds - excused
    return (excused, product, product < line)
}

/// 端到端挂钟验收：把 `waitUntil` 交出的两本账分开判，三个数一起打印（判错了可被复核）。
private func expectWithinLatencyBudget(
    _ waited: (satisfied: Bool, elapsedSeconds: Double, harnessDebtSeconds: Double),
    line: Double,
    what: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    // 先钉测量本身可信：装置欠账按构造不可能超过墙钟（每轮还有 20 ms 的名义睡眠），
    // 一旦超过，说明装置被改坏了，此时"抵完等于零"会把断言变成永真 ⇒ 必须响亮地红。
    // 取 `<=` 而不是 `<`：首轮立即命中时墙钟可以是 0，此时欠账也是 0，那不是异常。
    #expect(waited.harnessDebtSeconds <= waited.elapsedSeconds,
            "\(what)：装置欠账 \(waited.harnessDebtSeconds)s ≥ 墙钟 \(waited.elapsedSeconds)s ⇒ 测量不可信，不判时延",
            sourceLocation: sourceLocation)
    let verdict = latencyBudget(elapsedSeconds: waited.elapsedSeconds,
                                harnessDebtSeconds: waited.harnessDebtSeconds,
                                line: line)
    // 第二参是 `Comment?`：字符串**字面量**能隐式转，先存成 `String` 变量再传就编译不过。
    #expect(verdict.withinBudget, """
        \(what) 超验收线：墙钟 \(waited.elapsedSeconds)s，装置自己睡过头 \(waited.harnessDebtSeconds)s\
        （最多抵 \(verdict.excused)s），产品侧 \(verdict.productSeconds)s ≥ 预算 \(line)s。\
        减掉装置账仍然超线 ⇒ 这一次是产品的慢，不是机器的慢。
        """, sourceLocation: sourceLocation)
}

/// 启动后台消费任务，把流里的事件塞进收集器。调用方必须 cancel 返回的 Task。
private func startPump(_ stream: AsyncStream<RawFileSystemEvent>, into collector: EventCollector) -> Task<Void, Never> {
    Task {
        for await event in stream {
            if Task.isCancelled { break }
            await collector.append(event)
        }
    }
}

/// 一次性 scratch 目录（由 `Scratch` 定位到当前检出自带的 `.scratch-tests/`）。
private func makeScratch(_ purpose: String) throws -> URL {
    try Scratch.directory("files-\(purpose)")
}

// MARK: - 挂钟预算算法本身（确定性用例，不依赖机器负载）

/// `latencyBudget` 是纯函数，所以能脱离负载把它的语义逐格钉住。
/// 端到端那五条只能证明"这一次没超线"，证不了"0.5 s 封顶真的在咬"——
/// 而封顶是这套算法唯一新增的失效模式（不封顶就退化成"机器越忙预算越大"的空断言）。
/// 期望值全部手推，不拿实现算一遍再抄回来看成通过。
@Suite("WS-Files: 挂钟预算算法（确定性）")
struct LatencyBudgetTests {

    private func approx(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    /// #88 的现场形状：墙钟 1.015 s 里装置自己睡了 0.12 s 过头 ⇒ 产品侧 0.895 s，在 1 s 线内。
    @Test("抵掉当轮量到的装置欠账：1.015 − 0.12 = 0.895 < 1.0（旧写法这一格会红）")
    func excusedWithinCap() {
        let v = latencyBudget(elapsedSeconds: 1.015, harnessDebtSeconds: 0.12, line: 1.0)
        #expect(approx(v.excused, 0.12))
        #expect(v.withinBudget, "欠账在额度内时不该判红，否则 #88 没修掉")
    }

    /// 封顶那一格：墙钟 1.6 s、欠账 0.9 s ⇒ 只许抵 0.5 s，产品侧 1.1 s 仍超线。
    /// 不封顶的话这一格会变成 0.7 s ⇒ 判绿 —— 这条用例就是为了让"去掉封顶"当场红。
    @Test("0.5 s 封顶在咬：1.6 − min(0.9, 0.5) = 1.1 ≥ 1.0 ⇒ 判红")
    func capBoundsTheExcuse() {
        let v = latencyBudget(elapsedSeconds: 1.6, harnessDebtSeconds: 0.9, line: 1.0)
        #expect(approx(v.excused, 0.5), "抵账必须被封顶在 0.5 s")
        #expect(!v.withinBudget, "去掉封顶就会把 1.6 s 的慢判成合格 ⇒ 断言失效")
    }

    /// 机器完全没拖后腿时不得退化成空断言。
    @Test("零欠账时照原线判：1.2 − 0 = 1.2 ≥ 1.0 ⇒ 判红")
    func zeroDebtJudgesOnTheLine() {
        let v = latencyBudget(elapsedSeconds: 1.2, harnessDebtSeconds: 0, line: 1.0)
        #expect(approx(v.excused, 0))
        #expect(!v.withinBudget)
    }

    /// 严格小于：抵完恰好等于验收线也算超线（不许"到线即合格"）。
    @Test("边界取严格小于：1.5 − 0.5 = 1.0 ⇒ 不算在 1.0 s 线内")
    func lineIsExclusive() {
        let v = latencyBudget(elapsedSeconds: 1.5, harnessDebtSeconds: 0.5, line: 1.0)
        #expect(!v.withinBudget)
    }

    /// 抵账不得超过墙钟本身（否则产品侧为负 ⇒ 永真）。
    @Test("抵账被墙钟本身夹住：elapsed 0.3 / debt 5.0 ⇒ excused 0.3、产品侧 0，不为负")
    func excuseNeverExceedsElapsed() {
        let v = latencyBudget(elapsedSeconds: 0.3, harnessDebtSeconds: 5.0, line: 1.0)
        #expect(approx(v.excused, 0.3))
        #expect(approx(v.productSeconds, 0))
        // 这一格单独看是"判绿"，所以 `expectWithinLatencyBudget` 里另有一条
        // "欠账 ≥ 墙钟 ⇒ 测量不可信"的前置断言把它拦成红；那条按构造不会在正常运行里触发。
    }

    /// 默认配置那条护栏用 3 s 线：同样只抵装置账，抵完仍超 ⇒ 判红。
    @Test("3 s 护栏同一套算法：3.4 − 0.2 = 3.2 ≥ 3.0 ⇒ 判红")
    func defaultConfigGuardUsesSameArithmetic() {
        let v = latencyBudget(elapsedSeconds: 3.4, harnessDebtSeconds: 0.2, line: 3.0)
        #expect(!v.withinBudget)
    }
}

// MARK: - 纯去抖器单测（不依赖内核时序，确定性）

@Suite("WS-Files: 去抖与重命名配对（低层）", .timeLimit(.minutes(1)))
struct ChangePipelineTests {

    /// 收集「直到流结束」的全部事件：先喂完事件，再 flushAll + finish，因此不会挂死。
    private func drained(_ body: (ChangeDebouncer, AsyncStream<RawFileSystemEvent>.Continuation) async -> Void) async -> [RawFileSystemEvent] {
        let (stream, cont) = AsyncStream.makeStream(of: RawFileSystemEvent.self)
        let debouncer = ChangeDebouncer(window: 0.4, output: cont)
        await body(debouncer, cont)
        await debouncer.flushAll()
        cont.finish()
        var collected: [RawFileSystemEvent] = []
        for await event in stream { collected.append(event) }
        return collected
    }

    @Test("去抖：同一路径连续 10 次 modified 合并为 1 条")
    func tenFeedsCoalesceToOne() async {
        let events = await drained { debouncer, _ in
            for i in 0..<10 {
                await debouncer.feed(RawFileSystemEvent(path: "/a/hot.swift", kind: .modified, sizeBytes: UInt64((i + 1) * 10)))
            }
        }
        #expect(events.count == 1)
        #expect(events.first?.kind == .modified)
        // sizeBytes 语义 = 最后一次观测到的真实大小（不是累加值）。
        #expect(events.first?.sizeBytes == 100)
    }

    @Test("去抖：created 后跟 modified 折叠为 created")
    func createdThenModified() async {
        let events = await drained { debouncer, _ in
            await debouncer.feed(RawFileSystemEvent(path: "/a/new.swift", kind: .created, sizeBytes: 10))
            await debouncer.feed(RawFileSystemEvent(path: "/a/new.swift", kind: .modified, sizeBytes: 50))
        }
        #expect(events.count == 1)
        #expect(events.first?.kind == .created)
        #expect(events.first?.sizeBytes == 50)
    }

    @Test("去抖：窗口内累加字节可观测")
    func accumulatedBytesIsObservable() async {
        let (stream, cont) = AsyncStream.makeStream(of: RawFileSystemEvent.self)
        let debouncer = ChangeDebouncer(window: 5, output: cont)  // 窗口足够大，期间不自动放行
        for _ in 0..<5 {
            await debouncer.feed(RawFileSystemEvent(path: "/a/x.swift", kind: .modified, sizeBytes: 20))
        }
        let stat = await debouncer.stat(forPath: "/a/x.swift")
        #expect(stat?.mergeCount == 5)
        #expect(stat?.bytesObserved == 100)
        // 另一路径没有状态。
        let missing = await debouncer.stat(forPath: "/a/other.swift")
        #expect(missing == nil)
        await debouncer.flushAll()
        cont.finish()
        var count = 0
        for await _ in stream { count += 1 }
        #expect(count == 1)
        // 放行之后窗口状态被清空。
        let after = await debouncer.stat(forPath: "/a/x.swift")
        #expect(after == nil)
    }

    @Test("去抖：不同路径各自独立合并")
    func distinctPathsIndependent() async {
        let events = await drained { debouncer, _ in
            await debouncer.feed(RawFileSystemEvent(path: "/a/one.swift", kind: .modified))
            await debouncer.feed(RawFileSystemEvent(path: "/a/two.swift", kind: .modified))
            await debouncer.feed(RawFileSystemEvent(path: "/a/one.swift", kind: .modified))
        }
        #expect(events.count == 2)
        #expect(Set(events.map(\.path)) == ["/a/one.swift", "/a/two.swift"])
    }

    @Test("重命名：同 inode 的 delete+create 合并为 renamed 且带 previousPath")
    func renamePairedByInode() async {
        let (stream, cont) = AsyncStream.makeStream(of: RawFileSystemEvent.self)
        let debouncer = ChangeDebouncer(window: 0.4, output: cont)
        let matcher = RenamedFileMatcher(window: 0.5, inodeResolver: { _ in 4242 }, debouncer: debouncer)
        await matcher.feed(RawFileSystemEvent(path: "/a/before.swift", kind: .deleted))
        await matcher.feed(RawFileSystemEvent(path: "/a/after.swift", kind: .created))
        await matcher.shutdown()
        cont.finish()
        var collected: [RawFileSystemEvent] = []
        for await event in stream { collected.append(event) }
        #expect(collected.count == 1)
        #expect(collected.first?.kind == .renamed)
        #expect(collected.first?.path == "/a/after.swift")
        #expect(collected.first?.previousPath == "/a/before.swift")
    }

    @Test("重命名：批内两端顺序颠倒也能配对")
    func renamePairedRegardlessOfBatchOrder() async {
        let (stream, cont) = AsyncStream.makeStream(of: RawFileSystemEvent.self)
        let debouncer = ChangeDebouncer(window: 0.4, output: cont)
        let matcher = RenamedFileMatcher(window: 0.5, inodeResolver: { _ in 77 }, debouncer: debouncer)
        // 同一批里 create 先于 delete（FSEvents 不保证顺序）。
        await matcher.feedBatch([
            RawFileSystemEvent(path: "/a/new.swift", kind: .created),
            RawFileSystemEvent(path: "/a/old.swift", kind: .deleted),
        ])
        await matcher.shutdown()
        cont.finish()
        var collected: [RawFileSystemEvent] = []
        for await event in stream { collected.append(event) }
        #expect(collected.count == 1)
        #expect(collected.first?.kind == .renamed)
        #expect(collected.first?.previousPath == "/a/old.swift")
    }

    @Test("重命名：无配对的删除在窗口到期后确实发出 .deleted，且只发一次")
    func unmatchedDeletionIsReleasedOnce() async {
        let (stream, cont) = AsyncStream.makeStream(of: RawFileSystemEvent.self)
        let debouncer = ChangeDebouncer(window: 0.05, output: cont)
        let matcher = RenamedFileMatcher(window: 0.1, inodeResolver: { _ in nil }, debouncer: debouncer)
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)
        await matcher.feed(RawFileSystemEvent(path: "/a/gone.swift", kind: .deleted))

        // 等到 .deleted 真正出现（而不是等到 shutdown）。
        // 为什么 10 s 而不是 3 s：这条用例在全量套件里红过，症状是 `arrived == false`
        // **且** snapshot 里一条都没有——延期的放行任务在抢线程时可能 3 s 都排不上，
        // 于是退化成「只在 shutdown 放行」的旧行为证据。超时只影响**坏掉时**的耗时。
        let (arrived, _, _) = await waitUntil(
            { $0.contains { $0.path == "/a/gone.swift" && $0.kind == .deleted } },
            on: collector, timeout: .seconds(10)
        )
        // 再静默一会儿，确认不会被重复放行；shutdown 也不该重发。
        try? await Task.sleep(for: .milliseconds(200))
        await matcher.shutdown()
        cont.finish()
        // ⚠️ 这里**不能** cancel：`cancel` 会把已缓冲、尚未被 pump 取走的事件直接丢掉，
        // 于是计数变成 0——一个把「实现正确」判成红的假阴性。收尾一律 drain。
        await pump.value
        let events = await collector.snapshot

        #expect(arrived, "运行期间从未收到 .deleted（旧实现只在 shutdown 才放行）")
        #expect(events.filter { $0.path == "/a/gone.swift" && $0.kind == .deleted }.count == 1)
    }

    @Test("重命名：shutdown 可重复调用且不重复下发")
    func shutdownIsIdempotent() async {
        let (stream, cont) = AsyncStream.makeStream(of: RawFileSystemEvent.self)
        let debouncer = ChangeDebouncer(window: 0.4, output: cont)
        let matcher = RenamedFileMatcher(window: 30, inodeResolver: { _ in nil }, debouncer: debouncer)
        await matcher.feed(RawFileSystemEvent(path: "/a/x.swift", kind: .deleted))
        await matcher.shutdown()
        await matcher.shutdown()
        await matcher.flushPending()
        await matcher.feed(RawFileSystemEvent(path: "/a/y.swift", kind: .deleted))
        cont.finish()
        var collected: [RawFileSystemEvent] = []
        for await event in stream { collected.append(event) }
        #expect(collected.count == 1)
        #expect(collected.first?.path == "/a/x.swift")
    }

    /// inode 缓存：路径消失后仍能凭「活着时记下的 inode」配对（真实文件系统 + 真实 lstat）。
    @Test("重命名：真实 mv 依赖 inode 缓存配对成功")
    func renameUsesInodeCacheWithRealFiles() async throws {
        let dir = try makeScratch("rename-cache")
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldURL = dir.appendingPathComponent("before.txt")
        let newURL = dir.appendingPathComponent("after.txt")
        try "content".write(to: oldURL, atomically: true, encoding: .utf8)

        let (stream, cont) = AsyncStream.makeStream(of: RawFileSystemEvent.self)
        let debouncer = ChangeDebouncer(window: 0.05, output: cont)
        let matcher = RenamedFileMatcher(window: 0.5, debouncer: debouncer)  // 真实 lstat 解析器

        // 1) 文件还活着时被观测到 → 缓存 inode。
        await matcher.feed(RawFileSystemEvent(path: oldURL.path, kind: .modified, sizeBytes: 7))
        // 2) 真实 mv。
        try FileManager.default.moveItem(at: oldURL, to: newURL)
        // 3) 旧路径已消失（实时 lstat 必失败，只能靠缓存），新路径出现。
        await matcher.feed(RawFileSystemEvent(path: oldURL.path, kind: .deleted))
        await matcher.feed(RawFileSystemEvent(path: newURL.path, kind: .created, sizeBytes: 7))
        await matcher.shutdown()
        cont.finish()

        var collected: [RawFileSystemEvent] = []
        for await event in stream { collected.append(event) }
        let renamed = collected.filter { $0.kind == .renamed }
        #expect(renamed.count == 1, "期望恰好一条 renamed，实际事件：\(collected.map(\.kind))")
        #expect(renamed.first?.path == newURL.path)
        #expect(renamed.first?.previousPath == oldURL.path)
    }
}

// MARK: - 端到端验收

@Suite("WS-Files: 事件流端到端（验收）", .timeLimit(.minutes(1)))
struct FileTrackingTests {

    /// 验收 1：新建文件后 1 秒内收到 `created`。
    @Test("验收：新建文件 1 秒内收到 created 事件")
    func createdWithinOneSecond() async throws {
        let dir = try makeScratch("created")
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FSEventsWatcher(debouncerWindow: 0.05, latency: 0.05, renameWindow: 0.2)
        let stream = try watcher.startObserving(roots: [dir], ignoredPatterns: [])
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)
        defer { pump.cancel() }

        // 先让监听真正建立，避免「写完才订阅」造成假阴性。
        try await Task.sleep(for: .milliseconds(150))
        // 必须非原子写：`atomically: true` 是「写 note.txt.sb-<uuid> 再 rename 覆盖」，
        // 在文件系统层面本来就是一次重命名 ⇒ 会被如实上报为 renamed（见 atomicSave 用例）。
        let file = dir.appendingPathComponent("note.txt")
        try "hello observatory".write(to: file, atomically: false, encoding: .utf8)

        let target = file.path
        let (ok, elapsed, harnessDebt) = await waitUntil(
            { $0.contains { $0.path == target && $0.kind == .created } },
            on: collector, timeout: .seconds(3)
        )
        let summary = await collector.summary
        await watcher.stopObserving()

        #expect(ok, "未收到 created 事件；已收到：\(summary)")
        expectWithinLatencyBudget((ok, elapsed, harnessDebt), line: 1.0, what: "created 事件")
    }

    /// 验收 2：改写一个已存在的文件后，1 秒内为该路径收到事件。
    @Test("验收：改写已存在文件后 1 秒内收到事件（就地覆写）")
    func modifiedWithinOneSecond() async throws {
        let dir = try makeScratch("modified")
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("note.txt")
        // 建档放在开始监听之前，并等内核把「建仓期间的历史事件」冲刷完再订阅：
        // 实测 FSEvents 会把 stream 建立瞬间仍在缓冲的 dir/file created 一并投递
        // （即便用了 EventIdSinceNow），若不等它排干，后面那次写会和未投递完的 created 合并。
        try "ab".write(to: file, atomically: false, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(800))

        // 去抖窗口设 0：让本用例只考察「watcher 的事件形状 + 时延」，不被合并逻辑干扰。
        let watcher = FSEventsWatcher(debouncerWindow: 0, latency: 0.05, renameWindow: 0.2)
        let stream = try watcher.startObserving(roots: [dir], ignoredPatterns: [])
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)
        defer { pump.cancel() }

        try await Task.sleep(for: .milliseconds(300))
        // 改写之前必须完全安静：若这里就有事件，说明内核把建档历史补投了进来，
        // 后面那条事件的身份就无法判定（本断言的作用是把这个歧义消灭掉）。
        let preWrite = await collector.snapshot
        let preWriteSummary = await collector.summary
        #expect(!preWrite.contains { $0.path == file.path }, "建档被补投：\(preWriteSummary)")

        // 就地改写**且保持长度不变**：FileHandle 覆写同一个 inode、不增删字节 ⇒ 只能给出 ItemModified。
        // 两个实测坑（都写进了 kind(forItemFlags:) 的文档）：
        //  · `String.write(atomically: false)` 内部会重建文件 ⇒ 上报为 ItemCreated；
        //  · 使文件**变长**的就地覆写（分配新块）在 APFS 上也带 ItemCreated 而不带 ItemModified。
        let payload = Data("cd".utf8)
        #expect(payload.count == 2, "必须与建档内容等长，否则 APFS 会按 created 上报")
        let handle = try FileHandle(forWritingTo: file)
        handle.seek(toFileOffset: 0)
        handle.write(payload)
        try handle.close()
        // 必须确认真的改到位：否则「没收到事件」可能是写入静默失败，而不是监听漏报。
        #expect(try String(contentsOf: file, encoding: .utf8) == "cd")

        let target = file.path
        let (ok, elapsed, harnessDebt) = await waitUntil(
            { $0.contains { $0.path == target } },
            on: collector, timeout: .seconds(3)
        )
        let summary = await collector.summary
        let events = await collector.snapshot
        await watcher.stopObserving()

        #expect(ok, "改写文件后完全没收到事件；已收到：\(summary)")
        expectWithinLatencyBudget((ok, elapsed, harnessDebt), line: 1.0, what: "改写事件")
        // 实测（本用例的 pre-write 静默断言已排除历史补投）：APFS 上「同 inode、同长度的就地覆写」
        // 被 FSEvents 打上 ItemCreated 而非 ItemModified ⇒ 内核给的就是 created。
        // 「这条事件是对既有文件的修改」这一语义不靠 created/modified 标签判定，
        // 而由 FileSnapshotter 的前后快照 + MyersDiffEngine 比对来确立（本工作流的另一半职责）。
        // ItemModified ⇒ .modified 的映射本身由 EventPipelineTests.flagToKindMapping 确定性覆盖。
        let kind = events.first(where: { $0.path == target })?.kind
        #expect(kind == .modified || kind == .created, "改写事件种类异常：\(kind?.rawValue ?? "nil")")
        #expect(events.first(where: { $0.path == target })?.sizeBytes == 2, "sizeBytes 应是改写后真实 stat 值")
    }

    /// 行为钉桩：原子保存（写 temp 再 rename）在**事件层**只能被报成两种形状之一，
    /// 且若报成 `renamed`，`previousPath` 必须指向 `.sb-` temp。
    ///
    /// ⚠️ 2026-09-20 改：原来这条写死「必须是 `renamed`」，在 load 95+ 的机器上会红
    /// （实测 `原子保存未表现为 temp→target 的 rename：["created"]`，且在合并前的基线 `187698f`
    /// 上同样红 ⇒ 与产品改动无关）。原因是**写错了钉的对象**：
    /// FSEvents 的合并粒度由内核按负载决定，机器忙时它自己就把 temp 创建与 rename 折叠成了
    /// 一个 `created`——也就是说「折叠」不是产品的选项，而是**随时可能由 OS 替我们做掉**的事实。
    /// ⇒ 真正需要保证的是产品**两种形状都得能处理**，而不是期望内核一定给 `renamed`。
    /// temp↔target 的**配对机制**由上面两条低层用例确定性钉住（直接喂 `RawFileSystemEvent`，
    /// 不经内核），所以把这条改成"容忍两种形状"并不会让配对失去覆盖。
    @Test("行为钉桩：原子保存上报为 renamed(temp→target) 或 created，不得报成 modified/deleted")
    func atomicSaveIsReportedAsRename() async throws {
        let dir = try makeScratch("atomic-save")
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FSEventsWatcher(debouncerWindow: 0.05, latency: 0.05, renameWindow: 0.2)
        let stream = try watcher.startObserving(roots: [dir], ignoredPatterns: [])
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)

        try await Task.sleep(for: .milliseconds(150))
        let target = dir.appendingPathComponent("saved.txt")
        try "atomic content".write(to: target, atomically: true, encoding: .utf8)

        let targetPath = target.path
        let (ok, _, _) = await waitUntil(
            { $0.contains { $0.path == targetPath } },
            on: collector, timeout: .seconds(10)
        )
        // 先停观测、再把 pump 排空，最后取快照：顺序颠倒会把「已发出但还没被 pump 取走」
        // 的事件当成没发生（同一族假阴性见 `unmatchedDeletionIsReleasedOnce`）。
        await watcher.stopObserving()
        await pump.value
        let events = await collector.snapshot

        let forTarget = events.filter { $0.path == targetPath }
        #expect(ok, "原子保存后完全没收到目标路径的事件")

        // 一个全新文件的原子保存，绝不能被报成「改了一个已存在的文件」或「被删了」——
        // 那会让 Engine 侧的 massDeletion / 修改类风险规则凭空起算。
        #expect(!forTarget.contains { $0.kind == .modified || $0.kind == .deleted },
                "原子保存被报成了修改/删除：\(forTarget.map { $0.kind.rawValue })")
        if let renamed = forTarget.first(where: { $0.kind == .renamed }) {
            #expect(renamed.previousPath?.contains(".sb-") == true,
                    "报了 renamed 但前路径不是 Foundation 的原子写 temp：\(renamed.previousPath ?? "nil")")
        }
    }

    /// 验收 3：删除文件后 1 秒内收到 `deleted`。
    ///
    /// 这条同时是 Engine 侧 massDeletion 风险规则的前提：旧实现把 `.deleted` 一直压到
    /// `stopObserving()` 才下发 ⇒ 运行期永远收不到。
    @Test("验收：删除文件 1 秒内收到 deleted 事件")
    func deletedWithinOneSecond() async throws {
        let dir = try makeScratch("deleted")
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = dir.appendingPathComponent("doomed.txt")
        try "delete me".write(to: file, atomically: true, encoding: .utf8)

        let watcher = FSEventsWatcher(debouncerWindow: 0.05, latency: 0.05, renameWindow: 0.2)
        let stream = try watcher.startObserving(roots: [dir], ignoredPatterns: [])
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)
        defer { pump.cancel() }

        try await Task.sleep(for: .milliseconds(150))
        try FileManager.default.removeItem(atPath: file.path)

        let target = file.path
        let (ok, elapsed, harnessDebt) = await waitUntil(
            { $0.contains { $0.path == target && $0.kind == .deleted } },
            on: collector, timeout: .seconds(3)
        )
        let summary = await collector.summary
        await watcher.stopObserving()

        #expect(ok, "未收到 deleted 事件；已收到：\(summary)")
        expectWithinLatencyBudget((ok, elapsed, harnessDebt), line: 1.0, what: "deleted 事件")
    }

    /// 验收 4：连续写同一文件 10 次 ⇒ 端到端只放行 1 条事件。
    ///
    /// 去抖窗口取 1.0 s（远大于「10 次写入 + 内核批量投递」的总跨度），
    /// 保证合并成一条是去抖器的行为而不是巧合。
    @Test("验收：连写 10 次去抖为 1 条事件")
    func tenWritesCoalesceToOne() async throws {
        let dir = try makeScratch("debounce")
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FSEventsWatcher(debouncerWindow: 1.0, latency: 0.05, renameWindow: 0.2)
        let stream = try watcher.startObserving(roots: [dir], ignoredPatterns: [])
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)
        defer { pump.cancel() }

        try await Task.sleep(for: .milliseconds(150))
        let file = dir.appendingPathComponent("hot.txt")
        for i in 0..<10 {
            try String(repeating: "line\(i)\n", count: i + 1).write(to: file, atomically: false, encoding: .utf8)
            try await Task.sleep(for: .milliseconds(15))
        }

        let target = file.path
        let (ok, _, _) = await waitUntil(
            { $0.contains { $0.path == target } },
            on: collector, timeout: .seconds(4)
        )
        // 静默期：确认窗口内没有第二条放行。
        let (second, _, _) = await waitUntil(
            { $0.filter { $0.path == target }.count > 1 },
            on: collector, timeout: .seconds(1)
        )
        let forwarded = await collector.snapshot
        await watcher.stopObserving()

        let forTarget = forwarded.filter { $0.path == target }
        #expect(ok, "10 次写入后一个事件都没收到")
        #expect(!second, "去抖窗口内出现了多条放行事件")
        #expect(forTarget.count == 1, "期望恰好 1 条，实际 \(forTarget.count) 条")
        #expect(forTarget.first?.kind == .created, "created 后跟 modified 应折叠为 created")
    }

    /// 验收 5：真实 `mv` 被合并为一条带 `previousPath` 的 `renamed`。
    @Test("验收：真实 mv 合并为 renamed 且带 previousPath")
    func renameIsPairedEndToEnd() async throws {
        let dir = try makeScratch("rename")
        defer { try? FileManager.default.removeItem(at: dir) }

        let oldURL = dir.appendingPathComponent("before.txt")
        let newURL = dir.appendingPathComponent("after.txt")

        let watcher = FSEventsWatcher(debouncerWindow: 0.05, latency: 0.05, renameWindow: 0.3)
        let stream = try watcher.startObserving(roots: [dir], ignoredPatterns: [])
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)
        defer { pump.cancel() }

        // 关键：文件必须在**开始监听之后**创建 —— 我们用 kFSEventStreamEventIdSinceNow，
        // 不重放历史。这样 watcher 才会「见过」旧路径并缓存它的 inode。
        try await Task.sleep(for: .milliseconds(150))
        try "rename me please".write(to: oldURL, atomically: false, encoding: .utf8)

        // 先让 watcher「见过」旧路径，从而缓存其 inode。
        let oldPath = oldURL.path
        let (seen, _, _) = await waitUntil({ $0.contains { $0.path == oldPath } }, on: collector, timeout: .seconds(3))
        #expect(seen, "前置条件失败：连旧文件的 created 都没收到")

        try FileManager.default.moveItem(at: oldURL, to: newURL)

        let newPath = newURL.path
        let (ok, elapsed, harnessDebt) = await waitUntil(
            { $0.contains { $0.kind == .renamed && $0.path == newPath && $0.previousPath == oldPath } },
            on: collector, timeout: .seconds(3)
        )
        let summary = await collector.summary
        await watcher.stopObserving()

        #expect(ok, "未把 mv 合并成 renamed；已收到：\(summary)")
        expectWithinLatencyBudget((ok, elapsed, harnessDebt), line: 1.0, what: "renamed 事件")
    }

    /// 验收 6：忽略规则在真实流里生效（`.build/`、`*.tmp`、追加规则）。
    @Test("验收：忽略规则命中路径不产生事件")
    func ignoredPathsAreNotEmitted() async throws {
        let dir = try makeScratch("ignored")
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FSEventsWatcher(debouncerWindow: 0.05, latency: 0.05, renameWindow: 0.2)
        let stream = try watcher.startObserving(roots: [dir], ignoredPatterns: ["secret/"])
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)
        defer { pump.cancel() }

        try await Task.sleep(for: .milliseconds(150))
        let fm = FileManager.default
        let buildDir = dir.appendingPathComponent(".build", isDirectory: true)
        try fm.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try "junk".write(to: buildDir.appendingPathComponent("out.txt"), atomically: true, encoding: .utf8)
        try "junk".write(to: dir.appendingPathComponent("scratch.tmp"), atomically: true, encoding: .utf8)
        let secretDir = dir.appendingPathComponent("secret", isDirectory: true)
        try fm.createDirectory(at: secretDir, withIntermediateDirectories: true)
        try "junk".write(to: secretDir.appendingPathComponent("key.txt"), atomically: true, encoding: .utf8)

        // 对照组：同时写一个「应当被观测到」的文件，证明不是整条流没跑起来造成的假通过。
        let normal = dir.appendingPathComponent("visible.txt")
        try "observable".write(to: normal, atomically: true, encoding: .utf8)

        let normalPath = normal.path
        let (controlArrived, _, _) = await waitUntil(
            { $0.contains { $0.path == normalPath } },
            on: collector, timeout: .seconds(3)
        )
        try await Task.sleep(for: .milliseconds(400))  // 给忽略路径的事件（若有）机会冒出来
        let events = await collector.snapshot
        await watcher.stopObserving()

        #expect(controlArrived, "对照文件都没收到事件 ⇒ 整条流未工作")
        #expect(!events.contains { $0.path.contains("/.build/") }, "忽略规则失效：出现了 .build 事件")
        #expect(!events.contains { $0.path.hasSuffix("scratch.tmp") }, "忽略规则失效：出现了 *.tmp 事件")
        #expect(!events.contains { $0.path.contains("/secret/") }, "追加的忽略规则未生效")
    }

    /// 护栏：默认配置（latency 0.3 / debounce 0.4）下事件仍能送达；停止后不再产出事件。
    @Test("护栏：默认配置可用 + stopObserving 后不再有事件")
    func defaultConfigWorksAndStopIsFinal() async throws {
        let dir = try makeScratch("defaults")
        defer { try? FileManager.default.removeItem(at: dir) }

        let watcher = FSEventsWatcher()
        let stream = try watcher.startObserving(roots: [dir], ignoredPatterns: [])
        let collector = EventCollector()
        let pump = startPump(stream, into: collector)
        defer { pump.cancel() }

        try await Task.sleep(for: .milliseconds(400))
        let file = dir.appendingPathComponent("default.txt")
        try "default config".write(to: file, atomically: true, encoding: .utf8)

        let target = file.path
        // 默认 0.3 + 0.4 ⇒ 上界取 3s（宽松护栏，不是 1 秒验收线）。
        let (ok, elapsed, harnessDebt) = await waitUntil({ $0.contains { $0.path == target } }, on: collector, timeout: .seconds(3))
        #expect(ok, "默认配置下没收到事件")
        expectWithinLatencyBudget((ok, elapsed, harnessDebt), line: 3.0, what: "默认配置事件")

        await watcher.stopObserving()
        let afterStop = await collector.snapshot.count

        try "should be invisible".write(to: dir.appendingPathComponent("after-stop.txt"), atomically: true, encoding: .utf8)
        try await Task.sleep(for: .milliseconds(900))
        let still = await collector.snapshot.count
        #expect(still == afterStop, "stopObserving 之后仍在产出事件")

        await watcher.stopObserving()  // 重复停止必须安全（幂等）
    }
}
