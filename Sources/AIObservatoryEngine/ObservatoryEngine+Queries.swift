//
//  ObservatoryEngine+Queries.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine（由 ObservatoryEngine.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import os
import CryptoKit
import AIObservatoryCore
import AIObservatoryRiskRules   // 装配点要直接构造 RiskAssessor（语言要同源）
import AIObservatoryStore
import AIObservatoryPlatform

extension ObservatoryEngine {

    // MARK: - Queries（全部委托 Store，先确保 schema 就绪）

    /// 仪表板统计（允许重算，调用频率低）。旧口径：只做"某一天"。
    public func dashboardStats(for date: Date) async throws -> DashboardStats {
        try await readyStore().dashboardStats(for: date)
    }

    /// 仪表板**时段累计**（#75）：窗口原样下推给 Store，端点进 SQL，引擎这一层不做任何口径加工。
    ///
    /// 这一条必须显式转发：不写的话它会落到 `ObservatoryService` 的退化默认实现上
    /// （"只算那一天"），引擎就成了无声的降级点——正是 #75 要修的那个形状。
    public func dashboardStats(settledAt: Date, within range: DateRangeFilter) async throws -> DashboardStats {
        try await readyStore().dashboardStats(settledAt: settledAt, within: range)
    }

    /// 当前活跃 Agent（state 为 running 或 idle）。
    public func activeAgents() async throws -> [AgentInstance] {
        try await readyStore().activeAgents()
    }

    /// 会话分页查询。
    public func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        try await readyStore().sessions(matching: query)
    }

    /// 单个会话。
    public func session(id: UUID) async throws -> AgentSession? {
        try await readyStore().session(id: id)
    }

    /// 时间线事件分页查询。
    public func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        try await readyStore().events(matching: query)
    }

    /// 文件变更分页查询。
    public func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        try await readyStore().fileChanges(matching: query)
    }

    /// 某次文件变更对应的 diff。
    public func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        try await readyStore().fileDiff(for: changeID)
    }

    /// 命令记录分页查询。
    public func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        try await readyStore().commands(matching: query)
    }

    /// 某会话的性能采样（时间升序）。
    public func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        try await readyStore().performanceSamples(sessionID: sessionID)
    }

    /// 整机性能采样（时间升序）。
    ///
    /// ⚠️ 无上限：会把保留期内的整机采样整段捞回（#38）。它是冻结契约
    /// `ObservatoryService.systemPerformance(since:)` 的实现，签名不能改；
    /// 界面与分析侧请改用下面的带 `limit:` 版本。
    public func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        try await readyStore().systemPerformance(since: date)
    }

    /// 某会话**最新 `limit` 条**采样（返回仍按时间升序）。#38。
    ///
    /// 这是给界面的那条：`PerformanceModel` 现在先 `systemPerformance(since:)` 整段捞回、
    /// 再 `suffix(sampleCap)` ⇒ 30 天保留期下等于每刷一次页就重建几万条对象。
    /// 换到这条之后，截断发生在 SQL/SwiftData 的 `ORDER BY … DESC LIMIT ?` 上。
    /// ICR-0007 批准后这两个 `limit:` 变体**已经是契约成员**（`ObservatoryService`），
    /// 本方法是它的实现，不再是"具体类型上的额外能力"；界面上那四处换调用由总控接线
    /// （本车道不碰 `Sources/AIObservatoryUI/`）。
    public func performanceSamples(sessionID: UUID, limit: Int) async throws -> [PerformanceSample] {
        try await readyStore().performanceSamples(sessionID: sessionID, limit: limit)
    }

    /// 保留期内**最新 `limit` 条**整机采样（返回按时间升序）。#38。
    public func systemPerformance(since date: Date, limit: Int) async throws -> [SystemPerformanceSample] {
        try await readyStore().systemPerformance(since: date, limit: limit)
    }

    /// 风险事件分页查询。
    public func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        try await readyStore().riskEvents(matching: query)
    }

    /// 全部项目活动地图。
    public func projects() async throws -> [ProjectActivity] {
        try await readyStore().projects()
    }

    /// 指定项目在给定区间内的活动地图。
    public func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        try await readyStore().projectActivity(path: path, dateRange: dateRange)
    }

    func readyStore() async throws -> ObservatoryStore {
        let store = try await storeBootstrap.value
        resolvedStore.withLock { $0 = store }
        return store
    }

    /// 已解析出的 Store（未解析返回 nil）；供 `stop()` 这类不抛错路径使用。
    var settledStore: ObservatoryStore? {
        resolvedStore.withLock { $0 }
    }

}
