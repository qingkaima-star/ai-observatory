//
//  ThermalPowerReaderTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-Telemetry（性能收尾线 ws/perfclose）
//  ─────────────────────────────────────────────────────────
//  这个读数器此前**一条用例都没有**，而它的形状恰好藏着一个每-tick 成本：
//  七个候选 SMC 温度键在 Apple Silicon 的 IORegistry 里全不存在
//  （2026-09-20 实测：`ioreg -l -n AppleSMC | grep -c '"TC0C"'` 等七项命中均为 0），
//  于是每 tick 付 9 个 IOKit 系统调用换回一个 `nil`。
//
//  所以这里的断言刻意**按调用次数**做，不按耗时：
//   · 耗时在别人的负载下不是结论（§6）；
//   · "第二次一次都不调"是这台机器上唯一能让这笔开销归零的行为事实，可数、可复现、可变异检查。
//
//  ⚠️ 不缓存**温度值**是本文件另一条要钉住的口径：温度是随时间变的量，
//  缓存值等于把上一轮读数当这一轮报（那是本仓主导缺陷类"有消费者无生产者"的近亲：
//  有消费者、有值、但值是假的）。只允许缓存"哪个键有值"。
//

import Testing
import Foundation
import os   // `OSAllocatedUnfairLock`
@testable import AIObservatoryPlatform

/// 记录每次被问的是哪个键的假通道。
private final class RecordingKeyReader: Sendable {
    private struct Box: Sendable {
        var asked: [String] = []
        /// 每个键要给什么值；`nil` = 该键取不到。
        var answers: [String: Double]
        /// 下一次 `read` 强制返回它（用来证明"每轮重读"而不是把首轮的数冻住）。
        var forcedValue: Double?
    }
    private let lock = OSAllocatedUnfairLock(initialState: Box(answers: [:]))

    init(answers: [String: Double] = [:]) { lock.withLock { $0.answers = answers } }

    var askedKeys: [String] { lock.withLock { $0.asked } }
    var askCount: Int { lock.withLock { $0.asked.count } }

    /// 让下一次读数返回给定值，无论被问的是哪个键。
    func forceValue(_ value: Double?) { lock.withLock { $0.forcedValue = value } }

    func read(_ key: String) -> Double? {
        lock.withLock { box in
            box.asked.append(key)
            if let forced = box.forcedValue {
                box.forcedValue = nil
                return forced
            }
            return box.answers[key]
        }
    }
}

@Suite("WS-Telemetry：温度/功耗读数器（不得编造 + 每-tick 系统调用上界）")
struct ThermalPowerReaderTests {

    @Test("候选键全空：首轮试完 7 个，第二轮起一次都不再试")
    func exhaustedChannelStopsBeingProbed() {
        let reader = RecordingKeyReader()
        let thermal = ThermalPowerReader(readKey: reader.read)

        #expect(thermal.read().thermalCelsius == nil)
        #expect(reader.askCount == ThermalPowerReader.candidateTemperatureKeys.count,
                "首轮应把 \(ThermalPowerReader.candidateTemperatureKeys.count) 个候选键各试一次")
        #expect(thermal.temperatureChannelUnavailable)

        // 关键的一条：这笔每-tick 成本必须归零。
        let afterFirst = reader.askCount
        for _ in 0..<5 {
            #expect(thermal.read().thermalCelsius == nil, "不可得必须报 nil，不是 0.0")
        }
        #expect(reader.askCount == afterFirst,
                "已判定不可得之后不得再调 IORegistry（旧实现每 tick 付 7 次）")
    }

    @Test("命中某键：记住它、每轮只读它，且每轮都重读（不冻结上一轮的值）")
    func hitKeyIsReReadEveryRound() {
        let reader = RecordingKeyReader(answers: ["TC0D": 45.5])
        let thermal = ThermalPowerReader(readKey: reader.read)

        #expect(thermal.read().thermalCelsius == 45.5)
        #expect(reader.askedKeys == ["TC0C", "TC0D"], "按候选顺序试到命中即停，不多试")

        reader.forceValue(61.25)
        #expect(thermal.read().thermalCelsius == 61.25,
                "第二轮必须拿到新读数，而不是首轮缓存下来的 45.5")
        #expect(reader.askedKeys.count == 3, "第二轮只读那一个命中的键")
        #expect(reader.askedKeys.last == "TC0D")
        #expect(!thermal.temperatureChannelUnavailable)
    }

    @Test("功耗恒为 nil：这台机器没有公开整机功耗 API，禁止用估算值填")
    func powerIsAlwaysNil() {
        let reader = RecordingKeyReader(answers: ["TC0C": 50.0])
        let thermal = ThermalPowerReader(readKey: reader.read)
        #expect(thermal.read().powerWatts == nil)
        _ = thermal.read()
        #expect(thermal.read().powerWatts == nil)
    }

    @Test("非有限值（NaN / inf）不算命中：它落库会变成'有读数'的假象")
    func nonFiniteIsNotAHit() {
        let reader = RecordingKeyReader(answers: ["TC0C": .nan])
        let thermal = ThermalPowerReader(readKey: reader.read)
        #expect(thermal.read().thermalCelsius == nil)
        #expect(thermal.temperatureChannelUnavailable, "NaN 不是温度，应继续把剩下的键试完")
        #expect(reader.askCount == ThermalPowerReader.candidateTemperatureKeys.count)
    }

    /// 真机口径：只断"不得编造"，不断"必为 nil"——换一台真暴露了 `TC0x` 的机器，
    /// 后者会变成假红（那正是本仓反对的把环境当结论）。
    /// 打印探测结果，是为了让"本机到底取不取得到"这件事有一条可抄的实测行，
    /// 而不是靠谁在终端里手跑一次再转述。
    @Test("真通道：不给区间外的温度，也不因读不到而崩")
    func realChannelNeverFabricates() {
        let thermal = ThermalPowerReader()
        for _ in 0..<3 {
            let reading = thermal.read()
            #expect(reading.powerWatts == nil, "整机功耗在本机不可得")
            if let celsius = reading.thermalCelsius {
                #expect((0...120).contains(celsius),
                        "温度 \(celsius) °C 落在物理区间外 ⇒ 这是把别的量当成了温度")
            }
        }
        print("THERMAL-PROBE 本机实测 thermalCelsius=\(String(describing: thermal.read().thermalCelsius))"
            + " 候选键数=\(ThermalPowerReader.candidateTemperatureKeys.count)"
            + " 探测后判定通道不可得=\(thermal.temperatureChannelUnavailable)"
            + "（键不在 IORegistry 属性里，见文件头 ioreg 实测）")
    }
}
