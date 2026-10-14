//
//  ExplicitRootIgnoreScopeTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws-engaudit（#45，总控真机取证抓到）
//
//  先判性质（总控要求"判性质再改"，两条路结论完全不同）：
//
//  (a) **不成立**：`PatternMatcher` 的 `**/x` 匹得到目录本身。它是不管路径分隔符的
//      字符级通配（`*` 会跨过 `/`），所以 `**/node_modules` 对 `/p/node_modules`
//      恰好收尾命中。本文件第 1 条用例就是把这句话变成可执行事实（顺便钉住它**不**匹
//      `/p/node_modules-x`，免得我拿"能匹目录"当许可证去多丢根）。
//      ⇒ 不是"这一支在界面上永远说不出来"，也就用不着删契约里的 reason。
//
//  (b) **成立，但要说准**：不是"根解析阶段压根不查忽略规则"，而是
//      `resolveScope` 只对**从 Agent cwd 推导出来的根**查，对用户在设置里**显式**配的根
//      一个字都没查（那一支只有 `emptyPath` 与 `protectedRoot` 两道，然后直接 keep）。
//      总控的复现现场与此完全吻合：5 条显式根里 `/` 与那条空白被点名了（那两道有实现），
//      两个命中忽略规则的根仍被算进"正在监控 4 个根"（那一道没实现）。
//      ⇒ 而显式根恰恰是最该查的那一侧：推导根命中忽略规则是意外，显式根是用户亲手写的，
//        写错才常见，也更需要一个点名式的解释。
//
//  修在 `ObservatoryEngine.resolveScope` 的显式分支，与推导支同一出口（同 reason、
//  并报出命中的那条规则本身）。跨组件那半（引擎产出 → 界面读到）在
//  `Tests/AIObservatoryUITests/ExplicitRootIgnoreRenderTests.swift`——本仓已经吃过好几次
//  「函数绿、链路没接」，`CaptureAvailabilityTests` 里那条 `.matchedIgnoredPattern` 用例
//  就是**手搭**的 Dropped，所以它一直绿着而产品里从来没长出过这一条。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryEngine

private let scopeNow = Date(timeIntervalSince1970: 1_800_006_000)

@Suite("显式监控根也要过忽略规则（#45）", .timeLimit(.minutes(1)))
struct ExplicitRootIgnoreScopeTests {

    private static let patterns = ["**/node_modules", "**/build"]

    // MARK: - 性质 (a)：匹配语义没问题

    @Test("`**/node_modules` 匹得到目录本身（所以缺的不是匹配语义）")
    func globMatchesTheDirectoryItself() {
        #expect(PatternMatcher.matches(pattern: "**/node_modules", path: "/p/node_modules"))
        #expect(PatternMatcher.matches(pattern: "**/build", path: "/work/mono/build"))
        // 但也不是"前缀一沾就算"：尾巴对不上就不算。这条挡住我拿 (a) 的结论去多丢根。
        #expect(!PatternMatcher.matches(pattern: "**/node_modules", path: "/p/node_modules-x"))
        #expect(!PatternMatcher.matches(pattern: "**/node_modules", path: "/p/node_modules/x"))
    }

    // MARK: - 性质 (b)：显式分支真漏了

    @Test("总控那组 fixture：kept 只剩 `/p`，两条命中忽略规则的根被点名剔除")
    func explicitRootsConsultIgnorePatterns() {
        let resolver = MonitoringRootResolver(ignoredPathPatterns: Self.patterns)
        let scope = resolver.resolveScope(
            explicit: ["/", "   ", "/p/node_modules", "/p/build", "/p"],
            agents: [],
            now: scopeNow
        )

        #expect(scope.keptRoots == ["/p"], "只剩这一条该被监控，实得 \(scope.keptRoots)")
        // 手推：四条各一个原因，顺序与输入顺序一致（显式支不做排序，只按配置走）。
        #expect(scope.dropped.count == 4, "实得 \(scope.dropped.map(\.reason))")
        let ignored = scope.dropped.filter { $0.reason == .matchedIgnoredPattern }
        #expect(ignored.map(\.path) == ["/p/node_modules", "/p/build"])
        #expect(ignored.map(\.matchedRule) == ["**/node_modules", "**/build"],
                "必须报出**具体哪条规则**命中的，只说「被忽略规则排除」用户无从知道配错了哪一条")
    }

    @Test("反向守卫：没命中规则的显式根一条都不许被丢（修成「一律丢」会在这里红）")
    func nonMatchingExplicitRootsSurvive() {
        let resolver = MonitoringRootResolver(ignoredPathPatterns: Self.patterns)
        let scope = resolver.resolveScope(
            explicit: ["/work/src", "/work/docs"], agents: [], now: scopeNow
        )
        #expect(scope.keptRoots == ["/work/docs", "/work/src"], "实得 \(scope.keptRoots)")
        #expect(scope.dropped.isEmpty)
    }

    @Test("没有配忽略规则时：显式分支与改前逐字同结果（这次改动的影响面被规则表挡住）")
    func noPatternsMeansNoBehaviorChange() {
        let resolver = MonitoringRootResolver(ignoredPathPatterns: [])
        let scope = resolver.resolveScope(
            explicit: ["/p/node_modules", "/p"], agents: [], now: scopeNow
        )
        #expect(scope.keptRoots == ["/p", "/p/node_modules"].sorted(), "实得 \(scope.keptRoots)")
        #expect(scope.dropped.isEmpty)
    }

    /// 一条**没修**的边界，写下来而不是留成暗坑：本仓自己的 dogfood 配置
    /// （`ai-observatory/tmp/dogfood-0145/settings.json`）写的是 `**/node_modules/**`、`**/tmp/**`
    /// 这种**带尾部** 的形式，而字符级通配的 `/**` 要求目录后面还有东西 ⇒ 对"目录本身"不命中。
    /// ⇒ 用户按那种写法配忽略规则时，把 `<dir>/node_modules` 直接配成监控根仍然会被 keep。
    /// 这一支我**没改**：改 `PatternMatcher` 的语义（让 `/**` 也覆盖目录本身）会同时改掉
    /// **事件侧**的过滤口径（`ProjectMapper.isIgnored` / watcher 的 `ignoredPatterns` 共用它），
    /// 影响面远超 #45，且 `PatternMatcher` 在 `Core/Contracts/Formatting.swift`（冻结区）。
    /// ⇒ 交总控定：要么改匹配语义，要么在设置页把写法点明（推荐后者，成本低且不暗改判定）。
    @Test("已知边界：`**/x/**` 这种带尾写法匹不到目录本身（本用例记录未修，不是断言它正确）")
    func trailingSlashPatternDoesNotMatchTheDirectoryItself() {
        #expect(!PatternMatcher.matches(pattern: "**/node_modules/**", path: "/p/node_modules"))
        // 但它确实匹得到里面的文件——所以事件侧一直是生效的，缺的只是"根这一层"。
        #expect(PatternMatcher.matches(pattern: "**/node_modules/**", path: "/p/node_modules/a.js"))
        let resolver = MonitoringRootResolver(ignoredPathPatterns: ["**/node_modules/**"])
        let scope = resolver.resolveScope(explicit: ["/p/node_modules"], agents: [], now: scopeNow)
        #expect(scope.keptRoots == ["/p/node_modules"], "边界现状：带尾写法下这条根仍被监控")
        #expect(scope.dropped.isEmpty)
    }

    @Test("`resolve()` 与 `resolveScope().keptRoots` 仍然同值（规则只有一份，没开第二处口径）")
    func thinShellStaysEqual() {
        let resolver = MonitoringRootResolver(ignoredPathPatterns: Self.patterns)
        let explicit = ["/", "/p/node_modules", "/p/build", "/p"]
        #expect(resolver.resolve(explicit: explicit, agents: [])
                == resolver.resolveScope(explicit: explicit, agents: [], now: scopeNow).keptRoots)
    }

    @Test("显式支与推导支同一出口：同一条命中忽略规则的根，两条来源都给出同一个 reason + 规则")
    func bothBranchesReportTheSameWay() {
        let resolver = MonitoringRootResolver(ignoredPathPatterns: Self.patterns)
        let explicitOnly = resolver.resolveScope(
            explicit: ["/p/node_modules"], agents: [], now: scopeNow
        )
        let derivedOnly = resolver.resolveScope(
            explicit: [],
            agents: [AgentInstance(kind: .claudeCode, pid: 7_700, displayName: "Claude Code",
                                   executablePath: "/usr/local/bin/claude",
                                   workingDirectory: "/p/node_modules",
                                   startedAt: scopeNow, lastSeenAt: scopeNow)],
            now: scopeNow
        )
        #expect(explicitOnly.dropped.map(\.reason) == derivedOnly.dropped.map(\.reason),
                "两支的原因口径漂了：\(explicitOnly.dropped.map(\.reason)) vs \(derivedOnly.dropped.map(\.reason))")
        #expect(explicitOnly.dropped.first?.matchedRule == "**/node_modules")
        #expect(derivedOnly.dropped.first?.matchedRule == "**/node_modules")
        #expect(explicitOnly.keptRoots.isEmpty && derivedOnly.keptRoots.isEmpty)
    }
}
