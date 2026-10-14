//
//  ObservatoryRootView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI
//  ─────────────────────────────────────────────────────────
//  应用主界面外壳：NavigationSplitView + 9 板块侧边栏 + 全局工具栏。
//
//  侧边栏从「两行一条目」收成「单行一条目」：旧版每个条目下面挂一句中文说明，
//  9 个条目就是 9 行噪声，而且整栏的高度预算被吃掉一半。说明改由 tooltip 承载。
//  栏底引擎状态从 `.ultraThinMaterial` 换成 `Hairline` + 页面底色（材质是灰泥感的来源）。
//
//  【冻结签名】App 目标通过下面这个入口挂载 UI，WS-UI 必须保留：
//      public init(runtime: ObservatoryRuntime)
//  下面那个 `selfProcessSource` 带默认值 `nil`，所以旧调用点一行都不用改就能编过
//  （#29 / ICR-0003：装配本进程仪器时才需要传）。
//

import SwiftUI
import AIObservatoryCore

/// observatory 主界面根视图。
public struct ObservatoryRootView: View {
    private let runtime: ObservatoryRuntime
    /// 本进程开销的读数来源（判据④）。`nil` = 宿主未装配，性能页那一格会如实写明。
    private let selfProcessSource: (any SelfProcessReadingSource)?
    @State private var shell: ShellModel

    /// `shell` 由宿主注入时用它——⌘1–⌘8 现在归 App 的 `CommandGroup(after: .sidebar)`，
    /// 而菜单与侧栏必须驱动**同一个** `ShellModel`，否则会出现"菜单切了页、侧栏高亮没动"。
    /// 传 `nil` 时自建一份（`#Preview` 与旧的 `public init(runtime:)` 调用点因此一行都不用改）。
    public init(
        runtime: ObservatoryRuntime,
        selfProcessSource: (any SelfProcessReadingSource)? = nil,
        shell: ShellModel? = nil
    ) {
        self.runtime = runtime
        self.selfProcessSource = selfProcessSource
        _shell = State(initialValue: shell ?? ShellModel(runtime: runtime))
    }

    public var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                // 2026-09-23 真机截图改的：这里原先是 `min: 856`，而会话页的详情还挂着一列
                // `.inspector(min: 300)`，侧栏 216 ⇒ 三栏**硬下限合计 1372**。窗口比它窄时
                // SwiftUI 不让详情列低于 min，于是把侧栏挤到 216 以下（分区标题被裁出左边界）、
                // 同时把检查器推出右边界——两个症状同一个根因（1280 宽的窗口实测）。
                // 560 是按「声明的 minWidth 1080 − 侧栏 216 − 检查器 min 300 = 564」取的：
                // 在**声明的最小窗口**里三栏也放得下，检查器开着不再裁任何一栏。
                .navigationSplitViewColumnWidth(min: 560, ideal: 720)
        }
        .navigationSplitViewStyle(.balanced)
        .environment(shell)
        // #61：演示/脉敏输出的唯一注入点。读的是 `runtime.settings`——生产宿主里它就是
        // `ObservatoryLaunch` 按「落盘值 → 基线」解析出来的那份启动设置，所以这一句
        // 与设置页 caveat 说的「重启后生效」是同一件事，不是两处各说各话。
        .environment(\.demoRedaction, PathPrivacy.Mask.configured(from: runtime.settings))
        .task { await shell.start() }
        .observatoryToolbar(shell: shell)
        .searchable(text: $shell.searchText, placement: .sidebar,
                    prompt: ShellCopy.searchPrompt.text(UILanguage.current))
    }

    // MARK: 侧边栏

    private var sidebar: some View {
        List(selection: $shell.selection) {
            ForEach(SidebarGroup.allCases) { group in
                Section(group.title) {
                    ForEach(group.sections) { section in
                        sidebarRow(section)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: Spacing.none) { sidebarFooter }
        // 只给 ideal 不给 min 的话，详情列顶到硬下限时 SwiftUI 会**先挤侧栏**：
        // 分区标题（「总览」「行为取证」…）被裁出窗口左边界，行还在、字没了（1280 宽实测）。
        // 侧栏是导航的唯一入口，它不许成为三栏争宽度时的让步方。
        .navigationSplitViewColumnWidth(min: Sizing.sidebarWidth, ideal: Sizing.sidebarWidth)
    }

    /// 侧栏一行。
    ///
    /// 为什么是 `Button` 而不是裸 `Label`：⌘数字要落在一个**有 action 的控件**上才生效
    /// （`View.keyboardShortcut` 挂在没有 action 的视图上是静默失效的，编译零警告）。
    /// `List(selection:)` 的选中高亮不受影响——按钮的 action 写的就是 `shell.selection`，
    /// 而它正是这个 List 的 selection 绑定；点击落到按钮还是落到行都由同一条路径决定选中。
    @ViewBuilder
    private func sidebarRow(_ section: SidebarSection) -> some View {
        let row = Button {
            shell.select(section)
        } label: {
            Label(section.title, systemImage: section.symbol)
        }
        // #11 点名豁免（判据用例 `InteractionFeedbackTests` 里那份名单就这一条）：
        // 侧栏行的悬停/选中底由 `List(selection:)` 自己画，再叠一层自绘底就是同一次悬停两处反馈，
        // 而且会盖掉系统那一档的"这一行是当前板块"语义。它已经是真 `Button`，
        // 焦点环 / 手型光标 / Return 触发三样都在，缺的只是这一族独有的悬停底色。
        .buttonStyle(.plain)
        .font(.axBody)
        .tag(section)
        .help(section.subtitle + section.shortcutHint)

        // 键位表在 `SidebarSection.navigationKey` 一处；`.settings` 是 nil ⇒ 不给键，
        // 设置走 macOS 标准的 ⌘,。
        //
        // 2026-09-21：绑定从**这里**搬到 App 的 `CommandGroup(after: .sidebar)`——
        // 视图级 `keyboardShortcut` 有一条改不掉的性质：它不出现在菜单栏里，
        // 用户只能靠 tooltip 猜（ICR-0005）。搬走的代价是"焦点不在侧栏时是否仍生效"，
        // 菜单项属于主菜单 ⇒ 全窗口有效，反而更对。
        row
    }

    private var sidebarFooter: some View {
        VStack(spacing: Spacing.none) {
            Hairline()
            HStack(spacing: Spacing.sm) {
                Circle()
                    .fill(shell.engineStateColor)
                    .frame(width: 6, height: 6)
                    .accessibilityHidden(true)
                Text(shell.engineStateReadout)
                    .font(.axMeta)
                    .foregroundStyle(Surface.label)
                Spacer(minLength: Spacing.sm)
                if let at = shell.lastUpdateAt {
                    Text(DateFormat.time(at))
                        .font(.axMeta)
                        .monospacedDigit()
                        .foregroundStyle(Surface.tertiaryLabel)
                        .help(shell.monitoringLabel)
                }
            }
            .padding(.horizontal, Spacing.md)
            .padding(.vertical, Spacing.sm)
        }
        .background(Surface.page)
    }

    // MARK: 详情（板块路由）

    @ViewBuilder
    private var detail: some View {
        switch shell.selection ?? .dashboard {
        case .dashboard:   DashboardView(runtime: runtime)
        case .sessions:    SessionsView(runtime: runtime)
        case .timeline:    TimelineView(runtime: runtime)
        case .commands:    CommandsView(runtime: runtime)
        case .files:       FilesView(runtime: runtime)
        case .performance: PerformanceView(runtime: runtime, selfProcessSource: selfProcessSource)
        case .security:    SecurityView(runtime: runtime)
        case .projects:    ProjectsView(runtime: runtime)
        case .settings:    SettingsView(runtime: runtime)
        }
    }
}

#Preview("主界面") {
    ObservatoryRootView(runtime: ObservatoryPreview.runtime())
}

#Preview("主界面 · 空状态") {
    ObservatoryRootView(runtime: ObservatoryPreview.emptyRuntime())
}
