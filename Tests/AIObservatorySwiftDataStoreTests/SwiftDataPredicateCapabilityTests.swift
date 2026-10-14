//
//  SwiftDataPredicateCapabilityTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: WS-SwiftData
//
//  **架构决定测试**：SwiftData 后端能不能把查询完全下推到 SQL，取决于
//  `#Predicate` 宏的哪些写法可被翻译。这不是偏好问题——写错了要到运行时才抛
//  「cannot be precisely evaluated」，所以每个查询用到的构造都在这里钉死。
//
//  下推失败 = 退化成「先取全表再在 Swift 里筛」，直接违反「大数据不拼全量」这条验收。
//
//  被断言的构造：
//    1. `Date` 两端闭区间比较（`>=` / `<=`）→ `DateRangeFilter.contains`
//    2. 捕获 `[String]` 的 `isEmpty || array.contains($0.col)` → 空 Set = 不过滤 + `IN (…)`
//    3. `String` 相等（哨兵空串表示不过滤）→ `projectPath` / `sessionID` 精确匹配
//    4. `String.contains(needle)` 子串 → `search_text`
//    5. 捕获 `Int` 的 `>=` → `risk_rank >= minimumRisk.rank`
//    6. 可选 `String?` 与 `String` 比较 → `session_id = ?`
//    7. `Bool` 相等 → `is_destructive = 1` / `is_acknowledged = 0`
//    8. `fetchCount` + `fetchLimit`/`fetchOffset` + 双 `SortDescriptor`（时间 + id）
//

import Testing
import Foundation
import SwiftData
@testable import AIObservatorySwiftDataStore
import AIObservatoryCore
import AIObservatoryTestSupport

private let spikeDay = Date(timeIntervalSinceReferenceDate: 800_000_000)

private func spikeEvent(
    _ title: String,
    kind: OperationKind,
    agentKind: AgentKind,
    risk: RiskLevel,
    offset: TimeInterval,
    sessionID: UUID?
) -> TimelineEvent {
    TimelineEvent(
        timestamp: spikeDay.addingTimeInterval(offset),
        sessionID: sessionID,
        agentKind: agentKind,
        kind: kind,
        title: title,
        summary: "summary of \(title)",
        riskLevel: risk
    )
}

/// 三条覆盖不同 kind / agentKind / risk / 时间的事件。
private func makeContext() throws -> ModelContext {
    let container = try ModelContainer(
        for: ObservatorySchema.schema,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let context = ModelContext(container)
    let session = UUID()
    context.insert(SDEvent(spikeEvent("alpha", kind: .fileCreated, agentKind: .claudeCode,
                                       risk: .low, offset: 10, sessionID: session)))
    context.insert(SDEvent(spikeEvent("beta", kind: .commandExecuted, agentKind: .openAICodex,
                                      risk: .high, offset: 20, sessionID: session)))
    context.insert(SDEvent(spikeEvent("gamma", kind: .fileDeleted, agentKind: .claudeCode,
                                      risk: .critical, offset: 30, sessionID: nil)))
    try context.save()
    return context
}

/// 本 SDK 的 `ModelContext` 没有 `fetchOne`，只能 `fetchLimit = 1` + `first`。
private func fetchOne<Model: PersistentModel>(
    _ context: ModelContext,
    _ descriptor: FetchDescriptor<Model>
) throws -> Model? {
    var limited = descriptor
    limited.fetchLimit = 1
    return try context.fetch(limited).first
}

@Suite("SwiftData 谓词下推能力", .timeLimit(.minutes(1)))
struct SwiftDataPredicateCapabilityTests {

    @Test("1. Date 两端闭区间可下推")
    func dateRange() throws {
        let context = try makeContext()
        let lower = spikeDay.addingTimeInterval(20)
        let upper = spikeDay.addingTimeInterval(30)
        let rows = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { $0.timestamp >= lower && $0.timestamp <= upper }
        ))
        #expect(rows.count == 2)
    }

    @Test("2. 空集合 = 不过滤，非空 = IN")
    func setMembership() throws {
        let context = try makeContext()
        let empty: [String] = []
        let all = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { empty.isEmpty || empty.contains($0.kind) }
        ))
        #expect(all.count == 3)

        let kinds = [OperationKind.fileCreated.rawValue, OperationKind.fileDeleted.rawValue]
        let some = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { kinds.isEmpty || kinds.contains($0.kind) }
        ))
        #expect(some.map(\.title).sorted() == ["alpha", "gamma"])
    }

    @Test("3. 字符串相等 + 空串哨兵")
    func stringEquality() throws {
        let context = try makeContext()
        let any = ""
        let codex = AgentKind.openAICodex.rawValue
        #expect(try context.fetchCount(FetchDescriptor<SDEvent>(
            predicate: #Predicate { any.isEmpty || any == $0.agentKind }
        )) == 3)
        #expect(try context.fetchCount(FetchDescriptor<SDEvent>(
            predicate: #Predicate { codex.isEmpty || codex == $0.agentKind }
        )) == 1)
    }

    @Test("4. 子串搜索可下推")
    func substringSearch() throws {
        let context = try makeContext()
        let needle = "alpha"
        let rows = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { needle.isEmpty || $0.searchText.contains(needle) }
        ))
        #expect(rows.count == 1)
    }

    @Test("5. 风险等级按 rank 过滤")
    func riskRank() throws {
        let context = try makeContext()
        let minimum = RiskLevel.high.rank
        let rows = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { $0.riskRank >= minimum }
        ))
        #expect(rows.count == 2)
    }

    @Test("6. 可空字符串与常量比较")
    func optionalStringEquality() throws {
        let context = try makeContext()
        let rows = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { $0.sessionID == nil }
        ))
        #expect(rows.count == 1)
    }

    @Test("7. 组合全部构造：一条谓词同时用 2/3/4/5/6")
    func combinedPredicate() throws {
        let context = try makeContext()
        let kinds: [String] = []
        let agentKinds = [AgentKind.claudeCode.rawValue]
        let needle = ""
        let minimum = RiskLevel.low.rank
        let rows = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { event in
                (kinds.isEmpty || kinds.contains(event.kind))
                    && (agentKinds.isEmpty || agentKinds.contains(event.agentKind))
                    && (needle.isEmpty || needle == event.summary)
                    && event.riskRank >= minimum
                    && event.sessionID != nil
            },
            sortBy: [
                SortDescriptor(\.timestamp, order: .reverse),
                SortDescriptor(\.id, order: .reverse),
            ]
        ))
        #expect(rows.map(\.title) == ["alpha"])
    }

    @Test("8. fetchLimit / fetchOffset 与 fetchCount 一致")
    func pagination() throws {
        let context = try makeContext()
        var descriptor = FetchDescriptor<SDEvent>(
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        descriptor.fetchLimit = 2
        descriptor.fetchOffset = 1
        let page = try context.fetch(descriptor)
        #expect(page.map(\.title) == ["beta", "alpha"])
        #expect(try context.fetchCount(FetchDescriptor<SDEvent>()) == 3)
    }

    /// upsert 的落法：同一 unique id「先删后插」能否放在**一次** save 里。
    ///
    /// 放得下 → 一次写路径就是一个事务，与 SQLite 的 `ON CONFLICT DO UPDATE` 同等原子性；
    /// 放不下 → 只能中间 save 一次（崩溃窗口里该行会短暂消失），或改成整属性就地赋值。
    @Test("9. 同一 save 内 delete+insert 同一 unique id 可行")
    func deleteThenInsertSameUniqueID() throws {
        let context = try makeContext()
        let fetched = try fetchOne(context, FetchDescriptor<SDEvent>(
            predicate: #Predicate { $0.title == "beta" }
        ))
        let original = try #require(fetched)
        #expect(original.riskRank == RiskLevel.high.rank)
        let eventID = try #require(UUID(uuidString: original.rowID))
        let sessionID = original.sessionID.flatMap { UUID(uuidString: $0) }

        let replacement = TimelineEvent(
            id: eventID,
            timestamp: original.timestamp,
            sessionID: sessionID,
            agentKind: .openAICodex,
            kind: .commandExecuted,
            title: "beta",
            summary: "rewritten",
            riskLevel: .critical
        )
        context.delete(original)
        context.insert(SDEvent(replacement))
        try context.save()   // 关键：唯一约束在含挂起删除的 save 时不应报错

        let storedRecord = try fetchOne(context, FetchDescriptor<SDEvent>(
            predicate: #Predicate { $0.title == "beta" }
        ))
        let stored = try #require(storedRecord)
        #expect(stored.summary == "rewritten")
        #expect(stored.riskRank == RiskLevel.critical.rank)
        #expect(try context.fetchCount(FetchDescriptor<SDEvent>()) == 3)
    }

    @Test("10. `starts(with:)` 可表达 pathPrefix")
    func pathPrefixForms() throws {
        let container = try ModelContainer(
            for: ObservatorySchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        // 一条在合成工作区内、一条在别的用户目录下：判据是「前缀只圈住前者」。
        for path in ["\(FixturePaths.projectAlpha)/a.swift", "/Users/other/b.swift"] {
            context.insert(SDFileChange(FileChange(path: path, kind: .modified, agentKind: .claudeCode)))
        }
        try context.save()

        let prefix = FixturePaths.work
        let begins = try context.fetch(FetchDescriptor<SDFileChange>(
            predicate: #Predicate { $0.path.starts(with: prefix) }
        ))
        #expect(begins.count == 1)

        let none = ""
        let all = try context.fetchCount(FetchDescriptor<SDFileChange>(
            predicate: #Predicate { none.isEmpty || $0.path.starts(with: none) }
        ))
        #expect(all == 2)
    }

    /// SQLite 侧用 `instr(search_text, ?) > 0`，即**字面**子串；SwiftData 的 `contains`
    /// 若被翻译成 `LIKE '%…%'`，needle 里的 `%` / `_` 会变成通配符 → 两个后端搜出不同行。
    ///
    /// 判据要能区分两者：LIKE 版会把「删除 50X 文件」也当成「删除 5%」的命中
    /// （`%` 吃掉 `0X 文件`）、把「axb」当成「a_b」的命中（`_` 吃掉一个字符）。
    /// 字面版只命中真正含该子串的行。
    @Test("11. 搜索词含 LIKE 通配符时按字面匹配，与 SQLite instr 同结果")
    func searchNeedleWithWildcards() throws {
        let context = try makeContext()
        let percentHit = TimelineEvent(kind: .fileDeleted, title: "删除 5% 文件", riskLevel: .low)
        let percentDecoy = TimelineEvent(kind: .fileDeleted, title: "删除 50X 文件", riskLevel: .low)
        let underscoreHit = TimelineEvent(kind: .fileDeleted, title: "a_b", riskLevel: .low)
        let underscoreDecoy = TimelineEvent(kind: .fileDeleted, title: "axb", riskLevel: .low)
        for event in [percentHit, percentDecoy, underscoreHit, underscoreDecoy] {
            context.insert(SDEvent(event))
        }
        try context.save()

        let percent = "删除 5%"
        let percentRows = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { $0.searchText.contains(percent) }
        ))
        #expect(percentRows.count == 1)
        #expect(percentRows.first?.title == "删除 5% 文件")

        let underscore = "a_b"
        let underscoreRows = try context.fetch(FetchDescriptor<SDEvent>(
            predicate: #Predicate { $0.searchText.contains(underscore) }
        ))
        #expect(underscoreRows.count == 1)
        #expect(underscoreRows.first?.title == "a_b")
    }
    /// **两条实测结论，都是写查询层时必须知道的地雷：**
    ///
    /// 1. `PersistentModel` 自带 `id: PersistentIdentifier`，而 `PersistentIdentifier`
    ///    是 `Comparable`。所以 `SortDescriptor(\.id)` 与「存 uuidString 的那个 String 列」
    ///    **不是同一列**（实测两者给出的顺序不同）——schema 里那列因此名为 `rowID`，
    ///    让 `\.id` 不再有被静默选中的可能。
    /// 2. 即使按 `\.rowID` 排，SwiftData 对字符串列的顺序**也不是** SQLite 的
    ///    `COLLATE BINARY` 字节序（实测 uuidString 三条的顺序是 8C8E → 0704 → CB5F，
    ///    字节序应为 0704 → 8C8E → CB5F）。因此 SQLite 的 `ORDER BY …, id DESC`
    ///    tie-break 无法在 SwiftData 侧逐位复刻：**时间戳完全相同的行，两后端先后可能不同**。
    ///    这是已列进简报「已知限制」的跨后端差异，不去假装它成立。
    ///
    /// 这里断言的是真做得到、而且分页游标真正依赖的性质：**同一份数据重复取，顺序稳定**，
    /// 且行集合完整。
    @Test("12. 排序列必须是 rowID，且并列顺序确定但不等于 SQLite 字节序")
    func rowIDColumnOrderingIsDeterministicNotBinary() throws {
        let container = try ModelContainer(
            for: ObservatorySchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let byteOrder = [
            "0704226B-D890-4CAE-826C-2AFF82E24A91",
            "8C8E0D6D-2A4A-415C-B15D-13AD026CC322",
            "CB5FA306-A6CD-4CED-890A-256807D0BDAA",
        ]
        // 插入顺序按字节的逆序给，确保 rowid 序、字节序、框架 id 序三者可区分。
        for text in byteOrder.reversed() {
            let id = try #require(UUID(uuidString: text))
            context.insert(SDEvent(TimelineEvent(id: id, timestamp: spikeDay,
                                                 kind: .fileRead, title: "同刻")))
        }
        try context.save()

        let descriptor = FetchDescriptor<SDEvent>(sortBy: [SortDescriptor(\.rowID)])
        let first = try context.fetch(descriptor).map(\.rowID)
        #expect(Set(first) == Set(byteOrder), "行集合必须完整")
        for _ in 0..<20 {
            let again = try context.fetch(descriptor).map(\.rowID)
            #expect(again == first, "同一排序重复取出行序不同 → 分页游标不可靠")
        }
        // 框架 id 是另一列：用它排序会得到不同顺序（这就是 schema 用 rowID 的理由）。
        let byFrameworkID = try context.fetch(
            FetchDescriptor<SDEvent>(sortBy: [SortDescriptor(\.id)])
        ).map(\.rowID)
        #expect(Set(byFrameworkID) == Set(byteOrder), "按框架 id 排也不该丢行")

        // 记录（不是断言）实测事实：SwiftData 的字符串序 ≠ BINARY 字节序。
        // 若哪天 SwiftData 改成字节序，这条会反过来变红，届时应同步更新简报的已知限制。
        if first == byteOrder {
            Issue.record("SwiftData 的字符串排序看起来已改成 BINARY 字节序 —— 简报的已知限制可以撤掉了")
        }
    }
}
