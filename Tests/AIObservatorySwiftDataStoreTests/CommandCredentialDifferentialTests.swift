//
//  CommandCredentialDifferentialTests.swift
//  Tests/AIObservatorySwiftDataStoreTests
//
//  Owner: ws-engaudit
//
//  §7 的**后端可切换**那一半：同一批命令记录写进 SQLite 与 SwiftData，两边读回来的
//  `arguments` 必须逐元素相等、两边都查不到凭据原文。
//
//  口径说明（不是正确性证据的部分写清楚）：「两后端相等」只证明可切换；
//  「值本身没有凭据」才是 §7 的判据。因此本文件两条都断，且各自单独会红。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
@testable import AIObservatorySwiftDataStore

private let marker = "‹redacted:openai_key›"
private let secret = "sk-TEST123"

private enum CredentialDiff {
    static let base = Date(timeIntervalSince1970: 1_700_001_200)
    static let agent = UUID()
    static let session = UUID()

    /// 生产侧（`CommandLineRedaction`）实际会产出的那一格。
    static let redactedScript = "curl -sS -H 'Authorization: Bearer \(marker)' http://127.0.0.1:9/"

    static var command: CommandRecord {
        CommandRecord(executable: "bash", arguments: ["sh", "-c", redactedScript],
                      agentID: agent, sessionID: session, agentKind: .claudeCode,
                      startedAt: base, outcome: .running, riskLevel: .high)
    }

    /// 对照组：跳过生产侧、直接 seed 原文。两侧都必须查得到它，否则这条尺子抓不住回归。
    static var rawCommand: CommandRecord {
        CommandRecord(executable: "bash", arguments: ["sh", "-c", "curl -H 'Authorization: Bearer \(secret)' http://h/"],
                      agentID: agent, sessionID: session, agentKind: .claudeCode,
                      startedAt: base.addingTimeInterval(1), outcome: .running, riskLevel: .high)
    }
}

@Suite("凭据脱敏：SQLite 与 SwiftData 两后端一致")
struct CommandCredentialDifferentialTests {

    private func pair() async throws -> (ObservatoryStore, SwiftDataObservatoryStore) {
        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        return (sqlite, swiftData)
    }

    @Test("脱敏后的记录：两后端读回的 arguments 逐元素相等，且都不含凭据")
    func redactedRecordMatchesAcrossBackends() async throws {
        let (sqlite, swiftData) = try await pair()
        await sqlite.append(CredentialDiff.command)
        await swiftData.append(CredentialDiff.command)
        await sqlite.flush()
        await swiftData.flush()

        let fromSQLite = (try await sqlite.commands(matching: .all)).items
        let fromSwiftData = (try await swiftData.commands(matching: .all)).items
        #expect(fromSQLite.count == 1 && fromSwiftData.count == 1, "两侧各落一行")
        let sqliteArguments = try #require(fromSQLite.first?.arguments)
        let swiftArguments = try #require(fromSwiftData.first?.arguments)
        #expect(sqliteArguments == swiftArguments, "两后端逐元素相等（这只证明可切换）")
        #expect(sqliteArguments == ["sh", "-c", CredentialDiff.redactedScript], "值本身必须是手推的那串")
        #expect(!sqliteArguments.joined(separator: " ").contains(secret), "SQLite 侧没有凭据")
        #expect(!swiftArguments.joined(separator: " ").contains(secret), "SwiftData 侧没有凭据")
        // 两侧都仍按结构可搜（脱敏没把审计事实删掉）。
        #expect((try await sqlite.commands(matching: CommandQuery(searchText: "authorization"))).totalCount == 1)
        #expect((try await swiftData.commands(matching: CommandQuery(searchText: "authorization"))).totalCount == 1)
    }

    @Test("对照组：绕过生产侧直接 seed 原文，两侧都留得下（尺子有牙）")
    func rawRecordPersistsOnBothBackends() async throws {
        let (sqlite, swiftData) = try await pair()
        await sqlite.append(CredentialDiff.rawCommand)
        await swiftData.append(CredentialDiff.rawCommand)
        await sqlite.flush()
        await swiftData.flush()

        let sqliteArguments = try #require((try await sqlite.commands(matching: .all)).items.first?.arguments)
        let swiftArguments = try #require((try await swiftData.commands(matching: .all)).items.first?.arguments)
        #expect(sqliteArguments.joined(separator: " ").contains(secret),
                "Store 不做二次清洗：干净只可能来自入库之前，这一条把话说死")
        #expect(swiftArguments.joined(separator: " ").contains(secret))
    }
}
