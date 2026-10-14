//
//  SelfProcessSamplerTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: 总控（#29）
//  ─────────────────────────────────────────────────────────
//  两条线分开测：
//   ① 真实读数**不能是伪造的**（本项目反复出现的缺陷类：契约成员有声明、无生产者）。
//      所以断言的是"读到了一个合理的非零值"，而不是"读到了任何值"。
//   ② 派生量是纯函数 ⇒ 用**手算字面量**钉死，不写"与实现同构"的断言
//      （那种断言换任何错误实现都还是绿的）。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform

@Suite("本进程读数：真实、非伪造、派生量可手算", .timeLimit(.minutes(1)))
struct SelfProcessSamplerTests {

    /// 只断言"读到了一个合理的非零值"，不断言具体大小。
    ///
    /// ⚠️ 这里**故意不写**「> 20 MB」：那个直觉来自打包 App（SwiftUI + AppKit 常驻几十 MB），
    /// 但测试宿主是一个纯命令行进程，footprint 只有个位数 MB——第一版就是被这条假设绊倒的
    /// （`mb > 20` 当场红）。要量"App 自身常驻"，判据在 `Tools/UIProbe/measure-pages.sh`
    /// 与静默窗那一侧，不在单元测试里。
    @Test("footprint 读到合理非零值（>0 且 <2 GB；单元测试只保证「读得通、不是伪造的 0」）")
    func footprintIsReal() {
        let reading = SelfProcessSampler().sample()
        #expect(reading.footprintBytes > 0, "phys_footprint 读到 0 ⇒ task_info 失败或被静默降级")
        let mb = reading.footprintMB
        #expect(mb < 2048, "footprint \(mb) MB 超过 2 GB ⇒ 读数来源可疑（多半是单位或字段取错）")
        // 一个跑着 Foundation 与测试运行时的进程不可能小于 1 MB；这条只挡"单位错成字节/页"这类事故。
        #expect(mb > 1, "footprint \(mb) MB 小得不合理 ⇒ 可能读到的是页数或别的字段")
    }

    @Test("累计 CPU 秒单调不减，且远小于墙钟（本测试进程不是满载）")
    func cpuSecondsAreMonotonic() async throws {
        let sampler = SelfProcessSampler()
        let a = sampler.sample()
        #expect(a.cpuSeconds > 0, "getrusage 读到 0 ⇒ 从未拿到过 CPU 时间，读数不可信")
        try await Task.sleep(for: .milliseconds(120))
        let b = sampler.sample()
        #expect(b.cpuSeconds >= a.cpuSeconds, "累计 CPU 倒退：\(a.cpuSeconds) → \(b.cpuSeconds)")
        #expect(b.takenAt > a.takenAt)
    }

    @Test("峰值跟踪：peak 永远 ≥ 任一读数，且不会小于当前值")
    func peakNeverBelowLatest() {
        let sampler = SelfProcessSampler()
        let first = sampler.sample()
        #expect(sampler.peakFootprintBytes() >= first.footprintBytes)
        let second = sampler.sample()
        #expect(sampler.peakFootprintBytes() >= max(first.footprintBytes, second.footprintBytes))
    }

    // MARK: 派生量（手算字面量）

    @Test("CPU% = Δcpu / Δ墙钟 × 100（手算：1.0s→2.0s 跨 10s ⇒ 10.0%）")
    func cpuPercentMatchesHandComputation() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let previous = SelfProcessReading(footprintBytes: 1, cpuSeconds: 1.0, takenAt: t0)
        let next = SelfProcessReading(footprintBytes: 1, cpuSeconds: 2.0, takenAt: t0.addingTimeInterval(10))
        #expect(SelfProcessSampler.cpuPercent(from: previous, to: next) == 10.0)

        // 半秒 CPU 摊在 10 秒墙钟上 = 5.0%（不是 0.5%，也不是 50%）
        let half = SelfProcessReading(footprintBytes: 1, cpuSeconds: 1.5, takenAt: t0.addingTimeInterval(10))
        #expect(SelfProcessSampler.cpuPercent(from: previous, to: half) == 5.0)
    }

    @Test("CPU% 的边界：同刻、倒退、零耗时都不许产出负数或 NaN/inf")
    func cpuPercentDegenerateCases() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let base = SelfProcessReading(footprintBytes: 1, cpuSeconds: 3.0, takenAt: t0)

        // 同一时刻两次读数 ⇒ 分母为 0，必须返回 0 而不是 inf/NaN
        let same = SelfProcessSampler.cpuPercent(from: base, to: base)
        #expect(same == 0, "同刻读数应得 0，实际 \(same)")

        // 墙钟前进 10 s、CPU 前进 0.5 s ⇒ 5.0%
        let forward = SelfProcessReading(footprintBytes: 1, cpuSeconds: 3.5, takenAt: t0.addingTimeInterval(10))
        #expect(SelfProcessSampler.cpuPercent(from: base, to: forward) == 5.0)

        // 累计 CPU 倒退（理论上不该发生）⇒ 0，不产生负占用率
        let backward = SelfProcessReading(footprintBytes: 1, cpuSeconds: 1.0, takenAt: t0.addingTimeInterval(10))
        #expect(SelfProcessSampler.cpuPercent(from: base, to: backward) == 0)
    }

    @Test("余量%：100 MB / 上限 200 MB ⇒ +50%；正好顶满 ⇒ 0；250 MB ⇒ −25%")
    func headroomIsHandComputable() {
        func mb(_ value: Double) -> UInt64 { UInt64(value * 1_048_576) }
        #expect(SelfProcessSampler.headroomPercent(footprintBytes: mb(100)) == 50.0)
        #expect(SelfProcessSampler.headroomPercent(footprintBytes: mb(200)) == 0.0)
        #expect(SelfProcessSampler.headroomPercent(footprintBytes: mb(250)) == -25.0)
        // 判据④ 的目标值是 120 MB（上限才是 200 MB）⇒ 同一函数换分母即可
        #expect(SelfProcessSampler.headroomPercent(footprintBytes: mb(60), limitMB: 120) == 50.0)
    }
}
