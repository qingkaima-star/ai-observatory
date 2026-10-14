//
//  Analysis.swift
//  AIObservatoryCore
//
//  Owner: WS-InsightsMount（波次 4）
//  ─────────────────────────────────────────────────────────
//  AI 分析层跨进 UI 时使用的**值类型**。
//
//  为什么这些结构体住在 Core 而不是 Insights：UI 只依赖 Core（这是 UI 与 Engine 能并行开发
//  的前提，见 Runtime.swift）。让 `AIObservatoryUI` 直接 import `AIObservatoryInsights` 会把
//  表现层和分析层焊死，所以分析结论由 Engine 换算成这里定义的 Core 值类型再交给界面。
//
//  为什么 id 走 `StableID` 而不是 `UUID()`（同 c94d48a 的教训）：健康度与异常结论都是
//  **派生聚合值**，会随每一轮刷新重算。随机 id 会让「数字一个都没变，条目身份全变了」——
//  `ForEach` 动画与选中态抖动，导出报告也不再字节确定。所以：
//    · 项目健康度的身份 = 项目路径（一个项目一份健康度）；
//    · 异常结论的身份 = 种类 + 落在哪个桶 + 归属项目（同一次观测重算两次仍是同一条）。
//
//  诚实约定（本项目把「数据不足」当正确答案，把编数字当缺陷）：
//    · 不可估计的量一律用 `Optional` 表达（`efficiencyScore == nil` 是「算不出」，不是 0）；
//    · `expected` 是分析器自己的基线均值，不是拍脑袋的期望值；
//    · `verdict.insufficientData` 必须能和 `healthy` 区分开，界面不得把前者渲染成绿色。
//

import Foundation

// MARK: - Risk Counts

/// 一个项目在某段时间内按等级累计的风险事件数。
///
/// 与 `AIObservatoryInsights.ProjectRiskCounts` 同构但独立定义：Core 不能反向依赖 Insights，
/// 这个类型是分析结论落到界面时的**唯一风险计数口径**。
public struct AnalysisRiskCounts: Codable, Sendable, Hashable {
    public var critical: Int
    public var high: Int
    public var medium: Int
    public var low: Int

    public init(critical: Int = 0, high: Int = 0, medium: Int = 0, low: Int = 0) {
        self.critical = critical
        self.high = high
        self.medium = medium
        self.low = low
    }

    /// 全等级合计。
    public var total: Int { critical + high + medium + low }

    /// 需要人看一眼的量级：HIGH 与 CRITICAL（口径与 Insights 保持一致）。
    public var attentionCount: Int { critical + high }

    /// 一个事件都没有。
    public static let none = AnalysisRiskCounts()
}

// MARK: - Project Health

/// 单个项目的健康度快照（由 Engine 调用 `AIObservatoryInsights` 分析层算出后换算）。
public struct ProjectHealthSnapshot: Codable, Sendable, Hashable, Identifiable {

    /// 健康判定结论。
    ///
    /// `insufficientData` 是独立结论而不是「healthy 的弱版本」：观测条数不够时任何结论都站不住，
    /// 把它渲染成绿色等于宣称「查过了，没事」。
    public enum Verdict: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
        case healthy
        case watch
        case atRisk
        case insufficientData

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .healthy:          return "健康"
            case .watch:            return "需关注"
            case .atRisk:           return "有风险"
            case .insufficientData: return "数据不足"
            }
        }
    }

    public var id: UUID
    /// 项目根路径，同时是身份来源。
    public var projectPath: String
    public var riskCounts: AnalysisRiskCounts
    /// 本项目在分析窗口内检出的异常桶数量（0 表示「判过了，没异常」）。
    public var anomalyCount: Int
    /// 单位时间产出，取自该项目效率最高的可比 Agent：**去重文件数 / 活跃秒**。
    ///
    /// 这不是 `0...1` 的综合健康指数，别把它当分数看；没有任何可比 Agent（活跃秒缺失、
    /// 或只剩归属不明的 Agent）时为 `nil`，界面显示「不可估计」。
    public var efficiencyScore: Double?
    public var verdict: Verdict
    /// 本轮分析的参考时刻（由 Engine 注入，不是界面读到的墙钟）。
    public var generatedAt: Date

    public init(
        id: UUID? = nil,
        projectPath: String,
        riskCounts: AnalysisRiskCounts = .none,
        anomalyCount: Int = 0,
        efficiencyScore: Double? = nil,
        verdict: Verdict,
        generatedAt: Date
    ) {
        self.id = id ?? StableID.uuid(namespace: "projecthealth", key: projectPath)
        self.projectPath = projectPath
        self.riskCounts = riskCounts
        self.anomalyCount = anomalyCount
        self.efficiencyScore = efficiencyScore
        self.verdict = verdict
        self.generatedAt = generatedAt
    }
}

// MARK: - Anomaly Finding

/// 一条已检出的异常结论（z-score 超阈值的单个时间桶）。
public struct AnomalyFinding: Codable, Sendable, Hashable, Identifiable {

    /// 异常种类。只覆盖「突增」方向：分析器也会检出偏低的桶（drop），
    /// 但本契约的四种种类都描述尖峰，把「事件数骤降」写成 eventBurst 就是撒谎，
    /// 因此 drop 观测点由 Engine 明确丢弃而不是硬套一个种类。
    public enum Kind: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
        case eventBurst
        case deletionSpike
        case commandSpike
        case cpuSpike

        public var id: String { rawValue }

        public var displayName: String {
            switch self {
            case .eventBurst:     return "事件突增"
            case .deletionSpike:  return "删除量突增"
            case .commandSpike:   return "命令突增"
            case .cpuSpike:       return "CPU 突增"
            }
        }

        /// 被检测指标的观测口径（单位写进文案，避免「40」被误读成「40%」）。
        public var metricText: String {
            switch self {
            case .eventBurst:     return "事件数"
            case .deletionSpike:  return "删除行数"
            case .commandSpike:   return "命令数"
            case .cpuSpike:       return "CPU 占用 %"
            }
        }

        public var sfSymbolName: String {
            switch self {
            case .eventBurst:     return "chart.bar.xaxis"
            case .deletionSpike:  return "trash"
            case .commandSpike:   return "terminal"
            case .cpuSpike:       return "cpu"
            }
        }
    }

    public var id: UUID
    public var kind: Kind
    /// 严重度由 σ 倍数换算而来（见 Engine 的换算表），不是第二套判定算法。
    public var severity: RiskLevel
    /// 一行人类可读结论，数字全部来自分析器自身给出的观测值与基线。
    public var summary: String
    /// 该时间桶的实测值。
    public var observed: Double
    /// 基线均值（「期望值」）。分析器给出的就是它自己的基线，不额外编一个目标。
    public var expected: Double
    /// 异常落在的那个时间桶的起始时刻。
    public var detectedAt: Date
    /// 归属项目；整机级指标（CPU）或该桶内记录归属不一致时为 `nil`。
    public var projectPath: String?
    /// 归属会话；仅当该桶内的记录全部属于同一个会话时才填，否则为 `nil`。
    public var sessionID: UUID?

    public init(
        id: UUID? = nil,
        kind: Kind,
        severity: RiskLevel,
        summary: String,
        observed: Double,
        expected: Double,
        detectedAt: Date,
        projectPath: String? = nil,
        sessionID: UUID? = nil
    ) {
        self.id = id ?? StableID.uuid(namespace: "anomalyfinding", key: Self.identityKey(
            kind: kind,
            detectedAt: detectedAt,
            projectPath: projectPath
        ))
        self.kind = kind
        self.severity = severity
        self.summary = summary
        self.observed = observed
        self.expected = expected
        self.detectedAt = detectedAt
        self.projectPath = projectPath
        self.sessionID = sessionID
    }

    /// 身份键：`种类|桶起始秒|归属项目`。
    ///
    /// 时间取整到秒只作为哈希输入（同一个桶重算两次必然落进同一个键），
    /// 不参与任何面向用户的时间计算。
    static func identityKey(kind: Kind, detectedAt: Date, projectPath: String?) -> String {
        "\(kind.rawValue)|\(Int(detectedAt.timeIntervalSince1970))|\(projectPath ?? "-")"
    }
}

// MARK: - Analysis Provider

/// 分析能力的执行者，由组合根注入。
///
/// 为什么挂在 `ObservatoryRuntime` 而不是 `ObservatoryService`：后者是冻结契约，
/// 已经有 Store / Engine / 内存服务 / 预览服务四个实现方，加任何必需方法都会一次性打破全部实现。
/// 与 `exporter` 同一套做法（d6a3550）：可选成员 + 默认 `nil`，预览等宿主没有接入时
/// 界面显示「分析层未接入」，而不是显示一个永远转圈的加载态。
public protocol ObservatoryAnalysisProviding: Sendable {

    /// 单个项目的健康度。
    /// - Returns: `nil` 表示分析层不认识这个项目（活动地图里没有它的行），
    ///   与「认识但数据不足」（`verdict == .insufficientData`）是两件事。
    func projectHealth(for path: String) async throws -> ProjectHealthSnapshot?

    /// 某时刻之后的全部异常结论，按检出时间降序。
    func anomalies(since date: Date) async throws -> [AnomalyFinding]
}
