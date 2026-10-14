//
//  SwiftDataQueryParityTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: WS-SwiftData
//
//  **本任务的核心验收**：SwiftData 后端的查询语义必须与既有后端一致，否则「可切换」只是口号。
//
//  ── 为什么对照的是 `InMemoryObservatoryService` 而不是 SQLite store ─────────
//  `Package.swift`（总控冻结）里 `AIObservatorySwiftDataStoreTests` 的依赖只有
//  `AIObservatorySwiftDataStore` + `Core` + `TestSupport`，**看不到 `AIObservatoryStore`**，
//  所以本文件无法直接 import SQLite 后端。走的是等价且可机器判定的传递性：
//
//      SQLite ≡ InMemory   （由 AIObservatoryEngineTests/StoreParityTests 断言，同一次 `swift test` 里跑）
//      SwiftData ≡ InMemory（本文件断言）
//      ─────────────────────────────────────────────
//      ⇒ SwiftData ≡ SQLite
//
//  两侧在同一次测试运行内喂**同一批 fixture**、跑**同一批查询**，因此不存在
//  「基准已过期」的问题：StoreParityTests 一旦红，本文件的绿灯也不构成放行证据。
//  直接把两个后端放进同一个对照测试需要给测试 target 加依赖 → 已写 IFR 交总控。
//
//  ── InMemory 覆盖不到、必须单独钉的一条 ───────────────────────────────────
//  InMemory 只按时间列排序（没有 tie-breaker），所以**时间戳相同的两行**它的顺序是实现
//  定义的吗——SQLite 侧靠 `ORDER BY ts, id DESC` 得到确定顺序。因此：
//    · 本文件的对照 fixture 时间戳**两两互不相同**（与 StoreParityTests 同策），
//      避免把「基准本身的不确定」当成差异；
//    · tie-break 的确定性由 `SwiftDataOrderingDeterminismTests` 单独按规则断言。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatorySwiftDataStore
import AIObservatoryTestSupport

// MARK: - Fixture

/// 共享样本。时间戳从「今天已经过的秒数」按比例推出，因此一定落在
/// `DateRangeFilter.today(now)` 窗口内、且不晚于 now（避免负时长抖动）。
private enum Parity {
    static let now = Date()
    static let dayStart = Calendar.current.startOfDay(for: now)
    static let elapsed = max(600, now.timeIntervalSince(dayStart))

    static func today(_ fraction: Double) -> Date {
        dayStart.addingTimeInterval(elapsed * fraction)
    }

    static func daysAgo(_ days: Int, _ fraction: Double) -> Date {
        today(fraction).addingTimeInterval(-Double(days) * 86_400)
    }

    // MARK: 标识

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

    // MARK: agents

    static let agents: [AgentInstance] = [
        AgentInstance(id: agentClaude, kind: .claudeCode, pid: 4001, parentPID: 3001,
                      displayName: "Claude Code", executablePath: "/usr/local/bin/claude",
                      workingDirectory: projectAlpha, bundleIdentifier: nil, tty: "/dev/ttys003",
                      startedAt: daysAgo(1, 0.2), lastSeenAt: today(0.9), state: .running,
                      cpuPercent: 12.5, memoryBytes: 1_800_000_000, childPIDs: [4002, 4003]),
        AgentInstance(id: agentCodex, kind: .openAICodex, pid: 5001,
                      displayName: "Codex CLI", executablePath: "/usr/local/bin/codex",
                      workingDirectory: projectBeta, startedAt: daysAgo(2, 0.3),
                      lastSeenAt: today(0.5), state: .idle, cpuPercent: 3.25,
                      memoryBytes: 900_000_000, detectedVia: .argumentSignature),
        AgentInstance(id: agentCursor, kind: .cursorAgent, pid: 6001,
                      displayName: "Cursor", executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                      workingDirectory: nil, startedAt: daysAgo(3, 0.4), lastSeenAt: daysAgo(1, 0.1),
                      state: .terminated, cpuPercent: 0, memoryBytes: 0, detectedVia: .bundleIdentifier),
    ]

    // MARK: 时间线事件（时间戳两两不同；两条越界负例）

    static let events: [TimelineEvent] = [
        TimelineEvent(timestamp: today(0.1), sessionID: sessionA, agentID: agentClaude,
                      agentKind: .claudeCode, kind: .fileCreated, title: "创建 Engine.swift",
                      summary: "新文件", filePath: "\(projectAlpha)/Sources/Engine.swift",
                      cost: ResourceCost(cpuSeconds: 0.4, memoryBytes: 240_000_000),
                      riskLevel: .low, projectPath: projectAlpha),
        TimelineEvent(timestamp: today(0.3), sessionID: sessionA, agentID: agentClaude,
                      agentKind: .claudeCode, kind: .commandExecuted, title: "执行 rm -rf",
                      summary: "危险命令", command: "rm -rf ./DerivedData", exitCode: 0,
                      durationSeconds: 1.5, riskLevel: .critical, projectPath: projectAlpha),
        TimelineEvent(timestamp: today(0.5), sessionID: sessionB, agentID: agentCodex,
                      agentKind: .openAICodex, kind: .fileModified, title: "修改 README",
                      summary: "文档", filePath: "\(projectBeta)/README.md",
                      riskLevel: .medium, projectPath: projectBeta),
        TimelineEvent(timestamp: today(0.7), sessionID: sessionB, agentID: agentCodex,
                      agentKind: .openAICodex, kind: .gitOperation, title: "git commit",
                      summary: "提交", command: "git commit -m 'feat: 双后端'",
                      riskLevel: .high, projectPath: projectBeta),
        TimelineEvent(timestamp: today(0.9), sessionID: sessionRunning, agentID: agentClaude,
                      agentKind: .claudeCode, kind: .fileRead, title: "读取 secrets.env",
                      summary: "敏感路径", filePath: "\(projectAlpha)/secrets.env",
                      riskLevel: .high, projectPath: projectAlpha),
        // 负例：昨天，且 agentKind 为 cursor（用于 agentKinds / dateRange 过滤）
        TimelineEvent(timestamp: daysAgo(2, 0.4), sessionID: nil, agentID: agentCursor,
                      agentKind: .cursorAgent, kind: .unknown, title: "旧活动",
                      summary: "窗口外", riskLevel: .low, projectPath: nil),
    ]

    // MARK: 文件变更

    static let fileChanges: [FileChange] = [
        FileChange(id: changeText, path: "\(projectAlpha)/Sources/Engine.swift",
                   previousPath: nil, kind: .created, timestamp: today(0.1),
                   agentID: agentClaude, sessionID: sessionA, agentKind: .claudeCode,
                   sizeBytes: 4_096, previousSizeBytes: nil, isText: true,
                   linesAdded: 120, linesRemoved: 0, projectPath: projectAlpha),
        FileChange(id: changeBinary, path: "\(projectAlpha)/Assets/icon.png",
                   kind: .modified, timestamp: today(0.2), agentID: agentClaude, sessionID: sessionA,
                   agentKind: .claudeCode, sizeBytes: 2, previousSizeBytes: 1, isText: false,
                   riskLevel: .medium, projectPath: projectAlpha),
        FileChange(path: "\(projectAlpha)/tmp/scratch.txt", kind: .deleted, timestamp: today(0.3),
                   agentID: agentClaude, sessionID: sessionA, agentKind: .claudeCode,
                   sizeBytes: 0, previousSizeBytes: 512, linesRemoved: 12,
                   riskLevel: .high, projectPath: projectAlpha),
        FileChange(path: "\(projectBeta)/docs/note.md", previousPath: "\(projectBeta)/docs/old.md",
                   kind: .renamed, timestamp: today(0.5),
                   agentID: agentCodex, sessionID: sessionB, agentKind: .openAICodex, sizeBytes: 128,
                   projectPath: projectBeta),
        FileChange(path: "\(projectBeta)/Package.swift", kind: .modified, timestamp: today(0.7),
                   agentID: agentCodex, sessionID: sessionB, agentKind: .openAICodex,
                   sizeBytes: UInt64(Int64.max) + 4_096,   // > Int64.max：bit-pattern 往返
                   linesAdded: 3, linesRemoved: 1, riskLevel: .critical, projectPath: projectBeta),
        // 负例：昨天
        FileChange(path: "\(projectAlpha)/Sources/Old.swift", kind: .modified,
                   timestamp: daysAgo(3, 0.5), agentKind: .cursorAgent, sizeBytes: 10,
                   projectPath: projectAlpha),
    ]

    // MARK: diffs

    static let diffs: [FileDiff] = [
        FileDiff(
            id: changeText, path: "\(projectAlpha)/Sources/Engine.swift", kind: .created,
            lines: [
                DiffLine(style: .hunkHeader, text: "@@ -0,0 +1,2 @@", newLineNumber: 1),
                DiffLine(style: .added, text: "import Foundation", newLineNumber: 1),
                DiffLine(style: .context, text: "", oldLineNumber: 2, newLineNumber: 2),
            ],
            linesAdded: 120, capturedAt: today(0.1)
        ),
        FileDiff(
            id: changeBinary, path: "\(projectAlpha)/Assets/icon.png", kind: .modified,
            lines: [], linesRemoved: 0, isBinary: true, isTruncated: true, capturedAt: today(0.2)
        ),
    ]

    // MARK: commands

    static let commands: [CommandRecord] = [
        CommandRecord(id: UUID(),
                      executable: "rm", arguments: ["-rf", "./DerivedData"],
                      workingDirectory: projectAlpha, agentID: agentClaude, sessionID: sessionA,
                      agentKind: .claudeCode, startedAt: today(0.3), endedAt: today(0.31),
                      exitCode: 0, outcome: .success, isDestructive: true,
                      requiresConfirmation: true, riskLevel: .critical, projectPath: projectAlpha),
        CommandRecord(executable: "git", arguments: ["commit", "-m", "feat: 双后端"],
                      workingDirectory: projectBeta, agentID: agentCodex, sessionID: sessionB,
                      agentKind: .openAICodex, startedAt: today(0.5), endedAt: today(0.55),
                      exitCode: 1, outcome: .failure, riskLevel: .medium, projectPath: projectBeta),
        CommandRecord(executable: "swift", arguments: ["test"], workingDirectory: projectAlpha,
                      agentID: agentClaude, sessionID: sessionA, agentKind: .claudeCode,
                      startedAt: today(0.7), outcome: .running, projectPath: projectAlpha),
        CommandRecord(executable: "sudo", arguments: ["rm", "-rf", "/System/Volumes/Data"],
                      agentID: agentCursor, agentKind: .cursorAgent, startedAt: today(0.9),
                      endedAt: today(0.95), exitCode: -1, outcome: .terminated,
                      isDestructive: true, requiresConfirmation: true, riskLevel: .critical),
        // 负例：昨天
        CommandRecord(executable: "echo", arguments: ["hi"], agentKind: .genericCLIAgent,
                      startedAt: daysAgo(2, 0.5), endedAt: daysAgo(2, 0.51),
                      exitCode: 0, outcome: .success),
    ]

    // MARK: sessions（riskEventCount 用派生值，避免与 recordRisks 的重算口径打架）

    static func riskCount(for sessionID: UUID) -> Int {
        risks.filter { $0.sessionID == sessionID }.count
    }

    static let sessions: [AgentSession] = [
        AgentSession(id: sessionA, displayIndex: 101, kind: .claudeCode, agentID: agentClaude,
                     title: "重构持久层", projectPath: projectAlpha, startedAt: today(0.05),
                     endedAt: today(0.95), modifiedFileCount: 3, createdFileCount: 1,
                     deletedFileCount: 1, commandCount: 2, failedCommandCount: 0,
                     cpuSeconds: 42.5, peakCPUPercent: 78.5, peakMemoryBytes: 1_200_000_000,
                     estimatedTokens: 18_000, riskEventCount: riskCount(for: sessionA),
                     outcome: .success),
        AgentSession(id: sessionB, displayIndex: 102, kind: .openAICodex, agentID: agentCodex,
                     title: "补测试", projectPath: projectBeta, startedAt: today(0.4),
                     endedAt: today(0.8), modifiedFileCount: 2, commandCount: 1,
                     failedCommandCount: 1, cpuSeconds: 12, peakCPUPercent: 40,
                     peakMemoryBytes: UInt64(Int64.max) + 1, estimatedTokens: 4_000,
                     riskEventCount: riskCount(for: sessionB), outcome: .failed),
        AgentSession(id: sessionRunning, displayIndex: 103, kind: .claudeCode, agentID: agentClaude,
                     title: "排查崩溃", startedAt: today(0.85),
                     riskEventCount: riskCount(for: sessionRunning), outcome: .running),
        // 负例：昨天的会话
        AgentSession(id: UUID(),
                     displayIndex: 100, kind: .cursorAgent, title: "旧会话",
                     projectPath: projectAlpha, startedAt: daysAgo(2, 0.5),
                     endedAt: daysAgo(2, 0.9), modifiedFileCount: 1,
                     outcome: .interrupted),
    ]

    // MARK: 性能采样

    static let performanceSamples: [PerformanceSample] = [
        PerformanceSample(timestamp: today(0.1), sessionID: sessionA, agentID: agentClaude,
                          cpuPercent: 20, memoryBytes: 500_000_000,
                          diskReadBytesPerSecond: 1_024, diskWriteBytesPerSecond: 2_048,
                          networkBytesIn: 4_096, networkBytesOut: 8_192),
        PerformanceSample(timestamp: today(0.5), sessionID: sessionA, agentID: agentClaude,
                          cpuPercent: 60.5, memoryBytes: UInt64(Int64.max), gpuPercent: 12.5,
                          thermalCelsius: 74.25, powerWatts: 18.75),
        PerformanceSample(timestamp: today(0.6), sessionID: sessionB, agentID: agentCodex,
                          cpuPercent: 5, memoryBytes: 100, networkBytesIn: 0, networkBytesOut: 0),
        // 负例：窗口外 + 无归属会话
        PerformanceSample(timestamp: daysAgo(4, 0.2), sessionID: nil, agentID: nil,
                          cpuPercent: 1, memoryBytes: 1),
    ]

    static let systemSamples: [SystemPerformanceSample] = [
        SystemPerformanceSample(timestamp: today(0.2), cpuTotalPercent: 33.5, cpuSystemPercent: 5,
                                cpuUserPercent: 28.5, memoryUsedBytes: 16_000_000_000,
                                memoryTotalBytes: 34_359_738_368, diskReadBytesPerSecond: 512,
                                diskWriteBytesPerSecond: 256, loadAverage1m: 2.5),
        SystemPerformanceSample(timestamp: today(0.6), cpuTotalPercent: 91.25,
                                cpuSystemPercent: 11.5, cpuUserPercent: 79.75,
                                memoryUsedBytes: UInt64(Int64.max) + 7, memoryTotalBytes: 0,
                                loadAverage1m: 8.75, thermalCelsius: 88.5, powerWatts: 42),
        SystemPerformanceSample(timestamp: daysAgo(2, 0.7), cpuTotalPercent: 1, cpuSystemPercent: 1,
                                cpuUserPercent: 0, memoryUsedBytes: 1, memoryTotalBytes: 2),
    ]

    // MARK: 风险

    static let risks: [RiskEvent] = [
        RiskEvent(timestamp: today(0.3), level: .critical, category: .massDeletion,
                  title: "批量删除", detail: "rm -rf 命中构建产物目录",
                  agentID: agentClaude, agentKind: .claudeCode, sessionID: sessionA,
                  command: "rm -rf ./DerivedData", filePaths: ["\(projectAlpha)/DerivedData"],
                  requiresConfirmation: true, matchedRuleID: "R-DANGEROUS-RM"),
        RiskEvent(timestamp: today(0.35), level: .high, category: .sensitivePathAccess,
                  title: "读取凭据文件", detail: "命中 secrets.env",
                  agentID: agentClaude, agentKind: .claudeCode, sessionID: sessionA,
                  filePaths: ["\(projectAlpha)/secrets.env"], isAcknowledged: true,
                  matchedRuleID: "R-SENSITIVE-PATH"),
        RiskEvent(timestamp: today(0.7), level: .medium, category: .dangerousCommand,
                  title: "git 强制推送", detail: "",
                  agentID: agentCodex, agentKind: .openAICodex, sessionID: sessionB,
                  command: "git push --force"),
        RiskEvent(timestamp: today(0.9), level: .low, category: .unknown,
                  title: "未分类活动", detail: "特征不足", agentID: nil, agentKind: .cursorAgent,
                  sessionID: nil, filePaths: [], matchedRuleID: nil),
        // 负例：昨天
        RiskEvent(timestamp: daysAgo(3, 0.4), level: .critical, category: .privilegeEscalation,
                  title: "旧提权", detail: "sudo", agentKind: .genericCLIAgent),
    ]

    // MARK: projects

    static let projects: [ProjectActivity] = [
        ProjectActivity(id: projectAlpha, name: "Alpha", path: projectAlpha,
                        fileChangeCount: 9, commandCount: 8, sessionCount: 4, riskEventCount: 3,
                        codeGrowthLines: 400, codeShrinkLines: 90,
                        agentContributions: [
                            // 不给 id：契约（StableID）按 kind 推导，聚合值身份与「谁算的」无关。
                            AgentContribution(kind: .claudeCode, relativeShare: 0.75, eventCount: 12),
                            AgentContribution(kind: .openAICodex, relativeShare: 0.25, eventCount: 4),
                        ],
                        hotFiles: [
                            FileHeat(path: "\(projectAlpha)/Sources/Engine.swift", changeCount: 7,
                                     linesAdded: 210, linesRemoved: 30, lastTouchedAt: today(0.9),
                                     score: 0.87),
                            FileHeat(path: "\(projectAlpha)/tmp/scratch.txt", changeCount: 2,
                                     lastTouchedAt: today(0.3), score: nil),
                        ],
                        firstSeenAt: daysAgo(5, 0.1), lastSeenAt: today(0.9)),
        ProjectActivity(id: projectBeta, name: "Beta", path: projectBeta, fileChangeCount: 3,
                        sessionCount: 2, codeGrowthLines: 40,
                        firstSeenAt: daysAgo(1, 0.2), lastSeenAt: today(0.8)),
    ]

    // MARK: 查询矩阵（与 StoreParityTests 的维度口径一致）

    static let sessionQueries: [SessionQuery] = [
        .all,
        SessionQuery(agentKinds: [.claudeCode]),
        SessionQuery(agentKinds: [.claudeCode, .cursorAgent]),
        SessionQuery(outcomes: [.failed]),
        SessionQuery(outcomes: [.running, .success, .interrupted]),
        SessionQuery(dateRange: .today(now)),
        SessionQuery(dateRange: .lastHours(6, now: now)),
        SessionQuery(dateRange: DateRangeFilter(start: today(0.4), end: today(0.8))),
        SessionQuery(projectPath: projectAlpha),
        SessionQuery(projectPath: "\(FixturePaths.work)/Ghost"),
        SessionQuery(searchText: "重构"),
        SessionQuery(searchText: "CLAUDE"),
        SessionQuery(searchText: "codex cli", limit: 2),
        SessionQuery(limit: 3, sort: .oldestFirst),
        SessionQuery(limit: 2, offset: 1),
        SessionQuery(limit: 10, offset: 99),
        SessionQuery(limit: 0, offset: 0),
    ]

    static let eventQueries: [EventQuery] = [
        .all,
        EventQuery(kinds: [.fileCreated]),
        EventQuery(kinds: [.fileModified, .fileRead]),
        EventQuery(agentKinds: [.claudeCode]),
        EventQuery(agentKinds: [.claudeCode, .openAICodex], sort: .oldestFirst),
        EventQuery(sessionID: sessionA),
        EventQuery(dateRange: .today(now), sessionID: sessionB),
        EventQuery(sessionID: UUID()),
        EventQuery(projectPath: projectBeta),
        EventQuery(minimumRisk: .high),
        EventQuery(minimumRisk: .critical),
        EventQuery(searchText: "rm -rf"),
        EventQuery(searchText: "README", sort: .oldestFirst),
        EventQuery(limit: 2, offset: 2),
        EventQuery(limit: 100, offset: 0, sort: .oldestFirst),
    ]

    static let fileChangeQueries: [FileChangeQuery] = [
        .all,
        FileChangeQuery(kinds: [.created]),
        FileChangeQuery(kinds: [.deleted, .renamed]),
        FileChangeQuery(agentKinds: [.openAICodex]),
        FileChangeQuery(sessionID: sessionA),
        FileChangeQuery(dateRange: .today(now), projectPath: projectAlpha),
        FileChangeQuery(pathPrefix: "\(projectAlpha)/Sources"),
        FileChangeQuery(pathPrefix: projectAlpha),
        FileChangeQuery(pathPrefix: ""),
        FileChangeQuery(pathPrefix: "/Nope"),
        FileChangeQuery(searchText: "package.swift"),
        FileChangeQuery(searchText: "PACKAGE"),
        FileChangeQuery(searchText: ".md", sort: .oldestFirst),
        FileChangeQuery(limit: 3, offset: 1),
    ]

    static let commandQueries: [CommandQuery] = [
        .all,
        CommandQuery(agentKinds: [.claudeCode]),
        CommandQuery(sessionID: sessionA),
        CommandQuery(outcomes: [.failure]),
        CommandQuery(outcomes: [.running, .terminated]),
        CommandQuery(destructiveOnly: true),
        CommandQuery(dateRange: .today(now)),
        CommandQuery(searchText: "git commit"),
        CommandQuery(searchText: "SUDO", sort: .oldestFirst),
        CommandQuery(limit: 2, offset: 1),
    ]

    static let riskQueries: [RiskQuery] = [
        .all,
        RiskQuery(levels: [.critical]),
        RiskQuery(levels: [.critical, .high]),
        RiskQuery(categories: [.dangerousCommand]),
        RiskQuery(categories: [.massDeletion, .sensitivePathAccess]),
        RiskQuery(agentKinds: [.claudeCode]),
        RiskQuery(sessionID: sessionA),
        RiskQuery(sessionID: sessionB),
        RiskQuery(unacknowledgedOnly: true),
        RiskQuery(dateRange: .today(now)),
        RiskQuery(searchText: "secrets"),
        RiskQuery(searchText: "强制", sort: .oldestFirst),
        RiskQuery(limit: 2, offset: 1),
    ]
}

// MARK: - 两侧装配

/// 同一批 fixture 同时喂 InMemory（冻结基准）与 SwiftData 后端。
///
/// - Parameter seedRisksViaRecordRisks: true 时 SwiftData 侧走 `recordRisks`（会重算会话风险计数），
///   InMemory 侧只能 `seed` 预置值 —— fixture 里的 `riskEventCount` 已按派生口径给好，两侧才可比。
private func makePair() async throws -> (InMemoryObservatoryService, SwiftDataObservatoryStore) {
    let reference = InMemoryObservatoryService()
    reference.seed(
        agents: Parity.agents,
        sessions: Parity.sessions,
        events: Parity.events,
        fileChanges: Parity.fileChanges,
        diffs: Parity.diffs,
        commands: Parity.commands,
        performance: Parity.performanceSamples,
        systemPerformance: Parity.systemSamples,
        risks: Parity.risks,
        projects: Parity.projects
    )
    let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
    try await store.upsertAgents(Parity.agents)
    try await store.upsertSessions(Parity.sessions)
    for event in Parity.events { await store.append(event) }
    for change in Parity.fileChanges { await store.append(change) }
    for command in Parity.commands { await store.append(command) }
    for sample in Parity.performanceSamples { await store.append(sample) }
    for sample in Parity.systemSamples { await store.append(sample) }
    for diff in Parity.diffs { try await store.record(diff, forChangeID: diff.id) }
    try await store.recordRisks(Parity.risks)
    try await store.upsertProjects(Parity.projects)
    await store.flush()
    return (reference, store)
}

// MARK: - 断言工具

private func expectSamePage<T: Equatable & Sendable>(
    _ store: Page<T>,
    _ reference: Page<T>,
    label: String,
    identity: (T) -> String
) {
    #expect(store.totalCount == reference.totalCount, "\(label): totalCount 不一致")
    #expect(store.offset == reference.offset, "\(label): offset 不一致")
    #expect(store.items.map(identity) == reference.items.map(identity), "\(label): 页内行或顺序不一致")
    #expect(store.items == reference.items, "\(label): 逐字段不一致")
}

private func expectSameList<T: Equatable & Sendable>(
    _ store: [T],
    _ reference: [T],
    label: String,
    identity: (T) -> String
) {
    #expect(store.map(identity) == reference.map(identity), "\(label): 顺序或集合不一致")
    #expect(store == reference, "\(label): 逐字段不一致")
}

// MARK: - 分页查询一致性

@Suite("SwiftData 与基准：分页查询逐项一致", .timeLimit(.minutes(1)))
struct SwiftDataSessionParityTests {

    @Test("sessions(matching:) 一致", arguments: Parity.sessionQueries)
    func sessions(query: SessionQuery) async throws {
        let (reference, store) = try await makePair()
        expectSamePage(
            try await store.sessions(matching: query),
            try await reference.sessions(matching: query),
            label: "sessions \(query.agentKinds.count)/\(query.searchText)",
            identity: \.id.uuidString
        )
    }
}

@Suite("SwiftData 与基准：事件/文件/命令/风险分页一致", .timeLimit(.minutes(1)))
struct SwiftDataEventParityTests {

    @Test("events(matching:) 一致", arguments: Parity.eventQueries)
    func events(query: EventQuery) async throws {
        let (reference, store) = try await makePair()
        expectSamePage(
            try await store.events(matching: query),
            try await reference.events(matching: query),
            label: "events \(query.kinds.count)/\(query.searchText)",
            identity: \.id.uuidString
        )
    }

    @Test("fileChanges(matching:) 一致", arguments: Parity.fileChangeQueries)
    func fileChanges(query: FileChangeQuery) async throws {
        let (reference, store) = try await makePair()
        expectSamePage(
            try await store.fileChanges(matching: query),
            try await reference.fileChanges(matching: query),
            label: "fileChanges \(query.pathPrefix ?? "nil")/\(query.searchText)",
            identity: \.id.uuidString
        )
    }

    @Test("commands(matching:) 一致", arguments: Parity.commandQueries)
    func commands(query: CommandQuery) async throws {
        let (reference, store) = try await makePair()
        expectSamePage(
            try await store.commands(matching: query),
            try await reference.commands(matching: query),
            label: "commands \(query.searchText)",
            identity: \.id.uuidString
        )
    }

    @Test("riskEvents(matching:) 一致", arguments: Parity.riskQueries)
    func risks(query: RiskQuery) async throws {
        let (reference, store) = try await makePair()
        expectSamePage(
            try await store.riskEvents(matching: query),
            try await reference.riskEvents(matching: query),
            label: "risks \(query.levels.count)",
            identity: \.id.uuidString
        )
    }
}

// MARK: - 单值与列表查询一致性

@Suite("SwiftData 与基准：单值/列表查询一致", .timeLimit(.minutes(1)))
struct SwiftDataSingleValueParityTests {

    @Test("session(id:) 一致：命中 / running / 未命中")
    func sessionByID() async throws {
        let (reference, store) = try await makePair()
        for id in [Parity.sessionA, Parity.sessionRunning, UUID()] {
            let storeValue = try await store.session(id: id)
            let referenceValue = try await reference.session(id: id)
            #expect(storeValue == referenceValue, "session(id: \(id)) 不一致")
        }
    }

    @Test("fileDiff(for:) 一致：逐行相同 / 二进制 / 缺失为 nil")
    func fileDiff() async throws {
        let (reference, store) = try await makePair()
        for id in [Parity.changeText, Parity.changeBinary, UUID()] {
            let storeValue = try await store.fileDiff(for: id)
            let referenceValue = try await reference.fileDiff(for: id)
            #expect(storeValue == referenceValue, "fileDiff(for: \(id)) 不一致")
        }
        let fetched = try await store.fileDiff(for: Parity.changeText)
        let text = try #require(fetched)
        #expect(text.lines.count == 3)
        #expect(text.lines.map(\.style) == [.hunkHeader, .added, .context])
    }

    @Test("performanceSamples(sessionID:) 一致", arguments: [Parity.sessionA, Parity.sessionB, UUID()])
    func performance(sessionID: UUID) async throws {
        let (reference, store) = try await makePair()
        expectSameList(
            try await store.performanceSamples(sessionID: sessionID),
            try await reference.performanceSamples(sessionID: sessionID),
            label: "perf \(sessionID)",
            identity: \.id.uuidString
        )
    }

    @Test("systemPerformance(since:) 一致",
          arguments: [Date(timeIntervalSinceReferenceDate: 0), Parity.today(0.3), Parity.now])
    func systemPerformance(since: Date) async throws {
        let (reference, store) = try await makePair()
        expectSameList(
            try await store.systemPerformance(since: since),
            try await reference.systemPerformance(since: since),
            label: "sysperf since \(since.timeIntervalSinceReferenceDate)",
            identity: \.id.uuidString
        )
    }

    @Test("projects() 一致（同为 lastSeenAt 降序）")
    func projects() async throws {
        let (reference, store) = try await makePair()
        expectSameList(
            try await store.projects(),
            try await reference.projects(),
            label: "projects",
            identity: \.id
        )
    }

    @Test("activeAgents() 一致（running 与 idle 都算活跃）")
    func activeAgents() async throws {
        let (reference, store) = try await makePair()
        expectSameList(
            try await store.activeAgents(),
            try await reference.activeAgents(),
            label: "activeAgents",
            identity: \.id.uuidString
        )
    }

    @Test("projectActivity 区间重算一致",
          arguments: [DateRangeFilter.unbounded, DateRangeFilter.today(Parity.now),
                      DateRangeFilter.lastHours(6, now: Parity.now),
                      DateRangeFilter(start: Parity.today(0.2), end: Parity.today(0.6))])
    func projectActivity(range: DateRangeFilter) async throws {
        let (reference, store) = try await makePair()
        for path in [Parity.projectAlpha, Parity.projectBeta, "/Nope"] {
            let storeValue = try await store.projectActivity(path: path, dateRange: range)
            let referenceValue = try await reference.projectActivity(path: path, dateRange: range)
            #expect(storeValue == referenceValue, "projectActivity(\(path)) 不一致")
        }
    }

    @Test("dashboardStats(for:) 各字段一致",
          arguments: [Parity.now, Parity.daysAgo(1, 0.9), Parity.today(0.5)])
    func dashboard(date: Date) async throws {
        let (reference, store) = try await makePair()
        let storeStats = try await store.dashboardStats(for: date)
        let referenceStats = try await reference.dashboardStats(for: date)
        // 逐字段展开：整体失败时看不出是哪一列算错。
        #expect(storeStats.sessionCount == referenceStats.sessionCount, "sessionCount")
        #expect(abs(storeStats.totalActiveSeconds - referenceStats.totalActiveSeconds) < 1e-6, "totalActiveSeconds")
        #expect(storeStats.filesModified == referenceStats.filesModified, "filesModified")
        #expect(storeStats.filesCreated == referenceStats.filesCreated, "filesCreated")
        #expect(storeStats.filesDeleted == referenceStats.filesDeleted, "filesDeleted")
        #expect(storeStats.commandsExecuted == referenceStats.commandsExecuted, "commandsExecuted")
        #expect(storeStats.failedCommands == referenceStats.failedCommands, "failedCommands")
        #expect(storeStats.riskEventCount == referenceStats.riskEventCount, "riskEventCount")
        #expect(storeStats.highRiskEventCount == referenceStats.highRiskEventCount, "highRiskEventCount")
        #expect(abs(storeStats.averageCPUPercent - referenceStats.averageCPUPercent) < 1e-6, "averageCPUPercent")
        #expect(abs(storeStats.peakCPUPercent - referenceStats.peakCPUPercent) < 1e-6, "peakCPUPercent")
        #expect(storeStats.peakMemoryBytes == referenceStats.peakMemoryBytes, "peakMemoryBytes")
        #expect(storeStats.activeAgentCount == referenceStats.activeAgentCount, "activeAgentCount")
        #expect(storeStats.hourlyActivity == referenceStats.hourlyActivity, "hourlyActivity")
        #expect(storeStats.agentShares == referenceStats.agentShares, "agentShares")
        #expect(storeStats == referenceStats, "DashboardStats 整体")
    }
}

// MARK: - 排序 / 分页语义

@Suite("SwiftData 排序与分页语义", .timeLimit(.minutes(1)))
struct SwiftDataOrderingSemanticsTests {

    @Test("事件按时间倒序，totalCount 是分页前总数")
    func totalBeforePaging() async throws {
        let (reference, store) = try await makePair()
        let page = try await store.events(matching: EventQuery(limit: 2, offset: 0))
        #expect(page.items.count == 2)
        #expect(page.totalCount == Parity.events.count)
        #expect(page.hasMore)
        #expect(page.items[0].timestamp >= page.items[1].timestamp)
        let all = try await reference.events(matching: .all)
        #expect(page.totalCount == all.totalCount)
    }

    @Test("offset 越界返回空页但 totalCount 不变", arguments: [0, 1, 5, 6, 7, 40])
    func offsetBeyondEnd(offset: Int) async throws {
        let (reference, store) = try await makePair()
        let query = EventQuery(limit: 3, offset: offset)
        expectSamePage(
            try await store.events(matching: query),
            try await reference.events(matching: query),
            label: "offset \(offset)",
            identity: \.id.uuidString
        )
    }

    @Test("升序与降序互为首尾颠倒")
    func reverseOrdering() async throws {
        let (_, store) = try await makePair()
        let descending = try await store.events(matching: EventQuery(limit: 100, sort: .newestFirst))
        let ascending = try await store.events(matching: EventQuery(limit: 100, sort: .oldestFirst))
        #expect(descending.items.map { $0.id } == ascending.items.map { $0.id }.reversed())
    }

    @Test("负 limit / 负 offset 收敛为 0，不崩")
    func negativePaging() async throws {
        let (reference, store) = try await makePair()
        let query = EventQuery(limit: -5, offset: -2)
        let page = try await store.events(matching: query)
        #expect(page.items.isEmpty)
        #expect(page.totalCount == (try await reference.events(matching: .all)).totalCount)
        #expect(page.offset == -2, "offset 原样回传查询值")
    }

    @Test("风险按 rank 过滤而非 rawValue 字典序")
    func riskOrdersByRank() async throws {
        let (reference, store) = try await makePair()
        // 字典序会把 "critical" < "high" < "low" < "medium" 当成大小，rank 才是语义。
        let mediumUp = try await store.events(matching: EventQuery(minimumRisk: .medium))
        let referenceMediumUp = try await reference.events(matching: EventQuery(minimumRisk: .medium))
        expectSamePage(mediumUp, referenceMediumUp, label: "minimumRisk=.medium", identity: \.id.uuidString)
        #expect(mediumUp.items.allSatisfy { $0.riskLevel >= .medium })
        #expect(!mediumUp.items.contains { $0.riskLevel == .low })
    }

    @Test("搜索大小写不敏感，且命中同一行")
    func caseInsensitiveSearch() async throws {
        let (reference, store) = try await makePair()
        for needle in ["GIT COMMIT", "git commit", "Git Commit"] {
            let query = CommandQuery(searchText: needle)
            let page = try await store.commands(matching: query)
            expectSamePage(page, try await reference.commands(matching: query),
                           label: "search \(needle)", identity: \.id.uuidString)
            #expect(page.totalCount == 1, "「\(needle)」应命中 1 条")
        }
    }

    @Test("空 Set 过滤 = 不过滤，且与 .all 等价")
    func emptySetsDoNotFilter() async throws {
        let (_, store) = try await makePair()
        let withEmpties = try await store.events(
            matching: EventQuery(kinds: [], agentKinds: [], searchText: "")
        )
        let unfiltered = try await store.events(matching: .all)
        #expect(withEmpties.items.map(\.id) == unfiltered.items.map(\.id))
        #expect(withEmpties.totalCount == unfiltered.totalCount)
    }

    @Test("时间区间两端闭区间：边界时刻本身被包含")
    func closedRangeBoundaries() async throws {
        let (reference, store) = try await makePair()
        let boundary = Parity.today(0.3)
        let query = EventQuery(dateRange: DateRangeFilter(start: boundary, end: boundary))
        expectSamePage(
            try await store.events(matching: query),
            try await reference.events(matching: query),
            label: "closed range at boundary",
            identity: \.id.uuidString
        )
        #expect(query.dateRange.contains(boundary), "契约自身把 end 当闭区间")
        #expect(try await store.events(matching: query).totalCount == 1)
    }

    @Test("projectPath 是精确相等而不是前缀")
    func projectPathIsExact() async throws {
        let (reference, store) = try await makePair()
        let query = EventQuery(projectPath: Parity.projectAlpha)
        expectSamePage(
            try await store.events(matching: query),
            try await reference.events(matching: query),
            label: "projectPath exact",
            identity: \.id.uuidString
        )
        let partial = try await store.events(matching: EventQuery(projectPath: FixturePaths.work))
        #expect(partial.items.isEmpty, "前缀不该命中")
    }
}

// MARK: - tie-break 确定性（InMemory 覆盖不到）

@Suite("SwiftData 排序确定性", .timeLimit(.minutes(1)))
struct SwiftDataOrderingDeterminismTests {

    /// 三条**时间戳完全相同**的事件：只有靠 `id DESC` tie-break 才能得到确定顺序，
    /// 而这正是 SQLite 后端 `ORDER BY ts DESC|ASC, id DESC` 的口径。
    /// InMemory 没有 tie-breaker，所以这条只能按规则直接断言，不能做对照断言。
    private func makeTiedStore() async throws -> (SwiftDataObservatoryStore, [UUID]) {
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let at = Parity.today(0.5)
        var ids: [UUID] = []
        for index in 0..<3 {
            let candidate = try #require(UUID(uuidString: "7777777\(index)-0000-0000-0000-00000000000\(index)"))
            ids.append(candidate)
        }
        for id in ids {
            await store.append(TimelineEvent(id: id, timestamp: at, kind: .fileModified, title: "同刻"))
        }
        await store.flush()
        return (store, ids)
    }

    @Test("同时间戳按 id 降序，与 sort 方向无关")
    func tieBreakIsAlwaysIDDescending() async throws {
        let (store, ids) = try await makeTiedStore()
        let expected = ids.sorted { $0.uuidString > $1.uuidString }
        let descending = try await store.events(matching: EventQuery(sort: .newestFirst))
        let ascending = try await store.events(matching: EventQuery(sort: .oldestFirst))
        #expect(descending.items.map { $0.id } == expected)
        #expect(ascending.items.map { $0.id } == expected,
                "tie-breaker 恒为 id DESC（对齐 SQL 的 `, id DESC`），不随排序方向翻转")
    }

    @Test("翻页不重不漏：把 tie 数据逐页读完，集合等于全集")
    func pagingIsStable() async throws {
        let (store, ids) = try await makeTiedStore()
        var seen: [UUID] = []
        var offset = 0
        while true {
            let page = try await store.events(matching: EventQuery(limit: 1, offset: offset))
            if page.items.isEmpty { break }
            seen += page.items.map(\.id)
            offset += 1
            if offset > 10 { Issue.record("翻页未收敛，疑似游标不稳定"); break }
        }
        #expect(Set(seen) == Set(ids))
        #expect(seen.count == ids.count)
    }
}
