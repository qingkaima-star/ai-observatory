//
//  BeforeAfterDiffTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Diff
//  ─────────────────────────────────────────────────────────
//  需求③「文件行为追踪 + Before/After Diff」的引擎侧真值。
//
//  为什么这批用例存在：`ObservatoryEngine.makeFileChange` 原先写死
//  `guard isText, raw.kind == .created`，且唯一的生产调用点把 `oldText` 恒传 `nil`
//  ⇒「Agent 改一个已存在的文件」这个最主要场景**连单边 diff 都没有**，
//  Before/After 面板是空白的。这里钉的是：改前内容必须是**真的**（上一次观测到的那份），
//  拿不到时必须如实说明、且不许拿当前内容冒充增量。
//
//  Diff 用真 `MyersDiffEngine`（经 `Components.live` 拿，Platform 不是本 target 的依赖，
//  但 `Components.differ` 是公开的 `any DiffComputing`），因为「removed 行等于改前字面量」
//  这句话只有在真差分器下才有意义——换桩就变成测我自己的桩。
//

import Testing
import Foundation
import os
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

// MARK: - 夹具

/// 观测根。**不落在任何真实用户目录**：引擎对根只做字符串判定（不查存在性），
/// 而把个人路径写进测试代码会让托管 CI 只能对这些用例放行。
let fixtureRoot = "/observatory-fixture/Projects/demo"
let firstVersion = "alpha\nbeta\ngamma"
let secondVersion = "alpha\nBETA CHANGED\ngamma\ndelta"

/// 按路径供应「当前内容」的快照器。
///
/// 测试在投递事件**之前**改它，于是引擎读到的就是「变更之后磁盘上的那份」——
/// 与 FSEvents「事后通知」的语义同形：旧字节已经被覆盖，事后拿不到。
/// 这正是「改前内容必须由引擎自己留底」的原因，也是本文件的被测点。
final class ScriptedSnapshotter: FileSnapshotting, Sendable {
    private let lock = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    func setContent(_ text: String?, forPath path: String) {
        lock.withLock { $0[path] = text }
    }

    func snapshot(path: String) async -> FileSnapshot? {
        guard let text = lock.withLock({ state in state[path] }) else { return nil }
        return FileSnapshot(
            path: path,
            contentHash: "sha256:test",
            sizeBytes: UInt64(text.utf8.count),
            lineCount: text.split(separator: "\n", omittingEmptySubsequences: false).count
        )
    }

    /// 夹具内容都远小于 `maxSnippetBytes`，不做截断：真截断语义由 Platform 侧
    /// `FileSnapshotter` 自己的用例守，这里重复一遍只会掩盖本文件的被测点。
    func readTextSnippet(path: String, maxBytes: Int) async -> String? {
        lock.withLock { $0[path] }
    }
}

struct DiffHarness {
    var engine: ObservatoryEngine
    var store: ObservatoryStore
    var observer: StubFileObserver
    var snapshotter: ScriptedSnapshotter
}

/// 轮询到条件成立；超时记失败（避免固定 sleep 抖动）。
func waitUntilDiff(
    timeout: TimeInterval = 6,
    _ condition: @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: .seconds(timeout))
    while clock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    Issue.record("condition not met within \(timeout)s")
}

func makeDiffHarness(plaintext: Bool = true) async throws -> DiffHarness {
    let started = Date(timeIntervalSince1970: 1_900_000_000)
    let settings = ObservatorySettings(
        monitoredRoots: [fixtureRoot],
        ignoredPathPatterns: [],
        processScanIntervalSeconds: 3_600,
        storeDiffPlaintext: plaintext
    )
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let observer = StubFileObserver()
    let snapshotter = ScriptedSnapshotter()
    let mapper = ProjectMapper(resolver: { path in
        path.hasPrefix(fixtureRoot) ? fixtureRoot : nil
    })
    let agent = AgentInstance(
        kind: .claudeCode,
        pid: 41_001,
        displayName: "Claude Code",
        executablePath: "/usr/local/bin/claude",
        workingDirectory: fixtureRoot,
        startedAt: started,
        lastSeenAt: Date(),
        state: .running,
        detectedVia: .processName
    )
    // `live(settings:)` 只作差分器来源：它构造的都是纯值装配（无 IO、无线程），
    // 其余采集件一律换成桩，所以这里不依赖 Platform 的任何真实采集。
    let live = ObservatoryEngine.Components.live(settings: settings)
    let engine = ObservatoryEngine(
        settings: settings,
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: StubDetector(agents: [agent]),
            processInspector: StubProcessSource(),
            metrics: StubMetrics(),
            commandAuditor: StubAuditor(),
            fileObserver: observer,
            snapshotter: snapshotter,
            differ: live.differ,
            aggregator: TimelineAggregator(projectMapper: mapper),
            projectMapper: mapper
        )
    )
    await engine.rescanNow()
    return DiffHarness(engine: engine, store: store, observer: observer, snapshotter: snapshotter)
}

func rawEvent(
    _ path: String,
    _ kind: FileChangeKind,
    at date: Date,
    previousPath: String? = nil,
    sizeBytes: UInt64 = 0
) -> RawFileSystemEvent {
    RawFileSystemEvent(
        path: path,
        previousPath: previousPath,
        kind: kind,
        timestamp: date,
        sizeBytes: sizeBytes
    )
}

/// 按 (path, kind) 取回那条变更；不存在就 `#require` 失败（不返回 nil 让后续断言空转）。
func changeRow(
    of engine: ObservatoryEngine,
    path: String,
    kind: FileChangeKind
) async throws -> FileChange {
    let page = try await engine.fileChanges(matching: .all)
    let matches = page.items.filter { $0.path == path && $0.kind == kind }
    #expect(matches.count == 1, "\(path) 的 \(kind.rawValue) 变更应当恰好一条，实际 \(matches.count) 条")
    return try #require(matches.first)
}

// MARK: - 核心：改前内容是真的

@Suite("Engine: Before/After 的改前内容", .timeLimit(.minutes(2)))
struct BeforeAfterDiffTests {

    /// 本任务的核心成功判据。把 `ObservatoryEngine` 里传给 differ 的 `oldText`
    /// 改回 `nil`，这条会当场红在「removed 行为空」上。
    @Test("先创建再修改：diff 同时含 .removed(=第一版原文) 与 .added，且溯源为 lastObserved")
    func modifiedUsesLastObservedContent() async throws {
        let started = Date(timeIntervalSince1970: 1_900_000_000)
        let harness = try await makeDiffHarness()
        let path = "\(fixtureRoot)/Sources/Auth.swift"
        let createdAt = started.addingTimeInterval(3)
        let modifiedAt = started.addingTimeInterval(9)

        harness.snapshotter.setContent(firstVersion, forPath: path)
        harness.observer.emit(rawEvent(path, .created, at: createdAt, sizeBytes: 18))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }

        harness.snapshotter.setContent(secondVersion, forPath: path)
        harness.observer.emit(rawEvent(path, .modified, at: modifiedAt, sizeBytes: 30))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 2
        }
        await harness.store.flush()

        let created = try await changeRow(of: harness.engine, path: path, kind: .created)
        let modified = try await changeRow(of: harness.engine, path: path, kind: .modified)

        // 新建那一条：本来就没有可比版本。
        let createdDiff = try #require(try await harness.engine.fileDiff(for: created.id))
        #expect(createdDiff.baselineSource == .unavailableFirstSighting)
        #expect(createdDiff.baselineCapturedAt == nil)

        let diff = try #require(
            try await harness.engine.fileDiff(for: modified.id),
            "修改类变更必须落 diff，Before/After 面板不许空白"
        )
        #expect(diff.baselineSource == .lastObserved)
        #expect(diff.baselineCapturedAt == createdAt, "Before 的时刻就是上一次观测到该路径的时刻")
        #expect(diff.kind == .modified)
        #expect(diff.path == path)
        // 改前那份内容逐字出现在 removed 行里 —— 这就是「before 是真的」的证据。
        #expect(diff.lines.filter { $0.style == .removed }.map(\.text) == ["beta"])
        #expect(diff.lines.filter { $0.style == .added }.map(\.text) == ["BETA CHANGED", "delta"])
        #expect(
            !diff.lines.contains { $0.style == .added && $0.text == "alpha" },
            "改前就存在的行不许算成新增：那等于把旧内容冒充本次编辑的产出"
        )
        #expect(diff.linesAdded == 2)
        #expect(diff.linesRemoved == 1)
        // 变更行上的计数是给会话/项目汇总用的，只有可比才许填。
        #expect(modified.linesAdded == 2)
        #expect(modified.linesRemoved == 1)
        #expect(created.linesAdded == 3, "新建：全文确实都是新增，这个数是真的")
    }

    @Test("首次观测到修改（缓存里没有旧版）：出单边 diff 并写明原因，不伪造增量")
    func firstSightingModifiedIsSingleSided() async throws {
        let started = Date(timeIntervalSince1970: 1_900_010_000)
        let harness = try await makeDiffHarness()
        let path = "\(fixtureRoot)/notes.md"

        harness.snapshotter.setContent(firstVersion, forPath: path)
        harness.observer.emit(rawEvent(path, .modified, at: started, sizeBytes: 18))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let modified = try await changeRow(of: harness.engine, path: path, kind: .modified)
        let diff = try #require(
            try await harness.engine.fileDiff(for: modified.id),
            "拿不到改前版本也要有 diff + 原因，绝不许退回空白面板"
        )
        #expect(diff.baselineSource == .unavailableFirstSighting)
        #expect(diff.baselineCapturedAt == nil)
        #expect(diff.lines.contains { $0.style == .added }, "单边 diff：当前内容全部按新增呈现")
        #expect(
            !diff.lines.contains { $0.style == .removed },
            "没有可比版本就没有任何一行是「被删掉的」，凭空造 removed 行是撒谎"
        )
        #expect(modified.linesAdded == 0 && modified.linesRemoved == 0,
                "不可比时行计数保持 0（未知），不得拿全文行数冒充本次增量")
    }

    @Test("重命名后继续修改：基线跟着换到新路径，不退成首次观测")
    func renameCarriesBaselineForward() async throws {
        let started = Date(timeIntervalSince1970: 1_900_020_000)
        let harness = try await makeDiffHarness()
        let oldPath = "\(fixtureRoot)/Sources/Old.swift"
        let newPath = "\(fixtureRoot)/Sources/New.swift"

        harness.snapshotter.setContent(firstVersion, forPath: oldPath)
        harness.observer.emit(rawEvent(oldPath, .created, at: started, sizeBytes: 18))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        harness.observer.emit(rawEvent(newPath, .renamed, at: started.addingTimeInterval(2), previousPath: oldPath))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 2
        }

        harness.snapshotter.setContent(secondVersion, forPath: newPath)
        harness.observer.emit(rawEvent(newPath, .modified, at: started.addingTimeInterval(6), sizeBytes: 30))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 3
        }
        await harness.store.flush()

        let modified = try await changeRow(of: harness.engine, path: newPath, kind: .modified)
        let diff = try #require(try await harness.engine.fileDiff(for: modified.id))
        // 重命名不改内容，所以「上一次观测到的那份」仍然可比；丢掉这条链会谎称首次观测。
        #expect(diff.baselineSource == .lastObserved)
        #expect(diff.baselineCapturedAt == started)
        #expect(diff.lines.filter { $0.style == .removed }.map(\.text) == ["beta"])
    }

    @Test("非文本文件的修改不落 diff（isText 门槛不得被放宽）")
    func nonTextModificationProducesNoDiff() async throws {
        let started = Date(timeIntervalSince1970: 1_900_030_000)
        let harness = try await makeDiffHarness()
        let path = "\(fixtureRoot)/Assets/logo.png"

        harness.snapshotter.setContent(firstVersion, forPath: path)
        harness.observer.emit(rawEvent(path, .modified, at: started, sizeBytes: 4_096))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == 1
        }
        await harness.store.flush()

        let binary = try await changeRow(of: harness.engine, path: path, kind: .modified)
        #expect(binary.isText == false)
        #expect(binary.linesAdded == 0 && binary.linesRemoved == 0)
        #expect(try await harness.engine.fileDiff(for: binary.id) == nil)
    }

    /// 逐出必须真的发生：否则「留底」变成无界内存占用，而判据4 的预算不起这个。
    @Test("留底逐出后同路径再修改：退回单边 diff，而不是拿更老的版本硬凑")
    func evictedBaselineFallsBackToFirstSighting() async throws {
        let started = Date(timeIntervalSince1970: 1_900_040_000)
        let harness = try await makeDiffHarness()
        let capacity = ObservatoryEngine.baselineCacheCapacity
        let oldest = "\(fixtureRoot)/Filler0.swift"

        // 塞满并多塞一条：按 LRU，第一条 `Filler0.swift` 应当被逐出。
        for index in 0...capacity {
            let path = "\(fixtureRoot)/Filler\(index).swift"
            harness.snapshotter.setContent(firstVersion, forPath: path)
            harness.observer.emit(rawEvent(path, .created, at: started.addingTimeInterval(TimeInterval(index))))
        }
        let filled = capacity + 1
        try await waitUntilDiff(timeout: 20) {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == filled
        }

        harness.snapshotter.setContent(secondVersion, forPath: oldest)
        harness.observer.emit(rawEvent(oldest, .modified, at: started.addingTimeInterval(TimeInterval(filled)) + 1))
        try await waitUntilDiff {
            await harness.store.flush()
            return (try await harness.engine.fileChanges(matching: .all)).totalCount == filled + 1
        }
        await harness.store.flush()

        let modified = try await changeRow(of: harness.engine, path: oldest, kind: .modified)
        let diff = try #require(try await harness.engine.fileDiff(for: modified.id))
        #expect(diff.baselineSource == .unavailableFirstSighting,
                "容量 \(capacity) 条留底塞满后第一条应已被逐出")
        #expect(diff.baselineCapturedAt == nil)
        #expect(!diff.lines.contains { $0.style == .removed })
        // 逐出只影响「能不能报增量」，不影响这一条 diff 存在与否。
        #expect(modified.linesAdded == 0 && modified.linesRemoved == 0)
    }
}

// MARK: - 留底本身

/// 逐出与 LRU 顺序直接用类型测：走引擎要投几十条事件，抓不住「谁被逐出」这种细节。
@Suite("Engine: 改前内容留底的有界与逐出次序", .timeLimit(.minutes(1)))
struct FileTextBaselineCacheTests {

    private static let at = Date(timeIntervalSince1970: 1_700_000_000)

    @Test("记一次就能查回来，内容与时刻都不打折")
    func rememberThenLookup() {
        var cache = FileTextBaselineCache(capacity: 2)
        cache.remember("第一版\n", observedAt: Self.at, forPath: "/r/a.swift")
        #expect(cache.baseline(forPath: "/r/a.swift")?.text == "第一版\n")
        #expect(cache.baseline(forPath: "/r/a.swift")?.observedAt == Self.at)
        #expect(cache.count == 1)
    }

    @Test("超出容量才逐出，且逐的是最久没被碰的那条")
    func evictsLeastRecentlyUsedOnly() {
        var cache = FileTextBaselineCache(capacity: 2)
        cache.remember("a1", observedAt: Self.at, forPath: "/r/a")
        cache.remember("b1", observedAt: Self.at, forPath: "/r/b")
        #expect(cache.count == 2)

        // 先碰一下 a，让 b 成为最久未使用的那条。
        _ = cache.baseline(forPath: "/r/a")
        cache.remember("c1", observedAt: Self.at, forPath: "/r/c")

        #expect(cache.count == 2)
        #expect(cache.baseline(forPath: "/r/b") == nil, "最久未使用的 b 才该被逐出")
        #expect(cache.baseline(forPath: "/r/a")?.text == "a1", "刚被查过的 a 必须留下")
        #expect(cache.baseline(forPath: "/r/c")?.text == "c1")
    }

    @Test("同路径重复记录只占一格，且留下的是最新那份")
    func reRememberReplacesInPlace() {
        var cache = FileTextBaselineCache(capacity: 2)
        cache.remember("旧", observedAt: Self.at, forPath: "/r/a")
        cache.remember("新", observedAt: Self.at.addingTimeInterval(30), forPath: "/r/a")
        #expect(cache.count == 1)
        #expect(cache.baseline(forPath: "/r/a")?.text == "新")
        #expect(cache.baseline(forPath: "/r/a")?.observedAt == Self.at.addingTimeInterval(30))
    }

    @Test("删除即失底：同路径重新出现时按首次观测处理")
    func forgetDropsTheEntry() {
        var cache = FileTextBaselineCache(capacity: 2)
        cache.remember("x", observedAt: Self.at, forPath: "/r/a")
        cache.forget(path: "/r/a")
        #expect(cache.baseline(forPath: "/r/a") == nil)
        #expect(cache.count == 0)
    }

    @Test("重命名搬的是同一份内容和同一个时刻，且目标路径不会留下两份")
    func moveCarriesTextAndTimestamp() {
        var cache = FileTextBaselineCache(capacity: 3)
        cache.remember("内容", observedAt: Self.at, forPath: "/r/old")
        cache.remember("占位", observedAt: Self.at.addingTimeInterval(60), forPath: "/r/new")
        cache.move(from: "/r/old", to: "/r/new")

        #expect(cache.baseline(forPath: "/r/new")?.text == "内容", "改名不改内容 ⇒ 可比版本必须跟着走")
        #expect(cache.baseline(forPath: "/r/new")?.observedAt == Self.at,
                "时刻是那份内容被观测到的时刻，不该被改名刷新")
        #expect(cache.count == 1, "旧路径不能还留一份，否则同一路径两份底说不清是哪份")
        #expect(cache.baseline(forPath: "/r/old") == nil)
    }

    @Test("没有底的旧路径改名：不新增条目也不崩")
    func moveOfUnknownPathIsNoop() {
        var cache = FileTextBaselineCache(capacity: 2)
        cache.remember("x", observedAt: Self.at, forPath: "/r/kept")
        cache.move(from: "/r/never-seen", to: "/r/kept")
        #expect(cache.count == 1)
        #expect(cache.baseline(forPath: "/r/kept")?.text == "x")
    }

    @Test("容量 0 也要能用：按至少留一条处理，不出现逐空自己")
    func nonPositiveCapacityStillWorks() {
        var cache = FileTextBaselineCache(capacity: 0)
        cache.remember("x", observedAt: Self.at, forPath: "/r/a")
        #expect(cache.baseline(forPath: "/r/a")?.text == "x")
    }
}
