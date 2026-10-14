//
//  DiffLineListView.swift
//  AIObservatoryUI / Files
//
//  Owner: WS-UI (QUIET-2)
//  ─────────────────────────────────────────────────────────
//  DiffLine 的两种渲染器：统一视图（unified）与并排视图（side-by-side）。
//
//  quiet 语言下的修正：增删行的颜色是**功能色**，保留（`.axMono` / `.axMetaMono`），
// 但**不再整行铺色**——整行铺色在深色下发脏。改用「左侧 2pt 色条 + 文字色」：
// 行首一根 2pt 的 diff 色竖条，文字本身也带 diff 色，整行底色保持透明。
// 行高收紧（`.axMono` 12pt），不画框。
//

import SwiftUI
import AIObservatoryCore

// MARK: - Unified

/// 统一 diff 视图：逐行铺开，左栏旧行号 / 右栏新行号。
@MainActor
struct UnifiedDiffListView: View {
    let lines: [DiffLine]

    var body: some View {
        if lines.isEmpty {
            EmptyStateView(
                FilesCopy.diffListEmptyTitle.text(),
                systemImage: "doc.text.magnifyingglass",
                message: FilesCopy.diffListEmptyMessage.text()
            )
            .frame(maxWidth: .infinity, minHeight: 160)
        } else {
            ScrollView([.vertical, .horizontal]) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { line in
                        DiffUnifiedRow(line: line)
                    }
                }
                .padding(.vertical, Spacing.xs)
                .frame(minWidth: .zero, alignment: .leading)
            }
            .textSelection(.enabled)
            .background(Surface.recessed)
        }
    }
}

/// 统一视图的一行。
@MainActor
struct DiffUnifiedRow: View {
    let line: DiffLine

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            Text(line.oldLineNumber.map(String.init) ?? "")
                .axNumberColumn(Column.count)
            Text(line.newLineNumber.map(String.init) ?? "")
                .axNumberColumn(Column.count)
            Text(glyph + " ")
                .foregroundStyle(ObservatoryTheme.diffColor(for: line.style))
            Text(line.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.axMono)
        .foregroundStyle(textColor)
        .padding(.leading, Spacing.sm)
        .padding(.trailing, Spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 左侧 2pt 色条代替整行铺色：只在增 / 删 / hunk 上出现。
        .background(alignment: .leading) { leftBar }
    }

    private var glyph: String {
        switch line.style {
        case .added:       return "+"
        case .removed:     return "-"
        case .hunkHeader:  return "@"
        case .meta:        return "#"
        case .context:     return " "
        }
    }

    private var textColor: Color {
        switch line.style {
        case .context:     return Surface.label
        case .hunkHeader:  return ObservatoryTheme.diffColor(for: line.style)
        case .meta:        return Surface.secondaryLabel
        default:           return Surface.label
        }
    }

    /// 仅增 / 删 / hunk 行画一根 2pt 色条；context / meta 不画。
    @ViewBuilder private var leftBar: some View {
        switch line.style {
        case .context, .meta:
            EmptyView()
        default:
            Rectangle()
                .fill(ObservatoryTheme.diffColor(for: line.style))
                .frame(width: 2)
        }
    }
}

// MARK: - Side by side

/// 并排 diff 视图：左旧右新，删除行与新增行成对占位。
@MainActor
struct SideBySideDiffListView: View {
    let lines: [DiffLine]

    /// 一行左右两侧的配对内容。
    private struct SidePair: Identifiable {
        let id: Int
        let left: DiffLine?
        let right: DiffLine?
        let header: Bool
    }

    var body: some View {
        if lines.isEmpty {
            UnifiedDiffListView(lines: [])
        } else {
            // 两栏标题：同字号（`axSection`）、同基线，且严格对齐——
            // 并排视图的两栏标题必须一致，别一栏改了另一栏没改（WS-Quiet2 坑 #8）。
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    sideTitle(FilesCopy.diffSideBefore.text())
                    Divider()
                    sideTitle(FilesCopy.diffSideAfter.text())
                }
                .padding(.bottom, Spacing.xs)

                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(pairs) { pair in
                            if pair.header, let line = pair.left ?? pair.right {
                                DiffHeaderBand(line: line)
                            } else {
                                HStack(alignment: .top, spacing: 0) {
                                    DiffSideCell(line: pair.left, side: .left)
                                    Divider()
                                    DiffSideCell(line: pair.right, side: .right)
                                }
                            }
                        }
                    }
                    .padding(.vertical, Spacing.xs)
                }
                .textSelection(.enabled)
                .background(Surface.recessed)
            }
        }
    }

    private func sideTitle(_ text: String) -> some View {
        Text(text)
            .font(.axSection)
            .foregroundStyle(Surface.secondaryLabel)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, Spacing.sm)
            .padding(.trailing, Spacing.sm)
    }

    /// 把扁平的 DiffLine 折叠成左右配对：连续的 removed 与新增的 added 一一对齐。
    private var pairs: [SidePair] {
        var result: [SidePair] = []
        var removals: [DiffLine] = []
        var additions: [DiffLine] = []
        var index = 0

        func flush() {
            let rowCount = max(removals.count, additions.count)
            for row in 0..<rowCount {
                result.append(
                    SidePair(
                        id: index,
                        left: row < removals.count ? removals[row] : nil,
                        right: row < additions.count ? additions[row] : nil,
                        header: false
                    )
                )
                index += 1
            }
            removals.removeAll(keepingCapacity: true)
            additions.removeAll(keepingCapacity: true)
        }

        for line in lines {
            switch line.style {
            case .removed:
                removals.append(line)
            case .added:
                additions.append(line)
            case .context:
                flush()
                result.append(SidePair(id: index, left: line, right: line, header: false))
                index += 1
            case .hunkHeader, .meta:
                flush()
                result.append(SidePair(id: index, left: line, right: line, header: true))
                index += 1
            }
        }
        flush()
        return result
    }
}

/// 并排视图的单元格（缺失一侧时留空）。
@MainActor
struct DiffSideCell: View {
    enum Side { case left, right }

    let line: DiffLine?
    let side: Side

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.xs) {
            Text(numberText)
                .font(.axMetaMono)
                .foregroundStyle(Surface.tertiaryLabel)
                .axNumberColumn(Column.count)
            Text(bodyText)
                .font(.axMono)
                .foregroundStyle(foreground)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.leading, Spacing.sm)
        .padding(.trailing, Spacing.sm)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 左侧 2pt 色条代替整行铺色：空单元格 / 纯 context 不画。
        .background(alignment: .leading) { leftBar }
    }

    private var numberText: String {
        guard let line else { return "" }
        return side == .left
            ? (line.oldLineNumber.map(String.init) ?? "")
            : (line.newLineNumber.map(String.init) ?? "")
    }

    private var bodyText: String {
        line?.text ?? ""
    }

    private var foreground: Color {
        guard let line else { return Surface.label }
        return line.style == .context ? Surface.label : ObservatoryTheme.diffColor(for: line.style)
    }

    @ViewBuilder private var leftBar: some View {
        if let line, line.style != .context, line.style != .meta {
            Rectangle()
                .fill(ObservatoryTheme.diffColor(for: line.style))
                .frame(width: 2)
        }
    }
}

/// hunk 头横条：只保留彩色文字 + 一根左侧色条，**不再整行铺色**（深色下发脏）。
@MainActor
struct DiffHeaderBand: View {
    let line: DiffLine

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(ObservatoryTheme.diffColor(for: line.style))
                .frame(width: 2)
            Text(line.text)
                .font(.axMetaMono)
                .foregroundStyle(ObservatoryTheme.diffColor(for: line.style))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, Spacing.sm)
        }
        .padding(.vertical, Spacing.xs)
    }
}

// MARK: - Previews

#Preview("统一 Diff") {
    ObservatoryPreview.screen { runtime in
        DiffPreviewHost(runtime: runtime)
    }
}

/// 仅用于 Preview：从样本服务取一份真实 diff 来渲染两种视图。
@MainActor
private struct DiffPreviewHost: View {
    let runtime: ObservatoryRuntime
    @State private var diff: FileDiff?

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.md) {
            if let diff {
                SectionHeader("统一视图")
                UnifiedDiffListView(lines: diff.lines)
                    .frame(height: 220)
                SectionHeader("并排视图")
                SideBySideDiffListView(lines: diff.lines)
                    .frame(height: 220)
            } else {
                ProgressView()
            }
        }
        .padding(Spacing.lg)
        .task {
            do {
                let page = try await runtime.service.fileChanges(matching: FileChangeQuery(limit: 1))
                if let change = page.items.first {
                    diff = try await runtime.service.fileDiff(for: change.id)
                }
            } catch {
                diff = nil
            }
        }
    }
}
