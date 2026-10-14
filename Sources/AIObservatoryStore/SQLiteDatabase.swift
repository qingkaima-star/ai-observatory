//
//  SQLiteDatabase.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine
//  Sub-owner: A
//
//  对 sqlite3 C API 的 actor 封装（打开 / WAL / busy_timeout / prepared statement LRU
//  缓存 / 事务 / 迁移应用 / checkpoint / vacuum / 关闭）。
//
//  ── 并发设计（INTERFACE.md §3、§6A）─────────────────────────────────────────
//  · 本 actor 的**每个公开方法内部都不含 await**（全同步）。调用方 `await db.xxx()`
//    只跨一次 actor 边界，中途不可能被同一个 db 的其他调用插入 → 天然无重入、
//    无「半提交」状态。多语句原子写因此必须一次性交给 `inTransaction(_:)`。
//  · 查询结果在 actor 内**完全物化**为 Swift 值（`[SQLiteRow]`），绝不外泄游标、
//    `sqlite3_stmt*` 或任何指向 SQLite 内存的指针。
//  · 唯一允许的 `nonisolated(unsafe)` 是连接句柄本身（见 `handle`）。
//
//  ── 路径策略 ───────────────────────────────────────────────────────────────
//  本封装**不校验**路径是否位于「授权工作目录」（本次运行被允许读写的那棵树）内；
//  该约束由调用方（ObservatoryStore / App 装配层）负责。这里只负责在必要时创建父目录。
//

import Foundation
import OSLog
import SQLite3

import AIObservatoryCore

// MARK: - SQLiteValue

/// SQL 绑定值。
public enum SQLiteValue: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

// MARK: - SQLiteStatement

/// 一条待执行语句（值类型，可跨 actor 边界）。
public struct SQLiteStatement: Sendable, Hashable {
    /// 单条 SQL（不含 `;` 分隔的多语句；多语句请拆成多个 SQLiteStatement）。
    public var sql: String
    /// 按 `?` 占位符顺序排列的绑定参数。
    public var arguments: [SQLiteValue]

    /// 构造一条语句。
    public init(_ sql: String, arguments: [SQLiteValue] = []) {
        self.sql = sql
        self.arguments = arguments
    }
}

// MARK: - SQLiteColumn

/// 一列取回后的值。
public enum SQLiteColumn: Sendable, Hashable {
    case null
    case integer(Int64)
    case real(Double)
    case text(String)
    case blob(Data)
}

// 内部（非公共 API）宽松转换：SQLite 是动态类型存储，同一列可能混入
// INTEGER/REAL/TEXT（例如聚合表达式的结果），因此读取时做无损尽力转换。
extension SQLiteColumn {
    /// 转成 64 位整数：integer 直取、real 截断、text 按十进制解析、null/blob 为 nil。
    var coercedInt64: Int64? {
        switch self {
        case .null:                             return nil
        case .integer(let value):               return value
        case .real(let value):                  return value.isFinite ? Int64(value) : nil
        case .text(let value):                  return Int64(value.trimmingCharacters(in: .whitespaces))
        case .blob:                             return nil
        }
    }

    /// 转成 Double：integer/real 直取、text 按小数解析、其余为 nil。
    var coercedDouble: Double? {
        switch self {
        case .null:                             return nil
        case .integer(let value):               return Double(value)
        case .real(let value):                  return value
        case .text(let value):                  return Double(value.trimmingCharacters(in: .whitespaces))
        case .blob:                             return nil
        }
    }

    /// 仅当底层确实是文本时返回（不做数字→字符串的伪造格式化）。
    var coercedText: String? {
        switch self {
        case .text(let value):                  return value
        case .blob(let data):                   return String(decoding: data, as: UTF8.self)
        default:                                return nil
        }
    }
}

// MARK: - SQLiteRow

/// 一行结果（列名 → 值），已在 actor 内完全物化。
public struct SQLiteRow: Sendable, Hashable {
    /// 列名到值的映射（实现细节；对外通过 `column(_:)` / `columnNames` 访问）。
    private let columns: [String: SQLiteColumn]

    /// 用列字典构造一行。
    public init(columns: [String: SQLiteColumn]) {
        self.columns = columns
    }

    /// 列名清单，按字典序返回（与字典的随机迭代顺序无关，保证可断言/可比对）。
    public var columnNames: [String] {
        columns.keys.sorted()
    }

    /// 取原始列值；列不存在返回 nil。
    public func column(_ name: String) -> SQLiteColumn? {
        columns[name]
    }

    /// 文本列（BLOB 会按 UTF-8 解码兜底）；其他类型返回 nil，不伪造字符串。
    public func text(_ name: String) -> String? {
        column(name)?.coercedText
    }

    /// 整数列（64 位平台下 Int64→Int 无损）；非数值列返回 nil。
    public func int(_ name: String) -> Int? {
        guard let value = column(name)?.coercedInt64 else { return nil }
        return Int(value)
    }

    /// 64 位整数列；非数值列返回 nil。
    public func int64(_ name: String) -> Int64? {
        column(name)?.coercedInt64
    }

    /// 以 `Int64(bitPattern:)` 往返存回来的 UInt64（memory_bytes 等）；非整数列返回 nil。
    public func uint64(_ name: String) -> UInt64? {
        switch column(name) {
        case .integer(let value):   return UInt64(bitPattern: value)
        case .real(let value):      return value.isFinite && value >= 0 ? UInt64(value) : nil
        default:                    return nil
        }
    }

    /// Double 列；非数值列返回 nil。
    public func double(_ name: String) -> Double? {
        column(name)?.coercedDouble
    }

    /// 布尔列：非 0 → true；列缺失或为 NULL/无法解析 → false。
    public func bool(_ name: String) -> Bool {
        guard let value = column(name)?.coercedInt64 else { return false }
        return value != 0
    }

    /// 日期列：按 REAL `timeIntervalSinceReferenceDate` 解释；INTEGER 同口径；无值或 NaN 返回 nil。
    /// 用参考日期而非 1970 纪元存储：`±978307200` 的纪元换算会让每个时间戳抖动 1 ULP（约 1.2e-7 秒），
    /// 直接存内部表示则编解码恒等，Date 可逐位往返。
    public func date(_ name: String) -> Date? {
        guard let seconds = column(name)?.coercedDouble, seconds.isFinite else { return nil }
        return Date(timeIntervalSinceReferenceDate: seconds)
    }

    /// UUID 列：按文本 `UUID(uuidString:)` 解析，失败返回 nil（不伪造）。
    public func uuid(_ name: String) -> UUID? {
        guard let raw = column(name)?.coercedText else { return nil }
        return UUID(uuidString: raw)
    }
}

// MARK: - SQLiteDatabase

/// 对单个 sqlite3 连接的 actor 封装。
public actor SQLiteDatabase {
    // MARK: 配置与错误

    /// 数据库位置。
    public enum Location: Sendable, Hashable {
        /// `":memory:"`：不落地文件（SQLite 不支持 WAL，封装会自动跳过）。
        case memory
        /// 文件库。路径合法性（只允许 AiX 内）由调用方负责，见文件头注释。
        case file(path: String)
    }

    /// 打开参数。
    public struct Configuration: Sendable, Hashable {
        /// 数据库位置。
        public var location: Location
        /// `sqlite3_busy_timeout` 毫秒数（映射为 Int32）。
        public var busyTimeoutMilliseconds: Int
        /// 文件库是否启用 WAL；`Location.memory` 时无条件跳过。
        public var useWAL: Bool
        /// prepared statement LRU 缓存条数上限（至少 1）。
        public var statementCacheLimit: Int

        /// 构造配置。
        public init(
            location: Location,
            busyTimeoutMilliseconds: Int = 5_000,
            useWAL: Bool = true,
            statementCacheLimit: Int = 64
        ) {
            self.location = location
            self.busyTimeoutMilliseconds = busyTimeoutMilliseconds
            self.useWAL = useWAL
            self.statementCacheLimit = statementCacheLimit
        }

        /// 内存库默认配置。
        public static let inMemory: Configuration = Configuration(location: .memory)

        /// 文件库默认配置（WAL + 5 秒 busy_timeout）。
        public static func file(_ path: String) -> Configuration {
            Configuration(location: .file(path: path))
        }
    }

    /// 存储层错误。`errorDescription` 为中文，并带上 SQLite 原始消息。
    public enum Error: LocalizedError, Equatable, Sendable {
        case openFailed(code: Int32, message: String)
        case prepareFailed(sql: String, code: Int32, message: String)
        case stepFailed(sql: String, code: Int32, message: String)
        case closed
        case migrationFailed(version: Int, message: String)

        public var errorDescription: String? {
            switch self {
            case .openFailed(let code, let message):
                return "无法打开数据库（SQLite 错误码 \(code)）：\(message)"
            case .prepareFailed(let sql, let code, let message):
                return "SQL 预编译失败（错误码 \(code)）：\(message)｜SQL: \(abbreviatedSQL(sql))"
            case .stepFailed(let sql, let code, let message):
                return "SQL 执行失败（错误码 \(code)）：\(message)｜SQL: \(abbreviatedSQL(sql))"
            case .closed:
                return "数据库连接已关闭。"
            case .migrationFailed(let version, let message):
                return "Schema 迁移到版本 \(version) 失败：\(message)"
            }
        }
    }

    // MARK: 存储属性

    /// sqlite3 连接句柄。
    ///
    /// 这是本文件（也是整个 Store 层）**唯一**允许的 `nonisolated(unsafe)`：
    /// 它只是一个 C 连接指针，之所以要 nonisolated，是因为 `deinit` 不在 actor 隔离域内、
    /// 必须能访问它来做最终关闭。所有实际的 SQLite 调用都发生在**本 actor 的隔离域内**
    /// （每个方法全同步、无 await → 串行），`close()` 之后句柄被置回 nil，
    /// 因此 `deinit` 里的 `closeHandle()` 不会二次关闭。
    nonisolated(unsafe) private var handle: OpaquePointer?

    private let configuration: Configuration
    private let isOpenInMemory: Bool

    /// LRU 缓存：SQL → 已预编译语句。
    private var cachedStatements: [String: OpaquePointer] = [:]
    /// 缓存的访问顺序，末尾为最近使用。
    private var cacheOrder: [String] = []
    /// 事务嵌套计数（>0 表示已在事务中，禁止重复 BEGIN）。
    private var transactionDepth: Int = 0
    /// SQLite 侧是否真的有我们开启的事务（最外层 BEGIN 成功才为 true）。
    private var transactionBegun: Bool = false
    /// 是否已显式 `close()`。
    private var isClosed: Bool = false

    // MARK: 生命周期

    /// 打开（或创建）数据库并应用启动 PRAGMA。失败抛 `SQLiteDatabase.Error.openFailed`。
    public init(configuration: Configuration) throws {
        let path = Self.pathString(for: configuration.location)
        if case .file(let filePath) = configuration.location {
            Self.createParentDirectory(forFilePath: filePath)
        }
        var opened: OpaquePointer?
        let flags = Int32(SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX)
        let code = sqlite3_open_v2(path, &opened, flags, nil)
        guard code == Int32(SQLITE_OK) else {
            let message = opened.flatMap { Self.message(from: $0) } ?? "sqlite3_open_v2 返回错误码 \(code)"
            if let leaked = opened { sqlite3_close_v2(leaked) }
            throw Error.openFailed(code: code, message: message)
        }
        guard let connection = opened else {
            throw Error.openFailed(code: Int32(SQLITE_OK), message: "打开成功但连接指针为 nil")
        }
        self.handle = connection
        self.configuration = configuration
        self.isOpenInMemory = configuration.location.isMemory

        do {
            try Self.startup(connection: connection, configuration: configuration)
        } catch {
            self.handle = nil
            sqlite3_close_v2(connection)
            throw error
        }
    }

    /// 关闭连接：先 finalize 全部缓存语句，再 `sqlite3_close_v2`。重复调用是安全的 no-op。
    public func close() {
        clearStatementCache()
        transactionDepth = 0
        transactionBegun = false
        isClosed = true
        closeHandle()
    }

    /// 连接是否仍然可用（`close()` 后为 false）。
    public var isOpen: Bool {
        !isClosed && (handle != nil)
    }

    /// `deinit` 不是 actor 隔离域：只能调用 nonisolated helper。
    deinit {
        closeHandle()
    }

    // MARK: 执行

    /// 顺序执行多条语句（无显式事务），返回受影响行数总和。任一失败即抛出（不回滚）。
    @discardableResult
    public func execute(_ statements: [SQLiteStatement]) throws -> Int {
        var affected = 0
        for statement in statements {
            affected += try perform(statement)
        }
        return affected
    }

    /// 执行单条语句（结果行被丢弃）。用于 PRAGMA / 单条写。
    public func run(_ sql: String, arguments: [SQLiteValue] = []) throws {
        _ = try perform(SQLiteStatement(sql, arguments: arguments))
    }

    /// 单事务原子执行一批语句：`BEGIN IMMEDIATE` → 逐条执行 → `COMMIT`；
    /// 任何失败自动 `ROLLBACK` 并 rethrow 原错误。已在事务中时不再重复 BEGIN。
    public func inTransaction(_ statements: [SQLiteStatement]) throws {
        try beginNested()
        do {
            for statement in statements {
                _ = try perform(statement)
            }
            try commitNested()
        } catch {
            rollbackNested()
            throw error
        }
    }

    // MARK: 查询

    /// 执行查询并在 actor 内完全物化为 `[SQLiteRow]`（不外泄游标）。
    public func rows(_ sql: String, arguments: [SQLiteValue] = []) throws -> [SQLiteRow] {
        let connection = try requireConnection()
        let statement = try cachedStatement(for: sql)
        defer { Self.resetForReuse(statement, sql: sql) }
        try Self.bind(arguments, to: statement, sql: sql)
        return try Self.fetchRows(of: statement, sql: sql, handle: connection)
    }

    /// 查询至多一行：无结果返回 nil（多于一条时取第一条）。
    public func optionalRow(_ sql: String, arguments: [SQLiteValue] = []) throws -> SQLiteRow? {
        try rows(sql, arguments: arguments).first
    }

    /// 取第一行的第一列；无行或无列返回 nil。
    public func scalar(_ sql: String, arguments: [SQLiteValue] = []) throws -> SQLiteColumn? {
        let connection = try requireConnection()
        let statement = try cachedStatement(for: sql)
        defer { Self.resetForReuse(statement, sql: sql) }
        try Self.bind(arguments, to: statement, sql: sql)
        while true {
            let code = sqlite3_step(statement)
            if code == Int32(SQLITE_ROW) {
                // 没有任何列时不要拿 index 0 去问 SQLite（会触发 misuse）。
                guard sqlite3_column_count(statement) > 0 else { return nil }
                return Self.columnValue(of: statement, index: 0)
            }
            if code == Int32(SQLITE_DONE) {
                return nil
            }
            throw Error.stepFailed(sql: sql, code: code, message: Self.message(from: connection))
        }
    }

    /// 取第一行第一列并转成 Int；无值或非数值返回 nil。
    public func scalarInt(_ sql: String, arguments: [SQLiteValue] = []) throws -> Int? {
        guard let value = try scalar(sql, arguments: arguments) else { return nil }
        guard let wide = value.coercedInt64 else { return nil }
        return Int(wide)
    }

    /// 最近一次插入的 rowid（`WITHOUT ROWID` 表或已关闭时为 0）。
    public var lastInsertRowID: Int64 {
        guard !isClosed, let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    /// 上一条语句影响的行数（`sqlite3_changes`）。
    public var changes: Int {
        guard !isClosed, let handle else { return 0 }
        return Int(sqlite3_changes(handle))
    }

    // MARK: schema 版本与运维

    /// 读取 `PRAGMA user_version`（未建库时为 0）。
    public func userVersion() throws -> Int {
        let value = try scalar("PRAGMA user_version")
        return Int(value?.coercedInt64 ?? 0)
    }

    /// 写入 `PRAGMA user_version`。
    public func setUserVersion(_ version: Int) throws {
        // 只拼接 Int64 字面量，不存在注入风险。
        let clamped = Int64(clamping: version)
        try run("PRAGMA user_version = \(clamped)")
    }

    /// 原子应用有序迁移（幂等）：校验清单 → 读 `user_version` → 逐版本
    /// `inTransaction{ DDL 语句 + PRAGMA user_version = v }`，返回实际应用的迁移数。
    /// 重复调用（版本已追平）返回 0 且不改任何东西。
    @discardableResult
    public func applyMigrations(_ migrations: [SchemaMigration]) throws -> Int {
        try SchemaMigrator.validate(migrations)
        let current = try userVersion()
        let pending = SchemaMigrator.plan(currentVersion: current, migrations: migrations)
        var applied = 0
        for migration in pending {
            var statements = migration.statements
            statements.append(SQLiteStatement("PRAGMA user_version = \(Int64(clamping: migration.version))"))
            do {
                try inTransaction(statements)
            } catch {
                throw Error.migrationFailed(
                    version: migration.version,
                    message: "\(migration.name)：\((error as? Error)?.errorDescription ?? String(describing: error))"
                )
            }
            applied += 1
        }
        return applied
    }

    /// `PRAGMA wal_checkpoint(TRUNCATE)`；内存库直接跳过（内存库不支持 WAL）。
    public func checkpoint() throws {
        guard !isOpenInMemory else { return }
        try run("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    /// `VACUUM` 回收空间。注意：不能与进行中的事务同时使用（SQLite 会报错并抛出）。
    public func vacuum() throws {
        try run("VACUUM")
    }

    /// 立即 finalize 并清空 prepared statement LRU 缓存（下次执行会重新 prepare）。
    public func clearStatementCache() {
        for statement in cachedStatements.values {
            sqlite3_finalize(statement)
        }
        cachedStatements.removeAll()
        cacheOrder.removeAll()
    }

    // MARK: - 内部实现（全部同步，无 await）

    /// 取得仍可用的连接。
    private func requireConnection() throws -> OpaquePointer {
        guard !isClosed, let handle else { throw Error.closed }
        return handle
    }

    /// 执行一条语句（走 LRU 缓存），返回 `sqlite3_changes`。
    private func perform(_ statement: SQLiteStatement) throws -> Int {
        let connection = try requireConnection()
        let prepared = try cachedStatement(for: statement.sql)
        defer { Self.resetForReuse(prepared, sql: statement.sql) }
        try Self.bind(statement.arguments, to: prepared, sql: statement.sql)
        try Self.discardRows(of: prepared, sql: statement.sql, handle: connection)
        return Int(sqlite3_changes(connection))
    }

    /// BEGIN（已在事务中则只加计数，绝不重复 BEGIN）。
    private func beginNested() throws {
        transactionDepth += 1
        guard !transactionBegun else { return }
        do {
            try Self.executeRaw(Self.beginSQL, on: requireConnection())
        } catch {
            transactionDepth -= 1
            throw error
        }
        transactionBegun = true
    }

    /// 最外层退出时 COMMIT；内层只减计数。
    private func commitNested() throws {
        guard transactionDepth > 0 else { return }
        transactionDepth -= 1
        guard transactionDepth == 0, transactionBegun else { return }
        try Self.executeRaw(Self.commitSQL, on: requireConnection())
        transactionBegun = false
    }

    /// 回滚到无事务状态。ROLLBACK 自身失败只记日志，**不覆盖**调用方要抛出的原错误。
    private func rollbackNested() {
        transactionDepth = 0
        guard transactionBegun else { return }
        transactionBegun = false
        guard let connection = handle else { return }
        do {
            try Self.executeRaw(Self.rollbackSQL, on: connection)
        } catch {
            ObservatoryLog.store.error(
                "SQLite ROLLBACK 失败（保留原错误）：\(String(reflecting: error), privacy: .public)"
            )
        }
    }

    /// 从 LRU 缓存取得或新预编译一条语句。
    private func cachedStatement(for sql: String) throws -> OpaquePointer {
        let connection = try requireConnection()
        if let hit = cachedStatements[sql] {
            touch(sql)
            // 每次复用前：sqlite3_reset + sqlite3_clear_bindings（INTERFACE.md §6A），
            // 保证上一次执行/绑定的残留状态不会污染本次执行。
            Self.resetForReuse(hit, sql: sql)
            return hit
        }
        let prepared = try Self.prepare(sql, on: connection)
        let limit = max(1, configuration.statementCacheLimit)
        cachedStatements[sql] = prepared
        cacheOrder.append(sql)
        while cacheOrder.count > limit {
            let victim = cacheOrder.removeFirst()
            if let stale = cachedStatements.removeValue(forKey: victim) {
                sqlite3_finalize(stale)
            }
        }
        return prepared
    }

    /// 把某个 key 标记为最近使用。
    private func touch(_ sql: String) {
        cacheOrder.removeAll { $0 == sql }
        cacheOrder.append(sql)
    }

    /// 语句复用前的复位：`sqlite3_reset` + `sqlite3_clear_bindings`。
    /// 既在每次从缓存取出时调用，也在执行结束后（`defer`）调用，确保异常路径不残留游标。
    /// 失败只记日志：真正的错误由调用方（step/prepare 的返回值）抛出。
    /// 声明为 static（非隔离）以便在 `defer` 里零隔离歧义地调用。
    private static func resetForReuse(_ statement: OpaquePointer, sql: String) {
        let code = sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        if code != Int32(SQLITE_OK) {
            ObservatoryLog.store.warning(
                "SQLite reset 失败 SQL=\(abbreviatedSQL(sql), privacy: .public) code=\(code, privacy: .public)"
            )
        }
    }

    /// 非隔离路径上的收尾：真正关闭句柄并置 nil（幂等）。
    ///
    /// 缓存语句的 finalize 由隔离的 `close()` 负责；若绕过 `close()` 直接析构，
    /// `sqlite3_close_v2` 对仍有未 finalize 的语句是安全的（连接转为 zombie，
    /// 待 SQLite 内部所有对象释放后回收），不会崩溃。
    nonisolated private func closeHandle() {
        guard let connection = handle else { return }
        handle = nil
        // 已知限制（审计 P2-10）：deinit 是非隔离域，无法读 actor 隔离的 `cachedStatements`，
        // 所以这里只能关连接，不 finalize 缓存语句。未显式 `close()` 就释放时，
        // `sqlite3_close_v2` 会把连接挂成 zombie 等待 stmt 释放，那些 stmt 便随之滞留。
        // 触发面只有「不调用 close() 就丢弃实例」（进程退出由系统回收，引擎侧 Store 全程常驻）。
        // 根治方案：把缓存值换成持有 stmt 的 `StatementBox`（其 deinit 里 finalize），
        // 这样释放顺序不再依赖 actor 隔离。留待后续，不做半吊子改法。
        sqlite3_close_v2(connection)
    }

    /// 打开后立即应用的 PRAGMA / busy_timeout。
    private static func startup(connection: OpaquePointer, configuration: Configuration) throws {
        // sqlite3_busy_timeout 的参数是 Int32 毫秒。
        sqlite3_busy_timeout(connection, Int32(clamping: configuration.busyTimeoutMilliseconds))
        if case .file = configuration.location, configuration.useWAL {
            // 内存库不支持 WAL，因此只在文件库上执行。
            try executeRaw("PRAGMA journal_mode=WAL", on: connection)
        }
        try executeRaw("PRAGMA synchronous=NORMAL", on: connection)
        try executeRaw("PRAGMA foreign_keys=ON", on: connection)
    }

    // MARK: 静态 C API helper（无共享状态，可在任何上下文调用）

    private static let beginSQL = "BEGIN IMMEDIATE"
    private static let commitSQL = "COMMIT"
    private static let rollbackSQL = "ROLLBACK"

    /// 一次性执行（不查缓存、立即 finalize）：用于 BEGIN/COMMIT/ROLLBACK/PRAGMA，
    /// 避免把控制语句挤进查询用的 LRU 缓存。
    private static func executeRaw(_ sql: String, on connection: OpaquePointer) throws {
        let statement = try prepare(sql, on: connection)
        defer { sqlite3_finalize(statement) }
        try discardRows(of: statement, sql: sql, handle: connection)
    }

    private static func prepare(_ sql: String, on connection: OpaquePointer) throws -> OpaquePointer {
        var prepared: OpaquePointer?
        let code = sqlite3_prepare_v2(connection, sql, -1, &prepared, nil)
        if code != Int32(SQLITE_OK) {
            if let stale = prepared { sqlite3_finalize(stale) }
            throw Error.prepareFailed(sql: sql, code: code, message: message(from: connection))
        }
        guard let statement = prepared else {
            throw Error.prepareFailed(
                sql: sql,
                code: Int32(SQLITE_ERROR),
                message: "prepare 返回 SQLITE_OK 但语句指针为 nil"
            )
        }
        return statement
    }

    /// 绑定参数。文本/BLOB 一律用 `SQLITE_TRANSIENT`，让 SQLite 立刻复制字节，
    /// 因为 Swift 侧的缓冲区只在 `withCString` / `withUnsafeBytes` 闭包内存活。
    private static func bind(_ arguments: [SQLiteValue], to statement: OpaquePointer, sql: String) throws {
        for (offset, value) in arguments.enumerated() {
            let index = Int32(offset + 1)
            let code: Int32
            switch value {
            case .null:
                code = sqlite3_bind_null(statement, index)
            case .integer(let raw):
                code = sqlite3_bind_int64(statement, index, raw)
            case .real(let raw):
                code = sqlite3_bind_double(statement, index, raw)
            case .text(let raw):
                code = raw.withCString { pointer in
                    sqlite3_bind_text(statement, index, pointer, Int32(clamping: raw.utf8.count), SQLiteDestructor.transient)
                }
            case .blob(let raw):
                if raw.isEmpty {
                    // 空 BLOB：零长度 + SQLITE_STATIC，不需要 SQLite 复制任何东西。
                    code = sqlite3_bind_blob(statement, index, nil, 0, SQLiteDestructor.staticValue)
                } else {
                    code = raw.withUnsafeBytes { buffer -> Int32 in
                        guard let base = buffer.baseAddress else {
                            return sqlite3_bind_null(statement, index)
                        }
                        return sqlite3_bind_blob(statement, index, base, Int32(clamping: buffer.count), SQLiteDestructor.transient)
                    }
                }
            }
            if code != Int32(SQLITE_OK) {
                throw Error.stepFailed(
                    sql: sql,
                    code: code,
                    message: "第 \(index) 个参数绑定失败"
                )
            }
        }
    }

    /// 执行到 SQLITE_DONE，丢弃任何结果行。
    private static func discardRows(of statement: OpaquePointer, sql: String, handle: OpaquePointer) throws {
        while true {
            let code = sqlite3_step(statement)
            if code == Int32(SQLITE_ROW) { continue }
            if code == Int32(SQLITE_DONE) { return }
            throw Error.stepFailed(sql: sql, code: code, message: message(from: handle))
        }
    }

    /// 执行到 SQLITE_DONE，把每一行完全物化成 Swift 值。
    private static func fetchRows(of statement: OpaquePointer, sql: String, handle: OpaquePointer) throws -> [SQLiteRow] {
        let columnCount = Int(sqlite3_column_count(statement))
        var names: [String] = []
        names.reserveCapacity(columnCount)
        for index in 0..<columnCount {
            names.append(decode(sqlite3_column_name(statement, Int32(index))))
        }
        var fetched: [SQLiteRow] = []
        while true {
            let code = sqlite3_step(statement)
            if code == Int32(SQLITE_ROW) {
                var values: [String: SQLiteColumn] = [:]
                values.reserveCapacity(columnCount)
                for index in 0..<columnCount {
                    values[names[index]] = columnValue(of: statement, index: index)
                }
                fetched.append(SQLiteRow(columns: values))
                continue
            }
            if code == Int32(SQLITE_DONE) { return fetched }
            throw Error.stepFailed(sql: sql, code: code, message: message(from: handle))
        }
    }

    /// 读取一列。NULL 列的 `sqlite3_column_text` 会返回 nil，因此先看列类型。
    private static func columnValue(of statement: OpaquePointer, index: Int) -> SQLiteColumn {
        let type = Int32(sqlite3_column_type(statement, Int32(index)))
        if type == Int32(SQLITE_NULL) {
            return .null
        }
        if type == Int32(SQLITE_INTEGER) {
            return .integer(sqlite3_column_int64(statement, Int32(index)))
        }
        if type == Int32(SQLITE_FLOAT) {
            return .real(sqlite3_column_double(statement, Int32(index)))
        }
        if type == Int32(SQLITE_BLOB) {
            // 先取指针再取长度（取文本/二进制表示可能改变长度）。
            guard let pointer = sqlite3_column_blob(statement, Int32(index)) else { return .blob(Data()) }
            let length = Int(sqlite3_column_bytes(statement, Int32(index)))
            guard length > 0 else { return .blob(Data()) }
            return .blob(Data(bytes: pointer, count: length))
        }
        // TEXT（含 SQLITE_TEXT 之外的兜底）：按 UTF-8 字节读，非法序列退化为 lossy 解码，绝不强解。
        guard let pointer = sqlite3_column_text(statement, Int32(index)) else { return .text("") }
        let length = Int(sqlite3_column_bytes(statement, Int32(index)))
        guard length > 0 else { return .text("") }
        let data = Data(bytes: pointer, count: length)
        return .text(String(decoding: data, as: UTF8.self))
    }

    /// SQLite 连接的最近一条错误消息。
    private static func message(from connection: OpaquePointer?) -> String {
        guard let connection else { return "数据库连接不可用" }
        return decode(sqlite3_errmsg(connection))
    }

    /// C 字符串 → Swift String（按 UTF-8 解码，非法序列 lossy 退化，绝不强解）。
    private static func decode(_ cString: UnsafePointer<CChar>?) -> String {
        guard let cString else { return "" }
        let data = Data(bytes: cString, count: Int(strlen(cString)))
        return String(decoding: data, as: UTF8.self)
    }

    /// 位置 → sqlite3 路径字符串。
    private static func pathString(for location: Location) -> String {
        switch location {
        case .memory:           return ":memory:"
        case .file(let path):   return path
        }
    }

    /// 尽力创建文件库的父目录；失败只记日志，由随后的 open 给出权威错误。
    private static func createParentDirectory(forFilePath path: String) {
        let parent = (path as NSString).deletingLastPathComponent
        guard !parent.isEmpty else { return }
        do {
            try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
        } catch {
            ObservatoryLog.store.warning(
                "无法创建数据库父目录 \(abbreviatedSQL(parent), privacy: .public)：\(String(reflecting: error), privacy: .public)"
            )
        }
    }
}

// MARK: - Location 便利判定

extension SQLiteDatabase.Location {
    /// 是否为内存库（内存库要跳过 WAL / checkpoint）。
    var isMemory: Bool {
        if case .memory = self { return true }
        return false
    }
}

// MARK: - SQLITE_TRANSIENT / SQLITE_STATIC

/// C 析构器常量。用计算属性而不是全局 `let`，避免 Swift 6 对全局变量并发安全的额外要求。
private enum SQLiteDestructor {
    /// `SQLITE_TRANSIENT`：SQLite 立即复制绑定内存。
    static var transient: sqlite3_destructor_type {
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    }

    /// `SQLITE_STATIC`：数据不由 SQLite 管理（仅用于长度 0 的空 BLOB）。
    static var staticValue: sqlite3_destructor_type {
        unsafeBitCast(0, to: sqlite3_destructor_type.self)
    }
}

// MARK: - 日志/错误用小工具

/// 错误信息里不把超长 SQL 或路径整条打印出来。
private func abbreviatedSQL(_ text: String) -> String {
    let oneLine = text.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    guard oneLine.count > 160 else { return oneLine }
    return String(oneLine.prefix(160)) + "…"
}
