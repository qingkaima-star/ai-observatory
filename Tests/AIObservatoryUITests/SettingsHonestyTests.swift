//
//  SettingsHonestyTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-Honesty（ADR-0006 #14 / #6）
//  ─────────────────────────────────────────────────────────
//  设置页的两条「不许说谎」：
//    1. 拨了菜单栏开关 → 应用后的提示必须讲清本进程不会变（原来只会报「N 项已应用」）；
//    2. About 页那一行报的是**本进程声明了什么**，不是草稿拨到哪。
//  外加实时捕获能力那一行的上屏读数（含宿主没接入时的兜底文案）。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryTestSupport

private struct StubCapability: RealtimeCapabilityReporting {
    let capability: RealtimeCapability
    func currentRealtimeCapability() -> RealtimeCapability { capability }
}

@MainActor
private func makeModel(
    menuBarAtLaunch: Bool,
    capability: (any RealtimeCapabilityReporting)? = nil
) -> SettingsModel {
    let service = InMemoryObservatoryService()
    let runtime = ObservatoryRuntime(
        service: service,
        controller: service,
        updates: service,
        settings: ObservatorySettings(enableMenuBarExtra: menuBarAtLaunch),
        capability: capability
    )
    return SettingsModel(runtime: runtime)
}

@MainActor
@Suite("UI: 设置页不谎报菜单栏与采集保真度")
struct SettingsHonestyTests {

    @Test("拨了菜单栏开关再应用：提示里必须点明本进程不变、要重启")
    func applyMentionsRestartForMenuBarChange() async {
        let model = makeModel(menuBarAtLaunch: true)
        model.update { $0.enableMenuBarExtra = false }
        await model.apply()
        // `notice` 是**存下来的一句**（写入时按当时语言定稿），所以只能拿同一来源比：
        // 常驻说明 + 那句菜单栏提醒。子串里的"本进程不变"这类措辞由
        // `SettingsBilingualCopyTests.menuBarReminderEnglishStaysHonest` 逐语言钉住。
        let language = UILanguage.current
        #expect(model.notice == SettingsModel.persistenceNotice(language)
                + SettingsCopy.menuBarRestartReminder.text(language))
    }

    @Test("没碰菜单栏就应用：不许塞一句无关的重启提醒（常驻噪音会稀释真提醒）")
    func applyStaysQuietWithoutMenuBarChange() async {
        let model = makeModel(menuBarAtLaunch: true)
        model.update { $0.retentionDays = 12 }
        await model.apply()
        #expect(model.notice == SettingsModel.persistenceNotice(UILanguage.current))
    }

    @Test("About 页报的是启动声明值：草稿改动只标注为待重启")
    func aboutRowReportsLaunchDeclaration() {
        // 启动时声明了菜单栏，草稿把它拨成关：那一行仍须报「已声明」，另附待重启。
        let model = makeModel(menuBarAtLaunch: true)
        model.update { $0.enableMenuBarExtra = false }
        #expect(model.menuBarAboutText(.chineseSimplified) == "已声明菜单栏（草稿待重启）")
        #expect(model.menuBarDraftMatchesLaunch == false)
    }

    @Test("About 页：草稿与启动声明一致时不带待重启后缀")
    func aboutRowStaysCleanWithoutDraftChange() {
        #expect(makeModel(menuBarAtLaunch: true).menuBarAboutText(.chineseSimplified) == "已声明菜单栏")
    }

    @Test("About 页：启动就没声明时如实说未声明")
    func aboutRowReportsAbsentMenuBar() {
        let model = makeModel(menuBarAtLaunch: false)
        #expect(model.menuBarAboutText(.chineseSimplified) == "未声明菜单栏")
        #expect(model.menuBarDeclaredAtLaunchText(.chineseSimplified) == "未声明菜单栏")
    }

    @Test("能力读数接得上时：展示名与保真度说明都取自枚举，界面不自写一套")
    func capabilityReadoutComesFromEnum() async {
        let model = makeModel(menuBarAtLaunch: true, capability: StubCapability(capability: .processPolling))
        await model.load()
        #expect(model.realtimeCapabilityText(.chineseSimplified) == "轮询模式")
        #expect(model.realtimeCapabilityNote(.chineseSimplified) == RealtimeCapability.processPolling.fidelityNote)
        #expect(model.realtimeCapabilityNote(.chineseSimplified).contains("不是全量记录") == true)
    }

    @Test("宿主没接能力读数时：明说未接入，而不是留空或猜一档")
    func capabilityReadoutStatesMissingWiring() async {
        let model = makeModel(menuBarAtLaunch: true)
        await model.load()
        #expect(model.realtimeCapability == nil)
        #expect(model.realtimeCapabilityText(.chineseSimplified) == "未接入：本宿主没有提供能力读数")
        #expect(model.realtimeCapabilityNote(.chineseSimplified).contains("不等于「全量」") == true)
    }
}
