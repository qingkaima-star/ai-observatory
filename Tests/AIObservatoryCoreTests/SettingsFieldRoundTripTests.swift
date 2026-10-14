//
//  SettingsFieldRoundTripTests.swift
//  AIObservatoryCoreTests
//
//  Owner: WS-l10n（ICR-0010 批准时需求方点名要的承重用例之一）
//  ─────────────────────────────────────────────────────────
//  **制度性护栏**：给 `ObservatorySettings` 加字段时，最容易漏的是手写 `init(from:)` 里那一行
//  `decodeIfPresent`。漏了**不报错、不崩、编译通过**（memberwise init 带默认值），
//  实际表现是「用户拨了、存了、重启回到默认」——ADR-0006「有人拨、没人读」的镜像变体
//  「**有人拨、没人存**」，比原变体更阴，因为它连一次异常都不留。
//
//  为什么用 `Mirror` 而不是手列字段：手列 12 个字段等于把同一个 bug 的第二个副本写进测试里——
//  加字段的人既然会漏 `init(from:)`，也一定会漏这里。`Mirror` 直接读结构体本身，
//  **新字段自动进入断言范围**，漏补解码就会以"该字段往返后不相等"的形式当场红并点名。
//
//  口径：这里量的是**契约自身的 Codable**（`SettingsPersistence` 用的就是合成的
//  `JSONEncoder` / `JSONDecoder`），不掺引擎的启动装配。
//  `SettingsPersistence.restore` 另有一处"storeDirectory 是位置不是偏好、读盘后强行钉回入参"的
//  特例（`SettingsPersistence.swift:48`），那条由 `SettingsPersistenceTests` 管，不在本文件射程内。
//

import Testing
import Foundation
@testable import AIObservatoryCore

@Suite("Core: 设置全字段持久化往返（加字段漏补 init(from:) 当场红）")
struct SettingsFieldRoundTripTests {

    /// 一份"**每个字段都不是默认值**"的设置。
    ///
    /// 为什么非要"每个字段都非默认"：默认值往返后仍然相等，漏解码就藏在里面看不出来。
    /// 例如 `demoRedactedOutput` 默认 false，若 `init(from:)` 忘了它，
    /// 用默认值那份 fixture 测出来是 `false → false`，**绿的**；只有非默认值才暴露。
    private static func everyFieldNonDefault() -> ObservatorySettings {
        ObservatorySettings(
            monitoredRoots: ["/Users/dev/Projects/alpha", "~/Documents/beta"],
            ignoredPathPatterns: ["*/vendor/*", "*.log"],
            processScanIntervalSeconds: 7.5,
            retentionDays: 21,
            enableEndpointSecurity: true,
            enableMenuBarExtra: false,
            enableRiskConfirmation: false,
            theme: .dark,
            launchAtLogin: true,
            storeDirectory: "/Users/dev/Library/Application Support/AIObservatory/store",
            storeDiffPlaintext: false,
            demoRedactedOutput: true,
        )
    }

    private static func fields(of settings: ObservatorySettings) -> [(String, String)] {
        Mirror(reflecting: settings).children.compactMap { child in
            guard let label = child.label else { return nil }
            return (label, String(reflecting: child.value))
        }
    }

    /// 分母守卫：**结构体自己报出的字段数**。这条不是防"漏解码"，是防"Mirror 突然数不到东西"
    /// （例如哪天换成 class 或加了计算属性，`fields(of:)` 会静默变少，上面那条就空转）。
    @Test("字段总数与登记值一致（今天 13 项）")
    func fieldCountMatchesLedger() {
        let labels = Self.fields(of: Self.everyFieldNonDefault()).map(\.0)
        #expect(labels.count == 13,
                "字段数变了（实测 \(labels.count)：\(labels)）⇒ 把本条的登记值改成新数，并确认新字段补了 init(from:)")
        #expect(Set(labels).count == labels.count, "字段名重复：\(labels)")
    }

    @Test("写盘→读回：每个字段逐字相等（漏 decodeIfPresent 就红在这里）")
    func roundTripPreservesEveryField() throws {
        let original = Self.everyFieldNonDefault()
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(ObservatorySettings.self, from: data)

        let before = Self.fields(of: original)
        let after = Dictionary(uniqueKeysWithValues: Self.fields(of: restored))
        #expect(before.count == after.count, "往返前后字段数不等：\(before.map(\.0)) vs \(after.keys.sorted())")
        for (label, value) in before {
            let cameBack = after[label] ?? "<字段消失>"
            #expect(after[label] == value,
                    "字段 \(label) 没活过一次写盘读回：存进去 \(value)，读回来 \(cameBack) ⇒ 十有八九是 init(from:) 少了一行 decodeIfPresent")
        }
        #expect(restored == original, "整份结构体不等（上面那条逐字断言会指出差在哪个字段）")
    }

    /// 反向校准：**证这把尺子真的会咬**。
    /// 造一份"故意丢掉某个键"的 JSON，断言该字段回落到默认值而不是解码失败——
    /// 这既钉住"缺键不重置全部设置"的既有口径，也证明上面的相等断言不是恒真
    /// （如果 `fields(of:)` 或比较写坏了，这一条会先红）。
    @Test("反向：缺一个键时该字段回落默认，其余字段照读（证尺子不空转）")
    func missingKeyFallsBackPerField() throws {
        let original = Self.everyFieldNonDefault()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as? [String: Any]
        #expect(json != nil, "设置编码出来不是 JSON 对象")
        let dropped = "demoRedactedOutput"
        json?[dropped] = nil
        let data = try JSONSerialization.data(withJSONObject: json!)
        let restored = try JSONDecoder().decode(ObservatorySettings.self, from: data)

        #expect(restored.demoRedactedOutput == ObservatorySettings.default.demoRedactedOutput,
                "缺 \(dropped) 键时没回落到默认值")
        // 其余字段必须**照原样读回来**：回落只许发生在被删掉的那一个键上。
        #expect(restored.theme == original.theme)
        #expect(restored.retentionDays == original.retentionDays)
        #expect(restored.monitoredRoots == original.monitoredRoots)
        #expect(restored.storeDiffPlaintext == original.storeDiffPlaintext)
    }
}
