//
//  ObservatoryPreviewSupport.swift
//  AIObservatoryUI
//
//  Owner: WS-UI (subagent A)
//  Preview 专用样本运行时：确定性小数据 + 真实过滤/排序/分页语义，绝不进入生产路径。
//
//  设计约束：
//    · UI target 只依赖 AIObservatoryCore，因此不能 import AIObservatoryTestSupport（会编译失败），
//      这里在 UI 内自造一份与 SampleData.demoService 思路一致的样本服务。
//    · 样本服务是 `struct`（全部存储属性不可变）→ 天然 Sendable，无需 `@unchecked`。
//    · `makeUpdateStream()` 返回立即 finish 的空流，避免 Preview 空转消费。
//    · 唯一入口是 `ObservatoryPreview`，生产代码（App / Engine）不会引用它。
//

import SwiftUI
import AIObservatoryCore

// MARK: - Sample service

/// 仅供 SwiftUI Preview 使用的内存样本服务。
struct ObservatoryPreviewService: ObservatoryService, ObservatoryControlling, ObservatoryEventStreaming {

    // MARK: - Samples container

    private struct Samples {
        var agents: [AgentInstance] = []
        var sessions: [AgentSession] = []
        var events: [TimelineEvent] = []
        var fileChanges: [FileChange] = []
        var diffs: [UUID: FileDiff] = [:]
        var commands: [CommandRecord] = []
        var performance: [PerformanceSample] = []
        var systemPerformance: [SystemPerformanceSample] = []
        var risks: [RiskEvent] = []
        var projects: [ProjectActivity] = []
    }

    private let samples: Samples

    /// - Parameters:
    ///   - now: 样本时间轴的「现在」锚点，保证所有样本落在同一个可查询窗口内。
    ///   - empty: 传 `true` 得到全空数据，用于验证各板块的空状态。
    init(now: Date = Date(), empty: Bool = false) {
        samples = empty ? Samples() : Self.makeSamples(now: now)
    }

    // MARK: - Deterministic sample factory

    /// 一次装配的全部中间态：夹具的确定性由「同一个 `now` + 同一份 fraction 时间轴」保证。
    /// 阶段方法按下面的顺序往 `s` 上追加，后一阶段会读前一阶段的结果 ⇒ 顺序就是行为。
    private struct SamplesBuilder {

        var s = Samples()
        let now: Date
        let dayStart: Date
        let elapsed: TimeInterval
        let projectPaths = ["/Users/demo/Projects/Mona", "/Users/demo/Projects/Aurora"]
        let fileNames = ["API.swift", "UserService.swift", "README.md", "Package.swift",
                         "Config.json", "Router.swift", "Model.swift", "ViewModel.swift"]

        init(now: Date) {
            self.now = now
            // 时间轴口径与拆前完全相同：日首 + [0,1] 线性映射到 [dayStart, now]。
            let dayStart = Calendar.current.startOfDay(for: now)
            self.dayStart = dayStart
            self.elapsed = max(now.timeIntervalSince(dayStart), 0)
        }

        // 把 [dayStart, now] 均分成一条时间轴，fraction ∈ [0,1] → 保证样本全部落在「今天」。
        func spread(_ fraction: Double) -> Date {
            dayStart.addingTimeInterval(elapsed * min(max(fraction, 0), 1))
        }

        func agentID(for kind: AgentKind) -> UUID? {
            s.agents.first { $0.kind == kind }?.id
        }

        /// appendAgents：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func appendAgents() {
            // —— 2 个 running AgentInstance ——
            let agentKinds: [AgentKind] = [.claudeCode, .cursorAgent]
            s.agents = agentKinds.enumerated().map { index, kind in
                AgentInstance(
                    kind: kind,
                    pid: Int32(12_400 + index * 331),
                    parentPID: 1,
                    displayName: kind.displayName,
                    executablePath: "/usr/local/bin/\(kind.rawValue)",
                    workingDirectory: projectPaths[index % projectPaths.count],
                    bundleIdentifier: nil,
                    tty: "ttys00\(index)",
                    startedAt: spread(0.04 + Double(index) * 0.06),
                    lastSeenAt: now,
                    state: .running,
                    cpuPercent: index == 0 ? 18.4 : 6.2,
                    memoryBytes: UInt64(index == 0 ? 1_800 : 640) * 1_048_576,
                    childPIDs: [Int32(13_000 + index)],
                    detectedVia: index == 0 ? .executablePath : .processName
                )
            }
        }

        /// appendSessions：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func appendSessions() {
            // —— 7 个 Session（running ×2、success ×3、failed、interrupted）——
            let sessionSeeds: [(kind: AgentKind, project: Int, start: Double, durationMinutes: Double?, outcome: SessionOutcome)] = [
                (.claudeCode,      0, 0.08, nil,   .running),
                (.cursorAgent,     1, 0.18, nil,   .running),
                (.openAICodex,     0, 0.28, 40,    .success),
                (.windsurf,        1, 0.40, 30,    .failed),
                (.claudeCode,      0, 0.55, 60,    .success),
                (.genericCLIAgent, 1, 0.66, 15,    .interrupted),
                (.cursorAgent,     0, 0.75, 45,    .success)
            ]
            let riskCounts = [2, 1, 1, 1, 0, 0, 0]
            s.sessions = sessionSeeds.enumerated().map { index, seed in
                let startedAt = spread(seed.start)
                let endedAt: Date? = seed.durationMinutes.map { minutes in
                    min(startedAt.addingTimeInterval(minutes * 60), now)
                }
                let duration = (endedAt ?? now).timeIntervalSince(startedAt)
                return AgentSession(
                    displayIndex: 101 + index,
                    kind: seed.kind,
                    agentID: agentID(for: seed.kind),
                    title: "\(seed.kind.displayName) · 重构与测试闭环 #\(101 + index)",
                    projectPath: projectPaths[seed.project],
                    startedAt: startedAt,
                    endedAt: endedAt,
                    modifiedFileCount: 6 + index * 3,
                    createdFileCount: index % 2 == 0 ? 3 + index : 1,
                    deletedFileCount: index % 3 == 0 ? 1 + index / 3 : 0,
                    commandCount: 3 + index * 2,
                    failedCommandCount: index % 3,
                    cpuSeconds: duration * 0.22,
                    peakCPUPercent: 32 + Double(index) * 8,
                    peakMemoryBytes: UInt64(620 + index * 260) * 1_048_576,
                    estimatedTokens: 12_000 + index * 9_500,
                    riskEventCount: riskCounts[index],
                    outcome: seed.outcome
                )
            }
        }

        /// appendEventsAndFileChanges：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func appendEventsAndFileChanges() {
            // —— 49 条 TimelineEvent（7 session × 7 类操作），并顺带产出 21 条 FileChange ——
            let eventCycle: [OperationKind] = [.fileModified, .fileCreated, .commandExecuted,
                                               .gitOperation, .fileDeleted, .riskDetected, .fileRead]
            let commandCycle: [(exe: String, args: [String])] = [
                ("npm", ["test"]), ("git", ["status"]), ("swift", ["build"]),
                ("rm", ["-rf", "./build"]), ("docker", ["compose", "up"]), ("git", ["push", "origin", "main"])
            ]
    let sessions = s.sessions   // 快照：循环体只写 events / fileChanges
            for (sessionIndex, session) in sessions.enumerated() {
                let span = max(session.duration, 600)
                for (eventIndex, kind) in eventCycle.enumerated() {
                    let timestamp = session.startedAt.addingTimeInterval(span * Double(eventIndex + 1) / 8.0)
                    let fileName = fileNames[(sessionIndex + eventIndex * 2) % fileNames.count]
                    let path = "\(session.projectPath ?? projectPaths[0])/Sources/\(fileName)"
                    var event = TimelineEvent(
                        timestamp: timestamp,
                        sessionID: session.id,
                        agentID: session.agentID,
                        agentKind: session.kind,
                        kind: kind,
                        title: "\(kind.displayName) · \(fileName)",
                        summary: path,
                        projectPath: session.projectPath
                    )
                    switch kind {
                    case .fileModified, .fileCreated, .fileDeleted:
                        event.filePath = path
                        event.summary = path
                        let changeKind: FileChangeKind = kind == .fileCreated ? .created : (kind == .fileDeleted ? .deleted : .modified)
                        if changeKind == .deleted { event.riskLevel = .medium }
                        event.cost = ResourceCost(
                            cpuSeconds: 0.2 + Double(eventIndex) * 0.3,
                            memoryBytes: UInt64(24 + eventIndex * 9) * 1_048_576,
                            bytesRead: UInt64(40_000 + eventIndex * 11_000),
                            bytesWritten: UInt64(9_000 + eventIndex * 3_500)
                        )
                        s.fileChanges.append(FileChange(
                            path: path,
                            kind: changeKind,
                            timestamp: timestamp,
                            agentID: session.agentID,
                            sessionID: session.id,
                            agentKind: session.kind,
                            sizeBytes: UInt64(4_000 + eventIndex * 2_400),
                            previousSizeBytes: changeKind == .created ? nil : UInt64(3_200 + eventIndex * 1_900),
                            linesAdded: changeKind == .deleted ? 0 : 4 + eventIndex * 6,
                            linesRemoved: changeKind == .created ? 0 : 2 + eventIndex * 3,
                            riskLevel: changeKind == .deleted ? .medium : .low,
                            projectPath: session.projectPath
                        ))
                    case .commandExecuted:
                        let template = commandCycle[(sessionIndex + eventIndex) % commandCycle.count]
                        let isDeletion = template.exe == "rm"
                        let exit: Int32 = (sessionIndex + eventIndex) % 4 == 3 ? 1 : 0
                        event.title = "执行 \(template.exe) \(template.args.joined(separator: " "))"
                        event.summary = "退出码 \(exit) · 耗时 \(String(format: "%.1f", 2 + Double(eventIndex))) 秒"
                        event.command = ([template.exe] + template.args).joined(separator: " ")
                        event.exitCode = exit
                        event.durationSeconds = 2 + Double(eventIndex)
                        event.riskLevel = isDeletion ? .high : .low
                    case .gitOperation:
                        event.command = "git commit -m \"feat: observatory pass \(sessionIndex)\""
                        event.summary = "分支 main · 提交成功"
                    case .riskDetected:
                        event.title = "风险：疑似破坏性清理"
                        event.summary = "命中规则 R-004（批量删除阈值 20）"
                        event.command = "rm -rf ./Archives"
                        event.filePath = "\(session.projectPath ?? projectPaths[0])/Archives"
                        event.riskLevel = sessionIndex % 2 == 0 ? .critical : .high
                        event.exitCode = 0
                    case .fileRead:
                        event.filePath = path
                        event.summary = "读取 \(fileName)（无写入）"
                    default:
                        break
                    }
                    s.events.append(event)
                }
            }
        }

        /// attachDiffs：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func attachDiffs() {
            // —— 8 份完整 FileDiff（meta + hunkHeader + context/added/removed，带行号）——
    let firstChanges = Array(s.fileChanges.prefix(8))   // 同上：只写 diffs
            for change in firstChanges {
                s.diffs[change.id] = ObservatoryPreviewService.makeDiff(for: change)
            }
        }

        /// appendCommands：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func appendCommands() {
            // —— 16 条 CommandRecord（含 rm -rf 破坏性命令）——
            let commandSeeds: [(exe: String, args: [String], outcome: CommandOutcome, exit: Int32?,
                                destructive: Bool, risk: RiskLevel)] = [
                ("rm", ["-rf", "./build"], .success, 0, true, .high),
                ("npm", ["test"], .success, 0, false, .low),
                ("git", ["commit", "-m", "feat: shell"], .success, 0, false, .low),
                ("swift", ["build"], .failure, 1, false, .low),
                ("git", ["push", "origin", "main"], .success, 0, false, .low),
                ("docker", ["compose", "up", "-d"], .success, 0, false, .low),
                ("python", ["train.py", "--epochs", "3"], .running, nil, false, .low),
                ("curl", ["-fsSL", "https://example.com/install.sh"], .success, 0, false, .medium),
                ("chmod", ["+x", "Scripts/deploy.sh"], .success, 0, false, .low),
                ("sudo", ["rm", "-rf", "/var/cache/tmp"], .terminated, nil, true, .critical),
                ("git", ["rebase", "-i", "HEAD~5"], .failure, 1, false, .medium),
                ("xcodebuild", ["test", "-scheme", "AIObservatory"], .success, 0, false, .low),
                ("killall", ["PreviewAgent"], .success, 0, true, .medium),
                ("swift", ["test"], .success, 0, false, .low),
                ("node", ["bench.js"], .running, nil, false, .low),
                ("tar", ["czf", "backup.tgz", "Sources"], .unknown, nil, false, .low)
            ]
            s.commands = commandSeeds.enumerated().map { index, seed in
                let session = s.sessions[index % s.sessions.count]
                let startedAt = spread(0.10 + Double(index) * 0.05)
                let endedAt: Date? = seed.outcome == .running || seed.outcome == .unknown ? nil
                    : min(startedAt.addingTimeInterval(30 + Double(index) * 12), now)
                return CommandRecord(
                    executable: seed.exe,
                    arguments: seed.args,
                    workingDirectory: session.projectPath,
                    agentID: session.agentID,
                    sessionID: session.id,
                    agentKind: session.kind,
                    startedAt: startedAt,
                    endedAt: endedAt,
                    exitCode: seed.exit,
                    outcome: seed.outcome,
                    isDestructive: seed.destructive,
                    requiresConfirmation: seed.destructive || seed.risk >= .high,
                    riskLevel: seed.risk,
                    projectPath: session.projectPath
                )
            }
        }

        /// appendPerformance：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func appendPerformance() {
            // —— 36 条 PerformanceSample（最近 3 小时，每 5 分钟）——
            s.performance = (0..<36).map { index in
                let session = s.sessions[index % s.sessions.count]
                return PerformanceSample(
                    timestamp: now.addingTimeInterval(-Double(36 - index) * 300),
                    sessionID: session.id,
                    agentID: session.agentID,
                    cpuPercent: 8 + Double((index * 17) % 64),
                    memoryBytes: UInt64(480 + (index * 137) % 2_100) * 1_048_576,
                    gpuPercent: index % 3 == 0 ? Double((index * 7) % 42) : nil,
                    diskReadBytesPerSecond: Double(2_000_000 + (index * 971_713) % 120_000_000),
                    diskWriteBytesPerSecond: Double(500_000 + (index * 761_317) % 60_000_000),
                    networkBytesIn: UInt64((index * 2_311_713) % 40_000_000),
                    networkBytesOut: UInt64((index * 1_451_079) % 12_000_000),
                    thermalCelsius: 45 + Double((index * 3) % 21),
                    powerWatts: 8 + Double((index * 5) % 15)
                )
            }
        }

        /// appendSystemPerformance：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func appendSystemPerformance() {
            // —— 24 点 SystemPerformanceSample（每 5 分钟，覆盖最近 2 小时）——
            s.systemPerformance = (0..<24).map { index -> SystemPerformanceSample in
                let cpuTotal = 22 + Double((index * 13) % 41)
                let cpuSystem = 4 + Double((index * 5) % 11)
                let cpuUser = 16 + Double((index * 9) % 29)
                let usedBytes = UInt64(11 + (index % 7)) * 1_073_741_824
                let readRate = Double(4_000_000 + (index * 8_317_713) % 180_000_000)
                let writeRate = Double(2_000_000 + (index * 6_121_317) % 90_000_000)
                let load = 0.8 + Double((index * 7) % 52) / 10
                let thermal = 48 + Double((index * 4) % 18)
                let power = 9 + Double((index * 3) % 16)
                let stamp = now.addingTimeInterval(-Double(23 - index) * 300)
                return SystemPerformanceSample(
                    timestamp: stamp,
                    cpuTotalPercent: cpuTotal,
                    cpuSystemPercent: cpuSystem,
                    cpuUserPercent: cpuUser,
                    memoryUsedBytes: usedBytes,
                    memoryTotalBytes: 32 * 1_073_741_824,
                    diskReadBytesPerSecond: readRate,
                    diskWriteBytesPerSecond: writeRate,
                    loadAverage1m: load,
                    thermalCelsius: thermal,
                    powerWatts: power
                )
            }
        }

        /// appendRisks：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func appendRisks() {
            // —— 4 条 RiskEvent（critical / high+已确认 / medium / low）——
            s.risks = [
                RiskEvent(
                    timestamp: spread(0.92), level: .critical, category: .massDeletion,
                    title: "疑似批量删除 42 个文件",
                    detail: "同一分钟内删除文件数超过阈值 20，工作目录位于 Mona 项目内。",
                    agentID: agentID(for: .claudeCode), agentKind: .claudeCode,
                    sessionID: s.sessions[0].id,
                    command: "rm -rf ./Archives",
                    filePaths: ["/Users/demo/Projects/Mona/Archives"],
                    requiresConfirmation: true, matchedRuleID: "R-001"
                ),
                RiskEvent(
                    timestamp: spread(0.80), level: .high, category: .dangerousCommand,
                    title: "执行提权删除命令",
                    detail: "sudo rm -rf 命中破坏性规则 R-004，已由用户确认为预期操作。",
                    agentKind: .windsurf, sessionID: s.sessions[3].id,
                    command: "sudo rm -rf /var/cache/tmp",
                    requiresConfirmation: true, isAcknowledged: true, matchedRuleID: "R-004"
                ),
                RiskEvent(
                    timestamp: spread(0.60), level: .medium, category: .sensitivePathAccess,
                    title: "写入 ~/.config 目录",
                    detail: "修改用户配置目录下的文件，属于敏感路径。",
                    agentID: agentID(for: .cursorAgent), agentKind: .cursorAgent,
                    sessionID: s.sessions[1].id,
                    filePaths: ["\(NSHomeDirectory())/.config/demo/settings.json"],
                    matchedRuleID: "R-011"
                ),
                RiskEvent(
                    timestamp: spread(0.35), level: .low, category: .resourceAbuse,
                    title: "训练进程 CPU 持续偏高",
                    detail: "python train.py 连续 12 分钟占用超过 60% CPU。",
                    agentKind: .openAICodex, sessionID: s.sessions[2].id,
                    command: "python train.py --epochs 3"
                )
            ]
        }

        /// appendProjects：从上一阶段的 `s` 出发追加本阶段（逐字搬自拆分前的 makeSamples）。
        mutating func appendProjects() {
            // —— 2 个 ProjectActivity（贡献占比与热区文件从上面的样本聚合而来，保证自洽）——
            s.projects = projectPaths.map { path in
                let changes = s.fileChanges.filter { $0.projectPath == path }
                let projectCommands = s.commands.filter { $0.projectPath == path }
                let projectSessions = s.sessions.filter { $0.projectPath == path }
                let projectSessionIDs = Set(projectSessions.map(\.id))
                let grouped = Dictionary(grouping: changes, by: \.path)
                let builtHotFiles: [FileHeat] = grouped.keys.sorted().compactMap { filePath in
                    guard let items = grouped[filePath], !items.isEmpty else { return nil }
                    let added = items.reduce(0) { $0 + $1.linesAdded }
                    let removed = items.reduce(0) { $0 + $1.linesRemoved }
                    let touched = items.map(\.timestamp).max() ?? now
                    return FileHeat(
                        path: filePath,
                        changeCount: items.count,
                        linesAdded: added,
                        linesRemoved: removed,
                        lastTouchedAt: touched
                    )
                }
                let hotFiles = builtHotFiles.sorted { lhs, rhs in
                    lhs.changeCount != rhs.changeCount ? lhs.changeCount > rhs.changeCount : lhs.path < rhs.path
                }
                var contributions: [AgentContribution] = []
                let total = max(1, changes.count)
                for kind in AgentKind.allCases {
                    let count = changes.filter { $0.agentKind == kind }.count
                    if count > 0 {
                        contributions.append(AgentContribution(kind: kind, relativeShare: Double(count) / Double(total), eventCount: count))
                    }
                }
                return ProjectActivity(
                    id: path,
                    name: (path as NSString).lastPathComponent,
                    path: path,
                    fileChangeCount: changes.count,
                    commandCount: projectCommands.count,
                    sessionCount: projectSessions.count,
                    riskEventCount: s.risks.filter { risk in
                        guard let sessionID = risk.sessionID else { return false }
                        return projectSessionIDs.contains(sessionID)
                    }.count,
                    codeGrowthLines: changes.reduce(0) { $0 + $1.linesAdded },
                    codeShrinkLines: changes.reduce(0) { $0 + $1.linesRemoved },
                    agentContributions: contributions.sorted { $0.eventCount > $1.eventCount },
                    hotFiles: Array(hotFiles.prefix(12)),
                    firstSeenAt: projectSessions.map(\.startedAt).min() ?? now,
                    lastSeenAt: changes.map(\.timestamp).max() ?? now
                )
            }
        }

    }

    /// 夹具装配 = 九个阶段按顺序跑一遍（阶段之间只通过 `s` 传递状态）。
    private static func makeSamples(now: Date) -> Samples {
        var builder = SamplesBuilder(now: now)
        builder.appendAgents()
        builder.appendSessions()
        builder.appendEventsAndFileChanges()
        builder.attachDiffs()
        builder.appendCommands()
        builder.appendPerformance()
        builder.appendSystemPerformance()
        builder.appendRisks()
        builder.appendProjects()
        return builder.s
    }


    /// 构造一份带行号、四类样式齐全的示例 diff。
    private static func makeDiff(for change: FileChange) -> FileDiff {
        let fileName = change.fileName
        var lines: [DiffLine] = [
            DiffLine(style: .meta, text: "diff --git a/\(fileName) b/\(fileName)"),
            DiffLine(style: .hunkHeader, text: "@@ -1,12 +1,14 @@ \(fileName)")
        ]
        var oldLine = 1
        var newLine = 1
        var added = 0
        var removed = 0
        for index in 0..<10 {
            switch index % 4 {
            case 1:
                lines.append(DiffLine(style: .removed,
                                      text: "    let legacy\(index) = compute(entry: \(index))",
                                      oldLineNumber: oldLine))
                oldLine += 1
                removed += 1
            case 2:
                lines.append(DiffLine(style: .added,
                                      text: "    let modern\(index) = compute(entry: \(index), profile: .fast)",
                                      newLineNumber: newLine))
                newLine += 1
                added += 1
            default:
                lines.append(DiffLine(style: .context,
                                      text: "    // stable statement \(index)",
                                      oldLineNumber: oldLine,
                                      newLineNumber: newLine))
                oldLine += 1
                newLine += 1
            }
        }
        return FileDiff(
            id: change.id,
            path: change.path,
            previousPath: change.previousPath,
            kind: change.kind,
            lines: lines,
            linesAdded: added,
            linesRemoved: removed,
            capturedAt: change.timestamp,
            // 示例 diff 里有 removed 行 ⇒ 预览也得给一个「比得上」的来历，否则面板会
            // 在旁边挂一句「首次观测到该文件，无改前版本可比」，自相矛盾。
            baselineSource: change.kind == .created ? .unavailableFirstSighting : .lastObserved,
            baselineCapturedAt: change.kind == .created
                ? nil
                : change.timestamp.addingTimeInterval(-3 * 60 * 60)
        )
    }

    // MARK: - ObservatoryControlling（Preview：无真实副作用）

    func start() async {}
    func stop() async {}
    func rescanNow() async {}

    /// Preview 场景下确认动作不做持久化，仅避免 crash（样本数据不可变）。
    func acknowledgeRiskEvent(id: UUID) async throws {}

    /// Preview 场景下设置不落盘：样本运行时只为渲染服务。
    func updateSettings(_ settings: ObservatorySettings) async {}

    // MARK: - ObservatoryEventStreaming

    /// 立即 finish 的空流：避免 Preview 空转消费。
    func makeUpdateStream() -> AsyncStream<ObservatoryUpdate> {
        AsyncStream { continuation in
            continuation.finish()
        }
    }

    func currentState() async -> EngineState { .running }

    // MARK: - ObservatoryService

    func dashboardStats(for date: Date) async throws -> DashboardStats {
        computeStats(for: date)
    }

    func activeAgents() async throws -> [AgentInstance] {
        samples.agents.filter { $0.state == .running || $0.state == .idle }
    }

    func sessions(matching query: SessionQuery) async throws -> Page<AgentSession> {
        var results = samples.sessions.filter { session in
            guard query.dateRange.contains(session.startedAt) else { return false }
            if !query.agentKinds.isEmpty, !query.agentKinds.contains(session.kind) { return false }
            if !query.outcomes.isEmpty, !query.outcomes.contains(session.outcome) { return false }
            if let project = query.projectPath, session.projectPath != project { return false }
            if !query.searchText.isEmpty {
                let needle = query.searchText.lowercased()
                let haystack = "\(session.title) \(session.projectPath ?? "") \(session.kind.displayName)".lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
        results.sort { query.sort.descending ? $0.startedAt > $1.startedAt : $0.startedAt < $1.startedAt }
        return page(from: results, offset: query.offset, limit: query.limit)
    }

    func session(id: UUID) async throws -> AgentSession? {
        samples.sessions.first { $0.id == id }
    }

    func events(matching query: EventQuery) async throws -> Page<TimelineEvent> {
        var results = samples.events.filter { event in
            guard query.dateRange.contains(event.timestamp) else { return false }
            if !query.kinds.isEmpty, !query.kinds.contains(event.kind) { return false }
            if !query.agentKinds.isEmpty, !query.agentKinds.contains(event.agentKind) { return false }
            if let sessionID = query.sessionID, event.sessionID != sessionID { return false }
            if let project = query.projectPath, event.projectPath != project { return false }
            if event.riskLevel < query.minimumRisk { return false }
            if !query.searchText.isEmpty {
                let needle = query.searchText.lowercased()
                let haystack = "\(event.title) \(event.summary) \(event.filePath ?? "") \(event.command ?? "")".lowercased()
                if !haystack.contains(needle) { return false }
            }
            return true
        }
        results.sort { query.sort.descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
        return page(from: results, offset: query.offset, limit: query.limit)
    }

    func fileChanges(matching query: FileChangeQuery) async throws -> Page<FileChange> {
        var results = samples.fileChanges.filter { change in
            guard query.dateRange.contains(change.timestamp) else { return false }
            if !query.kinds.isEmpty, !query.kinds.contains(change.kind) { return false }
            if !query.agentKinds.isEmpty, !query.agentKinds.contains(change.agentKind) { return false }
            if let sessionID = query.sessionID, change.sessionID != sessionID { return false }
            if let project = query.projectPath, change.projectPath != project { return false }
            if let prefix = query.pathPrefix, !change.path.hasPrefix(prefix) { return false }
            if !query.searchText.isEmpty, !change.path.lowercased().contains(query.searchText.lowercased()) { return false }
            return true
        }
        results.sort { query.sort.descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
        return page(from: results, offset: query.offset, limit: query.limit)
    }

    func fileDiff(for changeID: UUID) async throws -> FileDiff? {
        samples.diffs[changeID]
    }

    func commands(matching query: CommandQuery) async throws -> Page<CommandRecord> {
        var results = samples.commands.filter { record in
            guard query.dateRange.contains(record.startedAt) else { return false }
            if !query.agentKinds.isEmpty, !query.agentKinds.contains(record.agentKind) { return false }
            if let sessionID = query.sessionID, record.sessionID != sessionID { return false }
            if !query.outcomes.isEmpty, !query.outcomes.contains(record.outcome) { return false }
            if query.destructiveOnly, !record.isDestructive { return false }
            if !query.searchText.isEmpty, !record.commandLine.lowercased().contains(query.searchText.lowercased()) { return false }
            return true
        }
        results.sort { query.sort.descending ? $0.startedAt > $1.startedAt : $0.startedAt < $1.startedAt }
        return page(from: results, offset: query.offset, limit: query.limit)
    }

    func performanceSamples(sessionID: UUID) async throws -> [PerformanceSample] {
        samples.performance.filter { $0.sessionID == sessionID }.sorted { $0.timestamp < $1.timestamp }
    }

    func systemPerformance(since date: Date) async throws -> [SystemPerformanceSample] {
        samples.systemPerformance.filter { $0.timestamp >= date }.sorted { $0.timestamp < $1.timestamp }
    }

    func riskEvents(matching query: RiskQuery) async throws -> Page<RiskEvent> {
        var results = samples.risks.filter { risk in
            guard query.dateRange.contains(risk.timestamp) else { return false }
            if !query.levels.isEmpty, !query.levels.contains(risk.level) { return false }
            if !query.categories.isEmpty, !query.categories.contains(risk.category) { return false }
            if !query.agentKinds.isEmpty, !query.agentKinds.contains(risk.agentKind) { return false }
            if let sessionID = query.sessionID, risk.sessionID != sessionID { return false }
            if query.unacknowledgedOnly, risk.isAcknowledged { return false }
            if !query.searchText.isEmpty {
                let needle = query.searchText.lowercased()
                if !"\(risk.title) \(risk.detail) \(risk.command ?? "")".lowercased().contains(needle) { return false }
            }
            return true
        }
        results.sort { query.sort.descending ? $0.timestamp > $1.timestamp : $0.timestamp < $1.timestamp }
        return page(from: results, offset: query.offset, limit: query.limit)
    }

    func projects() async throws -> [ProjectActivity] {
        samples.projects.sorted { $0.lastSeenAt > $1.lastSeenAt }
    }

    func projectActivity(path: String, dateRange: DateRangeFilter) async throws -> ProjectActivity? {
        guard var project = samples.projects.first(where: { $0.path == path }) else { return nil }
        let changes = samples.fileChanges.filter { $0.projectPath == path && dateRange.contains($0.timestamp) }
        let projectCommands = samples.commands.filter { $0.projectPath == path && dateRange.contains($0.startedAt) }
        project.fileChangeCount = changes.count
        project.commandCount = projectCommands.count
        project.codeGrowthLines = changes.reduce(0) { $0 + $1.linesAdded }
        project.codeShrinkLines = changes.reduce(0) { $0 + $1.linesRemoved }
        return project
    }

    // MARK: - Helpers

    private func page<Element>(from items: [Element], offset: Int, limit: Int) -> Page<Element> where Element: Sendable & Codable {
        let total = items.count
        let window = Array(items.dropFirst(max(offset, 0)).prefix(max(limit, 0)))
        return Page(items: window, totalCount: total, offset: offset)
    }

    /// Dashboard 统计从上方样本现场聚合，保证与列表数据自洽。
    private func computeStats(for date: Date) -> DashboardStats {
        let range = DateRangeFilter.today(date)
        let daySessions = samples.sessions.filter { range.contains($0.startedAt) }
        let dayEvents = samples.events.filter { range.contains($0.timestamp) }
        let dayFiles = samples.fileChanges.filter { range.contains($0.timestamp) }
        let dayCommands = samples.commands.filter { range.contains($0.startedAt) }
        let dayRisks = samples.risks.filter { range.contains($0.timestamp) }
        let dayPerformance = samples.performance.filter { range.contains($0.timestamp) }

        var buckets: [Int: (count: Int, cpu: Double, n: Int)] = [:]
        let calendar = Calendar.current
        for event in dayEvents {
            let hour = calendar.component(.hour, from: event.timestamp)
            var bucket = buckets[hour] ?? (0, 0, 0)
            bucket.count += 1
            buckets[hour] = bucket
        }
        for sample in dayPerformance {
            let hour = calendar.component(.hour, from: sample.timestamp)
            var bucket = buckets[hour] ?? (0, 0, 0)
            bucket.cpu += sample.cpuPercent
            bucket.n += 1
            buckets[hour] = bucket
        }
        let hourly = (0..<24).map { hour -> HourlyActivity in
            let bucket = buckets[hour]
            let sampleCount = bucket?.n ?? 0
            let cpuTotal = bucket?.cpu ?? 0
            return HourlyActivity(hour: hour,
                                  eventCount: bucket?.count ?? 0,
                                  cpuAverage: sampleCount > 0 ? cpuTotal / Double(sampleCount) : 0)
        }
        let shares = AgentKind.allCases.compactMap { kind -> AgentUsageShare? in
            let matched = daySessions.filter { $0.kind == kind }
            guard !matched.isEmpty else { return nil }
            return AgentUsageShare(kind: kind,
                                   sessionCount: matched.count,
                                   totalSeconds: matched.reduce(0) { $0 + $1.duration })
        }
        return DashboardStats(
            date: date,
            sessionCount: daySessions.count,
            totalActiveSeconds: daySessions.reduce(0.0) { $0 + $1.duration },
            filesModified: dayFiles.filter { $0.kind == .modified }.count,
            filesCreated: dayFiles.filter { $0.kind == .created }.count,
            filesDeleted: dayFiles.filter { $0.kind == .deleted }.count,
            commandsExecuted: dayCommands.count,
            failedCommands: dayCommands.filter { $0.outcome == .failure }.count,
            riskEventCount: dayRisks.count,
            highRiskEventCount: dayRisks.filter { $0.level >= .high }.count,
            averageCPUPercent: dayPerformance.isEmpty ? 0
                : dayPerformance.reduce(0) { $0 + $1.cpuPercent } / Double(dayPerformance.count),
            peakCPUPercent: dayPerformance.map(\.cpuPercent).max() ?? 0,
            peakMemoryBytes: dayPerformance.map(\.memoryBytes).max() ?? 0,
            activeAgentCount: samples.agents.filter { $0.state == .running }.count,
            hourlyActivity: hourly,
            agentShares: shares
        )
    }
}

// MARK: - Preview entry point

/// `#Preview` 唯一入口。生产路径（App / Engine 装配）禁止使用。
enum ObservatoryPreview {

    /// 有样本数据的运行时：agents / sessions / events / fileChanges / diffs / commands /
    /// performance / systemPerformance / risks / projects 全部非空。
    static func runtime(now: Date = Date()) -> ObservatoryRuntime {
        ObservatoryRuntime.makePreview(now: now)
    }

    /// 全空运行时：用于验证每个板块的空状态（禁止白屏）。
    static func emptyRuntime(now: Date = Date()) -> ObservatoryRuntime {
        ObservatoryRuntime.makePreview(now: now, empty: true)
    }

    /// 把一个板块入口视图包进真实的 Shell 环境（含 `ShellModel` 与窗口最小尺寸）。
    @MainActor
    static func screen<V: View>(
        empty: Bool = false,
        now: Date = Date(),
        @ViewBuilder _ content: (ObservatoryRuntime) -> V
    ) -> some View {
        let runtime = empty ? emptyRuntime(now: now) : runtime(now: now)
        return content(runtime)
            .environment(ShellModel(runtime: runtime))
            .frame(minWidth: 1_080, minHeight: 720)
    }
}

extension ObservatoryRuntime {
    /// 装配一个仅用于 Preview 的运行时（service / controller / updates 指向同一个样本服务）。
    fileprivate static func makePreview(now: Date = Date(), empty: Bool = false) -> ObservatoryRuntime {
        let service = ObservatoryPreviewService(now: now, empty: empty)
        return ObservatoryRuntime(
            service: service,
            controller: service,
            updates: service,
            settings: .default
        )
    }
}
