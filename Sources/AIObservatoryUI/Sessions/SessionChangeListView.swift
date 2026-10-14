//
//  SessionChangeListView.swift
//  AIObservatoryUI / Sessions
//
//  Owner: ws/engaudit（#60，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  会话详情的「改动清单」页签：一次改动一行，写清动了哪个文件、
//  这个文件还没提交还是已提交、能不能退回，并给一个「改前 / 改后」入口。
//
//  三条界面口径（都有用例对着，不要"顺手美化"掉）：
//   · **一行 = 一条改动**，不并成一个文件：等价式是"条数 == 该会话 `file_changes` 行数"；
//     标题同时给"几次改动 · 几个文件"两个数，读者不会以为 9 就是 12。
//   · 回滚状态**四态四句**：未提交可退回 / 已提交 / 无版本控制无法回滚 / 未能确认。
//     后两句不许并排显示成同一句，也不许把"未能确认"写成"干净"——那是界面在说谎。
//   · 取不满时必须写明"仅前 N 条"，不能让清单冒充全量。
//
//  只读：这一页不执行任何 git 写操作，也不提供"帮你回滚"的按钮（#60 第 3 条红线）。
//  「改前 / 改后」只做只读取数（`fileDiff(for:)`），逐行对照的完整视图仍在 Files 页，
//  这里不复制一份（那两个组件不是我的射程，复制一份必然开始各说一套）。
//

import SwiftUI
import AIObservatoryCore

/// 会话「本次改动清单」。
struct SessionChangeListView: View {

    let model: SessionsModel

    private var language: AppLanguage { UILanguage.current }
    private var inventory: SessionChangeInventory { model.changeInventory }

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                header
                if let message = model.changeErrorMessage {
                    Text(SessionsCopy.changesError.copy.format(language, message))
                        .font(.axMeta)
                        .foregroundStyle(Surface.label)
                }
                if inventory.rows.isEmpty && !model.isLoadingChanges {
                    Text(SessionsCopy.changesEmpty.text(language))
                        .font(.axBody)
                        .foregroundStyle(Surface.secondaryLabel)
                }
                rows
            }
        }
        .task(id: model.selectedID) { await model.loadChanges() }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            VStack(alignment: .leading, spacing: 2) {
                Text(SessionsCopy.changesTitle.text(language))
                    .font(.axSection)
                Text(SessionsCopy.changesSummary.copy.format(
                    language, inventory.changeCount, inventory.fileCount
                ))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .monospacedDigit()
            }
            Spacer(minLength: 0)
            if inventory.uncommittedCount > 0 {
                Text(SessionsCopy.changesUncommittedCount.copy.format(language, inventory.uncommittedCount))
                    .font(.axMeta)
                    .foregroundStyle(Surface.label)
            }
            if !inventory.isComplete {
                Text(SessionsCopy.changesPartial.copy.format(
                    language, inventory.changeCount, inventory.serverRowCount
                ))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            }
        }
    }

    // MARK: - 行

    @ViewBuilder private var rows: some View {
        if model.isLoadingChanges && inventory.rows.isEmpty {
            ProgressView().controlSize(.small)
        }
        ForEach(inventory.rows) { row in
            SessionChangeRowView(row: row, status: inventory.rollbackStatus(for: row), model: model)
            Divider()
        }
    }
}

/// 一行改动：路径、操作类型、行数增减、回滚判定，以及「改前 / 改后」入口。
private struct SessionChangeRowView: View {

    let row: SessionChangeRow
    let status: FileRollbackStatus
    let model: SessionsModel
    /// #64：这一行把「目录」单独铺成一格（`deletingLastPathComponent` = 绝对目录），
    /// 是会话页最大的一个路径出口。
    @Environment(\.demoRedaction) private var demoRedaction

    @State private var diff: FileDiff?
    @State private var isLoadingDiff = false
    @State private var didAttempt = false

    private var language: AppLanguage { UILanguage.current }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(demoRedaction.scrub((row.path as NSString).lastPathComponent))
                        .font(.axBody)
                    Text(demoRedaction.scrub((row.path as NSString).deletingLastPathComponent))
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 0)
                rollbackChip
            }
            HStack(spacing: Spacing.sm) {
                Text(row.kind.displayName)
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                Text("+\(row.linesAdded) −\(row.linesRemoved)")
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
                Spacer(minLength: 0)
                diffEntry
            }
            diffDetail
        }
        .accessibilityElement(children: .combine)
    }

    /// 四态四句。`unknown` 单独一句"未能确认"——**不许**与"已提交"共用样式。
    private var rollbackChip: some View {
        Text(label)
            .font(.axMeta)
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .uncommitted: return SessionsCopy.rollbackUncommitted.text(language)
        case .committed: return SessionsCopy.rollbackCommitted.text(language)
        case .notVersioned: return SessionsCopy.rollbackNotVersioned.text(language)
        case .unknown: return SessionsCopy.rollbackUnknown.text(language)
        }
    }

    /// 颜色只用来分层强弱，**四种状态靠字面区分**：`notVersioned` 与 `unknown`
    /// 都是"不能假定可回滚"的坏消息，用 tertiary 会把它们压得跟"已提交"一样轻。
    private var color: Color {
        switch status {
        case .uncommitted, .notVersioned, .unknown: return Surface.label
        case .committed: return Surface.secondaryLabel
        }
    }

    private var diffEntry: some View {
        Button {
            guard !didAttempt, !isLoadingDiff else { return }
            isLoadingDiff = true
            didAttempt = true
            Task {
                let loaded = await model.diff(for: row.changeID)
                isLoadingDiff = false
                diff = loaded
            }
        } label: {
            Text(SessionsCopy.diffEntry.text(language))
                .font(.axMeta)
        }
        .buttonStyle(.link)
    }

    @ViewBuilder private var diffDetail: some View {
        if isLoadingDiff {
            Text(SessionsCopy.diffLoading.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
        } else if didAttempt, let diff {
            // 「入口」= 一眼看到这条改动前后的样子；完整逐行对照仍在 Files 页，这里不复制一份。
            HStack(spacing: Spacing.xs) {
                Text(SessionsCopy.diffMeta.copy.format(
                    language,
                    diff.lines.filter { $0.style == .removed || $0.style == .context }.count,
                    diff.lines.filter { $0.style == .added || $0.style == .context }.count,
                    diff.linesAdded,
                    diff.linesRemoved
                ))
                if diff.isBinary {
                    Text(SessionsCopy.diffBinary.text(language))
                } else if diff.isTruncated {
                    Text(SessionsCopy.diffTruncated.text(language))
                }
            }
            .font(.axMeta)
            .foregroundStyle(Surface.secondaryLabel)
            .monospacedDigit()
            ForEach(diff.lines.prefix(8)) { line in
                if line.style == .added || line.style == .removed {
                    Text(verbatim: (line.style == .added ? "+ " : "− ") + line.text)
                        .font(.axMetaMono)
                        .foregroundStyle(Surface.secondaryLabel)
                        .lineLimit(1)
                }
            }
        } else if didAttempt {
            Text(SessionsCopy.diffUnavailable.text(language))
                .font(.axMeta)
                .foregroundStyle(Surface.label)
        }
    }
}
