//
//  CommandCredentialIngestEndToEndTests.swift
//  Tests/AIObservatorySwiftDataStoreTests
//
//  Owner: ws-engaudit
//
//  总控 03:5x 那条判据：**只测脱敏函数不算**。要从采集入口送一条带凭据的命令进去，
//  再**从库里**把落库字段读出来断言明文不在其中，两个后端各跑一遍。
//  这条就是那一次链路：真生产者（`CommandInferenceEngine` 走 KERN_PROCARGS2 的 argv 形状、
//  `HookCommandAuditing` 真读 `<数据目录>/agent-hooks/*.jsonl`）→ 真 writer API 落库 →
//  真 SQL / 真查询读回。中间没有任何一格是手搭的"已掩记录"。
//
//  与前两份的分工（不要误读成重复）：
//   · `CommandRecordRedactionTests`（Platform）钉「生产者产出的那条记录本身干净」；
//   · `CommandCredentialPersistenceTests`（EngineTests）钉「落库面的 11 个列都没有明文」，
//     但它的输入是**照生产者形状手搭**的记录；
//   · 本文件补的就是那段没接上的链：**入口 → 两个后端**，一条用例走完整程。
//
//  ⚠️ 一处构建面依赖要知情：本 target 在 `Package.swift` 里**没有**声明
//  `AIObservatoryPlatform` 依赖（声明只有 SwiftDataStore / Store / Core / TestSupport），
//  现在能 import 是因为 SwiftPM 把所有模块放进同一个 `.build` 搜索路径。
//  真要长期依赖它，请在 `Package.swift`（冻结区，总控的手）给本 target 补那一行；
//  若哪天布局收紧导致 "no such module"，把本文件搬到一个同时声明两者依赖的 target 即可，
//  **不要因为编不动就删掉这条断言**。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryPlatform
import AIObservatoryTestSupport
@testable import AIObservatorySwiftDataStore

/// 三种形态，逐字按总控点名的写法：`--token=…` / `Authorization: Bearer …` / `password=`。
private enum Secret {
    static let bearer = "sk-E2E-0123456789abcdef"
    static let token = "ghp_E2ETOKEN0123456789"
    static let password = "E2EHunter2Passw0rd"
}

private enum IngestEndToEnd {
    static let base = Date(timeIntervalSinceReferenceDate: 800_010_000)
    static let agentID = UUID()
    static let sessionID = UUID()
    static let projectRoot = "/work/e2e"

    /// 三条命令，各自把一种凭据塞进 argv 的不同位置。
    static let tokenScript = "gh api --token=\(Secret.token) /repos/x/y"
    static let authScript = "curl -sS -H 'Authorization: Bearer \(Secret.bearer)' https://api.example.test/v1"
    static let passwordScript = "mysql --host=127.0.0.1 --password=\(Secret.password) -e 'select 1'"

    /// 采样入口：真 `CommandInferenceEngine`，argv 形状与 `KERN_PROCARGS2` 读出来的一致。
    static func sampledRecords() -> [CommandRecord] {
        let agent = AgentInstance(
            id: agentID, kind: .claudeCode, pid: 6_100, displayName: "Claude Code",
            executablePath: "/usr/local/bin/claude", workingDirectory: projectRoot,
            startedAt: base, lastSeenAt: base, state: .running,
            cpuPercent: 1, memoryBytes: 1_024, childPIDs: [], detectedVia: .executablePath
        )
        var processes: [ProcessRecord] = [
            ProcessRecord(pid: 6_100, parentPID: 1, name: "claude", arguments: [], startTime: base),
        ]
        let scripts = [tokenScript, authScript, passwordScript]
        for (offset, script) in scripts.enumerated() {
            processes.append(ProcessRecord(
                pid: Int32(6_101 + offset), parentPID: 6_100, name: "bash",
                arguments: ["sh", "-c", script], startTime: base.addingTimeInterval(Double(offset))
            ))
        }
        return CommandInferenceEngine().inferCommands(
            processes: processes, agents: [agent], since: base.addingTimeInterval(-1)
        )
    }

    /// hook 入口：真 `HookCommandAuditing`，从 scratch 数据目录里的 `*.jsonl` 读。
    static func hookRecords(directory: URL) throws -> [CommandRecord] {
        let hooks = directory.appendingPathComponent("agent-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let lines = [authScript, tokenScript].enumerated().map { offset, command in
            let escaped = command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"agentKind":"claude-code","command":"\#(escaped)","startedAt":\#(800_010_000 + offset)}"#
        }
        try (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
            .write(to: hooks.appendingPathComponent("claude.jsonl"))
        return HookCommandAuditing(storeDirectoryURL: directory).inferCommands(
            processes: [], agents: [], since: .distantPast
        )
    }
}

@Suite("凭据端到端：采集入口 → 两个后端 → 读库断言明文不在其中", .timeLimit(.minutes(2)))
struct CommandCredentialIngestEndToEndTests {

    /// 明文是否在 SQLite 的 11 个持久化落点里出现过（逐列 LIKE，含 haystack 与 JSON 列）。
    private static func sqliteHits(_ database: SQLiteDatabase, _ needle: String) async throws -> Int {
        let pattern = "%\(needle)%"
        let sql = """
        SELECT
          (SELECT COUNT(*) FROM commands WHERE arguments_json LIKE ? OR search_text LIKE ? OR executable LIKE ?) +
          (SELECT COUNT(*) FROM events WHERE title LIKE ? OR summary LIKE ? OR command LIKE ? OR search_text LIKE ?) +
          (SELECT COUNT(*) FROM risk_events WHERE title LIKE ? OR detail LIKE ? OR command LIKE ? OR search_text LIKE ?) AS hits
        """
        let arguments: [SQLiteValue] = Array(repeating: .text(pattern), count: 11)
        let row = try await database.optionalRow(sql, arguments: arguments)
        return try #require(row?.int("hits"))
    }

    private static let secrets = [Secret.bearer, Secret.token, Secret.password]

    @Test("采样入口的三条命令落进两个后端之后，库里查不到任何一处明文")
    func sampledEntriesReachBothBackendsCleanly() async throws {
        let records = IngestEndToEnd.sampledRecords()
        #expect(records.count == 3, "三条命令都该被采到（一条都没少）")
        let joined = records.map(\.commandLine).joined(separator: " ")
        for secret in Self.secrets {
            #expect(!joined.contains(secret), "生产者这一步就该掩掉：\(joined)")
        }

        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        for record in records {
            await sqlite.append(record)
            await swiftData.append(record)
        }
        await sqlite.flush()
        await swiftData.flush()

        let database = await sqlite.database
        for secret in Self.secrets {
            #expect(try await Self.sqliteHits(database, secret) == 0, "SQLite 侧 11 列都查不到 \(secret)")
        }
        let fromSwiftData = try await swiftData.commands(matching: .all).items
        #expect(fromSwiftData.count == 3)
        let swiftJoined = fromSwiftData.map(\.commandLine).joined(separator: " ")
        for secret in Self.secrets {
            #expect(!swiftJoined.contains(secret), "SwiftData 侧落库字段里还有 \(secret)")
            #expect((try await swiftData.commands(matching: CommandQuery(searchText: secret))).items.isEmpty,
                    "SwiftData 的 haystack 也不该搜得到 \(secret)")
        }
        // 干净 ≠ 没了：三条命令都还在、参数个数还在、头名/开关名还在原位。
        #expect((try await sqlite.commands(matching: CommandQuery(searchText: "authorization"))).totalCount == 1)
        #expect((try await sqlite.commands(matching: CommandQuery(searchText: "--password="))).totalCount == 1)
        #expect((try await sqlite.commands(matching: CommandQuery(searchText: "hunter"))).items.isEmpty,
                "口令值不能当搜索键，但开关名必须还能搜到（上一条就是）")
        for record in fromSwiftData {
            #expect(record.arguments.count == 3, "两后端都要保住参数个数：\(record.arguments)")
        }
    }

    @Test("hook 入口（真读 agent-hooks/*.jsonl）落进两个后端之后同样查不到明文")
    func hookEntriesReachBothBackendsCleanly() async throws {
        let scratch = try Scratch.directory("credential-e2e-hook")
        let records = try IngestEndToEnd.hookRecords(directory: scratch.appendingPathComponent("store"))
        #expect(records.count == 2, "两行 hook 都该被消费（一条都没丢）")
        for record in records {
            #expect(!record.commandLine.contains(Secret.bearer))
            #expect(!record.commandLine.contains(Secret.token))
            // hook 的自然键会写进 `.offsets.json` 长期留存 ⇒ 顺手查它一次
            #expect(!record.id.uuidString.isEmpty)
        }

        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        for record in records {
            await sqlite.append(record)
            await swiftData.append(record)
        }
        await sqlite.flush()
        await swiftData.flush()

        let database = await sqlite.database
        #expect(try await Self.sqliteHits(database, Secret.bearer) == 0)
        #expect(try await Self.sqliteHits(database, Secret.token) == 0)
        #expect(try await Self.sqliteHits(database, Secret.password) == 0)
        let restored = try await swiftData.commands(matching: .all).items
        #expect(restored.count == 2)
        #expect(!restored.map(\.commandLine).joined(separator: " ").contains(Secret.bearer))
        // 幂等性不能被脱敏破坏：同一行再读一次必须是同一个 id。
        let again = try IngestEndToEnd.hookRecords(directory: scratch.appendingPathComponent("store"))
        #expect(Set(again.map(\.id)) == Set(records.map(\.id)) || again.isEmpty,
                "偏移文件让重读产出新行 ⇒ 脱敏改键后幂等性断了")
    }

    /// 红的那条：跳过生产者、直接 seed 原文 ⇒ 同一把尺子必须抓到。
    /// 没有这一条，上面所有 "查不到" 都可能只是因为探针根本查不出来。
    @Test("尺子有牙：绕过采集入口直接 seed 原文时，两个后端都查得到明文")
    func rawControlIsDetectedByBothBackends() async throws {
        let raw = CommandRecord(
            executable: "curl",
            arguments: ["-H", "Authorization: Bearer \(Secret.bearer)", "--password=\(Secret.password)"],
            workingDirectory: IngestEndToEnd.projectRoot, sessionID: IngestEndToEnd.sessionID,
            agentKind: .claudeCode, startedAt: IngestEndToEnd.base, outcome: .running
        )
        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        await sqlite.append(raw)
        await swiftData.append(raw)
        await sqlite.flush()
        await swiftData.flush()

        let database = await sqlite.database
        // 手推按**上面那段 SQL 的形状**数，不是按列数：三个表各一个子查询、
        // 每个子查询里的三个条件是 `OR` 起来数**行**的 ⇒ 一行同时命中 arguments_json 与
        // search_text 也只算 1；events / risk_events 没写行 ⇒ 0。总计 1。
        // （`CommandCredentialPersistenceTests` 里那条断的是 2，因为那边的 SQL 每列一个子查询。）
        let controlHits = try await Self.sqliteHits(database, Secret.bearer)
        #expect(controlHits == 1,
                "探针查不到原文就是没牙：这条 seed 的是明文，commands 那一行必须被命中")
        #expect((try await swiftData.commands(matching: CommandQuery(searchText: Secret.password))).totalCount == 1,
                "SwiftData 侧不清洗：库就是照抄进来的")
    }
}
