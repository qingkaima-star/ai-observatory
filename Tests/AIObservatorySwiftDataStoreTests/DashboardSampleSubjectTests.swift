//
//  DashboardSampleSubjectTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: 总控接手 ws/subject（#96）
//  ─────────────────────────────────────────────────────────
//  #96 要钉的是首页那一格 CPU 的**主体**：它只该算**归到会话的 Agent 采样**。
//
//  为什么这是"锁"而不是"顺手加个过滤"：
//    · `perf_samples` 里 `session_id` 为 NULL 的行是**常态不是异常** —— 引擎每轮给每个 Agent 落一条
//      采样，归属靠 `ObservatoryEngine+Ingestion.swift` 里那句 `sessionID(forAgentID:)`，
//      而它的返回类型就是 `UUID?`（`SessionLifecycleManager.swift:336`）。Agent 还没归到会话
//      （刚起来、或归属没解出来）时，那一轮的 CPU 就是无主的。
//    · 无主行放进来，这格会无声地从"被观测 Agent 的 CPU"变成"Agent + 无主样本"，
//      而且**不会有任何一格报错**。整机 CPU 在另一张表（`system_perf`），本来就不该被混进来。
//    · 同一个 `dashboardPerformanceRollup` 一次扫描同时喂**格子与柱图**（SQLite 侧两条 SQL 共用
//      同一个 `perfFilter`；SwiftData 侧同一个 descriptor 的分块扫描），所以这一把锁必须
//      同时钉住两个消费者 —— 本文件两样都断，只断一个就等于给"只改一处"留缝。
//
//  期望值全部手推，不抄实现：三个有归属的采样 cpu = 10 / 20 / 30、内存 = 1000 / 2000 / 9000；
//  两个无主采样故意做得**极大**（cpu 900 / 1000、内存 900 000 / 1 000 000），
//  这样"锁没生效"必然改变读数，而不是恰好算出同一个数。
//  `fixtureStillDiscriminates` 再显式钉一次这件事（哪天有人挪夹具让两边撞成同一个数，那条先红）。
//
//  两侧后端各跑一遍（SQLite / SwiftData 同一条谓词，同 ICR-0007 那条护栏的形状）。
//  时刻全部固定（不读墙钟），并带一条"离当地零点够远"的夹具守卫。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatorySwiftDataStore

// MARK: - Fixture

private enum SubjectFixture {
    /// 一个固定时刻（ReferenceDate 秒），刻意落在当地下午：整点下取与当日零点不是同一时刻。
    static let settlement = Date(timeIntervalSinceReferenceDate: 800_100_000)
    static let agentID = UUID()
    static let sessionID = UUID()
    /// 合成项目路径（口径见 AGENTS.md §7 与 `Scripts/verify.sh` 4/4：仓里只准出现 `/Users/dev/…`）。
    static let project = "/Users/dev/Projects/Subject"

    /// 第 `hours` 小时前。
    static func ago(_ hours: Double) -> Date {
        settlement.addingTimeInterval(-hours * 3600)
    }

    /// 六小时窗口，右端点即结算时刻 ⇒ 五个采样各占一个整点桶（间隔恰好 1 h）。
    static var window: DateRangeFilter { .lastHours(6, now: settlement) }

    /// 挂在会话上的三条：cpu 10 / 20 / 30，内存 1000 / 2000 / 9000。
    static let owned: [(hour: Double, cpu: Double, memory: UInt64)] = [
        (0, 10, 1_000), (1, 20, 2_000), (3, 30, 9_000),
    ]
    /// 无主的两条：值刻意极大，而且**各自独占一个整点桶**（柱图那一格的判据要靠这个）。
    static let orphan: [(hour: Double, cpu: Double, memory: UInt64)] = [
        (2, 900, 900_000), (4, 1000, 1_000_000),
    ]

    /// 手推真值：只算有归属的那三条。均值 (10+20+30)/3 = 20。
    static let expectedAverageCPU: Double = 20
    static let expectedPeakCPU: Double = 30
    static let expectedPeakMemory: UInt64 = 9_000
    /// 锁失效（无主行一起算）会得到的数：(10+20+30+900+1000)/5 = 392。
    static let averageCPUWithoutLock: Double = 392
    static let peakCPUWithoutLock: Double = 1000
    static let peakMemoryWithoutLock: UInt64 = 1_000_000

    static var samples: [PerformanceSample] {
        var rows: [PerformanceSample] = []
        for row in owned {
            let stamp = ago(row.hour)
            let cpu = row.cpu
            let memory = row.memory
            rows.append(PerformanceSample(
                timestamp: stamp, sessionID: sessionID, agentID: agentID,
                cpuPercent: cpu, memoryBytes: memory
            ))
        }
        for row in orphan {
            let stamp = ago(row.hour)
            let cpu = row.cpu
            let memory = row.memory
            rows.append(PerformanceSample(
                timestamp: stamp, sessionID: nil, agentID: agentID,
                cpuPercent: cpu, memoryBytes: memory
            ))
        }
        return rows
    }

    static let sessions: [AgentSession] = [
        AgentSession(
            id: sessionID, displayIndex: 3, kind: .claudeCode, agentID: agentID,
            title: "有归属的会话", projectPath: project,
            startedAt: ago(5), outcome: .running
        ),
    ]

    static let agents: [AgentInstance] = [
        AgentInstance(
            id: agentID, kind: .claudeCode, pid: 4_101, displayName: "claude",
            executablePath: "/usr/local/bin/claude", workingDirectory: project,
            startedAt: ago(5), lastSeenAt: settlement, state: .running,
            cpuPercent: 10, memoryBytes: 1_000
        ),
    ]
}

/// 两个真后端 + 同一批种子（一次构造、多条用例复用，避免每个断言重开一遍库）。
private struct Backends {
    let sqlite: ObservatoryStore
    let swiftData: SwiftDataObservatoryStore

    static func open() async throws -> Backends {
        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        for store in [AnyStore(sqlite), AnyStore(swiftData)] {
            try await store.seed()
        }
        return Backends(sqlite: sqlite, swiftData: swiftData)
    }

    private struct AnyStore {
        private let inner: any ObservatoryWriting
        init(_ store: some ObservatoryWriting) { inner = store }

        func seed() async throws {
            try await inner.upsertAgents(SubjectFixture.agents)
            try await inner.upsertSessions(SubjectFixture.sessions)
            for sample in SubjectFixture.samples { await inner.append(sample) }
            await inner.flush()
        }
    }
}

// MARK: - 主体锁

@Suite("Dashboard 性能读数：#96 的主体锁（只算归到会话的采样）", .serialized)
struct DashboardSampleSubjectTests {

    /// 格子那一读：均值 / 峰值 CPU / 峰值内存三个数都只认有归属的行。
    @Test("均值、峰值 CPU、峰值内存 = 手推的「只算有归属」三个数（两个后端各一遍）")
    func rollupCountsOnlyAttributedSamples() async throws {
        let backends = try await Backends.open()
        let pairs: [(name: String, stats: DashboardStats)] = [
            ("sqlite", try await backends.sqlite.dashboardStats(
                settledAt: SubjectFixture.settlement, within: SubjectFixture.window)),
            ("swiftData", try await backends.swiftData.dashboardStats(
                settledAt: SubjectFixture.settlement, within: SubjectFixture.window)),
        ]
        for pair in pairs {
            let stats = pair.stats
            // ⚠️ 判据消息只用**一条**插值串：`#expect` 的第二参数是 `Comment?`，
            // `"…" + "…"` 出来的是 `String`，转换不了（编译器直接拒绝整条用例）。
            #expect(stats.averageCPUPercent == SubjectFixture.expectedAverageCPU,
                    """
                    \(pair.name)：CPU 均值 \(stats.averageCPUPercent) ≠ 手推 \(SubjectFixture.expectedAverageCPU)；\
                    把两条无主采样一起算是 \(SubjectFixture.averageCPUWithoutLock) ⇒ 主体锁没生效
                    """)
            #expect(stats.peakCPUPercent == SubjectFixture.expectedPeakCPU,
                    """
                    \(pair.name)：峰值 CPU \(stats.peakCPUPercent) ≠ 手推 \(SubjectFixture.expectedPeakCPU)；\
                    无主那两条是 900 / 1000，混进来峰值会是 \(SubjectFixture.peakCPUWithoutLock)
                    """)
            #expect(stats.peakMemoryBytes == SubjectFixture.expectedPeakMemory,
                    """
                    \(pair.name)：峰值内存 \(stats.peakMemoryBytes) ≠ 手推 \(SubjectFixture.expectedPeakMemory)；\
                    无主那两条是 900000 / 1000000，混进来会是 \(SubjectFixture.peakMemoryWithoutLock)
                    """)
        }
    }

    /// 柱图那一读：与格子同源（同一条锁），但它是**另一个消费者** ⇒ 单独钉。
    /// 两个无主采样各自独占一个整点桶 ⇒ 锁失效时那两格会分别冒出 900 / 1000，
    /// 而不是只在合计里漂一点数（这才分得清"锁没生效"与"桶算错了"）。
    @Test("柱图每桶的 CPU 均值同样不含无主采样（那两个独占桶必须是 0）")
    func bucketsExcludeOrphanSamples() async throws {
        let backends = try await Backends.open()
        let buckets = try await backends.sqlite.dashboardStats(
            settledAt: SubjectFixture.settlement, within: SubjectFixture.window).hourlyActivity
        let latest = try #require(buckets.map(\.hour).max(), "六小时窗口一个桶都没有")
        // 桶序号 = 距锚点的整点数；`ago(k)` 的采样落在 `latest - k`（彼此间隔恰好 1 h）。
        let expected: [(k: Int, cpu: Double)] = [(0, 10), (1, 20), (2, 0), (3, 30), (4, 0)]
        for entry in expected {
            let found = try #require(
                buckets.first { $0.hour == latest - entry.k },
                "序号 \(latest - entry.k) 那一格没铺出来（铺到 \(latest) 为止，共 \(buckets.count) 格）"
            )
            #expect(found.cpuAverage == entry.cpu,
                    """
                    距最新格 \(entry.k) 小时的桶应 \(entry.cpu)，实得 \(found.cpuAverage)；\
                    k = 2 / 4 两格只有无主采样 ⇒ 非 0 就是主体锁失效
                    """)
        }
    }

    /// 反空转（①「无主行确实写进去了」）：库里五条，其中两条 `session_id IS NULL`。
    /// 少了这一格，上面两条断言可能只是因为**根本没写出无主行**而绿。
    @Test("夹具真的落库：五条采样、两条无主（两个后端各一遍）")
    func orphanSamplesAreReallyStored() async throws {
        let backends = try await Backends.open()
        let nullCount = try await backends.sqlite.database.scalarInt(
            "SELECT COUNT(*) FROM \(StoreSchema.Table.perfSamples) WHERE session_id IS NULL"
        )
        #expect(nullCount == SubjectFixture.orphan.count,
                "SQLite：无主采样应 \(SubjectFixture.orphan.count) 条，实得 \(String(describing: nullCount))")
        let sqliteTotal = try await backends.sqlite.rowCount(table: StoreSchema.Table.perfSamples)
        #expect(sqliteTotal == SubjectFixture.samples.count,
                "SQLite：采样总数应 \(SubjectFixture.samples.count)，实得 \(sqliteTotal)")

        let swiftTotal = try await backends.swiftData.rowCount(table: "perf_samples")
        // SwiftData 侧没有 `session_id IS NULL` 的直查口，改用减法：全表条数 − 该会话命中的条数。
        let attributed = try await backends.swiftData.performanceSamples(sessionID: SubjectFixture.sessionID)
        #expect(swiftTotal == SubjectFixture.samples.count,
                "SwiftData：采样总数应 \(SubjectFixture.samples.count)，实得 \(swiftTotal)")
        #expect(attributed.count == SubjectFixture.owned.count,
                "SwiftData：挂在会话上的应 \(SubjectFixture.owned.count) 条，实得 \(attributed.count)")
        #expect(swiftTotal - attributed.count == SubjectFixture.orphan.count,
                """
                SwiftData：无主行 \(swiftTotal - attributed.count) 条 ≠ SQLite 侧的 \
                \(SubjectFixture.orphan.count) 条 ⇒ 夹具在某一侧退化了
                """)
    }

    /// 反空转（②「锁与不锁必须是两个数」）：夹具挪动后若两边撞成同一个数，上面的断言就白写了。
    @Test("夹具仍有区分度：锁与不锁算出来必须是两个数")
    func fixtureStillDiscriminates() {
        #expect(SubjectFixture.averageCPUWithoutLock != SubjectFixture.expectedAverageCPU,
                "夹具退化了：把无主采样一起算与只算有归属是同一个数")
        #expect(SubjectFixture.peakCPUWithoutLock > SubjectFixture.expectedPeakCPU,
                "夹具退化了：无主行的 CPU 不比有归属的大 ⇒ 峰值那一格测不出锁")
        #expect(SubjectFixture.peakMemoryWithoutLock > SubjectFixture.expectedPeakMemory,
                "夹具退化了：无主行的内存不比有归属的大 ⇒ 内存那一格测不出锁")
    }

    /// 结算时刻若落在当地零点后第一小时内，"整点下取"与"当日零点"就是同一时刻，
    /// 本文件的桶序号判据会集体空转（同 `DashboardRangeParityTests` 那条守卫）。
    @Test("夹具的结算时刻离当地零点够远（否则桶判据空转）")
    func settlementIsAwayFromLocalMidnight() {
        let calendar = Calendar.current
        let hour = calendar.component(.hour, from: SubjectFixture.settlement)
        let flooredToHour = calendar.date(
            from: calendar.dateComponents([.year, .month, .day, .hour], from: SubjectFixture.settlement)
        ) ?? .distantPast
        #expect(flooredToHour != calendar.startOfDay(for: SubjectFixture.settlement),
                "结算时刻落在当地 \(String(format: "%02d", hour)) 时：整点下取与当日零点是同一时刻")
    }
}
