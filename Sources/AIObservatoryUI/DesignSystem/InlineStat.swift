//
//  InlineStat.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  两个轻量展示组件：InlineStat（「标签 …… 值」一行字段）与 FilePathText（路径省略策略）。
//  用于详情面板、列表行尾与菜单栏窗口。
//
//  字段行不上色：旧版 `tint` 会把「命令执行 96」染成紫色，颜色在这里不携带信息，
//  只会让一屏详情读起来像彩虹。需要表达状态的那一类（风险 / 成败）请用 `Tag`。
//

import SwiftUI

struct InlineStat: View {
    private let label: String
    private let value: String
    private let isEmphasized: Bool

    /// - Parameter isEmphasized: 详情面板里的主字段用 `true`（值取 13pt 半粗），其余默认。
    init(_ label: String, value: String, emphasized: Bool = false) {
        self.label = label
        self.value = value
        self.isEmphasized = emphasized
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.sm) {
            Text(label)
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
                .lineLimit(1)
            Spacer(minLength: Spacing.md)
            Text(value)
                .font(isEmphasized
                        ? .system(size: 13, weight: .semibold).monospacedDigit()
                        : .axMeta.monospacedDigit())
                .foregroundStyle(isEmphasized ? Surface.label : Surface.secondaryLabel)
                .lineLimit(1)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: Sizing.rowMinHeight - 8)
        .accessibilityElement(children: .combine)
    }
}

#Preview("InlineStat") {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        InlineStat("会话数", value: "12")
        InlineStat("文件修改", value: "348")
        InlineStat("命令执行", value: "96")
        InlineStat("高危事件", value: "3")
        InlineStat("主字段", value: "12h47m", emphasized: true)
        InlineStat("无数据", value: "—")
    }
    .padding(Spacing.md)
    .frame(width: 300)
    .background(Surface.panel)
}

// MARK: - FilePathText

/// 路径展示：中段省略 / 仅文件名 / 末两级目录三种模式，等宽可选中，tooltip 保留完整路径。
struct FilePathText: View {
    /// 路径截断策略。
    enum Mode {
        case middleEllipsis
        case fileNameOnly
        case lastTwoComponents
    }

    private let path: String
    private let mode: Mode
    /// 覆盖**显示串**（`path` 仍然是完整路径，`.help` 与无障碍读数不变）。
    /// 给「需要按同组上下文才能区分」的调用方用，见 `ProjectPathLabels`。
    private let label: String?

    /// #61 演示/脉敏输出。默认 `.off` = 恒等映射 ⇒ 装配点没注入时这一屏与今天逐字一致。
    @Environment(\.demoRedaction) private var demoRedaction

    init(path: String, label: String? = nil, mode: Mode = .middleEllipsis) {
        self.path = path
        self.label = label
        self.mode = mode
    }

    /// 给人读的那一份：**先脱敏，再按模式截断**。
    /// 顺序不能反——先截断再脱敏会把 `~` 当成普通目录名吃掉，
    /// 而先脱敏再截断时，`fileNameOnly` / `lastTwoComponents` 看到的仍是"真实的最后几段"。
    private var masked: String { demoRedaction.apply(to: path) }

    var body: some View {
        Text(displayed)
            .font(.axMetaMono)
            .foregroundStyle(Surface.label)
            .textSelection(.enabled)
            .lineLimit(1)
            .truncationMode(mode == .middleEllipsis ? .middle : .tail)
            // 这两处原来直接吃 `path`：开着脱敏时 tooltip 与 VoiceOver 会把家目录原样念出来
            // ——像素里查不到（`make-public-release.sh` 自检④ 那句"grep 0 命中、人眼一眼看见"同源）。
            .help(masked)
            .accessibilityLabel(masked)
    }

    private var displayed: String {
        // #64：`label` 原来**原样返回**，等于给调用方留了一条绕过映射的后门——
        // `ProjectCard` 传的正是 `ProjectPathLabels` 按冲突深度算出来的标签，
        // 冲突足够多时那个标签会长成完整路径。所以标签也要过一遍映射，
        // 而且走 `scrub`（标签是"路径片段拼出来的串"，不保证整串以某个根开头）。
        if let label { return demoRedaction.scrub(label) }
        // #89 ①：三种模式**全部**交给 `Mask.tail`。原来这里自己 `split("/").suffix(2)`，
        // 而 `apply` 已经把前缀换成了 `~` ⇒ 切末两级干的第一件事就是把 `~` 扔掉，
        // 于是开着开关仍把 `Documents/mona` 铺在屏上（看起来像相对路径，其实是被遮住的根的子孙）。
        // 顺序仍是"先脱敏、再截断"，只是截断这一步现在认得占位符。
        switch mode {
        case .middleEllipsis:
            return masked
        case .fileNameOnly:
            return demoRedaction.tail(path, components: 1)
        case .lastTwoComponents:
            return demoRedaction.tail(path, components: 2)
        }
    }
}

#Preview("FilePathText 模式") {
    VStack(alignment: .leading, spacing: Spacing.sm) {
        FilePathText(path: "/Users/demo/Projects/AiX/Sources/AIObservatoryCore/Contracts/DomainModels.swift")
        FilePathText(path: "/Users/demo/Projects/AiX/Sources/AIObservatoryCore/Contracts/DomainModels.swift",
                     mode: .fileNameOnly)
        FilePathText(path: "/Users/demo/Projects/AiX/Sources/AIObservatoryCore/Contracts/DomainModels.swift",
                     mode: .lastTwoComponents)
    }
    .padding(Spacing.md)
    .frame(width: 320, alignment: .leading)
}
