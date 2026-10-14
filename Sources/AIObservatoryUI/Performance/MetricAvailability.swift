//
//  MetricAvailability.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-Perf
//  ─────────────────────────────────────────────────────────
//  指标读数的口径：把「还没采到」与「这台机器拿不到」分成两种空态。
//
//  为什么值得抽出来：界面上一个 `nil` 有两种含义完全相反的来源——引擎刚启动、
//  第一轮采样还没落地（等一会就有），以及这台机器压根没有这个传感器
//  （Apple Silicon 的功耗、没有驱动的机器上的 GPU，等多久都没有）。
//  两者都渲染成 "—" 或 "0"，用户就会把「采不到」读成「这台机器没有负载/没有活动」，
//  而 0% 恰好是最容易被当成结论的那个值。
//

import Foundation
import AIObservatoryCore

/// 单个指标的读数口径。
enum MetricAvailability: Hashable {
    /// 有真实读数，照常显示。
    case measured
    /// 还没有任何采样落库：等下一轮即可，不该被当成 0。
    case awaitingSample
    /// 这台机器给不出该指标：显示「不可得」，等多久都不会变成数字。
    case unavailableOnThisMachine

    /// 由「有没有样本」+「这个指标有没有值」推出口径。
    ///
    /// 有样本但指标为 `nil` ⇒ 这台机器拿不到；一条样本都没有 ⇒ 还谈不上机器能不能给。
    static func resolve(hasSamples: Bool, reading: Double?) -> MetricAvailability {
        if reading != nil { return .measured }
        return hasSamples ? .unavailableOnThisMachine : .awaitingSample
    }

    /// 瓷贴副标题文案。`metric` 只用于「不可得」时点明是哪一项，避免六个瓷贴说同一句话。
    func caption(metric: String, _ language: AppLanguage = UILanguage.current) -> String {
        switch self {
        case .measured: ""
        case .awaitingSample: PerformanceCopy.awaitingSample.text(language)
        case .unavailableOnThisMachine: PerformanceCopy.unavailableOnThisMachine.format(language, metric)
        }
    }
}
