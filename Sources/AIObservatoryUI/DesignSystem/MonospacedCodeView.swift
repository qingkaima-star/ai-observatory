//
//  MonospacedCodeView.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  等宽代码/命令展示：maxLines 截断 + 「… 共 N 行」提示 + 横向滚动不截断 + 可选复制按钮。
//
//  容器改用 `Panel.recessed`：旧版是 `Color.primary.opacity(0.05)` 填充 + 0.06 描边，
//  那是自造的一层「假语义色」，深色模式下会变成一块发灰的脏斑。
//

import SwiftUI
import AppKit

struct MonospacedCodeView: View {
    private let text: String
    private let maxLines: Int
    private let showsCopyButton: Bool

    /// #89 ①：这一格是**界面侧最大的未遮罩出口**——它吃的是整条命令行、整份设置草稿 JSON、
    /// 存储目录，而它自己一个字都不掩。七个调用点（命令详情、会话命令列表、安全详情/确认面板、
    /// 时间线详情、关于页草稿、存储页目录）全都指望着"组件里做过脱敏"，而此前并没有。
    /// 修在组件里而不是七个调用点各包一层，因为组件还带着**剪贴板**那条出口（见 `copy()`），
    /// 调用点包不住。
    @Environment(\.demoRedaction) private var demoRedaction

    @State private var didCopy = false

    init(_ text: String, maxLines: Int = 12, showsCopyButton: Bool = true) {
        self.text = text
        self.maxLines = maxLines
        self.showsCopyButton = showsCopyButton
    }

    var body: some View {
        let lines = scrubbed.components(separatedBy: .newlines)
        let visibleCount = min(lines.count, max(1, maxLines))
        let truncated = lines.count > visibleCount

        Panel.recessed(padding: Spacing.sm) {
            VStack(alignment: .leading, spacing: Spacing.xs) {
                HStack(alignment: .top, spacing: Spacing.sm) {
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(lines.prefix(visibleCount).joined(separator: "\n"))
                            .font(.axMono)
                            .foregroundStyle(Surface.label)
                            .fixedSize(horizontal: true, vertical: false)
                            .textSelection(.enabled)
                    }
                    Spacer(minLength: Spacing.none)
                    if showsCopyButton {
                        Button {
                            copy()
                        } label: {
                            Image(systemName: didCopy ? "checkmark.circle" : "doc.on.doc")
                                .foregroundStyle(didCopy ? ObservatoryColor.positive : Surface.tertiaryLabel)
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                        .help("复制到剪贴板")
                    }
                }
                if truncated {
                    Text("… 共 \(lines.count) 行，已显示前 \(visibleCount) 行")
                        .axCaptionStyle()   // #99：这句承载口径，曾在最低档（≈1.8:1）
                }
            }
        }
    }

    /// 屏上那一份与剪贴板那一份**必须是同一个字符串**：只在渲染时掩、复制出去是原文，
    /// 等于把最省事的一条外流通道留在原地（AI 上下文里出现的就是复制出去的那一份）。
    /// 换行是路径段的终止符 ⇒ 掩过之后行数与截断位置一个字都不变。
    private var scrubbed: String { demoRedaction.scrub(text) }

    private func copy() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(scrubbed, forType: .string)
        didCopy = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            didCopy = false
        }
    }
}

#Preview("MonospacedCodeView") {
    VStack(alignment: .leading, spacing: Spacing.lg) {
        MonospacedCodeView("swift build -c release --scratch-path .build")
        MonospacedCodeView("git commit -m \"feat: observatory shell\"\n" +
                           "  --author=\"Agent <agent@example.com>\"\n" +
                           (1...20).map { "echo line-\($0)   # 演示长输出的横向滚动与截断" }.joined(separator: "\n"),
                           maxLines: 4)
    }
    .padding(Spacing.lg)
    .frame(width: 480, alignment: .leading)
    .background(Surface.panel)
}
