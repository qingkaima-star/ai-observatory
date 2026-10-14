//
//  StoreSchema.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine
//  Sub-owner: B
//
//  数据库 schema 真相源：version 1 全量 DDL（INTERFACE.md §4 的 10 张表）+ 全部索引。
//  所有语句均 `CREATE TABLE/INDEX IF NOT EXISTS`，幂等，可重复执行。
//  列名 / 类型逐字对齐 INTERFACE.md §4：日期 REAL(timeIntervalSinceReferenceDate)、枚举 TEXT rawValue、
//  可序枚举额外 INTEGER rank 列、JSON 列表 TEXT 列。
//  本版本**不新增** §4 之外的表：`FileSnapshot` 的落点见 ObservatoryStore.recordSnapshot(_:) 的注释。
//

import Foundation
import AIObservatoryCore

/// Store 层 schema 定义：版本、迁移清单、保留期清理表序、全表名单。
public enum StoreSchema {

    /// 当前 schema 版本（v1 十张核心表，v2 补 `file_snapshots`，v3 补网络/GPU 列，v4 补 diff 溯源列）。
    public static let schemaVersion: Int = 4

    // MARK: - 表名常量（供 B/E 复用，避免各处硬编码）

    /// §4 定义的表名常量（E 的查询文件直接引用，不要硬编码字符串）。
    public enum Table {
        /// Agent 进程实例表。
        public static let agents = "agents"
        /// 会话表。
        public static let sessions = "sessions"
        /// 时间线事件表。
        public static let events = "events"
        /// 文件变更表。
        public static let fileChanges = "file_changes"
        /// 文件 diff 表（change_id 唯一）。
        public static let diffs = "diffs"
        /// 命令审计表。
        public static let commands = "commands"
        /// 会话级性能采样表。
        public static let perfSamples = "perf_samples"
        /// 整机性能采样表。
        public static let systemPerf = "system_perf"
        /// 风险事件表。
        public static let riskEvents = "risk_events"
        /// 项目活动表。
        public static let projects = "projects"
        /// 文件内容快照表（哈希/大小/行数，供跨次变更对比）。
        public static let fileSnapshots = "file_snapshots"
    }

    // MARK: - 迁移

    /// 经 `SchemaMigrator.validate` 校验的有序迁移清单（当前仅 version 1）。
    /// 校验失败只记日志、不 crash（静态初始化无法 throws；本文件内容编译期固定，校验必过）。
    public static let migrations: [SchemaMigration] = StoreSchema.validatedMigrations()

    /// 保留期清理用的 (表名, 时间列) 清单，顺序即删除顺序：先子表后父表。
    ///
    /// 时间列口径（INTERFACE.md §4）：`diffs→captured_at`、`perf_samples/events/file_changes/
    /// system_perf/risk_events→timestamp`、`sessions/commands→started_at`、
    /// `agents/projects→last_seen_at`。
    /// `diffs` 最先（引用 `file_changes.id`），随后所有挂在 `sessions` 下的叶子表，
    /// 最后才是父表 `sessions` → `agents`；`projects` 独立，放最后。
    public static let prunable: [(table: String, timestampColumn: String)] = [
        (Table.fileSnapshots, "captured_at"),
        (Table.diffs, "captured_at"),
        (Table.perfSamples, "timestamp"),
        (Table.events, "timestamp"),
        (Table.fileChanges, "timestamp"),
        (Table.commands, "started_at"),
        (Table.riskEvents, "timestamp"),
        (Table.systemPerf, "timestamp"),
        (Table.sessions, "started_at"),
        (Table.agents, "last_seen_at"),
        (Table.projects, "last_seen_at"),
    ]

    /// 全部表名（`deleteAllData` / `rowCount(table:)` 的唯一合法白名单），顺序同 `prunable`。
    public static let allTables: [String] = [
        Table.fileSnapshots,
        Table.diffs,
        Table.perfSamples,
        Table.events,
        Table.fileChanges,
        Table.commands,
        Table.riskEvents,
        Table.systemPerf,
        Table.sessions,
        Table.agents,
        Table.projects,
    ]

    private static func validatedMigrations() -> [SchemaMigration] {
        let all: [SchemaMigration] = [
            SchemaMigration(version: 1, name: "initial-schema", statements: version1Statements()),
            SchemaMigration(version: 2, name: "file-snapshots", statements: version2Statements()),
            SchemaMigration(version: 3, name: "system-perf-network-gpu", statements: version3Statements()),
            SchemaMigration(version: 4, name: "diff-baseline-provenance", statements: version4Statements()),
        ]
        do {
            try SchemaMigrator.validate(all)
        } catch {
            ObservatoryLog.store.error(
                "StoreSchema.migrations failed SchemaMigrator.validate: \(error.localizedDescription, privacy: .public)"
            )
        }
        return all
    }

    // MARK: - Version 2 DDL

    /// `file_snapshots`：`recordSnapshot(_:)` 一直在写这张表，但 v1 忘了建表
    /// —— 运行时才暴露为 `no such table`。列与 `SQL.insertSnapshot` 逐字对齐。
    private static func version2Statements() -> [SQLiteStatement] {
        let ddl: [String] = [
            """
            CREATE TABLE IF NOT EXISTS file_snapshots (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                content_hash TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                line_count INTEGER NOT NULL,
                captured_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_snapshots_path ON file_snapshots(path)",
            "CREATE INDEX IF NOT EXISTS idx_snapshots_captured ON file_snapshots(captured_at)",
        ]
        return ddl.map { SQLiteStatement($0) }
    }

    /// v3：整机网络速率与 GPU 活动。
    ///
    /// 只走 `ALTER TABLE`，**不**回头改 v1 的 `CREATE TABLE`：迁移按 `PRAGMA user_version`
    /// 逐版本只跑一次，新库是「先建表再 ALTER」，同名列直接失败。
    /// 规矩与 v2 的 `file_snapshots`（v1 DDL 里也没有它）一致。
    /// 四列全部可空 ⇒ 老行读回来是 `nil`，正是「当时没采这个指标」的正确语义，不需要回填。
    private static func version3Statements() -> [SQLiteStatement] {
        let ddl: [String] = [
            "ALTER TABLE system_perf ADD COLUMN network_in_bytes_per_second REAL",
            "ALTER TABLE system_perf ADD COLUMN network_out_bytes_per_second REAL",
            "ALTER TABLE system_perf ADD COLUMN network_availability TEXT",
            "ALTER TABLE system_perf ADD COLUMN gpu_percent REAL",
        ]
        return ddl.map { SQLiteStatement($0) }
    }

    /// v4：diff 的「改前内容是从哪来的」，以及「正文有没有被隐私开关关掉」。
    ///
    /// 只走 `ALTER TABLE`，规矩与 v3 一致（迁移按 `PRAGMA user_version` 逐版本只跑一次，
    /// 新库是「先建表再 ALTER」，同名列直接失败）。
    /// 三列都可空且**不带 DEFAULT**：NULL 的含义是「当时压根没记过这件事」，
    /// 给了 DEFAULT 就变成「当时记录的值就是这个」——那是在替历史数据编供述。
    /// 老行读回来由 `StoreRows.diff` 明确回落为 `.unavailableFirstSighting`
    /// （写这些行的旧代码 `oldText` 恒为 `nil`，见该处注释）。
    private static func version4Statements() -> [SQLiteStatement] {
        let ddl: [String] = [
            "ALTER TABLE diffs ADD COLUMN baseline_source TEXT",
            "ALTER TABLE diffs ADD COLUMN baseline_captured_at REAL",
            "ALTER TABLE diffs ADD COLUMN plaintext_stored INTEGER",
        ]
        return ddl.map { SQLiteStatement($0) }
    }

    // MARK: - Version 1 DDL

    /// v1 DDL：agents 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1agentsDDL() -> [String] {
        [
            // ---- agents ----
            """
            CREATE TABLE IF NOT EXISTS agents (
                id TEXT PRIMARY KEY,
                kind TEXT NOT NULL,
                pid INTEGER NOT NULL,
                parent_pid INTEGER,
                display_name TEXT NOT NULL,
                executable_path TEXT NOT NULL,
                working_directory TEXT,
                bundle_identifier TEXT,
                tty TEXT,
                started_at REAL NOT NULL,
                last_seen_at REAL NOT NULL,
                state TEXT NOT NULL,
                cpu_percent REAL NOT NULL,
                memory_bytes INTEGER NOT NULL,
                child_pids_json TEXT NOT NULL,
                detected_via TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_agents_state ON agents(state)",
            "CREATE INDEX IF NOT EXISTS idx_agents_kind ON agents(kind)",
            "CREATE INDEX IF NOT EXISTS idx_agents_last_seen ON agents(last_seen_at)",
            "CREATE INDEX IF NOT EXISTS idx_agents_pid ON agents(pid)",

        ]
    }

    /// v1 DDL：sessions 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1sessionsDDL() -> [String] {
        [
            // ---- sessions ----
            """
            CREATE TABLE IF NOT EXISTS sessions (
                id TEXT PRIMARY KEY,
                display_index INTEGER NOT NULL,
                kind TEXT NOT NULL,
                agent_id TEXT,
                title TEXT NOT NULL,
                project_path TEXT,
                started_at REAL NOT NULL,
                ended_at REAL,
                modified_file_count INTEGER NOT NULL,
                created_file_count INTEGER NOT NULL,
                deleted_file_count INTEGER NOT NULL,
                command_count INTEGER NOT NULL,
                failed_command_count INTEGER NOT NULL,
                cpu_seconds REAL NOT NULL,
                peak_cpu_percent REAL NOT NULL,
                peak_memory_bytes INTEGER NOT NULL,
                estimated_tokens INTEGER NOT NULL,
                risk_event_count INTEGER NOT NULL,
                outcome TEXT NOT NULL,
                search_text TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_sessions_started ON sessions(started_at)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_kind ON sessions(kind)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_outcome ON sessions(outcome)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_project ON sessions(project_path)",
            "CREATE INDEX IF NOT EXISTS idx_sessions_agent ON sessions(agent_id)",

        ]
    }

    /// v1 DDL：events 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1eventsDDL() -> [String] {
        [
            // ---- events ----
            """
            CREATE TABLE IF NOT EXISTS events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                session_id TEXT,
                agent_id TEXT,
                agent_kind TEXT NOT NULL,
                kind TEXT NOT NULL,
                title TEXT NOT NULL,
                summary TEXT NOT NULL,
                file_path TEXT,
                command TEXT,
                exit_code INTEGER,
                duration_seconds REAL,
                cost_cpu_seconds REAL NOT NULL,
                cost_memory_bytes INTEGER NOT NULL,
                cost_bytes_read INTEGER NOT NULL,
                cost_bytes_written INTEGER NOT NULL,
                risk_level TEXT NOT NULL,
                risk_rank INTEGER NOT NULL,
                project_path TEXT,
                search_text TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_events_ts ON events(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_events_session ON events(session_id)",
            "CREATE INDEX IF NOT EXISTS idx_events_kind ON events(kind)",
            "CREATE INDEX IF NOT EXISTS idx_events_agent_kind ON events(agent_kind)",
            "CREATE INDEX IF NOT EXISTS idx_events_project ON events(project_path)",
            "CREATE INDEX IF NOT EXISTS idx_events_risk_rank ON events(risk_rank)",

        ]
    }

    /// v1 DDL：file_changes 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1fileChangesDDL() -> [String] {
        [
            // ---- file_changes ----
            """
            CREATE TABLE IF NOT EXISTS file_changes (
                id TEXT PRIMARY KEY,
                path TEXT NOT NULL,
                previous_path TEXT,
                kind TEXT NOT NULL,
                timestamp REAL NOT NULL,
                agent_id TEXT,
                session_id TEXT,
                agent_kind TEXT NOT NULL,
                size_bytes INTEGER NOT NULL,
                previous_size_bytes INTEGER,
                is_text INTEGER NOT NULL,
                lines_added INTEGER NOT NULL,
                lines_removed INTEGER NOT NULL,
                risk_level TEXT NOT NULL,
                risk_rank INTEGER NOT NULL,
                project_path TEXT,
                search_text TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_files_ts ON file_changes(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_files_session ON file_changes(session_id)",
            "CREATE INDEX IF NOT EXISTS idx_files_kind ON file_changes(kind)",
            "CREATE INDEX IF NOT EXISTS idx_files_agent_kind ON file_changes(agent_kind)",
            "CREATE INDEX IF NOT EXISTS idx_files_project ON file_changes(project_path)",
            "CREATE INDEX IF NOT EXISTS idx_files_path ON file_changes(path)",

        ]
    }

    /// v1 DDL：diffs 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1diffsDDL() -> [String] {
        [
            // ---- diffs ----
            """
            CREATE TABLE IF NOT EXISTS diffs (
                id TEXT PRIMARY KEY,
                change_id TEXT NOT NULL UNIQUE,
                path TEXT NOT NULL,
                previous_path TEXT,
                kind TEXT NOT NULL,
                lines_json TEXT NOT NULL,
                lines_added INTEGER NOT NULL,
                lines_removed INTEGER NOT NULL,
                is_binary INTEGER NOT NULL,
                is_truncated INTEGER NOT NULL,
                captured_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_diffs_change ON diffs(change_id)",

        ]
    }

    /// v1 DDL：commands 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1commandsDDL() -> [String] {
        [
            // ---- commands ----
            """
            CREATE TABLE IF NOT EXISTS commands (
                id TEXT PRIMARY KEY,
                executable TEXT NOT NULL,
                arguments_json TEXT NOT NULL,
                working_directory TEXT,
                agent_id TEXT,
                session_id TEXT,
                agent_kind TEXT NOT NULL,
                started_at REAL NOT NULL,
                ended_at REAL,
                exit_code INTEGER,
                outcome TEXT NOT NULL,
                is_destructive INTEGER NOT NULL,
                requires_confirmation INTEGER NOT NULL,
                risk_level TEXT NOT NULL,
                risk_rank INTEGER NOT NULL,
                project_path TEXT,
                search_text TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_commands_started ON commands(started_at)",
            "CREATE INDEX IF NOT EXISTS idx_commands_session ON commands(session_id)",
            "CREATE INDEX IF NOT EXISTS idx_commands_agent_kind ON commands(agent_kind)",
            "CREATE INDEX IF NOT EXISTS idx_commands_outcome ON commands(outcome)",
            "CREATE INDEX IF NOT EXISTS idx_commands_destructive ON commands(is_destructive)",
            "CREATE INDEX IF NOT EXISTS idx_commands_project ON commands(project_path)",

        ]
    }

    /// v1 DDL：perf_samples 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1perfSamplesDDL() -> [String] {
        [
            // ---- perf_samples ----
            """
            CREATE TABLE IF NOT EXISTS perf_samples (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                session_id TEXT,
                agent_id TEXT,
                cpu_percent REAL NOT NULL,
                memory_bytes INTEGER NOT NULL,
                gpu_percent REAL,
                disk_read_bytes_per_second REAL NOT NULL,
                disk_write_bytes_per_second REAL NOT NULL,
                network_bytes_in INTEGER NOT NULL,
                network_bytes_out INTEGER NOT NULL,
                thermal_celsius REAL,
                power_watts REAL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_perf_session ON perf_samples(session_id, timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_perf_ts ON perf_samples(timestamp)",

        ]
    }

    /// v1 DDL：system_perf 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1systemPerfDDL() -> [String] {
        [
            // ---- system_perf ----
            """
            CREATE TABLE IF NOT EXISTS system_perf (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                cpu_total_percent REAL NOT NULL,
                cpu_system_percent REAL NOT NULL,
                cpu_user_percent REAL NOT NULL,
                memory_used_bytes INTEGER NOT NULL,
                memory_total_bytes INTEGER NOT NULL,
                disk_read_bytes_per_second REAL NOT NULL,
                disk_write_bytes_per_second REAL NOT NULL,
                load_average_1m REAL NOT NULL,
                thermal_celsius REAL,
                power_watts REAL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_sysperf_ts ON system_perf(timestamp)",

        ]
    }

    /// v1 DDL：risk_events 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1riskEventsDDL() -> [String] {
        [
            // ---- risk_events ----
            """
            CREATE TABLE IF NOT EXISTS risk_events (
                id TEXT PRIMARY KEY,
                timestamp REAL NOT NULL,
                level TEXT NOT NULL,
                level_rank INTEGER NOT NULL,
                category TEXT NOT NULL,
                title TEXT NOT NULL,
                detail TEXT NOT NULL,
                agent_id TEXT,
                agent_kind TEXT NOT NULL,
                session_id TEXT,
                command TEXT,
                file_paths_json TEXT NOT NULL,
                requires_confirmation INTEGER NOT NULL,
                is_acknowledged INTEGER NOT NULL,
                matched_rule_id TEXT,
                search_text TEXT NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_risk_ts ON risk_events(timestamp)",
            "CREATE INDEX IF NOT EXISTS idx_risk_level ON risk_events(level)",
            "CREATE INDEX IF NOT EXISTS idx_risk_category ON risk_events(category)",
            "CREATE INDEX IF NOT EXISTS idx_risk_session ON risk_events(session_id)",
            "CREATE INDEX IF NOT EXISTS idx_risk_ack ON risk_events(is_acknowledged)",
            "CREATE INDEX IF NOT EXISTS idx_risk_agent_kind ON risk_events(agent_kind)",

        ]
    }

    /// v1 DDL：projects 表与它的索引。语句顺序与拆成单块时逐条一致。
    private static func version1projectsDDL() -> [String] {
        [
            // ---- projects ----
            """
            CREATE TABLE IF NOT EXISTS projects (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                path TEXT NOT NULL,
                file_change_count INTEGER NOT NULL,
                command_count INTEGER NOT NULL,
                session_count INTEGER NOT NULL,
                risk_event_count INTEGER NOT NULL,
                code_growth_lines INTEGER NOT NULL,
                code_shrink_lines INTEGER NOT NULL,
                agent_contributions_json TEXT NOT NULL,
                hot_files_json TEXT NOT NULL,
                first_seen_at REAL NOT NULL,
                last_seen_at REAL NOT NULL
            )
            """,
            "CREATE INDEX IF NOT EXISTS idx_projects_last_seen ON projects(last_seen_at)",
            "CREATE INDEX IF NOT EXISTS idx_projects_path ON projects(path)",
        ]
    }

    private static func version1Statements() -> [SQLiteStatement] {
        let ddl: [String] =
            version1agentsDDL()
            + version1sessionsDDL()
            + version1eventsDDL()
            + version1fileChangesDDL()
            + version1diffsDDL()
            + version1commandsDDL()
            + version1perfSamplesDDL()
            + version1systemPerfDDL()
            + version1riskEventsDDL()
            + version1projectsDDL()
        return ddl.map { SQLiteStatement($0) }
    }

}
