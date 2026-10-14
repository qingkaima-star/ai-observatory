//
//  SessionChangeInventoryTests.swift
//  Tests/AIObservatoryUITests
//
//  Owner: ws/engaudit（#60，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  #60 的四条硬要求，一条一格，每格都判"能核对的数"而不是"看着对"：
//   1. 等价：清单条数 == 该会话 `file_changes` **行数**（同一文件被改多次 ⇒ 不许并成一行）；
//   2. 非 git 目录如实说「无版本控制，无法回滚」、探针问不到说「未能确认」——**都不许说成"干净"**；
//   3. 红线：只读。在**真 git 夹具**上跑完清单之后，整棵树（含 `.git`、含 mtime）sha256 必须逐字节不变，
//      且脏文件必须还是脏的（被 `git checkout` 过的话它会"变干净" ⇒ 当场暴露）；
//   4. 没有动 `Store/**`：只用既有的 `fileChanges(matching:)`（`fileDiff(for:)` 由界面懒查）。
//
//  另三格是给仪器本身的：脏路径解析（重命名的 NUL 双字段、带空格/中文的路径）、
//  白名单（逐个钉会写人的子命令 + 参数数组里子命令位怎么取）、分页（超过单页必须翻完，
//  否则等价式只在头 100 行成立）。
//

import Foundation
import CryptoKit
import os
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 桩

/// 记着"被问了什么"的只读 git 桩。产品代码若偷偷问出白名单之外的东西，这里就会看见。
private struct ScriptedGitReader: GitReadOnlyReading {
    let inside: Bool
    let root: String
    let statusZ: String
    let failing: Bool
    private let asked = OSAllocatedUnfairLock(initialState: [String]())

    init(inside: Bool = true, root: String = "/repo", statusZ: String = "", failing: Bool = false) {
        self.inside = inside
        self.root = root
        self.statusZ = statusZ
        self.failing = failing
    }

    var askedSubcommands: [String] { asked.withLock { $0 } }

    func run(_ invocation: GitReadOnlyInvocation) async throws -> String {
        asked.withLock { $0.append(invocation.subcommand) }
        if failing { throw GitReadingError.gitNotFound }
        switch invocation {
        case .isInsideWorkTree: return inside ? "true\n" : "false\n"
        case .repositoryRoot: return root + "\n"
        case .status: return statusZ
        }
    }
}

// MARK: - 夹具

private let project = "/repo/Project"
private let sessionID = StableID.uuid(namespace: "sess60", key: "session")

private func change(_ index: Int, path: String, kind: FileChangeKind = .modified) -> FileChange {
    var made = FileChange(
        id: StableID.uuid(namespace: "sess60", key: "c\(index)"),
        path: path,
        kind: kind,
        timestamp: Date(timeIntervalSince1970: 1_900_100_000 + Double(index)),
        agentKind: .claudeCode,
        linesAdded: 3,
        linesRemoved: 1,
        projectPath: project
    )
    made.sessionID = sessionID
    return made
}

private func row(_ index: Int, path: String, kind: FileChangeKind = .modified,
                 at projectPath: String = project) -> SessionChangeRow {
    SessionChangeRow.make(
        changeID: StableID.uuid(namespace: "sess60", key: "r\(index)"),
        path: path,
        projectPath: projectPath,
        kind: kind,
        timestamp: Date(timeIntervalSince1970: 1_900_100_000),
        linesAdded: 1,
        linesRemoved: 0
    )
}

private func builder(_ reader: any GitReadOnlyReading = ScriptedGitReader()) -> SessionChangeInventoryBuilder {
    SessionChangeInventoryBuilder(reader: reader)
}

// MARK: - 1. 等价

@Suite("会话改动清单：条数等价式")
struct SessionChangeInventoryEquivalenceTests {

    @Test("清单条数 == 该会话 file_changes 行数（12 行，其中两个文件各被改两次）")
    func changeCountEqualsServerRows() async throws {
        // 手推形状：12 行、9 个不同文件 ⇒ F0 三次、F1 两次（"去重成 9 行"就是把等价式做假）。
        var changes: [FileChange] = []
        for index in 0..<7 { changes.append(change(index, path: "\(project)/Sources/F\(index).swift")) }
        changes.append(change(7, path: "\(project)/Sources/F0.swift"))
        changes.append(change(8, path: "\(project)/Sources/F0.swift", kind: .created))
        changes.append(change(9, path: "\(project)/Sources/F1.swift"))
        changes.append(change(10, path: "\(project)/README.md", kind: .created))
        changes.append(change(11, path: "\(project)/Package.swift", kind: .deleted))
        // 别的会话的行不许混进来（等价式右边是"**该会话**"的行数）。
        var stranger = change(99, path: "\(project)/Other.swift")
        stranger.sessionID = StableID.uuid(namespace: "sess60", key: "another-session")
        let service = InMemoryObservatoryService()
        service.seed(fileChanges: changes + [stranger])

        let inventory = try await builder().inventory(sessionID: sessionID, from: service, skipProbe: true)

        #expect(inventory.changeCount == 12, "该会话有 12 行 file_changes，清单却给了 \(inventory.changeCount) 行")
        #expect(inventory.serverRowCount == 12, "服务端报的总行数也该是 12，实得 \(inventory.serverRowCount)")
        #expect(inventory.fileCount == 9, "12 行落在 9 个文件上：F0..F6 七个 + README + Package（F0 三次、F1 两次不另计），实得 \(inventory.fileCount)")
        #expect(inventory.isComplete, "没触顶却标了截断 ⇒ 界面会少报")
    }

    @Test("超过单页（100）必须翻页取完：250 行的会话等价式仍然成立")
    func pagesUntilExhausted() async throws {
        let many = (0..<250).map { change($0, path: "\(project)/Sources/G\($0).swift") }
        let service = InMemoryObservatoryService()
        service.seed(fileChanges: many)
        let inventory = try await builder().inventory(sessionID: sessionID, from: service, skipProbe: true)
        #expect(inventory.changeCount == 250, "翻页没翻完就交了清单：实得 \(inventory.changeCount)")
        #expect(inventory.isComplete)
    }
}

// MARK: - 2. 三态诚实

@Suite("会话改动清单：版本控制三态不许塌成'干净'")
struct SessionChangeInventoryHonestyTests {

    @Test("目录不在 git 里：判成 notVersioned，且绝不是 committed")
    func nonGitSaysNotVersioned() async {
        let target = row(0, path: "\(project)/A.swift")
        let read = await builder(ScriptedGitReader(inside: false)).build(
            rows: [target], serverRowCount: 1, isComplete: true
        )
        let status = read.rollbackStatus(for: target)
        #expect(status == .notVersioned)
        #expect(status != .committed, "非版本控制目录被渲染成'干净'——那是界面在说谎")
    }

    @Test("探针问不到（git 不可用/超时）：unknown，且绝不是 committed")
    func probeFailureIsUnknown() async {
        let target = row(1, path: "\(project)/A.swift")
        let read = await builder(ScriptedGitReader(failing: true)).build(
            rows: [target], serverRowCount: 1, isComplete: true
        )
        let status = read.rollbackStatus(for: target)
        #expect(status == .unknown)
        #expect(status != .committed && status != .notVersioned, "问不到冒充了任何一种确定结论")
    }

    @Test("仓库根对不上这个路径（外部/软链）：unknown，不许蒙成 committed")
    func outsideRepositoryRootIsUnknown() async {
        let target = row(2, path: "\(project)/A.swift")
        let read = await builder(ScriptedGitReader(root: "/somewhere/else")).build(
            rows: [target], serverRowCount: 1, isComplete: true
        )
        #expect(read.rollbackStatus(for: target) == .unknown)
    }

    @Test("在 git 里：脏 ⇒ uncommitted，不脏 ⇒ committed，未跟踪也算'还没提交'")
    func managedDistinguishesDirtyFromClean() async {
        let statusZ = " M Project/Sources/A.swift\0?? Project/new.txt\0"
        let modified = row(3, path: "\(project)/Sources/A.swift")
        let clean = row(4, path: "\(project)/Sources/Clean.swift")
        let untracked = row(5, path: "\(project)/new.txt", kind: .created)
        let read = await builder(ScriptedGitReader(inside: true, root: "/repo", statusZ: statusZ))
            .build(rows: [modified, clean, untracked], serverRowCount: 3, isComplete: true)
        #expect(read.rollbackStatus(for: modified) == .uncommitted)
        #expect(read.rollbackStatus(for: clean) == .committed)
        #expect(read.rollbackStatus(for: untracked) == .uncommitted, "未跟踪文件也是「还没提交」")
        #expect(read.uncommittedCount == 2)
        #expect(read.unknownCount == 0)
    }

    @Test("探针只问读子命令：rev-parse / status，一次写操作都没有")
    func probeOnlyAsksReadOnlyCommands() async {
        let reader = ScriptedGitReader()
        _ = await builder(reader).build(rows: [row(6, path: "\(project)/A.swift")],
                                        serverRowCount: 1, isComplete: true)
        #expect(reader.askedSubcommands == ["rev-parse", "rev-parse", "status"],
                "探针问了计划之外的东西：\(reader.askedSubcommands)")
    }
}

// MARK: - 3. 脏路径解析

@Suite("git status --porcelain=v1 -z 的解析")
struct GitStatusParsingTests {

    @Test("状态码逐类给出手推集合（含重命名的 NUL 双字段、带空格与中文的路径）")
    func parsesEveryStateShape() {
        let payload = [
            " M Project/a.swift",              // 已改未 add
            "A  Project/added.swift",          // 已 add 未 commit
            "?? Project/new file.txt",         // 未跟踪，带空格
            "D  Project/删除.txt",             // 已删未 commit，中文
            "R  Project/new.swift", "Project/old.swift",   // 重命名：两条 NUL 字段
            "M  Project/staged.swift",         // 已 staged
        ].joined(separator: "\0") + "\0"

        let dirty = GitReadOnlyInvocation.dirtyPaths(fromStatusZ: payload)
        #expect(dirty == Set([
            "Project/a.swift", "Project/added.swift", "Project/new file.txt",
            "Project/删除.txt", "Project/new.swift", "Project/old.swift", "Project/staged.swift",
        ]), "脏路径集合不对，实得 \(dirty.sorted())")
    }

    @Test("空输出 = 零脏路径（**不等于**「这个目录没有版本控制」）")
    func emptyOutputMeansNothingDirty() {
        #expect(GitReadOnlyInvocation.dirtyPaths(fromStatusZ: "").isEmpty)
        #expect(GitReadOnlyInvocation.dirtyPaths(fromStatusZ: "\0\0").isEmpty)
    }
}

// MARK: - 4. 白名单与"spawn 之前"的守卫

@Suite("只读探针的白名单")
struct GitReadOnlyAllowlistTests {

    @Test("三种内置调用都在白名单内，且参数里的子命令位解析正确")
    func builtInInvocationsAreAllowed() throws {
        for invocation in [
            GitReadOnlyInvocation.isInsideWorkTree(directory: "/tmp"),
            .repositoryRoot(directory: "/tmp"),
            .status(directory: "/tmp"),
        ] {
            #expect(invocation.isAllowed, "\(invocation.subcommand) 竟然不在白名单里")
            try SystemGitReader.guardAllows(arguments: invocation.arguments)
        }
        // `-c` 的赋值串不能被当成子命令（否则 `core.quotepath=false` 会让守卫看错位置）。
        #expect(GitReadOnlyInvocation.subcommand(
            in: GitReadOnlyInvocation.status(directory: "/tmp").arguments
        ) == "status")
    }

    @Test(arguments: ["checkout", "switch", "restore", "stash", "reset", "clean", "rm", "mv",
                      "add", "commit", "merge", "rebase", "apply", "am", "cherry-pick",
                      "push", "fetch", "pull", "gc", "prune", "update-index", "write-tree",
                      "init", "clone", "worktree"])
    func mutatingSubcommandsAreRejected(_ subcommand: String) {
        #expect(!GitReadOnlyInvocation.isAllowed(subcommand: subcommand),
                "白名单里出现了会改工作区的子命令：\(subcommand)")
        // 绕开枚举、直接拼参数的那条路也必须被同一道门拦下（进程不起）。
        #expect(throws: GitReadingError.mutatingCommandRejected(subcommand: subcommand)) {
            try SystemGitReader.guardAllows(arguments: ["--no-optional-locks", subcommand, "."])
        }
    }

    @Test("空参数 / 只给选项：也拒（守卫不许「找不到子命令就放行」）")
    func shapelessArgumentsAreRejected() {
        #expect(throws: GitReadingError.mutatingCommandRejected(subcommand: "<no subcommand in arguments>")) {
            try SystemGitReader.guardAllows(arguments: [])
        }
        #expect(throws: GitReadingError.mutatingCommandRejected(subcommand: "<no subcommand in arguments>")) {
            try SystemGitReader.guardAllows(arguments: ["--version"])
        }
    }
}

// MARK: - 5. 红线：真 git 夹具上整棵树 sha256 不变

@Suite("红线：探针只读 —— 真 git 夹具跑完，整棵树逐字节不变", .serialized)
struct GitProbeReadOnlyTests {

    /// 整棵树的指纹：**含 `.git`**，且把每个文件的 mtime 一起算进去。
    /// 只哈希内容会漏两类越界：① `git status` 默认会重写 `.git/index`（stat 缓存）；
    /// ② 任何"顺手 touch 一下"。少了 mtime，这两类都能悄悄过。
    private func fingerprint(_ root: URL) throws -> String {
        var digest = SHA256()
        for line in try collect(root, relativeTo: root.standardizedFileURL).sorted() {
            digest.update(data: Data(line.utf8))
        }
        return digest.finalize().hexString
    }

    private func collect(_ directory: URL, relativeTo root: URL) throws -> [String] {
        var lines: [String] = []
        var queue: [URL] = [directory]
        while let current = queue.popLast() {
            let names = try FileManager.default.contentsOfDirectory(atPath: current.path).sorted()
            for name in names {
                let childURL = current.appendingPathComponent(name)
                var isDirectory: ObjCBool = false
                guard FileManager.default.fileExists(atPath: childURL.path, isDirectory: &isDirectory) else { continue }
                if isDirectory.boolValue {
                    queue.append(childURL)
                    continue
                }
                let values = try childURL.resourceValues(forKeys: [
                    .isRegularFileKey, .contentModificationDateKey,
                ])
                guard values.isRegularFile == true else { continue }   // 符号链接等特殊文件不参与指纹
                var fileDigest = SHA256()
                fileDigest.update(data: try Data(contentsOf: childURL))
                lines.append(
                    "\(childURL.path.replacingOccurrences(of: root.path, with: ""))"
                        + "|\(values.contentModificationDate?.timeIntervalSince1970 ?? -1)"
                        + "|\(fileDigest.finalize().hexString)"
                )
            }
        }
        return lines
    }

    @Test("在真 git 库上跑清单：树指纹不变、脏文件仍脏、判定也确实跑通了")
    func probeLeavesTheWorkingTreeUntouched() async throws {
        let gitPath = "/usr/bin/git"
        #expect(FileManager.default.isExecutableFile(atPath: gitPath),
                "这台机器没有可用的 git ⇒ 红线守卫测不出任何东西，必须红而不是静默跳过")
        let scratch = try Scratch.directory("gitreadonly")

        func git(_ arguments: [String]) async throws {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: gitPath)
            process.arguments = arguments
            process.currentDirectoryURL = scratch
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0, "夹具 git 命令失败：\(arguments)")
        }

        try FileManager.default.createDirectory(at: scratch.appendingPathComponent("Sources"),
                                                withIntermediateDirectories: true)
        let file = scratch.appendingPathComponent("Sources/A.swift")
        try "original\n".write(to: file, atomically: true, encoding: .utf8)
        try await git(["init", "-q", "."])
        let identity = ["-c", "user.email=t@invalid", "-c", "user.name=t"]
        try await git(identity + ["add", "."])
        try await git(identity + ["commit", "-qm", "base"])
        // 造"未提交"的现场：改一个已跟踪文件 + 落一个未跟踪文件。
        try "modified by the agent\n".write(to: file, atomically: true, encoding: .utf8)
        try "untracked\n".write(to: scratch.appendingPathComponent("New.txt"), atomically: true, encoding: .utf8)

        let before = try fingerprint(scratch)
        let dirtyContent = try String(contentsOf: file, encoding: .utf8)

        // 走**真执行器**（不是桩）：这一格要防的就是真执行器自己。
        let projectPath = scratch.path
        let rows = [
            row(100, path: "\(projectPath)/Sources/A.swift", at: projectPath),
            row(101, path: "\(projectPath)/New.txt", kind: .created, at: projectPath),
        ]
        let inventory = await builder(SystemGitReader()).build(
            rows: rows, serverRowCount: 2, isComplete: true
        )

        // 判定也必须成立 —— 不然"没写"可能只是因为压根没跑成。
        #expect(inventory.rollbackStatus(for: rows[0]) == .uncommitted,
                "已跟踪且改过没提交的文件，探针应该判成 uncommitted")
        #expect(inventory.rollbackStatus(for: rows[1]) == .uncommitted, "未跟踪文件同样要判成还没提交")

        #expect(try fingerprint(scratch) == before,
                "跑完清单之后工作树（含 .git）指纹变了 ⇒ 越了只读红线")
        #expect(try String(contentsOf: file, encoding: .utf8) == dirtyContent,
                "脏文件内容变了 ⇒ 有代码替用户回滚了改动")
    }
}

extension Sequence where Element == UInt8 {
    var hexString: String { map { String(format: "%02x", $0) }.joined() }
}
