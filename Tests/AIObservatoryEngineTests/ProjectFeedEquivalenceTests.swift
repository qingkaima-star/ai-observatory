//
//  ProjectFeedEquivalenceTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws-engaudit
//
//  窄取数（`ObservatoryStore.projectFeed`）换的是**取多少列**，不许换结论。
//  这条用例就是那道闸：同一份数据，宽路（五路 `SELECT *`）与窄路各自的聚合输出必须
//  逐字段相同；行序与截断也必须相同（超过上限时两侧选到同一批行）。
//
//  为什么值得单独钉：窄路没取的列在领域对象里是**类型默认值**（`arguments: []`、
//  `title: ""`、`outcome: .unknown`…）。哪天 `ProjectMapper` 开始读一个没取的列，
//  没有这条用例就会静默少算——而「声明了却没喂」正是本仓最主要的缺陷族。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
@testable import AIObservatoryEngine

private let feedBase = Date(timeIntervalSinceReferenceDate: 800_004_000)

private enum FeedFixture {
    static let root = "/work/Alpha"
    /// 固定 id：不给 `UUID(uuidString:)!`——本仓不许强制解包，哪怕是字面量。
    static func id(_ key: String) -> UUID { StableID.uuid(namespace: "feedfixture", key: key) }
    static let agent = UUID()
    static let sessionA = UUID()
    static let sessionB = UUID()
    static let sessionNoProject = UUID()

    static func sessions() -> [AgentSession] {
        [
            AgentSession(id: sessionA, displayIndex: 1, kind: .claudeCode, agentID: agent,
                         title: "会话 A · 带着没人读的一堆列", projectPath: root,
                         startedAt: feedBase, endedAt: feedBase.addingTimeInterval(600),
                         modifiedFileCount: 4, createdFileCount: 2, deletedFileCount: 1,
                         commandCount: 9, failedCommandCount: 3, cpuSeconds: 42.5,
                         peakCPUPercent: 88, peakMemoryBytes: 1 << 30, estimatedTokens: 9_000,
                         riskEventCount: 2, outcome: .success),
            AgentSession(id: sessionB, displayIndex: 2, kind: .openAICodex, agentID: agent,
                         title: "会话 B", projectPath: root,
                         startedAt: feedBase.addingTimeInterval(100), outcome: .running),
            // 归属拿不到的会话：projectPath 为 nil，两侧都必须把它挡在桶外。
            AgentSession(id: sessionNoProject, displayIndex: 3, kind: .unknown,
                         title: "无项目", startedAt: feedBase.addingTimeInterval(200)),
        ]
    }

    static func fileChanges() -> [FileChange] {
        [
            FileChange(id: id("change-a-1"),
                       path: "\(root)/Sources/a.swift", kind: .modified,
                       timestamp: feedBase.addingTimeInterval(10), agentID: agent, sessionID: sessionA,
                       agentKind: .claudeCode, sizeBytes: 512, previousSizeBytes: 480, isText: true,
                       linesAdded: 12, linesRemoved: 3, riskLevel: .high, projectPath: root),
            FileChange(id: id("change-b"),
                       path: "\(root)/Sources/b.swift", kind: .created,
                       timestamp: feedBase.addingTimeInterval(20), agentID: agent, sessionID: sessionA,
                       agentKind: .claudeCode, sizeBytes: 64, isText: true,
                       linesAdded: 4, linesRemoved: 0, projectPath: root),
            FileChange(id: id("change-readme"),
                       path: "\(root)/README.md", kind: .deleted,
                       timestamp: feedBase.addingTimeInterval(30), agentID: agent, sessionID: sessionB,
                       agentKind: .openAICodex, sizeBytes: 0, previousSizeBytes: 900, isText: true,
                       linesAdded: 0, linesRemoved: 40, riskLevel: .critical, projectPath: root),
            // 同一文件再改一次：热文件是按 path 聚合的，窄路漏字段的话这里最先露。
            FileChange(id: id("change-a-2"),
                       path: "\(root)/Sources/a.swift", kind: .modified,
                       timestamp: feedBase.addingTimeInterval(40), agentID: agent, sessionID: sessionB,
                       agentKind: .openAICodex, sizeBytes: 700, previousSizeBytes: 512, isText: true,
                       linesAdded: 7, linesRemoved: 1, projectPath: root),
            // 归属在别处 + unknown agentKind：两条分支都要两侧一致。
            FileChange(id: id("change-elsewhere"),
                       path: "/elsewhere/x.txt", kind: .modified,
                       timestamp: feedBase.addingTimeInterval(50), agentKind: .unknown,
                       linesAdded: 1, linesRemoved: 1, projectPath: "/elsewhere"),
        ]
    }

    static func commands() -> [CommandRecord] {
        [
            CommandRecord(id: id("cmd-swift"),
                          executable: "swift",
                          arguments: ["test", "--filter", "ProjectFeed", "--password=‹redacted:password_assignment›"],
                          workingDirectory: root, agentID: agent, sessionID: sessionA,
                          agentKind: .claudeCode, startedAt: feedBase.addingTimeInterval(15),
                          endedAt: feedBase.addingTimeInterval(18), exitCode: 1, outcome: .failure,
                          isDestructive: true, requiresConfirmation: true, riskLevel: .high,
                          projectPath: root),
            CommandRecord(id: id("cmd-git"),
                          executable: "git", arguments: ["push", "origin", "ws/engaudit"],
                          workingDirectory: root, agentID: agent, sessionID: sessionB,
                          agentKind: .openAICodex, startedAt: feedBase.addingTimeInterval(25),
                          outcome: .success, projectPath: root),
        ]
    }

    static func events() -> [TimelineEvent] {
        [
            TimelineEvent(id: id("event-modified"),
                          timestamp: feedBase.addingTimeInterval(12), sessionID: sessionA,
                          agentID: agent, agentKind: .claudeCode, kind: .fileModified,
                          title: "改了一个没人读的大标题", summary: "摘要也长到没人读",
                          filePath: "\(root)/Sources/a.swift", command: "swift test --filter x",
                          exitCode: 0, durationSeconds: 3.5,
                          cost: ResourceCost(cpuSeconds: 1.5, memoryBytes: 1 << 20,
                                             bytesRead: 4096, bytesWritten: 1024),
                          riskLevel: .medium, projectPath: root),
            TimelineEvent(id: id("event-git"),
                          timestamp: feedBase.addingTimeInterval(22), sessionID: sessionB,
                          agentKind: .openAICodex, kind: .gitOperation, title: "push",
                          summary: "推了一次", filePath: root, projectPath: root),
        ]
    }

    static func risks() -> [RiskEvent] {
        [
            RiskEvent(id: id("risk-deletion"),
                      timestamp: feedBase.addingTimeInterval(16), level: .critical,
                      category: .massDeletion, title: "标题不取", detail: "详情也不取",
                      agentID: agent, agentKind: .claudeCode, sessionID: sessionA,
                      command: "rm -rf " + root, filePaths: ["\(root)/Sources/a.swift"],
                      matchedRuleID: "risk.destructive.mass-deletion-window"),
            RiskEvent(id: id("risk-memory"),
                      timestamp: feedBase.addingTimeInterval(26), level: .medium,
                      category: .resourceAbuse, title: "内存峰值超限",
                      detail: "没有路径 ⇒ 两侧都该跳过它", agentKind: .openAICodex,
                      sessionID: sessionB, matchedRuleID: "risk.pattern.excessive-memory-peak"),
        ]
    }

    static func seed(_ store: ObservatoryStore) async throws {
        try await store.upsertSessions(sessions())
        for change in fileChanges() { await store.append(change) }
        for command in commands() { await store.append(command) }
        for event in events() { await store.append(event) }
        try await store.recordRisks(risks())
        await store.flush()
    }

    static let mapper = ProjectMapper(resolver: { path in
        path.hasPrefix("/work/Alpha") ? "/work/Alpha" : (path.hasPrefix("/elsewhere") ? "/elsewhere" : nil)
    })
}

@Suite("窄取数与全量取数：聚合输出与截断必须同结论", .timeLimit(.minutes(1)))
struct ProjectFeedEquivalenceTests {

    /// 宽路：今天那五条 `SELECT *` 分页查询。
    private func wideAggregate(_ store: ObservatoryStore) async throws -> [ProjectActivity] {
        FeedFixture.mapper.aggregate(
            changes: try await store.fileChanges(matching: FileChangeQuery(limit: 2_000)).items,
            commands: try await store.commands(matching: CommandQuery(limit: 2_000)).items,
            events: try await store.events(matching: EventQuery(limit: 2_000)).items,
            sessions: try await store.sessions(matching: SessionQuery(limit: 500)).items,
            risks: try await store.riskEvents(matching: RiskQuery(limit: 500)).items
        )
    }

    private func narrowAggregate(_ store: ObservatoryStore, limit: Int = 2_000) async throws -> [ProjectActivity] {
        let feed = try await store.projectFeed(
            fileChangeLimit: limit, commandLimit: limit, eventLimit: limit,
            sessionLimit: 500, riskLimit: 500
        )
        return FeedFixture.mapper.aggregate(
            changes: feed.fileChanges, commands: feed.commands, events: feed.events,
            sessions: feed.sessions, risks: feed.risks
        )
    }

    @Test("同一份数据：窄路聚合逐字段等于宽路")
    func narrowEqualsWide() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await FeedFixture.seed(store)
        let wide = try await wideAggregate(store)
        let narrow = try await narrowAggregate(store)
        #expect(!wide.isEmpty, "fixture 得先产出项目，否则这条断言是空的")
        #expect(narrow == wide, "窄取数改变了项目地图的结论：\(narrow.map(\.path)) vs \(wide.map(\.path))")
        #expect(narrow.map(\.id) == wide.map(\.id), "顺序也是结论的一部分")
        // 逐项点几个派生量：整体相等之外，把最容易被漏算的三格单独说出来。
        let alpha = try #require(wide.first { $0.path == FeedFixture.root })
        let alphaNarrow = try #require(narrow.first { $0.path == FeedFixture.root })
        #expect(alphaNarrow.fileChangeCount == alpha.fileChangeCount)
        #expect(alphaNarrow.codeGrowthLines == alpha.codeGrowthLines)
        #expect(alphaNarrow.hotFiles == alpha.hotFiles, "热文件靠 path/agentKind/timestamp 算，窄路必须带齐")
    }

    @Test("上限截断时两侧选到同一批行（顺序口径没被换掉）")
    func truncationMatches() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await FeedFixture.seed(store)
        // 5 条 fileChanges、limit 2 ⇒ 只留时间最新的两条；两侧必须是同样的两条。
        let wide = try await store.fileChanges(matching: FileChangeQuery(limit: 2)).items
        let feed = try await store.projectFeed(
            fileChangeLimit: 2, commandLimit: 2, eventLimit: 2, sessionLimit: 500, riskLimit: 500
        )
        #expect(feed.fileChanges.map(\.id) == wide.map(\.id),
                "窄路的 ORDER BY / LIMIT 与 pagedRows 不一致：\(feed.fileChanges.map(\.id)) vs \(wide.map(\.id))")
        #expect(feed.commands.map(\.id) == (try await store.commands(matching: CommandQuery(limit: 2)).items).map(\.id))
        #expect(feed.risks.count == 2)
        #expect(feed.sessions.count == 3)
    }

    @Test("窄路确实没带那些大列：这是省下来的那一块，不是漏读")
    func feedCarriesOnlyWhatTheMapperReads() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await FeedFixture.seed(store)
        let feed = try await store.projectFeed(
            fileChangeLimit: 2_000, commandLimit: 2_000, eventLimit: 2_000, sessionLimit: 500, riskLimit: 500
        )
        let command = try #require(feed.commands.first { $0.executable == "swift" })
        #expect(command.arguments.isEmpty, "arguments_json 不再解——每行一次 JSONDecoder 就是省在这里")
        #expect(command.outcome == .unknown, "没取的列是默认值；这些对象只为聚合服务")
        let event = try #require(feed.events.first)
        #expect(event.title.isEmpty && event.summary.isEmpty)
        let risk = try #require(feed.risks.first { $0.id == FeedFixture.id("risk-deletion") })
        #expect(risk.title.isEmpty && risk.detail.isEmpty)
        // filePaths 是这条唯一非省不可的 JSON：它决定风险归到哪个项目。
        #expect(risk.filePaths == ["/work/Alpha/Sources/a.swift"])
        // 归属用的列必须在：缺了就会少一个项目，而那是「静默少算」不是「报错」。
        #expect(feed.fileChanges.allSatisfy { $0.projectPath != nil || $0.path.hasPrefix("/elsewhere") })
    }
}
