//
//  BatchWriter.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine
//  Sub-owner: E
//
//  高频 append 的写入缓冲（见 INTERFACE.md §5「==== E: BatchWriter.swift ====」）。
//  策略：攒够 `policy.maxStatementsInBatch` 条 **或** 距上次成功提交超过 `policy.flushInterval`
//  秒，才做一次 `BEGIN IMMEDIATE … COMMIT`（由 `SQLiteDatabase.inTransaction(_:)` 承担），
//  以此把磁盘 IO 摊薄到「单次事务 ≥ 32 条语句」（AGENTS.md §6 性能预算）。
//
//  并发模型：本类型是 actor。所有多语句原子写都只跨一次 actor 边界
//  （`inTransaction` 内部无 await），因此不存在重入或半提交。
//

import Foundation
import os
import AIObservatoryCore

/// 写入缓冲：攒够 maxStatementsInBatch 条或距上次 flush 超过 flushInterval 提交一次事务。
public actor BatchWriter {

    /// 批量写策略。
    public struct Policy: Sendable, Hashable {
        /// 单批最多攒多少条语句；达到即就地提交一次事务。
        public var maxStatementsInBatch: Int
        /// 定时器检查间隔（秒）：每这么久评估一次是否该把剩余缓冲落盘。
        public var flushInterval: TimeInterval
        /// 定时器路径每次提交的最少行数。攒不够就不提交（AGENTS §6「单次事务 ≥ 32 行」），
        /// 由 `maxBufferAge` 兜底，避免低频数据永久滞留。
        public var minRowsPerCommit: Int
        /// 缓冲硬延迟上限（秒）：最老一条超过它，即使行数不足也必须落盘。
        public var maxBufferAge: TimeInterval

        /// 创建策略；`maxStatementsInBatch` 的非正值在实际使用时收敛为 1。
        public init(
            maxStatementsInBatch: Int = 32,
            flushInterval: TimeInterval = 1.0,
            minRowsPerCommit: Int = 8,
            maxBufferAge: TimeInterval = 10
        ) {
            self.maxStatementsInBatch = maxStatementsInBatch
            self.flushInterval = flushInterval
            self.minRowsPerCommit = max(minRowsPerCommit, 1)
            // 兜底上限不得小于检查周期，否则定时器永远来不及看它。
            self.maxBufferAge = max(maxBufferAge, flushInterval)
        }

        /// 默认策略：32 条 / 1 秒（对齐性能预算表）。
        public static let standard = Policy()
    }

    /// 批量写运行期统计。
    public struct Stats: Sendable, Hashable {
        /// 实际执行过 BEGIN/COMMIT 的次数（空缓冲的 flush 不计）。
        public var commitCount: Int
        /// 缓冲区里还没提交的语句条数。
        public var pendingCount: Int
        /// 累计 submit 进来的语句条数。
        public var totalSubmitted: Int
        /// 因违反约束而被**逐条**丢弃的语句数（每条都记了日志）。
        /// 调用方据此把「有数据没落库」暴露出来，而不是只留在日志里。
        public var droppedStatementCount: Int

        /// 全量成员初始化，默认全 0。
        public init(commitCount: Int = 0, pendingCount: Int = 0, totalSubmitted: Int = 0, droppedStatementCount: Int = 0) {
            self.commitCount = commitCount
            self.pendingCount = pendingCount
            self.totalSubmitted = totalSubmitted
            self.droppedStatementCount = droppedStatementCount
        }
    }

    /// 后台循环的最小睡眠间隔，避免 `flushInterval` 被配成 0 时退化成忙等。
    internal static let minimumSleepInterval: TimeInterval = 0.01

    private let database: SQLiteDatabase
    private let policy: Policy
    private let clock = ContinuousClock()

    private var buffer: [SQLiteStatement] = []
    /// 当前缓冲里最老一条的入缓冲时刻（缓冲空时为 nil），供 `maxBufferAge` 兜底判断。
    private var oldestBufferedAt: ContinuousClock.Instant?
    private var droppedStatementCount = 0
    private var commitCount = 0
    private var totalSubmitted = 0
    /// 上一次成功提交的时刻（nil 表示尚未成功提交过）。
    private var lastCommitAt: ContinuousClock.Instant?
    private var flushTask: Task<Void, Never>?

    /// 准备一个批量写通道；不启动后台循环（需显式 `start()`）。
    public init(database: SQLiteDatabase, policy: Policy = .standard) {
        self.database = database
        self.policy = policy
    }

    // MARK: - 提交入口

    /// 投入一条语句；若缓冲已满则就地提交一次事务。
    public func submit(_ statement: SQLiteStatement) async {
        await submit([statement])
    }

    /// 投入多条语句；每满一批就地提交一次，剩余留在缓冲里等定时器或显式 `flush()`。
    ///
    /// 攒批口径（验收）：默认阈值 32 时连续 100 次单条 `submit` 会在第 32/64/96 条各提交一次
    /// （3 次事务），余下 4 条留在缓冲；随后一次显式 `flush()` 提交 → 总计 **4 次 commit**。
    public func submit(_ statements: [SQLiteStatement]) async {
        guard !statements.isEmpty else { return }
        totalSubmitted += statements.count
        if buffer.isEmpty { oldestBufferedAt = clock.now }
        buffer.append(contentsOf: statements)
        // 提交失败时 commitBuffer 会把语句放回缓冲头部，此时必须跳出，否则会活锁。
        while buffer.count >= effectiveBatchSize {
            let drained = await commitBuffer()
            if !drained { break }
        }
    }

    /// 强制提交当前缓冲（不做新鲜度判定）；缓冲为空时不提交、也不计入 `commitCount`。
    public func flush() async {
        await commitBuffer()
    }

    // MARK: - 生命周期

    /// 启动后台定时 flush 循环（幂等）。空闲时只 `Task.sleep`，不轮询忙等。
    public func start() {
        guard flushTask == nil else { return }
        let interval = max(policy.flushInterval, BatchWriter.minimumSleepInterval)
        flushTask = Task { [weak self] in
            while !Task.isCancelled {
                // try? 只吞掉「被取消」这一种情况，取消由循环条件与 stop() 负责处理。
                try? await Task.sleep(for: .seconds(interval))
                guard let self else { return }
                await self.flushIfStale()
            }
        }
    }

    /// 取消后台循环并强制把缓冲清零（测试会断言 `pendingCount == 0`）。
    public func stop() async {
        let inFlight = flushTask
        inFlight?.cancel()
        flushTask = nil
        // 先等在途那一轮结束：否则它的提交会与下面的排空交错，可能把已换出的语句误判为丢失。
        _ = await inFlight?.value
        // commitBuffer 保证缓冲清零（整批失败时逐条提交），因此这里只需一轮。
        await commitBuffer()
    }

    /// 被丢弃（始终无法写入）的语句条数；引擎在 `stop()` 后据此显式告警。
    public var droppedStatements: Int { droppedStatementCount }

    /// 当前统计快照（actor 同步属性，调用方 `await writer.stats`）。
    public var stats: Stats {
        Stats(commitCount: commitCount, pendingCount: buffer.count,
              totalSubmitted: totalSubmitted, droppedStatementCount: droppedStatementCount)
    }

    // MARK: - 内部实现

    /// `Duration` → 秒：策略判定与测试用浮点秒表达，避免到处传 `Duration`。
    private static func seconds(of duration: Duration) -> TimeInterval {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }

    /// 收敛后的批量阈值：非正配置按 1 处理，避免永远凑不满或死循环。
    private var effectiveBatchSize: Int {
        max(policy.maxStatementsInBatch, 1)
    }

    /// 定时器入口：是否落盘交给 `TimerPolicy.shouldCommit` 判定。
    private func flushIfStale() async {
        let oldestAge = oldestBufferedAt.map { Self.seconds(of: $0.duration(to: clock.now)) }
        let sinceCommit = lastCommitAt.map { Self.seconds(of: $0.duration(to: clock.now)) }
        guard TimerPolicy.shouldCommit(
            bufferCount: buffer.count,
            oldestBufferedSeconds: oldestAge,
            secondsSinceLastCommit: sinceCommit,
            policy: policy
        ) else { return }
        await commitBuffer()
    }

    /// 定时器提交决策（纯函数，便于不依赖 sleep 的单元测试）。
    ///
    /// 两条准入路径：
    /// 1. 攒够 `minRowsPerCommit` 行且距上次提交超过 `flushInterval` —— 常规批量路径；
    /// 2. 最老一条已滞留 `maxBufferAge` 秒 —— 硬延迟兜底，保证低频数据最终落盘。
    /// 只有 1–5 行且未到兜底时刻时**不提交**：否则稳态会退化成逐行事务，违反 AGENTS §6。
    struct TimerPolicy {
        static func shouldCommit(
            bufferCount: Int,
            oldestBufferedSeconds: TimeInterval?,
            secondsSinceLastCommit: TimeInterval?,
            policy: Policy
        ) -> Bool {
            guard bufferCount > 0 else { return false }
            if let age = oldestBufferedSeconds, age >= policy.maxBufferAge { return true }
            guard bufferCount >= policy.minRowsPerCommit else { return false }
            guard let since = secondsSinceLastCommit else { return true }
            return since >= policy.flushInterval
        }
    }

    /// 把当前缓冲一次性提交。
    ///
    /// **换出（swap-out）语义**：先把 `buffer` 的内容拷进局部 `statements` 并立即清空缓冲，
    /// 之后才 `await database.inTransaction(statements)`。因为 await 期间缓冲已为空，
    /// 重入的 `submit` 只会追加到新缓冲、由下一次 flush 处理：既不会丢语句（局部副本已持有全部旧语句），
    /// 也不会被重复写入（旧语句已不在缓冲里，失败时才按原顺序插回头部）。
    ///
    /// - Returns: 恒为 `true` —— 无论整批成功还是逐条兜底，缓冲都会在这一轮结束时清空。
    ///
    /// 失败处理：整批失败时**逐条重投**，只丢弃真正违规的那一条并记日志。
    /// 否则一条坏数据（例如采集器漂移导致的约束冲突）会连带 31 条有效写入一起消失。
    @discardableResult
    private func commitBuffer() async -> Bool {
        guard !buffer.isEmpty else { return true }
        let statements = buffer
        buffer.removeAll(keepingCapacity: true)
        oldestBufferedAt = buffer.isEmpty ? nil : clock.now
        do {
            try await database.inTransaction(statements)
            commitCount += 1
            lastCommitAt = clock.now
            return true
        } catch {
            ObservatoryLog.store.error(
                "BatchWriter 整批提交失败（\(statements.count, privacy: .public) 条）：\(error.localizedDescription, privacy: .public)，改为逐条提交"
            )
            await commitIndividually(statements)
            lastCommitAt = clock.now
            return true
        }
    }

    /// 逐条提交：成功的照常入库，违规的单条被丢弃并记录 SQL 片段（不静默）。
    private func commitIndividually(_ statements: [SQLiteStatement]) async {
        var lost = 0
        for statement in statements {
            do {
                try await database.inTransaction([statement])
                commitCount += 1
            } catch {
                lost += 1
                ObservatoryLog.store.error(
                    "BatchWriter 丢弃 1 条无法写入的语句：\(error.localizedDescription, privacy: .public) ｜ SQL=\(statement.sql.prefix(120), privacy: .public)"
                )
            }
        }
        droppedStatementCount += lost
        if lost == statements.count {
            ObservatoryLog.store.critical(
                "BatchWriter 逐条重试后仍然全部失败（\(statements.count, privacy: .public) 条）：数据库可能已不可写"
            )
        }
    }
}
