//
//  CoreContractTests.swift
//  AIObservatoryCoreTests
//
//  Owner: master-controller（冻结基线测试）
//

import Testing
import Foundation
@testable import AIObservatoryCore
@testable import AIObservatoryTestSupport

@Suite("核心契约：格式化")
struct FormattingTests {

    @Test("时长格式化符合人类可读预期")
    func durationFormatting() {
        #expect(DurationFormat.humanReadable(0) == "0秒")
        #expect(DurationFormat.humanReadable(45) == "45秒")
        #expect(DurationFormat.humanReadable(18 * 60 + 32) == "18分钟32秒")
        #expect(DurationFormat.humanReadable(2 * 3600 + 15 * 60) == "2小时15分钟")
        #expect(DurationFormat.humanReadable(86_400) == "1天")
        #expect(DurationFormat.compact(6 * 3600 + 32 * 60) == "6h32m")
        #expect(DurationFormat.clock(3_661) == "01:01:01")
    }

    @Test("字节格式化")
    func byteFormatting() {
        #expect(ByteFormat.humanReadable(UInt64(0)) == "0 B")
        #expect(ByteFormat.humanReadable(UInt64(1_536)) == "1.5 KB")
        #expect(ByteFormat.humanReadable(UInt64(2_576_980_377)) == "2.4 GB")
        #expect(ByteFormat.rate(320_000_000) == "305.2 MB/s")
    }
}

@Suite("核心契约：通配符与路径启发式")
struct PatternTests {

    @Test("忽略规则的通配符匹配")
    func wildcardMatching() {
        #expect(PatternMatcher.matches(pattern: "*/.build/*", path: "/Users/x/proj/.build/debug/foo.o"))
        #expect(PatternMatcher.matches(pattern: "*/node_modules/*", path: "/Users/x/app/node_modules/react/index.js"))
        #expect(PatternMatcher.matches(pattern: "*.tmp", path: "/tmp/scratch.tmp"))
        #expect(!PatternMatcher.matches(pattern: "*/node_modules/*", path: "/Users/x/app/src/index.js"))
        #expect(PatternMatcher.matchesAny(patterns: ["*/Caches/*", "*.o"], path: "/a/b/Caches/c/d"))
    }

    @Test("敏感路径判定")
    func sensitivePaths() {
        #expect(PathHeuristics.isSensitive("/etc/hosts"))
        #expect(PathHeuristics.isSensitive("/System/Library/CoreServices/foo"))
        #expect(PathHeuristics.isSensitive(NSHomeDirectory() + "/.ssh/id_rsa"))
        #expect(!PathHeuristics.isSensitive(NSHomeDirectory() + "/Projects/Mona/API.swift"))
    }

    @Test("根目录归属判定")
    func descendantCheck() {
        #expect(PathHeuristics.isDescendant("/Users/x/proj/Sources/A.swift", of: ["/Users/x/proj"]))
        #expect(!PathHeuristics.isDescendant("/Users/x/other/A.swift", of: ["/Users/x/proj"]))
    }
}

@Suite("核心契约：查询语义")
struct QueryTests {

    @Test("日期范围过滤")
    func dateRange() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let range = DateRangeFilter.lastHours(2, now: now)
        #expect(range.contains(now))
        #expect(range.contains(now.addingTimeInterval(-3_600)))
        #expect(range.contains(now.addingTimeInterval(-7_200)))   // start 为闭区间
        #expect(!range.contains(now.addingTimeInterval(-7_201)))
        #expect(!range.contains(now.addingTimeInterval(1)))       // end 为开区间
    }

    @Test("风险等级可比较")
    func riskOrdering() {
        #expect(RiskLevel.low < RiskLevel.medium)
        #expect(RiskLevel.medium < RiskLevel.high)
        #expect(RiskLevel.high < RiskLevel.critical)
        #expect([RiskLevel.high, .low, .critical].max() == .critical)
    }

    @Test("Page 分页语义")
    func pagination() {
        let page = Page(items: [1, 2, 3], totalCount: 10, offset: 0)
        #expect(page.hasMore)
        let last = Page(items: [9, 10], totalCount: 10, offset: 8)
        #expect(!last.hasMore)
    }
}

@Suite("测试支撑：样本数据与内存服务")
struct TestSupportTests {

    @Test("确定性种子产生一致数据")
    func deterministicSeed() async throws {
        let a = SampleData.demoService(now: Date(timeIntervalSince1970: 1_700_000_000), seed: 42, sessionCount: 5)
        let b = SampleData.demoService(now: Date(timeIntervalSince1970: 1_700_000_000), seed: 42, sessionCount: 5)
        let sessionsA = try await a.sessions(matching: .all)
        let sessionsB = try await b.sessions(matching: .all)
        #expect(sessionsA.totalCount == sessionsB.totalCount)
        #expect(sessionsA.items.map(\.startedAt) == sessionsB.items.map(\.startedAt))
    }

    @Test("会话查询按时间倒序并尊重 limit")
    func sessionQuery() async throws {
        let service = SampleData.demoService(sessionCount: 12)
        let page = try await service.sessions(matching: SessionQuery(limit: 5))
        #expect(page.items.count <= 5)
        #expect(page.totalCount == 12)
        let timestamps = page.items.map(\.startedAt)
        #expect(timestamps == timestamps.sorted(by: >))
    }

    @Test("文件变更可按类型过滤")
    func fileChangeFilter() async throws {
        let service = SampleData.demoService(sessionCount: 8)
        let created = try await service.fileChanges(matching: FileChangeQuery(kinds: [.created], limit: 500))
        #expect(created.items.allSatisfy { $0.kind == .created })
    }

    @Test("Dashboard 统计字段自洽")
    func dashboardStats() async throws {
        let now = Date()
        let service = SampleData.demoService(now: now, sessionCount: 12)
        let stats = try await service.dashboardStats(for: now)
        #expect(stats.sessionCount > 0)
        #expect(stats.totalActiveSeconds > 0)
        #expect(stats.hourlyActivity.count == 24)
        #expect(stats.riskEventCount >= 1)
        #expect(stats.activeAgentCount >= 1)
    }

    /// 样本数据曾在凌晨暴露缺陷：会话被固定排在当天 09:00–20:00，
    /// 于是时间戳落到未来，`totalActiveSeconds` 变成负数；
    /// 而把它们整体挪到前一天又会让按天统计的 Dashboard 变成 0 场。
    /// 因此必须覆盖一天中所有时刻。
    @Test("样本数据在任意墙钟时刻都自洽", arguments: [0, 1, 8, 9, 13, 20, 21, 23])
    func sampleDataIsSelfConsistentAcrossClock(hour: Int) async throws {
        let calendar = Calendar.current
        let anchor = calendar.startOfDay(for: Date())
        let now = anchor.addingTimeInterval(TimeInterval(hour * 3600 + 1_830))
        let service = SampleData.demoService(now: now, sessionCount: 12)
        let stats = try await service.dashboardStats(for: now)

        #expect(stats.sessionCount > 0, "hour=\(hour) 统计不到会话")
        #expect(stats.totalActiveSeconds > 0, "hour=\(hour) 活跃时长非正")
        // 运行中的会话时长等于「到此刻为止」，本就可以超过样本里的 duration 上限，
        // 因此真正的不变量是：所有会话都落在同一天内，单场不可能超过一天。
        #expect(
            stats.totalActiveSeconds <= Double(stats.sessionCount) * 86_400,
            "hour=\(hour) 活跃时长超出单日上限"
        )
    }
}
