//
//  JSONExporterTests.swift
//  AIObservatoryExportTests
//
//  Owner: WS-Export（子代理 A）
//
//  JSONExporter 的验收测试。样本全部自建（AIObservatoryCore 模型 init + 固定 UUID + 固定时间基线），
//  **不**依赖任何测试支撑模块（只 import Foundation / Testing / Core / Export）。
//  断言策略：
//   · 语义类断言走 `JSONSerialization` 解码后的值（不把期望串硬编进测试，也不依赖 Foundation
//     对非 ASCII 的转义细节）；
//   · 键序 / 空白类断言走文本位置与前后缀（envelope 顺序是手工写的，必须有字节层证据）；
//   · 时间一律注入固定 `generatedAt`，不读墙钟、不 sleep、不起线程；
//   · 唯一落盘的用例写 `.scratch/export/json/<用例名>/`，并在 `defer` 里删除自己创建的目录。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
import AIObservatoryExport

// MARK: - 样本工厂

/// JSON 测试样本：确定性 = 固定 UUID 串 + 固定时间基线 + 固定注入时间。
private enum JSONFixtures {
    /// 全部记录时间的基线（测试与运行时刻无关）。
    static let baseline = Date(timeIntervalSince1970: 1_800_000_000)
    /// 请求注入时间：决定 `generatedAt`、运行中会话时长与 counts。
    static let generatedAt = Date(timeIntervalSince1970: 1_800_000_000 + 3_600)

    /// 落盘用例的允许根与其下的本套件子目录（不同代理用不同子目录，避免并行互删）。
    static let scratchRoot = Scratch.root
    static let scratchBase = scratchRoot
        .appendingPathComponent("export", isDirectory: true)
        .appendingPathComponent("json", isDirectory: true)

    /// 理论不可达的回退值（避免对 `UUID(uuidString:)` 的结果做强解包）。
    static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                      0, 0, 0, 0, 0, 0, 0, 0))

    /// 由下标生成稳定 UUID：`00000007-0000-0000-0000-000000000007`。
    static func uuid(index: Int) -> UUID {
        // %X 必须配 UInt32：Swift 的 Int 直接进 CVarArg 是 64 位，会串位。
        let value = UInt32(truncatingIfNeeded: index)
        let hex = String(format: "%08X-0000-0000-0000-%012X", value, value)
        return UUID(uuidString: hex) ?? zeroUUID
    }

    static func date(offset: TimeInterval) -> Date { baseline.addingTimeInterval(offset) }

    /// 一条会话。`endedAt == nil` 表示运行中（`ended_at` 必须是 `null`）。
    static func session(index: Int, endedAt: Date? = date(offset: 900),
                        projectPath: String? = FixturePaths.projectRoot) -> ExportRecord {
        .session(AgentSession(
            id: uuid(index: index),
            displayIndex: index,
            kind: .claudeCode,
            agentID: uuid(index: 70),
            title: "会话 \(index)",
            projectPath: projectPath,
            startedAt: date(offset: Double(index)),
            endedAt: endedAt,
            modifiedFileCount: 3,
            createdFileCount: 1,
            deletedFileCount: 0,
            commandCount: 4,
            failedCommandCount: 1,
            cpuSeconds: 12.5,
            peakCPUPercent: 37.5,
            peakMemoryBytes: 1_048_576,
            estimatedTokens: 20_000,
            riskEventCount: 1,
            outcome: endedAt == nil ? .running : .success
        ))
    }

    /// 一条时间线事件。
    static func event(index: Int, title: String = "读取文件", command: String? = nil,
                      summary: String = "普通摘要") -> ExportRecord {
        .event(TimelineEvent(
            id: uuid(index: index),
            timestamp: date(offset: Double(index)),
            sessionID: uuid(index: 900_000),
            agentID: uuid(index: 70),
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

    /// 一条文件变更。
    static func fileChange(index: Int, path: String = FixturePaths.inProjectRoot("Sources/A.swift"),
                           previousPath: String? = nil) -> ExportRecord {
        .fileChange(FileChange(
            id: uuid(index: index),
            path: path,
            previousPath: previousPath,
            kind: previousPath == nil ? .modified : .renamed,
            timestamp: date(offset: Double(index)),
            agentID: uuid(index: 70),
            sessionID: uuid(index: 900_000),
            agentKind: .claudeCode,
            sizeBytes: 4_096,
            previousSizeBytes: 2_048,
            isText: true,
            linesAdded: 12,
            linesRemoved: 3,
            riskLevel: .medium,
            projectPath: FixturePaths.projectRoot
        ))
    }

    /// 一条命令记录。
    static func command(index: Int, executable: String = "git",
                        arguments: [String] = ["status", "--short"]) -> ExportRecord {
        .command(CommandRecord(
            id: uuid(index: index),
            executable: executable,
            arguments: arguments,
            workingDirectory: FixturePaths.projectRoot,
            agentID: uuid(index: 70),
            sessionID: uuid(index: 900_000),
            agentKind: .genericCLIAgent,
            startedAt: date(offset: Double(index)),
            endedAt: date(offset: Double(index) + 0.5),
            exitCode: 0,
            outcome: .success,
            isDestructive: false,
            requiresConfirmation: false,
            riskLevel: .medium,
            projectPath: FixturePaths.projectRoot
        ))
    }

    /// 一条风险事件。
    static func riskEvent(index: Int, detail: String = "命中批量删除规则",
                          command: String? = "rm -rf tmp", filePaths: [String] = [],
                          level: RiskLevel = .high) -> ExportRecord {
        .riskEvent(RiskEvent(
            id: uuid(index: index),
            timestamp: date(offset: Double(index)),
            level: level,
            category: .dangerousCommand,
            title: "危险命令",
            detail: detail,
            agentID: uuid(index: 70),
            agentKind: .claudeCode,
            sessionID: uuid(index: 900_000),
            command: command,
            filePaths: filePaths,
            requiresConfirmation: true,
            isAcknowledged: false,
            matchedRuleID: "rule-destructive"
        ))
    }

    /// `count` 条时间线事件（时间升序）。
    static func events(_ count: Int) -> [ExportRecord] {
        (0..<count).map { event(index: $0, title: "事件\($0)") }
    }

    /// 一个 JSON 导出请求（`generatedAt` 固定 → 字节可重现）。
    static func request(kind: ExportKind, pretty: Bool = true, limit: Int? = nil,
                        dateRange: DateRangeFilter = .unbounded) -> ExportRequest {
        ExportRequest(
            format: .json,
            kinds: [kind],
            selectedFieldNames: nil,
            dateRange: dateRange,
            maximumRecordsPerKind: limit,
            generatedAt: generatedAt,
            redactionEnabled: true,
            csvIncludesByteOrderMark: false,
            jsonPrettyPrinted: pretty,
            destination: ExportDestination(directory: scratchBase, allowedRoots: [scratchRoot])
        )
    }
}

// MARK: - 断言辅助

/// 解码结果不是期望形状时抛出的显式错误（替代强解包）。
private struct JSONShapeMismatch: Error, CustomStringConvertible {
    let description: String
}

/// 测试侧的 JSON 读回工具：一律 `as?` + 显式错误，绝不强解包外部数据。
private enum JSONTest {
    /// 解析为顶层对象。
    static func document(_ data: Data) throws -> [String: Any] {
        let object = try JSONSerialization.jsonObject(with: data, options: [])
        guard let dict = object as? [String: Any] else {
            throw JSONShapeMismatch(description: "顶层不是 JSON 对象，而是 \(type(of: object))")
        }
        return dict
    }

    /// 顶层 `items` 数组（元素必须是对象）。
    static func items(_ data: Data) throws -> [[String: Any]] {
        guard let raw = try document(data)["items"] as? [Any] else {
            throw JSONShapeMismatch(description: "items 不是数组")
        }
        return raw.compactMap { $0 as? [String: Any] }
    }

    /// 第一条记录。
    static func firstItem(_ data: Data) throws -> [String: Any] {
        let records = try items(data)
        guard let first = records.first else {
            throw JSONShapeMismatch(description: "items 为空，期望至少一条记录")
        }
        return first
    }

    /// 递归收集全部字符串叶子，**排序后**返回（字典遍历顺序无关 → 断言确定）。
    static func stringLeaves(in value: Any) -> [String] {
        var result: [String] = []
        collect(value, into: &result)
        return result.sorted()
    }

    private static func collect(_ value: Any, into result: inout [String]) {
        if let text = value as? String {
            result.append(text)
            return
        }
        if let dict = value as? [String: Any] {
            for (_, element) in dict { collect(element, into: &result) }
            return
        }
        if let array = value as? [Any] {
            for element in array { collect(element, into: &result) }
        }
    }

    /// 顶层键（写作 `"name"`）在文本中的位置；找不到时返回 `Int.max`，让断言自然失败。
    static func keyPosition(of name: String, in text: String, backwards: Bool = false) -> Int {
        let needle = "\"" + name + "\""
        let options: String.CompareOptions = backwards ? [.backwards] : []
        guard let range = text.range(of: needle, options: options) else { return .max }
        return text.distance(from: text.startIndex, to: range.lowerBound)
    }

    /// 凭据的全部 `length` 字符滑窗片段（验收要求「任意 ≥8 字符片段都不残留」）。
    static func fragments(of secret: String, length: Int = 8) -> [String] {
        let characters = Array(secret)
        guard characters.count >= length else { return [secret] }
        return (0...(characters.count - length)).map { start in
            String(characters[start..<(start + length)])
        }
    }

    /// 字节序列出现次数（线性扫描，10 000 条也数得动）。
    static func countOccurrences(of needle: String, in data: Data) -> Int {
        let bytes = Array(data)
        let pattern = Array(needle.utf8)
        guard pattern.isEmpty == false, bytes.count >= pattern.count else { return 0 }
        let head = pattern[0]
        var count = 0
        var index = 0
        while index + pattern.count <= bytes.count {
            guard bytes[index] == head else { index += 1; continue }
            if Array(bytes[index..<(index + pattern.count)]) == pattern {
                count += 1
                index += pattern.count
            } else {
                index += 1
            }
        }
        return count
    }
}

// MARK: - 测试

@Suite("JSONExporter · envelope 键序 / 字节确定 / 流式分块")
struct JSONExporterTests {

    /// 捕获 `write` 抛出的 `ExportError`（闭包不能捕获 `inout` 写入器，故单独包一层）。
    /// 未抛错时返回哨兵值，便于直接等值断言。
    private func writeFailure(records: [ExportRecord], kind: ExportKind,
                              request: ExportRequest) -> ExportError {
        var writer = ExportWriter.memory()
        do {
            try JSONExporter.write(records: records, kind: kind, request: request,
                                   redactor: .standard, to: &writer)
            return ExportError.invalidRequest("期望 write 抛出，但它正常返回")
        } catch let error as ExportError {
            return error
        } catch {
            return ExportError.invalidRequest("抛出了非 ExportError：\(error)")
        }
    }

    // 1 · 字节确定

    @Test("同一输入 + 同一 generatedAt：两次 data(...) 字节完全相同（pretty 与紧凑都是）")
    func sameInputProducesIdenticalBytes() throws {
        let records: [ExportRecord] = [
            JSONFixtures.session(index: 1, endedAt: nil),
            JSONFixtures.session(index: 2),
            JSONFixtures.session(index: 3, projectPath: nil)
        ]
        let prettyRequest = JSONFixtures.request(kind: .sessions)
        let prettyA = try JSONExporter.data(records: records, kind: .sessions, request: prettyRequest)
        let prettyB = try JSONExporter.data(records: records, kind: .sessions, request: prettyRequest)
        #expect(Array(prettyA) == Array(prettyB))
        #expect(prettyA.count > 300)

        let compactRequest = JSONFixtures.request(kind: .sessions, pretty: false)
        let compactA = try JSONExporter.data(records: records, kind: .sessions, request: compactRequest)
        let compactB = try JSONExporter.data(records: records, kind: .sessions, request: compactRequest)
        #expect(Array(compactA) == Array(compactB))
        // 两种排版只差空白：解码后的叶子值集合相同，紧凑一定更短
        let compactLeaves = JSONTest.stringLeaves(in: try JSONTest.document(compactA))
        let prettyLeaves = JSONTest.stringLeaves(in: try JSONTest.document(prettyA))
        #expect(compactLeaves == prettyLeaves)
        #expect(compactA.count < prettyA.count)

        // 唯一的外部输入是 generatedAt：改它 → 字节必改；不改 → 逐字节相同
        var shifted = prettyRequest
        shifted.generatedAt = shifted.generatedAt.addingTimeInterval(1)
        let shiftedData = try JSONExporter.data(records: records, kind: .sessions, request: shifted)
        let shiftedText = String(decoding: shiftedData, as: UTF8.self)
        #expect(shiftedText != String(decoding: prettyA, as: UTF8.self))
        #expect(shiftedText.contains(ExportDateEncoder().string(shifted.generatedAt)))
        #expect(shiftedText.contains(ExportDateEncoder().string(JSONFixtures.generatedAt)) == false)
    }

    // 2 · envelope 键序与值

    @Test("envelope：六个顶层键固定顺序、items 在最后、值来自常量与注入时间")
    func envelopeKeyOrderAndValues() throws {
        let records: [ExportRecord] = [JSONFixtures.event(index: 11), JSONFixtures.command(index: 12)]
        let data = try JSONExporter.data(records: records, kind: .timeline,
                                         request: JSONFixtures.request(kind: .timeline))
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("{\n  \"schemaVersion\": \(ExportConstants.schemaVersion)"))
        #expect(text.hasSuffix("]\n}\n"))
        #expect(text.contains("\"items\": ["))

        let order = ["schemaVersion", "generatedAt", "exportedBy", "kind", "counts", "items"]
        let positions = order.map { JSONTest.keyPosition(of: $0, in: text) }
        #expect(positions == positions.sorted())
        let itemsPosition = JSONTest.keyPosition(of: "items", in: text)
        for name in order.dropLast() {
            #expect(JSONTest.keyPosition(of: name, in: text, backwards: true) < itemsPosition)
        }

        let document = try JSONTest.document(data)
        #expect(document["schemaVersion"] as? Int == ExportConstants.schemaVersion)
        // 刻意不写 `== ExportConstants.exportedBy`：那是拿实现比实现，
        // 应用改名后它照样绿，等于什么都没守。钉字面量，改名时这条必须红并逼人看一眼。
        #expect(document["exportedBy"] as? String == "AiX (local)")
        #expect(document["kind"] as? String == ExportKind.timeline.rawValue)
        #expect(document["generatedAt"] as? String == ExportDateEncoder().string(JSONFixtures.generatedAt))
        #expect((document["items"] as? [Any])?.count == 1)   // 只有那条 event 属于 .timeline

        let counts = document["counts"] as? [String: Any]
        #expect(counts?["total"] as? Int == 1)
        #expect(counts?["byAgentKind"] as? [String: Int] == ["claudeCode": 1])
        #expect(counts?["byRiskLevel"] as? [String: Int] == ["low": 1])
        #expect(Set((counts ?? [:]).keys) == ["total", "byAgentKind", "byRiskLevel"])

        // 记录键 = schema 字段名（两份真相不漂移），文本里按 .sortedKeys 升序出现
        let item = try JSONTest.firstItem(data)
        #expect(try item.keys.sorted() == ExportSchema.fieldNames(for: .timeline).sorted())
        #expect(text.contains("\"event_id\""))
        #expect(text.contains("\"operation_kind\""))
    }

    // 3 · 空记录集

    @Test("空记录集：仍是合法 JSON，counts 全零且字典为空，items 是 [] 而不是空字节")
    func emptyRecordSetStillProducesValidJSONWithEmptyItems() throws {
        let data = try JSONExporter.data(records: [], kind: .fileChanges,
                                         request: JSONFixtures.request(kind: .fileChanges))
        #expect(data.isEmpty == false)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("\"items\": []"))

        let document = try JSONTest.document(data)
        #expect(document["schemaVersion"] as? Int == ExportConstants.schemaVersion)
        #expect((document["items"] as? [Any])?.isEmpty == true)
        let counts = document["counts"] as? [String: Any]
        #expect(counts?["total"] as? Int == 0)
        #expect((counts?["byAgentKind"] as? [String: Any])?.isEmpty == true)
        #expect((counts?["byRiskLevel"] as? [String: Any])?.isEmpty == true)
        #expect(try JSONTest.items(data).isEmpty)

        // 紧凑模式同样合法（能被 JSONSerialization 解析 = 括号与分隔符都写对了）
        let compact = try JSONExporter.data(records: [], kind: .fileChanges,
                                           request: JSONFixtures.request(kind: .fileChanges, pretty: false))
        #expect(String(decoding: compact, as: UTF8.self).contains("\"items\":[]"))
        #expect(try JSONTest.document(compact).isEmpty == false)
    }

    // 4 · 五种秘钥形态

    @Test("五种秘钥形态：原值与任意 8 字符片段都不残留，且留下 ‹redacted:kind›")
    func fiveSecretFormsLeaveNoFragment() throws {
        let openAIKey = "sk-Wx7vQpZtRnYdLfKgHmBc"
        let githubToken = "ghp_AbCdEfGhIjKlMnOpQrSt"
        let awsKey = "AKIAIOSFODNN7EXAMPLE"
        let privateKey = "-----BEGIN RSA PRIVATE KEY-----\nMIIEowIBAAKCAQEAZuzr7cw\n-----END RSA PRIVATE KEY-----"
        let passwordValue = "hunter2supersecret"

        let timelineRecords: [ExportRecord] = [
            JSONFixtures.event(index: 41, title: "导出环境变量",
                               command: "export OPENAI_API_KEY=\(openAIKey)"),
            JSONFixtures.event(index: 42, title: "推送",
                               command: "git push https://\(githubToken)@github.com/aix/app.git",
                               summary: "git push")
        ]
        let riskRecords: [ExportRecord] = [
            JSONFixtures.riskEvent(index: 43, detail: "读到私钥：\(privateKey)",
                                   command: "aws configure set aws_access_key_id \(awsKey)"),
            JSONFixtures.riskEvent(index: 44, detail: "mysql --user=root --password=\(passwordValue)",
                                   command: nil)
        ]
        let commandRecords: [ExportRecord] = [
            JSONFixtures.command(index: 45, executable: "curl",
                                 arguments: ["-H", "password=\(passwordValue)",
                                             "--upload-file", "./\(githubToken)"])
        ]

        let timelineData = try JSONExporter.data(records: timelineRecords, kind: .timeline,
                                                 request: JSONFixtures.request(kind: .timeline))
        let riskData = try JSONExporter.data(records: riskRecords, kind: .riskEvents,
                                             request: JSONFixtures.request(kind: .riskEvents))
        let commandData = try JSONExporter.data(records: commandRecords, kind: .commands,
                                                request: JSONFixtures.request(kind: .commands))
        let blobs = [timelineData, riskData, commandData]
        let combined = blobs.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "\n")

        // ① 原值与其任意 8 字符滑窗都不出现（这些凭据都是 ASCII，JSON 转义拆不散）
        for secret in [openAIKey, githubToken, awsKey, privateKey, passwordValue] {
            #expect(combined.contains(secret) == false)
            for fragment in JSONTest.fragments(of: secret) {
                #expect(combined.contains(fragment) == false)
            }
        }

        // ② 掩码确实发生：解码后的叶子里既有占位符、也点名了五种形态
        var leaves: [String] = []
        for blob in blobs {
            leaves += JSONTest.stringLeaves(in: try JSONTest.document(blob))
        }
        #expect(leaves.contains { $0.contains(ExportConstants.redactionPrefix) })
        for form in ["openai_key", "github_token", "aws_access_key", "private_key",
                     "password_assignment"] {
            #expect(leaves.contains { $0.contains("redacted:" + form) })
        }
    }

    // 5 · 流式分块

    @Test("10 000 条事件：memory(chunkThresholdBytes: 4096) 下 chunkCount ≥ 2、总字节 > 1MB")
    func tenThousandEventsStreamInMultipleChunks() throws {
        let records = JSONFixtures.events(10_000)
        let request = JSONFixtures.request(kind: .timeline, pretty: false)

        var writer = ExportWriter.memory(chunkThresholdBytes: 4_096)
        try JSONExporter.write(records: records, kind: .timeline, request: request,
                               redactor: .standard, to: &writer)
        try writer.finish()
        #expect(writer.chunkCount >= 2)
        #expect(writer.bytesWritten > 1_000_000)

        let streamed = try writer.collectedData()
        #expect(streamed.count == writer.bytesWritten)
        #expect(try JSONTest.items(streamed).count == 10_000)
        // 每条记录各自编码：一个 key 恰好出现 10 000 次
        #expect(JSONTest.countOccurrences(of: "\"event_id\"", in: streamed) == 10_000)
        // 分块写出与一次性取字节完全等价 → 不存在「先拼整篇文档」的路径
        let bulk = try JSONExporter.data(records: records, kind: .timeline, request: request)
        #expect(Array(streamed) == Array(bulk))
        let streamedCounts = try JSONTest.document(streamed)["counts"] as? [String: Any]
        #expect(streamedCounts?["total"] as? Int == 10_000)
        #expect(streamedCounts?["byRiskLevel"] as? [String: Int] == ["low": 10_000])
    }

    // 6 · 可选值与关闭脱敏

    @Test("可选字段缺失 → null（不是空串）；redactor: .disabled 时不掩码")
    func missingOptionalsEncodeAsNullAndDisabledRedactorKeepsRaw() throws {
        let running = JSONFixtures.session(index: 61, endedAt: nil, projectPath: nil)
        let runningData = try JSONExporter.data(records: [running], kind: .sessions,
                                                request: JSONFixtures.request(kind: .sessions))
        let sessionItem = try JSONTest.firstItem(runningData)
        #expect(sessionItem["ended_at"] is NSNull)
        #expect(sessionItem["ended_at"] as? String == nil)
        #expect(sessionItem["project_path"] is NSNull)
        #expect(sessionItem["session_id"] as? String == JSONFixtures.uuid(index: 61).uuidString)
        #expect(sessionItem["started_at"] as? String
            == ExportDateEncoder().string(JSONFixtures.date(offset: 61)))
        // 运行中会话的时长来自注入时间，而不是墙钟
        let expectedDuration = JSONFixtures.generatedAt.timeIntervalSince(JSONFixtures.date(offset: 61))
        #expect(sessionItem["duration_seconds"] as? Double == expectedDuration)

        // 事件的可选项全缺位（含空串命令）→ 逐个 null
        let bareEvent: ExportRecord = .event(TimelineEvent(
            id: JSONFixtures.uuid(index: 62),
            timestamp: JSONFixtures.date(offset: 62),
            agentKind: .unknown,
            kind: .unknown,
            title: "只有标题",
            command: ""
        ))
        let eventData = try JSONExporter.data(records: [bareEvent], kind: .timeline,
                                              request: JSONFixtures.request(kind: .timeline))
        let eventItem = try JSONTest.firstItem(eventData)
        for key in ["session_id", "file_path", "command", "exit_code", "duration_seconds",
                    "project_path"] {
            #expect(eventItem[key] is NSNull)
        }
        #expect(eventItem["summary"] as? String == "")   // 必选字段的空串保持原样

        // 关闭脱敏 → 原值逐字节回来，且不出现任何占位符
        let secret = "AKIAIOSFODNN7EXAMPLE"
        let risky = [JSONFixtures.riskEvent(index: 63, detail: "key id \(secret)", command: nil)]
        let riskRequest = JSONFixtures.request(kind: .riskEvents)
        let rawData = try JSONExporter.data(records: risky, kind: .riskEvents, request: riskRequest,
                                            redactor: .disabled)
        let rawText = String(decoding: rawData, as: UTF8.self)
        #expect(rawText.contains(secret))
        #expect(rawText.contains(ExportConstants.redactionPrefix) == false)
        #expect(rawText.contains("redacted:") == false)
        let maskedData = try JSONExporter.data(records: risky, kind: .riskEvents, request: riskRequest)
        let maskedText = String(decoding: maskedData, as: UTF8.self)
        #expect(maskedText.contains(secret) == false)
        #expect(maskedText.contains("redacted:aws_access_key"))
        // 掩码只落在 detail 上，其余字段原样保留
        let maskedItem = try JSONTest.firstItem(maskedData)
        #expect((maskedItem["detail"] as? String)?.contains(secret) == false)
        #expect(maskedItem["matched_rule_id"] as? String == "rule-destructive")
        #expect(maskedItem["command"] is NSNull)
    }

    // 7 · 记录与 kind 不匹配

    @Test("混入别的 kind：不崩，只输出与 kind 匹配的记录，JSON 键与 schema 字段一一对应")
    func mixedKindsExportOnlyMatchingRecords() throws {
        let mixed: [ExportRecord] = [
            JSONFixtures.command(index: 71),
            JSONFixtures.event(index: 72),
            JSONFixtures.session(index: 73),
            JSONFixtures.fileChange(index: 74),
            JSONFixtures.riskEvent(index: 75),
            JSONFixtures.command(index: 76, executable: "ls", arguments: ["-la"])
        ]
        let data = try JSONExporter.data(records: mixed, kind: .commands,
                                         request: JSONFixtures.request(kind: .commands))
        let document = try JSONTest.document(data)
        let items = try JSONTest.items(data)
        #expect(items.count == 2)
        #expect(document["kind"] as? String == ExportKind.commands.rawValue)
        #expect((document["counts"] as? [String: Any])?["total"] as? Int == 2)
        #expect(items.allSatisfy { $0["command_id"] is String && $0["event_id"] == nil })
        #expect(items.allSatisfy { $0["detail"] == nil && $0["path"] == nil })

        // 五种记录 kind 逐个走整包混合输入：条数、counts、键名三者互相对齐
        for kind in ExportSchema.allRecordKinds {
            let perKind = try JSONExporter.data(records: mixed, kind: kind,
                                                request: JSONFixtures.request(kind: kind))
            let parsed = try JSONTest.document(perKind)
            let exported = try JSONTest.items(perKind)
            let expected = mixed.filter { $0.kind == kind }.count
            #expect(exported.count == expected)
            #expect((parsed["counts"] as? [String: Any])?["total"] as? Int == expected)
            if let only = exported.first {
                #expect(try only.keys.sorted() == ExportSchema.fieldNames(for: kind).sorted())
            }
        }
    }

    // 8 · 非法 kind

    @Test(".report 不是记录类 kind：data 与 write 都抛 unsupportedCombination，不崩")
    func reportKindIsRejected() throws {
        let records = JSONFixtures.events(2)
        #expect(throws: ExportError.unsupportedCombination(format: .json, kind: .report)) {
            try JSONExporter.data(records: records, kind: .report,
                                  request: JSONFixtures.request(kind: .report))
        }
        #expect(writeFailure(records: records, kind: .report,
                             request: JSONFixtures.request(kind: .report))
            == ExportError.unsupportedCombination(format: .json, kind: .report))
    }

    // 9 · 落盘集成（唯一碰磁盘的用例）

    @Test("写入磁盘文件：与内存版字节一致，解析回来仍是同一 envelope")
    func writesFileIntoScratchDirectory() throws {
        let caseDirectory = JSONFixtures.scratchBase.appendingPathComponent("file-roundtrip",
                                                                           isDirectory: true)
        let fileURL = caseDirectory.appendingPathComponent("risk-events.json", isDirectory: false)
        let manager = FileManager.default
        try manager.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: caseDirectory) }

        let records: [ExportRecord] = [
            JSONFixtures.riskEvent(index: 91, detail: "含\"引号\"、逗号, 与中文",
                                   command: "rm -rf ./build", filePaths: ["/a/b.txt", "/c/d.txt"]),
            JSONFixtures.riskEvent(index: 92, detail: "emoji 🦀 与 ‹已脱敏› 字面", command: nil)
        ]
        let request = JSONFixtures.request(kind: .riskEvents)
        var writer = try ExportWriter.file(fileURL, allowedRoots: [JSONFixtures.scratchRoot])
        try JSONExporter.write(records: records, kind: .riskEvents, request: request,
                               redactor: .standard, to: &writer)
        try writer.finish()

        let onDisk = try Data(contentsOf: fileURL)
        let inMemory = try JSONExporter.data(records: records, kind: .riskEvents, request: request)
        #expect(Array(onDisk) == Array(inMemory))
        #expect(writer.bytesWritten == onDisk.count)
        #expect(writer.destinationURL == fileURL)

        let items = try JSONTest.items(onDisk)
        #expect(items.count == 2)
        #expect(items[0]["detail"] as? String == "含\"引号\"、逗号, 与中文")
        #expect(items[0]["file_paths"] as? [String] == ["/a/b.txt", "/c/d.txt"])
        #expect(items[0]["risk_id"] as? String == JSONFixtures.uuid(index: 91).uuidString)
        #expect(items[0]["level"] as? String == RiskLevel.high.rawValue)
        #expect(items[1]["command"] is NSNull)
        #expect(items[1]["requires_confirmation"] as? Bool == true)
        #expect(items[1]["is_acknowledged"] as? Bool == false)
    }
}
