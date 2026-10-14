//
//  AttributionGapPanel.swift
//  AIObservatoryUI / Files
//
//  Owner: WS-UI（uicopy · #54 / ICR-0009 界面那一半）
//  ─────────────────────────────────────────────────────────
//  文件页上那一格「本次运行内的归属缺口」：把 `AttributionGapReporting` 的读数原样列出来。
//  `AttributionGapReporting.currentAttributionGap()` 在数据侧落地（引擎 `ObservatoryEngine.swift:523`）
//  之后一直**零消费者**——本文件就是那个消费者。
//
//  【三条硬约束怎么落在代码上，逐条有用例】
//  ① `nil` 与 `total == 0` 分开说：`nil` → 「本次运行尚无归属读数」，
//     `total == 0` → 「本次运行内的文件变更全部归上了因」。
//     这一条与 ICR-0006 同族："没有读数"和"一条都没漏"是两件事，合并就是一句假话。
//  ② 每一句都带「本次运行内」：这份账不落库、重启归零（契约注释原话），
//     写成保留期内的历史总数就是假数。用例扫渲染出来的每个字符串。
//  ③ **只数不判**：只列非零机制 + 条数（按 `Reason.rank`，不是 `CaseIterable` 顺序），
//     全零时不画空表；不讲责任、不给建议、不复刻判定规则。
//     用例把"不许出现的词"钉成禁句表（建议/应当/配置/权限不足…），
//     并且**反向**要求四个机制名一个都不许少（少一个就是在替引擎挑"哪些值得说"）。
//
//  措辞一律走 `AttributionCopy`（#47-B 立的唯一出处），这里不开第二套"未归属"说法。
//

import SwiftUI
import AIObservatoryCore

/// 归属缺口那一格。入参是**值**：由 `FilesModel` 每轮 `load()` 取一次，视图不自己查引擎。
@MainActor struct AttributionGapPanel: View {

    let gap: AttributionGap?

    @MainActor init(gap: AttributionGap?) {
        self.gap = gap
    }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                SectionHeader(AttributionCopy.gapTitle.text(language),
                              subtitle: AttributionCopy.gapSubtitle.text(language))
                Hairline()
                content
            }
        }
    }

    @ViewBuilder private var content: some View {
        if let gap {
            if gap.total == 0 {
                Text(AttributionCopy.gapNothingMissing.copy.format(language, gap.total))
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                // 行数量有上界（四个机制）⇒ 非懒栈。
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    ForEach(Self.visibleReasons(in: gap), id: \.self) { reason in
                        Text(AttributionCopy.gapRow.copy.format(
                            language,
                            AttributionCopy.gapReasonLabel(reason, language),
                            gap.count(of: reason)
                        ))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Hairline()
                Text(AttributionCopy.gapTotalRow.copy.format(language, gap.total))
                    .font(.axMeta)
                    .monospacedDigit()
                    .axCaptionStyle()   // #99：承载口径，曾在最低档
            }
        } else {
            Text(AttributionCopy.gapNoReading.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// 要列出来的机制：**非零的**那些，按 `rank` 排。
    ///
    /// 为什么单独拎成静态纯函数：视图渲染不进单元测试，而"排序用 rank 不用 CaseIterable"、
    /// "零条目不画行"这两条判据必须可测。`CaseIterable` 的顺序是
    /// `nothingDetected, detectedWithoutWorkingDirectory, workingDirectoryUnusable, outside…`，
    /// 而 `rank` 把 `workingDirectoryUnusable` 提到第 2 位（本机今天的主因）——
    /// 两者不同，用错就看不出差别，所以用例直接钉死顺序。
    static func visibleReasons(in gap: AttributionGap) -> [AttributionGap.Reason] {
        AttributionGap.Reason.allCases
            .filter { gap.count(of: $0) > 0 }
            .sorted { $0.rank < $1.rank }
    }

    private var language: AppLanguage { UILanguage.current }
}

// MARK: - Previews

#Preview("归属缺口 · 有分布") {
    AttributionGapPanel(gap: AttributionGap(counts: [
        .workingDirectoryUnusable: 178,
        .outsideEveryWorkingDirectory: 3,
    ]))
        .padding(Spacing.lg)
        .frame(width: 520)
        .background(Surface.page)
}

#Preview("归属缺口 · 全部归上") {
    AttributionGapPanel(gap: AttributionGap(counts: [:]))
        .padding(Spacing.lg)
        .frame(width: 520)
        .background(Surface.page)
}

#Preview("归属缺口 · 尚无读数") {
    AttributionGapPanel(gap: nil)
        .padding(Spacing.lg)
        .frame(width: 520)
        .background(Surface.page)
}
