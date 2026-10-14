//
//  ProcessTreeBuilder.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Agent
//  ─────────────────────────────────────────────────────────
//  在扁平的 `ProcessRecord` 快照上查询父子关系（祖先链 / 子孙集合）。
//  处理两类现实问题：
//   · 环（A 的父是 B，B 的父是 A）→ 回溯与展开都有 visited 守卫，不会无限递归。
//   · 父进程不在快照里（已退出，或本就没权限看到）→ 链条在此自然终止。
//
//  开销口径（2026-09-20 真机实测，828 pid）：一份快照的索引构建 0.26 ms，
//  而「每次查询都重建索引」的形状是 176 ms/轮——因为它被放在「对每条记录跑一遍」
//  的循环里，复杂度是 O(N²) 且每次复制整份胖记录。所以**一轮采集只允许有一份索引**，
//  用 `ProcessTreeIndex`；下面两个一次性函数只服务单次查询与测试，不得进热路径。
//

import Foundation
import AIObservatoryCore

/// 一份进程快照的父子索引：整轮采集构建一次，祖先链与子孙集合都只查表。
public struct ProcessTreeIndex: Sendable {

    /// pid → 记录。同 pid 重复时保留**先出现**的那条（与快照顺序一致，可复现）。
    private let recordsByPID: [Int32: ProcessRecord]
    /// ppid → 直接子进程 pid（自环 `ppid == pid` 不入表，否则展开会自己咬自己）。
    private let childrenByPID: [Int32: [Int32]]

    public init(records: [ProcessRecord]) {
        var byPID: [Int32: ProcessRecord] = [:]
        byPID.reserveCapacity(records.count)
        var children: [Int32: [Int32]] = [:]
        for record in records {
            if byPID[record.pid] == nil {
                byPID[record.pid] = record
            }
            if let ppid = record.parentPID, ppid != record.pid {
                children[ppid, default: []].append(record.pid)
            }
        }
        self.recordsByPID = byPID
        self.childrenByPID = children
    }

    /// 快照里是否存在该 pid。
    public func contains(pid: Int32) -> Bool { recordsByPID[pid] != nil }

    /// 该 pid 记录的父 pid；进程不在快照里（已退出 / 无权限看）时返回 nil。
    ///
    /// 不做任何环路或自环修正——调用方要的是「快照就这么写」这一事实本身。
    public func parentPID(of pid: Int32) -> Int32? { recordsByPID[pid]?.parentPID }

    /// 从 `pid` 向上回溯的祖先链（最近父进程在前，不含自身）。遇到环或缺失父节点安全终止。
    public func ancestors(of pid: Int32) -> [ProcessRecord] {
        var result: [ProcessRecord] = []
        // visited 记的是「已经站过的节点」：ppid 图可能成环（父进程重启后 pid 被复用），
        // 少了这个守卫就会在环里无限追加。
        var visited = Set<Int32>()
        var current = recordsByPID[pid]
        while let record = current,
              let ppid = record.parentPID,
              ppid != record.pid,
              !visited.contains(ppid) {
            visited.insert(record.pid)
            guard let parent = recordsByPID[ppid] else { break }
            result.append(parent)
            current = parent
        }
        return result
    }

    /// `pid` 的全部子孙 pid（不含自身），广度展开，环只算一次。
    public func descendantPIDs(of pid: Int32) -> [Int32] {
        var result: [Int32] = []
        var queue: [Int32] = [pid]
        var seen = Set<Int32>([pid])
        while let current = queue.popLast() {
            for child in childrenByPID[current, default: []] where !seen.contains(child) {
                seen.insert(child)
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }
}

/// 同 pid 首次出现才写入（保留快照顺序里的第一条）。
private func recordsByPIDIsNew(_ dict: inout [Int32: ProcessRecord], _ record: ProcessRecord) -> Bool {
    dict[record.pid] == nil
}

/// 在扁平进程快照上查询父子关系（一次性 API：内部即「建索引 + 查一次」）。
public enum ProcessTreeBuilder {

    /// 返回从 `pid` 向上回溯的祖先链（最近父进程在前）。
    ///
    /// 用于构造 `DetectionContext.ancestors`，让策略能依据父进程树判定。
    /// 遇到环或缺失父节点时安全终止。
    ///
    /// - Note: 需要对**整份快照的每个 pid** 查询时，改用 `ProcessTreeIndex`——
    ///   本函数每次调用都要重建索引，放在逐记录循环里就是 O(N²)。
    ///
    /// - Parameters:
    ///   - pid: 目标进程 pid。
    ///   - records: 完整进程快照。
    /// - Returns: 祖先 `ProcessRecord` 数组（不含自身）。
    public static func ancestors(of pid: Int32, records: [ProcessRecord]) -> [ProcessRecord] {
        ProcessTreeIndex(records: records).ancestors(of: pid)
    }

    /// 返回某 pid 的全部子孙 pid（含其直接子进程，递归展开）。
    ///
    /// 用于填充 `AgentInstance.childPIDs`，呈现一个 Agent 拉起的全部进程。
    ///
    /// - Parameters:
    ///   - pid: 目标进程 pid。
    ///   - records: 完整进程快照。
    /// - Returns: 子孙进程 pid 数组（不含自身）。
    public static func descendantPIDs(of pid: Int32, records: [ProcessRecord]) -> [Int32] {
        ProcessTreeIndex(records: records).descendantPIDs(of: pid)
    }
}
