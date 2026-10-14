//
//  SwiftDataStoreRoundTripTests.swift
//  AIObservatorySwiftDataStoreTests
//
//  Owner: WS-SwiftData（子代理 · 验收清单第 2 条）
//
//  **写入 → 读回无损**：11 类实体（agents / sessions / events / file_changes / diffs /
//  commands / perf_samples / system_perf / risk_events / projects / file_snapshots）
//  每一类都要「经真实写 API 落库 → 经 `ObservatoryService` 读回来 → 逐字段相等」。
//  逐字段展开而不是只比整结构体：整结构体失败时看不出是哪一列丢了，而丢列正是这类
//  编码层最常见的 bug。两者都做：先逐字段，再整体。
//
//  ── 只盯往返最容易丢数的四个地方 ────────────────────────────────────────────
//   1. `UInt64` 存成有符号 `Int`（bit-pattern）：大于 `Int64.max` 的字节数会存成负数，
//      普通 `Int(value)` 转换在这里直接崩。每类带字节的实体都探 `Int64.max + 4096`
//      与 `UInt64.max` 两个越界值。
//   2. JSON 列表列（child_pids / arguments / file_paths / lines / contributions / hot_files）：
//      空字符串、引号、换行、中文、emoji、可选值（`FileHeat.score`）都必须原样回来。
//   3. 可空列的 **nil** 分支：`nil` 不能读回成 0 或空串（那会把「没采到」伪装成「采到 0」）。
//   4. `Date` 的亚秒精度（REAL `timeIntervalSinceReferenceDate`）：`…000.123456` 必须逐位相等。
//
//  ── 语义而非仅编码：upsert 与保留期 ────────────────────────────────────────
//  · upsert 是**全行覆盖**（对齐 `INSERT … ON CONFLICT DO UPDATE`），同 id 二次写入行数不增；
//  · `recordRisks` 的 `isAcknowledged` **单调为真**、会话 `riskEventCount` 是**重算**；
//  · `markRunningSessionsInterrupted(at:)` 只结算 `endedAt == nil` 的行，时间戳取注入值；
//  · `prune(vacuum: true)` 必须抛 `unsupported`——SwiftData 不暴露 VACUUM，静默返回比不做更糟；
//  · `deleteAllData()` 后 11 张表全空。
//
//  ── 环境纪律 ────────────────────────────────────────────────────────────────
//  时间一律来自本文件的固定常量（`Fix`），**不读墙钟**；查询用的「现在」也是注入常量。
//  零等待：`append` 之后直接 `await store.flush()` 再查，不用 `Task.sleep` 等异步事件。
//  优先 `.inMemory`；只有「真的落盘 / 能重开」那一条用文件路径，且目录一律由
//  `AIObservatoryTestSupport.Scratch.directory(_:)` 给出（ci.yml 的 G2 门禁禁止测试
//  写死个人检出目录），`defer` 里删掉整个目录——`-wal` / `-shm` 兄弟文件随之而去。
//

import Testing
import Foundation
import SwiftData
@testable import AIObservatorySwiftDataStore
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 固定夹具

/// 本文件的确定性来源：固定时间基线、稳定 UUID、越界 UInt64。全部与墙钟无关。
private enum Fix {

    /// 全部记录时间的基线（REF 秒，测试与运行时刻无关）。
    static let baseline = Date(timeIntervalSinceReferenceDate: 800_000_000)

    /// 亚秒精度探针：REAL 往返后必须逐位相等。
    static let subSecond = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456)

    /// 注入的「现在」：所有查询下界/结算时间点都用它，不读墙钟。
    static let now = Date(timeIntervalSinceReferenceDate: 800_000_600)

    /// 明显早于 cutoff 的时间点（保留期清理用）。
    static let longAgo = Date(timeIntervalSinceReferenceDate: 800_000_000 - 86_400 * 30)

    // MARK: 越界整数探针

    /// 刚好跨过 `Int64.max`：bit-pattern 存成负 `Int`。
    static let hugeUInt = UInt64(Int64.max) + 4_096

    /// 全 1：bit-pattern 存成 `-1`。
    static let maxUInt = UInt64.max

    /// 有符号上界本身（存成正数，边界另一侧）。
    static let int64MaxAsUInt = UInt64(Int64.max)

    // MARK: 标识

    /// 理论不可达的回退值（避免对 `UUID(uuidString:)` 强解包）。
    static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                      0, 0, 0, 0, 0, 0, 0, 0))

    /// 由下标生成稳定 UUID：`00000007-0000-0000-0000-000000000007`。
    static func uuid(_ index: Int) -> UUID {
        // %X 必须配 UInt32：Swift 的 Int 进 CVarArg 是 64 位，会串位。
        let value = UInt32(truncatingIfNeeded: index)
        let hex = String(format: "%08X-0000-0000-0000-%012X", value, value)
        return UUID(uuidString: hex) ?? zeroUUID
    }

    static func offset(_ seconds: TimeInterval) -> Date { baseline.addingTimeInterval(seconds) }

    // MARK: 字符串探针（引号 / 换行 / 中文 / emoji / 空串）

    /// 一条同时含直引号、书名引号、换行、中文与 emoji 的标题。
    static let messyTitle = "重命名 \"核心\" 「模块」\n第二行 🤖 与 🎯"

    /// JSON 列表里最容易被吞掉的元素：空字符串。
    static let messyList = ["", "含\"引号\"", "路径/中文文件.swift", "🔥 emoji 项", "尾随空格 "]

    // MARK: 装配

    /// 内存库 store（绝大多数用例：零磁盘写入）。
    static func store() async throws -> SwiftDataObservatoryStore {
        try await SwiftDataObservatoryStore.open(configuration: .inMemory)
    }
}

// MARK: - 落盘 scratch

// MARK: - 逐字段断言工具
//
// 每个实体一个 `expectSame`：先逐字段（失败时报得出是哪一列），最后一句整体比较兜底。
// tag 进注释，保证失败信息能定位到「哪个实体的哪个字段、哪一条用例」。

private func expectSame(
    _ restored: AgentInstance, _ original: AgentInstance, tag: String
) {
    let t = "AgentInstance[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.kind == original.kind, "\(t).kind")
    #expect(restored.pid == original.pid, "\(t).pid")
    #expect(restored.parentPID == original.parentPID, "\(t).parentPID")
    #expect(restored.displayName == original.displayName, "\(t).displayName")
    #expect(restored.executablePath == original.executablePath, "\(t).executablePath")
    #expect(restored.workingDirectory == original.workingDirectory, "\(t).workingDirectory")
    #expect(restored.bundleIdentifier == original.bundleIdentifier, "\(t).bundleIdentifier")
    #expect(restored.tty == original.tty, "\(t).tty")
    #expect(restored.startedAt == original.startedAt, "\(t).startedAt")
    #expect(
        restored.startedAt.timeIntervalSinceReferenceDate
            == original.startedAt.timeIntervalSinceReferenceDate,
        "\(t).startedAt 亚秒精度丢失"
    )
    #expect(restored.lastSeenAt == original.lastSeenAt, "\(t).lastSeenAt")
    #expect(restored.state == original.state, "\(t).state")
    #expect(restored.cpuPercent == original.cpuPercent, "\(t).cpuPercent")
    #expect(restored.memoryBytes == original.memoryBytes, "\(t).memoryBytes(UInt64 bit-pattern)")
    #expect(restored.childPIDs == original.childPIDs, "\(t).childPIDs(JSON 列表)")
    #expect(restored.detectedVia == original.detectedVia, "\(t).detectedVia")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: AgentSession, _ original: AgentSession, tag: String
) {
    let t = "AgentSession[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.displayIndex == original.displayIndex, "\(t).displayIndex")
    #expect(restored.kind == original.kind, "\(t).kind")
    #expect(restored.agentID == original.agentID, "\(t).agentID")
    #expect(restored.title == original.title, "\(t).title")
    #expect(restored.projectPath == original.projectPath, "\(t).projectPath")
    #expect(restored.startedAt == original.startedAt, "\(t).startedAt")
    #expect(restored.endedAt == original.endedAt, "\(t).endedAt")
    #expect(
        restored.endedAt?.timeIntervalSinceReferenceDate == original.endedAt?.timeIntervalSinceReferenceDate,
        "\(t).endedAt 亚秒精度丢失"
    )
    #expect(restored.modifiedFileCount == original.modifiedFileCount, "\(t).modifiedFileCount")
    #expect(restored.createdFileCount == original.createdFileCount, "\(t).createdFileCount")
    #expect(restored.deletedFileCount == original.deletedFileCount, "\(t).deletedFileCount")
    #expect(restored.commandCount == original.commandCount, "\(t).commandCount")
    #expect(restored.failedCommandCount == original.failedCommandCount, "\(t).failedCommandCount")
    #expect(restored.cpuSeconds == original.cpuSeconds, "\(t).cpuSeconds")
    #expect(restored.peakCPUPercent == original.peakCPUPercent, "\(t).peakCPUPercent")
    #expect(restored.peakMemoryBytes == original.peakMemoryBytes, "\(t).peakMemoryBytes(UInt64)")
    #expect(restored.estimatedTokens == original.estimatedTokens, "\(t).estimatedTokens")
    // `riskEventCount` 是**派生列**（唯一写入者是那条重算）：调用方传的期望值必须与
    // 「该会话名下铺了几条风险行」一致，否则这里红——那不是回归，是 fixture 不自洽。
    #expect(restored.riskEventCount == original.riskEventCount, "\(t).riskEventCount")
    #expect(restored.outcome == original.outcome, "\(t).outcome")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: TimelineEvent, _ original: TimelineEvent, tag: String
) {
    let t = "TimelineEvent[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.timestamp == original.timestamp, "\(t).timestamp")
    #expect(
        restored.timestamp.timeIntervalSinceReferenceDate
            == original.timestamp.timeIntervalSinceReferenceDate,
        "\(t).timestamp 亚秒精度丢失"
    )
    #expect(restored.sessionID == original.sessionID, "\(t).sessionID")
    #expect(restored.agentID == original.agentID, "\(t).agentID")
    #expect(restored.agentKind == original.agentKind, "\(t).agentKind")
    #expect(restored.kind == original.kind, "\(t).kind")
    #expect(restored.title == original.title, "\(t).title")
    #expect(restored.summary == original.summary, "\(t).summary")
    #expect(restored.filePath == original.filePath, "\(t).filePath")
    #expect(restored.command == original.command, "\(t).command")
    #expect(restored.exitCode == original.exitCode, "\(t).exitCode(Int32)")
    #expect(restored.durationSeconds == original.durationSeconds, "\(t).durationSeconds")
    #expect(restored.cost.cpuSeconds == original.cost.cpuSeconds, "\(t).cost.cpuSeconds")
    #expect(restored.cost.memoryBytes == original.cost.memoryBytes, "\(t).cost.memoryBytes(UInt64)")
    #expect(restored.cost.bytesRead == original.cost.bytesRead, "\(t).cost.bytesRead(UInt64)")
    #expect(restored.cost.bytesWritten == original.cost.bytesWritten, "\(t).cost.bytesWritten(UInt64)")
    #expect(restored.riskLevel == original.riskLevel, "\(t).riskLevel")
    #expect(restored.projectPath == original.projectPath, "\(t).projectPath")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: FileChange, _ original: FileChange, tag: String
) {
    let t = "FileChange[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.path == original.path, "\(t).path")
    #expect(restored.previousPath == original.previousPath, "\(t).previousPath")
    #expect(restored.kind == original.kind, "\(t).kind")
    #expect(restored.timestamp == original.timestamp, "\(t).timestamp")
    #expect(restored.agentID == original.agentID, "\(t).agentID")
    #expect(restored.sessionID == original.sessionID, "\(t).sessionID")
    #expect(restored.agentKind == original.agentKind, "\(t).agentKind")
    #expect(restored.sizeBytes == original.sizeBytes, "\(t).sizeBytes(UInt64)")
    #expect(restored.previousSizeBytes == original.previousSizeBytes, "\(t).previousSizeBytes")
    #expect(restored.isText == original.isText, "\(t).isText")
    #expect(restored.linesAdded == original.linesAdded, "\(t).linesAdded(Int 全域)")
    #expect(restored.linesRemoved == original.linesRemoved, "\(t).linesRemoved")
    #expect(restored.riskLevel == original.riskLevel, "\(t).riskLevel")
    #expect(restored.projectPath == original.projectPath, "\(t).projectPath")
    #expect(restored.fileName == original.fileName, "\(t).fileName(派生)")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: FileDiff, _ original: FileDiff, tag: String
) {
    let t = "FileDiff[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.path == original.path, "\(t).path")
    #expect(restored.previousPath == original.previousPath, "\(t).previousPath")
    #expect(restored.kind == original.kind, "\(t).kind")
    #expect(restored.lines.count == original.lines.count, "\(t).lines.count")
    for (index, line) in original.lines.enumerated() {
        guard restored.lines.indices.contains(index) else { break }
        let back = restored.lines[index]
        #expect(back.id == line.id, "\(t).lines[\(index)].id")
        #expect(back.style == line.style, "\(t).lines[\(index)].style")
        #expect(back.text == line.text, "\(t).lines[\(index)].text")
        #expect(back.oldLineNumber == line.oldLineNumber, "\(t).lines[\(index)].oldLineNumber")
        #expect(back.newLineNumber == line.newLineNumber, "\(t).lines[\(index)].newLineNumber")
    }
    #expect(restored.lines == original.lines, "\(t).lines 逐行整体")
    #expect(restored.linesAdded == original.linesAdded, "\(t).linesAdded")
    #expect(restored.linesRemoved == original.linesRemoved, "\(t).linesRemoved")
    #expect(restored.isBinary == original.isBinary, "\(t).isBinary")
    #expect(restored.isTruncated == original.isTruncated, "\(t).isTruncated")
    #expect(restored.capturedAt == original.capturedAt, "\(t).capturedAt")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: CommandRecord, _ original: CommandRecord, tag: String
) {
    let t = "CommandRecord[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.executable == original.executable, "\(t).executable")
    #expect(restored.arguments == original.arguments, "\(t).arguments(JSON 列表)")
    #expect(restored.arguments.count == original.arguments.count, "\(t).arguments.count")
    #expect(restored.workingDirectory == original.workingDirectory, "\(t).workingDirectory")
    #expect(restored.agentID == original.agentID, "\(t).agentID")
    #expect(restored.sessionID == original.sessionID, "\(t).sessionID")
    #expect(restored.agentKind == original.agentKind, "\(t).agentKind")
    #expect(restored.startedAt == original.startedAt, "\(t).startedAt")
    #expect(restored.endedAt == original.endedAt, "\(t).endedAt")
    #expect(restored.exitCode == original.exitCode, "\(t).exitCode(Int32)")
    #expect(restored.outcome == original.outcome, "\(t).outcome")
    #expect(restored.isDestructive == original.isDestructive, "\(t).isDestructive")
    #expect(restored.requiresConfirmation == original.requiresConfirmation, "\(t).requiresConfirmation")
    #expect(restored.riskLevel == original.riskLevel, "\(t).riskLevel")
    #expect(restored.projectPath == original.projectPath, "\(t).projectPath")
    #expect(restored.commandLine == original.commandLine, "\(t).commandLine(派生)")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: PerformanceSample, _ original: PerformanceSample, tag: String
) {
    let t = "PerformanceSample[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.timestamp == original.timestamp, "\(t).timestamp")
    #expect(restored.sessionID == original.sessionID, "\(t).sessionID")
    #expect(restored.agentID == original.agentID, "\(t).agentID")
    #expect(restored.cpuPercent == original.cpuPercent, "\(t).cpuPercent")
    #expect(restored.memoryBytes == original.memoryBytes, "\(t).memoryBytes(UInt64)")
    #expect(restored.gpuPercent == original.gpuPercent, "\(t).gpuPercent")
    #expect(
        restored.diskReadBytesPerSecond == original.diskReadBytesPerSecond,
        "\(t).diskReadBytesPerSecond"
    )
    #expect(
        restored.diskWriteBytesPerSecond == original.diskWriteBytesPerSecond,
        "\(t).diskWriteBytesPerSecond"
    )
    #expect(restored.networkBytesIn == original.networkBytesIn, "\(t).networkBytesIn(UInt64)")
    #expect(restored.networkBytesOut == original.networkBytesOut, "\(t).networkBytesOut(UInt64)")
    #expect(restored.thermalCelsius == original.thermalCelsius, "\(t).thermalCelsius")
    #expect(restored.powerWatts == original.powerWatts, "\(t).powerWatts")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: SystemPerformanceSample, _ original: SystemPerformanceSample, tag: String
) {
    let t = "SystemPerformanceSample[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.timestamp == original.timestamp, "\(t).timestamp")
    #expect(restored.cpuTotalPercent == original.cpuTotalPercent, "\(t).cpuTotalPercent")
    #expect(restored.cpuSystemPercent == original.cpuSystemPercent, "\(t).cpuSystemPercent")
    #expect(restored.cpuUserPercent == original.cpuUserPercent, "\(t).cpuUserPercent")
    #expect(restored.memoryUsedBytes == original.memoryUsedBytes, "\(t).memoryUsedBytes(UInt64)")
    #expect(restored.memoryTotalBytes == original.memoryTotalBytes, "\(t).memoryTotalBytes(UInt64)")
    #expect(
        restored.diskReadBytesPerSecond == original.diskReadBytesPerSecond,
        "\(t).diskReadBytesPerSecond"
    )
    #expect(
        restored.diskWriteBytesPerSecond == original.diskWriteBytesPerSecond,
        "\(t).diskWriteBytesPerSecond"
    )
    #expect(restored.loadAverage1m == original.loadAverage1m, "\(t).loadAverage1m")
    #expect(restored.thermalCelsius == original.thermalCelsius, "\(t).thermalCelsius")
    #expect(restored.powerWatts == original.powerWatts, "\(t).powerWatts")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: RiskEvent, _ original: RiskEvent, tag: String
) {
    let t = "RiskEvent[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.timestamp == original.timestamp, "\(t).timestamp")
    #expect(restored.level == original.level, "\(t).level")
    #expect(restored.level.rank == original.level.rank, "\(t).level.rank(预计算列跟随)")
    #expect(restored.category == original.category, "\(t).category")
    #expect(restored.title == original.title, "\(t).title")
    #expect(restored.detail == original.detail, "\(t).detail")
    #expect(restored.agentID == original.agentID, "\(t).agentID")
    #expect(restored.agentKind == original.agentKind, "\(t).agentKind")
    #expect(restored.sessionID == original.sessionID, "\(t).sessionID")
    #expect(restored.command == original.command, "\(t).command")
    #expect(restored.filePaths == original.filePaths, "\(t).filePaths(JSON 列表)")
    #expect(restored.requiresConfirmation == original.requiresConfirmation, "\(t).requiresConfirmation")
    #expect(restored.isAcknowledged == original.isAcknowledged, "\(t).isAcknowledged")
    #expect(restored.matchedRuleID == original.matchedRuleID, "\(t).matchedRuleID")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: ProjectActivity, _ original: ProjectActivity, tag: String
) {
    let t = "ProjectActivity[\(tag)]"
    #expect(restored.id == original.id, "\(t).id(String 主键)")
    #expect(restored.name == original.name, "\(t).name")
    #expect(restored.path == original.path, "\(t).path")
    #expect(restored.fileChangeCount == original.fileChangeCount, "\(t).fileChangeCount")
    #expect(restored.commandCount == original.commandCount, "\(t).commandCount")
    #expect(restored.sessionCount == original.sessionCount, "\(t).sessionCount")
    #expect(restored.riskEventCount == original.riskEventCount, "\(t).riskEventCount")
    #expect(restored.codeGrowthLines == original.codeGrowthLines, "\(t).codeGrowthLines")
    #expect(restored.codeShrinkLines == original.codeShrinkLines, "\(t).codeShrinkLines")
    #expect(
        restored.agentContributions.count == original.agentContributions.count,
        "\(t).agentContributions.count"
    )
    for (index, item) in original.agentContributions.enumerated() {
        guard restored.agentContributions.indices.contains(index) else { break }
        let back = restored.agentContributions[index]
        #expect(back.id == item.id, "\(t).agentContributions[\(index)].id")
        #expect(back.kind == item.kind, "\(t).agentContributions[\(index)].kind")
        #expect(back.relativeShare == item.relativeShare, "\(t).agentContributions[\(index)].relativeShare")
        #expect(back.eventCount == item.eventCount, "\(t).agentContributions[\(index)].eventCount")
    }
    #expect(restored.agentContributions == original.agentContributions, "\(t).agentContributions 整体")
    #expect(restored.hotFiles.count == original.hotFiles.count, "\(t).hotFiles.count")
    for (index, item) in original.hotFiles.enumerated() {
        guard restored.hotFiles.indices.contains(index) else { break }
        let back = restored.hotFiles[index]
        #expect(back.id == item.id, "\(t).hotFiles[\(index)].id")
        #expect(back.path == item.path, "\(t).hotFiles[\(index)].path")
        #expect(back.changeCount == item.changeCount, "\(t).hotFiles[\(index)].changeCount")
        #expect(back.linesAdded == item.linesAdded, "\(t).hotFiles[\(index)].linesAdded")
        #expect(back.linesRemoved == item.linesRemoved, "\(t).hotFiles[\(index)].linesRemoved")
        #expect(back.lastTouchedAt == item.lastTouchedAt, "\(t).hotFiles[\(index)].lastTouchedAt")
        #expect(back.score == item.score, "\(t).hotFiles[\(index)].score(可选 Double)")
        #expect(back.fileName == item.fileName, "\(t).hotFiles[\(index)].fileName(派生)")
    }
    #expect(restored.hotFiles == original.hotFiles, "\(t).hotFiles 整体")
    #expect(restored.firstSeenAt == original.firstSeenAt, "\(t).firstSeenAt")
    #expect(restored.lastSeenAt == original.lastSeenAt, "\(t).lastSeenAt")
    #expect(restored == original, "\(t) 整体比较")
}

private func expectSame(
    _ restored: FileSnapshot, _ original: FileSnapshot, tag: String
) {
    let t = "FileSnapshot[\(tag)]"
    #expect(restored.id == original.id, "\(t).id")
    #expect(restored.path == original.path, "\(t).path")
    #expect(restored.contentHash == original.contentHash, "\(t).contentHash")
    #expect(restored.sizeBytes == original.sizeBytes, "\(t).sizeBytes(UInt64 bit-pattern)")
    #expect(restored.capturedAt == original.capturedAt, "\(t).capturedAt")
    #expect(restored.lineCount == original.lineCount, "\(t).lineCount")
    #expect(restored == original, "\(t) 整体比较")
}

// MARK: - 样本构造

/// 一条字段发散度拉满的 Agent：引号/换行/中文/emoji、越界 UInt64、Int32 极值、子进程列表。
private func richAgent(id: UUID, state: AgentRunState) -> AgentInstance {
    AgentInstance(
        id: id,
        kind: .claudeCode,
        pid: Int32.max,
        parentPID: Int32.min,
        displayName: Fix.messyTitle,
        executablePath: FixturePaths.inHome(".local/bin/claude \"code\""),
        workingDirectory: FixturePaths.inProjectRoot("ai-observatory"),
        bundleIdentifier: "com.anthropic.claude-code",
        tty: "/dev/ttys003",
        startedAt: Fix.subSecond,
        lastSeenAt: Fix.now,
        state: state,
        cpuPercent: 37.5,
        memoryBytes: Fix.hugeUInt,
        childPIDs: [1, -2, Int32.min, Int32.max],
        detectedVia: .parentProcessTree
    )
}

/// 一条可选字段全 nil 的 Agent。
private func sparseAgent(id: UUID) -> AgentInstance {
    AgentInstance(
        id: id,
        kind: .unknown,
        pid: -1,
        displayName: "裸进程",
        executablePath: "/bin/sh",
        startedAt: Fix.baseline,
        lastSeenAt: Fix.subSecond,
        state: .idle,
        cpuPercent: -3.75,
        memoryBytes: Fix.maxUInt,
        childPIDs: [],
        detectedVia: .unknown
    )
}

/// 一条字段发散度拉满的会话。
private func richSession(id: UUID) -> AgentSession {
    AgentSession(
        id: id,
        displayIndex: 102,
        kind: .openAICodex,
        agentID: Fix.uuid(1),
        title: Fix.messyTitle,
        projectPath: FixturePaths.inProjectRoot("ai-observatory"),
        startedAt: Fix.subSecond,
        endedAt: Fix.subSecond.addingTimeInterval(900.5),
        modifiedFileCount: 7,
        createdFileCount: 2,
        deletedFileCount: 1,
        commandCount: 12,
        failedCommandCount: 3,
        cpuSeconds: 12.25,
        peakCPUPercent: 87.5,
        peakMemoryBytes: Fix.hugeUInt,
        estimatedTokens: 188_000,
        // 这一列派生自 risk_events（本 fixture 没有给该会话铺风险行）⇒ 只能是 0。
        // 改前这里是 2：那时整行 upsert 会写它，`recordRisks` 的重算随后又被盖回去（#35）。
        riskEventCount: 0,
        outcome: .success
    )
}

/// 一条运行中会话：`endedAt` / `agentID` / `projectPath` 全 nil + Int 极值。
private func openSession(id: UUID) -> AgentSession {
    AgentSession(
        id: id,
        displayIndex: -1,
        kind: .geminiCLI,
        title: "",
        startedAt: Fix.subSecond,
        peakMemoryBytes: Fix.maxUInt,
        estimatedTokens: Int.min,
        outcome: .running
    )
}

/// 一条全字段事件（cost 的三个 UInt64 各自探越界值）。
private func richEvent(id: UUID, sessionID: UUID) -> TimelineEvent {
    TimelineEvent(
        id: id,
        timestamp: Fix.subSecond,
        sessionID: sessionID,
        agentID: Fix.uuid(1),
        agentKind: .cursorAgent,
        kind: .commandExecuted,
        title: Fix.messyTitle,
        summary: "摘要含 \"引号\"、换行\n与 emoji 🎯",
        filePath: FixturePaths.inProjectRoot("中文 路径/文件.swift"),
        command: "rm -rf \"带空格/目录\"",
        exitCode: -1,
        durationSeconds: 0.125,
        cost: ResourceCost(
            cpuSeconds: 2.75,
            memoryBytes: Fix.hugeUInt,
            bytesRead: Fix.maxUInt,
            bytesWritten: Fix.int64MaxAsUInt
        ),
        riskLevel: .critical,
        projectPath: FixturePaths.projectRoot
    )
}

/// 一条可选字段全 nil 的事件（`summary` 为空串）。
private func sparseEvent(id: UUID) -> TimelineEvent {
    TimelineEvent(
        id: id,
        timestamp: Fix.baseline,
        kind: .unknown,
        title: "只有标题",
        cost: .zero
    )
}

/// 一条全字段文件变更（`previousPath` / `previousSizeBytes` 有值，行数为超大/负 Int）。
private func richFileChange(id: UUID, sessionID: UUID) -> FileChange {
    FileChange(
        id: id,
        path: FixturePaths.inProjectRoot("Sources/\"核心\".swift"),
        previousPath: FixturePaths.inProjectRoot("Sources/旧名.swift"),
        kind: .renamed,
        timestamp: Fix.subSecond,
        agentID: Fix.uuid(1),
        sessionID: sessionID,
        agentKind: .aiderCLI,
        sizeBytes: Fix.hugeUInt,
        previousSizeBytes: Fix.maxUInt,
        isText: false,
        linesAdded: 4_294_967_296,
        linesRemoved: -3,
        riskLevel: .high,
        projectPath: FixturePaths.projectRoot
    )
}

/// 一条可选字段全 nil 的文件变更。
private func sparseFileChange(id: UUID) -> FileChange {
    FileChange(
        id: id,
        path: Fix.messyTitle,
        kind: .unknown,
        timestamp: Fix.baseline,
        isText: true,
        riskLevel: .low
    )
}

/// 一条 diff：行数、style 全枚举、行号有 nil。
private func richDiff(id: UUID) -> FileDiff {
    FileDiff(
        id: id,
        path: FixturePaths.inProjectRoot("Sources/文件.swift"),
        previousPath: FixturePaths.inProjectRoot("Sources/旧文件.swift"),
        kind: .modified,
        lines: [
            DiffLine(id: Fix.uuid(201), style: .meta, text: "diff --git a/中文 b/中文 🤖"),
            DiffLine(id: Fix.uuid(202), style: .hunkHeader, text: "@@ -1,3 +1,4 @@"),
            DiffLine(id: Fix.uuid(203), style: .context, text: "let a = \"引号\"", oldLineNumber: 1, newLineNumber: 1),
            DiffLine(id: Fix.uuid(204), style: .removed, text: "- 换行\n仍在", oldLineNumber: 2, newLineNumber: nil),
            DiffLine(id: Fix.uuid(205), style: .added, text: "+新增 🎯", oldLineNumber: nil, newLineNumber: 2),
            DiffLine(id: Fix.uuid(206), style: .context, text: "", oldLineNumber: 0, newLineNumber: 0),
        ],
        linesAdded: 1,
        linesRemoved: 1,
        isBinary: false,
        isTruncated: true,
        capturedAt: Fix.subSecond
    )
}

/// 一条 arguments 含空串/换行/中文/emoji 的命令。
private func richCommand(id: UUID, sessionID: UUID) -> CommandRecord {
    CommandRecord(
        id: id,
        executable: "/bin/zsh",
        arguments: Fix.messyList + ["--message", "含\"引号\"与\n换行"],
        workingDirectory: FixturePaths.projectRoot,
        agentID: Fix.uuid(1),
        sessionID: sessionID,
        agentKind: .windsurf,
        startedAt: Fix.subSecond,
        endedAt: Fix.subSecond.addingTimeInterval(1.5),
        exitCode: Int32.min,
        outcome: .failure,
        isDestructive: true,
        requiresConfirmation: true,
        riskLevel: .critical,
        projectPath: FixturePaths.projectRoot
    )
}

/// 一条仍在运行、可选字段全 nil 的命令。
private func sparseCommand(id: UUID) -> CommandRecord {
    CommandRecord(
        id: id,
        executable: "git",
        arguments: [],
        startedAt: Fix.baseline,
        outcome: .running
    )
}

/// 一条会话性能采样（三个 UInt64 各自探越界值 + 一个可选有值）。
private func richSample(id: UUID, sessionID: UUID, at date: Date) -> PerformanceSample {
    PerformanceSample(
        id: id,
        timestamp: date,
        sessionID: sessionID,
        agentID: Fix.uuid(1),
        cpuPercent: Double.pi,
        memoryBytes: Fix.hugeUInt,
        gpuPercent: 42.5,
        diskReadBytesPerSecond: 1_000_000_000_000.5,
        diskWriteBytesPerSecond: 0,
        networkBytesIn: Fix.maxUInt,
        networkBytesOut: Fix.int64MaxAsUInt,
        thermalCelsius: -273.15,
        powerWatts: 15.25
    )
}

/// 一条会话性能采样：可选字段全 nil。
private func sparseSample(id: UUID, sessionID: UUID?) -> PerformanceSample {
    PerformanceSample(
        id: id,
        timestamp: Fix.subSecond,
        sessionID: sessionID,
        cpuPercent: 0,
        memoryBytes: Fix.maxUInt,
        diskReadBytesPerSecond: -1.5,
        networkBytesIn: 0,
        networkBytesOut: Fix.hugeUInt
    )
}

/// 一条整机采样（memoryUsedBytes / memoryTotalBytes 越界 + 可选有值）。
private func richSystemSample(id: UUID, at date: Date) -> SystemPerformanceSample {
    SystemPerformanceSample(
        id: id,
        timestamp: date,
        cpuTotalPercent: 12.5,
        cpuSystemPercent: 3.25,
        cpuUserPercent: 9.25,
        memoryUsedBytes: Fix.hugeUInt,
        memoryTotalBytes: Fix.int64MaxAsUInt,
        diskReadBytesPerSecond: 2_048.5,
        diskWriteBytesPerSecond: 4_096.25,
        loadAverage1m: 3.5,
        thermalCelsius: 55.5,
        powerWatts: 27.75
    )
}

/// 一条整机采样：可选字段全 nil。
private func sparseSystemSample(id: UUID) -> SystemPerformanceSample {
    SystemPerformanceSample(
        id: id,
        timestamp: Fix.baseline,
        memoryUsedBytes: Fix.maxUInt,
        memoryTotalBytes: 0
    )
}

/// 一条风险事件（每个 level 配不同 category / 可选字段轮换 nil）。
private func riskAt(_ level: RiskLevel, index: Int, sessionID: UUID?) -> RiskEvent {
    RiskEvent(
        id: Fix.uuid(300 + index),
        timestamp: Fix.subSecond.addingTimeInterval(TimeInterval(index)),
        level: level,
        category: RiskCategory.allCases[index % RiskCategory.allCases.count],
        title: "风险 \(level.displayName) 🤖",
        detail: Fix.messyTitle,
        agentID: index.isMultiple(of: 2) ? Fix.uuid(1) : nil,
        agentKind: .claudeCode,
        sessionID: sessionID,
        command: index.isMultiple(of: 3) ? nil : "rm -rf \"目录\"",
        filePaths: index.isMultiple(of: 2) ? Fix.messyList : [],
        requiresConfirmation: index.isMultiple(of: 2),
        isAcknowledged: false,
        matchedRuleID: index.isMultiple(of: 2) ? "rule-\(level.rawValue)" : nil
    )
}

/// 一条含 agentContributions / hotFiles 的项目地图。
private func richProject() -> ProjectActivity {
    ProjectActivity(
        id: FixturePaths.inProjectRoot("ai-observatory"),
        name: "AI 观测台 \"主仓\" 🎯",
        path: FixturePaths.inProjectRoot("ai-observatory"),
        fileChangeCount: 42,
        commandCount: 17,
        sessionCount: 5,
        riskEventCount: 3,
        codeGrowthLines: 1_200,
        codeShrinkLines: -340,
        agentContributions: [
            AgentContribution(id: Fix.uuid(401), kind: .claudeCode, relativeShare: 0.75, eventCount: 30),
            AgentContribution(id: Fix.uuid(402), kind: .openAICodex, relativeShare: 0.25, eventCount: 12),
            AgentContribution(id: Fix.uuid(403), kind: .unknown, relativeShare: 0, eventCount: 0),
        ],
        hotFiles: [
            FileHeat(
                id: Fix.uuid(411), path: "/Sources/\"核心\".swift", changeCount: 9,
                linesAdded: 120, linesRemoved: 30, lastTouchedAt: Fix.subSecond, score: 0.9375
            ),
            FileHeat(
                id: Fix.uuid(412), path: "/Sources/中文 路径/文件.swift", changeCount: 4,
                linesAdded: 0, linesRemoved: 0, lastTouchedAt: Fix.baseline, score: nil
            ),
            FileHeat(id: Fix.uuid(413), path: "", changeCount: 0, lastTouchedAt: Fix.now, score: 1),
        ],
        firstSeenAt: Fix.subSecond,
        lastSeenAt: Fix.now
    )
}

/// 一条列表全空的项目（JSON 列表列的 nil/空数组分支）。
private func sparseProject() -> ProjectActivity {
    ProjectActivity(
        id: FixturePaths.inHome("Empty"),
        name: "空项目",
        path: FixturePaths.inHome("Empty"),
        firstSeenAt: Fix.baseline,
        lastSeenAt: Fix.baseline
    )
}

/// 一条快照（sizeBytes 越过 `Int64.max`）。
private func richSnapshot(id: UUID) -> FileSnapshot {
    FileSnapshot(
        id: id,
        path: FixturePaths.inProjectRoot("中文/文件 🎯.swift"),
        contentHash: "sha256:\"abc\ndef\"",
        sizeBytes: Fix.hugeUInt,
        capturedAt: Fix.subSecond,
        lineCount: 1_234
    )
}

// MARK: - Suite 1：Agent 与会话

@Suite("SwiftData 往返：Agent 与会话", .timeLimit(.minutes(1)))
struct SwiftDataAgentSessionRoundTripTests {

    /// `activeAgents()` 只收 running / idle —— terminated 的行必须**不出现**在活跃集里，
    /// 但它确实落库（`rowCount` 为 3），后续 upsert 覆盖时的字段解码由第 2 条钉住。
    @Test("1. AgentInstance：running/idle 全字段往返，terminated 不入活跃集")
    func agentActiveStates() async throws {
        let store = try await Fix.store()
        let running = richAgent(id: Fix.uuid(1), state: .running)
        let idle = AgentInstance(
            id: Fix.uuid(2), kind: .genericCLIAgent, pid: 4242, displayName: "终端 Agent",
            executablePath: "/usr/bin/env", startedAt: Fix.baseline, lastSeenAt: Fix.subSecond,
            state: .idle, cpuPercent: 0, memoryBytes: Fix.int64MaxAsUInt, childPIDs: [],
            detectedVia: .argumentSignature
        )
        let terminated = AgentInstance(
            id: Fix.uuid(3), kind: .unknown, pid: 99, displayName: "已退出",
            executablePath: "/bin/true", startedAt: Fix.baseline, lastSeenAt: Fix.baseline,
            state: .terminated, memoryBytes: Fix.maxUInt, childPIDs: [7], detectedVia: .unknown
        )
        try await store.upsertAgents([running, idle, terminated])

        let active = try await store.activeAgents()
        #expect(active.count == 2, "活跃集应只剩 running + idle")
        #expect(active.contains(where: { $0.id == terminated.id }) == false, "terminated 不得出现在活跃集")

        let restoredRunning = try #require(active.first { $0.id == running.id })
        expectSame(restoredRunning, running, tag: "running")
        let restoredIdle = try #require(active.first { $0.id == idle.id })
        expectSame(restoredIdle, idle, tag: "idle")

        let rows = try await store.rowCount(table: "agents")
        #expect(rows == 3, "terminated 那一行确实落库")
    }

    @Test("2. AgentInstance：UInt64 越过 Int64.max、Int32 极值与全 nil 字段")
    func agentBoundaryValues() async throws {
        let store = try await Fix.store()
        let rich = richAgent(id: Fix.uuid(4), state: .running)
        let sparse = sparseAgent(id: Fix.uuid(5))
        try await store.upsertAgents([rich, sparse])

        let active = try await store.activeAgents()
        let restoredRich = try #require(active.first { $0.id == rich.id })
        // 越界探针逐条钉住（bit-pattern 一旦写成 Int() 就会崩或返回 nil 行）。
        #expect(restoredRich.memoryBytes == Fix.hugeUInt, "memoryBytes 必须逐位等于 Int64.max+4096")
        #expect(restoredRich.pid == Int32.max, "pid(Int32.max)")
        #expect(restoredRich.parentPID == Int32.min, "parentPID(Int32.min)")
        expectSame(restoredRich, rich, tag: "rich")

        let restoredSparse = try #require(active.first { $0.id == sparse.id })
        #expect(restoredSparse.parentPID == nil, "parentPID 的 nil 不得变成 0")
        #expect(restoredSparse.workingDirectory == nil, "workingDirectory 的 nil 不得变成空串")
        #expect(restoredSparse.bundleIdentifier == nil, "bundleIdentifier 的 nil 不得变成空串")
        #expect(restoredSparse.tty == nil, "tty 的 nil 不得变成空串")
        #expect(restoredSparse.childPIDs.isEmpty, "空 JSON 列表读回应为空数组")
        #expect(restoredSparse.memoryBytes == Fix.maxUInt, "memoryBytes(UInt64.max)")
        #expect(restoredSparse.pid == -1, "负 pid 保号")
        #expect(restoredSparse.cpuPercent == -3.75, "负 cpuPercent 保号")
        expectSame(restoredSparse, sparse, tag: "sparse")
    }

    @Test("3. AgentSession：sessions(matching:) 与 session(id:) 两路读回一致")
    func sessionRichRoundTrip() async throws {
        let store = try await Fix.store()
        let session = richSession(id: Fix.uuid(10))
        try await store.upsertSessions([session])

        let page = try await store.sessions(matching: SessionQuery(limit: 50))
        let items = page.items
        #expect(page.totalCount == 1)
        #expect(page.offset == 0)
        let restored = try #require(items.first)
        #expect(restored.peakMemoryBytes == Fix.hugeUInt, "peakMemoryBytes 越界值逐位相等")
        #expect(restored.title == Fix.messyTitle, "引号/换行/中文/emoji 全须原样")
        expectSame(restored, session, tag: "rich")

        let byID = try await store.session(id: session.id)
        let sameByID = try #require(byID)
        expectSame(sameByID, session, tag: "byID")
    }

    @Test("4. AgentSession：endedAt/agentID/projectPath 全 nil + Int 极值往返")
    func sessionNilAndExtremes() async throws {
        let store = try await Fix.store()
        let open = openSession(id: Fix.uuid(11))
        try await store.upsertSessions([open])

        let fetched = try await store.session(id: open.id)
        let restored = try #require(fetched)
        #expect(restored.endedAt == nil, "endedAt 的 nil 不得变成任何日期")
        #expect(restored.isActive, "派生属性 isActive 随 endedAt == nil")
        #expect(restored.agentID == nil, "agentID 的 nil 不得变成全零 UUID")
        #expect(restored.projectPath == nil, "projectPath 的 nil 不得变成空串")
        #expect(restored.title == "", "空标题应还是空标题")
        #expect(restored.displayIndex == -1, "负 displayIndex 保号")
        #expect(restored.estimatedTokens == Int.min, "Int.min 逐位相等")
        #expect(restored.peakMemoryBytes == Fix.maxUInt, "peakMemoryBytes(UInt64.max)")
        expectSame(restored, open, tag: "open")

        // 注入时间做下界的区间查询：闭区间含 start，因此这一行必须命中。
        let page = try await store.sessions(matching: SessionQuery(
            dateRange: DateRangeFilter(start: Fix.subSecond, end: Fix.now), limit: 10
        ))
        #expect(page.items.map(\.id) == [open.id], "startedAt == start 应被闭区间包含")
    }

    @Test("5. upsert：同 id 二次写入为全行覆盖且行数不增（agents / sessions）")
    func upsertOverwritesWholeRow() async throws {
        let store = try await Fix.store()
        let first = richSession(id: Fix.uuid(12))
        let second = AgentSession(
            id: first.id, displayIndex: 999, kind: .vscodeCopilot, title: "第二次写入",
            startedAt: Fix.baseline, endedAt: Fix.now, modifiedFileCount: 1,
            peakMemoryBytes: Fix.maxUInt, riskEventCount: 7, outcome: .failed   // 携带 7，但落不进那一列
        )
        try await store.upsertSessions([first])
        try await store.upsertSessions([second])

        let overwritten = try await store.session(id: first.id)
        let restored = try #require(overwritten)
        // `second` 携带 riskEventCount = 7，但那一列派生自 risk_events（本用例没铺风险行）⇒
        // 期望值是 0。留着 7 才有意义：它证明「调用方带的数字」确实落不进去（#35 的写法）。
        var expected = second
        expected.riskEventCount = 0
        expectSame(restored, expected, tag: "覆盖后")
        #expect(restored.title != first.title, "旧值不得残留")
        #expect(restored.kind == .vscodeCopilot, "kind 必须整体换掉")
        #expect(restored.riskEventCount == 0,
                "全行覆盖覆盖不到 risk_event_count：它只有一个写入者（派生重算），见 ObservatoryStore.upsertSessions")
        let sessionRows = try await store.rowCount(table: "sessions")
        #expect(sessionRows == 1, "upsert 不得增行")

        let agentFirst = richAgent(id: Fix.uuid(13), state: .running)
        let agentSecond = AgentInstance(
            id: agentFirst.id, kind: .aiderCLI, pid: 7, parentPID: 8, displayName: "Aider",
            executablePath: "/usr/local/bin/aider", startedAt: Fix.baseline, lastSeenAt: Fix.now,
            state: .idle, cpuPercent: 1.5, memoryBytes: Fix.int64MaxAsUInt, childPIDs: [9],
            detectedVia: .bundleIdentifier
        )
        try await store.upsertAgents([agentFirst])
        try await store.upsertAgents([agentSecond])
        let activeAgents = try await store.activeAgents()
        let restoredAgent = try #require(activeAgents.first { $0.id == agentFirst.id })
        expectSame(restoredAgent, agentSecond, tag: "agent 覆盖后")
        let agentRows = try await store.rowCount(table: "agents")
        #expect(agentRows == 1, "upsert 不得增行")
    }
}

// MARK: - Suite 2：时间线与文件

@Suite("SwiftData 往返：时间线与文件", .timeLimit(.minutes(1)))
struct SwiftDataTimelineFileRoundTripTests {

    @Test("6. TimelineEvent：append + flush → events(matching:) 全字段往返")
    func eventRichRoundTrip() async throws {
        let store = try await Fix.store()
        let sessionID = Fix.uuid(20)
        let event = richEvent(id: Fix.uuid(21), sessionID: sessionID)
        await store.append(event)
        await store.flush()

        let page = try await store.events(matching: EventQuery(limit: 50))
        let restored = try #require(page.items.first { $0.id == event.id })
        #expect(page.totalCount == 1)
        #expect(restored.timestamp == Fix.subSecond, "亚秒时间戳逐位相等")
        #expect(restored.cost.memoryBytes == Fix.hugeUInt, "cost.memoryBytes 越界")
        #expect(restored.cost.bytesRead == Fix.maxUInt, "cost.bytesRead 越界")
        #expect(restored.cost.bytesWritten == Fix.int64MaxAsUInt, "cost.bytesWritten 上界")
        #expect(restored.exitCode == -1, "负 exitCode 保号")
        expectSame(restored, event, tag: "rich")

        let stats = await store.batchStats()
        #expect(stats.pendingCount == 0, "flush 后缓冲应为空")
        #expect(stats.totalSubmitted == 1)
        #expect(stats.commitCount >= 1)
        #expect(stats.droppedStatementCount == 0, "有行写不进去时必须显式暴露")
    }

    @Test("7. TimelineEvent：可选字段全 nil 与默认空摘要")
    func eventNilRoundTrip() async throws {
        let store = try await Fix.store()
        let event = sparseEvent(id: Fix.uuid(22))
        await store.append(event)
        await store.flush()

        let page = try await store.events(matching: EventQuery.all)
        let restored = try #require(page.items.first { $0.id == event.id })
        #expect(restored.sessionID == nil, "sessionID 的 nil 不得变成空串派生的假 UUID")
        #expect(restored.agentID == nil)
        #expect(restored.filePath == nil, "filePath 的 nil 不得变成空串")
        #expect(restored.command == nil, "command 的 nil 不得变成空串")
        #expect(restored.exitCode == nil, "exitCode 的 nil 不得变成 0")
        #expect(restored.durationSeconds == nil, "durationSeconds 的 nil 不得变成 0")
        #expect(restored.summary == "", "空摘要保持空")
        #expect(restored.projectPath == nil)
        #expect(restored.agentKind == .unknown, "枚举默认值 rawValue 往返")
        #expect(restored.cost == .zero, "ResourceCost.zero 的四个 UInt64 全 0")
        expectSame(restored, event, tag: "sparse")
    }

    /// `risk_rank` 是预计算列（`#Predicate` 调不到 Swift 计算属性），它必须跟着 `riskLevel` 走，
    /// 否则 `minimumRisk` 过滤在两个后端上筛出不同的行。
    @Test("8. TimelineEvent：四个 RiskLevel 各一条，riskRank 预计算列跟着对")
    func eventRiskRankPrecomputed() async throws {
        let store = try await Fix.store()
        var written: [RiskLevel: TimelineEvent] = [:]
        for (index, level) in RiskLevel.allCases.enumerated() {
            let event = TimelineEvent(
                id: Fix.uuid(30 + index),
                timestamp: Fix.subSecond.addingTimeInterval(TimeInterval(index)),
                agentKind: .claudeCode,
                kind: .fileModified,
                title: "等级 \(level.displayName)",
                riskLevel: level
            )
            written[level] = event
            await store.append(event)
        }
        await store.flush()

        let all = try await store.events(matching: EventQuery(limit: 10))
        #expect(all.totalCount == 4)
        for level in RiskLevel.allCases {
            let original = try #require(written[level])
            let restored = try #require(all.items.first { $0.id == original.id })
            #expect(restored.riskLevel == level, "riskLevel 原样回来：\(level.rawValue)")
            expectSame(restored, original, tag: "level \(level.rawValue)")
        }

        let high = try #require(written[.high])
        let critical = try #require(written[.critical])
        let highOrCritical = try await store.events(matching: EventQuery(minimumRisk: .high, limit: 10))
        let expectedIDs: Set<UUID> = [high.id, critical.id]
        #expect(Set(highOrCritical.items.map(\.id)) == expectedIDs, "minimumRisk 必须走 risk_rank 预计算列")
        let mediumUp = try await store.events(matching: EventQuery(minimumRisk: .medium, limit: 10))
        #expect(mediumUp.totalCount == 3, "rank>=1 命中 medium/high/critical 三行")
        let noneAbove = try await store.events(matching: EventQuery(minimumRisk: .critical, limit: 10))
        #expect(noneAbove.items.map(\.riskLevel) == [.critical])
        #expect(noneAbove.items.map(\.id) == [critical.id])
        #expect(highOrCritical.items.contains { $0.id == high.id })
    }

    @Test("9. FileChange：全字段与全 nil 两条一次往返")
    func fileChangeRoundTrip() async throws {
        let store = try await Fix.store()
        let sessionID = Fix.uuid(40)
        let rich = richFileChange(id: Fix.uuid(41), sessionID: sessionID)
        let sparse = sparseFileChange(id: Fix.uuid(42))
        await store.append(rich)
        await store.append(sparse)
        await store.flush()

        let page = try await store.fileChanges(matching: FileChangeQuery(limit: 50))
        #expect(page.totalCount == 2)
        let restoredRich = try #require(page.items.first { $0.id == rich.id })
        #expect(restoredRich.sizeBytes == Fix.hugeUInt, "sizeBytes 越界值逐位相等")
        #expect(restoredRich.previousSizeBytes == Fix.maxUInt, "previousSizeBytes 越界值逐位相等")
        #expect(restoredRich.linesAdded == 4_294_967_296, "Int 必须存满 64 位，不得被截成 Int32")
        #expect(restoredRich.linesRemoved == -3, "负 linesRemoved 保号")
        expectSame(restoredRich, rich, tag: "rich")

        let restoredSparse = try #require(page.items.first { $0.id == sparse.id })
        #expect(restoredSparse.previousPath == nil, "previousPath 的 nil 不得变成空串")
        #expect(restoredSparse.previousSizeBytes == nil, "previousSizeBytes 的 nil 不得变成 0")
        #expect(restoredSparse.agentID == nil)
        #expect(restoredSparse.sessionID == nil)
        #expect(restoredSparse.projectPath == nil)
        #expect(restoredSparse.isText, "isText = true 不得退化成 0")
        #expect(restoredSparse.sizeBytes == 0)
        expectSame(restoredSparse, sparse, tag: "sparse")

        // pathPrefix / kind 集合过滤顺带证明 path 列（含引号与 emoji）逐字落库。
        let scoped = try await store.fileChanges(matching: FileChangeQuery(
            kinds: [.renamed], pathPrefix: FixturePaths.projectRoot, limit: 10
        ))
        #expect(scoped.items.map(\.id) == [rich.id])
    }

    @Test("10. FileDiff：record(_:forChangeID:) → fileDiff(for:) 逐行相等")
    func diffRoundTrip() async throws {
        let store = try await Fix.store()
        let changeID = Fix.uuid(50)
        let diff = richDiff(id: changeID)
        try await store.record(diff, forChangeID: changeID)

        let fetchedDiff = try await store.fileDiff(for: changeID)
        let restored = try #require(fetchedDiff)
        #expect(restored.lines.count == 6, "lines(JSON) 六行须全回来")
        #expect(restored.lines.map(\.style) == diff.lines.map(\.style), "五种 Style 逐个往返")
        #expect(restored.lines.map(\.text) == diff.lines.map(\.text), "含空串行与换行的文本逐字相等")
        #expect(restored.lines.map(\.oldLineNumber) == diff.lines.map(\.oldLineNumber), "行号 nil 与 0 要分得开")
        #expect(restored.lines.map(\.newLineNumber) == diff.lines.map(\.newLineNumber))
        #expect(restored.lines[0].id == diff.lines[0].id, "每行的 DiffLine.id 也在 JSON 里")
        expectSame(restored, diff, tag: "rich")

        let missing = try await store.fileDiff(for: Fix.uuid(59))
        #expect(missing == nil, "没有 diff 的 changeID 必须返回 nil 而非伪造空 diff")
        let rows = try await store.rowCount(table: "diffs")
        #expect(rows == 1)
    }

    @Test("11. FileDiff：同 changeID 重复 record 为覆盖，diffs 表不增行")
    func diffOverwrite() async throws {
        let store = try await Fix.store()
        let changeID = Fix.uuid(51)
        let first = richDiff(id: changeID)
        let second = FileDiff(
            id: changeID, path: FixturePaths.inProjectRoot("second.swift"), previousPath: nil, kind: .created,
            lines: [DiffLine(id: Fix.uuid(52), style: .added, text: "+只有一行 🎯", newLineNumber: 1)],
            linesAdded: 1, linesRemoved: 0, isBinary: true, isTruncated: false,
            capturedAt: Fix.baseline
        )
        try await store.record(first, forChangeID: changeID)
        try await store.record(second, forChangeID: changeID)

        let fetchedDiff = try await store.fileDiff(for: changeID)
        let restored = try #require(fetchedDiff)
        expectSame(restored, second, tag: "覆盖后")
        #expect(restored.lines.count == 1, "旧 lines 不得残留")
        #expect(restored.isBinary, "isBinary 由 false 变 true")
        #expect(restored.previousPath == nil, "覆盖后旧 previousPath 必须消失")
        let rows = try await store.rowCount(table: "diffs")
        #expect(rows == 1, "覆盖式 record 不得增行")
    }
}

// MARK: - Suite 3：命令与性能

@Suite("SwiftData 往返：命令与性能", .timeLimit(.minutes(1)))
struct SwiftDataCommandPerformanceRoundTripTests {

    @Test("12. CommandRecord：arguments 含空串/换行/中文/emoji 逐元素相等")
    func commandRichRoundTrip() async throws {
        let store = try await Fix.store()
        let sessionID = Fix.uuid(60)
        let record = richCommand(id: Fix.uuid(61), sessionID: sessionID)
        await store.append(record)
        await store.flush()

        let page = try await store.commands(matching: CommandQuery(limit: 50))
        let restored = try #require(page.items.first { $0.id == record.id })
        #expect(restored.arguments.count == record.arguments.count, "JSON 列表元素数不得缩水")
        #expect(restored.arguments.first == "", "空字符串元素必须活着回来（最易被丢）")
        #expect(restored.arguments == record.arguments, "arguments 逐元素逐字相等")
        #expect(restored.exitCode == Int32.min, "exitCode(Int32.min)")
        #expect(restored.isDestructive && restored.requiresConfirmation, "两个 Bool 探针")
        expectSame(restored, record, tag: "rich")

        let destructive = try await store.commands(matching: CommandQuery(destructiveOnly: true, limit: 10))
        #expect(destructive.items.map(\.id) == [record.id])
    }

    @Test("13. CommandRecord：可选字段全 nil + 空 arguments + running 态")
    func commandNilRoundTrip() async throws {
        let store = try await Fix.store()
        let record = sparseCommand(id: Fix.uuid(62))
        await store.append(record)
        await store.flush()

        let commands = try await store.commands(matching: CommandQuery.all)
        let restored = try #require(commands.items.first { $0.id == record.id })
        #expect(restored.workingDirectory == nil)
        #expect(restored.agentID == nil)
        #expect(restored.sessionID == nil)
        #expect(restored.endedAt == nil, "running 命令的 endedAt 不得被编成日期")
        #expect(restored.exitCode == nil, "没退出码 ≠ 退出码 0")
        #expect(restored.duration == nil, "派生 duration 随 endedAt == nil")
        #expect(restored.arguments.isEmpty, "空 arguments 读回应为空数组")
        #expect(restored.agentKind == .unknown)
        #expect(restored.riskLevel == .low)
        expectSame(restored, record, tag: "sparse")
    }

    @Test("14. PerformanceSample：三个 UInt64 越界与 Double 极值往返")
    func performanceRichRoundTrip() async throws {
        let store = try await Fix.store()
        let sessionID = Fix.uuid(70)
        let sample = richSample(id: Fix.uuid(71), sessionID: sessionID, at: Fix.subSecond)
        await store.append(sample)
        await store.flush()

        let samples = try await store.performanceSamples(sessionID: sessionID)
        let restored = try #require(samples.first { $0.id == sample.id })
        #expect(restored.memoryBytes == Fix.hugeUInt, "memoryBytes 越界")
        #expect(restored.networkBytesIn == Fix.maxUInt, "networkBytesIn(UInt64.max) → Int(-1) → 回来")
        #expect(restored.networkBytesOut == Fix.int64MaxAsUInt, "networkBytesOut 上界另一侧")
        #expect(restored.cpuPercent == Double.pi, "无理数 Double 逐位相等")
        #expect(restored.diskReadBytesPerSecond == 1_000_000_000_000.5, "大数量级带 .5 逐位相等")
        #expect(restored.thermalCelsius == -273.15, "负温度保号")
        expectSame(restored, sample, tag: "rich")
    }

    /// `session_id` 为 nil 的行永不匹配某个具体会话（与 SQLite 侧 `WHERE session_id = ?` 同语义）；
    /// 若把 nil 编成空串就会被误命中，这条把差异钉住。
    @Test("15. PerformanceSample：可选全 nil 与 sessionID 为 nil 的行不被任何会话命中")
    func performanceNilRoundTrip() async throws {
        let store = try await Fix.store()
        let sessionID = Fix.uuid(72)
        let mine = sparseSample(id: Fix.uuid(73), sessionID: sessionID)
        let orphan = sparseSample(id: Fix.uuid(74), sessionID: nil)
        await store.append(mine)
        await store.append(orphan)
        await store.flush()

        let restoredList = try await store.performanceSamples(sessionID: sessionID)
        #expect(restoredList.map(\.id) == [mine.id], "sessionID 为 nil 的行不得串进具体会话")
        let restored = try #require(restoredList.first)
        #expect(restored.agentID == nil)
        #expect(restored.gpuPercent == nil, "gpuPercent 的 nil 不得变成 0")
        #expect(restored.thermalCelsius == nil)
        #expect(restored.powerWatts == nil)
        #expect(restored.memoryBytes == Fix.maxUInt)
        #expect(restored.networkBytesOut == Fix.hugeUInt)
        #expect(restored.diskReadBytesPerSecond == -1.5, "负数保号")
        expectSame(restored, mine, tag: "sparse")

        let empty = try await store.performanceSamples(sessionID: Fix.uuid(75))
        #expect(empty.isEmpty)
        let rows = try await store.rowCount(table: "perf_samples")
        #expect(rows == 2, "两条都确实落库，只是有一条不可按会话命中")
    }

    @Test("16. SystemPerformanceSample：全字段往返 + since 下界（注入常量）")
    func systemPerformanceRoundTrip() async throws {
        let store = try await Fix.store()
        let rich = richSystemSample(id: Fix.uuid(80), at: Fix.subSecond)
        let sparse = sparseSystemSample(id: Fix.uuid(81))
        let late = richSystemSample(id: Fix.uuid(82), at: Fix.now)
        for sample in [rich, sparse, late] { await store.append(sample) }
        await store.flush()

        let sinceBaseline = try await store.systemPerformance(since: Fix.baseline)
        #expect(sinceBaseline.count == 3)
        let restoredRich = try #require(sinceBaseline.first { $0.id == rich.id })
        #expect(restoredRich.memoryUsedBytes == Fix.hugeUInt, "memoryUsedBytes 越界")
        #expect(restoredRich.memoryTotalBytes == Fix.int64MaxAsUInt)
        #expect(restoredRich.memoryUsageRatio == rich.memoryUsageRatio, "派生比例随原始 UInt64 一致")
        expectSame(restoredRich, rich, tag: "rich")

        let restoredSparse = try #require(sinceBaseline.first { $0.id == sparse.id })
        #expect(restoredSparse.thermalCelsius == nil, "thermalCelsius 的 nil 不得变成 0")
        #expect(restoredSparse.powerWatts == nil, "powerWatts 的 nil 不得变成 0")
        #expect(restoredSparse.memoryUsageRatio == 0, "memoryTotalBytes = 0 时派生比率为 0（不崩）")
        expectSame(restoredSparse, sparse, tag: "sparse")

        // 下界为注入常量：`since == timestamp` 应命中（闭下界）。
        let sinceNow = try await store.systemPerformance(since: Fix.now)
        #expect(sinceNow.map(\.id) == [late.id], "since 是闭下界")
        let noneAfter = try await store.systemPerformance(since: Fix.now.addingTimeInterval(1))
        #expect(noneAfter.isEmpty)
        let rows = try await store.rowCount(table: "system_perf")
        #expect(rows == 3)
    }
}

// MARK: - Suite 4：风险与项目

@Suite("SwiftData 往返：风险与项目", .timeLimit(.minutes(1)))
struct SwiftDataRiskProjectRoundTripTests {

    @Test("17. RiskEvent：四个 RiskLevel 各一条，全字段往返")
    func riskAllLevels() async throws {
        let store = try await Fix.store()
        var originals: [RiskEvent] = []
        for (index, level) in RiskLevel.allCases.enumerated() {
            originals.append(riskAt(level, index: index, sessionID: nil))
        }
        try await store.recordRisks(originals)

        let page = try await store.riskEvents(matching: RiskQuery(limit: 50))
        #expect(page.totalCount == 4)
        for original in originals {
            let restored = try #require(page.items.first { $0.id == original.id })
            #expect(restored.level.rank == original.level.rank, "levelRank 预计算列随 level")
            expectSame(restored, original, tag: "level \(original.level.rawValue)")
        }

        let criticalOnly = try await store.riskEvents(matching: RiskQuery(levels: [.critical], limit: 10))
        #expect(criticalOnly.items.count == 1)
        #expect(criticalOnly.items.first?.level == .critical)
        let byCategory = try await store.riskEvents(matching: RiskQuery(
            categories: Set(originals.map(\.category)), limit: 10
        ))
        #expect(byCategory.totalCount == 4)
    }

    @Test("18. RiskEvent：filePaths 含空串/引号/emoji，command 与 matchedRuleID 为 nil")
    func riskListAndNils() async throws {
        let store = try await Fix.store()
        let withList = RiskEvent(
            id: Fix.uuid(310), timestamp: Fix.subSecond, level: .high, category: .credentialExposure,
            title: "读取 \"凭据\" 🤖", detail: Fix.messyTitle, agentKind: .claudeCode,
            command: "cat ~/.ssh/id_rsa", filePaths: Fix.messyList,
            requiresConfirmation: true, isAcknowledged: true, matchedRuleID: "rule.credential"
        )
        let emptyList = RiskEvent(
            id: Fix.uuid(311), timestamp: Fix.baseline, level: .low, category: .unknown,
            title: "无附件风险", agentKind: .unknown, filePaths: [], matchedRuleID: nil
        )
        try await store.recordRisks([withList, emptyList])

        let page = try await store.riskEvents(matching: RiskQuery.all)
        let restoredList = try #require(page.items.first { $0.id == withList.id })
        #expect(restoredList.filePaths.count == withList.filePaths.count, "列表元素数不得缩水")
        #expect(restoredList.filePaths.first == "", "空字符串元素必须保留")
        #expect(restoredList.filePaths == withList.filePaths, "filePaths 逐元素逐字相等")
        #expect(restoredList.isAcknowledged, "写入时已确认 → 读回仍已确认")
        expectSame(restoredList, withList, tag: "含列表")

        let restoredEmpty = try #require(page.items.first { $0.id == emptyList.id })
        #expect(restoredEmpty.filePaths.isEmpty, "空列表读回为空数组而不是 nil 崩溃")
        #expect(restoredEmpty.command == nil, "command 的 nil 不得变成空串")
        #expect(restoredEmpty.agentID == nil)
        #expect(restoredEmpty.sessionID == nil)
        #expect(restoredEmpty.matchedRuleID == nil, "matchedRuleID 的 nil 不得变成空串")
        #expect(restoredEmpty.detail == "", "detail 默认空串")
        #expect(restoredEmpty.requiresConfirmation == false)
        #expect(restoredEmpty.isAcknowledged == false)
        expectSame(restoredEmpty, emptyList, tag: "空列表")
    }

    /// 已确认的风险被再次采集命中时不得退回未确认——否则用户以为冒出了新风险。
    @Test("19. recordRisks：isAcknowledged 单调为真")
    func riskAcknowledgedMonotonic() async throws {
        let store = try await Fix.store()
        let id = Fix.uuid(320)
        let acknowledged = RiskEvent(
            id: id, timestamp: Fix.subSecond, level: .critical, category: .massDeletion,
            title: "批量删除", detail: "第一版", isAcknowledged: true
        )
        try await store.recordRisks([acknowledged])
        let firstRead = try await store.riskEvents(matching: RiskQuery.all)
        #expect(firstRead.items.first?.isAcknowledged == true)

        // 同 id 再写一次「未确认」：除 isAcknowledged 外其余字段仍是全行覆盖。
        let again = RiskEvent(
            id: id, timestamp: Fix.subSecond, level: .critical, category: .massDeletion,
            title: "批量删除（改写）", detail: "第二版", isAcknowledged: false
        )
        try await store.recordRisks([again])
        let secondRead = try await store.riskEvents(matching: RiskQuery.all)
        let restored = try #require(secondRead.items.first { $0.id == id })
        #expect(restored.isAcknowledged, "isAcknowledged 必须单调为真")
        #expect(restored.detail == "第二版", "其余列仍是全行覆盖")
        #expect(restored.title == "批量删除（改写）")
        let unacked = try await store.riskEvents(matching: RiskQuery(unacknowledgedOnly: true, limit: 10))
        #expect(unacked.items.isEmpty, "unacknowledgedOnly 过滤应认这个列为 true")
        let rows = try await store.rowCount(table: "risk_events")
        #expect(rows == 1)
    }

    /// 计数是**重算**而非自增：同一批风险重复录入不得翻倍。
    @Test("20. recordRisks：会话 riskEventCount 为重算而非自增")
    func riskCountRecomputedNotIncremented() async throws {
        let store = try await Fix.store()
        let sessionID = Fix.uuid(330)
        try await store.upsertSessions([openSession(id: sessionID)])
        let beforeValue = try await store.session(id: sessionID)
        let beforeSession = try #require(beforeValue)
        #expect(beforeSession.riskEventCount == 0, "起始计数由写入值决定")

        let batch = [
            riskAt(.high, index: 0, sessionID: sessionID),
            riskAt(.critical, index: 1, sessionID: sessionID),
            riskAt(.low, index: 2, sessionID: nil),
        ]
        try await store.recordRisks(batch)
        let onceValue = try await store.session(id: sessionID)
        let onceSession = try #require(onceValue)
        #expect(onceSession.riskEventCount == 2, "只算属于该会话的两条")

        // 同批再录一次：重算 → 仍是 2，不翻倍。
        try await store.recordRisks(batch)
        let twiceValue = try await store.session(id: sessionID)
        let twiceSession = try #require(twiceValue)
        #expect(twiceSession.riskEventCount == 2, "重复录入不得让计数翻倍")
        let rows = try await store.rowCount(table: "risk_events")
        #expect(rows == 3, "三条风险各一行，无重复")

        // 再加一条 → 重算为 3（证明它确实在跟着集合变化，而不是写死）。
        try await store.recordRisks([riskAt(.medium, index: 3, sessionID: sessionID)])
        let thriceValue = try await store.session(id: sessionID)
        let thriceSession = try #require(thriceValue)
        #expect(thriceSession.riskEventCount == 3)
    }

    @Test("21. acknowledgeRisk(id:)：置为已确认、不增行，未知 id 静默无操作")
    func acknowledgeRisk() async throws {
        let store = try await Fix.store()
        let id = Fix.uuid(340)
        try await store.recordRisks([riskAt(.medium, index: 0, sessionID: nil)])
        try await store.recordRisks([
            RiskEvent(
                id: id, timestamp: Fix.subSecond, level: .medium, category: .dangerousCommand,
                title: "sudo rm", agentKind: .claudeCode, command: "sudo rm -rf /",
                requiresConfirmation: true, isAcknowledged: false, matchedRuleID: "rule.sudo"
            )
        ])
        let before = try await store.riskEvents(matching: RiskQuery(limit: 10))
        #expect(before.items.first { $0.id == id }?.isAcknowledged == false, "写入时确实是未确认")

        try await store.acknowledgeRisk(id: id)
        let after = try await store.riskEvents(matching: RiskQuery(limit: 10))
        let restored = try #require(after.items.first { $0.id == id })
        #expect(restored.isAcknowledged, "确认后读回必须为 true")
        #expect(restored.matchedRuleID == "rule.sudo", "确认不得顺手改写其他列")
        #expect(restored.title == "sudo rm")
        let rows = try await store.rowCount(table: "risk_events")
        #expect(rows == 2)

        try await store.acknowledgeRisk(id: Fix.uuid(341))
        let stillTwo = try await store.rowCount(table: "risk_events")
        #expect(stillTwo == 2, "未知 id 应为静默无操作")
    }

    @Test("22. ProjectActivity：agentContributions 与 hotFiles（含 score nil）逐项相等")
    func projectRichRoundTrip() async throws {
        let store = try await Fix.store()
        let rich = richProject()
        let sparse = sparseProject()
        try await store.upsertProjects([rich, sparse])

        let all = try await store.projects()
        #expect(all.count == 2)
        let restored = try #require(all.first { $0.id == rich.id })
        #expect(restored.hotFiles.count == 3, "hotFiles JSON 列表三项")
        #expect(restored.hotFiles[1].score == nil, "score 的 nil 不得变成 0（旧数据兼容靠它）")
        #expect(restored.hotFiles[0].score == 0.9375, "score 有值时逐位相等")
        #expect(restored.hotFiles[2].path == "", "空路径项必须原样回来")
        #expect(restored.agentContributions.count == 3)
        #expect(restored.agentContributions[2].relativeShare == 0)
        #expect(restored.codeShrinkLines == -340, "负数保号")
        expectSame(restored, rich, tag: "rich")

        let restoredSparse = try #require(all.first { $0.id == sparse.id })
        #expect(restoredSparse.agentContributions.isEmpty, "空列表 → 空数组")
        #expect(restoredSparse.hotFiles.isEmpty)
        expectSame(restoredSparse, sparse, tag: "sparse")
    }

    @Test("23. ProjectActivity：upsertProjects 覆盖，projectActivity(path:) 命中同一行")
    func projectOverwrite() async throws {
        let store = try await Fix.store()
        let first = richProject()
        try await store.upsertProjects([first])
        let second = ProjectActivity(
            id: first.id, name: "第二次写入 🎯", path: first.path, fileChangeCount: 0,
            commandCount: 1, sessionCount: 2, riskEventCount: 0, codeGrowthLines: 3,
            codeShrinkLines: 4, agentContributions: [
                AgentContribution(id: Fix.uuid(420), kind: .windsurf, relativeShare: 1, eventCount: 9)
            ],
            hotFiles: [
                FileHeat(id: Fix.uuid(421), path: "/only.swift", changeCount: 1, lastTouchedAt: Fix.now, score: 0)
            ],
            firstSeenAt: Fix.baseline,
            lastSeenAt: Fix.baseline
        )
        try await store.upsertProjects([second])

        let all = try await store.projects()
        #expect(all.count == 1, "同 id 覆盖不得增行")
        let restored = try #require(all.first)
        expectSame(restored, second, tag: "覆盖后")
        #expect(restored.agentContributions.count == 1, "旧 contributions 必须消失")
        #expect(restored.hotFiles.count == 1, "旧 hotFiles 必须消失")

        // 注意：projectActivity(path:dateRange:) 会**重算**四个计数字段（fileChangeCount /
        // commandCount / codeGrowthLines / codeShrinkLines），因此这里只断言它沿用库里
        // 行值的那几个字段，不去碰被重算的四项。
        let scopedRow = try await store.projectActivity(path: second.path, dateRange: .unbounded)
        let scoped = try #require(scopedRow)
        #expect(scoped.id == second.id)
        #expect(scoped.name == second.name)
        #expect(scoped.path == second.path)
        #expect(scoped.agentContributions == second.agentContributions)
        #expect(scoped.hotFiles == second.hotFiles)
        #expect(scoped.firstSeenAt == second.firstSeenAt)
        #expect(scoped.lastSeenAt == second.lastSeenAt)
        let missing = try await store.projectActivity(path: "/nope", dateRange: .unbounded)
        #expect(missing == nil)
        let rows = try await store.rowCount(table: "projects")
        #expect(rows == 1)
    }
}

// MARK: - Suite 5：快照、生命周期与保留期

@Suite("SwiftData 往返：快照、生命周期与保留期", .timeLimit(.minutes(1)))
struct SwiftDataSnapshotLifecycleTests {

    /// `FileSnapshot` 不在 `ObservatoryService` 的 13 个读方法里（没有读取 API），
    /// 因此 store 侧只能断言「确实落库 + 覆盖不增行」，逐字段无损由下一条补齐。
    @Test("24. FileSnapshot：recordSnapshot 落库，同 id 再写不增行")
    func snapshotRowCount() async throws {
        let store = try await Fix.store()
        let id = Fix.uuid(500)
        try await store.recordSnapshot(richSnapshot(id: id))
        let firstRow = try await store.rowCount(table: "file_snapshots")
        #expect(firstRow == 1)

        let rewritten = FileSnapshot(
            id: id, path: "/second.swift", contentHash: "sha256:second",
            sizeBytes: Fix.maxUInt, capturedAt: Fix.now, lineCount: 0
        )
        try await store.recordSnapshot(rewritten)
        let secondRow = try await store.rowCount(table: "file_snapshots")
        #expect(secondRow == 1, "同 id 覆盖不增行")

        try await store.recordSnapshot(richSnapshot(id: Fix.uuid(501)))
        let thirdRow = try await store.rowCount(table: "file_snapshots")
        #expect(thirdRow == 2)

        // 表名白名单：不在 `ObservatorySchema.allTableNames` 里必须显式抛错。
        do {
            _ = try await store.rowCount(table: "no_such_table")
            Issue.record("未知表名应抛 ObservatoryError.invalidQuery")
        } catch let error as ObservatoryError {
            switch error {
            case .invalidQuery(let why): #expect(why.contains("no_such_table"), "错误里要能定位表名：\(why)")
            default: Issue.record("应为 invalidQuery，实得 \(error)")
            }
        }
    }

    /// store 侧没有快照读取 API → 直接过 schema（与 `SwiftDataPredicateCapabilityTests`
    /// 同一手法，自建内存容器），钉住列级无损与 bit-pattern。
    @Test("25. FileSnapshot：@Model 列级 bit-pattern 与逐字段无损")
    func snapshotColumnLevel() throws {
        let container = try ModelContainer(
            for: ObservatorySchema.schema,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        let context = ModelContext(container)
        let snapshot = richSnapshot(id: Fix.uuid(502))
        context.insert(SDFileSnapshot(snapshot))
        try context.save()

        let text = snapshot.id.uuidString
        let records = try context.fetch(FetchDescriptor<SDFileSnapshot>(
            predicate: #Predicate { $0.rowID == text }
        ))
        #expect(records.count == 1)
        let record = try #require(records.first)
        #expect(record.sizeBytes < 0, "越界 UInt64 有意存成负 INTEGER（与 SQLite 的 Int64(bitPattern:) 同策）")
        #expect(record.sizeBytes == Int(Int64(bitPattern: Fix.hugeUInt)), "列值就是 bit-pattern 本身")
        #expect(record.path == snapshot.path, "path 含中文与 emoji")
        #expect(record.contentHash == snapshot.contentHash, "含引号与换行的哈希串原样存")
        #expect(record.lineCount == snapshot.lineCount)
        #expect(record.capturedAt == snapshot.capturedAt, "REAL 亚秒精度")
        let restored = try #require(record.domainValue())
        expectSame(restored, snapshot, tag: "column-level")
    }

    @Test("26. markRunningSessionsInterrupted：只结算 endedAt == nil 的行，时间戳为注入值")
    func markRunningSessionsInterrupted() async throws {
        let store = try await Fix.store()
        let openOne = openSession(id: Fix.uuid(600))
        let openTwo = AgentSession(
            id: Fix.uuid(601), displayIndex: 2, kind: .claudeCode, title: "另一条进行中",
            startedAt: Fix.subSecond, peakMemoryBytes: Fix.hugeUInt, outcome: .running
        )
        let closed = richSession(id: Fix.uuid(602))
        try await store.upsertSessions([openOne, openTwo, closed])

        let openBefore = try await store.openSessionCount()
        #expect(openBefore == 2)
        let changed = try await store.markRunningSessionsInterrupted(at: Fix.now)
        #expect(changed == 2, "返回受影响的条数")
        let openAfter = try await store.openSessionCount()
        #expect(openAfter == 0)

        let openOneAfter = try await store.session(id: openOne.id)
        let restoredOpen = try #require(openOneAfter)
        #expect(restoredOpen.endedAt == Fix.now, "endedAt 必须是注入的时间戳")
        #expect(
            restoredOpen.endedAt?.timeIntervalSinceReferenceDate == Fix.now.timeIntervalSinceReferenceDate,
            "结算时间逐位等于注入值"
        )
        #expect(restoredOpen.outcome == .interrupted)
        #expect(restoredOpen.isActive == false)
        #expect(restoredOpen.title == openOne.title, "结算只改两列，其余列不动")
        #expect(restoredOpen.kind == openOne.kind)
        #expect(restoredOpen.peakMemoryBytes == openOne.peakMemoryBytes)

        let openTwoAfter = try await store.session(id: openTwo.id)
        let restoredTwo = try #require(openTwoAfter)
        #expect(restoredTwo.endedAt == Fix.now)
        #expect(restoredTwo.outcome == .interrupted)

        let closedAfter = try await store.session(id: closed.id)
        let restoredClosed = try #require(closedAfter)
        expectSame(restoredClosed, closed, tag: "已结算行不得被动")

        // 幂等：没有未闭合会话时返回 0。
        let again = try await store.markRunningSessionsInterrupted(at: Fix.now.addingTimeInterval(60))
        #expect(again == 0)
        let rows = try await store.rowCount(table: "sessions")
        #expect(rows == 3)
    }

    @Test("27. prune(olderThan:vacuum:false) 只删 cutoff 之前的行（严格小于）")
    func pruneRemovesOnlyOldRows() async throws {
        let store = try await Fix.store()
        let sessionID = Fix.uuid(700)
        try await store.upsertSessions([richSession(id: sessionID)])
        try await store.upsertProjects([sparseProject()])
        try await store.recordSnapshot(richSnapshot(id: Fix.uuid(701)))
        await store.append(sparseEvent(id: Fix.uuid(702)))              // Fix.baseline：保留
        await store.append(richEvent(id: Fix.uuid(703), sessionID: sessionID)) // Fix.subSecond：保留
        await store.append(TimelineEvent(
            id: Fix.uuid(704), timestamp: Fix.longAgo, kind: .unknown, title: "很久以前"
        ))
        await store.append(FileChange(id: Fix.uuid(705), path: "/old.swift", kind: .deleted, timestamp: Fix.longAgo))
        await store.append(richCommand(id: Fix.uuid(706), sessionID: sessionID))
        await store.append(sparseSample(id: Fix.uuid(707), sessionID: sessionID))
        await store.append(sparseSystemSample(id: Fix.uuid(708)))
        try await store.recordRisks([riskAt(.high, index: 0, sessionID: sessionID)])
        await store.flush()

        let cutoff = Fix.offset(-3_600)  // 早于所有 Fix.baseline 之后的样本，晚于 longAgo
        let result = try await store.prune(olderThan: cutoff, vacuum: false)
        #expect(result.cutoff == cutoff, "返回的 cutoff 就是入参（不读墙钟）")
        #expect(result.didVacuum == false, "SwiftData 永不 VACUUM")
        #expect(result.deletedRowsByTable["events"] == 1, "只有 longAgo 那条事件被删")
        #expect(result.deletedRowsByTable["file_changes"] == 1)
        #expect(result.deletedRowsByTable["sessions"] == 0, "sessions 按 started_at 判：基准会话保留")
        #expect(result.deletedRowsByTable["agents"] == 0)
        #expect(result.deletedRowsByTable["projects"] == 0)
        #expect(result.deletedRowsByTable["file_snapshots"] == 0)
        #expect(result.totalDeletedRows == 2)
        #expect(result.deletedRowsByTable.count == 11, "每张表都要在字典里（含删了 0 行的表）")

        let events = try await store.events(matching: EventQuery(limit: 50))
        #expect(events.totalCount == 2)
        #expect(events.items.contains(where: { $0.id == Fix.uuid(704) }) == false)
        #expect(events.items.contains(where: { $0.id == Fix.uuid(702) }))
        #expect(events.items.contains(where: { $0.id == Fix.uuid(703) }))
        let changes = try await store.fileChanges(matching: FileChangeQuery(limit: 50))
        #expect(changes.totalCount == 0, "唯一的文件变更在 cutoff 之前，应已被删")
        #expect(changes.items.isEmpty)
        // 保留下来的行仍逐字段无损（剪枝不该改写它们）。
        let keptSamples = try await store.performanceSamples(sessionID: sessionID)
        let keptSample = try #require(keptSamples.first)
        expectSame(keptSample, sparseSample(id: Fix.uuid(707), sessionID: sessionID), tag: "剪枝后保留行")
        let keptEvents = try await store.events(matching: EventQuery(limit: 50))
        for event in keptEvents.items {
            let original = event.id == Fix.uuid(702) ? sparseEvent(id: Fix.uuid(702))
                : richEvent(id: Fix.uuid(703), sessionID: sessionID)
            expectSame(event, original, tag: "剪枝后保留事件")
        }
    }

    /// 断言口径选择：`ObservatoryError` 是 Equatable，但整值比较会把**措辞**也钉成契约
    /// （改一个标点就红，红得没有信息量）。因此断 **case 形状** + 关键信息子串，
    /// 既保证「确实是 unsupported 而不是顺手抛个错」，也不锁死文案。
    @Test("28. prune(vacuum: true) 抛 ObservatoryError.unsupported，且不动任何行")
    func pruneVacuumUnsupported() async throws {
        let store = try await Fix.store()
        await store.append(sparseEvent(id: Fix.uuid(800)))
        await store.flush()

        var caught: ObservatoryError?
        do {
            _ = try await store.prune(olderThan: Fix.now, vacuum: true)
        } catch let error as ObservatoryError {
            caught = error
        } catch {
            Issue.record("应抛 ObservatoryError，实得 \(type(of: error))")
        }
        let thrown = try #require(caught)
        switch thrown {
        case .unsupported(let what):
            #expect(what.contains("VACUUM"), "错误里必须讲清是 VACUUM 不支持：\(what)")
            #expect(what.contains("SQLite"), "错误里应指路回 SQLite 后端：\(what)")
        default:
            Issue.record("必须且只能是 .unsupported，实得 \(thrown)")
        }
        // 抛错发生在任何删除之前。
        let rows = try await store.rowCount(table: "events")
        #expect(rows == 1, "拒绝 VACUUM 时一行都不该动")
        let pruned = try await store.prune(olderThan: Fix.now, vacuum: false)
        #expect(pruned.totalDeletedRows == 1, "同一 cutoff 下 vacuum:false 正常删除")
        let rowsAfter = try await store.rowCount(table: "events")
        #expect(rowsAfter == 0)
    }

    @Test("29. deleteAllData：11 张表全部清空，内存库不落盘")
    func deleteAllDataEmptiesEveryTable() async throws {
        let store = try await Fix.store()
        let sessionID = Fix.uuid(900)
        try await store.upsertAgents([richAgent(id: Fix.uuid(1), state: .running)])
        try await store.upsertSessions([richSession(id: sessionID)])
        try await store.upsertProjects([richProject()])
        try await store.recordRisks([riskAt(.critical, index: 0, sessionID: sessionID)])
        try await store.record(richDiff(id: Fix.uuid(901)), forChangeID: Fix.uuid(901))
        try await store.recordSnapshot(richSnapshot(id: Fix.uuid(902)))
        await store.append(richEvent(id: Fix.uuid(903), sessionID: sessionID))
        await store.append(richFileChange(id: Fix.uuid(904), sessionID: sessionID))
        await store.append(richCommand(id: Fix.uuid(905), sessionID: sessionID))
        await store.append(richSample(id: Fix.uuid(906), sessionID: sessionID, at: Fix.subSecond))
        await store.append(richSystemSample(id: Fix.uuid(907), at: Fix.subSecond))
        await store.flush()

        let tables = [
            "file_snapshots", "diffs", "perf_samples", "events", "file_changes", "commands",
            "risk_events", "system_perf", "sessions", "agents", "projects",
        ]
        #expect(tables.count == 11)
        for table in tables {
            let beforeCount = try await store.rowCount(table: table)
            #expect(beforeCount > 0, "清空前 \(table) 应非空")
        }

        try await store.deleteAllData()
        for table in tables {
            let afterCount = try await store.rowCount(table: table)
            #expect(afterCount == 0, "deleteAllData 后 \(table) 必须为 0")
        }
        let activeAfter = try await store.activeAgents()
        let projectsAfter = try await store.projects()
        let openAfter = try await store.openSessionCount()
        let memory = await store.isInMemory
        let fileURL = await store.fileURL
        #expect(activeAfter.isEmpty, "活跃 Agent 列表也应清空")
        #expect(projectsAfter.isEmpty)
        #expect(openAfter == 0)
        #expect(memory, "本用例全程零磁盘写入")
        #expect(fileURL == nil)
    }

    /// 唯一落盘的一条：证明数据不是只活在内存里。写完 `stop()`、离开作用域释放容器，
    /// 再用同一目录同名文件重开，读回来的行仍逐字段相等。
    @Test("30. 落盘：文件 open → 写 → stop → 重开同名文件，数据仍在")
    func dataSurvivesReopen() async throws {
        let fileName = "roundtrip-reopen.store"
        let directory = try Scratch.directory("swiftdata-reopen")
        defer { try? FileManager.default.removeItem(at: directory) }
        let configuration = SwiftDataStoreConfiguration(directory: directory.path, fileName: fileName)
        let sessionID = Fix.uuid(1_000)
        let eventID = Fix.uuid(1_001)
        let session = richSession(id: sessionID)
        let event = richEvent(id: eventID, sessionID: sessionID)

        try await writeToFile(configuration: configuration, session: session, event: event)

        let entries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        #expect(entries.contains { $0.hasPrefix(fileName) }, "store 文件必须真的存在：\(entries)")

        let restored = try await readFromFile(
            configuration: configuration, sessionID: sessionID, eventID: eventID
        )
        let reopened = try #require(restored.session)
        expectSame(reopened, session, tag: "重开后")
        let reopenedEvent = try #require(restored.event)
        expectSame(reopenedEvent, event, tag: "重开后事件")
        #expect(restored.agentCount == 1, "agents 也要活过重开")
        #expect(restored.sessionRows == 1, "重开后会话表不该多出幽灵行")
    }

    @Test("31. 配置解析：显式目录优先 → 环境变量兜底 → 全空退化为内存库（不落盘）")
    func configurationResolution() throws {
        let explicit = SwiftDataStoreConfiguration.resolved(
            explicitDirectory: Scratch.root.path,
            fileName: "explicit.store",
            environment: [SwiftDataStoreConfiguration.dataDirectoryEnvironmentKey: "/env/dir"]
        )
        #expect(explicit.directory == Scratch.root.path, "显式值赢过环境变量")
        #expect(explicit.storeURL?.lastPathComponent == "explicit.store")
        #expect(explicit.isInMemory == false)

        let fromEnvironment = SwiftDataStoreConfiguration.resolved(
            explicitDirectory: "   ",
            environment: [SwiftDataStoreConfiguration.dataDirectoryEnvironmentKey: "/env/dir"]
        )
        #expect(fromEnvironment.directory == "/env/dir", "显式全空白 → 环境变量")
        #expect(fromEnvironment.storeURL?.path == "/env/dir/observatory.store", "默认文件名")
        #expect(fromEnvironment.isInMemory == false)

        let memory = SwiftDataStoreConfiguration.resolved(
            explicitDirectory: "",
            environment: [SwiftDataStoreConfiguration.dataDirectoryEnvironmentKey: "  "]
        )
        #expect(memory.directory == "")
        #expect(memory.storeURL == nil, "两处都为空 → 内存库")
        #expect(memory.isInMemory)
        #expect(SwiftDataStoreConfiguration.inMemory.isInMemory)
    }

    @Test("32. 后端选择：AIOBSERVATORY_BACKEND 大小写/连字符宽容，认不出就回落默认")
    func backendSelection() {
        let key = ObservatoryStoreBackend.environmentKey
        #expect(ObservatoryStoreBackend.fromEnvironment([key: "swiftdata"], default: .sqlite) == .swiftData)
        #expect(ObservatoryStoreBackend.fromEnvironment([key: " Swift-Data "]) == .swiftData, "空白与连字符宽容")
        #expect(ObservatoryStoreBackend.fromEnvironment([key: "SWIFT_DATA"]) == .swiftData)
        #expect(ObservatoryStoreBackend.fromEnvironment([key: "sqlite3"]) == .sqlite)
        #expect(ObservatoryStoreBackend.fromEnvironment([:]) == .sqlite, "未设置 → 默认 SQLite")
        #expect(ObservatoryStoreBackend.fromEnvironment([key: ""], default: .swiftData) == .swiftData, "空串按未设置")
        #expect(ObservatoryStoreBackend.fromEnvironment([key: "postgres"], default: .swiftData) == .swiftData, "配错一个字母不该让 app 起不来")
        #expect(ObservatoryStoreBackend.sqlite.displayName == "SQLite")
        #expect(ObservatoryStoreBackend.swiftData.displayName == "SwiftData")
    }
}

// MARK: - 落盘用例的分阶段辅助
//
// 拆成两个自由函数而不是在一个测试里开两次容器：`SwiftDataObservatoryStore` 持有
// 非 Sendable 的 `ModelContainer`，只有让它先离开作用域（容器随之释放），重开同一文件
// 才是「换个进程等价」的冷启动，而不是两个容器抢同一个 store。

private func writeToFile(
    configuration: SwiftDataStoreConfiguration, session: AgentSession, event: TimelineEvent
) async throws {
    let store = try await SwiftDataObservatoryStore.open(configuration: configuration)
    let url = await store.fileURL
    #expect(url == configuration.storeURL, "fileURL 必须回显落盘位置")
    let inMemory = await store.isInMemory
    #expect(inMemory == false, "带目录的配置不该退化成内存库")
    try await store.upsertSessions([session])
    try await store.upsertAgents([richAgent(id: Fix.uuid(1), state: .running)])
    await store.append(event)
    await store.flush()
    await store.stop()
}

private func readFromFile(
    configuration: SwiftDataStoreConfiguration, sessionID: UUID, eventID: UUID
) async throws -> (session: AgentSession?, event: TimelineEvent?, agentCount: Int, sessionRows: Int) {
    let store = try await SwiftDataObservatoryStore.open(configuration: configuration)
    let session = try await store.session(id: sessionID)
    let events = try await store.events(matching: EventQuery(limit: 10))
    let agents = try await store.activeAgents()
    let sessionRows = try await store.rowCount(table: "sessions")
    await store.stop()
    return (session, events.items.first { $0.id == eventID }, agents.count, sessionRows)
}
