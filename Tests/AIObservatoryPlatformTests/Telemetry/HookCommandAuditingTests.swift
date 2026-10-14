//
//  HookCommandAuditingTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-CmdSrc
//  ─────────────────────────────────────────────────────────
//  精确命令来源（Agent hook 落盘 JSONL）的行为验收，对应
//  `04-决策记录/IFR-command-precision.md` 验收第 2 条：
//  正常行保真、缺字段行丢弃并计数、重复读幂等、重启从偏移续读。
//
//  全部落盘只在 `Scratch.directory(...)`（当前检出自带的 `.scratch-tests/`）内，
//  用例结束即删除；不读 AiX 之外任何路径。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 测试辅助

/// `ISO8601DateFormatter` 未标注 `Sendable`；建好之后只读，与生产代码同一口径。
nonisolated(unsafe) private let iso8601Fractional: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return formatter
}()

private func iso(_ date: Date) -> String { iso8601Fractional.string(from: date) }

/// 一条 hook 记录的时间基准（固定值，避免用例之间互相影响）。
private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

/// 手工拼一行 hook JSONL；只给非 nil 的字段，用于造「缺字段」的行。
private func hookLine(
    agentKind: String? = "claudeCode",
    sessionId: String? = nil,
    command: String? = "git status",
    arguments: [String]? = nil,
    workingDirectory: String? = nil,
    startedAt: String? = nil,
    endedAt: String? = nil,
    exitCode: Int? = nil,
    durationMs: Double? = nil,
    source: String? = "hook",
    extraFields: [String: String] = [:]
) -> String {
    var fields: [String] = []
    func add(_ key: String, _ value: String) { fields.append("\"\(key)\":\(value)") }
    if let agentKind { add("agentKind", "\"\(agentKind)\"") }
    if let sessionId { add("sessionId", "\"\(sessionId)\"") }
    if let command { add("command", "\"\(command)\"") }
    if let arguments { add("arguments", "[" + arguments.map { "\"\($0)\"" }.joined(separator: ",") + "]") }
    if let workingDirectory { add("workingDirectory", "\"\(workingDirectory)\"") }
    if let startedAt { add("startedAt", "\"\(startedAt)\"") }
    if let endedAt { add("endedAt", "\"\(endedAt)\"") }
    if let exitCode { add("exitCode", "\(exitCode)") }
    if let durationMs { add("durationMs", "\(durationMs)") }
    if let source { add("source", "\"\(source)\"") }
    for (key, value) in extraFields { add(key, value) }
    return "{" + fields.joined(separator: ",") + "}"
}

/// 测试夹具：一个 `.scratch-tests/<purpose>/store` 目录，`agent-hooks/` 已建好。
/// 用例结束时（实例离开作用域）整目录删除——落盘只在 scratch 内，且不留下残渣。
private final class HookFixture {
    let root: URL
    let storeDirectory: URL
    let hooksDirectory: URL
    var jsonlName: String

    init(purpose: String, jsonlName: String = "claude.jsonl") throws {
        let root = try Scratch.directory("hook-" + purpose)
        self.root = root
        storeDirectory = root.appendingPathComponent("store", isDirectory: true)
        hooksDirectory = storeDirectory.appendingPathComponent("agent-hooks", isDirectory: true)
        self.jsonlName = jsonlName
        try FileManager.default.createDirectory(at: hooksDirectory, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    var jsonlURL: URL { hooksDirectory.appendingPathComponent(jsonlName) }

    /// 追加若干整行（自带换行）。模拟 Agent hook 一行一行往外写。
    func appendLines(_ lines: [String]) throws {
        let data = (lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        try Self.append(data, to: jsonlURL)
    }

    /// 追加原始字节（用于造「没有结尾换行的半行」）。
    func appendRaw(_ text: String) throws {
        try Self.append(Data(text.utf8), to: jsonlURL)
    }

    func write(_ text: String, to name: String) throws {
        try Data(text.utf8).write(to: hooksDirectory.appendingPathComponent(name))
    }

    private static func append(_ data: Data, to url: URL) throws {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }
}

private func claudeAgent(id: UUID = UUID()) -> AgentInstance {
    AgentInstance(
        id: id,
        kind: .claudeCode,
        pid: 4242,
        displayName: "Claude Code",
        executablePath: "/usr/local/bin/claude",
        startedAt: t0
    )
}

/// 一次读取，拿记录。
private func read(_ auditing: HookCommandAuditing, agents: [AgentInstance] = []) -> [CommandRecord] {
    auditing.inferCommands(processes: [], agents: agents, since: .distantPast)
}

// MARK: - 正常路径

@Suite("Hook 命令来源：正常行入库", .timeLimit(.minutes(1)))
struct HookCommandAuditingHappyPathTests {

    @Test("带 exitCode 与 endedAt 的行：命令文本、退出码、耗时逐格保真")
    func fullLinePreservesExitCodeAndDuration() throws {
        let fixture = try HookFixture(purpose: "happy")
        let started = t0
        let ended = t0.addingTimeInterval(1.25)
        try fixture.appendLines([
            hookLine(command: "git status", startedAt: iso(started), endedAt: iso(ended), exitCode: 0),
        ])

        let agent = claudeAgent()
        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        let records = read(auditing, agents: [agent])

        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.commandLine == "git status")
        #expect(record.exitCode == 0)
        #expect(record.outcome == .success)
        #expect(record.startedAt == started)
        #expect(record.endedAt == ended)
        #expect(record.duration ?? 0 > 1.24)
        #expect(record.duration ?? 0 < 1.26)
        #expect(record.agentID == agent.id)
        #expect(record.agentKind == .claudeCode)
        #expect(auditing.stats.droppedLineCount == 0)
    }

    @Test("arguments 存在时 commandLine 为 command + 参数；带引号的参数不被拆坏")
    func argumentsAppendToCommandLine() throws {
        let fixture = try HookFixture(purpose: "args")
        try fixture.appendLines([
            hookLine(command: "/bin/ls", arguments: ["-la", "my dir"], startedAt: iso(t0)),
        ])
        let record = try #require(read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)).first)
        #expect(record.commandLine == "/bin/ls -la my dir")
        #expect(record.arguments == ["-la", "my dir"])
    }

    @Test("只有 durationMs：endedAt 由 startedAt + durationMs 推出，耗时不失真")
    func durationMsDerivesEndedAt() throws {
        let fixture = try HookFixture(purpose: "durationms")
        try fixture.appendLines([
            hookLine(command: "jq . f.json", startedAt: iso(t0), exitCode: 0, durationMs: 42),
        ])
        let record = try #require(read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)).first)
        #expect(record.exitCode == 0)
        #expect(record.duration ?? 0 > 0.041)
        #expect(record.duration ?? 0 < 0.043)
    }

    @Test("非零退出码记为 failure；只有 startedAt 的行记为 running，不伪造结局")
    func outcomeMappingIsHonest() throws {
        let fixture = try HookFixture(purpose: "outcome")
        try fixture.appendLines([
            hookLine(command: "false", startedAt: iso(t0), endedAt: iso(t0.addingTimeInterval(0.2)), exitCode: 1),
            hookLine(command: "sleep 1", startedAt: iso(t0)),
        ])
        let records = read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory))
        #expect(records.count == 2)
        let failed = records.first { $0.executable == "false" }
        #expect(failed?.outcome == .failure)
        #expect(failed?.exitCode == 1)
        let running = records.first { $0.executable == "sleep" }
        #expect(running?.outcome == .running)
        #expect(running?.exitCode == nil)
        #expect(running?.endedAt == nil)
    }

    @Test("带 exitCode 的破坏性命令被分级为 destructive/high，风险层拿得到输入")
    func destructiveLineIsClassified() throws {
        let fixture = try HookFixture(purpose: "destructive")
        try fixture.appendLines([
            hookLine(command: "rm -rf ./junk", startedAt: iso(t0), endedAt: iso(t0.addingTimeInterval(0.3)), exitCode: 0),
        ])
        let record = try #require(read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)).first)
        #expect(record.isDestructive)
        #expect(record.riskLevel == .high)
        #expect(record.requiresConfirmation)
    }

    @Test("同一轮多行按 startedAt 升序返回（时间线口径）")
    func recordsSortedByStartedAt() throws {
        let fixture = try HookFixture(purpose: "sorted")
        try fixture.appendLines([
            hookLine(command: "later", startedAt: iso(t0.addingTimeInterval(5))),
            hookLine(command: "earlier", startedAt: iso(t0)),
        ])
        let records = read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory))
        #expect(records.map(\.executable) == ["earlier", "later"])
    }

    @Test("sessionId 透传；非法 sessionId 置空而不是编一个")
    func sessionIdPassesThroughOrStaysNil() throws {
        let fixture = try HookFixture(purpose: "session")
        let session = UUID()
        try fixture.appendLines([
            hookLine(sessionId: session.uuidString, command: "pwd", startedAt: iso(t0)),
            hookLine(sessionId: "not-a-uuid", command: "whoami", startedAt: iso(t0)),
        ])
        let records = read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory))
        #expect(records.first { $0.executable == "pwd" }?.sessionID == session)
        #expect(records.first { $0.executable == "whoami" }?.sessionID == nil)
    }

    @Test("agentKind 认别名；认不出来落 unknown，不做猜测归因")
    func agentKindAliases() throws {
        let fixture = try HookFixture(purpose: "alias")
        try fixture.appendLines([
            hookLine(agentKind: "claude", command: "one", startedAt: iso(t0)),
            hookLine(agentKind: "codex", command: "two", startedAt: iso(t0)),
            hookLine(agentKind: "mythical-agent", command: "three", startedAt: iso(t0)),
        ])
        let records = read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory))
        #expect(records.first { $0.executable == "one" }?.agentKind == .claudeCode)
        #expect(records.first { $0.executable == "two" }?.agentKind == .openAICodex)
        #expect(records.first { $0.executable == "three" }?.agentKind == .unknown)
    }

    @Test("command 文本按 shell 方式切成 argv：引号内的空格不是分隔符")
    func commandTextTokenizesLikeShell() throws {
        let fixture = try HookFixture(purpose: "tokenize")
        try fixture.appendLines([
            hookLine(command: "/bin/ls -la 'my dir'", startedAt: iso(t0)),
        ])
        let record = try #require(read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)).first)
        #expect(record.executable == "/bin/ls")
        #expect(record.arguments == ["-la", "my dir"])
        #expect(record.commandLine == "/bin/ls -la my dir")
    }

    @Test("endedAt 早于 startedAt 的行不产出负耗时，但命令与退出码照样入库")
    func invertedTimestampLosesDurationOnly() throws {
        let fixture = try HookFixture(purpose: "inverted")
        try fixture.appendLines([
            hookLine(command: "date", startedAt: iso(t0), endedAt: iso(t0.addingTimeInterval(-5)), exitCode: 0),
        ])
        let record = try #require(read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)).first)
        #expect(record.executable == "date")
        #expect(record.exitCode == 0)
        #expect(record.endedAt == nil)
        #expect(record.duration == nil)
    }

    @Test("时间戳接受 Unix 秒（数字），不要因为写法不同就丢命令")
    func unixEpochTimestampAccepted() throws {
        let fixture = try HookFixture(purpose: "epoch")
        let epoch = t0.timeIntervalSince1970
        try fixture.appendRaw(
            "{\"agentKind\":\"claudeCode\",\"command\":\"echo epoch\",\"startedAt\":\(epoch),\"exitCode\":0}\n"
        )
        let record = try #require(read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)).first)
        #expect(abs(record.startedAt.timeIntervalSince(t0)) < 0.001)
        #expect(record.exitCode == 0)
    }

    @Test("没有匹配的 Agent 实例时仍入库，agentID 留空")
    func recordsWithoutMatchingAgentStillLand() throws {
        let fixture = try HookFixture(purpose: "noagent")
        try fixture.appendLines([hookLine(command: "uptime", startedAt: iso(t0))])
        let records = read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory), agents: [])
        #expect(records.count == 1)
        #expect(records[0].agentID == nil)
        #expect(records[0].exitCode == nil)
    }
}

// MARK: - 丢弃与计数

@Suite("Hook 命令来源：坏行丢弃并计数", .timeLimit(.minutes(1)))
struct HookCommandAuditingDiscardTests {

    @Test("缺 command 的行不入库、被计数，且不猜成空命令")
    func missingCommandIsDroppedAndCounted() throws {
        let fixture = try HookFixture(purpose: "drop-command")
        try fixture.appendLines([
            hookLine(command: nil, startedAt: iso(t0), exitCode: 0),
            hookLine(command: "", startedAt: iso(t0), exitCode: 0),
            hookLine(command: "echo ok", startedAt: iso(t0)),
        ])
        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        let records = read(auditing)
        #expect(records.map(\.commandLine) == ["echo ok"])
        #expect(auditing.stats.droppedLineCount == 2)
        #expect(auditing.stats.missingCommandCount == 2)
        #expect(auditing.stats.parsedLineCount == 3)
    }

    @Test("缺或坏 startedAt 的行不入库、被计数")
    func missingOrBrokenStartedAtIsDroppedAndCounted() throws {
        let fixture = try HookFixture(purpose: "drop-started")
        try fixture.appendLines([
            hookLine(command: "ls", startedAt: nil),
            hookLine(command: "pwd", startedAt: "昨天下午"),
            hookLine(command: "echo ok", startedAt: iso(t0)),
        ])
        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        #expect(read(auditing).map(\.commandLine) == ["echo ok"])
        #expect(auditing.stats.missingTimestampCount == 2)
    }

    @Test("JSON 语法坏的行不入库、被计数，同文件后续行照常入库")
    func malformedJSONDoesNotBlockFollowingLines() throws {
        let fixture = try HookFixture(purpose: "drop-json")
        try fixture.appendLines([
            "{\"agentKind\":\"claudeCode\"",
            hookLine(command: "echo ok", startedAt: iso(t0)),
        ])
        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        #expect(read(auditing).map(\.commandLine) == ["echo ok"])
        #expect(auditing.stats.malformedLineCount == 1)
    }

    @Test("schema 之外的未知字段忽略，不影响入库")
    func unknownFieldsIgnored() throws {
        let fixture = try HookFixture(purpose: "unknown-field")
        try fixture.appendLines([
            hookLine(command: "echo ok", startedAt: iso(t0), exitCode: 0, extraFields: [
                "toolName": "\"Bash\"",
                "transcriptPath": "\"/some/where.jsonl\"",
            ]),
        ])
        let records = read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory))
        #expect(records.map(\.commandLine) == ["echo ok"])
        #expect(records.first?.exitCode == 0)
    }

    @Test("超过单行上限的行按丢弃计数，偏移照样前进（不会被永久卡住）")
    func oversizedLineDroppedButOffsetAdvances() throws {
        let fixture = try HookFixture(purpose: "oversized")
        let padding = String(repeating: "a", count: 900_000)
        try fixture.appendRaw("{\"agentKind\":\"claudeCode\",\"command\":\"\(padding)\"}\n")
        try fixture.appendLines([hookLine(command: "echo ok", startedAt: iso(t0))])

        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        #expect(read(auditing).map(\.commandLine) == ["echo ok"])
        #expect(auditing.stats.oversizedLineCount == 1)
        // 第二轮不再有内容
        #expect(read(auditing).isEmpty)
    }
}

// MARK: - 偏移 / 幂等 / 重启

@Suite("Hook 命令来源：增量读、幂等与重启续读", .timeLimit(.minutes(1)))
struct HookCommandAuditingOffsetTests {

    @Test("偏移增量：每轮只消费新追加的行，不重扫历史")
    func onlyNewLinesConsumedEachPass() throws {
        let fixture = try HookFixture(purpose: "incremental")
        try fixture.appendLines([hookLine(command: "one", startedAt: iso(t0))])
        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        #expect(read(auditing).map(\.executable) == ["one"])
        #expect(read(auditing).isEmpty)

        try fixture.appendLines([hookLine(command: "two", startedAt: iso(t0))])
        #expect(read(auditing).map(\.executable) == ["two"])
        #expect(auditing.stats.parsedLineCount == 2)
    }

    @Test("幂等：内容完全相同的行被重复追加两次，只产出一条记录")
    func duplicatedIdenticalLineProducedOnce() throws {
        let fixture = try HookFixture(purpose: "idempotent")
        let line = hookLine(command: "echo hi", startedAt: iso(t0), exitCode: 0)
        try fixture.appendLines([line])
        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        #expect(read(auditing).count == 1)

        try fixture.appendLines([line])
        #expect(read(auditing).isEmpty)
        #expect(auditing.stats.duplicateLineCount == 1)
    }

    @Test("重启续读：新建实例从持久化偏移接着读，不漏不重")
    func restartResumesFromPersistedOffset() throws {
        let fixture = try HookFixture(purpose: "restart")
        try fixture.appendLines([hookLine(command: "before-restart", startedAt: iso(t0))])
        #expect(read(HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)).count == 1)

        // 模拟进程重启：全新实例，同一目录。
        try fixture.appendLines([hookLine(command: "after-restart", startedAt: iso(t0))])
        let restarted = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        let records = read(restarted)
        #expect(records.map(\.executable) == ["after-restart"])
        #expect(restarted.stats.parsedLineCount == 1)
    }

    @Test("半行（缺结尾换行）不消耗偏移；补全后恰好产出一次")
    func partialLineDoesNotConsumeOffset() throws {
        let fixture = try HookFixture(purpose: "partial")
        let whole = hookLine(command: "echo tail", startedAt: iso(t0), exitCode: 0)
        try fixture.appendRaw(String(whole.prefix(whole.count - 12)))

        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        #expect(read(auditing).isEmpty)
        #expect(auditing.stats.parsedLineCount == 0)

        try fixture.appendRaw(whole.suffix(12) + "\n")
        #expect(read(auditing).map(\.commandLine) == ["echo tail"])
        #expect(read(auditing).isEmpty)
    }

    @Test("文件被轮转/清空（size 小于偏移）时回到开头重读，不报错也不卡死")
    func truncatedFileRestartsFromZero() throws {
        let fixture = try HookFixture(purpose: "truncate")
        try fixture.appendLines([hookLine(command: "first", startedAt: iso(t0))])
        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        #expect(read(auditing).count == 1)

        try Data().write(to: fixture.jsonlURL)
        try fixture.appendLines([hookLine(command: "second", startedAt: iso(t0))])
        #expect(read(auditing).map(\.executable) == ["second"])
    }

    @Test("多个 *.jsonl 各自维护偏移；非 jsonl 文件与子目录一律不读")
    func onlyJsonlFilesReadWithPerFileOffsets() throws {
        let fixture = try HookFixture(purpose: "multi-file")
        try fixture.appendLines([hookLine(command: "from-claude", startedAt: iso(t0))])
        try fixture.write(hookLine(command: "not-jsonl", startedAt: iso(t0)) + "\n", to: "claude.csv")
        try fixture.write("not jsonl at all\n", to: "notes.txt")
        try fixture.write(hookLine(command: "from-codex", startedAt: iso(t0)) + "\n", to: "codex.jsonl")
        try FileManager.default.createDirectory(
            at: fixture.hooksDirectory.appendingPathComponent("nested.jsonl", isDirectory: true),
            withIntermediateDirectories: true
        )

        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        let executables = read(auditing).map(\.executable).sorted()
        #expect(executables == ["from-claude", "from-codex"])
    }

    @Test("hooks 目录里指向目录外的符号链接不读（边界：只读 agent-hooks 自己的文件）")
    func symlinkPointingOutsideIsNotReaded() throws {
        let fixture = try HookFixture(purpose: "symlink")
        try fixture.appendLines([hookLine(command: "inside", startedAt: iso(t0))])
        // 同一 scratch 根下、但不在 agent-hooks 里的另一个 jsonl：链接过去也不该被读。
        let outside = fixture.storeDirectory
            .appendingPathComponent("outside.jsonl")
        try (hookLine(command: "outside", startedAt: iso(t0)) + "\n").data(using: .utf8)!
            .write(to: outside)
        try FileManager.default.createSymbolicLink(
            at: fixture.hooksDirectory.appendingPathComponent("escape.jsonl"),
            withDestinationURL: outside
        )

        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        #expect(read(auditing).map(\.executable) == ["inside"])
    }

    @Test("目录不存在或为空：零记录、不抛异常")
    func missingDirectoryIsQuiet() throws {
        let root = try Scratch.directory("hook-missing-dir")
        defer { try? FileManager.default.removeItem(at: root) }
        let auditing = HookCommandAuditing(storeDirectoryURL: root.appendingPathComponent("nope", isDirectory: true))
        #expect(read(auditing).isEmpty)
        #expect(auditing.stats.parsedLineCount == 0)
    }

    @Test("离线期间写的行仍然补采：`since` 不参与 hook 来源的过滤")
    func offlineLinesBackfilledRegardlessOfSince() throws {
        let fixture = try HookFixture(purpose: "backfill")
        try fixture.appendLines([
            hookLine(command: "old-but-unseen", startedAt: iso(t0.addingTimeInterval(-7200))),
        ])
        let auditing = HookCommandAuditing(storeDirectoryURL: fixture.storeDirectory)
        let records = auditing.inferCommands(
            processes: [],
            agents: [],
            since: Date().addingTimeInterval(-3)
        )
        #expect(records.map(\.executable) == ["old-but-unseen"])
    }

    @Test("hook 记录 id 由事件内容决定：同内容两次解析 id 相同")
    func recordIDIsDeterministicForIdenticalContent() throws {
        let fixtureA = try HookFixture(purpose: "stable-id-a")
        let fixtureB = try HookFixture(purpose: "stable-id-b")
        let line = hookLine(command: "echo same", startedAt: iso(t0), exitCode: 0)
        try fixtureA.appendLines([line])
        try fixtureB.appendLines([line])

        let first = try #require(read(HookCommandAuditing(storeDirectoryURL: fixtureA.storeDirectory)).first)
        let second = try #require(read(HookCommandAuditing(storeDirectoryURL: fixtureB.storeDirectory)).first)
        #expect(first.id == second.id)
    }
}
