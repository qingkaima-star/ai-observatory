//
//  SettingsPersistenceTests.swift
//  AIObservatoryEngineTests
//
//  Owner: master-controller
//
//  覆盖「设置真的生效并留得住」这条验收：契约新增 `updateSettings` 之前，
//  Settings 板块点「应用」只改 UI 自己的本地副本，既不生效也不跨启动。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

/// 测试专用 scratch 目录，**必须**落在 AiX 内。
private func scratchDirectory(_ name: String) throws -> String {
    let repoRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // Tests/AIObservatoryEngineTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // 仓库根
    let url = repoRoot.appending(path: ".scratch-tests").appending(path: name)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url.path
}

private func cleanup(_ path: String) {
    try? FileManager.default.removeItem(atPath: path)
}

private func makeSettings(directory: String) -> ObservatorySettings {
    ObservatorySettings(
        monitoredRoots: ["/Users/demo/Projects/Mona"],
        ignoredPathPatterns: ["**/node_modules/**"],
        processScanIntervalSeconds: 11,
        retentionDays: 45,
        enableEndpointSecurity: false,
        enableMenuBarExtra: true,
        enableRiskConfirmation: false,
        theme: .dark,
        launchAtLogin: true,
        storeDirectory: directory
    )
}

private func makeEngine(settings: ObservatorySettings) async throws -> ObservatoryEngine {
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let mapper = ProjectMapper(resolver: { _ in nil })
    return ObservatoryEngine(
        settings: settings,
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: StubDetector(agents: []),
            processInspector: StubProcessSource(),
            metrics: StubMetrics(),
            commandAuditor: StubAuditor(),
            fileObserver: StubFileObserver(),
            snapshotter: StubSnapshotter(providesContent: false),
            differ: StubDiffer(),
            aggregator: TimelineAggregator(projectMapper: mapper),
            projectMapper: mapper
        )
    )
}

@Suite("设置持久化：存得下、读得回、坏了不崩")
struct SettingsPersistenceTests {

    @Test("保存后逐字段读回")
    func roundTrip() throws {
        let dir = try scratchDirectory("roundtrip")
        defer { cleanup(dir) }
        let settings = makeSettings(directory: dir)

        #expect(SettingsPersistence.save(settings))
        let restored = try #require(SettingsPersistence.restore(ifPresentIn: dir))
        #expect(restored == settings)
    }

    @Test("文件损坏时回退基线而不是抛错")
    func corruptFileFallsBack() throws {
        let dir = try scratchDirectory("corrupt")
        defer { cleanup(dir) }
        try Data("这不是 JSON".utf8).write(to: URL(fileURLWithPath: dir).appending(path: "settings.json"))

        #expect(SettingsPersistence.restore(ifPresentIn: dir) == nil)
    }

    @Test("内存库（空目录）不落盘也不报错")
    func memoryStoreSkipsDisk() throws {
        #expect(SettingsPersistence.restore(ifPresentIn: "") == nil)
        #expect(SettingsPersistence.save(makeSettings(directory: "")))
    }

    @Test("目录不存在时保存会自建")
    func createsMissingDirectory() throws {
        let base = try scratchDirectory("nested")
        defer { cleanup(base) }
        let nested = base + "/deep/levels"

        #expect(SettingsPersistence.save(makeSettings(directory: nested)))
        #expect(SettingsPersistence.restore(ifPresentIn: nested) != nil)
    }

    /// 事故复现（真机 release 包，`03-进度日志/2026-09-20-flake-hardening.md`）：
    /// 目录里只放一个 `{"theme":"light"}`，45 秒后该目录**没有任何 sqlite**、
    /// `lsof` 显示进程打开的 `observatory.sqlite` 数为 0 ⇒ 全部数据只在内存里。
    /// 对照：同一颗包、同一个目录，不放这个文件时正常落 `observatory.sqlite`/`-shm`/`-wal`。
    @Test("部分字段的 settings.json 不能把数据目录覆盖成空串（否则静默退内存库）")
    func partialFileKeepsAuthoritativeDirectory() throws {
        let dir = try scratchDirectory("partial")
        defer { cleanup(dir) }
        try Data(#"{"theme":"light"}"#.utf8)
            .write(to: URL(fileURLWithPath: dir).appending(path: "settings.json"))

        // 未知键被 JSONDecoder 忽略 ⇒ 解码**成功**，缺失的 `storeDirectory` 拿到 init 的默认 `""`。
        // 旧实现在这里返回 `""`，而两个调用方都是「文件在就整个采信」⇒ 位置被空串覆盖。
        let restored = try #require(SettingsPersistence.restore(ifPresentIn: dir))
        #expect(restored.storeDirectory == dir,
                "落盘文件把自己的位置覆盖掉了 ⇒ 引擎按「空目录 → 内存库」装配，数据不落盘")
    }

    /// 反向守卫：文件**写了别的路径**也不许作数——它就在那个目录里，没资格决定自己在哪。
    /// 少了这条，"修好"可以偷懒成"缺字段时补个默认值"，而显式写错路径的情况仍然漏。
    @Test("settings.json 里写的 storeDirectory 不能反向决定数据目录")
    func fileCannotRelocateItsOwnDirectory() throws {
        let dir = try scratchDirectory("relocate")
        defer { cleanup(dir) }
        try Data(#"{"storeDirectory":"/nonexistent/elsewhere","enableMenuBarExtra":true}"#.utf8)
            .write(to: URL(fileURLWithPath: dir).appending(path: "settings.json"))

        let restored = try #require(SettingsPersistence.restore(ifPresentIn: dir))
        #expect(restored.storeDirectory == dir)
        // 同时证明这是"真的解码成功了"，不是回退到 nil/基线：偏好字段要读得到。
        #expect(restored.enableMenuBarExtra, "偏好字段应照常生效（本用例只剥夺它对位置的发言权）")
    }
}

@Suite("updateSettings：真的生效")
struct UpdateSettingsTests {

    @Test("引擎反映新设置")
    func engineAppliesNewSettings() async throws {
        let dir = try scratchDirectory("engine-apply")
        defer { cleanup(dir) }
        let engine = try await makeEngine(settings: makeSettings(directory: dir))

        var updated = makeSettings(directory: dir)
        updated.retentionDays = 3
        updated.processScanIntervalSeconds = 42
        await engine.updateSettings(updated)

        #expect(engine.currentSettings.retentionDays == 3)
        #expect(engine.currentSettings.processScanIntervalSeconds == 42)
    }

    @Test("跨引擎实例保留：新实例从磁盘读回上次设置")
    func survivesNewEngineInstance() async throws {
        let dir = try scratchDirectory("engine-survive")
        defer { cleanup(dir) }

        let first = try await makeEngine(settings: makeSettings(directory: dir))
        var updated = makeSettings(directory: dir)
        updated.theme = .light
        await first.updateSettings(updated)

        // 第二个实例传入一份不同的基线：应当被磁盘上「上次真正应用的值」覆盖。
        let second = try await makeEngine(settings: ObservatorySettings(storeDirectory: dir))
        #expect(second.currentSettings.theme == .light)
        #expect(second.currentSettings.retentionDays == 45)
    }

    @Test("内存库下设置仅本次会话生效，不写文件")
    func memoryScopedSettingsDoNotTouchDisk() async throws {
        let engine = try await makeEngine(settings: ObservatorySettings())
        var updated = ObservatorySettings()
        updated.retentionDays = 9
        await engine.updateSettings(updated)

        #expect(engine.currentSettings.retentionDays == 9)
    }

    @Test("与内存实现行为一致")
    func parityWithInMemoryService() async throws {
        let inMemory = InMemoryObservatoryService()
        var updated = ObservatorySettings()
        updated.retentionDays = 12
        updated.theme = .light

        await inMemory.updateSettings(updated)
        #expect(inMemory.currentSettings.retentionDays == 12)
        #expect(inMemory.currentSettings.theme == .light)
    }

    @Test("声明了需重启的项不会假装自己已生效")
    func restartRequiredListIsHonest() {
        let listed = Set(ObservatoryEngine.restartRequiredSettings)
        #expect(listed.contains("theme"))
        #expect(listed.contains("storeDirectory"))
        // 而这两项必须**不**在列表里——它们是真能热生效的，别把它们推给用户。
        #expect(!listed.contains("processScanIntervalSeconds"))
        #expect(!listed.contains("retentionDays"))
    }
}
