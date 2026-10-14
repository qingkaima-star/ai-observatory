//
//  AttributionGapPanelTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · #54 / ICR-0009 界面那一半）
//  ─────────────────────────────────────────────────────────
//  三条硬约束逐条可执行，外加一条等价用例。
//
//  【为什么必须有等价用例】这一格的病和它上游一模一样：读数在引擎里（`ObservatoryEngine:523`）
//  已经落地，却零消费者。只测"面板能画出一个手搭的 AttributionGap"，等于又造一条
//  「函数绿、链路没接」的用例（`ExplicitRootIgnoreRenderTests` 的文件头把这类写法定过罪）。
//  ⇒ `modelReceivesExactlyWhatTheReporterReturns` 走完整链路：
//     真 `FilesModel.load()` → `AttributionGapWiring` → service → 断言模型手里的数**等于**读数方的数。
//
//  【桥的失效模式也在这里钉】`runtime.service as? AttributionGapReporting` 一旦因为
//  装配根包装了 service 而返回 nil，那一格会说出「本次运行尚无归属读数」——那是假话。
//  所以有 `bridgeIsLiveInTheShippedComposition`：扫装配根，`service:` 那一项必须是裸 `engine`。
//
//  【真机撞见的第二件事（07:55，同一格）】两份引擎读数过去**只在 `load()` 里取一次**，
//  而列表是走推送长起来的 ⇒ 页面开着不动，下面 8 行每行都写「未能归属」，上面那一格仍说
//  「本次运行尚无归属读数：引擎还没处理过文件事件」。`ObservatoryUpdate` 里没有承载这两份
//  读数的 case（§3 冻结），所以只能由界面在事件到达时回头再取一次
//  ——见 `FilesModel.scheduleEngineReadingsRefresh`，下面「冻结缺陷」那三条钉住它。
//

import Foundation
import os
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

@Suite("UI: 归属缺口那一格（#54 / ICR-0009）", .timeLimit(.minutes(2)))
@MainActor struct AttributionGapPanelTests {

    // MARK: 文案表本身

    @Test("归属缺口那一批文案合格：无缺陷、名字唯一、真双语、英文不夹汉字也不踩复数")
    func copyTableIsSound() {
        let gapEntries = AttributionCopy.bilingualCopy.filter { $0.name.hasPrefix("attribution.gap.") }
        #expect(gapEntries.count == 10, "缺口那一格应有 10 条文案，实得 \(gapEntries.count)")
        #expect(copyProblems(in: gapEntries).isEmpty)
        #expect(duplicateCopyNames(in: gapEntries).isEmpty)
        #expect(gapEntries.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsHan
        }.map(\.name) == [])
        #expect(gapEntries.filter { $0.copy.english.containsHan }.map(\.name) == [])
        #expect(B3PageCopyGate.pluralTrapNames(in: gapEntries) == [],
                "英文侧写成「数字紧跟复数名词」了（复数没有机制，只能靠写法）")
    }

    // MARK: 约束①：nil 与 total == 0 分开说

    @Test("约束①：没有读数与一条都没漏是两句话，且互不含对方的关键词")
    func nilAndZeroAreWordedDifferently() {
        for language in [AppLanguage.chineseSimplified, .english] {
            let noReading = AttributionCopy.gapNoReading.text(language)
            let allIn = AttributionCopy.gapNothingMissing.text(language)
            // 手推字面量（钉语义，不是钉实现）：换措辞要连带改这条，正是想要的摩擦。
            if language == .chineseSimplified {
                #expect(noReading == "本次运行尚无归属读数：引擎还没处理过文件事件。")
                #expect(allIn == "本次运行内的文件变更全部归上了因（%1$d 条）。")
            }
            // 两句不许互相包含对方的核心词：合并成一句就是 ICR-0006 那条禁止的事。
            #expect(!noReading.contains("全部归上"), "\\(noReading)")
            #expect(!allIn.contains("尚无"), "\\(allIn)")
            #expect(!allIn.contains("还没处理过"), "\\(allIn)")
        }
    }

    // MARK: 约束②：必带「本次运行内」

    @Test("约束②：每一句带数字或带结论的文案都限定在本次运行")
    func countBearingCopyIsScopedToThisRun() {
        let scoped: [(String, NamedCopy)] = [
            ("title", AttributionCopy.gapTitle),
            ("noReading", AttributionCopy.gapNoReading),
            ("nothingMissing", AttributionCopy.gapNothingMissing),
            ("reason.nothingDetected", AttributionCopy.gapReasonNothingDetected),
        ]
        for (name, entry) in scoped {
            let zh = entry.copy.chineseSimplified
            let en = entry.copy.english
            #expect(zh.contains("本次运行"), "\(name) 中文侧丢了限定：\(zh)")
            #expect(en.lowercased().contains("in this run"), "\(name) 英文侧丢了限定：\(en)")
        }
        // 反向：整批缺口文案里不许出现"历史/保留期"这类越界说法（这份账不落库）。
        for banned in ["保留期", "历史", "全部变更", "all-time", "retention"] {
            let hits = AttributionCopy.bilingualCopy
                .filter { $0.name.hasPrefix("attribution.gap.") }
                .filter { $0.copy.chineseSimplified.contains(banned) || $0.copy.english.lowercased().contains(banned) }
                .map(\.name)
            #expect(hits == [], "缺口文案里出现了越界说法「\(banned)」：\(hits)")
        }
    }

    // MARK: 约束③：只数不判

    @Test("约束③：不判责任、不给建议、不复刻判定规则")
    func copyCountsWithoutJudging() {
        let banned = [
            "建议", "应当", "应该", "请", "配置", "设置里", "责任", "导致", "因为您",
            "recommend", "should", "please", "configure", "blame", "caused by",
        ]
        let gapEntries = AttributionCopy.bilingualCopy.filter { $0.name.hasPrefix("attribution.gap.") }
        for phrase in banned {
            let hits = gapEntries.filter {
                $0.copy.chineseSimplified.contains(phrase) || $0.copy.english.lowercased().contains(phrase.lowercased())
            }.map(\.name)
            #expect(hits == [], "缺口文案里出现判责/建议词「\(phrase)」：\(hits)")
        }
    }

    @Test("约束③：四个机制名一个都不许少（少一个就是在替引擎挑哪些值得说）")
    func everyReasonIsNamed() {
        for language in [AppLanguage.chineseSimplified, .english] {
            let labels = AttributionGap.Reason.allCases.map { AttributionCopy.gapReasonLabel($0, language) }
            #expect(labels.allSatisfy { !$0.isEmpty })
            #expect(Set(labels).count == 4, "四个机制名撞了：\(labels)")
        }
    }

    // MARK: 排序与"全零不渲染空表"

    @Test("行按 rank 排（不是 CaseIterable 顺序），零条目的机制不画行")
    func rowsFollowRankAndSkipZeros() {
        // 手推期望：rank 把 `workingDirectoryUnusable` 提到第 2 位，
        // 而 CaseIterable 里它是第 3 个——两者不同，用错就看不出主次。
        let all = AttributionGap(counts: [
            .outsideEveryWorkingDirectory: 1,
            .nothingDetected: 2,
            .detectedWithoutWorkingDirectory: 3,
            .workingDirectoryUnusable: 4,
        ])
        #expect(AttributionGapPanel.visibleReasons(in: all) == [
            .nothingDetected, .workingDirectoryUnusable,
            .detectedWithoutWorkingDirectory, .outsideEveryWorkingDirectory,
        ])
        #expect(AttributionGapPanel.visibleReasons(in: all) != AttributionGap.Reason.allCases,
                "排序等于 CaseIterable ⇒ 没有按 rank")

        // 只列非零：
        #expect(AttributionGapPanel.visibleReasons(in: AttributionGap(counts: [.nothingDetected: 5]))
                == [.nothingDetected])
        // 全零不渲染空表（`total == 0` 那一支由视图直接说整句，不画表）：
        #expect(AttributionGapPanel.visibleReasons(in: .empty).isEmpty)
    }

    /// 再看副标题声称的次序是不是行序**真的**那一种。⇒ 两种漂移都红：
    /// ①措辞说按条数而代码按 rank（今天这一笔）；②代码改按条数而措辞不动
    /// （那条用例 `rowsFollowRankAndSkipZeros` 同时红，两句一起改才过）。
    /// 最后一条守卫防的是"把尾巴整段删掉蒙过去"：那一格确实有个非显然的次序（`rank`
    /// 把本机主因摆在第 2 位），句子必须说出来，不许沉默。
    @Test("副标题声称的次序 == visibleReasons 实际给的次序（拿 rank≠条数 的反例账验）")
    func subtitleOrderClaimMatchesTheRows() throws {
        // 反例账：`outsideEveryWorkingDirectory` 条数最多（9），但 rank 最靠后（3）；
        // `nothingDetected` 只有 1 条，却因 rank=0 排第一 ⇒ 两种次序给出不同结果。
        let probe = AttributionGap(counts: [
            .nothingDetected: 1,
            .outsideEveryWorkingDirectory: 9,
        ])
        let byRank = AttributionGapPanel.visibleReasons(in: probe)
        let byCount = probe.counts.keys.sorted {
            (probe.count(of: $0), $0.rank) > (probe.count(of: $1), $1.rank)
        }
        #expect(byRank == [.nothingDetected, .outsideEveryWorkingDirectory],
                "反例账本身失效：rank 次序与条数次序无法区分，这条用例就是在空转")
        #expect(byRank != byCount, "反例账失效：按条数排与按 rank 排给出同一顺序")

        let countOrderClaims = [
            "按条数", "条数排", "按数量排", "数量多",   // 中文侧
            "by count", "ordered by count", "most first", "most frequent",
        ]
        for language in [AppLanguage.chineseSimplified, .english] {
            let subtitle = AttributionCopy.gapSubtitle.text(language)
            let claimsCountOrder = countOrderClaims.contains { subtitle.lowercased().contains($0) }
            if claimsCountOrder {
                // 声称按条数排 ⇒ 行序就必须真是按条数排。今天不成立 ⇒ 红。
                #expect(byRank == byCount,
                        "副标题声称「按条数排」，但 \(language) 侧渲染出的行序是 rank 序：\(subtitle)")
            }
            // 反向：句子必须说清它按什么排（防"删掉尾巴"式绕过）。
            let namesFixedOrder = subtitle.contains("固定") || subtitle.lowercased().contains("fixed")
            #expect(namesFixedOrder && !claimsCountOrder,
                    "副标题既没说是固定次序、又（或）声称了另一种次序：\(subtitle)")
        }
    }

    // MARK: 等价用例：界面拿到的数 == 读数方的数

    @Test("等价：FilesModel 手里的数与 reporter 给的逐字相等（走完整链路）")
    func modelReceivesExactlyWhatTheReporterReturns() async throws {
        let expected = AttributionGap(counts: [
            .workingDirectoryUnusable: 181,
            .outsideEveryWorkingDirectory: 7,
        ])
        let service = GapReportingService(inner: InMemoryObservatoryService(), gap: expected)
        let runtime = ObservatoryRuntime(
            service: service, controller: service, updates: service, settings: .default
        )
        let model = FilesModel(runtime: runtime)

        await model.load()

        let got = try #require(model.attributionGap)
        #expect(got == expected, "界面拿到的分布与读数方不一致：\(got.counts)")
        #expect(got.total == 188)
        #expect(got.count(of: .workingDirectoryUnusable) == 181)
        // 链路本身也算证据：桥没接上时这里就是 nil，而界面会把它说成"尚无读数"。
        #expect(AttributionGapWiring.reporter(runtime) != nil, "桥没取到 reporter")
    }

    @Test("未接入归属读数的宿主：模型留 nil，而不是造一个 0")
    func absentReporterStaysNil() async {
        let plain = InMemoryObservatoryService()
        let runtime = ObservatoryRuntime(
            service: plain, controller: plain, updates: plain, settings: .default
        )
        let model = FilesModel(runtime: runtime)

        await model.load()

        #expect(model.attributionGap == nil)
        #expect(AttributionGapWiring.reporter(runtime) == nil)
    }

    /// 挂载点。真机第一张图抓到的缺陷：原来只挂在"有数据"那一支里，
    /// 而本机这一轮采集面是 0 个根 ⇒ 整页走空态，那一格一个字都没出现——
    /// 恰恰是最需要"为什么没有归属"这句话的那一屏。
    /// ⚠️ 这条只能扫源码：视图的**摆放位置**在单元测试里没有任何行为可观测量
    /// （SwiftUI 不渲染进测试）。它可变异验证：删掉第二处挂载就红。
    @Test("那一格在没有数据的那几屏也要出现，且一屏只出现一次")
    func panelIsMountedInBothStates() throws {
        let view = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryUI/Files/FilesView.swift")
        let mounts = view.components(separatedBy: "AttributionGapPanel(gap: model.attributionGap)").count - 1
        #expect(mounts == 2, "挂载点应恰好两处（列表之前 + 非数据屏之后），实得 \(mounts)")
        #expect(view.contains("if !showsListContent, !(model.isLoading && model.changes.isEmpty)"),
                "补集条件被改 ⇒ 要么空态看不见那一格，要么同一屏画出两格（同一个数说两遍）")
    }

    // MARK: 冻结缺陷（07:55 真机第二张图抓到）

    /// 两份引擎读数过去**只在 `load()` 里取一次**，而列表是走推送长起来的。
    /// 真机上撞见的画面：下面 8 行每行都写着「未能归属」，上面那一格停在
    /// 「本次运行尚无归属读数：引擎还没处理过文件事件」。
    @Test("推来文件事件之后那一格必须重取样，不许停在启动值")
    func pushedFileChangeResamplesEngineReadings() async throws {
        let inner = InMemoryObservatoryService()
        let host = GapReportingService(inner: inner, gap: nil)
        let runtime = ObservatoryRuntime(
            service: host, controller: host, updates: host, settings: .default
        )
        let model = FilesModel(runtime: runtime)

        await model.load()
        #expect(model.attributionGap == nil, "启动时引擎确实一条都没处理过")

        let later = AttributionGap(counts: [.workingDirectoryUnusable: 8])
        host.setGap(later)
        let observer = await subscribe(model, to: host)

        // `agentKind` 默认 `.unknown` ⇒ 与真机那 8 行同一个形状（都没归上因）。
        inner.ingest(.fileChange(FileChange(path: "/tmp/frozen-a.swift", kind: .created)))
        let refreshed = await waitUntil { model.attributionGap == later }
        observer.cancel()

        #expect(refreshed, """
            推来一条文件事件后那一格仍停在 \(String(describing: model.attributionGap))——\
            就是真机那张图的形状（列表在长，那一格说"引擎还没处理过文件事件"）
            """)
        #expect(model.changes.count == 1, "列表要照常长起来（重取样不许把事件吞掉）")
    }

    @Test("被本页筛掉的事件也要唤起重取样：引擎的账与本页筛选无关")
    func filteredOutEventStillResamples() async throws {
        let inner = InMemoryObservatoryService()
        let host = GapReportingService(inner: inner, gap: nil)
        let runtime = ObservatoryRuntime(
            service: host, controller: host, updates: host, settings: .default
        )
        let model = FilesModel(runtime: runtime)
        await model.load()
        model.timeRange = .lastHour   // 本页只看最近一小时

        let later = AttributionGap(counts: [.nothingDetected: 3])
        host.setGap(later)
        let observer = await subscribe(model, to: host)

        inner.ingest(.fileChange(FileChange(
            path: "/tmp/frozen-old.swift", kind: .created,
            timestamp: Date().addingTimeInterval(-3 * 24 * 3600)   // 三天前
        )))
        let refreshed = await waitUntil { model.attributionGap != nil }
        observer.cancel()

        #expect(refreshed, "重取样被排在了 `matchesCurrentQuery` 之后：一条被筛掉的事件永远唤不起它")
        #expect(model.changes.isEmpty, "这条被时间范围筛掉了，不该进列表")
        #expect(model.attributionGap == later)
    }

    @Test("连着来六条：每一格都跟着走，最后停在读数方当前的值")
    func burstEndsOnTheLiveValue() async throws {
        let inner = InMemoryObservatoryService()
        let host = GapReportingService(inner: inner, gap: nil)
        let runtime = ObservatoryRuntime(
            service: host, controller: host, updates: host, settings: .default
        )
        let model = FilesModel(runtime: runtime)
        await model.load()
        let observer = await subscribe(model, to: host)

        for index in 1...3 {
            inner.ingest(.fileChange(FileChange(path: "/tmp/burst-\(index).swift", kind: .created)))
        }
        let firstStage = AttributionGap(counts: [.workingDirectoryUnusable: 3])
        host.setGap(firstStage)
        #expect(await waitUntil { model.attributionGap == firstStage }, "前三条没把那一格推起来")

        // 中途读数方换了值：界面必须跟上，而不是把第一次取到的数当成启动快照。
        for index in 4...6 {
            inner.ingest(.fileChange(FileChange(path: "/tmp/burst-\(index).swift", kind: .created)))
        }
        let secondStage = AttributionGap(counts: [
            .workingDirectoryUnusable: 5, .outsideEveryWorkingDirectory: 1,
        ])
        host.setGap(secondStage)
        let settled = await waitUntil { model.attributionGap == secondStage }
        // ⚠️ **先排空，再取消**。`observeUpdates()` 每一轮是"先看 `Task.isCancelled` 再 ingest"，
        // 所以取消一落地，还在流缓冲里排队的事件就永远进不了列表。
        // 改前的顺序是 `observer.cancel()` 紧接 `#expect(changes.count == 6)` ——
        // 等于自己先把尾巴剪掉，再抱怨清单少了两条（实测基线 20 轮里 4 轮红，缺的正好是最后两条）。
        // 这不是"重试到绿"：期望值一个字没动，`waitUntil` 有上限，排不空就 `drained == false` 判红；
        // 而"取消会不会吞事件"另有一格确定性地判（`cancellingBeforeDrainStrandsTheTail`）。
        //
        // 两臂各 20 轮**全量**实测（2026-09-21 21:2x，总控自跑，同机同负载档）：
        //   · A 臂 = 把顺序改回"先 cancel 再断言"（`git checkout e8d0c05 -- 本文件`）⇒ **20 轮红 12 次**，
        //     签名全是本行，缺的条数 2/3/4 不等（取消落地早晚决定吞几条）；
        //   · B 臂 = 现在这版（先排空再 cancel）⇒ **20/20 全绿**。
        // ⇒ 根因是**装置顺序**，不是采集 / 归因算法。产品侧唯一的丢弃路径就是这里：
        //   `FilesModel.observeUpdates()` 每轮在循环顶部 `if Task.isCancelled { break }`，
        //   取消一落地，流里已排队的推送永远进不了列表；而这一页 `.task` 先 `load()` 重读、
        //   另有 `.refreshable` ⇒ 丢弃**有界且自愈**，不是静默数据丢失。
        //   会话中途没有第二条丢弃路径（循环是逐条 `await ingest(update)`）。
        let drained = await waitUntil { model.changes.count == 6 }
        observer.cancel()

        #expect(settled, "突发结束后仍停在旧读数：\(String(describing: model.attributionGap))")
        #expect(
            drained,
            """
            六条推完排不空：只有 \(model.changes.count) 条进了列表 ⇒ 推送在链路里被丢了。
            （不是取消造成的——"取消会不会吞事件"由 `cancellingBeforeDrainStrandsTheTail` 单独判。）
            """
        )
        #expect(model.changes.count == 6)
    }

    @Test("机制取证：不排空就取消订阅，尾巴必定进不了列表（判的是装置顺序）")
    func cancellingBeforeDrainStrandsTheTail() async throws {
        let inner = InMemoryObservatoryService()
        let host = GapReportingService(inner: inner, gap: nil)
        let runtime = ObservatoryRuntime(
            service: host, controller: host, updates: host, settings: .default
        )
        let model = FilesModel(runtime: runtime)
        await model.load()
        let observer = await subscribe(model, to: host)

        // 六条**同步连发**、中间一次 await 都没有 ⇒ 主执行序没让出去，消费循环还没来得及取；
        // 紧接着取消 ⇒ 下一轮循环先撞上 `Task.isCancelled` 就 break。
        for index in 1...6 {
            inner.ingest(.fileChange(FileChange(path: "/tmp/strand-\(index).swift", kind: .created)))
        }
        observer.cancel()
        // 之后让出主执行序，给消费循环充分的机会：它若还能吞进任何一条，就是产品行为与这里的
        // 注释不符，上面那格"先排空再取消"的理由也随之作废（两处必须一起改）。
        try? await Task.sleep(for: .milliseconds(120))

        #expect(model.changes.isEmpty,
                "取消之后仍有 \(model.changes.count) 条进了列表 ⇒ `observeUpdates` 的取消语义变了")
    }

    /// 起订阅并**等到订阅真的活着**再返回。
    /// 为什么要等：`Task { await model.observeUpdates() }` 排到主执行序后面，
    /// 而 `InMemoryObservatoryService` 的订阅者是在 `makeUpdateStream()` 里登记的——
    /// 不等这一步，测试紧接着发的第一条事件会在无人订阅时被丢掉（本仓第二次撞这种形状）。
    /// 用 `.engineState` 那一路当探针：它和文件事件走同一条流，收到它就知道流已接通。
    @MainActor
    private func subscribe(
        _ model: FilesModel, to host: GapReportingService
    ) async -> Task<Void, Never> {
        let observer = Task { await model.observeUpdates() }
        // 反复推一次 `.engineState` 直到订阅者收到为止：订阅是在 `observeUpdates()` 里登记
        // continuation 的，而那个 Task 排在主执行序后面——只 `start()` 一次会撞在"还没人订阅"
        // 的空档上（本仓反复出事的那类订阅竞态，见文件头第二段注释同一个形状）。
        var live = false
        for _ in 0..<200 {
            await host.start()
            live = model.engineState == .running
            if live { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        if !live {
            Issue.record("订阅没接通：后面发的文件事件会在无人订阅时被丢掉，下面的失败都是它的影子")
        }
        return observer
    }

    // MARK: 桥的存活守卫

    @Test("装配根仍把裸 engine 交给 service（桥一旦失效，这条先红而不是界面说假话）")
    func bridgeIsLiveInTheShippedComposition() throws {
        let app = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryApp/AIObservatoryApp.swift")
        #expect(app.contains("service: engine,"),
                """
                装配根的 `service:` 不再是裸 engine ⇒ `runtime.service as? AttributionGapReporting` \
                会静默返回 nil，那一格会说出「本次运行尚无归属读数」这句假话。
                正确处置不是放宽这条，而是把正门补上：`ObservatoryRuntime.attributionGap`（§3 冻结区，找总控），
                然后删掉 `AttributionGapWiring` 这座桥与这两条守卫。
                """)
    }
}

// MARK: - 等待

/// 轮询到条件成立（带上限），返回是否等到。
/// 为什么不用固定 `Task.sleep` 再断言：等短了是假红，等长了会把调度问题藏进余量里
/// （`FileTrackingTests` 里那份同名私有助手是同一个理由）。
@MainActor private func waitUntil(
    seconds: Double = 5,
    _ condition: @MainActor () -> Bool
) async -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !condition() {
        if Date() >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}

// MARK: - 替身

/// 一个"既当 service、又报归属缺口、还能收测试发来的推流事件"的宿主
/// （真引擎在装配里就是这个形状：`ObservatoryEngine` 同时 conform 这几个协议）。
///
/// `gap` 是**可变的**：07:55 真机抓到的缺陷正是"读数只在 `load()` 里取一次"，
/// 要复现它必须让"启动时读到的值"和"后来引擎里的值"不同。
/// 为什么不给 `InMemoryObservatoryService` 加这些：它在 §3 冻结区，
/// 而它的 `broadcast` 是 private——为了测试方便去开一个 public 口子，
/// 等于把测试的形状变成产品 API 的一部分。推流本身仍走内层那份（`makeUpdateStream` 转发），
/// 测试用 `inner.ingest(.fileChange(...))` 发事件。
private final class GapReportingService: ObservatoryService, ObservatoryControlling,
    ObservatoryEventStreaming, AttributionGapReporting, Sendable {

    private struct State: Sendable {
        var gap: AttributionGap?
    }

    private let inner: InMemoryObservatoryService
    private let state: OSAllocatedUnfairLock<State>

    init(inner: InMemoryObservatoryService, gap: AttributionGap?) {
        self.inner = inner
        self.state = OSAllocatedUnfairLock(initialState: State(gap: gap))
    }

    /// 测试侧的旋钮：换掉"引擎此刻的读数"。
    func setGap(_ gap: AttributionGap?) { state.withLock { $0.gap = gap } }

    func currentAttributionGap() async -> AttributionGap? { state.withLock { $0.gap } }

    // MARK: 转发（ObservatoryService）

    func dashboardStats(for date: Date) async throws -> DashboardStats {
        try await inner.dashboardStats(for: date)
    }

    func activeAgents() async throws -> [AgentInstance] { try await inner.activeAgents() }

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        try await inner.sessions(matching: query)
    }

    func session(id: UUID) async throws -> AgentSession? { try await inner.session(id: id) }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        try await inner.events(matching: query)
    }

    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        try await inner.fileChanges(matching: query)
    }

    func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        try await inner.fileDiff(for: changeID)
    }

    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        try await inner.commands(matching: query)
    }

    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        try await inner.performanceSamples(sessionID: sessionID)
    }

    func performanceSamples(sessionID: UUID, limit: Int) async throws -> [PerformanceSample] {
        try await inner.performanceSamples(sessionID: sessionID, limit: limit)
    }

    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        try await inner.systemPerformance(since: date)
    }

    func systemPerformance(since date: Date, limit: Int) async throws -> [SystemPerformanceSample] {
        try await inner.systemPerformance(since: date, limit: limit)
    }

    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        try await inner.riskEvents(matching: query)
    }

    func projects() async throws -> [ProjectActivity] { try await inner.projects() }

    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        try await inner.projectActivity(path: path, dateRange: dateRange)
    }

    // MARK: 转发（控制与推流）

    func start() async { await inner.start() }
    func stop() async { await inner.stop() }
    func rescanNow() async { await inner.rescanNow() }
    func updateSettings(_ settings: ObservatorySettings) async { await inner.updateSettings(settings) }

    func acknowledgeRiskEvent(id: UUID) async throws {
        try await inner.acknowledgeRiskEvent(id: id)
    }

    func currentState() async -> EngineState { await inner.currentState() }

    func makeUpdateStream() -> AsyncStream<ObservatoryUpdate> { inner.makeUpdateStream() }
}
