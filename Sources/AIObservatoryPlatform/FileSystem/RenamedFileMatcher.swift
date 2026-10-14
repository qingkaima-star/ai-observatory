//
//  RenamedFileMatcher.swift
//  AIObservatoryPlatform — FileSystem 子模块
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  FSEvents 不直接给出 rename 的两个端点，这里用 inode 把「旧路径消失 + 新路径出现
//  （同一 inode）」合并判定为 renamed。
//
//  三条本次修复引入的硬约束：
//  1) `deleted` **必须在运行期就能流出**：每条删除挂一个到期任务，窗口到期仍未配上
//     对就作为 `.deleted` 下发；绝不出现「只在 stopObserving 才放行」或「按窗口裁剪时
//     静默丢弃」。Engine 的 massDeletion（批量删除）风险规则依赖这一点。
//  2) 旧路径在删除事件到来时已经消失，对它 `lstat` 必然失败 ⇒ 单靠实时 resolver
//     永远配不上对。因此额外维护「最后已知 inode 缓存」：路径还活着时记下 inode/size，
//     等它消失后再取出来用。
//  3) 一次 `mv` 的两端通常在**同一批**回调里，但先后顺序不确定 ⇒ 配对以「批」为单位
//     做（`feedBatch`），与到达顺序无关。
//

import Foundation
import AIObservatoryCore

/// 把「旧路径消失 + 新路径出现（同一 inode）」合并为 `renamed` 的匹配器。
///
/// 上游约定（`FSEventsWatcher`）：FSEvents 对一次 `mv` 抛出的两条 `ItemRenamed` 事件会被拆成
/// 「旧路径（已不存在）→ `.deleted`」与「新路径（存在）→ `.created`」，因此本类型只需处理
/// `.deleted` / `.created` 即可覆盖重命名。
///
/// 输出时序：
/// - 配上对的删除：不再单独下发，改为下发一条 `renamed`（`path` = 新路径，`previousPath` = 旧路径）；
/// - 没配上对的删除：在 `window` 到期后原样下发 `.deleted`；
/// - 其余事件（无匹配的 `created`、`modified`、`unknown`）：原样下发。
///
/// 已知限制（诚实声明，不伪造）：
/// - 进程开始监听**之前**就存在、且此后从未以「文件还在」状态被观测过的路径没有缓存 inode，
///   这类 `mv` 会退化成 `deleted` + `created` 两条事件；
/// - 「新路径」那一端先于「旧路径」那一端**跨批**到达时同样退化为两条事件
///   （同批内不受顺序影响）。
public actor RenamedFileMatcher {

    /// 解析某路径当前 inode 的闭包（测试可注入确定性假实现）。
    public typealias InodeResolver = @Sendable (String) -> UInt64?

    /// 待匹配删除项的缓冲窗口（秒）。到期即放行 `.deleted`。
    public let window: TimeInterval

    /// inode 缓存条目上限：超出后淘汰「最久未见」的条目，避免长期运行时无界增长。
    static let inodeCacheCapacity = 2048

    private let inodeResolver: InodeResolver
    private let debouncer: ChangeDebouncer

    private var pendingDeletions: [PendingDeletion] = []
    private var expiryTasks: [UInt64: Task<Void, Never>] = [:]
    private var nextDeletionID: UInt64 = 1
    private var inodeFacts: [String: InodeFact] = [:]
    private var isShutdown = false

    /// 创建重命名匹配器。
    /// - Parameters:
    ///   - window: 删除项的配对窗口（秒），默认 0.5；到期即放行 `.deleted`。
    ///   - inodeResolver: 实时 inode 解析器，默认基于 `lstat`。
    ///   - debouncer: 下游去抖器，合并后的事件交给它输出。
    public init(
        window: TimeInterval = 0.5,
        inodeResolver: @escaping InodeResolver = RenamedFileMatcher.defaultInodeResolver,
        debouncer: ChangeDebouncer
    ) {
        self.window = max(0, window)
        self.inodeResolver = inodeResolver
        self.debouncer = debouncer
    }

    // MARK: - 主流程

    /// 喂入一批同属一次 FSEvents 回调的原始事件（批内配对，与到达顺序无关）。
    ///
    /// - Parameter events: 一批事件。`shutdown()` 之后调用是无害的空操作
    ///   （拆除顺序由 `FSEventsWatcher` 保证：先停止投递、再 `shutdown()`）。
    public func feedBatch(_ events: [RawFileSystemEvent]) async {
        guard !events.isEmpty, !isShutdown else { return }

        // 兜底：先放行已超过窗口的历史删除（与各自的到期任务互斥，只会放行一次）。
        await expireStaleDeletions(before: Date())

        var deletions: [PendingDeletion] = []
        var creations: [RawFileSystemEvent] = []
        var others: [RawFileSystemEvent] = []
        deletions.reserveCapacity(events.count)

        for event in events {
            switch event.kind {
            case .deleted:
                let cached = inodeFacts[event.path]
                deletions.append(PendingDeletion(
                    id: 0,  // 真实 id 在确认要缓冲时再分配；配对成功者不会占用 id。
                    path: event.path,
                    inode: inodeResolver(event.path) ?? cached?.inode,
                    timestamp: event.timestamp,
                    knownSize: event.sizeBytes > 0 ? event.sizeBytes : (cached?.size ?? 0),
                    isDirectory: event.isDirectory
                ))
            case .created:
                creations.append(event)
            default:
                others.append(event)
            }
        }

        // 1) 先解析所有新建路径的 inode（顺带刷新缓存），再配对。
        var resolvedCreations: [(event: RawFileSystemEvent, inode: UInt64?)] = []
        resolvedCreations.reserveCapacity(creations.count)
        for creation in creations {
            resolvedCreations.append((creation, rememberIfAlive(path: creation.path, size: creation.sizeBytes, isDirectory: creation.isDirectory)))
        }

        // 2) 先与「更早批次里仍在缓冲的删除」配对（跨批：delete 先到、create 后到）。
        //    漏掉这一步会导致 renamed 永远配不成——历史缓冲项只在到期时退化成 deleted。
        var unmatchedCreations: [(event: RawFileSystemEvent, inode: UInt64?)] = []
        for creation in resolvedCreations {
            if let inode = creation.inode, let prior = takePendingDeletion(matching: inode) {
                inodeFacts[prior.path] = nil
                await emitRenamed(from: prior, to: creation.event)
            } else {
                unmatchedCreations.append(creation)
            }
        }

        // 3) 再与「同批删除」配对：一条删除找它之后**最早**出现的同 inode 新建（FIFO，稳定可预期）。
        var pairedCreationSlots: Set<Int> = []
        var pairedDeletionSlots: Set<Int> = []
        for deletionSlot in deletions.indices {
            guard let inode = deletions[deletionSlot].inode,
                  let index = unmatchedCreations.indices.first(where: {
                      unmatchedCreations[$0].inode == inode && !pairedCreationSlots.contains($0)
                  })
            else { continue }
            pairedCreationSlots.insert(index)
            pairedDeletionSlots.insert(deletionSlot)
            inodeFacts[deletions[deletionSlot].path] = nil
            await emitRenamed(from: deletions[deletionSlot], to: unmatchedCreations[index].event)
        }

        // 4) 没配上的新建原样放行。
        for (slot, resolved) in unmatchedCreations.enumerated() where !pairedCreationSlots.contains(slot) {
            await debouncer.feed(resolved.event)
        }

        // 4) 其余事件原样放行（顺带缓存它们所代表路径的 inode）。
        for event in others {
            rememberIfAlive(path: event.path, size: event.sizeBytes, isDirectory: event.isDirectory)
            await debouncer.feed(event)
        }

        // 5) 没配上的删除进入缓冲窗口，等待后续批次的同 inode 新建；到期即放行 `.deleted`。
        for (slot, deletion) in deletions.enumerated() where !pairedDeletionSlots.contains(slot) {
            await buffer(deletion)
        }
    }

    /// 喂入单条事件（等价于 `feedBatch([event])`）。
    public func feed(_ event: RawFileSystemEvent) async {
        await feedBatch([event])
    }

    /// 把缓冲区内所有尚未配对的删除立即作为 `.deleted` 放行（安全网，可重复调用）。
    public func flushPending() async {
        let draining = pendingDeletions
        pendingDeletions.removeAll(keepingCapacity: false)
        for del in draining {
            expiryTasks[del.id]?.cancel()
            expiryTasks[del.id] = nil
            await debouncer.feed(Self.deletedEvent(from: del))
        }
    }

    /// 关闭：取消所有到期任务 → 放行未配对的删除 → 让去抖器立即放行累积事件。
    ///
    /// 可重复调用；第二次起不再产生任何输出。
    public func shutdown() async {
        guard !isShutdown else { return }
        isShutdown = true
        for task in expiryTasks.values { task.cancel() }
        expiryTasks.removeAll(keepingCapacity: false)
        await flushPending()
        await debouncer.flushAll()
    }

    // MARK: - 删除缓冲

    /// 取出（并取消到期任务）缓冲区里第一条 inode 相同的删除。
    ///
    /// 从 `pendingDeletions` 移除即是「已消费」的唯一判据，因此与到期任务、
    /// `flushPending()` 天然互斥，不会重复下发。
    private func takePendingDeletion(matching inode: UInt64) -> PendingDeletion? {
        guard let index = pendingDeletions.firstIndex(where: { $0.inode == inode }) else { return nil }
        let deletion = pendingDeletions.remove(at: index)
        expiryTasks[deletion.id]?.cancel()
        expiryTasks[deletion.id] = nil
        return deletion
    }

    /// 下发一条合并后的 `renamed`：`path` = 新路径，`previousPath` = 旧路径。
    private func emitRenamed(from deletion: PendingDeletion, to creation: RawFileSystemEvent) async {
        await debouncer.feed(RawFileSystemEvent(
            path: creation.path,
            previousPath: deletion.path,
            kind: .renamed,
            timestamp: creation.timestamp,
            isDirectory: creation.isDirectory,
            sizeBytes: creation.sizeBytes
        ))
    }

    /// 把一条未配对的删除放进缓冲区并挂到期任务。
    private func buffer(_ deletion: PendingDeletion) async {
        let id = nextDeletionID
        nextDeletionID += 1
        pendingDeletions.append(PendingDeletion(
            id: id,
            path: deletion.path,
            inode: deletion.inode,
            timestamp: deletion.timestamp,
            knownSize: deletion.knownSize,
            isDirectory: deletion.isDirectory
        ))

        // 闭包只捕获 Sendable 的 id 与 delay，避免把整个非 Sendable 结构带进 @Sendable 闭包。
        let delay = window
        expiryTasks[id] = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            guard let self, !Task.isCancelled else { return }
            await self.expire(id: id)
        }
    }

    /// 到期任务回调：仅当该项仍在缓冲区（即没被后来的新建配走）时才放行，保证只放行一次。
    private func expire(id: UInt64) async {
        expiryTasks[id] = nil
        guard let index = pendingDeletions.firstIndex(where: { $0.id == id }) else { return }
        let deletion = pendingDeletions.remove(at: index)
        await debouncer.feed(Self.deletedEvent(from: deletion))
    }

    /// 放行所有时间戳已超出窗口的删除（`flushPending` 之外的第二条兜底路径）。
    private func expireStaleDeletions(before now: Date) async {
        guard pendingDeletions.contains(where: { now.timeIntervalSince($0.timestamp) >= window }) else { return }
        var released: [PendingDeletion] = []
        var kept: [PendingDeletion] = []
        for deletion in pendingDeletions {
            if now.timeIntervalSince(deletion.timestamp) >= window {
                expiryTasks[deletion.id]?.cancel()
                expiryTasks[deletion.id] = nil
                released.append(deletion)
            } else {
                kept.append(deletion)
            }
        }
        pendingDeletions = kept
        for deletion in released { await debouncer.feed(Self.deletedEvent(from: deletion)) }
    }

    private static func deletedEvent(from deletion: PendingDeletion) -> RawFileSystemEvent {
        RawFileSystemEvent(
            path: deletion.path,
            kind: .deleted,
            timestamp: deletion.timestamp,
            isDirectory: deletion.isDirectory,
            sizeBytes: deletion.knownSize
        )
    }

    // MARK: - inode 缓存

    /// 路径此刻仍存在则记下它的 inode 与大小，并返回解析到的 inode（读不到为 `nil`，不伪造）。
    @discardableResult
    private func rememberIfAlive(path: String, size: UInt64, isDirectory: Bool) -> UInt64? {
        // 目录不参与重命名配对：`mv` 目录会牵连大量子项事件，按目录自身的普通事件处理即可。
        guard !isDirectory, let inode = inodeResolver(path) else { return nil }
        inodeFacts[path] = InodeFact(path: path, inode: inode, size: size, seenAt: Date())
        trimCacheIfNeeded()
        return inode
    }

    /// 缓存超容量时淘汰最久未见的条目。
    private func trimCacheIfNeeded() {
        guard inodeFacts.count > Self.inodeCacheCapacity else { return }
        let excess = inodeFacts.count - Self.inodeCacheCapacity
        let victims = inodeFacts.values.sorted { $0.seenAt < $1.seenAt }.prefix(excess).map(\.path)
        for path in victims { inodeFacts[path] = nil }
    }

    // MARK: - 类型

    /// 待配对删除项。`id` 让「到期任务」「被后来的新建配走」「flushPending」三条路径互斥。
    private struct PendingDeletion {
        var id: UInt64
        let path: String
        let inode: UInt64?
        let timestamp: Date
        let knownSize: UInt64
        let isDirectory: Bool
    }

    /// 路径还活着时观测到的事实，供其消失后回落取用。
    private struct InodeFact {
        let path: String
        let inode: UInt64
        let size: UInt64
        let seenAt: Date
    }

    // MARK: - 默认实现

    /// 默认 inode 解析：基于 `lstat` 取 `st_ino`；路径不存在（如已被删除）时返回 `nil`。
    public static func defaultInodeResolver(_ path: String) -> UInt64? {
        var st = stat()
        guard lstat(path, &st) == 0 else { return nil }
        return UInt64(st.st_ino)
    }
}
