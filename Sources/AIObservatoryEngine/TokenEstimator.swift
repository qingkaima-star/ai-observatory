//
//  TokenEstimator.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine
//  Sub-owner: D
//
//  本系统**没有**模型侧的 token 遥测通道，因此这里只给出「估算值」。
//  估算口径：会话时长 × 该 AgentKind 的「每活跃分钟 token 系数」。
//  依据不足（时长 < 1 分钟、Agent 类型无法识别、时长非有限、系数缺失）时
//  一律返回 nil —— 禁止伪造指标（INTERFACE.md §0.7）。
//
//  `Estimate.isEstimated` 在类型层面恒为 `true`，任何写入 `AgentSession.estimatedTokens`
//  的路径都只能取 `estimate.tokens`；`disclaimer(for:)` 的文本仅供 UI/日志展示，
//  不得进入 `title` 或任何统计字段。
//

import Foundation
import AIObservatoryCore

/// 无真实 token 遥测时的会话 token 估算器。无状态、纯函数、天然 `Sendable`。
public struct TokenEstimator: Sendable {

    // MARK: - Estimate

    /// 一次 token 估算的结果。
    public struct Estimate: Sendable, Hashable {
        /// 估算出的 token 数（恒为正整数）。
        public var tokens: Int
        /// 恒为 `true`：显式标注「这是估算，不是实测」；只读，无法被关闭。
        public var isEstimated: Bool { true }
        /// 人类可读的估算依据，例如「时长 30.0 分钟 × Claude Code 系数 11500 tokens/活跃分钟」。
        public var basis: String

        /// 以「估算」语义构造一条结果（`isEstimated` 不可被关闭）。
        public init(tokens: Int, basis: String) {
            self.tokens = tokens
            self.basis = basis
        }
    }

    // MARK: - Configuration

    /// 最短可估算时长（秒）：低于此值样本太短，直接返回 nil。
    public static let minimumDurationSeconds: TimeInterval = 60

    /// `AgentKind` → 每「活跃分钟」的 token 量级系数。
    public var tokensPerActiveMinuteByKind: [AgentKind: Double]

    /// 活跃度下限（CPU%）：会话若明确采到过 CPU 但全程低于该值，视为空闲，不估算。
    /// 说明：`peakCPUPercent == 0` 代表「无采样」而非「确认空闲」，此时仍按时长估算。
    public var activityFloorCPUPercent: Double

    /// 构造估算器。
    /// - Parameters:
    ///   - tokensPerActiveMinuteByKind: 自定义系数表；缺省用 `defaultCoefficients`。
    ///   - activityFloorCPUPercent: 空闲判定阈值，仅在会话带有明确 CPU 证据时生效。
    public init(tokensPerActiveMinuteByKind: [AgentKind: Double] = TokenEstimator.defaultCoefficients,
                activityFloorCPUPercent: Double = 0.5) {
        self.tokensPerActiveMinuteByKind = tokensPerActiveMinuteByKind
        self.activityFloorCPUPercent = activityFloorCPUPercent
    }

    /// 默认系数表：覆盖 `AgentKind.allCases` 全部 9 个 kind，量级 3k–12k tokens/活跃分钟，
    /// `.unknown` 取最低档（且实际不参与估算，见 `estimate(duration:kind:)`）。
    public static let defaultCoefficients: [AgentKind: Double] = [
        .claudeCode:      11_500,
        .openAICodex:      9_000,
        .cursorAgent:     10_000,
        .vscodeCopilot:    7_500,
        .windsurf:         8_000,
        .geminiCLI:        6_500,
        .aiderCLI:         5_000,
        .genericCLIAgent:  4_000,
        .unknown:          3_000
    ]

    // MARK: - Estimation

    /// 按时长估算 token。
    /// 返回 nil 的条件：`kind == .unknown`、`duration` 非有限或为负、`duration < 60s`、
    /// 系数表缺该 kind、或取整后 token 数为 0。
    public func estimate(duration: TimeInterval, kind: AgentKind) -> Estimate? {
        guard kind != .unknown else { return nil }
        guard duration.isFinite, duration >= Self.minimumDurationSeconds else { return nil }
        guard let coefficient = tokensPerActiveMinuteByKind[kind], coefficient.isFinite, coefficient > 0 else {
            return nil
        }
        let minutes = duration / 60
        let raw = minutes * coefficient
        guard raw.isFinite, raw > 0 else { return nil }
        let tokens = Int(raw.rounded())
        guard tokens > 0 else { return nil }
        return Estimate(tokens: tokens,
                        basis: Self.basisText(minutes: minutes, kind: kind, coefficient: coefficient))
    }

    /// 对会话估算 token。时长用 `duration(until: referenceDate)` 结算：
    /// 未结束的会话以**调用方给定的时刻**为终点，而不是隐式读墙钟，否则同一份数据两次
    /// 结算会得到不同数字（统计口径必须可复现）。
    /// 额外规则：会话若有**明确**的 CPU 证据（`peakCPUPercent` 在 0 与 `activityFloorCPUPercent`
    /// 之间）→ 判定为全程空闲，返回 nil（不给出虚高估算）。
    public func estimate(session: AgentSession, until referenceDate: Date) -> Estimate? {
        guard session.peakCPUPercent.isFinite else { return nil }
        if session.peakCPUPercent > 0 && session.peakCPUPercent < activityFloorCPUPercent {
            return nil
        }
        return estimate(duration: session.duration(until: referenceDate), kind: session.kind)
    }

    /// 供 UI / 日志展示的口径说明。调用方**不得**把返回文本写入 `AgentSession.title`
    /// 或任何统计字段（避免污染搜索文本与聚合口径）。
    public func disclaimer(for estimate: Estimate) -> String {
        "估算值（非真实 token 遥测）：\(estimate.tokens) tokens。依据：\(estimate.basis)。"
            + "仅供趋势参考，不可用于计费或精确统计；需要准确数值请接入模型侧 usage 上报。"
    }

    // MARK: - Private

    /// 生成人类可读依据文本。
    private static func basisText(minutes: Double, kind: AgentKind, coefficient: Double) -> String {
        let minuteText = String(format: "%.1f", minutes)
        let coefficientText = coefficient == coefficient.rounded()
            ? String(format: "%.0f", coefficient)
            : String(format: "%.1f", coefficient)
        return "时长 \(minuteText) 分钟 × \(kind.displayName) 系数 \(coefficientText) tokens/活跃分钟"
    }
}
