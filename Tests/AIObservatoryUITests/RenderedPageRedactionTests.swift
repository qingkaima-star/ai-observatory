//
//  RenderedPageRedactionTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-finisher（#64 ①「整页枚举断言」）
//  ─────────────────────────────────────────────────────────
//  派单原话：**逐格断言就是这次的漏因**。所以这一支不数格子，
//  而是把真的无障碍树走完——文件页与时间线页**全部**含路径的格子收进一个集合，
//  断言集合里一个真实家目录都不许存在。
//
//  输入用的是 `NSHomeDirectory()`（真机家目录），不是合成值：
//  #64 要证的正是"这台机器的路径不会漏到屏上"，拿 `/Users/dev` 造夹具只能证明
//  映射认得 `/Users/dev`。写进源码的仍是 `NSHomeDirectory()` 调用而非字面路径 ⇒
//  门禁 4/4 认这一种形状（`Scripts/verify.sh` 末尾口径）。
//
//  ⚠️ 每个正向判据都配一条**反向探针**：关掉映射时同一棵树里必须看得见家目录。
//  探针红 = 树没走通 / 夹具没喂到屏上，此时正向那条是空的，必须一起作废。
//

import Testing
import Foundation
import SwiftUI
import AppKit
@testable import AIObservatoryCore
@testable import AIObservatoryUI
import AIObservatoryTestSupport

@MainActor
@Suite("UI: #64 整页枚举（真无障碍树）· 文件页与时间线页不许出现真实家目录", .serialized)
struct RenderedPageRedactionTests {

    private static var home: String { NSHomeDirectory() }

    /// 造一份"这台机器上真实存在形状"的输入：文件变更、时间线事件、
    /// 以及一句把路径拼进去的 summary（引擎真就这么拼，见 `TimelineAggregator`）。
    private static func fileChanges() -> [FileChange] {
        [
            FileChange(path: "\(home)/Documents/AiX/README.md", kind: .modified,
                       timestamp: Date(), agentKind: .claudeCode, linesAdded: 3, linesRemoved: 1),
            FileChange(path: "\(home)/.ssh/id_ed25519", kind: .created,
                       timestamp: Date(), agentKind: .openAICodex),
            FileChange(path: "\(home)/Library/Application Support/com.aix.aiobservatory/x.sqlite",
                       kind: .deleted, timestamp: Date(), agentKind: .claudeCode),
        ]
    }

    private static func events() -> [TimelineEvent] {
        [
            TimelineEvent(timestamp: Date(), agentKind: .claudeCode, kind: .fileModified,
                          title: "修改文件 · README.md",
                          summary: "[\(home)/Documents/AiX/README.md] +3 −1",
                          filePath: "\(home)/Documents/AiX/README.md",
                          projectPath: "\(home)/Documents/AiX"),
            TimelineEvent(timestamp: Date().addingTimeInterval(-30), agentKind: .openAICodex,
                          kind: .commandExecuted, title: "读取凭据",
                          summary: "原路径 \(home)/.ssh",
                          filePath: "\(home)/.ssh/id_ed25519",
                          command: "cat \(home)/.ssh/id_ed25519",
                          projectPath: home),
        ]
    }

    /// `demoRedactedOutput` 走**两条**路：视图从环境值读映射，`FilesModel` 从启动设置读
    /// （采集面那句是模型拼的，不是视图拼的）。所以测试里两边必须同源，
    /// 否则"环境开了、设置没开"会测出一个真机上不存在的组合。
    private static func runtime(on: Bool) -> ObservatoryRuntime {
        let settings = ObservatorySettings(
            monitoredRoots: ["\(home)/Documents/AiX"],
            demoRedactedOutput: on
        )
        let host = InMemoryObservatoryService()
        host.seed(events: events(), fileChanges: fileChanges())
        return ObservatoryRuntime(
            service: host, controller: host, updates: host, settings: settings
        )
    }

    private static func mask(on: Bool) -> PathPrivacy.Mask {
        PathPrivacy.Mask.configured(from: ObservatorySettings(
            monitoredRoots: ["\(home)/Documents/AiX"], demoRedactedOutput: on))
    }

    private static func filesPage(on: Bool) async -> [String] {
        await A11yTree.renderedTexts(
            FilesView(runtime: runtime(on: on))
                .environment(\.demoRedaction, mask(on: on))
                .frame(width: 1_440, height: 2_600)
        )
    }

    private static func timelinePage(on: Bool) async -> [String] {
        await A11yTree.renderedTexts(
            TimelineView(runtime: runtime(on: on))
                .environment(\.demoRedaction, mask(on: on))
                .frame(width: 1_440, height: 2_600)
        )
    }

    // MARK: - 文件页

    @Test("反向探针：关掉映射时，文件页整棵树上必须看得见真实家目录（否则正向那条是空的）")
    func filesPageShowsTheHomeWhenTheSwitchIsOff() async {
        let texts = await Self.filesPage(on: false)
        #expect(texts.count >= 20, "只从无障碍树收到 \(texts.count) 段文本 ⇒ 树没走通，这套机器是空的")
        #expect(texts.contains { $0.contains(Self.home) },
                "关掉映射后整页没有一处带 \(Self.home) ⇒ 夹具没喂到屏上，正向判据作废：\n\(texts)")
    }

    @Test("开启映射：文件页**全部**含路径的格子里一个真实家目录都不许有")
    func filesPageCarriesNoHomeWhenTheSwitchIsOn() async {
        let texts = await Self.filesPage(on: true)
        let leaks = texts.filter { $0.contains(Self.home) }
        let report = leaks.joined(separator: "\n---\n")
        // 正向判据也要**看得见内容**：只断言"不含家目录"的话，
        // 页面没渲染出行来也算通过（那正是 #61 那批逐格断言的空转形状）。
        #expect(texts.contains { $0.contains("README.md") },
                "整页里没有一行 README.md ⇒ 这一页根本没渲染，下面的『不含家目录』是空的")
        #expect(leaks.isEmpty, "开着开关，文件页仍有 \(leaks.count) 格带真实家目录：\n\(report)")
    }

    // MARK: - 时间线页（行 + 详情面板两条出口）

    @Test("反向探针：关掉映射时，时间线页也必须有格子带真实家目录")
    func timelineShowsTheHomeWhenOff() async {
        let texts = await Self.timelinePage(on: false)
        #expect(texts.count >= 12, "只收到 \(texts.count) 段 ⇒ 树没走通")
        #expect(texts.contains { $0.contains(Self.home) },
                "关掉映射仍看不见家目录 ⇒ 正向判据是空的：\n\(texts.joined(separator: "\n"))")
    }

    @Test("开启映射：时间线页整棵树不含真实家目录")
    func timelineCarriesNoHomeWhenOn() async {
        let texts = await Self.timelinePage(on: true)
        #expect(texts.contains { $0.contains("README.md") },
                "时间线页没渲染出内容行 ⇒ 正向判据是空的：\n\(texts.joined(separator: "\n"))")
        let leaks = texts.filter { $0.contains(Self.home) }
        let report = leaks.joined(separator: "\n---\n")
        #expect(leaks.isEmpty, "时间线页仍有 \(leaks.count) 格漏：\n\(report)")
    }

    @Test("详情面板（`.help`、VoiceOver 与复制出去的那一份）单独走一遍树")
    func detailPanelCarriesNoHomeWhenOn() async {
        let event = Self.events()[0]
        let on = await A11yTree.renderedTexts(
            TimelineEventDetail(event: event)
                .environment(\.demoRedaction, Self.mask(on: true))
                .frame(width: 900, height: 1_200),
            minCount: 6, settle: 4
        )
        let off = await A11yTree.renderedTexts(
            TimelineEventDetail(event: event)
                .environment(\.demoRedaction, .off)
                .frame(width: 900, height: 1_200),
            minCount: 6, settle: 4
        )
        #expect(off.contains { $0.contains(Self.home) },
                "详情面板关掉映射时看不见家目录 ⇒ 这一页没吃到路径：\n\(off.joined(separator: "\n"))")
        let leaks = on.filter { $0.contains(Self.home) }
        let report = leaks.joined(separator: "\n---\n")
        #expect(leaks.isEmpty, "详情面板漏 \(leaks.count) 格：\n\(report)")
    }

}
