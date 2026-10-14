//
//  SettingsFieldCoverageTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10n（ICR-0010 批准时需求方点名要的承重用例之二）
//  ─────────────────────────────────────────────────────────
//  治的病：`SettingsModel.pendingChangeCount` 是**手摆的一串 `if`**，
//  加字段的人不会想起这里——今天它就是活体病例：`storeDiffPlaintext` 漏着，
//  用户拨了那个开关，头部徽章仍写着"没有待应用的变更"（界面在说谎）。
//
//  为什么不用"数 if 的条数"这种源码级断言：那要维护第二份字段清单，
//  而**会漏 `if` 的人同样会漏那份清单**（本仓那一族：尺子自己也是被量对象）。
//  这里的做法是**让结构体自己报字段名**（`Mirror`），逐个真改一次、断言计数恰好 +1：
//  新字段没被 `pendingChangeCount` 认到 ⇒ 那一个字段红并点名，不用任何人记得来改测试。
//

import Testing
import Foundation
@testable import AIObservatoryCore
@testable import AIObservatoryUI
import AIObservatoryTestSupport

@MainActor
@Suite("UI: 每个设置字段都被 pendingChangeCount 认到（分母守卫）")
struct SettingsFieldCoverageTests {

    private static func model(starting settings: ObservatorySettings) -> SettingsModel {
        let service = InMemoryObservatoryService()
        let runtime = ObservatoryRuntime(
            service: service, controller: service, updates: service, settings: settings
        )
        return SettingsModel(runtime: runtime)
    }

    /// 结构体自己报出的字段名（顺序无关，只当集合用）。
    private static func fieldLabels() -> [String] {
        Mirror(reflecting: ObservatorySettings.default).children.compactMap(\.label)
    }

    /// 按字段名单改一次草稿。
    /// **返回 false = 这份测试不认识这个字段** ⇒ 上层断言会红并点名它，
    /// 逼着加字段的人（有意地）来这里补一行、并去 `pendingChangeCount` 补一行。
    private static func flip(_ label: String, on draft: inout ObservatorySettings) -> Bool {
        switch label {
        case "monitoredRoots": draft.monitoredRoots = ["/Users/dev/Projects/only"]; return true
        case "ignoredPathPatterns": draft.ignoredPathPatterns = ["*/only-one/*"]; return true
        case "processScanIntervalSeconds": draft.processScanIntervalSeconds = 11; return true
        case "retentionDays": draft.retentionDays = 45; return true
        case "enableEndpointSecurity": draft.enableEndpointSecurity.toggle(); return true
        case "enableMenuBarExtra": draft.enableMenuBarExtra.toggle(); return true
        case "enableRiskConfirmation": draft.enableRiskConfirmation.toggle(); return true
        case "theme": draft.theme = draft.theme == .dark ? .light : .dark; return true
        case "launchAtLogin": draft.launchAtLogin.toggle(); return true
        case "storeDirectory": draft.storeDirectory = "/Users/dev/elsewhere"; return true
        case "storeDiffPlaintext": draft.storeDiffPlaintext.toggle(); return true
        case "demoRedactedOutput": draft.demoRedactedOutput.toggle(); return true
        case "notifyHighRisk": draft.notifyHighRisk.toggle(); return true
        default: return false
        }
    }

    @Test("逐个字段单独改：计数必须恰好 +1（漏算那个字段就红并点名）")
    func everyFieldIsCountedExactlyOnce() {
        let baseline = ObservatorySettings.default
        var uncovered: [String] = []
        var miscounted: [String] = []
        for label in Self.fieldLabels() {
            var changed = baseline
            guard Self.flip(label, on: &changed) else { uncovered.append(label); continue }
            let model = Self.model(starting: baseline)
            model.update { $0 = changed }
            if model.pendingChangeCount != 1 { miscounted.append("\(label)（实测 \(model.pendingChangeCount)）") }
        }
        #expect(uncovered.isEmpty,
                "这些字段本测试不认识 ⇒ 补 flip() 并确认 pendingChangeCount 也认它：\(uncovered)")
        #expect(miscounted.isEmpty,
                "改了这些字段而徽章没数到（或多数了）：\(miscounted)")
    }

    @Test("两个字段一起改 ⇒ 计数为 2（防「任何改动都只算 1」这种假覆盖）")
    func twoFieldsCountTwo() {
        let baseline = ObservatorySettings.default
        let model = Self.model(starting: baseline)
        model.update { draft in
            draft.retentionDays = 90
            draft.demoRedactedOutput.toggle()
        }
        #expect(model.pendingChangeCount == 2, "实测 \(model.pendingChangeCount) ⇒ 有一项没被单独数到")
    }

    /// 反向校准：证上面那条"不认识就红"不是空话。
    @Test("反向：不存在的字段名必须被判未覆盖")
    func unknownLabelIsReportedAsUncovered() {
        var draft = ObservatorySettings.default
        #expect(Self.flip("thisFieldDoesNotExist", on: &draft) == false,
                "harness 对未知字段返回了 true ⇒ 上面那条分母守卫是空转的")
    }

    @Test("反向：没改任何字段时计数为 0（否则徽章天天说谎）")
    func untouchedDraftCountsZero() {
        let baseline = ObservatorySettings.default
        let model = Self.model(starting: baseline)
        #expect(model.pendingChangeCount == 0)
        model.update { _ in }                       // 空改动也不许虚增
        #expect(model.pendingChangeCount == 0)
    }
}
