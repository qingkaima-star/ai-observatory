//
//  ProcessTreeIndexTests.swift
//  AIObservatoryPlatformTests — AgentDetection
//
//  Owner: WS-ProcScan
//
//  `ProcessTreeIndex` 的正确性。它替换的是「每条记录各建一次索引」的查询形状，
//  所以断言的口径是**与旧实现逐元素相等**（含顺序），而不是「非空 / 大于 0」——
//  后者在方向写反、顺序颠倒时照样绿。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

// MARK: - 旧实现（向上试探）作为参考口径

/// 改动前 `ProcessTreeBuilder.ancestors` 的原始形状：每次查询重建一份字典。
/// 只在测试里留一份，用来证明新索引没有改变语义。
///
/// 注意它**没有**跳数上限——旧实现只有 `guardSet`（`1024` 那个计数器在
/// `CommandInferenceEngine.nearestAgent` 里，不在这个函数里）。把两者混为一谈会让
/// 「祖先链无深度上限」这条从未被真正钉住。
private func legacyAncestorPIDs(of pid: Int32, records: [ProcessRecord]) -> [Int32] {
    let byPID = Dictionary(records.map { ($0.pid, $0) }, uniquingKeysWith: { a, _ in a })
    var result: [Int32] = []
    var guardSet = Set<Int32>()
    var current = byPID[pid]

    while let record = current,
          let ppid = record.parentPID,
          ppid != record.pid,
          !guardSet.contains(ppid) {
        guardSet.insert(record.pid)
        guard let parent = byPID[ppid] else { break }
        result.append(parent.pid)
        current = parent
    }
    return result
}

private func record(_ pid: Int32, _ ppid: Int32?, name: String = "p") -> ProcessRecord {
    ProcessRecord(pid: pid, parentPID: ppid, name: name, executablePath: "/bin/\(name)\(pid)")
}

// MARK: - 等价性

@Suite("进程树索引：与旧「向上试探」实现等价")
struct ProcessTreeIndexEquivalenceTests {

    @Test("多叉图：整条快照逐 pid 比对，祖先链完全一致")
    func matchesLegacyOnMixedGraph() {
        // 1 是 init 之下的森林根；20 的父不在快照里（链须自然终止）；
        // 40/41 互为父子构成环；42 自环；43 与 7 重复 pid（先出现的须胜出）。
        let records: [ProcessRecord] = [
            record(1, nil, name: "launchd"),
            record(2, 1, name: "a"),
            record(3, 2, name: "b"),
            record(4, 2, name: "c"),
            record(5, 3, name: "d"),
            record(6, 5, name: "e"),
            record(20, 999, name: "orphan"),
            record(40, 41, name: "loopA"),
            record(41, 40, name: "loopB"),
            record(42, 42, name: "selfParent"),
            record(7, 1, name: "first"),
            record(7, 3, name: "duplicateShouldLose"),
        ]
        let tree = ProcessTreeIndex(records: records)

        for pid in records.map(\.pid) {
            #expect(
                tree.ancestors(of: pid).map(\.pid) == legacyAncestorPIDs(of: pid, records: records),
                "pid \(pid) 的祖先链与旧实现不一致"
            )
        }
    }

    @Test("重复 pid：先出现的那条入表（旧 Dictionary 的 uniquingKeysWith 口径）")
    func firstOccurrenceWins() {
        // pid 7 出现两次，父分别是 1 和 3。若表按「后出现的赢」构建，祖先链会变成 [3]。
        let records = [
            record(1, nil, name: "launchd"),
            record(3, 1, name: "other"),
            record(7, 1, name: "first"),
            record(7, 3, name: "loser"),
        ]
        let tree = ProcessTreeIndex(records: records)
        #expect(tree.ancestors(of: 7).map(\.pid) == [1])
    }

    @Test("祖先顺序：最近父进程在前")
    func nearestParentFirst() {
        let records = [
            record(10, nil), record(20, 10), record(30, 20), record(40, 30),
        ]
        let tree = ProcessTreeIndex(records: records)
        #expect(tree.ancestors(of: 40).map(\.pid) == [30, 20, 10])
    }

    @Test("一次性 API 与索引结果一致（保留的封装没有第二套逻辑）")
    func oneShotWrappersAgree() {
        let records = [record(1, nil), record(2, 1), record(3, 2), record(4, 2)]
        #expect(
            ProcessTreeBuilder.ancestors(of: 4, records: records).map(\.pid)
                == ProcessTreeIndex(records: records).ancestors(of: 4).map(\.pid)
        )
        #expect(
            ProcessTreeBuilder.descendantPIDs(of: 1, records: records).sorted()
                == ProcessTreeIndex(records: records).descendantPIDs(of: 1).sorted()
        )
    }
}

// MARK: - 环与病态图

@Suite("进程树索引：环与缺失父节点")
struct ProcessTreeIndexCycleTests {

    @Test("两节点环：链只走到回到起点为止，不死循环、不重复计数")
    func twoNodeCycle() {
        let records = [record(40, 41), record(41, 40)]
        let tree = ProcessTreeIndex(records: records)
        #expect(tree.ancestors(of: 40).map(\.pid) == [41])
        #expect(tree.ancestors(of: 41).map(\.pid) == [40])
        // 子孙展开同理：环里的每个 pid 只出现一次。
        #expect(tree.descendantPIDs(of: 40).sorted() == [41])
    }

    @Test("三节点环 + 支线：支线进程各计一次，环内节点不重复")
    func cycleWithBranch() {
        let records = [
            record(1, 2), record(2, 3), record(3, 1),
            record(10, 1), record(11, 10), record(12, 2),
        ]
        let tree = ProcessTreeIndex(records: records)
        let fromRing = tree.descendantPIDs(of: 1).sorted()
        #expect(fromRing == [2, 3, 10, 11, 12])
        #expect(fromRing.count == Set(fromRing).count)
        #expect(tree.ancestors(of: 11).map(\.pid) == [10, 1, 2, 3])
    }

    @Test("自环（ppid == pid）：既不是自己的祖先也不是自己的子孙")
    func selfParent() {
        let records = [record(42, 42), record(43, 42)]
        let tree = ProcessTreeIndex(records: records)
        #expect(tree.ancestors(of: 42).isEmpty)
        #expect(tree.descendantPIDs(of: 42) == [43])
    }

    @Test("父进程不在快照里：链在此终止")
    func missingParentTerminates() {
        let records = [record(1, nil), record(20, 999)]
        let tree = ProcessTreeIndex(records: records)
        #expect(tree.ancestors(of: 20).isEmpty)
        #expect(!tree.contains(pid: 999))
    }

    @Test("深链 2000 层：走完全部祖先，任何一侧都不许有跳数上限")
    func deepChain() {
        var records: [ProcessRecord] = [record(1, nil)]
        records.reserveCapacity(2001)
        for pid in 2...2000 {
            records.append(record(Int32(pid), Int32(pid - 1)))
        }
        let tree = ProcessTreeIndex(records: records)
        #expect(tree.ancestors(of: 2000).count == 1999)
        #expect(tree.descendantPIDs(of: 1).count == 1999)
        // 与旧实现同时钉：若哪一侧偷偷加了 1024 跳上限，这里就会分叉。
        #expect(
            tree.ancestors(of: 2000).map(\.pid)
                == legacyAncestorPIDs(of: 2000, records: records)
        )
    }
}
