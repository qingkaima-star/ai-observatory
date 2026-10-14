//
//  SwiftDataScaleAndFormatTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: WS-SwiftData
//
//  两件事：
//    1. **大数据不拼全量**：5 000 条事件入库后分页读，用耗时与 phys_footprint 增量两条指标
//       证明查询走的是「谓词 + fetchLimit/fetchOffset」而不是「取全表再在 Swift 里筛」。
//    2. **磁盘格式与 SQLite 后端一致**：SwiftData 的 `.store` 本身就是一个 SQLite 文件，
//       直接用系统 `SQLite3` 模块打开它，核对日期列是 REAL（`timeIntervalSinceReferenceDate`
//       口径）、枚举列是 TEXT。格式一致才谈得上「两个后端查出的结果可比」，
//       也是迁移器能按值直搬的前提。
//
//  阈值刻意放宽：CI 机器与开发机差一个数量级不该让测试变红。这里断言的是
//  「量级合理 + 分页明显比全量便宜」，不是精确性能回归。
//

import Testing
import Foundation
import Darwin
import SQLite3
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatorySwiftDataStore

/// 进程内存（bytes），口径与全仓其它地方一致：**phys_footprint**。
///
/// 走 `proc_pid_rusage(RUSAGE_INFO_V4)` —— 即 `Tools/UIProbe/probe-footprint.swift` 里那条
/// "同 UID 免权限"的 B 路。上一版在这里退回 RSS，写的理由是"phys_footprint 在本机读不到"：
/// 那句话只对 `task_info(TASK_VM_INFO)` **那一条**路成立（它 rc≠0 ⇒ 恒为 0），
/// rusage 这条路当时**根本没试**。本波现试：self rc=0、读另一个同 UID 进程也 rc=0
/// （`tmp/j90_probe2`：rss 5.5 MB / phys_footprint 1.5 MB），⇒ 那句"平台天花板"当场收回。
///
/// 读不到就返回 nil，由调用方判红——**绝不打 0**：0 是"量到且确为零"，与"量不到"是两个结论。
private func physFootprintBytes() -> UInt64? {
    var info = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &info) { pointer -> Int32 in
        pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
            proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
        }
    }
    guard rc == 0 else { return nil }
    return info.ri_phys_footprint
}

/// 两臂增量。任何一臂量不到都直接判红，不许把"量不到"当成"增长了 0"。
private func footprintGrowth(_ before: UInt64?, _ after: UInt64?) throws -> Int64 {
    let baseline = try #require(before, "phys_footprint 读不到（rc≠0）⇒ 这条内存对照没有读数")
    let now = try #require(after, "phys_footprint 读不到（rc≠0）⇒ 这条内存对照没有读数")
    return Int64(now) - Int64(baseline)
}

private func megabytes(_ bytes: Int64) -> String {
    String(format: "%.1f MB", Double(bytes) / 1_048_576)
}

private func scaleEvent(_ index: Int) -> TimelineEvent {
    TimelineEvent(
        timestamp: Date(timeIntervalSinceReferenceDate: 800_000_000 + Double(index)),
        agentKind: index.isMultiple(of: 3) ? .claudeCode : .openAICodex,
        kind: index.isMultiple(of: 5) ? .commandExecuted : .fileModified,
        title: "事件 \(index)",
        summary: "第 \(index) 条批量写入的观测事件",
        riskLevel: RiskLevel.allCases[index % RiskLevel.allCases.count],
        projectPath: index.isMultiple(of: 2) ? FixturePaths.projectAlpha : FixturePaths.projectBeta
    )
}

@Suite("SwiftData 大数据量分页与磁盘格式", .timeLimit(.minutes(1)))
struct SwiftDataScaleTests {

    /// 5 000 条事件的分页读：总量、末页、过滤后分页三组断言。
    ///
    /// 独立算出「按 kind 过滤 + 按时间倒序 + offset 4 000」的期望切片，
    /// 与 store 返回逐 id 相等——只有过滤与分页都发生在存储层才可能成立。
    @Test("5000 条事件入库后分页读：总量正确且耗时量级合理")
    func pagedReadOverFiveThousand() async throws {
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        let clock = ContinuousClock()
        // 只生成一次：期望切片必须比对**同一批** id，重新生成会得到全新 UUID。
        let population = (0..<5_000).map { scaleEvent($0) }
        let writeStart = clock.now
        for event in population { await store.append(event) }
        await store.flush()
        let writeDuration = writeStart.duration(to: clock.now)
        #expect(writeDuration < .seconds(120), "5000 条写入耗时 \(writeDuration) 超出量级预期")

        let total = try await store.rowCount(table: "events")
        #expect(total == 5_000)

        let readStart = clock.now
        let page = try await store.events(matching: EventQuery(limit: 250, offset: 4_750))
        let readDuration = readStart.duration(to: clock.now)
        #expect(page.totalCount == 5_000, "totalCount 必须是分页前总数")
        #expect(page.items.count == 250)
        #expect(!page.hasMore)
        // 时间倒序翻到末页：页内仍是新的在前，所以第一条的时间戳必须大于最后一条。
        #expect(page.items[0].timestamp > page.items[249].timestamp)
        #expect(readDuration < .seconds(10), "末页分页读耗时 \(readDuration) 说明未在存储层分页")

        let modifiedOnly = try await store.events(matching: EventQuery(kinds: [.fileModified], limit: 100))
        #expect(modifiedOnly.totalCount == 4_000)
        #expect(modifiedOnly.items.count == 100)
        let expectedFirst = population.filter { $0.kind == .fileModified }
            .sorted { ($0.timestamp, $0.id.uuidString) > ($1.timestamp, $1.id.uuidString) }
            .prefix(100).map(\.id)
        #expect(modifiedOnly.items.map(\.id) == expectedFirst,
                "过滤 + 倒序(时间,id DESC) + 前 100 的切片必须逐 id 相等")

        let stats = await store.batchStats()
        #expect(stats.commitCount >= 5_000 / 32, "攒批未生效：\(stats.commitCount) 次提交")
        #expect(stats.droppedStatementCount == 0)
    }

    /// 相对量：一次小页读取的常驻增量必须显著小于把全量取回来的增量。
    ///
    /// 同进程内做**相对比较**而不是设绝对 MB 阈值——Swift Testing 会并行跑别的测试，
    /// 绝对量抖动很大；「分页读不该等于全量读」这个结论只依赖两者之比。
    ///
    /// ⚠️ #90 的改判（**先记我试错试出来的事实，再记我做了什么**）：
    /// 台账把它写成"分配对照余量只有 4 % ⇒ 尺子噪声"。我先按"降噪"去治——两臂各热身一次、
    /// 再交替取三个样本求中位数——结果 `fullGrowth` 从 ~11 MB 掉到 **0.16 MB**，
    /// 分母守卫当场判红（`fullGrowth → 163840 > 1_000_000` 不成立，实测 5 轮全红）。
    /// ⇒ 这条用例量的**本来就是"第一次读"的冷缓存成本**：SwiftData 第二次取同一批行时
    /// 对象已在内存里，几乎不再分配。所以"重复取样求中位"不是降噪，是**把被测的那件事抹掉**。
    /// 真正的余量问题出在**信噪比的构造**：分页臂那 2.6 MB 里大头是"读一次的固定成本"（与行数无关），
    /// 全量臂是"固定成本 + 每行成本"⇒ 行数太少时两者同量级，比值自然贴着 4 倍线。
    /// 于是把行数从 5 000 抬到 20 000（只动规模，不动阈值 `/4`、不动单取样的形状），
    /// 让每行成本真的压过固定成本。探针实测见提交信息。
    @Test("小页读取的内存增量远小于全量读取")
    func pagedReadCostsLessThanFullScan() async throws {
        let store = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        for index in 0..<20_000 { await store.append(scaleEvent(index)) }
        await store.flush()

        let beforePaged = physFootprintBytes()
        let paged = try await store.events(matching: EventQuery(limit: 50))
        let pagedGrowth = try footprintGrowth(beforePaged, physFootprintBytes())
        #expect(paged.items.count == 50)

        let beforeFull = physFootprintBytes()
        let full = try await store.events(matching: EventQuery(limit: 20_000))
        let fullGrowth = try footprintGrowth(beforeFull, physFootprintBytes())
        #expect(full.items.count == 20_000)

        // 读数落盘：下面两个阈值都是**看这里的数**定的，没有这行下次就没法复算该不该调。
        // 本机实测（换到 phys_footprint 口径后，四轮）：分页读 0.0–0.3 MB｜全量读 46.7–50.0 MB。
        // ⇒ 两臂之比 ~150–500 倍：phys_footprint 不把可换出的干净页算进来，"整表进了内存"这件事
        //   在它身上比在 RSS 上诚实（口径与 Tools/UIProbe/probe-footprint.swift、验收脚本对齐）。
        //   阈值**不动**（这条判据要的是"量级 + 明显便宜"）——换口径不是顺手收紧判据，
        //   收紧要另立一格、按实测带重定。
        print("phys_footprint 增量：分页读 \(megabytes(pagedGrowth))｜全量读 \(megabytes(fullGrowth))")

        // 全量读必须真的涨了很多（否则这条对照没有意义），且分页读涨幅远小于它。
        #expect(fullGrowth > 1_000_000, "全量读未见内存增长（\(megabytes(fullGrowth))），对照不成立")
        #expect(max(pagedGrowth, 0) < fullGrowth / 4,
                "分页读增量 \(megabytes(pagedGrowth)) 相对全量 \(megabytes(fullGrowth)) 过大 → 疑似取了全表")
    }
}

@Suite("SwiftData 磁盘格式与 SQLite 后端同口径", .timeLimit(.minutes(1)))
struct SwiftDataStorageFormatTests {

    /// 只读打开 `.store` 跑一条两列查询（第一列 name / 第二列 value）。
    ///
    /// 表名与列名一律取自 `sqlite_master` / `pragma_table_info` 自身，不含外部输入，
    /// 所以拼接安全；不读任何用户数据值，只读类型。
    private func queryPairs(_ sql: String, path: String) throws -> [(first: String, second: String)] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(handle)
            throw ObservatoryError.storeUnavailable("无法只读打开 \(path)")
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw ObservatoryError.storeUnavailable("查询失败：\(sql)")
        }
        defer { sqlite3_finalize(statement) }
        var pairs: [(String, String)] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let left = sqlite3_column_text(statement, 0),
                  let right = sqlite3_column_text(statement, 1) else { continue }
            pairs.append((String(cString: left), String(cString: right)))
        }
        return pairs
    }

    private func tableNames(path: String) throws -> [String] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close_v2(handle)
            throw ObservatoryError.storeUnavailable("无法只读打开 \(path)")
        }
        defer { sqlite3_close_v2(handle) }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, "SELECT name FROM sqlite_master WHERE type='table'", -1,
                                 &statement, nil) == SQLITE_OK else {
            sqlite3_finalize(statement)
            throw ObservatoryError.storeUnavailable("无法读取 sqlite_master")
        }
        defer { sqlite3_finalize(statement) }
        var names: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let pointer = sqlite3_column_text(statement, 0) else { continue }
            names.append(String(cString: pointer))
        }
        return names
    }

    /// 取「表名含 tableFragment、列名含 columnFragment」那一列**实际存进去的值类型**。
    ///
    /// 用 `typeof()` 而不是声明类型：SwiftData 有 Core Data 血统（`Z` 前缀 + 全大写列名，
    /// 还可能带代际后缀），按片段定位才对版本升级耐操；而 `typeof()` 反映真实存储 class，
    /// 正是「日期 REAL / 枚举 TEXT / 计数 INTEGER」这条口径的直接证据。
    private func storedValueType(
        tableFragment: String,
        columnFragment: String,
        path: String
    ) throws -> String? {
        for table in try tableNames(path: path) where table.uppercased().contains(tableFragment) {
            let columns = try queryPairs("SELECT name, type FROM pragma_table_info('\(table)')", path: path)
            guard let column = columns.first(where: { $0.first.uppercased().contains(columnFragment) }) else {
                continue
            }
            let rows = try queryPairs(
                "SELECT typeof(\"\(column.first)\"), typeof(\"\(column.first)\") FROM \"\(table)\" LIMIT 1",
                path: path
            )
            if let row = rows.first { return row.second }
        }
        return nil
    }

    /// 某列的原始文本形式（`CAST(... AS TEXT)`），用来核对日期值有没有被截断成整秒。
    private func rawValue(tableFragment: String, columnFragment: String, path: String) throws -> String? {
        for table in try tableNames(path: path) where table.uppercased().contains(tableFragment) {
            let columns = try queryPairs("SELECT name, type FROM pragma_table_info('\(table)')", path: path)
            guard let column = columns.first(where: { $0.first.uppercased().contains(columnFragment) }) else {
                continue
            }
            let rows = try queryPairs(
                "SELECT CAST(\"\(column.first)\" AS TEXT), CAST(\"\(column.first)\" AS TEXT)"
                    + " FROM \"\(table)\" LIMIT 1",
                path: path
            )
            if let row = rows.first { return row.second }
        }
        return nil
    }

    @Test("日期落盘为 REAL(REF 秒)、枚举 TEXT、字节计数 INTEGER")
    func storedValueTypesMatchSQLiteBackend() async throws {
        // 落盘位置一律由 Scratch 给出（ci.yml 的 G2 门禁禁止测试写死个人检出目录）。
        // 目录自带唯一后缀，删目录即连带 -wal / -shm。
        let directory = try Scratch.directory("swiftdata-format")
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("observatory.store").path

        let store = try await SwiftDataObservatoryStore.open(
            configuration: SwiftDataStoreConfiguration(directory: directory.path)
        )
        #expect(!(await store.isInMemory), "指定了目录就不该退化成内存库")
        // 刻意用**带小数**的时间戳：整数值会被 SQLite 的 NUMERIC 亲和性归一化成 INTEGER
        // 存储类（实测 ZTIMESTAMP = 800000001 → typeof 'integer'），那样就证不了 REAL 编码。
        let fractional = Date(timeIntervalSinceReferenceDate: 800_000_000.123456)
        try await store.upsertSessions([
            AgentSession(kind: .claudeCode, title: "格式探针", startedAt: fractional,
                         peakMemoryBytes: UInt64(Int64.max) + 1, outcome: .success),
        ])
        await store.append(scaleEvent(1))
        await store.flush()
        await store.stop()

        // 亚秒必须**无损**落盘：这是「两个后端查出的结果可比」的真正前提
        // （SQLite 后端存的就是 REAL timeIntervalSinceReferenceDate）。
        let storedDate = try rawValue(tableFragment: "SESSION", columnFragment: "STARTEDAT", path: path)
        #expect(storedDate == "800000000.123456", "日期必须按 REF 秒无损存储，实得 \(storedDate ?? "nil")")
        let dateClass = try storedValueType(tableFragment: "SESSION", columnFragment: "STARTEDAT",
                                            path: path)
        #expect(dateClass == "real", "日期列的存储类必须是 real，实得 \(dateClass ?? "nil")")

        let kindClass = try storedValueType(tableFragment: "EVENT", columnFragment: "KIND", path: path)
        #expect(kindClass == "text", "枚举必须存 TEXT rawValue，实得 \(kindClass ?? "nil")")

        let memoryClass = try storedValueType(tableFragment: "SESSION", columnFragment: "MEMORY",
                                              path: path)
        #expect(memoryClass == "integer", "UInt64 按 Int64(bitPattern:) 存进 INTEGER 列")
    }
}
