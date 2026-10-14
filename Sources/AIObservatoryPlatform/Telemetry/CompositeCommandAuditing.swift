//
//  CompositeCommandAuditing.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-CmdSrc
//  ─────────────────────────────────────────────────────────
//  两条命令来源的组合（IFR-command-precision 设计约束 1）：
//    · 采样来源（`CommandInferenceEngine`）：轮询进程表反推，长命令兜底，永远拿不到退出码；
//    · hook 来源（`HookCommandAuditing`）：当事进程自己落盘，命令/退出码/耗时三格齐全。
//  **重叠时以 hook 为准**——它有 `exit_code`，采样那条只是同一件事的残缺版本。
//
//  重叠判定口径：`CommandRecord` 契约里没有 pid（冻结契约，本车道不改），
//  所以只能按「同一 Agent + 同一命令行文本 + `startedAt` 相差在 `overlapWindow` 内」判同一件事。
//  窗口默认 2 秒：采样的 `startTime` 取的是进程启动时刻，hook 的 `startedAt` 是工具调用时刻，
//  两者本来就差一个 shell/`exec` 的启动开销。超出窗口就当两次独立执行，宁可多记一条也不误吞。
//
//  幂等：产出过的记录 id 记进有界集合，同一 id 不再往外抛第二次。
//  hook 记录的 id 由事件内容派生（见 `AgentHookEvent.recordID`），因此偏移文件被清、
//  上游重放同一事件时，这里也只会落一次；采样侧每轮都是新 id，不会被误吞。
//

import Foundation
import os
import AIObservatoryCore

/// 采样来源 + hook 来源的组合命令审计器。
public final class CompositeCommandAuditing: CommandAuditing, Sendable {

    private let sampling: any CommandAuditing
    private let hook: any CommandAuditing
    private let overlapWindow: TimeInterval
    private let emittedCapacity: Int
    private let emitted = OSAllocatedUnfairLock(initialState: Emitted())

    /// - Parameters:
    ///   - sampling: 轮询兜底来源。
    ///   - hook: 精确来源（hook 落盘）。
    ///   - overlapWindow: 判定「同一件事」的时间容差（秒）。
    ///   - emittedCapacity: 幂等集合的容量上限；超出的按 FIFO 淘汰。
    public init(
        sampling: any CommandAuditing,
        hook: any CommandAuditing,
        overlapWindow: TimeInterval = 2,
        emittedCapacity: Int = 2048
    ) {
        self.sampling = sampling
        self.hook = hook
        self.overlapWindow = max(overlapWindow, 0)
        self.emittedCapacity = max(emittedCapacity, 1)
    }

    /// 先取 hook（它决定哪些采样记录算重复），再取采样，合并后按 `startedAt` 升序。
    public func inferCommands(
        processes: [ProcessRecord],
        agents: [AgentInstance],
        since: Date
    ) -> [CommandRecord] {
        let precise = hook.inferCommands(processes: processes, agents: agents, since: since)
        let sampled = sampling.inferCommands(processes: processes, agents: agents, since: since)
            .filter { !isCovered(by: $0, with: precise) }

        var merged = precise + sampled
        merged.sort { $0.startedAt < $1.startedAt }
        return firstTimeThrough(merged)
    }

    /// 分级委托给 hook 来源：与采样来源共用同一份 `DestructiveCommandRules`，
    /// 因此同一条命令在两边拿到的等级必然一致。
    public func classify(command: String) -> CommandClassification {
        hook.classify(command: command)
    }

    // MARK: - 重叠判定

    private func isCovered(by record: CommandRecord, with precise: [CommandRecord]) -> Bool {
        let line = Self.normalize(record.commandLine)
        return precise.contains { candidate in
            candidate.agentID == record.agentID
                && candidate.agentKind == record.agentKind
                && Self.normalize(candidate.commandLine) == line
                && abs(candidate.startedAt.timeIntervalSince(record.startedAt)) <= overlapWindow
        }
    }

    /// 只折叠空白：`rm   -rf  ./x` 与 `rm -rf ./x` 算同一条命令；大小写不同算不同命令。
    ///
    /// 这里刻意要求**整条命令行文本**相等，不做前缀/截断匹配：采样侧 argv 不完整时
    /// 顶多退化成「多留一条 `.running` 的采样记录」（少合并），而前缀匹配会把
    /// `rm -rf ./a` 与 `rm -rf ./b` 合并掉——那是在丢真实命令，审计工具不可接受。
    /// （main `41aec4e` 之前 `KERN_PROCARGS2` 丢末位参数，本判据曾因此少合并；已随该修复恢复。）
    private static func normalize(_ text: String) -> String {
        text.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" })
            .joined(separator: " ")
    }

    // MARK: - 幂等

    private func firstTimeThrough(_ records: [CommandRecord]) -> [CommandRecord] {
        emitted.withLock { state in
            var fresh: [CommandRecord] = []
            fresh.reserveCapacity(records.count)
            for record in records where state.remember(record.id, capacity: emittedCapacity) {
                fresh.append(record)
            }
            return fresh
        }
    }

    private struct Emitted {
        private(set) var ordered: [UUID] = []
        private(set) var seen: Set<UUID> = []

        /// 没见过返回 true（并记下）；见过返回 false。超出容量按 FIFO 淘汰。
        mutating func remember(_ id: UUID, capacity: Int) -> Bool {
            guard !seen.contains(id) else { return false }
            ordered.append(id)
            seen.insert(id)
            while ordered.count > capacity {
                seen.remove(ordered.removeFirst())
            }
            return true
        }
    }
}
