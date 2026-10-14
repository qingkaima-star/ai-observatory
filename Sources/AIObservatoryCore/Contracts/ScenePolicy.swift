//
//  ScenePolicy.swift
//  AIObservatoryCore
//
//  Owner: WS-Honesty（ADR-0006）
//  ─────────────────────────────────────────────────────────
//  「本次启动到底声不声明菜单栏」的判据。放 Core 而不是 App：
//  App 用它选 Scene，UI 用它派生文案，两边必须是同一条规则——
//  本仓库主导的缺陷类就是「两处各写一份判据然后走偏」。
//

import Foundation

/// 菜单栏 Scene 的启动判据。
public enum MenuBarScenePolicy {

    /// 本次启动是否声明 `MenuBarExtra`。
    ///
    /// 为什么需要这么一个小东西：SwiftUI 的 `Scene` 在进程启动时构建一次，
    /// `@SceneBuilder` **没有** `buildIf` / `buildEither`（实测 Swift 6.3.3 / SDK 26.5：
    /// 运行时 `if` 报 `closure containing control flow statement cannot be used with
    /// result builder 'SceneBuilder'`，裸 `if` 甚至报 `failed to produce diagnostic`），
    /// 所以只能按启动值挑一套具体 Scene 类型，见 ADR-0006。
    ///
    /// 三条取值优先级是**行为约定**，不是实现细节：
    ///   1. 落盘值存在 ⇒ 以它为准（用户拨过的开关必须赢，否则开关还是在骗人）；
    ///   2. 落盘值不存在（内存库 / 文件缺失 / JSON 损坏）⇒ 退回宿主基线，
    ///      **绝不因为读盘失败就静默藏掉一个用户可见的功能**；
    ///   3. 基线由宿主给（打包壳给 `true`，预览/测试可给 `false`）。
    /// - Parameters:
    ///   - persistedValue: 已落盘的 `enableMenuBarExtra`；`nil` 表示读不到。
    ///   - fallbackValue: 宿主基线里的 `enableMenuBarExtra`。
    /// - Returns: 本次启动是否声明菜单栏 Scene。
    public static func declaresMenuBar(persistedValue: Bool?, fallbackValue: Bool) -> Bool {
        persistedValue ?? fallbackValue
    }
}
