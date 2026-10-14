//
//  PlatformTickBreakdownTests.swift
//  AIObservatoryPlatformTests — 每-tick 采集链阶段分解（诊断工具，默认不参与判定）
//
//  Owner: WS-Platform
//  ─────────────────────────────────────────────────────────
//  干什么用的：AGENTS §6 把「空闲 CPU < 3%」换算成「每 tick ≤ 周期 × 3%」之后，
//  本文件按六个入口逐段计时、打出来，并把「两个 CPU% 入口是否给出同一个数」一起打出来
//  （那是求差口径的可见证据）。
//
//  ⚠️ 它**不是** §6 要的那笔「可核对的加总」，两条原因（2026-09-20 ws/perfclose 复核）：
//   1. 它量的是**墙钟**，而 §6 的判据口径是「累计 CPU 时间差 ÷ 墙钟差」；
//   2. 它只覆盖 `ObservatoryEngine.runTick()` 九个阶段里的五个——没有 storeReady、
//      ingestAgents 与三段落库、syncProjects、prune。B10 那笔
//      「app 级 396 ms/tick 而链上只拆出 ≈68 ms」的缺口就在这几段没被量的地方；
//      **拿本表去减总数，得到的「无归属开销」不是真实存在的一段工作，只是没量。**
//  ⇒ 加总请用 `TickStageLedger`（Platform/Telemetry）：它跑在真 `runTick` 里、
//    按进程 CPU 时间记账、并显式给出「未归属」余额。用法见 `ObservatoryEngine.tickAccount()`
//    与统一日志里的 `tick-account` 行。本表留着答的是另一类问题：策略链内部占比、
//    `Bundle(url:)` 碰磁盘的命中面、以及两个 CPU% 入口是否同数——这些账本里没有。
//
//
//  为什么默认不跑：它测的是**墙钟耗时**，在 load 5–30 的机器上绝对值能差 6 倍
//  （实测同页 39 ↔ 417 ms/tick），放进常规套件就是一条只会制造红点的 flake。
//  所以它按环境变量开关——**静默窗里手动拉起来跑，产出的数进对账单，不进断言**。
//  开法：
//      AIOBSERVATORY_TICK_BREAKDOWN=1 xcrun swift test -c release --disable-sandbox \
//        --filter PlatformTickBreakdown 2>&1 | sed -n '1,60p'
//  静默窗前先确认：`uptime` 的 1 分钟 load 是个位数、且 `pgrep -f swift-frontend` 为空。
//
//  读这些数时的三个坑（都踩过）：
//   1. `strategiesOnly` 是**绕过管线闸门**逐条直接调策略链，所以它**大于** `detectAgents`
//      里策略那一段；两个数不能相加，那会把被 gate 掉的记录算两遍。
//   2. `inferCommands` 必须用**生产口径**的 `since`（引擎传的是「上一 tick 时刻」）。
//      传 `.distantPast` 量到的是「整轮所有候选重判一遍」的爆发尖峰（实测 17.6 ms 对
//      稳态 0.2 ms，差两个数量级），那不是每 tick 值。
//   3. 本表的绝对值只在**同一台机器、同一负载窗口、同一颗 release 构建**下可比。
//      拿 A 窗的总数减 B 窗的分项，会造出一笔根本不存在的「无归属开销」。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

/// 回放一份**已经抓到**的快照——与 `ObservatoryEngine.runTick()` 喂给检测管线的那个
/// `ReplayProcessInspector` 同形：一个 tick 只扫一次全表，检测走回放。
private struct ReplaySnapshot: ProcessInspecting {
    let records: [ProcessRecord]
    func scanProcesses() async -> [ProcessRecord] { records }
}

/// 环境变量开关。没设就整条 suite 不启用——常规 `swift test` 不会因此多花一秒，
/// 也不会有一条墙钟断言能在别人的机器上变红。
private let breakdownEnabled = ProcessInfo.processInfo.environment["AIOBSERVATORY_TICK_BREAKDOWN"] != nil

@Suite("WS-Platform：每-tick 采集链阶段分解（诊断，需显式开启）", .enabled(if: breakdownEnabled), .timeLimit(.minutes(1)))
struct PlatformTickBreakdownTests {

    /// 轮数：取中位数用。5 轮够压掉单次抖动，又不会让这条 suite 变成半分钟的长跑。
    private static let rounds = 5

    /// 阶段名（顺序即输出顺序，也即一个 tick 里引擎实际经过它们的顺序）。
    private enum Stage: Int, CaseIterable {
        case scanProcesses, detectAgents, strategyChainOnly, bundleIDStrategy
        case inferCommands, sampleSystem, sampleProcessesByPID

        /// 输出里的列名。带「— 其中」前缀的两段是**参考项**，不参与合计。
        var label: String {
            switch self {
            case .scanProcesses: return "scanProcesses(全表)"
            case .detectAgents: return "detectAgents(管线)"
            case .strategyChainOnly: return "- 其中 策略链(绕过闸门)"
            case .bundleIDStrategy: return "- 其中 BundleID 策略"
            case .inferCommands: return "inferCommands(生产 since)"
            case .sampleSystem: return "sampleSystem(整机)"
            case .sampleProcessesByPID: return "sampleProcesses(按 pid)"
            }
        }
    }

    @Test("逐阶段 ms/tick + 记录数/Agent 数/候选数 + 两个 CPU% 入口是否同数")
    func breakdown() async {
        let inspector = LibprocProcessInspector()
        let pipeline = AgentDetectionPipeline()
        let auditor = CommandInferenceEngine()
        let host = HostMetricsSampler(processInspector: inspector)

        // 预热一轮：首轮没有 CPU 基准，且 dyld / IOKit 的首次调用成本不该算进稳态。
        _ = await pipeline.detectAgents(using: ReplaySnapshot(records: await inspector.scanProcesses()))
        _ = await host.sampleSystem()

        var samples: [Stage: [Double]] = [:]
        for stage in Stage.allCases { samples[stage] = [] }
        var recordCounts: [Int] = []
        var agentCounts: [Int] = []
        var commandCounts: [Int] = []
        var bundlePathCounts: [Int] = []
        var cpuFromScan: [Double] = []
        var cpuFromMetrics: [Double] = []
        var distanceBetweenEntries: [Double] = []

        for _ in 0..<Self.rounds {
            let tickStart = DispatchTime.now().uptimeNanoseconds
            var mark = tickStart
            func lap(_ stage: Stage) {
                let now = DispatchTime.now().uptimeNanoseconds
                samples[stage, default: []].append(Double(now - mark) / 1_000_000)
                mark = now
            }

            let records = await inspector.scanProcesses()
            lap(.scanProcesses)

            let agents = await pipeline.detectAgents(using: ReplaySnapshot(records: records))
            lap(.detectAgents)

            // 绕过管线逐条直接调策略链：用来看「策略本身」占 `detectAgents` 的几成。
            // ⚠️ 它**不**与 detectAgents 相加（见文件头坑 1）。
            let tree = ProcessTreeIndex(records: records)
            let chain = pipeline.strategies
            for record in records {
                let context = DetectionContext(ancestors: tree.ancestors(of: record.pid))
                for strategy in chain where strategy.detect(record, context: context) != nil { break }
            }
            lap(.strategyChainOnly)

            // 单独再量一遍 Bundle Identifier 策略：它是这条链里唯一会碰磁盘的一段
            // （`Bundle(url:)` 读 Info.plist，实测叶帧落在 lstat 与符号链接解析）。
            let bundleStrategy = BundleIdentifierStrategy()
            for record in records {
                _ = bundleStrategy.detect(record, context: DetectionContext())
            }
            lap(.bundleIDStrategy)

            // 生产口径：引擎传的是「上一 tick 的时刻」，稳态下绝大多数老进程在归因之前
            // 就被 `startTime < since` 挡掉。传 .distantPast 量的是爆发尖峰（见文件头坑 2）。
            let commands = auditor.inferCommands(
                processes: records, agents: agents,
                since: Date().addingTimeInterval(-3.2)
            )
            lap(.inferCommands)

            _ = await host.sampleSystem()
            lap(.sampleSystem)

            let pids = Set(agents.flatMap { [$0.pid] + $0.childPIDs }).sorted()
            _ = await host.sampleProcesses(pids: pids)
            lap(.sampleProcessesByPID)

            // CPU% 两个入口对照：本轮全表扫描算出的值 vs 紧接着按 pid 再取一次的值。
            // 两者必须是同一个数（求差窗口 = 一个 tick）。若按 pid 那条明显偏小，
            // 说明它拿本轮扫描刚写下的读数当了基准 ⇒ 窗口塌缩成两次入口之间那几十毫秒。
            let mine = Int32(ProcessInfo.processInfo.processIdentifier)
            let again = inspector.metrics(for: [mine])

            recordCounts.append(records.count)
            agentCounts.append(agents.count)
            commandCounts.append(commands.count)
            bundlePathCounts.append(Set(records.compactMap {
                DetectionHygiene.enclosingAppBundle($0.executablePath)
            }).count)
            cpuFromScan.append(records.first { $0.pid == mine }?.cpuPercent ?? -1)
            cpuFromMetrics.append(again[mine]?.cpuPercent ?? -1)
            distanceBetweenEntries.append(
                Double(DispatchTime.now().uptimeNanoseconds - tickStart) / 1_000_000
            )
        }

        func median(_ xs: [Double]) -> Double {
            let s = xs.sorted()
            guard !s.isEmpty else { return 0 }
            return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
        }

        var total = 0.0
        // 出处标注：这张表**必须**自带 load 与构建档，否则拿不到判据的人会把 debug 的数
        // 当成 release 的数用（本仓因「拿 debug 读数判 release 约束」错两次）。
        var load = [Double](repeating: 0, count: 3)
        getloadavg(&load, 3)
        #if DEBUG
        let buildConfig = "DEBUG（不可用于判据，只作对照）"
        #else
        let buildConfig = "RELEASE（主口径）"
        #endif
        print("TICK-BREAKDOWN 构建档=\(buildConfig)")
        print(String(format: "TICK-BREAKDOWN 机器状态=load %.2f / %.2f / %.2f，活跃核心 %d，编译器进程数请另行 pgrep（load 非个位数时只取差值，不取达标与否）",
                     load[0], load[1], load[2], ProcessInfo.processInfo.activeProcessorCount))
        for stage in Stage.allCases {
            let m = median(samples[stage] ?? [])
            // `detectAgents` 已经把「策略链 + Bundle ID」那两段含在里面，所以合计只加
            // 引擎真实会付的段：scan / detect / infer / sampleSystem / sampleProcesses。
            if stage != .strategyChainOnly, stage != .bundleIDStrategy { total += m }
            print("TICK-BREAKDOWN \(stage.label.padding(toLength: 26, withPad: " ", startingAt: 0))= \(String(format: "%6.2f", m)) ms")
        }
        print("TICK-BREAKDOWN 合计(引擎真实付的段)      = \(String(format: "%6.2f", total)) ms **墙钟**，且不含 syncProjects/落库/未量段"
            + "——判加总请用 tick-account，不要拿它去减实测每 tick（见文件头 ⚠️）")
        print("TICK-BREAKDOWN records=\(recordCounts) agents=\(agentCounts) 命令候选=\(commandCounts)")
        print("TICK-BREAKDOWN 不同 .app 路径数=\(bundlePathCounts)（对比 records 即 Bundle ID 读取的去重命中面）")
        print("TICK-BREAKDOWN 按 pid 取数距本轮全表扫描中位 \(String(format: "%.1f", median(distanceBetweenEntries))) ms")
        print("TICK-BREAKDOWN 本进程 cpuPercent 全表口径=\(cpuFromScan.map { String(format: "%.2f", $0) }) 按pid口径=\(cpuFromMetrics.map { String(format: "%.2f", $0) })")

        // 只断「这把尺子本身还在量东西」，不判预算——判据一律是人读输出 + 静默窗。
        #expect(recordCounts.allSatisfy { $0 > 100 }, "快照只有 \(recordCounts) 条记录 ⇒ 环境或采集器变了，本表无意义")
        #expect(samples.values.flatMap { $0 }.allSatisfy { $0 >= 0 && $0.isFinite }, "有阶段计时出现负数或非有限值 ⇒ 分段边界写错了")
        #expect(total > 0, "六个阶段全为 0 ⇒ 计时根本没生效")
    }
}
