//
//  InMemoryDashboardRangeGuardTests.swift
//  AIObservatoryCoreTests
//
//  Owner: ws/double（#95，台账 十点五「门禁在、射程不在」那一族的收口）
//  ─────────────────────────────────────────────────────────
//  #75 给区间版 `dashboardStats(settledAt:within:)` 在契约里留了一条退化桥
//  （`ServiceProtocols.swift` 的默认实现：区间版直接转调单日版）。两个真后端各自
//  重写了它，`DashboardRangeParityTests` 又以 1 h / 24 h / 7 d 三档钉住了那两个真后端
//  ——这一步是对的。**但测试替身没被钉住**：`InMemoryObservatoryService` 此前只实现
//  单日版 ⇒ 走桥 ⇒ 凡拿这个替身、又递非今天区间给 `DashboardModel` 的 UI 用例，
//  看到的其实永远是"某一天"的数（忘了重写是**无声的**）。
//
//  本文件把同一枚闸门对准替身：同一份夹具，1 小时 / 24 小时 / 7 天 三档必须给出
//  **互不相等**的读数（镜像 `DashboardRangeParityTests.narrowerWindowIsSmaller` 对真后端
//  的做法）。走桥时三档会全部塌成"结算那一刻所在的那一天"⇒ 逐格相等 ⇒ 当场红。
//
//  期望值是**手推**的（见 `Fixture` 里每个标量旁的推导），不是从实现反推的：
//  数据按"结算前多少小时"摆放，落不落某个窗口由那条相对窗口的端点一眼数得出来。
//  时刻全部固定（不读墙钟），夏令时无关。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 夹具（数据全部摆在"结算时刻前 0.5 / 12 / 48 / 120 小时"这四环上）

/// 三档窗口的端点全是相对结算时刻的（`.lastHours`），所以每一环落不落在某个窗口里
/// 只由"该环的小时数 < 窗口宽度"决定，与本机时区无关：
///   · 1 h  = { 0.5 }
///   · 24 h = { 0.5, 12 }
///   · 7 d(=168 h) = { 0.5, 12, 48, 120 }
private enum Fixture {
    /// 固定结算时刻（一个 2026 年 5 月的 ReferenceDate 秒，同 `DashboardRangeParityTests` 一族）。
    static let settlement = Date(timeIntervalSinceReferenceDate: 800_086_800)

    /// 结算前 `hours` 小时。
    static func ago(_ hours: Double) -> Date { settlement.addingTimeInterval(-hours * 3600) }

    static func window(_ hours: Double) -> DateRangeFilter {
        DateRangeFilter(start: ago(hours), end: settlement)
    }
    static let oneHour = window(1)
    static let twentyFourHours = window(24)
    static let sevenDays = window(24 * 7)

    static let agentID = UUID()
    static let sessionID = UUID()
    /// 合成项目路径（§7 / verify.sh 4/4：仓里只准出现 `/Users/dev/…`）。
    static let project = "/Users/dev/Projects/Double"

    /// 三环各建一场会话（长度手定，都是已闭合的，故 `duration` 不随结算时刻/墙钟变）：
    ///   · s1 起于 0.5 h 前、长 900 s   ⇒ 只进 1 h 档 ⇒ 三档累计分别 900 / 8100 / 22500
    ///   · s2 起于 12 h 前、长 7200 s   ⇒ 进 24 h 与 7 d
    ///   · s3 起于 48 h 前、长 14400 s  ⇒ 只进 7 d
    static let sessions: [AgentSession] = [
        AgentSession(id: sessionID, kind: .claudeCode, agentID: agentID, title: "近 30 分钟的会话",
                     projectPath: project, startedAt: ago(0.5), endedAt: ago(0.25), outcome: .success),
        AgentSession(kind: .claudeCode, agentID: agentID, title: "半天前",
                     projectPath: project, startedAt: ago(12), endedAt: ago(10), outcome: .success),
        AgentSession(kind: .claudeCode, agentID: agentID, title: "两天前",
                     projectPath: project, startedAt: ago(48), endedAt: ago(44), outcome: .success),
    ]

    /// 事件 / 文件 / 命令 / 风险 / 采样：四环各一条（0.5 / 12 / 48 / 120 小时前）。
    static let ages = [0.5, 12.0, 48.0, 120.0]

    static var events: [TimelineEvent] {
        ages.map { age in
            TimelineEvent(timestamp: ago(age), sessionID: sessionID, agentID: agentID,
                          agentKind: .claudeCode, kind: .fileModified, title: "事件 @\(age)",
                          summary: "环 \(age)", projectPath: project)
        }
    }

    static var fileChanges: [FileChange] {
        ages.map { age in
            FileChange(path: "\(project)/Sources/F@\(age).swift", kind: .modified, timestamp: ago(age),
                       agentID: agentID, sessionID: sessionID, agentKind: .claudeCode, projectPath: project)
        }
    }

    /// 命令四环各一条，失败那一条摆在 12 h 环 ⇒ failedCommands = 1 h:0 / 24 h:1 / 7 d:1。
    static var commands: [CommandRecord] {
        ages.map { age in
            let failed = age == 12.0
            return CommandRecord(executable: "tool", arguments: ["--age", "\(age)"],
                                 agentID: agentID, sessionID: sessionID, agentKind: .claudeCode,
                                 startedAt: ago(age), endedAt: ago(age).addingTimeInterval(2),
                                 exitCode: failed ? 1 : 0, outcome: failed ? .failure : .success,
                                 projectPath: project)
        }
    }

    /// 风险四环各一条，等级 low/high/critical/low ⇒ highRisk(≥high) = 1 h:0 / 24 h:1 / 7 d:2。
    static var risks: [RiskEvent] {
        let levels: [RiskLevel] = [.low, .high, .critical, .low]
        return zip(ages, levels).map { age, level in
            RiskEvent(timestamp: ago(age), level: level, category: .dangerousCommand,
                      title: "风险 @\(age)", detail: "", agentID: agentID, agentKind: .claudeCode,
                      sessionID: sessionID, command: "git push")
        }
    }

    /// 采样四环各一条，cpu = 10·序号、memory = 序号×1 MB：
    ///   · peakCPU = 1 h:10 / 24 h:20 / 7 d:40；avgCPU = 10 / 15 / 25；peakMem = 1 / 2 / 4 MB。
    static var performanceSamples: [PerformanceSample] {
        ages.enumerated().map { (i, age) in
            PerformanceSample(timestamp: ago(age), sessionID: sessionID, agentID: agentID,
                              cpuPercent: Double((i + 1) * 10), memoryBytes: UInt64(1_000_000 * (i + 1)))
        }
    }

    /// 当前状态快照的唯一来源：一场 running、一场 idle ⇒ 三档 `activeAgentCount` 恒为 1（它不该看窗口）。
    static let agents: [AgentInstance] = [
        AgentInstance(id: agentID, kind: .claudeCode, pid: 4_001, displayName: "claude",
                      executablePath: "/usr/local/bin/claude", workingDirectory: project,
                      startedAt: ago(200), lastSeenAt: settlement, state: .running,
                      cpuPercent: 11, memoryBytes: 200_000_000),
        AgentInstance(kind: .openAICodex, pid: 5_001, displayName: "codex",
                      executablePath: "/usr/local/bin/codex", workingDirectory: project,
                      startedAt: ago(200), lastSeenAt: settlement, state: .idle,
                      cpuPercent: 3, memoryBytes: 100_000_000),
    ]

    static func seededService() -> InMemoryObservatoryService {
        let service = InMemoryObservatoryService()
        service.seed(agents: agents, sessions: sessions, events: events,
                     fileChanges: fileChanges, commands: commands,
                     performance: performanceSamples, risks: risks)
        return service
    }
}

// MARK: - 守卫

@Suite("替身不许无声降级：内存参照实现的区间版必须真按窗口取数（#95）")
struct InMemoryDashboardRangeGuardTests {

    /// 主判据：同一份夹具，三档给出**互不相等**的读数。
    /// 走桥时（替身没实现区间版）三者全部塌成"结算那一刻所在的那一天"⇒ 逐格相等 ⇒ 红。
    /// 期望值全部手推（见上面 `Fixture` 的推导注释），不从实现反推。
    @Test("1 h / 24 h / 7 d 三档读数互不相等（走桥 = 三档同值，当场红）")
    func threeWindowsGiveThreeDifferentReadings() async throws {
        let service = Fixture.seededService()
        let settledAt = Fixture.settlement

        let one = try await service.dashboardStats(settledAt: settledAt, within: Fixture.oneHour)
        let day = try await service.dashboardStats(settledAt: settledAt, within: Fixture.twentyFourHours)
        let week = try await service.dashboardStats(settledAt: settledAt, within: Fixture.sevenDays)

        // 一份指纹（八个时段累计标量 + 事件桶合计）：三档两两不等。
        func fingerprint(_ s: DashboardStats) -> [String] {
            [
                "\(s.sessionCount)",
                "\(s.filesModified)",
                "\(s.commandsExecuted)",
                "\(s.riskEventCount)",
                "\(s.highRiskEventCount)",
                "\(s.peakCPUPercent)",
                "\(s.peakMemoryBytes)",
                "\(Int(s.totalActiveSeconds))",
                "\(s.hourlyActivity.reduce(0) { $0 + $1.eventCount })",
            ]
        }
        let f1 = fingerprint(one), f24 = fingerprint(day), f7 = fingerprint(week)
        #expect(f1 != f24, "1 h 与 24 h 读数逐格相同 ⇒ 窗口没进过滤（替身在走桥）：\(f1)")
        #expect(f24 != f7, "24 h 与 7 d 读数逐格相同 ⇒ 窗口没进过滤（替身在走桥）：\(f24)")
        #expect(f1 != f7, "1 h 与 7 d 读数逐格相同 ⇒ 窗口没进过滤（替身在走桥）：\(f1)")

        // 严格单调（换更窄的窗口读数必须更小），与真后端那条 `narrowerWindowIsSmaller` 同形。
        #expect(one.sessionCount < day.sessionCount && day.sessionCount < week.sessionCount,
                "会话数没随窗口单调变：\(one.sessionCount)/\(day.sessionCount)/\(week.sessionCount)")
        #expect(one.filesModified < day.filesModified && day.filesModified < week.filesModified,
                "文件数没随窗口单调变：\(one.filesModified)/\(day.filesModified)/\(week.filesModified)")
        #expect(one.riskEventCount < day.riskEventCount && day.riskEventCount < week.riskEventCount,
                "风险数没随窗口单调变：\(one.riskEventCount)/\(day.riskEventCount)/\(week.riskEventCount)")
    }

    /// 逐格手推真值：把三档的每个时段累计标量钉死，替"只是不相等"多钉一层"值对"。
    @Test("三档每个标量 = 手推真值（不是抄实现，是数环）")
    func eachWindowMatchesHandComputedTruth() async throws {
        let service = Fixture.seededService()
        let settledAt = Fixture.settlement

        let one = try await service.dashboardStats(settledAt: settledAt, within: Fixture.oneHour)
        let day = try await service.dashboardStats(settledAt: settledAt, within: Fixture.twentyFourHours)
        let week = try await service.dashboardStats(settledAt: settledAt, within: Fixture.sevenDays)

        // 1 h：只有 0.5 h 环入场（1 会话 / 1 事件 / 1 文件 / 1 命令 / 1 风险，且那条风险是 low、命令是成功）。
        #expect(one.sessionCount == 1)
        #expect(one.filesModified == 1)
        #expect(one.commandsExecuted == 1)
        #expect(one.failedCommands == 0)          // 失败在 12 h 环，1 h 档还没进来
        #expect(one.riskEventCount == 1)
        #expect(one.highRiskEventCount == 0)      // 首条风险是 low
        #expect(one.totalActiveSeconds == 900)    // 只 s1 = 900 s
        #expect(one.peakCPUPercent == 10)
        #expect(one.averageCPUPercent == 10)
        #expect(one.peakMemoryBytes == 1_000_000)
        #expect(one.hourlyActivity.reduce(0) { $0 + $1.eventCount } == 1)

        // 24 h：+ 12 h 环 ⇒ 会话 2、文件/命令/风险各 2、失败 1、高风险 1、时长 900+7200、peakCPU 20、peakMem 2MB。
        #expect(day.sessionCount == 2)
        #expect(day.filesModified == 2)
        #expect(day.commandsExecuted == 2)
        #expect(day.failedCommands == 1)
        #expect(day.riskEventCount == 2)
        #expect(day.highRiskEventCount == 1)
        #expect(day.totalActiveSeconds == 8100)
        #expect(day.peakCPUPercent == 20)
        #expect(day.averageCPUPercent == 15)      // (10+20)/2
        #expect(day.peakMemoryBytes == 2_000_000)
        #expect(day.hourlyActivity.reduce(0) { $0 + $1.eventCount } == 2)

        // 7 d：+ 48 h 与 120 h 两环 ⇒ 会话 3、文件/命令/风险各 4、失败仍 1、高风险 2、时长 22500、peakCPU 40。
        #expect(week.sessionCount == 3)
        #expect(week.filesModified == 4)
        #expect(week.commandsExecuted == 4)
        #expect(week.failedCommands == 1)
        #expect(week.riskEventCount == 4)
        #expect(week.highRiskEventCount == 2)
        #expect(week.totalActiveSeconds == 22500) // 900+7200+14400
        #expect(week.peakCPUPercent == 40)
        #expect(week.averageCPUPercent == 25)     // (10+20+30+40)/4
        #expect(week.peakMemoryBytes == 4_000_000)
        #expect(week.hourlyActivity.reduce(0) { $0 + $1.eventCount } == 4)
    }

    /// 分桶换档（#75 裁定 9）也必须在替身身上成立：≤ 36 h 小时桶、更宽自然日桶。
    /// 走桥时替身只会给"某一天"（永远小时桶），7 d 档就会红——顺带钉住"没在走桥"。
    @Test("换档与真后端同形：1 h / 24 h 小时桶，7 d 自然日桶")
    func bucketSpanTieringFollowsTheWindow() async throws {
        let service = Fixture.seededService()
        let settledAt = Fixture.settlement
        let one = try await service.dashboardStats(settledAt: settledAt, within: Fixture.oneHour)
        let day = try await service.dashboardStats(settledAt: settledAt, within: Fixture.twentyFourHours)
        let week = try await service.dashboardStats(settledAt: settledAt, within: Fixture.sevenDays)
        #expect(one.bucketSpan == .hourOfDay, "1 h 档应是小时桶")
        #expect(day.bucketSpan == .hourOfDay, "24 h 档（≤36 h）应是小时桶")
        #expect(week.bucketSpan == .naturalDay, "7 d 档（>36 h）应是自然日桶；仍是小时桶 = 替身没按窗口换档")
    }

    /// 「当前状态」那一族仍按契约既有口径：全表 `state = .running` 的快照，**与窗口无关**。
    /// 三档必须一模一样（= 1），而它又该和"窗口内会话数"是两回事（后者三档 1/2/3 在变）。
    @Test("活跃 Agent 快照不限窗口（当前状态 ≠ 时段累计）")
    func runningSnapshotIgnoresTheWindow() async throws {
        let service = Fixture.seededService()
        let settledAt = Fixture.settlement
        let one = try await service.dashboardStats(settledAt: settledAt, within: Fixture.oneHour)
        let day = try await service.dashboardStats(settledAt: settledAt, within: Fixture.twentyFourHours)
        let week = try await service.dashboardStats(settledAt: settledAt, within: Fixture.sevenDays)
        #expect(one.activeAgentCount == 1, "全表 running 应为 1")
        #expect(one.activeAgentCount == day.activeAgentCount
                    && day.activeAgentCount == week.activeAgentCount,
                "快照随窗口变了 ⇒ 它被当成时段累计在数（#75 拆开的正是这两类）")
        // 与"窗口内会话数"（时段累计，三档在变）不是一个东西。
        #expect(one.sessionCount == 1 && week.sessionCount == 3, "夹具退化：累计那侧也没随窗口动")
    }
}
