//
//  FilesView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (QUIET-2)
//  ─────────────────────────────────────────────────────────
//  文件板块主视图：指标区（hero = 变更文件总数）→ 过滤条 → 变更列表（左）/ Diff 面板（右）主从布局。
//
//  quiet 语言：外层唯一容器是 `ObservatoryPage`；本页唯一 `.hero` 是「变更文件总数」——
//  它决定用户要不要继续往下看某一条变更。列表行压成单行 + 尾元信息（`FileChangeRow`），
//  主从区用 `Panel` + `Hairline(vertical)` 收口，不画框不铺自造灰。
//  增删行数是 diff 功能色（绿 / 红），保留；其余一律语义色。
//

import SwiftUI
import Observation
import AIObservatoryCore

// MARK: - 主从区高度带

/// 主从区的高度带。`List` / 内部 `ScrollView` 坐在 `ObservatoryPage` 的 `ScrollView` 里，
/// 必须拿到确定高度，否则塌成 0（旧版用 `GeometryReader` 求宽会把高度也塌掉）。
private enum FilesSplitBand {
    static let minHeight: CGFloat = 520
    static let maxHeight: CGFloat = 620
}

@MainActor struct FilesView: View {

    @State private var model: FilesModel
    @Environment(ShellModel.self) private var shell: ShellModel?

    init(runtime: ObservatoryRuntime) {
        _model = State(initialValue: FilesModel(runtime: runtime))
    }

    var body: some View {
        ObservatoryPage(
            SidebarSection.files.title,
            subtitle: FilesCopy.heroSubtitle.format(.resolved(), model.timeRange.displayName(UILanguage.current), model.totalCount)
        ) {
            if model.hasMore {
                Button {
                    Task { await model.loadMore() }
                } label: {
                    if model.isLoadingMore {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(FilesCopy.loadMore.text())
                    }
                }
                .controlSize(.small)
                .disabled(model.isLoadingMore)
            }
            Button {
                Task { await model.load() }
            } label: {
                Label(FilesCopy.reload.text(), systemImage: "arrow.clockwise")
            }
            .controlSize(.small)
        } content: {
            // #81：这一屏带着跳转条件 ⇒ 说出来。放在整条 if/else 链**之前**，
            // 因为「被筛到一条不剩」那一支（下面 `filteredOutPanel`）恰恰最需要这句话。
            EvidenceJumpChip(conditions: model.carriedJumpConditions) {
                await EvidenceJumpWiring.clear(fromShell: shell, into: model)
            }
            if model.isLoading && model.changes.isEmpty {
                loadingPanel
            } else if let message = model.errorMessage, model.changes.isEmpty {
                errorPanel(message)
            } else if model.changes.isEmpty {
                emptyPanel
            } else if model.visibleChanges.isEmpty {
                filteredOutPanel
            } else {
                metricPanel
                FilesFilterBar(model: model)
                // #54：有数据时挂在**列表之前**而不是三块之后——`splitPanel` 会吃掉剩余高度，
                // 挂在它后面等于挂在折叠线以下，那一格就永远要滚动才看得见。
                AttributionGapPanel(gap: model.attributionGap)
                splitPanel
            }
            // 同一格在**没有数据**的那几支也要出现（真机第一张图抓到的挂载缺陷：
            // 原来只挂在"有数据"那一支里，而本机这一轮采集面是 0 个根 ⇒ 整页走空态，
            // 于是最需要"为什么没有归属"这句话的那一屏，一个字都没说）。
            // 加载态不画：那一屏已经在说"正在读取"，同一件事不必同时给两句。
            if !showsListContent, !(model.isLoading && model.changes.isEmpty) {
                AttributionGapPanel(gap: model.attributionGap)
            }
        }
        .task(id: shell?.timeRange) {
            if let shell, model.timeRange != shell.timeRange {
                model.timeRange = shell.timeRange
            }
            // #74 ①：侧栏那个词在第一次取数之前落进 `query.searchText` ⇒ 首屏那次
            // `fileChanges(matching:)` 就是按路径筛过的（`load()` 里还顺带取引擎实况，
            // 先播种再拉，等于不为此多一次往返）。
            SidebarSearchWiring.seed(fromShell: shell, into: model)
            // #81 ①：跳转条件（项目 / 会话 / 事件种类）在第一次 `fileChanges(matching:)`
            // 之前落进同一条 `FileChangeQuery` ⇒ 首屏那次查询就是筛过的。
            EvidenceJumpWiring.seed(fromShell: shell, into: model)
            await model.load()
            await model.observeUpdates()
        }
        // #74 ②：侧栏改词 ⇒ 防抖后下推进 `FileChangeQuery.searchText`，走 Store 真查询。
        .task(id: shell?.searchText) {
            await SidebarSearchWiring.push(fromShell: shell, into: model)
        }
        // #81 ②：已经停在本页时又来了一条跳转意图 ⇒ 落条件并走真查询（相等不重查）。
        .task(id: shell?.pendingJump) {
            await EvidenceJumpWiring.push(fromShell: shell, into: model)
        }
        // #74 ③：本页过滤条改词 / 「重置」清词 ⇒ 侧栏显示同一个词。
        .onChange(of: model.query.searchText) { _, term in
            SidebarSearchWiring.pull(queryTerm: term, into: shell)
        }
        .refreshable { await model.load() }
    }

    /// 上面那条 `if / else if` 链的最后一支（列表那一屏）到底有没有渲染。
    /// 拿它当补集，是为了让「归属缺口」那一格**一屏只出现一次**：
    /// 有数据时挂在列表之前（折叠线之上），没有数据时挂在空态之后。
    /// 这个判断必须与那条链的最后一个 `else` 等价——`errorMessage` 只在 `changes` 为空时
    /// 接管那一屏，所以这里不必再判它。
    private var showsListContent: Bool {
        !model.isLoading && !model.changes.isEmpty && !model.visibleChanges.isEmpty
    }

    // MARK: - 指标区（本页唯一的 .hero 在这里）

    /// 四个读数填满一行（`columns: 4`），多出来的降级成 `InlineStat` 排在下面。
    ///
    /// **hero 给「变更文件总数」的理由**：本页是一张「哪些文件被 AI 动过」的清单，
    /// 决定用户要不要继续往下查某一条 diff 的，正是变更总数；新建 / 删除 / 已加载都是背景，
    /// 给它们 22pt，把 40pt 留给总数，主次就落在语义上。
    private var metricPanel: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.md) {
                MetricGrid(tiles, columns: Sizing.metricColumns) { tile in
                    StatTile(
                        title: tile.title,
                        value: tile.value,
                        caption: tile.caption,
                        emphasis: tile.emphasis
                    )
                }

                Hairline()

                HStack(spacing: Spacing.xl) {
                    InlineStat(FilesCopy.kindModified.text(), value: "\(model.distinctFileCount(for: .modified))")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    InlineStat(FilesCopy.linesAddedTotal.text(), value: "\(model.loadedLineTotals.added)", emphasized: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    InlineStat(FilesCopy.linesRemovedTotal.text(), value: "\(model.loadedLineTotals.removed)", emphasized: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                // 三个分类型读数与 hero 那个总数**不是一个口径**，必须写明白关系：
                // 真机截图上 hero 是 49，而 新建 9 + 删除 32 + 修改 5 = 46，副标题又写「共 78 个变更」。
                // 差额有两个方向相反的来源，两句都得说，否则这一格还是在骗人：
                // ① 这里只列三类，重命名没有自己的格 ⇒ 相加偏小；
                // ② 同一文件可以既被新建又被修改，按类型各数一次 ⇒ 相加偏大。
                Text(FilesCopy.dedupeNotice.text())
                    .axCaptionStyle()   // #99：这句承载口径，曾在最低档（≈1.8:1）
                    .fixedSize(horizontal: false, vertical: true)

                // 有记录时这句也要常驻：盲区跟「这一页有没有行」无关。
                // 只显示 3 条变更而不说采集面覆盖到哪，用户读到的就是「这个 Agent 只动了 3 个文件」。
                Text(model.captureScope.coverageLine())
                    .font(.axMeta)
                    .foregroundStyle(Surface.secondaryLabel)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// 已加载变更里按路径去重后的**文件**数——hero 大数的口径。
    /// 只在 `tiles` 里算一次；`changes` 是分页加载的有界集合，不是全表扫描。
    private var distinctFileCount: Int {
        Set(model.changes.map(\.path)).count
    }

    private var tiles: [FileTile] {
        [
            FileTile(
                id: 0,
                // **口径**：`totalCount` 是服务端匹配的**变更事件**条数，同一个文件被改三次
                // 就是三条，直接把它写在「变更文件总数」下面就是拿事件数冒充文件数
                // （Dashboard 的「今日新建会话」踩过同一类：大数与说明口径互相矛盾，
                // 用户以为观测器坏了）。这里按 path 去重，并把两个数都摊开写进 caption。
                title: FilesCopy.tileTotalTitle.text(),
                value: "\(distinctFileCount)",
                caption: FilesCopy.tileTotalCaption.format(.resolved(), model.changes.count, ReadoutCopy.serverTotalCaption),
                emphasis: .hero
            ),
            FileTile(
                id: 1,
                title: FilesCopy.tileCreatedTitle.text(),
                value: "\(model.distinctFileCount(for: .created))",
                caption: FilesCopy.tileCreatedCaption.text(),
                emphasis: .metric
            ),
            FileTile(
                id: 2,
                title: FilesCopy.tileDeletedTitle.text(),
                value: "\(model.distinctFileCount(for: .deleted))",
                caption: FilesCopy.tileDeletedCaption.text(),
                emphasis: .metric
            ),
            FileTile(
                id: 3,
                title: FilesCopy.tileSensitiveTitle.text(),
                value: "\(model.changes.filter { PathHeuristics.isSensitive($0.path) }.count)",
                caption: FilesCopy.tileSensitiveCaption.text(),
                emphasis: .metric
            ),
        ]
    }

    // MARK: - 主从区

    /// 列表列定宽收口（不再按窗口比例算宽度），整块给确定高度带：
    /// 左列表与右侧 diff 各自内部滚动，页面滚动条不会因为某条 diff 长就抖。
    private var splitPanel: some View {
        Panel(padding: Spacing.sm) {
            HStack(alignment: .top, spacing: Spacing.md) {
                changeList
                    .frame(minWidth: 300, idealWidth: 400, maxWidth: 460)

                Hairline(vertical: true)

                DiffView(model: model)
                    .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(minHeight: FilesSplitBand.minHeight, maxHeight: FilesSplitBand.maxHeight)
        }
    }

    // MARK: - 左：变更列表

    /// 内嵌列表用 `Surface.recessed` 下沉一级（旧版是 `.primary.opacity(0.03)` 自造灰）。
    private var changeList: some View {
        List {
            ForEach(model.visibleChanges) { change in
                FileChangeRow(
                    change: change,
                    isSelected: model.selected?.id == change.id
                ) {
                    Task { await model.select(change) }
                }
                .listRowInsets(EdgeInsets(
                    top: 0,
                    leading: Spacing.sm,
                    bottom: 0,
                    trailing: Spacing.sm
                ))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

            if model.isLoadingMore {
                HStack(spacing: Spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(FilesCopy.loadingMore.text())
                        .axCaptionStyle()   // #99：口径句提档（原 .axMeta + tertiary）
                }
                .listRowInsets(EdgeInsets(
                    top: Spacing.xs,
                    leading: Spacing.sm,
                    bottom: Spacing.xs,
                    trailing: Spacing.sm
                ))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(Surface.recessed)
    }

    // MARK: - 加载 / 空 / 被筛空 / 错误

    private var loadingPanel: some View {
        Panel {
            HStack(spacing: Spacing.md) {
                ProgressView().controlSize(.regular)
                VStack(alignment: .leading, spacing: Spacing.xs) {
                    Text(FilesCopy.loadingInitial.text())
                        .font(.axBody)
                        .foregroundStyle(Surface.label)
                    Text(FilesCopy.loadingHint.text())
                        .font(.axMeta)
                        .foregroundStyle(Surface.secondaryLabel)
                }
                Spacer(minLength: Spacing.none)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 200)
        }
    }

    /// 空态。⚠️ 文案出自 `model.captureAvailability`，不在这里组织——
    /// 「这一页没有记录」有两种相反的含义（引擎没在采集 / 在采集但覆盖不到），
    /// 而原来这一格只说「还没有文件变更 · 引擎捕获到…后会在这里列出」，
    /// 把「我看不到」说成了「没有」。
    private var emptyPanel: some View {
        let availability = model.captureAvailability ?? .nothingInScope(model.captureScope)
        return Panel {
            EmptyStateView(
                availability.headline(),
                systemImage: "doc.on.doc",
                message: availability.explanation(),
                fills: false
            ) {
                Button {
                    Task { await shell?.rescan() }
                } label: {
                    Label(FilesCopy.rescanNow.text(), systemImage: "arrow.clockwaves")
                }
            }
        }
    }

    private var filteredOutPanel: some View {
        Panel {
            EmptyStateView(
                FilesCopy.noSensitiveTitle.text(),
                systemImage: "lock.doc",
                message: FilesCopy.noSensitiveMessage.text(),
                fills: false
            ) {
                Button(FilesCopy.closeSensitiveFilter.text()) { model.setSensitiveOnly(false) }
            }
        }
    }

    private func errorPanel(_ message: String) -> some View {
        Panel {
            SectionHeader(FilesCopy.loadFailedHeader.text(), subtitle: message) {
                Button(FilesCopy.retry.text()) {
                    Task { await model.load() }
                }
                .controlSize(.small)
            }
        }
    }
}

// MARK: - 指标区的一格

/// 指标区的一格。`MetricGrid` 要 `Identifiable` 的数据，所以把四个读数收成值类型，
/// 布局与取数就此分开——谁该大谁该小在数据里就写死。
private struct FileTile: Identifiable {
    let id: Int
    let title: String
    let value: String
    let caption: String?
    let emphasis: StatTile.Emphasis
}

// MARK: - Previews

#Preview("文件与 Diff") {
    ObservatoryPreview.screen { runtime in
        FilesView(runtime: runtime)
    }
}

#Preview("空状态") {
    ObservatoryPreview.screen(empty: true) { runtime in
        FilesView(runtime: runtime)
    }
}
