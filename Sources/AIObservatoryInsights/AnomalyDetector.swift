//
//  AnomalyDetector.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

/// z-score 异常检测：把一条等间隔序列跟它自己的基线比，标出显著偏高 / 偏低的桶。
///
/// 本模块的全部价值在于**保护性短路**：统计意义上的「异常」只有在样本足够、序列确有波动时才成立。
/// 因此三条纪律不可协商——
/// 1. 无数据、样本量不足（`n < minimumSampleSize`）、序列恒定（标准差为 0）一律**不做任何判定**，
///    `zScore` 保持 `nil`、`isAnomalous` 保持 `false`，并在 `skippedReason` 里说清原因；
/// 2. 「没判出异常」与「数据不足以判异常」都必须能和「确实平稳」区分开，靠的是 `nil` 而不是 0；
/// 3. 绝不出现除零、`nan`、`inf`——常量序列的标准差是 0，硬除会得到 `±inf`，
///    于是「一条从未变过的曲线」会被渲染成惊天告警，这是可信审计最不能犯的错。
///
/// 纯函数：无 IO、无全局态、不读当前时间（时间一律由参数注入），因此可安全用于 Swift 6 严格并发。
public enum AnomalyDetector {
    /// 默认判定阈值（σ 倍数）。3σ 是「明显异常」的保守口径，避免把正常抖动报成事件。
    public static let defaultThreshold: Double = 3.0

    /// 默认最少样本量。低于 8 个桶时基线本身噪声远大于信号，任何 z 值都不具解释力。
    public static let defaultMinimumSampleSize: Int = 8

    // 不可判定的原因文案（集中定义，保证 `skippedReason` 与 `basis` 口径一致）。
    // 两条都走 InsightCopy：同一句理由在 `skippedReason` 与 `basis` 里必须逐字相同，
    // 分语言后若在某一处手写译文，两路就会各说一种语言。

    private static func noDataReason(_ language: AppLanguage) -> String {
        InsightCopy.anomalyNoDataReason.text(language)
    }

    /// 样本量不足时的跳过说明：`n` 与门槛都写进文案，UI 可直接展示「再攒多少桶才判」。
    private static func insufficientSampleReason(sampleSize: Int, minimumSampleSize: Int,
                                                 _ language: AppLanguage) -> String {
        InsightCopy.anomalyInsufficientSample.format(language, String(sampleSize), String(minimumSampleSize))
    }

    /// 序列恒定时的跳过说明：零方差意味着「无波动」，而不是「波动恰好为 0σ」，所以不能判。
    private static func constantSeriesReason(_ language: AppLanguage) -> String {
        InsightCopy.anomalyConstantSeries.text(language)
    }

    /// 序列含 `nan` / `inf` 时的跳过说明：这种基线没有数值意义，直接放弃判定而非给出垃圾结论。
    private static func nonFiniteReason(_ language: AppLanguage) -> String {
        InsightCopy.anomalyNonFiniteReason.text(language)
    }

    // MARK: - 核心入口

    /// 对一条等间隔序列做 z-score 判定。所有适配器最终都汇聚到这里。
    ///
    /// - Parameters:
    ///   - values: 按桶序排列的取值；空数组走「无数据」短路。
    ///   - metric: 被检测的指标语义，仅透传到结果里供 UI 标注。
    ///   - bucketStarts: 各桶起始时刻。允许 `nil` 或与 `values` 数量不等——此时对应
    ///     `observation.bucketStart` 为 `nil`，**不崩溃**：数值结论与时间标注是两件事，
    ///     拿不到时间不该妨碍统计，只是不能告诉用户「异常发生在几点」。
    ///   - bucketSeconds: 桶宽，仅用于推算覆盖时长（`n × 桶宽`）以决定置信度；
    ///     非正值按 1 秒处理，防止「桶宽未知」被误算成「零覆盖」。
    ///   - threshold: 判定阈值（σ 倍数）。
    ///   - minimumSampleSize: 样本量门槛，低于它不做任何判定。
    /// - Returns: 携带基线统计、逐桶观测与 `skippedReason` 的报告；被跳过时 `anomalousObservations` 必为空。
    public static func detect(
        values: [Double],
        metric: AnomalyMetric,
        bucketStarts: [Date]?,
        bucketSeconds: Double,
        threshold: Double = AnomalyDetector.defaultThreshold,
        minimumSampleSize: Int = AnomalyDetector.defaultMinimumSampleSize,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> AnomalyReport {
        let sampleSize = values.count

        // 短路 1：无数据。基线为 nil（不是 0），置信度只能是 low。
        guard sampleSize > 0 else {
            return AnomalyReport(
                metric: metric,
                observations: [],
                anomalousObservations: [],
                baselineMean: nil,
                baselineStdev: nil,
                threshold: threshold,
                sampleSize: 0,
                minimumSampleSize: minimumSampleSize,
                isBaselineSufficient: false,
                skippedReason: noDataReason(interfaceLanguage),
                confidence: .low,
                basis: InsightCopy.anomalyNoDataBasis.text(interfaceLanguage)
            )
        }

        // 基线统计对「展示」始终有用，即使命中跳过分支也一并给出（nil 表示确实算不出）。
        let baselineMean = InsightStatistics.mean(values)
        let baselineStdev = InsightStatistics.populationStdev(values)

        // 短路 2：样本量不足。逐桶只记观测值，不给 z、不给方向、不判异常。
        guard sampleSize >= minimumSampleSize else {
            return undetectedReport(
                metric: metric,
                values: values,
                bucketStarts: bucketStarts,
                baselineMean: baselineMean,
                baselineStdev: baselineStdev,
                threshold: threshold,
                minimumSampleSize: minimumSampleSize,
                skippedReason: insufficientSampleReason(sampleSize: sampleSize,
                                                          minimumSampleSize: minimumSampleSize,
                                                          interfaceLanguage),
                basis: InsightCopy.anomalyBaselineWithMinimum.format(
                    interfaceLanguage,
                    numberText(baselineMean, interfaceLanguage),
                    numberText(baselineStdev, interfaceLanguage),
                    String(sampleSize),
                    String(minimumSampleSize),
                    insufficientSampleReason(sampleSize: sampleSize,
                                             minimumSampleSize: minimumSampleSize,
                                             interfaceLanguage)
                )
            )
        }

        // 短路 3a：基线本身不可用（含 nan / inf）。
        guard let meanValue = baselineMean, let stdevValue = baselineStdev,
              meanValue.isFinite, stdevValue.isFinite else {
            return undetectedReport(
                metric: metric,
                values: values,
                bucketStarts: bucketStarts,
                baselineMean: baselineMean,
                baselineStdev: baselineStdev,
                threshold: threshold,
                minimumSampleSize: minimumSampleSize,
                skippedReason: nonFiniteReason(interfaceLanguage),
                basis: InsightCopy.anomalyBaselineNotComputable.format(
                    interfaceLanguage, String(sampleSize), nonFiniteReason(interfaceLanguage)
                )
            )
        }

        // 短路 3b：序列恒定（总体标准差为 0，常量序列与全零序列都在此）。绝不进入除法。
        guard stdevValue > 0 else {
            return undetectedReport(
                metric: metric,
                values: values,
                bucketStarts: bucketStarts,
                baselineMean: baselineMean,
                baselineStdev: baselineStdev,
                threshold: threshold,
                minimumSampleSize: minimumSampleSize,
                skippedReason: constantSeriesReason(interfaceLanguage),
                basis: InsightCopy.anomalyBaselinePlain.format(
                    interfaceLanguage,
                    numberText(meanValue, interfaceLanguage),
                    numberText(stdevValue, interfaceLanguage),
                    String(sampleSize),
                    constantSeriesReason(interfaceLanguage)
                )
            )
        }

        // 正常路径：z = (v - mean) / stdev，超阈值才算异常。
        var observations: [AnomalyObservation] = []
        observations.reserveCapacity(sampleSize)
        var anomalousObservations: [AnomalyObservation] = []
        for index in values.indices {
            let rawZ = InsightStatistics.zScore(value: values[index], mean: meanValue, stdev: stdevValue)
            // 单个取值本身可能是 nan / inf（脏数据）：这种点只保留观测值，z 记 nil，不参与判定。
            let z: Double?
            if let rawZ, rawZ.isFinite {
                z = rawZ
            } else {
                z = nil
            }
            var direction: AnomalyDirection?
            if let z {
                if z >= threshold {
                    direction = .spike
                } else if z <= -threshold {
                    direction = .drop
                }
            }
            let observation = AnomalyObservation(
                metric: metric,
                bucketIndex: index,
                bucketStart: bucketStart(at: index, in: bucketStarts, matching: sampleSize),
                value: values[index],
                zScore: z,
                isAnomalous: direction != nil,
                direction: direction
            )
            observations.append(observation)
            if direction != nil {
                anomalousObservations.append(observation)
            }
        }

        let interval = bucketSeconds.isFinite ? max(bucketSeconds, 1) : 1
        let confidence = InsightConfidenceEvaluator.evaluate(
            InsightEvidence(
                observationCount: sampleSize,
                coverageSeconds: Double(sampleSize) * interval,
                missingFieldRatio: 0
            )
        )
        let anomalousCount = anomalousObservations.count
        let outcomeText = anomalousCount == 0
            ? InsightCopy.anomalyNoneFound.text(interfaceLanguage)
            : InsightCopy.anomalyFoundCount.format(interfaceLanguage, String(anomalousCount))

        return AnomalyReport(
            metric: metric,
            observations: observations,
            anomalousObservations: anomalousObservations,
            baselineMean: meanValue,
            baselineStdev: stdevValue,
            threshold: threshold,
            sampleSize: sampleSize,
            minimumSampleSize: minimumSampleSize,
            isBaselineSufficient: true,
            skippedReason: nil,
            confidence: confidence,
            basis: InsightCopy.anomalyBaselineWithThreshold.format(
                interfaceLanguage,
                numberText(meanValue, interfaceLanguage),
                numberText(stdevValue, interfaceLanguage),
                String(sampleSize),
                thresholdText(threshold, interfaceLanguage),
                outcomeText
            )
        )
    }

    // MARK: - 适配器

    /// 事件速率异常：按固定窗口分桶统计**每分钟事件数**。
    ///
    /// 窗口非法（`windowEnd <= windowStart` 或 `bucketSeconds <= 0`）时分桶返回 `nil`，
    /// 这里转成 `values: []` 走「无数据」短路——参数错误不该被伪装成「一切正常」。
    public static func detectEventRates(
        events: [TimelineEvent],
        windowStart: Date,
        windowEnd: Date,
        bucketSeconds: Double = 60,
        threshold: Double = AnomalyDetector.defaultThreshold,
        minimumSampleSize: Int = AnomalyDetector.defaultMinimumSampleSize,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> AnomalyReport {
        let values = InsightStatistics.bucketCounts(
            timestamps: events.map(\.timestamp),
            start: windowStart,
            end: windowEnd,
            bucketSeconds: bucketSeconds
        ) ?? []
        return detectBuckets(
            values: values,
            metric: .eventRate,
            windowStart: windowStart,
            bucketSeconds: bucketSeconds,
            threshold: threshold,
            minimumSampleSize: minimumSampleSize,
            interfaceLanguage: interfaceLanguage
        )
    }

    /// 删除量异常：每桶 `Σ linesRemoved`。
    ///
    /// 用行数而不是「删除文件的条数」，是因为审计关心的是「这一分钟被抹掉了多少代码」；
    /// 一次 5000 行的批量删除和一次 3 行的清理，在条数维度上看起来完全一样。
    public static func detectDeletions(
        changes: [FileChange],
        windowStart: Date,
        windowEnd: Date,
        bucketSeconds: Double = 60,
        threshold: Double = AnomalyDetector.defaultThreshold,
        minimumSampleSize: Int = AnomalyDetector.defaultMinimumSampleSize,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> AnomalyReport {
        let values = InsightStatistics.bucketSums(
            dated: changes.map { change -> (date: Date, amount: Double) in
                (date: change.timestamp, amount: Double(change.linesRemoved))
            },
            start: windowStart,
            end: windowEnd,
            bucketSeconds: bucketSeconds
        ) ?? []
        return detectBuckets(
            values: values,
            metric: .deletionRate,
            windowStart: windowStart,
            bucketSeconds: bucketSeconds,
            threshold: threshold,
            minimumSampleSize: minimumSampleSize,
            interfaceLanguage: interfaceLanguage
        )
    }

    /// 命令产量异常：每桶命令数（按 `startedAt` 归桶）。
    ///
    /// 以「开始时刻」归桶而非结束时刻：突发的大量命令是**发起**的那一刻发生的事，
    /// 长耗时命令的结束时刻会把尖峰抹平到后面的桶里。
    public static func detectCommands(
        commands: [CommandRecord],
        windowStart: Date,
        windowEnd: Date,
        bucketSeconds: Double = 60,
        threshold: Double = AnomalyDetector.defaultThreshold,
        minimumSampleSize: Int = AnomalyDetector.defaultMinimumSampleSize,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> AnomalyReport {
        let values = InsightStatistics.bucketCounts(
            timestamps: commands.map(\.startedAt),
            start: windowStart,
            end: windowEnd,
            bucketSeconds: bucketSeconds
        ) ?? []
        return detectBuckets(
            values: values,
            metric: .commandRate,
            windowStart: windowStart,
            bucketSeconds: bucketSeconds,
            threshold: threshold,
            minimumSampleSize: minimumSampleSize,
            interfaceLanguage: interfaceLanguage
        )
    }

    /// CPU 负载异常：直接对每个采样的 `cpuTotalPercent` 做 z-score。
    ///
    /// 性能采样不是等间隔分桶而是原始序列，因此：
    /// - `bucketStarts` 就是各采样自身的 `timestamp`；
    /// - 桶宽用「采样跨度 / (n-1)」推算平均间隔，仅为让置信度拿到合理的覆盖时长；
    ///   `n < 2` 时推不出间隔，传 0（`detect` 内部按 1 秒兜底，不会倒推成零覆盖）。
    /// 序列先按 `timestamp` 升序**稳定**排序：等间隔假设下顺序影响 `bucketIndex`，
    /// 相同时间戳必须保持输入次序，否则同一份数据两次分析可能给出不同的「第几个桶」。
    public static func detectCPU(
        samples: [SystemPerformanceSample],
        threshold: Double = AnomalyDetector.defaultThreshold,
        minimumSampleSize: Int = AnomalyDetector.defaultMinimumSampleSize,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> AnomalyReport {
        let ordered = stableSortedByTimestamp(samples)
        let values = ordered.map(\.cpuTotalPercent)
        var bucketSeconds = 0.0
        if values.count >= 2, let earliest = ordered.first, let latest = ordered.last {
            let span = max(0, latest.timestamp.timeIntervalSince(earliest.timestamp))
            bucketSeconds = span / Double(values.count - 1)
        }
        return detect(
            values: values,
            metric: .cpuLoad,
            bucketStarts: ordered.map(\.timestamp),
            bucketSeconds: bucketSeconds,
            threshold: threshold,
            minimumSampleSize: minimumSampleSize,
            interfaceLanguage: interfaceLanguage
        )
    }

    // MARK: - 内部构造

    /// 分桶适配器共用出口：桶起始时刻由窗口起点 + 桶宽推得；桶数为 0 时得到空数组，
    /// 与「窗口非法」同样落到 `detect` 的无数据分支。
    private static func detectBuckets(
        values: [Double],
        metric: AnomalyMetric,
        windowStart: Date,
        bucketSeconds: Double,
        threshold: Double,
        minimumSampleSize: Int,
        interfaceLanguage: AppLanguage
    ) -> AnomalyReport {
        let starts = InsightStatistics.bucketStarts(start: windowStart, count: values.count, bucketSeconds: bucketSeconds)
        return detect(
            values: values,
            metric: metric,
            bucketStarts: starts,
            bucketSeconds: bucketSeconds,
            threshold: threshold,
            minimumSampleSize: minimumSampleSize,
            interfaceLanguage: interfaceLanguage
        )
    }

    /// 命中跳过分支时的报告：保留基线供 UI 展示，但逐桶 `zScore = nil`、`isAnomalous = false`、
    /// `direction = nil`，`anomalousObservations` 恒为空——「不判定」必须是一个看得见的状态。
    private static func undetectedReport(
        metric: AnomalyMetric,
        values: [Double],
        bucketStarts: [Date]?,
        baselineMean: Double?,
        baselineStdev: Double?,
        threshold: Double,
        minimumSampleSize: Int,
        skippedReason: String,
        basis: String
    ) -> AnomalyReport {
        let observations = values.indices.map { index in
            AnomalyObservation(
                metric: metric,
                bucketIndex: index,
                bucketStart: bucketStart(at: index, in: bucketStarts, matching: values.count),
                value: values[index],
                zScore: nil,
                isAnomalous: false,
                direction: nil
            )
        }
        return AnomalyReport(
            metric: metric,
            observations: observations,
            anomalousObservations: [],
            baselineMean: baselineMean,
            baselineStdev: baselineStdev,
            threshold: threshold,
            sampleSize: values.count,
            minimumSampleSize: minimumSampleSize,
            isBaselineSufficient: false,
            skippedReason: skippedReason,
            confidence: .low,
            basis: basis
        )
    }

    /// 取第 `index` 个桶的起始时刻。`bucketStarts` 缺失或数量与序列不等时返回 `nil`（宁可少标注，不可错位标注）。
    private static func bucketStart(at index: Int, in bucketStarts: [Date]?, matching valuesCount: Int) -> Date? {
        guard let bucketStarts, bucketStarts.count == valuesCount else { return nil }
        guard index >= 0, index < bucketStarts.count else { return nil }
        return bucketStarts[index]
    }

    /// 按 `timestamp` 升序的稳定排序：以原下标作次级键，消除 `sorted` 的不稳定性带来的不确定性。
    private static func stableSortedByTimestamp(
        _ samples: [SystemPerformanceSample]
    ) -> [SystemPerformanceSample] {
        samples.enumerated().sorted { lhs, rhs in
            if lhs.element.timestamp != rhs.element.timestamp {
                return lhs.element.timestamp < rhs.element.timestamp
            }
            return lhs.offset < rhs.offset
        }
        .map { $0.element }
    }

    /// 基线数值文案：`nil` 显示「不可计算」而非 0，避免读图的人把「没算」当成「是 0」。
    private static func numberText(_ value: Double?, _ language: AppLanguage) -> String {
        guard let value, value.isFinite else { return InsightCopy.notComputable.text(language) }
        return String(format: "%.2f", value)
    }

    /// 阈值文案：整数量保留一位小数（3.0σ），带小数的按最简形式（2.5σ）。
    private static func thresholdText(_ threshold: Double, _ language: AppLanguage) -> String {
        guard threshold.isFinite else { return InsightCopy.invalidValue.text(language) }
        if threshold == threshold.rounded() {
            return String(format: "%.1f", threshold)
        }
        return String(format: "%g", threshold)
    }
}
