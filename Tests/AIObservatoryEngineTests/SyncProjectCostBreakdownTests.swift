//
//  SyncProjectCostBreakdownTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws-engaudit
//
//  为什么默认不跑：它要种 8 000 行、跑十轮取数与聚合，是秒级到几十秒的长跑，
//  而且它**打数**不判定（判定留给人）。开法：
//
//      AIOBSERVATORY_SYNC_BREAKDOWN=1 xcrun swift test -c release --disable-sandbox \
//        --filter SyncProjectCostBreakdown 2>&1 | grep SYNC-BD
//
//  要回答的问题很具体：`syncProjects` 在 release 归因台里是 15.8 ms/tick
//  （`EngineTickAttributionTests` 的 `TickStageLedger`，`getrusage` CPU 口径），
//  换成窄取数之后只降到 15.0 ms/tick ⇒ **「那五次 7 000 行重拉」这个归因没有兑现**。
//  所以把这 15 ms 拆成四块，各自单独量：
//
//      窄取数 / 宽取数（同一份数据、只换列集合）/ 聚合 / 项目落库
//
//  两条诚实性要求（照 AGENTS §6 与 ADR-0009 的口径）：
//   1. 用 **CPU 时间**（`getrusage`）而不是墙钟——墙钟会被别的线程与别的负载污染；
//   2. 报出来的四块必须能加回台账那一段（对不上就是漏了项，那条差额也打印出来）。
//
//  ⚠️ 一台机器一个窗口：绝对值随负载漂，**只有同窗内的比值可用**（与归因台同一条限制）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport
@testable import AIObservatoryEngine

private let breakdownEnabled = ProcessInfo.processInfo.environment["AIOBSERVATORY_SYNC_BREAKDOWN"] != nil

/// 本进程的 CPU 时间（用户 + 系统），毫秒。与 `TickStageLedger` 同一把尺子。
private func cpuMilliseconds() -> Double {
    var usage = rusage()
    guard getrusage(RUSAGE_SELF, &usage) == 0 else { return .nan }
    let user = Double(usage.ru_utime.tv_sec) * 1_000 + Double(usage.ru_utime.tv_usec) / 1_000
    let system = Double(usage.ru_stime.tv_sec) * 1_000 + Double(usage.ru_stime.tv_usec) / 1_000
    return user + system
}

private enum Breakdown {
    static let rounds = 10
    /// 五路的行数，与 `syncProjectsIfNeeded` 的上限同量级（合计 8 000 行）。
    static let fileChanges = 2_000
    static let commands = 2_000
    static let events = 2_000
    static let sessions = 500
    static let risks = 500
    static let base = Date(timeIntervalSince1970: 1_800_006_000)
}

@Suite("syncProjects 那 15 ms 到底在哪：四块拆开量", .enabled(if: breakdownEnabled),
       .timeLimit(.minutes(3)))
struct SyncProjectCostBreakdownTests {

    /// 铺一个与生产形状接近的库：五路都有行，`commands` 带 argv、`events` 带 summary。
    private func seededStore() async throws -> ObservatoryStore {
        let directory = try AIObservatoryTestSupport.Scratch.directory("sync-breakdown")
        let store = try await ObservatoryStore.open(
            configuration: .file(directory.appendingPathComponent("observatory.sqlite").path)
        )
        let agent = UUID()
        let session = UUID()
        for index in 0..<Breakdown.fileChanges {
            await store.append(FileChange(
                path: "/projects/p\(index % 12)/src/file\(index).swift",
                kind: .modified,
                timestamp: Breakdown.base.addingTimeInterval(Double(index)),
                agentID: agent, sessionID: session, agentKind: .claudeCode,
                sizeBytes: 640, previousSizeBytes: 610, isText: true,
                linesAdded: 3, linesRemoved: 1,
                projectPath: "/projects/p\(index % 12)"
            ))
        }
        for index in 0..<Breakdown.commands {
            await store.append(CommandRecord(
                executable: "swift",
                arguments: ["test", "--filter", "Module\(index)", "--scratch-path", "/tmp/very/long/path/\(index)"],
                workingDirectory: "/projects/p\(index % 12)",
                agentID: agent, sessionID: session, agentKind: .claudeCode,
                startedAt: Breakdown.base.addingTimeInterval(Double(index)),
                endedAt: Breakdown.base.addingTimeInterval(Double(index) + 0.4),
                exitCode: 0, outcome: .success, riskLevel: .medium,
                projectPath: "/projects/p\(index % 12)"
            ))
        }
        for index in 0..<Breakdown.events {
            await store.append(TimelineEvent(
                timestamp: Breakdown.base.addingTimeInterval(Double(index)),
                sessionID: session, agentID: agent, agentKind: .claudeCode,
                kind: .commandExecuted,
                title: "swift test --filter Module\(index)",
                summary: "退出码 0 · 工作目录 /projects/p\(index % 12) · 用时 0.4 秒",
                command: "swift test --filter Module\(index)",
                exitCode: 0, durationSeconds: 0.4,
                riskLevel: .medium,
                projectPath: "/projects/p\(index % 12)"
            ))
        }
        for index in 0..<Breakdown.sessions {
            try await store.upsertSessions([AgentSession(
                kind: .claudeCode, agentID: agent, title: "会话 · \(index)",
                projectPath: "/projects/p\(index % 12)",
                startedAt: Breakdown.base.addingTimeInterval(Double(index)),
                commandCount: 4, riskEventCount: 1, outcome: .success
            )])
        }
        for index in 0..<Breakdown.risks {
            try await store.recordRisks([RiskEvent(
                timestamp: Breakdown.base.addingTimeInterval(Double(index)),
                level: .high, category: .dangerousCommand, title: "递归开放权限 · \(index)",
                detail: "chmod -R 777 ./junk（第 \(index) 次）",
                agentID: agent, agentKind: .claudeCode,
                filePaths: ["/projects/p\(index % 12)/junk"],
                matchedRuleID: "risk.command.recursive-permission-broadening"
            )])
        }
        await store.flush()
        return store
    }

    @Test("四块各自的 CPU 毫秒/tick，并核对能不能加回同一形状下的整段")
    func breaksDownSyncProjectsCost() async throws {
        let store = try await seededStore()
        let mapper = ProjectMapper()

        var narrowFetch = 0.0
        var wideFetch = 0.0
        var aggregation = 0.0
        var wideAggregation = 0.0
        var persisting = 0.0
        var widePersisting = 0.0
        // 「整段」按同一形状、同一轮单独量：三段加起来必须≈它，对不上就是漏了项。
        // ⚠️ 不要拿这个数去减 `TickStageLedger` 的 15.0 ms/tick——那条台账的 fixture 只有
        // file_changes，而本用例五路都有行 ⇒ 那是两个不同的负载形状，相减会造出假缺口。
        var wholeNarrow = 0.0
        var wholeWide = 0.0
        for _ in 0..<Breakdown.rounds {
            let wholeStart = cpuMilliseconds()
            var mark = wholeStart

            let feed = try await store.projectFeed(
                fileChangeLimit: 2_000, commandLimit: 2_000, eventLimit: 2_000,
                sessionLimit: 500, riskLimit: 500
            )
            narrowFetch += cpuMilliseconds() - mark
            mark = cpuMilliseconds()

            let projects = mapper.aggregate(
                changes: feed.fileChanges, commands: feed.commands, events: feed.events,
                sessions: feed.sessions, risks: feed.risks
            )
            aggregation += cpuMilliseconds() - mark
            mark = cpuMilliseconds()

            try await store.upsertProjects(projects)
            persisting += cpuMilliseconds() - mark
            wholeNarrow += cpuMilliseconds() - wholeStart

            // 宽路走**完整三步**（只把列集合换回 `SELECT *`）：只量取数会把「对象更胖 ⇒
            // 聚合也更贵」那一半漏掉，两条路比的就不是同一段活了。
            let wideStart = cpuMilliseconds()
            mark = wideStart
            let changes = try await store.fileChanges(matching: FileChangeQuery(limit: 2_000)).items
            let commands = try await store.commands(matching: CommandQuery(limit: 2_000)).items
            let events = try await store.events(matching: EventQuery(limit: 2_000)).items
            let sessions = try await store.sessions(matching: SessionQuery(limit: 500)).items
            let risks = try await store.riskEvents(matching: RiskQuery(limit: 500)).items
            wideFetch += cpuMilliseconds() - mark
            mark = cpuMilliseconds()

            let wideProjects = mapper.aggregate(
                changes: changes, commands: commands, events: events, sessions: sessions, risks: risks
            )
            wideAggregation += cpuMilliseconds() - mark
            mark = cpuMilliseconds()

            try await store.upsertProjects(wideProjects)
            widePersisting += cpuMilliseconds() - mark
            wholeWide += cpuMilliseconds() - wideStart

            // 口径自检：两侧行数与聚合结论必须一致，否则比的不是同一件事。
            #expect(changes.count == feed.fileChanges.count)
            #expect(commands.count == feed.commands.count)
            #expect(risks.count == feed.risks.count)
            #expect(wideProjects == projects, "窄取数改变了项目地图的结论 ⇒ 少取了列")
        }
        let rounds = Double(Breakdown.rounds)
        let per = { (total: Double) in String(format: "%6.2f", total / rounds) }
        print("SYNC-BD 行数 文件变更=\(Breakdown.fileChanges) 命令=\(Breakdown.commands) "
            + "事件=\(Breakdown.events) 会话=\(Breakdown.sessions) 风险=\(Breakdown.risks)")
        print("SYNC-BD 取数  窄 \(per(narrowFetch)) / 宽 \(per(wideFetch)) ms/tick"
            + "    只换列集合省下 \(String(format: "%.2f", (wideFetch - narrowFetch) / rounds)) ms")
        print("SYNC-BD 聚合  窄 \(per(aggregation)) / 宽 \(per(wideAggregation)) ms/tick"
            + "    落库  窄 \(per(persisting)) / 宽 \(per(widePersisting)) ms/tick")
        let parts = (narrowFetch + aggregation + persisting) / rounds
        let wideParts = (wideFetch + wideAggregation + widePersisting) / rounds
        print("SYNC-BD 整段  窄 \(per(wholeNarrow))（三段合计 \(String(format: "%.2f", parts))"
            + " ⇒ 未归因余额 \(String(format: "%.2f", wholeNarrow / rounds - parts))）"
            + "    宽 \(per(wholeWide))（三段合计 \(String(format: "%.2f", wideParts))）")
        print("SYNC-BD 这一段的净节省 = \(String(format: "%.2f", wholeWide / rounds - wholeNarrow / rounds)) ms/tick")
        // 恒等式：余额必须是个位数毫秒内的零头，否则这张表是缺项的分解表。
        #expect(abs(wholeNarrow / rounds - parts) < 1.0,
                "三段加不回整段：漏了一项，这张分解表不能用")
        #expect(wholeNarrow < wholeWide, "窄路整段不比宽路便宜 ⇒ 这条改动没有意义")
        await store.stop()
    }
}
