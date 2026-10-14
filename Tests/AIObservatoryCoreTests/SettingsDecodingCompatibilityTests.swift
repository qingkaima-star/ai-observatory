//
//  SettingsDecodingCompatibilityTests.swift
//  AIObservatoryCoreTests
//
//  Owner: master-controller
//  ─────────────────────────────────────────────────────────
//  守的是「加字段会不会清掉用户设置」这条升级路径。
//
//  起因：`ObservatorySettings` 原先只用合成的 `Codable`。Swift 合成的 `Decodable`
//  **不会**拿属性默认值去补缺失的键——非 Optional 的键不在 JSON 里就抛 `keyNotFound`。
//  而 `SettingsPersistence.restore` 把任何解码失败都记成「设置文件损坏」并返回 `nil`，
//  调用方于是回落全默认值。⇒ **给这个 struct 加一个新字段，所有老用户的 settings.json
//  都会解码失败、全部设置被静默重置**，日志还会把它说成数据损坏。
//  现在解码器改成逐键 `decodeIfPresent ?? ObservatorySettings.default`，本文件钉住这个行为。
//

import Foundation
import Testing
@testable import AIObservatoryCore

/// 测试侧的键清单。**新增设置项时必须往这里加一行** —— 漏加不会静默通过：
/// `everyMissingKeyFallsBackToDefaultIndividually` 会拿完整 JSON 逐键删除，
/// 而 `ObservatorySettings` 的新字段若不在此列，就永远不会被「缺这个键」覆盖到。
private enum SettingsKey: String, CaseIterable {
    case monitoredRoots
    case ignoredPathPatterns
    case processScanIntervalSeconds
    case retentionDays
    case enableEndpointSecurity
    case enableMenuBarExtra
    case enableRiskConfirmation
    case theme
    case launchAtLogin
    case storeDirectory
    case storeDiffPlaintext
}

/// 一份**每个字段都不同于默认值**的设置，用来区分「读到了」与「悄悄回落默认值」。
/// 期望值全部手算写死，不拿 `ObservatorySettings.default` 当期望值（那是自我对账）。
private func distinctiveSettings() -> ObservatorySettings {
    ObservatorySettings(
        monitoredRoots: ["/tmp/alpha", "/tmp/beta"],
        ignoredPathPatterns: ["*/skip/*"],
        processScanIntervalSeconds: 11.25,
        retentionDays: 123,
        enableEndpointSecurity: true,
        enableMenuBarExtra: false,
        enableRiskConfirmation: false,
        theme: .dark,
        launchAtLogin: true,
        storeDirectory: "/tmp/obs-store",
        storeDiffPlaintext: false
    )
}

private func jsonObject(from settings: ObservatorySettings) throws -> [String: Any] {
    let data = try JSONEncoder().encode(settings)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw SerializationError.notAnObject
    }
    return object
}

private enum SerializationError: Error {
    case notAnObject, notData
}

private func decode(_ object: [String: Any]) throws -> ObservatorySettings {
    let data = try JSONSerialization.data(withJSONObject: object)
    return try JSONDecoder().decode(ObservatorySettings.self, from: data)
}

@Suite("Core: 设置解码的向后兼容（#18）", .timeLimit(.minutes(1)))
struct SettingsDecodingCompatibilityTests {

    @Test("空 JSON 不再抛错：每个字段都取默认值（逐项写死期望）")
    func emptyObjectYieldsAllDefaults() throws {
        let settings = try decode([:])
        #expect(settings.monitoredRoots == [])
        #expect(settings.ignoredPathPatterns == [
            "*/Library/Caches/*", "*/.build/*", "*/node_modules/*",
            "*/.git/objects/*", "*/DerivedData/*", "*.tmp",
        ])
        #expect(settings.processScanIntervalSeconds == 3)
        #expect(settings.retentionDays == 30)
        #expect(settings.enableEndpointSecurity == false)
        #expect(settings.enableMenuBarExtra == true)
        #expect(settings.enableRiskConfirmation == true)
        #expect(settings.theme == .system)
        #expect(settings.launchAtLogin == false)
        #expect(settings.storeDirectory == "")
        // 缺这个键的默认值必须是 true：老用户从没要求过「不要明文」，
        // 悄悄按 false 解码会让他们升级后突然看不到 diff 内容。
        #expect(settings.storeDiffPlaintext == true)
    }

    /// 这条是 bug 的正面对撞：老版本写出的文件**不含新版本才有的键**，必须还能读。
    @Test("逐键删除：缺哪个键就只回落那一个字段，其余字段不被牵连")
    func everyMissingKeyFallsBackToDefaultIndividually() throws {
        let full = try jsonObject(from: distinctiveSettings())
        let defaults = ObservatorySettings.default

        for key in SettingsKey.allCases {
            var partial = full
            partial.removeValue(forKey: key.rawValue)

            let settings = try decode(partial)   // 修前：这里对非 Optional 键抛 keyNotFound

            switch key {
            case .monitoredRoots: #expect(settings.monitoredRoots == defaults.monitoredRoots, "\(key.rawValue) 缺失应回落默认")
            case .ignoredPathPatterns: #expect(settings.ignoredPathPatterns == defaults.ignoredPathPatterns)
            case .processScanIntervalSeconds: #expect(settings.processScanIntervalSeconds == defaults.processScanIntervalSeconds)
            case .retentionDays: #expect(settings.retentionDays == defaults.retentionDays)
            case .enableEndpointSecurity: #expect(settings.enableEndpointSecurity == defaults.enableEndpointSecurity)
            case .enableMenuBarExtra: #expect(settings.enableMenuBarExtra == defaults.enableMenuBarExtra)
            case .enableRiskConfirmation: #expect(settings.enableRiskConfirmation == defaults.enableRiskConfirmation)
            case .theme: #expect(settings.theme == defaults.theme)
            case .launchAtLogin: #expect(settings.launchAtLogin == defaults.launchAtLogin)
            case .storeDirectory: #expect(settings.storeDirectory == defaults.storeDirectory)
            case .storeDiffPlaintext: #expect(settings.storeDiffPlaintext == defaults.storeDiffPlaintext)
            }

            // 关键：其余字段必须**原样保留**，不能被整份重置成默认。
            #expect(
                settings.monitoredRoots == (key == .monitoredRoots ? defaults.monitoredRoots : ["/tmp/alpha", "/tmp/beta"]),
                "\(key.rawValue) 缺失时不应连带改掉 monitoredRoots"
            )
            #expect(
                settings.retentionDays == (key == .retentionDays ? defaults.retentionDays : 123),
                "\(key.rawValue) 缺失时不应连带改掉 retentionDays"
            )
        }
    }

    @Test("未知键被忽略：新版本写出的文件老版本读得动（向前兼容）")
    func unknownKeyIsIgnored() throws {
        var object = try jsonObject(from: distinctiveSettings())
        object["someSettingFromTheFuture"] = true
        object["enableDiffCapture"] = "不是布尔也无妨"

        let settings = try decode(object)
        #expect(settings == distinctiveSettings())
    }

    @Test("完整往返：非默认值一个都不丢（防止解码器默默吞掉真实设置）")
    func fullRoundTripPreservesEveryField() throws {
        let original = distinctiveSettings()
        let restored = try decode(try jsonObject(from: original))
        #expect(restored == original)
        #expect(restored.theme == .dark)
        #expect(restored.enableMenuBarExtra == false)
        #expect(restored.storeDirectory == "/tmp/obs-store")
    }

    @Test("已删除的历史键 `sampleIntervalSeconds` 留在老文件里也不影响解码")
    func removedKeyIsIgnoredByOldFiles() throws {
        // 这个键真的存在过（默认 2），且**引擎侧从来没有人读它**，所以被删掉了。
        // 但用户磁盘上的 settings.json 里还带着它，于是必须钉住两件事：
        //   1. 它**不会**让解码失败（失败会被 `SettingsPersistence.restore` 当成
        //      「文件损坏」并静默重置全部设置 —— 那等于删一个字段清掉用户所有配置）；
        //   2. 它**不会**被误读成别的字段（尤其不能污染同族的 `processScanIntervalSeconds`）。
        // 与 `unknown key ignored` 那条的分工：那条证明「机制上未知键会被跳过」，
        // 这条证明**这个具体的、真实写进过用户磁盘的键**在当前代码下无害。
        var object = try jsonObject(from: distinctiveSettings())
        object["sampleIntervalSeconds"] = 9.5
        let settings = try decode(object)
        #expect(settings == distinctiveSettings())
        #expect(settings.processScanIntervalSeconds == distinctiveSettings().processScanIntervalSeconds)
    }

    @Test("类型写错的字段仍然抛错：兼容的是「缺键」，不是「烂数据」")
    func wrongTypeStillThrows() throws {
        #expect(throws: (any Error).self) {
            try decode(["retentionDays": "三十"])
        }
    }
}
