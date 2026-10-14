//
//  PageEnumerationTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-exitlist（#89 ②「整页枚举 + 反向探针」）
//  ─────────────────────────────────────────────────────────
//  `RenderedPageRedactionTests`（#64）已经走了一遍文件页与时间线页，但那份夹具**造不出**
//  #89 ② 那一族：没有 `.renamed` 变更（所以「从 /Users/…」那句从没上过屏）、
//  没有"命令行里带家目录"的命令记录（所以命令页与详情页那一族从没被测过）。
//  **夹具的形状就是覆盖面**——这就是把五页重新走一遍、并把缺的形状补上的理由。
//
//  两把尺，每页都配一对：
//   · 正向：开着映射 ⇒ 整棵无障碍树里一个真实家目录都不许有；
//   · 反向：关掉映射 ⇒ 同一棵树里**必须**看得见真实家目录（看不见 = 这一页压根没吃到路径，
//     那正向那条是空的，必须一起作废）。
//
//  ⚠️ 只做「包含 / 不包含」的断言，不数格子：跨套件的窗口会互相污染（本仓实测 1 格 vs 33 格），
//  数量断言只会带来假红。
//  ⚠️ 不点击、不翻页、不拍图（需求方 09-23 硬令）：这里的"页"是把那一页的根视图直接装进
//  测试窗口渲染的，选中态走模型 API（`FilesModel.select(_:)`），不走鼠标。
//

import Testing
import Foundation
import SwiftUI
@testable import AIObservatoryCore
@testable import AIObservatoryUI
import AIObservatoryTestSupport

@MainActor
@Suite("UI: #89 整页枚举（真无障碍树）· 五页 + 补上的夹具形状", .serialized)
struct PageEnumerationTests {

    private static var home: String { NSHomeDirectory() }
    private static var projectRoot: String { "\(home)/Documents/AiX" }

    /// 关闭那一臂必须是 `.off`（恒等）。写成"只去掉项目根"会让"关掉"仍然遮着家目录，
    /// 反向探针当场失去意义（本单第一版就踩了这一下，是反向探针自己把它报出来的）。
    private static func mask(on: Bool) -> PathPrivacy.Mask {
        on ? PathPrivacy.Mask(home: home, projectRoots: [projectRoot]) : .off
    }

    private static func settings(on: Bool) -> ObservatorySettings {
        ObservatorySettings(monitoredRoots: [projectRoot], demoRedactedOutput: on)
    }

    /// 夹具形状是这一支的重点：每一类记录都至少有一条把真实家目录写在**句中**或**参数里**。
    private static func host() -> InMemoryObservatoryService {
        let host = InMemoryObservatoryService()
        let renamed = FileChange(path: "\(projectRoot)/Sources/Renamed.swift",
                                 previousPath: "\(home)/Documents/Legacy/OldName.swift",
                                 kind: .renamed, timestamp: Date(), agentKind: .claudeCode)
        let plain = FileChange(path: "\(projectRoot)/README.md", kind: .modified,
                               timestamp: Date(), agentKind: .claudeCode,
                               linesAdded: 3, linesRemoved: 1)
        host.seed(
            sessions: [AgentSession(kind: .claudeCode, title: "改重命名",
                                    projectPath: projectRoot, startedAt: Date(),
                                    modifiedFileCount: 2, commandCount: 2)],
            events: [
                TimelineEvent(timestamp: Date(), agentKind: .claudeCode, kind: .commandExecuted,
                              title: "执行 cat \(home)/.ssh/id_ed25519",
                              summary: "原路径 \(home)/.ssh",
                              command: "cat \(home)/.ssh/id_ed25519",
                              projectPath: home),
            ],
            fileChanges: [plain, renamed],
            commands: [
                CommandRecord(executable: "cat", arguments: ["\(home)/.ssh/id_ed25519"],
                              workingDirectory: home, agentKind: .claudeCode,
                              startedAt: Date(), outcome: .success, projectPath: projectRoot),
                CommandRecord(executable: "rm", arguments: ["-rf", "\(home)/Documents/Secrets"],
                              workingDirectory: projectRoot, agentKind: .openAICodex,
                              startedAt: Date(), outcome: .success, isDestructive: true,
                              projectPath: projectRoot),
            ],
            risks: [
                RiskEvent(timestamp: Date(), level: .high, category: .dangerousCommand,
                          title: "Agent 执行了高风险删除命令",
                          detail: "命令命中破坏性规则，目标 \(home)/Documents/Secrets",
                          agentKind: .claudeCode,
                          command: "rm -rf \(home)/Documents/Secrets",
                          filePaths: ["\(home)/Documents/Secrets"], matchedRuleID: "R-004"),
            ],
            projects: [ProjectActivity(id: projectRoot, name: "AiX", path: projectRoot,
                                       fileChangeCount: 2, commandCount: 2, sessionCount: 1)]
        )
        return host
    }

    private static func runtime(on: Bool) -> ObservatoryRuntime {
        let host = host()
        return ObservatoryRuntime(service: host, controller: host, updates: host,
                                  settings: settings(on: on))
    }

    /// 一页 = 一个名字 + 一个造视图的闭包 + 一个「这一页真的渲染了」的内容守卫字面量。
    private struct Page {
        let name: String
        let marker: String
        let make: @MainActor (Bool) -> AnyView
    }

    private static let pages: [Page] = [
        Page(name: "文件页", marker: "README.md") { on in
            AnyView(FilesView(runtime: runtime(on: on)))
        },
        Page(name: "命令页", marker: "id_ed25519") { on in
            AnyView(CommandsView(runtime: runtime(on: on)))
        },
        Page(name: "会话页", marker: "改重命名") { on in
            AnyView(SessionsView(runtime: runtime(on: on)))
        },
        Page(name: "项目页", marker: "AiX") { on in
            AnyView(ProjectsView(runtime: runtime(on: on)))
        },
        Page(name: "安全页", marker: "高风险删除命令") { on in
            AnyView(SecurityView(runtime: runtime(on: on)))
        },
    ]

    private static func render(_ page: Page, on: Bool) async -> [String] {
        await A11yTree.renderedTexts(
            page.make(on).environment(\.demoRedaction, mask(on: on))
                .frame(width: 1_440, height: 2_600),
            minCount: 6, settle: 10, probe: page.marker)
    }

    // MARK: 五页整页枚举

    @Test("反向探针：关掉映射时，每一页的树里都必须看得见真实家目录（否则正向是空的）")
    func everyPageShowsTheHomeWhenTheSwitchIsOff() async {
        var failures: [String] = []
        for page in Self.pages {
            let texts = await Self.render(page, on: false)
            if !texts.contains(where: { $0.contains(Self.home) }) {
                failures.append("\(page.name)：关掉映射仍看不见 \(Self.home)"
                                + "（渲染出 \(texts.count) 段，其中含 \(page.marker) 吗："
                                + "\(texts.contains { $0.contains(page.marker) })")
            }
        }
        #expect(failures.isEmpty, "夹具没喂到屏上的页：\n\(failures.joined(separator: "\n"))")
    }

    @Test("开启映射：五页的整棵树都不许有真实家目录，且每页确实渲染出了内容行")
    func everyPageHidesTheHomeWhenTheSwitchIsOn() async {
        var failures: [String] = []
        for page in Self.pages {
            let texts = await Self.render(page, on: true)
            // 内容守卫：这一页真的渲染出了带路径的那一格，"不含家目录"才不是空的。
            if !texts.contains(where: { $0.contains(page.marker) }) {
                failures.append("\(page.name)：整页没有一行含「\(page.marker)」⇒ 正向判据是空的")
            }
            let leaks = texts.filter { $0.contains(Self.home) }
            if !leaks.isEmpty {
                failures.append("\(page.name)：仍有 \(leaks.count) 格带真实家目录：\n\(leaks.joined(separator: "\n"))")
            }
        }
        #expect(failures.isEmpty, "整页枚举有页不合格：\(failures.joined(separator: "\n——\n"))")
    }

    // MARK: ② 那一族：整句拼进本地化文案、不经过 FilePathText

    /// 「从 /Users/… 重命名而来」这一句只有选中一条 `.renamed` 变更才渲染，
    /// 而 #64 那份夹具里根本没有 `.renamed` 行 ⇒ 它从来没上过屏，也就从来没被测过。
    @Test("重命名那句「从 …」（整句拼进本地化文案）：关掉看得见原文、开着只剩占位符")
    func renamedPreviousPathIsMasked() async {
        let onModel = FilesModel(runtime: Self.runtime(on: true))
        await onModel.load()
        let renamed = onModel.changes.first { $0.kind == .renamed }
        #expect(renamed != nil, "夹具里的 .renamed 变更没被加载出来 ⇒ 这一支测不到东西")
        if let renamed {
            await onModel.select(renamed)
            let on = await A11yTree.renderedTexts(
                DiffView(model: onModel).environment(\.demoRedaction, Self.mask(on: true))
                    .frame(width: 1_100, height: 900),
                minCount: 3, settle: 4)
            #expect(on.contains { $0.contains("OldName.swift") || $0.contains("Renamed.swift") },
                    "Diff 面板没渲染出重命名那一格 ⇒ 正向判据是空的：\n\(on)")
            let leaks = on.filter { $0.contains(Self.home) }
            #expect(leaks.isEmpty, "开着映射，「从 …」那一句仍带真实路径：\n\(leaks)")

            // 反向：同一份模型、映射关闭 ⇒ 原文必须在。
            let offModel = FilesModel(runtime: Self.runtime(on: false))
            await offModel.load()
            if let same = offModel.changes.first(where: { $0.kind == .renamed }) {
                await offModel.select(same)
            }
            let off = await A11yTree.renderedTexts(
                DiffView(model: offModel).environment(\.demoRedaction, .off)
                    .frame(width: 1_100, height: 900),
                minCount: 3, settle: 4)
            #expect(off.contains { $0.contains("\(Self.home)/Documents/Legacy/OldName.swift") },
                    "关掉映射时「从 …」那句读不到原文 ⇒ 这一格根本没吃到 previousPath：\n\(off)")
        }
    }
}
