//
//  CommandCandidateSetTests.swift
//  AIObservatoryPlatformTests — Telemetry
//
//  Owner: WS-ProcScan
//
//  命令审计的**候选集**：改法把「每个进程各自沿父链向上试探」换成「从 Agent 向下扩散一次」，
//  因此这里钉的是两件事——
//   1. 两个方向的候选集**逐元素相等**（含快照顺序），不是「条数 ≥ 1」；
//   2. fidelity 不丢：Agent 的子进程跑 `rm -rf` 仍被审计到，且归因到正确的那个 Agent。
//  候选集通过公开 API 观测：夹具里进程名唯一（"cmd<pid>"），于是 `CommandRecord.executable`
//  就是 pid 的可读别名，不必把内部集合暴露出来配合测试。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

// MARK: - 参考实现：改动前「每个进程向上试探」的原始形状

/// 含旧的 `guardCount < 1024` 兜底与 `uniquingKeysWith: { $1 }`（后者对唯一 pid 无影响）。
private func legacyUpwardProbeNames(processes: [ProcessRecord], agents: [AgentInstance]) -> [String] {
    let byPID = Dictionary(processes.map { ($0.pid, $0) }, uniquingKeysWith: { $1 })
    let agentPIDs = Set(agents.map(\.pid))
    var kept: [String] = []
    for proc in processes {
        guard !agentPIDs.contains(proc.pid) else { continue }
        var pid = proc.parentPID
        var guardCount = 0
        var hitAgent = false
        while let current = pid, guardCount < 1024 {
            if agents.contains(where: { $0.pid == current }) { hitAgent = true; break }
            pid = byPID[current]?.parentPID
            guardCount += 1
        }
        if hitAgent || agents.contains(where: { $0.childPIDs.contains(proc.pid) }) {
            kept.append(proc.name)
        }
    }
    return kept
}

private func procRecord(_ pid: Int32, _ ppid: Int32?, arguments: [String] = []) -> ProcessRecord {
    ProcessRecord(pid: pid, parentPID: ppid, name: "cmd\(pid)", arguments: arguments, startTime: .distantPast)
}

/// 一份覆盖各种形状的进程图。Agent 实例与进程记录分开给，因为真实链路里它们来自不同环节。
private struct Fixture {
    let processes: [ProcessRecord]
    let agents: [AgentInstance]
    let idA: UUID
    let idB: UUID
    let idC: UUID
}

private func makeFixture() -> Fixture {
    let idA = UUID()
    let idB = UUID()
    let idC = UUID()
    let started = Date.distantPast   // 与 since: .distantPast 相等 ⇒ `start < since` 为假，全部纳入

    let processes: [ProcessRecord] = [
        procRecord(1, nil),                       // launchd
        procRecord(100, 1),                       // Agent A 本体
        procRecord(101, 100, arguments: ["-rf", "/tmp/build"]),
        procRecord(102, 101),                     // A 的孙
        procRecord(110, 1),                       // node
        procRecord(111, 110),                     // Agent B（挂在 node 下）
        procRecord(112, 111),
        procRecord(113, 112),
        procRecord(150, 100),                     // Agent C：本身是 A 的子孙 → 测「取最近」
        procRecord(151, 150),                     // C 的子：归因必须是 C 不是 A
        procRecord(200, 1),                       // 与 Agent 无关的子树
        procRecord(201, 200),
        procRecord(300, 999),                     // 父不在快照里，且 999 也不是 Agent
        procRecord(310, 310),                     // 自环
        procRecord(320, 321),                     // 两节点环
        procRecord(321, 320),
        procRecord(400, nil),                      // 图上不连通，仅由 B 的 childPIDs 显式登记
    ]
    let agents: [AgentInstance] = [
        AgentInstance(id: idA, kind: .claudeCode, pid: 100, parentPID: 1,
                      displayName: "Claude", executablePath: "/usr/local/bin/claude", startedAt: started),
        AgentInstance(id: idB, kind: .openAICodex, pid: 111, parentPID: 110,
                      displayName: "Codex", executablePath: "/usr/local/bin/codex",
                      startedAt: started, childPIDs: [400]),
        AgentInstance(id: idC, kind: .geminiCLI, pid: 150, parentPID: 100,
                      displayName: "Gemini", executablePath: "/usr/local/bin/gemini", startedAt: started),
    ]
    return Fixture(processes: processes, agents: agents, idA: idA, idB: idB, idC: idC)
}

private func audit(_ fixture: Fixture) -> [CommandRecord] {
    CommandInferenceEngine().inferCommands(
        processes: fixture.processes, agents: fixture.agents, since: .distantPast
    )
}

// MARK: - 候选集等价

@Suite("命令审计：候选集与「向上试探」逐元素相等", .timeLimit(.minutes(1)))
struct CommandCandidateSetTests {

    @Test("两个方向给出的候选集完全相同（含快照顺序）")
    func candidateSetsMatch() {
        let fixture = makeFixture()
        let newNames = audit(fixture).map(\.executable)
        #expect(newNames == ["cmd101", "cmd102", "cmd112", "cmd113", "cmd151", "cmd400"])
        #expect(
            newNames == legacyUpwardProbeNames(processes: fixture.processes, agents: fixture.agents),
            "向下扩散与向上试探的候选集不一致"
        )
    }

    @Test("图上不连通、仅由 Agent 登记 childPIDs 的进程仍进候选集")
    func declaredChildOnly() throws {
        let fixture = makeFixture()
        let record = try #require(audit(fixture).first(where: { $0.executable == "cmd400" }))
        #expect(record.agentID == fixture.idB)
    }

    @Test("嵌套 Agent：孙进程归因到最近的那个，不是最上层")
    func nearestAgentWins() {
        let fixture = makeFixture()
        let attribution = Dictionary(uniqueKeysWithValues: audit(fixture).map { ($0.executable, $0.agentID) })
        #expect(attribution["cmd101"] == fixture.idA)
        #expect(attribution["cmd102"] == fixture.idA)
        #expect(attribution["cmd151"] == fixture.idC)   // ← 不是 idA
        #expect(attribution["cmd112"] == fixture.idB)
        #expect(attribution["cmd113"] == fixture.idB)
    }

    @Test("Agent 自身、无关子树、断链、自环、双节点环都不进候选集")
    func excludedProcessesStayOut() {
        let fixture = makeFixture()
        let names = Set(audit(fixture).map(\.executable))
        for excluded in [100, 111, 150, 200, 201, 300, 310, 320, 321] {
            #expect(!names.contains("cmd\(excluded)"), "pid \(excluded) 不该被审计")
        }
    }

    @Test("父链成环时终止，且环内进程不会被重复计入")
    func cyclicGraphTerminates() {
        let agentID = UUID()
        let processes = [
            procRecord(100, 100),                 // 自环，且是 Agent
            procRecord(200, 300),                 // 两节点环，与 Agent 无连通
            procRecord(300, 200),
            procRecord(101, 100),                 // Agent 的直接子
        ]
        let agents = [
            AgentInstance(id: agentID, kind: .claudeCode, pid: 100, parentPID: 100,
                          displayName: "Claude", executablePath: "/usr/local/bin/claude",
                          startedAt: .distantPast),
        ]
        let inferred = CommandInferenceEngine().inferCommands(
            processes: processes, agents: agents, since: .distantPast
        )
        #expect(inferred.map(\.executable) == ["cmd101"])
    }

    /// 真机快照里 pid 不可能重复（出自 `proc_listpids`），但 `inferCommands` 是公开 API，
    /// 收的是任意数组（回放快照就可能带重复）。索引只能记住一条记录的父，
    /// 所以第一跳必须沿用「这条记录自己写明的 parentPID」——两条都要钉住。
    @Test("同一 pid 出现两条且父不同：两个方向都按各自那条记录的父上溯")
    func duplicatePIDEntriesKeepOwnParent() {
        let agentID = UUID()
        let agents = [
            AgentInstance(id: agentID, kind: .claudeCode, pid: 2,
                          displayName: "Claude", executablePath: "/usr/local/bin/claude",
                          startedAt: .distantPast),
        ]
        // 同一个 pid 10，两条记录的父分别是 2（是 Agent）和 1（不在快照里）。
        let entriesOwnParent = [
            ProcessRecord(pid: 10, parentPID: 2, name: "cmd10a", startTime: .distantPast),
            ProcessRecord(pid: 10, parentPID: 1, name: "cmd10b", startTime: .distantPast),
        ]
        let inferredA = CommandInferenceEngine().inferCommands(
            processes: entriesOwnParent, agents: agents, since: .distantPast
        )
        #expect(inferredA.map(\.executable) == ["cmd10a"])
        #expect(
            inferredA.map(\.executable)
                == legacyUpwardProbeNames(processes: entriesOwnParent, agents: agents)
        )

        // 换个数：Agent 挂在 1 上，被审计的就该换成另一条记录。
        let otherParented = [
            AgentInstance(id: agentID, kind: .claudeCode, pid: 1,
                          displayName: "Claude", executablePath: "/usr/local/bin/claude",
                          startedAt: .distantPast),
        ]
        let inferredB = CommandInferenceEngine().inferCommands(
            processes: entriesOwnParent, agents: otherParented, since: .distantPast
        )
        #expect(inferredB.map(\.executable) == ["cmd10b"])
        #expect(
            inferredB.map(\.executable)
                == legacyUpwardProbeNames(processes: entriesOwnParent, agents: otherParented)
        )
    }
}

// MARK: - fidelity（本任务的核心：改性能不许丢审计）

@Suite("命令审计：fidelity 不丢", .timeLimit(.minutes(1)))
struct CommandAuditFidelityTests {

    private let engine = CommandInferenceEngine()

    /// 简报钉住的那一条：agent pid=100、其子 pid=101 跑 `rm -rf …`。
    @Test("Agent 的子进程跑 rm -rf 仍被审计到且归属正确")
    func agentChildDestructiveCommandStillAudited() throws {
        let agentID = UUID()
        let agent = AgentInstance(
            id: agentID, kind: .claudeCode, pid: 100, parentPID: 1,
            displayName: "Claude", executablePath: "/usr/local/bin/claude",
            startedAt: Date().addingTimeInterval(-100)
        )
        let processes = [
            ProcessRecord(pid: 100, parentPID: 1, name: "claude",
                          startTime: Date().addingTimeInterval(-100)),
            ProcessRecord(
                pid: 101, parentPID: 100, name: "rm",
                arguments: ["-rf", "/tmp/build"], startTime: Date().addingTimeInterval(-5),
                workingDirectory: "/Users/demo/project"
            ),
        ]
        let records = engine.inferCommands(processes: processes, agents: [agent], since: .distantPast)
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.executable == "rm")
        #expect(record.arguments == ["-rf", "/tmp/build"])
        #expect(record.agentID == agentID)
        #expect(record.agentKind == .claudeCode)
        #expect(record.isDestructive)
        #expect(record.riskLevel == .high)
        #expect(record.workingDirectory == "/Users/demo/project")
    }

    /// 隔了几代的孙进程同样要抓到——候选集若只含「直接子」就会漏。
    @Test("Agent 的第三代子孙跑破坏性命令仍被审计到")
    func deepDescendantAudited() throws {
        let agentID = UUID()
        let agent = AgentInstance(
            id: agentID, kind: .claudeCode, pid: 100,
            displayName: "Claude", executablePath: "/usr/local/bin/claude",
            startedAt: Date().addingTimeInterval(-100)
        )
        let processes = [
            ProcessRecord(pid: 100, name: "claude", startTime: Date().addingTimeInterval(-100)),
            ProcessRecord(pid: 101, parentPID: 100, name: "zsh", startTime: Date().addingTimeInterval(-9)),
            ProcessRecord(pid: 102, parentPID: 101, name: "bash", startTime: Date().addingTimeInterval(-8)),
            ProcessRecord(pid: 103, parentPID: 102, name: "sudo", arguments: ["rm", "-rf", "/"],
                          startTime: Date().addingTimeInterval(-7)),
        ]
        let records = engine.inferCommands(processes: processes, agents: [agent], since: .distantPast)
        // 审计的是 Agent 子孙的**全部**命令，破坏性只是其中一条标记——只留破坏性的话就退化成告警器了。
        #expect(records.map(\.executable) == ["zsh", "bash", "sudo"])
        let destructive = try #require(records.first(where: { $0.executable == "sudo" }))
        #expect(destructive.agentID == agentID)
        #expect(destructive.isDestructive)
        #expect(records.filter(\.isDestructive).count == 1)
    }
}
