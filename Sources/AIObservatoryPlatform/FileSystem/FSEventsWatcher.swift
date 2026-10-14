//
//  FSEventsWatcher.swift
//  AIObservatoryPlatform — FileSystem 子模块
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  实现 FileActivityObserving：基于 FSEventStream 监听文件变更。
//  · sinceWhen = kFSEventStreamEventIdSinceNow（不重放历史，避免首启动刷出几万条）
//  · kFSEventStreamCreateFlagFileEvents（文件名级事件）+ UseCFTypes（回调路径是 CFArray）
//  · latency 默认 0.3s（内核粗去抖）+ 内部 ChangeDebouncer 0.4s（按路径细去抖）
//  · 回调 → PathFilter（忽略/自激抑制）→ 有界重扫 → FIFO 管道 → RenamedFileMatcher
//    → ChangeDebouncer → AsyncStream<RawFileSystemEvent>
//  · stopObserving 必须 Stop + SetDispatchQueue(nil) + Invalidate + Release，否则泄漏
//
//  本次修复的硬缺陷：
//  1) 逐事件 `Task {}` 投递 → 改为「一条 FIFO 管道 + 单消费者」，保证事件顺序；
//  2) `ItemRenamed` 直接标 `.renamed`（跳过配对）→ 批内按「消失端 ↔ 现存端」配对，
//     配不上再退化为 `.deleted`/`.created` 交给 RenamedFileMatcher 按 inode 跨批兜底；
//     且不再对已消失路径做无效 lstat 取 inode；
//  3) `MustScanSubDirs`（及 Kernel/UserDropped）伪造 `.modified` → 改为**真实有界重扫**，
//     只对确实存在、stat 成功的条目产出事件，动作未知一律 `.unknown`（禁止伪造数据）；
//  4) 拆除竞态与泄漏：代次闸门让在途回调立即失效，输出流 finish 之前先排空管道。
//

import Foundation
import os
import AIObservatoryCore

/// 文件监听抛出的错误。
public enum FileTrackingError: Error, Sendable {
    /// `roots` 为空 —— FSEventStream 没有可监听的目录。
    case emptyRoots
    /// `FSEventStreamCreate` 返回 `nil`。
    case streamCreationFailed
}

/// 基于 macOS FSEvents 的文件活动观察者。
///
/// 事件链路（严格保序）：
/// ```
/// FSEvents C 回调（专用串行队列）
///   → PathFilter（忽略规则 / 观测器自身数据库自激抑制）
///   → MustScanSubDirs / Dropped 标志 → 有界真实重扫
///   → AsyncStream<[RawFileSystemEvent]> 管道（一次回调 = 一个批次）
///   → 单个消费者 Task：await RenamedFileMatcher.feedBatch(...)
///   → ChangeDebouncer（按路径窗口合并）
///   → 对外 AsyncStream<RawFileSystemEvent>
/// ```
///
/// 生命周期：`startObserving` 可重复调用（会先停掉上一轮）；`stopObserving` 幂等，
/// 且保证「先排空、再 finish」，不会在 `finish()` 之后 yield。
///
/// 并发说明（`@unchecked Sendable` 的理由，AGENTS.md §5 要求写明）：
/// 本类的可变状态（流句柄、队列、上下文、continuation、消费者任务）全部收在 `state` 里，
/// 读写一律经由 `withLock(_:)`（`NSLock`）完成。`State` 内含 CoreFoundation 不透明类型
/// （`FSEventStreamRef` / `CFArray`），它们不是 `Sendable`，因此这里不能用
/// `OSAllocatedUnfairLock<State>`（它要求 `State: Sendable`），改用显式锁。
/// C 裸指针只在单个函数内使用，从不跨函数保存。
/// 之所以不做成 `actor`：契约里的 `startObserving(roots:ignoredPatterns:)` 是
/// **同步 throwing** 方法，无法在 actor 上实现。
public final class FSEventsWatcher: FileActivityObserving {

    /// 单次重扫最多枚举的条目数（防止在巨型目录上跑飞）。
    static let rescanEntryCap = 2_000
    /// 单次重扫的最大深度（根目录自身为第 0 层）。
    static let rescanDepthCap = 2

    private let filter: PathFilter
    private let debouncerWindow: TimeInterval
    private let latency: TimeInterval
    private let renameWindow: TimeInterval

    /// 受锁保护的全部可变状态。
    private struct State {
        var streamRef: FSEventStreamRef?
        /// FSEventStream 不接管路径数组的所有权，必须自己持有到流结束。
        var pathsToWatch: CFArray?
        var callbackQueue: DispatchQueue?
        var context: CallbackContext?
        var pipeline: Task<Void, Never>?
        var output: AsyncStream<RawFileSystemEvent>.Continuation?
    }

    private let stateLock = NSLock()
    private var state = State()

    /// 在锁保护下读写可变状态。`body` 必须同步完成（内部不得 await）。
    private func withLock<R>(_ body: (inout State) -> R) -> R {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body(&state)
    }

    /// 创建观察者。
    /// - Parameters:
    ///   - filter: 忽略规则过滤器，默认 `PathFilter()`（含默认规则与自身数据库抑制）。
    ///   - debouncerWindow: 按路径细去抖窗口（秒），默认 0.4。
    ///   - latency: FSEvents 内核批处理延迟（秒），默认 0.3（建议 0.3–0.5）。
    ///   - renameWindow: 删除项等待配对的时间窗（秒），默认 0.5，透传给
    ///     `RenamedFileMatcher(window:)`；到期即放行 `.deleted`。
    public init(
        filter: PathFilter = PathFilter(),
        debouncerWindow: TimeInterval = 0.4,
        latency: TimeInterval = 0.3,
        renameWindow: TimeInterval = 0.5
    ) {
        self.filter = filter
        self.debouncerWindow = debouncerWindow
        self.latency = latency
        self.renameWindow = renameWindow
    }

    deinit {
        // 尽力清理：契约要求先 `stopObserving()`（那是唯一能等待排空的路径），
        // 但即使调用方忘了，也不能泄漏 FSEventStream 句柄。
        let abandoned = withLock { s -> (CallbackContext?, AsyncStream<RawFileSystemEvent>.Continuation?) in
            if let stream = s.streamRef {
                FSEventStreamStop(stream)
                FSEventStreamSetDispatchQueue(stream, nil)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            let result = (s.context, s.output)
            s.streamRef = nil
            s.pathsToWatch = nil
            s.callbackQueue = nil
            s.context = nil
            s.pipeline?.cancel()
            s.pipeline = nil
            s.output = nil
            return result
        }
        abandoned.0?.markStopped()
        abandoned.0?.pipe.finish()
        abandoned.1?.finish()
    }

    // MARK: - FileActivityObserving

    /// 开始监听，返回原始事件流。
    ///
    /// - Parameters:
    ///   - roots: 要监听的目录（递归覆盖其下所有内容）。为空则抛 `FileTrackingError.emptyRoots`。
    ///   - ignoredPatterns: 在 `filter` 之上**追加**的忽略规则（不会重复叠加默认规则）。
    /// - Returns: 已经过去抖与合并的文件事件流。
    public func startObserving(roots: [URL], ignoredPatterns: [String]) throws -> AsyncStream<RawFileSystemEvent> {
        guard !roots.isEmpty else { throw FileTrackingError.emptyRoots }

        // 重复 start：先把上一轮停掉。本方法同步、无法 await 排空，
        // 因此对残留的消费者取「取消」而不是「等待」。
        let abandoned = teardownStream()
        abandoned.context?.pipe.finish()
        abandoned.output?.finish()
        abandoned.pipeline?.cancel()

        let effectiveFilter = ignoredPatterns.isEmpty ? filter : filter.appending(ignoredPatterns)

        // 对外输出：unbounded，保证停止时不丢已放行事件。
        let (stream, outputContinuation) = AsyncStream.makeStream(
            of: RawFileSystemEvent.self,
            bufferingPolicy: .unbounded
        )
        // 内部 FIFO 管道：一次回调 = 一个批次，单消费者按序 await 下游 actor。
        let (pipeline, pipelineContinuation) = AsyncStream.makeStream(
            of: [RawFileSystemEvent].self,
            bufferingPolicy: .unbounded
        )

        let debouncer = ChangeDebouncer(window: debouncerWindow, output: outputContinuation)
        let matcher = RenamedFileMatcher(window: renameWindow, debouncer: debouncer)
        let context = CallbackContext(filter: effectiveFilter, pipe: pipelineContinuation)

        // 单消费者：管道 finish 之后（所有已入队批次都投递完）再关闭 matcher，
        // 这样 matcher / debouncer 的尾部事件一定发生在 output.finish() 之前。
        let consumer = Task {
            for await batch in pipeline {
                if Task.isCancelled { break }
                await matcher.feedBatch(batch)
            }
            await matcher.shutdown()
        }

        let paths: CFArray = roots.map { $0.path(percentEncoded: false) as CFString } as CFArray
        var streamContext = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(context).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        // UseCFTypes 必需：缺它时回调的 eventPaths 是 `char **` 而非 CFArray，
        // 按 CFArray 解引用会直接崩溃。NoDefer 让首批事件不被内核再推迟一个 latency 周期。
        let createFlags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents
            | kFSEventStreamCreateFlagNoDefer
            | kFSEventStreamCreateFlagUseCFTypes
        )

        guard let eventStream = FSEventStreamCreate(
            nil,
            Self.callback,
            &streamContext,
            paths,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            CFTimeInterval(max(0, latency)),
            createFlags
        ) else {
            context.markStopped()
            // 消费者会在管道 finish 后自然退出并执行 matcher.shutdown()。
            // 本方法是同步 throwing，不能 await，因此这里刻意不等待任务。
            pipelineContinuation.finish()
            outputContinuation.finish()
            throw FileTrackingError.streamCreationFailed
        }

        let queue = DispatchQueue(label: "com.aix.aiobservatory.filetracking.fsevents")
        withLock { s in
            s.streamRef = eventStream
            s.pathsToWatch = paths
            s.callbackQueue = queue
            s.context = context
            s.pipeline = consumer
            s.output = outputContinuation
        }

        // 现代 API：回调派发到独立串行队列，无需自建 run loop 线程。
        FSEventStreamSetDispatchQueue(eventStream, queue)
        FSEventStreamStart(eventStream)

        // 消费方提前取消迭代时主动收尾（只在 .cancelled 时触发，避免与 stopObserving 互相回调）。
        outputContinuation.onTermination = { [weak self] termination in
            guard case .cancelled = termination else { return }
            Task { await self?.stopObserving() }
        }

        return stream
    }

    /// 停止监听：排空已入队事件 → 关闭合并层 → 结束输出流。
    ///
    /// 幂等，可重复调用。
    public func stopObserving() async {
        let pending = teardownStream()
        // 1) 代次闸门已置位、流已释放 ⇒ 不会再有新批次入队。
        // 2) finish 管道后，消费者的 `for await` 会处理完已入队批次再退出。
        pending.context?.pipe.finish()
        if let pipeline = pending.pipeline {
            await pipeline.value
        }
        // 3) 消费者内部已执行 matcher.shutdown()（含 debouncer.flushAll()），此处收尾输出流。
        pending.output?.finish()
    }

    /// 停止并释放 FSEventStream（Stop + SetDispatchQueue(nil) + Invalidate + Release）。
    ///
    /// 同时置代次闸门，使已在途的回调立即失效；返回被摘除的资源供调用方按序收尾。
    private func teardownStream() -> (pipeline: Task<Void, Never>?, output: AsyncStream<RawFileSystemEvent>.Continuation?, context: CallbackContext?) {
        withLock { s in
            let context = s.context
            context?.markStopped()

            if let stream = s.streamRef {
                FSEventStreamStop(stream)
                // 解除队列引用，否则 DispatchQueue 会被流一直持有。
                FSEventStreamSetDispatchQueue(stream, nil)
                FSEventStreamInvalidate(stream)
                FSEventStreamRelease(stream)
            }
            let result = (s.pipeline, s.output, context)
            s.streamRef = nil
            s.pathsToWatch = nil
            s.callbackQueue = nil
            s.context = nil
            s.pipeline = nil
            s.output = nil
            return result
        }
    }

    // MARK: - C 回调（稳定函数指针，不捕获任何上下文）

    /// FSEvents C 回调。
    ///
    /// 只在本函数内使用 `eventPaths` / `eventFlags` 这些由系统持有的裸指针：
    /// 立刻拷成值类型（路径字符串 + 标志位）再交给上下文，绝不跨函数保存指针。
    private static let callback: FSEventStreamCallback = { _, info, numEvents, eventPaths, eventFlags, _ in
        guard let info, numEvents > 0 else { return }
        let context = Unmanaged<CallbackContext>.fromOpaque(info).takeUnretainedValue()
        guard context.isActive else { return }

        // 前提：以 kFSEventStreamCreateFlagUseCFTypes 创建 ⇒ eventPaths 是 CFArray<CFString>。
        // 不接管所有权（系统在本轮回调返回前负责释放），因此只 takeUnretainedValue。
        let cfArray = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
        let count = Int(numEvents)
        guard CFArrayGetCount(cfArray) >= count else { return }

        var pairs: [(path: String, flags: FSEventStreamEventFlags)] = []
        pairs.reserveCapacity(count)
        for index in 0..<count {
            guard let rawPointer = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            let cfString = Unmanaged<CFString>.fromOpaque(rawPointer).takeUnretainedValue()
            pairs.append((path: cfString as String, flags: eventFlags[index]))
        }

        var batch: [RawFileSystemEvent] = []
        batch.reserveCapacity(pairs.count)
        context.appendEvents(forBatch: pairs, into: &batch)
        if !batch.isEmpty { context.pipe.yield(batch) }
    }

    // MARK: - 回调上下文

    /// C 回调的宿主对象：忽略规则、代次闸门、以及通向消费者的 FIFO 管道。
    ///
    /// 可变状态只有 `stoppedFlag`（`OSAllocatedUnfairLock<Bool>`）⇒ 可安全声明为 `Sendable`。
    final class CallbackContext: Sendable {
        let filter: PathFilter
        let pipe: AsyncStream<[RawFileSystemEvent]>.Continuation
        private let stoppedFlag = OSAllocatedUnfairLock(initialState: false)

        init(filter: PathFilter, pipe: AsyncStream<[RawFileSystemEvent]>.Continuation) {
            self.filter = filter
            self.pipe = pipe
        }

        /// 回调是否仍应被处理（`stopObserving` 之后为 `false`）。
        var isActive: Bool { stoppedFlag.withLock { !$0 } }

        /// 关闭闸门：之后所有在途回调立即被丢弃。
        func markStopped() {
            stoppedFlag.withLock { $0 = true }
        }

        /// 判断事件标志位。
        ///
        /// `FSEventStreamEventFlags` 在 Swift 侧就是 `UInt32`（不是 OptionSet），
        /// 而 `kFSEventStreamEventFlag*` 常量是 `Int`，因此统一按位与比较。
        private func has(_ flag: Int, _ flags: FSEventStreamEventFlags) -> Bool {
            flags & UInt32(truncatingIfNeeded: flag) != 0
        }

        /// 把**一次回调**里的全部原始条目翻译成 `RawFileSystemEvent` 批次。
        ///
        /// 重命名在这里就地定案：FSEvents 为一次 `mv` 抛出的两条 `ItemRenamed` 通常落在
        /// 同一批，但先后顺序不保证。批内按「已消失端（旧路径）↔ 仍存在端（新路径）」
        /// 按到达顺序配对，命中即直接产出带 `previousPath` 的 `.renamed`；
        /// 多出来的部分退化为 `.deleted` / `.created`（目录则 `.modified`），
        /// 由 `RenamedFileMatcher` 再用 inode 缓存做跨批兜底。
        func appendEvents(forBatch pairs: [(path: String, flags: FSEventStreamEventFlags)], into batch: inout [RawFileSystemEvent]) {
            var vanished: [RenameEndpoint] = []
            var appeared: [RenameEndpoint] = []

            for pair in pairs {
                let path = pair.path
                let flags = pair.flags
                // 与监听生命周期相关、不携带文件改动的标志：忽略。
                if has(kFSEventStreamEventFlagHistoryDone, flags) { continue }
                // 先过滤再 stat：被忽略的路径（node_modules / .build / 自身数据库）不该产生磁盘访问。
                if filter.shouldIgnore(path) { continue }

                // 事件溢出（内核/用户态丢事件）与「子目录需重扫」：具体动作无从得知，
                // 因此做**真实有界重扫**补回现状（动作未知记 `.unknown`）——
                // 既不伪造 `.modified`，也不静默丢弃。
                if has(kFSEventStreamEventFlagKernelDropped, flags)
                    || has(kFSEventStreamEventFlagUserDropped, flags)
                    || has(kFSEventStreamEventFlagMustScanSubDirs, flags) {
                    rescan(path: path, into: &batch)
                    continue
                }

                if has(kFSEventStreamEventFlagItemRenamed, flags) {
                    let endpoint = RenameEndpoint(
                        path: path,
                        fact: FileFact(path: path),
                        flaggedAsDirectory: has(kFSEventStreamEventFlagItemIsDir, flags)
                    )
                    if endpoint.fact.exists { appeared.append(endpoint) } else { vanished.append(endpoint) }
                    continue
                }
                appendSingleEvent(path: path, fact: FileFact(path: path), flags: flags, into: &batch)
            }

            guard !vanished.isEmpty || !appeared.isEmpty else { return }
            let now = Date()
            let pairedCount = min(vanished.count, appeared.count)
            for index in 0..<pairedCount {
                let oldSide = vanished[index]
                let newSide = appeared[index]
                batch.append(RawFileSystemEvent(
                    path: newSide.path,
                    previousPath: oldSide.path,
                    kind: .renamed,
                    timestamp: now,
                    isDirectory: newSide.fact.isDirectory,
                    sizeBytes: newSide.fact.size ?? 0
                ))
            }
            // 没配上的旧路径：真删除（文件已消失，size 无从取得 ⇒ 0 表示「无信息」）。
            for leftover in vanished.dropFirst(pairedCount) {
                batch.append(RawFileSystemEvent(
                    path: leftover.path, kind: .deleted, timestamp: now,
                    isDirectory: leftover.flaggedAsDirectory, sizeBytes: 0
                ))
            }
            // 没配上的现存路径：父目录本身被 rename 时也会带 ItemRenamed，
            // 它一直存在 ⇒ 只是内容变化，不能谎报成 created。
            for leftover in appeared.dropFirst(pairedCount) {
                batch.append(RawFileSystemEvent(
                    path: leftover.path,
                    kind: leftover.fact.isDirectory ? .modified : .created,
                    timestamp: now,
                    isDirectory: leftover.fact.isDirectory,
                    sizeBytes: leftover.fact.size ?? 0
                ))
            }
        }

        /// 由条目的 FSEvents 标志位推导变更种类。
        ///
        /// internal 而非 private：单测直接覆盖这张映射表，不依赖内核何时真的抛出事件。
        /// 判定顺序 `Removed > Created > Modified`：同一批标志里若同时出现 Created 与
        /// Modified（APFS 上就地覆写有时两者都带），按「先消失后出现」的语义取 Created。
        static func kind(forItemFlags flags: FSEventStreamEventFlags) -> FileChangeKind {
            if flags & UInt32(truncatingIfNeeded: kFSEventStreamEventFlagItemRemoved) != 0 { return .deleted }
            if flags & UInt32(truncatingIfNeeded: kFSEventStreamEventFlagItemCreated) != 0 { return .created }
            return .modified
        }

        /// 非重命名条目的直译。
        private func appendSingleEvent(path: String, fact: FileFact, flags: FSEventStreamEventFlags, into batch: inout [RawFileSystemEvent]) {
            batch.append(RawFileSystemEvent(
                path: path,
                kind: Self.kind(forItemFlags: flags),
                timestamp: Date(),
                isDirectory: fact.isDirectory,
                // deleted 事件的文件已消失，stat 必然失败 ⇒ 0 表示「无信息」，不猜测大小。
                sizeBytes: fact.size ?? 0
            ))
        }

        /// 有界真实重扫：只对**确实存在且 stat 成功**的条目产出事件，动作未知记 `.unknown`。
        ///
        /// 限制：重扫只能发现「现在有什么」，无法发现这期间被删掉的文件；
        /// 条目数超过 `rescanEntryCap` 或深度超过 `rescanDepthCap` 时停止枚举（宁可漏，也不伪造）。
        private func rescan(path: String, into batch: inout [RawFileSystemEvent]) {
            var statBuffer = stat()
            guard lstat(path, &statBuffer) == 0, (statBuffer.st_mode & S_IFMT) == S_IFDIR else {
                // 路径本身已不存在或不是目录：没有可重扫的子树，只报这一条现状。
                let fact = FileFact(path: path)
                guard let size = fact.size else { return }
                batch.append(RawFileSystemEvent(
                    path: path, kind: .unknown, timestamp: Date(),
                    isDirectory: fact.isDirectory, sizeBytes: size
                ))
                return
            }
            guard !filter.shouldIgnore(path) else { return }
            let fm = FileManager.default
            var budget = FSEventsWatcher.rescanEntryCap
            var stack: [(path: String, depth: Int)] = [(path, 0)]

            while let (directory, depth) = stack.popLast(), budget > 0 {
                guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { continue }
                for entry in entries.sorted() {
                    if budget <= 0 { return }
                    let child = (directory as NSString).appendingPathComponent(entry)
                    if filter.shouldIgnore(child) { continue }
                    let fact = FileFact(path: child)
                    guard let size = fact.size else { continue }   // 读不到就跳过，绝不编造
                    budget -= 1
                    batch.append(RawFileSystemEvent(
                        path: child, kind: .unknown, timestamp: Date(),
                        isDirectory: fact.isDirectory, sizeBytes: size
                    ))
                    if fact.isDirectory && depth + 1 <= FSEventsWatcher.rescanDepthCap {
                        stack.append((child, depth + 1))
                    }
                }
            }
        }

        /// 一个 `ItemRenamed` 端点。
        private struct RenameEndpoint {
            let path: String
            let fact: FileFact
            /// FSEvents 的 `ItemIsDir` 标志：路径已消失时唯一可用的类型线索。
            let flaggedAsDirectory: Bool
        }
    }
}

extension FSEventsWatcher: @unchecked Sendable {}

/// 一次 `lstat` 的结果。读不到 ⇒ `exists == false`、`size == nil`（不用 0 冒充已知大小）。
private struct FileFact {
    let exists: Bool
    let size: UInt64?
    let isDirectory: Bool

    init(path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else {
            self.exists = false
            self.size = nil
            self.isDirectory = false
            return
        }
        self.exists = true
        self.size = UInt64(st.st_size)
        self.isDirectory = (st.st_mode & S_IFMT) == S_IFDIR
    }
}
