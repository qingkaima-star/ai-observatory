//
//  EventPipelineTests.swift
//  AIObservatoryPlatformTests — FileSystem
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  事件整形层的**确定性**单测：直接调用 `FSEventsWatcher.CallbackContext.appendEvents(forBatch:)`
//  与 `ChangeDebouncer`，用真实文件 + 合成标志位覆盖「标志 → 事件」的映射。
//
//  为什么需要这一层：FSEvents 何时抛事件、把哪些路径放进同一批，由内核决定，
//  端到端用例只能验「能不能收到」，无法确定性地验「标志位翻成了什么种类」。
//  本文件把这部分从内核时序里摘出来，成为可重复、零等待的断言。
//
//  临时目录建在 `Scratch.directory(...)`（当前检出自带的 `.scratch-tests/`）下，defer 清理。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 辅助

/// 把若干 `kFSEventStreamEventFlag*` 常量合成一个标志位。
private func flagSet(_ values: Int...) -> FSEventStreamEventFlags {
    var acc: UInt32 = 0
    for value in values { acc |= UInt32(truncatingIfNeeded: value) }
    return acc
}

private func pipelineContext(dbPaths: [String] = [], additional: [String] = []) -> (FSEventsWatcher.CallbackContext, AsyncStream<[RawFileSystemEvent]>.Continuation) {
    let (_, continuation) = AsyncStream.makeStream(of: [RawFileSystemEvent].self)
    let context = FSEventsWatcher.CallbackContext(
        filter: PathFilter(additionalPatterns: additional, databasePaths: dbPaths),
        pipe: continuation
    )
    return (context, continuation)
}

private func translate(
    _ context: FSEventsWatcher.CallbackContext,
    _ entries: [(path: String, flags: FSEventStreamEventFlags)]
) -> [RawFileSystemEvent] {
    var batch: [RawFileSystemEvent] = []
    context.appendEvents(forBatch: entries, into: &batch)
    return batch
}

private func makeScratch(_ purpose: String) throws -> URL {
    try Scratch.directory("files-pipeline-\(purpose)")
}

// MARK: - 标志位映射

@Suite("WS-Files: 事件整形（确定性）")
struct EventPipelineTests {

    @Test("标志位 → 变更种类：created / removed / modified 及组合")
    func flagToKindMapping() {
        let item = kFSEventStreamEventFlagItemIsFile
        #expect(FSEventsWatcher.CallbackContext.kind(forItemFlags: flagSet(kFSEventStreamEventFlagItemCreated, item)) == .created)
        #expect(FSEventsWatcher.CallbackContext.kind(forItemFlags: flagSet(kFSEventStreamEventFlagItemRemoved, item)) == .deleted)
        #expect(FSEventsWatcher.CallbackContext.kind(forItemFlags: flagSet(kFSEventStreamEventFlagItemModified, item)) == .modified)
        // 就地覆写有时同时带 Created + Modified ⇒ 取 Created（先消失后出现的语义）
        #expect(FSEventsWatcher.CallbackContext.kind(
            forItemFlags: flagSet(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemModified, item)) == .created)
        // Removed 优先级最高：同时带 Removed + Created 时按删除处理
        #expect(FSEventsWatcher.CallbackContext.kind(
            forItemFlags: flagSet(kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemCreated, item)) == .deleted)
        // 只有目录级标志（无 Item* 标志）⇒ modified（目录内容确实变了）
        #expect(FSEventsWatcher.CallbackContext.kind(forItemFlags: flagSet(kFSEventStreamEventFlagItemIsDir)) == .modified)
    }

    @Test("翻译：ItemCreated 事件带真实 size 与 isDirectory")
    func createdEventCarriesRealStat() throws {
        let dir = try makeScratch("created-stat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try "1234567890".write(to: file, atomically: false, encoding: .utf8)

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let events = translate(context, [(file.path, flagSet(kFSEventStreamEventFlagItemCreated, kFSEventStreamEventFlagItemIsFile))])

        #expect(events.count == 1)
        #expect(events.first?.kind == .created)
        #expect(events.first?.sizeBytes == 10)
        #expect(events.first?.isDirectory == false)
    }

    @Test("翻译：ItemRemoved 的 size 为 0（文件已消失，不猜大小）")
    func removedEventDoesNotFabricateSize() throws {
        let dir = try makeScratch("removed-stat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let gone = dir.appendingPathComponent("gone.txt")   // 故意不存在

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let events = translate(context, [(gone.path, flagSet(kFSEventStreamEventFlagItemRemoved, kFSEventStreamEventFlagItemIsFile))])

        #expect(events.count == 1)
        #expect(events.first?.kind == .deleted)
        #expect(events.first?.sizeBytes == 0)
    }

    @Test("翻译：忽略规则命中的条目不产生事件（且不做 stat）")
    func ignoredEntriesProduceNothing() throws {
        let dir = try makeScratch("ignored-stat")
        defer { try? FileManager.default.removeItem(at: dir) }
        let nm = dir.appendingPathComponent("node_modules", isDirectory: true)
        try FileManager.default.createDirectory(at: nm, withIntermediateDirectories: true)
        let inside = nm.appendingPathComponent("lib.js")
        try "code".write(to: inside, atomically: false, encoding: .utf8)

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let events = translate(context, [
            (inside.path, flagSet(kFSEventStreamEventFlagItemModified, kFSEventStreamEventFlagItemIsFile)),
            (dir.path, flagSet(kFSEventStreamEventFlagItemIsDir)),
        ])
        #expect(events.count == 1, "node_modules 内的条目应被过滤，只剩目录自身那条")
        #expect(events.first?.path == dir.path)
    }

    // MARK: - 重命名配对（批内）

    @Test("翻译：同批的 ItemRenamed 两端合并为带 previousPath 的 renamed")
    func renameEndpointsInOneBatchMerge() throws {
        let dir = try makeScratch("rename-batch")
        defer { try? FileManager.default.removeItem(at: dir) }
        let newURL = dir.appendingPathComponent("after.txt")
        try "content".write(to: newURL, atomically: false, encoding: .utf8)
        let oldPath = dir.appendingPathComponent("before.txt").path   // 已消失

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let renamed = flagSet(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsFile)
        // 故意让「新路径」先于「旧路径」到达：批内配对应与顺序无关。
        let events = translate(context, [(newURL.path, renamed), (oldPath, renamed)])

        #expect(events.count == 1)
        #expect(events.first?.kind == .renamed)
        #expect(events.first?.path == newURL.path)
        #expect(events.first?.previousPath == oldPath)
        #expect(events.first?.sizeBytes == 7)
    }

    @Test("翻译：父目录自身带 ItemRenamed 时不得谎报为 created")
    func loneDirectoryRenameEndpointIsModified() throws {
        let dir = try makeScratch("dir-rename")
        defer { try? FileManager.default.removeItem(at: dir) }

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let events = translate(context, [(dir.path, flagSet(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsDir))])

        #expect(events.count == 1)
        #expect(events.first?.kind == .modified, "一直存在的目录被 rename 时只是内容变化，不是新建")
        #expect(events.first?.isDirectory == true)
        #expect(events.first?.previousPath == nil)
    }

    @Test("翻译：孤立的新路径 rename 端点退化为 created，孤立旧路径退化为 deleted")
    func unpairedRenameEndpointsDegrade() throws {
        let dir = try makeScratch("rename-unpaired")
        defer { try? FileManager.default.removeItem(at: dir) }
        let live = dir.appendingPathComponent("live.txt")
        try "abc".write(to: live, atomically: false, encoding: .utf8)

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let events = translate(context, [
            (live.path, flagSet(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsFile)),
            (dir.appendingPathComponent("ghost.txt").path, flagSet(kFSEventStreamEventFlagItemRenamed, kFSEventStreamEventFlagItemIsFile)),
        ])
        // 只有一条 rename 记录能配上（这里 vanished 与 appeared 各一条 ⇒ 直接配成 renamed）。
        #expect(events.count == 1)
        #expect(events.first?.kind == .renamed)
        #expect(events.first?.previousPath == dir.appendingPathComponent("ghost.txt").path)
    }

    // MARK: - 重扫，不伪造

    @Test("MustScanSubDirs：真实重扫只报现存条目，动作未知记 unknown")
    func mustScanSubDirsDoesRealRescan() throws {
        let dir = try makeScratch("rescan")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "aaaa".write(to: dir.appendingPathComponent("one.txt"), atomically: false, encoding: .utf8)
        try "bb".write(to: dir.appendingPathComponent("two.txt"), atomically: false, encoding: .utf8)

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let events = translate(context, [(dir.path, flagSet(kFSEventStreamEventFlagMustScanSubDirs, kFSEventStreamEventFlagItemIsDir))])

        let names = Set(events.map { ($0.path as NSString).lastPathComponent })
        #expect(names == ["one.txt", "two.txt"], "重扫应只发现这两个真实存在的条目，实际：\(names)")
        #expect(events.allSatisfy { $0.kind == .unknown }, "重扫发现的动作未知条目必须记 unknown，不得伪造 modified")
        let sizes = Dictionary(uniqueKeysWithValues: events.map { (($0.path as NSString).lastPathComponent, $0.sizeBytes) })
        #expect(sizes["one.txt"] == 4)
        #expect(sizes["two.txt"] == 2)
    }

    @Test("UserDropped / KernelDropped：走重扫补回现状，而不是静默丢弃")
    func droppedFlagsTriggerRescan() throws {
        let dir = try makeScratch("dropped")
        defer { try? FileManager.default.removeItem(at: dir) }
        try "xyz".write(to: dir.appendingPathComponent("keep.txt"), atomically: false, encoding: .utf8)

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        for dropped in [kFSEventStreamEventFlagUserDropped, kFSEventStreamEventFlagKernelDropped] {
            let events = translate(context, [(dir.path, flagSet(dropped, kFSEventStreamEventFlagItemIsDir))])
            #expect(!events.isEmpty, "标志 \(dropped) 被静默丢弃了")
            #expect(events.contains { $0.path.hasSuffix("keep.txt") && $0.sizeBytes == 3 })
        }
    }

    @Test("HistoryDone：生命周期标志不产生任何事件")
    func historyDoneIsIgnored() throws {
        let dir = try makeScratch("history")
        defer { try? FileManager.default.removeItem(at: dir) }
        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let events = translate(context, [(dir.path, flagSet(kFSEventStreamEventFlagHistoryDone))])
        #expect(events.isEmpty)
    }

    @Test("重扫遵守深度与条目上限（不递归到第 rescanDepthCap 层以下）")
    func rescanIsBounded() throws {
        let dir = try makeScratch("rescan-bound")
        defer { try? FileManager.default.removeItem(at: dir) }
        // depth1/a.txt 与 depth1/depth2/a.txt：第 2 层及更深不应被枚举。
        let l1 = dir.appendingPathComponent("l1", isDirectory: true)
        let l2 = l1.appendingPathComponent("l2", isDirectory: true)
        let l3 = l2.appendingPathComponent("l3", isDirectory: true)
        try FileManager.default.createDirectory(at: l3, withIntermediateDirectories: true)
        try "x".write(to: l1.appendingPathComponent("a.txt"), atomically: false, encoding: .utf8)
        try "y".write(to: l2.appendingPathComponent("b.txt"), atomically: false, encoding: .utf8)
        try "z".write(to: l3.appendingPathComponent("c.txt"), atomically: false, encoding: .utf8)

        let (context, pipe) = pipelineContext()
        defer { pipe.finish() }
        let events = translate(context, [(dir.path, flagSet(kFSEventStreamEventFlagMustScanSubDirs))])
        let names = Set(events.map { ($0.path as NSString).lastPathComponent })
        #expect(names.contains("a.txt"), "第 1 层应被枚举")
        #expect(names.contains("b.txt"), "第 2 层（深度 < rescanDepthCap）应被枚举")
        #expect(!names.contains("c.txt"), "第 3 层应被深度上限截断")
    }

    // MARK: - 代次闸门

    @Test("markStopped 之后 isActive 立即为 false（在途回调据此丢弃）")
    func generationGateFlipsImmediately() {
        let (context, pipe) = pipelineContext()
        #expect(context.isActive)
        context.markStopped()
        #expect(!context.isActive)
        pipe.finish()
    }
}
