//
//  MyersDiffEngine.swift
//  AIObservatoryPlatform — FileSystem 子模块
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  纯 Swift 自研 Myers O(ND) 文本 diff（不依赖 /usr/bin/diff、不 shell out 任何外部进程）。
//  输出 [DiffLine]（含 hunk 头 `@@ -a,b +c,d @@`）与增删行数；
//  单侧行数 > 20 000 或编辑距离超出 maxEditDistance 时退化为「整块替换」摘要并置 isTruncated，
//  绝不逐行展开。含 NUL 字节的文本判为二进制，只输出一条 meta 行（不产生乱码 diff）。
//

import Foundation
import AIObservatoryCore

/// 纯 Swift 实现的 Myers O(ND) 文本 diff 引擎，实现 `DiffComputing` 契约。
///
/// 语义约定：
/// - 行切分见 ``splitLines(_:)``；行尾是否带 `\n` 不影响 diff 结果。
/// - 每个改动块输出为 git 风格 hunk：`@@ -a,b +c,d @@`，后跟**最多** `contextLines` 行上文、
///   改动行、**最多** `contextLines` 行下文（靠近文件首尾时按实际可用行数收紧）。
/// - 两个改动块之间的未改动行数 ≤ `2 * contextLines` 时合并为同一个 hunk，否则切开；
///   各 hunk 覆盖的编辑区间互不重叠，同一行不会被输出两次。
/// - 文本含 `\u{0}` → `isBinary == true`，仅一条 `meta` 行，增删行数均为 0。
/// - 单侧行数 > `maxLinesBeforeTruncation`，或最短编辑脚本的 D 超出 `maxEditDistance` →
///   退化为「整块替换」摘要（只一条 `meta` 行，不逐行展开），`isTruncated == true`，
///   且 `linesAdded = 新文件行数`、`linesRemoved = 旧文件行数`。
public struct MyersDiffEngine: DiffComputing {

    /// 超过此行数的文本直接退化为摘要，避免 O(ND) 内存/时间爆炸。
    public let maxLinesBeforeTruncation: Int

    /// Myers 算法的最大编辑距离（D）上限；超出即退化为整块替换摘要。
    public let maxEditDistance: Int

    /// Hunk 上下文行数（每个改动块上下各最多保留多少未改动行）。
    public let contextLines: Int

    /// 创建 diff 引擎。
    /// - Parameters:
    ///   - maxLinesBeforeTruncation: 单侧行数上限，默认 20_000；超过即 `isTruncated`。
    ///   - maxEditDistance: 编辑距离上限，默认 4_000；超过即 `isTruncated`。
    ///   - contextLines: hunk 上下文行数，默认 3（git 风格）。
    public init(maxLinesBeforeTruncation: Int = 20_000, maxEditDistance: Int = 4_000, contextLines: Int = 3) {
        self.maxLinesBeforeTruncation = max(maxLinesBeforeTruncation, 0)
        self.maxEditDistance = max(maxEditDistance, 0)
        self.contextLines = max(contextLines, 0)
    }

    /// 计算两份文本的 diff。
    ///
    /// 输出行样式只会是 `.context` / `.added` / `.removed` / `.hunkHeader` / `.meta`：
    /// 正常路径产出一或多个 hunk（含 `@@ -a,b +c,d @@` 头），异常路径（二进制 / 过大）
    /// 只产出一条 `.meta` 摘要行。
    /// - Parameters:
    ///   - oldText: 旧文本（`nil` 表示创建，按空文本处理）。
    ///   - newText: 新文本（`nil` 表示删除，按空文本处理）。
    ///   - path: 文件路径（仅回填 `FileDiff.path`）。
    ///   - changeKind: 变更种类（仅回填 `FileDiff.kind`）。
    public func diff(
        oldText: String?,
        newText: String?,
        path: String,
        changeKind: FileChangeKind
    ) -> FileDiff {
        // 二进制：任一文本含 NUL 字节即视为二进制，只给一条 meta 行，绝不输出乱码行。
        if (oldText?.contains("\u{0}") ?? false) || (newText?.contains("\u{0}") ?? false) {
            return FileDiff(
                path: path,
                kind: changeKind,
                lines: [DiffLine(style: .meta, text: "Binary file differs (not shown)")],
                isBinary: true
            )
        }

        let aLines = splitLines(oldText ?? "")
        let bLines = splitLines(newText ?? "")
        let aCount = aLines.count
        let bCount = bLines.count

        // 超大文件：在跑 Myers 之前就退化，保证 O(1) 时间，不逐行展开。
        if aCount > maxLinesBeforeTruncation || bCount > maxLinesBeforeTruncation {
            let meta = DiffLine(
                style: .meta,
                text: "File too large to diff (\(aCount) → \(bCount) lines); showing summary only"
            )
            return FileDiff(
                path: path,
                kind: changeKind,
                lines: [meta],
                linesAdded: bCount,
                linesRemoved: aCount,
                isTruncated: true
            )
        }

        let (edits, truncated) = computeEdits(aLines, bLines)
        if truncated {
            // 超出 maxEditDistance：退化为「整块替换」摘要（不逐行展开），增删按整块计数。
            let meta = DiffLine(
                style: .meta,
                text: "Diff exceeds edit-distance budget (\(maxEditDistance)); showing whole-file replacement summary (\(aCount) → \(bCount) lines)"
            )
            return FileDiff(
                path: path,
                kind: changeKind,
                lines: [meta],
                linesAdded: bCount,
                linesRemoved: aCount,
                isTruncated: true
            )
        }

        let diffLines = buildDiffLines(edits)
        var added = 0
        var removed = 0
        for e in edits {
            switch e.kind {
            case .equal: break
            case .add: added += 1
            case .remove: removed += 1
            }
        }
        return FileDiff(
            path: path,
            kind: changeKind,
            lines: diffLines,
            linesAdded: added,
            linesRemoved: removed
        )
    }

    // MARK: - 文本切分

    /// 按 `\n` 切分文本为行数组（不含行尾换行符），空文本 → 0 行。
    ///
    /// 边界：`"a\nb"` 与 `"a\nb\n"` 都是 2 行（行尾换行差异不产生 diff）；
    /// `""` → 0 行；`"\n"` → 1 个空行；`"a\n\nb"` → 3 行（中间为空行）。
    /// 返回 `Substring` 以避免大文件下的整份字符串拷贝，比较按行内容（grapheme 级）进行。
    func splitLines(_ text: String) -> [Substring] {
        guard !text.isEmpty else { return [] }
        var lines: [Substring] = []
        var current = text.startIndex
        while current < text.endIndex {
            if let nl = text[current...].firstIndex(of: "\n") {
                lines.append(text[current..<nl])
                current = text.index(after: nl)
            } else {
                lines.append(text[current...])
                break
            }
        }
        return lines
    }

    // MARK: - Myers O(ND)

    private enum EditKind: Sendable { case equal, add, remove }

    private struct RawEdit: Sendable {
        let kind: EditKind
        let text: String
        let oldLine: Int?
        let newLine: Int?
    }

    /// trace 快照的内存预算（字节）。第 d 轮只需保存 `k ∈ [-d, d]`（2d+1 个 Int），
    /// 前 D 轮总占用约 `(D+1)^2 * sizeof(Int)`；据此再压一次 D 上限，避免大文件下内存爆炸。
    private static let traceMemoryBudgetBytes = 64 << 20

    /// 计算 Myers 最短编辑脚本，返回（完整编辑序列 —— 覆盖从第 1 行起的每一行 ——, 是否因超预算而失败）。
    private func computeEdits<T: Equatable>(_ a: [T], _ b: [T]) -> (edits: [RawEdit], truncated: Bool) {
        let n = a.count
        let m = b.count
        guard n != 0 || m != 0 else { return ([], false) }

        let maxDByMemory = max(
            0,
            Int(Double(Self.traceMemoryBudgetBytes / MemoryLayout<Int>.stride).squareRoot()) - 1
        )
        let maxD = min(maxEditDistance, n + m, maxDByMemory)
        let offset = n + m
        var v = [Int](repeating: 0, count: 2 * offset + 1)
        // trace[d] = 第 d 轮结束后的 V 快照（仅 k ∈ [-d, d]）。回溯只需 trace[0...foundD-1]。
        var trace: [[Int]] = []
        var foundD = -1
        var foundK = 0

        outer: for d in 0...maxD {
            for k in stride(from: -d, through: d, by: 2) {
                var x: Int
                if k == -d || (k != d && v[offset + k - 1] < v[offset + k + 1]) {
                    x = v[offset + k + 1]
                } else {
                    x = v[offset + k - 1] + 1
                }
                var y = x - k
                while x < n && y < m && a[x] == b[y] {
                    x += 1
                    y += 1
                }
                v[offset + k] = x
                if x >= n && y >= m {
                    foundD = d
                    foundK = k
                    break outer
                }
            }
            trace.append(Array(v[(offset - d)...(offset + d)]))
        }

        guard foundD >= 0 else {
            // 未在 maxD 内收敛 → 交由调用方退化为整块替换摘要。
            return ([], true)
        }

        let points = backtrackPoints(
            n: n, m: m, foundD: foundD, foundK: foundK,
            offset: offset, trace: trace
        )
        return (replay(points, a, b), false)
    }

    /// 从终点 `(n, m)` 沿各轮 V 快照反推拐点序列，并保证以 `(0, 0)` 开头。
    ///
    /// 重要：`(0, 0)` 必须显式补齐。回溯到的第一个拐点是「第 0 轮的最远到达点」，
    /// 即公共前缀末端 `(p, p)`；若不补 `(0, 0)`，`(0,0) → (p,p)` 这段纯对角线（文件开头
    /// 的 `p` 行相等内容）会整体丢失，导致首个 hunk 的上文缺失、hunk 头行号偏大。
    private func backtrackPoints(
        n: Int, m: Int, foundD: Int, foundK: Int, offset: Int, trace: [[Int]]
    ) -> [(x: Int, y: Int)] {
        var points: [(Int, Int)] = []
        var d = foundD
        var k = foundK
        while d > 0 {
            // trace[d - 1] 是第 d-1 轮的 V（长度 2(d-1)+1，下标 k + (d-1)）。
            let vPrev = trace[d - 1]
            let prevRound = d - 1
            let prevK: Int
            if k == -d || (k != d && valueOf(vPrev, round: prevRound, k: k - 1) < valueOf(vPrev, round: prevRound, k: k + 1)) {
                prevK = k + 1
            } else {
                prevK = k - 1
            }
            let x = valueOf(vPrev, round: prevRound, k: prevK)
            points.append((x, x - prevK))
            k = prevK
            d = prevRound
        }
        points.reverse()
        points.append((n, m))
        points.insert((0, 0), at: 0)
        return points
    }

    /// 读取第 `round` 轮 V 快照中对角线 `k` 的最远 x。
    /// 调用点在 Myers 性质下必满足 `|k| <= round`；越界兜底返回 0，避免任何 trap。
    private func valueOf(_ snapshot: [Int], round: Int, k: Int) -> Int {
        let index = k + round
        guard index >= 0, index < snapshot.count else { return 0 }
        return snapshot[index]
    }

    /// 把拐点序列展开为逐行编辑脚本：相邻拐点之间恰为「一步插入/删除 + 一段纯对角线」。
    ///
    /// `String(describing:)` 对 `Substring` 走 `CustomStringConvertible.description`，
    /// 得到的是原样行内容（不含引号），已由独立验证程序逐例断言（见 `DiffEngineTests` 的
    /// 「行文本不含引号」用例）。
    private func replay<T: Equatable>(_ points: [(x: Int, y: Int)], _ a: [T], _ b: [T]) -> [RawEdit] {
        var edits: [RawEdit] = []
        edits.reserveCapacity(max(a.count, b.count))
        for i in 0..<(points.count - 1) {
            let x0 = points[i].x
            let y0 = points[i].y
            let x1 = points[i + 1].x
            let y1 = points[i + 1].y
            let diagLen = min(x1 - x0, y1 - y0)

            if x1 - x0 > y1 - y0 {
                // 删除 a[x0]，随后 diagLen 行相等。
                edits.append(RawEdit(kind: .remove, text: String(describing: a[x0]), oldLine: x0 + 1, newLine: nil))
                for j in 0..<diagLen {
                    edits.append(RawEdit(
                        kind: .equal,
                        text: String(describing: a[x0 + 1 + j]),
                        oldLine: x0 + 2 + j,
                        newLine: y0 + 1 + j
                    ))
                }
            } else if y1 - y0 > x1 - x0 {
                // 新增 b[y0]，随后 diagLen 行相等。
                edits.append(RawEdit(kind: .add, text: String(describing: b[y0]), oldLine: nil, newLine: y0 + 1))
                for j in 0..<diagLen {
                    edits.append(RawEdit(
                        kind: .equal,
                        text: String(describing: a[x0 + j]),
                        oldLine: x0 + 1 + j,
                        newLine: y0 + 2 + j
                    ))
                }
            } else {
                // 纯对角线（含开头补上的公共前缀段）。
                for j in 0..<diagLen {
                    edits.append(RawEdit(
                        kind: .equal,
                        text: String(describing: a[x0 + j]),
                        oldLine: x0 + 1 + j,
                        newLine: y0 + 1 + j
                    ))
                }
            }
        }
        return edits
    }

    // MARK: - Hunk 组装

    /// 把完整编辑脚本按上下文窗口分组，生成带 `@@ -a,b +c,d @@` 头的 `DiffLine` 数组。
    ///
    /// 算法（可证明单次线性、区间互不重叠）：
    /// 1. 记下所有「改动行」的下标；若无改动行 → 返回空数组（与 `git diff` 一致）。
    /// 2. 以第一个改动行为起点，窗口为 `[c - ctx, c + ctx]`；后续改动行 `c'` 满足
    ///    `c' - ctx <= 当前窗口右端 + 1`（即两改动行间隔 ≤ `2*ctx`）时并入当前 hunk，
    ///    否则闭合当前 hunk 并新起一个。
    /// 3. 每组输出一个 hunk 头 + 组内所有编辑行。
    ///
    /// Hunk 头约定：
    /// - `a`：hunk 第一行的 **1-based 旧行号**；`c`：hunk 第一行的 **1-based 新行号**。
    /// - `b`：hunk 消耗的旧行数（context + removed）；`d`：hunk 消耗的新行数（context + added）。
    /// - `b == 0`（纯插入）时 `a` 取「插入点前一行」的旧行号，在文件头插入即为 `@@ -0,0 ...`，
    ///   `d == 0` 时对称，与 git 一致。
    /// - 本引擎始终显式写出 `,b` / `,d`，不采用 git「计数为 1 时省略」的简写。
    private func buildDiffLines(_ edits: [RawEdit]) -> [DiffLine] {
        guard !edits.isEmpty else { return [] }
        let ctx = contextLines
        let count = edits.count

        // 1. 改动行下标。
        var changed: [Int] = []
        for i in 0..<count where edits[i].kind != .equal {
            changed.append(i)
        }
        guard let firstChange = changed.first else { return [] }

        // 2. 旧/新行号前缀计数：preOld[i] = edits[0..<i] 消耗的旧行数（0-based 行号即等于它）。
        var preOld = [Int](repeating: 0, count: count + 1)
        var preNew = [Int](repeating: 0, count: count + 1)
        for i in 0..<count {
            preOld[i + 1] = preOld[i] + (edits[i].kind == .add ? 0 : 1)
            preNew[i + 1] = preNew[i] + (edits[i].kind == .remove ? 0 : 1)
        }

        // 3. 分组并输出。
        var result: [DiffLine] = []
        func appendHunk(lo: Int, hi: Int) {
            let oldCount = preOld[hi + 1] - preOld[lo]
            let newCount = preNew[hi + 1] - preNew[lo]
            let oldStart = preOld[lo] + (oldCount == 0 ? 0 : 1)
            let newStart = preNew[lo] + (newCount == 0 ? 0 : 1)
            result.append(DiffLine(
                style: .hunkHeader,
                text: "@@ -\(oldStart),\(oldCount) +\(newStart),\(newCount) @@"
            ))
            for i in lo...hi {
                let e = edits[i]
                switch e.kind {
                case .equal:
                    result.append(DiffLine(style: .context, text: e.text, oldLineNumber: e.oldLine, newLineNumber: e.newLine))
                case .add:
                    result.append(DiffLine(style: .added, text: e.text, oldLineNumber: nil, newLineNumber: e.newLine))
                case .remove:
                    result.append(DiffLine(style: .removed, text: e.text, oldLineNumber: e.oldLine, newLineNumber: nil))
                }
            }
        }

        var lo = max(0, firstChange - ctx)
        var hi = min(count - 1, firstChange + ctx)
        for c in changed.dropFirst() {
            if c - ctx > hi + 1 {
                appendHunk(lo: lo, hi: hi)
                lo = max(0, c - ctx)
            }
            hi = min(count - 1, c + ctx)
        }
        appendHunk(lo: lo, hi: hi)
        return result
    }

    // MARK: - 字符级编辑距离（用于校验 Myers 正确性）

    /// 计算两个字符串的字符级最短编辑脚本长度（删除 + 插入次数，不含相等字符）。
    ///
    /// 用途：作为 Myers 实现的回归探针 —— 经典论文样例
    /// `ABCABBA` → `CBABAC` 的最小编辑脚本长度为 5，即
    /// `characterEditDistance("ABCABBA", "CBABAC") == 5`。
    /// 注意这是**字符级**；行级最小编辑数请用 ``diff(oldText:newText:path:changeKind:)``
    /// 的 `linesAdded + linesRemoved`。
    public func characterEditDistance(_ old: String, _ new: String) -> Int {
        let (edits, truncated) = computeEdits(Array(old), Array(new))
        guard !truncated else { return Array(old).count + Array(new).count }
        var distance = 0
        for e in edits where e.kind != .equal { distance += 1 }
        return distance
    }
}
