//
//  MigrationSourceRows.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-Engine（由 SwiftDataMigration.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import os
import SQLite3
import AIObservatoryCore
// MARK: - 源库行 → 领域模型

/// 行 → 领域模型。解码口径与 `AIObservatoryStore.StoreRows` 逐条对齐：任一关键列缺失 /
/// 类型不符 / 枚举 rawValue 无法识别 → 整行返回 nil，由迁移器计入 `skipped`；绝不伪造默认值。
/// JSON 列表列复用 `SwiftDataValues.decodeList`（宽松，失败回退空集合并记日志），
/// 只有 `diffs.lines_json` 用 `decodeRequiredList`（失败丢整行）。
enum SQLiteSourceRows {

    static func agent(from row: SQLiteSourceRow) -> AgentInstance? {
        guard let id = row.uuid("id"),
              let kind = row.text("kind").flatMap({ AgentKind(rawValue: $0) }),
              let pid = row.int("pid"),
              let displayName = row.text("display_name"),
              let executablePath = row.text("executable_path"),
              let startedAt = row.date("started_at"),
              let lastSeenAt = row.date("last_seen_at"),
              let state = row.text("state").flatMap({ AgentRunState(rawValue: $0) }),
              let cpuPercent = row.double("cpu_percent"),
              let memoryBytes = row.uint64("memory_bytes"),
              let detectedVia = row.text("detected_via").flatMap({ DetectionSignal(rawValue: $0) })
        else { return nil }
        return AgentInstance(
            id: id,
            kind: kind,
            pid: Int32(clamping: pid),
            parentPID: row.int("parent_pid").map { Int32(clamping: $0) },
            displayName: displayName,
            executablePath: executablePath,
            workingDirectory: row.text("working_directory"),
            bundleIdentifier: row.text("bundle_identifier"),
            tty: row.text("tty"),
            startedAt: startedAt,
            lastSeenAt: lastSeenAt,
            state: state,
            cpuPercent: cpuPercent,
            memoryBytes: memoryBytes,
            childPIDs: SwiftDataValues.decodeList([Int32].self, from: row.text("child_pids_json"), fallback: []),
            detectedVia: detectedVia
        )
    }

    static func session(from row: SQLiteSourceRow) -> AgentSession? {
        guard let id = row.uuid("id"),
              let displayIndex = row.int("display_index"),
              let kind = row.text("kind").flatMap({ AgentKind(rawValue: $0) }),
              let title = row.text("title"),
              let startedAt = row.date("started_at"),
              let modifiedFileCount = row.int("modified_file_count"),
              let createdFileCount = row.int("created_file_count"),
              let deletedFileCount = row.int("deleted_file_count"),
              let commandCount = row.int("command_count"),
              let failedCommandCount = row.int("failed_command_count"),
              let cpuSeconds = row.double("cpu_seconds"),
              let peakCPUPercent = row.double("peak_cpu_percent"),
              let peakMemoryBytes = row.uint64("peak_memory_bytes"),
              let estimatedTokens = row.int("estimated_tokens"),
              let riskEventCount = row.int("risk_event_count"),
              let outcome = row.text("outcome").flatMap({ SessionOutcome(rawValue: $0) })
        else { return nil }
        return AgentSession(
            id: id,
            displayIndex: displayIndex,
            kind: kind,
            agentID: row.uuid("agent_id"),
            title: title,
            projectPath: row.text("project_path"),
            startedAt: startedAt,
            endedAt: row.date("ended_at"),
            modifiedFileCount: modifiedFileCount,
            createdFileCount: createdFileCount,
            deletedFileCount: deletedFileCount,
            commandCount: commandCount,
            failedCommandCount: failedCommandCount,
            cpuSeconds: cpuSeconds,
            peakCPUPercent: peakCPUPercent,
            peakMemoryBytes: peakMemoryBytes,
            estimatedTokens: estimatedTokens,
            riskEventCount: riskEventCount,
            outcome: outcome
        )
    }

    static func event(from row: SQLiteSourceRow) -> TimelineEvent? {
        guard let id = row.uuid("id"),
              let timestamp = row.date("timestamp"),
              let agentKind = row.text("agent_kind").flatMap({ AgentKind(rawValue: $0) }),
              let kind = row.text("kind").flatMap({ OperationKind(rawValue: $0) }),
              let title = row.text("title"),
              let summary = row.text("summary"),
              let cpuSeconds = row.double("cost_cpu_seconds"),
              let memoryBytes = row.uint64("cost_memory_bytes"),
              let bytesRead = row.uint64("cost_bytes_read"),
              let bytesWritten = row.uint64("cost_bytes_written"),
              let riskLevel = row.text("risk_level").flatMap({ RiskLevel(rawValue: $0) })
        else { return nil }
        return TimelineEvent(
            id: id,
            timestamp: timestamp,
            sessionID: row.uuid("session_id"),
            agentID: row.uuid("agent_id"),
            agentKind: agentKind,
            kind: kind,
            title: title,
            summary: summary,
            filePath: row.text("file_path"),
            command: row.text("command"),
            exitCode: row.int("exit_code").map { Int32(clamping: $0) },
            durationSeconds: row.double("duration_seconds"),
            cost: ResourceCost(
                cpuSeconds: cpuSeconds,
                memoryBytes: memoryBytes,
                bytesRead: bytesRead,
                bytesWritten: bytesWritten
            ),
            riskLevel: riskLevel,
            projectPath: row.text("project_path")
        )
    }

    static func fileChange(from row: SQLiteSourceRow) -> FileChange? {
        guard let id = row.uuid("id"),
              let path = row.text("path"),
              let kind = row.text("kind").flatMap({ FileChangeKind(rawValue: $0) }),
              let timestamp = row.date("timestamp"),
              let agentKind = row.text("agent_kind").flatMap({ AgentKind(rawValue: $0) }),
              let sizeBytes = row.uint64("size_bytes"),
              let linesAdded = row.int("lines_added"),
              let linesRemoved = row.int("lines_removed"),
              let riskLevel = row.text("risk_level").flatMap({ RiskLevel(rawValue: $0) })
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
            sizeBytes: sizeBytes,
            previousSizeBytes: row.uint64("previous_size_bytes"),
            isText: row.bool("is_text"),
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            riskLevel: riskLevel,
            projectPath: row.text("project_path")
        )
    }

    /// `diffs` 行 → `FileDiff` + `change_id`。
    ///
    /// `FileDiff.id` 用库里存的 `id`，`forChangeID` 用库里的 `change_id`
    /// （SQLite 侧约定两者相等，见 `ObservatoryStore.record(_:forChangeID:)` 的 P2-9 注释）。
    static func diffEntry(from row: SQLiteSourceRow) -> MigrationDiffEntry? {
        guard let id = row.uuid("id"),
              let changeID = row.uuid("change_id"),
              let path = row.text("path"),
              let kind = row.text("kind").flatMap({ FileChangeKind(rawValue: $0) }),
              let linesAdded = row.int("lines_added"),
              let linesRemoved = row.int("lines_removed"),
              let capturedAt = row.date("captured_at"),
              let lines = SwiftDataValues.decodeRequiredList([DiffLine].self, from: row.text("lines_json"))
        else { return nil }
        let diff = FileDiff(
            id: id,
            path: path,
            previousPath: row.text("previous_path"),
            kind: kind,
            lines: lines,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            isBinary: row.bool("is_binary"),
            isTruncated: row.bool("is_truncated"),
            capturedAt: capturedAt,
            // 源库若只到 v3，这两列压根不存在 ⇒ `column(_:)` 返回 nil ⇒ 同 SQLite 读侧
            // 一样回落「单边 diff」。缺列不是坏行：把它 skip 掉会让迁移凭空吃掉历史 diff。
            baselineSource: row.text("baseline_source")
                .flatMap(DiffBaselineSource.init(rawValue:)) ?? .unavailableFirstSighting,
            baselineCapturedAt: row.date("baseline_captured_at"),
            plaintextStored: row.int("plaintext_stored").map { $0 != 0 } ?? true
        )
        return MigrationDiffEntry(diff: diff, changeID: changeID)
    }

    static func command(from row: SQLiteSourceRow) -> CommandRecord? {
        guard let id = row.uuid("id"),
              let executable = row.text("executable"),
              let agentKind = row.text("agent_kind").flatMap({ AgentKind(rawValue: $0) }),
              let startedAt = row.date("started_at"),
              let outcome = row.text("outcome").flatMap({ CommandOutcome(rawValue: $0) }),
              let riskLevel = row.text("risk_level").flatMap({ RiskLevel(rawValue: $0) })
        else { return nil }
        return CommandRecord(
            id: id,
            executable: executable,
            arguments: SwiftDataValues.decodeList([String].self, from: row.text("arguments_json"), fallback: []),
            workingDirectory: row.text("working_directory"),
            agentID: row.uuid("agent_id"),
            sessionID: row.uuid("session_id"),
            agentKind: agentKind,
            startedAt: startedAt,
            endedAt: row.date("ended_at"),
            exitCode: row.int("exit_code").map { Int32(clamping: $0) },
            outcome: outcome,
            isDestructive: row.bool("is_destructive"),
            requiresConfirmation: row.bool("requires_confirmation"),
            riskLevel: riskLevel,
            projectPath: row.text("project_path")
        )
    }

    static func performanceSample(from row: SQLiteSourceRow) -> PerformanceSample? {
        guard let id = row.uuid("id"),
              let timestamp = row.date("timestamp"),
              let cpuPercent = row.double("cpu_percent"),
              let memoryBytes = row.uint64("memory_bytes"),
              let diskRead = row.double("disk_read_bytes_per_second"),
              let diskWrite = row.double("disk_write_bytes_per_second"),
              let networkIn = row.uint64("network_bytes_in"),
              let networkOut = row.uint64("network_bytes_out")
        else { return nil }
        return PerformanceSample(
            id: id,
            timestamp: timestamp,
            sessionID: row.uuid("session_id"),
            agentID: row.uuid("agent_id"),
            cpuPercent: cpuPercent,
            memoryBytes: memoryBytes,
            gpuPercent: row.double("gpu_percent"),
            diskReadBytesPerSecond: diskRead,
            diskWriteBytesPerSecond: diskWrite,
            networkBytesIn: networkIn,
            networkBytesOut: networkOut,
            thermalCelsius: row.double("thermal_celsius"),
            powerWatts: row.double("power_watts")
        )
    }

    static func systemPerformanceSample(from row: SQLiteSourceRow) -> SystemPerformanceSample? {
        guard let id = row.uuid("id"),
              let timestamp = row.date("timestamp"),
              let cpuTotal = row.double("cpu_total_percent"),
              let cpuSystem = row.double("cpu_system_percent"),
              let cpuUser = row.double("cpu_user_percent"),
              let memoryUsed = row.uint64("memory_used_bytes"),
              let memoryTotal = row.uint64("memory_total_bytes"),
              let diskRead = row.double("disk_read_bytes_per_second"),
              let diskWrite = row.double("disk_write_bytes_per_second"),
              let loadAverage = row.double("load_average_1m")
        else { return nil }
        return SystemPerformanceSample(
            id: id,
            timestamp: timestamp,
            cpuTotalPercent: cpuTotal,
            cpuSystemPercent: cpuSystem,
            cpuUserPercent: cpuUser,
            memoryUsedBytes: memoryUsed,
            memoryTotalBytes: memoryTotal,
            diskReadBytesPerSecond: diskRead,
            diskWriteBytesPerSecond: diskWrite,
            loadAverage1m: loadAverage,
            thermalCelsius: row.double("thermal_celsius"),
            powerWatts: row.double("power_watts"),
            // v3（`system-perf-network-gpu`）新增四列。逐字对齐 StoreRows 的口径：
            // 缺列/NULL 一律 nil，枚举认不出也是 nil 而不丢整行。
            // 迁移用的是 `SELECT *`，所以 v2 时代的源库（根本没这四列）在这里自然退化为
            // nil——不需要探测 schema 版本，也不会把「当时没采这个指标」伪造成记成 0。
            networkInBytesPerSecond: row.double("network_in_bytes_per_second"),
            networkOutBytesPerSecond: row.double("network_out_bytes_per_second"),
            networkAvailability: row.text("network_availability")
                .flatMap(NetworkRateAvailability.init(rawValue:)),
            gpuActivityPercent: row.double("gpu_percent")
        )
    }

    static func riskEvent(from row: SQLiteSourceRow) -> RiskEvent? {
        guard let id = row.uuid("id"),
              let timestamp = row.date("timestamp"),
              let level = row.text("level").flatMap({ RiskLevel(rawValue: $0) }),
              let category = row.text("category").flatMap({ RiskCategory(rawValue: $0) }),
              let title = row.text("title"),
              let detail = row.text("detail"),
              let agentKind = row.text("agent_kind").flatMap({ AgentKind(rawValue: $0) })
        else { return nil }
        return RiskEvent(
            id: id,
            timestamp: timestamp,
            level: level,
            category: category,
            title: title,
            detail: detail,
            agentID: row.uuid("agent_id"),
            agentKind: agentKind,
            sessionID: row.uuid("session_id"),
            command: row.text("command"),
            filePaths: SwiftDataValues.decodeList([String].self, from: row.text("file_paths_json"), fallback: []),
            requiresConfirmation: row.bool("requires_confirmation"),
            isAcknowledged: row.bool("is_acknowledged"),
            matchedRuleID: row.text("matched_rule_id")
        )
    }

    /// `projects.id` 是路径字符串（不是 UUID），与 `StoreRows.project` 一样不做 UUID 校验；
    /// 它同时是 `SDProject` 的 `@Attribute(.unique)` 主键，所以 keyset 分页与覆盖式 upsert 共用它。
    static func project(from row: SQLiteSourceRow) -> ProjectActivity? {
        guard let id = row.text("id"),
              let name = row.text("name"),
              let path = row.text("path"),
              let fileChangeCount = row.int("file_change_count"),
              let commandCount = row.int("command_count"),
              let sessionCount = row.int("session_count"),
              let riskEventCount = row.int("risk_event_count"),
              let codeGrowthLines = row.int("code_growth_lines"),
              let codeShrinkLines = row.int("code_shrink_lines"),
              let firstSeenAt = row.date("first_seen_at"),
              let lastSeenAt = row.date("last_seen_at")
        else { return nil }
        return ProjectActivity(
            id: id,
            name: name,
            path: path,
            fileChangeCount: fileChangeCount,
            commandCount: commandCount,
            sessionCount: sessionCount,
            riskEventCount: riskEventCount,
            codeGrowthLines: codeGrowthLines,
            codeShrinkLines: codeShrinkLines,
            agentContributions: SwiftDataValues.decodeList(
                [AgentContribution].self, from: row.text("agent_contributions_json"), fallback: []
            ),
            hotFiles: SwiftDataValues.decodeList([FileHeat].self, from: row.text("hot_files_json"), fallback: []),
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt
        )
    }

    /// `StoreSchema` v2 才建的表；`StoreRows` 没有对应的解码函数（SQLite 后端只写不读），
    /// 这里按同样的「关键列缺一整行作废」口径补一个。
    static func snapshot(from row: SQLiteSourceRow) -> FileSnapshot? {
        guard let id = row.uuid("id"),
              let path = row.text("path"),
              let contentHash = row.text("content_hash"),
              let sizeBytes = row.uint64("size_bytes"),
              let lineCount = row.int("line_count"),
              let capturedAt = row.date("captured_at")
        else { return nil }
        return FileSnapshot(
            id: id,
            path: path,
            contentHash: contentHash,
            sizeBytes: sizeBytes,
            capturedAt: capturedAt,
            lineCount: lineCount
        )
    }
}
