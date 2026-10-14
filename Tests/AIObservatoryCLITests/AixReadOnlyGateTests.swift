//
//  AixReadOnlyGateTests.swift
//  AIObservatoryCLITests
//
//  Owner: ws/cli（#65 约束 1 的常驻化）
//  ─────────────────────────────────────────────────────────
//  #65 的第一条硬约束是「只读」：不开写事务、不跑采集、不改设置、不删数据、
//  绝不静默建库再输出"什么都没有"。此前它只有**我一次性跑的 sha256 实测**背书
//  （牌上 20:2x / 21:0x 两块），一次性实测挡不住后面有人往 `AixStore` 里加一行写。
//  这一族用例把它变成常驻门禁：七条命令各跑一次，**主库文件哈希与 user_version 都不许动**。
//
//  两道防空转的守卫（本仓最贵的那一类就是"绿着但其实没喂"）：
//  ① 每条命令必须**真的读到行**（退 0）——否则七条全退 2 时哈希自然不变，门禁就是假的；
//  ② 写完一行之后哈希**必须变**——不变说明这把尺子量不到写入，整族用例当场红。
//

import CryptoKit
import Foundation
import Testing
@testable import AIObservatoryCLI
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

/// 整个库状态的摘要：主库 + `-wal`（`-shm` 是易失索引，不算）。
///
/// ⚠️ 只哈希主库文件会**假绿**：变异探针往产品里插一条 `CREATE TABLE` 时门禁没红 ——
/// WAL 模式下写在 `-wal` 里，而 CLI 这条连接要到进程退出才关，checkpoint 还没发生。
/// 所以量"没写"必须把未合并的 WAL 一起算进来。空/不存在的 `-wal` 都算空片段，
/// 免得"跑完多出个 0 字节边车"被误判成写入。
private func digest(of path: String) throws -> String {
    var hash = SHA256()
    hash.update(data: try Data(contentsOf: URL(fileURLWithPath: path)))
    let wal = path + "-wal"
    if let walData = try? Data(contentsOf: URL(fileURLWithPath: wal)) {
        hash.update(data: walData)
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

/// 灌满每张表，好让七条命令**都有行可读**（没行可读的话这条门禁会在"什么都没发生"上常绿）。
private func seedEverything(_ store: ObservatoryStore) async throws {
    let agent = AixFixture.agent(pid: 4321, name: "codex")
    try await store.upsertAgents([agent])
    try await store.upsertSessions([AixFixture.session()])
    await store.append(TimelineEvent(timestamp: AixFixture.stamp(5), agentKind: .claudeCode,
                                     kind: .fileModified, title: "改了一个文件"))
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 2))
    await store.append(AixFixture.command("git status", agent: agent.id))
    try await store.recordRisks([AixFixture.risk(.critical, title: "凭据暴露", agent: agent.id)])
    await store.flush()
}

@Test("七条命令各跑一次：主库文件哈希与 user_version 逐字不变（约束 1 常驻门禁）")
func everyCommandLeavesTheDatabaseBytesUntouched() async throws {
    let directory = try Scratch.directory("cli-readonly-gate")
    let store = try await AixFixture.store(in: directory)
    try await seedEverything(store)
    await store.stop()          // stop() 会 checkpoint ⇒ 主库是稳定态，量的是它

    let path = AixFixture.databasePath(in: directory).path
    let commands: [[String]] = [
        ["agents"], ["sessions"], ["timeline"], ["files"], ["commands"], ["risk"], ["report"],
    ]
    #expect(commands.count == 7, "分母：七条命令得各跑一次")

    for arguments in commands {
        let before = try digest(of: path)
        let output = await Aix.run(arguments: arguments + ["--data-dir", directory.path])
        let after = try digest(of: path)
        // 守卫①：这条命令必须真读到行。全退 2 的话哈希当然不变，那是"没打开库"不是"只读"。
        #expect(output.exitCode == AixExitCode.ok.rawValue,
                "aix \(arguments[0]) 没读到行（exit \(output.exitCode)）⇒ 这一格在空跑：\(output.stderr)")
        #expect(before == after,
                "aix \(arguments[0]) 改动了主库字节：\(before) → \(after)")
    }

    let probe = try SQLiteDatabase(configuration: .file(path))
    let version = try await probe.userVersion()
    await probe.close()
    #expect(version == StoreSchema.schemaVersion, "跑完一轮库版本就不是 \(StoreSchema.schemaVersion) 了")
}

@Test("敏感性探针：往库里写一行，哈希**必须**变（不变=这把尺子量不到写入，门禁是假的）")
func digestInstrumentActuallyDetectsWrites() async throws {
    let directory = try Scratch.directory("cli-readonly-probe")
    let store = try await AixFixture.store(in: directory)
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 1))
    await store.flush()
    await store.stop()

    let path = AixFixture.databasePath(in: directory).path
    let quiet = try digest(of: path)
    // 先证"什么都不做"不动它：把 CLI 正常跑一遍。
    _ = await Aix.run(arguments: ["files", "--data-dir", directory.path])
    #expect(try digest(of: path) == quiet, "CLI 自己就把库改了 ⇒ 上面那族门禁的现场不成立")

    // 再证"真写一行"一定被量到。
    let writer = try await AixFixture.store(in: directory)
    await AixFixture.append(writer, AixFixture.unattributedChanges(count: 1, prefix: "written"))
    await writer.flush()
    await writer.stop()
    #expect(try digest(of: path) != quiet,
            "写了一行哈希却没变 ⇒ sha256 这把尺子失效，整套只读门禁都是空的")
}

@Test("库不存在时：七条命令都不许在目录里留下任何文件（连边车都不行）")
func noCommandCreatesAnythingWhenTheStoreIsAbsent() async throws {
    let directory = try Scratch.directory("cli-readonly-absent")
    for arguments in [["agents"], ["sessions"], ["timeline"], ["files"], ["commands"], ["risk"], ["report"]] {
        _ = await Aix.run(arguments: arguments + ["--data-dir", directory.path])
    }
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(leftovers.isEmpty, "跑完凭空建出了 \(leftovers) ⇒ 违反「不静默建库」这条约束")
}
