//
//  PerformanceDisplay.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-Perf
//  ─────────────────────────────────────────────────────────
//  网络与 GPU 两块遥测的显示口径，收成纯函数。
//
//  为什么要抽出来：这两项的「空」比数字更容易骗人。网络本轮不可信（计数器回绕、
//  网卡重连）和这台机器压根读不到计数器，在界面上都只有一个可选字段为 nil，
//  但给用户的结论完全相反；GPU 更是只有整机近似值——一旦这里写成 `?? 0`，
//  页面就会宣称「这台机器 GPU 0%」，而真相是「没读到」。
//  越界值同样按不可得处理：把 137% 裁剪成 100% 是把垃圾伪装成读数。
//

import Foundation
import AIObservatoryCore

enum PerformanceDisplay {

    // MARK: - 网络

    /// 速率大字号；没有可信读数时是「—」，**不是** `0 B/s`。
    static func networkValue(bytesPerSecond: Double?) -> String {
        guard let bytesPerSecond, bytesPerSecond >= 0 else { return "—" }
        return ByteFormat.rate(bytesPerSecond)
    }

    /// 网络瓷贴副标题：可信读数说峰值，不可信读数说清是哪一类「没有」。
    static func networkCaption(
        bytesPerSecond: Double?,
        peak: Double?,
        availability: NetworkRateAvailability?,
        hasSamples: Bool,
        _ language: AppLanguage = UILanguage.current
    ) -> String {
        if bytesPerSecond != nil {
            guard let peak, peak > 0 else {
                return PerformanceCopy.networkNoTraffic.text(language)   // 真 0，与「采不到」是两句不同的话
            }
            return PerformanceCopy.networkIntervalPeak.format(language, ByteFormat.rate(peak))
        }
        guard hasSamples else {
            // 一条样本都没有也可能已经知道答案：`getifaddrs` 第一轮就失败，
            // 这时候说「等待首次采样」是让用户白等。
            return availability == .countersUnreadable
                ? MetricAvailability.unavailableOnThisMachine.caption(metric: PerformanceCopy.metricNetworkRate.text(language), language)
                : MetricAvailability.awaitingSample.caption(metric: PerformanceCopy.metricNetworkRate.text(language), language)
        }
        let networkRate = PerformanceCopy.metricNetworkRate.text(language)
        switch availability {
        case .awaitingFirstSample: return MetricAvailability.awaitingSample.caption(metric: networkRate, language)
        case .noElapsedTime: return PerformanceCopy.networkNoElapsed.text(language)
        case .counterRegression: return PerformanceCopy.networkCounterWrap.text(language)
        case .interfaceRemoved: return PerformanceCopy.networkInterfaceChanged.text(language)
        case .countersUnreadable: return MetricAvailability.unavailableOnThisMachine.caption(metric: networkRate, language)
        case nil: return PerformanceCopy.networkNoColumn.text(language)   // v3 之前的老数据
        }
    }

    // MARK: - GPU

    /// 越界值与 nil 一起归为「不可得」：判断只做这一次，免得三处口径各漂一次。
    static func gpuPercentOrNil(_ percent: Double?) -> Double? {
        guard let percent, (0...100).contains(percent) else { return nil }
        return percent
    }

    /// 整机 GPU 活动近似值；`nil` 或越界都是「不可得」，显示为「—」。
    static func gpuValue(percent: Double?) -> String {
        guard let value = gpuPercentOrNil(percent) else { return "—" }
        return String(format: "%.0f", value)
    }

    static func gpuUnit(percent: Double?) -> String {
        gpuPercentOrNil(percent) == nil ? "" : "%"
    }

    static func gpuCaption(percent: Double?, hasSamples: Bool,
                           _ language: AppLanguage = UILanguage.current) -> String {
        let value = gpuPercentOrNil(percent)
        guard value != nil else {
            return MetricAvailability
                .resolve(hasSamples: hasSamples, reading: value)
                .caption(metric: PerformanceCopy.metricGPUActivity.text(language), language)
        }
        return PerformanceCopy.gpuWholeMachineOnly.text(language)
    }
}
