//
//  AttributionGapTests.swift
//  AIObservatoryEngineTests
//
//  Owner: ws/engaudit（ICR-0009 落地，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  「未归属」不是一格，是四条出口（`ObservatoryEngine.attributedAgent(forPath:)` 返回 nil 的
//  四条路），而界面今天只能说"不知道是谁"。ICR-0009 批准的那三条要求在这里逐条钉：
//   ① **不落库** —— 账活在引擎进程内，`file_changes` 一个字段都没多（第 6 条用例反向钉住：
//      库里读不到任何 gap 列，且重启后归零这件事由"账不在 store 里"保证）；
//   ② **出口形状照 ICR-0006 方案 A** —— 一个只读访问器 + `nil` 表达"还没有读数"，
//      与"有读数、零缺口"必须是两个不同的状态（第 7 条专门钉这个，那正是我写第一版时撒的谎）；
//   ③ **四条出口各自可数 + 一条总数恒等式** —— 每条一个用例，再加一条混合场景：
//      `Σcounts == 库里 agent_id 为空的行数`，且归上了因的那几条**一格都不占**。
//
//  驱动方式：真引擎 + 桩采集件（`StubDetector` 换注册表、`StubFileObserver` 投事件），
//  不是直接调私有函数——要证的正是"文件事件进来之后这张账真的被记了一笔"。
//  `StubProcessSource` 必须为每个 agent 供一条进程记录，否则 #39 的启动孤儿收口会把它们
//  当成已死对象结算掉，测的就是收口而不是归因。
//
//  路径全部合成（`/observatory-fixture/…`），与 `BeforeAfterDiffTests` 同一根。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore

// MARK: - 夹具

private let gapStarted = Date(timeIntervalSince1970: 1_900_004_000)

private func gapAgent(pid: Int32, workingDirectory: String?) -> AgentInstance {
    AgentInstance(
        kind: .claudeCode,
        pid: pid,
        displayName: "Gap Fixture Agent",
        executablePath: "/usr/local/bin/gap-fixture",
        workingDirectory: workingDirectory,
        startedAt: gapStarted,
        lastSeenAt: gapStarted.addingTimeInterval(60),
        state: .running,
        detectedVia: .processName
    )
}

/// 每个 agent 都配一条进程记录（`lastSeenAt` 用"现在"，避免被陈旧判定关掉会话）。
private func gapRecords(for agents: [AgentInstance]) -> [ProcessRecord] {
    agents.map {
        ProcessRecord(
            pid: $0.pid, parentPID: 1, name: "gap-fixture",
            executablePath: $0.executablePath, startTime: gapStarted,
            workingDirectory: $0.workingDirectory
        )
    }
}

private struct GapHarness {
    var engine: ObservatoryEngine
    var store: ObservatoryStore
    var observer: StubFileObserver
    var detector: StubDetector
}

private func gapHarness(_ agents: [AgentInstance]) async throws -> GapHarness {
    let settings = ObservatorySettings(
        monitoredRoots: [fixtureRoot],
        ignoredPathPatterns: [],
        processScanIntervalSeconds: 3_600,
        storeDiffPlaintext: true
    )
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let observer = StubFileObserver()
    let detector = StubDetector(agents: agents)
    let live = ObservatoryEngine.Components.live(settings: settings)
    let mapper = ProjectMapper(resolver: { path in
        path.hasPrefix(fixtureRoot) ? fixtureRoot : nil
    })
    let engine = ObservatoryEngine(
        settings: settings,
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: detector,
            processInspector: StubProcessSource(records: gapRecords(for: agents)),
            metrics: StubMetrics(),
            commandAuditor: StubAuditor(),
            fileObserver: observer,
            snapshotter: StubSnapshotter(),
            differ: live.differ,
            aggregator: TimelineAggregator(projectMapper: mapper),
            projectMapper: mapper
        )
    )
    await engine.rescanNow()
    return GapHarness(engine: engine, store: store, observer: observer, detector: detector)
}

/// 投一条事件并等它进库（归因发生在同一条路径上，所以库里有行 = 账已经记过）。
private func emitAndWait(
    _ harness: GapHarness,
    _ path: String,
    expectingRows expected: Int
) async throws {
    harness.observer.emit(rawEvent(path, .modified, at: gapStarted.addingTimeInterval(120)))
    try await waitUntilDiff(timeout: 8) {
        // 显式 flush：写入走 BatchWriter 的定时批，轮询不该依赖那个节奏
        // （引擎没 start()，批只会被显式 flush 或被填满时冲掉）。
        await harness.store.flush()
        let page = try await harness.store.fileChanges(matching: FileChangeQuery(limit: 200))
        return page.items.count == expected
    }
}

private func unattributedRows(_ store: ObservatoryStore) async throws -> Int {
    await store.flush()
    let page = try await store.fileChanges(matching: FileChangeQuery(limit: 200))
    return page.items.filter { $0.agentID == nil }.count
}

// MARK: - ③ 四条出口，各自一条

@Suite("未归属的机制分布：四条出口各自可数")
struct AttributionGapExitsTests {

    @Test("出口一：注册表里一个 Agent 都没有 ⇒ nothingDetected")
    func nothingDetected() async throws {
        let harness = try await gapHarness([])
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/a.swift", expectingRows: 1)
        let gap = try #require(await harness.engine.currentAttributionGap())
        #expect(gap.count(of: .nothingDetected) == 1)
        #expect(gap.total == 1)
    }

    @Test("出口二：检出了但工作目录不可用（GUI 宿主的 cwd 是 `/`）⇒ workingDirectoryUnusable")
    func unusableWorkingDirectory() async throws {
        let harness = try await gapHarness([gapAgent(pid: 41_002, workingDirectory: "/")])
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/b.swift", expectingRows: 1)
        let gap = try #require(await harness.engine.currentAttributionGap())
        #expect(gap.count(of: .workingDirectoryUnusable) == 1)
        // 只记一格：不能既算"不可用"又算"不在名下"，否则 Σcounts 会大于未归属行数。
        #expect(gap.count(of: .outsideEveryWorkingDirectory) == 0)
        #expect(gap.total == 1)
    }

    @Test("出口三：检出了但拿不到工作目录读数 ⇒ detectedWithoutWorkingDirectory")
    func missingWorkingDirectory() async throws {
        let harness = try await gapHarness([gapAgent(pid: 41_003, workingDirectory: nil)])
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/c.swift", expectingRows: 1)
        let gap = try #require(await harness.engine.currentAttributionGap())
        #expect(gap.count(of: .detectedWithoutWorkingDirectory) == 1)
        #expect(gap.total == 1)
    }

    @Test("出口四：目录可用但路径不在任何名下 ⇒ outsideEveryWorkingDirectory")
    func outsideEveryDirectory() async throws {
        let harness = try await gapHarness([
            gapAgent(pid: 41_004, workingDirectory: "/observatory-fixture/Projects/other")
        ])
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/d.swift", expectingRows: 1)
        let gap = try #require(await harness.engine.currentAttributionGap())
        #expect(gap.count(of: .outsideEveryWorkingDirectory) == 1)
        #expect(gap.total == 1)
    }

    @Test("优先级：一个候选目录不可用、另一个可用但不匹配 ⇒ 记「观测缺口」而不是「不属于谁」")
    func gapOutranksGenuineMiss() async throws {
        let harness = try await gapHarness([
            gapAgent(pid: 41_005, workingDirectory: "/"),
            gapAgent(pid: 41_006, workingDirectory: "/observatory-fixture/Projects/other")
        ])
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/e.swift", expectingRows: 1)
        let gap = try #require(await harness.engine.currentAttributionGap())
        #expect(gap.count(of: .workingDirectoryUnusable) == 1)
        #expect(gap.count(of: .outsideEveryWorkingDirectory) == 0)
    }
}

// MARK: - ③ 恒等式 + ② 读数形状 + ① 不落库

@Suite("未归属的机制分布：恒等式与读数形状")
struct AttributionGapIdentityTests {

    @Test("混合场景：Σcounts == 库里 agent_id 为空的行数，归上了因的一格都不占")
    func countsMatchUnattributedRows() async throws {
        let harness = try await gapHarness([
            gapAgent(pid: 41_007, workingDirectory: fixtureRoot),
            gapAgent(pid: 41_008, workingDirectory: "/observatory-fixture/Projects/other")
        ])
        // 3 条落在 fixtureRoot 名下（可归因），2 条落在别处（不可归因，且两个目录都可用）。
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/one.swift", expectingRows: 1)
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/two.swift", expectingRows: 2)
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/three.swift", expectingRows: 3)
        try await emitAndWait(harness, "/elsewhere/four.swift", expectingRows: 4)
        try await emitAndWait(harness, "/elsewhere/five.swift", expectingRows: 5)

        let gap = try #require(await harness.engine.currentAttributionGap())
        let rows = try await unattributedRows(harness.store)
        // 恒等式：四条出口相加 == 未归属总条数 == 库里 agent_id 为空的行数。
        #expect(gap.total == rows, "账上 \(gap.total) 条、库里 \(rows) 条 ⇒ 有一边在偷偷记或漏记")
        #expect(gap.count(of: .nothingDetected)
                + gap.count(of: .workingDirectoryUnusable)
                + gap.count(of: .detectedWithoutWorkingDirectory)
                + gap.count(of: .outsideEveryWorkingDirectory) == gap.total)
        #expect(gap.total == 2)
        #expect(gap.count(of: .outsideEveryWorkingDirectory) == 2)
    }

    @Test("读数形状：一条都没处理过时是 nil；处理过且全部归上因时是「零缺口」而不是 nil")
    func ledgerOpensOnFirstEventEvenWhenAttributed() async throws {
        let fresh = try await gapHarness([gapAgent(pid: 41_009, workingDirectory: fixtureRoot)])
        // 引擎刚装配完、一条文件事件都没投 ⇒ 还没有读数。
        #expect(await fresh.engine.currentAttributionGap() == nil,
                "还没有任何读数时不许凭空给一个「零缺口」")

        try await emitAndWait(fresh, "\(fixtureRoot)/Sources/owned.swift", expectingRows: 1)
        let gap = try #require(await fresh.engine.currentAttributionGap())
        #expect(gap.total == 0, "这条归上了因，一格都不该占")
        #expect(gap.count(of: .outsideEveryWorkingDirectory) == 0)
    }

    @Test("不落库：账只在引擎里，file_changes 的行除既有字段外没多出什么")
    func gapIsNotPersisted() async throws {
        let harness = try await gapHarness([gapAgent(pid: 41_010, workingDirectory: "/")])
        try await emitAndWait(harness, "\(fixtureRoot)/Sources/f.swift", expectingRows: 1)
        await harness.store.flush()
        let page = try await harness.store.fileChanges(matching: FileChangeQuery(limit: 50))
        let row = try #require(page.items.first)
        // 归因失败的那条行，字段仍是"没有 agent"，而不是多带了一个 gap 值：
        #expect(row.agentID == nil)
        #expect(row.agentKind == .unknown)
        // 换一个引擎实例（等价于重启）⇒ 账归零，证明它没被持久化。
        let restarted = try await gapHarness([gapAgent(pid: 41_010, workingDirectory: "/")])
        #expect(await restarted.engine.currentAttributionGap() == nil)
    }
}
