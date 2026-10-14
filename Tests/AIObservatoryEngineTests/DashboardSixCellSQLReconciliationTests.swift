//
//   DashboardSixCellSQLReconciliationTests.swift
//   Tests/AIObservatoryEngineTests
//
//   Owner: ws/range（#75）
//   ─────────────────────────────────────────────────────────
//   台账 §五.1 的验收 ①「对账」那一格：**界面六格的每一个数 ↔ 同条件 SQL 直查，逐条给数**。
//
//   为什么单独一份而不是塞进 `DashboardRangeParityTests`：那份对拍的是"两个后端互相比"
//   （SQLite vs SwiftData 同口径），本文件比的是"读数 vs 库"（界面拿到的那份载荷 vs
//   直接对同一张表、同一个 `ts >= ? AND ts <= ?` 手写的 SQL）。两者红了说的是不同的事：
//   前者红 = 两侧漂开；后者红 = **两侧一起漂**（那才是"界面自洽但和库不符"这一族）。
//
//   两档取的是产品里真实的两个档（折算式与 `ObservatoryTimeRange.dateRange(now:)` 逐字相同）：
//     · 「今天」  = `DateRangeFilter.today(now)`
//     · 「7 天」  = `DateRangeFilter.lastHours(24 * 7, now: now)`
//   界面六格 = `DashboardView.periodTiles` 里那六个 `value`，它们的唯一出处是
//   `dashboardStats(settledAt:within:)` 的那份载荷，所以这里逐格对的就是那六个格子。
//
//   数字要能现跑现取：设 `AIOBS_DASHBOARD_RECONCILE=1` 跑这一条用例，会把两端的具体数字
//   （含区间端点的可读时刻）打成一张表输出到 stdout；不设就只做断言、不打印。
//
//   时刻用 `Date()` 现取（这一条用例的存在理由就是"此刻界面上那几个数对得上库"），
//   两端读的是**同一个** `now`，所以不依赖运行时刻的稳定性。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore

@Suite("Dashboard 六格 ↔ SQL 直查：#75 的对账账本", .serialized)
struct DashboardSixCellSQLReconciliationTests {

    /// 夹具：9 天 × 每天若干条，跨档分布刻意做 uneven ——
    /// 「今天」与「7 天」两档下每一格都不同值，这样"把区间压成某一天"必然对不上账。
    private struct ReconcileFixture {
        let now: Date
        let agentID = UUID()
        let sessionID = UUID()
        let project = "/Users/dev/Projects/Reconcile"

        func ago(days: Double, hour: Int = 9) -> Date {
            let calendar = Calendar.current
            let day = calendar.date(byAdding: .day, value: -Int(days.rounded(.down)), to: now) ?? now
            let start = calendar.startOfDay(for: day)
            return calendar.date(byAdding: .hour, value: hour, to: start) ?? start
        }

        /// 事件：第 0…8 天前各 `9 - 天前` 条（今天 9 条、第八天前 1 条）。
        var events: [TimelineEvent] {
            var rows: [TimelineEvent] = []
            for back in 0..<9 {
                for index in 0..<(9 - back) {
                    let stamp = ago(days: Double(back)).addingTimeInterval(TimeInterval(index) * 60)
                    let kind = OperationKind.allCases[index % OperationKind.allCases.count]
                    rows.append(TimelineEvent(
                        timestamp: stamp, sessionID: sessionID, agentID: agentID,
                        agentKind: AgentKind.claudeCode, kind: kind,
                        title: "事件 D\(back)-\(index)", summary: "第 \(back) 天前",
                        filePath: "\(project)/Sources/A\(index).swift",
                        riskLevel: RiskLevel.low, projectPath: project
                    ))
                }
            }
            return rows
        }

        /// 文件变更：第 0…8 天前各三条，kind 轮转 ⇒ 三格分开可数。
        var fileChanges: [FileChange] {
            var rows: [FileChange] = []
            for back in 0..<9 {
                for (index, kind) in [FileChangeKind.modified, .created, .deleted].enumerated() {
                    let stamp = ago(days: Double(back), hour: 10 + index)
                    rows.append(FileChange(
                        path: "\(project)/Sources/D\(back)_\(index).swift", kind: kind,
                        timestamp: stamp, agentID: agentID, sessionID: sessionID,
                        agentKind: AgentKind.claudeCode, projectPath: project
                    ))
                }
            }
            return rows
        }

        /// 命令：今天 4 条（1 条失败），第五天前 6 条（2 条失败）⇒ 两档不同值。
        var commands: [CommandRecord] {
            var rows: [CommandRecord] = []
            for (back, count) in [(0, 4), (5, 6)] {
                for index in 0..<count {
                    let stamp = ago(days: Double(back), hour: 11 + index)
                    let failed = index % 4 == 3
                    rows.append(CommandRecord(
                        executable: "tool", arguments: ["--day", "\(back)", "--n", "\(index)"],
                        agentID: agentID, sessionID: sessionID, agentKind: AgentKind.claudeCode,
                        startedAt: stamp, endedAt: stamp.addingTimeInterval(3),
                        exitCode: failed ? 1 : 0,
                        outcome: failed ? .failure : .success, projectPath: project
                    ))
                }
            }
            return rows
        }

        /// 风险：今天 2 条（1 高），第三天前 3 条（1 高），第七天前 1 条（低）。
        var risks: [RiskEvent] {
            var rows: [RiskEvent] = []
            for (back, total, high) in [(0, 2, 1), (3, 3, 1), (7, 1, 0)] {
                for index in 0..<total {
                    let level: RiskLevel = index < high ? .high : .low
                    rows.append(RiskEvent(
                        timestamp: ago(days: Double(back), hour: 13 + index), level: level,
                        category: .dangerousCommand, title: "风险 D\(back)-\(index)", detail: "",
                        agentID: agentID, agentKind: .claudeCode, sessionID: sessionID,
                        command: "git push --force"
                    ))
                }
            }
            return rows
        }

        /// 采样：今天 4 条、第二天前 4 条、第六天前 4 条（cpu 各异，峰值落在 7 天档内）。
        var samples: [PerformanceSample] {
            var rows: [PerformanceSample] = []
            for back in [0, 2, 6] {
                for index in 0..<4 {
                    rows.append(PerformanceSample(
                        timestamp: ago(days: Double(back), hour: 14 + index),
                        sessionID: sessionID, agentID: agentID,
                        cpuPercent: Double(10 * (index + 1) + back),
                        memoryBytes: UInt64(1_000_000 * (index + 1 + back))
                    ))
                }
            }
            return rows
        }

        /// 会话：今天一场已结算（30 分钟），第五天前一场**仍未结算**
        /// （它的时长只在 7 天档里进"活跃总时长"，是"某一天 vs 真区间"最尖的一刀）。
        var sessions: [AgentSession] {
            let todayStart = ago(days: 0, hour: 8)
            let oldStart = ago(days: 5, hour: 7)
            return [
                AgentSession(id: UUID(), displayIndex: 1, kind: .claudeCode, agentID: agentID,
                             title: "今天的会话", projectPath: project,
                             startedAt: todayStart, endedAt: todayStart.addingTimeInterval(1_800),
                             outcome: .success),
                AgentSession(id: sessionID, displayIndex: 2, kind: .openAICodex, agentID: agentID,
                             title: "五天前起、还在跑", projectPath: project,
                             startedAt: oldStart, outcome: .running),
            ]
        }

        var agents: [AgentInstance] {
            [AgentInstance(id: agentID, kind: .claudeCode, pid: 4_101, displayName: "claude",
                           executablePath: "/usr/local/bin/claude", workingDirectory: project,
                           startedAt: ago(days: 8), lastSeenAt: now, state: .running,
                           cpuPercent: 9, memoryBytes: 120_000_000)]
        }
    }

    /// 一条"读数 ↔ 直查"的账：格子名、界面那格的数、SQL 的数、以及用的条件。
    private struct Line: Sendable {
        let cell: String
        let shown: String
        let queried: String
        let condition: String
    }

    @Test("「今天」与「7 天」两档：六格逐条对上同条件 SQL 直查")
    func sixCellsMatchRawSQL() async throws {
        let fixture = ReconcileFixture(now: Date())
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        try await store.upsertAgents(fixture.agents)
        try await store.upsertSessions(fixture.sessions)
        for event in fixture.events { await store.append(event) }
        for change in fixture.fileChanges { await store.append(change) }
        for command in fixture.commands { await store.append(command) }
        for sample in fixture.samples { await store.append(sample) }
        try await store.recordRisks(fixture.risks)
        await store.flush()
        let database = await store.database

        for (tier, window) in [
            ("今天", DateRangeFilter.today(fixture.now)),
            ("最近 7 天", DateRangeFilter.lastHours(24 * 7, now: fixture.now)),
        ] {
            // 与界面完全同一条入口：同一份 `settledAt`、同一个 `DateRangeFilter`。
            let settledAt = fixture.now
            let stats = try await store.dashboardStats(settledAt: settledAt, within: window)
            let endpoints = [
                SQLiteValue.real(window.start?.timeIntervalSinceReferenceDate ?? 0),
                SQLiteValue.real(window.end?.timeIntervalSinceReferenceDate ?? 0),
            ]
            let readableWindow = "\(window.start?.formatted(date: .numeric, time: .standard) ?? "无起点") … "
                + "\(window.end?.formatted(date: .numeric, time: .standard) ?? "无终点")"
            var lines: [Line] = []

            func check(_ cell: String, shown: String, queried: String, condition: String) {
                #expect(shown == queried,
                        "「\(tier)」档格子「\(cell)」对不上账：界面 \(shown) ↔ 直查 \(queried)（条件 \(condition)）")
                lines.append(Line(cell: cell, shown: shown, queried: queried, condition: condition))
            }

            // ① 活跃总时长：会话按 `started_at` 落窗口，未结算的算到 `settledAt`（SQL 用
            //    `MAX(0, COALESCE(ended_at, ?) - started_at)`，与 `duration(until:)` 同式）。
            let durationRow = try await database.optionalRow(
                """
                SELECT COALESCE(SUM(MAX(0, COALESCE(ended_at, ?) - started_at)), 0) AS active_seconds
                  FROM \(StoreSchema.Table.sessions)
                 WHERE started_at >= ? AND started_at <= ?
                """,
                arguments: [SQLiteValue.real(settledAt.timeIntervalSinceReferenceDate)] + endpoints
            )
            let duration = durationRow?.double("active_seconds") ?? -1
            check("活跃总时长", shown: Self.seconds(stats.totalActiveSeconds),
                  queried: Self.seconds(duration),
                  condition: "sessions.started_at ∈ [起, 止] 的 SUM(时长)，未结算算到 \(readableWindow)")

            // ② 区间内新建会话
            let sessionCount = try await database.scalarInt(
                "SELECT COUNT(*) FROM \(StoreSchema.Table.sessions) WHERE started_at >= ? AND started_at <= ?",
                arguments: endpoints
            ) ?? -1
            check("区间内新建会话", shown: "\(stats.sessionCount)", queried: "\(sessionCount)",
                  condition: "sessions.started_at ∈ [起, 止]（闭区间，与界面递出去的窗口同两端）")

            // ③ 文件变更三格（界面那一格的大数是三者之和）
            let fileRow = try await database.optionalRow(
                """
                SELECT COALESCE(SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), 0) AS modified_count,
                       COALESCE(SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), 0) AS created_count,
                       COALESCE(SUM(CASE WHEN kind = ? THEN 1 ELSE 0 END), 0) AS deleted_count
                  FROM \(StoreSchema.Table.fileChanges)
                 WHERE timestamp >= ? AND timestamp <= ?
                """,
                arguments: [.text(FileChangeKind.modified.rawValue), .text(FileChangeKind.created.rawValue),
                            .text(FileChangeKind.deleted.rawValue)] + endpoints
            )
            let queriedModified = fileRow?.int("modified_count") ?? -1
            let queriedCreated = fileRow?.int("created_count") ?? -1
            let queriedDeleted = fileRow?.int("deleted_count") ?? -1
            check("文件变更（改/新/删）",
                  shown: "\(stats.filesModified + stats.filesCreated + stats.filesDeleted)"
                  + " [\(stats.filesModified)/\(stats.filesCreated)/\(stats.filesDeleted)]",
                  queried: "\(queriedModified + queriedCreated + queriedDeleted)"
                  + " [\(queriedModified)/\(queriedCreated)/\(queriedDeleted)]",
                  condition: "file_changes.timestamp ∈ [起, 止] 按 kind 分桶")

            // ④ 命令（含失败数）
            let commandRow = try await database.optionalRow(
                """
                SELECT COUNT(*) AS total_count,
                       COALESCE(SUM(CASE WHEN outcome = ? THEN 1 ELSE 0 END), 0) AS failed_count
                  FROM \(StoreSchema.Table.commands)
                 WHERE started_at >= ? AND started_at <= ?
                """,
                arguments: [.text(CommandOutcome.failure.rawValue)] + endpoints
            )
            check("命令", shown: "\(stats.commandsExecuted)（失败 \(stats.failedCommands)）",
                  queried: "\(commandRow?.int("total_count") ?? -1)（失败 \(commandRow?.int("failed_count") ?? -1)）",
                  condition: "commands.started_at ∈ [起, 止]")

            // ⑤ CPU（均值 / 峰值）+ 峰值内存。直查的条件与实现**逐字同一条**：#96 之后这一格
            //    只算挂着会话的采样（本格在界面上写的是"被观测 Agent 的 CPU"），直查少了这一句
            //    就不是"同条件对账"了——它会同条件地把两侧一起放过的错算成对得上。
            let perfRow = try await database.optionalRow(
                """
                SELECT COALESCE(AVG(cpu_percent), 0) AS avg_cpu,
                       COALESCE(MAX(cpu_percent), 0) AS peak_cpu,
                       MAX(memory_bytes) AS peak_memory
                  FROM \(StoreSchema.Table.perfSamples)
                 WHERE timestamp >= ? AND timestamp <= ?
                   AND session_id IS NOT NULL
                """,
                arguments: endpoints
            )
            check("CPU 均值/峰值",
                  shown: "\(Self.seconds(stats.averageCPUPercent)) / \(Self.seconds(stats.peakCPUPercent))",
                  queried: "\(Self.seconds(perfRow?.double("avg_cpu") ?? -1)) / \(Self.seconds(perfRow?.double("peak_cpu") ?? -1))",
                  condition: "perf_samples.timestamp ∈ [起, 止] 且 session_id 非 NULL（主体锁，#96）")
            check("峰值内存", shown: "\(stats.peakMemoryBytes)",
                  queried: "\((perfRow?.uint64("peak_memory") ?? 0))",
                  condition: "perf_samples.timestamp ∈ [起, 止] 且 session_id 非 NULL 的 MAX(memory_bytes)")

            // ⑥ 风险（含高风险数）
            let riskRow = try await database.optionalRow(
                """
                SELECT COUNT(*) AS total_count,
                       COALESCE(SUM(CASE WHEN level_rank >= ? THEN 1 ELSE 0 END), 0) AS high_count
                  FROM \(StoreSchema.Table.riskEvents)
                 WHERE timestamp >= ? AND timestamp <= ?
                """,
                arguments: [.integer(Int64(RiskLevel.high.rank))] + endpoints
            )
            check("风险", shown: "\(stats.riskEventCount)（高 \(stats.highRiskEventCount)）",
                  queried: "\(riskRow?.int("total_count") ?? -1)（高 \(riskRow?.int("high_count") ?? -1)）",
                  condition: "risk_events.timestamp ∈ [起, 止]")

            // ⑦ 柱图合计（事件数）：载荷里是"每格一条"，直查是"整段一条"，两者必须同号。
            let eventCount = try await database.scalarInt(
                "SELECT COUNT(*) FROM \(StoreSchema.Table.events) WHERE timestamp >= ? AND timestamp <= ?",
                arguments: endpoints
            ) ?? -1
            check("柱图事件合计", shown: "\(stats.hourlyActivity.reduce(0) { $0 + $1.eventCount })",
                  queried: "\(eventCount)",
                  condition: "events.timestamp ∈ [起, 止]（分桶合计 == 直查总数）")

            // ⑧ 「当前状态」那一格：全表快照，**两档必须同一个数**（裁定 3 的分组前提）。
            let runningSnapshot = try await database.scalarInt(
                "SELECT COUNT(*) FROM \(StoreSchema.Table.agents) WHERE state = ?",
                arguments: [.text(AgentRunState.running.rawValue)]
            ) ?? -1
            check("当前状态·活跃 Agent（全表快照）",
                  shown: "\(stats.runningAgentSnapshotCount)", queried: "\(runningSnapshot)",
                  condition: "agents.state = 'running'，**不带窗口条件**")
            #expect(stats.runningAgentSnapshotCount == runningSnapshot,
                    "「\(tier)」档：快照读数被窗口影响了 ⇒ 它不该进时段累计那一组")

            if ProcessInfo.processInfo.environment["AIOBS_DASHBOARD_RECONCILE"] != nil {
                print("── #75 对账单：档位「\(tier)」 窗口 \(readableWindow)"
                      + "（SQL 绑定秒值 \(endpoints.map { "\($0)" }.joined(separator: " / "))")
                for line in lines {
                    print("   [\(line.cell)] 界面=\(line.shown)  直查=\(line.queried)  条件=\(line.condition)")
                }
            }
        }
    }

    /// 浮点读数按毫秒级对齐：SQL 侧与 Swift 侧的加法次序不同，
    /// 逐位比 `Double` 会把"其实对得上"的账报成红账（真值差在 1e-12 量级）。
    private static func seconds(_ value: Double) -> String {
        String(format: "%.3f", value)
    }
}
