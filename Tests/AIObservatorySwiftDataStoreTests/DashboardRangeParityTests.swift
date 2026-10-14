//
//  DashboardRangeParityTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: ws/range（#75）
//  ─────────────────────────────────────────────────────────
//  #75 的三件事各钉一枚：
//    A. **窗口真进取数**：换窗口必须换读数。契约上那条"退化成单日"的默认实现
//       （`ServiceProtocols.swift` 的 `dashboardStats(settledAt:within:)`）是**无声**的——
//       真后端忘了重写只会让数字偏小、不会报错，所以这里用 1 h / 24 h / 72 h / 7 d 四档
//       逐格钉住两个真后端（SQLite 与 SwiftData 一起跑，同 ICR-0007 那条护栏的形状）。
//       再加一条 `sevenDayWindowIsNotASingleDay`：7 天档的六格对上 168 小时的量，
//       且**严格大于**同一批数据在「今天」档下的六格 —— 那就是"还剩 Dashboard 把区间压成
//       某一天"这条派单原话的反证。
//    B. **两侧同口径**：同一窗口、同一批数据，两份载荷必须逐字段相等（含分桶序号、桶序同序）。
//       `bothBackendsAgreeOnEveryProductTier` 按产品那六档逐个比整份 `DashboardStats`。
//    C. **换档与锚点**（裁定 9）：≤ 36 h 小时桶、> 36 h 自然日桶；
//       日档桶序号是"自结算日零点起、带符号的天偏移"，界面按同一条规则还原日期。
//       「全部」档（`.unbounded`）没有起点，这一档单独钉：改前把锚点塞进载荷的那版在这里
//       推不出标签，所以 `unboundedWindowCoversAllDays` 走「序号 → 日期 → 当天条数」的闭环，
//       锚点偏一天就红（而不是只比一个合计）。
//    D. 期望值不是抄实现的：每个窗口都同时给一份**手算真值**（`truth`），
//       实现算一遍、这里按声明式条件数一遍，两边对不上就红。
//       SQL 侧的"同条件直查"那一半在同形状的用例里：
//       `Tests/AIObservatoryEngineTests/DashboardSixCellSQLReconciliationTests.swift`。
//
//  时刻全部固定（不读墙钟），夏令时无关。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryStore
import AIObservatorySwiftDataStore

// MARK: - Fixture

/// 一个「连续 100 小时、每小时一条事件/一次文件变更/一条采样」的夹具，
/// 加两场会话（一场跨窗口、一场在窗口内）与三条风险。
private enum RangeFixture {
    /// 2026-05-09 前后的一个固定时刻（ReferenceDate 秒），**刻意取当地下午**：
    ///   · 不取整点 ⇒ "日档锚点 = 结算日零点"这件事是真的在被测，而不是被整点巧合掩盖；
    ///   · 更不能落在当地零点后的第一小时内 ⇒ 那一小时里 `startOfDay` 与"整点下取"是同一个
    ///     时刻，把日档锚点错写成 `floorToHour` 也测不出来（变异检查 M5 实测溜过去过一次）。
    ///     下面 `settlementIsAwayFromLocalMidnight` 那条守卫就是钉这件事的。
    static let settlement = Date(timeIntervalSinceReferenceDate: 800_086_800)

    /// 第 `hours` 小时前（负数就是之后，夹具不用）。
    static func ago(_ hours: Double) -> Date {
        settlement.addingTimeInterval(-hours * 3600)
    }

    /// 窗口：`hours` 小时宽，右端点就是结算时刻。
    static func window(_ hours: Double) -> DateRangeFilter {
        DateRangeFilter(start: ago(hours), end: settlement)
    }

    static let oneHour = window(1)
    static let twentyFourHours = window(24)
    static let thirtySixHours = window(36)
    static let thirtySevenHours = window(37)
    static let seventyTwoHours = window(72)
    static let unbounded = DateRangeFilter.unbounded

    /// 事件 / 文件变更 / 性能采样：0…99 小时前各一条（第 0 小时前 = 结算时刻本身）。
    static let horizon = 100.0

    static let agentID = UUID()
    static let sessionID = UUID()
    static let outsideSessionID = UUID()
    /// 合成项目路径（口径见 AGENTS.md §7 与 `Scripts/verify.sh` 4/4：仓里只准出现 `/Users/dev/…`）。
    static let project = "/Users/dev/Projects/Range"

    /// 逐条构造：每步先落成带类型的常量再交给初始化器。
    /// （多参数 + 满屏默认值的域模型初始化器直接内联插值，会让类型检查
    /// 退化成" unable to type-check in reasonable time"——这是写法问题不是设计问题。）
    static var events: [TimelineEvent] {
        var rows: [TimelineEvent] = []
        for hour in 0..<Int(horizon) {
            let stamp = ago(Double(hour))
            let kind = OperationKind.fileModified
            rows.append(TimelineEvent(
                timestamp: stamp,
                sessionID: sessionID,
                agentID: agentID,
                agentKind: AgentKind.claudeCode,
                kind: kind,
                title: "事件 \(hour)",
                summary: "第 \(hour) 小时前",
                filePath: "\(project)/Sources/F\(hour).swift",
                riskLevel: RiskLevel.low,
                projectPath: project
            ))
        }
        return rows
    }

    static var fileChanges: [FileChange] {
        var rows: [FileChange] = []
        for hour in 0..<Int(horizon) {
            let stamp = ago(Double(hour))
            let kind: FileChangeKind = hour % 3 == 0 ? .created : (hour % 3 == 1 ? .modified : .deleted)
            rows.append(FileChange(
                path: "\(project)/Sources/F\(hour).swift",
                kind: kind,
                timestamp: stamp,
                agentID: agentID,
                sessionID: sessionID,
                agentKind: AgentKind.claudeCode,
                projectPath: project
            ))
        }
        return rows
    }

    static var performanceSamples: [PerformanceSample] {
        var rows: [PerformanceSample] = []
        for hour in 0..<Int(horizon) {
            let stamp = ago(Double(hour))
            let cpu = Double(hour % 7) * 10
            let memory = UInt64(1_000_000 * (hour + 1))
            rows.append(PerformanceSample(
                timestamp: stamp,
                sessionID: sessionID,
                agentID: agentID,
                cpuPercent: cpu,
                memoryBytes: memory
            ))
        }
        return rows
    }

    static var commands: [CommandRecord] {
        var rows: [CommandRecord] = []
        for hour in 0..<Int(horizon) {
            let stamp = ago(Double(hour))
            let failed = hour % 5 == 0
            let outcome: CommandOutcome = failed ? .failure : .success
            rows.append(CommandRecord(
                executable: "tool",
                arguments: ["--step", "\(hour)"],
                agentID: agentID,
                sessionID: sessionID,
                agentKind: AgentKind.claudeCode,
                startedAt: stamp,
                endedAt: stamp.addingTimeInterval(2),
                exitCode: failed ? 1 : 0,
                outcome: outcome,
                projectPath: project
            ))
        }
        return rows
    }

    static let sessions: [AgentSession] = [
        // 窗口内新建：跨过结算时刻，用来测"未结算会话算到 settledAt"。
        AgentSession(
            id: sessionID, displayIndex: 7, kind: .claudeCode, agentID: agentID,
            title: "窗口内的会话", projectPath: project,
            startedAt: ago(6), outcome: .running
        ),
        // 窗口外新建（120 小时前起，跑了 30 小时）：任何一档窗口都不该数到它。
        AgentSession(
            id: outsideSessionID, displayIndex: 8, kind: .openAICodex, agentID: agentID,
            title: "窗口外的老会话", projectPath: project,
            startedAt: ago(120), endedAt: ago(90), outcome: .success
        ),
    ]

    static let risks: [RiskEvent] = [
        RiskEvent(
            timestamp: ago(2), level: .critical, category: .massDeletion,
            title: "批量删除", detail: "rm -rf 命中产物目录",
            agentID: agentID, agentKind: .claudeCode, sessionID: sessionID,
            command: "rm -rf ./out", filePaths: ["\(project)/out"],
            requiresConfirmation: true, matchedRuleID: "R-1"
        ),
        RiskEvent(
            timestamp: ago(30), level: .high, category: .dangerousCommand,
            title: "强推", detail: "", agentID: agentID, agentKind: .claudeCode,
            sessionID: sessionID, command: "git push --force"
        ),
        RiskEvent(
            timestamp: ago(80), level: .low, category: .unknown,
            title: "低危", detail: "", agentID: agentID, agentKind: .claudeCode,
            sessionID: sessionID
        ),
    ]

    /// 此刻在跑的 Agent（当前状态快照的唯一来源）。
    static let agents: [AgentInstance] = [
        AgentInstance(
            id: agentID, kind: .claudeCode, pid: 4_001, displayName: "claude",
            executablePath: "/usr/local/bin/claude", workingDirectory: project,
            startedAt: ago(200), lastSeenAt: settlement, state: .running,
            cpuPercent: 11, memoryBytes: 200_000_000
        ),
        AgentInstance(
            id: UUID(), kind: .openAICodex, pid: 5_001, displayName: "codex",
            executablePath: "/usr/local/bin/codex", workingDirectory: project,
            startedAt: ago(200), lastSeenAt: settlement, state: .idle,
            cpuPercent: 3, memoryBytes: 100_000_000
        ),
    ]
}

/// 一个窗口的**手算真值**：全部用声明式条件数出来，不抄实现。
private struct WindowTruth {
    let events: Int
    let filesModified: Int
    let filesCreated: Int
    let filesDeleted: Int
    let commands: Int
    let failedCommands: Int
    let risks: Int
    let highRisks: Int
    let sessions: Int

    static func compute(_ window: DateRangeFilter) -> WindowTruth {
        let f = RangeFixture.self
        func inside(_ date: Date) -> Bool { window.contains(date) }
        return WindowTruth(
            events: f.events.filter { inside($0.timestamp) }.count,
            filesModified: f.fileChanges.filter { $0.kind == .modified && inside($0.timestamp) }.count,
            filesCreated: f.fileChanges.filter { $0.kind == .created && inside($0.timestamp) }.count,
            filesDeleted: f.fileChanges.filter { $0.kind == .deleted && inside($0.timestamp) }.count,
            commands: f.commands.filter { inside($0.startedAt) }.count,
            failedCommands: f.commands.filter { inside($0.startedAt) && $0.outcome == .failure }.count,
            risks: f.risks.filter { inside($0.timestamp) }.count,
            highRisks: f.risks.filter { inside($0.timestamp) && $0.level >= .high }.count,
            sessions: f.sessions.filter { inside($0.startedAt) }.count
        )
    }
}

/// 两个真后端 + 它们的种子。一次构造、多条用例复用（避免每个断言重开一遍库）。
private struct Backends {
    let sqlite: ObservatoryStore
    let swiftData: SwiftDataObservatoryStore

    static func open() async throws -> Backends {
        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        for store in [AnySendableStore(sqlite), AnySendableStore(swiftData)] {
            try await store.seed()
        }
        return Backends(sqlite: sqlite, swiftData: swiftData)
    }

    /// 同一个窗口在两个后端各取一次读数（用例按 name 分辨是哪一侧红了）。
    func stats(within window: DateRangeFilter, settledAt: Date = RangeFixture.settlement) async throws
        -> [(name: String, stats: DashboardStats)] {
        [
            ("sqlite", try await sqlite.dashboardStats(settledAt: settledAt, within: window)),
            ("swiftData", try await swiftData.dashboardStats(settledAt: settledAt, within: window)),
        ]
    }

    private struct AnySendableStore {
        private let inner: any ObservatoryWriting
        init(_ store: some ObservatoryWriting) { inner = store }

        func seed() async throws {
            try await inner.upsertAgents(RangeFixture.agents)
            try await inner.upsertSessions(RangeFixture.sessions)
            for event in RangeFixture.events { await inner.append(event) }
            for change in RangeFixture.fileChanges { await inner.append(change) }
            for command in RangeFixture.commands { await inner.append(command) }
            for sample in RangeFixture.performanceSamples { await inner.append(sample) }
            try await inner.recordRisks(RangeFixture.risks)
            await inner.flush()
        }
    }
}

// MARK: - A. 窗口真进取数（默认实现漏重写当场红）

@Suite("Dashboard 区间取数：#75 的窗口必须真的进查询", .serialized)
struct DashboardRangeWindowTests {

    /// 每个窗口给一份手算真值 ⇒ 这条用例同时是"六格数字 ↔ 同条件 SQL 直查"的最小对账器。
    @Test("六项时段累计 = 手算真值，且随窗口变（两个后端各跑一遍）", arguments: [
        ("1 h", 1.0), ("24 h", 24.0), ("72 h", 72.0), ("7 d", 168.0),
    ])
    func everyMetricTracksTheWindow(label: String, hours: Double) async throws {
        let backends = try await Backends.open()
        let window = RangeFixture.window(hours)
        let truth = WindowTruth.compute(window)
        let settledAt = RangeFixture.settlement

        let sqlite = try await backends.sqlite.dashboardStats(settledAt: settledAt, within: window)
        let swiftData = try await backends.swiftData.dashboardStats(settledAt: settledAt, within: window)

        for (name, stats) in [("sqlite", sqlite), ("swiftData", swiftData)] {
            #expect(stats.hourlyActivity.reduce(0) { $0 + $1.eventCount } == truth.events,
                    "\(name) / \(label)：事件桶合计 \(stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }) ≠ 直查 \(truth.events)")
            #expect(stats.filesModified == truth.filesModified, "\(name) / \(label) filesModified")
            #expect(stats.filesCreated == truth.filesCreated, "\(name) / \(label) filesCreated")
            #expect(stats.filesDeleted == truth.filesDeleted, "\(name) / \(label) filesDeleted")
            #expect(stats.commandsExecuted == truth.commands, "\(name) / \(label) commandsExecuted")
            #expect(stats.failedCommands == truth.failedCommands, "\(name) / \(label) failedCommands")
            #expect(stats.riskEventCount == truth.risks, "\(name) / \(label) riskEventCount")
            #expect(stats.highRiskEventCount == truth.highRisks, "\(name) / \(label) highRiskEventCount")
            #expect(stats.sessionCount == truth.sessions, "\(name) / \(label) sessionCount")
            #expect(stats.date == settledAt, "\(name) / \(label)：结算时刻没回传")
        }
    }

    @Test("换窄窗口读数必须变小（漏重写区间版 = 三档同值，当场红）")
    func narrowerWindowIsSmaller() async throws {
        let backends = try await Backends.open()
        let one = try await backends.stats(within: RangeFixture.oneHour)
        let day = try await backends.stats(within: RangeFixture.twentyFourHours)
        let three = try await backends.stats(within: RangeFixture.seventyTwoHours)
        for index in one.indices {
            let name = one[index].name
            let oneEvents = one[index].stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }
            let dayEvents = day[index].stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }
            let threeEvents = three[index].stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }
            #expect(oneEvents < dayEvents, "\(name)：1 h 与 24 h 的事件数一样（\(oneEvents)）⇒ 窗口没进查询")
            #expect(dayEvents < threeEvents, "\(name)：24 h 与 72 h 的事件数一样（\(dayEvents)）⇒ 窗口没进查询")
            #expect(day[index].stats.riskEventCount < three[index].stats.riskEventCount, "\(name)：风险数没随窗口变")
            #expect(day[index].stats.filesModified < three[index].stats.filesModified, "\(name)：文件数没随窗口变")
            #expect(day[index].stats.commandsExecuted < three[index].stats.commandsExecuted, "\(name)：命令数没随窗口变")
            // 会话只有两场：一场的 `started_at` 落在 6 h 前 ⇒ 24 h 与 72 h 两档都是 1，
            // 只有把它跟 1 h 档比才看得出"窗口在挪"（这正是日档与小时档的差别所在）。
            #expect(one[index].stats.sessionCount < three[index].stats.sessionCount, "\(name)：会话数没随窗口变")
        }
    }

    /// 「当前状态」快照：三种窗口下**必须一模一样**（它就不该看窗口）。
    @Test("活跃 Agent 快照不限窗口（当前状态 ≠ 时段累计）")
    func snapshotIgnoresWindow() async throws {
        let backends = try await Backends.open()
        let narrow = try await backends.stats(within: RangeFixture.oneHour)
        let wide = try await backends.stats(within: RangeFixture.seventyTwoHours)
        for index in narrow.indices {
            let name = narrow[index].name
            #expect(narrow[index].stats.activeAgentCount == 1, "\(name)：全表 running 应为 1")
            #expect(narrow[index].stats.activeAgentCount == wide[index].stats.activeAgentCount,
                    "\(name)：快照随窗口变了 ⇒ 它被当成时段累计在数")
            #expect(narrow[index].stats.runningAgentSnapshotCount == narrow[index].stats.activeAgentCount,
                    "\(name)：实名与旧名指向同一个数")
            // 快照 ≠ 窗口内出现过的会话数（后者是时段累计，两者不许互当对方）
            #expect(narrow[index].stats.runningAgentSnapshotCount != narrow[index].stats.sessionCount,
                    "\(name)：夹具退化了——快照与累计撞成同一个数，分组断言就白写了")
        }
    }

    /// ①「7 天档下的六格数字来自真区间，而不是来自某一天」的正证 + 反证：
    ///   · 正证：168 小时窗口的六个读数 == 该窗口的手算真值（含区间端点写在消息里）；
    ///   · 反证：同一批数据在「今天」档下的六个读数**必须更小**——若界面又把区间压成了一天
    ///     （`dashboardStats(for:)` 那条老路），两档会给出**一模一样**的数，这里当场红。
    /// 这就是 #75 派单原文「只剩 Dashboard 把区间压成一个 Date」那一条的判据。
    @Test("「7 天」档六格 = 168 小时的量，且不等于「今天」档六格")
    func sevenDayWindowIsNotASingleDay() async throws {
        let backends = try await Backends.open()
        let sevenDays = DateRangeFilter.lastHours(24 * 7, now: RangeFixture.settlement)
        let today = DateRangeFilter.today(RangeFixture.settlement)
        let wide = WindowTruth.compute(sevenDays)
        let narrow = WindowTruth.compute(today)
        let endpoints = "7 天档端点 \(sevenDays.start?.description ?? "nil") → \(sevenDays.end?.description ?? "nil")"

        let pairs = try await backends.stats(within: sevenDays)
        let singleDayReadings = try await backends.stats(within: today)
        for index in pairs.indices {
            let pair = pairs[index]
            let singleDay = singleDayReadings[index].stats
            // 正证：六格逐个对上"这个区间"的手算真值。
            #expect(pair.stats.hourlyActivity.reduce(0) { $0 + $1.eventCount } == wide.events,
                    "\(pair.name)：事件桶合计对不上 \(endpoints)")
            #expect(pair.stats.filesModified == wide.filesModified, "\(pair.name)：filesModified 对不上 \(endpoints)")
            #expect(pair.stats.filesCreated == wide.filesCreated, "\(pair.name)：filesCreated 对不上 \(endpoints)")
            #expect(pair.stats.filesDeleted == wide.filesDeleted, "\(pair.name)：filesDeleted 对不上 \(endpoints)")
            #expect(pair.stats.commandsExecuted == wide.commands, "\(pair.name)：commandsExecuted 对不上 \(endpoints)")
            #expect(pair.stats.failedCommands == wide.failedCommands, "\(pair.name)：failedCommands 对不上 \(endpoints)")
            #expect(pair.stats.riskEventCount == wide.risks, "\(pair.name)：riskEventCount 对不上 \(endpoints)")
            #expect(pair.stats.sessionCount == wide.sessions, "\(pair.name)：sessionCount 对不上 \(endpoints)")
            // 反证：某一天（「今天」档）的六格比 7 天档小 ⇒ 六格不可能是"某一天"的数。
            #expect(singleDay.hourlyActivity.reduce(0) { $0 + $1.eventCount } == narrow.events,
                    "\(pair.name)：「今天」档自己对不上今天的真值，反证不成立")
            #expect(narrow.events < wide.events, "夹具退化了：今天 == 7 天的事件数，档期区分不出来")
            #expect(singleDay.filesModified < pair.stats.filesModified,
                    "\(pair.name)：文件数在 7 天档没变大 ⇒ 六格还是某一天的数")
            #expect(singleDay.commandsExecuted < pair.stats.commandsExecuted,
                    "\(pair.name)：命令数在 7 天档没变大 ⇒ 六格还是某一天的数")
            #expect(singleDay.riskEventCount < pair.stats.riskEventCount,
                    "\(pair.name)：风险数在 7 天档没变大 ⇒ 六格还是某一天的数")
            #expect(singleDay.sessionCount < pair.stats.sessionCount,
                    "\(pair.name)：会话数在 7 天档没变大 ⇒ 六格还是某一天的数")
        }
    }

    /// 旧的单日入口 = 区间入口在 `.today` 下的特例（两侧后端同一条桥）。
    @Test("dashboardStats(for:) 与 today 窗口逐字段等值")
    func legacySingleDayIsTheTodayWindow() async throws {
        let backends = try await Backends.open()
        let settledAt = RangeFixture.settlement
        let today = DateRangeFilter.today(settledAt)
        let legacySQLite = try await backends.sqlite.dashboardStats(for: settledAt)
        let legacySwift = try await backends.swiftData.dashboardStats(for: settledAt)
        let bridged = try await backends.stats(within: today, settledAt: settledAt)
        #expect(legacySQLite == bridged[0].stats, "sqlite：单日版与 .today 窗口版不等值")
        #expect(legacySwift == bridged[1].stats, "swiftData：单日版与 .today 窗口版不等值")
        #expect(legacySQLite.hourlyActivity.reduce(0) { $0 + $1.eventCount }
                == WindowTruth.compute(today).events, "sqlite：单日版没落在「今天」这一格里")
    }
}

// MARK: - B/C. 换档、锚点与两侧同形

@Suite("Dashboard 分桶：#75 裁定 9 的换档与锚点", .serialized)
struct DashboardBucketTierTests {

    /// ≤ 36 h 小时桶、> 36 h 自然日桶；边界 36 h 本身留在小时档。
    @Test("换档阈值 36 h（含边界）")
    func tierSwitchAtThirtySixHours() async throws {
        let backends = try await Backends.open()
        let expected: [(DateRangeFilter, ActivityBucketSpan)] = [
            (RangeFixture.oneHour, .hourOfDay),
            (RangeFixture.twentyFourHours, .hourOfDay),
            (RangeFixture.thirtySixHours, .hourOfDay),
            (RangeFixture.thirtySevenHours, .naturalDay),
            (RangeFixture.seventyTwoHours, .naturalDay),
            (RangeFixture.unbounded, .naturalDay),
        ]
        for (window, span) in expected {
            for pair in try await backends.stats(within: window) {
                // 判据消息里不许对 `.unbounded` 写 `window.start!`：那正是本文件要钉的那个形状
                // （「全部」档没有起点），一崩就把"红"变成"整个用例进程挂了"。
                #expect(pair.stats.bucketSpan == span,
                        "\(pair.name)：窗口 \(String(describing: window.start))–\(String(describing: window.end)) 应给 \(span)，实得 \(pair.stats.bucketSpan)")
            }
        }
    }

    /// 日档锚点 = 结算日零点，序号是**带符号的天偏移**：今天 = 0，往前每天 -1。
    /// 界面（`DashboardModel.bucketStart(for:)`）按同一条规则还原日期，两侧不许各算一套。
    @Test("日档桶序号 = 自结算日零点起的天偏移（可负），且两侧逐格相同")
    func daySlotsAreSignedOffsetsFromSettlementDay() async throws {
        let backends = try await Backends.open()
        let pairs = try await backends.stats(within: RangeFixture.seventyTwoHours)
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: RangeFixture.settlement)
        let settlementSlot = calendar.dateComponents([.day], from: anchor, to: anchor).day ?? 0

        for pair in pairs {
            let slots = pair.stats.hourlyActivity.map(\.hour)
            #expect(slots == slots.sorted(), "\(pair.name)：桶序号没按时间升序返回")
            #expect(slots.max() == settlementSlot,
                    "\(pair.name)：日档最后一格应当是结算那天（\(settlementSlot)），实得 \(String(describing: slots.max()))")
            #expect((slots.min() ?? 0) < 0,
                    "\(pair.name)：72 h 窗口的日档必须往回数到前一天，序号里却没有负数 ⇒ 锚点认错了")
            // 每一格都真能被还原成一个日期，且还原后落在窗口里 —— 界面画轴就用这条。
            for slot in slots {
                let start = calendar.date(byAdding: .day, value: slot, to: anchor) ?? .distantPast
                let nextDay = calendar.date(byAdding: .day, value: 1, to: start) ?? start
                #expect(start < nextDay, "\(pair.name)：桶起点推不出下一天")
            }
        }
        #expect(pairs[0].stats.hourlyActivity == pairs[1].stats.hourlyActivity,
                "两侧的日档分桶逐格不同：\(pairs[0].stats.hourlyActivity) vs \(pairs[1].stats.hourlyActivity)")
    }

    /// 小时档：「今天」那档锚点 = 当日零点 ⇒ 序号恰好等于 0…23 的时（改造前的形状）。
    @Test("小时档逐格相同，且事件全落进格子（不丢数）")
    func hourTierBucketsMatchAcrossBackendsAndSumToWindow() async throws {
        let backends = try await Backends.open()
        for window in [RangeFixture.oneHour, RangeFixture.twentyFourHours] {
            let pairs = try await backends.stats(within: window)
            #expect(pairs[0].stats.hourlyActivity == pairs[1].stats.hourlyActivity,
                    "两侧小时档分桶不同")
            let truth = WindowTruth.compute(window)
            let total = pairs[0].stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }
            #expect(total == truth.events, "小时档桶合计 \(total) ≠ 直查 \(truth.events)")
        }
    }

    /// 「全部」档（`.unbounded`）没有窗口起点：锚点仍是**结算日零点**（结算时刻在载荷里，
    /// 界面自己复算），格子从最早有数据那天铺起。
    ///
    /// 这一格是前一手那个设计 bug 的回炉点：改前载荷里塞的是"从窗口起点推出来的锚点"，
    /// 「全部」档 `start == nil` ⇒ 锚点无从谈起（要么崩、要么整排标签错到别的日子去）。
    /// 所以这里的判据全部走「序号 → 日期 → 该日的事件条数」这条闭环：
    /// 序号错一格、锚点认错一天，逐格对数就会红，而不是只比一个总数。
    @Test("「全部」档：日桶、逐格对得上那一天、不虚构数据之外的格子、也不崩")
    func unboundedWindowCoversAllDays() async throws {
        let backends = try await Backends.open()
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: RangeFixture.settlement)
        // 最早的数据：第 99 小时前（`horizon - 1`）。它在**当地时区**落在结算日之前第几天，
        // 就是第一格的序号 —— 用 `Calendar` 数，不写 `(99 / 24)` 那种秒差（§5）。
        let earliest = RangeFixture.ago(RangeFixture.horizon - 1)
        let expectedFirst = calendar.dateComponents([.day], from: anchor,
                                                    to: calendar.startOfDay(for: earliest)).day ?? 0

        for pair in try await backends.stats(within: RangeFixture.unbounded) {
            let buckets = pair.stats.hourlyActivity
            #expect(pair.stats.bucketSpan == .naturalDay, "\(pair.name)：「全部」应为日档")
            #expect(!buckets.isEmpty, "\(pair.name)：「全部」档一格都没有")
            // ① 覆盖：合计 == 全部事件条数（「全部」= 无端点，一条都不该漏）。
            #expect(buckets.reduce(0) { $0 + $1.eventCount } == RangeFixture.events.count,
                    "\(pair.name)：「全部」档事件合计 \(buckets.reduce(0) { $0 + $1.eventCount }) ≠ \(RangeFixture.events.count)")
            // ② 连续、升序、且不多铺：第一格 = 最早数据那天，最后一格 = 结算那天（序号 0）。
            #expect(buckets.map(\.hour) == Array(expectedFirst...0),
                    "\(pair.name)：「全部」档格子应是连续的第 \(expectedFirst)…0 天，实得 \(buckets.map(\.hour))")
            // ③ **逐格**对数：序号还原成日期之后，那一格的事件数必须等于"当天新建的事件条数"。
            //    这一条才是"不错标"的正证：锚点偏一天、序号少一格，都会在这里对不上。
            for bucket in buckets {
                let dayStart = calendar.date(byAdding: .day, value: bucket.hour, to: anchor) ?? anchor
                let nextDay = calendar.date(byAdding: .day, value: 1, to: dayStart) ?? dayStart
                let expected = RangeFixture.events.filter {
                    $0.timestamp >= dayStart && $0.timestamp < nextDay
                }.count
                #expect(bucket.eventCount == expected,
                        "\(pair.name)：第 \(bucket.hour) 格（\(dayStart) 那天）应 \(expected) 条，实得 \(bucket.eventCount)")
            }
        }
    }

    /// 「今天」档：小时桶必须仍是**整 0…23 共 24 格**（改造前的形状）。
    /// 这一格盯的是右端点：`DateRangeFilter.today` 给的是**次日零点**，落在桶边界上，
    /// 补齐时不退一格就会吐 25 格；而初版实现反过来用 `min(终点, 结算时刻)`，
    /// 把"此刻之后"抹平，只吐到当前那一小时（16 格）——「今天」这张图本来就该画出还没来的那几个小时。
    @Test("「今天」档仍是 0…23 整 24 格（次日零点那个右端点要退一格）")
    func todayTierEmitsTwentyFourHourBuckets() async throws {
        let backends = try await Backends.open()
        for pair in try await backends.stats(within: .today(RangeFixture.settlement)) {
            #expect(pair.stats.bucketSpan == .hourOfDay, "\(pair.name)：「今天」档应为小时桶")
            #expect(pair.stats.hourlyActivity.map(\.hour) == Array(0...23),
                    "\(pair.name)：「今天」档不是整 24 格：\(pair.stats.hourlyActivity.map(\.hour))")
        }
    }

    /// 夹具自身的**区分度**守卫（写法同 `DashboardHourlyBucketParityTests` 里那条 UTC 判据）：
    /// 结算时刻若离当地零点太近，"日档锚点 = 零点"与"锚点 = 整点下取"会撞成同一个时刻，
    /// 本文件所有钉锚点的判据集体空转 —— 显式记一条 issue，不静默放行。
    @Test("夹具的结算时刻离当地零点够远（否则锚点判据空转）")
    func settlementIsAwayFromLocalMidnight() {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: RangeFixture.settlement)
        let flooredToHour = calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour], from: RangeFixture.settlement)
        ) ?? .distantPast
        #expect(flooredToHour != calendar.startOfDay(for: RangeFixture.settlement),
                "结算时刻落在当地 \(String(format: "%02d", hour)) 时：整点下取与当日零点是同一时刻，锚点判据测不出来")
    }

    /// ③「Store ↔ SwiftData 两侧对拍」的完整版：产品六档逐个跑，**整份载荷**必须逐字段相等，
    /// 且两侧的桶序号都严格升序（同序）。既有用例只在个别档上比过 `hourlyActivity` 一个字段，
    /// 而"同值"要的是整份载荷 —— 少一个字段比，就等于给"只在一侧改口径"留了缝。
    @Test("产品六档逐个对拍：两侧整份载荷逐字段相等，桶序号同序")
    func bothBackendsAgreeOnEveryProductTier() async throws {
        let backends = try await Backends.open()
        // 六档 = `ObservatoryTimeRange` 的六个 case 折算出来的窗口（枚举在 UI 目标里，
        // 测试目标不依赖它，这里按 `dateRange(now:)` 的同一套折算式重建）。
        let windows: [DateRangeFilter] = [
            .today(RangeFixture.settlement),
            .lastHours(1, now: RangeFixture.settlement),
            .lastHours(6, now: RangeFixture.settlement),
            .lastHours(24, now: RangeFixture.settlement),
            .lastHours(24 * 7, now: RangeFixture.settlement),
            .unbounded,
        ]
        for window in windows {
            let pairs = try await backends.stats(within: window)
            let (sqlite, swiftData) = (pairs[0].stats, pairs[1].stats)
            let endpoints = "\(String(describing: window.start))–\(String(describing: window.end))"
            #expect(sqlite == swiftData, "两侧整份载荷在窗口 \(endpoints) 不等：\nsqlite=\(sqlite)\nswiftData=\(swiftData)")
            for pair in pairs {
                let slots = pair.stats.hourlyActivity.map(\.hour)
                #expect(slots == slots.sorted() && Set(slots).count == slots.count,
                        "\(pair.name)：窗口 \(endpoints) 的桶序号不是升序无重复：\(slots)")
            }
        }
    }

}
