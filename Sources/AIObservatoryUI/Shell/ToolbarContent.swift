//
//  ToolbarContent.swift
//  AIObservatoryUI
//
//  Owner: WS-UI
//  ─────────────────────────────────────────────────────────
//  全局工具栏：时间范围、采集启停、立即重新扫描、引擎状态。
//  以 View 扩展形式提供，内部用一个 @MainActor 宿主视图读取 ShellModel，
//  避免 ToolbarContent 直接持有 @MainActor 隔离类型。
//

import SwiftUI
import AIObservatoryCore

extension View {

    /// 挂载全局工具栏（时间范围 / 启停 / 重新扫描）。
    func observatoryToolbar(shell: ShellModel) -> some View {
        toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ObservatoryToolbarHost(shell: shell)
            }
        }
    }
}

/// 工具栏内容宿主。
@MainActor
struct ObservatoryToolbarHost: View {
    private let shell: ShellModel

    init(shell: ShellModel) {
        self.shell = shell
    }

    var body: some View {
        timeRangeMenu
        Divider()
            .frame(height: 18)
        engineControl
        rescanButton
    }

    private var timeRangeMenu: some View {
        let language = UILanguage.current
        return Menu {
            Picker(ShellCopy.timeRange.text(language), selection: Bindable(shell).timeRange) {
                ForEach(ObservatoryTimeRange.allCases) { range in
                    Label(range.displayName(UILanguage.current), systemImage: range.symbol).tag(range)
                }
            }
        } label: {
            Label(shell.timeRange.displayName(UILanguage.current), systemImage: "calendar")
                .labelStyle(.titleAndIcon)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(ShellCopy.globalTimeRange.text(language))
    }

    private var engineControl: some View {
        let language = UILanguage.current
        return Button {
            Task { await shell.toggleEngine() }
        } label: {
            Label(
                shell.isCollecting ? ShellCopy.pauseCapture.text(language)
                                   : ShellCopy.startCapture.text(language),
                systemImage: shell.isCollecting ? "pause.circle" : "play.circle"
            )
        }
        .help(shell.isCollecting ? ShellCopy.pauseEngine.text(language)
                                 : ShellCopy.startEngine.text(language))
    }

    private var rescanButton: some View {
        Button {
            Task { await shell.rescan() }
        } label: {
            if shell.isRescanning {
                ProgressView().controlSize(.small)
            } else {
                Label(ShellCopy.rescan.text(UILanguage.current), systemImage: "arrow.clockwise")
            }
        }
        .disabled(shell.isRescanning)
        // ⇧⌘R 的唯一 owner 是「观测」菜单里那条（`AIObservatoryApp.swift:192`）。
        // 这里原来也挂了一遍同一个键：一个 keyEquivalent 两个 owner，谁生效取决于
        // 第一响应者，且「立即重新扫描」在菜单里出现两次（一次带快照重拉、一次不带）。
        // App 侧是冻结区 ⇒ 本车道只摘掉自己这一遍，tooltip 继续写这个键（它仍然是对的），
        // 并把两条路径的差别交回总控：见交付块与 ICR-0005。
        .help(ShellCopy.rescanTooltip.text(UILanguage.current))
    }
}
