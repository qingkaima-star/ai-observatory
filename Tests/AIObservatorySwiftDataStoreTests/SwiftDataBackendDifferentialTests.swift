//
//  SwiftDataBackendDifferentialTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: WS-SwiftData
//
//  **两个后端的直接对照**：同一批数据同时喂 SQLite 后端（`AIObservatoryStore`）与
//  SwiftData 后端，逐条查询比对 `items` / `totalCount` / `offset` 与逐字段内容。
//
//  为什么以前做不到、以及为什么它比传递性论证强：
//    · `Package.swift` 先前没给本测试 target `AIObservatoryStore` 依赖（已按
//      IFR-swiftdata-test-target-dependency 补上），所以此前只能走
//      `SwiftData ≡ InMemory` + `SQLite ≡ InMemory` 的传递性。
//    · 传递性有一个结构性盲区：**`InMemoryObservatoryService` 只按时间列排序，没有第二键**。
//      时间戳相同的两行，它的顺序是实现定义的；而两个真后端都必须
//      `ORDER BY 时间, id DESC`。这类行**只有两后端并排跑才测得准**——本文件第 1 组就是这么测的。
//    · 另一个盲区是「基准已过期」：哪天 `StoreParityTests` 被改弱，传递性论证会静默失效，
//      而我的测试不会变红。直接对照没有这个依赖。
//
//  同时本文件也是「可切换」这件事的**可执行证明**：`seed(_:)` 只吃
//  `any ObservatoryService & ObservatoryWriting`，两个后端走同一段代码填数据。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryStore
import AIObservatorySwiftDataStore
import AIObservatoryTestSupport

// MARK: - Fixture

/// 主 fixture 的时间戳**两两互不相同**，好让「逐项顺序完全一致」成为强断言。
/// 并列时间戳（InMemory 覆盖不到的那类形状）由 `makeTiedPair()` 单独造一套数据来测。
private enum Diff {
    static let base = Date(timeIntervalSinceReferenceDate: 800_000_000)
    static let tied = base.addingTimeInterval(600)

    static func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    static let agentClaude = UUID()
    static let agentCodex = UUID()
    static let agentCursor = UUID()
    static let sessionA = UUID()
    static let sessionB = UUID()
    static let sessionRunning = UUID()
    static let projectAlpha = FixturePaths.projectAlpha
    static let projectBeta = FixturePaths.projectBeta
    static let changeText = UUID()
    static let changeBinary = UUID()

    /// 三条**同刻**事件的 id。这里是普通实体 id（不是派生聚合值，故不归 StableID 管）；
    /// 期望顺序由本数组排序得出，所以不需要写死字面量，也就不用强解 `UUID(uuidString:)!`。
    static let tiedIDs: [UUID] = [UUID(), UUID(), UUID()]

    static let agents: [AgentInstance] = [
        AgentInstance(id: agentClaude, kind: .claudeCode, pid: 4001, parentPID: 3001,
                      displayName: "Claude Code", executablePath: "/usr/local/bin/claude",
                      workingDirectory: projectAlpha, tty: "/dev/ttys003",
                      startedAt: at(10), lastSeenAt: at(900), state: .running,
                      cpuPercent: 12.5, memoryBytes: UInt64(Int64.max) + 4_096,
                      childPIDs: [4002, 4003]),
        AgentInstance(id: agentCodex, kind: .openAICodex, pid: 5001,
                      displayName: "Codex", executablePath: "/usr/local/bin/codex",
                      startedAt: at(20), lastSeenAt: at(800), state: .idle,
                      cpuPercent: 3.25, memoryBytes: 900_000_000, detectedVia: .argumentSignature),
        AgentInstance(id: agentCursor, kind: .cursorAgent, pid: 6001,
                      displayName: "Cursor", executablePath: "/Applications/Cursor",
                      startedAt: at(30), lastSeenAt: at(40), state: .terminated,
                      memoryBytes: 0, detectedVia: .bundleIdentifier),
    ]

    static let risks: [RiskEvent] = [
        RiskEvent(timestamp: at(100), level: .critical, category: .massDeletion,
                  title: "批量删除", detail: "rm -rf 命中产物目录",
                  agentID: agentClaude, agentKind: .claudeCode, sessionID: sessionA,
                  command: "rm -rf ./out", filePaths: ["\(projectAlpha)/out"],
                  requiresConfirmation: true, matchedRuleID: "R-1"),
        RiskEvent(timestamp: at(110), level: .high, category: .sensitivePathAccess,
                  title: "读取凭据", detail: "命中 secrets.env",
                  agentID: agentClaude, agentKind: .claudeCode, sessionID: sessionA,
                  filePaths: ["\(projectAlpha)/secrets.env"], isAcknowledged: true,
                  matchedRuleID: "R-2"),
        RiskEvent(timestamp: tied, level: .medium, category: .dangerousCommand,
                  title: "强推", detail: "", agentID: agentCodex, agentKind: .openAICodex,
                  sessionID: sessionB, command: "git push --force"),
        RiskEvent(timestamp: at(30), level: .low, category: .unknown,
                  title: "旧提权", detail: "sudo", agentKind: .genericCLIAgent),
    ]

    static let sessions: [AgentSession] = [
        AgentSession(id: sessionA, displayIndex: 101, kind: .claudeCode, agentID: agentClaude,
                     title: "重构持久层", projectPath: projectAlpha, startedAt: at(50),
                     endedAt: at(950), modifiedFileCount: 3, createdFileCount: 1,
                     deletedFileCount: 1, commandCount: 2, failedCommandCount: 0,
                     cpuSeconds: 42.5, peakCPUPercent: 78.5,
                     peakMemoryBytes: UInt64(Int64.max) + 1, estimatedTokens: 18_000,
                     riskEventCount: 2, outcome: .success),
        AgentSession(id: sessionB, displayIndex: 102, kind: .openAICodex, agentID: agentCodex,
                     title: "补测试", projectPath: projectBeta, startedAt: at(60),
                     endedAt: at(960), commandCount: 1, failedCommandCount: 1,
                     cpuSeconds: 12, peakCPUPercent: 40, peakMemoryBytes: 1_000,
                     estimatedTokens: 4_000, riskEventCount: 1, outcome: .failed),
        AgentSession(id: sessionRunning, displayIndex: 103, kind: .claudeCode, agentID: agentClaude,
                     title: "排查崩溃", startedAt: at(970), outcome: .running),
    ]

    static let events: [TimelineEvent] = {
        var events: [TimelineEvent] = [
            TimelineEvent(timestamp: at(100), sessionID: sessionA, agentID: agentClaude,
                          agentKind: .claudeCode, kind: .fileCreated, title: "创建 Engine.swift",
                          summary: "新文件", filePath: "\(projectAlpha)/Sources/Engine.swift",
                          cost: ResourceCost(cpuSeconds: 0.4, memoryBytes: 240_000_000,
                                             bytesRead: 4096, bytesWritten: 8192),
                          riskLevel: .low, projectPath: projectAlpha),
            TimelineEvent(timestamp: at(30), sessionID: nil, agentID: agentCursor,
                          agentKind: .cursorAgent, kind: .unknown, title: "旧活动",
                          summary: "窗口外", riskLevel: .low),
            TimelineEvent(timestamp: at(500), sessionID: sessionB, agentID: agentCodex,
                          agentKind: .openAICodex, kind: .commandExecuted, title: "跑测试",
                          summary: "swift test", command: "swift test --filter X", exitCode: 1,
                          durationSeconds: 3.5, riskLevel: .medium, projectPath: projectBeta),
        ]
        for (offset, id) in tiedIDs.enumerated() {
            events.append(TimelineEvent(
                id: id, timestamp: at(600 + Double(offset)),
                sessionID: sessionA, agentID: agentClaude,
                agentKind: .claudeCode, kind: offset.isMultiple(of: 2) ? .fileModified : .fileRead,
                title: "同刻事件 \(offset)", summary: "三条时间戳完全相同",
                filePath: "\(projectAlpha)/tied\(offset).swift",
                riskLevel: offset == 2 ? .critical : .high, projectPath: projectAlpha
            ))
        }
        return events
    }()

    static let fileChanges: [FileChange] = [
        FileChange(id: changeText, path: "\(projectAlpha)/Sources/Engine.swift", kind: .created,
                   timestamp: at(100), agentID: agentClaude, sessionID: sessionA,
                   agentKind: .claudeCode, sizeBytes: 4_096, linesAdded: 120,
                   projectPath: projectAlpha),
        FileChange(id: changeBinary, path: "\(projectAlpha)/Assets/icon.png", kind: .modified,
                   timestamp: at(101), agentID: agentClaude, sessionID: sessionA,
                   agentKind: .claudeCode, sizeBytes: 2, previousSizeBytes: 1, isText: false,
                   riskLevel: .medium, projectPath: projectAlpha),
        FileChange(path: "\(projectAlpha)/tmp/scratch.txt", kind: .deleted, timestamp: at(102),
                   agentID: agentClaude, sessionID: sessionA, agentKind: .claudeCode,
                   sizeBytes: 0, previousSizeBytes: 512, linesRemoved: 12, riskLevel: .high,
                   projectPath: projectAlpha),
        // sizeBytes > Int64.max：两侧都必须按 bit-pattern 往返
        FileChange(path: "\(projectBeta)/big.bin", kind: .modified, timestamp: at(103),
                   agentKind: .openAICodex, sizeBytes: UInt64(Int64.max) + 9_999,
                   projectPath: projectBeta),
    ]

    static let diffs: [FileDiff] = [
        FileDiff(id: changeText, path: "\(projectAlpha)/Sources/Engine.swift", kind: .created,
                 lines: [
                     DiffLine(style: .hunkHeader, text: "@@ -0,0 +1,2 @@", newLineNumber: 1),
                     DiffLine(style: .added, text: "import SwiftData", newLineNumber: 1),
                     DiffLine(style: .removed, text: "import SQLite3", oldLineNumber: 1),
                     DiffLine(style: .context, text: "", oldLineNumber: 2, newLineNumber: 2),
                 ],
                 linesAdded: 120, linesRemoved: 1, capturedAt: at(100)),
        FileDiff(id: changeBinary, path: "\(projectAlpha)/Assets/icon.png", kind: .modified,
                 lines: [], isBinary: true, isTruncated: true, capturedAt: at(101)),
    ]

    static let commands: [CommandRecord] = [
        CommandRecord(executable: "rm", arguments: ["-rf", "./out"], workingDirectory: projectAlpha,
                      agentID: agentClaude, sessionID: sessionA, agentKind: .claudeCode,
                      startedAt: at(100), endedAt: at(101), exitCode: 0, outcome: .success,
                      isDestructive: true, requiresConfirmation: true, riskLevel: .critical,
                      projectPath: projectAlpha),
        CommandRecord(executable: "git", arguments: ["push", "--force"], workingDirectory: projectBeta,
                      agentID: agentCodex, sessionID: sessionB, agentKind: .openAICodex,
                      startedAt: at(500), endedAt: at(501), exitCode: 128, outcome: .failure,
                      riskLevel: .high, projectPath: projectBeta),
        CommandRecord(executable: "swift", arguments: ["test"], agentID: agentClaude,
                      sessionID: sessionA, agentKind: .claudeCode, startedAt: tied,
                      outcome: .running, projectPath: projectAlpha),
        CommandRecord(executable: "sudo", arguments: ["rm", "-rf", "/System/Volumes/Data"],
                      agentKind: .cursorAgent, startedAt: at(30), endedAt: at(31), exitCode: -1,
                      outcome: .terminated, isDestructive: true, riskLevel: .critical),
    ]

    static let performanceSamples: [PerformanceSample] = [
        PerformanceSample(timestamp: at(100), sessionID: sessionA, agentID: agentClaude,
                          cpuPercent: 20, memoryBytes: 500_000_000,
                          diskReadBytesPerSecond: 1_024, diskWriteBytesPerSecond: 2_048,
                          networkBytesIn: 4_096, networkBytesOut: 8_192),
        PerformanceSample(timestamp: tied, sessionID: sessionA, agentID: agentClaude,
                          cpuPercent: 60.5, memoryBytes: UInt64(Int64.max), gpuPercent: 12.5,
                          thermalCelsius: 74.25, powerWatts: 18.75),
        PerformanceSample(timestamp: at(500), sessionID: sessionB, agentID: agentCodex,
                          cpuPercent: 5, memoryBytes: 100),
    ]

    /// v3 新字段的三种情形必须互不塌缩：有值 / 拿不到（带原因）/ 真的零。
    static let systemSamples: [SystemPerformanceSample] = [
        SystemPerformanceSample(timestamp: at(100), cpuTotalPercent: 33.5, cpuSystemPercent: 5,
                                cpuUserPercent: 28.5, memoryUsedBytes: 16_000_000_000,
                                memoryTotalBytes: 34_359_738_368, diskReadBytesPerSecond: 512,
                                diskWriteBytesPerSecond: 256, loadAverage1m: 2.5,
                                networkInBytesPerSecond: 1_048_576.5,
                                networkOutBytesPerSecond: 2_097_152.25,
                                gpuActivityPercent: 37.5),
        SystemPerformanceSample(timestamp: at(200), cpuTotalPercent: 10, cpuSystemPercent: 1,
                                cpuUserPercent: 9, memoryUsedBytes: 1, memoryTotalBytes: 2,
                                loadAverage1m: 0.5,
                                networkAvailability: .counterRegression),
        // 「真的没有流量」= 0.0，与上面的 nil 是两回事
        SystemPerformanceSample(timestamp: tied, cpuTotalPercent: 1, cpuSystemPercent: 1,
                                cpuUserPercent: 0, memoryUsedBytes: 0, memoryTotalBytes: 0,
                                loadAverage1m: 0, networkInBytesPerSecond: 0,
                                networkOutBytesPerSecond: 0, gpuActivityPercent: 0),
    ]

    static let projects: [ProjectActivity] = [
        ProjectActivity(id: projectAlpha, name: "Alpha", path: projectAlpha,
                        fileChangeCount: 3, commandCount: 2, sessionCount: 2, riskEventCount: 2,
                        codeGrowthLines: 120, codeShrinkLines: 12,
                        agentContributions: [
                            AgentContribution(kind: .claudeCode, relativeShare: 0.75, eventCount: 6),
                        ],
                        hotFiles: [
                            FileHeat(path: "\(projectAlpha)/Sources/Engine.swift", changeCount: 3,
                                     linesAdded: 120, lastTouchedAt: at(100), score: 0.87),
                        ],
                        firstSeenAt: at(10), lastSeenAt: at(950)),
        ProjectActivity(id: projectBeta, name: "Beta", path: projectBeta, fileChangeCount: 1,
                        commandCount: 1, sessionCount: 1, codeGrowthLines: 0,
                        firstSeenAt: at(60), lastSeenAt: at(500)),
    ]

    static let snapshots: [FileSnapshot] = [
        FileSnapshot(path: "\(projectAlpha)/a.swift", contentHash: "sha256:aa",
                     sizeBytes: UInt64(Int64.max) + 7, capturedAt: at(100), lineCount: 42),
        FileSnapshot(path: "\(projectBeta)/b.md", contentHash: "sha256:bb", sizeBytes: 3,
                     capturedAt: at(500), lineCount: 0),
    ]
}

// MARK: - 装配

/// 同一个 fixture 喂两个后端。
///
/// 写入一律通过 `any ObservatoryService & ObservatoryWriting` 走**同一段代码**：
/// 这段能编译并跑绿，本身就是「两后端在写侧可互换」的证据。
private func seed(_ writer: any ObservatoryWriting) async throws {
    try await writer.upsertAgents(Diff.agents)
    try await writer.upsertSessions(Diff.sessions)
    try await writer.upsertProjects(Diff.projects)
    for event in Diff.events { await writer.append(event) }
    for change in Diff.fileChanges { await writer.append(change) }
    for command in Diff.commands { await writer.append(command) }
    for sample in Diff.performanceSamples { await writer.append(sample) }
    for sample in Diff.systemSamples { await writer.append(sample) }
    for diff in Diff.diffs { try await writer.record(diff, forChangeID: diff.id) }
    try await writer.recordRisks(Diff.risks)
    for snapshot in Diff.snapshots { try await writer.recordSnapshot(snapshot) }
    await writer.flush()
}

private func makePair() async throws -> (sqlite: ObservatoryStore, swiftData: SwiftDataObservatoryStore) {
    let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
    try await seed(sqlite)
    let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
    try await seed(swiftData)

    // 两个后端的缓冲写在「整批提交失败」时都会逐条重投并丢弃真正违规的那行，
    // 计数进 droppedStatementCount。那是一条**静默**的数据丢失通道：一旦在某个负载下发生，
    // 对照测试看到的就不是「语义不一致」而是「少了几行」，会被误读成排序差异。
    // 所以在这里钉成前置条件——掉了就是测试装置坏了，当场失败。
    #expect(try await sqlite.rowCount(table: "events") == Diff.events.count, "SQLite 侧事件未全落库")
    #expect(try await swiftData.rowCount(table: "events") == Diff.events.count, "SwiftData 侧事件未全落库")
    #expect(try await sqlite.rowCount(table: "sessions") == Diff.sessions.count, "SQLite 侧会话未全落库")
    #expect(try await swiftData.rowCount(table: "sessions") == Diff.sessions.count, "SwiftData 侧会话未全落库")
    #expect(await swiftData.batchStats().droppedStatementCount == 0, "SwiftData 缓冲写丢了行")
    return (sqlite, swiftData)
}

/// 并列时间戳专用的一对库：`tiedCount` 条事件时间戳完全相同，
/// 只有 tie-break 口径不同的时候两侧顺序才会不一致（这是已知跨后端差异）。
private let tiedCount = 3

private func makeTiedPair() async throws
    -> (sqlite: ObservatoryStore, swiftData: SwiftDataObservatoryStore) {
    let events = Diff.tiedIDs.prefix(tiedCount).map { id in
        TimelineEvent(id: id, timestamp: Diff.tied, sessionID: Diff.sessionA,
                      agentKind: .claudeCode, kind: .fileModified, title: "同刻事件")
    }
    let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
    for event in events { await sqlite.append(event) }
    await sqlite.flush()
    let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
    for event in events { await swiftData.append(event) }
    await swiftData.flush()
    return (sqlite, swiftData)
}

private func expectSamePage<T: Equatable & Sendable>(
    _ sqlite: Page<T>, _ swiftData: Page<T>, label: String
) {
    #expect(swiftData.totalCount == sqlite.totalCount, "\(label): totalCount")
    #expect(swiftData.offset == sqlite.offset, "\(label): offset")
    #expect(swiftData.items == sqlite.items, "\(label): items（含顺序与逐字段）")
}

private func expectSameList<T: Equatable & Sendable>(
    _ sqlite: [T], _ swiftData: [T], label: String
) {
    #expect(swiftData.count == sqlite.count, "\(label): 条数 \(swiftData.count) vs \(sqlite.count)")
    #expect(swiftData == sqlite, "\(label): 内容或顺序")
}

/// 比较两个都要 `try await` 的值。
///
/// `#expect(try await a() == try await b())` 在本语言里**非法**
/// （`try` 不能出现在非赋值运算符右侧），所以统一走这个函数；
/// `sourceLocation` 透传，失败信息仍指向调用那一行。
private func expectSameValue<T: Equatable & Sendable>(
    _ sqlite: () async throws -> T,
    _ swiftData: () async throws -> T,
    label: Comment,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let sqliteValue = try await sqlite()
    let swiftValue = try await swiftData()
    #expect(swiftValue == sqliteValue, label, sourceLocation: sourceLocation)
}

// MARK: - 排序确定性（InMemory 的结构性盲区）

@Suite("两后端直接对照：同刻事件的排序与翻页", .timeLimit(.minutes(1)))
struct BackendTieBreakDifferentialTests {

    /// ⚠️ **这里的断言是刻意放宽的，不是漏写。**
    ///
    /// SQLite 的 tie-break 是 `ORDER BY …, id DESC`，比较的是 TEXT 的 `COLLATE BINARY`
    /// 字节序；而 **SwiftData 对字符串列的排序不是 BINARY 字节序**（实测：同一批
    /// uuidString `[0704…, 8C8E…, CB5F…]` 按 `\.rowID` 升序得到 `8C8E → 0704 → CB5F`）。
    /// 因此「时间戳完全相同的行在两后端先后一致」这条**本质上无法保证**，
    /// 不是暂时没做到。总控 2026-09-20 裁决：接受并记录（方案 b），
    /// 不为了它去改 SQLite 的 tie-break 列 —— 那要动冻结契约并跑一次有失败面的迁移，
    /// 换来的只是同刻并列行的顺序对齐，不影响选中哪些行、不影响 `totalCount`、不影响游标。
    ///
    /// ⇒ **不要再把这里改成「两后端完全同序」**，也不要把它删掉当没这回事。
    ///    影响面（导出与两库对账时行序会不一致）已记在 `Documentation/README.md` 第 1 节。
    ///
    /// 现在断言的是真正成立且要紧的三件事：
    ///   ① 行集合一致（不多不少）；② 各自重复查询顺序稳定（分页游标可靠，故 20 次重取）；
    ///   ③ 时间戳**互不相同**的行，两后端顺序完全一致（见 `distinctTimestampsAgreeExactly`）。
    @Test("同刻行：两侧集合一致，且各自顺序重复稳定")
    func tiedRowsAreSameSetAndStablePerBackend() async throws {
        let (sqlite, swiftData) = try await makeTiedPair()
        let query = EventQuery(dateRange: DateRangeFilter(start: Diff.tied, end: Diff.tied))
        let sqliteFirst = try await sqlite.events(matching: query).items
        let swiftFirst = try await swiftData.events(matching: query).items
        #expect(sqliteFirst.count == tiedCount)
        #expect(Set(swiftFirst.map(\.id)) == Set(sqliteFirst.map(\.id)), "同刻行集合不一致")
        for _ in 0..<20 {
            #expect(try await sqlite.events(matching: query).items.map(\.id)
                    == sqliteFirst.map(\.id), "SQLite 侧顺序不稳定")
            #expect(try await swiftData.events(matching: query).items.map(\.id)
                    == swiftFirst.map(\.id), "SwiftData 侧顺序不稳定 → 分页游标不可靠")
        }
    }

    @Test("时间戳互不相同的行：两后端顺序完全一致（含逐页翻页序列）")
    func distinctTimestampsAgreeExactly() async throws {
        let (sqlite, swiftData) = try await makePair()
        let tied = Set<UUID>()   // 主 fixture 已无并列时间戳，全部行都参与严格序列比对
        for sort in [SortOrder.newestFirst, .oldestFirst] {
            let query = EventQuery(sort: sort)
            let left = try await sqlite.events(matching: query).items.filter { !tied.contains($0.id) }
            let right = try await swiftData.events(matching: query).items.filter { !tied.contains($0.id) }
            #expect(right.map(\.id) == left.map(\.id),
                    "非并列行顺序在两后端不一致（descending=\(sort.descending)）")
        }
    }

    /// 分页游标：两侧各自逐页读完全表，必须不重不漏（顺序可以不同，集合必须齐）。
    @Test("逐页翻完：两侧各自不重不漏")
    func pagingCursorsAreComplete() async throws {
        let (sqlite, swiftData) = try await makePair()
        let services: [(String, any ObservatoryService)] = [
            ("SQLite", sqlite), ("SwiftData", swiftData),
        ]
        for (label, service) in services {
            var seen: [UUID] = []
            for offset in 0...8 {
                seen += try await service.events(matching: EventQuery(limit: 1, offset: offset))
                    .items.map { $0.id }
            }
            #expect(seen.count == Diff.events.count,
                    "\(label) 翻页命中 \(seen.count) 次，应为 \(Diff.events.count)（有重复或漏页）")
            #expect(Set(seen).count == Diff.events.count,
                    "\(label) 翻页后集合只覆盖 \(Set(seen).count) 条 → 漏行")
        }
    }
}

// MARK: - 全部查询轴

@Suite("两后端直接对照：分页查询", .timeLimit(.minutes(1)))
struct BackendPagedQueryDifferentialTests {

    /// 覆盖两后端的每条轴；其中三组刻意打在我的「扫描 + Swift 细筛」路径上
    /// （会话 + 搜索、项目 + 搜索、风险 + 未确认 + 搜索），用来证明下推/扫描两条路径同结果。
    static let eventQueries: [EventQuery] = [
        .all,
        EventQuery(kinds: [.fileCreated, .fileModified]),
        EventQuery(agentKinds: [.claudeCode], sort: .oldestFirst),
        EventQuery(minimumRisk: .high),
        EventQuery(searchText: "tied"),
        EventQuery(sessionID: Diff.sessionA),
        // ↓ 会话 + 搜索：SwiftData 侧走扫描路径（臂 S 把 searchText 留给 Swift）
        EventQuery(sessionID: Diff.sessionA, searchText: "同刻"),
        EventQuery(projectPath: Diff.projectAlpha),
        // ↓ 项目 + 搜索：同样落在细筛路径上
        EventQuery(projectPath: Diff.projectAlpha, searchText: "engine.swift"),
        EventQuery(limit: 2, offset: 2),
        EventQuery(limit: 0, offset: 0),
        EventQuery(limit: -3, offset: -1),
        EventQuery(limit: 10, offset: 40),
    ]

    static let sessionQueries: [SessionQuery] = [
        .all,
        SessionQuery(agentKinds: [.claudeCode]),
        SessionQuery(outcomes: [.success, .failed]),
        SessionQuery(projectPath: Diff.projectBeta),
        SessionQuery(searchText: "持久层"),
        SessionQuery(agentKinds: [.claudeCode, .openAICodex], outcomes: [.running], sort: .oldestFirst),
        SessionQuery(limit: 1, offset: 1),
        SessionQuery(limit: 0),
    ]

    static let fileChangeQueries: [FileChangeQuery] = [
        .all,
        FileChangeQuery(kinds: [.created, .deleted]),
        FileChangeQuery(agentKinds: [.openAICodex]),
        FileChangeQuery(sessionID: Diff.sessionA),
        FileChangeQuery(pathPrefix: "\(Diff.projectAlpha)/Sources"),
        FileChangeQuery(pathPrefix: Diff.projectAlpha, searchText: "engine"),
        FileChangeQuery(sessionID: Diff.sessionA, searchText: "icon"),
        FileChangeQuery(searchText: "BIG.BIN"),
        FileChangeQuery(limit: 2, offset: 1, sort: .oldestFirst),
        FileChangeQuery(limit: 0),
    ]

    static let commandQueries: [CommandQuery] = [
        .all,
        CommandQuery(agentKinds: [.claudeCode]),
        CommandQuery(outcomes: [.failure, .terminated]),
        CommandQuery(destructiveOnly: true),
        CommandQuery(searchText: "push"),
        // ↓ 会话 + 破坏性：SwiftData 侧落在细筛路径
        CommandQuery(sessionID: Diff.sessionA, destructiveOnly: true),
        CommandQuery(sessionID: Diff.sessionB, searchText: "force"),
        // ↓ 项目条件（#81(a)）：SQL 侧 `project_path = ?` 下推，SwiftData 侧走 Swift 细筛
        //   （与事件/文件那两族的 projectPath 同一条路径）⇒ 这一组同时在量「两条路径同结果」。
        //   `projectAlpha` 期望 2 条而不是 3 条：`sudo rm -rf /System/Volumes/Data` 那条
        //   `projectPath == nil`，任何项目条件下都不该被捞出来。
        CommandQuery(projectPath: Diff.projectAlpha),
        CommandQuery(projectPath: Diff.projectBeta),
        CommandQuery(projectPath: Diff.projectAlpha, destructiveOnly: true),
        CommandQuery(projectPath: Diff.projectBeta, searchText: "force"),
        CommandQuery(projectPath: Diff.projectAlpha, limit: 1, offset: 0),
        CommandQuery(projectPath: "/no/such/project"),
        CommandQuery(limit: 1, offset: 1),
        CommandQuery(limit: 0),
    ]

    static let riskQueries: [RiskQuery] = [
        .all,
        RiskQuery(levels: [.critical, .high]),
        RiskQuery(categories: [.massDeletion]),
        RiskQuery(agentKinds: [.claudeCode]),
        RiskQuery(unacknowledgedOnly: true),
        RiskQuery(searchText: "secrets"),
        // ↓ 会话 + 未确认 + 搜索：三个维度里必然有两个走 Swift 细筛
        RiskQuery(sessionID: Diff.sessionA, unacknowledgedOnly: true),
        RiskQuery(agentKinds: [.openAICodex], searchText: "强推"),
        // ↓ 项目条件（#81(a)）：口径 = 风险 → 会话 → 项目（`risk_events` 没有项目列）。
        //   SQL 侧走同一句里的子查询，SwiftData 侧走「先取该项目的会话 id、再 Swift 细筛」
        //   ⇒ 这一组同时在对打两条实现路径。「旧提权」那条不挂会话，任何项目条件下都不该出现。
        RiskQuery(projectPath: Diff.projectAlpha),
        RiskQuery(projectPath: Diff.projectBeta),
        RiskQuery(projectPath: "/no/such/project"),
        RiskQuery(projectPath: Diff.projectAlpha, unacknowledgedOnly: true),
        RiskQuery(projectPath: Diff.projectAlpha, searchText: "secrets"),
        RiskQuery(projectPath: Diff.projectAlpha, limit: 1, offset: 0),
        RiskQuery(limit: 2, offset: 1, sort: .oldestFirst),
        RiskQuery(limit: 0),
    ]

    @Test("events(matching:) 两后端一致", arguments: eventQueries)
    func events(query: EventQuery) async throws {
        let (sqlite, swiftData) = try await makePair()
        expectSamePage(try await sqlite.events(matching: query),
                       try await swiftData.events(matching: query), label: "events")
    }

    @Test("sessions(matching:) 两后端一致", arguments: sessionQueries)
    func sessions(query: SessionQuery) async throws {
        let (sqlite, swiftData) = try await makePair()
        expectSamePage(try await sqlite.sessions(matching: query),
                       try await swiftData.sessions(matching: query), label: "sessions")
    }

    @Test("fileChanges(matching:) 两后端一致", arguments: fileChangeQueries)
    func fileChanges(query: FileChangeQuery) async throws {
        let (sqlite, swiftData) = try await makePair()
        expectSamePage(try await sqlite.fileChanges(matching: query),
                       try await swiftData.fileChanges(matching: query), label: "fileChanges")
    }

    @Test("commands(matching:) 两后端一致", arguments: commandQueries)
    func commands(query: CommandQuery) async throws {
        let (sqlite, swiftData) = try await makePair()
        expectSamePage(try await sqlite.commands(matching: query),
                       try await swiftData.commands(matching: query), label: "commands")
    }

    @Test("riskEvents(matching:) 两后端一致", arguments: riskQueries)
    func risks(query: RiskQuery) async throws {
        let (sqlite, swiftData) = try await makePair()
        expectSamePage(try await sqlite.riskEvents(matching: query),
                       try await swiftData.riskEvents(matching: query), label: "risks")
    }
}

@Suite("两后端直接对照：单值、列表与派生查询", .timeLimit(.minutes(1)))
struct BackendSingleQueryDifferentialTests {

    @Test("session(id:) / fileDiff(for:) / activeAgents() 一致")
    func singleValues() async throws {
        let (sqlite, swiftData) = try await makePair()
        for id in [Diff.sessionA, Diff.sessionRunning, UUID()] {
            try await expectSameValue(
                { try await sqlite.session(id: id) },
                { try await swiftData.session(id: id) },
                label: "session(id: \(id))"
            )
        }
        for id in [Diff.changeText, Diff.changeBinary, UUID()] {
            let sqliteDiff = try await sqlite.fileDiff(for: id)
            let swiftDiff = try await swiftData.fileDiff(for: id)
            #expect(swiftDiff == sqliteDiff, "fileDiff(for: \(id))")
        }
        // 文本 diff 必须逐行一致（含 style 与两个行号），二进制不得伪造行
        let text = try #require(try await swiftData.fileDiff(for: Diff.changeText))
        #expect(text.lines.count == 4)
        #expect(text.lines.map { $0.style } == [.hunkHeader, .added, .removed, .context])
        expectSameList(try await sqlite.activeAgents(), try await swiftData.activeAgents(),
                       label: "activeAgents")
    }

    @Test("performanceSamples / systemPerformance 一致（含 v3 网络与 GPU 字段）")
    func performance() async throws {
        let (sqlite, swiftData) = try await makePair()
        for id in [Diff.sessionA, Diff.sessionB, UUID()] {
            expectSameList(try await sqlite.performanceSamples(sessionID: id),
                           try await swiftData.performanceSamples(sessionID: id),
                           label: "perf \(id)")
        }
        for since in [Date(timeIntervalSinceReferenceDate: 0), Diff.at(150), Diff.tied] {
            expectSameList(try await sqlite.systemPerformance(since: since),
                           try await swiftData.systemPerformance(since: since),
                           label: "sysperf since \(since.timeIntervalSinceReferenceDate)")
        }
        // v3 三种情形不得互相塌缩：有值 / nil + 原因 / 真的是 0
        // v3 三种情形不得互相塌缩：**有速率 / 拿不到（nil + 原因）/ 真的是 0**。
        // 注意 `0 != nil`：把「拿不到」存成 0 会被界面念成「没有流量」，那是撒谎。
        let all = try await swiftData.systemPerformance(since: Date(timeIntervalSinceReferenceDate: 0))
        #expect(all.count == 3)
        let unknown = all.filter { $0.networkInBytesPerSecond == nil }
        #expect(unknown.count == 1, "只有 1 条是真的没采到速率")
        #expect(unknown.first?.networkAvailability == .counterRegression)
        #expect(unknown.first?.gpuActivityPercent == nil)
        let measured = all.filter { $0.networkInBytesPerSecond != nil }
        #expect(measured.count == 2, "带值（含 0.0）的应剩 2 条")
        let positive = all.filter { ($0.networkInBytesPerSecond ?? 0) > 0 }
        #expect(positive.count == 1)
        #expect(positive.first?.networkInBytesPerSecond == 1_048_576.5)
        #expect(positive.first?.networkOutBytesPerSecond == 2_097_152.25)
        #expect(positive.first?.gpuActivityPercent == 37.5)
        let trueZero = all.filter { $0.networkInBytesPerSecond == 0 }
        #expect(trueZero.count == 1, "「真的没有流量」只有 1 条")
        #expect(trueZero.first?.networkAvailability == nil)
        #expect(trueZero.first?.gpuActivityPercent == 0)
    }

    @Test("projects() 与 projectActivity 区间重算一致")
    func projects() async throws {
        let (sqlite, swiftData) = try await makePair()
        expectSameList(try await sqlite.projects(), try await swiftData.projects(), label: "projects")
        let ranges = [DateRangeFilter.unbounded, DateRangeFilter(start: Diff.at(100), end: Diff.at(600)),
                      DateRangeFilter(start: Diff.tied, end: Diff.tied)]
        for range in ranges {
            for path in [Diff.projectAlpha, Diff.projectBeta, "/Nope"] {
                let sqliteValue = try await sqlite.projectActivity(path: path, dateRange: range)
                let swiftValue = try await swiftData.projectActivity(path: path, dateRange: range)
                #expect(swiftValue == sqliteValue, "projectActivity(\(path), \(range))")
            }
        }
    }

    @Test("dashboardStats(for:) 逐字段一致",
          arguments: [Diff.at(960), Diff.at(100), Date(timeIntervalSinceReferenceDate: 0)])
    func dashboard(date: Date) async throws {
        let (sqlite, swiftData) = try await makePair()
        let sqliteStats = try await sqlite.dashboardStats(for: date)
        let swiftStats = try await swiftData.dashboardStats(for: date)
        // 逐字段展开：整体失败时看不出是哪一列算错。
        #expect(swiftStats.sessionCount == sqliteStats.sessionCount, "sessionCount")
        #expect(swiftStats.totalActiveSeconds == sqliteStats.totalActiveSeconds, "totalActiveSeconds")
        #expect(swiftStats.filesModified == sqliteStats.filesModified, "filesModified")
        #expect(swiftStats.filesCreated == sqliteStats.filesCreated, "filesCreated")
        #expect(swiftStats.filesDeleted == sqliteStats.filesDeleted, "filesDeleted")
        #expect(swiftStats.commandsExecuted == sqliteStats.commandsExecuted, "commandsExecuted")
        #expect(swiftStats.failedCommands == sqliteStats.failedCommands, "failedCommands")
        #expect(swiftStats.riskEventCount == sqliteStats.riskEventCount, "riskEventCount")
        #expect(swiftStats.highRiskEventCount == sqliteStats.highRiskEventCount, "highRiskEventCount")
        #expect(swiftStats.averageCPUPercent == sqliteStats.averageCPUPercent, "averageCPUPercent")
        #expect(swiftStats.peakCPUPercent == sqliteStats.peakCPUPercent, "peakCPUPercent")
        #expect(swiftStats.peakMemoryBytes == sqliteStats.peakMemoryBytes, "peakMemoryBytes")
        #expect(swiftStats.activeAgentCount == sqliteStats.activeAgentCount, "activeAgentCount")
        #expect(swiftStats.hourlyActivity == sqliteStats.hourlyActivity, "hourlyActivity")
        #expect(swiftStats.agentShares == sqliteStats.agentShares, "agentShares")
        #expect(swiftStats == sqliteStats, "DashboardStats 整体")
    }

    @Test("辅助查询与写侧后续动作一致：acknowledge / 结算 interrupted / 计数")
    func writeThenRead() async throws {
        let (sqlite, swiftData) = try await makePair()
        try await expectSameValue(
            { try await sqlite.openSessionCount() },
            { try await swiftData.openSessionCount() },
            label: "初始未结算会话数"
        )

        try await sqlite.acknowledgeRisk(id: Diff.risks[0].id)
        try await swiftData.acknowledgeRisk(id: Diff.risks[0].id)
        expectSamePage(try await sqlite.riskEvents(matching: .all),
                       try await swiftData.riskEvents(matching: .all), label: "acknowledge 之后")
        try await expectSameValue(
            { try await sqlite.riskEvents(matching: RiskQuery(unacknowledgedOnly: true)).totalCount },
            { try await swiftData.riskEvents(matching: RiskQuery(unacknowledgedOnly: true)).totalCount },
            label: "acknowledge 之后待办风险数"
        )

        let settled = Diff.at(1_000)
        let sqliteChanged = try await sqlite.markRunningSessionsInterrupted(at: settled)
        let swiftChanged = try await swiftData.markRunningSessionsInterrupted(at: settled)
        #expect(swiftChanged == sqliteChanged, "结算的会话条数")
        try await expectSameValue(
            { try await sqlite.openSessionCount() },
            { try await swiftData.openSessionCount() },
            label: "结算之后未结算会话数"
        )
        expectSamePage(try await sqlite.sessions(matching: .all),
                       try await swiftData.sessions(matching: .all), label: "结算之后")
    }

    @Test("保留期清理：同一 cutoff 后两侧逐表剩余行数相同")
    func pruneLeavesSameRows() async throws {
        let (sqlite, swiftData) = try await makePair()
        let cutoff = Diff.at(102)
        _ = try await sqlite.prune(olderThan: cutoff, vacuum: false)
        _ = try await swiftData.prune(olderThan: cutoff, vacuum: false)
        for table in ["events", "file_changes", "commands", "sessions", "risk_events",
                      "perf_samples", "system_perf", "agents", "projects", "diffs",
                      "file_snapshots"] {
            let sqliteLeft = try await sqlite.rowCount(table: table)
            let swiftLeft = try await swiftData.rowCount(table: table)
            #expect(swiftLeft == sqliteLeft, "\(table) 清理后剩余行数不同")
        }
        // 边界：`< cutoff` 是严格小于，恰好等于 cutoff 的行两侧都必须留下
        try await expectSameValue(
            { try await sqlite.rowCount(table: "file_changes") },
            { try await swiftData.rowCount(table: "file_changes") },
            label: "清理后 file_changes 剩余（边界行应留下）"
        )
    }

    @Test("deleteAllData 之后两侧所有表都为空")
    func deleteAll() async throws {
        let (sqlite, swiftData) = try await makePair()
        try await sqlite.deleteAllData()
        try await swiftData.deleteAllData()
        for table in ["events", "sessions", "risk_events", "projects"] {
            #expect(try await sqlite.rowCount(table: table) == 0)
            #expect(try await swiftData.rowCount(table: table) == 0, "\(table) 没清干净")
        }
    }
}

// MARK: - 写侧可互换（协议层证据）

@Suite("两后端可切换：只经协议读写", .timeLimit(.minutes(1)))
struct BackendProtocolInterchangeabilityTests {

    /// 只持有 `any ObservatoryService & ObservatoryWriting`，两个后端走完全同一段代码。
    /// 这就是需求「SwiftData + SQLite 可切换」与 ADR-0001 第二阶段的收口。
    @Test("同一段协议化代码在两后端上读写结果一致")
    func drivenThroughProtocolsOnly() async throws {
        let sqlite: any ObservatoryService & ObservatoryWriting =
            try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData: any ObservatoryService & ObservatoryWriting =
            try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        try await seed(sqlite)
        try await seed(swiftData)

        for query in BackendPagedQueryDifferentialTests.eventQueries {
            expectSamePage(try await sqlite.events(matching: query),
                           try await swiftData.events(matching: query), label: "protocol events")
        }
        try await expectSameValue({ try await sqlite.projects() },
                                  { try await swiftData.projects() },
                                  label: "protocol projects")
        try await expectSameValue({ try await sqlite.dashboardStats(for: Diff.tied) },
                                  { try await swiftData.dashboardStats(for: Diff.tied) },
                                  label: "protocol dashboard")
    }
}

// MARK: - 需求④：闭合未终结命令（两后端逐字段对照）

@Suite("两后端对照：terminateOpenCommands", .timeLimit(.minutes(1)))
struct TerminateOpenCommandsDifferentialTests {

    private func openStores() async throws
        -> [(label: String, store: any ObservatoryService & ObservatoryWriting)]
    {
        [
            ("sqlite", try await ObservatoryStore.open(configuration: .inMemory)),
            ("swiftData", try await SwiftDataObservatoryStore.open(configuration: .inMemory)),
        ]
    }

    /// 会话 A：两条开放 + 一条**已由 hook 闭合**；会话 B：一条开放。
    private func seed(_ store: any ObservatoryService & ObservatoryWriting,
                      sessionA: UUID, sessionB: UUID, started: Date) async {
        await store.append(CommandRecord(executable: "rm", arguments: ["-f", "a"],
                                         sessionID: sessionA, startedAt: started))
        await store.append(CommandRecord(executable: "git", arguments: ["status"],
                                         sessionID: sessionA, startedAt: started))
        await store.append(CommandRecord(executable: "codex", arguments: ["run"],
                                         sessionID: sessionA, startedAt: started,
                                         endedAt: started.addingTimeInterval(1),
                                         exitCode: 0, outcome: .success))
        await store.append(CommandRecord(executable: "sleep", arguments: ["1"],
                                         sessionID: sessionB, startedAt: started))
        await store.flush()   // 命令走缓冲写入通道，不 flush 就查不到
    }

    @Test("只收开放行、按会话筛选、幂等，且两后端逐字段一致")
    func terminatesOnlyOpenRowsOfTheGivenSession() async throws {
        let sessionA = UUID()
        let sessionB = UUID()
        let started = Date(timeIntervalSince1970: 1_800_000_000)
        let endedAt = started.addingTimeInterval(30)

        var observed: [(String, [String])] = []
        for (label, store) in try await openStores() {
            await seed(store, sessionA: sessionA, sessionB: sessionB, started: started)

            let settled = try await store.terminateOpenCommands(
                agentID: nil, sessionID: sessionA, outcome: .terminated, endedAt: endedAt)
            // 2 条被收口，第 3 条（已 success）与 B 的那条都不许动
            #expect(settled == 2, "\(label): 应收口 2 条，实际 \(settled)")

            // 幂等：再收一次必须是 0，且不产生写入
            let again = try await store.terminateOpenCommands(
                agentID: nil, sessionID: sessionA, outcome: .terminated, endedAt: endedAt)
            #expect(again == 0, "\(label): 重复收口必须返回 0，实际 \(again)")

            let all = try await store.commands(matching: .all).items
            let rows = all.sorted { $0.executable < $1.executable }.map { command in
                [
                    command.executable,
                    command.outcome.rawValue,
                    command.endedAt == nil ? "nil" : "set",
                    command.exitCode.map(String.init) ?? "nil",
                ].joined(separator: "|")
            }
            observed.append((label, rows))
            #expect(!rows.contains { $0.hasPrefix("git|running") }, "\(label): 会话 A 仍有开放命令")
            #expect(rows.contains { $0.hasPrefix("sleep|running") }, "\(label): 会话 B 被误收口")
            // ⚠️ 红线：`.terminated` 不得冒充成败——退出码必须仍是 nil
            #expect(rows.contains { $0 == "git|terminated|set|nil" }, "\(label): terminated 丢了退出码未知这一事实")
            #expect(rows.contains { $0 == "codex|success|set|0" }, "\(label): 已闭合命令被改写")
        }
        // 两后端逐字一致（本仓库反复栽在"只改一个后端"）
        #expect(observed[0].1 == observed[1].1,
                "两后端不一致：sqlite=\(observed[0].1) swiftData=\(observed[1].1)")
    }
}
