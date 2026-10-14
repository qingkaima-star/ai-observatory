//
//  StoreSQL.swift
//  AIObservatoryStore
//
//  Owner: WS-Engine（由 ObservatoryStore.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import os
import AIObservatoryCore
// MARK: - SQL 常量（全部 ? 参数化；B/E 共用）

/// ObservatoryStore 使用的 SQL 语句常量。列名逐字对齐 INTERFACE.md §4。
enum StoreSQL {

    static let upsertAgent = """
    INSERT INTO agents (id, kind, pid, parent_pid, display_name, executable_path, working_directory,
        bundle_identifier, tty, started_at, last_seen_at, state, cpu_percent, memory_bytes,
        child_pids_json, detected_via)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET
        kind=excluded.kind, pid=excluded.pid, parent_pid=excluded.parent_pid,
        display_name=excluded.display_name, executable_path=excluded.executable_path,
        working_directory=excluded.working_directory, bundle_identifier=excluded.bundle_identifier,
        tty=excluded.tty, started_at=excluded.started_at, last_seen_at=excluded.last_seen_at,
        state=excluded.state, cpu_percent=excluded.cpu_percent, memory_bytes=excluded.memory_bytes,
        child_pids_json=excluded.child_pids_json, detected_via=excluded.detected_via
    """

    /// 会话整行覆盖。`risk_event_count` **刻意不在** `DO UPDATE SET` 里：那一列由
    /// `recomputeSessionRiskCount` 派生，写第二遍就会把自增值盖到派生值上（#35 那条 P0）。
    /// 插入分支仍带着它，紧跟着的重算会把它校正成派生值——见 `upsertSessions(_:)`。
    static let upsertSession = """
    INSERT INTO sessions (id, display_index, kind, agent_id, title, project_path, started_at, ended_at,
        modified_file_count, created_file_count, deleted_file_count, command_count, failed_command_count,
        cpu_seconds, peak_cpu_percent, peak_memory_bytes, estimated_tokens, risk_event_count,
        outcome, search_text)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET
        display_index=excluded.display_index, kind=excluded.kind, agent_id=excluded.agent_id,
        title=excluded.title, project_path=excluded.project_path, started_at=excluded.started_at,
        ended_at=excluded.ended_at, modified_file_count=excluded.modified_file_count,
        created_file_count=excluded.created_file_count, deleted_file_count=excluded.deleted_file_count,
        command_count=excluded.command_count, failed_command_count=excluded.failed_command_count,
        cpu_seconds=excluded.cpu_seconds, peak_cpu_percent=excluded.peak_cpu_percent,
        peak_memory_bytes=excluded.peak_memory_bytes, estimated_tokens=excluded.estimated_tokens,
        outcome=excluded.outcome,
        search_text=excluded.search_text
    """

    static let upsertProject = """
    INSERT INTO projects (id, name, path, file_change_count, command_count, session_count,
        risk_event_count, code_growth_lines, code_shrink_lines, agent_contributions_json,
        hot_files_json, first_seen_at, last_seen_at)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET
        name=excluded.name, path=excluded.path, file_change_count=excluded.file_change_count,
        command_count=excluded.command_count, session_count=excluded.session_count,
        risk_event_count=excluded.risk_event_count, code_growth_lines=excluded.code_growth_lines,
        code_shrink_lines=excluded.code_shrink_lines,
        agent_contributions_json=excluded.agent_contributions_json,
        hot_files_json=excluded.hot_files_json, first_seen_at=excluded.first_seen_at,
        last_seen_at=excluded.last_seen_at
    """

    static let upsertRisk = """
    INSERT INTO risk_events (id, timestamp, level, level_rank, category, title, detail, agent_id,
        agent_kind, session_id, command, file_paths_json, requires_confirmation, is_acknowledged,
        matched_rule_id, search_text)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET
        timestamp=excluded.timestamp, level=excluded.level, level_rank=excluded.level_rank,
        category=excluded.category, title=excluded.title, detail=excluded.detail,
        agent_id=excluded.agent_id, agent_kind=excluded.agent_kind, session_id=excluded.session_id,
        command=excluded.command, file_paths_json=excluded.file_paths_json,
        requires_confirmation=excluded.requires_confirmation,
        is_acknowledged=MAX(is_acknowledged, excluded.is_acknowledged),
        matched_rule_id=excluded.matched_rule_id,
        search_text=excluded.search_text
    """

    static let insertDiff = """
    INSERT OR REPLACE INTO diffs (id, change_id, path, previous_path, kind, lines_json,
        lines_added, lines_removed, is_binary, is_truncated, captured_at,
        baseline_source, baseline_captured_at, plaintext_stored)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    static let insertSnapshot = """
    INSERT OR REPLACE INTO file_snapshots (id, path, content_hash, size_bytes, line_count, captured_at)
    VALUES (?,?,?,?,?,?)
    """

    /// 缓冲写入用普通 `INSERT`（不是 `OR IGNORE`）：约束违规必须冒出来。
    /// BatchWriter 整批失败时会逐条重投，只丢弃真正违规的那条并计入 `droppedStatementCount`；
    /// 用 `OR IGNORE` 会把数据丢失变成静默行为。
    static let insertEvent = """
    INSERT INTO events (id, timestamp, session_id, agent_id, agent_kind, kind, title, summary,
        file_path, command, exit_code, duration_seconds, cost_cpu_seconds, cost_memory_bytes,
        cost_bytes_read, cost_bytes_written, risk_level, risk_rank, project_path, search_text)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    /// 与 `insertEvent` 同列同序，只多一段 `DO UPDATE`：给**确定性 id 的派生行**用
    /// （见 `upsertEvents(_:)`）。列集合与 `insertEvent` 的一致性由 `eventArguments` 保证——
    /// 两条路径共用同一份绑定值。
    static let upsertEvent = """
    INSERT INTO events (id, timestamp, session_id, agent_id, agent_kind, kind, title, summary,
        file_path, command, exit_code, duration_seconds, cost_cpu_seconds, cost_memory_bytes,
        cost_bytes_read, cost_bytes_written, risk_level, risk_rank, project_path, search_text)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    ON CONFLICT(id) DO UPDATE SET
        timestamp=excluded.timestamp, session_id=excluded.session_id, agent_id=excluded.agent_id,
        agent_kind=excluded.agent_kind, kind=excluded.kind, title=excluded.title,
        summary=excluded.summary, file_path=excluded.file_path, command=excluded.command,
        exit_code=excluded.exit_code, duration_seconds=excluded.duration_seconds,
        cost_cpu_seconds=excluded.cost_cpu_seconds, cost_memory_bytes=excluded.cost_memory_bytes,
        cost_bytes_read=excluded.cost_bytes_read, cost_bytes_written=excluded.cost_bytes_written,
        risk_level=excluded.risk_level, risk_rank=excluded.risk_rank,
        project_path=excluded.project_path, search_text=excluded.search_text
    """

    static let insertFileChange = """
    INSERT INTO file_changes (id, path, previous_path, kind, timestamp, agent_id, session_id,
        agent_kind, size_bytes, previous_size_bytes, is_text, lines_added, lines_removed,
        risk_level, risk_rank, project_path, search_text)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    static let insertCommand = """
    INSERT INTO commands (id, executable, arguments_json, working_directory, agent_id,
        session_id, agent_kind, started_at, ended_at, exit_code, outcome, is_destructive,
        requires_confirmation, risk_level, risk_rank, project_path, search_text)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    static let insertPerfSample = """
    INSERT INTO perf_samples (id, timestamp, session_id, agent_id, cpu_percent, memory_bytes,
        gpu_percent, disk_read_bytes_per_second, disk_write_bytes_per_second, network_bytes_in,
        network_bytes_out, thermal_celsius, power_watts)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    static let insertSystemPerf = """
    INSERT INTO system_perf (id, timestamp, cpu_total_percent, cpu_system_percent,
        cpu_user_percent, memory_used_bytes, memory_total_bytes, disk_read_bytes_per_second,
        disk_write_bytes_per_second, load_average_1m, thermal_celsius, power_watts,
        network_in_bytes_per_second, network_out_bytes_per_second, network_availability, gpu_percent)
    VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
    """

    static let acknowledgeRisk = "UPDATE risk_events SET is_acknowledged = 1 WHERE id = ?"

    /// 重算指定会话的风险条数：派生自 `risk_events`，因此同一批风险重复录入不会双计数
    /// （旧的 `risk_event_count = risk_event_count + ?` 语义在重录时会翻倍）。
    static func recomputeSessionRiskCount(sessionIDCount: Int) -> String {
        let placeholders = Array(repeating: "?", count: max(sessionIDCount, 1)).joined(separator: ", ")
        return """
        UPDATE sessions SET risk_event_count = (
            SELECT COUNT(*) FROM risk_events WHERE risk_events.session_id = sessions.id
        ) WHERE id IN (\(placeholders))
        """
    }

    /// 活跃 Agent：按最近可见时间倒序，保证同一份数据每次返回同一顺序（无 ORDER BY 时 SQLite 顺序不保证）。
    static let selectActiveAgents = "SELECT * FROM agents WHERE state IN (?, ?) ORDER BY last_seen_at DESC, id ASC"

    static let selectOpenSessionCount = "SELECT COUNT(*) FROM sessions WHERE ended_at IS NULL"

    /// 会话编号的下限来源：全历史，**不是**只查未结算的那几行（见 `maxSessionDisplayIndex()`）。
    static let selectMaxSessionDisplayIndex = "SELECT MAX(display_index) FROM sessions"

    static let selectOpenSessions = """
    SELECT * FROM sessions WHERE ended_at IS NULL ORDER BY started_at ASC, id ASC
    """

    static let markInterruptedReturning = """
    UPDATE sessions SET ended_at = ?, outcome = ? WHERE ended_at IS NULL RETURNING id
    """
}

/// 兼容别名：文件内以 `SQL.xxx` 引用（保持私有语句名简短）。
typealias SQL = StoreSQL

