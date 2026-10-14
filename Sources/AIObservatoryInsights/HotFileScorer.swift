//
//  HotFileScorer.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

/// 「热文件」评分：本项目里哪些文件最近最常被 Agent 触碰。
///
/// 综合分是四个归一化因子的加权和：
/// - **frequency** 改动次数——改得多的文件更值得人先看一眼；
/// - **repetition** 等比衰减后的有效改动数——同一文件被反复修改的边际关注度递减，
///   否则一个被 Agent 反复微调 40 次的琐碎文件会永远压过刚被大改的核心文件；
/// - **breadth** 触碰过它的 Agent 种类数——多个 Agent 同时改一个文件往往是耦合信号；
/// - **recency** 按半衰期衰减的新鲜度——10 天没动过的文件即使历史上很热也已经凉。
///
/// 归一化一律除以**语料库内的最大值**而不是某个全局常量，因此分数含义是「相对本项目内部的热门度」，
/// 不会因为某个项目改动绝对量大就整体虚高，也不鼓励跨项目直接比分数的绝对值。
///
/// 输入须已由 WS-Engine 的 `ProjectMapper` 按项目根归好组；本文件只做 `path` 精确分组，
/// **不做**任何路径归一化或项目归属判断（那是采集层的职责，重复实现会导致两处规则漂移）。
public enum FileHotnessScorer {
    /// 评分策略。
    ///
    /// 把衰减系数、半衰期与权重收敛成一个可注入、可编码的值，便于 UI 侧做敏感性对比，
    /// 也避免「换个权重就要改代码」。
    public struct Policy: Codable, Sendable, Hashable {
        /// 重复改动的等比衰减系数 `r`：第 1 次改动记满权重，其后每次乘 `r`。
        ///
        /// `r` 越小越不看重重复（`0` 等价于「只算改过 / 没改过」），`r → 1` 退化为原始次数。
        public var repetitionDecay: Double

        /// 新鲜度半衰期（秒）：距今正好 `halfLife` 时 recency 权重衰减到 `0.5`。
        ///
        /// 默认取 7 天，对应「一个活跃迭代周期」的直觉尺度。
        public var recencyHalfLifeSeconds: Double

        /// 四因子权重，默认 `HotFileWeights.standard`（之和为 1，分数因此落在 `0...1`）。
        public var weights: HotFileWeights

        public init(repetitionDecay: Double, recencyHalfLifeSeconds: Double, weights: HotFileWeights) {
            self.repetitionDecay = repetitionDecay
            self.recencyHalfLifeSeconds = recencyHalfLifeSeconds
            self.weights = weights
        }

        /// 默认策略：衰减 0.6、半衰期 7 天、标准权重。
        public static let standard = Policy(
            repetitionDecay: 0.6,
            recencyHalfLifeSeconds: 604_800,
            weights: .standard
        )
    }

    /// 语料库内全部文件的热度。
    ///
    /// - Parameters:
    ///   - changes: 同一项目内的文件变更（已由 `ProjectMapper` 归好组）。
    ///   - referenceDate: 「现在」。时间一律注入，不读 `Date()`——否则同一份数据在不同时刻
    ///     跑出的分数不可复现，审计结论就失去了可追溯性。
    ///   - policy: 评分策略。
    /// - Returns: 按 `score` 降序、同分按 `path` 升序的评分。**确定性输出**：与 `changes`
    ///   的内部顺序无关（包括字典遍历顺序），因此可以直接缓存或跨进程比对。空输入返回空数组。
    public static func score(
        changes: [FileChange],
        referenceDate: Date,
        policy: Policy = .standard,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> [HotFileScore] {
        guard !changes.isEmpty else { return [] }

        // 按 path 精确分组，并保留首次出现顺序；不用 Dictionary 的遍历顺序参与任何计算或排序。
        var observations: [Observation] = []
        var indexOfPath: [String: Int] = [:]
        for change in changes {
            if let index = indexOfPath[change.path] {
                observations[index].absorb(change)
            } else {
                indexOfPath[change.path] = observations.count
                observations.append(Observation(absorbing: change))
            }
        }

        // 每个文件的原始信号只算一次，随后既用于求上界也用于归一化。
        var effectiveEdits: [Double] = []
        var rawRecency: [Double] = []
        effectiveEdits.reserveCapacity(observations.count)
        rawRecency.reserveCapacity(observations.count)
        for observation in observations {
            effectiveEdits.append(
                InsightStatistics.decayedSum(count: observation.changeCount, decay: policy.repetitionDecay)
            )
            rawRecency.append(
                InsightStatistics.recencyWeight(
                    ageSeconds: observation.ageSeconds(referenceDate: referenceDate),
                    halfLifeSeconds: policy.recencyHalfLifeSeconds
                )
            )
        }

        // 语料库上界：全语料最大值。归一化到「本项目里最热的那个文件」而非某个魔法常量。
        var maxCount = 0
        var maxAgents = 0
        var maxEffective = 0.0
        var maxRecency = 0.0
        for index in observations.indices {
            maxCount = max(maxCount, observations[index].changeCount)
            maxAgents = max(maxAgents, observations[index].distinctAgentCount)
            maxEffective = max(maxEffective, effectiveEdits[index])
            maxRecency = max(maxRecency, rawRecency[index])
        }

        let weights = policy.weights
        // 权重总和可能为 0（自定义策略把四项权重全设为 0），用 1e-9 兜住分母而不是除零得到 inf。
        let weightDenominator = max(weights.total, 1e-9)

        var scores: [HotFileScore] = []
        scores.reserveCapacity(observations.count)
        for index in observations.indices {
            let observation = observations[index]
            let effectiveEditCount = effectiveEdits[index]
            let frequency = InsightStatistics.ratio(Double(observation.changeCount), to: Double(maxCount))
            let repetition = InsightStatistics.ratio(effectiveEditCount, to: maxEffective)
            let breadth = InsightStatistics.ratio(Double(observation.distinctAgentCount), to: Double(maxAgents))
            let recency = InsightStatistics.ratio(rawRecency[index], to: maxRecency)
            let weighted = weights.frequency * frequency
                + weights.repetition * repetition
                + weights.breadth * breadth
                + weights.recency * recency

            let ageSeconds = observation.ageSeconds(referenceDate: referenceDate)
            scores.append(
                HotFileScore(
                    path: observation.path,
                    score: InsightStatistics.clamp01(weighted / weightDenominator),
                    factors: HotFileFactors(
                        changeCount: observation.changeCount,
                        distinctAgentCount: observation.distinctAgentCount,
                        ageSeconds: ageSeconds,
                        effectiveEditCount: effectiveEditCount,
                        normalizedFrequency: frequency,
                        normalizedRepetition: repetition,
                        normalizedBreadth: breadth,
                        normalizedRecency: recency
                    ),
                    weights: weights,
                    confidence: confidence(of: observation),
                    basis: basisText(
                        changeCount: observation.changeCount,
                        distinctAgentCount: observation.distinctAgentCount,
                        ageSeconds: ageSeconds,
                        effectiveEditCount: effectiveEditCount,
                        interfaceLanguage: interfaceLanguage
                    )
                )
            )
        }

        scores.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.path < rhs.path
        }
        return scores
    }

    /// 取前 `limit` 个热文件，用于 UI 的「Top 热文件」列表。
    ///
    /// `limit <= 0` 返回空数组（而不是全部）——调用方给出「0 个」的意图必须是 0 个，
    /// 否则一个可配置的显示条数会在 0 时突然把整个语料倒给用户。
    public static func topHotFiles(_ scores: [HotFileScore], limit: Int) -> [HotFileScore] {
        guard limit > 0 else { return [] }
        return Array(scores.prefix(min(limit, scores.count)))
    }

    // MARK: - 私有实现

    /// 单个文件的原始观测聚合。
    ///
    /// 只累积、不解释：归一化必须等到看到全语料的最大值之后才能做，所以这里保留原始计数与时间边界。
    private struct Observation {
        var path: String
        var changeCount: Int
        var agentKinds: Set<AgentKind>
        /// `agentKind == .unknown` 的改动数，作为置信度的「关键字段缺失」比例来源。
        var unknownAgentCount: Int
        var earliestChangeAt: Date
        var latestChangeAt: Date

        init(absorbing change: FileChange) {
            self.path = change.path
            self.changeCount = 1
            self.agentKinds = [change.agentKind]
            self.unknownAgentCount = change.agentKind == .unknown ? 1 : 0
            self.earliestChangeAt = change.timestamp
            self.latestChangeAt = change.timestamp
        }

        mutating func absorb(_ change: FileChange) {
            changeCount += 1
            agentKinds.insert(change.agentKind)
            if change.agentKind == .unknown {
                unknownAgentCount += 1
            }
            if change.timestamp < earliestChangeAt {
                earliestChangeAt = change.timestamp
            }
            if change.timestamp > latestChangeAt {
                latestChangeAt = change.timestamp
            }
        }

        /// 去重后触碰过该文件的 Agent 种类数。
        var distinctAgentCount: Int { agentKinds.count }

        /// 该文件自身改动的时间跨度（最晚 - 最早），单条改动为 `0`。
        var coverageSeconds: Double { max(0, latestChangeAt.timeIntervalSince(earliestChangeAt)) }

        /// 最后一次改动距今的秒数；未来的改动按 `0` 处理，不给「还没发生」的数据发新鲜度奖励。
        func ageSeconds(referenceDate: Date) -> Double {
            max(0, referenceDate.timeIntervalSince(latestChangeAt))
        }
    }

    /// 置信度证据：样本量 = 该文件的改动数，覆盖时长 = 该文件自身的改动时间跨度，
    /// 缺失比例 = 归属不明（`.unknown`）改动占比。
    ///
    /// 刻意只用**该文件自己**的证据而不是全语料的——某个冷门文件只有 2 条改动时，
    /// 它的热度结论就该标成 LOW，不能被项目里其他文件的样本量抬高。
    private static func confidence(of observation: Observation) -> InsightConfidence {
        InsightConfidenceEvaluator.evaluate(
            InsightEvidence(
                observationCount: observation.changeCount,
                coverageSeconds: observation.coverageSeconds,
                missingFieldRatio: InsightStatistics.ratio(
                    Double(observation.unknownAgentCount),
                    to: Double(observation.changeCount)
                )
            )
        )
    }

    /// 人类可读依据。每个分数都必须能被一句话解释清楚，否则 UI 上就是一个不可追问的黑盒数字。
    private static func basisText(
        changeCount: Int,
        distinctAgentCount: Int,
        ageSeconds: Double,
        effectiveEditCount: Double,
        interfaceLanguage: AppLanguage
    ) -> String {
        let ageDays = ageSeconds / 86_400
        return InsightCopy.hotFileBasis.format(
            interfaceLanguage,
            String(changeCount),
            String(distinctAgentCount),
            decimalText(ageDays, fractionDigits: 1),
            decimalText(effectiveEditCount, fractionDigits: 2)
        )
    }

    /// 定点小数字符串。
    ///
    /// 走整数运算而不是 `%f`：后者的十进制分隔符与数字字形随系统 locale 变化，
    /// 会让 `basis` 这种既要展示又要被断言的稳定文本在不同机器上给出不同结果。
    private static func decimalText(_ value: Double, fractionDigits: Int) -> String {
        guard value.isFinite else { return "0" }
        let digits = max(0, min(6, fractionDigits))
        var scale = 1
        for _ in 0..<digits { scale *= 10 }
        // 1e12 已经是毫无业务意义的量级，夹一下即可避免整数转换溢出崩溃。
        let bounded = min(max(value, -1e12), 1e12)
        var scaled = Int((bounded * Double(scale)).rounded())
        let isNegative = scaled < 0
        if isNegative { scaled = -scaled }
        let integerPart = scaled / scale
        let sign = isNegative ? "-" : ""
        guard digits > 0 else { return "\(sign)\(integerPart)" }
        let fractionPart = scaled % scale
        let fractionText = String(fractionPart)
        let padding = String(repeating: "0", count: digits - fractionText.count)
        return "\(sign)\(integerPart).\(padding)\(fractionText)"
    }
}
