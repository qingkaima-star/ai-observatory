//
//  SelfProcessInstrument.swift
//  AIObservatoryApp
//
//  Owner: master-controller（组合根）
//  ─────────────────────────────────────────────────────────
//  ICR-0003 方案 B 的装配：把 Platform 的 `SelfProcessSampler` 交给界面的
//  `SelfProcessReadingSource`。UI 只依赖 Core 的协议（这是各模块能并行的前提），
//  所以跨模块那条线只能由组合根接——`AIObservatoryApp` 本来就同时依赖
//  Platform 与 UI（`Package.swift`），不需要动 manifest。
//
//  为什么是**一个实例从头用到尾**：`SelfProcessSampler` 内部记着窗口序列与
//  进程存活期峰值；每次 body 求值都新建一个的话，峰值永远等于当前值、
//  CPU 差值永远算不出来（少于两条读数），那一格会稳定显示"还没有窗口"。
//

import AIObservatoryPlatform
import AIObservatoryUI
import Foundation

/// 把 `SelfProcessSampler` 适配成界面接收端（字段同名同类型，只是跨模块）。
struct SelfProcessInstrument: SelfProcessReadingSource {

    /// 全进程唯一实例。AGENTS.md §5 限制 `shared` 只用于 App 层装配，这里正是装配根；
    /// 而且**必须**唯一：`body` 每次求值都新建的话，窗口序列被清零、
    /// 存活期峰值退化成当前值，那一格会永远停在"还没有窗口"。
    static let shared = SelfProcessInstrument()

    private let sampler = SelfProcessSampler()

    func readSelfProcessSample(now: Date) -> SelfProcessSamplePoint? {
        let reading = sampler.sample(now: now)
        // 读不到 ≠ 0 MB：仪器失败时返回的是全零读数，而界面协议要求"读不到给 nil"，
        // 否则那一格会把"取不到"画成"本 App 占用 0 字节"——那是撒谎。
        guard reading.footprintBytes > 0 else { return nil }
        return SelfProcessSamplePoint(
            footprintBytes: reading.footprintBytes,
            cpuSeconds: reading.cpuSeconds,
            takenAt: reading.takenAt
        )
    }
}
