//
//  HookJSONLReader.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-CmdSrc
//  ─────────────────────────────────────────────────────────
//  `<storeDirectory>/agent-hooks/*.jsonl` 的字节级增量读取。
//
//  本类型**不持有状态**：偏移与 inode 的持久化由 `HookCommandAuditing` 负责，
//  因为「读到哪一字节」和「哪些事件已经见过」必须落在同一份旁挂 json 里，
//  分两处写就会出现「偏移前进了、键集还没存」的错开窗口。
//
//  三条硬口径：
//  1. 只读该目录下的普通 `.jsonl` 文件，不递归、不跟符号目录、不读 AiX 之外的路径。
//  2. 结尾不完整的半行不消耗偏移——半条命令既不能入库，也不能被永久跳过。
//  3. 每文件每轮最多读 `maxBytesPerPass`，离线攒出来的大文件分多轮补采，不卡住采集循环。
//

import Foundation
import Darwin

/// `stat` 既是结构体名又是函数名，起个别名避开同名歧义。
private typealias FileStat = stat

/// 单文件增量读取器（无状态）。
struct HookJSONLReader: Sendable {

    /// 一轮读取的结果。
    struct Chunk: Sendable {
        /// 完整行（已去掉行尾 `\r`，空白行不纳入）。
        var lines: [String] = []
        /// 下一轮该从哪个字节开始。
        var nextOffset: Int = 0
        /// 当前 inode；换了文件（轮转/被覆盖）时用于判定要回到 0。
        var inode: UInt64?
        /// 超过 `maxLineBytes` 而被丢掉的行数。
        var oversizedLineCount: Int = 0
        /// 因截断 / inode 变化而从文件头重读。
        var restartedFromZero: Bool = false
    }

    /// 单行字节上限：超过即认定不是给观测站用的行，丢弃并计数，避免整轮被撑爆。
    var maxLineBytes: Int
    /// 单文件单轮读取上限：限制采集循环里一次同步 IO 的最坏耗时。
    var maxBytesPerPass: Int

    init(maxLineBytes: Int = 256 * 1024, maxBytesPerPass: Int = 1024 * 1024) {
        self.maxLineBytes = max(maxLineBytes, 1)
        self.maxBytesPerPass = max(maxBytesPerPass, 1)
    }

    /// 目录下的 hook 文件，按名字排序（结果稳定，便于排查）。目录不存在返回空。
    ///
    /// 隐私边界在这里落地：只认「解掉符号链接之后仍然落在该目录内」的普通文件。
    /// 有人往 `agent-hooks/` 里放一个指向 `~/.claude` 的软链接，观测站也不会去读它——
    /// 读 AiX 之外的路径就是越界，不因「链接是用户自己放的」而放宽。
    static func hookFiles(in directory: URL) -> [URL] {
        let root = directory.standardizedFileURL.resolvingSymlinksInPath().path
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        )) ?? []
        let prefix = root + "/"
        return entries
            .filter { $0.pathExtension.lowercased() == "jsonl" }
            .filter { url in
                let values = try? url.resourceValues(forKeys: [.isRegularFileKey])
                return values?.isRegularFile == true
            }
            .filter { url in
                let resolved: URL = url.resolvingSymlinksInPath()
                let path: String = resolved.standardizedFileURL.path
                return path.hasPrefix(prefix)
            }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// 从 `startOffset` 读到最后一个换行边界（不超过 `maxBytesPerPass` 字节）。
    ///
    /// - Parameter expectedInode: 上次记录的那个文件的 inode。变了说明同名文件被换掉，
    ///   旧偏移没有意义，回到 0 重读。
    func read(url: URL, startOffset: Int, expectedInode: UInt64?) -> Chunk {
        guard let attributes = Self.fileInfo(url.path) else {
            return Chunk(nextOffset: startOffset)
        }
        let inode = attributes.st_ino
        let size = Int(attributes.st_size)

        // 文件被换过或被截断：旧偏移落在不存在的位置上，只能从头再来。
        var offset = startOffset
        var restarted = false
        if inode != expectedInode || offset > size {
            offset = 0
            restarted = true
        } else if offset > 0, Self.byte(at: url.path, index: offset - 1) != UInt8(ascii: "\n") {
            // 同 inode 就地截断（`logrotate copytruncate`、手工清空后重写）时 size 可能仍大于旧偏移，
            // 光看长度看不出来。旧偏移前一个字节必须是换行，否则说明文件内容已经换了一批。
            offset = 0
            restarted = true
        }
        guard size > offset else { return Chunk(nextOffset: offset, inode: inode, restartedFromZero: restarted) }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return Chunk(nextOffset: startOffset, inode: inode)
        }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(offset))) != nil,
              let data = (try? handle.read(upToCount: maxBytesPerPass)) ?? nil, !data.isEmpty else {
            return Chunk(nextOffset: offset, inode: inode, restartedFromZero: restarted)
        }

        var lines: [String] = []
        var oversized = 0
        var lineStart = data.startIndex
        var index = data.startIndex
        while index < data.endIndex {
            if data[index] == UInt8(ascii: "\n") {
                let length = index - lineStart
                if length > maxLineBytes {
                    oversized += 1
                } else if length > 0 {
                    let segment = Data(data[lineStart..<index])
                    // 非 UTF-8 字节按替换字符解码：坏行随后会在 JSON 解析处被计成 malformed，不静默吞掉。
                    var text = String(decoding: segment, as: UTF8.self)
                    if text.hasSuffix("\r") { text.removeLast() }
                    if !text.trimmingCharacters(in: .whitespaces).isEmpty { lines.append(text) }
                }
                lineStart = data.index(after: index)
            }
            index = data.index(after: index)
        }

        var nextOffset = offset + (lineStart - data.startIndex)
        if nextOffset == offset && data.count >= maxLineBytes {
            // 一整窗口都没换行：这行注定超上限，跳过去，否则该文件永久读不动。
            nextOffset = offset + data.count
            oversized += 1
        }
        return Chunk(
            lines: lines,
            nextOffset: nextOffset,
            inode: inode,
            oversizedLineCount: oversized,
            restartedFromZero: restarted
        )
    }

    /// `lstat(2)` 一次拿 inode + size。用 lstat 而非 stat：不跟随符号链接，
    /// 链接目标由 `hookFiles(in:)` 的边界检查决定读不读。文件消失或没权限时返回 nil。
    private static func fileInfo(_ path: String) -> FileStat? {
        var info = FileStat()
        guard Darwin.lstat(path, &info) == 0 else { return nil }
        return info
    }

    /// 读单个字节（偏移 sanity check 用）。读不到返回 nil，按「不合法」处理。
    private static func byte(at path: String, index: Int) -> UInt8? {
        guard index >= 0, let handle = try? FileHandle(forReadingFrom: URL(fileURLWithPath: path)) else { return nil }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: UInt64(index))) != nil,
              let data = (try? handle.read(upToCount: 1)) ?? nil,
              let first = data.first else { return nil }
        return first
    }
}
