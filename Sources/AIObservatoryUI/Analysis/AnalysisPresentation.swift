//
//  AnalysisPresentation.swift
//  AIObservatoryUI / Analysis
//
//  Owner: WS-InsightsMount（波次 4）
//  ─────────────────────────────────────────────────────────
//  分析结论的展示口径（纯函数，脱离 SwiftUI 可单测）。
//
//  为什么单独抽出来：Dashboard 与 Projects 两块界面都要把 `ProjectHealthSnapshot` /
//  `AnomalyFinding` 翻成中文，文案规则一旦长第二份就会漂移（本项目已经吃过
//  「同一个数字两种说法」的亏）。这里只有一个出口，界面只负责摆。
//
//  诚实口径（三条都会被抓到，所以钉死在这里）：
//    · `insufficientData` 绝不可能渲染成「健康」——它有自己的文案与中性色；
//    · 不可估计的量写「不可估计」，不写 0（0 是「测到了，值为零」）；
//    · 分析层没接入时明说「未接入」，不显示一排看起来像结论的空数字。
//

import SwiftUI
import AIObservatoryCore

// MARK: - 空态种类

/// Dashboard「异常检测」卡片的三种空态。三者必须能区分开：
/// 「没接入」「没数据」「查过了没有异常」在审计产品里是三个完全不同的结论。
enum AnalysisEmptyKind: String, CaseIterable, Hashable {
    case notWired
    case noRecords
    case nothingFound
}

// MARK: - 项目健康度状态

/// 项目详情面板的健康度来源状态。
enum ProjectHealthState: Hashable {
    /// 宿主没有装配分析层（预览、或引擎启动失败前的窗口）。
    case notWired
    /// 分析层已接入，但这个项目拿不到健康度：活动地图里没有它的行。
    case unavailable
    /// 分析层查询失败。原因原样带出来，不降级成「暂无健康度」——
    /// 「没查到」与「查失败」在审计产品里不能共用一句话。
    case failed(String)
    /// 分析层给出了快照（含 `insufficientData` 这种「查了但数据不够」的结论）。
    case resolved(ProjectHealthSnapshot)
}

// MARK: - Presentation

enum AnalysisPresentation {

    /// Dashboard 卡片最多展示的异常条数。
    static let dashboardFindingLimit = 5

    // MARK: 空态

    /// 判定当前该显示哪一种空态。
    /// - Parameters:
    ///   - analysisWired: `runtime.analysis != nil`。
    ///   - hasRecords: 本范围内是否有任何观测记录（哪怕没命中异常）。
    ///   - hasFindings: 是否检出了异常。
    static func emptyKind(analysisWired: Bool, hasRecords: Bool, hasFindings: Bool) -> AnalysisEmptyKind? {
        if !analysisWired { return .notWired }
        if !hasRecords { return .noRecords }
        if !hasFindings { return .nothingFound }
        return nil
    }

    static func title(for kind: AnalysisEmptyKind) -> String {
        switch kind {
        case .notWired:     return "分析层未接入"
        case .noRecords:    return "还没有可分析的记录"
        case .nothingFound: return "本范围内没有检出异常"
        }
    }

    static func message(for kind: AnalysisEmptyKind) -> String {
        switch kind {
        case .notWired:
            return "当前宿主没有装配 AI 分析层（例如 SwiftUI 预览）。这里不显示任何结论，"
                + "以免一排空数字被读成「查过了，一切正常」。"
        case .noRecords:
            return "这段时间还没有任何事件、文件改动或命令记录，异常检测没有可以建立基线的样本。"
        case .nothingFound:
            return "已按 z-score 比对事件数、删除行数、命令数与 CPU 占用，没有发现显著偏离自身基线的时段。"
                + "「没检出」不等于「一定没有」：基线样本不足时分析器会主动放弃判定。"
        }
    }

    static func systemImage(for kind: AnalysisEmptyKind) -> String {
        switch kind {
        case .notWired:     return "questionmark.circle"
        case .noRecords:    return "tray"
        case .nothingFound: return "checkmark.seal"
        }
    }

    // MARK: 列表裁剪

    /// 卡片内展示的前 N 条（按检出时间降序，输入已是该顺序时不再重排）。
    static func visibleFindings(_ findings: [AnomalyFinding], limit: Int = dashboardFindingLimit) -> [AnomalyFinding] {
        guard limit > 0 else { return [] }
        return Array(orderedFindings(findings).prefix(limit))
    }

    /// 被裁掉、没显示出来的条数。
    static func hiddenCount(_ findings: [AnomalyFinding], limit: Int = dashboardFindingLimit) -> Int {
        max(0, findings.count - max(0, limit))
    }

    /// 检出时间降序；同一时刻按 id 定序，保证两次刷新行序不抖。
    static func orderedFindings(_ findings: [AnomalyFinding]) -> [AnomalyFinding] {
        findings.sorted { lhs, rhs in
            if lhs.detectedAt != rhs.detectedAt { return lhs.detectedAt > rhs.detectedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    // MARK: 项目健康度

    /// 换算来源状态。`snapshot == nil` 时「未接入」「查失败」「这个项目没有行」必须分开说。
    static func healthState(
        analysisWired: Bool,
        snapshot: ProjectHealthSnapshot?,
        errorMessage: String? = nil
    ) -> ProjectHealthState {
        if !analysisWired { return .notWired }
        if let errorMessage { return .failed(errorMessage) }
        guard let snapshot else { return .unavailable }
        return .resolved(snapshot)
    }

    static func healthTitle(_ state: ProjectHealthState) -> String {
        switch state {
        case .notWired:     return "分析层未接入"
        case .unavailable:  return "暂无健康度"
        case .failed:       return "分析未完成"
        case .resolved(let snapshot):
            return snapshot.verdict.displayName
        }
    }

    /// 是否展示派生数字（风险分解 / 异常数 / 单位产出）。
    ///
    /// `insufficientData` 时一个都不展示：观测条数不够时上面这些数字全都不可采信，
    /// 「数据不足」和「检出 2 处异常」并排出现只会让人以为后一句是真结论。
    static func showsBreakdown(_ state: ProjectHealthState) -> Bool {
        guard case .resolved(let snapshot) = state else { return false }
        return snapshot.verdict != .insufficientData
    }

    /// 健康度副标题。
    ///
    /// ⚠️ 这里**不再重复**风险分解 / 异常数 / 单位产出那三个数：同一张卡上方三格
    /// `InlineStat` 报的就是它们（`ProjectHealthCard` 的 `breakdown`），一行之内说两遍
    /// 正是全站口径要收的那类复述。这一行只留一件别处没有的事：**这个结论是什么时候算的**。
    /// 「数据不足」「查失败」「没接入」三档没有 breakdown，那句话就是它唯一的正文。
    static func healthDetail(_ state: ProjectHealthState) -> String {
        switch state {
        case .notWired:
            return "当前宿主没有装配 AI 分析层，这里不显示任何健康结论。"
        case .unavailable:
            return "活动地图里还没有这个项目的行，分析层因此无法给出健康度。"
        case .failed(let message):
            return "分析层查询失败：\(message)。上一轮的健康度不再沿用，避免显示过期结论。"
        case .resolved(let snapshot):
            var parts: [String] = []
            if snapshot.verdict == .insufficientData {
                parts.append("窗口内观测条数不足，分析层主动放弃判定，派生数字一概不展示")
            }
            parts.append("分析于 \(DateFormat.timestamp(snapshot.generatedAt))")
            return parts.joined(separator: " · ")
        }
    }

    /// 结论底色。**这里不再有第二套色**：四档全部走 `ObservatoryTheme.color(for:)`
    /// （以前本函数自带 `.green/.yellow/.red/.gray`，其中黄与灰根本不在 `ObservatoryColor`
    /// 那五档里，于是同一屏上「需关注」的橙与「中风险」的橙不是同一个出处）。
    /// 未接入 / 无健康度 / 查失败同样落在中性，不给任何「一切正常」的暗示。
    static func verdictTint(_ state: ProjectHealthState) -> Color {
        switch state {
        case .notWired, .unavailable, .failed:
            ObservatoryColor.neutral
        case .resolved(let snapshot):
            ObservatoryTheme.color(for: snapshot.verdict)
        }
    }

    static func verdictSymbol(_ state: ProjectHealthState) -> String {
        switch state {
        case .notWired:     return "questionmark.circle"
        case .unavailable:  return "tray"
        case .failed:       return "exclamationmark.triangle"
        case .resolved(let snapshot):
            switch snapshot.verdict {
            case .healthy:          return "checkmark.shield"
            case .watch:            return "eye"
            case .atRisk:           return "exclamationmark.shield"
            case .insufficientData: return "tray"
            }
        }
    }

    // MARK: 数字文案

    /// 风险计数分解：全为 0 时写「0 起」而不是留白（留白会被读成「没统计」）。
    static func riskBreakdownText(_ counts: AnalysisRiskCounts) -> String {
        guard counts.total > 0 else { return "0 起" }
        var parts: [String] = []
        if counts.critical > 0 { parts.append("严重 \(counts.critical)") }
        if counts.high > 0 { parts.append("高 \(counts.high)") }
        if counts.medium > 0 { parts.append("中 \(counts.medium)") }
        if counts.low > 0 { parts.append("低 \(counts.low)") }
        return "\(counts.total)（\(parts.joined(separator: " · "))）"
    }

    static func anomalyText(_ count: Int) -> String {
        count > 0 ? "\(count) 处" : "0 处"
    }

    /// 单位时间产出：`nil` 是「算不出」，必须写成「不可估计」。
    static func efficiencyText(_ score: Double?) -> String {
        guard let score else { return "不可估计" }
        return "\(compactNumber(score)) 文件/活跃秒"
    }

    /// 异常行的数值文案：`实测 40 / 基线 3.7`。
    static func observedExpectedText(_ finding: AnomalyFinding) -> String {
        "实测 \(compactNumber(finding.observed)) · 基线 \(compactNumber(finding.expected)) · \(finding.kind.metricText)"
    }

    /// 定点小数：极小的非零值保留 4 位，避免「0.0001 文件/秒」被印成「0.00」看起来像零产出。
    static func compactNumber(_ value: Double) -> String {
        guard value.isFinite else { return "不可计算" }
        let magnitude = Swift.abs(value)
        if magnitude > 0, magnitude < 0.01 { return String(format: "%.4f", value) }
        return String(format: "%.2f", value)
    }
}
