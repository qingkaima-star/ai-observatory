//
//  RiskLanguageFreezeTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: WS-l10n（B2 · #41 落库文案「写入时冻结」）
//  ─────────────────────────────────────────────────────────
//  IFR-i18n-string-catalog 裁定 2 要求的那条用例，**两后端各跑一遍**。形状照
//  `RiskCountDifferentialTests`：`makePair()` 造两个真后端、同一段断言里逐行写两遍、
//  两侧互相比对 —— 不引新测试依赖（`Package.swift` 是 §3 冻结区）。
//
//  本文件判的是「**已入库的行不许被回改**」这一半：
//   ① 中文时写入的一行风险事件，切到英文之后逐字仍是中文；
//   ② 同一库里之后新写入的行是英文；
//   ③ 两后端逐字相同，含派生的 `search_text` 与时间线行 `events.summary`。
//
//  ⚠️ 它**不判**「规则是否真的按注入语言渲染」。那一半要等 RiskRules 的 167 条文案接进
//  `LocalizedString`（B2 第二段）之后，在 `AIObservatoryEngineTests` 里用**真规则**断言：
//  本测试目标没有 `AIObservatoryRiskRules` / `AIObservatoryEngine` 依赖，硬加要动
//  `Package.swift` = 冻结区。在这里塞一个"测试内自己渲染"的假规则，只能证明存储不改字符串
//  ——那是必要的，但**不是**裁定 2 的全部，所以把边界写在脸上而不是含糊带过。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryStore
import AIObservatorySwiftDataStore

// MARK: - 夹具

/// 一条风险事件在两种语言下的**写入时**文本。
///
/// 串是手推的（不是跑一遍抄回来的）：中文那两行就是现在真规则会写进库的形状，
/// 英文那两行是 B2 第二段接完之后真规则应当写的形状。
private enum Frozen {
    static let base = Date(timeIntervalSince1970: 1_800_000_000)
    /// 理论不可达的回退值（避免强解包 / `try!`）。
    static let zeroUUID = UUID(uuidString: "00000000-0000-0000-0000-000000000000")
        ?? UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    static let agent = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001") ?? zeroUUID
    static let session = UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000002") ?? zeroUUID

    static let chineseTitle = "内存峰值超限"
    static let chineseDetail = "内存峰值 6.0 GB 超过阈值 3.0 GB（来自会话汇总值）。"
    static let englishTitle = "Memory peak exceeded"
    static let englishDetail = "Peak memory 6.0 GB exceeded the 3.0 GB threshold (from session totals)."

    static func title(_ language: AppLanguage) -> String {
        language == .english ? englishTitle : chineseTitle
    }

    static func detail(_ language: AppLanguage) -> String {
        language == .english ? englishDetail : chineseDetail
    }

    /// `index` 决定 id 与时间戳 ⇒ 同一库里两种语言的行可以并存且各自可取回。
    static func event(_ language: AppLanguage, index: Int) -> RiskEvent {
        let id = UUID(uuidString: String(format: "BBBBBBBB-0000-0000-0000-%012X", index)) ?? zeroUUID
        return RiskEvent(
            id: id,
            timestamp: base.addingTimeInterval(Double(index) * 60),
            level: .high,
            category: .resourceAbuse,
            title: title(language),
            detail: detail(language),
            agentID: agent,
            agentKind: .claudeCode,
            sessionID: session,
            matchedRuleID: "risk.pattern.excessive-memory-peak"
        )
    }
}

// MARK: - 用例

@Suite("落库文案写入时冻结：切语言不许回改已入库的行（两后端）")
struct RiskLanguageFreezeTests {

    /// 两个真后端、内存库，不起文件、不读墙钟。
    private func makePair() async throws -> (ObservatoryStore, SwiftDataObservatoryStore) {
        let sqlite = try await ObservatoryStore.open(configuration: .inMemory)
        let swiftData = try await SwiftDataObservatoryStore.open(configuration: .inMemory)
        return (sqlite, swiftData)
    }

    private func risk(_ id: UUID, in sqlite: ObservatoryStore, _ swiftData: SwiftDataObservatoryStore)
        async throws -> (RiskEvent, RiskEvent) {
        let query = RiskQuery(limit: 50, offset: 0)
        let left = try await sqlite.riskEvents(matching: query).items.first { $0.id == id }
        let right = try await swiftData.riskEvents(matching: query).items.first { $0.id == id }
        return (try #require(left, "SQLite 侧读不到该行：\(id)"),
                try #require(right, "SwiftData 侧读不到该行：\(id)"))
    }

    @Test("中文写入 → 切英文后旧行逐字仍是中文、新行是英文")
    func chineseRowSurvivesSwitchToEnglish() async throws {
        let (sqlite, swiftData) = try await makePair()
        let oldRow = Frozen.event(.chineseSimplified, index: 1)
        let newRow = Frozen.event(.english, index: 2)

        // ① 中文时写入
        try await sqlite.recordRisks([oldRow])
        try await swiftData.recordRisks([oldRow])
        // ② 「切语言」= 之后新写入的行按英文生成，旧行谁也不许动
        try await sqlite.recordRisks([newRow])
        try await swiftData.recordRisks([newRow])

        let (oldLeft, oldRight) = try await risk(oldRow.id, in: sqlite, swiftData)
        #expect(oldLeft.title == Frozen.chineseTitle, "SQLite 侧旧行标题被改写：\(oldLeft.title)")
        #expect(oldLeft.detail == Frozen.chineseDetail, "SQLite 侧旧行理由被改写：\(oldLeft.detail)")
        #expect(oldRight == oldLeft, "同一行两后端不一致：SQLite \(oldLeft.detail) / SwiftData \(oldRight.detail)")

        let (newLeft, newRight) = try await risk(newRow.id, in: sqlite, swiftData)
        #expect(newLeft.title == Frozen.englishTitle, "新行没按写入时语言生成：\(newLeft.title)")
        #expect(newLeft.detail == Frozen.englishDetail, "新行理由不是英文：\(newLeft.detail)")
        #expect(newRight == newLeft, "新行两后端不一致")

        // 旧行没因为新行的写入而被顺手动过（时间戳/等级/id 都逐字比）
        #expect(oldLeft.id != newLeft.id)
        #expect(oldLeft.timestamp == Frozen.base.addingTimeInterval(60))
        #expect(oldLeft.level == .high && oldLeft.category == .resourceAbuse)
    }

    /// `search_text` 是写入时由 title+detail 拼出来的派生列（两后端同口径）。
    /// 它若改成读时现算，切语言就会让历史行搜不到——这条钉住"派生列同样冻结"。
    @Test("派生的 search_text 也冻结在写入时：中文行切英文后仍被中文关键词命中")
    func derivedSearchTextStaysFrozen() async throws {
        let (sqlite, swiftData) = try await makePair()
        let zh = Frozen.event(.chineseSimplified, index: 1)
        let en = Frozen.event(.english, index: 2)
        try await sqlite.recordRisks([zh, en])
        try await swiftData.recordRisks([zh, en])

        let zhQuery = RiskQuery(searchText: "内存峰值", limit: 50, offset: 0)
        let enQuery = RiskQuery(searchText: "memory peak", limit: 50, offset: 0)

        let zhLeft = try await sqlite.riskEvents(matching: zhQuery).items
        let zhRight = try await swiftData.riskEvents(matching: zhQuery).items
        #expect(zhLeft.map(\.id) == zhRight.map(\.id),
                "中文关键词两后端命中集不同：SQLite \(zhLeft.count) / SwiftData \(zhRight.count)")
        #expect(zhLeft.map(\.id) == [zh.id], "中文关键词应只命中那条中文行，实得 \(zhLeft.map(\.id))")

        let enLeft = try await sqlite.riskEvents(matching: enQuery).items
        #expect(enLeft.map(\.id) == [en.id], "英文关键词应只命中新写入的英文行，实得 \(enLeft.map(\.id))")
    }

    /// 时间线行是同一批风险的**第二份**入库文案（`events.summary` 由 `risk.detail` 派生）。
    /// 只冻结 `risk_events` 而让时间线行读时现翻译，等于没冻结。
    @Test("时间线行里那份派生文案同样逐字冻结在两后端")
    func timelineDerivedTextIsFrozenToo() async throws {
        let (sqlite, swiftData) = try await makePair()
        let zh = Frozen.event(.chineseSimplified, index: 1)
        let en = Frozen.event(.english, index: 2)
        // 与引擎收口一致的口径：时间线行的 summary 直接取 risk.detail
        // （`TimelineAggregator.riskSummary(for:)`）。本测试目标不依赖 Engine，
        // 所以这里显式复现该口径而不是 import 进来。
        let timeline = [
            TimelineEvent(timestamp: zh.timestamp, sessionID: Frozen.session, agentKind: .claudeCode,
                          kind: .riskDetected, title: Frozen.chineseTitle, summary: zh.detail),
            TimelineEvent(timestamp: en.timestamp, sessionID: Frozen.session, agentKind: .claudeCode,
                          kind: .riskDetected, title: Frozen.englishTitle, summary: en.detail),
        ]
        try await sqlite.recordRisks([zh, en])
        try await swiftData.recordRisks([zh, en])
        try await sqlite.upsertEvents(timeline)
        try await swiftData.upsertEvents(timeline)

        let query = EventQuery(limit: 50, offset: 0)
        let left = try await sqlite.events(matching: query).items
        let right = try await swiftData.events(matching: query).items
        #expect(left.map(\.summary) == right.map(\.summary), "时间线 summary 两后端不一致")
        #expect(Set(left.map(\.summary)) == Set([Frozen.chineseDetail, Frozen.englishDetail]),
                "两条时间线行没有各自留在写入时语言：\(left.map(\.summary))")
        for event in left where event.summary == Frozen.chineseDetail {
            #expect(event.title == Frozen.chineseTitle, "中文那行的标题被换掉了：\(event.title)")
        }
    }
}
