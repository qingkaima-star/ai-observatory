//
//  AixFixture.swift
//  AIObservatoryCLITests
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  用例夹具：临时库 + 已知内容。目录一律走 `Scratch.directory`，
//  **不落宿主绝对路径**（AGENTS.md §0：曾有 13 处落盘用例硬编当次机器的家目录，
//  导致托管 CI 只能对它们 continue-on-error）。
//

import Foundation
import Testing
@testable import AIObservatoryCLI
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

/// `--json` 的 stdout 不是预期形状时报错 —— 不用 `XCTUnwrap` 式的隐式解包。
struct AixFixtureError: Error {}

enum AixFixture {
    /// 固定时刻：所有断言里出现的时间都由它推出来，不读墙钟。
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    static func stamp(_ offset: TimeInterval) -> Date { now.addingTimeInterval(offset) }

    /// 在临时目录里建一份**当前版本**的库，并按引擎的入库约定灌入行。
    ///
    /// 约定（`ObservatoryEngine.swift:1211` 一族）：未归属 ⇒ `agentID == nil` **且** `agentKind == .unknown`。
    /// 返回该目录，调用方把 `observatory.sqlite` 拼上去就是 `--data-dir` 要指的东西。
    static func store(in directory: URL) async throws -> ObservatoryStore {
        try await ObservatoryStore.open(configuration: .file(databasePath(in: directory).path))
    }

    static func databasePath(in directory: URL) -> URL {
        directory.appending(path: AixDataLocation.databaseFileName)
    }

    /// 逐条缓冲写入。`ObservatoryStore` 只有单条 `append(_:)`，没有批量入口 ——
    /// 而缓冲写通道要 `flush()` 之后才查得到（用例轮询前先 flush，这是本仓踩过的一族）。
    static func append(_ store: ObservatoryStore, _ changes: [FileChange]) async {
        for change in changes { await store.append(change) }
    }

    /// 未归属的文件变更行（agent_id 为 NULL）。
    static func unattributedChanges(count: Int, prefix: String = "loose") -> [FileChange] {
        (0..<count).map { index in
            FileChange(
                id: UUID(), path: "/repo/\(prefix)/\(index).txt", kind: .modified,
                timestamp: stamp(TimeInterval(index)), agentID: nil, agentKind: .unknown
            )
        }
    }

    /// 已归属的文件变更行。
    static func attributedChanges(count: Int, agent: UUID, prefix: String = "owned") -> [FileChange] {
        (0..<count).map { index in
            FileChange(
                id: UUID(), path: "/repo/\(prefix)/\(index).txt", kind: .created,
                timestamp: stamp(TimeInterval(100 + index)), agentID: agent, agentKind: .claudeCode,
                sizeBytes: 16
            )
        }
    }

    static func agent(pid: Int32, name: String, state: AgentRunState = .running) -> AgentInstance {
        AgentInstance(
            kind: .openAICodex, pid: pid, displayName: name, executablePath: "/usr/bin/\(name)",
            workingDirectory: "/repo/\(name)", startedAt: stamp(-60), lastSeenAt: stamp(0), state: state
        )
    }

    static func session(_ kind: AgentKind = .claudeCode, index: Int = 1) -> AgentSession {
        AgentSession(kind: kind, title: "会话 \(index)", projectPath: "/repo/demo",
                     startedAt: stamp(-120), endedAt: stamp(-30), outcome: .success)
    }

    static func command(_ line: String, agent: UUID? = nil) -> CommandRecord {
        CommandRecord(
            executable: "/bin/sh", arguments: ["-c", line], workingDirectory: "/repo",
            agentID: agent, agentKind: agent == nil ? .unknown : .claudeCode,
            startedAt: stamp(-10), endedAt: stamp(-9), exitCode: 0, outcome: .success
        )
    }

    static func risk(_ level: RiskLevel, title: String, agent: UUID? = nil) -> RiskEvent {
        RiskEvent(
            timestamp: stamp(-5), level: level, category: .dangerousCommand, title: title,
            detail: title, agentID: agent, agentKind: agent == nil ? .unknown : .claudeCode
        )
    }

    /// 解析 `aix --json` 的 stdout：返回顶层对象与 `items` 数组。
    static func document(_ stdout: String) throws -> [String: Any] {
        let data = Data(stdout.utf8)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AixFixtureError()
        }
        return object
    }

    static func items(_ stdout: String) throws -> [Any] {
        guard let array = try document(stdout)["items"] as? [Any] else {
            throw AixFixtureError()
        }
        return array
    }
}

/// 读一个路径的 POSIX 权限位。用例改完 `0o000` 之后要按**原值**恢复，
/// 不能写死 `0o644` —— 那是另一处"把现场当成默认值"。
func permissions(of path: String) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: path)
    return (attributes?[.posixPermissions] as? Int) ?? 0o644
}

/// 从测试运行位置往上找到包根，再读源文件。
/// 用在「源码级接线断言」上：比对两份实现引用的同一批常量，漂移当场红。
enum AixSourceTree {
    static let root: URL = {
        var url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        for _ in 0..<8 {
            if FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) { return url }
            url.deleteLastPathComponent()
        }
        Issue.record("找不到包根（Package.swift），源码级断言无法进行")
        return url
    }()

    static func text(_ relativePath: String) throws -> String {
        let url = root.appending(path: relativePath)
        guard let data = FileManager.default.contents(atPath: url.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        return String(decoding: data, as: UTF8.self)
    }

    /// 扫一个目录下的全部 `.swift`。**指目录、不指单个文件** —— 锚点写死某个文件时，
    /// 一次重构把字面量搬走就会把对拍尺子弄红（`observatory.sqlite` 那个锚点这轮就被
    /// `ws/health` 的引擎拆分挪走过，同一形状本波已第三次）。带上"扫到几份"的分母守卫，
    /// 否则目录改名后扫到 0 份也会假装通过。
    static func codeFiles(under relativeDirectory: String) throws -> [String] {
        let directory = root.appending(path: relativeDirectory)
        let urls = try FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
        return try urls.filter { $0.pathExtension == "swift" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .map { try text(relativeDirectory + "/" + $0.lastPathComponent) }
    }

    /// 剥掉注释后的源码 —— 否则「注释里提到某个字符串」会被当成接线存在（#20 那一族假绿）。
    static func codeOnly(_ relativePath: String) throws -> String {
        let raw = try text(relativePath)
        var output: [String] = []
        for line in raw.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("///") { continue }
            output.append(String(line))
        }
        return output.joined(separator: "\n")
    }
}
