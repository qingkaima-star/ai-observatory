//
//  CommandCredentialPersistenceTests.swift
//  AIObservatoryEngineTests
//
//  Owner: ws-engaudit
//
//  凭据**落库面**的绝对真值（AGENTS §7）。同一份命令行文本在本仓有 5 个持久化落点
//  （`commands` 的 3 列、`events` 的 4 列、`risk_events` 的 4 列，加上 hook 偏移文件），
//  所以「arguments_json 干净」这一条不构成修完——本文件把 11 个落点一次查穿。
//
//  两条断言成对写：
//   · **红的那条**（rawControl）：直接 seed 带原文的记录，探针必须查得到 ⇒ 证明尺子有牙，
//     Store 层不会「顺手」替谁洗数据（真要洗，也不该在这里悄悄洗）。
//   · **绿的那条**：seed 生产侧（`CommandLineRedaction`）实际产出的那种记录，11 列全查不到。
//     生产侧怎么产出那个形状，由 `Tests/AIObservatoryPlatformTests/Telemetry/
//     CommandRecordRedactionTests.swift` 钉住；这里钉的是「那个形状落库之后仍然干净」。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryEngine
import AIObservatoryExport

private let secret = "sk-TEST123"
private let marker = "‹redacted:openai_key›"

/// 生产侧脱敏后的那一格 argv（与 `CommandLineRedaction.redact` 的实际产出逐字一致，
/// 那条一致性由 Platform 侧的用例钉着）。
private let redactedScript = "curl -sS -H 'Authorization: Bearer \(marker)' http://127.0.0.1:9/"
private let rawScript = "curl -sS -H 'Authorization: Bearer \(secret)' http://127.0.0.1:9/"

private enum CredentialFixture {
    static let base = Date(timeIntervalSince1970: 1_700_000_900)
    static let agent = UUID()
    static let session = UUID()

    static func command(arguments: [String]) -> CommandRecord {
        CommandRecord(executable: "bash", arguments: arguments, agentID: agent, sessionID: session,
                      agentKind: .claudeCode, startedAt: base, outcome: .running, riskLevel: .high)
    }

    static var redacted: CommandRecord { command(arguments: ["sh", "-c", redactedScript]) }
    static var raw: CommandRecord { command(arguments: ["sh", "-c", rawScript]) }
}

/// 11 个持久化落点：一条 SQL 查穿（列名逐条写死，新增列时这条会因表结构变化而被注意到）。
private let credentialProbeSQL = """
SELECT
  (SELECT COUNT(*) FROM commands   WHERE arguments_json LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM commands   WHERE search_text      LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM commands   WHERE executable       LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM events     WHERE title            LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM events     WHERE summary          LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM events     WHERE command          LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM events     WHERE search_text      LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM risk_events WHERE detail          LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM risk_events WHERE title           LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM risk_events WHERE command         LIKE '%sk-TEST123%') +
  (SELECT COUNT(*) FROM risk_events WHERE search_text     LIKE '%sk-TEST123%') AS hits
"""

@Suite("凭据落库面：11 个持久化落点一次查穿", .timeLimit(.minutes(1)))
struct CommandCredentialPersistenceTests {

    private func hits(_ store: ObservatoryStore) async throws -> Int {
        let database = await store.database
        let row = try #require(try await database.optionalRow(credentialProbeSQL))
        return try #require(row.int("hits"))
    }

    @Test("红的那条：原文入库时探针必须查得到（尺子有牙）")
    func rawControlIsDetected() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        await store.append(CredentialFixture.raw)
        await store.flush()
        #expect(try await hits(store) == 2, "原文会同时进 commands.arguments_json 与 commands.search_text（executable 是 bash，不算）")
    }

    @Test("绿的那条：生产侧产出的记录落库后 11 列全干净，但审计事实还在")
    func redactedRecordPersistsCleanly() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let record = CredentialFixture.redacted
        await store.append(record)
        await store.append(TimelineAggregator().event(for: record))
        try await store.recordRisks([
            RiskEvent(timestamp: CredentialFixture.base, level: .high, category: .dangerousCommand,
                      title: "带凭据的外部请求", detail: redactedScript, agentKind: .claudeCode,
                      sessionID: CredentialFixture.session, command: record.commandLine),
        ])
        await store.flush()

        #expect(try await hits(store) == 0, "§7：库里一个字符都不该有")
        // 干净不等于消失：这三格是「仍能看出跑过一条带 Authorization 头的 curl」的字面证据。
        let stored = try await store.commands(matching: .all)
        let restored = try #require(stored.items.first)
        #expect(restored.arguments == ["sh", "-c", redactedScript], "参数个数与位置逐项保持")
        #expect(restored.commandLine.contains("Authorization: Bearer"))
        #expect(restored.commandLine.contains("curl"))
        #expect((try await store.commands(matching: CommandQuery(searchText: "authorization"))).totalCount == 1,
                "按结构还能搜着——脱敏不是删数据")
        #expect((try await store.commands(matching: CommandQuery(searchText: secret))).items.isEmpty)
    }

    @Test("导出侧不再有第二道防线兜底：关掉导出脱敏也拿不到凭据")
    func exportRedactionToggleIsNoLongerLoadBearing() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        await store.append(CredentialFixture.redacted)
        await store.flush()
        let restored = try #require((try await store.commands(matching: .all)).items.first)
        // 导出层的 `redactionEnabled` 可以被用户关掉；关掉之后导出内容 == 库内容。
        // 因此「库干净」是唯一一道防线，这条断言把它说明白。
        let passthrough = ExportRedactor.disabled
        #expect(passthrough.redact(restored.commandLine) == restored.commandLine)
        #expect(!restored.commandLine.contains(secret))
    }
}
