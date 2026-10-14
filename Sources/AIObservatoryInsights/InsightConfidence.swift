//
//  InsightConfidence.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation

/// 分析结果的可信度。
///
/// 本项目的首要卖点是「可信」，因此任何洞察都必须能回答「这个结论有多大概率站得住」。
/// 置信度只由**可见的证据**（样本量、覆盖时长、缺失比例）推出，绝不由模型自信程度推出。
public enum InsightConfidence: String, Codable, Sendable, CaseIterable, Hashable, Comparable {
    case low
    case medium
    case high

    public var rank: Int {
        switch self {
        case .low: return 0
        case .medium: return 1
        case .high: return 2
        }
    }

    public var displayName: String {
        switch self {
        case .low: return "LOW"
        case .medium: return "MEDIUM"
        case .high: return "HIGH"
        }
    }

    /// UI 提示：这条结论是否可以当作事实呈现。
    public var isSpeculative: Bool { self == .low }

    public static func < (lhs: InsightConfidence, rhs: InsightConfidence) -> Bool { lhs.rank < rhs.rank }
}

/// 计算置信度所需的证据强度。
///
/// 三个维度互相独立，任一维度不足都会拉低结论：
/// - `observationCount`：参与统计的样本数量；
/// - `coverageSeconds`：样本覆盖的时间跨度；
/// - `missingFieldRatio`：关键字段缺失（无法取值）的比例，取值 `0...1`。
public struct InsightEvidence: Codable, Sendable, Hashable {
    public var observationCount: Int
    public var coverageSeconds: Double
    public var missingFieldRatio: Double

    public init(observationCount: Int, coverageSeconds: Double, missingFieldRatio: Double = 0) {
        self.observationCount = max(0, observationCount)
        self.coverageSeconds = max(0, coverageSeconds)
        self.missingFieldRatio = min(1, max(0, missingFieldRatio))
    }

    /// 无任何观测。
    public static let empty = InsightEvidence(observationCount: 0, coverageSeconds: 0, missingFieldRatio: 1)

    /// 由可选值序列统计缺失比例：`nil` 视为缺失；空序列视为全部缺失。
    public static func missingRatio<Value>(of values: some Sequence<Value?>) -> Double {
        var total = 0
        var missing = 0
        for value in values {
            total += 1
            if case .none = value { missing += 1 }
        }
        guard total > 0 else { return 1 }
        return Double(missing) / Double(total)
    }
}

/// 置信度判定规则。纯函数，阈值集中在此处，便于总控统一调参。
public enum InsightConfidenceEvaluator {
    /// 达到 HIGH 需要同时满足的最低样本量 / 覆盖时长（秒）/ 可容忍缺失比例。
    public static let minimumCountForHigh = 30
    public static let minimumCoverageForHigh = 3600.0
    public static let maximumMissingForHigh = 0.10

    /// 达到 MEDIUM 的门槛，低于此即为 LOW。
    public static let minimumCountForMedium = 8
    public static let minimumCoverageForMedium = 600.0
    public static let maximumMissingForMedium = 0.35

    /// 按「样本量、覆盖时长、缺失比例」三项同时判级；任一项不达标即降级。
    public static func evaluate(_ evidence: InsightEvidence) -> InsightConfidence {
        if evidence.observationCount >= minimumCountForHigh,
           evidence.coverageSeconds >= minimumCoverageForHigh,
           evidence.missingFieldRatio <= maximumMissingForHigh {
            return .high
        }
        if evidence.observationCount >= minimumCountForMedium,
           evidence.coverageSeconds >= minimumCoverageForMedium,
           evidence.missingFieldRatio <= maximumMissingForMedium {
            return .medium
        }
        return .low
    }

    /// 组合多个置信度时取最弱一环——绝不让某个模块的自信掩盖另一模块的数据缺口。
    public static func weakest(_ levels: some Sequence<InsightConfidence>) -> InsightConfidence? {
        var result: InsightConfidence?
        for level in levels {
            guard let current = result else {
                result = level
                continue
            }
            if level < current { result = level }
        }
        return result
    }

    /// 时间跨度（秒），对空/单点输入返回 0。输入无需预排序。
    public static func coverageSeconds(of dates: some Sequence<Date>) -> Double {
        var earliest: Date?
        var latest: Date?
        for date in dates {
            if let current = earliest {
                if date < current { earliest = date }
            } else {
                earliest = date
            }
            if let current = latest {
                if date > current { latest = date }
            } else {
                latest = date
            }
        }
        guard let earliest, let latest else { return 0 }
        return max(0, latest.timeIntervalSince(earliest))
    }
}
