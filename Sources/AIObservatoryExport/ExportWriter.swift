//
//  ExportWriter.swift
//  AIObservatoryExport
//
//  Owner: WS-Export（子代理 E）
//
//  流式导出写入器 + 路径隐私策略。
//
//  设计要点：
//  1. 所有导出器（JSON / CSV / Markdown）只能通过本类型落盘：字节先累积到内部
//     `Data` 缓冲，攒满 `chunkThresholdBytes` 才 flush 一次，因此十万级记录也
//     **绝不会**先在内存里拼出「整篇文档」这样的大 String / 大 Data。
//  2. `write(_ text: String)` 等价于 `write(Data(text.utf8))`：整段字符串先编码成
//     UTF-8 字节再进缓冲，flush 时按字节切片，多字节字符（中文 / emoji）不会被切断，
//     落盘字节流拼回来仍是合法 UTF-8。
//  3. 隐私铁律：file sink 在创建任何文件**之前**必须先过 `ExportPathPolicy.validate`；
//     校验不通过就抛错，且不留下半个文件。
//  4. 本文件不读墙钟（无 `Date()` / `ProcessInfo.systemUptime`），写入内容完全由调用方决定。
//

import Foundation

// MARK: - 路径隐私策略

/// 导出落盘的路径隐私策略：「允许写到哪里」的唯一判定入口。
///
/// 判定顺序（错误尽量具体，便于 UI 给出可执行的修正建议）：
/// 1. 未展开的 `~` / `~/…` → ``ExportError/pathForbidden(_:)``
///    （`FileManager` 不会替你展开波浪号，真去创建就会落出一个名为 `~` 的目录）；
/// 2. 系统 / 只读目录（`/`、`/System`、`/usr`、`/bin`、`/sbin`、`/etc`、`/var`、
///    `/private`、`/Applications`、家目录本身）→ ``ExportError/pathForbidden(_:)``；
/// 3. 目标与每个 `allowedRoots` 都做 `standardizedFileURL` + 符号链接解析，
///    目标必须等于某个根或落在其内部，否则
///    ``ExportError/pathOutsideAllowedRoots(path:roots:)``；
///    `allowedRoots` 为空视为「不允许任何写入」，同样抛越界错误。
public enum ExportPathPolicy {

    /// 禁止写入的系统目录前缀。等于该前缀、或位于其内部都算命中。
    ///
    /// 有意不含 `/`（根目录单独判定，否则任何绝对路径都会被误伤）。
    /// `/tmp` 之类不需要列出：它是 `/private/tmp` 的符号链接，
    /// 第 3 步解析符号链接后会命中 `/private`。
    private static let forbiddenPrefixes: [String] = [
        "/System", "/usr", "/bin", "/sbin", "/etc", "/var", "/private", "/Applications",
    ]

    /// 校验目标文件路径是否允许写入。
    ///
    /// - Parameters:
    ///   - fileURL: 目标文件 URL（不必已存在）。
    ///   - allowedRoots: 允许写入的根目录集合；为空表示不允许任何写入。
    /// - Throws: ``ExportError/pathForbidden(_:)`` 或
    ///   ``ExportError/pathOutsideAllowedRoots(path:roots:)``。
    public static func validate(fileURL: URL, allowedRoots: [URL]) throws {
        let rawPath = fileURL.path

        // 2. 未展开的波浪号。
        if hasUnexpandedTilde(rawPath) {
            throw ExportError.pathForbidden(rawPath)
        }

        // 3. 家目录根。`URL(fileURLWithPath: "~/x")` 会被 Foundation 提前展开成 `/Users/<用户名>/x`，
        //    到这一步唯一可辨识的线索是「父目录 == 家目录」。散落在家目录根的导出文件一律禁写，
        //    这才是「绝不写 ~」这条隐私铁律的真正落点（`~` 本身已由 isForbiddenSystemPath 覆盖）。
        let rawParent = normalize((rawPath as NSString).deletingLastPathComponent)
        if homeDirectoryPaths().contains(rawParent) {
            throw ExportError.pathForbidden(rawPath)
        }

        // 4. 危险系统路径（按字面路径判定）。
        if isForbiddenSystemPath(rawPath) {
            throw ExportError.pathForbidden(rawPath)
        }

        // 5. 必须落在允许根内。先规范化两侧，再比较。
        let roots = allowedRoots.map { canonicalPath(of: $0) }
        guard roots.isEmpty == false else {
            throw ExportError.pathOutsideAllowedRoots(path: rawPath, roots: [])
        }

        let target = canonicalPath(of: fileURL)
        // 解析符号链接之后再查一次系统路径：`/etc` → `/private/etc`、`/tmp` → `/private/tmp`。
        if isForbiddenSystemPath(target) {
            throw ExportError.pathForbidden(target)
        }

        for root in roots where root.isEmpty == false {
            if target == root { return }
            let prefix = root.hasSuffix("/") ? root : root + "/"
            if target.hasPrefix(prefix) { return }
        }
        throw ExportError.pathOutsideAllowedRoots(path: rawPath, roots: roots)
    }

    /// 是否为禁止写入的系统路径。
    ///
    /// 判定使用「等于该前缀 或 以 `前缀/` 开头」，因此 `/System`、`/System/Library/x.csv`
    /// 命中，而 `/Systematic/a.csv`、`/usrshare/x` 这类同前缀字符串不被误伤。
    /// 家目录只禁**本身**（其内部是否可写交给 `allowedRoots` 决定）。
    /// 未展开的 `~/…` 由 ``validate(fileURL:allowedRoots:)`` 负责，不在本方法语义内。
    public static func isForbiddenSystemPath(_ path: String) -> Bool {
        let target = normalize(path)
        if target.isEmpty { return true }   // 空串不是合法导出目标
        if target == "/" { return true }
        for prefix in forbiddenPrefixes where target == prefix || target.hasPrefix(prefix + "/") {
            return true
        }
        for home in homeDirectoryPaths() where target == home {
            return true
        }
        return false
    }

    /// 波浪号未展开的形式：`~`、`~/x`、`~user/x`。
    ///
    /// `URL(fileURLWithPath: "~/out.csv")` 会把它变成普通目录名 `/~/out.csv`，
    /// 因此这里只看「第一个路径组件」是否以 `~` 开头。
    private static func hasUnexpandedTilde(_ path: String) -> Bool {
        var rest = Substring(path)
        while rest.hasPrefix("/") { rest = rest.dropFirst() }
        guard rest.isEmpty == false else { return false }
        return rest.prefix { $0 != "/" }.hasPrefix("~")
    }

    /// 去掉多余尾部斜杠，得到可比较的规范字符串（`"/"` 与 `""` 保持原样）。
    private static func normalize(_ path: String) -> String {
        var result = path
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// 规范化绝对路径。
    ///
    /// 注意 `URL.resolvingSymlinksInPath()` 对「末段尚不存在」的路径只做词法规范化，
    /// **不会**解析中间已存在的符号链接（实测），因此这里逐级向上找到第一个以某种形式
    /// 存在的祖先单独解析，再拼回未创建的组件。否则「在允许根内放一个指向外部的软链」
    /// 就能绕过隐私铁律。
    private static func canonicalPath(of url: URL) -> String {
        let manager = FileManager.default
        var pending: [String] = []
        var cursor = url.standardizedFileURL
        while existsInSomeForm(cursor, manager) == false {
            let component = cursor.lastPathComponent
            let parent = cursor.deletingLastPathComponent()
            if component.isEmpty || parent.path == cursor.path { break }
            pending.insert(component, at: 0)
            cursor = parent
        }
        let resolved = normalize(cursor.standardizedFileURL.resolvingSymlinksInPath().path)
        var result = resolved
        for component in pending {
            result = result.hasSuffix("/") ? result + component : result + "/" + component
        }
        return normalize(result)
    }

    /// 「以某种形式存在」：普通文件 / 目录，或（即使指向不存在目标的）符号链接。
    private static func existsInSomeForm(_ url: URL, _ manager: FileManager) -> Bool {
        if manager.fileExists(atPath: url.path) { return true }
        let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey])
        return values?.isSymbolicLink == true
    }

    /// 家目录的两种来源（`FileManager` 与 `NSHomeDirectory()`），去重后返回规范路径。
    private static func homeDirectoryPaths() -> [String] {
        var paths: [String] = []
        let fromFileManager = normalize(FileManager.default.homeDirectoryForCurrentUser.path)
        if fromFileManager.isEmpty == false { paths.append(fromFileManager) }
        let fromNSHome = normalize(NSHomeDirectory())
        if fromNSHome.isEmpty == false && paths.contains(fromNSHome) == false {
            paths.append(fromNSHome)
        }
        return paths
    }
}

// MARK: - 流式写入器

/// 流式导出写入器：缓冲 + 阈值 flush，绝不在内存里拼完整文档。
///
/// 导出器侧用法：
/// ```swift
/// var writer = try ExportWriter.file(url, allowedRoots: roots)
/// try writer.write(header)
/// for row in rows { try writer.write(row) }   // 逐条写，缓冲满阈值才落盘
/// try writer.finish()                          // flush 尾部残余并关闭句柄
/// ```
///
/// - Note: 内部持有 `FileHandle`，只能由创建者以 `inout` 方式顺序使用，
///   因此本类型不声明 `Sendable`。
public struct ExportWriter {

    /// 落盘目标。
    public enum Sink {
        /// 写入文件；`allowedRoots` 是创建时使用的允许根（用于诊断），创建前已通过校验。
        case file(URL, allowedRoots: [URL])
        /// 写入内存（测试与小文档）；同样按阈值分块，以便验证「确实分块」的行为。
        case memory
    }

    private let sink: Sink
    private let thresholdBytes: Int
    private let destination: URL?
    private var handle: FileHandle?
    private var buffer = Data()
    private var collected = Data()
    private var flushedChunks = 0
    private var totalBytes = 0
    private var isFinished = false

    // MARK: 工厂

    /// 创建文件 sink：先做路径校验，再建父目录、创建（覆盖）文件、取写入句柄。
    ///
    /// 校验不通过时**不会**留下任何文件；这一步在任何磁盘操作之前。
    ///
    /// - Parameters:
    ///   - url: 目标文件 URL。
    ///   - allowedRoots: 允许写入的根目录集合，见 ``ExportPathPolicy/validate(fileURL:allowedRoots:)``。
    ///   - chunkThresholdBytes: 缓冲阈值；`<= 0` 时回退到
    ///     ``ExportConstants/defaultChunkThresholdBytes``。
    /// - Throws: ``ExportError/pathForbidden(_:)``、
    ///   ``ExportError/pathOutsideAllowedRoots(path:roots:)``、
    ///   ``ExportError/cannotCreateFile(path:reason:)``、
    ///   ``ExportError/cannotOpenFileHandle(path:)``。
    public static func file(
        _ url: URL,
        allowedRoots: [URL],
        chunkThresholdBytes: Int = ExportConstants.defaultChunkThresholdBytes
    ) throws -> ExportWriter {
        try ExportPathPolicy.validate(fileURL: url, allowedRoots: allowedRoots)

        let manager = FileManager.default
        let parent = url.deletingLastPathComponent()

        if manager.fileExists(atPath: parent.path) == false {
            do {
                try manager.createDirectory(at: parent, withIntermediateDirectories: true)
            } catch {
                throw ExportError.cannotCreateFile(
                    path: url.path,
                    reason: ExportCopy.reasonCreateParentDirectoryFailed.renderedNow(describeExportError(error))
                )
            }
        }

        // 覆盖语义：导出是「重写这份产物」，先删同名旧文件再建，保证从 0 字节开始。
        if manager.fileExists(atPath: url.path) {
            do {
                try manager.removeItem(at: url)
            } catch {
                throw ExportError.cannotCreateFile(
                    path: url.path,
                    reason: ExportCopy.reasonOverwriteExistingFailed.renderedNow(describeExportError(error))
                )
            }
        }

        if manager.createFile(atPath: url.path, contents: nil, attributes: nil) == false {
            throw ExportError.cannotCreateFile(
                path: url.path,
                reason: ExportCopy.reasonCreateFileReturnedFalse.text()
            )
        }

        // 取写入句柄。`FileHandle(forWritingTo:)` 是 throwing（且在部分 SDK 上可失败），
        // 用 `try?` 统一两种形态：拿不到句柄 → `.cannotOpenFileHandle`。
        guard let opened = try? FileHandle(forWritingTo: url) else {
            throw ExportError.cannotOpenFileHandle(path: url.path)
        }
        return ExportWriter(
            sink: .file(url, allowedRoots: allowedRoots),
            rawChunkThresholdBytes: chunkThresholdBytes,
            handle: opened
        )
    }
    /// 创建内存 sink：不落盘，`finish()` 之后用 ``collectedData()`` 取回全部字节。
    ///
    /// - Parameter chunkThresholdBytes: 缓冲阈值；`<= 0` 时回退到
    ///   ``ExportConstants/defaultChunkThresholdBytes``。
    public static func memory(
        chunkThresholdBytes: Int = ExportConstants.defaultChunkThresholdBytes
    ) -> ExportWriter {
        ExportWriter(sink: .memory, rawChunkThresholdBytes: chunkThresholdBytes, handle: nil)
    }

    // MARK: 状态

    /// 已 flush 的块数（每次攒满阈值 flush 计一块，`finish()` 的尾部残余也计一块）。
    public var chunkCount: Int { flushedChunks }

    /// 累计写入字节数（含尚未 flush 的缓冲部分）。
    public var bytesWritten: Int { totalBytes }

    /// 目标文件 URL；memory sink 为 `nil`。
    public var destinationURL: URL? { destination }

    // MARK: 写入

    /// 写入一段文本（UTF-8）。等价于 `write(Data(text.utf8))`，因此不会切断多字节字符。
    ///
    /// - Throws: ``ExportError/alreadyFinished(path:)``，或 flush 时的写入错误。
    public mutating func write(_ text: String) throws {
        try write(Data(text.utf8))
    }

    /// 写入一段字节：进缓冲，攒满阈值才 flush。
    ///
    /// - Throws: ``ExportError/alreadyFinished(path:)``，或 flush 时的
    ///   ``ExportError/writeFailed(path:bytes:reason:)`` /
    ///   ``ExportError/cannotOpenFileHandle(path:)``。
    public mutating func write(_ data: Data) throws {
        guard isFinished == false else {
            throw ExportError.alreadyFinished(path: finishPathDescription)
        }
        if data.isEmpty { return }
        buffer.append(data)
        totalBytes += data.count
        // 按阈值切片 flush：峰值内存不超过「一次 write 的量 + 一个阈值」。
        while buffer.count >= thresholdBytes {
            let chunk = Data(buffer.prefix(thresholdBytes))
            buffer.removeFirst(thresholdBytes)
            try emit(chunk)
            flushedChunks += 1
        }
    }

    /// flush 尾部残余并关闭句柄。幂等：第二次调用直接返回，不重复关闭。
    ///
    /// - Throws: flush 残余时的写入错误。
    public mutating func finish() throws {
        guard isFinished == false else { return }
        if buffer.isEmpty == false {
            let tail = Data(buffer)
            buffer = Data()
            try emit(tail)
            flushedChunks += 1
        }
        buffer = Data()
        isFinished = true

        let pending = handle
        handle = nil
        guard let pending else { return }
        do {
            try pending.close()
        } catch {
            throw ExportError.writeFailed(
                path: finishPathDescription,
                bytes: totalBytes,
                reason: ExportCopy.reasonCloseHandleFailed.renderedNow(describeExportError(error))
            )
        }
    }

    /// 取回内存 sink 已收集的全部字节（含尚未 flush 的缓冲）。
    ///
    /// - Throws: 在 file sink 上调用 → ``ExportError/invalidRequest(_:)``。
    public func collectedData() throws -> Data {
        guard case .memory = sink else {
            throw ExportError.invalidRequest(ExportCopy.reasonCollectedDataMemoryOnly.text())
        }
        guard buffer.isEmpty == false else { return collected }
        var result = collected
        result.append(buffer)
        return result
    }

    // MARK: 内部

    /// 唯一入口：所有字段在此收敛，阈值非法时回退默认值（不得崩）。
    private init(sink: Sink, rawChunkThresholdBytes: Int, handle: FileHandle?) {
        self.sink = sink
        self.thresholdBytes = rawChunkThresholdBytes > 0
            ? rawChunkThresholdBytes
            : ExportConstants.defaultChunkThresholdBytes
        self.handle = handle
        switch sink {
        case let .file(url, _): self.destination = url
        case .memory: self.destination = nil
        }
    }

    /// 落一块：file sink 走 `FileHandle`，memory sink 追加进总 `Data`。
    ///
    /// `FileHandle.write(_:)`（ObjC `writeData:`）在本 SDK 已被标记
    /// `API_DEPRECATED_WITH_REPLACEMENT("writeData:error:")`，且失败时抛的是
    /// Objective-C 异常而非 Swift 错误；因此使用其 Swift 精炼版
    /// `write(contentsOf:) throws`，并用 `do/catch` 把底层错误原样转成
    /// ``ExportError/writeFailed(path:bytes:reason:)`` —— 不吞异常。
    private mutating func emit(_ chunk: Data) throws {
        switch sink {
        case let .file(url, _):
            guard let handle else {
                throw ExportError.cannotOpenFileHandle(path: url.path)
            }
            do {
                try handle.write(contentsOf: chunk)
            } catch {
                throw ExportError.writeFailed(
                    path: url.path,
                    bytes: chunk.count,
                    reason: describeExportError(error)
                )
            }
        case .memory:
            collected.append(chunk)
        }
    }

    /// 诊断用的路径描述。
    private var finishPathDescription: String { destination?.path ?? "memory sink" }
}

/// 把底层 `Error` 转成简短可读的原因片段，供 `writeFailed` / `cannotCreateFile` 携带。
private func describeExportError(_ error: Error) -> String {
    let localized = error.localizedDescription
    return localized.isEmpty ? String(describing: error) : localized
}
