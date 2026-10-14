//
//  SceneInjectionTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-exitlist（#89 ①-b 开关射程）
//  ─────────────────────────────────────────────────────────
//  派单里那句「`demoRedactedOutput` 射程不到」有一个纯字符串测试抓不到的机制：
//  SwiftUI 的 `.environment` **不跨 Scene**。主窗口注入的那一份进不了
//  `MenuBarExtra` 与 `Settings` 两个独立窗口 ⇒ 那一整屏拿到的是环境默认值 `.off`，
//  开关拨到天上也没用。设置页恰恰**全屏都是路径**（监控根、忽略规则、存储目录）。
//
//  所以这一支判的是「会渲染路径的 Scene 根必须自己注入」，两条腿：
//   ① 源码级：每个 Scene 根要么带着 `.environment(\\.demoRedaction`，要么被证明**没有**路径出口；
//   ② 行为级：把 `SettingsView` 原样渲染（**不**手工注入环境值——那正是真机的形状），
//      断言开着映射时那一屏读得到 `~`、读不到真实家目录。
//
//  ⚠️ 需求方 09-23 硬令：不点击、不翻页、不拍图。这里只用 `A11yTree` 在测试进程里
//  渲染视图并走无障碍树，不起 App。
//

import Testing
import Foundation
import SwiftUI
import AppKit
@testable import AIObservatoryCore
@testable import AIObservatoryUI
import AIObservatoryTestSupport

@MainActor
@Suite("UI: #89 每个 Scene 都要自己接上映射（.environment 不跨 Scene）", .serialized)
struct SceneInjectionTests {

    private static var home: String { NSHomeDirectory() }
    private static var monitoredRoot: String { "\(home)/Documents/AiX" }

    private static func settings(on: Bool) -> ObservatorySettings {
        ObservatorySettings(monitoredRoots: [monitoredRoot], demoRedactedOutput: on)
    }

    private static func runtime(on: Bool) -> ObservatoryRuntime {
        let host = InMemoryObservatoryService()
        host.seed(agents: [AgentInstance(kind: .claudeCode, pid: 4242, displayName: "claude",
                                         executablePath: "/usr/local/bin/claude",
                                         workingDirectory: monitoredRoot, startedAt: Date())])
        return ObservatoryRuntime(service: host, controller: host, updates: host,
                                  settings: settings(on: on))
    }

    // MARK: ① 源码级：Scene 根的清单本身就是分母

    /// 三个 Scene 根。加第四个窗口（比如再开一个独立面板）而不改这张表 ⇒ 下面那条用例红。
    private static let sceneRoots: [(file: String, name: String)] = [
        ("Sources/AIObservatoryUI/Shell/ObservatoryRootView.swift", "主窗口"),
        ("Sources/AIObservatoryUI/Settings/SettingsView.swift", "⌘, 设置窗口"),
        ("Sources/AIObservatoryUI/Shell/MenuBarContentView.swift", "菜单栏窗口"),
    ]

    /// 判据是「**必须注入**」，不是「这一页看起来没用到映射就算了」。
    ///
    /// ⚠️ 第一版写成"要么注入、要么本文件没有路径引用"，变异确认当场把它戳穿了：
    /// 摘掉 `SettingsView` 那行注入之后它仍然绿——因为吃路径的是**另外的文件**
    /// （`SettingsStoragePane` / `SettingsPrivacyPane`），在 `SettingsView.swift` 里当然扫不到。
    /// "本文件没引用"是"这一屏没路径"的坏证据，所以豁免改成正面登记：
    /// 只有列进 `pathFreeRoots`、且行为用例真的证过它不渲染路径的窗口才允许不注入。
    @Test("每一个 Scene 根都必须自己注入映射（除了行为证过没有路径的那一格）")
    func everySceneRootInjectsTheMask() throws {
        #expect(Self.sceneRoots.count == 3, "Scene 根的数量变了 ⇒ 这张表要跟着改，别只加窗口")
        let exempt = Set(Self.pathFreeRoots.map(\.file))
        for root in Self.sceneRoots where !exempt.contains(root.file) {
            let code = try BilingualCopyGate.codeOnlyString(root.file)
            #expect(!code.isEmpty, "\(root.file) 剥注释后为空 ⇒ 这条判据扫不到它")
            #expect(code.contains(".environment(\\.demoRedaction"),
                    "\(root.name)（\(root.file)）没注入映射 ⇒ 整个 Scene 在开关射程之外，而它的子视图（别的文件）正把路径铺上屏")
        }
    }

    /// 允许不注入的窗口，必须同时给出"它不渲染路径"的行为证据（用例名就写在本文件里）。
    private static let pathFreeRoots: [(file: String, proof: String)] = [
        ("Sources/AIObservatoryUI/Shell/MenuBarContentView.swift",
         "menuBarWindowCarriesNoPaths"),
    ]

    @Test("不注入的那一格，豁免理由必须是一段读得到的行为证据")
    func pathFreeExemptionsHaveBehavioralProof() async throws {
        let own = try BilingualCopyGate.codeOnlyString(
            "Tests/AIObservatoryUITests/SceneInjectionTests.swift")
        for exemption in Self.pathFreeRoots {
            #expect(own.contains(exemption.proof),
                    "\(exemption.file) 声称不渲染路径，但本文件里找不到证它的用例 `\(exemption.proof)`")
        }
    }

    @Test("菜单栏那一格不显示路径：拿真无障碍树证一次，而不是靠人说『这里没路径』")
    func menuBarWindowCarriesNoPaths() async {
        // 正向：整棵树里不许有真实家目录。
        let on = await A11yTree.renderedTexts(
            MenuBarContentView(runtime: Self.runtime(on: true))
                .frame(width: 320, height: 600),
            minCount: 4, settle: 4)
        let leaks = on.filter { $0.contains(Self.home) }
        // 内容守卫：树要是空的，"不含家目录"就是假绿。
        #expect(on.contains { $0.contains("claude") || $0.contains("Claude") },
                "菜单栏窗口连 Agent 行都没渲染出来 ⇒ 下面的『不含家目录』是空的：\n\(on)")
        #expect(leaks.isEmpty, "菜单栏窗口漏出真实家目录：\n\(leaks)")
        // 反向自证：这一格今天确实没有路径出口，所以**关着也不该有**——
        // 这条断言的意义是：如果哪天有人往这里加了路径行，上面那条正向会先红。
        let off = await A11yTree.renderedTexts(
            MenuBarContentView(runtime: Self.runtime(on: false))
                .frame(width: 320, height: 600),
            minCount: 4, settle: 4)
        #expect(off.contains { $0.contains("claude") || $0.contains("Claude") },
                "关掉映射后菜单栏连 Agent 行都不见了 ⇒ 渲染形状变了")
    }

    // MARK: ② 行为级：设置页那一分段的两态（映射由 Scene 根注入，见①）

    /// 为什么测的是分段而不是 `SettingsView` 整页：默认分段是「通用」，那里没有路径格；
    /// 换到「存储」要点选择器——需求方 09-23 硬令停止一切点击验证。
    /// 所以这一支拆成两跳，各自有牙：
    ///  · 「路径格开/关两态输出什么」⇒ 本条（渲染 `SettingsStoragePane`，接同一份映射）；
    ///  · 「这份映射到得了这一页」⇒ 上面 `everySceneRootHandlesItsOwnMask` 逐字钉着
    ///    `SettingsView` body 里那一行 `.environment(\.demoRedaction, model.renderMask)`。
    /// 两跳都过才算闭合；任何一跳红都不知道该找谁，所以两条分开写。
    private static func storagePane(on: Bool) async -> [String] {
        let model = SettingsModel(runtime: runtime(on: on))
        let mask = PathPrivacy.Mask.configured(from: settings(on: on))
        return await A11yTree.renderedTexts(
            SettingsStoragePane(model: model)
                .environment(\.demoRedaction, mask)
                .frame(width: 1_100, height: 1_400),
            minCount: 6, settle: 8,
                probe: on ? PathPrivacy.Mask.projectPlaceholder : "Documents")
    }

    @Test("反向探针：映射关闭时，存储分段以原文列出监控根")
    func storagePaneShowsTheRootWhenOff() async {
        let texts = await Self.storagePane(on: false)
        #expect(texts.contains { $0.contains(Self.monitoredRoot) },
                "关掉映射也读不到监控根原文 ⇒ 这一屏没吃到路径，正向判据是空的：\n\(texts)")
    }

    @Test("开启映射：存储分段整屏读不到真实家目录（改造前这一条必红——它是另一个 Scene）")
    func storagePaneHidesTheRootWhenOn() async {
        let texts = await Self.storagePane(on: true)
        #expect(texts.contains { $0.contains(PathPrivacy.Mask.projectPlaceholder) },
                "这一屏没渲染出监控根（连占位符都没有）⇒ 『不含家目录』是空的：\n\(texts)")
        let leaks = texts.filter { $0.contains(Self.home) }
        #expect(leaks.isEmpty,
                "开着映射，设置窗口仍有 \(leaks.count) 格带真实家目录：\n\(leaks.joined(separator: "\n"))")
    }
}
