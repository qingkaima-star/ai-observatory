//
//  ExportCoordinatorTests.swift
//  AIObservatoryExportTests
//
//  Owner: WS-Export（主代理）—— 多表分文件 / 字节可重现 / 越界拒写 / 分页终止性
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
import AIObservatoryExport

// MARK: - 夹具

private enum Fixture {
    static let generatedAt = Date(timeIntervalSince1970: 1_800_000_000)

    /// 确定性 UUID：把 seed 写进尾 8 字节，其余置零。
    static func uuid(_ seed: Int) -> UUID {
        var raw = [UInt8](repeating: 0, count: 16)
        var cursor = seed
        for index in stride(from: 15, through: 8, by: -1) {
            raw[index] = UInt8(truncatingIfNeeded: cursor)
            cursor >>= 8
        }
        return UUID(uuid: (raw[0], raw[1], raw[2], raw[3], raw[4], raw[5], raw[6], raw[7],
                           raw[8], raw[9], raw[10], raw[11], raw[12], raw[13], raw[14], raw[15]))
    }

    static func date(_ offset: Double) -> Date { generatedAt.addingTimeInterval(offset) }

    static func session(_ index: Int, ended: Bool = true) -> AgentSession {
        AgentSession(
            id: uuid(index), displayIndex: 100 + index, kind: .claudeCode, agentID: uuid(500 + index),
            title: "会话 \(index)", projectPath: "/Users/demo/Projects/Mona",
            startedAt: date(Double(index) * 60), endedAt: ended ? date(Double(index) * 60 + 30) : nil,
            modifiedFileCount: 3, createdFileCount: 1, deletedFileCount: 0,
            commandCount: 2, failedCommandCount: 0, cpuSeconds: 12.5, peakCPUPercent: 40,
            peakMemoryBytes: 4_096, estimatedTokens: 1_000, riskEventCount: 0,
            outcome: ended ? .success : .running
        )
    }

    static func event(_ index: Int) -> TimelineEvent {
        TimelineEvent(id: uuid(1_000 + index), timestamp: date(Double(index) * 10),
                      sessionID: uuid(1), agentID: uuid(2), agentKind: .openAICodex,
                      kind: .fileModified, title: "修改 API.swift", summary: "/Sources/API.swift",
                      filePath: "/Users/demo/Projects/Mona/Sources/API.swift",
                      riskLevel: index % 3 == 0 ? .high : .low)
    }

    static func command(_ index: Int) -> CommandRecord {
        CommandRecord(id: uuid(2_000 + index), executable: "rm",
                      arguments: ["-rf", "./build\(index)"], workingDirectory: "/Users/demo/Projects/Mona",
                      sessionID: uuid(1), agentKind: .claudeCode, startedAt: date(Double(index) * 20),
                      endedAt: date(Double(index) * 20 + 1), exitCode: 0, outcome: .success,
                      isDestructive: true, requiresConfirmation: true, riskLevel: .high)
    }

    static func records() -> [ExportRecord] {
        (1...3).map { ExportRecord.session(session($0)) }
            + (1...5).map { ExportRecord.event(event($0)) }
            + (1...2).map { ExportRecord.command(command($0)) }
    }

    static func request(format: ExportFormat, kinds: [ExportKind], directory: URL,
                        maximum: Int? = nil) -> ExportRequest {
        ExportRequest(format: format, kinds: kinds, maximumRecordsPerKind: maximum,
                      generatedAt: generatedAt,
                      destination: ExportDestination(directory: directory, baseName: "aix-test",
                                                     allowedRoots: [directory]))
    }
}

/// 每个用例一个独立子目录，全部落在当前检出自带的 `.scratch-tests/export/` 下，用例结束即删除。
private func exportScratch(_ name: String) throws -> URL {
    let root = Scratch.root.appendingPathComponent("export/coordinator", isDirectory: true)
    let url = root.appendingPathComponent(name, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func removeScratch(_ url: URL) { try? FileManager.default.removeItem(at: url) }

private func bytes(of url: URL) throws -> Data { try Data(contentsOf: url) }

private func jsonItems(of url: URL) throws -> [[String: Any]] {
    let data = try bytes(of: url)
    guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw ExportError.invalidRequest("顶层不是 JSON 对象：\(url.lastPathComponent)")
    }
    guard let items = envelope["items"] as? [[String: Any]] else {
        throw ExportError.invalidRequest("缺 items 数组：\(url.lastPathComponent)")
    }
    return items
}

// MARK: - 测试

@Suite("ExportCoordinator · 多表分文件与可重现性", .timeLimit(.minutes(1)))
struct ExportCoordinatorTests {
    @Test("JSON 多 kind → 每个 kind 一个文件，条数与各表一致")
    func jsonSplitsByKind() throws {
        let dir = try exportScratch("json-kinds")
        defer { removeScratch(dir) }
        let request = Fixture.request(format: .json, kinds: [.sessions, .timeline, .commands],
                                       directory: dir)

        let artifacts = try ExportCoordinator().run(request, records: Fixture.records())

        #expect(artifacts.map(\.kind) == [.sessions, .timeline, .commands])
        #expect(artifacts.map(\.recordCount) == [3, 5, 2])
        #expect(Set(artifacts.map(\.url)).count == 3, "三个 kind 必须是三个不同文件")
        for artifact in artifacts {
            #expect(FileManager.default.fileExists(atPath: artifact.url.path))
            #expect(artifact.chunkCount >= 1)
            #expect(artifact.bytesWritten > 0)
        }
        for (artifact, expected) in zip(artifacts, [3, 5, 2]) {
            #expect(try jsonItems(of: artifact.url).count == expected,
                    "\(artifact.kind.rawValue) 的 items 数应为 \(expected)")
        }
    }

    @Test("CSV 多 kind → 分文件、各自表头；空表仍有表头；BOM 只出现一次且在最前")
    func csvSplitsByKindWithHeaders() throws {
        let dir = try exportScratch("csv-kinds")
        defer { removeScratch(dir) }
        var request = Fixture.request(format: .csv, kinds: [.sessions, .riskEvents], directory: dir)
        request.csvIncludesByteOrderMark = true

        let artifacts = try ExportCoordinator().run(request, records: Fixture.records())
        #expect(artifacts.count == 2)

        let sessionsFile = try #require(artifacts.first { $0.kind == .sessions })
        let riskFile = try #require(artifacts.first { $0.kind == .riskEvents })
        #expect(sessionsFile.bytesWritten > 0)
        // 没有任何风险事件：仍必须写出表头，而不是 0 字节文件或空串。
        #expect(riskFile.recordCount == 0)
        #expect(riskFile.bytesWritten > 0)

        let riskText = String(decoding: try bytes(of: riskFile.url), as: UTF8.self)
        let sessionsText = String(decoding: try bytes(of: sessionsFile.url), as: UTF8.self)
        #expect(riskText.hasPrefix("\u{FEFF}"), "BOM 必须在文件最前")
        #expect(sessionsText.hasPrefix("\u{FEFF}"))
        #expect(riskText.dropFirst().contains("\u{FEFF}") == false, "BOM 只许出现一次")

        let header = String(riskText.dropFirst()).replacingOccurrences(of: "\r\n", with: "")
        #expect(header.split(separator: ",").count == (try ExportSchema.fieldNames(for: .riskEvents)).count)
        #expect(try CSVExporterTestsParse.rowCount(of: riskFile.url) == 1)
        #expect(try CSVExporterTestsParse.rowCount(of: sessionsFile.url) == 4, "表头 + 3 条会话")
    }

    @Test("同一请求两次运行 → 文件名相同且每个文件字节完全相同")
    func twoRunsAreByteIdentical() throws {
        let dirA = try exportScratch("determinism-a")
        let dirB = try exportScratch("determinism-b")
        defer {
            removeScratch(dirA)
            removeScratch(dirB)
        }
        let coordinator = ExportCoordinator(chunkThresholdBytes: 256)
        let records = Fixture.records()

        let first = try coordinator.run(Fixture.request(format: .json, kinds: [.sessions, .timeline],
                                                        directory: dirA), records: records)
        let second = try coordinator.run(Fixture.request(format: .json, kinds: [.sessions, .timeline],
                                                         directory: dirB), records: records)

        #expect(first.count == second.count)
        for (left, right) in zip(first, second) {
            #expect(left.kind == right.kind)
            #expect(left.url.lastPathComponent == right.url.lastPathComponent, "同一 generatedAt → 同一文件名")
            #expect(try bytes(of: left.url) == bytes(of: right.url),
                    "\(left.kind.rawValue) 两次导出字节必须完全相同")
        }
    }

    @Test("报告导出 → Markdown 单文件，含概览与危险命令")
    func markdownReport() throws {
        let dir = try exportScratch("report")
        defer { removeScratch(dir) }
        let request = Fixture.request(format: .markdown, kinds: [.report], directory: dir)
        let project = ProjectActivity(
            id: "/Users/demo/Projects/Mona", name: "Mona", path: "/Users/demo/Projects/Mona",
            fileChangeCount: 5, commandCount: 2, sessionCount: 3, riskEventCount: 1,
            hotFiles: [FileHeat(path: "/Users/demo/Projects/Mona/Sources/API.swift", changeCount: 5)],
            firstSeenAt: Fixture.date(-600), lastSeenAt: Fixture.date(0))

        let artifacts = try ExportCoordinator().run(request, records: Fixture.records(), projects: [project])
        #expect(artifacts.count == 1)

        let report = artifacts[0]
        #expect(report.url.pathExtension == "md")
        #expect(report.recordCount == 10, "报告统计全部记录（3 + 5 + 2）")
        let text = String(decoding: try bytes(of: report.url), as: UTF8.self)
        #expect(text.contains("# AI Agent 活动审计报告"))
        #expect(text.contains("## 概览"))
        #expect(text.contains("rm -rf"))
    }

    @Test("目标越出允许根目录 / 允许根为空 / 系统目录 → 抛错且磁盘上不留任何文件")
    func refusesOutOfBoundsDestinations() throws {
        let records = Fixture.records()
        let scratchRoot = Scratch.root.appendingPathComponent("export", isDirectory: true)
        let blocked: [(label: String, destination: ExportDestination)] = [
            ("系统目录当输出目录",
             ExportDestination(directory: URL(fileURLWithPath: "/System/Library/Factories/x", isDirectory: true),
                               allowedRoots: [scratchRoot])),
            ("根目录",
             ExportDestination(directory: URL(fileURLWithPath: "/", isDirectory: true),
                               allowedRoots: [URL(fileURLWithPath: FixturePaths.projectRoot, isDirectory: true)])),
            ("未展开的波浪号",
             ExportDestination(directory: URL(fileURLWithPath: "~/exports", isDirectory: true),
                               allowedRoots: [scratchRoot])),
            ("允许根为空",
             ExportDestination(directory: scratchRoot.appendingPathComponent("none", isDirectory: true),
                               allowedRoots: []))
        ]
        for item in blocked {
            let request = ExportRequest(format: .json, kinds: [.sessions],
                                        generatedAt: Fixture.generatedAt, destination: item.destination)
            var candidates: [URL] = []
            for kind in ExportKind.allCases where kind.isRecordKind {
                candidates.append(item.destination.fileURL(for: kind, format: .json, stamp: request.fileStamp))
            }
            var threw = false
            do {
                _ = try ExportCoordinator().run(request, records: records)
            } catch let error as ExportError {
                threw = true
                #expect(error.isRecoverable == false, "\(item.label)：路径类错误必须不可恢复")
            }
            #expect(threw, "\(item.label) 必须被拒绝")
            for url in candidates {
                #expect(FileManager.default.fileExists(atPath: url.path) == false,
                        "\(item.label) 被拒后不得留下 \(url.lastPathComponent)")
            }
        }
    }

    @Test("maximumRecordsPerKind → 保留时间上最新的 N 条")
    func capsRecordsPerKind() throws {
        let dir = try exportScratch("cap")
        defer { removeScratch(dir) }
        let request = Fixture.request(format: .json, kinds: [.timeline], directory: dir, maximum: 2)

        let artifacts = try ExportCoordinator().run(request, records: Fixture.records())
        #expect(artifacts[0].recordCount == 2)

        let stamps = try jsonItems(of: artifacts[0].url).compactMap { $0["timestamp"] as? String }
        #expect(stamps == [Fixture.date(40), Fixture.date(50)].map { ExportDateEncoder().string($0) })
    }

    @Test("脱敏贯穿协调器：导出文件里不含原始秘钥")
    func redactionAppliesThroughCoordinator() throws {
        let dir = try exportScratch("redaction")
        defer { removeScratch(dir) }
        let secret = "sk-ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
        var records = Fixture.records()
        records.append(.riskEvent(RiskEvent(id: Fixture.uuid(9_000), timestamp: Fixture.date(5),
                                            level: .critical, category: .credentialExposure,
                                            title: "读到凭据", detail: "OPENAI_API_KEY=\(secret)",
                                            agentKind: .claudeCode, command: "cat .env")))
        let request = Fixture.request(format: .json, kinds: [.riskEvents], directory: dir)

        let artifacts = try ExportCoordinator().run(request, records: records)
        #expect(artifacts.count == 1)
        let text = String(decoding: try bytes(of: artifacts[0].url), as: UTF8.self)
        #expect(text.contains("‹redacted:"))
        #expect(text.contains(secret) == false)
        #expect(text.contains("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789") == false)
    }

    @Test("从服务分页采集：pageSize=2 取满 5 会话与 5 事件并自然终止")
    func pagingFromService() async throws {
        let dir = try exportScratch("paging")
        defer { removeScratch(dir) }
        let service = StubObservatoryService(
            sessions: (1...5).map { Fixture.session($0, ended: $0 < 5) },
            events: (1...5).map { Fixture.event($0) })
        let request = Fixture.request(format: .json, kinds: [.sessions, .timeline], directory: dir)

        let artifacts = try await ExportCoordinator().run(request, service: service, pageSize: 2)

        #expect(artifacts.map(\.recordCount) == [5, 5])
        for artifact in artifacts {
            #expect(try jsonItems(of: artifact.url).count == artifact.recordCount)
        }
    }

    @Test("服务分页且指定上限 → 不越取，仍保留最新的 N 条")
    func pagingRespectsCap() async throws {
        let dir = try exportScratch("paging-cap")
        defer { removeScratch(dir) }
        let service = StubObservatoryService(sessions: (1...9).map { Fixture.session($0) }, events: [])
        let request = Fixture.request(format: .json, kinds: [.sessions], directory: dir, maximum: 3)

        let artifacts = try await ExportCoordinator().run(request, service: service, pageSize: 2)

        #expect(artifacts[0].recordCount == 3)
        let indexes = try jsonItems(of: artifacts[0].url).compactMap { $0["display_index"] as? Int }
        #expect(indexes == [107, 108, 109], "截断必须留下最新的三条")
    }
}

// MARK: - CSV 行数（本文件内部使用的最小辅助，不依赖其它套件）

private enum CSVExporterTestsParse {
    /// 按 CRLF 统计行数（尾部行尾不计成空行）。
    static func rowCount(of url: URL) throws -> Int {
        var text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        if text.hasPrefix("\u{FEFF}") { text = String(text.dropFirst()) }
        if text.hasSuffix("\r\n") { text = String(text.dropLast(2)) }
        return text.split(separator: "\r\n", omittingEmptySubsequences: false).count
    }
}

// MARK: - 只读服务替身

/// 只提供导出需要的分页查询；其余方法返回空值，用来验证分页循环会终止。
private struct StubObservatoryService: ObservatoryService {
    var sessions: [AgentSession] = []
    var events: [TimelineEvent] = []

    func dashboardStats(for date: Date) async throws -> DashboardStats { .empty }
    func activeAgents() async throws -> [AgentInstance] { [] }
    func session(id: UUID) async throws -> AgentSession? { nil }
    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        Page(items: [], totalCount: 0, offset: query.offset)
    }
    func fileDiff(for changeID: UUID) async throws -> FileDiff? { nil }
    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        Page(items: [], totalCount: 0, offset: query.offset)
    }
    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] { [] }
    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] { [] }
    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        Page(items: [], totalCount: 0, offset: query.offset)
    }
    func projects() async throws -> [ProjectActivity] { [] }
    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? { nil }

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        page(sessions, by: { $0.startedAt }, descending: query.sort.descending,
             limit: query.limit, offset: query.offset)
    }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        page(events, by: { $0.timestamp }, descending: query.sort.descending,
             limit: query.limit, offset: query.offset)
    }

    /// 真实实现会遵守 `SortOrder`，替身也必须遵守 —— 否则「上限保留最新 N 条」的断言会因错误的原因通过。
    private func page<Element>(_ all: [Element], by key: (Element) -> Date, descending: Bool,
                              limit: Int, offset: Int) -> Page<Element>
    where Element: Sendable & Codable {
        let sorted = all.sorted { descending ? key($0) > key($1) : key($0) < key($1) }
        let start = min(max(0, offset), sorted.count)
        let end = min(sorted.count, start + max(1, limit))
        return Page(items: Array(sorted[start..<end]), totalCount: all.count, offset: start)
    }
}
