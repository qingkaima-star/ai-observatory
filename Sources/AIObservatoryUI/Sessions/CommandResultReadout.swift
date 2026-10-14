//
//  CommandResultReadout.swift
//  AIObservatoryUI / Sessions
//
//  Owner: WS-Verify
//  ─────────────────────────────────────────────────────────
//  「失败命令 0」这句读数到底能说什么，抽出来单独可测。
//
//  为什么值得抽出来：这是「没采到」被渲染成「没问题」唯一能被机器抓住的地方。
//  命令审计靠轮询进程快照，采样**永远看不到退出码**
//  （见 `01-架构/真机验证-命令审计与检出.md`：真机 13 条命令 exit_code 全为 NULL）。
//  于是 `failedCommandCount == 0` 在真机上是常态，
//  而界面一旦把它写成绿色的「全部通过」，就是在替用户宣布「这些命令都成功了」——
//  一个审计工具最不该撒的谎。规则抽到这里后，改回「全部通过」会立刻红。
//

import Foundation
import AIObservatoryCore

/// 会话「失败命令」瓷贴的读数结论。
enum CommandResultReadout: Equatable {

    /// 有失败：数字可信，直接报。
    case someFailed(Int)
    /// 这个会话一条命令都没有。
    case noCommands
    /// 明细只加载了一部分，不能对整体下结论。
    case partiallyLoaded(loaded: Int, total: Int)
    /// 一条退出码都没采到 ⇒ 成败**未知**，不是「全通过」。
    case nothingResolved(Int)
    /// 只有一部分命令拿到了退出码。
    case partiallyResolved(resolved: Int, loaded: Int)
    /// 每条命令都真的拿到了成功的退出码 ⇒ 这时才允许说「全部通过」。
    case allPassed

    var caption: String { caption(UILanguage.current) }

    func caption(_ language: AppLanguage) -> String {
        switch self {
        case .someFailed(let n):      return SessionsCopy.resultSomeFailed.copy.format(language, n)
        case .noCommands:             return SessionsCopy.resultNoCommands.text(language)
        case .partiallyLoaded(let l, let t): return SessionsCopy.resultPartiallyLoaded.copy.format(language, l, t)
        case .nothingResolved:        return SessionsCopy.resultNothingResolved.text(language)
        case .partiallyResolved(let r, let l): return SessionsCopy.resultPartiallyResolved.copy.format(language, r, l)
        case .allPassed:              return SessionsCopy.resultAllPassed.text(language)
        }
    }

    /// 只有真的确认过每条命令都成功，才可以染成「安全」的绿色。
    var isConfirmedClean: Bool {
        if case .allPassed = self { return true }
        return false
    }

    var hasFailure: Bool {
        if case .someFailed = self { return true }
        return false
    }
}

/// 读数口径（面板与任何未来的导出/报表共用，避免出现第二套规则）。
enum CommandResultReader {

    /// 拿到退出码、能对成败下结论的结果。
    /// `.running` 与 `.unknown` 都是「还不知道」，不能算成功也不能算失败。
    ///
    /// ⚠️ #76：`.terminated` **同样不算已解决**（此前这里是 `return true`，与下面两处打架：
    /// 引擎侧 `ObservatoryEngine+Ingestion.settleOpenCommands` 的口径红线
    /// 「`.terminated` 不等于成功也不等于失败——没有 shell hook 就不知道退出码」，
    /// 以及契约侧 `Core/Contracts/StoreProtocols.terminateOpenCommands` 的同一句注释——
    /// 那两条都点名「见 `CommandResultReader.isResolved` 的口径」，而这一头当时正把
    /// terminated 判成已解决，等于红线指着一个违反它的地方当依据）。
    /// 后果是可量化的：一条 terminated 记录会让 `read(...)` 往「全部通过」那一格走
    /// （真机 86 条 terminated 全部来自 ⌘Q 收口、退出码恒为 NULL），
    /// 而「已解决」这个前提根本不成立。
    static func isResolved(_ outcome: CommandOutcome) -> Bool {
        switch outcome {
        case .success, .failure:    return true
        case .running, .unknown, .terminated: return false
        }
    }

    static func read(
        failedCommands: Int,
        totalCommands: Int,
        loadedOutcomes: [CommandOutcome]
    ) -> CommandResultReadout {
        if failedCommands > 0 { return .someFailed(failedCommands) }
        guard totalCommands > 0 else { return .noCommands }
        guard loadedOutcomes.count >= totalCommands else {
            return .partiallyLoaded(loaded: loadedOutcomes.count, total: totalCommands)
        }
        let resolved = loadedOutcomes.filter { isResolved($0) }
        guard !resolved.isEmpty else { return .nothingResolved(totalCommands) }
        guard resolved.count == loadedOutcomes.count else {
            return .partiallyResolved(resolved: resolved.count, loaded: loadedOutcomes.count)
        }
        // 到这里每条都有退出码、且一条都没失败。
        return .allPassed
    }
}

private extension CommandResultReadout {
    /// 语言不写死在渲染里：`caption` 无参版走本次启动解析一次的语言（`UILanguage`），
    /// 用例走 `caption(_:)` 显式要哪一种——测试进程读宿主系统语言不可靠。
    var language: AppLanguage { UILanguage.current }
}
