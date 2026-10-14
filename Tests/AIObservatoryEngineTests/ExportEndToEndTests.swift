//
//  ExportEndToEndTests.swift
//  AIObservatoryEngineTests
//
//  Owner: master-controller
//
//  补 WS-Export 自己声明的唯一未验证项：它的 62 个用例跑的是自写内存替身，
//  **从未对真实 SQLite 库端到端跑过导出**。这里让引擎真实采集 → 落文件库 →
//  导出读回，用产物存在且条数正确来钉住整条链路。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryExport
import AIObservatoryStore
import AIObservatoryTestSupport

@Suite("导出端到端：真实 SQLite 库 → 文件产物", .timeLimit(.minutes(1)))
struct ExportEndToEndTests {

    private func scratch(_ name: String) throws -> URL {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = repoRoot.appending(path: ".scratch-tests").appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 让引擎跑够至少一轮采集（不靠固定 sleep 猜时间）。
    private func eventually(_ condition: @Sendable () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(60))
        }
        Issue.record("等待条件超时（8 秒）")
    }

    @Test("引擎采集的真实数据能被导出成 JSON 与 Markdown 产物")
    func engineDataExportsToFileBackedArtifacts() async throws {
        let workspace = try scratch("export-e2e")
        let databaseDirectory = workspace.appending(path: "db").path
        let outputDirectory = workspace.appending(path: "out")
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let store = try await ObservatoryStore.open(
            configuration: .file(databaseDirectory + "/observatory.sqlite")
        )
        let mapper = ProjectMapper(resolver: { _ in nil })
        let agent = AgentInstance(
            kind: .claudeCode,
            pid: 41_001,
            displayName: "Claude Code",
            executablePath: "/usr/local/lib/node_modules/@anthropic-ai/claude-code/cli.js",
            workingDirectory: "/Users/demo/Projects/Mona",
            startedAt: Date().addingTimeInterval(-600),
            state: .running
        )
        let engine = ObservatoryEngine(
            settings: ObservatorySettings(storeDirectory: databaseDirectory),
            components: ObservatoryEngine.Components(
                storeSource: .ready(store),
                detector: StubDetector(agents: [agent]),
                processInspector: StubProcessSource(),
                metrics: StubMetrics(),
                commandAuditor: StubAuditor(),
                fileObserver: StubFileObserver(),
                snapshotter: StubSnapshotter(providesContent: false),
                differ: StubDiffer(),
                aggregator: TimelineAggregator(projectMapper: mapper),
                projectMapper: mapper
            )
        )

        await engine.start()
        defer { Task { await engine.stop() } }

        // 真的落库了才继续——否则下面的导出断言会变成「导出空集合也通过」的假证据。
        try await eventually {
            let sessions = try await engine.sessions(matching: SessionQuery(limit: 10))
            return sessions.totalCount > 0
        }

        let request = ExportRequest(
            format: .json,
            kinds: [.sessions, .timeline],
            generatedAt: Date(timeIntervalSince1970: 1_700_000_000),
            destination: ExportDestination(
                directory: outputDirectory,
                baseName: "e2e",
                allowedRoots: [outputDirectory]
            )
        )
        let artifacts = try await ExportCoordinator().run(request, service: engine)

        #expect(artifacts.count == 2)
        for artifact in artifacts {
            let url = artifact.url
            #expect(FileManager.default.fileExists(atPath: url.path), "产物缺失：\(url.path)")
            let data = try Data(contentsOf: url)
            #expect(!data.isEmpty, "产物为空：\(url.path)")
            // 落盘的必须是能解析的 JSON 信封，而不是半截字节流。
            let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(envelope != nil, "产物不是合法 JSON 对象：\(url.path)")
            #expect(envelope?["schemaVersion"] != nil, "缺少 schemaVersion：\(url.path)")
            let items = envelope?["items"] as? [Any]
            #expect(items != nil, "缺少 items 数组：\(url.path)")
            #expect(artifact.recordCount == (items?.count ?? -1),
                    "recordCount 与实际条数不符：\(artifact.recordCount) vs \(items?.count ?? -1)")
        }

        // 导出必须真的读到引擎写进 SQLite 的会话，而不是空集。
        let sessionsArtifact = try #require(artifacts.first { $0.kind == .sessions })
        // 桩识别器只有 1 个 agent ⇒ 会话产物恰好 1 条；`> 0` 连「导出把同一条写了两遍」都放过。
        #expect(sessionsArtifact.recordCount == 1, "导出读不到引擎写入的会话")
    }

    @Test("拒绝写到用户选定目录之外")
    func refusesDestinationOutsideAllowedRoots() async throws {
        let workspace = try scratch("export-guard")
        let allowed = workspace.appending(path: "allowed")
        let forbidden = workspace.appending(path: "forbidden")
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let request = ExportRequest(
            format: .json,
            kinds: [.sessions],
            destination: ExportDestination(
                directory: forbidden,
                baseName: "leak",
                allowedRoots: [allowed]
            )
        )
        await #expect(throws: (any Error).self) {
            _ = try await ExportCoordinator().run(request, service: InMemoryObservatoryService())
        }
        // 被拒时不得留下任何文件：目录不存在，或存在但为空，两者都算通过。
        let entries = try? FileManager.default.contentsOfDirectory(atPath: forbidden.path)
        #expect(entries == nil || entries?.isEmpty == true, "被拒后仍留下文件：\(entries ?? [])")
    }
}
