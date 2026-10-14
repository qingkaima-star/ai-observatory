//
//  MigrationSourceReader.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-Engine（由 SwiftDataMigration.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import os
import SQLite3
import AIObservatoryCore
// MARK: - 迁移用的 SQL 常量

/// 11 张表的分页读取语句。表名与列名（见 `SQLiteSourceRows` 里 `row.text("started_at")` 这类字面量）
/// 全部是**本文件的编译期常量字符串**，外部输入（游标、页大小）只经 `?` 绑定，绝不拼进 SQL。
/// 首屏游标是空串：任何 uuidString 文本与路径都 `>` `''`（TEXT 列按 BINARY 排序）。
/// 刻意用 `SELECT *`：源库多出来的列不会让迁移崩（列值按名字取）。
///
/// internal 而非 private：下面几个 `SQLiteSource*` 类型互相引用，混用 private / internal
/// 只会让访问级别推导变啰嗦；它们都不是本 target 的公共 API，出不了模块。
enum MigrationSQL {

    static let agents = "SELECT * FROM agents WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let sessions = "SELECT * FROM sessions WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let events = "SELECT * FROM events WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let fileChanges = "SELECT * FROM file_changes WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let diffs = "SELECT * FROM diffs WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let commands = "SELECT * FROM commands WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let perfSamples = "SELECT * FROM perf_samples WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let systemPerf = "SELECT * FROM system_perf WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let riskEvents = "SELECT * FROM risk_events WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let projects = "SELECT * FROM projects WHERE id > ? ORDER BY id ASC LIMIT ?"
    static let fileSnapshots = "SELECT * FROM file_snapshots WHERE id > ? ORDER BY id ASC LIMIT ?"
}

// MARK: - 只读 SQLite 源库

/// 一张表的一页读取结果。
struct SQLiteSourcePage<Value: Sendable>: Sendable {

    /// 本批从源库扫出的行数（含被跳过的），也是 keyset 游标。
    let scanned: Int

    /// 成功还原的值；按源库的 `ORDER BY id ASC` 顺序。
    let values: [Value]

    /// 本批最后一条**源库行**的 `id` 文本，下一页的游标。
    let lastID: String?

    /// 解码失败被丢弃的行数。
    var skipped: Int { scanned - values.count }

    /// 直接可以累加进报告的统计。
    var counts: SwiftDataMigrationCounts {
        SwiftDataMigrationCounts(read: scanned, written: values.count, skipped: skipped)
    }
}

/// 源库列值。与 `AIObservatoryStore.SQLiteColumn` 同构。
enum SQLiteSourceColumn: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)

    /// 整数值：integer 直取、real 截断、text 按十进制解析、null/blob 为 nil。
    var coercedInt64: Int64? {
        switch self {
        case .null:                 return nil
        case .integer(let value):   return value
        case .real(let value):      return value.isFinite ? Int64(value) : nil
        case .text(let value):      return Int64(value.trimmingCharacters(in: .whitespaces))
        case .blob:                 return nil
        }
    }

    /// Double 值：integer/real 直取、text 按小数解析、其余 nil。
    var coercedDouble: Double? {
        switch self {
        case .null:                 return nil
        case .integer(let value):   return Double(value)
        case .real(let value):      return value
        case .text(let value):      return Double(value.trimmingCharacters(in: .whitespaces))
        case .blob:                 return nil
        }
    }

    /// 仅当底层确实是文本（或可按 UTF-8 解出的 BLOB）时返回，不做数字→字符串的伪造格式化。
    var coercedText: String? {
        switch self {
        case .text(let value):      return value
        case .blob(let data):       return String(decoding: data, as: UTF8.self)
        default:                    return nil
        }
    }
}

/// 一行结果（列名 → 值），取值语义与 `AIObservatoryStore.SQLiteRow` 逐条对齐。
struct SQLiteSourceRow: Sendable, Hashable {

    private let names: [String]
    private let values: [SQLiteSourceColumn]

    init(names: [String], values: [SQLiteSourceColumn]) {
        self.names = names
        self.values = values
    }

    /// 按列名取原始值；列不存在返回 nil。
    func column(_ name: String) -> SQLiteSourceColumn? {
        guard let index = names.firstIndex(of: name) else { return nil }
        return index < values.count ? values[index] : nil
    }

    /// 文本列（BLOB 按 UTF-8 兜底）；其他类型返回 nil，不伪造字符串。
    func text(_ name: String) -> String? { column(name)?.coercedText }

    /// 整数列（64 位平台上 Int64 → Int 无损）；非数值列 nil。
    func int(_ name: String) -> Int? { column(name)?.coercedInt64.map { Int($0) } }

    /// Double 列；非数值列 nil。
    func double(_ name: String) -> Double? { column(name)?.coercedDouble }

    /// 以 `Int64(bitPattern:)` 存回来的 UInt64（`memory_bytes` 等）。
    /// integer 用 `UInt64(bitPattern:)` 还原，所以负数也照样能变回原来的大值；
    /// real 只在非负时取整（与 SQLite 后端一致）。
    func uint64(_ name: String) -> UInt64? {
        switch column(name) {
        case .integer(let value):   return UInt64(bitPattern: value)
        case .real(let value):      return value.isFinite && value >= 0 ? UInt64(value) : nil
        default:                    return nil
        }
    }

    /// 布尔列：非 0 → true；缺失 / NULL / 解析不出 → false。
    func bool(_ name: String) -> Bool { column(name)?.coercedInt64.map { $0 != 0 } ?? false }

    /// 日期列：按 REAL `timeIntervalSinceReferenceDate` 解释；非有限值返回 nil。
    /// 用参考日期而非 1970 纪元，与 SQLite 写侧同口径，因此时间戳可逐位往返。
    func date(_ name: String) -> Date? {
        guard let seconds = column(name)?.coercedDouble, seconds.isFinite else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// UUID 列：按文本解析，失败返回 nil（不伪造）。
    func uuid(_ name: String) -> UUID? {
        guard let raw = column(name)?.coercedText else { return nil }
        return UUID(uuidString: raw)
    }
}

/// `diffs` 表的一行：`FileDiff` 加上只存在于列里的 `change_id`
/// （`record(_:forChangeID:)` 的第二个参数，SQLite 约定 `diff.id == change_id`）。
struct MigrationDiffEntry: Sendable, Hashable {
    let diff: FileDiff
    let changeID: UUID
}

/// 只读、单连接的 SQLite 迁移源。
///
/// **不是** `@unchecked Sendable`：连接句柄与语句指针都不是 Sendable。
/// 使用方（`SwiftDataMigrator.migrate()`）在自己的 actor 隔离域内以局部量同步调用它，
/// 跨 await 传递的只有解码出来的 Core 值类型。
final class SQLiteSourceReader {

    private var handle: OpaquePointer?

    /// 每个实体当前的 keyset 游标（`id` 文本）；初始为空串 = 从表头开始。
    private var cursors: [SwiftDataMigrationEntity: String] = [:]

    /// 源库里实际存在、可以读的表；不存在（例如 v1 库没有 `file_snapshots`）时该表整表算 0 行。
    private var readable: Set<SwiftDataMigrationEntity>

    /// 只读打开源库。
    ///
    /// - Throws: `ObservatoryError.storeUnavailable(_)` —— 文件不存在、不是 SQLite 数据库、
    ///   或以只读方式打不开（缺读权限）。
    init(fileURL: URL) throws {
        let path = fileURL.path
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw ObservatoryError.storeUnavailable(
                "SQLite 源库不可读：\(path)（文件不存在或无读权限）"
            )
        }
        var opened: OpaquePointer?
        let code = sqlite3_open_v2(path, &opened, Int32(SQLITE_OPEN_READONLY), nil)
        guard code == Int32(SQLITE_OK), let connection = opened else {
            if let stale = opened { sqlite3_close_v2(stale) }
            throw ObservatoryError.storeUnavailable(
                "无法以只读方式打开 SQLite 源库 \(path)（错误码 \(code)）："
                    + Self.message(from: opened)
            )
        }
        // 先把两个存储属性都赋值到位，再查表清单：查询失败时实例算「已初始化」，
        // `deinit` 会跑，连接不会泄漏。
        self.handle = connection
        self.readable = []
        do {
            self.readable = try Self.readableTables(in: connection)
        } catch {
            close()   // 置 nil + close_v2；随后的 deinit → close() 是 no-op
            throw error
        }
    }

    /// 关闭连接（幂等：`deinit` 也会调，`defer` 里重复调用安全）。
    func close() {
        guard let connection = handle else { return }
        handle = nil
        sqlite3_close_v2(connection)
    }

    deinit {
        close()
    }

    /// 读某个实体的下一页并推进它的游标。
    ///
    /// - Parameters:
    ///   - entity: 目标表；同时决定 SQL 语句与游标槽位。
    ///   - limit: 单页最多行数。
    ///   - decode: 行 → 领域模型；返回 nil 表示这行非法，计入 `skipped`。
    /// - Throws: `ObservatoryError.storeUnavailable(_)` —— prepare / step 失败，或页内出现
    ///   `id` 不是文本的行（游标无法前进，继续跑会读到同一行）。
    func page<Value: Sendable>(
        _ entity: SwiftDataMigrationEntity,
        limit: Int,
        decode: (SQLiteSourceRow) -> Value?
    ) throws -> SQLiteSourcePage<Value> {
        let cursor = cursors[entity] ?? ""
        guard readable.contains(entity) else {
            // 缺表：当作 0 行，让 v1 老库也能迁完其余 10 张表。
            return SQLiteSourcePage(scanned: 0, values: [], lastID: nil)
        }
        guard let connection = handle else {
            throw ObservatoryError.storeUnavailable("SQLite 源库连接已关闭")
        }

        var values: [Value] = []
        var scanned = 0
        var lastID: String?
        try forEachRow(in: connection, sql: Self.selectSQL(for: entity), cursor: cursor, limit: limit) { row in
            scanned += 1
            // id 是 keyset 游标：非文本就让整个迁移失败，而不是悄悄停在同一页。
            let id = row.text("id") ?? ""
            if id > cursor { lastID = id }
            if let value = decode(row) {
                values.append(value)
            } else {
                ObservatoryLog.store.warning(
                    "SwiftData 迁移跳过表 \(entity.sourceTableName, privacy: .public) 的一行 id=\(id, privacy: .public)（枚举 rawValue 无法识别或关键列类型不符）"
                )
            }
        }

        if scanned == limit, let lastID, lastID > cursor {
            cursors[entity] = lastID
        } else if scanned == limit {
            throw ObservatoryError.storeUnavailable(
                "迁移中止：\(entity.sourceTableName) 的一页里 id 未前进（游标 \(cursor)），源库可能有非文本主键行"
            )
        }
        return SQLiteSourcePage(scanned: scanned, values: values, lastID: lastID)
    }

    // MARK: - 私有：C API

    /// 实体的分页语句（编译期常量字符串，来自 `MigrationSQL`）。
    private static func selectSQL(for entity: SwiftDataMigrationEntity) -> String {
        switch entity {
        case .agents:        return MigrationSQL.agents
        case .sessions:      return MigrationSQL.sessions
        case .events:        return MigrationSQL.events
        case .fileChanges:   return MigrationSQL.fileChanges
        case .diffs:         return MigrationSQL.diffs
        case .commands:      return MigrationSQL.commands
        case .perfSamples:   return MigrationSQL.perfSamples
        case .systemPerf:    return MigrationSQL.systemPerf
        case .riskEvents:    return MigrationSQL.riskEvents
        case .projects:      return MigrationSQL.projects
        case .fileSnapshots: return MigrationSQL.fileSnapshots
        }
    }

    /// 源库里存在的表名。
    ///
    /// 单独走一遍 prepare/step（而不是复用 `forEachRow`）：这条查询没有游标与页大小参数。
    /// 失败**抛出**而不是返回空集合 —— 返回空集合会把「读不到 sqlite_master」伪装成
    /// 「这张表本来 0 行」，那是最难查的迁移 bug。
    private static func existingTables(in connection: OpaquePointer) throws -> Set<String> {
        var statement: OpaquePointer?
        let sql = "SELECT name FROM sqlite_master WHERE type = 'table'"
        let code = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard code == Int32(SQLITE_OK), let prepared = statement else {
            if let stale = statement { sqlite3_finalize(stale) }
            throw ObservatoryError.storeUnavailable(
                "读取源库表清单失败（\(failureDescription(sql: sql, connection: connection, code: code))）"
            )
        }
        defer { sqlite3_finalize(prepared) }
        var names: Set<String> = []
        while true {
            let stepCode = sqlite3_step(prepared)
            if stepCode == Int32(SQLITE_ROW) {
                // 取的是**行的值**（表名），不是列名：`sqlite3_column_name` 在这条查询里
                // 永远返回 "name"，用它会让清单变成 {"name"}，于是 11 张表全部「缺表」，
                // 迁移静默读出 0 行。
                if case .text(let name) = columnValue(of: prepared, index: 0) { names.insert(name) }
                continue
            }
            if stepCode == Int32(SQLITE_DONE) { return names }
            throw ObservatoryError.storeUnavailable(
                "读取源库表清单失败（\(failureDescription(sql: sql, connection: connection, code: stepCode))）"
            )
        }
    }

    /// 可迁移的表：`StoreSchema` 的 11 张里源库真有的那些。
    /// 缺表不是错误（v1 建的库就没有 `file_snapshots`，`StoreSchema` v2 才补上建表语句），
    /// 那张表按 0 行处理并记一条 warning。
    private static func readableTables(in connection: OpaquePointer) throws -> Set<SwiftDataMigrationEntity> {
        let existing = try existingTables(in: connection)
        var readable: Set<SwiftDataMigrationEntity> = []
        for entity in SwiftDataMigrationEntity.allCases {
            if existing.contains(entity.sourceTableName) {
                readable.insert(entity)
            } else {
                ObservatoryLog.store.warning(
                    "SQLite 源库缺少表 \(entity.sourceTableName, privacy: .public)，该表按 0 行处理"
                )
            }
        }
        return readable
    }

    /// 预编译 + 绑定游标 + 逐行回调。语句在本调用内 finalize，绝不跨调用存活。
    /// （回调参数刻意不叫 `handle` —— 那是连接句柄的名字，同名会读错。）
    private func forEachRow(
        in connection: OpaquePointer,
        sql: String,
        cursor: String,
        limit: Int,
        rowHandler: (SQLiteSourceRow) -> Void
    ) throws {
        var statement: OpaquePointer?
        let prepareCode = sqlite3_prepare_v2(connection, sql, -1, &statement, nil)
        guard prepareCode == Int32(SQLITE_OK), let prepared = statement else {
            if let stale = statement { sqlite3_finalize(stale) }
            throw ObservatoryError.storeUnavailable(
                "预编译迁移查询失败（\(Self.failureDescription(sql: sql, connection: connection, code: prepareCode))）"
            )
        }
        defer { sqlite3_finalize(prepared) }

        // SQLITE_TRANSIENT：Swift 侧的 C 字符串缓冲区只在 withCString 闭包内存活，
        // 必须让 SQLite 立刻复制字节。
        let bindText = cursor.withCString { pointer in
            sqlite3_bind_text(prepared, 1, pointer, Int32(clamping: cursor.utf8.count), Self.transient)
        }
        let bindLimit = sqlite3_bind_int64(prepared, 2, Int64(clamping: limit))
        guard bindText == Int32(SQLITE_OK), bindLimit == Int32(SQLITE_OK) else {
            let code = bindText != Int32(SQLITE_OK) ? bindText : bindLimit
            throw ObservatoryError.storeUnavailable(
                "迁移查询绑定参数失败（\(Self.failureDescription(sql: sql, connection: connection, code: code))）"
            )
        }

        let names = Self.columnNames(of: prepared)
        while true {
            let code = sqlite3_step(prepared)
            if code == Int32(SQLITE_ROW) {
                var columns: [SQLiteSourceColumn] = []
                columns.reserveCapacity(names.count)
                for index in 0..<names.count {
                    columns.append(Self.columnValue(of: prepared, index: index))
                }
                rowHandler(SQLiteSourceRow(names: names, values: columns))
                continue
            }
            if code == Int32(SQLITE_DONE) { return }
            throw ObservatoryError.storeUnavailable(
                "读取迁移数据失败（\(Self.failureDescription(sql: sql, connection: connection, code: code))）"
            )
        }
    }

    private static func columnNames(of statement: OpaquePointer) -> [String] {
        let count = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(count)
        for index in 0..<count { names.append(columnName(in: statement, index: index) ?? "") }
        return names
    }

    private static func columnName(in statement: OpaquePointer, index: Int) -> String? {
        decodeCString(sqlite3_column_name(statement, Int32(index)))
    }

    /// 读一列。NULL 的 `sqlite3_column_text` 会返回 nil，所以先看列类型。
    private static func columnValue(of statement: OpaquePointer, index: Int) -> SQLiteSourceColumn {
        let type = Int32(sqlite3_column_type(statement, Int32(index)))
        if type == Int32(SQLITE_NULL) { return .null }
        if type == Int32(SQLITE_INTEGER) { return .integer(sqlite3_column_int64(statement, Int32(index))) }
        if type == Int32(SQLITE_FLOAT) { return .real(sqlite3_column_double(statement, Int32(index))) }
        if type == Int32(SQLITE_BLOB) {
            // 先取指针再取长度（取另一种表示可能改变长度）。
            guard let pointer = sqlite3_column_blob(statement, Int32(index)) else { return .blob(Data()) }
            let length = Int(sqlite3_column_bytes(statement, Int32(index)))
            guard length > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: length))
        }
        guard let pointer = sqlite3_column_text(statement, Int32(index)) else { return .text("") }
        let length = Int(sqlite3_column_bytes(statement, Int32(index)))
        guard length > 0 else { return .text("") }
        // 非法 UTF-8 退化为 lossy 解码，绝不强解。
        return .text(String(decoding: Data(bytes: pointer, count: length), as: UTF8.self))
    }

    private static func failureDescription(sql: String, connection: OpaquePointer, code: Int32) -> String {
        "错误码 \(code)：\(message(from: connection))｜SQL: \(abbreviated(sql))"
    }

    private static func message(from connection: OpaquePointer?) -> String {
        guard let connection else { return "SQLite 连接不可用" }
        return decodeCString(sqlite3_errmsg(connection)) ?? "SQLite 未给出错误消息"
    }

    /// C 字符串 → Swift String（按 UTF-8 复制，非法序列 lossy 退化）。空串当作 nil。
    private static func decodeCString(_ pointer: UnsafePointer<CChar>?) -> String? {
        guard let pointer else { return nil }
        let data = Data(bytes: pointer, count: Int(strlen(pointer)))
        guard !data.isEmpty else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// `SQLITE_TRANSIENT`。用计算属性而不是全局 `let`，避开 Swift 6 对全局变量的并发安全要求。
    private static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// 错误消息里不把整条 SQL 摊开。
    private static func abbreviated(_ sql: String) -> String {
        let oneLine = sql.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > 160 ? String(oneLine.prefix(160)) + "…" : oneLine
    }
}
