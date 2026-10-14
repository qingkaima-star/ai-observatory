//
//  MonitoringScopeTests.swift
//  AIObservatoryEngineTests
//
//  Owner: master-controller（ICR-0006 采集面实况）
//  ─────────────────────────────────────────────────────────
//  钉住两件事：
//   1. 界面拿到的"剔除了哪条、为什么"与 watcher 拿到的根**出自同一次解析**
//      （`resolve()` 已退化成 `resolveScope().keptRoots` 的薄壳，规则只有一份）；
//   2. 每个 `Reason` case 都对应解析里一条**真能走到**的分支——
//      不许留一个"界面上永远显示不到"的原因档位（那正是本仓最常见的死契约）。
//

import Foundation
import Testing
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryTestSupport

@Suite("引擎: 采集面实况（ICR-0006）", .timeLimit(.minutes(1)))
struct MonitoringScopeTests {

    private func agent(cwd: String) -> AgentInstance {
        AgentInstance(
            kind: .claudeCode,
            pid: 42_424,
            displayName: "Claude Code",
            executablePath: "/usr/local/bin/claude",
            workingDirectory: cwd,
            startedAt: Date(timeIntervalSince1970: 1_800_000_000),
            lastSeenAt: Date(timeIntervalSince1970: 1_800_000_000),
            state: .running,
            detectedVia: .processName
        )
    }

    @Test("受保护的显式根：既不进 kept，也在 dropped 里指名道姓")
    func protectedExplicitRootIsReported() {
        let resolver = MonitoringRootResolver()
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let scope = resolver.resolveScope(
            explicit: ["/", home, "/repo/AiX"], agents: [],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        // 手推字面量：只有第三个是能用的根。
        #expect(scope.keptRoots == ["/repo/AiX"])
        #expect(scope.dropped.map(\.reason) == [.protectedRoot, .protectedRoot],
                "两条受保护根都要报出来，实际 \(String(describing: scope.dropped.map(\.reason)))")
        #expect(scope.dropped.map(\.path) == ["/", home])
    }

    @Test("空白的显式根报 emptyPath，而不是被静默吃掉")
    func blankExplicitRootIsReported() {
        let scope = MonitoringRootResolver().resolveScope(
            explicit: ["   "], agents: [],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(scope.keptRoots.isEmpty)
        #expect(scope.dropped.count == 1)
        #expect(scope.dropped.first?.reason == .emptyPath)
    }

    @Test("推导根命中忽略规则时，把**具体哪条规则**一起交出来")
    func ignoredDerivedRootCarriesTheMatchingRule() {
        let resolver = MonitoringRootResolver(ignoredPathPatterns: ["/secret/**"])
        let scope = resolver.resolveScope(
            explicit: [], agents: [agent(cwd: "/secret/project")],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        #expect(scope.keptRoots.isEmpty)
        #expect(scope.dropped.first?.reason == .matchedIgnoredPattern)
        // 只说"被忽略规则排除"用户无从知道自己配错了哪一条 ⇒ 规则本身必须在。
        #expect(scope.dropped.first?.matchedRule == "/secret/**")
    }

    @Test("`resolve()` 与 `resolveScope().keptRoots` 永远同值（规则只有一份实现）")
    func thinShellAgreesWithScope() {
        let resolver = MonitoringRootResolver(ignoredPathPatterns: ["/skip/**"])
        let agents = [agent(cwd: "/repo/alpha"), agent(cwd: "/skip/beta"), agent(cwd: "/")]
        let explicit = ["/", "/repo/alpha", "/projects/x"]
        #expect(
            resolver.resolve(explicit: explicit, agents: agents)
                == resolver.resolveScope(explicit: explicit, agents: agents, now: Date()).keptRoots
        )
    }

    @Test("引擎在跑过一轮文件观测之前不谎报采集面")
    func engineReportsNilUntilFirstResolution() async {
        let engine = ObservatoryEngine(settings: ObservatorySettings(storeDirectory: ""))
        // 没有 Agent、也没跑过 tick ⇒ 界面此时只许说"尚无采集面读数"，
        // 不许推断成"用户没配监控根"（那是两件事）。
        #expect(await engine.currentMonitoringScope() == nil)
    }
}
