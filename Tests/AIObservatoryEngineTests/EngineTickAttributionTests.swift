//
//  EngineTickAttributionTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine（性能收尾线 ws/perfclose）
//  ─────────────────────────────────────────────────────────
//  为什么默认不跑：它要建库、种几万行、跑几十轮采集，是一条几十秒的长跑；
//  而且它**打数**而非**判定**——判定要留给人（和静默窗）。开法：
//
//      AIOBSERVATORY_TICK_ATTRIBUTION=1 xcrun swift test -c release --disable-sandbox \
//        --filter EngineTickAttribution 2>&1 | sed -n '1,80p'
//
//  为什么现在就能跑（而判据④ 的 CPU 那半要等静默窗）：`TickStageLedger` 记的是
//  **本进程累计 CPU 时间**（`getrusage`），不是墙钟。别人的负载会让我们**少被调度**，
//  但不会把我们自己已经烧掉的 CPU 秒变成别的数字 ⇒ 阶段间的**相对**归因在非静默窗成立。
//  需要静默窗的是「Δcputime ÷ 墙钟 ≤ 3%」那条聚合判据（分母是墙钟，会被抢 CPU 拖累）。
//  ⚠️ 例外： syscall 竞争（磁盘/内核锁）能真实抬高 CPU 时间，所以三个数据量档位
//  **必须在同一个窗口内跑完**，只比差值、不比绝对值。
//
//  三种数据量的用意：
//   · 0 行 —— 只有本轮新种的那一条，`syncProjects` 走「无历史可聚合」的下界；
//   · 2 000 行 —— 正好是 `syncProjectsIfNeeded` 那五条查询的 `limit`，聚合满额；
//   · 20 000 行 —— 超过 limit ⇒ **聚合的活应当不变**（`limit` 截住了），
//     只有 `SELECT COUNT(*) FROM file_changes` 那道闸门会随全表长。
//     如果 20 000 档的 syncProjects 明显高于 2 000 档，就说明"上限"没截住东西。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryEngine
@testable import AIObservatoryStore
@testable import AIObservatoryPlatform

private let attributionEnabled = ProcessInfo.processInfo.environment["AIOBSERVATORY_TICK_ATTRIBUTION"] != nil

/// 每档种的行数（0 / 2 000 / 20 000）。
private let seedVolumes = [0, 2_000, 20_000]
/// 每档跑几轮采集。10 轮够让 `syncProjects` 每轮都到期（见 `seedOneChange`）。
private let attributionTicks = 10

private func seededEngine(seed: Int) async throws -> (ObservatoryEngine, ObservatoryStore) {
    let directory = try Scratch.directory("tick-attribution-\(seed)")
    let store = try await ObservatoryStore.open(
        configuration: .file(directory.appendingPathComponent("observatory.sqlite").path)
    )
    let agentID = UUID()
    let sessionID = UUID()
    if seed > 0 {
        for index in 0..<seed {
            await store.append(FileChange(
                path: "/projects/p\(index % 12)/src/file\(index).swift",
                kind: .modified,
                timestamp: Date(timeIntervalSince1970: 1_800_003_000 + Double(index)),
                agentID: agentID,
                sessionID: sessionID,
                agentKind: .claudeCode,
                linesAdded: 3,
                projectPath: "/projects/p\(index % 12)"
            ))
        }
        await store.flush()
    }
    await store.stop()

    // **生产形状的装配**：真进程扫描 + 真识别管线 + 真采样器。
    // 用桩的话 scan/detect 塌成 0，这张表就又变成"缺项的加总"——那正是它要取代的东西。
    let settings = ObservatorySettings(
        processScanIntervalSeconds: 3,
        storeDirectory: directory.path
    )
    let engine = ObservatoryEngine(settings: settings, components: .live(settings: settings))
    let reopened = try await ObservatoryStore.open(
        configuration: .file(directory.appendingPathComponent("observatory.sqlite").path)
    )
    return (engine, reopened)
}

/// 本轮再种一条变更：让 `syncProjectsIfNeeded` 的「行数变了」闸门每轮都到期。
/// 生产里这就是文件事件持续进来的形状——不种的话第 2 轮起那段会被闸门挡掉，
/// 量到的会是"多数 tick 什么都不干"的乐观值。
private func seedOneChange(_ store: ObservatoryStore, index: Int) async {
    await store.append(FileChange(
        path: "/projects/p\(index % 12)/src/live\(index).swift",
        kind: .modified,
        agentKind: .claudeCode,
        linesAdded: 1,
        projectPath: "/projects/p\(index % 12)"
    ))
    await store.flush()
}

@Suite("Engine：每-tick 归因（真实数据量，诊断，需显式开启）",
       .enabled(if: attributionEnabled), .timeLimit(.minutes(3)))
struct EngineTickAttributionTests {

    @Test("三档数据量各跑 10 轮，打印九段 CPU 毫秒/tick 与未归属余额")
    func attributesStagesAcrossVolumes() async throws {
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        #if DEBUG
        let build = "DEBUG（不可用于判据）"
        #else
        let build = "RELEASE"
        #endif
        print("TICK-ATTR 构建档=\(build) load \(String(format: "%.2f", load[0]))"
            + "（同一窗口内只比差值，不比绝对值）")

        var syncProjectsPerSeed: [Int: Double] = [:]
        for seed in seedVolumes {
            let (engine, seeder) = try await seededEngine(seed: seed)
            for tick in 0..<attributionTicks {
                await seedOneChange(seeder, index: seed + tick)
                await engine.rescanNow()
            }
            let account = engine.tickAccount()
            await seeder.stop()
            await engine.stop()

            #expect(account.tickCount == attributionTicks)
            #expect(account.isStageCoverageComplete,
                    "边界计数不齐 ⇒ 有段没进账，本表归因不可信")
            syncProjectsPerSeed[seed] = account.msPerTick(.syncProjects)

            print("TICK-ATTR 种=\(seed) 行：已入账 \(String(format: "%7.2f", account.attributedMSPerTick))"
                + " ms/tick，未归属 \(String(format: "%6.2f", account.unattributedMSPerTick)) ms/tick"
                + "（syncProjects 合计 \(String(format: "%.1f", account.stageCPUMilliseconds[.syncProjects] ?? 0)) ms）")
            for stage in TickStage.allCases {
                print("TICK-ATTR   \(stage.rawValue.padding(toLength: 18, withPad: " ", startingAt: 0))"
                    + " = \(String(format: "%7.2f", account.msPerTick(stage))) ms/tick")
            }
        }

        // 机器状态一句话自述：三档同窗跑完才允许做这个比较。
        let gateOnly = (syncProjectsPerSeed[20_000] ?? 0) - (syncProjectsPerSeed[2_000] ?? 0)
        print("TICK-ATTR 闸门随全表长出来的部分（20 000 档 − 2 000 档）= \(String(format: "%.2f", gateOnly)) ms/tick")
    }
}
