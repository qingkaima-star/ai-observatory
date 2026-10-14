//
//  MenuBarScenePolicyTests.swift
//  AIObservatoryCoreTests
//
//  Owner: WS-Honesty（ADR-0006 #14）
//  ─────────────────────────────────────────────────────────
//  钉「本次启动到底声不声明菜单栏」这条判据。
//  这个函数决定用户拨的开关是真被读了、还是又一个应答而不应效的控件，
//  所以四个格子逐个钉字面量——不写「与输入相等」这种恒真断言。
//

import Foundation
import Testing
import AIObservatoryCore

@Suite("Core: 菜单栏 Scene 的启动判据（ADR-0006）")
struct MenuBarScenePolicyTests {

    @Test("落盘 false 必须赢过基线 true：否则开关还是在骗人")
    func persistedFalseBeatsBaselineTrue() {
        #expect(MenuBarScenePolicy.declaresMenuBar(persistedValue: false, fallbackValue: true) == false)
    }

    @Test("落盘 true 必须赢过基线 false：宿主改了默认值也不得覆盖用户已保存的开关")
    func persistedTrueBeatsBaselineFalse() {
        #expect(MenuBarScenePolicy.declaresMenuBar(persistedValue: true, fallbackValue: false) == true)
    }

    @Test("读不到落盘值时退基线 true：读盘失败绝不能静默藏掉一个用户可见功能")
    func absentFallsBackToBaselineTrue() {
        #expect(MenuBarScenePolicy.declaresMenuBar(persistedValue: nil, fallbackValue: true) == true)
    }

    @Test("读不到落盘值且宿主基线为 false 时不声明：基线由宿主说了算")
    func absentFallsBackToBaselineFalse() {
        #expect(MenuBarScenePolicy.declaresMenuBar(persistedValue: nil, fallbackValue: false) == false)
    }
}
