//
//  ObservatoryStore+ProjectFeed.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine / ws-engaudit
//
//  项目地图专用的**窄取数**（性能 #31 / 交回总控第 1 条：`syncProjects` 15.8 ms/tick）。
//
//  成因不是聚合本身贵，而是**取数带了一路没人读的大字段**：五路查询各走 `SELECT *`，
//  每 tick 把 7 000 行连同 `commands.arguments_json`（每行一次 JSONDecoder）、
//  五张表的 `search_text`、`events.title/summary`、`risk_events.title/detail` 一起
//  解成领域对象，只为喂给 `ProjectMapper.aggregate`——它实际只读 6~8 个列
//  （路径、归属目录、agentKind、时间戳、增删行数、`risk_events.file_paths_json`）。
//  ADR-0009 裁定 4 记的那三个存活对象计数指纹（`NSMutableDictionary` / `NSMutableArray` /
//  `CFString` 各 +1 万上下）就是这个形状的分配侧证据。
//
//  为什么走窄查询而不是增量聚合：语义不变、不引入冷启动与「删行后如何收敛」的一致性问题
//  （总控裁定，见 `车道认领-2026-09-20-性能.md` 的 8 条答复第 1 条）。
//
//  ## 两条边界
//
//  1. **顺序与上限逐字照抄 `pagedRows`**（`ORDER BY <时间列> DESC, id DESC LIMIT ? OFFSET 0`），
//  并且和今天一样**不再跑 `SELECT COUNT(*)`**（`totalCount` 在 `syncProjects` 里没人用）。
//  换序就会在行数超过上限时截掉不同的行，那才是这条改动唯一可能改变结论的地方。
//  2. 返回的领域对象**只为聚合服务**：没取的列是类型默认值，不是实测值。
//     今天没人读它们；哪天 `ProjectMapper` 开始读一个没取的列，
//     `ProjectFeedEquivalenceTests` 会当场红（它拿同一份数据把窄路与宽路的聚合输出对打）。
//

import Foundation
import AIObservatoryCore

extension ObservatoryStore {

    /// 五路窄取数的结果。字段与 `ProjectMapper.aggregate` 的五个入参一一对应。
    public struct ProjectFeed: Sendable {
        public var fileChanges: [FileChange]
        public var commands: [CommandRecord]
        public var events: [TimelineEvent]
        public var sessions: [AgentSession]
        public var risks: [RiskEvent]

        public init(
            fileChanges: [FileChange] = [],
            commands: [CommandRecord] = [],
            events: [TimelineEvent] = [],
            sessions: [AgentSession] = [],
            risks: [RiskEvent] = []
        ) {
            self.fileChanges = fileChanges
            self.commands = commands
            self.events = events
            self.sessions = sessions
            self.risks = risks
        }
    }

    /// 项目地图的五路取数，只 SELECT 聚合读得到的列。
    ///
    /// - Parameters: 五路各自的上限。顺序与上限口径见文件头（与 `pagedRows` 一致）。
    public func projectFeed(
        fileChangeLimit: Int,
        commandLimit: Int,
        eventLimit: Int,
        sessionLimit: Int,
        riskLimit: Int
    ) async throws -> ProjectFeed {
        ProjectFeed(
            // file_changes：热文件与行数增减的来源。`search_text` 就是路径小写，纯浪费。
            fileChanges: try await database.rows(
                """
                SELECT id, path, previous_path, kind, timestamp, agent_id, session_id, agent_kind,
                    size_bytes, previous_size_bytes, is_text, lines_added, lines_removed,
                    risk_level, project_path
                FROM \(StoreSchema.Table.fileChanges)
                ORDER BY timestamp DESC, id DESC
                LIMIT ? OFFSET 0
                """,
                arguments: [.integer(Int64(max(fileChangeLimit, 0)))]
            ).compactMap { ProjectFeedRows.fileChange(from: $0) },
            // commands：只数条数与归属。丢掉 arguments_json（每行一次 JSON 解码）与 search_text。
            commands: try await database.rows(
                """
                SELECT id, executable, working_directory, agent_id, session_id, agent_kind,
                    started_at, ended_at, risk_level, project_path
                FROM \(StoreSchema.Table.commands)
                ORDER BY started_at DESC, id DESC
                LIMIT ? OFFSET 0
                """,
                arguments: [.integer(Int64(max(commandLimit, 0)))]
            ).compactMap { ProjectFeedRows.command(from: $0) },
            // events：只用来定归属与时间戳。title/summary/command/search_text 一律不取。
            events: try await database.rows(
                """
                SELECT id, timestamp, session_id, agent_id, agent_kind, kind, file_path,
                    risk_level, project_path
                FROM \(StoreSchema.Table.events)
                ORDER BY timestamp DESC, id DESC
                LIMIT ? OFFSET 0
                """,
                arguments: [.integer(Int64(max(eventLimit, 0)))]
            ).compactMap { ProjectFeedRows.event(from: $0) },
            // sessions：聚合只读 projectPath / kind / 两个时间戳。
            sessions: try await database.rows(
                """
                SELECT id, kind, started_at, ended_at, project_path
                FROM \(StoreSchema.Table.sessions)
                ORDER BY started_at DESC, id DESC
                LIMIT ? OFFSET 0
                """,
                arguments: [.integer(Int64(max(sessionLimit, 0)))]
            ).compactMap { ProjectFeedRows.session(from: $0) },
            // risks：`file_paths_json` 是这条唯一的 JSON——它决定归属，省不掉。
            risks: try await database.rows(
                """
                SELECT id, timestamp, agent_id, agent_kind, session_id, level, file_paths_json
                FROM \(StoreSchema.Table.riskEvents)
                ORDER BY timestamp DESC, id DESC
                LIMIT ? OFFSET 0
                """,
                arguments: [.integer(Int64(max(riskLimit, 0)))]
            ).compactMap { ProjectFeedRows.risk(from: $0) }
        )
    }
}

// MARK: - 窄行的映射

/// 窄 SELECT 的行 → 领域对象。**没 SELECT 的列一律取类型默认值**，
/// 因此这些对象不许拿去做展示或判定（见 `ObservatoryStore+ProjectFeed.swift` 文件头第 2 条边界）。
enum ProjectFeedRows {

    static func fileChange(from row: SQLiteRow) -> FileChange? {
        guard let id = row.uuid("id"),
              let path = row.text("path"),
              let kind = row.text("kind").flatMap({ FileChangeKind(rawValue: $0) }),
              let timestamp = row.date("timestamp"),
              let agentKind = row.text("agent_kind").flatMap({ AgentKind(rawValue: $0) })
        else { return nil }
        return FileChange(
            id: id,
            path: path,
            previousPath: row.text("previous_path"),
            kind: kind,
            timestamp: timestamp,
            agentID: row.uuid("agent_id"),
            sessionID: row.uuid("session_id"),
            agentKind: agentKind,
            sizeBytes: row.uint64("size_bytes") ?? 0,
            previousSizeBytes: row.uint64("previous_size_bytes"),
            isText: (row.int("is_text") ?? 0) != 0,
            linesAdded: row.int("lines_added") ?? 0,
            linesRemoved: row.int("lines_removed") ?? 0,
            riskLevel: row.text("risk_level").flatMap({ RiskLevel(rawValue: $0) }) ?? .low,
            projectPath: row.text("project_path")
        )
    }

    static func command(from row: SQLiteRow) -> CommandRecord? {
        guard let id = row.uuid("id"),
              let executable = row.text("executable"),
              let startedAt = row.date("started_at"),
              let agentKind = row.text("agent_kind").flatMap({ AgentKind(rawValue: $0) })
        else { return nil }
        return CommandRecord(
            id: id,
            executable: executable,
            arguments: [],                       // 没取：每行一次 JSONDecoder，聚合用不上
            workingDirectory: row.text("working_directory"),
            agentID: row.uuid("agent_id"),
            sessionID: row.uuid("session_id"),
            agentKind: agentKind,
            startedAt: startedAt,
            endedAt: row.date("ended_at"),
            exitCode: nil,
            outcome: .unknown,                   // 没取 outcome：聚合只数条数与时间
            riskLevel: row.text("risk_level").flatMap({ RiskLevel(rawValue: $0) }) ?? .low,
            projectPath: row.text("project_path")
        )
    }

    static func event(from row: SQLiteRow) -> TimelineEvent? {
        guard let id = row.uuid("id"),
              let timestamp = row.date("timestamp"),
              let kind = row.text("kind").flatMap({ OperationKind(rawValue: $0) }),
              let agentKind = row.text("agent_kind").flatMap({ AgentKind(rawValue: $0) })
        else { return nil }
        return TimelineEvent(
            id: id,
            timestamp: timestamp,
            sessionID: row.uuid("session_id"),
            agentID: row.uuid("agent_id"),
            agentKind: agentKind,
            kind: kind,
            title: "",                           // 没取：见文件头，聚合只读 filePath / projectPath / 时间
            summary: "",
            filePath: row.text("file_path"),
            command: nil,
            riskLevel: row.text("risk_level").flatMap({ RiskLevel(rawValue: $0) }) ?? .low,
            projectPath: row.text("project_path")
        )
    }

    static func session(from row: SQLiteRow) -> AgentSession? {
        guard let id = row.uuid("id"),
              let kind = row.text("kind").flatMap({ AgentKind(rawValue: $0) }),
              let startedAt = row.date("started_at")
        else { return nil }
        return AgentSession(
            id: id,
            kind: kind,
            projectPath: row.text("project_path"),
            startedAt: startedAt,
            endedAt: row.date("ended_at")
        )
    }

    static func risk(from row: SQLiteRow) -> RiskEvent? {
        guard let id = row.uuid("id"),
              let timestamp = row.date("timestamp"),
              let level = row.text("level").flatMap({ RiskLevel(rawValue: $0) }),
              let agentKind = row.text("agent_kind").flatMap({ AgentKind(rawValue: $0) })
        else { return nil }
        return RiskEvent(
            id: id,
            timestamp: timestamp,
            level: level,
            category: .unknown,                   // 没取 category：聚合只按路径归属分桶
            title: "",
            detail: "",
            agentID: row.uuid("agent_id"),
            agentKind: agentKind,
            sessionID: row.uuid("session_id"),
            filePaths: StoreRows.decodeList([String].self, from: row.text("file_paths_json"), fallback: [])
        )
    }
}
