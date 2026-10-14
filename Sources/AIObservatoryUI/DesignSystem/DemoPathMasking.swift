//
//  DemoPathMasking.swift
//  AIObservatoryUI / DesignSystem
//
//  Owner: WS-l10n（#61 演示/脉敏输出 · 渲染层）· #64 收口
//  ─────────────────────────────────────────────────────────
//  这里**只剩注入通道**。映射本体（`PathPrivacy.Mask`）与"哪一段算路径"的判定
//  （`PathPrivacy`）都在 `AIObservatoryCore/Privacy/PathPrivacy.swift`——
//  因为 #64 要求导出件（`AIObservatoryExport`）与通知正文（`AIObservatoryPlatform`）
//  用同一份口径，而它们只共同依赖 Core。留两份映射就是 #64 的成因本身。
//
//  ⚠️ 三条铁口径随类型一起搬走了，这里复述一遍（改这个文件前先读）：
//  1. **只在渲染层，绝不在落库前**——库里必须仍是原始绝对路径（#41 写入时冻结）。
//  2. **默认关**：`off` 必须是恒等映射，一个字都不改。
//  3. **不删结构**：占位符只替换前缀，余下的段数、分隔符、文件名全部保留。
//
//  为什么走 `EnvironmentValues` 而不是一个全局 `static var`：
//  AGENTS.md §5 禁止单例隐式依赖；环境值是 SwiftUI 的正门，装配点（Shell）一行注入。
//  默认值 `.off` ⇒ 注入点没接之前行为与今天逐字一致。
//

import SwiftUI
import Foundation
import AIObservatoryCore

// MARK: - 注入通道

extension EnvironmentValues {
    /// 当前生效的脱敏映射。默认 `.off` ⇒ 装配点没注入时，渲染结果与今天逐字一致。
    var demoRedaction: PathPrivacy.Mask {
        get { self[DemoRedactionKey.self] }
        set { self[DemoRedactionKey.self] = newValue }
    }
}

private struct DemoRedactionKey: EnvironmentKey {
    static let defaultValue = PathPrivacy.Mask.off
}
