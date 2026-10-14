//
//  CaptureAvailabilityTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · P1 界面不许替未实现的功能编理由）
//  ─────────────────────────────────────────────────────────
//  钉住文件页那句「为什么是空的」。缺陷形状：采集侧把一条监控根判为不可用就静默跳过，
//  界面只说「还没有文件变更」⇒ 用户读到「这个 Agent 没动过文件」，而真相是「我没看到」。
//
//  ICR-0006 落地（`d1139af`，方案 A）之后实况拿得到，所以断言分三层：
//    · 值本身：`coverageLine` 每一段都手推字面量；
//    · 总控那三条硬约束：`nil` 不许写成「没配根」、原因一律走契约 `displayName`
//      （不为不可达的 `shadowedByShallowerRoot` 写专门文案）、UI 不许再读 `runtime.settings` 拼实况；
//    · 接线：视图读口径、模型真的去取读数——口径写得再对，没人调用就是零。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryTestSupport

@MainActor
@Suite("UI: 文件页的采集面实况与空态口径", .timeLimit(.minutes(1)))
struct CaptureAvailabilityTests {

    /// 固定时刻（不依赖宿主时钟）。时间段用产品自己的 formatter 反推，其余每段都是手推字面量。
    private static let resolvedAt = Date(timeIntervalSince1970: 1_800_000_000)

    private static var resolvedTail: String {
        " · 实况于 \(DateFormat.time(CaptureAvailabilityTests.resolvedAt)) 解析"
    }

    private func live(
        kept: [String],
        dropped: [MonitoringScope.Dropped] = []
    ) -> MonitoringScope {
        MonitoringScope(keptRoots: kept, dropped: dropped, resolvedAt: Self.resolvedAt)
    }

    // MARK: ① 没有读数那一档

    @Test("读数为 nil ⇒ 只说「尚无采集面读数」，一个字都不许指向用户的配置")
    func missingReadingNeverBlamesTheConfig() {
        let line = CaptureScope(live: nil, rangeName: "全部").coverageLine(language: .chineseSimplified)
        #expect(line == "采集面：尚无采集面读数（引擎还没解析过任何一轮） · 本页范围 全部")
        // 「没配监控根」与「引擎还没解析过」是两件事：宿主没装配、刚启动、还没跑完第一轮，
        // 都落在 nil。把它们说成用户的配置问题，就是替没发生的事编理由。
        for forbidden in ["未配置", "没配", "没有配置", "0 个根", "监控范围为空"] {
            #expect(!line.contains(forbidden), "nil 那一档写出了「\(forbidden)」：\(line)")
        }
    }

    @Test("读到 0 个根 ⇒ 如实报 0，不许退化成「尚无读数」")
    func zeroKeptRootsIsReportedAsZero() {
        // ① 的反方向：真拿到「一个根都没保住」的实况，就不能躲进"没读数"那一档，
        // 否则最该看见的一次（全部被剔除）反而没有声音。
        let line = CaptureScope(live: live(kept: []), rangeName: "今天").coverageLine(language: .chineseSimplified)
        #expect(line == "采集面：正在监控 0 个根 · 剔除 0 条 · 本页范围 今天" + Self.resolvedTail)
        #expect(!line.contains("尚无采集面读数"))
    }

    // MARK: ② 实况那一行

    @Test("正在监控 N 个根 + 剔除清单逐条点名 = 手推字面量")
    func keptAndDroppedReadVerbatim() {
        let scope = CaptureScope(
            live: live(
                kept: ["/Users/demo/Projects/Mona", "/Users/demo/Projects/AiX", "/Users/demo/Notes"],
                dropped: [.init(path: "/Users/demo", reason: .protectedRoot)]
            ),
            rangeName: "今天"
        )
        #expect(scope.coverageLine(language: .chineseSimplified)
            == "采集面：正在监控 3 个根 · 剔除 1 条：/Users/demo（过浅：受保护根） · 本页范围 今天"
            + Self.resolvedTail)
    }

    @Test("命中忽略规则那条要把规则本身带出来，不是只说「命中规则」")
    func ignoredPatternCarriesItsRule() {
        let line = CaptureScope(
            live: live(kept: ["/p"], dropped: [
                .init(path: "/p/web", reason: .matchedIgnoredPattern, matchedRule: "*/node_modules/*"),
            ]),
            rangeName: "全部"
        ).coverageLine(language: .chineseSimplified)
        #expect(line.contains("剔除 1 条：/p/web（命中忽略规则：*/node_modules/*）"))
    }

    @Test("没有剔除时也要写「剔除 0 条」——省略会被读成「这一栏没统计」")
    func emptyDropListStillReportsZero() {
        let line = CaptureScope(live: live(kept: ["/a", "/b"]), rangeName: "全部").coverageLine(language: .chineseSimplified)
        #expect(line.contains("正在监控 2 个根 · 剔除 0 条 ·"))
    }

    @Test("剔除清单超过 3 条：只点名前 3 条，但总数报全（不藏数）")
    func longDropListIsCappedButCounted() {
        let dropped = (1...5).map { MonitoringScope.Dropped(path: "/r\($0)", reason: .emptyPath) }
        let line = CaptureScope(live: live(kept: ["/a"], dropped: dropped), rangeName: "全部").coverageLine(language: .chineseSimplified)
        #expect(line.contains(
            "剔除 5 条：/r1（空路径）、/r2（空路径）、/r3（空路径）…另 2 条"
        ), "\(line)")
        // 总数必须是 5，不是被点名的 3。
        #expect(!line.contains("剔除 3 条"))
    }

    @Test("四种剔除原因都走契约的 displayName，界面没有 per-case 分叉")
    func reasonsComeFromTheContract() throws {
        // 约束②：`shadowedByShallowerRoot` 在当前排序下不可达，本车道**没有**为它写句子——
        // 它仍然渲染得出来，正是因为这里只转发 displayName、不 switch。
        let reasons: [MonitoringScope.Reason] = [
            .protectedRoot, .matchedIgnoredPattern, .emptyPath, .shadowedByShallowerRoot,
        ]
        for reason in reasons {
            let line = CaptureScope(
                live: live(kept: ["/a"], dropped: [.init(path: "/x", reason: reason)]),
                rangeName: "全部"
            ).coverageLine(language: .chineseSimplified)
            #expect(line.contains("（\(reason.displayName)）"), "\(reason) 的原因没上屏：\(line)")
        }
        #expect(reasons.map(\.displayName) == [
            "过浅：受保护根", "命中忽略规则", "空路径", "已被更浅的监控根覆盖",
        ])
        // 而且界面不许自己判「哪些路径算太浅」——那句话现在完全来自引擎。
        let source = Self.codeOnly(try Self.source("Sources/AIObservatoryUI/Files/CaptureAvailability.swift"))
        #expect(!source.contains("isProtected"), "UI 里又复刻了 isProtected")
        #expect(!source.contains("protectedRoots()"))
        #expect(!source.contains("case .shadowedByShallowerRoot"), "给不可达那一档写了专门文案")
    }

    // MARK: #46 空白值不许原样铺上屏

    @Test("#46 空路径 ⇒ 屏上是占位，不是两个空格")
    func blankPathGetsAVisiblePlaceholder() {
        // 真机复验抓到的形状：`… 、  （空路径）、/ …`——那条剔除的路径是空串，
        // 原样铺出去就是两个空格，读起来像渲染坏了。
        let line = CaptureScope(
            live: live(kept: ["/Users/demo/Projects/Mona"], dropped: [
                .init(path: "/", reason: .protectedRoot),
                .init(path: "", reason: .emptyPath),
            ]),
            rangeName: "全部"
        ).coverageLine(language: .chineseSimplified)
        #expect(line
            == "采集面：正在监控 1 个根 · 剔除 2 条：/（过浅：受保护根）、\"\"（空路径）"
            + " · 本页范围 全部" + Self.resolvedTail)
        // 反向：那一格前面不许再出现「顿号 + 空白 + 全角括号」这个坏形状。
        #expect(!line.contains("、 （"), "\\(line)")
    }

    @Test("只有空白的路径与只有空白的规则都走同一条占位规则")
    func whitespaceOnlyValuesAlsoGetPlaceholders() {
        // 引擎解析入口已经 trim 过，但界面不该依赖它——「值是不是空白」这条判断在屏前也要成立。
        let blankPath = CaptureScope(live: live(kept: [], dropped: [
            .init(path: "   \t ", reason: .emptyPath),
        ]), rangeName: "全部").coverageLine(language: .chineseSimplified)
        #expect(blankPath.contains("剔除 1 条：\"\"（空路径）"), "\\(blankPath)")
        // matchedRule 是空白时不拼那个冒号（否则又是一处「看着像坏了」）。
        let blankRule = CaptureScope(live: live(kept: ["/a"], dropped: [
            .init(path: "/p/web", reason: .matchedIgnoredPattern, matchedRule: "  "),
        ]), rangeName: "全部").coverageLine(language: .chineseSimplified)
        #expect(blankRule.contains("/p/web（命中忽略规则）"), "\\(blankRule)")
        #expect(!blankRule.contains("：）"), "\\(blankRule)")
        // 有规则时仍然把规则本身带上（占位规则不许顺手把正常路径也吃掉）。
        let realRule = CaptureScope(live: live(kept: ["/a"], dropped: [
            .init(path: "/p/web", reason: .matchedIgnoredPattern, matchedRule: "*/node_modules/*"),
        ]), rangeName: "全部").coverageLine(language: .chineseSimplified)
        #expect(realRule.contains("/p/web（命中忽略规则：*/node_modules/*）"), "\\(realRule)")
    }

    // MARK: ③ 实况只有一个出处

    @Test("Files 这一层不再读 runtime.settings 拼采集面（两把尺的源头）")
    func filesLayerStopsReadingTheSettingsSnapshot() throws {
        for relative in [
            "Sources/AIObservatoryUI/Files/CaptureAvailability.swift",
            "Sources/AIObservatoryUI/Files/FilesModel.swift",
        ] {
            let text = Self.codeOnly(try Self.source(relative))
            #expect(!text.contains("settings.monitoredRoots"),
                    "\(relative) 还在从启动快照读监控根 ⇒ 与引擎实况两把尺")
            #expect(!text.contains("settings.ignoredPathPatterns"), "\(relative) 同上（忽略规则）")
        }
        // 模型确实去取了读数（口径写得再对，没人调用就是零）。正向接线也只认代码。
        let model = Self.codeOnly(try Self.source("Sources/AIObservatoryUI/Files/FilesModel.swift"))
            .split(whereSeparator: \.isWhitespace).joined()
        #expect(model.contains("awaitruntime.monitoringScope?.currentMonitoringScope()"))
        #expect(model.contains("monitoringScope=scope"))
    }

    // MARK: 空态两态

    @Test("有记录就没有空态话术；引擎停着也不该拿范围事实去挡")
    func rowsPresentResolveToNil() {
        let scope = CaptureScope(live: nil, rangeName: "全部")
        #expect(CaptureAvailability.resolve(engineState: .running, rowCount: 3, scope: scope) == nil)
        // 引擎停了但库里还有上次的 3 条：显示的仍是数据，不是「没有在采集」。
        #expect(CaptureAvailability.resolve(engineState: .stopped, rowCount: 3, scope: scope) == nil)
    }

    @Test("五个引擎状态谁算「在采集」= 手推表")
    func isCollectingTable() {
        #expect(EngineState.stopped.isCollecting == false)
        #expect(EngineState.failed.isCollecting == false)
        #expect(EngineState.running.isCollecting == true)
        // starting / degraded 都在采集：一个刚起来还没到第一轮，一条采集链没起来但不是停下来了。
        // 侧栏那颗点写「降级运行」而这一页说「没有在采集」，就是同屏两把尺。
        #expect(EngineState.starting.isCollecting == true)
        #expect(EngineState.degraded.isCollecting == true)
    }

    @Test("空 + 引擎在采集 ⇒ 报实况，并明说「没有记录 ≠ 没有发生」")
    func emptyWhileCollecting() {
        let scope = CaptureScope(
            live: live(kept: ["/Users/demo/Projects/Mona"], dropped: [
                .init(path: "/Users/demo", reason: .protectedRoot),
            ]),
            rangeName: "全部"
        )
        let availability = CaptureAvailability.resolve(engineState: .running, rowCount: 0, scope: scope)
        #expect(availability == .nothingInScope(scope))
        #expect(availability?.headline(language: .chineseSimplified) == "这一页没有文件变更记录")
        #expect(availability?.explanation(language: .chineseSimplified)
            == "采集面：正在监控 1 个根 · 剔除 1 条：/Users/demo（过浅：受保护根） · 本页范围 全部"
            + Self.resolvedTail + " ⇒ 这里没有记录，不等于没有发生。")
    }

    @Test("空 + 引擎停了 ⇒ 说清是没人在看，并承诺不了任何事")
    func emptyWhileStopped() {
        let scope = CaptureScope(live: nil, rangeName: "全部")
        let availability = CaptureAvailability.resolve(engineState: .stopped, rowCount: 0, scope: scope)
        #expect(availability == .notCollecting(.stopped))
        #expect(availability?.headline(language: .chineseSimplified) == "引擎没有在采集")
        #expect(availability?.explanation(language: .chineseSimplified)
            == "引擎当前是「已停止」，没有在采集，所以这段时间不会有新的文件变更记录。")
        // 状态名出自 `EngineState.displayName`，换状态这句话要跟着变（不是写死的一句「已停止」）。
        let failed = CaptureAvailability.notCollecting(.failed)
        #expect(failed.explanation(language: .chineseSimplified).contains("「异常」"))
        #expect(!failed.explanation(language: .chineseSimplified).contains("已停止"))
    }

    @Test("两种空态必须是两句话，不许合成一句万能免责")
    func theTwoEmptiesStayDistinguishable() {
        let scope = CaptureScope(live: nil, rangeName: "全部")
        let collecting = CaptureAvailability.resolve(engineState: .running, rowCount: 0, scope: scope)
        let idle = CaptureAvailability.resolve(engineState: .stopped, rowCount: 0, scope: scope)
        #expect(collecting?.headline(language: .chineseSimplified) != idle?.headline(language: .chineseSimplified))
        #expect(collecting?.explanation(language: .chineseSimplified) != idle?.explanation(language: .chineseSimplified))
        // 「采集面」那一行只在真的在采集这一侧出现：引擎都没跑，报实况是误导。
        #expect(collecting?.explanation(language: .chineseSimplified).contains("采集面") == true)
        #expect(idle?.explanation(language: .chineseSimplified).contains("采集面") == false)
    }

    @Test("上屏字符串不许带 markdown 星号")
    func noMarkdownLeaksOnScreen() {
        let scope = CaptureScope(live: live(kept: ["/a"], dropped: [
            .init(path: "/b", reason: .protectedRoot),
        ]), rangeName: "全部")
        for sentence in [
            scope.coverageLine(language: .chineseSimplified),
            CaptureScope(live: nil, rangeName: "全部").coverageLine(language: .chineseSimplified),
            CaptureAvailability.notCollecting(.stopped).explanation(language: .chineseSimplified),
            CaptureAvailability.notCollecting(.stopped).headline(language: .chineseSimplified),
            CaptureAvailability.nothingInScope(scope).explanation(language: .chineseSimplified),
            CaptureAvailability.nothingInScope(scope).headline(language: .chineseSimplified),
        ] {
            #expect(!sentence.contains("**"), "`Text` 不解析代码字面量里的 markdown：\(sentence)")
        }
    }

    // MARK: 接线

    /// 口径写在模型里，但**视图重新把那句话写回 `FilesView`** 才是这个缺陷的原始形状——
    /// 上面那些用例对此全盲。所以逐行看那个文件。
    @Test("文件页视图读口径，不许自带空态文案")
    func filesViewWiresTheReadoutNotItsOwnSentence() throws {
        let text = Self.codeOnly(try Self.source("Sources/AIObservatoryUI/Files/FilesView.swift"))
        let squeezed = text.split(whereSeparator: \.isWhitespace).joined()
        #expect(squeezed.contains("EmptyStateView(availability.headline(),"),
                "空态标题没读 captureAvailability.headline()")
        #expect(squeezed.contains("message:availability.explanation(),fills:false"),
                "空态说明没读 captureAvailability.explanation()")
        // 有记录那一侧也要有常驻的实况行（否则「只列出 3 条」又被读成「只动了 3 个文件」）。
        #expect(squeezed.contains("Text(model.captureScope.coverageLine())"),
                "指标区里常驻的实况那一行被删了")
        #expect(!text.contains("会在这里列出每一次变更"), "旧的免责文案复活了")
        #expect(!text.contains("\"还没有文件变更\""), "旧的空态标题复活了")
    }

    /// 端到端：装配一个会报实况的宿主 → `load()` → 上屏那一行。
    /// 上面那些源码级守卫只证明"代码里写了这句话"，这一条证明**读数真的流到了文案**——
    /// 把 `captureScope` 改回写死 `live: nil` 时，只有这条会红。
    @Test("引擎读数经 load() 接上上屏那一行（端到端，不止于中间层不抛错）")
    func engineReadingReachesTheShippedLine() async throws {
        let scope = MonitoringScope(
            keptRoots: ["/Users/demo/Projects/Mona"],
            dropped: [.init(path: "/Users/demo", reason: .protectedRoot)],
            resolvedAt: Self.resolvedAt
        )
        let model = FilesModel(runtime: runtime(reporting: scope))
        await model.load()
        #expect(model.monitoringScope == scope)
        #expect(model.captureScope.coverageLine(language: .chineseSimplified)
            == "采集面：正在监控 1 个根 · 剔除 1 条：/Users/demo（过浅：受保护根） · 本页范围 全部"
            + Self.resolvedTail)
        // 宿主没装配（真实预览就是这个形状）时，模型侧也必须走到「尚无读数」那一档，
        // 而不是崩、也不是画成「0 个根」。
        let unwired = FilesModel(runtime: runtime(reporting: nil))
        await unwired.load()
        #expect(unwired.monitoringScope == nil)
        #expect(unwired.captureScope.coverageLine(language: .chineseSimplified)
            == "采集面：尚无采集面读数（引擎还没解析过任何一轮） · 本页范围 全部")
    }

    private func runtime(reporting scope: MonitoringScope?) -> ObservatoryRuntime {
        let service = SampleData.demoService(now: Self.resolvedAt, sessionCount: 3)
        return ObservatoryRuntime(
            service: service, controller: service, updates: service,
            settings: .default, monitoringScope: FixedScope(scope: scope)
        )
    }

    private struct FixedScope: MonitoringScopeReporting {
        let scope: MonitoringScope?
        func currentMonitoringScope() async -> MonitoringScope? { scope }
    }

    // MARK: 路径

    private enum ReadoutError: Error { case noRepoRoot }

    /// 只看代码：整行注释与「空格+//」之后的行文都不算。
    /// 这三条守卫问的是「有没有人在**代码里**这么写」，而解释为什么不能这么写的那些话
    /// 本身就带这些标识符（`isProtected`、`runtime.settings.monitoredRoots`）——
    /// 不过滤的话，注释写得越清楚越容易把自己判红，然后被人整条删掉。
    private static func codeOnly(_ text: String) -> String {
        text.split(separator: "\n")
            .map { line in String(line.components(separatedBy: " //").first ?? "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private static func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: root.appending(path: "Package.swift").path) else {
            throw ReadoutError.noRepoRoot
        }
        return try String(contentsOf: root.appending(path: relative), encoding: .utf8)
    }
}
