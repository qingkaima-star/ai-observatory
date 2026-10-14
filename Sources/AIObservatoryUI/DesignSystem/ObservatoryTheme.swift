//
//  ObservatoryTheme.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  **功能色**映射：只有「会改变读者判断」的地方才有颜色。
//
//  旧版在这里给 Agent 配了 10 色哈希色板、给操作类型配了 7 色，加上每张指标卡一个彩色
//  图标——那是装饰性配色，正是「东一个西一个、界面很脏」的来源。现在全部收掉：
//
//  - Agent 身份：**不上色**，靠名字与图标区分；图表里按枚举序取灰阶序列表。
//  - 操作类型：只有「风险」与「Agent 启停」两档有颜色，其余一律次级文本色。
//  - 圆角常量搬到 `ObservatoryRadius`，投影常量**删除**（见 ObservatoryTokens 规矩 1）。
//

import SwiftUI
import AIObservatoryCore

// MARK: - 功能色角色

/// 全应用允许出现的**全部**彩色。新增一档必须有「读者会因此判断错」的理由。
enum ObservatoryColor {
    /// 破坏性 / 不可逆 / 高危。
    static let critical = Color.red
    /// 需要留意但可继续。
    static let caution = Color.orange
    /// 成功 / 运行中 / 新增行。
    static let positive = Color.green
    /// 强调：跟随用户的系统强调色，不写死。
    static let accent = Color.accentColor
    /// 无信息量：默认文本层。
    static let neutral = Surface.secondaryLabel
}

enum ObservatoryTheme {

    // MARK: Risk

    /// 风险等级。四级只对应**三档色**：
    /// - `low` 不上色——绿色在本应用里表示「正常/成功」，低风险只是「不需要看」，
    ///   把四级染成红橙黄绿会让整页发脏；
    /// - `medium` 与 `high` 共用橙色——黄字在白底上对比度不达标，而且等级名始终跟着一起显示，
    ///   颜色只需要回答「要不要现在处理」。
    static func color(for level: RiskLevel) -> Color {
        switch level {
        case .low:                        return ObservatoryColor.neutral
        case .medium, .high:              return ObservatoryColor.caution
        case .critical:                   return ObservatoryColor.critical
        }
    }

    /// `color(for:)` 的色调版本，供 `Tag` / `RiskBadge` 复用同一套判定，避免两处漂移。
    static func tone(for level: RiskLevel) -> TagTone {
        switch level {
        case .low:            return .neutral
        case .medium, .high:  return .caution
        case .critical:       return .critical
        }
    }

    // MARK: Project health

    /// 项目健康结论的底色。**这条以前不在令牌层**：`AnalysisPresentation` 自己写了
    /// `.green/.yellow/.red/.gray`，于是全仓有两套功能色口径，而 `.yellow` 与 `.gray`
    /// 根本不在 `ObservatoryColor` 那五档里。
    ///
    /// `watch` 从黄改橙不是审美：ADR-0008 对风险等级已经下过同一个判断——
    /// **黄在浅底上对比度不达标**，而结论名（「需关注」）始终与颜色一起显示，
    /// 颜色只需要回答「要不要现在处理」。四档结论各自对应一档既有语义色，
    /// 没有新增色相（新增一档要有「读者会因此判断错」的理由）。
    ///
    /// ⚠️ `insufficientData` 落中性而不是绿：它说的是「没查出来」，不是「查过没事」。
    static func color(for verdict: ProjectHealthSnapshot.Verdict) -> Color {
        switch verdict {
        case .healthy:          return ObservatoryColor.positive
        case .watch:            return ObservatoryColor.caution
        case .atRisk:           return ObservatoryColor.critical
        case .insufficientData: return ObservatoryColor.neutral
        }
    }

    // MARK: Operation

    /// 操作类型。文件 / Git / 网络 / 命令之间的区别由**文字与 SF Symbol** 承担，
    /// 不由颜色承担；只有风险与 Agent 启停值得占用读者的色彩注意力。
    static func color(for kind: OperationKind) -> Color {
        switch kind {
        case .riskDetected:                  return ObservatoryColor.critical
        case .agentStarted, .agentStopped:   return ObservatoryColor.positive
        case .unknown:                       return Surface.tertiaryLabel
        default:                             return ObservatoryColor.neutral
        }
    }

    // MARK: File change

    /// 文件变更类型。`modified` 是列表里的绝大多数，给它颜色等于给整页铺色，
    /// 因此只有「新建（增益）」与「删除（破坏）」保留语义色。
    static func color(for kind: FileChangeKind) -> Color {
        switch kind {
        case .created:  return ObservatoryColor.positive
        case .deleted:  return ObservatoryColor.critical
        case .modified, .renamed, .unknown: return ObservatoryColor.neutral
        }
    }

    // MARK: Session outcome

    static func color(for outcome: SessionOutcome) -> Color {
        switch outcome {
        case .running:     return ObservatoryColor.accent
        case .success:     return ObservatoryColor.positive
        case .failed:      return ObservatoryColor.critical
        case .interrupted: return ObservatoryColor.caution
        case .unknown:     return ObservatoryColor.neutral
        }
    }

    // MARK: Command outcome

    static func color(for outcome: CommandOutcome) -> Color {
        switch outcome {
        case .running:    return ObservatoryColor.accent
        case .success:    return ObservatoryColor.positive
        case .failure:    return ObservatoryColor.critical
        case .terminated: return ObservatoryColor.caution
        case .unknown:    return ObservatoryColor.neutral
        }
    }

    // MARK: Engine

    static func color(for state: EngineState) -> Color {
        switch state {
        case .running:  return ObservatoryColor.positive
        case .starting: return ObservatoryColor.accent
        case .degraded: return ObservatoryColor.caution
        case .failed:   return ObservatoryColor.critical
        case .stopped:  return ObservatoryColor.neutral
        }
    }

    // MARK: Diff

    /// diff 使用「新增绿 / 删除红」通用约定，不使用股票涨跌配色语义。
    static func diffColor(for style: DiffLine.Style) -> Color {
        switch style {
        case .added:      return ObservatoryColor.positive
        case .removed:    return ObservatoryColor.critical
        case .hunkHeader: return ObservatoryColor.neutral
        case .context:    return Surface.label
        case .meta:       return Surface.tertiaryLabel
        }
    }

    /// `diffColor(for:)` 的等义别名，便于 `ObservatoryTheme.color(for:)` 一致的可读性。
    static func color(for style: DiffLine.Style) -> Color { diffColor(for: style) }

    // MARK: 图表序列

    /// 图表里第 `rank` 条序列的颜色：第一条用强调色，其余走灰阶梯队。
    ///
    /// 分类数据本应有可区分色，但**有序灰阶**在「比大小」这类读数上比彩虹色更好读，
    /// 而且 `Color.primary.opacity(_:)` 在深色模式下自动反向，不需要另写一套。
    static func chartColor(rank: Int) -> Color {
        if rank == 0 { return ObservatoryColor.accent }
        let ramp: [Double] = [0.55, 0.40, 0.28, 0.19, 0.12]
        return Color.primary.opacity(ramp[min(rank - 1, ramp.count - 1)])
    }

    /// Agent 在图表里的序列序：按 `AgentKind` 声明序取固定下标，
    /// 因此**同一 kind 永远同一灰阶**，且不随当前会话里出现了哪几个 Agent 而漂移。
    static func chartRank(for kind: AgentKind) -> Int {
        max(0, AgentKind.allCases.firstIndex(of: kind) ?? 0)
    }
}

#Preview("功能色：风险与状态") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        HStack(spacing: Spacing.sm) {
            ForEach(RiskLevel.allCases) { RiskBadge($0) }
        }
        HStack(spacing: Spacing.sm) {
            ForEach(RiskLevel.allCases) { RiskBadge($0, prominent: true) }
        }
        Hairline()
        HStack(spacing: Spacing.md) {
            ForEach([SessionOutcome.running, .success, .failed, .interrupted, .unknown], id: \.self) {
                Circle().fill(ObservatoryTheme.color(for: $0)).frame(width: 8, height: 8)
            }
        }
    }
    .padding(Spacing.lg)
}

#Preview("图表灰阶梯队") {
    HStack(spacing: Spacing.sm) {
        ForEach(0..<6, id: \.self) { rank in
            RoundedRectangle(cornerRadius: ObservatoryRadius.control, style: .continuous)
                .fill(ObservatoryTheme.chartColor(rank: rank))
                .frame(width: 44, height: 44)
                .overlay(Text("\(rank)").font(.axMeta).foregroundStyle(.white))
        }
    }
    .padding(Spacing.lg)
}
