//
//  CommandInferenceEngine.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-Telemetry / WS-Platform（本轮只把「每条命令都在重做的常数」挪出热循环）
//
//  从进程树推断被 Agent 触发的命令，并归类其破坏性等级。
//  父链上命中 Agent 进程（或属于 Agent 已知子进程）的进程被归因为该 Agent 的命令。
//  工作目录优先用注入进程快照中的 workingDirectory；缺失时尝试 proc_pidinfo 补充，失败则 nil。
//
//  成本口径（AGENTS §6「合法杠杆 = 少做 syscall、少做分配」）：本函数是**纯内存**的一段，
//  真机 145 个候选要 17.64 ms（每候选 121 µs）。全部产出字段只有三个来自分级，所以这里
//  只留三件事：一次建树、一次向下扩散、每条**不同**的命令行判一次。
//  归因集合与产出顺序与改前逐元素相等（见 `candidatePIDs` / `nearestAgent` 上的注释）。
//

import Foundation
import Darwin
import AIObservatoryCore

/// 命令推断引擎，实现 `CommandAuditing`。
public struct CommandInferenceEngine: CommandAuditing {

    private let classifier: DestructiveCommandRules

    public init(classifier: DestructiveCommandRules = DestructiveCommandRules()) {
        self.classifier = classifier
    }

    /// 委托给规则库做破坏性分级。
    public func classify(command: String) -> CommandClassification {
        classifier.classify(command: command)
    }

    /// 从进程快照中推断由 Agent 触发的命令。
    ///
    /// - 跳过 Agent 自身进程。
    /// - 仅保留 `startTime >= since` 的进程（无 startTime 视为未知，纳入）。
    /// - 进程父链上命中任一 Agent PID 即归因；命中多个时取最近（层级最高）的一个。
    /// - 退出状态：进程轮询模式下只能观测到"运行中"，统一记为 `.running`（后续由 Engine 关联真实退出码）。
    ///
    /// 每轮只做一次建树 + 一次向下扩散，其余全是字典查询；同一条命令行本轮只判一次级别
    /// （`classify` 是纯函数，见下面 `classified` 的注释）。
    public func inferCommands(processes: [ProcessRecord], agents: [AgentInstance], since: Date) -> [CommandRecord] {
        let tree = ProcessTreeIndex(records: processes)
        let candidates = candidatePIDs(agents: agents, tree: tree)
        let agentByPID = Dictionary(agents.map { ($0.pid, $0) }, uniquingKeysWith: { first, _ in first })
        let agentPIDs = Set(agentByPID.keys)
        // 父链追不到时的那条兜底，改前写作 `agents.first { $0.childPIDs.contains(proc.pid) }`：
        // 每个走到兜底的候选都要重扫「全部 Agent × 各自全部子进程」。预先建成 pid → Agent 的
        // 索引，语义是同一条：按 `agents` 的数组顺序，一个 pid 被两个 Agent 登记时先登记的那个胜。
        let childOwner = Dictionary(
            agents.flatMap { agent in agent.childPIDs.map { ($0, agent) } },
            uniquingKeysWith: { first, _ in first }
        )
        // 同一串命令行本轮只判一次：一次构建会冒出几十个参数相同的孩子，
        // 而分级是纯函数，判第 N 遍和判第 1 遍必然给出同一个数。
        // 这张表只活在本次调用里——不留跨轮可变状态，也就没有任何新鲜度问题。
        var classified: [String: CommandClassification] = [:]

        var results: [CommandRecord] = []
        // 顺序仍是快照顺序：产出会逐条写库并广播，换个顺序就是换种历史。
        for proc in processes {
            guard !agentPIDs.contains(proc.pid) else { continue }
            // 先用「Agent 的子孙」集合筛掉绝大多数进程，再对上溯归因。
            guard candidates.contains(proc.pid) else { continue }
            if let start = proc.startTime, start < since { continue }
            guard let agent = nearestAgent(from: proc, agentByPID: agentByPID,
                                           childOwner: childOwner, tree: tree) else { continue }

            let cwd = proc.workingDirectory ?? Self.workingDirectoryFor(pid: proc.pid)
            let commandLine = proc.commandLine
            let classification: CommandClassification
            if let known = classified[commandLine] {
                classification = known
            } else {
                let fresh = classify(command: commandLine)
                classified[commandLine] = fresh
                classification = fresh
            }

            let record = CommandRecord(
                executable: proc.name,
                // 凭据在「argv 变成可持久化记录」这一步就被掩掉（§7，见 CommandLineRedaction 文件头）。
                // 上面 `classify(command: commandLine)` 用的仍是原文：判定要看真文本，
                // 落库与广播只留结构——脱敏不该削弱检出，只该削减留存。
                arguments: CommandLineRedaction.redact(arguments: proc.arguments),
                workingDirectory: cwd,
                agentID: agent.id,
                agentKind: agent.kind,
                startedAt: proc.startTime ?? Date(),
                outcome: .running,
                isDestructive: classification.isDestructive,
                requiresConfirmation: classification.requiresConfirmation,
                riskLevel: classification.level,
                projectPath: cwd
            )
            results.append(record)
        }
        return results
    }

    // MARK: - 归因

    /// 审计候选集：Agent 的全部子孙，加上 Agent 显式登记的子进程，再去掉 Agent 自身。
    ///
    /// 它与「每个进程各自沿父链向上试探」是同一个集合，只是方向反过来——于是全表一次扩散，
    /// 绝大多数进程在归因之前就被集合判定挡掉，不必各自走一遍父链。
    private func candidatePIDs(agents: [AgentInstance], tree: ProcessTreeIndex) -> Set<Int32> {
        var candidates = Set<Int32>()
        for agent in agents {
            candidates.formUnion(tree.descendantPIDs(of: agent.pid))
            // 父链在快照里断掉（父进程已退出、或本就没权限看到）时，
            // Agent 自己登记的 childPIDs 是唯一还能追到它的线索——旧实现的同一条兜底。
            candidates.formUnion(agent.childPIDs)
        }
        candidates.subtract(Set(agents.map(\.pid)))
        return candidates
    }

    /// 沿父链向上找最近的 Agent；未命中时退到「某 Agent 显式登记了它」。
    ///
    /// 第一跳用的是**这条记录自己写明的 parentPID**，而不是「索引里该 pid 的那条记录」：
    /// 快照正常情况下 pid 唯一，两者等价；一旦同一 pid 出现两条（回放/注入的快照），
    /// 索引只能给出其中一条的父，而旧实现是按每条记录各自的父上溯的。保住这个差别，
    /// 才谈得上「候选集与旧实现逐元素相等」。
    ///
    /// `visited` 是必需项而不是保险：ppid 图可以成环（父进程退出后 pid 被复用），
    /// 旧实现用 `guardCount < 1024` 兜底，那是「转够圈数再放弃」而不是「不走第二遍」。
    ///
    /// 兜底查 `childOwner` 索引而不是现扫 `agents`：索引按 `agents` 数组顺序构建、
    /// 一个 pid 被多个 Agent 登记时保留先登记的那个，与改前的
    /// `agents.first { $0.childPIDs.contains(proc.pid) }` 逐情形给出同一个 Agent。
    private func nearestAgent(from proc: ProcessRecord,
                              agentByPID: [Int32: AgentInstance],
                              childOwner: [Int32: AgentInstance],
                              tree: ProcessTreeIndex) -> AgentInstance? {
        var visited = Set<Int32>()
        var current = proc.parentPID
        while let parent = current {
            if let agent = agentByPID[parent] { return agent }
            guard visited.insert(parent).inserted else { break }
            current = tree.parentPID(of: parent)
        }
        // 父链未命中，但可能是某 Agent 显式登记的子进程。
        return childOwner[proc.pid]
    }

    // MARK: - 工作目录补充（proc_pidinfo，失败返回 nil）

    /// 通过 libproc 的 `PROC_PIDVNODEPATHINFO` 读取进程当前工作目录。
    /// 任何失败（权限不足/进程已退出）一律返回 nil，不抛异常。
    private static func workingDirectoryFor(pid: Int32) -> String? {
        var info = vnode_info_path()
        let size = Int32(MemoryLayout<vnode_info_path>.size)
        let ret = withUnsafeMutablePointer(to: &info) { ptr in
            proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, ptr, size)
        }
        guard ret > 0 else { return nil }
        // vip_path 为定长 CChar 元组（MAXPATHLEN）；按 CChar 重绑定后构造字符串。
        return withUnsafePointer(to: info.vip_path) { tuplePtr in
            tuplePtr.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }
}
