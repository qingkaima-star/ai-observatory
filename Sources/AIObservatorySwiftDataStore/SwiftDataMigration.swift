//
//  SwiftDataMigration.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-SwiftData
//
//  ── 这个文件在做什么 ────────────────────────────────────────────────────────
//  一次性迁移器 `SwiftDataMigrator`：把用户机器上已有的 SQLite 观测库
//  （`AIObservatoryStore.ObservatoryStore` 的落盘文件）搬进 SwiftData 后端，
//  并且**可重入** —— 跑两次和只跑一次，目标库每张表的行数完全相同。
//
//  ── 为什么这里必须自带一个 SQLite 读取器 ────────────────────────────────────
//  `Package.swift`（冻结）里本 target 的依赖**只有 `AIObservatoryCore`**，
//  所以 `import AIObservatoryStore` 以及复用它的 `SQLiteDatabase` / `SQLiteRow` /
//  `StoreRows` 都不可得。而 SQLite 恰恰是迁移的数据源，不能不读。
//  出路是 macOS SDK 自带的 Clang 模块 `SQLite3`（`AIObservatoryStore/SQLiteDatabase.swift`
//  同样直接依赖它，无需在 Package.swift 里声明任何 linkedLibrary），
//  因此本文件自带一个**只读、最小化**的读取器 `SQLiteSourceReader`：
//  没有连接池、没有事务、没有 WAL PRAGMA、没有语句缓存，
//  只做「参数化 keyset 分页 + 列值宽松转换」。
//  列取值语义（`SQLiteSourceRow`）与 `SQLiteDatabase.SQLiteColumn` / `SQLiteRow` 逐条对齐，
//  行 → 领域模型的解码（`SQLiteSourceRows`）与 `StoreRows` 逐条对齐：
//  日期按 REAL `timeIntervalSinceReferenceDate`、枚举按 TEXT rawValue、
//  UInt64 按 `UInt64(bitPattern:)` 还原（源库里可以是负数，见下）、
//  布尔按 `!= 0`、pid / exit_code 用 `Int32(clamping:)`。
//  这两层口径一致是「迁移之后两个后端查出同一批行」的前提，不是风格问题。
//
//  ── 三条不能破的规则 ───────────────────────────────────────────────────────
//  1. **只用覆盖式写入**（`upsertX` / `replaceX` / `record(...)` / `recordSnapshot(_:)`），
//     绝不使用 `append`：后 5 张表的 `append` 是「只插入、不去重」语义（与 SQLite 侧的
//     `INSERT INTO events` 对齐），重跑一次行数就翻倍。
//  2. **分批，不拼全量**：每张表 `WHERE id > ? ORDER BY id ASC LIMIT ?`（首屏游标是空串，
//     因为任何 uuidString / 路径都 `>` 空串），不用 OFFSET（越翻越慢），也不把整表读进数组。
//  3. **坏数据只跳过、不伪造**：枚举 rawValue 认不出 / id 不是合法 UUID / 关键列非数值 →
//     计入 `skipped` 并记 warning，继续下一行（与 SQLite 后端 `compactMap` 丢弃非法行同口径）。
//     `diffs.lines_json` 是唯一的严格列：解不出来整行丢弃 —— 伪造一个「空 diff」
//     会让 UI 显示「这次改动没改任何东西」，比没有这条 diff 更误导。
//
//  ── 顺序 ───────────────────────────────────────────────────────────────────
//  先父后子：agents → sessions → events / file_changes / commands / perf_samples /
//  system_perf → diffs → risk_events → projects → file_snapshots。
//  `sessions` 必须早于 `risk_events`：`recordRisks(_:)` 会**重算**每个会话的
//  `riskEventCount`，而重算要求风险行已经在库里。因此会话的风险计数以 `recordRisks`
//  的结算值为最终值，迁移器自己不去数（源库带过来的计数会被算成同一个结果，重跑亦然）。
//
//  ── 只读与并发 ─────────────────────────────────────────────────────────────
//  源库以 `SQLITE_OPEN_READONLY` 打开，迁移器不写源库一个字节。
//  `SQLiteSourceReader` 是普通 `final class`（**不是** `@unchecked Sendable`）：
//  sqlite3 连接与语句指针都不是 Sendable。它只在 `migrate()` 这个 actor 隔离域内
//  作为局部量被**同步**调用，从不跨 await 传给别的隔离域（跨过去的只有 `[AgentInstance]`
//  这类 Sendable 值类型），所以既不需要假装 Sendable，也不需要 `nonisolated(unsafe)`。
//  源库若处于 WAL 模式，`-wal` / `-shm` 必须与主文件同目录且可读，否则会读到
//  「最后一次 checkpoint 之前没有落盘」的旧数据 —— 调用方应先停掉 SQLite 采集
//  （`ObservatoryStore.stop()` 会做 checkpoint）再迁移。
//

import Foundation
import os
import SQLite3
import AIObservatoryCore

// MARK: - 迁移统计

/// 单张表的搬运统计。三个计数满足 `read == written + skipped`。
public struct SwiftDataMigrationCounts: Sendable, Hashable {

    /// 从源库该表读到的行数（含随后被跳过的行）。
    public var read: Int

    /// 成功还原并交给目标库的行数。
    public var written: Int

    /// 因解码失败（枚举 rawValue 未知、id 不是 UUID、关键列类型不符）而被丢弃的行数。
    public var skipped: Int

    /// 全量成员初始化，默认全 0。
    public init(read: Int = 0, written: Int = 0, skipped: Int = 0) {
        self.read = read
        self.written = written
        self.skipped = skipped
    }

    /// 全 0 统计。
    public static let zero = SwiftDataMigrationCounts()

    /// 累加另一页的统计（分批读同一张表时逐页合并）。
    public static func += (lhs: inout SwiftDataMigrationCounts, rhs: SwiftDataMigrationCounts) {
        lhs.read += rhs.read
        lhs.written += rhs.written
        lhs.skipped += rhs.skipped
    }
}

/// 可迁移的实体。`rawValue` 就是 SQLite 侧的表名，因此
/// `report.counts(for: .fileChanges)` 与 `try await store.rowCount(table: "file_changes")`
/// 说的是同一张表 —— 用它对账即可验证「重跑不翻倍」。
public enum SwiftDataMigrationEntity: String, Sendable, Hashable, CaseIterable, Codable {

    /// SQLite `agents` ← `AgentInstance`。
    case agents
    /// SQLite `sessions` ← `AgentSession`。
    case sessions
    /// SQLite `events` ← `TimelineEvent`。
    case events
    /// SQLite `file_changes` ← `FileChange`。
    case fileChanges = "file_changes"
    /// SQLite `diffs` ← `FileDiff`（另带 `change_id`）。
    case diffs
    /// SQLite `commands` ← `CommandRecord`。
    case commands
    /// SQLite `perf_samples` ← `PerformanceSample`。
    case perfSamples = "perf_samples"
    /// SQLite `system_perf` ← `SystemPerformanceSample`。
    case systemPerf = "system_perf"
    /// SQLite `risk_events` ← `RiskEvent`。
    case riskEvents = "risk_events"
    /// SQLite `projects` ← `ProjectActivity`。
    case projects
    /// SQLite `file_snapshots` ← `FileSnapshot`。
    case fileSnapshots = "file_snapshots"

    /// 源库里的表名；同时是 `SwiftDataObservatoryStore.rowCount(table:)` 白名单里的合法值。
    public var sourceTableName: String { rawValue }
}

/// 一次迁移的结果。
public struct SwiftDataMigrationReport: Sendable, Hashable {

    /// 源 SQLite 库的位置。
    public var sourceURL: URL

    /// 每张表的统计（本次没碰过的表不在字典里，用 `counts(for:)` 取会得全 0）。
    public var countsByEntity: [SwiftDataMigrationEntity: SwiftDataMigrationCounts]

    /// 构造报告。
    public init(
        sourceURL: URL,
        countsByEntity: [SwiftDataMigrationEntity: SwiftDataMigrationCounts] = [:]
    ) {
        self.sourceURL = sourceURL
        self.countsByEntity = countsByEntity
    }

    /// 某张表的统计；未迁移过该表返回全 0。
    public func counts(for entity: SwiftDataMigrationEntity) -> SwiftDataMigrationCounts {
        countsByEntity[entity] ?? .zero
    }

    /// 源库读到的总行数（含被跳过的）。
    public var totalRead: Int { countsByEntity.values.reduce(0) { $0 + $1.read } }

    /// 写入目标库的总行数。
    public var totalWritten: Int { countsByEntity.values.reduce(0) { $0 + $1.written } }

    /// 被丢弃的总行数；非 0 说明源库有 SQLite 后端读不回来的坏行，值得人去翻日志。
    public var totalSkipped: Int { countsByEntity.values.reduce(0) { $0 + $1.skipped } }
}

// MARK: - SwiftDataMigrator

/// SQLite → SwiftData 的一次性迁移器 actor。
///
/// 用法：
/// ```swift
/// let store = try await SwiftDataObservatoryStore.open(configuration: configuration)
/// let report = try await SwiftDataMigrator(sourceURL: sqliteURL, destination: store).migrate()
/// ```
/// 重复调用 `migrate()` 安全（覆盖式写入 + keyset 分页）。
public actor SwiftDataMigrator {

    private let sourceURL: URL
    private let destination: SwiftDataObservatoryStore

    /// 单页行数上限：每页最多读这么多行、写完即释放，因此峰值内存与源库大小无关。
    private let chunkSize: Int

    /// 创建迁移器。
    ///
    /// 打开源库延后到 `migrate()`：构造一个「源文件此刻还不存在」的迁移器不该失败，
    /// 装配层可以先拿着实例再等文件落地。
    /// - Parameters:
    ///   - sourceURL: SQLite 观测库文件位置（只读打开，不会修改它）。
    ///   - destination: 目标 SwiftData 库。
    ///   - chunkSize: 单批行数；小于 1 时收敛为 1。
    public init(sourceURL: URL, destination: SwiftDataObservatoryStore, chunkSize: Int = 500) {
        self.sourceURL = sourceURL
        self.destination = destination
        self.chunkSize = max(chunkSize, 1)
    }

    /// 执行迁移（可重入：跑两次得到的目标库行数与跑一次相同）。
    ///
    /// - Returns: 每张表的 `read` / `written` / `skipped` 统计。
    /// - Throws: `ObservatoryError.storeUnavailable(_)` —— 源文件不存在、不是 SQLite 数据库、
    ///   表或列读不出来、SQLite 步进失败。**这些都不吞**：半途而废的库比不迁更危险。
    ///   单行解码失败不抛错，计入 `skipped` 并记 warning。
    public func migrate() async throws -> SwiftDataMigrationReport {
        // 取成局部常量：后面的读/写闭包只捕获这些 Sendable 值，不捕获 actor 的 self 隔离状态。
        let destination = self.destination
        let chunkSize = self.chunkSize

        let reader = try SQLiteSourceReader(fileURL: sourceURL)
        defer { reader.close() }

        var counts: [SwiftDataMigrationEntity: SwiftDataMigrationCounts] = [:]

        // ---- agents ----
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.agents, limit: chunkSize) { row in
                    SQLiteSourceRows.agent(from: row)
                }
                if !page.values.isEmpty { try await destination.upsertAgents(page.values) }
                total += page.counts
                if page.scanned < chunkSize { break }
            }
            counts[.agents] = total
        }

        // ---- sessions（必须早于 risk_events，见文件头「顺序」）----
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.sessions, limit: chunkSize) { row in
                    SQLiteSourceRows.session(from: row)
                }
                if !page.values.isEmpty { try await destination.upsertSessions(page.values) }
                total += page.counts
                if page.scanned < chunkSize { break }
            }
            counts[.sessions] = total
        }

        // ---- events ----
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.events, limit: chunkSize) { row in
                    SQLiteSourceRows.event(from: row)
                }
                if !page.values.isEmpty { try await destination.replaceEvents(page.values) }
                total += page.counts
                if page.scanned < chunkSize { break }
            }
            counts[.events] = total
        }

        // ---- file_changes ----
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.fileChanges, limit: chunkSize) { row in
                    SQLiteSourceRows.fileChange(from: row)
                }
                if !page.values.isEmpty { try await destination.replaceFileChanges(page.values) }
                total += page.counts
                if page.scanned < chunkSize { break }
            }
            counts[.fileChanges] = total
        }

        // ---- commands ----
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.commands, limit: chunkSize) { row in
                    SQLiteSourceRows.command(from: row)
                }
                if !page.values.isEmpty { try await destination.replaceCommands(page.values) }
                total += page.counts
                if page.scanned < chunkSize { break }
            }
            counts[.commands] = total
        }

        // ---- perf_samples ----
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.perfSamples, limit: chunkSize) { row in
                    SQLiteSourceRows.performanceSample(from: row)
                }
                if !page.values.isEmpty { try await destination.replacePerformanceSamples(page.values) }
                total += page.counts
                if page.scanned < chunkSize { break }
            }
            counts[.perfSamples] = total
        }

        // ---- system_perf ----
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.systemPerf, limit: chunkSize) { row in
                    SQLiteSourceRows.systemPerformanceSample(from: row)
                }
                if !page.values.isEmpty { try await destination.replaceSystemPerformance(page.values) }
                total += page.counts
                if page.scanned < chunkSize { break }
            }
            counts[.systemPerf] = total
        }

        // ---- diffs ----
        // 逐行写：`record(_:forChangeID:)` 的第二个参数来自 `change_id` 列，不属于 `FileDiff`。
        // 页内先按 `change_id` 去重并保留后出现的行：源库里同一变更出现多行时，
        // SQLite 侧 `INSERT OR REPLACE` 留下的就是后一行，迁移必须得出同样的结果。
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.diffs, limit: chunkSize) { row in
                    SQLiteSourceRows.diffEntry(from: row)
                }
                let entries = Self.lastWins(page.values, by: \.changeID)
                for entry in entries {
                    try await destination.record(entry.diff, forChangeID: entry.changeID)
                }
                total += SwiftDataMigrationCounts(
                    read: page.scanned,
                    written: entries.count,
                    skipped: page.scanned - entries.count
                )
                if page.scanned < chunkSize { break }
            }
            counts[.diffs] = total
        }

        // ---- risk_events（`recordRisks` 顺带结算 sessions.riskEventCount）----
        // 同一 `id` 在页内只保留后出现的整行（与 SQLite 侧 `ON CONFLICT(id) DO UPDATE` 同结果），
        // 否则一笔提交里出现两行同 id 会让 `SDRiskEvent.id` 的唯一约束报错。
        // 再按 chunkSize 切笔提交：`recordRisks` 只对「这批里出现过的会话」重算计数，
        // 一个会话的风险跨多笔时，最后一笔算出的才是全量；而行的先后顺序由源库的
        // `ORDER BY id ASC` 固定，所以重跑时每笔提交的构成相同 → 计数也相同（可重入）。
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.riskEvents, limit: chunkSize) { row in
                    SQLiteSourceRows.riskEvent(from: row)
                }
                let risks = Self.lastWins(page.values, by: \.id)
                for batch in Self.chunks(risks, size: chunkSize) {
                    try await destination.recordRisks(batch)
                }
                total += SwiftDataMigrationCounts(
                    read: page.scanned,
                    written: risks.count,
                    skipped: page.scanned - risks.count
                )
                if page.scanned < chunkSize { break }
            }
            counts[.riskEvents] = total
        }

        // ---- projects ----
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.projects, limit: chunkSize) { row in
                    SQLiteSourceRows.project(from: row)
                }
                if !page.values.isEmpty { try await destination.upsertProjects(page.values) }
                total += page.counts
                if page.scanned < chunkSize { break }
            }
            counts[.projects] = total
        }

        // ---- file_snapshots ----
        // `recordSnapshot(_:)` 一次只覆盖一行，所以这里逐行写；`chunkSize` 只约束读的一侧。
        // 页内按 `id` 去重并保留后出现的行，与 SQLite 侧 `INSERT OR REPLACE` 同结果。
        do {
            var total = SwiftDataMigrationCounts.zero
            while true {
                let page = try reader.page(.fileSnapshots, limit: chunkSize) { row in
                    SQLiteSourceRows.snapshot(from: row)
                }
                let snapshots = Self.lastWins(page.values, by: \.id)
                for snapshot in snapshots {
                    try await destination.recordSnapshot(snapshot)
                }
                total += SwiftDataMigrationCounts(
                    read: page.scanned,
                    written: snapshots.count,
                    skipped: page.scanned - snapshots.count
                )
                if page.scanned < chunkSize { break }
            }
            counts[.fileSnapshots] = total
        }

        // 覆盖式写入都是就地提交，缓冲区本应为空；这一句只为「迁移之后立刻查询」的调用方兜底。
        await destination.flush()

        let report = SwiftDataMigrationReport(sourceURL: sourceURL, countsByEntity: counts)
        // 整条消息必须是**一个**字符串字面量：`Logger` 的参数是 `OSLogMessage`，
        // 两个字面量用 `+` 拼起来会变成 `String`，编译不过。
        ObservatoryLog.store.info(
            "SwiftData 迁移完成 read=\(report.totalRead, privacy: .public) written=\(report.totalWritten, privacy: .public) skipped=\(report.totalSkipped, privacy: .public)"
        )
        return report
    }

    // MARK: - 私有：页内去重

    /// 按 key 去重并**保留后出现的行**（SQLite 侧 `INSERT OR REPLACE` 的语义就是后行赢），
    /// 同时保持首次出现的顺序，让重跑的写入次序稳定。
    private static func lastWins<Element: Equatable, Key: Hashable>(
        _ elements: [Element],
        by key: KeyPath<Element, Key>
    ) -> [Element] {
        var order: [Key] = []
        var latest: [Key: Element] = [:]
        for element in elements {
            let key = element[keyPath: key]
            if latest[key] == nil { order.append(key) }
            latest[key] = element
        }
        return order.compactMap { latest[$0] }
    }

    /// 按 `size` 行切块（保持顺序，末块可能不满）。
    private static func chunks<Element>(_ elements: [Element], size: Int) -> [[Element]] {
        guard !elements.isEmpty else { return [] }
        let size = max(size, 1)
        var result: [[Element]] = []
        result.reserveCapacity(elements.count / size + 1)
        var index = 0
        while index < elements.count {
            let upper = min(index + size, elements.count)
            result.append(Array(elements[index..<upper]))
            index = upper
        }
        return result
    }
}


