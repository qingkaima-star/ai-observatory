//
//  CompositeCommandAuditingTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-CmdSrc
//  ─────────────────────────────────────────────────────────
//  两条命令来源组合后的口径（IFR-command-precision 设计约束 1）：
//  重叠时 hook 胜出（它有 exit_code），不重叠时采样兜底，且整体幂等。
//
//  hook 侧用**真实**的 `HookCommandAuditing` + scratch 目录里的 jsonl，
//  这样「组合」这条路是真跑通而不是桩对桩。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 测试辅助

private let base = Date(timeIntervalSinceReferenceDate: 800_000_500)

/// 定长返回一批记录的审计器（模拟 `CommandInferenceEngine`：每次调用都新建记录、自然是新 id）。
private struct FreshIDSamplingAuditor: CommandAuditing {
    var makeRecords: @Sendable () -> [CommandRecord]
    func inferCommands(processes: [ProcessRecord], agents: [AgentInstance], since: Date) -> [CommandRecord] {
        makeRecords()
    }
    func classify(command: String) -> CommandClassification { DestructiveCommandRules().classify(command: command) }
}

/// 固定记录的审计器（模拟 hook 侧重放出同一事件：偏移丢了 / 上游重试）。
private struct FixedRecordAuditor: CommandAuditing {
    var records: [CommandRecord]
    func inferCommands(processes: [ProcessRecord], agents: [AgentInstance], since: Date) -> [CommandRecord] {
        records
    }
    func classify(command: String) -> CommandClassification { DestructiveCommandRules().classify(command: command) }
}

/// 采样来源的典型产出：只有命令文本，`outcome` 恒 running、`exitCode` 恒空。
private func sampled(_ command: String, agent: AgentInstance, at startedAt: Date) -> CommandRecord {
    let argv = CommandInferenceEngine().inferCommands(
        processes: [ProcessRecord(
            pid: 7_000,
            parentPID: agent.pid,
            name: String(command.split(separator: " ").first ?? "?"),
            arguments: Array(command.split(separator: " ").dropFirst()).map(String.init),
            startTime: startedAt
        )],
        agents: [agent],
        since: .distantPast
    )
    var record = argv.first ?? CommandRecord(executable: command, agentID: agent.id, startedAt: startedAt)
    record.agentID = agent.id
    return record
}

private func claudeAgent() -> AgentInstance {
    AgentInstance(
        kind: .claudeCode,
        pid: 4242,
        displayName: "Claude Code",
        executablePath: "/usr/local/bin/claude",
        startedAt: base
    )
}

/// 真 hook 来源的夹具：在 scratch 里铺一个 `<store>/agent-hooks/claude.jsonl`，离开作用域即删。
private final class HookBackedFixture {
    let root: URL
    let auditing: HookCommandAuditing

    init(lines: [String]) throws {
        let root = try Scratch.directory("hook-composite")
        self.root = root
        let store = root.appendingPathComponent("store", isDirectory: true)
        let hooks = store.appendingPathComponent("agent-hooks", isDirectory: true)
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        let text = (lines.isEmpty ? "" : lines.joined(separator: "\n") + "\n").data(using: .utf8)!
        try text.write(to: hooks.appendingPathComponent("claude.jsonl"))
        auditing = HookCommandAuditing(storeDirectoryURL: store)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

private func hookLine(agentKind: String = "claudeCode", command: String, startedAt: Date, exitCode: Int = 0) -> String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return "{\"agentKind\":\"\(agentKind)\",\"command\":\"\(command)\",\"startedAt\":\"\(formatter.string(from: startedAt))\",\"exitCode\":\(exitCode),\"source\":\"hook\"}"
}

// MARK: - 用例

@Suite("Composite 命令来源：hook 胜出与幂等", .timeLimit(.minutes(1)))
struct CompositeCommandAuditingTests {

    @Test("同一条命令两边都有：只留 hook 那条，退出码保住")
    func hookWinsOnOverlap() throws {
        let agent = claudeAgent()
        let source = try HookBackedFixture(lines: [hookLine(command: "rm -rf ./junk", startedAt: base.addingTimeInterval(0.1))])
        let composite = CompositeCommandAuditing(
            sampling: FreshIDSamplingAuditor { [sampled("rm -rf ./junk", agent: agent, at: base)] },
            hook: source.auditing
        )

        let records = composite.inferCommands(processes: [], agents: [agent], since: .distantPast)
        #expect(records.count == 1)
        #expect(records.first?.commandLine == "rm -rf ./junk")
        #expect(records.first?.exitCode == 0)
        #expect(records.first?.outcome == .success)
        #expect(records.first?.isDestructive == true)
    }

    @Test("不重叠时两条都在：采样继续兜未装 hook 的长命令")
    func nonOverlappingSourcesBothLand() throws {
        let agent = claudeAgent()
        let source = try HookBackedFixture(lines: [hookLine(command: "git status", startedAt: base)])
        let composite = CompositeCommandAuditing(
            sampling: FreshIDSamplingAuditor { [sampled("xcodebuild clean build", agent: agent, at: base)] },
            hook: source.auditing
        )

        let lines = composite.inferCommands(processes: [], agents: [agent], since: .distantPast).map(\.commandLine)
        #expect(lines.contains("git status"))
        #expect(lines.contains("xcodebuild clean build"))
        #expect(lines.count == 2)
    }

    @Test("同命令但相差 30 秒：是两次执行，不合并")
    func sameCommandOutsideWindowIsTwoExecutions() throws {
        let agent = claudeAgent()
        let source = try HookBackedFixture(lines: [hookLine(command: "npm test", startedAt: base.addingTimeInterval(30))])
        let composite = CompositeCommandAuditing(
            sampling: FreshIDSamplingAuditor { [sampled("npm test", agent: agent, at: base)] },
            hook: source.auditing
        )
        #expect(composite.inferCommands(processes: [], agents: [agent], since: .distantPast).count == 2)
    }

    @Test("同命令同时间但不同 Agent：不跨 Agent 误合并")
    func differentAgentKindsDoNotCollapse() throws {
        let claude = claudeAgent()
        let codex = AgentInstance(
            kind: .openAICodex,
            pid: 9_999,
            displayName: "Codex",
            executablePath: "/usr/local/bin/codex",
            startedAt: base
        )
        let source = try HookBackedFixture(lines: [hookLine(agentKind: "codex", command: "ls -la", startedAt: base)])
        let composite = CompositeCommandAuditing(
            sampling: FreshIDSamplingAuditor { [sampled("ls -la", agent: claude, at: base)] },
            hook: source.auditing
        )
        #expect(composite.inferCommands(processes: [], agents: [claude, codex], since: .distantPast).count == 2)
    }

    @Test("幂等：同一 hook 事件被重放两次，第二次不再产出")
    func replayedHookRecordSuppressedOnce() {
        let agent = claudeAgent()
        let record = CommandRecord(
            executable: "echo",
            arguments: ["hi"],
            agentID: agent.id,
            agentKind: .claudeCode,
            startedAt: base,
            exitCode: 0,
            outcome: .success
        )
        let composite = CompositeCommandAuditing(
            sampling: FreshIDSamplingAuditor {
                // 采样侧每轮新建记录 ⇒ 新 id，不该被幂等护栏误吞。
                [CommandRecord(executable: "sleep", arguments: ["1"], agentID: agent.id,
                               agentKind: .claudeCode, startedAt: base.addingTimeInterval(1))]
            },
            hook: FixedRecordAuditor(records: [record])
        )
        let first = composite.inferCommands(processes: [], agents: [agent], since: .distantPast)
        let second = composite.inferCommands(processes: [], agents: [agent], since: .distantPast)
        #expect(first.count == 2)
        #expect(first.contains { $0.id == record.id })
        #expect(second.count == 1)
        #expect(second.contains { $0.id == record.id } == false)
    }

    @Test("合并结果按 startedAt 升序")
    func mergedRecordsSortedByStartedAt() throws {
        let agent = claudeAgent()
        let source = try HookBackedFixture(lines: [hookLine(command: "later", startedAt: base.addingTimeInterval(5))])
        let composite = CompositeCommandAuditing(
            sampling: FreshIDSamplingAuditor { [sampled("earlier", agent: agent, at: base)] },
            hook: source.auditing
        )
        let executables = composite.inferCommands(processes: [], agents: [agent], since: .distantPast).map(\.executable)
        #expect(executables == ["earlier", "later"])
    }

    @Test("两边都没数据：空数组，不崩")
    func bothSourcesEmpty() throws {
        let source = try HookBackedFixture(lines: [])
        let composite = CompositeCommandAuditing(
            sampling: FreshIDSamplingAuditor { [] },
            hook: source.auditing
        )
        #expect(composite.inferCommands(processes: [], agents: [], since: .distantPast).isEmpty)
    }

    @Test("classify 走同一份规则库：与采样来源分级一致")
    func classifySharesRuleBook() {
        let composite = CompositeCommandAuditing(
            sampling: CommandInferenceEngine(),
            hook: FixedRecordAuditor(records: [])
        )
        #expect(composite.classify(command: "rm -rf /").level == .high)
        #expect(composite.classify(command: "rm -rf /").isDestructive)
        #expect(composite.classify(command: "echo hi") == .benign)
    }
}
