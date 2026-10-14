//
//  RetentionPruner.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine
//  Sub-owner: E
//
//  保留期清理（见 INTERFACE.md §5「==== E: RetentionPruner.swift ====」）。
//  按 `StoreSchema.prunable` 给出的 (表名, 时间列) 顺序删除 cutoff 之前的行（先子表后父表），
//  删除条数直接取 `SQLiteDatabase.execute` 返回的受影响行数（内部即 sqlite3_changes 累计），
//  不额外跑 COUNT，也不依赖跨 actor 调用的时序。除 `prunable` 里的语句外不做任何附加删除。
//
//  安全：表名/列名全部来自 `StoreSchema` 的编译期常量数组，永不含用户输入；
//  为兜底仍做一次标识符字符白名单校验，非法条目直接跳过并记日志。所有**值**都走参数绑定。
//

import Foundation
import os
import AIObservatoryCore

/// 按保留期删除历史行的清理器。
public struct RetentionPruner: Sendable {

    /// 清理策略。
    public struct Policy: Sendable, Hashable {
        /// 保留天数；`prune(now:)` 用它推算 cutoff。
        public var retentionDays: Int
        /// 未显式传 `vacuum` 参数时，清理后是否执行 VACUUM。
        public var vacuumAfterPrune: Bool

        /// 创建策略（默认保留 30 天、不自动 VACUUM）。
        public init(retentionDays: Int = 30, vacuumAfterPrune: Bool = false) {
            self.retentionDays = retentionDays
            self.vacuumAfterPrune = vacuumAfterPrune
        }

        /// 默认策略：30 天，不自动 VACUUM。
        public static let standard = Policy()
    }

    /// 一次清理的结果。
    public struct Result: Sendable, Hashable {
        /// 实际使用的截止时间点（早于它的行被删除）。
        public var cutoff: Date
        /// 每张表删除的行数（包含本次删除 0 行的表）。
        public var deletedRowsByTable: [String: Int]
        /// 是否执行了 VACUUM。
        public var didVacuum: Bool

        /// 全量成员初始化。
        public init(cutoff: Date, deletedRowsByTable: [String: Int] = [:], didVacuum: Bool = false) {
            self.cutoff = cutoff
            self.deletedRowsByTable = deletedRowsByTable
            self.didVacuum = didVacuum
        }

        /// 所有表删除行数之和。
        public var totalDeletedRows: Int { deletedRowsByTable.values.reduce(0, +) }
    }

    private let database: SQLiteDatabase
    private let policy: Policy

    /// 绑定数据库与默认策略；不产生任何副作用。
    public init(database: SQLiteDatabase, policy: Policy = .standard) {
        self.database = database
        self.policy = policy
    }

    // MARK: - 清理

    /// 删除 cutoff 之前的所有行，顺序与 `StoreSchema.prunable` 一致（先子后父）。
    ///
    /// 每表删除条数取自 `SQLiteDatabase.execute` 的返回值（即 `sqlite3_changes` 的累计），
    /// 因此不额外跑一次 COUNT，也不依赖跨 actor 调用的时序。除 `prunable` 声明的
    /// `DELETE FROM <表> WHERE <时间列> < ?` 之外不执行任何附加删除。
    ///
    /// - Parameter vacuum: nil 时取 `policy.vacuumAfterPrune`；为 true 才调用 `VACUUM`。
    /// - Returns: 每表精确删除条数与实际 cutoff；SQL 失败时抛出底层错误（不吞异常）。
    public func prune(olderThan cutoff: Date, vacuum: Bool? = nil) async throws -> Result {
        let threshold = cutoff.timeIntervalSinceReferenceDate
        var deleted: [String: Int] = [:]

        for entry in StoreSchema.prunable {
            guard isSafeSQLIdentifier(entry.table), isSafeSQLIdentifier(entry.timestampColumn) else {
                // 表名/列名只应来自 StoreSchema 常量；这里兜底，避免任何非白名单标识符进 SQL。
                ObservatoryLog.store.error("RetentionPruner 跳过非法标识符表 \(entry.table, privacy: .public)")
                continue
            }
            let deleteSQL = "DELETE FROM \(entry.table) WHERE \(entry.timestampColumn) < ?"
            let affected = try await database.execute([
                SQLiteStatement(deleteSQL, arguments: [.real(threshold)]),   // 值走绑定
            ])
            deleted[entry.table] = affected
        }

        var didVacuum = false
        if vacuum ?? policy.vacuumAfterPrune {
            try await database.vacuum()
            didVacuum = true
        }

        ObservatoryLog.store.info(
            "RetentionPruner 清理 cutoff=\(cutoff.timeIntervalSinceReferenceDate, privacy: .public) 共删除 \(deleted.values.reduce(0, +), privacy: .public) 行"
        )
        return Result(cutoff: cutoff, deletedRowsByTable: deleted, didVacuum: didVacuum)
    }

    /// 相对 `policy.retentionDays` 的便捷入口（用 `Calendar` 推算 cutoff，不做手写时间戳算术）。
    ///
    /// - Throws: `ObservatoryError.invalidQuery(_)` — 当日期加减超出可表示范围时。
    public func prune(now: Date, vacuum: Bool? = nil) async throws -> Result {
        guard let cutoff = Calendar.current.date(byAdding: .day, value: -policy.retentionDays, to: now) else {
            throw ObservatoryError.invalidQuery("无法从 retentionDays=\(policy.retentionDays) 推算保留期截止时间")
        }
        return try await prune(olderThan: cutoff, vacuum: vacuum)
    }
}

// MARK: - 内部工具

/// SQL 标识符白名单：仅 ASCII 字母、数字、下划线，且非空。
/// 表名/列名只应来自 `StoreSchema`；这里只是防止未来有人把外部字符串塞进常量数组。
private func isSafeSQLIdentifier(_ value: String) -> Bool {
    guard !value.isEmpty else { return false }
    for character in value {
        let isASCIIAlphanumeric = (character.isLetter || character.isNumber) && character.isASCII
        guard isASCIIAlphanumeric || character == "_" else { return false }
    }
    return true
}
