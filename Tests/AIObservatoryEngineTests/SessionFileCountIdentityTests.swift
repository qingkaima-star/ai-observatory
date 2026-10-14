//
//  SessionFileCountIdentityTests.swift
//  Tests/AIObservatoryEngineTests
//
//  Owner: ws/trust（#78 第二件事）
//
//  跨表恒等式守卫：`sessions.created_file_count + modified_file_count + deleted_file_count
//  == 按 session_id 数出的 file_changes 行数`，且**每列分别**等于按 kind 数出的行数。
//
//  为什么单列比对比不出来：真库那份实测是「modified 列 19 / 行 18」同时
//  「三列之和 26 / 总行 25」——只有把**和**与**总数**放在一起对，
//  「有一格被多记了一次」这种漂移才会必然露馅（见台账
//  `04-决策记录/发现-会话计数列比真实行数多1（活库实测）.md`）。
//  单列比在"两处口径恰好一起错"时也会失明，所以每列还各自对一次独立 COUNT。
//
//  ⚠️ 期望值全部手推（算式写在用例头上），不从实现反推：
//  本项目反复栽在「把 round-trip 当证明」——`读回来 == 写进去的` 对"多记一次"完全失明。
//
//  夹具（`makeHarness` / `emit` / `rowCount` / `settleCredits` …）与
//  `SessionFileCountPersistenceTests.swift` 共用同一套（那里是本文件的姊妹篇：
//  那一边钉"什么时候才允许动计数"，这一边钉"动完的数与行数对得上"）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryStore
@testable import AIObservatoryEngine

// MARK: - 2. 跨表恒等式守卫

@Suite("Engine #78：sessions 三列 × file_changes 的跨表恒等式", .timeLimit(.minutes(3)))
struct SessionFileCountIdentityTests {

    /// 恒等式：`created + modified + deleted == 按 session_id 数出的（计入类）行数`，
    /// 且**每列分别**等于按 kind 数出的行数。
    ///
    /// 手推的期望值（7 条事件逐条列出，不做任何循环累加）：
    ///   created  : alpha, beta          → 2
    ///   modified : gamma, delta, eps    → 3
    ///   deleted  : zeta                 → 1
    ///   renamed  : eta                  → 三列一列都不进（见 `SessionLifecycleManager` 文件头规则 5）
    /// ⇒ 三列之和 2 + 3 + 1 = 6；该会话的总行 = 6 + 1(renamed) = 7。
    ///
    /// 为什么必须带上那条 renamed：恒等式的**成立条件**就是「三列只数这三类」。
    /// 少掉它，「把 renamed 也算进 modified」这种错法会把两侧一起抬高，
    /// 「列 == 行」的单侧对比根本看不出来；总行数与三列之和的差必须恰好等于 renamed 的行数。
    @Test("三列分别等于按 kind 数出的行数，且之和等于该会话计入类的总行数")
    func columnsMatchRowCountsPerKind() async throws {
        let harness = try await makeIngestHarness()
        // renamed **排在最前**：它不进待认领集合 ⇒ "等到 6 条待认领"这把尺看不见它。
        // 事件流是 FIFO，排在前面就等于它一定已被消费过，而且它会和后面那一批一起
        // 被同一次 flush 落定（测试不许去依赖一个自己没启动的定时器）。
        emit(harness, "eta", kind: .renamed, before: 61)
        emit(harness, "alpha", kind: .created, before: 60)
        emit(harness, "beta", kind: .created, before: 59)
        emit(harness, "gamma", kind: .modified, before: 58)
        emit(harness, "delta", kind: .modified, before: 57)
        emit(harness, "eps", kind: .modified, before: 56)
        emit(harness, "zeta", kind: .deleted, before: 55)
        try await waitUntilStaged(harness, changes: 6)
        try await settleCredits(harness)

        let stored = try await storedSession(harness)
        #expect(stored.createdFileCount == 2, "手推：created 两条")
        #expect(stored.modifiedFileCount == 3, "手推：modified 三条")
        #expect(stored.deletedFileCount == 1, "手推：deleted 一条")
        let createdRows = try await rowCount(harness, kinds: [.created])
        let modifiedRows = try await rowCount(harness, kinds: [.modified])
        let deletedRows = try await rowCount(harness, kinds: [.deleted])
        let countedRows = try await rowCount(harness, kinds: [.created, .modified, .deleted])
        let everyRow = try await rowCount(harness, kinds: FileChangeKind.allCases)

        // 逐列对：每列 = 按 kind 独立数出来的行数。
        #expect(createdRows == 2 && stored.createdFileCount == createdRows)
        #expect(modifiedRows == 3 && stored.modifiedFileCount == modifiedRows)
        #expect(deletedRows == 1 && stored.deletedFileCount == deletedRows)
        // 恒等式（三列之和 == 计入类总行 == 6）。
        #expect(stored.createdFileCount + stored.modifiedFileCount + stored.deletedFileCount == 6)
        #expect(countedRows == 6)
        // 该会话的全部行：多出来的那一条恰好是 renamed（它一列都不进）。
        #expect(everyRow == 7)
        let renamedRows = try await rowCount(harness, kinds: [.renamed])
        #expect(countedRows + renamedRows == everyRow)
        #expect(await harness.stagedCount == 0)
    }

    /// 真库那一格的形状直接复刻一遍：7 created + 18 modified + 0 deleted = 25 行。
    ///
    /// 实测记录是「列 19 / 行 18、三列之和 26 / 总行 25」。这一格钉修好之后的两侧：
    /// modified 必须是 **18**（不是 19），三列之和必须**等于**总行数 25（不是 26）。
    /// 期望值来自台账那份实测的手推：`19 − 1 = 18`、`18 + 7 + 0 = 25`，不是从代码里数出来的。
    @Test("复刻活库会话 #2 的形状：18 行 modified 就记 18，三列之和等于总行 25")
    func liveDatabaseShapeHolds() async throws {
        let harness = try await makeIngestHarness()
        for index in 0..<7 {
            emit(harness, "created-\(index)", kind: .created, before: 90 - Double(index))
        }
        for index in 0..<18 {
            emit(harness, "modified-\(index)", kind: .modified, before: 80 - Double(index))
        }
        // 25 条变更 = 50 条语句，中途会被"凑满一批就地提交"切掉一次 ⇒ 待认领数在这里不稳定，
        // 所以用"彻底收口"那把尺：库里恰好 25 行且没有待认领条目。
        try await settleIngested(harness, rows: 25)

        let stored = try await storedSession(harness)
        #expect(stored.createdFileCount == 7)
        #expect(stored.modifiedFileCount == 18, "真库里这一格是 19 而行只有 18：这里必须是 18")
        #expect(stored.deletedFileCount == 0, "真的是 0 条删除，不等于「没数到」")

        let countedRows = try await rowCount(harness, kinds: [.created, .modified, .deleted])
        let modifiedRows = try await rowCount(harness, kinds: [.modified])
        let createdRows = try await rowCount(harness, kinds: [.created])
        #expect(createdRows == 7 && modifiedRows == 18 && countedRows == 25)
        #expect(stored.createdFileCount + stored.modifiedFileCount + stored.deletedFileCount
                == countedRows, "恒等式：三列之和 == 该会话按 session_id 数出的总行数")
        let wholeTable = try await harness.store.rowCount(table: StoreSchema.Table.fileChanges)
        #expect(wholeTable == 25, "整张表也只有这 25 行：归属约定没被顺手破坏")
        #expect(await harness.stagedCount == 0)
    }
}