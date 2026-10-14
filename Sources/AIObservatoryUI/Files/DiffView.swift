//
//  DiffView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (QUIET-2)
//  ─────────────────────────────────────────────────────────
//  Diff 面板：头部（文件名 / 路径 / 增删统计 / 截断提示 / 模式切换）+ 统一或并排的 diff 内容。
//
//  quiet 语言：标题字号由 `SectionHeader` 定死，调用点不再挂 `.font(.caption)`；
//  增删统计的 +/- 是 diff 功能色（绿 / 红），保留；其余一律语义色 / 次级色。
//  「Before 是哪份」「有没有明文」这些成因措辞全部走共享 readout（口径被测试钉死，不可改）。
//

import SwiftUI
import Observation
import AIObservatoryCore

@MainActor struct DiffView: View {

    private let model: FilesModel
    /// #64：Diff 区的副标题原来直出 `model.diff?.path ?? change.path`（完整绝对路径）。
    @Environment(\.demoRedaction) private var demoRedaction
    /// #81：这一条变更的取证出口要写外壳的路由状态（与时间线详情那两颗同一个入口）。
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(model: FilesModel) {
        self.model = model
   }

    var body: some View {
        VStack(spacing: Spacing.none) {
            header
            Hairline()
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - 头部

    @ViewBuilder private var header: some View {
        if let change = model.selected {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                SectionHeader(
                    change.fileName,
                    subtitle: demoRedaction.scrub(model.diff?.path ?? change.path)) {
                    HStack(spacing: Spacing.sm) {
                        deltaReadout(for: change)
                        Picker(FilesCopy.diffPickerView.text(), selection: Binding(
                            get: { model.viewMode },
                            set: { model.viewMode = $0 }
                        )) {
                            ForEach(FilesDiffViewMode.allCases) { mode in
                                Image(systemName: mode.symbol)
                                    .accessibilityLabel(mode.displayName)
                                    .tag(mode)
                            }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                        .fixedSize()
                        evidenceJumpButton(for: change)
                    }
                }

                if model.diff?.isTruncated == true {
                    HStack(spacing: Spacing.xs) {
                        Image(systemName: "scissors")
                        Text(FilesCopy.diffTruncated.text())
                    }
                    .font(.axMeta)
                    .foregroundStyle(ObservatoryColor.caution)
                }
                if let diff = model.diff {
                    baselineNotice(for: diff)
                }
                if change.kind == .renamed, let previous = change.previousPath {
                    HStack(spacing: Spacing.xs) {
                        // #89 ②：与采集面那一句同族——整句拼进本地化文案、不经过 `FilePathText`，
                        // 所以掩的动作必须落在**拼好之后**（`scrub` 管的是"路径在句中"）。
                        Text(demoRedaction.scrub(FilesCopy.diffRenamedFrom.format(.resolved(), previous)))
                            .font(.axMeta).foregroundStyle(Surface.secondaryLabel)
                    }
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        } else {
            Text("Diff")
                .font(.axSection)
                .foregroundStyle(Surface.label)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Spacing.md)
                .padding(.vertical, Spacing.sm)
        }
    }

    // MARK: - 取证出口（#81：这一条变更回时间线）

    /// 这一条文件变更 → 时间线那一类操作的那一颗按钮。
    ///
    /// 映射不到（`FileChangeKind.unknown`）时**这颗根本不排**：排了却悄悄少带一项条件，
    /// 就回到「屏幕上那句话与实际发出去的那次查询不是一回事」——#81 修的就是这件事。
    /// 带过去的三样都是**这一条变更自己**的事实（项目 / 会话 / 操作类型），
    /// 时间区间带全局那一份（`shell.timeRange`，与页头那把尺同一个出处）。
    @ViewBuilder
    private func evidenceJumpButton(for change: FileChange) -> some View {
        if let kind = JumpIntent.operationKind(forFileKind: change.kind) {
            Button {
                shell?.jump(JumpIntent(target: .timeline,
                                       projectPath: change.projectPath,
                                       sessionID: change.sessionID,
                                       eventKinds: [kind],
                                       timeRange: shell?.timeRange))
            } label: {
                Label(FilesCopy.diffJumpToTimeline.text(), systemImage: "clock.arrow.circlepath")
            }
            .controlSize(.small)
            .accessibilityLabel(FilesCopy.diffJumpToTimeline.text())
        }
    }

    /// 行数增减读数。口径在 ``FileLineDeltaReader``，那里有回归用例钉住
    /// 「拿不到差异就不许报 `+0 / -0`」。与列表行 `FileChangeRow.lineDelta` 同口径。
    @ViewBuilder
    private func deltaReadout(for change: FileChange) -> some View {
        switch FileLineDeltaReader.read(diff: model.diff, change: change) {
        case .notCaptured(let sizeBytes):
            Text(FilesCopy.diffLinesNotCaptured.format(.resolved(), ByteFormat.humanReadable(sizeBytes)))
                .font(.axMeta)
                .monospacedDigit()
                .axCaptionStyle()   // #99：承载口径，曾在最低档
                .accessibilityLabel(FilesCopy.diffLinesNotCapturedA11y.format(.resolved(), ByteFormat.humanReadable(sizeBytes)))
        case .measured(let added, let removed):
            Text("+\(added)")
                .font(.axMeta)
                .monospacedDigit()
                .foregroundStyle(ObservatoryColor.positive)
            Text("-\(removed)")
                .font(.axMeta)
                .monospacedDigit()
                .foregroundStyle(ObservatoryColor.critical)
        }
    }

    /// 「没有 diff」的成因按变更类型分档，措辞规则见 ``FileLineDeltaReader``。
    private var missingDiffMessage: String {
        FileLineDeltaReader.message(
            for: FileLineDeltaReader.reason(for: model.selected?.kind)
        )
    }

    /// 「Before 是哪份」必须写在面板上：读者看到一排绿色新增行时，有权知道那到底是
    /// 「有可比版本、确实只加了这些」，还是「我们根本没有改前版本」。
    @ViewBuilder
    private func baselineNotice(for diff: FileDiff) -> some View {
        let readout = DiffBaselineReader.readout(for: diff)
        HStack(alignment: .firstTextBaseline, spacing: Spacing.xs) {
            Image(systemName: readout == .firstSighting ? "questionmark.circle" : "clock.arrow.circlepath")
            Text(DiffBaselineReader.message(for: readout, timeText: Self.timeText(of: diff)))
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(.axMeta)
        .foregroundStyle(readout == .firstSighting ? ObservatoryColor.caution : Surface.secondaryLabel)
    }

    /// 格式化只在这里做；口径函数拿的是已经排好的文本（见 `DiffBaselineReader.message`）。
    private static func timeText(of diff: FileDiff) -> String {
        guard let observedAt = diff.baselineCapturedAt else { return "" }
        return observedAt.formatted(date: .abbreviated, time: .shortened)
    }

    /// 「有 diff 却一行都不显示」的文案：设置关掉的明文，与真的没有行级差异，两件事分开说。
    private var emptyLinesNotice: String {
        guard let diff = model.diff else { return missingDiffMessage }
        return DiffBaselineReader.emptyLinesMessage(for: diff)
    }

    // MARK: - 内容

    @ViewBuilder private var content: some View {
        switch model.diffState {
        case .loading:
            VStack(spacing: Spacing.md) {
                ProgressView()
                Text(FilesCopy.diffGenerating.text())
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .missing:
            EmptyStateView(
                FilesCopy.diffNoTextTitle.text(),
                systemImage: "doc.questionmark",
                message: missingDiffMessage
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.lg)

        case .binary:
            EmptyStateView(
                FilesCopy.diffBinaryTitle.text(),
                systemImage: "shippingbox",
                message: FilesCopy.diffBinaryMessage.format(.resolved(), ByteFormat.humanReadable(model.selected?.sizeBytes ?? 0))
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.lg)

        case .idle:
            EmptyStateView(
                FilesCopy.diffPickChangeTitle.text(),
                systemImage: "doc.text.magnifyingglass",
                message: FilesCopy.diffPickChangeMessage.text()
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(Spacing.lg)

        case .loaded, .truncated:
            if let diff = model.diff, !diff.lines.isEmpty {
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: Spacing.none) {
                        switch model.viewMode {
                        case .unified:
                            UnifiedDiffListView(lines: diff.lines)
                        case .sideBySide:
                            SideBySideDiffListView(lines: diff.lines)
                        }
                    }
                }
                .textSelection(.enabled)
            } else {
                EmptyStateView(
                    FilesCopy.diffNoLineChanges.text(),
                    systemImage: "equal.circle",
                    message: emptyLinesNotice
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(Spacing.lg)
            }
        }
    }
}
