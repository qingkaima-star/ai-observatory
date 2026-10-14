//
//  SnapshotterTests.swift
//  AIObservatoryPlatformTests — FileSystem
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  FileSnapshotter 单测：SHA-256 黄金值、行数定义、读取失败一律 nil（绝不伪造）、
//  大文件快速指纹分支、二进制探测、文本片段的 UTF-8 边界。
//
//  所有临时文件建在 `Scratch.directory(...)`（当前检出自带的 `.scratch-tests/`）下并在 defer 清理。
//  SHA-256 黄金值由 `shasum -a 256` 独立算出，不是从被测实现里抄回来的。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryTestSupport

@Suite("WS-Files: 文件内容快照", .timeLimit(.minutes(1)))
struct SnapshotterTests {

    private func makeScratch(_ purpose: String) throws -> URL {
        try Scratch.directory("files-snap-\(purpose)")
    }

    private func write(_ content: String, to url: URL) throws {
        try content.write(to: url, atomically: false, encoding: .utf8)
    }

    // MARK: - 哈希与元数据

    @Test("快照：文本文件的 SHA-256 / 大小 / 行数与独立算出的黄金值一致")
    func textSnapshotMatchesGoldenHash() async throws {
        let dir = try makeScratch("golden")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.txt")
        try write("line1\nline2\nline3\n", to: file)

        let snap = await FileSnapshotter().snapshot(path: file.path)
        #expect(snap?.contentHash == "66663af9c7aa341431a8ee2ff27b72abd06c9218f517bb6fef948e4803c19e03")
        #expect(snap?.sizeBytes == 18)
        #expect(snap?.lineCount == 3)
        #expect(snap?.path == file.path)
    }

    @Test("快照：空文件的哈希是空串的 SHA-256，行数为 0")
    func emptyFileSnapshot() async throws {
        let dir = try makeScratch("empty")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("empty.txt")
        try write("", to: file)

        let snap = await FileSnapshotter().snapshot(path: file.path)
        #expect(snap?.contentHash == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(snap?.sizeBytes == 0)
        #expect(snap?.lineCount == 0)
    }

    @Test("快照：改一个字节 ⇒ 哈希变化；同内容两次 ⇒ 哈希相同")
    func hashIsContentSensitiveAndStable() async throws {
        let dir = try makeScratch("sensitive")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("b.txt")
        let snapshotter = FileSnapshotter()

        try write("observatory snapshot probe", to: file)
        let first = await snapshotter.snapshot(path: file.path)
        #expect(first?.contentHash == "aed16e2f190b0585860d1b44f3974f608dc02f710baab94263b226b5fe7ce127")
        let again = await snapshotter.snapshot(path: file.path)
        #expect(again?.contentHash == first?.contentHash)

        try write("observatory snapshot Xprobe", to: file)
        let changed = await snapshotter.snapshot(path: file.path)
        #expect(changed?.contentHash == "46aaf4fbfda456df4c8bfde25660f801b7e4ed96fffa6717ff13f1e225e3ee51")
        #expect(changed?.contentHash != first?.contentHash)
    }

    @Test("快照：哈希是小写 64 位十六进制（不因 0 字节被丢弃而变短）")
    func hashIsFullWidthLowercaseHex() async throws {
        let dir = try makeScratch("hex")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("c.txt")
        try write("observatory snapshot probe", to: file)

        let snap = await FileSnapshotter().snapshot(path: file.path)
        let hash = snap?.contentHash ?? ""
        #expect(hash.count == 64)
        #expect(hash.allSatisfy { $0.isHexDigit && !$0.isUppercase })
    }

    // MARK: - 行数定义

    @Test("快照：行数 = 换行数，末字节非换行时再 +1")
    func lineCountDefinition() async throws {
        let dir = try makeScratch("lines")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("d.txt")
        let snapshotter = FileSnapshotter()

        for (content, expected) in [("a\nb", 2), ("a\nb\n", 2), ("\n\n\n", 3), ("single", 1), ("a\n\nb", 3)] {
            try write(content, to: file)
            let snap = await snapshotter.snapshot(path: file.path)
            #expect(snap?.lineCount == expected, "内容 \(content.debugDescription) 应计为 \(expected) 行")
        }
    }

    @Test("快照：超过行数扫描上限时不统计行数（size 仍准确）")
    func lineCountScanCap() async throws {
        let dir = try makeScratch("cap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("e.txt")
        try write(String(repeating: "row\n", count: 40), to: file)  // 160 字节

        let snap = await FileSnapshotter(lineCountScanLimitBytes: 64).snapshot(path: file.path)
        #expect(snap?.lineCount == 0)
        #expect(snap?.sizeBytes == 160)
        #expect(snap?.contentHash.isEmpty == false)
    }

    // MARK: - 读取失败：一律 nil，绝不伪造

    @Test("快照：目录 / 不存在路径 / 空串路径都返回 nil，而不是空哈希假快照")
    func unreadableReturnsNil() async throws {
        let dir = try makeScratch("missing")
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshotter = FileSnapshotter()

        #expect(await snapshotter.snapshot(path: dir.path) == nil, "目录没有「内容」可言")
        #expect(await snapshotter.snapshot(path: dir.appendingPathComponent("nope.txt").path) == nil)
        #expect(await snapshotter.snapshot(path: "") == nil)
    }

    // MARK: - 大文件快速指纹

    @Test("快照：大文件走「大小 + 首尾采样」指纹，且只改中间字节时指纹不变")
    func largeFileFingerprint() async throws {
        let dir = try makeScratch("fingerprint")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("big.txt")
        // 阈值压到 4 KB，避免真写几十 MB；走的就是 >8 MB 那条分支。
        let snapshotter = FileSnapshotter(largeFileThresholdBytes: 4_096, fingerprintSampleBytes: 512)

        var body = Data(capacity: 12_000)
        body.append(contentsOf: Array("HEAD".utf8))
        body.append(contentsOf: [UInt8](repeating: 0x41, count: 10_000))   // 中间段
        body.append(contentsOf: Array("TAIL".utf8))
        try body.write(to: file)

        let before = await snapshotter.snapshot(path: file.path)
        #expect(before?.contentHash.hasPrefix("fp:\(body.count):") == true)
        let hexPart = before?.contentHash.split(separator: ":").last.map(String.init) ?? ""
        #expect(hexPart.count == 64)
        #expect(before?.sizeBytes == UInt64(body.count))

        // 只改中间第 5000 字节：快速指纹**故意**不敏感（设计取舍，避免全量哈希）。
        var mutated = body
        mutated[5_000] = 0x42
        try mutated.write(to: file)
        let middleChange = await snapshotter.snapshot(path: file.path)
        #expect(middleChange?.contentHash == before?.contentHash)
        #expect(middleChange?.sizeBytes == before?.sizeBytes)

        // 改头一个字节：指纹必须变。
        var headMutated = body
        headMutated[0] = 0x5a
        try headMutated.write(to: file)
        let headChange = await snapshotter.snapshot(path: file.path)
        #expect(headChange?.contentHash != before?.contentHash)
    }

    @Test("快照：小于阈值的文件仍走全量 SHA-256（改中间字节哈希会变）")
    func smallFileIsFullyHashed() async throws {
        let dir = try makeScratch("small")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("small.txt")
        let snapshotter = FileSnapshotter(largeFileThresholdBytes: 4_096)

        var body = Data([UInt8](repeating: 0x41, count: 300))
        try body.write(to: file)
        let before = await snapshotter.snapshot(path: file.path)
        #expect(before?.contentHash.hasPrefix("fp:") == false, "未过阈值不该用指纹")

        body[150] = 0x42
        try body.write(to: file)
        let after = await snapshotter.snapshot(path: file.path)
        #expect(after?.contentHash != before?.contentHash)
    }

    // MARK: - 二进制探测

    @Test("二进制：前 4KB 内含 NUL 判为二进制，纯文本判为非二进制")
    func binaryProbe() async throws {
        let dir = try makeScratch("binary")
        defer { try? FileManager.default.removeItem(at: dir) }
        let snapshotter = FileSnapshotter()

        let bin = dir.appendingPathComponent("bin.dat")
        try Data([0x00, 0x01, 0x02, 0x00]).write(to: bin)
        #expect(await snapshotter.isBinaryFile(path: bin.path))

        let text = dir.appendingPathComponent("text.txt")
        try write("plain text, no nul", to: text)
        #expect(!(await snapshotter.isBinaryFile(path: text.path)))

        // NUL 落在探测窗口之外 ⇒ 判不出二进制（诚实反映 binaryProbeBytes 的语义）。
        let lateNUL = dir.appendingPathComponent("late.bin")
        try Data([UInt8](repeating: 0x41, count: 5_000) + [0x00]).write(to: lateNUL)
        #expect(!(await snapshotter.isBinaryFile(path: lateNUL.path)))
        #expect(await FileSnapshotter(binaryProbeBytes: 8_192).isBinaryFile(path: lateNUL.path))

        // 空文件与读不到的文件都不能被「证明」是二进制。
        let empty = dir.appendingPathComponent("empty.bin")
        try Data().write(to: empty)
        #expect(!(await snapshotter.isBinaryFile(path: empty.path)))
        #expect(!(await snapshotter.isBinaryFile(path: dir.appendingPathComponent("ghost").path)))
    }

    @Test("二进制：快照不统计行数，但大小与哈希仍然可用")
    func binarySnapshotSkipsLineCount() async throws {
        let dir = try makeScratch("binary-snap")
        defer { try? FileManager.default.removeItem(at: dir) }
        let bin = dir.appendingPathComponent("blob.bin")
        let payload = Data([0xDE, 0xAD, 0x00, 0xBF] + [UInt8](repeating: 0x0A, count: 20))
        try payload.write(to: bin)

        let snap = await FileSnapshotter().snapshot(path: bin.path)
        #expect(snap?.sizeBytes == UInt64(payload.count))
        #expect(snap?.lineCount == 0)
        #expect((snap?.contentHash.count ?? 0) == 64)
    }

    // MARK: - 文本片段

    @Test("readTextSnippet：受 maxBytes 限制，超界/缺失/0 字节都给 nil 或截断结果")
    func textSnippetIsCapped() async throws {
        let dir = try makeScratch("snippet")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try write("line1\nline2\nline3\n", to: file)
        let snapshotter = FileSnapshotter()

        #expect(await snapshotter.readTextSnippet(path: file.path, maxBytes: 5) == "line1")
        #expect(await snapshotter.readTextSnippet(path: file.path, maxBytes: 1_000) == "line1\nline2\nline3\n")
        #expect(await snapshotter.readTextSnippet(path: file.path, maxBytes: 0) == nil)
        #expect(await snapshotter.readTextSnippet(path: "/no/such/file", maxBytes: 10) == nil)
        #expect(await snapshotter.readTextSnippet(path: dir.path, maxBytes: 10) == nil, "目录不是文本")
    }

    @Test("readTextSnippet：切在多字节序列中间时裁掉残缺尾字节，不产出替换字符")
    func textSnippetHandlesSplitUTF8() async throws {
        let dir = try makeScratch("utf8")
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("g.txt")
        try write("观测台 🎉 ok", to: file)
        let full = "观测台 🎉 ok"

        // 首个字符「观」占 3 字节：maxBytes 1–2 连一个完整字符都凑不出来 ⇒ nil
        // （不返回半个字节序列，也不做 lossy 替换）。
        for limit in 1...2 {
            #expect(await FileSnapshotter().readTextSnippet(path: file.path, maxBytes: limit) == nil,
                    "maxBytes=\(limit) 不该产出内容")
        }

        // 从 3 起：任何上限都必须得到原串的合法前缀，且不含 U+FFFD。
        for limit in 3...(full.utf8.count + 3) {
            let snippet = await FileSnapshotter().readTextSnippet(path: file.path, maxBytes: limit)
            #expect(snippet != nil, "maxBytes=\(limit) 时应能解码出内容")
            if let snippet {
                #expect(full.hasPrefix(snippet), "maxBytes=\(limit) 得到非法前缀：\(snippet.debugDescription)")
                #expect(!snippet.unicodeScalars.contains("\u{FFFD}"), "maxBytes=\(limit) 出现了替换字符")
            }
        }
    }

    @Test("decodeUTF8TrimmingTail：完整序列直接解码，残缺尾巴最多裁 3 字节")
    func decodeTrimmingTail() {
        #expect(FileSnapshotter.decodeUTF8TrimmingTail(Data("abc".utf8)) == "abc")
        let bytes = Array("观测".utf8)              // 6 字节，两个 3 字节序列
        #expect(FileSnapshotter.decodeUTF8TrimmingTail(Data(bytes.prefix(3))) == "观")
        #expect(FileSnapshotter.decodeUTF8TrimmingTail(Data(bytes.prefix(4))) == "观")
        // 只有一个孤立 continuation 字节：裁到空也没意义 ⇒ nil（不猜字符）。
        #expect(FileSnapshotter.decodeUTF8TrimmingTail(Data([0xA0])) == nil)
        #expect(FileSnapshotter.decodeUTF8TrimmingTail(Data()) == "")
    }
}
