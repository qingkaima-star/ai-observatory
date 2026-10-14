//
//  SelfProcessOverheadPanel.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-UI（uiclose · #29）
//  ─────────────────────────────────────────────────────────
//  职责：性能页里「本 App 自身开销」那一块——判据④（空闲 CPU < 3%、常驻 < 200 MB）
//  第一次在**界面内**自证，而不是只能靠外部工具量。
//  文案全部出自 `SelfProcessOverheadCopy`（纯函数、可单测），视图只做排版。
//
//  三条口径在界面上的落点（缺一条这一格就是半句话，见 `SelfProcessGauge` 文件头）：
//  · 标题与 CPU 副标题点明「本进程 / 不含子进程」，与被观测 Agent 的**进程树合计**口径分开；
//  · 内存格写的是 `phys_footprint` 并明写「不是 RSS」；
//  · 峰值单独成格，且写明「采样间隙的瞬时峰值读不到」——它是下界，不许被读成真峰值。
//

import SwiftUI
import AIObservatoryCore

// MARK: - Copy

/// 这一块的文案与判据措辞。**与视图分开**是为了能被手推字面量断言住：
/// 口径写错就是界面撒谎，而撒谎恰好是这一格存在的唯一理由要防的事。
enum SelfProcessOverheadCopy {
    /// 静默窗的负载上限。取自 AGENTS.md §6：「机器 load 5–12 时量出来的绝对值不是结论」——
    /// 那条明写的区间从 5 起，所以上限取 4（保守侧），而不是另造一个数。
    static let quietLoadCeiling: Double = 4

    /// 本机是否处于静默窗。`nil` = 还没有整机采样，**不知道**，按「不能确认」处理：
    /// 确认不了就不给「静默窗实测」这个更强的说法。
    static func isQuietWindow(load1m: Double?) -> Bool {
        guard let load1m, load1m.isFinite else { return false }
        return load1m <= quietLoadCeiling
    }

    /// 窗口说明句：起点 → 终点（时长 · 读数个数 · 实测节拍）。
    /// 判据④ 要求「measurement 窗口起点/时长」必须写明白，缺这句这一格就不可核对。
    static func windowNote(_ overhead: SelfProcessOverhead, now: Date,
                           _ language: AppLanguage = UILanguage.current) -> String {
        let span = DurationFormat.compact(overhead.durationSeconds)
        let lag = DurationFormat.compact(max(0, now.timeIntervalSince(overhead.windowEnd)))
        let cadence = overhead.averageGapSeconds.map {
            PerformanceCopy.selfCadenceFragment.format(language, String(format: "%.0f", $0))
        } ?? ""
        return PerformanceCopy.selfWindowNote.format(
            language,
            DateFormat.time(overhead.windowStart),
            DateFormat.time(overhead.windowEnd),
            span,
            overhead.sampleCount,
            cadence,
            lag
        )
    }

    /// 达标结论行。CPU 与内存**各判各的**，因为两者的判据口径不同：
    /// CPU 要窗口 ≥60 秒（AGENTS.md §6），内存看末值（ADR-0009 裁定 5 的稳态口径）。
    static func verdictNote(
        _ overhead: SelfProcessOverhead,
        cpuBudgetPercent: Double,
        memoryLimitMB: Double,
        load1m: Double?,
        _ language: AppLanguage = UILanguage.current
    ) -> String {
        let cpu = overhead.cpuVerdict(
            budgetPercent: cpuBudgetPercent,
            windowFloorSeconds: SelfProcessGauge.cpuVerdictFloorSeconds
        )
        let memory = overhead.memoryVerdict(limitMB: memoryLimitMB)
        let cpuText = overhead.cpuPercent.map { String(format: "%.1f", $0) } ?? "—"
        var line = PerformanceCopy.selfVerdictCPU.format(
                language, PercentFormat.short(cpuBudgetPercent), cpuText, cpu.label(language))
            + PerformanceCopy.selfVerdictMemory.format(
                language, Int(memoryLimitMB), String(format: "%.1f", overhead.footprintMB),
                memory.label(language))
        switch cpu {
        case .windowForming:
            line += PerformanceCopy.selfVerdictNeedsWindow.format(
                language, Int(SelfProcessGauge.cpuVerdictFloorSeconds))
        case .withinBudget, .overBudget:
            // 静默窗这条不能省：AGENTS.md §6 明写 load 5–12 时量出来的绝对值不是结论，
            // 少了这句，一个 6.7% 的窗口值就会被读成「本 App 超预算 2 倍」。
            switch load1m {
            case .none:
                line += PerformanceCopy.selfVerdictNoSystemSample.text(language)
            case .some(let load) where !isQuietWindow(load1m: load):
                line += PerformanceCopy.selfVerdictBusyMachine.format(
                    language, String(format: "%.1f", load))
            case .some:
                break
            }
        }
        return line
    }

    /// 口径分隔句：同一页两套数字，不写这句就会复现 #30 那种「5.11 GB 像单进程」的误读。
    /// ⚠️ 上屏字符串里**不许用 markdown 强调**：`Text(_:)` 拿到的是 `LocalizableStringKey`，
    /// 只有本地化键才走 markdown 解析，代码里的字面量会把 `**` 原样画出来
    /// （真机截图抓到过一次，见 `03-进度日志/2026-09-20-性能.md` 的 uiclose 一节）。
    static var scopeNote: String { scopeNote(UILanguage.current) }

    static func scopeNote(_ language: AppLanguage) -> String {
        PerformanceCopy.selfScopeNote.text(language)
    }

    /// 仪器未接入时的说明。写清「目标值是真的、读数是没有的」，
    /// 而不是留一句含糊的「暂不支持」让人以为这一格坏了。
    static func notInstrumentedNote(
        cpuBudgetPercent: Double,
        memoryLimitMB: Double,
        memoryTargetMB: Double,
        _ language: AppLanguage = UILanguage.current
    ) -> String {
        PerformanceCopy.selfNotInstrumentedNote.format(
            language, PercentFormat.short(cpuBudgetPercent), Int(memoryLimitMB), Int(memoryTargetMB)
        )
    }
}

// MARK: - View

/// 「本 App 自身开销」面板：四格读数 + 窗口说明 + 达标结论 + 口径分隔。
///
/// 入参全是值，且 `overhead` 由 `PerformanceModel` 在采样的那一刻算好存下来——
/// 不在 body 里遍历序列（这一页的教训见 `PerformanceSeriesMetrics` 文件头）。
struct SelfProcessOverheadPanel: View {
    let overhead: SelfProcessOverhead?
    /// 宿主有没有把读数来源接进来。`false` 时这一格明写「未接入」，不画空读数。
    let isInstrumented: Bool
    /// 整机 1 分钟负载，只用来判「这是不是静默窗」。
    let machineLoad1m: Double?

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(PerformanceCopy.selfPanelTitle.text(language),
                              subtitle: PerformanceCopy.selfPanelSubtitle.text(language))
                PerformanceSummaryGrid(tiles, columns: Sizing.metricColumns)
                notes
            }
        }
    }

    private var language: AppLanguage { UILanguage.current }

    private var tiles: [PerformanceMetricTile] {
        guard let overhead else { return PerformanceMetricTile.pending(language) }
        let cpuBudget = PerformanceModel.idleCPUBudgetPercent
        let memoryLimit = PerformanceModel.memoryBudgetMB
        let headroom = overhead.headroomPercent(limitMB: memoryLimit)
        let peakHeadroom = overhead.peakHeadroomPercent(limitMB: memoryLimit)
        return [
            PerformanceMetricTile(
                id: 0,
                title: PerformanceCopy.selfTileCPU.text(language),
                value: overhead.cpuPercent.map { String(format: "%.1f", $0) } ?? "—",
                unit: overhead.cpuPercent == nil ? "" : "%",
                caption: PerformanceCopy.selfCPUCaption.format(
                    language, PercentFormat.short(cpuBudget))
            ),
            PerformanceMetricTile(
                id: 1,
                title: PerformanceCopy.selfTileFootprint.text(language),
                value: String(format: "%.1f", overhead.footprintMB),
                unit: "MB",
                caption: PerformanceCopy.selfFootprintCaption.format(
                    language, Int(memoryLimit), Int(PerformanceModel.memoryTargetMB))
            ),
            PerformanceMetricTile(
                id: 2,
                title: PerformanceCopy.selfTileHeadroom.text(language),
                value: String(format: "%.0f", headroom),
                unit: "%",
                caption: PerformanceCopy.selfHeadroomCaption.format(
                    language, String(format: "%.0f", peakHeadroom))
            ),
            PerformanceMetricTile(
                id: 3,
                title: PerformanceCopy.selfTilePeak.text(language),
                value: String(format: "%.1f", overhead.peakFootprintMB),
                unit: "MB",
                caption: PerformanceCopy.selfPeakCaption.text(language)
            ),
        ]
    }

    @ViewBuilder
    private var notes: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            if let overhead {
                Text(SelfProcessOverheadCopy.windowNote(overhead, now: Date(), language))
                Text(SelfProcessOverheadCopy.verdictNote(
                    overhead,
                    cpuBudgetPercent: PerformanceModel.idleCPUBudgetPercent,
                    memoryLimitMB: PerformanceModel.memoryBudgetMB,
                    load1m: machineLoad1m,
                    language
                ))
            } else if isInstrumented {
                Text(PerformanceCopy.selfWaitingFirstReading.format(
                    language, String(format: "%.0f", SelfProcessGauge.sampleGapSeconds)))
            } else {
                Text(SelfProcessOverheadCopy.notInstrumentedNote(
                    cpuBudgetPercent: PerformanceModel.idleCPUBudgetPercent,
                    memoryLimitMB: PerformanceModel.memoryBudgetMB,
                    memoryTargetMB: PerformanceModel.memoryTargetMB,
                    language
                ))
            }
            Text(SelfProcessOverheadCopy.scopeNote(language))
        }
        .axCaptionStyle()   // #99：这句承载口径，曾在最低档（≈1.8:1）
        .fixedSize(horizontal: false, vertical: true)
        .textSelection(.enabled)
    }
}

// MARK: - Tiles

extension PerformanceMetricTile {
    /// 仪器没接上时的四格：每格都是「—」，配一句各自该说明的话。
    /// 刻意不给 0——0 是最容易被当成结论的那个值（见 `MetricAvailability` 文件头）。
    /// 做成函数而不是 `static let`：这四句是判据④ 的口径句，语言要在取用处定，
    /// 而 `static let` 会在进程启动时按当时的语言定死（测试也就无法逐字对两语言）。
    static func pending(_ language: AppLanguage) -> [PerformanceMetricTile] {
        [
            .init(id: 0, title: PerformanceCopy.selfTileCPU.text(language), value: "—", unit: "%",
                  caption: PerformanceCopy.selfPendingCPU.text(language)),
            .init(id: 1, title: PerformanceCopy.selfTileFootprint.text(language), value: "—", unit: "MB",
                  caption: PerformanceCopy.selfNotRSS.text(language)),
            .init(id: 2, title: PerformanceCopy.selfTileHeadroom.text(language), value: "—", unit: "%",
                  caption: PerformanceCopy.selfPendingHeadroom.text(language)),
            .init(id: 3, title: PerformanceCopy.selfTilePeak.text(language), value: "—", unit: "MB",
                  caption: PerformanceCopy.selfPendingPeak.text(language)),
        ]
    }
}

#Preview("本 App 自身开销 · 已接入并成形") {
    Panel {
        SelfProcessOverheadPanel(
            overhead: SelfProcessOverhead.demo,
            isInstrumented: true,
            machineLoad1m: 0.8
        )
    }
    .padding(Spacing.xl)
    .frame(width: 1_000)
    .background(Surface.page)
}

#Preview("本 App 自身开销 · 未接入") {
    Panel {
        SelfProcessOverheadPanel(
            overhead: nil,
            isInstrumented: false,
            machineLoad1m: nil
        )
    }
    .padding(Spacing.xl)
    .frame(width: 1_000)
    .background(Surface.page)
}

extension SelfProcessOverhead {
    /// 仅供 Preview：演示「这一格长什么样」，不参与生产路径。
    /// 168 秒 / 15 个读数——刻意留在 180 秒窗口之内，免得 Preview 展示一个实际到不了的状态。
    static let demo = SelfProcessOverhead(
        windowStart: Date(timeIntervalSince1970: 1_700_000_000),
        windowEnd: Date(timeIntervalSince1970: 1_700_000_168),
        sampleCount: 15,
        cpuPercent: 1.8,
        footprintBytes: 93_113_505,      // ≈ 88.8 MB
        peakFootprintBytes: 192_323_744  // ≈ 183.4 MB
    )
}
