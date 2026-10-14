//
//  FileSnapshotter.swift
//  AIObservatoryPlatform — FileSystem 子模块
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  实现 FileSnapshotting：内容哈希（CryptoKit SHA-256）、行数、大小；
//  大文件（> 8 MB）不全量哈希，改用「首尾各 256 KB + 大小」快速指纹；
//  二进制探测：读前 4 KB，含 NUL 字节即判定二进制。
//  所有磁盘 IO 在后台（Task.detached）执行，绝不阻塞主线程。
//
//  两条硬约束（本次修复引入）：
//  1) 读不到 = 返回 nil（契约允许 nil），绝不返回 contentHash == "" 之类的伪造快照；
//  2) 单个文件从打开到读完只经历 1 次 open：二进制探测 → 哈希/指纹 → 行数，
//     全部复用同一 FileHandle，按需读取，不做重复 open。
//

import Foundation
import CryptoKit
import AIObservatoryCore

/// 对文件做内容快照与文本片段读取，供 Before/After Diff 使用。
///
/// 语义要点：
/// - **只存派生信息**：`FileSnapshot` 仅含 SHA-256 十六进制串、大小、行数、时间戳；
///   明文只在一次调用的栈内短暂存在（分块 ≤ 64 KB），不留缓存（隐私铁律 §7）。
///   唯一返回内容的 API 是 `readTextSnippet(path:maxBytes:)`，且严格受 `maxBytes` 限制。
/// - **失败即 nil**：路径不存在、是目录、权限不足、读不满声明的字节数 —— 一律返回 `nil`，
///   不产出「空哈希」占位值。
/// - **快速指纹故意不敏感**：`sizeBytes > largeFileThresholdBytes` 时只对
///   「首尾各 `fingerprintSampleBytes` + 文件大小」取哈希，因此**仅改动中间字节时哈希不变**。
///   这是设计取舍（避免为几十 MB 的产物做全量哈希），不是缺陷。
/// - **`lineCount == 0` 有三种含义**：空文件；二进制（故意不统计）；
///   超过 `lineCountScanLimitBytes` 的超大文本（未统计）。三者都可用 `sizeBytes` 区分。
/// - 行数定义：`\n` 的个数，末字节非 `\n` 时再 +1（故 `"a\nb"` 为 2 行）。
public struct FileSnapshotter: FileSnapshotting {

    /// 超过此大小（字节）视为大文件，改用快速指纹而非全量 SHA-256。
    public let largeFileThresholdBytes: UInt64

    /// 大文件快速指纹时，从头部/尾部各读取的字节数。
    public let fingerprintSampleBytes: UInt64

    /// 二进制探测时读取的头部字节数。
    public let binaryProbeBytes: Int

    /// 行数统计的扫描上限（字节）：更大的文本文件不做行数统计（`lineCount` 记 0）。
    public let lineCountScanLimitBytes: UInt64

    /// 流式读取的分块大小（同时决定栈内明文的最大驻留量）。
    private let chunkBytes: Int

    /// 创建快照器。
    /// - Parameters:
    ///   - largeFileThresholdBytes: 大文件阈值，默认 8 MB。
    ///   - fingerprintSampleBytes: 大文件指纹采样字节数，默认 256 KB。
    ///   - binaryProbeBytes: 二进制探测读取字节数，默认 4 KB。
    ///   - lineCountScanLimitBytes: 行数扫描上限，默认 64 MB。
    public init(
        largeFileThresholdBytes: UInt64 = 8 * 1024 * 1024,
        fingerprintSampleBytes: UInt64 = 256 * 1024,
        binaryProbeBytes: Int = 4096,
        lineCountScanLimitBytes: UInt64 = 64 * 1024 * 1024
    ) {
        self.largeFileThresholdBytes = largeFileThresholdBytes
        self.fingerprintSampleBytes = max(fingerprintSampleBytes, 1)
        self.binaryProbeBytes = max(binaryProbeBytes, 0)
        self.lineCountScanLimitBytes = lineCountScanLimitBytes
        self.chunkBytes = max(binaryProbeBytes, 65_536)
    }

    // MARK: - 公共 API（全部在后台线程做 IO）

    /// 对指定路径做内容快照（哈希 + 行数 + 大小）。
    ///
    /// 返回 `nil` 的情况：路径不存在 / 无权限 / 是目录 / 读取失败或读不满
    /// （包括「属性里的大小」与实际可读到字节数不一致，即并发截断）。
    public func snapshot(path: String) async -> FileSnapshot? {
        await Task.detached(priority: .utility) { [self] in
            snapshotBlocking(path: path)
        }.value
    }

    /// 读取文件开头最多 `maxBytes` 字节，以 UTF-8 严格解码为文本片段（用于 diff 预览）。
    ///
    /// 若切在 UTF-8 多字节序列中间，从尾部最多裁掉 3 个字节后重试；仍失败则返回 `nil`
    /// —— 不使用 lossy 替换，避免伪造出不存在的字符。
    public func readTextSnippet(path: String, maxBytes: Int) async -> String? {
        await Task.detached(priority: .utility) { [self] in
            readTextSnippetBlocking(path: path, maxBytes: maxBytes)
        }.value
    }

    /// 探测文件是否为二进制：读前 `binaryProbeBytes` 字节，含 NUL 即判为二进制。
    ///
    /// 打不开文件或空文件返回 `false`（无法证明其为二进制）；调用方据此再决定是否取文本片段。
    public func isBinaryFile(path: String) async -> Bool {
        await Task.detached(priority: .utility) { [self] in
            guard let handle = openForReading(path) else { return false }
            defer { try? handle.close() }
            return readProbe(handle, size: nil).contains(0)
        }.value
    }

    // MARK: - 后台阻塞实现

    /// 一次打开完成「探测 → 哈希/指纹 → 行数」的全部工作。
    private func snapshotBlocking(path: String) -> FileSnapshot? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        // 目录不是「内容」：FileSnapshot 描述的是字节内容，目录一律不给快照。
        if isDirectory(attrs) { return nil }
        guard let size = (attrs[.size] as? NSNumber)?.uint64Value else { return nil }

        guard let handle = openForReading(path) else { return nil }
        defer { try? handle.close() }

        // 1) 二进制探测：整条流程的第一次读，后续复用同一句柄与这段字节。
        let probe = readProbe(handle, size: size)
        if size > 0 && probe.isEmpty { return nil }           // 声称非空却一个字节都读不到
        let isBinary = probe.contains(0)

        // 2) 决定这次要不要顺带把行数扫出来（二进制不扫；超过扫描上限的文本不扫）。
        let fingerprintMode = size > largeFileThresholdBytes
        let scanLines = !isBinary && size <= lineCountScanLimitBytes

        var hasher = SHA256()
        var newlines = 0
        var lastByte: UInt8?
        if scanLines {
            newlines = Self.countNewlines(in: probe)
            lastByte = probe.last
        }
        // 纯指纹模式只需头部采样；其余情况一路读到文件末尾。
        let headSample = Data(fingerprintMode ? probe.prefix(Int(clamping: fingerprintSampleBytes)) : probe)
        if !fingerprintMode { hasher.update(data: probe) }

        var read = probe.count
        let headTarget = Int(clamping: fingerprintSampleBytes)
        var sample = headSample

        while UInt64(read) < size {
            // 只取指纹且不扫行数时，采够头部样本即可收工（省下整文件 IO）。
            if fingerprintMode && !scanLines && sample.count >= headTarget { break }
            let remaining = Int(clamping: size - UInt64(read))
            let want = min(fingerprintMode && !scanLines ? max(0, headTarget - sample.count) : chunkBytes, remaining)
            if want <= 0 { break }
            let chunk = handle.readData(ofLength: want)
            if chunk.count < want { return nil }               // 读不满 = 失败或并发截断：不伪造
            read += chunk.count
            if !fingerprintMode { hasher.update(data: chunk) }
            if fingerprintMode && sample.count < headTarget {
                sample.append(chunk.prefix(headTarget - sample.count))
            }
            if scanLines {
                newlines += Self.countNewlines(in: chunk)
                lastByte = chunk.last
            }
        }

        // 3) 定稿哈希：大文件走「大小 + 首尾采样」，普通文件走全量 SHA-256。
        let hash: String
        if fingerprintMode {
            var tail = Data()
            if size > fingerprintSampleBytes * 2 {
                let offset = size - fingerprintSampleBytes
                handle.seek(toFileOffset: offset)
                guard handle.offsetInFile == offset else { return nil }
                let want = Int(clamping: fingerprintSampleBytes)
                tail = handle.readData(ofLength: want)
                if tail.count < want { return nil }
            }
            if sample.isEmpty && tail.isEmpty { return nil }   // 头尾都拿不到 → 不给假指纹
            hasher.update(data: sample)
            hasher.update(data: tail)
            hash = "fp:\(size):" + Self.hex(hasher.finalize())
        } else {
            hash = Self.hex(hasher.finalize())
        }

        let lineCount = scanLines ? newlines + ((lastByte != nil && lastByte != Self.newline) ? 1 : 0) : 0
        return FileSnapshot(path: path, contentHash: hash, sizeBytes: size, lineCount: lineCount)
    }

    /// 读取文本片段（后台实现）。
    private func readTextSnippetBlocking(path: String, maxBytes: Int) -> String? {
        guard maxBytes > 0 else { return nil }
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return nil }
        if isDirectory(attrs) { return nil }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        guard let handle = openForReading(path) else { return nil }
        defer { try? handle.close() }

        let data = handle.readData(ofLength: min(maxBytes, Int(clamping: size)))
        if data.isEmpty { return size == 0 ? "" : nil }        // 非空文件却读不到 → 失败，不给空串
        return Self.decodeUTF8TrimmingTail(data)
    }

    // MARK: - 小工具

    private static let newline: UInt8 = 0x0A

    /// 只打开一次句柄；失败返回 nil。
    private func openForReading(_ path: String) -> FileHandle? {
        try? FileHandle(forReadingFrom: URL(fileURLWithPath: path))
    }

    /// 读文件头部探测字节（用于二进制判定）。`size` 为已知大小时用于避免越界读。
    private func readProbe(_ handle: FileHandle, size: UInt64?) -> Data {
        let want = binaryProbeBytes
        if want <= 0 { return Data() }
        guard let size else { return handle.readData(ofLength: want) }
        let capped = min(want, Int(clamping: size))
        return capped <= 0 ? Data() : handle.readData(ofLength: capped)
    }

    private func isDirectory(_ attrs: [FileAttributeKey: Any]) -> Bool {
        (attrs[.type] as? FileAttributeType) == FileAttributeType.typeDirectory
    }

    private static func countNewlines(in data: Data) -> Int {
        data.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
    }

    /// 严格 UTF-8 解码，失败时从尾部最多裁掉 3 个字节（UTF-8 序列最长 4 字节）再试。
    static func decodeUTF8TrimmingTail(_ data: Data) -> String? {
        if let exact = String(data: data, encoding: .utf8) { return exact }
        var trim = 1
        while trim <= 3 && data.count > trim {
            if let trimmed = String(data: Data(data.dropLast(trim)), encoding: .utf8) { return trimmed }
            trim += 1
        }
        return nil
    }

    /// 摘要转小写十六进制。
    ///
    /// 用 `map` 而不是 `compactMap`：`String(format: "%02x", 0)` 返回 `"00"`，
    /// `compactMap` 会把 0 字节当成「可选值缺失」而静默丢掉，导致哈希长度不定。
    private static func hex<D: Digest>(_ digest: D) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
