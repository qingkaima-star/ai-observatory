//
//  ObservatoryLaunchTests.swift
//  AIObservatoryAppTests
//
//  Owner: WS-Honesty（ADR-0006 #14）
//  ─────────────────────────────────────────────────────────
//  守的是**接线**而不是规则：`MenuBarScenePolicy` 那条规则在 Core 里已经单独钉过，
//  但「App 有没有把落盘值喂给它」只有这里能抓。喂错成基线、或者干脆喂 `nil`，
//  规则自身依然自洽，而用户拨的开关会重新变成一个不应效的控件——正是本工作流要修的那个谎。
//
//  全部手算字面量，且 persisted / baseline 两份输入的每个字段都不同：
//  否则「整份设置取错了来源」这种错误看不出来。
//

import Foundation
import Testing
@testable import AIObservatoryApp
import AIObservatoryCore

/// 落盘的那一份：与基线逐字段不同。
private func persistedOnDisk(menuBar: Bool) -> ObservatorySettings {
    ObservatorySettings(
        monitoredRoots: ["/disk/root"],
        ignoredPathPatterns: ["/disk/ignored"],
        processScanIntervalSeconds: 11,
        retentionDays: 45,
        enableEndpointSecurity: true,
        enableMenuBarExtra: menuBar,
        enableRiskConfirmation: false,
        theme: .dark,
        launchAtLogin: true,
        storeDirectory: "/disk/store"
    )
}

/// 宿主基线：与落盘值逐字段不同。
private var hostBaseline: ObservatorySettings {
    ObservatorySettings(
        monitoredRoots: ["/host/root"],
        ignoredPathPatterns: ["/host/ignored"],
        processScanIntervalSeconds: 3,
        retentionDays: 30,
        enableEndpointSecurity: false,
        enableMenuBarExtra: true,
        enableRiskConfirmation: true,
        theme: .light,
        launchAtLogin: false,
        storeDirectory: "/host/store"
    )
}

@Suite("App: 启动装配按落盘值挑 Scene（ADR-0006）")
struct ObservatoryLaunchTests {

    @Test("用户存过关：本次启动就不声明菜单栏，且整份设置取落盘那份（与引擎一致）")
    func savedFalseHidesMenuBarAndPersistedWins() {
        let startup = ObservatoryLaunch.resolvedStartupSettings(
            persisted: persistedOnDisk(menuBar: false),
            baseline: hostBaseline
        )
        #expect(startup.enableMenuBarExtra == false)
        #expect(startup.retentionDays == 45)
        #expect(startup.theme == .dark)
        #expect(startup.storeDirectory == "/disk/store")
    }

    @Test("用户存过开：基线为关也要被落盘值覆盖")
    func savedTrueOverridesBaselineFalse() {
        var baseline = hostBaseline
        baseline.enableMenuBarExtra = false
        let startup = ObservatoryLaunch.resolvedStartupSettings(
            persisted: persistedOnDisk(menuBar: true),
            baseline: baseline
        )
        #expect(startup.enableMenuBarExtra == true)
    }

    @Test("读不到落盘值：用基线，菜单栏随基线为开")
    func missingFileFallsBackToBaseline() {
        let startup = ObservatoryLaunch.resolvedStartupSettings(
            persisted: nil,
            baseline: hostBaseline
        )
        #expect(startup.enableMenuBarExtra == true)
        #expect(startup.retentionDays == 30)
        #expect(startup.storeDirectory == "/host/store")
    }

    @Test("读不到落盘值且宿主基线为关：不声明（宿主说了算，而不是硬编码 true）")
    func missingFileHonoursBaselineFalse() {
        var baseline = hostBaseline
        baseline.enableMenuBarExtra = false
        let startup = ObservatoryLaunch.resolvedStartupSettings(
            persisted: nil,
            baseline: baseline
        )
        #expect(startup.enableMenuBarExtra == false)
    }

    @Test("内存库（storeDirectory 为空）也必须有明确答复：不退到随机值")
    func inMemoryStoreStillDeclaresFromBaseline() {
        var baseline = hostBaseline
        baseline.storeDirectory = ""
        baseline.enableMenuBarExtra = true
        let startup = ObservatoryLaunch.resolvedStartupSettings(persisted: nil, baseline: baseline)
        #expect(startup.enableMenuBarExtra == true)
        #expect(startup.storeDirectory.isEmpty)
    }
}
