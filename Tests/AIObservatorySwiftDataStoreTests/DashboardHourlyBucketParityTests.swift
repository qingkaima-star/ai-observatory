//
//  DashboardHourlyBucketParityTests.swift
//  Tests/AIObservatorySwiftDataStoreTests
//
//  Owner: ws/engaudit（#53 动作 2a，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  动作 2 把 SQLite 侧 `dashboardStats` 的 hourly 分桶从「拉今日每一条事件回 Swift
//  逐行 `Calendar.component`」下推成一条 `GROUP BY`（真库形状：4 209 行进、6 行出）。
//  下推之后唯一要紧的问题是：**格子还是不是原来那些格子**。
//
//  已有的三套 dashboardStats 对照用例（`SwiftDataQueryParityTests` /
//  `SwiftDataBackendDifferentialTests` / `StoreInternalsTests`）都拿 `SampleData`
//  那批 `now − 1500 / − 3600 / − 7200` 秒的夹具做种子 ⇒ 全部落在**一两个**小时桶里。
//  于是"整体偏移八小时"这种错（SQLite 的 `strftime` 默认是 UTC 口径，正是最容易犯的那一种）
//  在现有覆盖下**一定测不出来**：两侧都在同一格里，合计还对得上。
//  本文件的种子因此铺满整天 24 个当地小时，并且每格条数**互不相同**（第 h 格 h+1 条）：
//  任何偏移或置换都会留下痕迹。
//
//  三件事一起判：
//   1. 逐格等于按 `Calendar.current` 手推的分布（日均 CPU / 峰值这些标量给手推字面量）；
//   2. 三个后端（SQLite / SwiftData / InMemory 参照）逐格等于同一份手推真值；
//   3. 一条"如果分桶走 UTC 口径就会红"的反向判据 —— 它钉的是修法本身，不是我的实现。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport
@testable import AIObservatorySwiftDataStore

// MARK: - 夹具

private let calendar = Calendar.current

/// 被查询的那一天：**两天前**的当地零点。
///
/// 不用"今天"是为了可复现：现在是凌晨三点的话，"今天"根本没有 24 个可填的小时，
/// 铺满一整天的用例会在某些时刻自己失去分母。两天前既落在 `retentionDays`（默认 30）
/// 之内，又保证那一整天已经过完。
private let dayAnchor = calendar.startOfDay(for: Date().addingTimeInterval(-2 * 86_400))

/// 结算时刻：那一天的最后一秒（`duration(until:)` 不夹任何未结算会话，本文件也没种会话）。
private let settlementDate = dayAnchor.addingTimeInterval(86_400 - 1)

/// 本机相对 UTC 的偏移（秒）。UTC 口径要让所有行落回**同一批**格子，偏移必须是整天的
/// 整数倍；除 UTC 本身（以及极少数整天偏移）以外，这条反向判据都有区分度。
private let localOffsetSeconds = TimeZone.current.secondsFromGMT(for: settlementDate)

/// 反向判据在**这台机器**上到底测不测得出来（false 时那条用例会显式记 issue，不静默放行）。
private let utcVersusLocalDiscriminates = localOffsetSeconds % 86_400 != 0

/// 第 h 格放 `h + 1` 条 ⇒ 总数 `Σ(h+1) = 300`，且 24 个格子的条数两两不同。
private func seededEventCount(hour: Int) -> Int { hour + 1 }
private let seededEventTotal = (0..<24).reduce(0) { $0 + seededEventCount(hour: $1) }

/// 上一天的干扰行：只有窗口失效时才会进今天的格子。
private let outsideDayEventCount = 7

/// 每小时两条采样，cpu = `h*10 + i`、memory = `h * 1_000_000`。
/// 手推：每格均值 `(10h + 10h + 1)/2 = 10h + 0.5`；
/// 全局和 `Σ_h Σ_i (10h+i) = Σ_h (20h+1) = 20*276 + 24 = 5544`，条数 48 ⇒ 均值 **115.5**；
/// 峰值 cpu = `23*10+1` = **231**；峰值内存落在第 23 格 = **23 000 000**。
private let samplesPerHour = 2
private let expectedAverageCPU: Double = 115.5
private let expectedPeakCPU: Double = 231
private let expectedPeakMemory: UInt64 = 23_000_000

/// 事件时刻：当地第 `hour` 小时的第 `2*slot+1` 分钟 ⇒ 1′、3′、5′…最远 47′，
/// 永不跨到下一个小时，也不压在整点边界上（边界处任何舍入歧义都不该替用例说话）。
private func eventDate(hour: Int, slot: Int) -> Date {
    dayAnchor.addingTimeInterval(TimeInterval(hour * 3_600 + (slot * 2 + 1) * 60))
}

/// 采样时刻：同一小时内的 11′ 与 31′。
private func sampleDate(hour: Int, slot: Int) -> Date {
    dayAnchor.addingTimeInterval(TimeInterval(hour * 3_600 + (slot * 20 + 11) * 60))
}

private func makeEvent(at date: Date, index: Int) -> TimelineEvent {
    TimelineEvent(
        id: StableID.uuid(namespace: "hourlybucket", key: "event-\(index)"),
        timestamp: date,
        agentKind: .claudeCode,
        kind: .fileModified,
        title: "改了 \(index).swift",
        summary: "第 \(index) 条",
        projectPath: "/hourly-bucket-fixture/Project"
    )
}

/// 本文件的采样全部挂在这一个会话上。#96 把首页那一格的**主体**锁成「挂着会话的采样」
/// （`session_id IS NOT NULL`），无主行不再入账 ⇒ 这里的标量真值 115.5 / 231 / 23 000 000
/// 才仍然算得出去。分桶测的是"格子对不对得齐"，不测主体，主体那一格在
/// `DashboardSampleSubjectTests`。
private let fixtureSessionID = StableID.uuid(namespace: "hourlybucket", key: "session")

private func makeSample(at date: Date, hour: Int, slot: Int, index: Int) -> PerformanceSample {
    PerformanceSample(
        id: StableID.uuid(namespace: "hourlybucket", key: "sample-\(index)"),
        timestamp: date,
        sessionID: fixtureSessionID,
        cpuPercent: Double(hour * 10 + slot),
        memoryBytes: UInt64(hour) * 1_000_000
    )
}

/// 一份确定的种子：24 个格子的事件 + 每小时两条采样 + 7 条昨天的干扰行。
private struct Fixture {
    var events: [TimelineEvent]
    var samples: [PerformanceSample]

    /// 只算窗口内那部分的手推真值（干扰行按定义不该进任何格子）。
    var expected: [HourlyActivity] {
        var eventCounts: [Int: Int] = [:]
        var cpuSum: [Int: Double] = [:]
        var cpuCount: [Int: Int] = [:]
        let range = DateRangeFilter.today(settlementDate)
        for event in events where range.contains(event.timestamp) {
            eventCounts[calendar.component(.hour, from: event.timestamp), default: 0] += 1
        }
        for sample in samples where range.contains(sample.timestamp) {
            let hour = calendar.component(.hour, from: sample.timestamp)
            cpuSum[hour, default: 0] += sample.cpuPercent
            cpuCount[hour, default: 0] += 1
        }
        return (0..<24).map { hour in
            let count = cpuCount[hour] ?? 0
            return HourlyActivity(
                hour: hour,
                eventCount: eventCounts[hour] ?? 0,
                cpuAverage: count > 0 ? (cpuSum[hour] ?? 0) / Double(count) : 0
            )
        }
    }
}

private func makeFixture() -> Fixture {
    var events: [TimelineEvent] = []
    var samples: [PerformanceSample] = []
    for hour in 0..<24 {
        for slot in 0..<samplesPerHour {
            samples.append(makeSample(at: sampleDate(hour: hour, slot: slot), hour: hour, slot: slot, index: hour * 10 + slot))
        }
        for slot in 0..<seededEventCount(hour: hour) {
            events.append(makeEvent(at: eventDate(hour: hour, slot: slot), index: hour * 100 + slot))
        }
    }
    // 干扰行落在**前一天**的 23 点档（不是前一天的中午，那样只会测到"中午有没有漏"）。
    let previousDayEvening = dayAnchor.addingTimeInterval(-1_800)
    for offset in 0..<outsideDayEventCount {
        events.append(makeEvent(at: previousDayEvening.addingTimeInterval(Double(offset) * 60), index: 9_000 + offset))
    }
    return Fixture(events: events, samples: samples)
}

private struct ThreeBackends {
    var sqlite: ObservatoryStore
    var swiftData: SwiftDataObservatoryStore
    var reference: InMemoryObservatoryService
}

private func seededBackends(_ fixture: Fixture) async throws -> ThreeBackends {
    let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
    let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
    for event in fixture.events {
        await sqlite.append(event)
        await swiftData.append(event)
    }
    for sample in fixture.samples {
        await sqlite.append(sample)
        await swiftData.append(sample)
    }
    await sqlite.flush()
    await swiftData.flush()

    let reference = InMemoryObservatoryService()
    reference.seed(events: fixture.events, performance: fixture.samples)
    return ThreeBackends(sqlite: sqlite, swiftData: swiftData, reference: reference)
}

/// `eventCount` 逐格比对（整数，不留容差）。
private func expectHourlyCounts(
    _ stats: DashboardStats,
    match want: [HourlyActivity],
    backend: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(
        stats.hourlyActivity.count == 24,
        "\(backend)：hourly 必须恒为 24 格（UI 不自己补洞），实得 \(stats.hourlyActivity.count) 格",
        sourceLocation: sourceLocation
    )
    let hours = stats.hourlyActivity.map(\.hour)
    #expect(Set(hours) == Set(0..<24), "\(backend)：小时下标越界或重复 ⇒ 实得 \(hours)", sourceLocation: sourceLocation)
    for entry in want {
        let got = stats.hourlyActivity.first { $0.hour == entry.hour }?.eventCount ?? -1
        #expect(
            got == entry.eventCount,
            "\(backend)：第 \(entry.hour) 格事件数应为 \(entry.eventCount)，实得 \(got)",
            sourceLocation: sourceLocation
        )
    }
}

/// `cpuAverage` 逐格比对。**只**在这里放浮点容差：SQL 的 `SUM` 与自己一行行累加的
/// 求和顺序不保证逐位相同；整数计数一律逐字比（见 `expectHourlyCounts`）。
private func expectHourlyCPU(
    _ stats: DashboardStats,
    match want: [HourlyActivity],
    backend: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    for entry in want {
        let got = stats.hourlyActivity.first { $0.hour == entry.hour }?.cpuAverage ?? -1
        #expect(
            abs(got - entry.cpuAverage) <= 1e-9 * max(1, abs(entry.cpuAverage)),
            "\(backend)：第 \(entry.hour) 格 cpuAverage 应为 \(entry.cpuAverage)，实得 \(got)",
            sourceLocation: sourceLocation
        )
    }
}

@Suite("Dashboard hourly 分桶：下推成 SQL GROUP BY 之后口径没变")
struct DashboardHourlyBucketParityTests {

    // MARK: - 0. 夹具的分母（铺不满一整天就别往下判）

    @Test("种子确实铺满 24 个不同的当地小时，且每格条数两两不同")
    func fixtureCoversEveryHour() {
        let fixture = makeFixture()
        let today = DateRangeFilter.today(settlementDate)
        let inWindow = fixture.events.filter { today.contains($0.timestamp) }
        let hours = Set(inWindow.map { calendar.component(.hour, from: $0.timestamp) })
        #expect(hours == Set(0..<24), "夹具只覆盖 \(hours.sorted()) ⇒ 分桶偏移测不出来，本文件全部判据作废")
        #expect(inWindow.count == seededEventTotal, "窗口内种子总数应为 300，实得 \(inWindow.count)")
        let counts = (0..<24).map { hour in inWindow.count { calendar.component(.hour, from: $0.timestamp) == hour } }
        #expect(Set(counts).count == 24, "每格条数必须两两不同（否则置换类错误测不出），实得 \(counts)")
        #expect(fixture.events.count - inWindow.count == outsideDayEventCount, "干扰行没算进窗口才是对的，实得 \(fixture.events.count - inWindow.count)")
    }

    // MARK: - 1. 逐格等于手推分布

    @Test("SQLite：24 格逐格等于手推分布，日均/峰值标量等于 115.5 / 231 / 23 000 000")
    func sqliteBucketsMatchHandComputation() async throws {
        let fixture = makeFixture()
        let backends = try await seededBackends(fixture)
        let stats = try await backends.sqlite.dashboardStats(for: settlementDate)
        let want = fixture.expected

        expectHourlyCounts(stats, match: want, backend: "SQLite")
        expectHourlyCPU(stats, match: want, backend: "SQLite")

        // 分母恒等式：24 格合计 = 窗口内事件数（少了是丢桶，多了是窗口失效）。
        let total = stats.hourlyActivity.reduce(0) { $0 + $1.eventCount }
        #expect(total == seededEventTotal, "24 格合计应为 \(seededEventTotal)，实得 \(total)")

        #expect(stats.averageCPUPercent == expectedAverageCPU, "日均 CPU 手推 115.5，实得 \(stats.averageCPUPercent)")
        #expect(stats.peakCPUPercent == expectedPeakCPU, "峰值 CPU 手推 231（在第 23 格），实得 \(stats.peakCPUPercent)")
        #expect(stats.peakMemoryBytes == expectedPeakMemory, "峰值内存手推 23 000 000，实得 \(stats.peakMemoryBytes)")
    }

    @Test("SQLite：分桶走的是本地时区口径，不是 UTC")
    func sqliteBucketsAreNotUTCShifted() async throws {
        let fixture = makeFixture()
        let backends = try await seededBackends(fixture)
        let stats = try await backends.sqlite.dashboardStats(for: settlementDate)

        // 同一批种子按 UTC 分桶会得到什么：那是 `strftime('%H', ts, 'unixepoch')` 的口径，
        // 也就是**忘了写 `'localtime'`** 时这份代码会变成的样子。
        var utcCalendar = calendar
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let range = DateRangeFilter.today(settlementDate)
        let inWindow = fixture.events.filter { range.contains($0.timestamp) }
        var shifted: [Int: Int] = [:]
        for event in inWindow {
            shifted[utcCalendar.component(.hour, from: event.timestamp), default: 0] += 1
        }
        let utcShape = (0..<24).map { shifted[$0] ?? 0 }
        let got = stats.hourlyActivity.map(\.eventCount)
        #expect(
            got != utcShape,
            "分桶结果与 UTC 口径逐格相同 ⇒ 那条 `localtime` 没生效；UTC 口径应为 \(utcShape)，实得 \(got)"
        )
        // 与 `Calendar.current` 的那一份必须逐格相同（正向判据，任何时区都判）。
        expectHourlyCounts(stats, match: fixture.expected, backend: "SQLite")
    }

    @Test("本机时区与 UTC 整天对齐 ⇒ 上面那条反向判据没有区分度（要红，不要绿着放过）")
    func utcDiscriminationIsMeaningfulHere() {
        // 这条用例本身不测分桶，测的是"本文件最有价值的那条反向判据此刻到底生不生效"。
        // 在 UTC runner 上它会红，从而逼着读结果的人换时区跑一次，而不是误以为已覆盖。
        #expect(
            utcVersusLocalDiscriminates,
            """
            本机 `TimeZone.current` 与 UTC 的偏移 \(localOffsetSeconds) 秒是整天倍数 ⇒ \
            `sqliteBucketsAreNotUTCShifted` 测不出任何东西，请在非 UTC 时区跑一遍再收
            """
        )
    }

    // MARK: - 2. 三后端一致（都和同一份手推真值比，不是互相比）

    @Test("SwiftData / InMemory 参照：逐格等于手推真值（只在**结果**上等价；成本上不等价——SwiftData 侧省解码不省行数）")
    func otherBackendsMatchTheSameTruthResultsNotCost() async throws {
        let fixture = makeFixture()
        let backends = try await seededBackends(fixture)
        let sqlite = try await backends.sqlite.dashboardStats(for: settlementDate)
        let swiftData = try await backends.swiftData.dashboardStats(for: settlementDate)
        let reference = try await backends.reference.dashboardStats(for: settlementDate)

        for (name, stats) in [("SwiftData", swiftData), ("InMemory", reference)] {
            expectHourlyCounts(stats, match: fixture.expected, backend: name)
            expectHourlyCPU(stats, match: fixture.expected, backend: name)
            #expect(stats.peakCPUPercent == sqlite.peakCPUPercent, "\(name) 峰值 CPU 与 SQLite 不同")
            #expect(stats.peakMemoryBytes == sqlite.peakMemoryBytes, "\(name) 峰值内存与 SQLite 不同")
            #expect(stats.commandsExecuted == sqlite.commandsExecuted, "\(name) 命令计数与 SQLite 不同")
            #expect(stats.sessionCount == sqlite.sessionCount, "\(name) 会话计数与 SQLite 不同")
        }
    }

    // MARK: - 3. 空那天与窗口边界

    @Test("那天一条都没有：24 格全 0，标量不因 SQL 聚合返回 NULL 而变 nil/崩")
    func emptyDayYieldsTwentyFourZeroBuckets() async throws {
        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        await sqlite.flush()
        let stats = try await sqlite.dashboardStats(for: settlementDate)
        #expect(stats.hourlyActivity.count == 24)
        #expect(stats.hourlyActivity.allSatisfy { $0.eventCount == 0 && $0.cpuAverage == 0 })
        #expect(stats.averageCPUPercent == 0, "空集合的 `SUM` 是 NULL，必须落到 0 而不是别的东西")
        #expect(stats.peakCPUPercent == 0)
        #expect(stats.peakMemoryBytes == 0)
    }

    @Test("只有前一天 23 点档有数据：今天 24 格全 0（GROUP BY 丢了窗口就会在这里红）")
    func previousDayDoesNotLeakIntoToday() async throws {
        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let previousDayEvening = dayAnchor.addingTimeInterval(-1_800)
        for offset in 0..<outsideDayEventCount {
            await sqlite.append(makeEvent(at: previousDayEvening.addingTimeInterval(Double(offset) * 60), index: offset))
        }
        await sqlite.flush()
        let stats = try await sqlite.dashboardStats(for: settlementDate)
        #expect(stats.hourlyActivity.reduce(0) { $0 + $1.eventCount } == 0, "前一天的事件漏进了今天的格子")
    }
}
