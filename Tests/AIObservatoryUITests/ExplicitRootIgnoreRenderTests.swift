//
//  ExplicitRootIgnoreRenderTests.swift
//  AIObservatoryUITests
//
//  Owner: ws-engaudit（#45 的跨组件那一半）
//  ─────────────────────────────────────────────────────────
//  为什么单独一个文件、为什么放在这个 target：
//  `CaptureAvailabilityTests`（WS-UI 的）里已经有一条 `.matchedIgnoredPattern` 的文案用例，
//  但它喂的是**手搭**的 `MonitoringScope.Dropped` —— 于是它从写下来那天就一直绿，
//  而产品里从来没长出过这一条（显式配置的根压根不过忽略规则）。这正是本仓反复吃的
//  「函数绿、链路没接」。⇒ 这条用例走完整程：
//      真引擎（`MonitoringRootResolver.resolveScope`）→ 真界面口径（`CaptureScope.coverageLine(language: .chineseSimplified)`）
//  断言总控那组 fixture 在屏上那一行里的实际样子。
//
//  ⚠️ 构建面知情：本 target 在 `Package.swift` 里声明的依赖只有
//  [AIObservatoryUI, AIObservatoryCore, AIObservatoryTestSupport]，**没有** AIObservatoryEngine；
//  现在 import 得到是因为 SwiftPM 把所有模块放进同一个 `.build` 搜索路径。
//  要长期依赖请在冻结区的 Package.swift 给本 target 补那一行；
//  若哪天布局收紧导致 `no such module`，请把这条用例搬进一个同时声明两侧依赖的 target——
//  **不要因为编不动就删掉它**（删了就又回到"只有手搭的用例在绿"那个状态）。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryEngine

@MainActor
@Suite("跨组件：引擎剔除的忽略根，文件页那一行真的点得名")
struct ExplicitRootIgnoreRenderTests {

    private static let resolvedAt = Date(timeIntervalSince1970: 1_800_006_500)

    /// 总控复现现场的同一组 fixture（绝对路径换成合成主体，规则一字未改）。
    private static let patterns = ["**/node_modules", "**/build"]
    private static let explicitRoots = ["/", "   ", "/p/node_modules", "/p/build", "/p"]

    @Test("引擎产出的实况喂进界面口径 ⇒ 那一行点名「命中忽略规则：**/node_modules」")
    func engineOutputReachesTheCoverageLine() {
        let live = MonitoringRootResolver(ignoredPathPatterns: Self.patterns).resolveScope(
            explicit: Self.explicitRoots, agents: [], now: Self.resolvedAt
        )
        // 引擎侧先自证一遍（不然界面那段绿可能是因为 fixture 变了而不是链路接上）。
        #expect(live.keptRoots == ["/p"], "keptRoots 里还留着命中忽略规则的根：\(live.keptRoots)")

        let line = CaptureScope(
            live: MonitoringScope(keptRoots: live.keptRoots, dropped: live.dropped,
                                  resolvedAt: Self.resolvedAt),
            rangeName: "全部"
        ).coverageLine(language: .chineseSimplified)

        #expect(line.contains("/p/node_modules（命中忽略规则：**/node_modules）"),
                "文件页那一行没把这条根连同它命中的规则一起点出来：\(line)")
        #expect(line.contains("正在监控 1 个根 · 剔除 4 条"),
                "计数不应对上（改前是「正在监控 4 个根」）：\(line)")
        // 被剔除的根不许同时出现在"正在监控"那一侧。
        #expect(!line.contains("正在监控 4 个根"))
        // 第 4 条超出界面内联点名上限（droppedInlineLimit = 3），必须落成「另 1 条」而不是消失。
        #expect(line.contains("另 1 条"), "五条里有几条被省略时必须说出来：\(line)")
    }

    @Test("链路是双向的：没有忽略规则时，那一行不说任何「命中忽略规则」")
    func noPatternsMeansNoClaim() {
        let live = MonitoringRootResolver(ignoredPathPatterns: []).resolveScope(
            explicit: Self.explicitRoots, agents: [], now: Self.resolvedAt
        )
        let line = CaptureScope(
            live: MonitoringScope(keptRoots: live.keptRoots, dropped: live.dropped,
                                  resolvedAt: Self.resolvedAt),
            rangeName: "全部"
        ).coverageLine(language: .chineseSimplified)
        #expect(!line.contains("命中忽略规则"), "规则表是空的却报命中：\(line)")
        #expect(line.contains("正在监控 3 个根 · 剔除 2 条"), "没规则时应退回改前的形状：只剔 / 与空白，实得：\(line)")
    }
}
