//
//  CommandRecordRedactionTests.swift
//  Tests/AIObservatoryPlatformTests — Telemetry
//
//  Owner: ws-engaudit
//
//  §7「禁采凭据」的**生产者侧**证据：两条真实采集路径（进程轮询 KERN_PROCARGS2 的 argv、
//  Agent hook 的 JSONL）在把 argv 转成 `CommandRecord` 的那一刻就不带凭据原文。
//  这三件事各自都有用例钉着，缺一件都算没修：
//   1. 落库面干净：`arguments` / `commandLine` 里没有 `sk-TEST123`；
//   2. 审计面完整：命令名、参数个数、`Authorization` 头名与 scheme 都还在；
//   3. **检出不被削弱**：分级用的仍是原文——脱敏只削减留存，不削减判定。
//

import Foundation
import Testing
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryTestSupport

private let redactedBase = "‹redacted:openai_key›"

@Suite("命令记录生产侧：入库前就没有凭据")
struct CommandRecordRedactionTests {

    private static let base = Date(timeIntervalSinceReferenceDate: 800_000_900)

    private static func agent() -> AgentInstance {
        AgentInstance(
            kind: .claudeCode,
            pid: 5_100,
            displayName: "Claude Code",
            executablePath: "/usr/local/bin/claude",
            startedAt: base
        )
    }

    /// 采样侧：Agent 的孙子进程被轮询到的一次真实快照（`sh -c "<脚本>"` 的形态）。
    private static func sampledRecord(argv: [String], name: String = "bash") -> CommandRecord? {        let parent = ProcessRecord(pid: 5_100, parentPID: 1, name: "claude", arguments: [], startTime: base)
        let child = ProcessRecord(
            pid: 5_101, parentPID: 5_100, name: name, arguments: argv,
            startTime: base.addingTimeInterval(1)
        )
        let records = CommandInferenceEngine().inferCommands(
            processes: [parent, child], agents: [agent()], since: .distantPast
        )
        return records.first
    }

    // MARK: - 采样路径（KERN_PROCARGS2 → argv → 记录）

    @Test("轮询采到的 shell 脚本参数：key 不进记录，头名与命令名留在原位")
    func sampledShellScriptArgument() throws {
        let record = try #require(Self.sampledRecord(argv: [
            "sh", "-c", "curl -sS -H 'Authorization: Bearer sk-TEST123' http://127.0.0.1:9/ ; sleep 4",
        ]))
        #expect(record.arguments.count == 3, "参数个数是审计事实：一格都不许多、不许少")
        #expect(record.arguments[2]
                == "curl -sS -H 'Authorization: Bearer \(redactedBase)' http://127.0.0.1:9/ ; sleep 4")
        #expect(!record.commandLine.contains("sk-TEST123"))
        #expect(!record.arguments.joined(separator: " ").contains("sk-TEST123"))
        // 「仍要能看出跑过一条带 Authorization 头的 curl」——这三格就是那句话的可执行版本。
        #expect(record.executable == "bash")
        #expect(record.commandLine.contains("curl"))
        #expect(record.commandLine.contains("Authorization: Bearer"))
    }

    @Test("离散 argv：-H 与值分两格时只掩值那一格")
    func sampledDiscreteArguments() throws {
        let record = try #require(Self.sampledRecord(argv: [
            "curl", "-H", "Authorization: Bearer sk-TEST123", "http://127.0.0.1:9/",
        ], name: "curl"))
        #expect(record.arguments == ["curl", "-H", "Authorization: Bearer \(redactedBase)", "http://127.0.0.1:9/"])
    }

    @Test("脱敏对分级中立：掩掉的只是凭据值，判定一格不动")
    func detectionIsRedactionNeutral() throws {
        let raw = "chmod -R 777 ./junk # sk-TEST123"
        let record = try #require(Self.sampledRecord(argv: ["sh", "-c", raw]))
        let rules = DestructiveCommandRules()
        // 手推自 `DestructiveCommandRules` 的 `chmod-777-recursive` 那条：
        // 它标「要确认 + high」，**不**标 isDestructive（此前我猜成 destructive，是错的）。
        #expect(record.riskLevel == .high)
        #expect(record.requiresConfirmation)
        #expect(!record.isDestructive)
        // 这条才是「检出没被削弱」的可执行判据：原文与脱敏文过同一个分类器，逐字段相等。
        // 若哪天脱敏把命令名或 `-R 777` 一起掩掉，这里立刻红。
        #expect(rules.classify(command: raw)
                == rules.classify(command: CommandLineRedaction.redact(raw)))
        #expect(!record.commandLine.contains("sk-TEST123"))
    }

    // MARK: - hook 路径（JSONL → 记录 + 幂等键）

    private static func hookEvent(command: String) -> AgentHookEvent? {
        let line = #"{"agentKind":"claude-code","command":"\#(command)","startedAt":800000901}"#
        guard case .success(let event) = AgentHookEvent.parse(jsonLine: line) else { return nil }
        return event
    }

    @Test("hook 记录不带凭据原文，但自然键仍可幂等")
    func hookRecordIsRedacted() throws {
        let event = try #require(Self.hookEvent(
            command: "curl -H 'Authorization: Bearer sk-TEST123' http://127.0.0.1:9/"
        ))
        let record = event.commandRecord(
            agentID: nil,
            classification: DestructiveCommandRules().classify(command: event.command)
        )
        #expect(record.executable == "curl")
        #expect(!record.commandLine.contains("sk-TEST123"))
        #expect(record.commandLine.contains("Authorization"))
        // 自然键会长期留在 <数据目录>/agent-hooks/.offsets.json 里，同样不许带凭据。
        #expect(!event.eventKey.contains("sk-TEST123"))
        // 幂等性不能被脱敏破坏：同一行读两次必须是同一个 id。
        let again = try #require(Self.hookEvent(
            command: "curl -H 'Authorization: Bearer sk-TEST123' http://127.0.0.1:9/"
        ))
        #expect(again.recordID == event.recordID)
    }

    @Test("hook 侧分级仍看原文（字段本身不被改写）")
    func hookClassificationSeesRaw() throws {
        let event = try #require(Self.hookEvent(command: "chmod -R 777 ./junk"))
        let classification = DestructiveCommandRules().classify(command: event.command)
        #expect(classification.level == .high)
        #expect(classification.requiresConfirmation)
        #expect(event.command == "chmod -R 777 ./junk", "字段本身不改写：改的是转出去的那份记录")
    }

    // MARK: - 内存后端（三套 store 的基准侧）

    @Test("内存后端：按凭据搜不到、按结构搜得到")
    func memoryBackendHoldsNoPlaintext() async throws {
        let record = try #require(Self.sampledRecord(argv: [
            "sh", "-c", "curl -sS -H 'Authorization: Bearer sk-TEST123' http://127.0.0.1:9/ ; sleep 4",
        ]))
        let service = InMemoryObservatoryService()
        service.seed(commands: [record])

        let bySecret = try await service.commands(matching: CommandQuery(searchText: "sk-TEST123"))
        #expect(bySecret.items.isEmpty, "§7：库里查不到凭据")
        let byStructure = try await service.commands(matching: CommandQuery(searchText: "authorization"))
        #expect(byStructure.items.map(\.id) == [record.id], "审计事实要还能搜得着")
        let byCommand = try await service.commands(matching: CommandQuery(searchText: "curl"))
        #expect(byCommand.totalCount == 1)
    }
}
