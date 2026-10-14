//
//  SessionChangeInventory.swift
//  AIObservatoryUI / Sessions
//
//  Owner: ws/engaudit（#60，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  会话详情里那份「本次改动清单」的读模型 + **只读** git 探针。
//  需求方要的那一句是："AI 说改好了" 之后，用户得能一眼看到
//  这个会话动了哪些文件、哪些还没提交、能不能退回。
//
//  三条不显然的设计决定，各有用例钉着（别靠读代码确认）：
//
//  1. **清单按"行"算，不按"去重后的文件"算。**
//     需求原话是"动了哪 12 个文件"，而可验收的等价式是「清单条数 == 该会话 `file_changes` 行数」。
//     同一个文件被改三次 ⇒ 那是三行（三次现场），去重就把等价式做假了。
//     ⇒ 每行是一条改动；标题同时给两个数（`N 次改动 · M 个文件`），口径不藏。
//
//  2. **"问不到"、"没有版本控制"、"干净"是三件事。**
//     只有 `managed` 且确实不在脏集合里，才可以说"已提交"；
//     非 git 目录必须说「无版本控制，无法回滚」；探针失败必须说「未能确认」。
//     ⇒ 三态用 `FileRollbackStatus` 表达，**没有** 一个 `Bool` 可以顺手 `?? false`。
//
//  3. **红线：只读。** 三层缺一不可：
//       · 参数只能由 `GitReadOnlyInvocation` 这个枚举构造（外部拼不出别的形状）；
//       · 执行器在 spawn 之前再核一次白名单 ⇒ 拒执行时**进程根本没起**；
//       · 用例拿真夹具 git 库，跑完清单后对**整棵树（含 `.git`、含 mtime）**取 sha256 比对。
//     ⚠️ 一个容易漏的细节：`git status` 默认会刷新 index 的 stat 缓存并**写 `.git/index`**
//     —— 它自称只读，其实会落盘。所以命令必须带 `--no-optional-locks`；
//     少带它，第 3 层守卫就会红，而那正是它该有的反应。
//

import Foundation
import AIObservatoryCore

// MARK: - 单个文件的回滚口径

/// 一条改动对应的文件"能不能退回"的判定结果。**四态，故意不用 Bool。**
enum FileRollbackStatus: Hashable, Sendable {
    /// 在 git 工作树里且有未提交变更 ⇒ 可以退回（`git checkout -- <path>` 由用户自己决定要不要跑）。
    case uncommitted
    /// 在 git 工作树里且该文件不在脏集合里 ⇒ 已提交。
    case committed
    /// 目录不在版本控制下 ⇒ 界面必须写「无版本控制，无法回滚」。
    case notVersioned
    /// 没能问到（git 不可用、超时、路径无项目归属）。⚠️ 不许渲染成"干净"。
    case unknown
}

/// 某个目录的版本控制实况。
enum ProjectVersionState: Hashable, Sendable {
    case notARepository
    /// 探针跑通。`repositoryRoot` 是 `git rev-parse --show-toplevel` 的原样输出；
    /// `dirtyPaths` 是**相对仓库根**的路径集合（改动含未跟踪、已删、已 staged 未提交）。
    case managed(repositoryRoot: String, dirtyPaths: Set<String>)
    case probeUnavailable(reason: String)

    /// 判定某个绝对路径。`nil` = 该目录的结论不适用于这个路径（不在仓库根下）。
    func rollbackStatus(forAbsolutePath path: String) -> FileRollbackStatus? {
        switch self {
        case .notARepository:
            return .notVersioned
        case .probeUnavailable:
            return .unknown
        case .managed(let root, let dirty):
            let prefix = root.hasSuffix("/") ? root : root + "/"
            guard path.hasPrefix(prefix) else { return nil }
            return dirty.contains(String(path.dropFirst(prefix.count))) ? .uncommitted : .committed
        }
    }
}

// MARK: - 只读 git 调用

/// 探针**唯一**会发出的三种调用。做成枚举而不是 `[String]`，
/// 是为了让"顺手加一句 stash"在这一层就拼不出来、并且过不了白名单。
enum GitReadOnlyInvocation: Hashable, Sendable {
    case isInsideWorkTree(directory: String)
    case repositoryRoot(directory: String)
    case status(directory: String)

    /// 传给 `git` 的参数（不含可执行文件）。
    ///
    /// `--no-optional-locks`：不许写 `.git/index`（见文件头第 3 条）。
    /// `core.quotepath=false`：中文/空格路径按原样输出，别转义成 `"\346\226\207…"`。
    /// `--porcelain=v1 -z`：机器可读 + NUL 分隔（文件名可以带换行，行式解析会被骗）。
    var arguments: [String] {
        switch self {
        case .isInsideWorkTree:
            return ["--no-optional-locks", "rev-parse", "--is-inside-work-tree"]
        case .repositoryRoot:
            return ["--no-optional-locks", "rev-parse", "--show-toplevel"]
        case .status:
            return [
                "--no-optional-locks", "-c", "core.quotepath=false",
                "status", "--porcelain=v1", "-z", "--untracked-files=all",
            ]
        }
    }

    /// 子命令。白名单只看它——整条命令行里塞个 `--help` 或路径叫 `stash.sh` 都不算数。
    var subcommand: String {
        arguments.contains("status") ? "status" : "rev-parse"
    }

    /// 只允许这两个**读**子命令。`checkout` / `stash` / `reset` / `clean` / `restore` /
    /// `apply` / `commit` / `push` / `gc` 等一律拒。
    static let allowedSubcommands: Set<String> = ["rev-parse", "status"]

    /// 白名单判定的**唯一入口**。它看的是"真正要传给 git 的那串参数里的子命令位"，
    /// 而不是调用方自称是哪个子命令 —— 第二层守卫要防的正是"以后有人绕着枚举直接拼参数"。
    static func isAllowed(subcommand: String) -> Bool { allowedSubcommands.contains(subcommand) }

    /// 从参数数组里取出子命令位：跳过以 `-` 开头的选项，并跳过 `-c` 后面那个赋值串。
    static func subcommand(in arguments: [String]) -> String? {
        var skipNext = false
        for token in arguments {
            if skipNext { skipNext = false; continue }
            if token == "-c" || token == "--no-optional-locks" { skipNext = (token == "-c"); continue }
            if token.hasPrefix("-") { continue }
            return token
        }
        return nil
    }

    var isAllowed: Bool { Self.isAllowed(subcommand: subcommand) }

    var directory: String {
        switch self {
        case .isInsideWorkTree(let d), .repositoryRoot(let d), .status(let d): return d
        }
    }

    /// `git status --porcelain=v1 -z` 的输出 → 相对仓库根的脏路径集合。
    ///
    /// `-z` 的记录形状是 `XY <path>`，NUL 分隔；**重命名/复制例外**：
    /// `R  new\0old` 是两条 NUL 记录，第二条必须按"原文路径"处理掉，
    /// 否则它会被当成一条新记录、把 old 的前两个字符当状态码解析出垃圾。
    static func dirtyPaths(fromStatusZ output: String) -> Set<String> {
        let fields = output.components(separatedBy: "\0")
        var dirty: Set<String> = []
        var index = 0
        while index < fields.count {
            let record = fields[index]
            index += 1
            guard record.count >= 4 else { continue }
            // 记录形状固定是 `XY␠path`：X = 暂存区状态，Y = 工作树状态，两个字符 + 一个空格。
            let state = record.prefix(2)
            let path = String(record.dropFirst(3))
            if state.first == "R" || state.first == "C" {
                // 紧随其后的一条是"从哪来"。两边都算脏：旧路径没了，同样是未提交的改动。
                if index < fields.count {
                    let origin = fields[index]
                    index += 1
                    if !origin.isEmpty { dirty.insert(origin) }
                }
                dirty.insert(path)
                continue
            }
            dirty.insert(path)
        }
        return dirty
    }
}

/// 只读 git 执行者的抽象。测试换成桩，于是"到底问了什么"可以逐条断言，
/// 不必靠真 git 的行为倒推。
protocol GitReadOnlyReading: Sendable {
    /// 抛错 = 没执行。实现**必须**在 spawn 之前完成白名单核对。
    func run(_ invocation: GitReadOnlyInvocation) async throws -> String
}

enum GitReadingError: Error, Hashable, Sendable {
    /// 试图执行白名单之外的子命令（红线拦截点：进程没有起）。
    case mutatingCommandRejected(subcommand: String)
    case gitNotFound
    case launchFailed(String)
    case timedOut(subcommand: String)
}

/// 真执行器。可执行文件写死 `/usr/bin/git`（macOS 自带的 xcode-select 垫片）：
/// 走 `PATH` 等于把"环境里恰好有个同名脚本"变成执行路径的一部分，
/// 一条只读探针不该带这种性质。拿不到就抛 `gitNotFound` ⇒ 界面落到 `unknown`，不是"干净"。
struct SystemGitReader: GitReadOnlyReading {
    static let executablePath = "/usr/bin/git"
    static let timeoutSeconds: TimeInterval = 2

    /// 低层守卫：给参数数组，白名单不过就抛错（**在 spawn 之前**）。
    /// 单独暴露出来，是为了让"绕开枚举直接拼参数"这条路也能被判红。
    static func guardAllows(arguments: [String]) throws {
        guard let subcommand = GitReadOnlyInvocation.subcommand(in: arguments) else {
            throw GitReadingError.mutatingCommandRejected(subcommand: "<no subcommand in arguments>")
        }
        guard GitReadOnlyInvocation.isAllowed(subcommand: subcommand) else {
            throw GitReadingError.mutatingCommandRejected(subcommand: subcommand)
        }
    }

    func run(_ invocation: GitReadOnlyInvocation) async throws -> String {
        try Self.guardAllows(arguments: invocation.arguments)
        guard FileManager.default.isExecutableFile(atPath: Self.executablePath) else {
            throw GitReadingError.gitNotFound
        }
        return try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: Self.executablePath)
            process.arguments = invocation.arguments
            process.currentDirectoryURL = URL(fileURLWithPath: invocation.directory)
            process.standardOutput = output
            process.standardError = Pipe()      // 不丢出去：`not a git repository` 走 stderr
            let finished = DispatchSemaphore(value: 0)
            process.terminationHandler = { _ in finished.signal() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: GitReadingError.launchFailed(error.localizedDescription))
                return
            }
            // 超时也守红线：terminate 杀的是子进程，不碰工作树。
            if finished.wait(timeout: .now() + Self.timeoutSeconds) == .timedOut {
                process.terminate()
                continuation.resume(throwing: GitReadingError.timedOut(subcommand: invocation.subcommand))
                return
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            continuation.resume(returning: String(data: data, encoding: .utf8) ?? "")
        }
    }
}

// MARK: - 读模型

/// 清单里的一条改动（= `file_changes` 的一行，**不去重**）。
struct SessionChangeRow: Identifiable, Hashable, Sendable {
    /// `file_changes.id`：「改前 / 改后」入口点开时用它去取 `fileDiff(for:)`。
    /// 懒查：不为一整页清单先发 N 次查询（那会把一次取数变成 N 次往返）。
    let changeID: UUID
    var id: UUID { changeID }
    let path: String
    /// 这条改动归属的项目目录（服务端 `project_path`；nil 时取文件的父目录）。
    let projectPath: String
    let kind: FileChangeKind
    let timestamp: Date
    let linesAdded: Int
    let linesRemoved: Int

    init(change: FileChange) {
        self.changeID = change.id
        self.path = change.path
        self.projectPath = change.projectPath ?? (change.path as NSString).deletingLastPathComponent
        self.kind = change.kind
        self.timestamp = change.timestamp
        self.linesAdded = change.linesAdded
        self.linesRemoved = change.linesRemoved
    }

    private init(changeID: UUID, path: String, projectPath: String, kind: FileChangeKind,
                 timestamp: Date, linesAdded: Int, linesRemoved: Int) {
        self.changeID = changeID
        self.path = path
        self.projectPath = projectPath
        self.kind = kind
        self.timestamp = timestamp
        self.linesAdded = linesAdded
        self.linesRemoved = linesRemoved
    }

    static func make(changeID: UUID, path: String, projectPath: String, kind: FileChangeKind,
                     timestamp: Date, linesAdded: Int, linesRemoved: Int) -> SessionChangeRow {
        SessionChangeRow(changeID: changeID, path: path, projectPath: projectPath, kind: kind,
                         timestamp: timestamp, linesAdded: linesAdded, linesRemoved: linesRemoved)
    }
}

/// 一个会话的改动清单 + 逐项回滚判定。
struct SessionChangeInventory: Hashable, Sendable {
    var rows: [SessionChangeRow] = []
    /// 项目目录 → 版本控制实况。
    var stateByProject: [String: ProjectVersionState] = [:]
    /// 服务端报的该会话总行数（等价式右边的数）。
    var serverRowCount: Int = 0
    /// 取数是否完整。⚠️ 不满时界面必须说"仅前 N 条"，不能让条数冒充全量。
    var isComplete: Bool = true

    /// 等价式左值：**行数**，不是文件数。
    var changeCount: Int { rows.count }
    var fileCount: Int { Set(rows.map(\.path)).count }

    func rollbackStatus(for row: SessionChangeRow) -> FileRollbackStatus {
        guard let state = stateByProject[row.projectPath] else { return .unknown }
        return state.rollbackStatus(forAbsolutePath: row.path) ?? .unknown
    }

    var uncommittedCount: Int { rows.count { rollbackStatus(for: $0) == .uncommitted } }
    var notVersionedCount: Int { rows.count { rollbackStatus(for: $0) == .notVersioned } }
    var unknownCount: Int { rows.count { rollbackStatus(for: $0) == .unknown } }
}

/// 把「已有的改动行 + 只读探针」拼成清单。**不发任何新的取数查询**：
/// 行由调用方（`SessionsModel` 用既有的 `fileChanges(matching:)` 分页）给，
/// 这里只补版本控制判定。#60 第 4 条硬要求：不为了这个功能动 `Store/**`。
struct SessionChangeInventoryBuilder: Sendable {
    let reader: any GitReadOnlyReading

    func build(rows: [SessionChangeRow], serverRowCount: Int, isComplete: Bool) async -> SessionChangeInventory {
        var states: [String: ProjectVersionState] = [:]
        for project in Set(rows.map(\.projectPath)).sorted() {
            states[project] = await state(forProject: project)
        }
        return SessionChangeInventory(rows: rows, stateByProject: states,
                                      serverRowCount: serverRowCount, isComplete: isComplete)
    }

    /// 一个目录问三次：在不在工作树里 → 仓库根在哪 → 有哪些脏路径。
    /// 任一步失败都落 `probeUnavailable`，**不落"干净"**。
    private func state(forProject directory: String) async -> ProjectVersionState {
        do {
            let inside = try await reader.run(.isInsideWorkTree(directory: directory))
            guard inside.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else {
                return .notARepository
            }
            let root = try await reader.run(.repositoryRoot(directory: directory))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !root.isEmpty else {
                return .probeUnavailable(reason: "rev-parse --show-toplevel returned no repository root")
            }
            let status = try await reader.run(.status(directory: directory))
            return .managed(repositoryRoot: root, dirtyPaths: GitReadOnlyInvocation.dirtyPaths(fromStatusZ: status))
        } catch {
            return .probeUnavailable(reason: String(describing: error))
        }
    }
}

// MARK: - 取数（只走既有契约成员，不动 Store/**：#60 第 4 条）

extension SessionChangeInventoryBuilder {

    /// 单页大小。分页翻到**取完为止**——需求 1 的等价式是"清单条数 == 该会话 `file_changes` 行数"，
    /// 只取第一页就会让它变成"条数 == 100"这种看着对、其实是假的断言。
    static let inventoryPageSize = 100

    /// 内存里保留的清单上限。**触顶时不装作全量**：`isComplete = false`，界面必须写"仅前 N 条"。
    static let inventoryMaxRows = 2_000

    /// 取某个会话的改动清单。
    /// - Parameter service: 只用的读接口（`fileChanges(matching:)`），不新增契约成员。
    func inventory(sessionID: UUID, from service: any ObservatoryService,
                   skipProbe: Bool = false) async throws -> SessionChangeInventory {
        var collected: [FileChange] = []
        var offset = 0
        var serverTotal = 0
        var complete = true
        while true {
            let page = try await service.fileChanges(matching: FileChangeQuery(
                dateRange: .unbounded, sessionID: sessionID, limit: Self.inventoryPageSize, offset: offset
            ))
            serverTotal = page.totalCount
            collected.append(contentsOf: page.items)
            offset += page.items.count
            if page.items.isEmpty { break }
            if collected.count >= Self.inventoryMaxRows { complete = false; break }
            if collected.count >= page.totalCount { break }
        }
        let rows = collected.map { SessionChangeRow(change: $0) }
        if skipProbe {
            return SessionChangeInventory(rows: rows, serverRowCount: serverTotal, isComplete: complete)
        }
        let built = await build(rows: rows, serverRowCount: serverTotal, isComplete: complete)
        return built
    }
}
