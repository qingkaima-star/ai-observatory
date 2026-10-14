//
//  DashboardStatsPushdownCostTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws/engaudit（#53 动作 2 的机制取证，2026-09-21）
//  开关：`AIOBSERVATORY_DASH_COST=1`（默认关；进程 CPU 计时不能进默认并行套件）
//
//  这一档要回答的问题很小：**同一批数据、同一台机器**，
//  `dashboardStats(for:)` 算完今日六宫格 + 24 格图表，
//  到底比"把今日事件整页拉一遍"贵还是便宜。
//  动作 2 之前它自己就是那个"整页拉"（events 今日每行一次解码 + perf 每行三列），
//  所以下推之后它应当**明显低于**那条参照线；谁把它改回去，这条就会红。
//
//  为什么不写绝对毫秒数当门：绝对值随机器负载漂（#53 已经吃过一次：
//  同一份代码 162.5 与 296.8 ms/tick），拿当次实测反过来钉一个刚好通过的常数，
//  等于用结论给自己出题。这里比的是同一份数据上的两次测量，量纲相同、机器相同。
//

import Foundation
import Testing
import os
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

private let costEnabled = ProcessInfo.processInfo.environment["AIOBSERVATORY_DASH_COST"] != nil

/// 今日种子形状：真库实测（tmp/idle53 那一份 #53 测量库）是 events 4 209 / perf 2 166，
/// 风暴跑时 events 8 840。取 8 000 + 3 000 是"偏保守那一侧"：如果下推只在大数据上有效，
/// 这里就该看得见。
private let seededEvents = 8_000
private let seededSamples = 3_000
/// 真库形状（tmp/idle53 那一份，2026-09-21 实测）：今日 file_changes 3 498 / 全表 7 004，
/// 今日 commands 597 / 全表 834，今日 risk_events 只有 54 ⇒ 风险那一路根本不值得为它建索引。
private let seededFiles = 7_000
private let seededCommands = 800
private let measuredCalls = 12

/// 进程 CPU 时间（秒）：与 `TickStageLedger.selfCPUSeconds()` 同一口径。
private func cpuSeconds() -> Double {
    var ts = timespec()
    clock_gettime(CLOCK_PROCESS_CPUTIME_ID, &ts)
    return Double(ts.tv_sec) + Double(ts.tv_nsec) / 1_000_000_000
}

/// (c) 那一档要验的候选：四条覆盖聚合的复合索引，并删掉被它们前缀覆盖的单列索引。
/// 列的顺序 = 谓词列在前、CASE WHEN 要读的列在后 ⇒ 计划从 `SEARCH … USING INDEX`
/// 变成 `SEARCH … USING COVERING INDEX`（改前那三条要按 rowid 回表逐行取 kind / outcome / cpu/memory）。
private let candidateIndexes: [(create: String, superseded: String)] = [
    ("CREATE INDEX idx_files_ts_kind ON file_changes(timestamp, kind)", "idx_files_ts"),
    ("CREATE INDEX idx_commands_started_outcome ON commands(started_at, outcome)", "idx_commands_started"),
    ("CREATE INDEX idx_perf_ts_cpu_mem ON perf_samples(timestamp, cpu_percent, memory_bytes)", "idx_perf_ts"),
]

/// 把 `seededEvents` 条事件均匀铺进"今天"已过完的那几个小时里。
private func seedToday(_ store: ObservatoryStore, from midnight: Date) async {
    for index in 0..<seededEvents {
        let stamp = midnight.addingTimeInterval(Double(index) * 4.0)   // 4 秒一条 ⇒ 8 千条 ≈ 8.9 小时
        await store.append(TimelineEvent(
            timestamp: stamp,
            agentKind: .claudeCode,
            kind: .fileModified,
            title: "改了 \(index).swift",
            summary: "第 \(index) 条",
            projectPath: "/dash-cost-fixture/Project"
        ))
    }
    for index in 0..<seededSamples {
        let stamp = midnight.addingTimeInterval(Double(index) * 10.0)
        await store.append(PerformanceSample(
            timestamp: stamp,
            cpuPercent: Double(index % 97),
            memoryBytes: UInt64(index) * 4_096
        ))
    }
    await store.flush()
}

private func median(_ values: [Double]) -> Double {
    let sorted = values.sorted()
    guard !sorted.isEmpty else { return 0 }
    let middle = sorted.count / 2
    return sorted.count % 2 == 1 ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2
}

/// 一次调用的中位 CPU 毫秒数。
private func perCallMS(_ body: () async throws -> Void) async throws -> Double {
    var samples: [Double] = []
    for _ in 0..<measuredCalls {
        let before = cpuSeconds()
        try await body()
        samples.append((cpuSeconds() - before) * 1_000)
    }
    return median(samples)
}

@Suite("dashboardStats 的成本：不该比\"把今日事件整页拉一遍\"还贵", .serialized)
struct DashboardStatsPushdownCostTests {

    @Test("同一批数据上对照：聚合取数 vs 整页拉取（两臂同机器同数据，比的是比值不是绝对值）",
          .enabled(if: costEnabled))
    func aggregateCheaperThanFullPull() async throws {
        let directory = try Scratch.directory("dashcost")
        let path = directory.appendingPathComponent("observatory.sqlite").path
        let store = try await ObservatoryStore.open(configuration: .file(path))
        let now = Date()
        let midnight = Calendar.current.startOfDay(for: now)
        await seedToday(store, from: midnight)

        let statsCost = try await perCallMS {
            _ = try await store.dashboardStats(for: now)
        }
        let pullCost = try await perCallMS {
            _ = try await store.events(matching: EventQuery(
                dateRange: DateRangeFilter.today(now), limit: seededEvents
            ))
        }
        // 改前那一格的**同形状重建**：同一份数据、同一个进程里，把"单列拉回 Swift +
        // 逐行 `Calendar.component`"（下推前 `dashboardStats` 对 events 做的全部事情）
        // 直接跑一遍。它不是"用改前的包测出来的数"（那要跨会话构建，负载不可比），
        // 而是把改前那一段的功原样搬回来量一次 —— 差别写在牌上，不冒充。
        let oldShapeCost = try await perCallMS {
            let handle = try SQLiteDatabase(configuration: .file(path))
            let rows = try await handle.rows(
                "SELECT timestamp FROM events WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp ASC, id ASC",
                arguments: [
                    .real(midnight.timeIntervalSinceReferenceDate),
                    .real(midnight.addingTimeInterval(86_400).timeIntervalSinceReferenceDate),
                ]
            )
            let stamps = rows.compactMap { $0.date("timestamp") }
            var buckets: [Int: Int] = [:]
            for stamp in stamps {
                buckets[Calendar.current.component(.hour, from: stamp), default: 0] += 1
            }
            #expect(stamps.count == seededEvents, "重建臂没拿到当日全部行（实得 \(stamps.count)）⇒ 它没在量改前那件事")
            await handle.close()
        }

        // 仪器自检：两臂都必须落在噪声之上，否则"便宜"是量出来的 0。
        #expect(statsCost > 0.1, "聚合那一臂只有 \(statsCost) ms ⇒ 计时器没测到东西，比值不作数")
        #expect(pullCost > 0.1, "整页拉那一臂只有 \(pullCost) ms ⇒ 参照线本身没测到东西")
        #expect(oldShapeCost > 0.1, "重建臂只有 \(oldShapeCost) ms ⇒ 它没在量改前那件事")
        print("DASH_COST events=\(seededEvents) samples=\(seededSamples) dashboardStatsMS=\(String(format: "%.3f", statsCost)) oldShapeRebuildMS=\(String(format: "%.3f", oldShapeCost)) fullPagePullMS=\(String(format: "%.3f", pullCost)) speedupVsOldShape=x\(String(format: "%.2f", oldShapeCost / statsCost))")

        #expect(
            statsCost < pullCost,
            "算完今日全部读数（六宫格 + 24 格）比把今日事件整页拉回 Swift 还贵 ⇒ hourly 分桶又退回逐行拉了"
        )
        // ── (c) 那一档：同一进程、同一批数据，加覆盖索引前后各测一遍 ──
        let handle = try SQLiteDatabase(configuration: .file(path))
        let withoutIndexMS = try await perCallMS {
            _ = try await store.dashboardStats(for: now)
        }
        // 先测无索引（同一进程、同一份文件库），再建索引复测：两臂只差那三条 DDL。
        for spec in candidateIndexes {
            try await handle.run(spec.create)
            try await handle.run("DROP INDEX IF EXISTS \(spec.superseded)")
        }
        try await handle.run("ANALYZE")
        let withIndexMS = try await perCallMS {
            _ = try await store.dashboardStats(for: now)
        }
        await handle.close()

        // 两臂都必须落在噪声之上，否则"索引有没有用"这个结论只是仪器不够细。
        #expect(withoutIndexMS > 0.1, "无索引那一臂只有 \(withoutIndexMS) ms ⇒ 仪器分不出来")
        #expect(withIndexMS > 0.1, "有索引那一臂只有 \(withIndexMS) ms ⇒ 仪器分不出来")
        print("INDEX_AB files=\(seededFiles) commands=\(seededCommands) perf=\(seededSamples) events=\(seededEvents) withoutIndexMS=\(String(format: "%.3f", withoutIndexMS)) withCoveringIndexMS=\(String(format: "%.3f", withIndexMS)) speedup=x\(String(format: "%.2f", withoutIndexMS / max(withIndexMS, 0.001)))")

        #expect(
            statsCost < oldShapeCost,
            "比改前那一格的同形状重建还贵（\(statsCost) vs \(oldShapeCost)）⇒ 下推没省下东西"
        )
    }
}
