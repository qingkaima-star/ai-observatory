//
//  SwiftDataRows.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-SwiftData
//
//  领域值类型 ⇄ `@Model` 记录的双向映射。规则逐字对齐 SQLite 后端：
//    · 写入侧 = `AIObservatoryStore.StoreValues`（日期 `Date`、UInt64 按 bit-pattern、
//      Bool 存 0/1、JSON 列表存 JSON 文本、`search_text` 用 Swift `.lowercased()` 预计算）。
//    · 读取侧 = `AIObservatoryStore.StoreRows`（**任何**关键列缺失/枚举 rawValue 无法识别
//      → 整行返回 nil，由调用方 `compactMap` 丢弃；绝不伪造默认值。
//      JSON 列表宽松解码，失败回退空数组并记日志；唯独 `diffs.lines_json` 严格，
//      解不出来就丢弃整条 diff）。
//
//  `search_text` 的拼接顺序必须与 `InMemoryObservatoryService` 的 haystack 一致，
//  否则同一批数据在两个后端上搜出不同的行。
//

import Foundation
import os
import AIObservatoryCore
import SwiftData

// MARK: - 值编码

/// 领域值 → SwiftData 属性值的统一口径。
enum SwiftDataValues {

    /// `UInt64` → 有符号 `Int`（bit-pattern）。
    ///
    /// 与 SQLite 侧 `StoreValues.uint64`（`Int64(bitPattern:)`）同口径：
    /// SwiftData 的 `Int` 就是 `Int64`，因此两端的**磁盘字节**也相同，
    /// 迁移时可以直接搬。大于 `Int64.max` 的字节数会存成负数——这是有意的，
    /// 换成 `Double` 或 `String` 反而会让两个后端查出的结果不可比。
    static func integer(from value: UInt64) -> Int {
        Int(Int64(bitPattern: value))
    }

    /// 有符号 `Int` → `UInt64`（`integer(from:)` 的逆）。
    static func uint64(from value: Int) -> UInt64 {
        UInt64(bitPattern: Int64(value))
    }

    static func uint64(from value: Int?) -> UInt64? {
        value.map { uint64(from: $0) }
    }

    /// 编码 JSON 列表列。与 SQLite 侧同为默认 `JSONEncoder`，因此文本逐字节一致。
    ///
    /// 失败时回退 `"[]"` 并记日志——沿用 SQLite 后端的行为：一列坏掉的 JSON 不该让
    /// 整条记录写不进库（读回时按空集合处理，可诊断）。
    static func json<T: Encodable>(_ value: T) -> String {
        do {
            let data = try JSONEncoder().encode(value)
            return String(decoding: data, as: UTF8.self)
        } catch {
            ObservatoryLog.store.error(
                "StoreJSON encode failed, wrote empty array: \(error.localizedDescription, privacy: .public)"
            )
            return "[]"
        }
    }

    /// 宽松解码：失败或为 nil 时返回 `fallback`。
    static func decodeList<T: Decodable>(_ type: [T].Type, from text: String?, fallback: [T]) -> [T] {
        guard let text, let data = text.data(using: .utf8) else { return fallback }
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            ObservatoryLog.store.warning(
                "StoreJSON decode failed for \(String(describing: type), privacy: .public); using fallback"
            )
            return fallback
        }
    }

    /// 严格解码：失败返回 nil（调用方据此丢弃整行，不伪造空 diff）。
    static func decodeRequiredList<T: Decodable>(_ type: [T].Type, from text: String?) -> [T]? {
        guard let text, let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    static func uuid(_ text: String?) -> UUID? {
        guard let text else { return nil }
        return UUID(uuidString: text)
    }
}

// MARK: - 搜索文本预计算

/// 写入侧预计算的小写 haystack，与 SQLite 后端 / `InMemoryObservatoryService` 逐字一致。
enum SwiftDataSearchText {

    static func session(_ session: AgentSession) -> String {
        "\(session.title) \(session.projectPath ?? "") \(session.kind.displayName)".lowercased()
    }

    static func event(_ event: TimelineEvent) -> String {
        "\(event.title) \(event.summary) \(event.filePath ?? "") \(event.command ?? "")".lowercased()
    }

    static func fileChange(_ change: FileChange) -> String {
        change.path.lowercased()
    }

    static func command(_ command: CommandRecord) -> String {
        command.commandLine.lowercased()
    }

    static func risk(_ risk: RiskEvent) -> String {
        "\(risk.title) \(risk.detail) \(risk.command ?? "")".lowercased()
    }
}

// MARK: - 记录 → 领域模型

extension SDAgent {

    /// 还原 `AgentInstance`；枚举 rawValue 无法识别或 id 不是 UUID 时返回 nil。
    func domainValue() -> AgentInstance? {
        guard let id = SwiftDataValues.uuid(self.rowID),
              let kind = AgentKind(rawValue: self.kind),
              let state = AgentRunState(rawValue: self.state),
              let detectedVia = DetectionSignal(rawValue: self.detectedVia)
        else { return nil }
        return AgentInstance(
            id: id,
            kind: kind,
            pid: Int32(clamping: pid),
            parentPID: parentPID.map { Int32(clamping: $0) },
            displayName: displayName,
            executablePath: executablePath,
            workingDirectory: workingDirectory,
            bundleIdentifier: bundleIdentifier,
            tty: tty,
            startedAt: startedAt,
            lastSeenAt: lastSeenAt,
            state: state,
            cpuPercent: cpuPercent,
            memoryBytes: SwiftDataValues.uint64(from: memoryBytes),
            childPIDs: SwiftDataValues.decodeList(
                [Int32].self, from: childPIDsJSON, fallback: []
            ),
            detectedVia: detectedVia
        )
    }
}

extension SDSession {

    func domainValue() -> AgentSession? {
        guard let id = SwiftDataValues.uuid(self.rowID),
              let kind = AgentKind(rawValue: self.kind),
              let outcome = SessionOutcome(rawValue: self.outcome)
        else { return nil }
        return AgentSession(
            id: id,
            displayIndex: displayIndex,
            kind: kind,
            agentID: SwiftDataValues.uuid(agentID),
            title: title,
            projectPath: projectPath,
            startedAt: startedAt,
            endedAt: endedAt,
            modifiedFileCount: modifiedFileCount,
            createdFileCount: createdFileCount,
            deletedFileCount: deletedFileCount,
            commandCount: commandCount,
            failedCommandCount: failedCommandCount,
            cpuSeconds: cpuSeconds,
            peakCPUPercent: peakCPUPercent,
            peakMemoryBytes: SwiftDataValues.uint64(from: peakMemoryBytes),
            estimatedTokens: estimatedTokens,
            riskEventCount: riskEventCount,
            outcome: outcome
        )
    }
}

extension SDEvent {

    func domainValue() -> TimelineEvent? {
        guard let id = SwiftDataValues.uuid(self.rowID),
              let kind = OperationKind(rawValue: self.kind),
              let agentKind = AgentKind(rawValue: self.agentKind),
              let riskLevel = RiskLevel(rawValue: self.riskLevel)
        else { return nil }
        return TimelineEvent(
            id: id,
            timestamp: timestamp,
            sessionID: SwiftDataValues.uuid(sessionID),
            agentID: SwiftDataValues.uuid(agentID),
            agentKind: agentKind,
            kind: kind,
            title: title,
            summary: summary,
            filePath: filePath,
            command: command,
            exitCode: exitCode.map { Int32(clamping: $0) },
            durationSeconds: durationSeconds,
            cost: ResourceCost(
                cpuSeconds: costCPUSeconds,
                memoryBytes: SwiftDataValues.uint64(from: costMemoryBytes),
                bytesRead: SwiftDataValues.uint64(from: costBytesRead),
                bytesWritten: SwiftDataValues.uint64(from: costBytesWritten)
            ),
            riskLevel: riskLevel,
            projectPath: projectPath
        )
    }
}

extension SDFileChange {

    func domainValue() -> FileChange? {
        guard let id = SwiftDataValues.uuid(self.rowID),
              let kind = FileChangeKind(rawValue: self.kind),
              let agentKind = AgentKind(rawValue: self.agentKind),
              let riskLevel = RiskLevel(rawValue: self.riskLevel)
        else { return nil }
        return FileChange(
            id: id,
            path: path,
            previousPath: previousPath,
            kind: kind,
            timestamp: timestamp,
            agentID: SwiftDataValues.uuid(agentID),
            sessionID: SwiftDataValues.uuid(sessionID),
            agentKind: agentKind,
            sizeBytes: SwiftDataValues.uint64(from: sizeBytes),
            previousSizeBytes: SwiftDataValues.uint64(from: previousSizeBytes),
            isText: isText,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            riskLevel: riskLevel,
            projectPath: projectPath
        )
    }
}

extension SDDiff {

    func domainValue() -> FileDiff? {
        guard let id = SwiftDataValues.uuid(self.rowID),
              let kind = FileChangeKind(rawValue: self.kind),
              let lines = SwiftDataValues.decodeRequiredList([DiffLine].self, from: linesJSON)
        else { return nil }
        return FileDiff(
            id: id,
            path: path,
            previousPath: previousPath,
            kind: kind,
            lines: lines,
            linesAdded: linesAdded,
            linesRemoved: linesRemoved,
            isBinary: isBinary,
            isTruncated: isTruncated,
            capturedAt: capturedAt,
            // 与 SQLite 后端同口径：列为 nil（自动迁移给老行的形状）与认不出的值都回落为
            // 「单边 diff」，绝不丢整条——丢了就等于把「有 diff」显示成「没有 diff」。
            baselineSource: baselineSource.flatMap(DiffBaselineSource.init(rawValue:)) ?? .unavailableFirstSighting,
            baselineCapturedAt: baselineCapturedAt,
            plaintextStored: plaintextStored ?? true
        )
    }
}

extension SDCommand {

    func domainValue() -> CommandRecord? {
        guard let id = SwiftDataValues.uuid(self.rowID),
              let kind = AgentKind(rawValue: self.agentKind),
              let outcome = CommandOutcome(rawValue: self.outcome),
              let riskLevel = RiskLevel(rawValue: self.riskLevel)
        else { return nil }
        return CommandRecord(
            id: id,
            executable: executable,
            arguments: SwiftDataValues.decodeList([String].self, from: argumentsJSON, fallback: []),
            workingDirectory: workingDirectory,
            agentID: SwiftDataValues.uuid(agentID),
            sessionID: SwiftDataValues.uuid(sessionID),
            agentKind: kind,
            startedAt: startedAt,
            endedAt: endedAt,
            exitCode: exitCode.map { Int32(clamping: $0) },
            outcome: outcome,
            isDestructive: isDestructive,
            requiresConfirmation: requiresConfirmation,
            riskLevel: riskLevel,
            projectPath: projectPath
        )
    }
}

extension SDPerformanceSample {

    func domainValue() -> PerformanceSample? {
        guard let id = SwiftDataValues.uuid(self.rowID) else { return nil }
        return PerformanceSample(
            id: id,
            timestamp: timestamp,
            sessionID: SwiftDataValues.uuid(sessionID),
            agentID: SwiftDataValues.uuid(agentID),
            cpuPercent: cpuPercent,
            memoryBytes: SwiftDataValues.uint64(from: memoryBytes),
            gpuPercent: gpuPercent,
            diskReadBytesPerSecond: diskReadBytesPerSecond,
            diskWriteBytesPerSecond: diskWriteBytesPerSecond,
            networkBytesIn: SwiftDataValues.uint64(from: networkBytesIn),
            networkBytesOut: SwiftDataValues.uint64(from: networkBytesOut),
            thermalCelsius: thermalCelsius,
            powerWatts: powerWatts
        )
    }
}

extension SDSystemPerformanceSample {

    func domainValue() -> SystemPerformanceSample? {
        guard let id = SwiftDataValues.uuid(self.rowID) else { return nil }
        return SystemPerformanceSample(
            id: id,
            timestamp: timestamp,
            cpuTotalPercent: cpuTotalPercent,
            cpuSystemPercent: cpuSystemPercent,
            cpuUserPercent: cpuUserPercent,
            memoryUsedBytes: SwiftDataValues.uint64(from: memoryUsedBytes),
            memoryTotalBytes: SwiftDataValues.uint64(from: memoryTotalBytes),
            diskReadBytesPerSecond: diskReadBytesPerSecond,
            diskWriteBytesPerSecond: diskWriteBytesPerSecond,
            loadAverage1m: loadAverage1m,
            thermalCelsius: thermalCelsius,
            powerWatts: powerWatts,
            // v3 之前写入的行这四列是 NULL ⇒ 读回来是 nil（「当时没采这个指标」），
            // 不能塌成 0——那会被界面念成「真的没有流量 / GPU 空闲」。
            // 口径与 StoreRows.systemPerformanceSample 逐字一致：枚举认不出也是 nil，
            // 但不因此丢弃整行。
            networkInBytesPerSecond: networkInBytesPerSecond,
            networkOutBytesPerSecond: networkOutBytesPerSecond,
            networkAvailability: networkAvailability.flatMap(NetworkRateAvailability.init(rawValue:)),
            gpuActivityPercent: gpuPercent
        )
    }
}

extension SDRiskEvent {

    func domainValue() -> RiskEvent? {
        guard let id = SwiftDataValues.uuid(self.rowID),
              let level = RiskLevel(rawValue: self.level),
              let category = RiskCategory(rawValue: self.category),
              let agentKind = AgentKind(rawValue: self.agentKind)
        else { return nil }
        return RiskEvent(
            id: id,
            timestamp: timestamp,
            level: level,
            category: category,
            title: title,
            detail: detail,
            agentID: SwiftDataValues.uuid(agentID),
            agentKind: agentKind,
            sessionID: SwiftDataValues.uuid(sessionID),
            command: command,
            filePaths: SwiftDataValues.decodeList([String].self, from: filePathsJSON, fallback: []),
            requiresConfirmation: requiresConfirmation,
            isAcknowledged: isAcknowledged,
            matchedRuleID: matchedRuleID
        )
    }
}

extension SDProject {

    func domainValue() -> ProjectActivity? {
        ProjectActivity(
            id: rowID,
            name: name,
            path: path,
            fileChangeCount: fileChangeCount,
            commandCount: commandCount,
            sessionCount: sessionCount,
            riskEventCount: riskEventCount,
            codeGrowthLines: codeGrowthLines,
            codeShrinkLines: codeShrinkLines,
            agentContributions: SwiftDataValues.decodeList(
                [AgentContribution].self, from: agentContributionsJSON, fallback: []
            ),
            hotFiles: SwiftDataValues.decodeList([FileHeat].self, from: hotFilesJSON, fallback: []),
            firstSeenAt: firstSeenAt,
            lastSeenAt: lastSeenAt
        )
    }
}

extension SDFileSnapshot {

    func domainValue() -> FileSnapshot? {
        guard let id = SwiftDataValues.uuid(self.rowID) else { return nil }
        return FileSnapshot(
            id: id,
            path: path,
            contentHash: contentHash,
            sizeBytes: SwiftDataValues.uint64(from: sizeBytes),
            capturedAt: capturedAt,
            lineCount: lineCount
        )
    }
}
