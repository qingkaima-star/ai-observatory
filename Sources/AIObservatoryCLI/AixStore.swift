//
//  AixStore.swift
//  AIObservatoryCLI
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  打开一个**已存在**的库，并在打开之前把「会不会写」的两条路堵死。
//
//  为什么要有这个前置检查（不是多虑，是实测出来的）：
//  `ObservatoryStore.open` 一定会写 —— `SQLiteDatabase.init` 用
//  `SQLITE_OPEN_READWRITE|SQLITE_OPEN_CREATE`（`SQLiteDatabase.swift:281`）、开库先建父目录（:277）、
//  再 `PRAGMA journal_mode=WAL`，最后无条件 `applyMigrations(StoreSchema.migrations)`
//  （`ObservatoryStore.swift:49`）。库已在当前版本时 `plan()` 返回空 ⇒ 不发 DDL；
//  **但库来自旧版 AiX 时，一个自称只读的工具会顺手把用户的 schema 迁走。**
//  ⇒ 版本不符就退 2，绝不打开。这条挡住之后，「只读」才是可核对的事实而不是声明。
//

import Foundation
import AIObservatoryCore
import AIObservatoryStore

/// 前置条件不满足 ⇒ 一律退 2。四种情况输出必须互不相同（约束 3）。
public enum AixFailure: Error, Equatable, Sendable {
    /// 解析到了目录，但目录里没有库文件。**不会创建**任何东西。
    case noDatabaseFile(catalogedPath: String, source: AixDataLocation.Resolution.Source)
    /// ADR-0003 四条优先级全部落空。
    case locationUnresolved(reason: String)
    /// 那是个 SQLite 文件，但不是 AiX 的库（缺表）。
    case notAnObservatoryStore(path: String, missingTables: [String])
    /// 库版本与本 CLI 支持的版本不同 —— 拒绝打开，以免迁移用户的库。
    case schemaVersionMismatch(path: String, found: Int, supported: Int)
    /// 打不开（权限、被独占、损坏）。
    case openFailed(path: String, message: String)

    /// 机器可读状态标记（`--json` 时进 stderr，供脚本分支）。
    public var statusToken: String {
        switch self {
        case .noDatabaseFile: return "AIX_NO_DATABASE_FILE"
        case .locationUnresolved: return "AIX_LOCATION_UNRESOLVED"
        case .notAnObservatoryStore: return "AIX_NOT_OBSERVATORY_STORE"
        case .schemaVersionMismatch: return "AIX_SCHEMA_VERSION_MISMATCH"
        case .openFailed: return "AIX_OPEN_FAILED"
        }
    }

    public var message: String {
        switch self {
        case .noDatabaseFile(let path, let source):
            return "按 \(source.rawValue) 找到数据目录，但里面没有 \(AixDataLocation.databaseFileName)：\(path)\n"
                + "本工具只读，不会创建数据库；确认 AiX 采集端是否真的往这里写过数据。"
        case .locationUnresolved(let reason):
            return "拿不到 AiX 的数据目录（\(reason)）。用 --data-dir <目录> 或设 AIOBSERVATORY_DATA_DIR 指定。"
        case .notAnObservatoryStore(let path, let missing):
            return "\(path) 不是一个 AiX 观测库（缺表：\(missing.joined(separator: ", "))）。"
        case .schemaVersionMismatch(let path, let found, let supported):
            return "\(path) 的 schema 版本是 \(found)，而本 CLI 支持 \(supported)。\n"
                + "拒绝打开：打开会触发迁移，那是写操作。请让 AiX 自己升级它，或换一份当前版本的库。"
        case .openFailed(let path, let message):
            return "打不开 \(path)：\(message)"
        }
    }
}

/// 「解析 + 前置检查 + 打开」这一步的产物。
public enum AixStore {
    public struct Opened: Sendable {
        public var service: any ObservatoryService
        public var databasePath: String
        /// **建立任何连接之前**采到的未合并 WAL 字节数；`nil` = 没有 `-wal` 边车，或它是空的。
        ///
        /// 为什么必须在建连接之前量：`preflight` 自己就要开一次、关一次连接，而「最后一个连接关闭」
        /// 会把 WAL checkpoint 进主库 —— 关完再量永远是 0。这一格自己踩过一次：
        /// 话术接在打开之后，那条 warning 于是一次都没有出现过。
        public var uncheckpointedWALBytes: Int?

        /// 自报「本次读取不是完全只读」的话术；无需自报时返回 `nil`。
        ///
        /// 只在 WAL **非空**时才念：采集端活着的时候 `-wal` 一直是常态，每次都念等于没有信息。
        /// 真会改字节的是「采集端被 kill 掉、留下未合并 WAL」那一次 —— 那时本进程是最后一个连接，
        /// 读完退出会把 WAL 合并进主库。要彻底免掉这一步需要 Store 的只读打开（ICR-0012 §三 C2）。
        public var walWarning: String? {
            guard let bytes = uncheckpointedWALBytes, bytes > 0 else { return nil }
            return "# warning=AIX_WAL_MAY_BE_CHECKPOINTED bytes=\(bytes)\n"
                + "# 本次读取结束时会把未合并的 WAL 写进主库（checkpoint），这不是只读操作。\n"
        }
    }

    /// 解析链上真正存在、且版本匹配的那份库。失败一律抛 ``AixFailure``（退 2）。
    public static func open(request: AixRequest) async throws -> Opened {
        let path = try databasePath(for: request)
        // 在建任何连接之前取数 —— 见 `Opened.uncheckpointedWALBytes` 的说明。
        let walBytes = uncheckpointedWALBytes(databasePath: path)
        try await preflight(path: path)
        do {
            let store = try await ObservatoryStore.open(configuration: .file(path))
            return Opened(service: store, databasePath: path, uncheckpointedWALBytes: walBytes)
        } catch {
            throw AixFailure.openFailed(path: path, message: error.localizedDescription)
        }
    }

    /// `-wal` 边车的当前字节数；没有边车、或它是空的 ⇒ `nil`。
    public static func uncheckpointedWALBytes(databasePath: String) -> Int? {
        // `attributesOfItem` 的取值本身是 `Any?`，再套 `try?` 会变成双重可选 ——
        // 直接 `as? Int` 会静默失败（症状就是那条自报话术永远不出现）。
        let attributes = try? FileManager.default.attributesOfItem(atPath: databasePath + "-wal")
        guard let size = attributes?[.size] as? Int, size > 0 else { return nil }
        return size
    }

    /// 只解析并判存在性，不打开。用例与 `--json` 的报错文案都靠它拿到候选路径。
    public static func databasePath(for request: AixRequest) throws -> String {
        let inputs = AixDataLocation.Inputs(explicit: request.dataDir)
        let resolution = AixDataLocation.resolve(inputs)
        guard case .directory(let directory, let source) = resolution else {
            guard case .unresolved(let reason) = resolution else {
                throw AixFailure.locationUnresolved(reason: "解析器未给出目录")
            }
            throw AixFailure.locationUnresolved(reason: reason)
        }
        let candidate = URL(fileURLWithPath: directory, isDirectory: true)
            .appendingPathComponent(AixDataLocation.databaseFileName).path
        guard FileManager.default.fileExists(atPath: candidate) else {
            throw AixFailure.noDatabaseFile(catalogedPath: candidate, source: source)
        }
        return candidate
    }

    /// 前置检查要开一次真实连接。⚠️ 它**不是**只读连接（`SQLiteDatabase` 只有 READWRITE|CREATE 这一条路）：
    /// 所以它自己就可能触发 checkpoint，见 `Opened.uncheckpointedWALBytes` 取数时机的说明。
    /// 里面只跑两条绑定参数的探活查询，不含任何审计口径 —— 审计数据一律走 `ObservatoryService`。
    static func preflight(path: String) async throws {
        let database: SQLiteDatabase
        do {
            database = try SQLiteDatabase(configuration: .file(path))
        } catch {
            throw AixFailure.openFailed(path: path, message: error.localizedDescription)
        }
        do {
            let version = try await database.userVersion()
            guard version == StoreSchema.schemaVersion else {
                await database.close()
                throw AixFailure.schemaVersionMismatch(path: path, found: version,
                                                       supported: StoreSchema.schemaVersion)
            }
            var missing: [String] = []
            for table in requiredTables {
                let found = try await database.scalarInt(
                    "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?",
                    arguments: [.text(table)]
                ) ?? 0
                if found == 0 { missing.append(table) }
            }
            await database.close()
            guard missing.isEmpty else { throw AixFailure.notAnObservatoryStore(path: path, missingTables: missing) }
        } catch let failure as AixFailure {
            await database.close()
            throw failure
        } catch {
            await database.close()
            throw AixFailure.openFailed(path: path, message: error.localizedDescription)
        }
    }


    private static let requiredTables = [
        StoreSchema.Table.agents, StoreSchema.Table.sessions, StoreSchema.Table.events,
        StoreSchema.Table.fileChanges, StoreSchema.Table.commands, StoreSchema.Table.riskEvents,
    ]
}
