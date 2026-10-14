//
//  AixCLITests.swift
//  AIObservatoryCLITests
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  验收硬要求的三条都在这里：
//  ① 已知内容的临时库 ⇒ `aix files --json` 的行数 == 库里 `agent_id IS NULL` 的行数；
//  ② 反向：把过滤改成「多一行」这一族断言必须红（`unattributedIsStrictSubsetOfAll` + 手工变异记录见牌）；
//  ③ 无库 ⇒ 退 2，**且跑完那个目录里没有被建出的库文件**。
//  外加「不许另写一套口径」的两条复用证明（JSON envelope、Markdown 报告逐字节等于导出层）。
//

import Foundation
import Testing
@testable import AIObservatoryCLI
import AIObservatoryCore
import AIObservatoryExport
import AIObservatoryStore
import AIObservatoryTestSupport
@testable import AIObservatoryApp  // 裁定 ①：测试 target 依赖 executable target（AIObservatoryAppTests 已有先例）

// MARK: - ① 等价：CLI 行数 == 库里 agent_id IS NULL 行数

@Test("aix files --unattributed --json 的行数 == 库里 agent_id IS NULL 的行数")
func unattributedJSONRowsEqualAgentIDNullCount() async throws {
    let directory = try Scratch.directory("cli-equiv")
    let store = try await AixFixture.store(in: directory)
    let agent = UUID()
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 7))
    await AixFixture.append(store, AixFixture.attributedChanges(count: 5, agent: agent))
    await store.flush()

    // 期望值**独立算**：不带任何过滤把全表捞出来，自己数 `agentID == nil`。
    // 不拿 CLI 的返回值当期望值 —— 那样它就只是在跟自己比（#20 那一族的假绿）。
    let all = try await store.fileChanges(matching: FileChangeQuery(limit: 500))
    let expectedNullAgent = all.items.filter { $0.agentID == nil }.count
    #expect(expectedNullAgent == 7, "夹具本身要先立住：灌进去 7 条未归属、5 条已归属")

    let output = await Aix.run(arguments: ["files", "--unattributed", "--json", "--data-dir", directory.path])
    #expect(output.exitCode == AixExitCode.ok.rawValue)
    #expect(try AixFixture.items(output.stdout).count == expectedNullAgent)

    // 反向的一半：不带 --unattributed 必须拿到全表条数。
    // 「多一行 / 少一行」在这里当场红 —— 过滤条件写歪一格，两条形不成 12 与 7 的同时成立。
    let everything = await Aix.run(arguments: ["files", "--json", "--data-dir", directory.path])
    #expect(try AixFixture.items(everything.stdout).count == all.items.count)
    #expect(try AixFixture.items(everything.stdout).count != AixFixture.items(output.stdout).count,
            "两个命令给出同一个行数 ⇒ --unattributed 是个摆设")
    await store.stop()
}

@Test("未归属的过滤口径是 agent_kind='unknown'，不是 agent_id IS NULL —— 两者靠引擎写入约定才等值")
func unattributedFilterIsKindBasedNotNullBased() async throws {
    let directory = try Scratch.directory("cli-conv")
    let store = try await AixFixture.store(in: directory)
    // 引擎**从不**写这种组合（agent_id 为空但 kind 不是 unknown）。真实库实测交叉项 = 0 行。
    await store.append(FileChange(path: "/repo/odd.txt", kind: .modified,
                                  timestamp: AixFixture.stamp(1), agentID: nil, agentKind: .claudeCode))
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 2))
    await store.flush()

    let rows: Int
    let output = await Aix.run(arguments: ["files", "--unattributed", "--json", "--data-dir", directory.path])
    rows = try AixFixture.items(output.stdout).count
    // CLI 报 2（按 kind），而 `agent_id IS NULL` 有 3。这一格把「为什么等价用例只在按约定写入时成立」钉住：
    // 它是**约定等值**，不是 DB 约束。哪天引擎改约定，这条先红。
    #expect(rows == 2)
    #expect(try await store.fileChanges(matching: FileChangeQuery(limit: 10)).items
            .filter { $0.agentID == nil }.count == 3)
    await store.stop()
}

// MARK: - ③ 无库 / 前置条件

@Test("没有库 ⇒ 退 2，且目录里不会被建出库文件（绝不静默造空库再输出「什么都没有」）")
func missingStoreExitsTwoAndCreatesNothing() async throws {
    let directory = try Scratch.directory("cli-nostore")
    for arguments in [["files"], ["files", "--json"], ["agents"], ["report"]] {
        let output = await Aix.run(arguments: arguments + ["--data-dir", directory.path])
        #expect(output.exitCode == AixExitCode.preconditionFailed.rawValue, "\(arguments) 必须退 2")
        #expect(output.stdout.isEmpty, "拿不到库时 stdout 必须一个字都不出（出了就是假数据）")
        #expect(output.stderr.contains("不会创建数据库"))
    }
    #expect(!FileManager.default.fileExists(atPath: AixFixture.databasePath(in: directory).path),
            "只读工具跑一次之后不该在目录里留下库文件")
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty,
            "连边车文件都不该建")
}

@Test("库版本落后 ⇒ 退 2，并且 user_version 保持原值（证明没有代 AiX 迁移）")
func refusesToMigrateAnOlderSchema() async throws {
    let directory = try Scratch.directory("cli-version")
    let store = try await AixFixture.store(in: directory)
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 3))
    await store.flush()
    await store.stop()

    // 人为把库降回 3，模拟「旧版 AiX 留下的库」。
    let probe = try SQLiteDatabase(configuration: .file(AixFixture.databasePath(in: directory).path))
    try await probe.run("PRAGMA user_version = 3")
    #expect(try await probe.userVersion() == 3)
    await probe.close()

    let output = await Aix.run(arguments: ["files", "--data-dir", directory.path])
    #expect(output.exitCode == AixExitCode.preconditionFailed.rawValue)
    #expect(output.stderr.contains("拒绝打开"))
    #expect(output.stdout.isEmpty)

    let after = try SQLiteDatabase(configuration: .file(AixFixture.databasePath(in: directory).path))
    #expect(try await after.userVersion() == 3, "跑一次 CLI 就把用户的库迁到 4 ⇒ 这就是「只读工具偷偷写库」")
    await after.close()
}

@Test("参数错一律退 2，并把可用参数带回来")
func usageErrorsExitTwo() async {
    let cases: [([String], String)] = [
        (["--level", "high"], "子命令必须出现在选项之前"),
        (["nope"], "未知子命令"),
        (["risk", "--level", "urgent"], "--level 取 low|medium|high|critical"),
        (["sessions", "--unattributed"], "只对 files 有效"),
        (["files", "--limit", "0"], "正整数"),
        (["files", "--since", "去年三月"], "--since 要 ISO 8601"),
        (["files", "--nope"], "未知选项"),
    ]
    for (arguments, reason) in cases {
        let output = await Aix.run(arguments: arguments)
        #expect(output.exitCode == AixExitCode.preconditionFailed.rawValue, "\(arguments) 应退 2")
        #expect(output.stderr.contains(reason), "\(arguments) 应报「\(reason)」，实得：\(output.stderr)")
    }
}

// MARK: - 约束 3：空 / 未知 / 无库 / 查无结果 四态互不相同

@Test("四种「没有东西可看」的输出互不相同")
func fourEmptyStatesAreTextuallyDistinct() async throws {
    // ① 空表：库在、表 0 行。
    let emptyDir = try Scratch.directory("cli-empty-table")
    let emptyStore = try await AixFixture.store(in: emptyDir)
    await emptyStore.flush()
    await emptyStore.stop()
    let empty = await Aix.run(arguments: ["files", "--data-dir", emptyDir.path])
    #expect(empty.exitCode == AixExitCode.noRows.rawValue)
    #expect(empty.stdout.contains("一行都没有"))

    // ② 查无结果：表有行，条件筛空。
    let filledDir = try Scratch.directory("cli-no-match")
    let filled = try await AixFixture.store(in: filledDir)
    await AixFixture.append(filled, AixFixture.attributedChanges(count: 4, agent: UUID()))
    await filled.flush()
    await filled.stop()
    let noMatch = await Aix.run(arguments: ["files", "--unattributed", "--data-dir", filledDir.path])
    #expect(noMatch.exitCode == AixExitCode.noRows.rawValue)
    #expect(noMatch.stdout.contains("查无结果"))
    #expect(noMatch.stdout.contains("不是「没有数据」"))

    // ③ 无库（另一条用例已覆盖）：文案与上面两者都不同。
    let noneDir = try Scratch.directory("cli-none")
    let noStore = await Aix.run(arguments: ["files", "--data-dir", noneDir.path])

    // ④ 字段拿不到：有行，但「机制分布」这一格 Store 侧给不出。
    let unattributedDir = try Scratch.directory("cli-unavailable")
    let unattributedStore = try await AixFixture.store(in: unattributedDir)
    await AixFixture.append(unattributedStore, AixFixture.unattributedChanges(count: 2))
    await unattributedStore.flush()
    await unattributedStore.stop()
    let unavailable = await Aix.run(
        arguments: ["files", "--unattributed", "--data-dir", unattributedDir.path]
    )
    #expect(unavailable.exitCode == AixExitCode.ok.rawValue)
    #expect(unavailable.stdout.contains("未知不等于 0"))

    let phrases = [empty.stdout, noMatch.stdout, noStore.stderr, unavailable.stdout]
    #expect(Set(phrases).count == 4, "四种状态的字面输出必须两两不同，实得：\(phrases)")

    // 机器可读侧同理：stderr 的 token 各不相同。
    let tokens = [
        await Aix.run(arguments: ["files", "--json", "--data-dir", emptyDir.path]).stderr,
        await Aix.run(arguments: ["files", "--unattributed", "--json", "--data-dir", filledDir.path]).stderr,
        await Aix.run(arguments: ["files", "--json", "--data-dir", noneDir.path]).stderr,
    ]
    #expect(Set(tokens).count == 3)
    #expect(tokens[0].contains("status=empty-table") && tokens[1].contains("status=no-match")
            && tokens[2].contains("AIX_NO_DATABASE_FILE"))
}

@Test("--unattributed 必须自报「机制分布拿不到」，而不是留白")
func unattributedReportsMechanismAsUnavailable() async throws {
    let directory = try Scratch.directory("cli-mechanism")
    let store = try await AixFixture.store(in: directory)
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 3))
    await store.flush()
    await store.stop()

    let output = await Aix.run(arguments: ["files", "--unattributed", "--data-dir", directory.path])
    #expect(output.stdout.contains("机制分布"))
    // 拿不到的原因：四个分支在入库前判、只活在引擎进程内存里，file_changes 没有对应列。
    let json = await Aix.run(arguments: ["files", "--unattributed", "--json", "--data-dir", directory.path])
    #expect(json.stderr.contains("status=unavailable field=attribution-mechanism"))
}

// MARK: - 约束 2：不许另写一套口径（复用证明）

@Test("--json 的 envelope 是导出层那份 —— **只管五类记录**（agents 例外，见下面两条）")
func jsonEnvelopeIsTheExportLayers() async throws {
    let directory = try Scratch.directory("cli-envelope")
    let store = try await AixFixture.store(in: directory)
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 2))
    await store.flush()
    await store.stop()

    let output = await Aix.run(arguments: ["files", "--json", "--data-dir", directory.path])
    let document = try AixFixture.document(output.stdout)
    // `JSONExporter` 的六个固定键（文档注释写死了这个键序）。
    #expect(Set(document.keys).isSuperset(of: ["schemaVersion", "generatedAt", "exportedBy", "kind", "counts", "items"]))
    // 期望值是我第一版写错的：`ExportKind.fileChanges` 的 rawValue 是 camelCase 的 "fileChanges"，
    // 不是连字符的 "file-changes"。这一格把**真实**写法钉住，顺便记下两本账的拼写确实不同：
    // 导出层 kind = `fileChanges`，DB 表名 = `file_changes`（人读输出用后者，因为那是"有没有行"的账本）。
    #expect(document["kind"] as? String == "fileChanges", "实得 \(String(describing: document["kind"]))")
    // 上一版这里写的是 `A || B`，两边都可能偶然成立 ⇒ 等于没断。改成零行那格的实锚点。
    let emptyDir = try Scratch.directory("cli-envelope-empty")
    let emptyStore = try await AixFixture.store(in: emptyDir)
    await emptyStore.flush()
    await emptyStore.stop()
    let emptyTable = await Aix.run(arguments: ["files", "--data-dir", emptyDir.path])
    #expect(emptyTable.stdout.contains("表 file_changes 一行都没有"),
            "人读输出用 **DB 表名**（file_changes），实得：\(emptyTable.stdout)")
}

/// 总控 22:2x 驳回我上一版的那一半：用例名字声称"所有 `--json` 都是导出层那份"，
/// 而它只喂了 `files` 一类 ⇒ **名字比证据宽**，正是本仓最贵的那一类（看起来对、其实没喂）。
/// 这一条把声称的范围真喂满：五类记录**逐类**拿 CLI 字节与 `JSONExporter` 字节逐字比。
@Test("五类记录的 --json 与 JSONExporter 逐字节相同（键集/计数/命名一起被钉住，不是抽两个键看看）")
func allFiveRecordKindsMatchJSONExporterByteForByte() async throws {
    let directory = try Scratch.directory("cli-envelope-five")
    let store = try await AixFixture.store(in: directory)
    let agent = UUID()
    try await store.upsertSessions([AixFixture.session()])
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 1))
    try await store.recordRisks([AixFixture.risk(.high, title: "批量删除", agent: agent)])
    await store.append(AixFixture.command("rm -rf /tmp/whatever", agent: agent))
    await store.append(TimelineEvent(timestamp: AixFixture.stamp(3), agentKind: .claudeCode,
                                     kind: .fileModified, title: "改了一个文件"))
    await store.flush()

    // (命令, 导出层 kind) 一一列表；少喂一类就红 —— 分母同时写进断言。
    let pairs: [(command: String, kind: ExportKind)] = [
        ("sessions", .sessions), ("timeline", .timeline), ("files", .fileChanges),
        ("commands", .commands), ("risk", .riskEvents),
    ]
    #expect(pairs.count == 5)
    for (command, kind) in pairs {
        let request = AixRequest(command: AixRequest.Command(rawValue: command)!,
                                 json: true, dataDir: directory.path)
        let output = await Aix.run(arguments: [command, "--json", "--data-dir", directory.path],
                                   now: AixFixture.stamp(0))
        let fetched = try await AixQuery.run(request, service: store)
        guard case .rows(let fetchedKind, let records, _, _) = fetched else {
            Issue.record("\(command) 应返回 rows 形状 ⇒ 这条对拍是空跑")
            continue
        }
        #expect(fetchedKind == kind, "\(command) 取到了别的 kind ⇒ 同样是在空跑")
        let opened = AixStore.Opened(service: store, databasePath: directory.path,
                                     uncheckpointedWALBytes: nil)
        let expected = try JSONExporter.data(records: records, kind: kind,
                                            request: Aix.exportRequest(for: request, kind: kind,
                                                                       opened: opened,
                                                                       now: AixFixture.stamp(0)),
                                            redactor: .standard)
        let expectedText = String(decoding: expected, as: UTF8.self) + "\n"
        #expect(output.stdout == expectedText,
                "\(command) 的 --json 与导出层不一致（CLI \(output.stdout.count) 字 vs 导出层 \(expectedText.count) 字）")
    }
    await store.stop()
}

@Test("agents 的 JSON 是 CLI 自有 v1：**生产者字段必须与导出层不同**，谁也不能把它当成导出层那份")
func agentsEnvelopeDeclaresItselfAsNotTheExportLayer() async throws {
    let directory = try Scratch.directory("cli-agents-v1")
    let store = try await AixFixture.store(in: directory)
    try await store.upsertAgents([AixFixture.agent(pid: 77, name: "codex")])
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 1))
    await store.flush()
    await store.stop()

    let agents = try AixFixture.document(
        (await Aix.run(arguments: ["agents", "--json", "--data-dir", directory.path])).stdout)
    let files = try AixFixture.document(
        (await Aix.run(arguments: ["files", "--json", "--data-dir", directory.path])).stdout)
    // 导出层那份的 exportedBy 由 `ExportConstants` 定；CLI 自己那份必须写自己的名字。
    // ⇒ 两份文档从字段上就分得开，消费方不会把 agents 误当成导出层产物（上一版用例名就是被这么误读的）。
    #expect(agents["exportedBy"] as? String != files["exportedBy"] as? String,
            "两份文档 exportedBy 相同 ⇒ agents 那份会被误认成导出层产物")
    #expect(agents["schemaVersion"] as? Int == Aix.agentsSchemaVersion)
    #expect(agents["kind"] as? String == "agents")
}

@Test("aix report --format md 的正文与直接调 MarkdownReportExporter 逐字节相同")
func reportMarkdownBytesEqualExporter() async throws {
    let directory = try Scratch.directory("cli-report")
    let store = try await AixFixture.store(in: directory)
    let agent = UUID()
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 3))
    await AixFixture.append(store, AixFixture.attributedChanges(count: 2, agent: agent))
    try await store.upsertSessions([AixFixture.session()])
    try await store.upsertAgents([AixFixture.agent(pid: 4242, name: "codex")])
    try await store.recordRisks([AixFixture.risk(.high, title: "批量删除", agent: agent)])
    await store.flush()
    await store.stop()

    let now = AixFixture.stamp(0)
    let output = await Aix.run(arguments: ["report", "--data-dir", directory.path], now: now)
    #expect(output.exitCode == AixExitCode.ok.rawValue)
    #expect(output.stdout.hasPrefix("# AI Agent 活动审计报告"))

    // 直接按导出层的入口再算一遍同样的输入：字节必须相同，否则 CLI 就是另写了一套口径。
    let reopened = try await AixFixture.store(in: directory)
    let request = AixRequest(command: .report, dataDir: directory.path)
    let records = try await AixQuery.reportRecords(request, service: reopened, now: now,
                                                   databasePath: AixFixture.databasePath(in: directory).path)
    let expected = try MarkdownReportExporter.report(
        input: MarkdownReportExporter.Input(records: records,
                                            projects: try await reopened.projects(),
                                            generatedAt: now),
        // 与 CLI 同一道脱敏：凭据脱敏默认开 ⇒ 这里必须是 .standard。
        // （这一格第一版用 .disabled 算 expected，红了 —— 错的是期望值，不是正文。）
        redactor: .standard
    )
    await reopened.stop()
    #expect(output.stdout == expected, "报告正文与导出层不一致 ⇒ CLI 里长出了第二套口径")
}

// MARK: - 其余命令面

@Test("risk --level 只按该等级过滤，不做「及以上」的臆造")
func riskLevelFilterIsExact() async throws {
    let directory = try Scratch.directory("cli-risk")
    let store = try await AixFixture.store(in: directory)
    try await store.recordRisks([
        AixFixture.risk(.low, title: "低"), AixFixture.risk(.medium, title: "中"),
        AixFixture.risk(.high, title: "高"), AixFixture.risk(.critical, title: "严重"),
    ])
    await store.flush()
    await store.stop()

    let high = await Aix.run(arguments: ["risk", "--level", "high", "--json", "--data-dir", directory.path])
    #expect(try AixFixture.items(high.stdout).count == 1)
    let critical = await Aix.run(arguments: ["risk", "--level", "critical", "--json", "--data-dir", directory.path])
    #expect(try AixFixture.items(critical.stdout).count == 1)
    #expect(critical.exitCode == AixExitCode.ok.rawValue)
}

@Test("agents 走 activeAgents()：terminated 不出现，且没有全量查询时不许写成「库里没有 Agent」")
func agentsListsOnlyActiveAndSaysSo() async throws {
    let directory = try Scratch.directory("cli-agents")
    let store = try await AixFixture.store(in: directory)
    try await store.upsertAgents([
        AixFixture.agent(pid: 1, name: "alive"),
        AixFixture.agent(pid: 2, name: "gone", state: .terminated),
    ])
    await store.flush()
    await store.stop()

    let table = await Aix.run(arguments: ["agents", "--data-dir", directory.path])
    #expect(table.stdout.contains("alive"))
    #expect(!table.stdout.contains("gone"))
    // 零活跃时：Store 没有不带过滤的 Agent 查询 ⇒ 只能说「活跃 0 个」，总行数那一格是「拿不到」。
    let emptyDir = try Scratch.directory("cli-agents-empty")
    let empty = try await AixFixture.store(in: emptyDir)
    await empty.flush()
    await empty.stop()
    let zero = await Aix.run(arguments: ["agents", "--data-dir", emptyDir.path])
    #expect(zero.exitCode == AixExitCode.noRows.rawValue)
    #expect(zero.stdout.contains("拿不到"))
    #expect(!zero.stdout.contains("库里没有"))
    // agents 是**唯一**不走导出层的命令：`ExportKind` 没有 agents 这一类（五类记录 + report），
    // 所以这一份 envelope 是 **CLI 自有 schema v1**，不冒称导出层那份（总控 20:0x 点名过这条差异）。
    // 钉两件事：① 它自己声明 kind=agents 且 schemaVersion 是 CLI 的 1；② 字段名不许与领域模型漂开。
    // 页脚必须自带口径：只写「1 行」的话，拿不到 --help 的 AI 会把"活跃 1 个"读成
    // "这台机器只有 1 个 Agent"（真库实测活跃 1 / 历史 24）。这条钉的是**告知**，
    // 行为一个字没动 —— 改回裸行数就红。
    let footerLine = table.stdout.split(separator: "\n").last.map(String.init) ?? ""
    #expect(footerLine.contains("1 行（活跃；历史见 sessions）"),
            "agents 页脚得自带口径，实得：\(footerLine)")
    #expect(!footerLine.hasPrefix("1 行 ｜"), "页脚退化成裸行数 ⇒ 又是「看起来对、其实会读错」的形状")
    let json = await Aix.run(arguments: ["agents", "--json", "--data-dir", directory.path])
    let document = try AixFixture.document(json.stdout)
    #expect(document["kind"] as? String == "agents")
    #expect(document["schemaVersion"] as? Int == Aix.agentsSchemaVersion,
            "CLI 自有 schema 的版本号变了，消费方要跟着改")
    #expect(try AixFixture.items(json.stdout).count == 1)
    let first = try #require(try AixFixture.items(json.stdout).first as? [String: Any])
    // 字段集现取：编码一份真的 AgentInstance，拿它自己的 Codable 键当尺子（不手抄清单）。
    let encoded = try JSONEncoder().encode(AixFixture.agent(pid: 9, name: "probe"))
    let modelKeys = Set(((try JSONSerialization.jsonObject(with: encoded)) as? [String: Any] ?? [:]).keys)
    #expect(!modelKeys.isEmpty, "取不到模型字段集 ⇒ 这条对拍是空跑")
    #expect(Set(first.keys).isSubset(of: modelKeys),
            "agents 的 JSON 字段必须是 AgentInstance 原生 Codable 的子集，多出：\\(Set(first.keys).subtracting(modelKeys))")
}

@Test("--limit 截断必须说出来；--all 收全量")
func truncationIsDisclosed() async throws {
    let directory = try Scratch.directory("cli-limit")
    let store = try await AixFixture.store(in: directory)
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 12))
    await store.flush()
    await store.stop()

    let limited = await Aix.run(arguments: ["files", "--unattributed", "--limit", "5", "--data-dir", directory.path])
    #expect(limited.stdout.contains("5 行"))
    #expect(limited.stdout.contains("过滤后共 12 行，已截断 7 行"))
    let all = await Aix.run(arguments: ["files", "--unattributed", "--all", "--json", "--data-dir", directory.path])
    #expect(try AixFixture.items(all.stdout).count == 12)
}

@Test("凭据脱敏**默认开**：不传任何 flag 时 sk-…/Authorization: 必须从输出里消失")
func credentialsAreRedactedByDefault() async throws {
    // ICR-0012 总控裁定 20:0x 把提案的默认值反过来了：CLI 的输出会被整段贴进模型上下文，
    // "默认不脱敏"在这条路径上是数据外泄默认值，不是中性值。这一条就是那个默认值的正向钉。
    let directory = try Scratch.directory("cli-redact-on")
    let store = try await AixFixture.store(in: directory)
    await store.append(AixFixture.command(
        "curl -H 'Authorization: Bearer sk-abcdefghijklmnopqrstuvwxyz123456' https://example.invalid"))
    await store.flush()
    await store.stop()

    let plain = await Aix.run(arguments: ["commands", "--json", "--data-dir", directory.path])
    #expect(!plain.stdout.contains("sk-abcdefghijklmnopqrstuvwxyz123456"),
            "凭据原文出现在默认输出里 ⇒ 默认值又偷偷变回关了")
    #expect(!plain.stdout.contains("Bearer sk-"), "Authorization 头整段也算凭据")
    #expect(!plain.stdout.contains("--no-redact"), "默认路径不该念关闭提示")
    // 关掉脱敏不影响行数与退出码：只改凭据那一处，不改变"查到几行"。
    let off = await Aix.run(arguments: ["commands", "--json", "--no-redact", "--data-dir", directory.path])
    #expect(off.exitCode == plain.exitCode)
}

@Test("`--no-redact` 时凭据出现 **且** 那行可审计提示必须出现（反向钉，防默认值悄悄漂回去）")
func noRedactShowsSecretAndAuditLine() async throws {
    let directory = try Scratch.directory("cli-redact-off")
    let store = try await AixFixture.store(in: directory)
    await store.append(AixFixture.command("aws configure set aws_access_key_id AKIAIOSFODNN7EXAMPLE"))
    await store.flush()
    await store.stop()

    let on = await Aix.run(arguments: ["commands", "--json", "--data-dir", directory.path])
    #expect(!on.stdout.contains("AKIAIOSFODNN7EXAMPLE"))
    let off = await Aix.run(arguments: ["commands", "--json", "--no-redact", "--data-dir", directory.path])
    #expect(off.stdout.contains("AKIAIOSFODNN7EXAMPLE"), "显式关掉就该出原文（否则这个 flag 是摆设）")
    #expect(off.stderr.contains("AIX_CREDENTIAL_REDACTION_OFF"), "关闭必须有机器可读标记")
    #expect(off.stderr.contains("已关闭凭据脱敏"), "关闭必须留一行可审计提示，不能静默出原文")
    // 表格模式同理：提示进 stderr，stdout 不被污染（管道里仍是干净数据）。
    let table = await Aix.run(arguments: ["commands", "--no-redact", "--data-dir", directory.path])
    #expect(table.stderr.contains("已关闭凭据脱敏"))
    #expect(!table.stderr.contains("{") , "stderr 里不该混进 JSON 片段")
}

@Test("路径遮罩（#61 那套）默认关、`--redact` 才开；它与凭据脱敏是两个独立开关")
func pathMaskingIsIndependentFromCredentialRedaction() async throws {
    let directory = try Scratch.directory("cli-mask")
    let store = try await AixFixture.store(in: directory)
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 1, prefix: "文档"))
    await store.flush()
    await store.stop()

    let home = NSHomeDirectory()
    let plain = await Aix.run(arguments: ["files", "--data-dir", directory.path])
    #expect(plain.stdout.contains("/repo/"), "默认不遮路径（库里就是原文，显示层不擅动作）")
    let masked = await Aix.run(arguments: ["files", "--redact", "--data-dir", directory.path])
    #expect(masked.stdout.contains("/repo/"), "与家目录无关的路径不该被改动")
    // 家目录路径才归遮罩管：把一条真实家目录路径灌进去。
    let homeStore = try await AixFixture.store(in: directory)
    await homeStore.append(FileChange(path: home + "/Documents/secret.txt", kind: .modified,
                                      timestamp: AixFixture.stamp(500), agentID: nil, agentKind: .unknown))
    await homeStore.flush()
    await homeStore.stop()
    let still = await Aix.run(arguments: ["files", "--data-dir", directory.path])
    #expect(still.stdout.contains(home), "默认态：家目录原文照出（这是显示层，不是安全边界）")
    let hidden = await Aix.run(arguments: ["files", "--redact", "--data-dir", directory.path])
    #expect(!hidden.stdout.contains(home), "--redact 后家目录原文不该再出现")
    #expect(hidden.stdout.contains("~"), "遮罩后应是 `~` 形态")
    // 两个开关互不越界：--redact 不动凭据，--no-redact 不动路径。
    let both = await Aix.run(arguments: ["files", "--redact", "--no-redact", "--data-dir", directory.path])
    #expect(!both.stdout.contains(home) && both.stderr.contains("已关闭凭据脱敏"))
}

@Test("路径遮罩只能有一份：CLI 里不许再长出一把分词尺子（#64 的成因就是这个）")
func cliDoesNotOwnAPathTokenizer() throws {
    let cli = try AixSourceTree.codeFiles(under: "Sources/AIObservatoryCLI").joined(separator: "\n")
    #expect(cli.contains("PathPrivacy.Mask"),
            "CLI 必须接 Core 里那份路径映射（#71 后它叫 `PathPrivacy.Mask`），实得：没有引用")
    // 反向探针：自己写的前缀切分一律算越界（`hasPrefix("/")` 是遮罩实现里的判据形状）。
    #expect(!cli.contains("hasPrefix(\"/\")"), "CLI 里出现了自写的路径边界判定 ⇒ 又长出第二把尺子")
    #expect(!cli.contains("projectPlaceholder"), "CLI 里不该自己声明占位符常量")
}

@Test("第七格：库文件存在但**不可读** ⇒ 退 2，且不得退化成「没有库」")
func unreadableDatabaseFileIsNotNoStore() async throws {
    let directory = try Scratch.directory("cli-unreadable")
    let store = try await AixFixture.store(in: directory)
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 2))
    await store.flush()
    await store.stop()

    let path = AixFixture.databasePath(in: directory).path
    let originalMode = permissions(of: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: originalMode], ofItemAtPath: path) }
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

    let output = await Aix.run(arguments: ["files", "--data-dir", directory.path])
    #expect(output.exitCode == AixExitCode.preconditionFailed.rawValue)
    #expect(output.stdout.isEmpty)
    // 关键是**别把"读不到"报成"没有"**：那会让人以为采集面空了（#46/#47 那一族的形状）。
    #expect(!output.stderr.contains("但里面没有"), "不可读不能报成「没有库」")
    #expect(output.stderr.contains("打不开"), "应报「打不开」，实得：\(output.stderr)")
}

@Test("WAL 自报只在边车非空时出现")
func walWarningOnlyWhenNonEmpty() async throws {
    let directory = try Scratch.directory("cli-wal")
    let store = try await AixFixture.store(in: directory)
    await AixFixture.append(store, AixFixture.unattributedChanges(count: 1))
    await store.flush()
    await store.stop()   // stop() 会 checkpoint ⇒ 空边车或无边车

    let databasePath = AixFixture.databasePath(in: directory).path
    #expect(AixStore.uncheckpointedWALBytes(databasePath: databasePath) == nil)
    let quiet = await Aix.run(arguments: ["files", "--data-dir", directory.path])
    #expect(!quiet.stderr.contains("AIX_WAL_MAY_BE_CHECKPOINTED"))

    let fake = URL(fileURLWithPath: databasePath + "-wal")
    try Data(repeating: 0x57, count: 4_096).write(to: fake)
    defer { try? FileManager.default.removeItem(at: fake) }
    #expect(AixStore.uncheckpointedWALBytes(databasePath: databasePath) == 4_096)
    let loud = await Aix.run(arguments: ["files", "--data-dir", directory.path])
    #expect(loud.stderr.contains("AIX_WAL_MAY_BE_CHECKPOINTED bytes=4096"))
    #expect(loud.stderr.contains("不是只读操作"))
}

// MARK: - 解析链：六输入矩阵 + 与 App 那份常量的对拍

@Test("ADR-0003 四条优先级 + 两个空白分支：逐分支给定输入定死输出")
func dataLocationResolutionMatrix() throws {
    let inputs = AixDataLocation.Inputs(
        explicit: nil,
        environment: ["AIOBSERVATORY_DATA_DIR": "  "],
        bundleIdentifier: "com.aix.aiobservatory",
        bundlePathExtension: "app",
        applicationSupportDirectory: "/Support",
        currentDirectory: "/work/pkg/sub",
        hasFile: { $0 == "/work/pkg/Package.swift" }
    )
    // env 只有空白 ⇒ 视同未配（App 侧那条修正是同一个道理），继续往下走打包分支。
    #expect(AixDataLocation.resolve(inputs) == .directory("/Support/com.aix.aiobservatory", source: .packagedBundle))
    // --data-dir 优先级最高。
    #expect(AixDataLocation.resolve(AixDataLocation.Inputs(explicit: "/given", environment: inputs.environment,
                                                           bundleIdentifier: "com.aix.aiobservatory",
                                                           bundlePathExtension: "app",
                                                           applicationSupportDirectory: "/Support",
                                                           currentDirectory: "/work/pkg/sub",
                                                           hasFile: inputs.hasFile))
            == .directory("/given", source: .cliFlag))
    // 未打包 + 仓库内 ⇒ observatory-data/
    let dev = AixDataLocation.resolve(AixDataLocation.Inputs(
        environment: [:], bundleIdentifier: nil, bundlePathExtension: "",
        applicationSupportDirectory: "/Support", currentDirectory: "/work/pkg/sub", hasFile: inputs.hasFile
    ))
    #expect(dev == .directory("/work/pkg/observatory-data", source: .repository))
    // 仓库外 6 层找不到 marker ⇒ unresolved（**不是**退内存库，也不是退临时目录）。
    let lost = AixDataLocation.devDirectory(fromCurrentDirectory: "/tmp/deep/a/b/c/d", hasMarker: { _ in false })
    #expect(lost.isEmpty)
    // 空白 --data-dir 是"要一个目录但没给"⇒ unresolved，不能悄悄退回链上其它档。
    if case .unresolved = AixDataLocation.resolve(AixDataLocation.Inputs(explicit: "   ", environment: [:],
                                                                        bundleIdentifier: nil, bundlePathExtension: "",
                                                                        applicationSupportDirectory: nil,
                                                                        currentDirectory: "/tmp", hasFile: { _ in false })) {}
    else { Issue.record("空白 --data-dir 必须 unresolved") }
}

@Test("两条解析链引用同一批字面常量 —— **这只比字串引用，不比行为**（行为对拍在 ResolverBehaviorParityTests）")
func resolverSharesLiteralConstantsWithAppImplementation() throws {
    // 总控 22:5x 点破的一格：上一条用例顶着「两份实现的漂移要当场红」的名字，但它量的是
    // "两边源码里都出现了这些字串" ⇒ 两边行为不同也能绿（本仓教训：源码级形状检查会被同名符号
    // 在别处的使用骗过，删掉整段仍然绿）。名字改成它实际量的东西，并保留作**第二层**
    // ——它能抓"其中一侧偷改常量名"这种形状，行为对拍抓不到那一类。
    // `DataLocation` 在 executableTarget 里 ⇒ 平时 import 不到（ICR-0012 §零.3）；
    // 现在测试 target 依裁定 ① 依赖 AIObservatoryApp，所以**行为**也能对了（见下一个 Suite）。
    let app = try AixSourceTree.codeOnly("Sources/AIObservatoryApp/DataLocation.swift")
    let cli = try AixSourceTree.codeOnly("Sources/AIObservatoryCLI/AixDataLocation.swift")
    // 上一版指的是 `ObservatoryEngine.swift` 这一个文件 —— health 把它拆成分片之后
    // 库文件名搬去了别处，锚点跟着红（同一形状本波已第三次）⇒ 改扫目录 + 分母守卫。
    let engineFiles = try AixSourceTree.codeFiles(under: "Sources/AIObservatoryEngine")
    #expect(engineFiles.count >= 5, "AIObservatoryEngine 目录只扫到 \(engineFiles.count) 份源码，分母不对")
    let engine = engineFiles.joined(separator: "\n")
    for constant in ["AIOBSERVATORY_DATA_DIR", "com.aix.aiobservatory", "Package.swift", "observatory-data"] {
        #expect(app.contains("\"" + constant + "\""), "App 侧的解析链少了常量 \(constant)")
        #expect(cli.contains("\"" + constant + "\""), "CLI 侧的解析链少了常量 \(constant)")
    }
    // 库文件名的持有者不在 App 的 DataLocation 里，而在 Engine（databaseConfiguration 那一处）。
    #expect(engine.contains("\"observatory.sqlite\""), "Engine 侧的库文件名被改名了，CLI 那份还指着旧名")
    #expect(cli.contains("\"observatory.sqlite\""), "CLI 侧的库文件名与 Engine 拼的那个不是一个")
    // 向上找 marker 的层数也得上锁：一边 6 层、另一边改成 8 层，仓库根更深的工作树里会选到不同目录。
    #expect(app.contains("0..<6") && cli.contains("0..<6"))
}

/// 同一组输入**分别喂两份实现**，比选到的路径逐字相等（裁定 ②）。
///
/// 可达面先说清，免得又变成"名字比证据宽"：App 侧 `DataLocation.storeDirectory` 是
/// 读活全局（ProcessInfo env / Bundle.main / 真实 cwd）且会 `createDirectory` 的**无参**计算属性 ⇒
/// 喂不进参数。两条实现真正共享的可注入面只有纯函数 `devDirectory(fromCurrentDirectory:hasMarker:)`。
/// 所以：仓内/仓外/嵌套层数这些格走**纯函数行为对拍**；env 那一格用 `setenv` 探一次（带还原）；
/// "不可建目录"与"库不可读"两格是**有意的行为分叉**（App 建目录、CLI 拒建），
/// 于是断言"路径相同 + CLI 拒绝打开"，而不是假装两边行为一致。
///
/// ⚠️ `setenv` 动的是进程全局，`.serialized` 只串行化**本 Suite 内**的用例，挡不住别的 Suite 并行读 env
/// （`AIObservatoryAppTests` 里有同一批全局的用例）。这一格的风险留在牌上，不在这儿藏。
@Suite(.serialized)
struct ResolverBehaviorParityTests {
    /// 六格矩阵：**每格的期望路径是手推出来的字面量**，两份实现各自去够它。
    /// （上一版这里写的是 `wantNonEmpty` 布尔 + 一个恒真的闭包过滤器 ⇒ 恰好就是刚被点破的
    ///  那一类"看着在断、其实没喂"，重写掉。）
    @Test("devDirectory 六格（含 6 层边界与找不到）：两份实现与手推期望值三方逐字相等")
    func devDirectoryParityMatrix() throws {
        let cases: [(cwd: String, marker: String, expected: String)] = [
            ("/work/pkg/sub/deep", "/work/pkg/Package.swift", "/work/pkg/observatory-data"),
            ("/work/pkg", "/work/pkg/Package.swift", "/work/pkg/observatory-data"),
            ("/a/b/c/d/e/f/g/h", "/a/b/c/d/e/f/Package.swift", "/a/b/c/d/e/f/observatory-data"),
            // 第 6 次检查刚好命中（循环是 0..<6）⇒ 边界格：两侧层数一旦不齐，这格先红。
            ("/a/b/c/d/e/f/g/h", "/a/b/c/Package.swift", "/a/b/c/observatory-data"),
            ("/tmp/deep/a/b/c/d", "/elsewhere/Package.swift", ""),            // 6 层内找不到
            ("/Users/dev/Projects/x/y", "/Users/dev/Projects/x/y/Package.swift",
             "/Users/dev/Projects/x/y/observatory-data"),
        ]
        #expect(cases.filter { !$0.expected.isEmpty }.count == 5, "矩阵得同时有命中格与空手格")
        #expect(cases.filter { $0.expected.isEmpty }.count == 1)
        for item in cases {
            let hasMarker: @Sendable (String) -> Bool = { $0 == item.marker }
            let appValue = DataLocation.devDirectory(fromCurrentDirectory: item.cwd, hasMarker: hasMarker)
            let cliValue = AixDataLocation.devDirectory(fromCurrentDirectory: item.cwd, hasMarker: hasMarker)
            #expect(cliValue == item.expected,
                    "CLI 在 cwd=\(item.cwd) 选到 \(cliValue)，手推期望是 \(item.expected)")
            #expect(appValue == item.expected,
                    "App 在 cwd=\(item.cwd) 选到 \(appValue)，手推期望是 \(item.expected)")
            #expect(appValue == cliValue, "同一格两份实现不等：App=\(appValue) CLI=\(cliValue)")
        }
    }

    @Test("env 那一格：setenv 后两份实现选到同一个目录（App 会 mkdir，CLI 不会 —— 分叉另断）")
    func environmentBranchAgreesOnChosenDirectory() throws {
        let scratch = try Scratch.directory("cli-resolver-parity")
        let target = scratch.appending(path: "given-dir").path
        let key = "AIOBSERVATORY_DATA_DIR"
        let backup = ProcessInfo.processInfo.environment[key]
        defer { if let backup { setenv(key, backup, 1) } else { unsetenv(key) } }

        setenv(key, target, 1)
        let appChosen = DataLocation.storeDirectory
        let cliChosen = AixDataLocation.resolve(AixDataLocation.Inputs(
            environment: [key: target])).directoryPath
        #expect(appChosen == cliChosen, "env 有值时两边选的目录不同：App=\(appChosen) CLI=\(cliChosen)")

        // 空白 env：两边都必须"视同未配"继续往下走（App 侧那条 trim 修正是同一个道理）。
        setenv(key, "   ", 1)
        let appBlank = DataLocation.storeDirectory
        let cliBlank = AixDataLocation.resolve(AixDataLocation.Inputs(
            environment: [key: "   "])).directoryPath
        #expect(appBlank == cliBlank, "空白 env 两边落点不同：App=\(appBlank) CLI=\(cliBlank)")
        #expect(appBlank != target, "空白 env 被当成有效目录 ⇒ 两边一起错")
    }

    @Test("第七格（库存在但 chmod 000）：两边路径相同，CLI 拒绝打开且不退化成「没有库」")
    func unreadableFileAgreesOnPathAndCliRefuses() async throws {
        let directory = try Scratch.directory("cli-parity-unreadable")
        let store = try await AixFixture.store(in: directory)
        await AixFixture.append(store, AixFixture.unattributedChanges(count: 1))
        await store.flush()
        await store.stop()

        // 路径层面两边必须指同一处 —— App 与 CLI 都不该在"文件存不存在"上各有说法。
        let path = AixFixture.databasePath(in: directory).path
        #expect(FileManager.default.fileExists(atPath: path))
        let cliChosen = try AixStore.databasePath(for: AixRequest(command: .files, dataDir: directory.path))
        #expect(cliChosen == path, "CLI 拼出的库路径与夹具建的那个不是一个：\(cliChosen)")

        let mode = permissions(of: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path) }
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)

        let output = await Aix.run(arguments: ["files", "--data-dir", directory.path])
        #expect(output.exitCode == AixExitCode.preconditionFailed.rawValue)
        #expect(!output.stderr.contains("但里面没有"), "不可读不能报成「没有库」")
        #expect(output.stderr.contains("打不开"))
    }
}
