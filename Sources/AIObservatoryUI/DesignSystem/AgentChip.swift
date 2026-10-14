//
//  AgentChip.swift
//  AIObservatoryUI
//
//  Owner: WS-UI（总控独占）
//  ─────────────────────────────────────────────────────────
//  Agent 身份标签：**图标 + 名字**，无底色、无描边、不上色。
//
//  旧版按 `AgentKind.rawValue` 的 FNV-1a 哈希从 10 色色板取色，再套一层 35% 描边胶囊。
//  哈希色不是「稳定语义」而是随机装饰——它不携带任何读者能解码的信息，
//  却在一屏里制造了十几个互不相干的色相。现在身份由名字与 SF Symbol 承担。
//
//  【#47-B · 04:47】`.unknown` 不再走"切首词"：Core 给的是 "Unknown Agent"，紧凑态切完
//  就是裸的 `Unknown`，风险列表与时间线那一列并排三个 `Unknown`，既不说谁也不说为什么。
//  现在这一格由 `AttributionCopy` 给标签（列内短标签 + tooltip 原因），
//  整句标签与原因同时上屏在三个详情面。措辞的三条硬判据写在 `AttributionCopy.swift` 文件头。
//
//  【#82 · 2026-09-22】取词从本文件搬进 `AgentNaming`，并且**删掉了"切首词"**：
//  紧凑态原先 `String(full.split(separator: " ").first …)`，于是同一列里
//  `Claude Code` 与 `Claude`、`OpenAI Codex CLI` 与 `OpenAI` 并排出现——
//  被切掉的第二个词恰恰是区别本身。现在两种形态取同一个产品名，
//  放不下由版面省略号截断并在 tooltip 给全名（截断可核对，改名不可）。
//  `displayName` 这个入参的含义也跟着收窄：**它是探测到的原始进程名，只进 tooltip，
//  永不进身份串**（签名保留，调用点不动）。
//
//  ⚠️ 本文件头原写「总控独占」，而 AGENTS.md §3 把整个 `Sources/AIObservatoryUI/` 划给 WS-UI。
//  这次改动只加 `.unknown` 分支、不动 `init` 签名、不动其它 kind 的渲染路径；
//  已在认领板上点名请总控确认这条所有权口径（见 #47-B 交付块）。
//

import SwiftUI
import AIObservatoryCore

struct AgentChip: View {
    private let kind: AgentKind
    /// 探测到的**原始进程名**（`claude` / `codex` / `cursor`）。
    /// #82 之后它只服务 tooltip，不参与"这一格显示什么名字"。
    private let displayName: String?
    private let compact: Bool

    init(kind: AgentKind, displayName: String? = nil, compact: Bool = false) {
        self.kind = kind
        self.displayName = displayName
        self.compact = compact
    }

    var body: some View {
        HStack(spacing: Spacing.xs) {
            Image(systemName: kind.sfSymbolName)
                .font(.axMeta)
                .foregroundStyle(Surface.secondaryLabel)
            Text(identityText)
                .font(.axMeta)
                .foregroundStyle(Surface.label)
                .lineLimit(1)
        }
        .accessibilityLabel(identityText)
        // 「未能归属」那一族记录的原因**必须能展开**（#47-B 判据②）。tooltip 只是补充：
        // 键盘与读屏用户展不开 hover，所以同一句原因也排在三个详情面上屏。
        // 已知 kind 的那一格，tooltip 改说"我们实际看到的进程名"（#82：它是唯一去处）。
        .help(AttributionCopy.isUnattributed(kind)
                ? AgentNaming.reasonText()
                : processNameTooltip)
    }

    /// 原始进程名那句 tooltip；没有（或与产品名同名）时给空串 = 不挂 tooltip。
    private var processNameTooltip: String {
        guard let processName = displayName, !processName.isEmpty,
              processName != AgentNaming.name(kind: kind) else { return "" }
        return AgentNaming.processNameTooltip(processName)
    }

    private var identityText: String {
        Self.displayedName(kind: kind, displayName: displayName, compact: compact)
    }

    /// 展示名，**纯函数**（视图自己没法在单元测试里渲染，判据①只能钉在这个函数上）。
    ///
    /// `.unknown` 必须在**任何截断之前**返回：`AgentKind.unknown.displayName` 是
    /// "Unknown Agent"，切完就是裸的 `Unknown` —— 一列里三个 `Unknown` 并排，
    /// 读的人既不知道是谁、也不知道为什么不知道（#47-B 判据①）。
    ///
    /// `displayName` 现在被**刻意忽略**（写成 `_ displayName` 让"这里不用它"长在签名上）：
    /// 它是原始进程名，进 tooltip 不进身份串（#82 口径①）。签名保持不变是因为
    /// 15 个调用点都按标签传它，而用例钉的也正是这条真实路径（判据①）。
    static func displayedName(kind: AgentKind, displayName _: String? = nil, compact: Bool) -> String {
        return AgentNaming.name(kind: kind, form: compact ? .compact : .full)
    }
}

#Preview("AgentChip") {
    HStack(spacing: Spacing.lg) {
        ForEach(AgentKind.allCases.prefix(5), id: \.self) { kind in
            AgentChip(kind: kind)
        }
    }
    .padding(Spacing.lg)
}
