//
//  StoreWriteTruthTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Asserts
//
//  写入侧的**绝对真值**：`acknowledge` 之后的状态、`prune` 之后的残留集、
//  `search_text` 这一列到底存了什么、以及 `system_perf` v3 四个新列的三态。
//
//  为什么单独一个文件：这四件事都没有「第二个实现」可对照（SwiftData 后端还没接 prune，
//  内存参考实现根本没有 prune/acknowledge 之外的写路径），所以只能靠硬编码期望值。
//  期望值全部按本文件的 fixture 手算；时间一律用 `Date(timeIntervalSince1970:)` 定死，
//  不读墙钟。落库用 `.inMemory`，因此本文件不产生任何磁盘写入。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryStore

// MARK: - 夹具

private enum WriteFixture {
    /// 固定基准（2023-11-15 06:00 UTC），与真实时钟无关。
    static let base = Date(timeIntervalSince1970: 1_700_000_400)
    static func at(_ seconds: TimeInterval) -> Date { base.addingTimeInterval(seconds) }

    static let agent = UUID()
    static let session = UUID()

    static func session(endedAt: Date? = at(60)) -> AgentSession {
        AgentSession(id: session, displayIndex: 7, kind: .claudeCode, agentID: agent,
                     title: "会话 · 七号", projectPath: "/work/Alpha",
                     startedAt: base, endedAt: endedAt,
                     modifiedFileCount: 1, commandCount: 1, outcome: endedAt == nil ? .running : .success)
    }

    static func agentRow(lastSeen: Date) -> AgentInstance {
        AgentInstance(id: agent, kind: .claudeCode, pid: 9001, displayName: "Claude Code",
                      executablePath: "/usr/local/bin/claude", workingDirectory: "/work/Alpha",
                      startedAt: base, lastSeenAt: lastSeen, state: .running,
                      cpuPercent: 5, memoryBytes: 1_024, childPIDs: [], detectedVia: .executablePath)
    }
}

private func makeStore() async throws -> ObservatoryStore {
    try await ObservatoryStore.open(configuration: .inMemory)
}

// MARK: - search_text 列内容

@Suite("Store 写入侧：search_text 列的字面内容", .timeLimit(.minutes(1)))
struct SearchTextColumnTests {

    /// 原来搜索只有「两边命中同一条」——两侧都在写入侧把 haystack 拼错（比如漏掉 projectPath、
    /// 或者只小写化 needle 不小写化 haystack）时，对账永远看不出来。
    /// 这里直接读 `search_text` 那一列，逐字对照手算的拼接结果。
    @Test("五张表的 search_text 等于手算的小写拼接串")
    func searchTextColumns() async throws {
        let store = try await makeStore()
        let database = await store.database

        try await store.upsertSessions([WriteFixture.session()])
        await store.append(TimelineEvent(timestamp: WriteFixture.base, sessionID: WriteFixture.session,
                                         agentID: WriteFixture.agent, agentKind: .claudeCode,
                                         kind: .commandExecuted, title: "Swift TEST",
                                         summary: "退出码 1", command: "Git Push --FORCE",
                                         projectPath: "/Work/Alpha"))
        await store.append(FileChange(path: "/Work/Alpha/README.md", kind: .created,
                                      timestamp: WriteFixture.base, agentID: WriteFixture.agent,
                                      sessionID: WriteFixture.session, agentKind: .claudeCode))
        await store.append(CommandRecord(executable: "Swift", arguments: ["Test", "--filter", "Auth"],
                                         workingDirectory: "/work/Alpha", agentID: WriteFixture.agent,
                                         sessionID: WriteFixture.session, agentKind: .claudeCode,
                                         startedAt: WriteFixture.base, exitCode: 1, outcome: .failure,
                                         riskLevel: .high, projectPath: "/work/Alpha"))
        try await store.recordRisks([
            RiskEvent(timestamp: WriteFixture.base, level: .high, category: .dangerousCommand,
                      title: "强制推送", detail: "Git Push", agentKind: .claudeCode,
                      sessionID: WriteFixture.session, command: "git push --FORCE",
                      matchedRuleID: "git-push-force"),
        ])
        await store.flush()

        #expect(try await searchText(database, table: "sessions", id: WriteFixture.session.uuidString)
                == "会话 · 七号 /work/alpha claude code",
                "会话 haystack = 标题 + 项目路径 + 种类显示名，整体小写")
        #expect(try await searchText(database, table: "events", id: eventID(store))
                == "swift test 退出码 1  git push --force",
                "事件 haystack = 标题 + 摘要 + filePath(空) + command，整体小写")
        #expect(try await searchText(database, table: "file_changes",
                                     id: changeID(store, path: "/Work/Alpha/README.md"))
                == "/work/alpha/readme.md", "文件变更 haystack 只用 path 小写，不含目录名之外的字段")
        #expect(try await searchText(database, table: "commands", id: commandID(store))
                == "swift test --filter auth", "命令 haystack = commandLine 小写（末位参数必须在）")
        #expect(try await searchText(database, table: "risk_events", id: riskID(store))
                == "强制推送 git push git push --force", "风险 haystack = 标题 + 详情 + 命令")
    }

    private func searchText(_ database: SQLiteDatabase, table: String, id: String) async throws -> String {
        let row = try #require(try await database.optionalRow(
            "SELECT search_text FROM \(table) WHERE id = ?", arguments: [.text(id)]
        ))
        return try #require(row.text("search_text"))
    }

    /// 缓冲写不回填 id，因此按可识别的列反查主键。
    private func eventID(_ store: ObservatoryStore) async throws -> String {
        let page = try await store.events(matching: .all)
        return try #require(page.items.first).id.uuidString
    }

    private func changeID(_ store: ObservatoryStore, path: String) async throws -> String {
        let page = try await store.fileChanges(matching: FileChangeQuery(searchText: "readme"))
        return try #require(page.items.first { $0.path == path }).id.uuidString
    }

    private func commandID(_ store: ObservatoryStore) async throws -> String {
        let page = try await store.commands(matching: .all)
        return try #require(page.items.first).id.uuidString
    }

    private func riskID(_ store: ObservatoryStore) async throws -> String {
        let page = try await store.riskEvents(matching: .all)
        return try #require(page.items.first).id.uuidString
    }
}

// MARK: - acknowledge 之后状态

@Suite("Store 写入侧：acknowledge 之后的状态", .timeLimit(.minutes(1)))
struct AcknowledgeStateTests {

    /// 原来 `riskCountAndAcknowledgement` 只断「未确认条数从 3 变 2」——
    /// 把「所有行都置 1」写进去也会先绿再红得不确定，而且被点那条自己读回什么、
    /// 别的字段有没有被顺带改掉，完全没断。这里逐条钉死。
    @Test("acknowledgeRisk 只把被点那条翻成已确认，其余字段与计数不动")
    func acknowledgeFlipsExactlyOneRow() async throws {
        let store = try await makeStore()
        let database = await store.database
        try await store.upsertSessions([WriteFixture.session()])

        let ids = [UUID(), UUID(), UUID()]
        let risks = [
            RiskEvent(id: ids[0], timestamp: WriteFixture.at(10), level: .critical, category: .massDeletion,
                      title: "批量删除", detail: "42 个删除", agentKind: .openAICodex,
                      sessionID: WriteFixture.session, command: "rm -rf ./build",
                      filePaths: ["/a/1.txt", "/a/2.txt"], requiresConfirmation: true,
                      matchedRuleID: "mass-deletion-window"),
            RiskEvent(id: ids[1], timestamp: WriteFixture.at(20), level: .high, category: .dangerousCommand,
                      title: "强制推送", detail: "git push --force", agentKind: .claudeCode,
                      sessionID: WriteFixture.session, command: "git push origin main --force",
                      requiresConfirmation: true, matchedRuleID: "git-push-force"),
            RiskEvent(id: ids[2], timestamp: WriteFixture.at(30), level: .medium, category: .unknown,
                      title: "未归类风险", detail: "", agentKind: .geminiCLI,
                      sessionID: WriteFixture.session),
        ]
        try await store.recordRisks(risks)

        let before = try await store.riskEvents(matching: .all)
        #expect(before.items.map(\.title) == ["未归类风险", "强制推送", "批量删除"], "倒序，三条全在")
        #expect(before.items.allSatisfy { !$0.isAcknowledged })
        #expect(try await store.session(id: WriteFixture.session)?.riskEventCount == 3)

        try await store.acknowledgeRisk(id: ids[1])

        let unacknowledged = try await store.riskEvents(matching: RiskQuery(unacknowledgedOnly: true))
        #expect(unacknowledged.items.map(\.title) == ["未归类风险", "批量删除"],
                "未确认集合必须恰好剩下没被点的两条")
        #expect(unacknowledged.totalCount == 2)

        let flipped = try #require(try await store.riskEvents(matching: .all).items.first { $0.id == ids[1] })
        #expect(flipped.isAcknowledged == true)
        // 确认动作不得顺手改动别的东西。
        #expect(flipped.title == "强制推送")
        #expect(flipped.detail == "git push --force")
        #expect(flipped.level == .high)
        #expect(flipped.category == .dangerousCommand)
        #expect(flipped.command == "git push origin main --force")
        #expect(flipped.matchedRuleID == "git-push-force")
        #expect(flipped.requiresConfirmation == true)
        #expect(flipped.filePaths == [])
        #expect(flipped.sessionID == WriteFixture.session)

        let untouched = try #require(try await store.riskEvents(matching: .all).items.first { $0.id == ids[0] })
        #expect(untouched.isAcknowledged == false, "同批次的另一条不得被顺带确认")
        #expect(untouched.filePaths == ["/a/1.txt", "/a/2.txt"])

        // 底层确实是 1/0，而不是 NULL：界面按 `isAcknowledged` 分支时不能撞上第三态。
        let flags = try await database.rows("SELECT id, is_acknowledged FROM risk_events ORDER BY timestamp ASC")
        #expect(flags.compactMap { $0.column("is_acknowledged") } == [.integer(0), .integer(1), .integer(0)])

        // 重复确认幂等；确认不存在的 id 不得动到任何一条。
        try await store.acknowledgeRisk(id: ids[1])
        try await store.acknowledgeRisk(id: UUID())
        #expect(try await store.riskEvents(matching: RiskQuery(unacknowledgedOnly: true)).totalCount == 2)
        #expect(try await store.riskEvents(matching: .all).totalCount == 3)
        #expect(try await store.session(id: WriteFixture.session)?.riskEventCount == 3,
                "确认不改变风险计数")
    }
}

// MARK: - prune 之后残留集

@Suite("Store 写入侧：prune 之后的残留集", .timeLimit(.minutes(1)))
struct PruneResidualTests {

    /// 原来只断「events 删了 2 条、rowCount 剩 2 条」：既没断**剩的是哪两条**，
    /// 也没覆盖另外 10 张表各自用哪个时间列——把 `sessions` 的 `started_at` 写错成
    /// `ended_at`、或把 `<` 写成 `<=`，都不一定红。
    @Test("prune 每表恰好删 1 条，残留集与边界行完全确定")
    func pruneKeepsExactlyTheExpectedResiduals() async throws {
        let store = try await makeStore()
        let cutoff = WriteFixture.base
        let old = WriteFixture.at(-1)
        let future = WriteFixture.at(1)

        // 每张表三种角色：old 必删、恰好落在 cutoff 的那条必须留（`<` 是严格的）、future 必留。
        try await store.upsertAgents([
            WriteFixture.agentRow(lastSeen: old),
            AgentInstance(id: UUID(), kind: .cursorAgent, pid: 9002, displayName: "Keeper",
                          executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                          startedAt: cutoff, lastSeenAt: cutoff, state: .running,
                          cpuPercent: 1, memoryBytes: 2_048, childPIDs: [], detectedVia: .bundleIdentifier),
            AgentInstance(id: UUID(), kind: .windsurf, pid: 9003, displayName: "Fresh",
                          executablePath: "/Applications/Windsurf.app/Contents/MacOS/Windsurf",
                          startedAt: future, lastSeenAt: future, state: .running,
                          detectedVia: .processName),
        ])
        try await store.upsertSessions([
            sessionRow(id: UUID(), title: "过期会话", startedAt: old),
            sessionRow(id: UUID(), title: "边界会话", startedAt: cutoff),
            sessionRow(id: UUID(), title: "新会话", startedAt: future),
        ])
        try await store.upsertProjects([
            projectRow(id: "expired", name: "Expired", lastSeen: old),
            projectRow(id: "boundary", name: "Boundary", lastSeen: cutoff),
            projectRow(id: "fresh", name: "Fresh", lastSeen: future),
        ])
        for (index, title) in ["过期事件", "边界事件", "新事件"].enumerated() {
            await store.append(TimelineEvent(timestamp: date(index, old: old, cut: cutoff, future: future),
                                             kind: .fileModified, title: title))
        }
        for (index, name) in ["gone.txt", "edge.txt", "keep.txt"].enumerated() {
            await store.append(FileChange(path: "/repo/\(name)", kind: .modified,
                                          timestamp: date(index, old: old, cut: cutoff, future: future),
                                          agentKind: .claudeCode))
        }
        for (index, line) in ["rm -rf /", "echo edge", "echo keep"].enumerated() {
            let parts = line.split(separator: " ").map(String.init)
            await store.append(CommandRecord(executable: parts[0], arguments: Array(parts.dropFirst()),
                                             agentKind: .claudeCode,
                                             startedAt: date(index, old: old, cut: cutoff, future: future)))
        }
        for (index, cpu) in [11.0, 22.0, 33.0].enumerated() {
            await store.append(PerformanceSample(timestamp: date(index, old: old, cut: cutoff, future: future),
                                                 cpuPercent: cpu))
        }
        for (index, cpu) in [44.0, 55.0, 66.0].enumerated() {
            await store.append(SystemPerformanceSample(
                timestamp: date(index, old: old, cut: cutoff, future: future), cpuTotalPercent: cpu))
        }
        let changeIDs = [UUID(), UUID(), UUID()]
        for index in 0..<3 {
            try await store.record(FileDiff(id: changeIDs[index], path: "/repo/f\(index).txt", kind: .modified,
                                            lines: [DiffLine(style: .added, text: "x", newLineNumber: 1)],
                                            linesAdded: 1, linesRemoved: 0,
                                            capturedAt: date(index, old: old, cut: cutoff, future: future)),
                                   forChangeID: changeIDs[index])
            try await store.recordSnapshot(FileSnapshot(path: "/repo/f\(index).txt", contentHash: "h\(index)",
                                                        sizeBytes: UInt64(index),
                                                        capturedAt: date(index, old: old, cut: cutoff, future: future),
                                                        lineCount: 1))
        }
        try await store.recordRisks([
            RiskEvent(timestamp: old, level: .high, category: .dangerousCommand, title: "过期风险",
                      agentKind: .claudeCode),
            RiskEvent(timestamp: cutoff, level: .high, category: .dangerousCommand, title: "边界风险",
                      agentKind: .claudeCode),
            RiskEvent(timestamp: future, level: .high, category: .dangerousCommand, title: "新风险",
                      agentKind: .claudeCode),
        ])
        await store.flush()

        // 先确认起点：11 张表各有 3 行（agents 2 行、sessions 3 行 …）。
        #expect(try await store.rowCount(table: StoreSchema.Table.events) == 3)
        #expect(try await store.rowCount(table: StoreSchema.Table.agents) == 3)

        let result = try await store.prune(olderThan: cutoff, vacuum: false)

        // 每表删除条数：手算 = 只有 `old` 那一条落在 cutoff 之前（`<` 严格，边界行必须留下）。
        // 表名按字面写死，不取 `StoreSchema.prunable`——否则给清单里加/换一张表会被静默吸收。
        #expect(result.deletedRowsByTable == [
            "file_snapshots": 1,
            "diffs": 1,
            "perf_samples": 1,
            "events": 1,
            "file_changes": 1,
            "commands": 1,
            "risk_events": 1,
            "system_perf": 1,
            "sessions": 1,
            "agents": 1,
            "projects": 1,
        ], "11 张表各自的时间列都必须挑对那一条过期行")
        #expect(result.totalDeletedRows == 11)
        #expect(result.cutoff == cutoff)
        #expect(result.didVacuum == false)

        // 残留集：具体是哪几条，而不只是条数。
        #expect(try await titles(store.events(matching: .all)) == ["新事件", "边界事件"])
        #expect(try await paths(store.fileChanges(matching: .all)) == ["keep.txt", "edge.txt"])
        #expect(try await store.commands(matching: .all).items.map(\.commandLine) == ["echo keep", "echo edge"])
        #expect(try await store.riskEvents(matching: .all).items.map(\.title) == ["新风险", "边界风险"])
        #expect(try await store.sessions(matching: .all).items.map(\.title) == ["新会话", "边界会话"])
        #expect(try await store.projects().map(\.name) == ["Fresh", "Boundary"])
        #expect(try await store.activeAgents().map(\.displayName) == ["Fresh", "Keeper"])
        let perf = try await store.database.rows("SELECT cpu_percent FROM perf_samples ORDER BY timestamp ASC")
        #expect(perf.compactMap { $0.double("cpu_percent") } == [22.0, 33.0])
        let system = try await store.systemPerformance(since: WriteFixture.at(-3_600))
        #expect(system.map(\.cpuTotalPercent) == [55.0, 66.0])
        #expect(try await store.rowCount(table: StoreSchema.Table.fileSnapshots) == 2)
        #expect(try await store.fileDiff(for: changeIDs[0]) == nil, "过期那条 diff 必须没了")
        #expect(try await store.fileDiff(for: changeIDs[1]) != nil, "边界那条 diff 必须留下")
        #expect(try await store.fileDiff(for: changeIDs[2]) != nil)
        #expect(try await store.deletedFileChangeCount(sessionID: nil, from: WriteFixture.at(-86_400),
                                                      to: WriteFixture.at(86_400)) == 0)
    }

    private func date(_ index: Int, old: Date, cut: Date, future: Date) -> Date {
        switch index {
        case 0: return old
        case 1: return cut
        default: return future
        }
    }

    private func titles(_ page: Page<TimelineEvent>) -> [String] { page.items.map(\.title) }

    private func paths(_ page: Page<FileChange>) -> [String] {
        page.items.map { ($0.path as NSString).lastPathComponent }
    }

    private func sessionRow(id: UUID, title: String, startedAt: Date) -> AgentSession {
        AgentSession(id: id, displayIndex: 1, kind: .claudeCode, title: title,
                     projectPath: "/repo", startedAt: startedAt, endedAt: startedAt.addingTimeInterval(5),
                     outcome: .success)
    }

    private func projectRow(id: String, name: String, lastSeen: Date) -> ProjectActivity {
        ProjectActivity(id: id, name: name, path: "/p/\(name)", fileChangeCount: 1, commandCount: 1,
                        sessionCount: 1, riskEventCount: 0, codeGrowthLines: 1, codeShrinkLines: 0,
                        firstSeenAt: lastSeen, lastSeenAt: lastSeen)
    }
}

// MARK: - system_perf v3 四列的三态

@Suite("Store 写入侧：system_perf v3 四列的三态", .timeLimit(.minutes(1)))
struct SystemPerfThreeStateTests {

    /// 「有值」「读不到 + 原因」「真的是 0」三件事必须在库里三种写法、读回来三件事。
    /// 只要有一侧把 nil 写成 0，界面就会把「这台机器给不出网络计数」念成「真的没有流量」。
    /// 现有用例只断过「有值」那一支（StoreInternalsTests 的 v3 升级用例名字说到了 NULL，
    /// 但没断），这里补齐并逐列下探到原始列值。
    @Test("网络入/出/原因/GPU：nil 存 NULL、0 存 0，二者读回来不互塌")
    func threeStatesStayDistinct() async throws {
        let store = try await makeStore()
        let database = await store.database

        let legacyID = UUID()
        let zeroID = UUID()
        let reasonID = UUID()
        let valuedID = UUID()

        // (a) 老库行形状：只写 v1 的 12 列，v3 四列交给 DEFAULT NULL。
        try await database.execute([SQLiteStatement("""
            INSERT INTO system_perf (id, timestamp, cpu_total_percent, cpu_system_percent, cpu_user_percent,
                memory_used_bytes, memory_total_bytes, disk_read_bytes_per_second,
                disk_write_bytes_per_second, load_average_1m, thermal_celsius, power_watts)
            VALUES (?,?,?,?,?,?,?,?,?,?,?,?)
            """, arguments: [
            .text(legacyID.uuidString), .real(WriteFixture.base.timeIntervalSinceReferenceDate),
            .real(1), .real(0.5), .real(0.5),
            .integer(1_000), .integer(2_000), .real(3), .real(4), .real(5), .null, .null,
        ])])

        // (b) 真的是 0：不是没采到。
        await store.append(SystemPerformanceSample(id: zeroID, timestamp: WriteFixture.at(1),
                                                   cpuTotalPercent: 2,
                                                   networkInBytesPerSecond: 0,
                                                   networkOutBytesPerSecond: 0,
                                                   gpuActivityPercent: 0))
        // (c) 没采到，但带原因。
        await store.append(SystemPerformanceSample(id: reasonID, timestamp: WriteFixture.at(2),
                                                   cpuTotalPercent: 3,
                                                   networkAvailability: .countersUnreadable))
        // (d) 有值；此时原因列应当是 NULL（而不是残留一个假原因）。
        await store.append(SystemPerformanceSample(id: valuedID, timestamp: WriteFixture.at(3),
                                                   cpuTotalPercent: 4,
                                                   networkInBytesPerSecond: 3_000,
                                                   networkOutBytesPerSecond: 4_000,
                                                   gpuActivityPercent: 64))
        await store.flush()

        let all = try await store.systemPerformance(since: WriteFixture.at(-1))
        #expect(all.count == 4)
        #expect(all.map(\.cpuTotalPercent) == [1, 2, 3, 4], "timestamp 升序")

        let legacy = try #require(all.first { $0.id == legacyID })
        #expect(legacy.networkInBytesPerSecond == nil, "v3 之前的老行 ⇒ nil（当时没采这个指标）")
        #expect(legacy.networkOutBytesPerSecond == nil)
        #expect(legacy.networkAvailability == nil)
        #expect(legacy.gpuActivityPercent == nil)
        #expect(legacy.thermalCelsius == nil && legacy.powerWatts == nil)

        let zero = try #require(all.first { $0.id == zeroID })
        #expect(zero.networkInBytesPerSecond == 0, "真的是 0，不是 nil")
        #expect(zero.networkOutBytesPerSecond == 0)
        #expect(zero.gpuActivityPercent == 0, "GPU 空闲 0% 与「读不出 GPU」是两件事")
        #expect(zero.networkAvailability == nil, "拿到了 0 就不该有「拿不到」的原因")

        let reason = try #require(all.first { $0.id == reasonID })
        #expect(reason.networkInBytesPerSecond == nil)
        #expect(reason.networkOutBytesPerSecond == nil)
        #expect(reason.networkAvailability == .countersUnreadable, "原因必须单独留得住")
        #expect(reason.gpuActivityPercent == nil)

        let valued = try #require(all.first { $0.id == valuedID })
        #expect(valued.networkInBytesPerSecond == 3_000)
        #expect(valued.networkOutBytesPerSecond == 4_000)
        #expect(valued.gpuActivityPercent == 64)
        #expect(valued.networkAvailability == nil)

        // 再往下探一层：库里确实是 NULL / 0 / 文本，而不是靠读取侧的猜测。
        let row = try #require(try await database.optionalRow(
            "SELECT network_in_bytes_per_second AS net_in, network_availability AS why, gpu_percent AS gpu," +
            " thermal_celsius AS temp FROM system_perf WHERE id = ?",
            arguments: [.text(legacyID.uuidString)]
        ))
        #expect(row.column("net_in") == .null, "老行的网络列在库里就是 NULL，不是 0")
        #expect(row.column("why") == .null)
        #expect(row.column("gpu") == .null)
        #expect(row.column("temp") == .null)
        let reasonRow = try #require(try await database.optionalRow(
            "SELECT network_availability AS why FROM system_perf WHERE id = ?",
            arguments: [.text(reasonID.uuidString)]
        ))
        #expect(reasonRow.column("why") == .text("countersUnreadable"))
        let zeroRow = try #require(try await database.optionalRow(
            "SELECT network_in_bytes_per_second AS net_in, gpu_percent AS gpu FROM system_perf WHERE id = ?",
            arguments: [.text(zeroID.uuidString)]
        ))
        #expect(zeroRow.column("net_in") == .real(0))
        #expect(zeroRow.column("gpu") == .real(0))
    }

    /// 会话级采样表同样有这个问题：`gpu_percent`/`thermal_celsius`/`power_watts` 可空，
    /// `network_bytes_in/out` 却是 NOT NULL —— 两者不能靠同一套「没值就 0」的写法糊过去。
    @Test("perf_samples：可空列存 NULL，非空列的 0 是真 0")
    func perfSampleNullability() async throws {
        let store = try await makeStore()
        let database = await store.database
        let id = UUID()
        await store.append(PerformanceSample(id: id, timestamp: WriteFixture.base,
                                             sessionID: WriteFixture.session, cpuPercent: 7,
                                             memoryBytes: 1_024))
        await store.flush()

        let sample = try #require(try await store.performanceSamples(sessionID: WriteFixture.session).first)
        #expect(sample.id == id)
        #expect(sample.gpuPercent == nil)
        #expect(sample.thermalCelsius == nil)
        #expect(sample.powerWatts == nil)
        #expect(sample.diskReadBytesPerSecond == 0 && sample.diskWriteBytesPerSecond == 0)
        #expect(sample.networkBytesIn == 0 && sample.networkBytesOut == 0)

        let row = try #require(try await database.optionalRow(
            "SELECT gpu_percent AS gpu, thermal_celsius AS temp, power_watts AS watts," +
            " network_bytes_in AS net_in FROM perf_samples WHERE id = ?",
            arguments: [.text(id.uuidString)]
        ))
        #expect(row.column("gpu") == .null)
        #expect(row.column("temp") == .null)
        #expect(row.column("watts") == .null)
        #expect(row.column("net_in") == .integer(0), "NOT NULL 列写入的是真 0，与上面的 NULL 不同")
    }
}

// MARK: - 数值列的存储类型

@Suite("Store 写入侧：UInt64 以 bitPattern 存成 INTEGER", .timeLimit(.minutes(1)))
struct UInt64EncodingTests {

    /// 光比 Swift 侧的往返相等不够：`UInt64(Int64.max) + 1` 就是 2^63，Double 能精确表示它，
    /// 所以把写入改成 `.real(Double(value))` 之后「读回来还等于原值」这条照样绿
    /// ——变异检查实测如此（M11 全绿）。这里换一个 Double 表示不了的奇数值，
    /// 并直接断库里那一列的类型是 INTEGER。
    @Test("超过 Int64.max 的 memoryBytes：奇数值让 REAL 编码必然露馅")
    func hugeMemoryBytesStoredAsInteger() async throws {
        let store = try await makeStore()
        let database = await store.database
        let id = UUID()
        // 2^63 + 1001：奇数，Double 在该量级的间距是 2048，舍不到它 ⇒ 走 REAL 存就回不来。
        let value = UInt64(Int64.max) &+ 1_002
        #expect(value == 9_223_372_036_854_776_809)
        try await store.upsertAgents([
            AgentInstance(id: id, kind: .claudeCode, pid: 1, displayName: "Huge",
                          executablePath: "/usr/bin/true", startedAt: WriteFixture.base,
                          lastSeenAt: WriteFixture.base, state: .running, cpuPercent: 0,
                          memoryBytes: value, childPIDs: [], detectedVia: .processName),
        ])

        let restored = try #require(try await store.activeAgents().first)
        #expect(restored.id == id)
        #expect(restored.memoryBytes == value, "REAL 编码会在奇数上暴露精度损失")
        let row = try #require(try await database.optionalRow(
            "SELECT memory_bytes FROM agents WHERE id = ?", arguments: [.text(id.uuidString)]
        ))
        #expect(row.column("memory_bytes") == .integer(-9_223_372_036_854_774_807),
                "底层必须是 INTEGER（bitPattern），不能是 REAL 也不是 TEXT")
    }
}
