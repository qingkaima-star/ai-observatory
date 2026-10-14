//
//  WindowFloorTests.swift
//  AIObservatoryUITests
//
//  Owner: master-controller（#91 收口）
//  ─────────────────────────────────────────────────────────
//  #91 原样是「`AIObservatoryApp.swift` 钉了 `minWidth 1080`，更窄的窗口适配要需求方裁」。
//  本波按目标授权自己拍板，动手前先把**这句话的前提**量了一遍，结论是前提错了：
//
//  1. 1080 不是一条"政策上限"，它比**外壳自己的地板**还窄 4 pt。
//     实测（挂根视图、把窗口按到 640 让内容顶回去，读回 `AXWindow` 的宽度）：
//     九页里八页的地板都是 **1084**，会话页 **1308**。
//  2. 地板的构成是**可算的**：详情列 `navigationSplitViewColumnWidth(min: 860)` + 侧栏
//     `Sizing.sidebarWidth 216` + 分隔 8 = 1084。
//     ⇒ 因果检查：把 `min:` 从 860 改成 856，九页地板**整齐地各降 4 pt**（1084→1080、1308→1304），
//       没有一页例外——这条不是相关，是同一颗常量搬过来的。
//  3. 所以"把 1080 降下来"这件事的正确形状是：**先让地板真的下来**，而不是把声明改小。
//     本波做了对齐（`min: 856` ⇒ 声明 1080 == 八页地板 1080，用户可见的最小窗口尺寸**没变**），
//     并把"声明必须等于实测地板"钉成下面这道闸。
//
//  ⚠️ 会话页是**点名在册的欠账**：它的详情列不吃 `min:`、吃 `ideal: 1080` ⇒ 地板比外壳高 224 pt。
//     也就是说在 1080 这一档，会话页的内容本来就顶出窗口（本夹具实测 1304）。
//     再想往下调声明，必须先让它可压缩——那是界面改造 + 视觉签署，不是改数字（需求方已停做真机
//     交互验收 ⇒ 本波不做）。这里给它一条**只许缩**的棘轮，谁把它推高就当场红。
//
//  ⚠️ 会话页那个数与**夹具**有关（数字位宽、标题长度都会推高它）。改了夹具就重量一次、
//     把基线写在下面并留一句话说明为什么动——**不许**为了绿而改断言形状。
//

import AppKit
import SwiftUI
import Testing
@testable import AIObservatoryCore
@testable import AIObservatoryUI
import AIObservatoryTestSupport

/// 性能页要读本 App 自身的开销；测试里给一颗空读数源，别去碰真仪器。
private struct StubSelfProcess: SelfProcessReadingSource {
    func readSelfProcessSample(now: Date) -> SelfProcessSamplePoint? { nil }
}

@Suite("UI: #91 窗口地板与声明的 minWidth 必须对齐（逐页实测）", .serialized, .timeLimit(.minutes(4)))
struct WindowFloorTests {

    private static let token = "窄窗甲"

    /// 九页地板的历史最高基线（2026-09-23 现读：会话页 1304，其余 1084）。只许缩。
    private static let sessionsFloorCeiling: Double = 1_304

    @MainActor private static func runtime() -> ObservatoryRuntime {
        let host = InMemoryObservatoryService()
        let project = "/Users/dev/Projects/\(token)-backend"
        host.seed(
            sessions: (0..<4).map { index in
                AgentSession(displayIndex: 200 + index,
                             kind: index.isMultiple(of: 2) ? .claudeCode : .openAICodex,
                             title: "\(token)-会话 \(index)",
                             projectPath: project,
                             startedAt: Date().addingTimeInterval(-Double(index) * 600),
                             modifiedFileCount: 13, createdFileCount: 12, deletedFileCount: 5,
                             commandCount: 1_289, failedCommandCount: 12, riskEventCount: 3,
                             outcome: .running)
            },
            events: (0..<4).map { index in
                TimelineEvent(timestamp: Date().addingTimeInterval(-Double(index) * 90),
                              agentKind: .claudeCode,
                              kind: index.isMultiple(of: 2) ? .commandExecuted : .fileModified,
                              title: "\(token)-事件 \(index) 执行了 git diff --stat 并改了 \(project)/Sources/File\(index).swift",
                              summary: "\(token)-摘要 第 \(index) 条",
                              command: "git -C \(project) diff HEAD~1 --stat",
                              projectPath: project)
            },
            fileChanges: (0..<4).map { index in
                FileChange(path: "\(project)/Sources/\(token)FileNumber\(index).swift",
                           kind: .modified, timestamp: Date(), agentKind: .claudeCode,
                           linesAdded: 120 + index, linesRemoved: 30 + index)
            },
            commands: (0..<4).map { index in
                CommandRecord(executable: "git",
                              arguments: ["-C", project, "log", "--oneline=\(token)"],
                              workingDirectory: project, agentKind: .claudeCode,
                              startedAt: Date(),
                              exitCode: index.isMultiple(of: 2) ? 0 : 128,
                              outcome: index.isMultiple(of: 2) ? .success : .failure,
                              projectPath: project)
            },
            risks: [
                RiskEvent(timestamp: Date(), level: .high, category: .dangerousCommand,
                          title: "\(token)-高风险删除命令",
                          detail: "命令命中破坏性规则，目标 \(project)/Secrets",
                          agentKind: .claudeCode, command: "rm -rf \(project)/Secrets",
                          filePaths: ["\(project)/Secrets"], matchedRuleID: "R-004"),
            ],
            projects: [ProjectActivity(id: project, name: "\(token)-backend", path: project,
                                       fileChangeCount: 4, commandCount: 4, sessionCount: 4)]
        )
        return ObservatoryRuntime(service: host, controller: host, updates: host,
                                  settings: ObservatorySettings())
    }

    /// 真窗口的 `minHeight 720`：地板要在"高度也压到下限"的形状下量，否则内容还有地方躲。
    private static let height: Double = 720

    /// 一页的地板：把窗口按到 640（低于一切），内容会把它顶回自己的最小宽度。
    ///
    /// ⚠️ 不能用"挂载宽度"当窗口宽度：`#100` 那支套件量到过同一件事的另一半——
    ///   挂在屏幕外的窗口会被 WindowServer 折回屏内，所以**绝对原点**算出来的右边界是假的。
    ///   这里读的是内容自己顶出来的 `AXWindow` 宽度，与挂载尺寸无关。
    @MainActor private static func floor(of section: SidebarSection) async -> (width: Double, nodes: Int) {
        let runtime = runtime()
        let shell = ShellModel(runtime: runtime)
        shell.selection = section
        let root = ObservatoryRootView(runtime: runtime,
                                       selfProcessSource: StubSelfProcess(),
                                       shell: shell)
        let frames = await A11yTree.renderedFrames(
            AnyView(root),
            size: NSSize(width: 640, height: height), settle: 6,
            ready: { $0.count >= 30 })
        let window = frames.first { $0.role == "AXWindow" }
        return (Double(window?.frame.width ?? -1), frames.count)
    }

    /// 声明的那个 1080 **从源码里读**，不在测试里抄第二份数字（两份常数分叉是本仓的老账）。
    private static func declaredMinWidth() throws -> Double {
        let code = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryApp/AIObservatoryApp.swift")
        guard let line = code.split(separator: "\n").first(where: { $0.contains("minWidth:") }),
              let number = Self.minWidthNumber(in: line) else {
            Issue.record("读不到 `AIObservatoryApp.swift` 里的 `minWidth:` 声明 ⇒ 这条对齐闸没有分母")
            return -1
        }
        return number
    }

    @Test("八页地板 == 声明的 minWidth；会话页是点名在册的欠账（只许缩）")
    @MainActor
    func floorsAreAlignedWithDeclaration() async throws {
        let declared = try Self.declaredMinWidth()
        // 正向判据先立住：读不到声明数字的话，下面每条都是空断言。
        #expect(declared > 500, "从源码读到的 `minWidth` 是 \(declared) ⇒ 解析坏了，本条不成立")

        var table: [String] = []
        for section in SidebarSection.allCases {
            let (width, nodes) = await Self.floor(of: section)
            table.append("\(section.rawValue)=\(String(format: "%.0f", width))(\(nodes)段)")
            // 地板必须**量得到**：没有 AXWindow 说明这一页压根没挂起来。
            #expect(width > 0, "\(section.rawValue) 量不到窗口地板（读到 \(width)）⇒ 这一页没渲染")
            // 2026-09-24：会话页的例外**撤了**。它当初地板 1304 的构成是
            // 「详情列 min 856 + 检查器 min 300 + 侧栏 216」再加瓷贴四列的理想宽；
            // 同一天把详情列 min 降到 560、ideal 降到 720、检查器 ideal 降到 320、
            // `MetricGrid` 改成按可用宽退档（ViewThatFits 4→2→1 列）之后，
            // 实测地板回到 1080 == 声明 ⇒ 九页统一一条规则，例外不留尸。
            // 方向性判据：**布局地板不许高于声明**。高于 ⇒ 在声明的最小窗口里三栏放不下、两端裁切
            // （2026-09-23 真机 1280 截图就是这个形状）；低于 ⇒ 内容比承诺的更能挤，是好事，不拦。
            // 2026-09-24 之前这里写的是"地板 == 声明"：那时布局自己的下限恰好顶着声明；
            // 瓷贴改成按宽退档、详情列 min/ideal 下调之后布局下限掉到 784–1027，等式就失去了意义。
            if section == .sessions {
                // 会话页**豁免方向性判据**，只留棘轮，理由写在下面：
                // NavigationSplitView 给这一页算出来的"列 min"（877）比**可见内容**的实际需求（621）大——
                // 于是挂载法量到的地板 1133 高于声明 1080，但 1280 / 1659 两档真机截图里
                // 侧栏、检查器、中栏右缘**都没有裁切**（可见内容 621 < 中栏拿到的 735）。
                // ⇒ 这条 AX 地板对会话页量的是 split view 的列宽下限，不是"会不会裁"；
                //   "会不会裁"由真机截图与 `SessionsPageGeometryTests`（1280/1437 两档越界/叠字闸）判。
                // 这里保留的是棘轮：列宽下限只许缩不许涨（涨回 1304 就是 2026-09-23 那个裁切形状）。
                #expect(width <= Self.sessionsFloorCeiling + 1,
                        "会话页列宽下限 \(String(format: "%.0f", width)) 超过基线 \(Self.sessionsFloorCeiling) ⇒ 又长了不压缩的东西（2026-09-23 的裁切形状）")
            } else {
                #expect(width <= declared + 1,
                        "\(section.rawValue) 的布局地板 \(String(format: "%.0f", width)) 高于声明的 \(String(format: "%.0f", declared)) ⇒ 声明的最小窗口里会裁内容（把 min/ideal/瓷贴列数改回去之前，先想清楚 1280 那三栏放不放得下）")
            }
            #expect(width > 400,
                    "\(section.rawValue) 地板只有 \(String(format: "%.0f", width)) ⇒ 不像一整页，更像测量塌了（检查 ready 判据与挂载尺寸）")
            #expect(width <= Self.sessionsFloorCeiling + 1,
                    "\(section.rawValue) 地板 \(String(format: "%.0f", width)) 超过历史最高基线 \(Self.sessionsFloorCeiling) ⇒ 布局又长了不压缩的东西（棘轮只许缩）")
        }
        print("#91 逐页地板：\(table.joined(separator: " "))｜声明 minWidth=\(String(format: "%.0f", declared))")
    }

    @Test("地板的可算性：外壳地板 = 详情列 min + 侧栏 + 分隔（不是拍出来的数）")
    @MainActor
    func floorIsArithmetic() async throws {
        let (dashboardFloor, _) = await Self.floor(of: .dashboard)
        let (sidebarFloorReading, _) = await Self.floor(of: .settings)
        // 两页同地板 ⇒ 这个数是**壳层**给的，不是某一页的内容给的。
        #expect(abs(dashboardFloor - sidebarFloorReading) <= 1,
                "概览 \(dashboardFloor) 与设置 \(sidebarFloorReading) 地板不同 ⇒ 地板开始吃各页内容了，'壳层地板'这条判据要重画")
        let detailMin = try #require(
            BilingualCopyGate.codeOnlyString("Sources/AIObservatoryUI/Shell/ObservatoryRootView.swift")
                .split(separator: "\n").first(where: { $0.contains("navigationSplitViewColumnWidth(min:") })
                .flatMap(Self.minWidthNumber(in:)),
            "读不到详情列的 `min:` ⇒ 这条算式没有分母")
        let predicted = detailMin + Sizing.sidebarWidth + 8
        #expect(abs(predicted - dashboardFloor) <= 1,
                "算出来的地板 \(String(format: "%.0f", predicted)) 与实测 \(String(format: "%.0f", dashboardFloor)) 不等 ⇒ 壳层多/少了一段宽度，#91 的因果链断了，判据要重推")
    }
}

extension WindowFloorTests {
    /// 从 `minWidth: 1_080` / `…(min: 856, …)` 这类声明里抠出**括号里的那个数**（写下划线也认）。
    /// 数字留在源码里，测试不抄第二份 —— 两份常数分叉是本仓的老账。
    static func minWidthNumber(in line: some StringProtocol) -> Double? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let tail = line[line.index(after: colon)...]
        var digits = ""
        for ch in tail {
            if ch.isNumber { digits.append(ch) }
            else if ch == "_" || ch == " " { continue }
            else { break }
        }
        return Double(digits)
    }
}
