//
//  GPUActivityTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-Perf
//
//  整机 GPU 活动读取的单元测试。解析与内核解耦，所以「缺键 / 越界 / 多节点」
//  都能构造；最后一条跑真机，证明这台机器上确实读得到（或诚实的 nil）。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

@Suite("Telemetry：整机 GPU 活动近似值", .timeLimit(.minutes(1)))
struct GPUActivityTests {

    private func node(_ stats: [String: Any]?) -> [String: Any] {
        var properties: [String: Any] = [:]
        if let stats { properties["PerformanceStatistics"] = stats }
        return properties
    }

    @Test("读到 Device Utilization % 即取该值（保留小数，不取整）")
    func readsDeviceUtilization() {
        let value = GPUActivityReader.activityPercent(from: [node([GPUActivityReader.statisticKey: 67.5])])
        #expect(value == 67.5)
    }

    @Test("缺 PerformanceStatistics / 缺键 / 值不是数字：一律 nil，不回落成 0%")
    func missingKeysYieldNil() {
        #expect(GPUActivityReader.activityPercent(from: [node(nil)]) == nil)
        #expect(GPUActivityReader.activityPercent(from: [node(["Tiler Utilization %": 42])]) == nil)
        #expect(GPUActivityReader.activityPercent(from: [node([GPUActivityReader.statisticKey: "busy"])]) == nil)
        #expect(GPUActivityReader.activityPercent(from: []) == nil)
    }

    @Test("越界值按不可得处理：裁剪到 0…100 会把垃圾伪装成读数")
    func outOfRangeYieldsNil() {
        #expect(GPUActivityReader.activityPercent(from: [node([GPUActivityReader.statisticKey: 137])]) == nil)
        #expect(GPUActivityReader.activityPercent(from: [node([GPUActivityReader.statisticKey: -5])]) == nil)
    }

    @Test("多节点（独显 + 核显）：跳过给不出值的节点，取第一个可用的")
    func firstUsableNodeWins() {
        let unusable = node(["IOGLBundleName": "AppleMetalOpenGLRenderer"])
        let usable = node([GPUActivityReader.statisticKey: 12])
        #expect(GPUActivityReader.activityPercent(from: [unusable, usable]) == 12)
    }

    @Test("真机：IOAccelerator 给的数必须落在 0…100，拿不到就是 nil")
    func realMachineReadingIsInRangeOrNil() {
        // 不用「读不到就跳过」：读不到本身就是这条链要如实反映的结局，
        // 断言的是不变量——要么区间内的真值，要么 nil，绝不出区间外的数。
        let value = GPUActivityReader().read()
        if let value {
            #expect((0...100).contains(value))
            print("[真机 GPU] 整机活动近似值 \(value)%（IOAccelerator Device Utilization %）")
        } else {
            print("[真机 GPU] 本机不可得 —— UI 须显示「不可得」，不得显示 0%")
        }
    }
}
