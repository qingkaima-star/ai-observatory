//
//  AppThemeColorSchemeTests.swift
//  AIObservatoryUITests
//
//  Owner: master-controller
//
//  守的是 ADR-0006 那一类缺陷：**设置项必须有真实消费者**。
//  2026-09-20 实测：「外观 / 主题」曾经只对设置页自己生效——宿主（App 层）没读 `settings.theme`，
//  而设置页的文案却写着「应用到全局由宿主读取 settings.theme 完成」。
//  现在 App 层的场景根与设置页共用同一份映射（`AppTheme.preferredColorScheme`），
//  本套件钉住这份映射本身，尤其是「跟随系统 ≠ 当浅色」这一条。
//

import Foundation
import Testing
import SwiftUI
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI：主题 → 配色方案映射", .timeLimit(.minutes(1)))
struct AppThemeColorSchemeTests {

    /// `system` 必须交回系统（`nil`）。
    ///
    /// 这条是承重的：把「跟随系统」实现成 `.light` 会让界面在**系统切深色时一动不动**，
    /// 而且用户从没做过「我要浅色」这个选择——那是替用户决定。
    @Test("跟随系统 ⇒ nil（不是浅色）")
    func systemMapsToNil() {
        #expect(AppTheme.system.preferredColorScheme == nil,
                "system 被映射成了具体配色 ⇒ 系统切换深浅色时界面不会跟")
    }

    @Test("浅色 / 深色各自映射到自身")
    func explicitThemesMapToThemselves() {
        #expect(AppTheme.light.preferredColorScheme == .light)
        #expect(AppTheme.dark.preferredColorScheme == .dark)
    }

    /// 三种取值的映射必须**互不相同**（`system` 的 nil 也是其中一个不同值）。
    ///
    /// 若两个取值映射到同一结果，界面上就有一个选项是死的——用户拨它什么都不会发生。
    @Test("三个取值映射互不相同（没有死选项）")
    func mappingIsInjective() {
        let mapped = AppTheme.allCases.map { $0.preferredColorScheme }
        #expect(Set(mapped.map { String(describing: $0) }).count == AppTheme.allCases.count,
                "有两个 AppTheme 取值映射到同一个配色方案 ⇒ 其中一个是死选项：\(mapped)")
    }
}
