//
//  PerformanceSessionBreakdown.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-UI (subagent D) → WS-QUIET-3
//  职责：选中会话的性能明细 —— 入参 `samples` 是 `PerformanceModel.sessionSamples`，
//        即 `performanceSamples(sessionID:limit:)`（ICR-0007）已经取好的那一段，
//        本视图列出最近若干条**按会话采集到的**采样（时刻 / CPU / 内存）。
//
//  ⚠️ 这里 `recentSamples` 的 `suffix(recentRowLimit)` **不是取数兑底**：它切的是一个已经
//  在取数层被 `sampleCap` 限住的数组，作用是"表格里只画最近 60 行"（版面），
//  与 ICR-0007 要消灭的"整段捞回再本地截"是两件事。派单把它列成第四处，实测不是查询。
//
//  本轮删掉了两样东西，都不是「先删了以后再加回来」，而是它们本来就在谎报：
//
//  1. **卡片里那个会话 `Picker`**。整页顶部的「观测对象」选择器选的就是同一个值
//     （`model.selectedSessionID`），同一页放两个入口 = 用户要先弄清哪个才作数。
//
//  2. **磁盘读 / 磁盘写 / 温度 / 功耗四列，以及那张 6 格的 `PerformanceSessionMetricGrid`**。
//     依据：`ObservatoryEngine.swift:727` 构造会话 `PerformanceSample` 时只传
//     `timestamp / sessionID / agentID / cpuPercent / memoryBytes`，其余字段全部落到
//     `DomainModels.swift:713` 那个 init 的默认值 ⇒ 会话行的
//     `diskRead/WriteBytesPerSecond` **恒为 0**、`thermalCelsius/powerWatts` **恒为 nil**。
//     于是这一度显示的是「磁盘读峰值 0 B/s」——把「根本没采」报成「这个会话没写盘」，
//     正是红线二禁的那类错（对照：`PerformanceSeriesPoint(_ PerformanceSample)` 已经
//     为了同一理由把网络与 GPU 写成 `nil`）。
//     汇总数字（CPU / 内存 峰值与均值、采样点数、覆盖窗口）现在由页面上方那组
//     会话口径的读数一格给一次，明细卡不再重复一遍。
//

import SwiftUI
import AIObservatoryCore

/// 会话性能明细。入参全是值：`stats` 与 `samples` 由调用方各算一次传下来，
/// 这里不读 `PerformanceModel` 的任何计算属性（那是本页内存单调增长的放大器）。
struct PerformanceSessionBreakdown: View {
    /// 明细表最多渲染的行数（列表本身已按 `PerformanceModel.sampleCap` 截断，这里只控制绘制成本）。
    private static let recentRowLimit = 60

    let session: AgentSession?
    /// 是否已经选定观测对象；`nil` = 整机口径。
    let selectedSessionID: UUID?
    let stats: PerformanceSessionStats
    let samples: [PerformanceSample]
    /// 引擎采样节奏的成句文案（由调用方从 `settings.processScanIntervalSeconds` 格式化）。
    let engineIntervalText: String

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.md) {
                SectionHeader(
                    PerformanceCopy.breakdownTitle.text(language),
                    subtitle: headerSubtitle)

                content
            }
        }
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if selectedSessionID == nil {
            EmptyStateView(
                PerformanceCopy.breakdownNoSessionTitle.text(language),
                systemImage: "cursorarrow.click",
                message: PerformanceCopy.breakdownNoSessionMessage.text(language),
                fills: false
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: Sizing.chartHeight)
        } else if samples.isEmpty {
            EmptyStateView(
                PerformanceCopy.breakdownNoSamplesTitle.text(language),
                systemImage: "chart.xyaxis.line",
                message: PerformanceCopy.breakdownNoSamplesMessage.format(language, engineIntervalText),
                fills: false
            )
            .frame(maxWidth: .infinity)
            .frame(minHeight: Sizing.chartHeight)
        } else {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                scopeNote
                sampleTable
            }
        }
    }

    /// 一句自述：这张表按会话给的是什么、不给的是什么。
    /// #84：这一句就是这张表的口径，原先 11pt + 三级色（≈1.8:1）等于藏在桌子底下。
    private var scopeNote: some View {
        Text(PerformanceCopy.breakdownScopeNote.text(language))
            .fixedSize(horizontal: false, vertical: true)
            .axCaptionStyle()
    }

    private var headerSubtitle: String {
        guard let session else {
            return selectedSessionID == nil
                ? PerformanceCopy.breakdownPickHint.text(language)
                : PerformanceCopy.breakdownNotInList.text(language)
        }
        return PerformanceCopy.breakdownSessionFacts.format(
            language, AgentNaming.name(kind: session.kind, form: .full, language),
            session.modifiedFileCount + session.createdFileCount, session.commandCount)
    }

    // MARK: Sample table

    private var recentSamples: [PerformanceSample] {
        Array(samples.suffix(Self.recentRowLimit)).reversed()
    }

    /// 列宽是这套表唯一的对齐依据（表头与行共用同一组数），
    /// 数量有界 ⇒ 非懒 `VStack`；只有下面那段行列表用懒容器。
    /// 刻意不是 `private`：`PerformanceSampleRow` 与表头必须引用同一组数，
    /// 分成两处写死就会在改宽度时错开一位。
    /// #83：这三个别名现在**只是 `Column` 的别名**（改前是 82 / 60 / 78 三个写死的数，
    /// 与时间线页那组 62 / 104 / 16 说的是同一族列，却各拿一把尺）。
    static let timeColumnWidth: CGFloat = Column.time
    static let cpuColumnWidth: CGFloat = Column.percent
    static let memoryColumnWidth: CGFloat = Column.memory

    private var sampleTable: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(spacing: Spacing.sm) {
                Text(PerformanceCopy.columnTime.text(language))
                    .axLeadingColumn(Self.timeColumnWidth)
                Text("CPU")
                    .axNumberColumn(Self.cpuColumnWidth)
                Text(PerformanceCopy.columnMemory.text(language))
                    .axNumberColumn(Self.memoryColumnWidth)
                Spacer(minLength: Spacing.none)
            }
            .font(.axLabel)
            .foregroundStyle(Surface.secondaryLabel)

            Hairline()

            // 本页唯一无上限的行列表（上限 `PerformanceModel.sampleCap`），
            // 所以只有这里是懒容器；里面**不许**放 `.menu` Picker。
            LazyVStack(spacing: Spacing.xs) {
                ForEach(recentSamples) { sample in
                    PerformanceSampleRow(sample: sample)
                }
            }

            if samples.count > Self.recentRowLimit {
                // 「上限」这一档说的是**取数层**的那道（ICR-0007：`performanceSamples(sessionID:limit:)`），
                // 不是本视图这 60 行的版面截断——两者数字不同，混着写会让人以为只有一道限。
                Text(PerformanceCopy.recentRowsNote.format(
                    language, Self.recentRowLimit, samples.count, PerformanceModel.sampleCap))
                    .axCaptionStyle()
            }
        }
    }
}

// MARK: - Sample row

/// 单条采样明细行。
struct PerformanceSampleRow: View {
    let sample: PerformanceSample

    var body: some View {
        HStack(spacing: Spacing.sm) {
            Text(DateFormat.time(sample.timestamp))
                .axLeadingColumn(PerformanceSessionBreakdown.timeColumnWidth)
            Text(PercentFormat.short(sample.cpuPercent, fractionDigits: 1))
                .axNumberColumn(PerformanceSessionBreakdown.cpuColumnWidth)
            Text(ByteFormat.humanReadable(sample.memoryBytes))
                .axNumberColumn(PerformanceSessionBreakdown.memoryColumnWidth)
            Spacer(minLength: Spacing.none)
        }
        .font(.axMetaMono)
        .foregroundStyle(Surface.label)
        .frame(minHeight: Sizing.rowMinHeight - 8)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(PerformanceCopy.sampleRowA11y.format(
            UILanguage.current, DateFormat.time(sample.timestamp),
            PercentFormat.short(sample.cpuPercent, fractionDigits: 1)))
    }
}

#Preview("PerformanceSessionBreakdown 有数据") {
    ObservatoryPreview.screen { runtime in
        PerformanceBreakdownPreviewHost(runtime: runtime)
    }
}

#Preview("PerformanceSessionBreakdown 空态") {
    ObservatoryPreview.screen(empty: true) { runtime in
        PerformanceBreakdownPreviewHost(runtime: runtime)
    }
}

/// Preview 宿主：负责装载数据并驱动会话选择。
private struct PerformanceBreakdownPreviewHost: View {
    @State private var model: PerformanceModel

    init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: PerformanceModel(runtime: runtime))
    }

    var body: some View {
        ScrollView {
            PerformanceSessionBreakdown(
                session: model.selectedSession,
                selectedSessionID: model.selectedSessionID,
                stats: model.sessionStats,
                samples: model.sessionSamples,
                engineIntervalText: intervalText
            )
            .padding(Spacing.xl)
        }
        .task {
            await model.load()
            model.selectedSessionID = model.sessions.first?.id
            await model.loadSessionSamples()
        }
    }

    private var intervalText: String {
        let seconds = model.engineScanIntervalSeconds
        return seconds >= 1 ? String(format: "%.0f 秒", seconds) : String(format: "%.1f 秒", seconds)
    }
}
