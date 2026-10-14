//
//  SchemaMigrator.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine
//  Sub-owner: A
//
//  通用「版本化 schema 迁移」框架：只负责迁移的校验、编排与版本推进策略，
//  **不含任何建表 DDL**（DDL 由 StoreSchema.swift 的 `SchemaMigrations`/`migrations` 提供）。
//  版本状态存放在 SQLite 的 `PRAGMA user_version`（见 SQLiteDatabase.applyMigrations）。
//

import Foundation

// MARK: - SchemaMigration

/// 一个版本迁移步骤。`statements` 必须幂等（全部 `CREATE TABLE/INDEX IF NOT EXISTS`），
/// 这样即使 `user_version` 落后而对象已存在，重放也不会失败。
public struct SchemaMigration: Sendable, Hashable {
    /// 目标版本号，必须严格递增且从 1 开始。
    public var version: Int
    /// 人类可读名称，用于日志与错误信息。
    public var name: String
    /// 该版本要执行的语句（原子提交）。
    public var statements: [SQLiteStatement]

    /// 构造一个迁移步骤。
    public init(version: Int, name: String, statements: [SQLiteStatement]) {
        self.version = version
        self.name = name
        self.statements = statements
    }
}

// MARK: - SchemaMigrator

/// 迁移清单的纯函数校验器 / 计划器（无状态、无 IO）。
public enum SchemaMigrator {
    /// 迁移清单非法。
    public enum MigratorError: LocalizedError, Equatable, Sendable {
        case emptyMigrations
        case outOfOrder(version: Int, previous: Int)
        case duplicateVersion(Int)
        case mustStartAtOne(firstVersion: Int)

        public var errorDescription: String? {
            switch self {
            case .emptyMigrations:
                return "迁移清单为空：至少需要一个版本 1 的迁移。"
            case .outOfOrder(let version, let previous):
                return "迁移版本顺序非法：版本 \(version) 未大于前一个版本 \(previous)（必须严格递增）。"
            case .duplicateVersion(let version):
                return "迁移版本重复：版本 \(version) 出现了多次。"
            case .mustStartAtOne(let firstVersion):
                return "迁移必须从版本 1 开始，实际首个版本为 \(firstVersion)。"
            }
        }
    }

    /// 校验迁移清单：非空、从 1 开始、版本严格递增且无重复。非法时抛 `MigratorError`。
    public static func validate(_ migrations: [SchemaMigration]) throws {
        guard let first = migrations.first else {
            throw MigratorError.emptyMigrations
        }
        guard first.version == 1 else {
            throw MigratorError.mustStartAtOne(firstVersion: first.version)
        }
        var seen: Set<Int> = [first.version]
        var previous = first.version
        for migration in migrations.dropFirst() {
            if seen.contains(migration.version) {
                throw MigratorError.duplicateVersion(migration.version)
            }
            if migration.version <= previous {
                throw MigratorError.outOfOrder(version: migration.version, previous: previous)
            }
            seen.insert(migration.version)
            previous = migration.version
        }
    }

    /// 计算待执行迁移（`version > currentVersion`），按版本升序返回；已追平时返回空数组。
    ///
    /// 不做校验（校验由 `validate` 负责），因此对已排序清单是纯过滤。
    public static func plan(currentVersion: Int, migrations: [SchemaMigration]) -> [SchemaMigration] {
        migrations
            .filter { $0.version > currentVersion }
            .sorted { $0.version < $1.version }
    }

    /// 清单里的最高版本号；空清单返回 0（= 尚未建库）。
    public static func latestVersion(of migrations: [SchemaMigration]) -> Int {
        migrations.map(\.version).max() ?? 0
    }
}
