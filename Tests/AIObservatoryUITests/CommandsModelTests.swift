//
//  CommandsModelTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI
//  ─────────────────────────────────────────────────────────
//  Commands 板块（需求④「终端命令审计：命令 / 退出结果 / 耗时」）里可脱离 SwiftUI 跑的那部分：
//    1. 结果与耗时文案 —— 这个板块最容易「撒谎」的地方：没有退出码时必须说「结果未知」，
//       没有 `endedAt` 时必须说「—」，绝不能显示成功或 0s。
//    2. 过滤口径 —— 本地判定与下推给服务端的 `CommandQuery` 必须同源，否则列表与实时增量会用两套规则。
//    3. 分页算术 —— offset 走页号而不是「已加载条数」，否则头部插入的实时命令会让下一页漏读或重读。
//    4. 跨会话取数 —— 用 `AIObservatoryTestSupport` 的内存服务（真实现，不是桩），
//       确认这个板块列的是**全库**命令而不是某个会话的附属品。
//
//  没有 sleep，没有对挂钟的断言：时间全部由固定基线推出来。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

// MARK: - 夹具

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func makeCommand(
    _ line: String,
    kind: AgentKind = .claudeCode,
    sessionID: UUID? = nil,
    startedAt: Date = t0,
    endedAt: Date? = nil,
    exitCode: Int32? = 0,
    outcome: CommandOutcome = .success,
    isDestructive: Bool = false,
    requiresConfirmation: Bool = false,
    workingDirectory: String? = nil
) -> CommandRecord {
    let tokens = line.split(separator: " ").map(String.init)
    return CommandRecord(
        executable: tokens.first ?? line,
        arguments: Array(tokens.dropFirst()),
        workingDirectory: workingDirectory,
        sessionID: sessionID,
        agentKind: kind,
        startedAt: startedAt,
        endedAt: endedAt,
        exitCode: exitCode,
        outcome: outcome,
        isDestructive: isDestructive,
        requiresConfirmation: requiresConfirmation,
        projectPath: nil
    )
}

/// 固定基线时间戳，让倒挂时钟的用例可重复。
private func offset(_ seconds: TimeInterval) -> Date {
    t0.addingTimeInterval(seconds)
}

// MARK: - 1. 结果与耗时

@Suite("UI: 命令审计 · 结果与耗时文案", .timeLimit(.minutes(1)))
struct CommandAuditFormatTests {

    @Test("运行中且没有退出码 = 结果未知：不写成成功，也不补一个 exit 0")
    func runningWithoutExitCodeIsUnknown() {
        let record = makeCommand("npm install", endedAt: nil, exitCode: nil, outcome: .running)
        #expect(CommandAuditFormat.exitStatus(of: record) == .unknown)
        #expect(CommandAuditFormat.exitText(of: record, .chineseSimplified) == "结果未知")
        #expect(CommandAuditFormat.exitText(of: record, .chineseSimplified) != "exit 0")
        #expect(CommandAuditFormat.durationText(of: record) == "—")
        #expect(CommandAuditFormat.endedText(of: record) == "—")
    }

    @Test("被终止 / 结论未知的命令同样不许猜：只要没有退出码就是结果未知")
    func terminatedAndUnknownAreAlsoUnknown() {
        let terminated = makeCommand("cargo build", endedAt: offset(12), exitCode: nil, outcome: .terminated)
        let unknown = makeCommand("make test", endedAt: offset(3), exitCode: nil, outcome: .unknown)
        #expect(CommandAuditFormat.exitText(of: terminated, .chineseSimplified) == "结果未知")
        #expect(CommandAuditFormat.exitText(of: unknown, .chineseSimplified) == "结果未知")
        #expect(CommandAuditFormat.exitStatus(of: terminated) == .unknown)
        #expect(CommandAuditFormat.exitStatus(of: unknown) == .unknown)
    }

    @Test("退出码 0 与非 0 各自归位：0 才算成功")
    func exitCodesAreClassified() {
        let ok = makeCommand("git push", endedAt: offset(30), exitCode: 0)
        let bad = makeCommand("swift test", endedAt: offset(4), exitCode: 137)
        #expect(CommandAuditFormat.exitText(of: ok, .chineseSimplified) == "exit 0")
        #expect(CommandAuditFormat.exitStatus(of: ok) == .succeeded)
        #expect(CommandAuditFormat.exitText(of: bad, .chineseSimplified) == "exit 137")
        #expect(CommandAuditFormat.exitStatus(of: bad) == .failed)
    }

    @Test("耗时只在有结束时间时才计算：缺结束时间显示「—」而不是 0s")
    func durationIsNotFabricated() {
        let finished = makeCommand("swift build", endedAt: offset(9_000), exitCode: 0)
        #expect(CommandAuditFormat.durationText(of: finished) == "2h30m")
        let quick = makeCommand("ls", endedAt: offset(2), exitCode: 0)
        #expect(CommandAuditFormat.durationText(of: quick) == "2s")
        let open = makeCommand("tail -f log", endedAt: nil, exitCode: nil, outcome: .running)
        #expect(CommandAuditFormat.durationText(of: open) == "—")
    }

    @Test("时钟倒挂时夹到 0s：既不出负数，也不假装没有结束时间")
    func reversedClockIsClamped() {
        let skewed = makeCommand("date", startedAt: offset(60), endedAt: offset(10), exitCode: 0)
        #expect(CommandAuditFormat.durationText(of: skewed) == "0s")
    }

    @Test("摘要里带着「结果未知」，并且绝不出现 exit 字样")
    func summaryStaysHonest() {
        let record = makeCommand("rm -rf ./DerivedData", exitCode: nil, outcome: .running)
        let summary = CommandAuditFormat.summary(of: record, .chineseSimplified)
        #expect(summary.contains("结果未知"))
        #expect(!summary.contains("exit"))
        #expect(summary.contains("耗时 —"))
    }
}

// MARK: - 2. 过滤口径

@Suite("UI: 命令审计 · 过滤条件组合", .timeLimit(.minutes(1)))
struct CommandCriteriaTests {

    /// #76 改写过这一条：旧断言是 `failed.outcomes == [.failure, .terminated]`，
    /// 断的正是「终止算失败」这个已被引擎红线否掉的口径（红线见
    /// `ObservatoryEngine+Ingestion.settleOpenCommands` 与 `StoreProtocols.terminateOpenCommands`）。
    /// 按新口径钉：失败格只装真失败，`.terminated` 归「结果未知」格。
    @Test("结果分桶直接换算成契约里的 outcomes：只有真失败进失败格，terminated 归结果未知")
    func exitFiltersMapOntoContract() {
        #expect(CommandExitFilter.all.outcomes.isEmpty)
        #expect(CommandExitFilter.succeeded.outcomes == [.success])
        #expect(CommandExitFilter.failed.outcomes == [.failure])
        #expect(CommandExitFilter.unknownResult.outcomes == [.running, .unknown, .terminated])
        // 四格合起来要覆盖全部 outcome：terminated 既没被丢掉也没被重复计数。
        let covered = CommandExitFilter.allCases
            .filter { $0 != .all }
            .reduce(Set<CommandOutcome>()) { $0.union($1.outcomes) }
        #expect(covered == Set(CommandOutcome.allCases), "分桶没覆盖全部结果：\(covered)")
        let buckets = CommandExitFilter.allCases.filter { $0 != .all }.map(\.outcomes)
        for (i, lhs) in buckets.enumerated() {
            for rhs in buckets.dropFirst(i + 1) {
                #expect(lhs.isDisjoint(with: rhs), "两格重了：\(lhs) ∩ \(rhs)")
            }
        }
    }

    /// 失败格不许再挂「失败或终止」这个标签（那条文案已随 #76 从表里删掉）：
    /// 标签与桶内容必须是一件事。
    @Test("失败格的标签只说「失败」：桶里已经没有 terminated，标签不许替它背书")
    func failedBucketLabelMatchesItsContents() {
        #expect(CommandExitFilter.failed.displayName(.chineseSimplified) == "失败")
        #expect(CommandExitFilter.failed.displayName(.english) == "Failed")
        let terminated = makeCommand("cargo build", endedAt: offset(12), exitCode: nil, outcome: .terminated)
        #expect(!CommandExitFilter.failed.matches(terminated), "terminated 又回到失败格里了")
        #expect(CommandExitFilter.unknownResult.matches(terminated))
    }

    @Test("分桶判定与下推集合严格等义（列表与实时增量共用同一个口径）")
    func exitFilterMatchesAgreeWithPushdown() {
        for filter in CommandExitFilter.allCases {
            for outcome in CommandOutcome.allCases {
                let record = makeCommand("true", exitCode: (outcome == .success ? 0 : nil), outcome: outcome)
                #expect(filter.matches(record) == (filter.outcomes.isEmpty || filter.outcomes.contains(outcome)),
                        "\(filter) 对 \(outcome) 的判定与服务端口径不一致")
            }
        }
    }

    @Test("多个条件同时生效时取交集：任一项不满足就出局")
    func criteriaIntersect() {
        let session = UUID()
        let window = DateRangeFilter(start: t0, end: offset(3_600))
        let target = makeCommand(
            "git commit -m msg",
            kind: .claudeCode,
            sessionID: session,
            startedAt: offset(60),
            endedAt: offset(61),
            exitCode: 0,
            outcome: .success
        )
        let strict = CommandAuditCriteria(
            dateRange: window,
            agentKinds: [.claudeCode],
            exitFilter: .succeeded,
            destructiveOnly: false,
            sessionID: session,
            searchText: "commit"
        )
        #expect(strict.matches(target))
        #expect(strict.activeFilterCount == 4)

        #expect(!CommandAuditCriteria(dateRange: window, agentKinds: [.windsurf]).matches(target))
        #expect(!CommandAuditCriteria(dateRange: window, exitFilter: .failed).matches(target))
        #expect(!CommandAuditCriteria(dateRange: window, destructiveOnly: true).matches(target))
        #expect(!CommandAuditCriteria(dateRange: window, sessionID: UUID()).matches(target))
        #expect(!CommandAuditCriteria(dateRange: window, searchText: "push").matches(target))
        #expect(!CommandAuditCriteria(dateRange: DateRangeFilter(start: offset(3_600))).matches(target))
        #expect(!CommandAuditCriteria(dateRange: DateRangeFilter(end: t0)).matches(target))
    }

    @Test("搜索口径与服务端一致：只匹配命令行本身，不匹配工作目录")
    func searchMatchesCommandLineOnly() {
        let record = makeCommand("swift test", workingDirectory: "/repo/alpha")
        #expect(CommandAuditCriteria(searchText: "swift").matches(record))
        #expect(CommandAuditCriteria(searchText: "TEST").matches(record))
        #expect(!CommandAuditCriteria(searchText: "alpha").matches(record))
    }

    @Test("条件 → CommandQuery：每一项都真实下推，分页由调用方给定")
    func criteriaMapOntoQuery() {
        let session = UUID()
        let criteria = CommandAuditCriteria(
            dateRange: DateRangeFilter(start: t0),
            agentKinds: [.geminiCLI],
            exitFilter: .failed,
            destructiveOnly: true,
            sessionID: session,
            searchText: "rm"
        )
        let query = criteria.makeQuery(limit: 100, offset: 200)
        #expect(query.agentKinds == [.geminiCLI])
        #expect(query.outcomes == [.failure])   // #76：terminated 不再被下推成失败
        #expect(query.destructiveOnly)
        #expect(query.sessionID == session)
        #expect(query.searchText == "rm")
        #expect(query.dateRange.start == t0)
        #expect(query.limit == 100)
        #expect(query.offset == 200)
    }

    @Test("activeFilterCount 只数用户主动收紧的条件，时间范围另算")
    func activeFilterCountTracksNarrowing() {
        #expect(CommandAuditCriteria().activeFilterCount == 0)
        var criteria = CommandAuditCriteria()
        criteria.exitFilter = .succeeded
        #expect(criteria.activeFilterCount == 1)
        criteria.destructiveOnly = true
        criteria.searchText = "git"
        #expect(criteria.activeFilterCount == 3)
        criteria.exitFilter = .all
        #expect(criteria.activeFilterCount == 2)
    }
}

// MARK: - 2b. #76：同一条 `.terminated` 在两处读数的口径

@Suite("UI: #76 terminated 既不计失败也不视为已解决", .timeLimit(.minutes(1)))
@MainActor struct TerminatedOutcomeTests {

    /// 台账第 5 节验收 2 点名的那一格：**同一条** `.terminated` 记录（引擎收口路径产出的真实形状 ——
    /// 有 `endedAt`、退出码 NULL），在「失败计数」里必须是 0、在「已解决」里必须是 false。
    ///
    /// 为什么两句话要写在同一个用例里：这一条口径此前被四处分别与总控各写一处
    /// （`InsightClassification` / 本页 `CommandExitFilter` / `CommandResultReadout.isResolved` /
    ///  总控自留的 `DashboardModel.failedCommands`），**分头钉就必然会再分叉**。
    /// 这里让同一个 `record` 同时喂给「计数」与「是否已解决」两个入口，
    /// 任何一处回退成「失败 / 已解决」都会红在同一行上。
    @Test("同一条 terminated 记录：失败计数 0、isResolved false、读数不许说「全部通过」")
    func terminatedIsNeitherFailedNorResolved() async {
        let record = makeCommand(
            "npm run dev",
            sessionID: UUID(),
            startedAt: offset(10),
            endedAt: offset(40),          // 收口路径写了结束时间（上界口径）
            exitCode: nil,                // 但永远没有退出码
            outcome: .terminated
        )
        let model = CommandsModel(runtime: makeRuntime(commands: [record]))
        await model.setTimeRange(.all)

        // ① 失败计数：这一条不进任何一侧。
        #expect(model.records.count == 1)
        #expect(model.failureCount == 0, "terminated 又被算成失败了")
        #expect(model.successCount == 0)
        #expect(model.unknownResultCount == 1)
        #expect(model.outcomeSummaryText(.chineseSimplified) == "成功 0 · 失败 0 · 结果未知 1")
        // ② 已解决：契约与引擎的红线都点名这一头。
        #expect(!CommandResultReader.isResolved(record.outcome), "terminated 不是「已解决」")
        // ③ 会话瓷贴的读数：只有这一条命令时不能说「全部通过」，也不能报有失败。
        let readout = CommandResultReader.read(
            failedCommands: model.failureCount,
            totalCommands: 1,
            loadedOutcomes: [record.outcome]
        )
        #expect(readout == .nothingResolved(1))
        #expect(!readout.isConfirmedClean, "一条都没判定时不许染成「确认安全」的绿")
        #expect(!readout.hasFailure)
        // ④ 过滤：这一条既不在失败格、也不在成功格，只在「运行中 / 未知」格。
        #expect(!CommandExitFilter.failed.matches(record))
        #expect(!CommandExitFilter.succeeded.matches(record))
        #expect(CommandExitFilter.unknownResult.matches(record))
    }
}

// MARK: - 3. 分页算术

@Suite("UI: 命令审计 · 分页与合并", .timeLimit(.minutes(1)))
struct CommandPagingTests {

    @Test("offset = 页号 × 页宽；负页号与 0 页宽被夹住")
    func offsetMathIsClamped() {
        #expect(CommandPaging.offset(page: 0, pageSize: 100) == 0)
        #expect(CommandPaging.offset(page: 3, pageSize: 100) == 300)
        #expect(CommandPaging.offset(page: -5, pageSize: 100) == 0)
        #expect(CommandPaging.offset(page: 2, pageSize: 0) == 2)
        #expect(CommandPaging.offset(page: 2, pageSize: -1) == 2)
    }

    @Test("hasMore 与未加载条数在越界数据下仍不为负")
    func boundariesAreClamped() {
        #expect(CommandPaging.hasMore(loadedCount: 10, totalCount: 11))
        #expect(!CommandPaging.hasMore(loadedCount: 11, totalCount: 11))
        #expect(!CommandPaging.hasMore(loadedCount: 12, totalCount: 11))
        #expect(CommandPaging.hasMore(loadedCount: 0, totalCount: 1))
        #expect(CommandPaging.unloadedCount(loadedCount: 5, totalCount: 11) == 6)
        #expect(CommandPaging.unloadedCount(loadedCount: 12, totalCount: 11) == 0)
    }

    @Test("按页宽切片：每条记录恰好出现一次（不漏不重）")
    func pagesCoverEveryRecordExactlyOnce() {
        let total = 235
        let pageSize = 50
        let all = (0..<total).map { makeCommand("cmd \($0)", startedAt: offset(TimeInterval($0))) }
        var seen: [UUID] = []
        var page = 0
        while true {
            let window = Array(all.dropFirst(CommandPaging.offset(page: page, pageSize: pageSize)).prefix(pageSize))
            if window.isEmpty { break }
            seen.append(contentsOf: window.map(\.id))
            page += 1
        }
        #expect(page == 5)
        #expect(seen.count == total)
        #expect(Set(seen).count == total)
    }

    @Test("内存裁剪只丢一端：降序丢最旧，升序丢已经划过去的头部（与 SessionsModel 同一口径）")
    func trimKeepsOneEnd() {
        let ascending = (0..<5).map { makeCommand("c\($0)", startedAt: offset(TimeInterval($0) * 60)) }
        let descending = Array(ascending.reversed())
        #expect(CommandPaging.trim(descending, cap: 3, descending: true).map(\.commandLine) == ["c4", "c3", "c2"])
        #expect(CommandPaging.trim(ascending, cap: 3, descending: false).map(\.commandLine) == ["c2", "c3", "c4"])
        #expect(CommandPaging.trim(ascending, cap: 99, descending: true).count == 5)
        #expect(CommandPaging.trim(ascending, cap: 0, descending: true).isEmpty)
    }

    @Test("合并同 id 只留一条，且「运行中」的快照不盖掉已完成的结果")
    func mergePrefersTheMoreCompleteSnapshot() {
        let id = UUID()
        let running = makeCommand("swift test --parallel", exitCode: nil, outcome: .running)
        let runningWithID = CommandRecord(
            id: id, executable: "swift", arguments: ["test", "--parallel"],
            agentKind: .claudeCode, startedAt: t0, outcome: .running
        )
        let finished = CommandRecord(
            id: id, executable: "swift", arguments: ["test", "--parallel"],
            agentKind: .claudeCode, startedAt: t0, endedAt: offset(30), exitCode: 1, outcome: .failure
        )
        #expect(CommandPaging.completeness(of: running) == 0)
        #expect(CommandPaging.completeness(of: finished) == 3)
        #expect(CommandPaging.merge([runningWithID], adding: [finished], descending: true, cap: 10).count == 1)

        let refreshed = CommandPaging.merge([runningWithID], adding: [finished], descending: true, cap: 10)
        #expect(refreshed.first?.exitCode == 1)
        let staleAttempt = CommandPaging.merge([finished], adding: [runningWithID], descending: true, cap: 10)
        #expect(staleAttempt.first?.exitCode == 1)
        #expect(staleAttempt.count == 1)
    }

    @Test("合并后按排序方向重排，时间相同再按 id 决出全序")
    func mergeOrdersDeterministically() {
        let early = makeCommand("echo early", startedAt: t0)
        let late = makeCommand("echo late", startedAt: offset(600))
        let sameTimeA = makeCommand("echo a", startedAt: offset(300))
        let sameTimeB = makeCommand("echo b", startedAt: offset(300))
        let newestFirst = CommandPaging.merge([early], adding: [late, sameTimeA, sameTimeB], descending: true, cap: 10)
        let oldestFirst = CommandPaging.merge([late], adding: [early, sameTimeA, sameTimeB], descending: false, cap: 10)
        #expect(newestFirst.first?.commandLine == "echo late")
        #expect(newestFirst.last?.commandLine == "echo early")
        #expect(oldestFirst.first?.commandLine == "echo early")
        #expect(oldestFirst.last?.commandLine == "echo late")
        // 同一时间戳的相对顺序与输入顺序无关。
        let flipped = CommandPaging.merge([early], adding: [late, sameTimeB, sameTimeA], descending: true, cap: 10)
        #expect(flipped.map(\.id) == newestFirst.map(\.id))
    }

    @Test("完整度只认退出码与结束时间，不看命令行文字")
    func completenessIgnoresPresentation() {
        #expect(CommandPaging.completeness(of: makeCommand("ls", exitCode: 0)) == 2)
        #expect(CommandPaging.completeness(of: makeCommand("ls", endedAt: t0, exitCode: nil)) == 1)
        #expect(CommandPaging.completeness(of: makeCommand("ls", exitCode: nil, outcome: .running)) == 0)
    }
}

// MARK: - 4. 跨会话取数（内存服务真实现）

private func makeRuntime(commands: [CommandRecord]) -> ObservatoryRuntime {
    let service = InMemoryObservatoryService()
    service.seed(commands: commands)
    return ObservatoryRuntime(service: service, controller: service, updates: service)
}

@Suite("UI: 命令审计 · 跨会话取数", .timeLimit(.minutes(1)))
@MainActor struct CommandsModelTests {

    @Test("列的是全库命令：两次会话的记录都出现在同一个列表里")
    func listsCommandsAcrossSessions() async {
        let first = UUID()
        let second = UUID()
        let model = CommandsModel(runtime: makeRuntime(commands: [
            makeCommand("git push", sessionID: first, startedAt: t0, endedAt: offset(5)),
            makeCommand("rm -rf ./DerivedData", sessionID: second, startedAt: offset(60),
                        endedAt: offset(61), exitCode: 0, isDestructive: true)
        ]))
        await model.setTimeRange(.all)
        #expect(model.totalCount == 2)
        #expect(model.records.count == 2)
        #expect(Set(model.records.compactMap { $0.sessionID }) == Set([first, second]))
        #expect(model.destructiveCount == 1)
        // 默认排序新→旧，且自动选中第一条（右侧详情不会是空的）。
        #expect(model.records.first?.commandLine == "rm -rf ./DerivedData")
        #expect(model.selectedID == model.records.first?.id)
        #expect(model.selectedRecord?.isDestructive == true)
    }

    @Test("加载更多只往前走一页：不重读、不重复计数")
    func loadMoreAdvancesExactlyOnePage() async {
        let seeded = (0..<250).map {
            makeCommand("echo \($0)", startedAt: offset(TimeInterval($0)))
        }
        let model = CommandsModel(runtime: makeRuntime(commands: seeded))
        await model.setTimeRange(.all)
        #expect(model.records.count == CommandsModel.pageSize)
        #expect(model.totalCount == 250)
        #expect(model.hasMore)
        #expect(model.unloadedCount == 250 - CommandsModel.pageSize)

        await model.loadMore()
        #expect(model.records.count == CommandsModel.pageSize * 2)
        #expect(Set(model.records.map(\.id)).count == model.records.count)

        await model.loadMore()
        #expect(model.records.count == 250)
        #expect(!model.hasMore)
        #expect(model.unloadedCount == 0)

        await model.loadMore()
        #expect(model.records.count == 250)
    }

    @Test("筛选真实下推：破坏性与结果分桶都改变服务端查询，而不是本地事后删行")
    func filtersPushDownIntoTheQuery() async {
        let destructiveRunning = makeCommand("rm -rf /tmp/cache", exitCode: nil, outcome: .running, isDestructive: true)
        let model = CommandsModel(runtime: makeRuntime(commands: [
            destructiveRunning,
            makeCommand("git status", startedAt: offset(-60), endedAt: offset(-59), exitCode: 0),
            makeCommand("swift test", startedAt: offset(-30), endedAt: offset(-1), exitCode: 1, outcome: .failure)
        ]))
        await model.setTimeRange(.all)
        #expect(model.query.destructiveOnly == false)
        #expect(model.totalCount == 3)
        #expect(model.successCount == 1)
        #expect(model.failureCount == 1)
        #expect(model.unknownResultCount == 1)

        await model.setDestructiveOnly(true)
        #expect(model.query.destructiveOnly)
        #expect(model.records.map(\.commandLine) == ["rm -rf /tmp/cache"])
        #expect(model.activeFilterCount == 1)

        await model.setExitFilter(.unknownResult)
        #expect(model.query.outcomes == [.running, .unknown, .terminated])
        #expect(model.totalCount == 1)
        #expect(model.records.first?.outcome == .running)

        await model.resetFilters()
        #expect(model.activeFilterCount == 0)
        #expect(model.totalCount == 3)
    }

    @Test("空态可区分：库里就没有 vs 被筛选条件筛光")
    func emptyStatesAreDistinguishable() async {
        let empty = CommandsModel(runtime: makeRuntime(commands: []))
        await empty.setTimeRange(.all)
        #expect(empty.records.isEmpty)
        #expect(empty.activeFilterCount == 0)
        #expect(!empty.hasNarrowedFilters)   // → 「还没有采到命令」

        let populated = CommandsModel(runtime: makeRuntime(commands: [
            makeCommand("git push", endedAt: offset(2))
        ]))
        await populated.setTimeRange(.all)
        await populated.setSearchText("nothing-matches-this")
        #expect(populated.records.isEmpty)
        #expect(populated.activeFilterCount == 1)
        #expect(populated.hasNarrowedFilters)  // → 「当前筛选下没有命令」
        #expect(populated.totalCount == 0)
    }

    @Test("只看某个会话：详情面板的收窄动作与过滤条的撤销入口共用同一份条件")
    func sessionFocusIsReversible() async {
        let target = UUID()
        let other = UUID()
        let model = CommandsModel(runtime: makeRuntime(commands: [
            makeCommand("ls", sessionID: target),
            makeCommand("pwd", sessionID: other)
        ]))
        await model.setTimeRange(.all)
        #expect(model.focusedSessionID == nil)

        await model.focusSession(target)
        #expect(model.focusedSessionID == target)
        #expect(model.query.sessionID == target)
        #expect(model.records.map(\.commandLine) == ["ls"])

        await model.focusSession(nil)
        #expect(model.focusedSessionID == nil)
        #expect(model.totalCount == 2)
    }

    @Test("Agent 维度同样可组合：选中一项就收窄，全选等价于不选")
    func agentKindsRoundTrip() async {
        let model = CommandsModel(runtime: makeRuntime(commands: [
            makeCommand("claude run", kind: .claudeCode),
            makeCommand("codex run", kind: .openAICodex),
            makeCommand("aider run", kind: .aiderCLI)
        ]))
        await model.setTimeRange(.all)
        await model.toggleAgentKind(.claudeCode)
        #expect(model.query.agentKinds == [.claudeCode])
        #expect(model.records.map(\.commandLine) == ["claude run"])

        await model.setAgentKinds(Set(AgentKind.allCases))
        #expect(model.query.agentKinds.isEmpty)   // 全选 == 放开，避免「看起来在筛其实没筛」
        #expect(model.totalCount == 3)
    }

    @Test("状态条数字自洽：成功 + 失败 + 结果未知 恰好等于已加载条数")
    func statusCountsAreAdditive() async {
        let model = CommandsModel(runtime: makeRuntime(commands: [
            makeCommand("a", endedAt: offset(1), exitCode: 0),
            makeCommand("b", startedAt: offset(2), endedAt: offset(3), exitCode: 2, outcome: .failure),
            makeCommand("c", startedAt: offset(4), exitCode: nil, outcome: .running),
            makeCommand("d", startedAt: offset(5), exitCode: nil, outcome: .terminated)
        ]))
        await model.setTimeRange(.all)
        #expect(model.successCount + model.failureCount + model.unknownResultCount == model.records.count)
        #expect(model.unknownResultCount == 2)
        #expect(model.progressText(.chineseSimplified) == "共 4 条命令 · 已加载 4")
        #expect(model.outcomeSummaryText(.chineseSimplified) == "成功 1 · 失败 1 · 结果未知 2")
        // 两条没有结束时间的命令不进总时长。
        #expect(model.measuredDuration == 2)
    }
}
