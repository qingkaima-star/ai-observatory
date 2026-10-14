//
//  SampleData.swift
//  AIObservatoryTestSupport
//
//  Owner: master-controller（冻结）
//
//  确定性样本数据工厂：给 WS-UI 的 Preview 和所有单测用。
//  使用固定种子的 SplitMix64，保证每次生成的数据完全一致（便于截图对比与快照测试）。
//

import Foundation
import AIObservatoryCore

// MARK: - Deterministic RNG

public struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    public init(seed: UInt64 = 0xA1B05E5E) {
        self.state = seed == 0 ? 0x9E3779B97F4A7C15 : seed
    }

    public mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    public mutating func int(in range: ClosedRange<Int>) -> Int {
        let span = UInt64(range.upperBound - range.lowerBound + 1)
        return range.lowerBound + Int(next() % span)
    }

    public mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() % 10_000) / 10_000.0
        return range.lowerBound + unit * (range.upperBound - range.lowerBound)
    }

    public mutating func pick<T>(_ values: [T]) -> T {
        values[int(in: 0...(values.count - 1))]
    }

    public mutating func bool(probability: Double = 0.5) -> Bool {
        double(in: 0...1) < probability
    }
}

// MARK: - Sample Data

public enum SampleData {

    public static let demoProjectPaths: [String] = [
        "/Users/demo/Projects/Mona",
        "/Users/demo/Projects/Aurora"
    ]

    /// 生成一整套演示数据并注入内存服务。
    public static func demoService(
        now: Date = Date(),
        seed: UInt64 = 0xA1B05E5E,
        sessionCount: Int = 12
    ) -> InMemoryObservatoryService {
        var rng = SeededRandom(seed: seed)
        let service = InMemoryObservatoryService()

        let calendar = Calendar.current
        let dayStart = calendar.startOfDay(for: now)

        var agents: [AgentInstance] = []
        let runningKinds: [AgentKind] = [.claudeCode, .cursorAgent]
        let allKinds: [AgentKind] = [.claudeCode, .openAICodex, .cursorAgent, .vscodeCopilot, .windsurf, .genericCLIAgent]

        for (index, kind) in runningKinds.enumerated() {
            let started = now.addingTimeInterval(-Double(rng.int(in: 1_800...8_000)))
            agents.append(AgentInstance(
                kind: kind,
                pid: Int32(10_000 + index * 977),
                parentPID: 1,
                displayName: kind.displayName,
                executablePath: "/usr/local/bin/\(kind.rawValue)",
                workingDirectory: demoProjectPaths[index % demoProjectPaths.count],
                bundleIdentifier: nil,
                tty: "ttys00\(index)",
                startedAt: started,
                state: .running,
                cpuPercent: rng.double(in: 2...48),
                memoryBytes: UInt64(rng.int(in: 220...2_600)) * 1_048_576,
                childPIDs: [Int32(20_000 + index)],
                detectedVia: index == 0 ? .executablePath : .bundleIdentifier
            ))
        }

        var sessions: [AgentSession] = []
        var events: [TimelineEvent] = []
        var fileChanges: [FileChange] = []
        var diffs: [FileDiff] = []
        var commands: [CommandRecord] = []
        var performance: [PerformanceSample] = []

        let fileNames = ["API.swift", "UserService.swift", "README.md", "Package.swift", "Config.json", "Router.swift", "Model.swift", "Tests.swift", "AppDelegate.swift", "ViewModel.swift"]
        let commandTemplates: [(String, [String])] = [
            ("npm", ["test"]),
            ("git", ["status"]),
            ("git", ["commit", "-m", "feat: update"]),
            ("swift", ["build"]),
            ("docker", ["compose", "up"]),
            ("python", ["train.py"]),
            ("rm", ["-rf", "./build"]),
            ("git", ["push", "origin", "main"])
        ]

        for index in 0..<sessionCount {
            let kind = rng.pick(allKinds)
            let project = rng.pick(demoProjectPaths)
            // 演示会话排在「工作时段 09:00–20:00」，但必须同时满足两条：
            //   1) 落在 `now` 所在的那一天内 —— Dashboard 按天统计，跨天会被算成 0 场；
            //   2) 不早于 `now` —— 否则 totalActiveSeconds 会变成负数。
            // 凌晨运行时今天的可用窗口很短甚至接近零，此时退化为在窗口内均匀分布。
            let dayWindowSeconds = max(0, Int(now.timeIntervalSince(dayStart)))
            let latestStart = max(0, dayWindowSeconds - 60)
            let earliestStart = min(9 * 3600, latestStart)
            let startedAt = dayStart.addingTimeInterval(Double(rng.int(in: earliestStart...latestStart)))
            let duration = Double(rng.int(in: 600...9_000))
            let endedAt = index < sessionCount - 2
                ? min(startedAt.addingTimeInterval(duration), now)
                : nil

            let sessionID = UUID()
            let agentID = agents.first(where: { $0.kind == kind })?.id

            let modified = rng.int(in: 4...62)
            let created = rng.int(in: 0...18)
            let deleted = rng.int(in: 0...4)
            let commandCount = rng.int(in: 2...24)
            let riskCount = index % 4 == 0 ? rng.int(in: 0...2) : 0

            sessions.append(AgentSession(
                id: sessionID,
                displayIndex: 100 + index,
                kind: kind,
                agentID: agentID,
                title: "\(kind.displayName) · \((project as NSString).lastPathComponent)",
                projectPath: project,
                startedAt: startedAt,
                endedAt: endedAt,
                modifiedFileCount: modified,
                createdFileCount: created,
                deletedFileCount: deleted,
                commandCount: commandCount,
                failedCommandCount: rng.int(in: 0...3),
                cpuSeconds: duration * rng.double(in: 0.05...0.35),
                peakCPUPercent: rng.double(in: 35...92),
                peakMemoryBytes: UInt64(rng.int(in: 400...3_200)) * 1_048_576,
                estimatedTokens: rng.int(in: 4_000...240_000),
                riskEventCount: riskCount,
                outcome: endedAt == nil ? .running : (rng.bool(probability: 0.82) ? .success : .failed)
            ))

            // 事件
            var cursor = startedAt
            for _ in 0..<rng.int(in: 6...26) {
                cursor = cursor.addingTimeInterval(Double(rng.int(in: 20...600)))
                guard cursor <= (endedAt ?? now) else { break }
                let kindRoll = rng.double(in: 0...1)
                let fileName = rng.pick(fileNames)
                let path = "\(project)/Sources/\(fileName)"
                switch kindRoll {
                case ..<0.42:
                    events.append(TimelineEvent(
                        timestamp: cursor, sessionID: sessionID, agentID: agentID,
                        agentKind: kind, kind: .fileModified,
                        title: "修改 \(fileName)", summary: path, filePath: path,
                        cost: ResourceCost(cpuSeconds: rng.double(in: 0.05...1.4), memoryBytes: UInt64(rng.int(in: 5...80)) * 1_048_576,
                                           bytesRead: UInt64(rng.int(in: 1_000...900_000)), bytesWritten: UInt64(rng.int(in: 200...200_000))),
                        projectPath: project
                    ))
                    fileChanges.append(FileChange(
                        path: path, kind: .modified, timestamp: cursor, sessionID: sessionID,
                        agentKind: kind, sizeBytes: UInt64(rng.int(in: 800...180_000)),
                        previousSizeBytes: UInt64(rng.int(in: 800...180_000)),
                        linesAdded: rng.int(in: 1...90), linesRemoved: rng.int(in: 0...40),
                        projectPath: project
                    ))
                case ..<0.58:
                    events.append(TimelineEvent(
                        timestamp: cursor, sessionID: sessionID, agentID: agentID,
                        agentKind: kind, kind: .fileCreated,
                        title: "创建 \(fileName)", summary: path, filePath: path,
                        projectPath: project
                    ))
                    fileChanges.append(FileChange(
                        path: path, kind: .created, timestamp: cursor, sessionID: sessionID,
                        agentKind: kind, sizeBytes: UInt64(rng.int(in: 200...40_000)),
                        linesAdded: rng.int(in: 3...120),
                        projectPath: project
                    ))
                case ..<0.86:
                    let template = rng.pick(commandTemplates)
                    let exit: Int32 = rng.bool(probability: 0.82) ? 0 : 1
                    events.append(TimelineEvent(
                        timestamp: cursor, sessionID: sessionID, agentID: agentID,
                        agentKind: kind, kind: .commandExecuted,
                        title: "执行 \(template.0) \(template.1.joined(separator: " "))",
                        summary: "exit \(exit)", command: ([template.0] + template.1).joined(separator: " "),
                        exitCode: exit, durationSeconds: rng.double(in: 0.4...42),
                        projectPath: project
                    ))
                    commands.append(CommandRecord(
                        executable: template.0, arguments: template.1, workingDirectory: project,
                        sessionID: sessionID, agentKind: kind,
                        startedAt: cursor, endedAt: cursor.addingTimeInterval(rng.double(in: 0.4...42)),
                        exitCode: exit, outcome: exit == 0 ? .success : .failure,
                        isDestructive: template.0 == "rm",
                        requiresConfirmation: template.0 == "rm",
                        riskLevel: template.0 == "rm" ? .high : .low,
                        projectPath: project
                    ))
                default:
                    events.append(TimelineEvent(
                        timestamp: cursor, sessionID: sessionID, agentID: agentID,
                        agentKind: kind, kind: .gitOperation,
                        title: "Git 操作", summary: "commit", command: "git commit",
                        projectPath: project
                    ))
                }
            }

            // 会话性能采样
            var sampleTime = startedAt
            while sampleTime <= (endedAt ?? min(now, startedAt.addingTimeInterval(3_600))) {
                performance.append(PerformanceSample(
                    timestamp: sampleTime, sessionID: sessionID, agentID: agentID,
                    cpuPercent: rng.double(in: 4...88),
                    memoryBytes: UInt64(rng.int(in: 300...2_800)) * 1_048_576,
                    gpuPercent: rng.bool(probability: 0.4) ? rng.double(in: 0...35) : nil,
                    diskReadBytesPerSecond: rng.double(in: 0...180_000_000),
                    diskWriteBytesPerSecond: rng.double(in: 0...90_000_000),
                    networkBytesIn: UInt64(rng.int(in: 0...40_000_000)),
                    networkBytesOut: UInt64(rng.int(in: 0...12_000_000)),
                    thermalCelsius: rng.double(in: 42...78),
                    powerWatts: rng.double(in: 4...22)
                ))
                sampleTime = sampleTime.addingTimeInterval(60)
            }
        }

        // 为前若干文件变更生成 diff
        for change in fileChanges.prefix(12) {
            diffs.append(makeSampleDiff(for: change, textLength: 24))
        }

        // 整机性能：最近 6 小时，每 5 分钟一个点
        var systemPerf: [SystemPerformanceSample] = []
        var t = now.addingTimeInterval(-6 * 3600)
        while t <= now {
            systemPerf.append(SystemPerformanceSample(
                timestamp: t,
                cpuTotalPercent: rng.double(in: 3...62),
                cpuSystemPercent: rng.double(in: 1...18),
                cpuUserPercent: rng.double(in: 2...44),
                memoryUsedBytes: UInt64(rng.int(in: 8...22)) * 1_073_741_824,
                memoryTotalBytes: 32 * 1_073_741_824,
                diskReadBytesPerSecond: rng.double(in: 0...220_000_000),
                diskWriteBytesPerSecond: rng.double(in: 0...120_000_000),
                loadAverage1m: rng.double(in: 0.4...7.2),
                thermalCelsius: rng.double(in: 44...72),
                powerWatts: rng.double(in: 6...28)
            ))
            t = t.addingTimeInterval(300)
        }

        // 风险事件
        // ⚠️ 时间戳必须落在**当天**：`dashboardStats` 按本地日历天算「今日」，
        // 而这里原先写死 `now - 1500` / `now - 3600` ⇒ 本地刚过午夜（00:00–01:00）
        // 时全部掉到昨天，`riskEventCount` 变 0，`CoreContractTests` 的
        // 「Dashboard 统计字段自洽」就红——2026-09-21 00:09 实测复现。
        // 上一轮只修过会话的同类问题（固定 09:00–20:00 区间），风险这一支漏了。
        let startOfToday = Calendar.current.startOfDay(for: now)
        func withinToday(_ seconds: TimeInterval) -> Date {
            max(startOfToday.addingTimeInterval(60), now.addingTimeInterval(-seconds))
        }
        var risks: [RiskEvent] = [
            RiskEvent(
                timestamp: withinToday(1_500), level: .high, category: .dangerousCommand,
                title: "Agent 执行了高风险删除命令",
                detail: "命令 rm -rf ./build 命中破坏性规则 R-004，且工作目录位于用户项目内。",
                agentKind: .claudeCode, sessionID: sessions.first?.id,
                command: "rm -rf ./build", filePaths: ["/Users/demo/Projects/Mona/build"],
                requiresConfirmation: true, matchedRuleID: "R-004"
            ),
            RiskEvent(
                timestamp: withinToday(3_600), level: .medium, category: .sensitivePathAccess,
                title: "写入 ~/.config 目录",
                detail: "Agent 修改了用户配置目录下的文件，属于敏感路径。",
                agentKind: .cursorAgent, sessionID: sessions.dropFirst().first?.id,
                filePaths: ["\(NSHomeDirectory())/.config/demo/settings.json"],
                matchedRuleID: "R-011"
            ),
            RiskEvent(
                timestamp: withinToday(7_200), level: .critical, category: .massDeletion,
                title: "疑似批量删除",
                detail: "同一分钟内删除 42 个文件，超过阈值 20。",
                agentKind: .genericCLIAgent, sessionID: sessions.dropFirst(2).first?.id,
                requiresConfirmation: true, matchedRuleID: "R-001"
            )
        ]
        risks.sort { $0.timestamp > $1.timestamp }

        // 项目活动地图
        var projects: [ProjectActivity] = []
        for path in demoProjectPaths {
            let projectChanges = fileChanges.filter { $0.projectPath == path }
            let projectCommands = commands.filter { $0.projectPath == path }
            let projectSessions = sessions.filter { $0.projectPath == path }
            var heat: [String: Int] = [:]
            for change in projectChanges { heat[change.path, default: 0] += 1 }
            let hotFiles = heat.map { entry in
                FileHeat(
                    path: entry.key,
                    changeCount: entry.value,
                    linesAdded: projectChanges.filter { $0.path == entry.key }.reduce(0) { $0 + $1.linesAdded },
                    linesRemoved: projectChanges.filter { $0.path == entry.key }.reduce(0) { $0 + $1.linesRemoved },
                    lastTouchedAt: projectChanges.filter { $0.path == entry.key }.map(\.timestamp).max() ?? now
                )
            }.sorted { $0.changeCount > $1.changeCount }

            var contributions: [AgentContribution] = []
            let total = max(1, projectChanges.count)
            for kind in allKinds {
                let count = projectChanges.filter { $0.agentKind == kind }.count
                if count > 0 {
                    contributions.append(AgentContribution(kind: kind, relativeShare: Double(count) / Double(total), eventCount: count))
                }
            }

            projects.append(ProjectActivity(
                id: path, name: (path as NSString).lastPathComponent, path: path,
                fileChangeCount: projectChanges.count,
                commandCount: projectCommands.count,
                sessionCount: projectSessions.count,
                riskEventCount: risks.filter { ($0.filePaths.first ?? "").hasPrefix(path) }.count,
                codeGrowthLines: projectChanges.reduce(0) { $0 + $1.linesAdded },
                codeShrinkLines: projectChanges.reduce(0) { $0 + $1.linesRemoved },
                agentContributions: contributions.sorted { $0.eventCount > $1.eventCount },
                hotFiles: Array(hotFiles.prefix(12)),
                firstSeenAt: sessions.map(\.startedAt).min() ?? now,
                lastSeenAt: projectChanges.map(\.timestamp).max() ?? now
            ))
        }

        service.seed(
            agents: agents, sessions: sessions, events: events.sorted { $0.timestamp < $1.timestamp },
            fileChanges: fileChanges, diffs: diffs, commands: commands,
            performance: performance, systemPerformance: systemPerf,
            risks: risks, projects: projects
        )
        return service
    }

    /// 构造一个带增删行的示例 diff。
    public static func makeSampleDiff(for change: FileChange, textLength: Int = 20) -> FileDiff {
        var lines: [DiffLine] = []
        var added = 0, removed = 0
        lines.append(DiffLine(style: .hunkHeader, text: "@@ -1,\(textLength) +1,\(textLength + 4) @@"))
        for index in 1...textLength {
            let roll = index % 5
            if roll == 0 {
                lines.append(DiffLine(style: .removed, text: "    let legacyValue\(index) = compute(\(index))", oldLineNumber: index))
                removed += 1
            } else if roll == 1 {
                lines.append(DiffLine(style: .added, text: "    let modernValue\(index) = compute(\(index), profile: .fast)", newLineNumber: index))
                added += 1
            } else {
                lines.append(DiffLine(style: .context, text: "    // existing statement \(index)", oldLineNumber: index, newLineNumber: index))
            }
        }
        return FileDiff(
            id: change.id, path: change.path, previousPath: change.previousPath,
            kind: change.kind, lines: lines, linesAdded: added, linesRemoved: removed
        )
    }

    /// 供 SwiftUI Preview 使用的一站式运行时。
    public static func previewRuntime(
        now: Date = Date(),
        withEmptyState: Bool = false
    ) -> ObservatoryRuntime {
        let service = withEmptyState ? InMemoryObservatoryService() : demoService(now: now)
        return ObservatoryRuntime(service: service, controller: service, updates: service, settings: .default)
    }
}
