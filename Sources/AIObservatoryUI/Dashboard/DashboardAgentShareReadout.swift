//
//  DashboardAgentShareReadout.swift
//  AIObservatoryUI / Dashboard
//
//  Owner: ws/summary（#80 占比环改紧凑读数）
//  ─────────────────────────────────────────────────────────
//  「Agent 时长占比」紧凑读数。前身是本页那张固定 156×156 的 `SectorMark` 环
//  （文件名与类型名都带着 Chart，所以这次连名字一起改：它已经不是一张图了）。
//
//  【为什么把环换掉——它给的是假读数，三处实证都在链路上】
//  1. 载荷按 `AgentKind` 逐种分组，**没有记录的种类根本不进表**
//     （`ObservatoryStore+Queries.swift` 的 `agentShares(for:until:)`：`compactMap` + `guard !matched.isEmpty`）。
//     于是「这段时间只有一种 Agent 跑过」是常态而不是边界：那种情况下环必然是一整圈、
//     图例那一条的百分比恒为 100.0 %。一个永远等于全部的"占比"没有回答任何问题。
//  2. 旧实现还在 `totalSeconds` 全为 0 时把分母换成 `max(1, sessionCount)`，
//     再把 `metricTotal` 兜一层 `max(1, …)` —— 那是拿凑出来的分母换"环看着是满的、数看着是有"。
//  3. 环中心那两行写的是「活跃总时长」，与本页时段累计第一格同名同数（#85 点名的重复出处）。
//
//  【现在的形状】按**有记录的种数**分支，判据写成纯函数 `shape(of:)` / `rows(for:)`，
//  用例不必渲染就能钉（`DashboardShareReadoutTests`）：
//    · `.noData`            ⇒ 明写这个窗口没有会话记录，不给百分比、不画条、不兜分母；
//    · `.singleSeries`      ⇒ 只报绝对量（时长 / 会话数），并写明"只有一种，不算占比"，**不印 100 %**；
//    · `.multipleSeries(n)` ⇒ 每种一行：色点 + 名字 + 占比条 + 绝对量 + 占比（分母 = 有记录那些种之和）。
//
//  输入只有 `stats.agentShares` 这一份**已经加载好**的载荷：#79 的硬约束（台账裁定 5）
//  是首页一次 `dashboardStats` 就是全部预算，这个读数不许多取一路、也不许多刷一次。
//  占比条照 `Projects/ProjectHotFilesPanel.swift` 的既有形状（下沉槽 + 按比例填充 + 条本身不进读屏），
//  不新增自绘坐标轴（`Scripts/ratchet-quiet-design.sh` 的 `self_drawn_axis_files` 不许涨）。
//

import SwiftUI
import AIObservatoryCore

/// 「Agent 时长占比」紧凑读数卡（首页第 4 档「活动趋势与关键事件」的右半边）。
struct DashboardAgentShareReadout: View {

    let shares: [AgentUsageShare]
    /// 所选窗口的人读口径。**必须显示在标题上**：这一读数的分母只有区间内新建的会话，
    /// #75 之前它印着"今日"，选「全部」时标题写"全部"而环上说"今日"，两句对不上。
    var windowCaption: String = ""

    // MARK: 形状与行（判据都在这两层，视图只负责摆）

    /// 有几种类别留下了记录。#80 的全部判据都挂在这三档上。
    enum Shape: Equatable {
        case noData
        case singleSeries
        case multipleSeries(kinds: Int)

        /// 有记录的种数（`kinds`）。无数据 0、单序列 1。
        var kinds: Int {
            switch self {
            case .noData: return 0
            case .singleSeries: return 1
            case .multipleSeries(let kinds): return kinds
            }
        }
    }

    /// 一行的显示值。
    struct Row: Identifiable {
        let kind: AgentKind
        let sessionCount: Int
        let durationText: String
        /// 占比（0…100）。`nil` = **这一行不许印占比**：无数据与单序列都是 nil。
        /// 这一格可空就是 #80 的落点：旧环在这里永远有个数，而那个数单序列时恒为 100.0。
        let sharePercent: Double?

        var id: AgentKind { kind }
    }

    /// 超过这个行数只列前面的，余量用一句话说清（不藏）。
    static let visibleRowLimit = 8

    private static let barWidth: CGFloat = 56
    private static let barHeight: CGFloat = 4
    private static let dotSize: CGFloat = 8

    // MARK: 纯函数

    /// 「有记录」= 时长与会话数至少有一项非零。
    /// 载荷里出现过某个种类 **不等于**它有记录（`sessionCount == 0 && totalSeconds == 0` 也算没有）。
    static func hasRecord(_ share: AgentUsageShare) -> Bool {
        share.totalSeconds > 0 || share.sessionCount > 0
    }

    /// 有记录的那些条，按时长降序、再按会话数降序（与改前图例同一条排序，读起来不换序）。
    static func recorded(_ shares: [AgentUsageShare]) -> [AgentUsageShare] {
        shares.filter(hasRecord).sorted { lhs, rhs in
            if lhs.totalSeconds != rhs.totalSeconds { return lhs.totalSeconds > rhs.totalSeconds }
            return lhs.sessionCount > rhs.sessionCount
        }
    }

    static func shape(of shares: [AgentUsageShare]) -> Shape {
        let kinds = recorded(shares).count
        switch kinds {
        case 0: return .noData
        case 1: return .singleSeries
        default: return .multipleSeries(kinds: kinds)
        }
    }

    /// 分母用哪一种度量：有任何时长就按时长，否则按会话数（副标题把这句说出来）。
    static func usesDuration(_ shares: [AgentUsageShare]) -> Bool {
        recorded(shares).reduce(0.0) { $0 + $1.totalSeconds } > 0
    }

    /// 一条在分母里占的那一份。**没有 `max(1, …)` 兜底**：
    /// 全为 0 的情况由 `.noData` 那一支接住，而不是凑一个分母出来除。
    static func metric(_ share: AgentUsageShare, durationBased: Bool) -> Double {
        durationBased ? share.totalSeconds : Double(share.sessionCount)
    }

    /// 界面要摆的那几行。**占比只在两种以上才有意义**：
    /// 一家时"占比"恒等于全部，那是同义反复不是读数（#80 的落点）。
    static func rows(for shares: [AgentUsageShare]) -> [Row] {
        let entries = recorded(shares)
        let durationBased = usesDuration(shares)
        let total = entries.reduce(0.0) { $0 + metric($1, durationBased: durationBased) }
        let reportsShare: Bool
        switch shape(of: shares) {
        case .multipleSeries: reportsShare = true
        case .noData, .singleSeries: reportsShare = false
        }
        return entries.map { share in
            let value = metric(share, durationBased: durationBased)
            return Row(
                kind: share.kind,
                sessionCount: share.sessionCount,
                durationText: DurationFormat.compact(share.totalSeconds),
                sharePercent: (reportsShare && total > 0) ? value / total * 100 : nil
            )
        }
    }

    // MARK: Body

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(
                    DashboardCopy.shareWindowedTitle(language, windowCaption: windowCaption),
                    subtitle: DashboardCopy.shareMeasureNote(
                        language, durationBased: Self.usesDuration(shares))) {
                    Text(DashboardCopy.shareKindSummary(
                        language, kinds: Self.shape(of: shares).kinds))
                        .font(.axMeta)
                        .monospacedDigit()
                        .foregroundStyle(Surface.secondaryLabel)
                }

                switch Self.shape(of: shares) {
                case .noData:
                    EmptyStateView(
                        DashboardCopy.shareEmptyTitle.text(language),
                        systemImage: "circle.dotted",
                        message: DashboardCopy.shareEmptyMessage.text(language),
                        fills: false
                    )
                default:
                    rowList
                }
            }
        }
    }

    // MARK: 读数列表

    private var rowList: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            let listed = Self.rows(for: shares)
            ForEach(listed.prefix(Self.visibleRowLimit)) { row in
                shareRow(row)
            }
            if listed.count > Self.visibleRowLimit {
                // #84：「还有 N 家没列进来」是这张读数的口径（哪些没算进来），走低对比档等于不说。
                Text(DashboardCopy.shareMoreAgents.copy.format(
                    language, listed.count - Self.visibleRowLimit))
                    .axCaptionStyle()
            }
            if case .singleSeries = Self.shape(of: shares) {
                // 单序列那一句必须上屏：不印百分比是**处置**，为什么什么都不印是**口径**，
                // 读者拿到的应当是一句解释而不是一个空位。
                Text(DashboardCopy.shareSingleSeriesNote.text(language))
                    .fixedSize(horizontal: false, vertical: true)
                    .axCaptionStyle()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func shareRow(_ row: Row) -> some View {
        HStack(spacing: Spacing.sm) {
            Circle()
                .fill(ObservatoryTheme.chartColor(rank: ObservatoryTheme.chartRank(for: row.kind)))
                .frame(width: Self.dotSize, height: Self.dotSize)
                .accessibilityHidden(true)
            AgentChip(kind: row.kind, compact: true)
            if let percent = row.sharePercent {
                shareBar(ratio: percent / 100, kind: row.kind)
            }
            Spacer(minLength: Spacing.sm)
            Text(DashboardCopy.shareRowSummary.copy.format(
                language, row.sessionCount, row.durationText))
                .font(.axMeta)
                .monospacedDigit()
                .foregroundStyle(Surface.secondaryLabel)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .layoutPriority(1)
            if let percent = row.sharePercent {
                Text(PercentFormat.short(percent, fractionDigits: 1))
                    .font(.axLabel)
                    .monospacedDigit()
                    .foregroundStyle(ObservatoryTheme.chartColor(
                        rank: ObservatoryTheme.chartRank(for: row.kind)))
                    .frame(minWidth: Spacing.xxl, alignment: .trailing)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(DashboardCopy.shareRowA11y(
            language,
            kind: row.kind,
            sessions: row.sessionCount,
            durationText: row.durationText,
            percentText: row.sharePercent.map { PercentFormat.short($0, fractionDigits: 1) }))
    }

    /// 占比条：底槽 `Surface.recessed` + 按比例填充的圆角条，形状与
    /// `ProjectHotFilesPanel.intensityBar` 同一条。**只有多序列才会画到这里**。
    private func shareBar(ratio: Double, kind: AgentKind) -> some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: ObservatoryRadius.tag, style: .continuous)
                .fill(Surface.recessed)
            RoundedRectangle(cornerRadius: ObservatoryRadius.tag, style: .continuous)
                .fill(ObservatoryTheme.chartColor(rank: ObservatoryTheme.chartRank(for: kind)))
                .frame(width: Self.barWidth * min(1, max(0, ratio)))
        }
        .frame(width: Self.barWidth, height: Self.barHeight)
        .accessibilityHidden(true)
    }
}

#Preview("DashboardAgentShareReadout") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        // 多家：占比条 + 百分比有意义。
        DashboardAgentShareReadout(shares: [
            AgentUsageShare(kind: .claudeCode, sessionCount: 6, totalSeconds: 7_200),
            AgentUsageShare(kind: .cursorAgent, sessionCount: 3, totalSeconds: 3_600),
            AgentUsageShare(kind: .openAICodex, sessionCount: 2, totalSeconds: 1_500),
            AgentUsageShare(kind: .genericCLIAgent, sessionCount: 1, totalSeconds: 420)
        ], windowCaption: "2026-09-22 00:00 — 2026-09-22 18:00")
        // 单家：整圈环当初就是在这里印出恒为 100.0 % 的假读数。现在只报绝对量。
        DashboardAgentShareReadout(shares: [
            AgentUsageShare(kind: .claudeCode, sessionCount: 4, totalSeconds: 5_400)
        ], windowCaption: "2026-09-22 00:00 — 2026-09-22 18:00")
        // 有会话但还没有时长：分母换成会话数，副标题要说出这件事。
        DashboardAgentShareReadout(shares: [
            AgentUsageShare(kind: .claudeCode, sessionCount: 3, totalSeconds: 0),
            AgentUsageShare(kind: .cursorAgent, sessionCount: 1, totalSeconds: 0)
        ], windowCaption: "全部时间")
        // 无数据：明写无数据。
        DashboardAgentShareReadout(shares: [
            AgentUsageShare(kind: .claudeCode, sessionCount: 0, totalSeconds: 0)
        ], windowCaption: "今天")
    }
    .padding(Spacing.lg)
    .frame(width: 620)
}

private extension DashboardAgentShareReadout {
    var language: AppLanguage { UILanguage.current }
}
