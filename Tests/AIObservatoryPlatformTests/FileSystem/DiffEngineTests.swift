//
//  DiffEngineTests.swift
//  AIObservatoryPlatformTests — FileSystem
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  MyersDiffEngine 单测：简报验收要求 diff 引擎至少 5 个用例，
//  覆盖空输入 / 纯新增 / 纯删除 / 完全相同 / 超长截断，
//  外加经典 Myers 样例、hunk 头逐字断言、hunk 自洽不变量、maxD 退化、二进制、性能护栏。
//
//  这些用例都是纯计算，不碰磁盘、不依赖 wall-clock（性能护栏除外）。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

// MARK: - 辅助

/// 一个 hunk：头 + body 行。
private struct ParsedHunk {
    let header: String
    let body: [DiffLine]

    /// 该 hunk 实际消耗的旧行数（context + removed）。
    var oldLineCount: Int { body.filter { $0.style != .added }.count }
    /// 该 hunk 实际消耗的新行数（context + added）。
    var newLineCount: Int { body.filter { $0.style != .removed }.count }
}

/// 把 `FileDiff.lines` 按 `hunkHeader` 切成若干 hunk。
private func parseHunks(_ diff: FileDiff) -> [ParsedHunk] {
    var result: [ParsedHunk] = []
    var currentHeader: String?
    var body: [DiffLine] = []
    for line in diff.lines {
        if line.style == .hunkHeader {
            if let header = currentHeader { result.append(ParsedHunk(header: header, body: body)) }
            currentHeader = line.text
            body = []
        } else {
            body.append(line)
        }
    }
    if let header = currentHeader { result.append(ParsedHunk(header: header, body: body)) }
    return result
}

/// 解析 `@@ -a,b +c,d @@` 的四个数字（手工解析，避免正则输出类型的不确定性）。
private func parseHunkHeader(_ header: String) -> (a: Int, b: Int, c: Int, d: Int)? {
    guard header.hasPrefix("@@ -"), header.hasSuffix(" @@") else { return nil }
    let middle = header.dropFirst(4).dropLast(3)          // "a,b +c,d"
    let halves = middle.split(separator: " ")
    guard halves.count == 2 else { return nil }
    let oldSide = halves[0].split(separator: ",")
    let newSide = halves[1].split(separator: ",")
    guard oldSide.count == 2, newSide.count == 2, newSide[0].hasPrefix("+") else { return nil }
    guard let a = Int(oldSide[0]), let b = Int(oldSide[1]),
          let c = Int(newSide[0].dropFirst()), let d = Int(newSide[1]) else { return nil }
    return (a, b, c, d)
}

private func numberedLines(_ count: Int, replacing index: Int? = nil, with replacement: String = "CHANGED") -> String {
    (1...count).map { i in (i == index ? replacement : "line \(i)") }.joined(separator: "\n") + "\n"
}

// MARK: - Suite

@Suite("WS-Files: Myers diff 引擎")
struct DiffEngineTests {

    // MARK: 简报点名的 5 类

    @Test("diff：空输入不产生任何行")
    func emptyInputs() {
        let engine = MyersDiffEngine()
        let d = engine.diff(oldText: nil, newText: nil, path: "x.swift", changeKind: .modified)
        #expect(d.lines.isEmpty)
        #expect(d.linesAdded == 0)
        #expect(d.linesRemoved == 0)
        #expect(!d.isBinary)
        #expect(!d.isTruncated)
        #expect(d.path == "x.swift")
        #expect(d.kind == .modified)
    }

    @Test("diff：纯新增（旧文本为空）")
    func pureAdd() {
        let engine = MyersDiffEngine()
        let d = engine.diff(oldText: nil, newText: "alpha\nbeta\ngamma\n", path: "x", changeKind: .created)
        #expect(d.linesAdded == 3)
        #expect(d.linesRemoved == 0)
        let added = d.lines.filter { $0.style == .added }
        #expect(added.map(\.text) == ["alpha", "beta", "gamma"])
        #expect(added.allSatisfy { $0.oldLineNumber == nil })
        #expect(added.compactMap(\.newLineNumber) == [1, 2, 3])
        // 纯新增的 hunk 头：旧侧 0 行，起点记在插入点前一行（此处为文件头 ⇒ -0,0）。
        #expect(d.lines.first?.style == .hunkHeader)
        #expect(d.lines.first?.text == "@@ -0,0 +1,3 @@")
    }

    @Test("diff：纯删除（新文本为空）")
    func pureDelete() {
        let engine = MyersDiffEngine()
        let d = engine.diff(oldText: "alpha\nbeta\ngamma\n", newText: nil, path: "x", changeKind: .deleted)
        #expect(d.linesRemoved == 3)
        #expect(d.linesAdded == 0)
        let removed = d.lines.filter { $0.style == .removed }
        #expect(removed.map(\.text) == ["alpha", "beta", "gamma"])
        #expect(removed.allSatisfy { $0.newLineNumber == nil })
        #expect(removed.compactMap(\.oldLineNumber) == [1, 2, 3])
        #expect(d.lines.first?.text == "@@ -1,3 +0,0 @@")
    }

    @Test("diff：完全相同的文本零改动")
    func identical() {
        let engine = MyersDiffEngine()
        let text = numberedLines(40)
        let d = engine.diff(oldText: text, newText: text, path: "x", changeKind: .modified)
        #expect(d.linesAdded == 0)
        #expect(d.linesRemoved == 0)
        #expect(d.lines.isEmpty, "无改动时不应输出 hunk（与 git diff 一致）")
        #expect(!d.isTruncated)
    }

    @Test("diff：超过 20 000 行退化为摘要并置 isTruncated")
    func overLongTruncation() {
        let engine = MyersDiffEngine()
        let big = String(repeating: "x\n", count: 25_000)
        let d = engine.diff(oldText: big, newText: big + "y\n", path: "x", changeKind: .modified)
        #expect(d.isTruncated)
        #expect(d.lines.count == 1)
        #expect(d.lines.allSatisfy { $0.style == .meta }, "截断路径只允许 meta 行")
        // 整块替换语义：旧侧全算删除、新侧全算新增。
        #expect(d.linesRemoved == 25_000)
        #expect(d.linesAdded == 25_001)
    }

    // MARK: 经典 Myers 样例

    @Test("diff：ABCABBA → CBABAC 字符级最小编辑脚本长度为 5")
    func myersPaperCharacterLevel() {
        let engine = MyersDiffEngine()
        #expect(engine.characterEditDistance("ABCABBA", "CBABAC") == 5)
    }

    @Test("diff：同一例子按行喂入也得 5 条编辑（2 增 3 删）")
    func myersPaperLineLevel() {
        let engine = MyersDiffEngine()
        let d = engine.diff(
            oldText: "A\nB\nC\nA\nB\nB\nA",
            newText: "C\nB\nA\nB\nA\nC",
            path: "x",
            changeKind: .modified
        )
        #expect(d.linesAdded + d.linesRemoved == 5)
        // 最小编辑脚本里 |旧-新| = 1 ⇒ 必然是 3 删 2 增。
        #expect(d.linesRemoved == 3)
        #expect(d.linesAdded == 2)
        #expect(!d.isTruncated)
        let added = d.lines.filter { $0.style == .added }.map(\.text)
        let removed = d.lines.filter { $0.style == .removed }.map(\.text)
        #expect(Set(added).isSubset(of: ["A", "B", "C"]))
        #expect(Set(removed).isSubset(of: ["A", "B", "C"]))
    }

    @Test("diff：非最小编辑脚本会被最短性检查拒绝（额外样例 D=1/2）")
    func trivialEditDistances() {
        let engine = MyersDiffEngine()
        #expect(engine.characterEditDistance("", "") == 0)
        #expect(engine.characterEditDistance("abc", "abc") == 0)
        #expect(engine.characterEditDistance("abc", "abcd") == 1)
        #expect(engine.characterEditDistance("abc", "axc") == 2)  // 删 b + 插 x
        #expect(engine.characterEditDistance("kitten", "sitting") == 5)
    }

    // MARK: Hunk 头与上下文

    @Test("diff：文件中部改一行的 hunk 头逐字正确（含 3 行上文）")
    func hunkHeaderMiddleOfFile() {
        let engine = MyersDiffEngine()
        let d = engine.diff(
            oldText: numberedLines(15),
            newText: numberedLines(15, replacing: 11, with: "CHANGED"),
            path: "x",
            changeKind: .modified
        )
        let hunks = parseHunks(d)
        #expect(hunks.count == 1)
        #expect(hunks.first?.header == "@@ -8,7 +8,7 @@")
        #expect(hunks.first?.body.filter { $0.style == .context }.map(\.text)
                    == ["line 8", "line 9", "line 10", "line 12", "line 13", "line 14"])
    }

    @Test("diff：靠近文件尾部的改动按实际可用行数收紧上下文")
    func hunkHeaderNearEOF() {
        let engine = MyersDiffEngine()
        let d = engine.diff(
            oldText: numberedLines(10, replacing: 8),
            newText: numberedLines(10, replacing: 8, with: "X"),
            path: "x",
            changeKind: .modified
        )
        let hunks = parseHunks(d)
        #expect(hunks.count == 1)
        #expect(hunks.first?.header == "@@ -5,6 +5,6 @@")
    }

    @Test("diff：改动间隔 ≤ 2*ctx 合并为一个 hunk，更大则切开")
    func hunkMergeThreshold() {
        let engine = MyersDiffEngine(contextLines: 3)
        // 两份 20 行文本，第 1 处改动固定在第 1 行，第二处改动随 gap 右移。
        func headerCount(secondChange: Int) -> [String] {
            let old = (1...20).map { i in "L\(i)" }.joined(separator: "\n") + "\n"
            let changed = (1...20).map { i in (i == 1 || i == secondChange) ? "CHANGED" : "L\(i)" }.joined(separator: "\n") + "\n"
            return parseHunks(engine.diff(oldText: old, newText: changed, path: "x", changeKind: .modified))
                .map(\.header)
        }
        #expect(headerCount(secondChange: 7).count == 1, "间隔 5 应合并")
        #expect(headerCount(secondChange: 8).count == 1, "间隔 6 = 2*ctx 仍合并")
        let split = headerCount(secondChange: 9)
        #expect(split.count == 2, "间隔 7 > 2*ctx 应切开")
        #expect(split == ["@@ -1,4 +1,4 @@", "@@ -6,7 +6,7 @@"], "实际：\(split)")
    }

    @Test("diff：每个 hunk 头声明的行数与其 body 严格自洽")
    func hunkHeaderIsSelfConsistent() {
        let engine = MyersDiffEngine(contextLines: 3)
        let cases: [(String, String)] = [
            (numberedLines(30, replacing: 1), numberedLines(30, replacing: 1, with: "CHANGED")),
            (numberedLines(30, replacing: 15), numberedLines(30, replacing: 15, with: "CHANGED")),
            (numberedLines(30, replacing: 30), numberedLines(30, replacing: 30, with: "CHANGED")),
            ("", numberedLines(5)),
            (numberedLines(5), ""),
            (numberedLines(20, replacing: 3), numberedLines(24, replacing: 3, with: "CHANGED") + "extra\n"),
        ]
        for (old, new) in cases {
            let d = engine.diff(oldText: old, newText: new, path: "x", changeKind: .modified)
            for hunk in parseHunks(d) {
                guard let header = parseHunkHeader(hunk.header) else {
                    Issue.record("hunk 头格式非法：\(hunk.header)")
                    continue
                }
                #expect(header.b == hunk.oldLineCount, "\(hunk.header) 声明旧 \(header.b) 行，实际 \(hunk.oldLineCount)")
                #expect(header.d == hunk.newLineCount, "\(hunk.header) 声明新 \(header.d) 行，实际 \(hunk.newLineCount)")
                // body 里第一条 context/removed 行的旧行号必须等于头里的 a（除非旧侧 0 行）。
                if let firstOld = hunk.body.first(where: { $0.style != .added })?.oldLineNumber, header.b > 0 {
                    #expect(firstOld == header.a, "\(hunk.header) 起始旧行号应为 \(header.a)，实际 \(firstOld)")
                }
                if let firstNew = hunk.body.first(where: { $0.style != .removed })?.newLineNumber, header.d > 0 {
                    #expect(firstNew == header.c, "\(hunk.header) 起始新行号应为 \(header.c)，实际 \(firstNew)")
                }
            }
        }
    }

    @Test("diff：上下文行数不超过 contextLines，且同一行不会出现在两个 hunk 里")
    func contextIsCappedAndNoDuplicates() {
        let engine = MyersDiffEngine(contextLines: 3)
        let old = numberedLines(60, replacing: 10)
        let new = numberedLines(60, replacing: 50, with: "CHANGED")
        let d = engine.diff(oldText: old, newText: new, path: "x", changeKind: .modified)
        let hunks = parseHunks(d)
        #expect(hunks.count == 2)
        for hunk in hunks {
            let body = hunk.body
            let lead = body.prefix(while: { $0.style == .context }).count
            let trail = body.reversed().prefix(while: { $0.style == .context }).count
            #expect(lead <= 3, "上文行数 \(lead) 超过 contextLines")
            #expect(trail <= 3, "下文行数 \(trail) 超过 contextLines")
        }
        let reportedOldLines = d.lines.compactMap(\.oldLineNumber)
        #expect(Set(reportedOldLines).count == reportedOldLines.count, "同一旧行号被输出两次")
    }

    // MARK: 退化路径

    @Test("diff：编辑距离超出 maxEditDistance 时退化为摘要并置 isTruncated")
    func editDistanceBudgetExhausted() {
        let engine = MyersDiffEngine(maxEditDistance: 2)
        let old = "a\nb\nc\nd\ne\nf\ng\nh\n"
        let new = "1\n2\n3\n4\n5\n6\n7\n8\n"
        let d = engine.diff(oldText: old, newText: new, path: "x", changeKind: .modified)
        #expect(d.isTruncated)
        #expect(d.lines.count == 1)
        #expect(d.lines.first?.style == .meta)
        #expect(d.linesRemoved == 8)
        #expect(d.linesAdded == 8)
    }

    @Test("diff：maxEditDistance 足够时同一输入产出正常 hunk")
    func editDistanceBudgetSufficient() {
        let engine = MyersDiffEngine(maxEditDistance: 4_000)
        let old = "a\nb\nc\nd\ne\nf\ng\nh\n"
        let new = "1\n2\n3\n4\n5\n6\n7\n8\n"
        let d = engine.diff(oldText: old, newText: new, path: "x", changeKind: .modified)
        #expect(!d.isTruncated)
        #expect(d.linesRemoved == 8)
        #expect(d.linesAdded == 8)
    }

    // MARK: 文本边界

    @Test("diff：行尾换行的有无不产生伪 diff")
    func trailingNewlineIgnored() {
        let engine = MyersDiffEngine()
        let d = engine.diff(oldText: "a\nb", newText: "a\nb\n", path: "x", changeKind: .modified)
        #expect(d.linesAdded == 0)
        #expect(d.linesRemoved == 0)
        #expect(d.lines.isEmpty)
    }

    @Test("diff：空行与连续空行被如实当作行处理")
    func blankLinesCountAsLines() {
        let engine = MyersDiffEngine()
        let d = engine.diff(oldText: "a\n\nb\n", newText: "a\nb\n", path: "x", changeKind: .modified)
        #expect(d.linesRemoved == 1)
        #expect(d.linesAdded == 0)
        #expect(d.lines.contains { $0.style == .removed && $0.text.isEmpty })
    }

    @Test("diff：行文本原样保真（含引号/反斜杠/中文/emoji 不被转义）")
    func lineTextIsFidelityPreserved() {
        let engine = MyersDiffEngine()
        let tricky = "{\"key\": \"v\\\\1\"}\n中文行 🎉\n"
        let d = engine.diff(oldText: "", newText: tricky, path: "x", changeKind: .created)
        let added = d.lines.filter { $0.style == .added }.map(\.text)
        #expect(added == ["{\"key\": \"v\\\\1\"}", "中文行 🎉"])
    }

    // MARK: 二进制

    @Test("diff：含 NUL 的文本判为二进制且不产出乱码行")
    func binaryDetected() {
        let engine = MyersDiffEngine()
        let d = engine.diff(oldText: "hello", newText: "he\u{0}llo", path: "x", changeKind: .modified)
        #expect(d.isBinary)
        #expect(!d.isTruncated)
        #expect(d.lines.count == 1)
        #expect(d.lines.first?.style == .meta)
        #expect(d.linesAdded == 0)
        #expect(d.linesRemoved == 0)
        #expect(!d.lines.contains { $0.style == .added || $0.style == .removed })
    }

    @Test("diff：旧侧含 NUL 同样判为二进制")
    func binaryOnOldSide() {
        let engine = MyersDiffEngine()
        let d = engine.diff(oldText: "\u{0}abc", newText: "def", path: "x", changeKind: .modified)
        #expect(d.isBinary)
        #expect(d.lines.allSatisfy { $0.style == .meta })
    }

    // MARK: 契约回填

    @Test("diff：kind / previousPath / capturedAt 按契约回填")
    func contractFieldsPopulated() {
        let engine = MyersDiffEngine()
        let before = Date(timeIntervalSince1970: 1_700_000_000)
        let d = engine.diff(oldText: "a\n", newText: "b\n", path: "/tmp/x.swift", changeKind: .renamed)
        #expect(d.kind == .renamed)
        #expect(d.path == "/tmp/x.swift")
        #expect(d.previousPath == nil)
        #expect(d.capturedAt >= before)
    }

    // MARK: 性能护栏

    @Test("性能护栏：5000 行只改 3 处应在 2 秒内完成")
    func performanceGuardrail() {
        let engine = MyersDiffEngine()
        let plain = (1...5_000).map { "line \($0)" }
        let old = plain.joined(separator: "\n") + "\n"
        var changed = plain
        changed[999] = "CHANGED"
        changed[2499] = "CHANGED"
        changed[4999] = "CHANGED"
        let new = changed.joined(separator: "\n") + "\n"

        let clock = ContinuousClock()
        let start = clock.now
        let d = engine.diff(oldText: old, newText: new, path: "x", changeKind: .modified)
        let elapsed = start.duration(to: clock.now)
        let spent = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) * 1e-18

        #expect(d.linesRemoved == 3)
        #expect(d.linesAdded == 3)
        #expect(!d.isTruncated)
        #expect(spent < 2.0, "5000 行 diff 耗时 \(spent)s，性能护栏失败")
    }
}
