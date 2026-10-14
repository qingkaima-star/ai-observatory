//
//  Aix.swift
//  AIObservatoryCLI
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  `aix` 的入口。四条设计约束全落在这一个文件：
//  · **只读**：先过 `AixStore` 的前置检查（无库 / 版本不符一律退 2，绝不建库），再只调 `ObservatoryService` 的查询。
//  · **一套口径**：人读表格与 `--json` 走同一次取数（`AixQuery`），`report` 也走同一处收集。
//  · **空与未知分得开**：无库 / 空表 / 查无结果 / 字段拿不到，四种输出互不相同（`AixStatus`）。
//  · **退出码**：0 有行 / 1 库在但零行 / 2 前置条件不满足。
//  · `--json` 时 stdout 只放数据，状态与诊断进 stderr ⇒ 管道里拿到的是干净 JSON。
//

import Foundation
import AIObservatoryCore
import AIObservatoryExport

/// 进程退出码。
public enum AixExitCode: Int32, Sendable {
    /// 拿到至少一行。
    case ok = 0
    /// 库存在且可读，但这一查零行（表本来就是空的，或被条件筛空）。
    case noRows = 1
    /// 前置条件不满足：无库、参数错、库版本不符、打不开。
    case preconditionFailed = 2
}

/// 输出状态。**四个 case 的字面文案互不相同**，用例逐字断言这一族 token（约束 3）。
public enum AixStatus: Sendable, Hashable {
    case ok
    /// 目标表 0 行 —— 这份库从来没产出过这类记录。
    case emptyTable(table: String)
    /// 表里有 \(total) 行，条件筛完剩 0 —— 数据在，只是不在你划的那格里。
    case noMatch(table: String, total: Int)
    /// 这一格的答案拿不到（未持久化 / Store 没有对应查询）。**这不等于 0。**
    /// `field` 是给机器读的 ASCII 名，`label` 是给人读的名字 —— 两者一起构造，避免只改一处。
    case unavailable(field: String, label: String, reason: String)

    /// `--json` 时写进 stderr 的机器可读标记。
    public var token: String {
        switch self {
        case .ok: "status=ok"
        case .emptyTable(let table): "status=empty-table table=\(table)"
        case .noMatch(let table, let total): "status=no-match table=\(table) table-total=\(total)"
        case .unavailable(let field, _, _): "status=unavailable field=\(field)"
        }
    }

    /// 人读输出里的那一行说明。
    public var note: String {
        switch self {
        case .ok: ""
        case .emptyTable(let table): "表 \(table) 一行都没有 —— 这份库里还没有这类记录（不是查询没匹配上）。"
        case .noMatch(let table, let total): "表 \(table) 有 \(total) 行，但当前条件筛出 0 行 —— 是「查无结果」，不是「没有数据」。"
        case .unavailable(_, let label, let reason): "\(label)：拿不到（\(reason)）—— 未知不等于 0。"
        }
    }
}

public struct AixOutput: Sendable, Hashable {
    public var stdout: String
    public var stderr: String
    public var exitCode: Int32

    public init(stdout: String = "", stderr: String = "", exitCode: Int32 = AixExitCode.ok.rawValue) {
        self.stdout = stdout
        self.stderr = stderr
        self.exitCode = exitCode
    }
}

public enum Aix {
    /// 版本串。真机验收要它，免得拿着一颗旧二进制读数。
    public static let version = "aix 0.1 (#65 只读查询面)"

    /// `aix agents --json` 那份 envelope 的版本。
    ///
    /// ⚠️ **它不是导出层那份文档**：`ExportKind` 只有五类记录 + report，没有 `agents` 这一类，
    /// 所以 agents 的 JSON 外壳由 CLI 自己搭（键序照 `JSONExporter`，字段取 `AgentInstance` 原生 Codable）。
    /// 总控 20:0x 点名过这条差异：不许冒称"envelope 就是导出层那份"。改动这里的键就要 +1，
    /// 用例 `agentsListsOnlyActiveAndSaysSo` 会把"字段集必须是模型 Codable 键的子集"钉住。
    public static let agentsSchemaVersion = 1

    /// 入口。`arguments` 不含可执行文件名；错误不抛出，按退出码 + stderr 表达。
    public static func run(arguments: [String], now: Date = Date()) async -> AixOutput {
        if arguments.isEmpty {
            return AixOutput(stdout: AixArguments.help(for: nil),
                             stderr: "缺少子命令。\n",
                             exitCode: AixExitCode.preconditionFailed.rawValue)
        }
        if arguments.contains("--help") || arguments.contains("-h") {
            return AixOutput(stdout: AixArguments.help(for: nil), exitCode: AixExitCode.ok.rawValue)
        }
        if arguments.contains("--version") {
            return AixOutput(stdout: version + "\n")
        }
        let request: AixRequest
        do {
            request = try AixArguments.parse(arguments)
        } catch {
            return AixOutput(stderr: "参数错：\(error.localizedDescription)\n",
                             exitCode: AixExitCode.preconditionFailed.rawValue)
        }
        let opened: AixStore.Opened
        do {
            opened = try await AixStore.open(request: request)
        } catch let failure as AixFailure {
            let token = request.json ? "# \(failure.statusToken)\n" : ""
            return AixOutput(stderr: failure.message + "\n" + token,
                             exitCode: AixExitCode.preconditionFailed.rawValue)
        } catch {
            return AixOutput(stderr: "打不开库：\(error.localizedDescription)\n",
                             exitCode: AixExitCode.preconditionFailed.rawValue)
        }
        // 唯一一条「本工具自报不是完全只读」的路径，实测出来的（`tmp/readonly-forensics.sh` 格 3）：
        // 库里有未 checkpoint 的 WAL 帧、且本进程是最后一个连接时（采集端被 kill 掉的那次就是这样），
        // 读完退出会把 WAL 合并进主库 —— 主库字节就变了。彻底免掉要 Store 的只读打开（ICR-0012 C2）。
        let walNote = opened.walWarning
        do {
            var result = try await output(request: request, opened: opened, now: now)
            if let walNote { result.stderr = walNote + result.stderr }
            return result
        } catch let failure as AixFailure {
            return AixOutput(stderr: failure.message + "\n", exitCode: AixExitCode.preconditionFailed.rawValue)
        } catch {
            return AixOutput(stderr: "\(request.command.rawValue) 失败：\(error.localizedDescription)\n",
                             exitCode: AixExitCode.preconditionFailed.rawValue)
        }
    }

    /// 渲染一条命令的完整输出。用例直接打这里，测的就是真命令面（退出码 + 字节流）。
    ///
    /// 两道遮罩/脱敏的分工（ICR-0012 总控裁定 20:0x）：
    /// · **凭据脱敏默认开**（`ExportRedactor.standard`，在导出层里做，逐字段）；`--no-redact` 关掉时
    ///   在 stderr 留一行可审计提示 —— 静默出原文等于把事故藏起来。
    /// · **路径遮罩默认关**（`--redact` 才开，#61 那套显示层映射）：它不是安全边界，库里仍是原文。
    ///   放在最后一道，是因为 JSON 由导出层吐字节，逐字段重编会另起一套口径。
    public static func output(request: AixRequest, opened: AixStore.Opened, now: Date) async throws -> AixOutput {
        let result = try await rawOutput(request: request, opened: opened, now: now)
        return finish(request: request, opened: opened, result: result)
    }

    /// 遮罩与可审计提示都收在这一步：stdout 保持纯数据（`--json` 可直接进管道），提示进 stderr。
    ///
    /// 路径遮罩**不在 CLI 里做字符串处理** —— 用的是 `Core/Privacy/PathPrivacy.swift` 里那份
    /// `PathPrivacy.Mask`（#64 收拢进来的，分词只有 `pathRuns(in:)` 一把尺子）。
    /// 我第一版自己写过一份镜像（`AixPathMasking.swift`），在裁定"等 standard(pathMask:) 接上、
    /// 不要手写分词/正则"之后**已删除** —— 两份遮罩互不认得正是 #64 的成因。
    static func finish(request: AixRequest, opened: AixStore.Opened, result: AixOutput) -> AixOutput {
        var output = result
        if request.maskPaths {
            // **不用** `PathPrivacy.Mask.configured(from:)`：它先按 `settings.demoRedactedOutput` 决定
            // 要不要遮，那是**图形界面自己的显示偏好**。CLI 这边 `--redact` 就是调用方的显式意图，
            // 拿设置项再挡一道 ⇒ flag 有一半概率是空开关（裁定要的是「`--redact` 才开」，不是「两者都开才开」）。
            // 所以这里只从设置里取**项目根清单**，家目录与开关由命令行自己定。
            let directory = (opened.databasePath as NSString).deletingLastPathComponent
            let home = NSHomeDirectory()
            let mask = PathPrivacy.Mask(
                home: home,
                projectRoots: settings(in: directory).monitoredRoots.map {
                    PathPrivacy.Mask.expanded($0, home: home)
                }
            )
            if !mask.isOff { output.stdout = mask.scrub(output.stdout) }
        }
        if !request.redactCredentials {
            output.stderr += "# warning=AIX_CREDENTIAL_REDACTION_OFF\n"
                + "# 已关闭凭据脱敏：下文出现的密钥/token 是原文，别贴进任何模型上下文或工单。\n"
        }
        return output
    }

    /// 读数据目录里的 `settings.json`；读不到 ⇒ 用契约默认值（遮罩因此可能落回 `.off`，
    /// 这是「拿不到」而不是「关着」，输出上不假装遮过）。
    static func settings(in directory: String) -> ObservatorySettings {
        let url = URL(fileURLWithPath: directory, isDirectory: true).appendingPathComponent("settings.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ObservatorySettings.self, from: data) else {
            return ObservatorySettings()
        }
        return decoded
    }

    static func rawOutput(request: AixRequest, opened: AixStore.Opened, now: Date) async throws -> AixOutput {
        if request.command == .report { return try await report(request: request, opened: opened, now: now) }

        let fetched = try await AixQuery.run(request, service: opened.service)
        let status = status(of: fetched)
        var notes = [status.token]
        // 「机制分布」这一格是真拿不到的：四个分支在入库**之前**判、只活在引擎进程内存里
        // （`ObservatoryEngine.swift:1131-1146`），而 `file_changes` 的 16 列里没有一列记归属原因。
        var mechanism: AixStatus?
        if request.command == .files, request.unattributedOnly {
            mechanism = .unavailable(field: "attribution-mechanism", label: "机制分布",
                                     reason: "四个分支在入库之前判、只活在采集进程内存里，"
                                         + "而 file_changes 表没有任何一列记录归属原因 ⇒ 只读拿不到")
            notes.append(mechanism!.token)
        }
        let diagnostics = notes.map { "# \($0)\n" }.joined()
        let code = fetched.isEmpty ? AixExitCode.noRows.rawValue : AixExitCode.ok.rawValue

        if request.json {
            return AixOutput(stdout: try json(request: request, fetched: fetched, opened: opened, now: now),
                             stderr: diagnostics, exitCode: code)
        }
        var text = table(request: request, fetched: fetched)
        // 零行时把「到底是哪种零行」写进 stdout：只放 stderr 的话，人读模式下这四种状态看着一模一样。
        if case .ok = status {} else { text += status.note + "\n" }
        if let mechanism { text += mechanism.note + "\n" }
        if let line = footer(request: request, fetched: fetched, databasePath: opened.databasePath) {
            text += line + "\n"
        }
        return AixOutput(stdout: text, exitCode: code)
    }

    /// 决定「空表 / 查无结果 / 拿不到」三种零行状态。
    static func status(of fetched: AixFetched) -> AixStatus {
        guard fetched.isEmpty else { return .ok }
        switch fetched.tableTotal {
        case 0: return .emptyTable(table: fetched.tableName)
        case .some(let total): return .noMatch(table: fetched.tableName, total: total)
        case nil:
            return .unavailable(field: fetched.tableName + "-table-total", label: fetched.tableName + " 表总行数",
                                reason: "Store 侧只有「活跃 Agent」查询，没有不带过滤的全量查询")
        }
    }

    // MARK: - 人读

    static func table(request: AixRequest, fetched: AixFetched) -> String {
        switch fetched {
        case .agents(let agents, _):
            let built = AixRows.agentTable(agents)
            return AixTable.render(headers: built.headers, rows: built.rows)
        case .rows(let kind, let records, _, _):
            let built = AixRows.table(kind: kind, records: records)
            return AixTable.render(headers: built.headers, rows: built.rows)
        }
    }

    /// 页脚：把「本次显示 / 过滤后总数 / 是否截断」写清楚，并复述生效的条件与库路径。
    static func footer(request: AixRequest, fetched: AixFetched, databasePath: String) -> String? {
        var parts: [String] = []
        let shown = fetched.displayedCount
        let matched = fetched.matchedTotal
        if shown == 0 { return nil }
        // agents 这一格必须自带口径：`activeAgents()` 只数 running/idle，库里还有历史行。
        // 只写「1 行」的话，拿不到 --help 的 AI 会把"活跃 1 个"读成"这台机器只有 1 个 Agent"
        // （真库实测：活跃 1、历史 24）。**不改行为、只改告知**——口径本身是派单要的形状。
        parts.append(request.command == .agents
            ? "\(shown) 行（活跃；历史见 sessions）"
            : "\(shown) 行")
        if matched > shown { parts.append("过滤后共 \(matched) 行，已截断 \(matched - shown) 行（--all 看全量）") }
        if request.unattributedOnly { parts.append("条件：仅未归属") }
        if let level = request.level { parts.append("条件：等级=\(level.rawValue)") }
        if let since = request.since { parts.append("条件：起 \(AixFormat.date(since))") }
        parts.append("库：\(databasePath)")
        return parts.joined(separator: " ｜ ")
    }

    // MARK: - 机读

    static func json(request: AixRequest, fetched: AixFetched, opened: AixStore.Opened, now: Date) throws -> String {
        switch fetched {
        case .agents(let agents, _):
            // 导出层没有 `agents` 这一类（`ExportKind` 只有五类记录 + report）。
            // 这一份 envelope 与 `JSONExporter` **同形但独立**，items 是 `AgentInstance` 的原生 Codable ⇒
            // 字段口径仍是 Store 那一套，只是外壳自己搭的。ICR-0012 §四 已把这条差异写进账。
            let envelope: [String: Any] = [
                "schemaVersion": agentsSchemaVersion,
                "generatedAt": AixFormat.iso8601(now),
                "exportedBy": "aix (read-only)",
                "kind": "agents",
                "counts": ["total": agents.count],
                "items": agents.map(agentDictionary),
            ]
            let data = try JSONSerialization.data(withJSONObject: envelope, options: [.sortedKeys])
            return String(decoding: data, as: UTF8.self) + "\n"

        case .rows(let kind, let records, _, _):
            let request = exportRequest(for: request, kind: kind, opened: opened, now: now)
            let data = try JSONExporter.data(records: records, kind: kind, request: request,
                                             redactor: request.redactionEnabled ? .standard : .disabled)
            return String(decoding: data, as: UTF8.self) + "\n"
        }
    }

    private static func agentDictionary(_ agent: AgentInstance) -> [String: Any] {
        [
            "id": agent.id.uuidString, "kind": agent.kind.rawValue, "pid": Int(agent.pid),
            "displayName": agent.displayName, "state": agent.state.rawValue,
            "workingDirectory": agent.workingDirectory ?? NSNull(),
            "startedAt": AixFormat.iso8601(agent.startedAt),
            "lastSeenAt": AixFormat.iso8601(agent.lastSeenAt),
            "cpuPercent": agent.cpuPercent, "memoryBytes": agent.memoryBytes,
        ]
    }

    /// 导出层的请求。**`destination` 在这条 stdout 路径上不参与写盘**（`JSONExporter.data` 只吃 records），
    /// 给一个已存在的目录只是为了满足 `ExportRequest` 的必填字段。
    public static func exportRequest(for request: AixRequest, kind: ExportKind,
                             opened: AixStore.Opened, now: Date) -> ExportRequest {
        let directory = URL(fileURLWithPath: (opened.databasePath as NSString).deletingLastPathComponent,
                            isDirectory: true)
        return ExportRequest(
            format: .json,
            kinds: [kind],
            dateRange: AixQuery.dateRange(request),
            maximumRecordsPerKind: nil,
            generatedAt: now,
            redactionEnabled: request.redactCredentials,
            jsonPrettyPrinted: false,
            interfaceLanguage: .resolved(),
            destination: ExportDestination(directory: directory, baseName: "aix", allowedRoots: [directory])
        )
    }

    // MARK: - report

    static func report(request: AixRequest, opened: AixStore.Opened, now: Date) async throws -> AixOutput {
        let records = try await AixQuery.reportRecords(request, service: opened.service,
                                                       now: now, databasePath: opened.databasePath)
        let redactor: ExportRedactor = request.redactCredentials ? .standard : .disabled
        let code: Int32 = records.isEmpty ? AixExitCode.noRows.rawValue : AixExitCode.ok.rawValue
        let emptyNote: String = records.isEmpty
            ? "# \(AixStatus.emptyTable(table: "全部记录表").token)\n" : ""

        if request.json {
            // 导出层没有「report 的 JSON」这一种组合（`.report` 只支持 markdown）。
            // 所以这里输出**每类记录一份 envelope 的数组**，每份与 `aix files --json` 等命令逐字节相同
            // —— 不新造字段口径，只加一层数组。
            var documents: [Data] = []
            for kind in ExportKind.reportSourceKinds where records.contains(where: { $0.kind == kind }) {
                // 同一份 dateRange 再传一次是幂等的（collect 已按它筛过），保持 envelope 与逐类命令逐字节同形。
                let request = exportRequest(for: request, kind: kind, opened: opened, now: now)
                documents.append(try JSONExporter.data(records: records, kind: kind, request: request, redactor: redactor))
            }
            let body = documents.isEmpty ? "[]\n"
                : "[\n" + documents.map { String(decoding: $0, as: UTF8.self) }.joined(separator: ",\n") + "\n]\n"
            return AixOutput(stdout: body, stderr: emptyNote, exitCode: code)
        }

        let input = MarkdownReportExporter.Input(
            records: records,
            projects: try await opened.service.projects(),
            generatedAt: now,
            dateRange: AixQuery.dateRange(request)
        )
        return AixOutput(stdout: try MarkdownReportExporter.report(input: input, redactor: redactor),
                         stderr: emptyNote, exitCode: code)
    }

}

private extension AixFetched {
    /// 输出里出现的表名统一用 **DB 表名**（`file_changes`），不用导出层 kind 的 camelCase 写法
    /// （`fileChanges`）：「库里到底有没有行」那本账是按前者记的，两处拼写不一致会让人对不上数。
    var tableName: String {
        switch self {
        case .agents: "agents"
        case .rows(let kind, _, _, _): kind.databaseTableName
        }
    }
}

private extension ExportKind {
    var databaseTableName: String {
        switch self {
        case .sessions: "sessions"
        case .timeline: "events"
        case .fileChanges: "file_changes"
        case .commands: "commands"
        case .riskEvents: "risk_events"
        case .report: "report"
        }
    }
}
