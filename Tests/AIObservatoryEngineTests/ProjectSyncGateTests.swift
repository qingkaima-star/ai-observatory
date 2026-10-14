//
//  ProjectSyncGateTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine（性能收尾线 ws/perfclose）
//  ─────────────────────────────────────────────────────────
//  `syncProjectsIfNeeded` 每 tick 都要问一次「本轮要不要重算项目地图」。
//  旧实现的问法是 `SELECT COUNT(*) FROM file_changes` 跟上次的行数比——
//  COUNT(*) 没有谓词可用索引定位，SQLite 只能整棵索引扫一遍 ⇒ **每 tick 的代价随
//  历史长度线性增长**（release 实测 20 000 行时 0.69 ms/tick；30 天保留期攒到百万行
//  就是几十 ms/tick，而 §6 的整轮预算只有 90 ms）。
//  现在换成「最大 rowid 有没有前进」，代价与行数无关。
//
//  这些用例用手推字面量把闸门的四条口径钉住，其中两条是**换判据时容易踩的坑**：
//   · 用 timestamp 当游标会静默漏行（批量写通道会把"事件时间更早"的行晚提交）；
//   · 保留期清理把最大行删掉后，游标不退回就会永久失去即时触发。
//  节流计时那条也一样：不该同步的轮次不得把计时器清零。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore

private let t0 = Date(timeIntervalSince1970: 1_800_004_000)

@Suite("Engine：项目地图的触发闸门（每 tick 不得付 O(历史长度) 的代价）")
struct ProjectSyncGateTests {

    /// 先绑定再断言：`#expect(gate.shouldSync(...))` 编译不过——宏把表达式包进闭包，
    /// `$0` 是不可变的，mutating 调用被拒（swift-testing 的已知形状）。
    private func sync(
        _ gate: inout ObservatoryEngine.ProjectSyncGate, row: Int, at offset: TimeInterval,
        throttle: TimeInterval = 60
    ) -> Bool {
        gate.shouldSync(newestFileChangeRowID: row, now: t0.addingTimeInterval(offset), throttle: throttle)
    }

    @Test("首轮没有历史：直接同步，并把游标推到当前最大 rowid")
    func firstRoundAlwaysSyncs() {
        var gate = ObservatoryEngine.ProjectSyncGate()
        #expect(sync(&gate, row: 7, at: 0))
        #expect(gate.lastFileChangeRowID == 7)
        #expect(gate.lastSyncAt == t0)
    }

    @Test("无新行且未到期：不同步，且不得把节流计时清零")
    func quietRoundDoesNotResetTheThrottle() {
        var gate = ObservatoryEngine.ProjectSyncGate()
        #expect(sync(&gate, row: 7, at: 0))
        #expect(!sync(&gate, row: 7, at: 30))
        // 60 s 从**上一次真同步**（t0）算起，不是从这次"什么也没干"的问询算起。
        let later = sync(&gate, row: 7, at: 61)
        #expect(later, "超时兜底被 quiet 轮次续掉了 ⇒ 项目地图的滞后会无限累加")
        #expect(gate.lastSyncAt == t0.addingTimeInterval(61))
    }

    @Test("有新行：不到节流窗口也立即同步（需求⑦ 的「新活动立即反映」）")
    func newRowsTriggerImmediately() {
        var gate = ObservatoryEngine.ProjectSyncGate()
        #expect(sync(&gate, row: 3, at: 0))
        #expect(sync(&gate, row: 5, at: 1))
        #expect(gate.lastFileChangeRowID == 5)
    }

    @Test("空表（最大 rowid 0）：首轮仍同步一次，之后不再被 0 触发")
    func emptyTableIsZero() {
        var gate = ObservatoryEngine.ProjectSyncGate()
        #expect(sync(&gate, row: 0, at: 0), "首轮没有任何行也要同步（项目地图要为空）")
        #expect(gate.lastFileChangeRowID == 0)
        #expect(!sync(&gate, row: 0, at: 10))
    }

    @Test("保留期删掉最大行后：游标退回，复用 rowid 的新行仍能触发")
    func cursorRetreatsAfterPrune() {
        var gate = ObservatoryEngine.ProjectSyncGate()
        #expect(sync(&gate, row: 7, at: 0))
        // prune 把第 5..7 行删了 ⇒ 最大 rowid 退到 4。本轮没有新活动 ⇒ 不同步，但游标要退。
        #expect(!sync(&gate, row: 4, at: 1))
        #expect(gate.lastFileChangeRowID == 4, "游标不退回，下一句就永远触发不了")
        // SQLite 从 max(rowid)+1 继续分配 ⇒ 新行拿到的正是被删掉的 5。
        let reused = sync(&gate, row: 5, at: 2)
        #expect(reused, "清理之后即时触发静默失效，只剩 60 s 节流在兜 ⇒ 用户看到的项目地图平白慢一分钟")
    }

    @Test("游标只前进不回弹：同一批行在窗口内反复问不会反复同步")
    func cursorOnlyMovesForward() {
        var gate = ObservatoryEngine.ProjectSyncGate()
        #expect(sync(&gate, row: 10, at: 0))
        for offset in stride(from: 1.0, through: 59.0, by: 7.0) {
            #expect(!sync(&gate, row: 10, at: offset))
        }
        #expect(gate.lastFileChangeRowID == 10)
    }
}

@Suite("Store：最大 rowid 读数", .timeLimit(.minutes(1)))
struct StoreMaxRowIDTests {

    @Test("空表 0、插入后严格前进")
    func growsWithInserts() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        #expect(try await store.maxRowID(table: StoreSchema.Table.fileChanges) == 0)
        await store.append(FileChange(path: "/p/a.swift", kind: .created))
        await store.flush()
        let afterOne = try await store.maxRowID(table: StoreSchema.Table.fileChanges)
        #expect(afterOne >= 1)
        await store.append(FileChange(path: "/p/b.swift", kind: .created))
        await store.flush()
        #expect(try await store.maxRowID(table: StoreSchema.Table.fileChanges) > afterOne)
        await store.stop()
    }

    @Test("迟提交的旧时间戳行：rowid 游标看得见，timestamp 游标看不见")
    func lateCommitWithOldTimestampStillMovesTheCursor() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let recent = Date(timeIntervalSince1970: 1_800_004_500)
        await store.append(FileChange(path: "/p/recent.swift", kind: .created, timestamp: recent))
        await store.flush()
        let rowBefore = try await store.maxRowID(table: StoreSchema.Table.fileChanges)
        let stampBefore = try #require(await maxTimestamp(in: store))

        // 一条事件时间更早、但**此刻才落库**的行。
        await store.append(FileChange(
            path: "/p/late.swift", kind: .created,
            timestamp: recent.addingTimeInterval(-86_400)
        ))
        await store.flush()

        #expect(try await store.maxRowID(table: StoreSchema.Table.fileChanges) > rowBefore,
                "rowid 游标必须看到这条迟提交的行")
        #expect(await maxTimestamp(in: store) == stampBefore,
                "同一批数据下 MAX(timestamp) 没前进 ⇒ 拿它当游标会把这行永久漏掉")
        await store.stop()
    }

    @Test("未知表名一律拒绝（不得拼出任意表名去查）")
    func rejectsUnknownTable() async throws {
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        await #expect(throws: (any Error).self) {
            _ = try await store.maxRowID(table: "sqlite_master")
        }
        await store.stop()
    }
}

/// 直接查 `MAX(timestamp)`。
///
/// 为什么要从测试里查而不是给 Store 加一个"只给测试用"的读数口：产品表面上一旦出现
/// 没有生产消费者的方法，它就变成下一轮的死代码（本仓主导缺陷类的另一个方向）。
private func maxTimestamp(in store: ObservatoryStore) async -> Double? {
    do {
        let database = await store.database
        let column = try await database.scalar("SELECT MAX(timestamp) FROM \(StoreSchema.Table.fileChanges)")
        guard case .real(let value) = column else { return nil }
        return value
    } catch {
        return nil
    }
}
