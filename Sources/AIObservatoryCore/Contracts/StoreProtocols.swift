//
//  StoreProtocols.swift
//  AIObservatoryCore
//
//  Owner: master-controller（冻结契约层）
//
//  存储后端的**写侧**契约。
//
//  为什么缺它：需求写「数据：SwiftData + SQLite」，ADR-0001 把 SwiftData 排到第二期，
//  而「第二期」的实际含义是两个后端**可切换**。读侧早就可切换（`ObservatoryService` 在 Core，
//  两个后端都 conform），写侧却没有对应的抽象——切换点只能引用具体类型，于是第二后端
//  永远只能当「另一个类」，不能当「另一个实现」。
//
//  成员与 `AIObservatoryStore.ObservatoryStore` 现有写入 API 逐字同名同签名，
//  所以 SQLite 侧只需一行 conformance，不改任何行为。
//

import Foundation

/// 一个可切换的存储后端的写入面。
public protocol ObservatoryWriting: Sendable {
    /// 启动后台写入通道（幂等）。
    func start() async
    /// 停止：强制 flush 缓冲 → 取消循环 → WAL checkpoint（失败只记日志，不抛）。
    func stop() async
    /// 把缓冲里的写入立刻落盘（测试与退出前收尾用）。
    func flush() async

    func upsertAgents(_ agents: [AgentInstance]) async throws
    func upsertSessions(_ sessions: [AgentSession]) async throws
    func upsertProjects(_ projects: [ProjectActivity]) async throws
    func recordRisks(_ risks: [RiskEvent]) async throws
    func acknowledgeRisk(id: UUID) async throws
    func record(_ diff: FileDiff, forChangeID changeID: UUID) async throws
    func recordSnapshot(_ snapshot: FileSnapshot) async throws

    /// 把**仍开放**（`outcome == .running` 且 `endedAt == nil`）的命令收敛成给定结果，并补上 `endedAt`。
    ///
    /// 为什么需要它（需求④「命令 / 结果 / 耗时」）：唯一能拿到退出码的路径是 shell hook，
    /// 而 hook 默认不装 ⇒ 真机实测三个独立库里 **236 条命令全部永远 `running`、`ended_at` 恒空**，
    /// 「耗时」这一项因此是 0% 覆盖。引擎其实**已经知道**进程不见了（会发 `agentStopped` 事件），
    /// 却没有任何地方把该进程名下的开放命令收口——`CommandOutcome.terminated` 有定义、无生产者。
    ///
    /// 语义约定（三套后端必须逐字一致，`StoreParityTests` 按此对账）：
    /// - 筛选：`agentID` / `sessionID` 任一非 nil 就是一个等值条件；两个都给则**同时成立**；
    ///   都为 nil 表示"所有开放命令"。
    /// - 只改 `outcome == .running` 的行：**已经闭合过的命令绝不改写**（hook 先闭合的优先）。
    /// - 幂等：没有匹配行时不产生任何写入，返回 0。
    /// - `endedAt` 由调用方给（= 该 Agent 最后一次可见的时刻），**存储层不读时钟**，
    ///   否则同一批数据在测试里不可复现。
    /// - ⚠️ 调用方**必须先 `flush()`**：命令走缓冲写入通道，未落盘的插入会被这次更新漏掉。
    ///
    /// ⚠️ `.terminated` 表示"随进程结束、**退出码未知**"，**不是**成功也不是失败：
    /// 成败类聚合必须继续排除它（见 `CommandResultReader.isResolved` 的口径注释）。
    /// - Returns: 被收敛的行数。
    @discardableResult
    func terminateOpenCommands(
        agentID: UUID?,
        sessionID: UUID?,
        outcome: CommandOutcome,
        endedAt: Date
    ) async throws -> Int

    func append(_ event: TimelineEvent) async
    func append(_ change: FileChange) async
    func append(_ command: CommandRecord) async
    func append(_ sample: PerformanceSample) async
    func append(_ sample: SystemPerformanceSample) async
}
