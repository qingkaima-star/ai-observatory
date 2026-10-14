//
//  FixtureStoreSeeder.swift
//  Tests/AIObservatorySwiftDataStoreTests
//
//  Owner: master-controller（#12 的配套仪器）
//  ─────────────────────────────────────────────────────────
//  README 那两张图（#12）卡了很久，原因很实在：**在跑着真 Agent 的机器上拍出来的图，
//  像素里会带真实目录**（当年底部那一行常驻 Agent 的 cwd 就是这么漏出去的）。
//  唯一干净的拍法是**给 App 一个夹具数据目录**，而夹具库得有人造得出、且可复现——
//  所以造库的这一步放在这里，而不是写在一个没人再跑的 shell 脚本里。
//
//  ⚠️ 平时**整条用例是跳过的**：只有显式给了 `AIOBS_FIXTURE_DIR` 才跑。
//     它不是一条判据，是一台仪器；让它天天跑没有任何意义，还会往仓库里写文件。
//  ⚠️ 夹具里**只准出现合成路径**（`/Users/dev/…`），一个真家目录都不许有——
//     这条不是风格问题：这张库最后会变成为仓库里的一张 PNG。跑完自己会数一遍（见文件末尾那道计数）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

@Suite("仪器：夹具库生成（只在给了 AIOBS_FIXTURE_DIR 时跑）", .serialized)
struct FixtureStoreSeeder {

    private static var fixtureDir: String? {
        let raw = ProcessInfo.processInfo.environment["AIOBS_FIXTURE_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? nil : raw
    }

    @Test("按夹具造一份可公开的库", .enabled(if: FixtureStoreSeeder.fixtureDir != nil))
    func seed() async throws {
        let directory = try #require(FixtureStoreSeeder.fixtureDir, "没给 AIOBS_FIXTURE_DIR 时这条不该跑")
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let store = try await ObservatoryStore.open(
            configuration: .file("\(directory)/observatory.sqlite"))

        let now = Date()
        // 跨午夜保护：偏移量不许早于"今天 00:01"，否则页面默认范围「今天」会读到 0 条
        // （本夹具第一次跨午夜重跑就踩到了：00:03 播种、-50min 落在昨天 ⇒ 列表空、检查器不开）。
        let dayStart = Calendar.current.startOfDay(for: now).addingTimeInterval(60)
        func todayClamped(_ offset: TimeInterval) -> Date { max(now.addingTimeInterval(offset), dayStart) }
        let project = "/Users/dev/Projects/atlas-backend"
        let alpha = UUID()
        let beta = UUID()

        // 会话：两条已收尾、一条在跑 —— 界面上的「当前运行中」那一格要有东西。
        try await store.upsertSessions([
            AgentSession(displayIndex: 41, kind: .claudeCode, agentID: alpha,
                         title: "重构订单聚合根", projectPath: project,
                         startedAt: todayClamped(-50 * 60),
                         endedAt: todayClamped(-12 * 60),
                         modifiedFileCount: 34, createdFileCount: 9, deletedFileCount: 3,
                         commandCount: 187, failedCommandCount: 6, riskEventCount: 2,
                         outcome: .success),
            AgentSession(displayIndex: 42, kind: .openAICodex, agentID: beta,
                         title: "补分库路由的回归用例", projectPath: project,
                         startedAt: todayClamped(-20 * 60),
                         modifiedFileCount: 12, createdFileCount: 4, deletedFileCount: 0,
                         commandCount: 61, failedCommandCount: 2, riskEventCount: 1,
                         outcome: .running),
        ])

        var events: [TimelineEvent] = []
        var changes: [FileChange] = []
        var commands: [CommandRecord] = []
        var risks: [RiskEvent] = []
        var samples: [SystemPerformanceSample] = []
        // 六小时、每分钟一颗事件 —— 概览页那张 24 小时柱图与趋势才有形状。
        for minute in 0..<360 {
            let at = now.addingTimeInterval(-Double(360 - minute) * 60)
            let which = minute % 3 == 0 ? beta : alpha
            let kind: AgentKind = which == beta ? .openAICodex : .claudeCode
            events.append(TimelineEvent(timestamp: at, agentID: which, agentKind: kind,
                                        kind: minute % 5 == 0 ? .commandExecuted : .fileModified,
                                        title: minute % 5 == 0 ? "执行 npm test -- --runInBand"
                                             : "改动 \(project)/Sources/Module\(minute % 12)/OrderAggregate.swift",
                                        summary: "第 \(minute) 分钟的一次活动",
                                        command: minute % 5 == 0 ? "npm test -- --runInBand" : nil,
                                        projectPath: project))
            if minute % 6 == 0 {
                changes.append(FileChange(path: "\(project)/Sources/Module\(minute % 12)/OrderAggregate.swift",
                                          kind: .modified, timestamp: at, agentID: which, agentKind: kind,
                                          linesAdded: 14 + minute % 40, linesRemoved: 3 + minute % 9,
                                          projectPath: project))
            }
            if minute % 9 == 0 {
                let failed = minute % 27 == 0
                commands.append(CommandRecord(executable: "npm",
                                              arguments: ["test", "--", "--runInBand"],
                                              agentID: which, startedAt: at,
                                              endedAt: at.addingTimeInterval(6 + Double(minute % 20)),
                                              exitCode: failed ? 1 : 0,
                                              outcome: failed ? .failure : .success,
                                              projectPath: project))
            }
            if minute % 2 == 0 {
                samples.append(SystemPerformanceSample(timestamp: at,
                                                       cpuTotalPercent: 18 + Double(minute % 37),
                                                       cpuSystemPercent: 4 + Double(minute % 7),
                                                       cpuUserPercent: 12 + Double(minute % 29),
                                                       memoryUsedBytes: 11_000_000_000 + UInt64(minute) * 5_000_000,
                                                       memoryTotalBytes: 34_359_738_368,
                                                       diskReadBytesPerSecond: 1_200_000 + Double(minute) * 9_000,
                                                       diskWriteBytesPerSecond: 640_000 + Double(minute) * 4_000,
                                                       loadAverage1m: 2.4 + Double(minute % 11) / 5))
            }
        }
        risks.append(RiskEvent(timestamp: now.addingTimeInterval(-2 * 3600), level: .high,
                               category: .dangerousCommand,
                               title: "Agent 执行了高风险删除命令",
                               detail: "命令命中破坏性规则，目标 \(project)/fixtures/legacy",
                               agentID: alpha, agentKind: .claudeCode,
                               command: "rm -rf \(project)/fixtures/legacy",
                               filePaths: ["\(project)/fixtures/legacy"], matchedRuleID: "R-004"))
        risks.append(RiskEvent(timestamp: now.addingTimeInterval(-40 * 60), level: .medium,
                               category: .credentialExposure,
                               title: "命令参数里出现了疑似令牌",
                               detail: "已按出口脱敏口径处理，落库前就不含原文",
                               agentID: beta, agentKind: .openAICodex,
                               command: "curl -H \"Authorization: Bearer <redacted>\" https://api.example.test/v1/orders"))
        try await store.recordRisks(risks)

        for batch in events.chunked(into: 200) { try await store.upsertEvents(batch) }
        for change in changes { await store.append(change) }
        for command in commands { await store.append(command) }
        for sample in samples { await store.append(sample) }
        await store.flush()

        // 自检：库里**一个真家目录都不许有**。这不是装饰 —— 这张库最后会变成 README 上的像素。
        let home = NSHomeDirectory()
        var leaked = 0
        for page in stride(from: 0, to: 400, by: 200) {
            let events = try await store.events(matching: EventQuery(limit: 200, offset: page))
            leaked += events.items.filter { $0.title.contains(home) || $0.summary.contains(home) }.count
        }
        let commandsPage = try await store.commands(matching: CommandQuery(limit: 500))
        leaked += commandsPage.items.filter { $0.workingDirectory?.contains(home) == true }.count
        #expect(leaked == 0, "夹具里有 \(leaked) 处带真家目录 \(home) 的记录 ⇒ 这份库不许拿去拍照")
        // 顺手把启动设置也写成夹具版：**路径遮罩必须开着**（`demoRedactedOutput`）。
        // 这条不是装饰 —— 第一次试拍时它默认关，于是「当前运行中的 Agent」那一行的
        // `FilePathText(mode: .lastTwoComponents)` 把真实家目录尾段 `Users/one` 原样画上屏
        // （遮罩关掉时 `tail` 走 `plainTail`，等价于按 `/` 切末两级）。像素里的事，grep 查不到。
        // 监控根指向那个不存在的合成项目 ⇒ 引擎在这台机器上采不到真仓库的活动。
        var startup = ObservatorySettings(storeDirectory: directory)
        startup.demoRedactedOutput = true
        startup.monitoredRoots = [project]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(startup).write(
            to: URL(fileURLWithPath: directory, isDirectory: true).appending(path: "settings.json"))

        print("夹具库已生成：\(directory)/observatory.sqlite（事件 \(events.count)／变更 \(changes.count)／命令 \(commands.count)／采样 \(samples.count)／风险 \(risks.count)）")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0 ..< Swift.min($0 + size, count)]) }
    }
}
