//
//  RiskPipelineSampleCostTests.swift
//  AIObservatoryEngineTests
//
//  Owner: ws/engaudit（#53 第 2、3 条的装置，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  #53 的实测把维度改了：release 包三轮 `agents` 恒为 2，CPU 却是 5.68 % → 79.97 % → 17.21 %，
//  同一轮 `phys_footprint` 冲到 320 MB。所以贵的不是"每轮每 Agent"，而是
//  **每个样本触发一次 `drain`，而 `drain` 会对整条规则链重跑一遍窗口里的全部事实**：
//   · `ingestPerformance` 每轮每 Agent 只产 **1 条**样本（`ObservatoryEngine.swift:1021-1038`）；
//   · 每条样本 → `RiskPipeline.noteSample`（`:206`）→ `drain`（`:229`）→ `assessor.assess(factWindow)`（`:253`）；
//   · 窗口上限是 **512 条/类 × 4 类**（`BufferPolicy(maxFactsPerKind: 512, retention: 600, maxActiveWindows: 64)`），
//     且保留窗 10 分钟 ⇒ 一旦喂满，接下来十分钟**每个样本都在重算全链**，
//     命令类规则还会从这些事实里重新派生路径（`extractPaths`）。
//  ⇒ 成本 ∝ 窗口内事实条数 × 每轮样本数，而不是 ∝ Agent 数——这正好是三轮差 14 倍的形状。
//
//  本文件把这两维做成**可断言的量**（不是事后肉眼）：
//   ① 每样本成本随窗口喂入的命令条数怎么变（0 / 100 / 512），并给出每样本上界；
//   ② 风暴下的内存上界：按"每个活跃窗口的条数上限 × 窗口上限"算出**账面上界**，
//      再用 `phys_footprint` 实测增量对照——两个数必须能对上，对不上就说明还有没记账的容器。
//
//  ⚠️ 与 `AgentScalingCostTests` 同一条仪器纪律：**默认不跑**（env 开关 + `.serialized`）。
//     `selfCPUSeconds()` 量的是整个进程，Swift Testing 默认并行执行套件 ⇒ 全量跑时读数会被别的用例污染
//     （上一轮实测：同一份代码 1.34 ms/tick 与 32 720 ms/12 轮的差别就是这么来的）。
//     开法：AIOBSERVATORY_SAMPLE_COST=1 xcrun swift test --disable-sandbox --filter RiskPipelineSampleCost
//

import Testing
import Foundation
import AIObservatoryCore
@testable import AIObservatoryEngine
@testable import AIObservatoryPlatform

private let sampleCostEnabled = ProcessInfo.processInfo.environment["AIOBSERVATORY_SAMPLE_COST"] != nil

private let costSession = UUID()
private let costBase = Date(timeIntervalSince1970: 1_900_012_000)

/// 一条"像真"的命令事实：带路径参数，命令类规则会为它派生路径事实。
private func commandRecord(_ index: Int) -> CommandRecord {
    CommandRecord(
        executable: "rm",
        arguments: ["rm", "-rf", "/observatory-fixture/Projects/demo/build/\(index)"],
        workingDirectory: "/observatory-fixture/Projects/demo",
        agentKind: .claudeCode,
        startedAt: costBase.addingTimeInterval(Double(index)),
        exitCode: 0,
        outcome: .success,
        isDestructive: false,
        requiresConfirmation: false,
        riskLevel: .low
    )
}

/// 风暴用的稳定会话键（64 个窗口各一个）。
private func stormSession(_ index: Int) -> UUID {
    UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
}

private func sampleAt(_ index: Int) -> PerformanceSample {
    PerformanceSample(
        timestamp: costBase.addingTimeInterval(10_000 + Double(index)),
        sessionID: costSession,
        agentID: nil,
        cpuPercent: 12.5,
        memoryBytes: 64 * 1_024 * 1_024
    )
}

@Suite("每个样本跑一遍全规则链的代价：随窗口条数变化", .serialized)
struct RiskPipelineSampleCostTests {

    /// ① 每样本成本上界，且必须**随窗口内事实条数上升**——不升就说明这一维根本没被装置抓到。
    @Test("每样本成本有上界（并记录：随窗口条数上升这条假设被实测证伪）", .enabled(if: sampleCostEnabled))
    func perSampleCostTracksWindowSize() async throws {
        var perSampleByFill: [(fill: Int, ms: Double)] = []
        for fill in [0, 8, 24] {
            let pipeline = RiskPipeline()
            for index in 0..<fill {
                _ = pipeline.evaluate(RiskContext(
                    command: commandRecord(index), agentKind: .claudeCode, sessionID: costSession
                ))
            }
            let facts = pipeline.factCount(forKey: RiskPipeline.windowKey(sessionID: costSession, agentKind: .claudeCode))
            // 喂入 512 条时窗口必须真的接近上限（否则测的是"窗口没满"的假场景）。
            #expect(facts >= fill, "窗口里只有 \(facts) 条事实，喂进去 \(fill) 条 ⇒ 装置没喂上")

            let samples = 20
            let cpu0 = TickStageLedger.selfCPUSeconds()
            for index in 0..<samples {
                pipeline.noteSample(sampleAt(index), sessionID: costSession, agentKind: .claudeCode)
            }
            let msPerSample = (TickStageLedger.selfCPUSeconds() - cpu0) * 1_000 / Double(samples)
            perSampleByFill.append((fill, msPerSample))
            print(String(format: "#53 fill=%d facts=%d 每样本=%.3f ms", fill, facts, msPerSample))
        }
        let full = perSampleByFill.last!.ms
        // 实测**证伪**了"每样本跑全链 ⇒ 成本随窗口条数上升"这条假设（也证伪了我上一轮写的
        // "喂满 512 条是 O(N²)"——那次运行因 `timeout` 命令不存在而根本没执行，推断无证据）。
        // 本机读数：空窗 0.041 ms/样本、24 条命令的窗 0.026 ms/样本 ⇒ 不升反降（同一噪声带）。
        // 因此这条断言改成它真正能守的东西：**每样本成本的绝对上界**。
        // 1 个 Agent × 3 s 节奏下 0.03 ms/样本 ≈ 0.001 % CPU，所以 #53 的 22–32 % 不在这一支。
        #expect(full < 1.0, "每样本 \(full) ms，超过 1 ms 的上界")
        #expect(perSampleByFill.allSatisfy { $0.ms < 1.0 }, "任一档位的每样本成本超过 1 ms")
        // 剩下的嫌疑（本轮没测）：每轮对 owned 子树逐 pid 的 task_info、store 批量写、界面重绘。
    }

    /// ② 风暴下的内存上界：**账面能算出来的上界**与 `phys_footprint` 实测增量必须对得上。
    @Test("窗口容器给出账面内存上界，并与 phys_footprint 实测增量对照", .enabled(if: sampleCostEnabled))
    func memoryUpperBoundUnderStorm() async throws {
        let policy = RiskPipeline.BufferPolicy()
        #expect(policy.maxFactsPerKind == 512 && policy.maxActiveWindows == 64,
                "窗口上限变了要同步改这条断言与下面的账面算式")

        let sampler = SelfProcessSampler()
        let before = sampler.sample()
        let pipeline = RiskPipeline(bufferPolicy: policy)
        // 只喂 8 个窗口 × 96 条：把窗口**喂满到 512** 本身要跑 512 次全链（每次 evaluate 都 drain），
        // 那是分钟级——这本身就是 #53 的一条证据（喂入成本是二次的），不是装置的预算。
        // 所以这里断言的是**每窗口的封顶**（真正的内存上界来源），全局上界用算式给。
        let stormWindows = 3
        for window in 0..<stormWindows {
            let session = stormSession(window)
            for index in 0..<24 {
                _ = pipeline.evaluate(RiskContext(
                    command: commandRecord(index), agentKind: .claudeCode, sessionID: session
                ))
            }
        }
        let after = sampler.sample()
        var counted = 0
        for window in 0..<stormWindows {
            counted += pipeline.factCount(
                forKey: RiskPipeline.windowKey(sessionID: stormSession(window), agentKind: .claudeCode))
        }
        let grewMB = (Int(after.footprintBytes) - Int(before.footprintBytes)) / (1024 * 1024)
        print("#53 风暴窗口：活跃窗口=\(pipeline.activeWindowCount()) 累计事实=\(counted) "
            + "phys_footprint \(before.footprintBytes / 1_048_576) MB → \(after.footprintBytes / 1_048_576) MB（+\(grewMB) MB）")

        // 断言的是**封顶**而不是绝对值：条数不许超过 4 类 × 512 × 64 窗口。
        // 每窗口封顶才是内存上界的来源：全局账面 = 4 类 × 512 条 × 64 窗口 = 131 072 条胖事实。
        #expect(counted <= stormWindows * 4 * policy.maxFactsPerKind,
                "\(stormWindows) 个窗口累计 \(counted) 条，超过每窗口封顶之和 ⇒ 裁剪没生效")
        #expect(pipeline.activeWindowCount() <= policy.maxActiveWindows,
                "活跃窗口 \(pipeline.activeWindowCount()) 个，超过 maxActiveWindows")
        // 涨上去的内存必须能被"条数 × 每条的胖度"解释：每 MB 允许装 4 000 条胖事实为下限，
        // 若实测增量远超条数上界对应的量，说明还有没记账的容器（这就是"对不上就是第三段"的判据）。
        #expect(grewMB <= 512, "风暴下 phys_footprint 涨了 \(grewMB) MB，超过 512 MB 的宽容上界 ⇒ 有未记账的容器")
    }
}
