//
//  InsightStatistics.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation

/// 分析层共用的纯统计工具。
///
/// 约定：所有函数对空输入返回 `nil` 而不是 `0`，以便上层区分「没有数据」与「数据为零」。
/// 所有函数无状态、无 IO、不读取当前时间。
public enum InsightStatistics {
    /// 算术平均；空序列返回 `nil`。
    public static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var total = 0.0
        for value in values { total += value }
        return total / Double(values.count)
    }

    /// 总体标准差（除以 n）；空序列返回 `nil`，单点返回 `0`。
    public static func populationStdev(_ values: [Double]) -> Double? {
        guard let average = mean(values), !values.isEmpty else { return nil }
        guard values.count > 1 else { return 0 }
        var sumOfSquares = 0.0
        for value in values {
            let delta = value - average
            sumOfSquares += delta * delta
        }
        return (sumOfSquares / Double(values.count)).squareRoot()
    }

    /// 样本标准差（除以 n-1）；样本量 < 2 时返回 `nil`（此时离散度不可估计）。
    public static func sampleStdev(_ values: [Double]) -> Double? {
        guard values.count >= 2, let average = mean(values) else { return nil }
        var sumOfSquares = 0.0
        for value in values {
            let delta = value - average
            sumOfSquares += delta * delta
        }
        return (sumOfSquares / Double(values.count - 1)).squareRoot()
    }

    /// 标准分数。`stdev <= 0` 时返回 `nil`，避免常量序列除零后把「无波动」误报成异常。
    public static func zScore(value: Double, mean average: Double, stdev: Double) -> Double? {
        guard stdev > 0 else { return nil }
        return (value - average) / stdev
    }

    /// 线性插值分位数（与 numpy 默认 `linear` / R type 7 一致）。
    ///
    /// 排序后取 `h = (n-1) * p`，在相邻两点间线性插值。
    /// 空序列返回 `nil`；单点返回该点；`p` 会被夹到 `0...1`。
    public static func percentile(_ values: [Double], at p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        guard values.count > 1 else { return values[0] }
        let sorted = values.sorted()
        let clamped = min(1, max(0, p))
        let position = Double(sorted.count - 1) * clamped
        let lowerIndex = Int(position.rounded(.down))
        let upperIndex = Int(position.rounded(.up))
        let fraction = position - Double(lowerIndex)
        if lowerIndex == upperIndex { return sorted[lowerIndex] }
        let lower = sorted[lowerIndex]
        let upper = sorted[upperIndex]
        return lower + (upper - lower) * fraction
    }

    /// 夹到 `0...1`；`nan` 归零。
    public static func clamp01(_ value: Double) -> Double {
        if value.isNaN || value.isInfinite { return 0 }
        return min(1, max(0, value))
    }

    /// 相对上限归一化：`raw / ceiling`。`ceiling <= 0` 时返回 `0`（避免除零）。
    public static func ratio(_ raw: Double, to ceiling: Double) -> Double {
        guard ceiling > 0 else { return 0 }
        let result = raw / ceiling
        if result.isNaN || result.isInfinite { return 0 }
        return result
    }

    /// 等比衰减累加：`1 + r + r² + … + r^(count-1)`。
    ///
    /// 用于「同一文件被反复修改」的边际递减——第 1 次改动记满权重，其后逐次衰减。
    /// `count <= 0` 返回 `0`；`r == 1` 时退化为 `count`。
    public static func decayedSum(count: Int, decay: Double) -> Double {
        guard count > 0 else { return 0 }
        guard decay != 1 else { return Double(count) }
        return (1 - pow(decay, Double(count))) / (1 - decay)
    }

    /// 半衰期衰减：距今 `ageSeconds` 的值衰减到 `0.5^(ageSeconds / halfLifeSeconds)`。
    ///
    /// 未来时间（`ageSeconds < 0`）按 `0` 处理，返回 `1`；`halfLifeSeconds <= 0` 时除 `now` 外全部归零。
    public static func recencyWeight(ageSeconds: Double, halfLifeSeconds: Double) -> Double {
        if ageSeconds <= 0 { return 1 }
        guard halfLifeSeconds > 0 else { return 0 }
        return pow(0.5, ageSeconds / halfLifeSeconds)
    }

    /// 最小二乘斜率（行/单位 x）。样本 < 2 或 x 全部相同（斜率不可定义）返回 `nil`。
    public static func linearSlope(xs: [Double], ys: [Double]) -> Double? {
        guard xs.count == ys.count, xs.count >= 2 else { return nil }
        guard let averageX = mean(xs), let averageY = mean(ys) else { return nil }
        var covariance = 0.0
        var variance = 0.0
        for index in 0..<xs.count {
            let dx = xs[index] - averageX
            covariance += dx * (ys[index] - averageY)
            variance += dx * dx
        }
        guard variance > 0 else { return nil }
        return covariance / variance
    }

    /// 把时间戳分桶计数。
    ///
    /// 桶数 = `ceil((end - start) / bucketSeconds)`，至少 1 个桶；落在窗口外的时间戳按最近的边界桶计入。
    /// 参数非法（`bucketSeconds <= 0` 或 `end <= start`）返回 `nil`。
    public static func bucketCounts(
        timestamps: [Date],
        start: Date,
        end: Date,
        bucketSeconds: Double
    ) -> [Double]? {
        bucketSums(dated: timestamps.map { ($0, 1.0) }, start: start, end: end, bucketSeconds: bucketSeconds)
    }

    /// 按固定宽度时间桶累加数值（空桶记 `0`）。
    ///
    /// 分桶规则与 `bucketCounts` 一致；`date` 落在窗口外时夹到边界桶。
    public static func bucketSums(
        dated: [(date: Date, amount: Double)],
        start: Date,
        end: Date,
        bucketSeconds: Double
    ) -> [Double]? {
        guard bucketSeconds > 0 else { return nil }
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        let bucketCount = max(1, Int((span / bucketSeconds).rounded(.up)))
        var sums = [Double](repeating: 0, count: bucketCount)
        for entry in dated {
            let offset = entry.date.timeIntervalSince(start) / bucketSeconds
            let index = min(bucketCount - 1, max(0, Int(offset.rounded(.down))))
            sums[index] += entry.amount
        }
        return sums
    }

    /// 每个桶起始时刻（`count` 个，间隔 `bucketSeconds`）。参数非法返回空数组。
    public static func bucketStarts(start: Date, count: Int, bucketSeconds: Double) -> [Date] {
        guard count > 0, bucketSeconds > 0 else { return [] }
        return (0..<count).map { start.addingTimeInterval(Double($0) * bucketSeconds) }
    }

    /// 桶数量，规则同 `bucketCounts`；参数非法返回 `nil`。
    public static func bucketCount(start: Date, end: Date, bucketSeconds: Double) -> Int? {
        guard bucketSeconds > 0 else { return nil }
        let span = end.timeIntervalSince(start)
        guard span > 0 else { return nil }
        return max(1, Int((span / bucketSeconds).rounded(.up)))
    }
}
