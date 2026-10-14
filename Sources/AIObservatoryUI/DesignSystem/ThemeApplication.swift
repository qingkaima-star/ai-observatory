//
//  ThemeApplication.swift
//  AIObservatoryUI — DesignSystem
//
//  Owner: master-controller（§3 冻结区：DesignSystem/** 由总控持有）
//  ─────────────────────────────────────────────────────────
//  `AppTheme` → SwiftUI `ColorScheme?` 的**唯一权威映射**。
//
//  为什么要有这个文件（ADR-0006「设置项必须有真实消费者」）：
//  2026-09-20 实测发现「外观 / 主题」这个设置**只对设置页自己生效**——
//  `SettingsView.swift:107` 把 `.preferredColorScheme(model.preferredColorScheme)` 挂在设置页
//  自己的视图上，而 `Sources/AIObservatoryApp/` 里 `theme` / `ColorScheme` **零引用**。
//  于是用户拨「深色」，除了设置页，全 App 外观不变。像素亮度实测：
//    theme=dark + section=settings → 0.167（深色）
//    theme=dark + section=timeline → 0.973（浅色）
//    theme=dark + section=dashboard 连跑 3 次 → 0.954 / 0.958 / 0.958（全浅色）
//
//  映射放在 UI 层而不是 Core：`ColorScheme` 是 SwiftUI 类型，而 `AIObservatoryCore` 刻意
//  不依赖 SwiftUI（契约层必须 UI-free）。放在这里，App 层与设置页共用同一份，
//  避免出现第二个映射口径——本仓反复出事的正是「同一件事有两个口径」。
//

import SwiftUI
import AIObservatoryCore

extension AppTheme {

    /// 该主题对应的 SwiftUI 配色方案。
    ///
    /// `system` 交回系统（`nil`），**不是**"当浅色"：把"跟随系统"悄悄当成浅色，
    /// 就等于替用户做了一个他没做的选择，而且系统切深色时界面不会跟。
    public var preferredColorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light:  return .light
        case .dark:   return .dark
        }
    }
}
