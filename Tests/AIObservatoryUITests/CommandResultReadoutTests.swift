//
//  CommandResultReadoutTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-Verify
//
//  守的是真机截图抓出来的那条谎：库里 13 条命令 exit_code 全为 NULL、
//  outcome 全是 running，会话详情却给绿色的「全部通过」。
//  只要有人把「拿不到退出码」重新渲染成「没问题」，这里立刻红。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: 会话读数 · 没采到不等于全通过")
struct CommandResultReadoutTests {

    @Test("一条退出码都没采到：报「结果未知」，绝不报「全部通过」")
    func nothingResolvedIsNotAllPassed() {
        let readout = CommandResultReader.read(
            failedCommands: 0,
            totalCommands: 13,
            loadedOutcomes: Array(repeating: CommandOutcome.running, count: 13)
        )
        #expect(readout == .nothingResolved(13))
        #expect(readout.caption(.chineseSimplified).contains("结果未知"))
        #expect(!readout.isConfirmedClean, "拿不到退出码时不许染成表示「确认安全」的绿色")
    }

    @Test("unknown 也不算成功：全 unknown 时同样不能说全通过")
    func unknownIsNotResolved() {
        #expect(!CommandResultReader.isResolved(.unknown))
        #expect(!CommandResultReader.isResolved(.running))
        #expect(CommandResultReader.isResolved(.success))
        #expect(CommandResultReader.isResolved(.failure))
        let readout = CommandResultReader.read(
            failedCommands: 0, totalCommands: 4,
            loadedOutcomes: [.unknown, .unknown, .unknown, .unknown]
        )
        #expect(readout == .nothingResolved(4))
    }

    /// #76 新增：`.terminated` 以前在这里被判成「已解决」（与引擎侧红线相反的那一侧），
    /// 于是真机 86 条 ⌘Q 收口出来的 terminated 会把会话瓷贴推向「全部通过」。
    /// 现在它与 `.running` / `.unknown` 同属「还不知道」，一条都不算 resolved。
    @Test("terminated 不是「已解决」：全是 terminated 时同样不能说全通过")
    func terminatedIsNotResolved() {
        #expect(!CommandResultReader.isResolved(.terminated),
                "红线：`.terminated` 不等于成功也不等于失败（ObservatoryEngine+Ingestion.settleOpenCommands）")
        let readout = CommandResultReader.read(
            failedCommands: 0, totalCommands: 3,
            loadedOutcomes: [.terminated, .terminated, .terminated]
        )
        #expect(readout == .nothingResolved(3))
        #expect(!readout.isConfirmedClean)
        #expect(!readout.hasFailure, "没采到退出码 ⇒ 也不许报「有失败」")
        // 混合：两条 terminated + 一条真成功 ⇒ 「部分结果未知」，仍然不是全通过。
        let mixed = CommandResultReader.read(
            failedCommands: 0, totalCommands: 3,
            loadedOutcomes: [.terminated, .terminated, .success]
        )
        #expect(mixed == .partiallyResolved(resolved: 1, loaded: 3))
        #expect(!mixed.isConfirmedClean)
    }

    @Test("每条都真的拿到成功退出码：这时才允许说「全部通过」")
    func allPassedRequiresEveryOutcomeResolved() {
        let readout = CommandResultReader.read(
            failedCommands: 0, totalCommands: 3,
            loadedOutcomes: [.success, .success, .success]
        )
        #expect(readout == .allPassed)
        #expect(readout.caption(.chineseSimplified) == "全部通过")
        #expect(readout.isConfirmedClean)
    }

    @Test("明细只加载了一部分：不能对整体下结论")
    func partialLoadBlocksVerdict() {
        let readout = CommandResultReader.read(
            failedCommands: 0, totalCommands: 40,
            loadedOutcomes: Array(repeating: CommandOutcome.success, count: 20)
        )
        #expect(readout == .partiallyLoaded(loaded: 20, total: 40))
        #expect(!readout.isConfirmedClean)
    }

    @Test("混合：一部分有退出码、一部分没有 ⇒ 说「部分结果未知」而不是「全部通过」")
    func mixedOutcomesArePartiallyResolved() {
        let readout = CommandResultReader.read(
            failedCommands: 0, totalCommands: 4,
            loadedOutcomes: [.success, .success, .running, .unknown]
        )
        #expect(readout == .partiallyResolved(resolved: 2, loaded: 4))
        #expect(!readout.isConfirmedClean)
    }

    @Test("真有失败：数字可信，直接报失败条数")
    func failuresAreReported() {
        let readout = CommandResultReader.read(
            failedCommands: 2, totalCommands: 5,
            loadedOutcomes: [.success, .failure, .failure, .running, .running]
        )
        #expect(readout == .someFailed(2))
        #expect(readout.hasFailure)
    }

    @Test("一条命令都没有：说「无命令记录」，不说「全部通过」")
    func emptyIsNotAllPassed() {
        let readout = CommandResultReader.read(
            failedCommands: 0, totalCommands: 0, loadedOutcomes: []
        )
        #expect(readout == .noCommands)
        #expect(!readout.isConfirmedClean)
    }
}
