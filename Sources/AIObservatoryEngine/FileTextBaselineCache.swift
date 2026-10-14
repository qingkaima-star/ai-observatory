//
//  FileTextBaselineCache.swift
//  AIObservatoryEngine
//
//  Owner: WS-Diff
//  ─────────────────────────────────────────────────────────
//  Before/After 里「Before」的唯一来源：引擎自己留的、该路径上一次被观测到的内容。
//
//  为什么只能靠留底：FSEvents 是**变更后**通知。事件到手时旧字节已经被覆盖，
//  事后任何一次读盘拿到的都是「改后」，全量预扫描监控根又要花掉判据4 预算不起的 I/O。
//  拿 `git show HEAD:path` 顶替也不行——那是「相对最近一次提交」，可能差着几十次编辑，
//  把它标成 Before/After 是换一种形状撒谎。
//
//  为什么必须有界：留底留的是全文，无界保留等于按监控根内的文件体积吃常驻内存
//  （性能预算：< 120 MB）。所以只留最近 `capacity` 条，每条体积在读取处已被
//  `maxSnippetBytes` 截住。被逐出的路径退回「首次观测」并如实标注，
//  而不是拿一份更老的版本硬凑成可比。
//

import Foundation

/// 「路径 → 上一次观测到的文本内容」的有界 LRU 留底。
struct FileTextBaselineCache: Sendable {

    /// 一份留底：内容本体 + 那次观测的时刻（UI 要说「与 <time> 观测到的版本对比」）。
    struct Baseline: Sendable, Hashable {
        var text: String
        var observedAt: Date
    }

    private struct Entry: Sendable, Hashable {
        var path: String
        var baseline: Baseline
    }

    private let capacity: Int
    /// 下标 0 是最近使用；命中即前移，超出容量逐出末位。
    /// 用数组而不是 `Dictionary` + 序号：容量是个位数到几十，前移一次的代价比多一套索引结构低。
    private var entries: [Entry] = []

    init(capacity: Int) {
        self.capacity = max(capacity, 1)
    }

    var count: Int { entries.count }

    /// 查改前版本；命中会把该条提到最近使用位（这正是「刚被读过的更该留下」）。
    mutating func baseline(forPath path: String) -> Baseline? {
        guard let index = entries.firstIndex(where: { $0.path == path }) else { return nil }
        entries.insert(entries.remove(at: index), at: 0)
        return entries[0].baseline
    }

    /// 记下本次观测到的内容，成为该路径下一次的「改前」。
    mutating func remember(_ text: String, observedAt: Date, forPath path: String) {
        entries.removeAll { $0.path == path }
        entries.insert(Entry(path: path, baseline: Baseline(text: text, observedAt: observedAt)), at: 0)
        if entries.count > capacity {
            entries.removeLast(entries.count - capacity)
        }
    }

    /// 文件已删除 ⇒ 留底不再指代任何存在的东西。留着它，之后同路径的新文件会被拿去
    /// 和一个死版本比较，那比「首次观测」更误导。
    mutating func forget(path: String) {
        entries.removeAll { $0.path == path }
    }

    /// 重命名不改内容 ⇒ 把留底挪到新路径。不挪的话，改名后的第一次修改会被谎称「首次观测」。
    /// 时刻**保持原样**：那份内容确实是它在旧路径被观测到的那一次。
    mutating func move(from oldPath: String, to newPath: String) {
        guard oldPath != newPath,
              let index = entries.firstIndex(where: { $0.path == oldPath }) else { return }
        // 必须先摘出来再清理目标路径：反过来做会让 `index` 指向别的元素甚至越界。
        var moved = entries.remove(at: index)
        moved.path = newPath
        entries.removeAll { $0.path == newPath }
        entries.insert(moved, at: 0)
    }
}
