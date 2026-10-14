//
//  CSVExporterTests.swift
//  AIObservatoryExportTests
//
//  Owner: WS-Export（子代理 B）
//
//  CSVExporter 的验收测试。样本全部自建（AIObservatoryCore 模型 init），
//  断言走**往返解析**而不是手改期望串：`ExportCSVTestParser` 是本文件内的最小 RFC 4180 解析器
//  （按 UTF-8 字节扫描，支持引号包裹、`""` 转义、字段内 `\r\n` 与 `\n`）。
//  时间一律注入固定 `generatedAt`；不读墙钟、不 sleep、不起线程。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
import AIObservatoryExport

// MARK: - 样本工厂

/// CSV 测试样本：确定性（固定 UUID 串 + 固定时间基线）。
private enum CSVFixtures {
    /// 固定基线时间：所有记录时间都由它推导，测试与运行时刻无关。
    static let baseline = Date(timeIntervalSince1970: 1_800_000_000)
    /// 请求注入时间（决定 duration 列与文件名时间戳）。
    static let generatedAt = Date(timeIntervalSince1970: 1_800_000_000 + 3_600)

    /// 写盘用例的临时目录根：当前检出自带的 `.scratch-tests/`，允许根为其父目录。
    static let scratchRoot = Scratch.root
    static let scratchBase = scratchRoot
        .appendingPathComponent("export", isDirectory: true)
        .appendingPathComponent("csv", isDirectory: true)

    /// 理论不可达的回退值（避免强解包 / `try!`）：全零 uuid_t，16 个 UInt8。
    static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                      0, 0, 0, 0, 0, 0, 0, 0))

    /// 由下标生成稳定 UUID：`00000007-0000-0000-0000-000000000007`。
    static func uuid(index: Int) -> UUID {
        // %X 必须配 UInt32（Swift 的 Int 直接给 CVarArg 是 64 位，会串位）。
        let value = UInt32(truncatingIfNeeded: index)
        let hex = String(format: "%08X-0000-0000-0000-%012X", value, value)
        return UUID(uuidString: hex) ?? zeroUUID
    }

    /// 一条时间线事件。
    static func event(index: Int, title: String = "读取文件", command: String? = nil,
                      summary: String = "普通摘要") -> ExportRecord {
        .event(TimelineEvent(
            id: uuid(index: index),
            timestamp: baseline.addingTimeInterval(Double(index)),
            sessionID: uuid(index: 900_000),
            agentKind: .claudeCode,
            kind: .fileRead,
            title: title,
            summary: summary,
            filePath: FixturePaths.inProjectRoot("Sources/App.swift"),
            command: command,
            exitCode: 0,
            durationSeconds: 1.5,
            cost: ResourceCost(cpuSeconds: 0.25, memoryBytes: 1_024, bytesRead: 2_048, bytesWritten: 0),
            riskLevel: .low,
            projectPath: FixturePaths.projectRoot
        ))
    }

    /// 一条命令记录。
    static func command(index: Int, line: String = "ls -la") -> ExportRecord {
        let pieces = line.split(separator: " ").map(String.init)
        return .command(CommandRecord(
            id: uuid(index: index),
            executable: pieces.first ?? "ls",
            arguments: Array(pieces.dropFirst()),
            workingDirectory: FixturePaths.projectRoot,
            sessionID: uuid(index: 900_000),
            agentKind: .genericCLIAgent,
            startedAt: baseline.addingTimeInterval(Double(index)),
            endedAt: baseline.addingTimeInterval(Double(index) + 0.5),
            exitCode: 0,
            outcome: .success,
            isDestructive: false,
            requiresConfirmation: false,
            riskLevel: .medium,
            projectPath: FixturePaths.projectRoot
        ))
    }

    /// `count` 条时间线事件（时间升序，`filtered` 的排序不会改变顺序）。
    static func events(_ count: Int) -> [ExportRecord] {
        (0..<count).map { event(index: $0, title: "事件 \($0)") }
    }

    /// 一个 CSV 导出请求。
    static func request(kind: ExportKind, selected: [String]? = nil, bom: Bool = false,
                        limit: Int? = nil) -> ExportRequest {
        ExportRequest(
            format: .csv,
            kinds: [kind],
            selectedFieldNames: selected,
            dateRange: .unbounded,
            maximumRecordsPerKind: limit,
            generatedAt: generatedAt,
            redactionEnabled: true,
            csvIncludesByteOrderMark: bom,
            destination: ExportDestination(directory: scratchBase, allowedRoots: [scratchRoot])
        )
    }

    /// 非重叠计数（用于「BOM 只出现一次」）。
    static func countOccurrences(of sequence: [UInt8], in data: Data) -> Int {
        let bytes = Array(data)
        guard !sequence.isEmpty, bytes.count >= sequence.count else { return 0 }
        var count = 0
        var index = 0
        while index + sequence.count <= bytes.count {
            if Array(bytes[index..<(index + sequence.count)]) == sequence {
                count += 1
                index += sequence.count
            } else {
                index += 1
            }
        }
        return count
    }
}

// MARK: - 最小 RFC 4180 解析器（测试专用）

/// 手写最小 CSV 解析器：按 UTF-8 字节扫描，支持引号包裹、`""` 转义、字段内 `\r\n` 与 `\n`，
/// 并忽略开头 BOM；尾部行尾符不产生幻影行。同时暴露行尾体检信息。
struct ExportCSVTestParser {
    /// 一次解析的全部结果。
    struct Document {
        /// 行 × 列的解码值。
        var rows: [[String]]
        /// 与 `rows` 一一对应的行尾符字节；空数组表示文档结尾缺行尾符。
        var terminators: [[UInt8]]
        /// 文档是否以行尾符结束（含最后一行）。
        var endsWithLineTerminator: Bool
    }

    private static let comma: UInt8 = 0x2C
    private static let quote: UInt8 = 0x22
    private static let carriageReturn: UInt8 = 0x0D
    private static let lineFeed: UInt8 = 0x0A
    private static let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]

    /// 解析为「行 × 列」。
    static func parse(_ data: Data) -> [[String]] {
        parseDocument(data).rows
    }

    /// 解析字符串（同样忽略开头 BOM）。
    static func parse(_ text: String) -> [[String]] {
        parseDocument(Data(text.utf8)).rows
    }

    /// 完整解析：附每行的行尾符字节，供「行尾必须是 CRLF」类断言使用。
    static func parseDocument(_ data: Data) -> Document {
        var bytes = Array(data)
        if bytes.count >= bomBytes.count, Array(bytes[0..<bomBytes.count]) == bomBytes {
            bytes.removeFirst(bomBytes.count)
        }

        var rows: [[String]] = []
        var terminators: [[UInt8]] = []
        var row: [String] = []
        var field: [UInt8] = []
        var insideQuotes = false
        var index = 0

        func endField() {
            row.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }

        func endRow(_ terminator: [UInt8]) {
            endField()
            rows.append(row)
            row.removeAll(keepingCapacity: true)
            terminators.append(terminator)
        }

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if insideQuotes {
                if byte == quote {
                    if index < bytes.count, bytes[index] == quote {
                        field.append(quote)          // "" → 一个字面引号
                        index += 1
                    } else {
                        insideQuotes = false
                    }
                } else {
                    field.append(byte)               // 引号内的 CR/LF/逗号都是内容
                }
                continue
            }
            if byte == quote {
                insideQuotes = true
            } else if byte == comma {
                endField()
            } else if byte == carriageReturn {
                var terminator: [UInt8] = [carriageReturn]
                if index < bytes.count, bytes[index] == lineFeed {
                    terminator.append(lineFeed)
                    index += 1
                }
                endRow(terminator)
            } else if byte == lineFeed {
                endRow([lineFeed])
            } else {
                field.append(byte)
            }
        }
        if !field.isEmpty || !row.isEmpty { endRow([]) }

        let lastTerminator = terminators.last ?? []
        return Document(rows: rows, terminators: terminators,
                        endsWithLineTerminator: rows.isEmpty == false && lastTerminator.isEmpty == false)
    }

    /// 行尾体检：返回「引号外、且前面没有 CR」的 LF 位置（期望恒为空）。
    static func bareLineFeedOffsets(in data: Data) -> [Int] {
        let bytes = Array(data)
        var offsets: [Int] = []
        var insideQuotes = false
        var index = 0
        while index < bytes.count {
            let byte = bytes[index]
            if byte == quote {
                if insideQuotes, index + 1 < bytes.count, bytes[index + 1] == quote {
                    index += 2
                    continue
                }
                insideQuotes.toggle()
            } else if byte == lineFeed, !insideQuotes {
                let precededByCR = index > 0 && bytes[index - 1] == carriageReturn
                if !precededByCR { offsets.append(index) }
            }
            index += 1
        }
        return offsets
    }
}

// MARK: - 测试

@Suite("CSVExporter · RFC 4180")
struct CSVExporterTests {
    /// 捕获 `write` 抛出的 `ExportError`（避免在 `#expect` 闭包里操作 `inout` 写入器）。
    /// 未抛错时返回哨兵值，便于直接做等值断言。
    private func writeFailure(records: [ExportRecord], kind: ExportKind, request: ExportRequest,
                              columns: [ExportColumn]) -> ExportError {
        var writer = ExportWriter.memory()
        do {
            try CSVExporter.write(records: records, kind: kind, request: request,
                                  redactor: .disabled, columns: columns, to: &writer)
            return ExportError.invalidRequest("期望抛出，但 write 正常返回")
        } catch let error as ExportError {
            return error
        } catch {
            return ExportError.invalidRequest("抛出了非 ExportError：\(error)")
        }
    }

    // 1 · escape 单元规则

    @Test("escape 逐条规则：逗号 / 引号 / 换行 / 原样 / 空串")
    func escapeCellRules() {
        #expect(CSVExporter.escape("a,b") == "\"a,b\"")
        #expect(CSVExporter.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(CSVExporter.escape("line1\nline2") == "\"line1\nline2\"")
        #expect(CSVExporter.escape("line1\r\nline2") == "\"line1\r\nline2\"")
        #expect(CSVExporter.escape("abc") == "abc")
        #expect(CSVExporter.escape("") == "")
        // \t 不是 RFC 4180 的必转字符：不加引号，内容也不丢失
        #expect(CSVExporter.escape("a\tb") == "a\tb")
        // 全角逗号是普通文本，不得触发引号
        #expect(CSVExporter.escape("甲，乙") == "甲，乙")
        // emoji 与长串原样
        #expect(CSVExporter.escape("🦀") == "🦀")
    }

    // 2 · 对抗性字段往返

    @Test("row(...) → 解析器 往返：对抗字段逐字节相等")
    func adversarialFieldsRoundTrip() {
        let long = String(repeating: "abcdefghij", count: 100)
        #expect(long.count == 1_000)
        let fields: [String] = [
            "a,b",
            "say \"hi\"",
            "line1\r\nline2",
            "line1\nline2",
            "tab\tseparated",
            "全角逗号，中文",
            "🦀 crab emoji",
            "  前后空格  ",
            "\"\"",
            "\"",
            "",
            ",",
            "\r\n",
            "\n",
            "\"quoted, inside\"",
            "a\"b,c\nd\rl",
            "尾随引号\"",
            long
        ]
        let text = CSVExporter.row(fields)
        #expect(text.hasSuffix("\r\n"))
        let rows = ExportCSVTestParser.parse(text)
        #expect(rows.count == 1)
        let onlyRow = rows.first ?? []
        #expect(onlyRow == fields)

        // 多行文档同样逐字段相等；尾部行尾符不产生幻影行
        let twoRows = CSVExporter.row(fields) + CSVExporter.row(["x", "y,z"]) + CSVExporter.row([""])
        let parsed = ExportCSVTestParser.parse(twoRows)
        #expect(parsed.count == 3)
        let firstParsedRow = parsed.first ?? []
        #expect(firstParsedRow == fields)
        #expect(parsed[1] == ["x", "y,z"])
        #expect(parsed[2] == [""])
    }

    // 3 · 表头随字段选择变化

    @Test("表头随 selectedFieldNames 变化，顺序按列定义顺序")
    func headerFollowsFieldSelection() throws {
        let request = CSVFixtures.request(kind: .timeline, selected: ["timestamp", "command"])
        let columns = try request.columns(for: .timeline)
        #expect(columns.map(\.name) == ["timestamp", "command"])
        #expect(columns.map(\.title) == ["Timestamp", "Command"])

        // 传入顺序颠倒 → 仍按定义顺序（timestamp 在前）
        let reversedRequest = CSVFixtures.request(kind: .timeline, selected: ["command", "timestamp"])
        let reversedNames = try reversedRequest.columns(for: .timeline).map(\.name)
        #expect(reversedNames == ["timestamp", "command"])

        let data = try CSVExporter.data(records: [CSVFixtures.event(index: 1, command: "ls -la")],
                                        kind: .timeline, request: request)
        let rows = ExportCSVTestParser.parse(data)
        #expect(rows.count == 2)
        #expect(rows[0] == ["Timestamp", "Command"])
        #expect(rows.allSatisfy { $0.count == 2 })
        #expect(rows[1][1] == "ls -la")

        // 全字段：表头列数 = schema 列数，数据行列数一致
        let fullRequest = CSVFixtures.request(kind: .timeline)
        let fullCount = try ExportSchema.columns(for: .timeline).count
        let fullData = try CSVExporter.data(records: [CSVFixtures.event(index: 2)],
                                            kind: .timeline, request: fullRequest)
        let fullRows = ExportCSVTestParser.parse(fullData)
        #expect(fullRows[0].count == fullCount)
        #expect(fullRows[1].count == fullCount)
    }

    // 4 · 空集合仍写表头

    @Test("空记录集仍输出表头行，且只有 1 行")
    func emptyRecordsStillWriteHeader() throws {
        let request = CSVFixtures.request(kind: .commands)
        let titles = try ExportSchema.columns(for: .commands).map(\.title)
        let data = try CSVExporter.data(records: [], kind: .commands, request: request)
        #expect(data.isEmpty == false)

        let document = ExportCSVTestParser.parseDocument(data)
        #expect(document.rows.count == 1)
        #expect(document.rows[0] == titles)
        #expect(document.endsWithLineTerminator)

        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\r\n"))
        // 无 BOM 时全部字节都是表头 + CRLF
        #expect(text == titles.joined(separator: ",") + "\r\n")
    }

    // 5 · BOM 开关

    @Test("BOM 开关：true 恰好一次且在最前，false 一个字节都没有")
    func byteOrderMarkToggle() throws {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        let records = [CSVFixtures.event(index: 3, command: "pwd"), CSVFixtures.event(index: 4)]

        let withBOM = try CSVExporter.data(records: records, kind: .timeline,
                                           request: CSVFixtures.request(kind: .timeline, bom: true))
        #expect(Array(withBOM.prefix(3)) == bom)
        #expect(CSVFixtures.countOccurrences(of: bom, in: withBOM) == 1)

        let withoutBOM = try CSVExporter.data(records: records, kind: .timeline,
                                              request: CSVFixtures.request(kind: .timeline, bom: false))
        #expect(CSVFixtures.countOccurrences(of: bom, in: withoutBOM) == 0)
        #expect(Array(withoutBOM.prefix(3)) != bom)

        // BOM 是唯一差异
        #expect(withBOM.count == withoutBOM.count + 3)
        #expect(Array(withBOM.dropFirst(3)) == Array(withoutBOM))
        // 解析器忽略 BOM → 两种开关下逻辑结构一致
        #expect(ExportCSVTestParser.parse(withBOM) == ExportCSVTestParser.parse(withoutBOM))
    }

    // 6 · 流式分块 + 字节一致

    @Test("10 000 条记录：流式分块且与 data(...) 字节一致")
    func streamingWritesInMultipleChunks() throws {
        let records = CSVFixtures.events(10_000)
        let request = CSVFixtures.request(kind: .timeline)
        let columns = try request.columns(for: .timeline)

        var writer = ExportWriter.memory(chunkThresholdBytes: 4_096)
        try CSVExporter.write(records: records, kind: .timeline, request: request,
                              redactor: .standard, columns: columns, to: &writer)
        try writer.finish()
        #expect(writer.chunkCount >= 2)

        let streamed = try writer.collectedData()
        let bulk = try CSVExporter.data(records: records, kind: .timeline, request: request,
                                        redactor: .standard, columns: columns)
        #expect(writer.bytesWritten == bulk.count)
        #expect(streamed.count > 4_096)
        #expect(Array(streamed) == Array(bulk))
        // 确定性：同一输入两次导出字节完全相同
        let repeated = try CSVExporter.data(records: records, kind: .timeline, request: request)
        #expect(Array(bulk) == Array(repeated))
    }

    // 7 · 脱敏落地（参数驱动）

    @Test("脱敏由 redactor 参数驱动：standard 掩掉密钥，disabled 原样保留")
    func redactionIsParameterDriven() throws {
        let secret = "sk-abcdefghij1234567890"
        let raw = "curl -H \"Authorization: Bearer \(secret)\""
        let records = [CSVFixtures.event(index: 7, title: "网络请求", command: raw)]
        let request = CSVFixtures.request(kind: .timeline, selected: ["event_id", "command"])

        let standardData = try CSVExporter.data(records: records, kind: .timeline,
                                                request: request, redactor: .standard)
        let standardText = String(decoding: standardData, as: UTF8.self)
        #expect(standardText.contains(secret) == false)
        #expect(standardText.contains(ExportConstants.redactionPrefix))

        let standardRows = ExportCSVTestParser.parse(standardData)
        #expect(standardRows.count == 2)
        #expect(standardRows[0] == ["Event ID", "Command"])
        let maskedCell = standardRows[1][1]
        #expect(maskedCell.contains(secret) == false)
        #expect(maskedCell.contains(ExportConstants.redactionPrefix))
        #expect(maskedCell.hasPrefix("curl -H"))

        // 关闭脱敏 → 原文逐字节回来（同时证明引号转义没破坏内容）
        let disabledData = try CSVExporter.data(records: records, kind: .timeline,
                                                request: request, redactor: .disabled)
        let disabledRows = ExportCSVTestParser.parse(disabledData)
        #expect(disabledRows[1][1] == raw)
        #expect(disabledRows[1][1].contains(secret))
    }

    // 8 · 行尾

    @Test("行尾统一 CRLF：无引号外孤立 LF，最后一行也有行尾")
    func lineEndingsAreUniformCRLF() throws {
        let records: [ExportRecord] = [
            CSVFixtures.event(index: 11, title: "含\n换行的标题", summary: "含\r\n的摘要"),
            CSVFixtures.event(index: 12, command: "echo \"a,b\"")
        ]
        let data = try CSVExporter.data(records: records, kind: .timeline,
                                        request: CSVFixtures.request(kind: .timeline),
                                        redactor: .disabled)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasSuffix("\r\n"))
        #expect(ExportCSVTestParser.bareLineFeedOffsets(in: data).isEmpty)

        let document = ExportCSVTestParser.parseDocument(data)
        #expect(document.rows.count == 3)
        #expect(document.endsWithLineTerminator)
        #expect(document.terminators.count == 3)
        #expect(document.terminators.allSatisfy { $0 == [0x0D, 0x0A] })

        // 字段内的换行被引号保护：解析回来一字不差
        #expect(document.rows[1][5] == "含\n换行的标题")
        #expect(document.rows[1][6] == "含\r\n的摘要")
        #expect(document.rows[2][8] == "echo \"a,b\"")
    }

    // 9 · 非法组合与空列

    @Test("非记录 kind 与空列：抛出可定位错误而不是崩溃")
    func unsupportedKindAndEmptyColumns() throws {
        let records = CSVFixtures.events(2)
        let timelineColumns = try ExportSchema.columns(for: .timeline)
        let timelineRequest = CSVFixtures.request(kind: .timeline)

        // data(...)：.report 不是记录类 kind
        #expect(throws: ExportError.unsupportedCombination(format: .csv, kind: .report)) {
            try CSVExporter.data(records: records, kind: .report,
                                 request: CSVFixtures.request(kind: .report))
        }

        // write(...)：同样先判 kind，再判列
        let reportError = writeFailure(records: records, kind: .report, request: timelineRequest,
                                       columns: timelineColumns)
        #expect(reportError == ExportError.unsupportedCombination(format: .csv, kind: .report))

        let emptyColumnsError = writeFailure(records: records, kind: .timeline, request: timelineRequest,
                                             columns: [])
        #expect(emptyColumnsError.isRecoverable)
        #expect(String(describing: emptyColumnsError).hasPrefix("invalidRequest"))
    }

    // 10 · 记录类型与 kind 不一致不得崩

    @Test("记录与 kind 错配：借用他表列导出不崩，单元留空")
    func mismatchedRecordTypeProducesEmptyCells() throws {
        let commandRecords = [CSVFixtures.command(index: 21, line: "git status")]
        let timelineColumns = try ExportSchema.columns(for: .timeline)
        let data = try CSVExporter.data(records: commandRecords, kind: .commands,
                                        request: CSVFixtures.request(kind: .commands),
                                        redactor: .disabled, columns: timelineColumns)
        let rows = ExportCSVTestParser.parse(data)
        #expect(rows.count == 2)
        #expect(rows[0] == timelineColumns.map(\.title))
        #expect(rows[1].count == timelineColumns.count)
        // 只有通用列（agent_kind）有值；event_* 列对命令记录取不到值 → 空串
        #expect(rows[1][0].isEmpty)
        #expect(rows[1][1].isEmpty)
        #expect(rows[1][3] == AgentKind.genericCLIAgent.rawValue)

        // 混杂 kind 整包丢进来：只保留匹配记录（filtered 语义），不崩
        let mixed: [ExportRecord] = commandRecords + CSVFixtures.events(3)
        let mixedRows = ExportCSVTestParser.parse(
            try CSVExporter.data(records: mixed, kind: .commands,
                                 request: CSVFixtures.request(kind: .commands))
        )
        #expect(mixedRows.count == 2)
    }

    // 11 · 落盘集成（唯一碰磁盘的用例）

    @Test("写入磁盘文件：BOM 在最前，行结构与内存版一致")
    func writesFileIntoScratchDirectory() throws {
        let caseDirectory = CSVFixtures.scratchBase.appendingPathComponent("file-roundtrip", isDirectory: true)
        let fileURL = caseDirectory.appendingPathComponent("timeline.csv", isDirectory: false)
        let manager = FileManager.default
        try manager.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: caseDirectory) }

        let records = [CSVFixtures.event(index: 31, title: "写盘, 带逗号"),
                       CSVFixtures.event(index: 32, command: "rm -rf \"tmp\"")]
        let request = CSVFixtures.request(kind: .timeline, selected: ["event_id", "title", "command"], bom: true)
        let columns = try request.columns(for: .timeline)

        var writer = try ExportWriter.file(fileURL, allowedRoots: [CSVFixtures.scratchRoot])
        try CSVExporter.write(records: records, kind: .timeline, request: request,
                              redactor: .standard, columns: columns, to: &writer)
        try writer.finish()

        let onDisk = try Data(contentsOf: fileURL)
        let inMemory = try CSVExporter.data(records: records, kind: .timeline, request: request,
                                            redactor: .standard, columns: columns)
        #expect(Array(onDisk) == Array(inMemory))
        #expect(writer.bytesWritten == onDisk.count)
        #expect(Array(onDisk.prefix(3)) == [0xEF, 0xBB, 0xBF])
        #expect(CSVFixtures.countOccurrences(of: [0xEF, 0xBB, 0xBF], in: onDisk) == 1)

        let rows = ExportCSVTestParser.parse(onDisk)
        #expect(rows.count == 3)
        #expect(rows[0] == ["Event ID", "Title", "Command"])
        #expect(rows[1][1] == "写盘, 带逗号")
        #expect(rows[2][2] == "rm -rf \"tmp\"")
    }
}
