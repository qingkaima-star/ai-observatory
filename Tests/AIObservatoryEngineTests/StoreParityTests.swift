//
//  StoreParityTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Engine（绝对真值改造：WS-Asserts）
//
//  这里原本 18 个用例**全部**是 parity-only：同一批 fixture 喂给 SQLite Store 与
//  冻结参考实现 `InMemoryObservatoryService`，逐条比「两边相等」。那种断言的证据力是零——
//  两个实现同时错（例如都按 rawValue 字典序比风险等级、都把 NULL 读成 0）它照样全绿。
//
//  现在的分工：
//    · `StorePageParityTests`（含一条 clock-relative）= 只证「换后端不改行为」这条需求；
//    · `StoreQueryTruthTests` = 81 条查询各自的 (页内身份序列, totalCount, hasMore) 手算期望；
//    · `StoreValueTruthTests` / `StoreDashboardTruthTests` / `StoreOrderingTruthTests`
//      = 字段级、统计口径级、排序分页级的手算绝对值，含 NULL / nil / 真 0 三态不互相塌缩。
//
//  每个查询族的手算期望表集中在 `ParityFixture.expected*Pages`，按 fixture 逐条算出，
//  **不从任何一侧实现读回**。新增查询而不补期望值会直接 `#require` 失败。
//

import Testing
import Foundation
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

// MARK: - Fixture

/// 共享样本。时间戳全部从「今天已经过的秒数」按比例推出，因此：
/// ① 一定落在 `DateRangeFilter.today(now)` 窗口内；② 一定不晚于 now（避免出现负时长）；
/// ③ 与本地钟点无关（午夜刚过也不会抖动）。
private enum ParityFixture {
    static let now = Date()
    static let dayStart = Calendar.current.startOfDay(for: now)
    /// 今天在 now 之前已经过的秒数（至少 5 分钟，保证有可分桶的时间跨度）。
    static let elapsed = max(300, now.timeIntervalSince(dayStart))

    /// 今天窗口内、且不晚于 now 的时刻。`fraction` ∈ (0, 1)。
    static func today(_ fraction: Double) -> Date {
        dayStart.addingTimeInterval(elapsed * fraction)
    }

    /// `days` 天前同一比例时刻（用于 dateRange 与保留期负例）。
    static func daysAgo(_ days: Int, _ fraction: Double) -> Date {
        today(fraction).addingTimeInterval(-Double(days) * 86_400)
    }

    // MARK: 标识

    static let agentClaude = UUID()
    static let agentCodex = UUID()
    static let agentCursor = UUID()
    static let agentWindsurf = UUID()
    static let sessionA = UUID()
    static let sessionB = UUID()
    static let sessionC = UUID()
    static let sessionRunning = UUID()
    static let sessionFailed = UUID()
    static let projectOne = FixturePaths.projectAlpha
    static let projectTwo = FixturePaths.projectBeta
    static let changeText = UUID()
    static let changeBinary = UUID()
    /// 「库里根本没有的会话 id」。原来查询集里直接写 `EventQuery(sessionID: UUID())`，
    /// 每次取列表都换一个随机值 ⇒ 既不能被当作字典键配期望值，也无法复现失败。
    static let orphanSessionID = UUID()

    // MARK: 数据

    static let agents: [AgentInstance] = {
        [
            AgentInstance(id: agentClaude, kind: .claudeCode, pid: 4001, displayName: "Claude Code",
                          executablePath: "/usr/local/bin/claude", workingDirectory: projectOne,
                          tty: "ttys001", startedAt: today(0.2), lastSeenAt: today(0.9), state: .running,
                          cpuPercent: 37.5, memoryBytes: 812 * 1024 * 1024, childPIDs: [4002, 4003],
                          detectedVia: .executablePath),
            AgentInstance(id: agentCodex, kind: .openAICodex, pid: 4101, parentPID: 1,
                          displayName: "OpenAI Codex CLI", executablePath: "/usr/local/bin/codex",
                          workingDirectory: projectTwo, bundleIdentifier: nil, tty: "ttys002",
                          startedAt: today(0.3), lastSeenAt: today(0.85), state: .running,
                          cpuPercent: 12.25, memoryBytes: UInt64(Int64.max) + 1, childPIDs: [],
                          detectedVia: .argumentSignature),
            AgentInstance(id: agentCursor, kind: .cursorAgent, pid: 4201, displayName: "Cursor Agent",
                          executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                          workingDirectory: nil, bundleIdentifier: "com.todesktop.cursor",
                          startedAt: today(0.1), lastSeenAt: today(0.6), state: .idle,
                          cpuPercent: 3, memoryBytes: 1024, childPIDs: [4202], detectedVia: .bundleIdentifier),
            AgentInstance(id: agentWindsurf, kind: .windsurf, pid: 4301, displayName: "Windsurf",
                          executablePath: "/Applications/Windsurf.app/Contents/MacOS/Windsurf",
                          startedAt: daysAgo(2, 0.4), lastSeenAt: daysAgo(2, 0.7), state: .terminated,
                          detectedVia: .processName),
        ]
    }()

    static let sessions: [AgentSession] = {
        [
            AgentSession(id: sessionA, displayIndex: 101, kind: .claudeCode, agentID: agentClaude,
                         title: "Claude Code · Alpha", projectPath: projectOne,
                         startedAt: today(0.2), endedAt: today(0.55),
                         modifiedFileCount: 12, createdFileCount: 3, deletedFileCount: 1,
                         commandCount: 9, failedCommandCount: 2, cpuSeconds: 420.5,
                         peakCPUPercent: 88.25, peakMemoryBytes: 900 * 1024 * 1024,
                         estimatedTokens: 18_400, riskEventCount: 2, outcome: .success),
            AgentSession(id: sessionB, displayIndex: 102, kind: .openAICodex, agentID: agentCodex,
                         title: "Codex · Beta", projectPath: projectTwo,
                         startedAt: today(0.3), endedAt: today(0.8),
                         modifiedFileCount: 5, createdFileCount: 0, deletedFileCount: 4,
                         commandCount: 14, failedCommandCount: 0, cpuSeconds: 88.125,
                         peakCPUPercent: 41.5, peakMemoryBytes: 512 * 1024 * 1024,
                         estimatedTokens: 7_200, riskEventCount: 1, outcome: .failed),
            AgentSession(id: sessionC, displayIndex: 103, kind: .cursorAgent, agentID: agentCursor,
                         title: "Cursor · Alpha 重构", projectPath: projectOne,
                         startedAt: daysAgo(1, 0.25), endedAt: daysAgo(1, 0.5),
                         modifiedFileCount: 30, createdFileCount: 8, deletedFileCount: 0,
                         commandCount: 3, failedCommandCount: 1, cpuSeconds: 1_500,
                         peakCPUPercent: 99.9, peakMemoryBytes: 4 * 1024 * 1024 * 1024,
                         // 声明值 == 本文件里挂在 sessionC 名下的风险行数（1）。
                         // 原来写 0 只有在「整行 upsert 会把派生值盖掉」时才成立，那正是 #35。
                         estimatedTokens: 51_000, riskEventCount: 1, outcome: .interrupted),
            AgentSession(id: sessionRunning, displayIndex: 104, kind: .claudeCode, agentID: agentClaude,
                         title: "运行中的会话", projectPath: projectTwo,
                         startedAt: today(0.6), endedAt: nil,
                         modifiedFileCount: 2, commandCount: 1, outcome: .running),
            AgentSession(id: sessionFailed, displayIndex: 105, kind: .geminiCLI,
                         title: "Gemini · 无项目", projectPath: nil,
                         startedAt: daysAgo(4, 0.2), endedAt: daysAgo(4, 0.3),
                         commandCount: 2, failedCommandCount: 2, outcome: .failed),
        ]
    }()

    /// 混合风险等级（含 `critical`/`low` 以便验证按 rank 过滤）、大小写与中文搜索串。
    static let events: [TimelineEvent] = {
        [
            TimelineEvent(timestamp: today(0.21), sessionID: sessionA, agentID: agentClaude,
                          agentKind: .claudeCode, kind: .agentStarted, title: "Agent 启动 · Claude Code",
                          summary: "pid 4001 · 识别依据：可执行文件路径", projectPath: projectOne),
            TimelineEvent(timestamp: today(0.24), sessionID: sessionA, agentID: agentClaude,
                          agentKind: .claudeCode, kind: .fileModified, title: "修改文件 · AuthService.swift",
                          summary: "12 行新增", filePath: "\(projectOne)/Sources/AuthService.swift",
                          cost: ResourceCost(cpuSeconds: 1.5, memoryBytes: 2_048, bytesRead: 4_096, bytesWritten: 1_024),
                          riskLevel: .medium, projectPath: projectOne),
            TimelineEvent(timestamp: today(0.27), sessionID: sessionA, agentID: agentClaude,
                          agentKind: .claudeCode, kind: .commandExecuted, title: "swift test",
                          summary: "退出码 1", command: "swift test --filter Auth", exitCode: 1,
                          durationSeconds: 42.5, riskLevel: .high, projectPath: projectOne),
            TimelineEvent(timestamp: today(0.31), sessionID: sessionB, agentID: agentCodex,
                          agentKind: .openAICodex, kind: .fileDeleted, title: "删除文件 · 旧配置",
                          summary: "批量清理旧配置目录", filePath: "\(projectTwo)/config/legacy.json",
                          riskLevel: .critical, projectPath: projectTwo),
            TimelineEvent(timestamp: today(0.35), sessionID: sessionB, agentID: agentCodex,
                          agentKind: .openAICodex, kind: .gitOperation, title: "git push origin main",
                          summary: "推送", command: "git push origin main --force", riskLevel: .low,
                          projectPath: projectTwo),
            TimelineEvent(timestamp: today(0.4), sessionID: sessionA, agentID: agentClaude,
                          agentKind: .claudeCode, kind: .networkRequest, title: "Network POST",
                          summary: "上传构建产物到 ci.example.test", durationSeconds: 3.25,
                          riskLevel: .medium, projectPath: projectOne),
            TimelineEvent(timestamp: today(0.45), sessionID: sessionC, agentID: agentCursor,
                          agentKind: .cursorAgent, kind: .fileRenamed, title: "重命名 Router.swift",
                          summary: "Router.swift → LegacyRouter.swift", filePath: "\(projectOne)/Router.swift",
                          riskLevel: .low, projectPath: projectOne),
            TimelineEvent(timestamp: today(0.5), sessionID: nil, agentKind: .unknown, kind: .unknown,
                          title: "未归类行为", summary: "无会话归属", riskLevel: .low),
            TimelineEvent(timestamp: daysAgo(1, 0.3), sessionID: sessionC, agentID: agentCursor,
                          agentKind: .cursorAgent, kind: .systemModification, title: "修改 /etc/hosts",
                          summary: "系统文件写入 · 高风险", filePath: "/etc/hosts",
                          riskLevel: .high, projectPath: projectOne),
            TimelineEvent(timestamp: daysAgo(4, 0.22), sessionID: sessionFailed, agentKind: .geminiCLI,
                          kind: .riskDetected, title: "风险事件 · 危险命令", summary: "rm -rf ./build",
                          command: "rm -rf ./build", riskLevel: .critical, projectPath: nil),
        ]
    }()

    static let fileChanges: [FileChange] = {
        [
            FileChange(id: changeText, path: "\(projectOne)/Sources/AuthService.swift",
                       kind: .modified, timestamp: today(0.24), agentID: agentClaude, sessionID: sessionA,
                       agentKind: .claudeCode, sizeBytes: 4_096, previousSizeBytes: 3_800,
                       linesAdded: 12, linesRemoved: 3, riskLevel: .medium, projectPath: projectOne),
            FileChange(id: changeBinary, path: "\(projectOne)/Assets/logo.png",
                       kind: .created, timestamp: today(0.26), agentID: agentClaude, sessionID: sessionA,
                       agentKind: .claudeCode, sizeBytes: 88_000, isText: false,
                       riskLevel: .low, projectPath: projectOne),
            FileChange(path: "\(projectTwo)/CONFIG.OLD", previousPath: "\(projectTwo)/config.OLD",
                       kind: .renamed, timestamp: today(0.33), agentID: agentCodex, sessionID: sessionB,
                       agentKind: .openAICodex, sizeBytes: 128, projectPath: projectTwo),
            FileChange(path: "\(projectTwo)/config/legacy.json", kind: .deleted, timestamp: today(0.31),
                       agentID: agentCodex, sessionID: sessionB, agentKind: .openAICodex,
                       previousSizeBytes: 900, linesRemoved: 45, riskLevel: .critical, projectPath: projectTwo),
            FileChange(path: "\(projectTwo)/build/output.o", kind: .deleted, timestamp: today(0.32),
                       agentID: agentCodex, sessionID: sessionB, agentKind: .openAICodex,
                       isText: false, riskLevel: .medium, projectPath: projectTwo),
            FileChange(path: "\(projectOne)/README.md", kind: .created, timestamp: today(0.42),
                       agentID: agentClaude, sessionID: sessionA, agentKind: .claudeCode,
                       sizeBytes: 512, linesAdded: 24, projectPath: projectOne),
            FileChange(path: "/etc/hosts", kind: .modified, timestamp: daysAgo(1, 0.3),
                       agentID: agentCursor, sessionID: sessionC, agentKind: .cursorAgent,
                       sizeBytes: 200, linesAdded: 1, linesRemoved: 1, riskLevel: .high, projectPath: projectOne),
            FileChange(path: "\(projectOne)/Unknown.bin", kind: .unknown, timestamp: daysAgo(4, 0.25),
                       agentKind: .geminiCLI, isText: false, projectPath: nil),
        ]
    }()

    static let diffs: [FileDiff] = {
        [
            FileDiff(id: changeText,
                     path: "\(projectOne)/Sources/AuthService.swift",
                     previousPath: nil, kind: .modified,
                     lines: [
                         DiffLine(style: .hunkHeader, text: "@@ -10,7 +10,16 @@", oldLineNumber: 10, newLineNumber: 10),
                         DiffLine(style: .context, text: "import Foundation", oldLineNumber: 11, newLineNumber: 11),
                         DiffLine(style: .removed, text: "let token = \"old\"", oldLineNumber: 12),
                         DiffLine(style: .added, text: "let token = config.apiToken", newLineNumber: 12),
                         DiffLine(style: .added, text: "func verify() async throws {", newLineNumber: 13),
                     ],
                     linesAdded: 12, linesRemoved: 3, capturedAt: today(0.24),
                     baselineSource: .lastObserved, baselineCapturedAt: today(0.21)),
            FileDiff(id: changeBinary,
                     path: "\(projectOne)/Assets/logo.png", kind: .created,
                     lines: [DiffLine(style: .meta, text: "binary file")],
                     isBinary: true, isTruncated: true, capturedAt: today(0.26),
                     baselineSource: .unavailableFirstSighting, baselineCapturedAt: nil),
        ]
    }()

    static let commands: [CommandRecord] = {
        [
            CommandRecord(executable: "swift", arguments: ["test", "--filter", "Auth"],
                          workingDirectory: projectOne, agentID: agentClaude, sessionID: sessionA,
                          agentKind: .claudeCode, startedAt: today(0.27), endedAt: today(0.28),
                          exitCode: 1, outcome: .failure, riskLevel: .high, projectPath: projectOne),
            CommandRecord(executable: "git", arguments: ["push", "origin", "main", "--force"],
                          workingDirectory: projectTwo, agentID: agentCodex, sessionID: sessionB,
                          agentKind: .openAICodex, startedAt: today(0.35), endedAt: today(0.36),
                          exitCode: 0, outcome: .success, isDestructive: true,
                          requiresConfirmation: true, riskLevel: .high, projectPath: projectTwo),
            CommandRecord(executable: "rm", arguments: ["-rf", "./build"], workingDirectory: projectTwo,
                          agentID: agentCodex, sessionID: sessionB, agentKind: .openAICodex,
                          startedAt: today(0.31), endedAt: today(0.315), exitCode: 0, outcome: .success,
                          isDestructive: true, requiresConfirmation: true, riskLevel: .critical,
                          projectPath: projectTwo),
            CommandRecord(executable: "npm", arguments: ["install"], workingDirectory: projectOne,
                          agentID: agentClaude, sessionID: sessionA, agentKind: .claudeCode,
                          startedAt: today(0.42), exitCode: nil, outcome: .running, projectPath: projectOne),
            CommandRecord(executable: "sudo", arguments: ["tee", "-a", "/etc/hosts"],
                          workingDirectory: nil, agentID: agentCursor, sessionID: sessionC,
                          agentKind: .cursorAgent, startedAt: daysAgo(1, 0.31), endedAt: daysAgo(1, 0.32),
                          exitCode: 0, outcome: .success, isDestructive: true,
                          requiresConfirmation: true, riskLevel: .critical),
            CommandRecord(executable: "curl", arguments: ["-sSL", "https://example.test/install.sh", "|", "sh"],
                          agentKind: .geminiCLI, startedAt: daysAgo(4, 0.23),
                          exitCode: nil, outcome: .terminated),
        ]
    }()

    static let performanceSamples: [PerformanceSample] = {
        [
            PerformanceSample(timestamp: today(0.22), sessionID: sessionA, agentID: agentClaude,
                              cpuPercent: 12.5, memoryBytes: 700 * 1024 * 1024, gpuPercent: 3.5,
                              diskReadBytesPerSecond: 1_024, diskWriteBytesPerSecond: 512,
                              networkBytesIn: 4_096, networkBytesOut: 1_024, thermalCelsius: 54.25, powerWatts: 8.5),
            PerformanceSample(timestamp: today(0.29), sessionID: sessionA, agentID: agentClaude,
                              cpuPercent: 88.25, memoryBytes: 900 * 1024 * 1024,
                              diskReadBytesPerSecond: 2_048, thermalCelsius: 61.5),
            PerformanceSample(timestamp: today(0.34), sessionID: sessionB, agentID: agentCodex,
                              cpuPercent: 41.5, memoryBytes: 512 * 1024 * 1024),
            PerformanceSample(timestamp: today(0.61), sessionID: sessionRunning, agentID: agentClaude,
                              cpuPercent: 5.5, memoryBytes: 256 * 1024 * 1024),
            PerformanceSample(timestamp: daysAgo(1, 0.28), sessionID: sessionC, agentID: agentCursor,
                              cpuPercent: 73.125, memoryBytes: 4 * 1024 * 1024 * 1024),
            PerformanceSample(timestamp: daysAgo(4, 0.24), sessionID: sessionFailed,
                              cpuPercent: 0, memoryBytes: 0),
        ]
    }()

    static let systemSamples: [SystemPerformanceSample] = {
        [
            SystemPerformanceSample(timestamp: today(0.2), cpuTotalPercent: 25.5, cpuSystemPercent: 5.5,
                                    cpuUserPercent: 20, memoryUsedBytes: 8 * 1024 * 1024 * 1024,
                                    memoryTotalBytes: 32 * 1024 * 1024 * 1024, loadAverage1m: 2.25,
                                    thermalCelsius: 50),
            SystemPerformanceSample(timestamp: today(0.5), cpuTotalPercent: 60.25, memoryUsedBytes: 16 * 1024 * 1024 * 1024,
                                    memoryTotalBytes: 32 * 1024 * 1024 * 1024, loadAverage1m: 6.75, powerWatts: 22.5),
            SystemPerformanceSample(timestamp: daysAgo(1, 0.5), cpuTotalPercent: 10, memoryTotalBytes: 32 * 1024 * 1024 * 1024),
            SystemPerformanceSample(timestamp: daysAgo(6, 0.5), cpuTotalPercent: 99.5, memoryTotalBytes: 32 * 1024 * 1024 * 1024),
        ]
    }()

    static let risks: [RiskEvent] = {
        [
            RiskEvent(timestamp: today(0.31), level: .critical, category: .massDeletion,
                      title: "批量删除", detail: "60 秒窗口内 42 个删除", agentID: agentCodex,
                      agentKind: .openAICodex, sessionID: sessionB, command: "rm -rf ./build",
                      filePaths: ["\(projectTwo)/config/legacy.json", "\(projectTwo)/build/output.o"],
                      requiresConfirmation: true, matchedRuleID: "mass-deletion-window"),
            RiskEvent(timestamp: today(0.27), level: .high, category: .dangerousCommand,
                      title: "强制推送", detail: "git push --force", agentID: agentClaude,
                      agentKind: .claudeCode, sessionID: sessionA, command: "git push origin main --force",
                      requiresConfirmation: true, matchedRuleID: "git-push-force"),
            RiskEvent(timestamp: today(0.4), level: .medium, category: .networkExfiltration,
                      title: "数据外发", detail: "POST 构建产物", agentID: agentClaude,
                      agentKind: .claudeCode, sessionID: sessionA),
            RiskEvent(timestamp: daysAgo(1, 0.3), level: .high, category: .systemFileModification,
                      title: "系统文件修改", detail: "/etc/hosts", agentID: agentCursor,
                      agentKind: .cursorAgent, sessionID: sessionC, filePaths: ["/etc/hosts"],
                      isAcknowledged: true, matchedRuleID: "system-directory-modified"),
            RiskEvent(timestamp: daysAgo(4, 0.25), level: .low, category: .unknown,
                      title: "未归类风险", detail: "", agentKind: .geminiCLI),
        ]
    }()

    static let projects: [ProjectActivity] = {
        [
            ProjectActivity(id: ProjectActivity.identity(path: projectOne), name: "Alpha", path: projectOne,
                            fileChangeCount: 5, commandCount: 2, sessionCount: 3, riskEventCount: 2,
                            codeGrowthLines: 37, codeShrinkLines: 4,
                            agentContributions: [
                                AgentContribution(kind: .claudeCode, relativeShare: 0.6, eventCount: 6),
                                AgentContribution(kind: .cursorAgent, relativeShare: 0.4, eventCount: 4),
                            ],
                            hotFiles: [
                                FileHeat(path: "\(projectOne)/Sources/AuthService.swift", changeCount: 4,
                                         linesAdded: 12, linesRemoved: 3, lastTouchedAt: today(0.24)),
                                FileHeat(path: "\(projectOne)/README.md", changeCount: 1, linesAdded: 24,
                                         lastTouchedAt: today(0.42)),
                            ],
                            firstSeenAt: today(0.2), lastSeenAt: today(0.9)),
            ProjectActivity(id: ProjectActivity.identity(path: projectTwo), name: "Beta", path: projectTwo,
                            fileChangeCount: 4, commandCount: 3, sessionCount: 2, riskEventCount: 1,
                            codeGrowthLines: 0, codeShrinkLines: 46,
                            agentContributions: [
                                AgentContribution(kind: .openAICodex, relativeShare: 1, eventCount: 5),
                            ],
                            hotFiles: [
                                FileHeat(path: "\(projectTwo)/config/legacy.json", changeCount: 2,
                                         linesRemoved: 45, lastTouchedAt: today(0.31)),
                            ],
                            firstSeenAt: today(0.3), lastSeenAt: today(0.8)),
        ]
    }()

    // MARK: 查询集（每条都会两边跑一遍）

    static var sessionQueries: [SessionQuery] {
        [
            .all,
            SessionQuery(agentKinds: [.claudeCode]),
            SessionQuery(agentKinds: [.claudeCode, .openAICodex]),
            SessionQuery(outcomes: [.running]),
            SessionQuery(outcomes: [.failed, .interrupted]),
            SessionQuery(projectPath: projectOne),
            SessionQuery(projectPath: "/no/such/project"),
            SessionQuery(searchText: "ALPHA"),
            SessionQuery(searchText: "重构"),
            SessionQuery(searchText: "codex"),
            SessionQuery(searchText: "绝不存在的东西"),
            SessionQuery(searchText: ""),
            SessionQuery(dateRange: .today(now), sort: .oldestFirst),
            // 这里原本是 `.lastHours(6, now: now)`：窗口边界跟着测试运行的钟点跑，
            // 「命中几条」根本没有唯一答案 ⇒ 只能对账。换成用 fixture 时刻围成的固定窗口，
            // 才写得出硬编码期望。`lastHours` 本身没有放弃覆盖，挪到
            // `clockRelativeSessionQueries` 继续跑两后端对账（那才是「可切换」这条需求要证的）。
            SessionQuery(dateRange: DateRangeFilter(start: today(0.25), end: today(0.62))),
            SessionQuery(dateRange: DateRangeFilter(start: daysAgo(2, 0.1), end: daysAgo(1, 0.9))),
            SessionQuery(limit: 2, offset: 1),
            SessionQuery(limit: 2, offset: 0, sort: .oldestFirst),
            SessionQuery(limit: 0, offset: 0),
            SessionQuery(limit: 10, offset: 999),
        ]
    }

    static var eventQueries: [EventQuery] {
        [
            .all,
            EventQuery(kinds: [.fileModified]),
            EventQuery(kinds: [.fileDeleted, .fileRenamed]),
            EventQuery(agentKinds: [.cursorAgent]),
            EventQuery(agentKinds: [.claudeCode, .openAICodex]),
            EventQuery(sessionID: sessionA),
            EventQuery(sessionID: orphanSessionID),
            EventQuery(projectPath: projectOne),
            EventQuery(minimumRisk: .high),
            EventQuery(minimumRisk: .critical),
            EventQuery(minimumRisk: .medium, sort: .oldestFirst),
            EventQuery(searchText: "PUSH"),
            EventQuery(searchText: "批量"),
            EventQuery(searchText: "legacy.json"),
            EventQuery(dateRange: .today(now)),
            EventQuery(dateRange: .lastHours(48, now: now)),
            EventQuery(limit: 3, offset: 2),
            EventQuery(kinds: [.riskDetected], limit: 500),
        ]
    }

    static var fileChangeQueries: [FileChangeQuery] {
        [
            .all,
            FileChangeQuery(kinds: [.deleted]),
            FileChangeQuery(kinds: [.created, .renamed]),
            FileChangeQuery(agentKinds: [.openAICodex]),
            FileChangeQuery(sessionID: sessionA),
            FileChangeQuery(projectPath: projectTwo),
            FileChangeQuery(pathPrefix: "\(projectOne)/Sources"),
            FileChangeQuery(pathPrefix: projectOne),
            FileChangeQuery(pathPrefix: "/nope"),
            FileChangeQuery(pathPrefix: ""),
            FileChangeQuery(searchText: "CONFIG"),
            FileChangeQuery(searchText: "README"),
            FileChangeQuery(searchText: "hosts"),
            FileChangeQuery(dateRange: .today(now), sort: .oldestFirst),
            FileChangeQuery(kinds: [.unknown]),
            FileChangeQuery(limit: 4, offset: 3),
            FileChangeQuery(kinds: [.modified], agentKinds: [.geminiCLI, .cursorAgent]),
        ]
    }

    static var commandQueries: [CommandQuery] {
        [
            .all,
            CommandQuery(agentKinds: [.claudeCode]),
            CommandQuery(sessionID: sessionB),
            CommandQuery(outcomes: [.failure]),
            CommandQuery(outcomes: [.success, .running]),
            CommandQuery(destructiveOnly: true),
            CommandQuery(outcomes: [.success], destructiveOnly: true),
            // #86：`withNonZeroExitCode` 这一维。四支各有分工——
            // 单用是"退出码非零"那一把；`outcomes` 补集那一支就是容斥的**第二项**
            // （`outcome != .failure && exit != 0`，Engine 数失败数时真的这么问）；
            // 最后一支是两项的交（#81 那阵子加的字段组合先例：交集最容易分叉）。
            CommandQuery(withNonZeroExitCode: true),
            CommandQuery(sessionID: sessionB, withNonZeroExitCode: true),
            CommandQuery(outcomes: Set(CommandOutcome.allCases).subtracting([.failure]),
                         withNonZeroExitCode: true),
            CommandQuery(outcomes: [.failure], withNonZeroExitCode: true),
            CommandQuery(searchText: "GIT PUSH"),
            CommandQuery(searchText: "curl"),
            CommandQuery(searchText: "swift test"),
            CommandQuery(dateRange: .today(now), sort: .oldestFirst),
            CommandQuery(dateRange: .lastHours(72, now: now)),
            CommandQuery(limit: 2, offset: 1),
        ]
    }

    /// 项目条件那一维（#81(a)：`CommandQuery.projectPath`）。
    ///
    /// **为什么单列一份、不并进 `commandQueries`**：那一份同时喂
    /// `StorePageParityTests`（SQLite ≡ 冻结基准 `InMemoryObservatoryService`），而基准实现在
    /// `AIObservatoryTestSupport/**`（§3 冻结区，本轮未授权改）里读不到这一维 ⇒ 并进去得到的
    /// 是一条「基准不筛、真实现筛」的假对账。这一份只跑**绝对真值**（对照下面的手算表），
    /// 两后端之间的对照在 `SwiftDataBackendDifferentialTests`（那边两侧都是真后端，不经过基准）。
    static var projectScopedCommandQueries: [CommandQuery] {
        [
            CommandQuery(projectPath: projectOne),
            CommandQuery(projectPath: projectTwo),
            CommandQuery(projectPath: "/no/such/project"),
            CommandQuery(projectPath: projectOne, destructiveOnly: true),
            CommandQuery(projectPath: projectTwo, destructiveOnly: true),
            CommandQuery(projectPath: projectOne, searchText: "npm"),
            CommandQuery(projectPath: projectOne, outcomes: [.running]),
            CommandQuery(projectPath: projectOne, limit: 1, offset: 0),
        ]
    }

    static var riskQueries: [RiskQuery] {
        [
            .all,
            RiskQuery(levels: [.critical]),
            RiskQuery(levels: [.high, .medium]),
            RiskQuery(categories: [.massDeletion]),
            RiskQuery(categories: [.dangerousCommand, .systemFileModification]),
            RiskQuery(agentKinds: [.openAICodex]),
            RiskQuery(sessionID: sessionA),
            RiskQuery(sessionID: sessionC),
            RiskQuery(unacknowledgedOnly: true),
            RiskQuery(searchText: "批量删除"),
            RiskQuery(searchText: "PUSH"),
            RiskQuery(searchText: "no-such-needle"),
            RiskQuery(dateRange: .today(now), sort: .oldestFirst),
            RiskQuery(limit: 2, offset: 1),
        ]
    }

    /// 项目条件那一维（#81(a)：`RiskQuery.projectPath`，口径 = 风险 → 会话 → 项目）。
    /// 单列一份的理由与 `projectScopedCommandQueries` 同（冻结基准读不到这一维）。
    static var projectScopedRiskQueries: [RiskQuery] {
        [
            RiskQuery(projectPath: projectOne),
            RiskQuery(projectPath: projectTwo),
            RiskQuery(projectPath: "/no/such/project"),
            RiskQuery(projectPath: projectOne, unacknowledgedOnly: true),
            RiskQuery(levels: [.high], projectPath: projectOne),
            RiskQuery(projectPath: projectOne, searchText: "PUSH"),
            RiskQuery(sessionID: sessionA, projectPath: projectOne),
            RiskQuery(sessionID: sessionB, projectPath: projectOne),
            RiskQuery(projectPath: projectOne, limit: 2, offset: 0),
        ]
    }

    /// 只有两后端对账才能证的查询：`lastHours` 的边界随墙钟移动，硬编码期望值不存在
    /// （「命中几条」取决于测试是几点跑的）。这些留在 parity 套件里，是为了证明
    /// 「换后端不改行为」这条真需求，**不充当正确性证据**。
    static var clockRelativeSessionQueries: [SessionQuery] {
        [
            SessionQuery(dateRange: .lastHours(6, now: now)),
        ]
    }

    // MARK: 硬编码期望（绝对真值）
    //
    // 下面每组 `(页内身份序列, totalCount, hasMore)` 都是照着本文件的 fixture **手算**出来的，
    // 不是从 SQLite 读回来的，也不是从 InMemory 读回来的。所以「两个实现同时错」会让它们红，
    // 而原来的 `expectSamePage` 不会。排序口径：默认 newestFirst；fixture 内同族时间戳互不相同，
    // 顺序因此唯一确定。身份键：会话=displayIndex、事件/风险=title、文件=文件名、命令=commandLine。

    /// 5 条会话按 startedAt 倒序：Running(今天60%) → B(30%) → A(20%) → C(昨天) → Gemini(4天前)。
    static let sessionOrderDESC: [Int] = [104, 102, 101, 103, 105]
    /// 同上一条条正序。
    static let sessionOrderASC: [Int] = [105, 103, 101, 102, 104]

    static let expectedSessionPages: [SessionQuery: ([Int], Int, Bool)] = [
        SessionQuery.all: (sessionOrderDESC, 5, false),
        SessionQuery(agentKinds: [.claudeCode]): ([104, 101], 2, false),
        SessionQuery(agentKinds: [.claudeCode, .openAICodex]): ([104, 102, 101], 3, false),
        SessionQuery(outcomes: [.running]): ([104], 1, false),
        SessionQuery(outcomes: [.failed, .interrupted]): ([102, 103, 105], 3, false),
        SessionQuery(projectPath: projectOne): ([101, 103], 2, false),
        SessionQuery(projectPath: "/no/such/project"): ([], 0, false),
        // "ALPHA" 命中标题与项目路径（大小写不敏感）；Beta 那条不含 alpha。
        SessionQuery(searchText: "ALPHA"): ([101, 103], 2, false),
        SessionQuery(searchText: "重构"): ([103], 1, false),
        SessionQuery(searchText: "codex"): ([102], 1, false),
        SessionQuery(searchText: "绝不存在的东西"): ([], 0, false),
        // 注意这里**不写** `SessionQuery(searchText: "")`：它与 `SessionQuery.all` 是同一个值
        // （空串本来就跳过搜索谓词），Dictionary 字面量遇到重复键会当场 trap（signal 5）。
        // 查询集里那条空串仍在跑，靠的就是上面这条期望值按相等关系命中它。
        SessionQuery(dateRange: .today(now), sort: .oldestFirst): ([101, 102, 104], 3, false),
        SessionQuery(dateRange: DateRangeFilter(start: today(0.25), end: today(0.62))): ([104, 102], 2, false),
        SessionQuery(dateRange: DateRangeFilter(start: daysAgo(2, 0.1), end: daysAgo(1, 0.9))): ([103], 1, false),
        SessionQuery(limit: 2, offset: 1): ([102, 101], 5, true),
        SessionQuery(limit: 2, offset: 0, sort: .oldestFirst): ([105, 103], 5, true),
        SessionQuery(limit: 0, offset: 0): ([], 5, true),
        SessionQuery(limit: 10, offset: 999): ([], 5, false),
    ]

    /// 10 条事件按 timestamp 倒序（今天 0.5→0.21，然后昨天、4 天前）。
    static let eventOrderDESC: [String] = [
        "未归类行为", "重命名 Router.swift", "Network POST", "git push origin main",
        "删除文件 · 旧配置", "swift test", "修改文件 · AuthService.swift",
        "Agent 启动 · Claude Code", "修改 /etc/hosts", "风险事件 · 危险命令",
    ]
    static let eventOrderASC: [String] = [
        "风险事件 · 危险命令", "修改 /etc/hosts", "Agent 启动 · Claude Code",
        "修改文件 · AuthService.swift", "swift test", "删除文件 · 旧配置",
        "git push origin main", "Network POST", "重命名 Router.swift", "未归类行为",
    ]

    static let expectedEventPages: [EventQuery: ([String], Int, Bool)] = [
        EventQuery.all: (eventOrderDESC, 10, false),
        EventQuery(kinds: [.fileModified]): (["修改文件 · AuthService.swift"], 1, false),
        EventQuery(kinds: [.fileDeleted, .fileRenamed]): (["重命名 Router.swift", "删除文件 · 旧配置"], 2, false),
        EventQuery(agentKinds: [.cursorAgent]): (["重命名 Router.swift", "修改 /etc/hosts"], 2, false),
        // claudeCode 4 条（含 Network POST，它的 agentKind 也是 claudeCode）+ openAICodex 2 条。
        EventQuery(agentKinds: [.claudeCode, .openAICodex]): ([
            "Network POST", "git push origin main", "删除文件 · 旧配置", "swift test",
            "修改文件 · AuthService.swift", "Agent 启动 · Claude Code",
        ], 6, false),
        EventQuery(sessionID: sessionA): ([
            "Network POST", "swift test", "修改文件 · AuthService.swift", "Agent 启动 · Claude Code",
        ], 4, false),
        // session_id 为 NULL 的那条（未归类行为）不得被任意具体 sessionID 捞出来。
        EventQuery(sessionID: orphanSessionID): ([], 0, false),
        EventQuery(projectPath: projectOne): ([
            "重命名 Router.swift", "Network POST", "swift test",
            "修改文件 · AuthService.swift", "Agent 启动 · Claude Code", "修改 /etc/hosts",
        ], 6, false),
        EventQuery(minimumRisk: .high): ([
            "删除文件 · 旧配置", "swift test", "修改 /etc/hosts", "风险事件 · 危险命令",
        ], 4, false),
        EventQuery(minimumRisk: .critical): (["删除文件 · 旧配置", "风险事件 · 危险命令"], 2, false),
        EventQuery(minimumRisk: .medium, sort: .oldestFirst): ([
            "风险事件 · 危险命令", "修改 /etc/hosts", "修改文件 · AuthService.swift",
            "swift test", "删除文件 · 旧配置", "Network POST",
        ], 6, false),
        EventQuery(searchText: "PUSH"): (["git push origin main"], 1, false),
        EventQuery(searchText: "批量"): (["删除文件 · 旧配置"], 1, false),
        EventQuery(searchText: "legacy.json"): (["删除文件 · 旧配置"], 1, false),
        EventQuery(dateRange: .today(now)): ([
            "未归类行为", "重命名 Router.swift", "Network POST", "git push origin main",
            "删除文件 · 旧配置", "swift test", "修改文件 · AuthService.swift",
            "Agent 启动 · Claude Code",
        ], 8, false),
        EventQuery(dateRange: .lastHours(48, now: now)): ([
            "未归类行为", "重命名 Router.swift", "Network POST", "git push origin main",
            "删除文件 · 旧配置", "swift test", "修改文件 · AuthService.swift",
            "Agent 启动 · Claude Code", "修改 /etc/hosts",
        ], 9, false),
        EventQuery(limit: 3, offset: 2): (
            ["Network POST", "git push origin main", "删除文件 · 旧配置"], 10, true
        ),
        EventQuery(kinds: [.riskDetected], limit: 500): (["风险事件 · 危险命令"], 1, false),
    ]

    /// 8 条文件变更按 timestamp 倒序。
    static let fileChangeOrderDESC: [String] = [
        "README.md", "CONFIG.OLD", "output.o", "legacy.json",
        "logo.png", "AuthService.swift", "hosts", "Unknown.bin",
    ]

    static let expectedFileChangePages: [FileChangeQuery: ([String], Int, Bool)] = [
        FileChangeQuery.all: (fileChangeOrderDESC, 8, false),
        FileChangeQuery(kinds: [.deleted]): (["output.o", "legacy.json"], 2, false),
        FileChangeQuery(kinds: [.created, .renamed]): (["README.md", "CONFIG.OLD", "logo.png"], 3, false),
        FileChangeQuery(agentKinds: [.openAICodex]): (["CONFIG.OLD", "output.o", "legacy.json"], 3, false),
        FileChangeQuery(sessionID: sessionA): (["README.md", "logo.png", "AuthService.swift"], 3, false),
        FileChangeQuery(projectPath: projectTwo): (["CONFIG.OLD", "output.o", "legacy.json"], 3, false),
        FileChangeQuery(pathPrefix: "\(projectOne)/Sources"): (["AuthService.swift"], 1, false),
        FileChangeQuery(pathPrefix: projectOne): (
            ["README.md", "logo.png", "AuthService.swift", "Unknown.bin"], 4, false
        ),
        FileChangeQuery(pathPrefix: "/nope"): ([], 0, false),
        FileChangeQuery(pathPrefix: ""): (fileChangeOrderDESC, 8, false),
        // 搜索串只由 path 小写化而来：`config` 同时命中 CONFIG.OLD 和 config/legacy.json。
        FileChangeQuery(searchText: "CONFIG"): (["CONFIG.OLD", "legacy.json"], 2, false),
        FileChangeQuery(searchText: "README"): (["README.md"], 1, false),
        FileChangeQuery(searchText: "hosts"): (["hosts"], 1, false),
        FileChangeQuery(dateRange: .today(now), sort: .oldestFirst): ([
            "AuthService.swift", "logo.png", "legacy.json", "output.o", "CONFIG.OLD", "README.md",
        ], 6, false),
        FileChangeQuery(kinds: [.unknown]): (["Unknown.bin"], 1, false),
        FileChangeQuery(limit: 4, offset: 3): ([
            "legacy.json", "logo.png", "AuthService.swift", "hosts",
        ], 8, true),
        FileChangeQuery(kinds: [.modified], agentKinds: [.geminiCLI, .cursorAgent]): (["hosts"], 1, false),
    ]

    /// 6 条命令按 startedAt 倒序；键用 commandLine，顺带钉住「argv 末位参数没丢」。
    static let commandOrderDESC: [String] = [
        "npm install", "git push origin main --force", "rm -rf ./build",
        "swift test --filter Auth", "sudo tee -a /etc/hosts",
        "curl -sSL https://example.test/install.sh | sh",
    ]

    static let expectedCommandPages: [CommandQuery: ([String], Int, Bool)] = [
        CommandQuery.all: (commandOrderDESC, 6, false),
        CommandQuery(agentKinds: [.claudeCode]): (["npm install", "swift test --filter Auth"], 2, false),
        CommandQuery(sessionID: sessionB): (["git push origin main --force", "rm -rf ./build"], 2, false),
        CommandQuery(outcomes: [.failure]): (["swift test --filter Auth"], 1, false),
        CommandQuery(outcomes: [.success, .running]): ([
            "npm install", "git push origin main --force", "rm -rf ./build", "sudo tee -a /etc/hosts",
        ], 4, false),
        CommandQuery(destructiveOnly: true): ([
            "git push origin main --force", "rm -rf ./build", "sudo tee -a /etc/hosts",
        ], 3, false),
        CommandQuery(outcomes: [.success], destructiveOnly: true): ([
            "git push origin main --force", "rm -rf ./build", "sudo tee -a /etc/hosts",
        ], 3, false),
        // #86 `withNonZeroExitCode` 四支。期望值全部**手推**自上面那 6 条命令
        // （退出码：swift test=1/failure、git push=0/success、rm=0/success、npm=nil/running、
        //   sudo=0/success、curl=nil/terminated；会话：前 4 条 A/B/B/A、sudo=C、curl 无会话）。
        // 全表只有第一条退出码非零 ⇒ 单用那一维就是它；
        // 与 `outcomes` 的交/并两支**故意都是空集**：
        // 一支漏掉退出码会返回 4 条、另一支漏掉 outcomes 会返回 1 条，两个方向都能被抓出来
        // （本夹具里没有"退出码非零但 outcome≠failure"那一格，那一格由
        //  `CommandCountLedgerTests` 自带夹具钉，见该文件）。
        CommandQuery(withNonZeroExitCode: true): (["swift test --filter Auth"], 1, false),
        CommandQuery(sessionID: sessionB, withNonZeroExitCode: true): ([], 0, false),
        CommandQuery(outcomes: Set(CommandOutcome.allCases).subtracting([.failure]),
                     withNonZeroExitCode: true): ([], 0, false),
        CommandQuery(outcomes: [.failure], withNonZeroExitCode: true): (["swift test --filter Auth"], 1, false),
        CommandQuery(searchText: "GIT PUSH"): (["git push origin main --force"], 1, false),
        CommandQuery(searchText: "curl"): (["curl -sSL https://example.test/install.sh | sh"], 1, false),
        CommandQuery(searchText: "swift test"): (["swift test --filter Auth"], 1, false),
        CommandQuery(dateRange: .today(now), sort: .oldestFirst): ([
            "swift test --filter Auth", "rm -rf ./build", "git push origin main --force", "npm install",
        ], 4, false),
        CommandQuery(dateRange: .lastHours(72, now: now)): ([
            "npm install", "git push origin main --force", "rm -rf ./build",
            "swift test --filter Auth", "sudo tee -a /etc/hosts",
        ], 5, false),
        CommandQuery(limit: 2, offset: 1): (["git push origin main --force", "rm -rf ./build"], 6, true),
    ]

    /// 项目条件那一维的手算期望（对应 `projectScopedCommandQueries`）。
    ///
    /// 逐条照本文件 fixture 命令表（`projectPath` 列）手推，DESC = startedAt 倒序：
    ///   · projectOne：`npm install`(0.42) 与 `swift test --filter Auth`(0.27) ⇒ 倒序 [npm, swift]。
    ///   · projectTwo：`git push … --force`(0.35) 与 `rm -rf ./build`(0.31) ⇒ 倒序 [git, rm]。
    ///   · 两条 projectOne 命令都不 destructive ⇒ projectOne + destructiveOnly = 空。
    ///   · `sudo` / `curl` 那两条 `projectPath == nil`：任何项目条件下都不该被 `=` 捞出来。
    static let expectedProjectScopedCommandPages: [CommandQuery: ([String], Int, Bool)] = [
        CommandQuery(projectPath: projectOne): (["npm install", "swift test --filter Auth"], 2, false),
        CommandQuery(projectPath: projectTwo): (["git push origin main --force", "rm -rf ./build"], 2, false),
        CommandQuery(projectPath: "/no/such/project"): ([], 0, false),
        CommandQuery(projectPath: projectOne, destructiveOnly: true): ([], 0, false),
        CommandQuery(projectPath: projectTwo, destructiveOnly: true): (
            ["git push origin main --force", "rm -rf ./build"], 2, false
        ),
        CommandQuery(projectPath: projectOne, searchText: "npm"): (["npm install"], 1, false),
        CommandQuery(projectPath: projectOne, outcomes: [.running]): (["npm install"], 1, false),
        CommandQuery(projectPath: projectOne, limit: 1, offset: 0): (["npm install"], 2, true),
    ]

    /// 5 条风险按 timestamp 倒序。
    static let riskOrderDESC: [String] = ["数据外发", "批量删除", "强制推送", "系统文件修改", "未归类风险"]

    static let expectedRiskPages: [RiskQuery: ([String], Int, Bool)] = [
        RiskQuery.all: (riskOrderDESC, 5, false),
        RiskQuery(levels: [.critical]): (["批量删除"], 1, false),
        RiskQuery(levels: [.high, .medium]): (["数据外发", "强制推送", "系统文件修改"], 3, false),
        RiskQuery(categories: [.massDeletion]): (["批量删除"], 1, false),
        RiskQuery(categories: [.dangerousCommand, .systemFileModification]): (
            ["强制推送", "系统文件修改"], 2, false
        ),
        RiskQuery(agentKinds: [.openAICodex]): (["批量删除"], 1, false),
        RiskQuery(sessionID: sessionA): (["数据外发", "强制推送"], 2, false),
        RiskQuery(sessionID: sessionC): (["系统文件修改"], 1, false),
        RiskQuery(unacknowledgedOnly: true): (["数据外发", "批量删除", "强制推送", "未归类风险"], 4, false),
        RiskQuery(searchText: "批量删除"): (["批量删除"], 1, false),
        RiskQuery(searchText: "PUSH"): (["强制推送"], 1, false),
        RiskQuery(searchText: "no-such-needle"): ([], 0, false),
        RiskQuery(dateRange: .today(now), sort: .oldestFirst): (["强制推送", "批量删除", "数据外发"], 3, false),
        RiskQuery(limit: 2, offset: 1): (["批量删除", "强制推送"], 5, true),
    ]

    /// 项目条件那一维的手算期望（对应 `projectScopedRiskQueries`）。
    ///
    /// 口径：**风险 → 会话 → 项目**（`risk_events` 没有项目列，`sessions.project_path` 才是它挂的项目）。
    /// 本 fixture 的归属：`数据外发`/`强制推送` 挂 sessionA(Alpha)、`系统文件修改` 挂 sessionC(Alpha)、
    /// `批量删除` 挂 sessionB(Beta)、`未归类风险` **不挂任何会话** ⇒ 它在任何项目条件下都不出现
    /// （全量 5 条里只有 3 + 1 = 4 条被两个项目条件捞到，第五条目条件的就是这条 NULL 规则）。
    static let expectedProjectScopedRiskPages: [RiskQuery: ([String], Int, Bool)] = [
        RiskQuery(projectPath: projectOne): (["数据外发", "强制推送", "系统文件修改"], 3, false),
        RiskQuery(projectPath: projectTwo): (["批量删除"], 1, false),
        RiskQuery(projectPath: "/no/such/project"): ([], 0, false),
        RiskQuery(projectPath: projectOne, unacknowledgedOnly: true): (["数据外发", "强制推送"], 2, false),
        RiskQuery(levels: [.high], projectPath: projectOne): (["强制推送", "系统文件修改"], 2, false),
        RiskQuery(projectPath: projectOne, searchText: "PUSH"): (["强制推送"], 1, false),
        RiskQuery(sessionID: sessionA, projectPath: projectOne): (["数据外发", "强制推送"], 2, false),
        // 会话与项目各说一头：sessionB 属于 Beta ⇒ 与 projectOne 的交集是空，不是「取其中一个」。
        RiskQuery(sessionID: sessionB, projectPath: projectOne): ([], 0, false),
        RiskQuery(projectPath: projectOne, limit: 2, offset: 0): (["数据外发", "强制推送"], 3, true),
    ]
}

// MARK: - 装配（两边同一批数据）

private actor ParitySandbox {
    static let shared = ParitySandbox()

    private var pair: (memory: InMemoryObservatoryService, store: ObservatoryStore)?

    /// 用同一批 fixture 分别装配内存实现与 SQLite Store。
    func services() async throws -> (InMemoryObservatoryService, ObservatoryStore) {
        if let pair { return pair }
        let store = try await ObservatoryStore.open(configuration: .inMemory)
        let memory = InMemoryObservatoryService()

        memory.seed(
            agents: ParityFixture.agents,
            sessions: ParityFixture.sessions,
            events: ParityFixture.events,
            fileChanges: ParityFixture.fileChanges,
            diffs: ParityFixture.diffs,
            commands: ParityFixture.commands,
            performance: ParityFixture.performanceSamples,
            systemPerformance: ParityFixture.systemSamples,
            risks: ParityFixture.risks,
            projects: ParityFixture.projects
        )

        try await store.upsertAgents(ParityFixture.agents)
        // 这一列只有一个写入者（`recomputeSessionRiskCount`，派生自 risk_events），
        // 所以两种顺序都得到同一个数——原来那句「反序会把期望值叠加掉」是 #35 那条 P0
        // 的写法本身：整行 upsert 会拿自增值盖住派生值。现在盖不动了。
        try await store.recordRisks(ParityFixture.risks)
        try await store.upsertSessions(ParityFixture.sessions)
        try await store.upsertProjects(ParityFixture.projects)
        // 参考实现用 `diff.id` 当作 changeID 索引，因此 fixture 里 diff.id == 对应 change.id。
        for diff in ParityFixture.diffs {
            try await store.record(diff, forChangeID: diff.id)
        }
        for event in ParityFixture.events { await store.append(event) }
        for change in ParityFixture.fileChanges { await store.append(change) }
        for command in ParityFixture.commands { await store.append(command) }
        for sample in ParityFixture.performanceSamples { await store.append(sample) }
        for sample in ParityFixture.systemSamples { await store.append(sample) }
        await store.flush()

        let built = (memory, store)
        pair = built
        return built
    }
}

// MARK: - 比对工具

/// 只报告第一处差异，避免整页数组刷进日志。
private func reportFirstDifference<T: Equatable & Sendable>(
    _ store: [T],
    _ reference: [T],
    context: String,
    sourceLocation: SourceLocation
) {
    if store.count != reference.count {
        let storeLabels = store.map(indexLabel).joined(separator: ",")
        let referenceLabels = reference.map(indexLabel).joined(separator: ",")
        Issue.record("\(context): 条数不同 store=\(store.count) memory=\(reference.count) ｜ store=[\(storeLabels)] memory=[\(referenceLabels)]",
                     sourceLocation: sourceLocation)
        return
    }
    for index in store.indices where store[index] != reference[index] {
        let report = fieldDifferences(store[index], reference[index])
        let detail = report.isEmpty ? "字段打印相同但不相等（可能是集合顺序）" : report.joined(separator: " ; ")
        Issue.record("\(context): 首个差异在 [\(index)] → \(detail)", sourceLocation: sourceLocation)
        return
    }
}

/// 逐字段定位差异：`Date` 打印会丢掉小数秒，因此数值化输出，避免「看着一样却不相等」。
private func fieldDifferences<T>(_ store: T, _ reference: T) -> [String] {
    let storeValue = unwrap(store)
    let referenceValue = unwrap(reference)
    let left = Mirror(reflecting: storeValue).children.map { ($0.label ?? "?", $0.value) }
    let right = Dictionary(
        grouping: Mirror(reflecting: referenceValue).children.map { ($0.label ?? "?", $0.value) },
        by: { $0.0 }
    ).mapValues { $0.first!.1 }
    var report: [String] = []
    for (key, value) in left {
        guard let other = right[key] else {
            report.append("\(key)=<memory 侧缺失>")
            continue
        }
        let encoded = scalarDescription(value)
        if encoded != scalarDescription(other) {
            report.append("\(key): store=\(encoded) memory=\(scalarDescription(other))")
        }
    }
    if report.isEmpty {
        report = ["两侧字段打印相同但不相等：store=\(scalarDescription(storeValue)) memory=\(scalarDescription(referenceValue))"]
    }
    return report
}

/// Optional 包一层会让 Mirror 只看到 `.some`，先剥掉再比字段。
private func unwrap<T>(_ value: T) -> Any {
    let mirror = Mirror(reflecting: value)
    if mirror.displayStyle == .optional, let child = mirror.children.first {
        return child.value
    }
    return value
}

/// 把值递归展开成可逐位比较的字符串：Optional 先解包（否则 `Date?` 只打印到整秒，
/// 会把真正的差异藏起来），`Date` 用 timeIntervalSince1970 呈现。
private func scalarDescription(_ value: Any) -> String {
    let mirror = Mirror(reflecting: value)
    switch mirror.displayStyle {
    case .optional:
        guard let child = mirror.children.first else { return "nil" }
        return scalarDescription(child.value)
    case .collection, .set, .dictionary:
        return mirror.children.map { scalarDescription($0.value) }.joined(separator: "|")
    case .some(_):
        return mirror.children.map { "\(label(of: $0))=\(scalarDescription($0.value))" }.joined(separator: ",")
    case .none:
        if let date = value as? Date { return String(format: "%.9f", date.timeIntervalSince1970) }
        if let uuid = value as? UUID { return uuid.uuidString }
        if let number = value as? Double { return String(format: "%.9f", number) }
        return String(describing: value)
    }
}

/// Mirror 子项标签（集合元素没有 label）。
private func label(of child: Mirror.Child) -> String {
    child.label ?? "?"
}

/// 元素的身份标签（用于条数不等时定位到底缺了哪条）。
private func indexLabel<T>(_ value: T) -> String {
    let text = String(describing: value)
    if let range = text.range(of: "id: ") {
        return String(text[range.upperBound...].prefix(8))
    }
    return String(text.prefix(24))
}

private func expectSamePage<T: Equatable & Sendable>(
    _ store: Page<T>,
    _ reference: Page<T>,
    context: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(store.totalCount == reference.totalCount, "\(context): totalCount 不一致 store=\(store.totalCount) memory=\(reference.totalCount)", sourceLocation: sourceLocation)
    #expect(store.offset == reference.offset, "\(context): offset 不一致", sourceLocation: sourceLocation)
    if store.items != reference.items {
        reportFirstDifference(store.items, reference.items, context: context, sourceLocation: sourceLocation)
    }
}

/// 与**手算值**比，带容差：只用于 Date 相减这类不可避免的浮点舍入，容差压到 1e-3 秒。
private func expectApprox(
    _ actual: Double,
    _ expected: Double,
    tolerance: Double,
    context: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(abs(actual - expected) <= tolerance,
            "\(context): 实得 \(actual)，手算 \(expected)，差 \(abs(actual - expected)) 超过 \(tolerance)",
            sourceLocation: sourceLocation)
}

/// 绝对真值版分页断言：页内身份序列、条数、`totalCount`、`offset`、`hasMore` 全部对照**手算**值。
///
/// 不用 `#expect(page.items[0] …)`：`#expect` 失败只记 issue 不中断，空数组下标会把整个
/// 测试二进制打挂（本仓库真发生过 signal 5）。这里只做整数组比较 + `try #require` 取首元素。
private func expectExactPage<Element: Sendable>(
    _ page: Page<Element>,
    identity: (Element) -> String,
    ids expected: [String],
    totalCount: Int,
    offset: Int,
    hasMore: Bool,
    context: String,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let actual = page.items.map(identity)
    #expect(actual == expected, "\(context): 页内序列不符\n     实得 \(actual)\n     期望 \(expected)", sourceLocation: sourceLocation)
    #expect(page.totalCount == totalCount, "\(context): totalCount 应为 \(totalCount)，实得 \(page.totalCount)", sourceLocation: sourceLocation)
    #expect(page.offset == offset, "\(context): offset 应原样回传 \(offset)，实得 \(page.offset)", sourceLocation: sourceLocation)
    #expect(page.hasMore == hasMore, "\(context): hasMore 应为 \(hasMore)，实得 \(page.hasMore)", sourceLocation: sourceLocation)
}

// MARK: - 逐查询一致性

// MARK: - 两后端一致性（**这一组刻意只是对账**）

/// 本套件证明的是「换后端不改行为」这条真需求（SQLite 与内存实现可切换），
/// **不是**正确性证据：两边同时错这里就同时绿。正确性由 `StoreQueryTruthTests`
/// 及下面几个套件的硬编码期望值负责。
@Suite("Store 与 InMemory 查询一致：分页类", .timeLimit(.minutes(1)))
struct StorePageParityTests {

    @Test("sessions(matching:) 一致", arguments: ParityFixture.sessionQueries)
    func sessions(query: SessionQuery) async throws {
        let (memory, store) = try await ParitySandbox.shared.services()
        expectSamePage(try await store.sessions(matching: query),
                       try await memory.sessions(matching: query),
                       context: "sessions \(query.searchText)/\(query.limit)/\(query.offset)")
    }

    @Test("events(matching:) 一致", arguments: ParityFixture.eventQueries)
    func events(query: EventQuery) async throws {
        let (memory, store) = try await ParitySandbox.shared.services()
        expectSamePage(try await store.events(matching: query),
                       try await memory.events(matching: query),
                       context: "events \(query.searchText)/\(query.minimumRisk)")
    }

    @Test("fileChanges(matching:) 一致", arguments: ParityFixture.fileChangeQueries)
    func fileChanges(query: FileChangeQuery) async throws {
        let (memory, store) = try await ParitySandbox.shared.services()
        expectSamePage(try await store.fileChanges(matching: query),
                       try await memory.fileChanges(matching: query),
                       context: "fileChanges \(query.pathPrefix ?? "nil")")
    }

    @Test("commands(matching:) 一致", arguments: ParityFixture.commandQueries)
    func commands(query: CommandQuery) async throws {
        let (memory, store) = try await ParitySandbox.shared.services()
        expectSamePage(try await store.commands(matching: query),
                       try await memory.commands(matching: query),
                       context: "commands \(query.searchText)")
    }

    @Test("riskEvents(matching:) 一致", arguments: ParityFixture.riskQueries)
    func risks(query: RiskQuery) async throws {
        let (memory, store) = try await ParitySandbox.shared.services()
        expectSamePage(try await store.riskEvents(matching: query),
                       try await memory.riskEvents(matching: query),
                       context: "risks \(query.levels)")
    }

    /// 窗口边界随墙钟移动的查询写不出硬编码期望（命中几条取决于几点跑），
    /// 只能停在「两后端一致」这一层。单独列出来，是为了不让它混进绝对真值里冒充证据。
    @Test("时钟相关窗口：只做两后端对账", arguments: ParityFixture.clockRelativeSessionQueries)
    func clockRelative(query: SessionQuery) async throws {
        let (memory, store) = try await ParitySandbox.shared.services()
        expectSamePage(try await store.sessions(matching: query),
                       try await memory.sessions(matching: query),
                       context: "clock-relative sessions \(query.dateRange.start?.timeIntervalSinceReferenceDate ?? 0)")
    }
}

// MARK: - 分页查询的绝对真值

@Suite("Store 分页查询：命中集等于手算期望", .timeLimit(.minutes(1)))
struct StoreQueryTruthTests {

    @Test("sessions(matching:) 命中集 = 手算 displayIndex 序列", arguments: ParityFixture.sessionQueries)
    func sessions(query: SessionQuery) async throws {
        let store = try await ParitySandbox.shared.services().1
        let (ids, total, hasMore) = try #require(
            ParityFixture.expectedSessionPages[query],
            "sessionQueries 新增了一条却没有手算期望值：\(query)"
        )
        expectExactPage(try await store.sessions(matching: query),
                        identity: { String($0.displayIndex) },
                        ids: ids.map(String.init), totalCount: total,
                        offset: query.offset, hasMore: hasMore,
                        context: "sessions(search=\(query.searchText), kinds=\(query.agentKinds.count))")
    }

    @Test("events(matching:) 命中集 = 手算 title 序列", arguments: ParityFixture.eventQueries)
    func events(query: EventQuery) async throws {
        let store = try await ParitySandbox.shared.services().1
        let (ids, total, hasMore) = try #require(
            ParityFixture.expectedEventPages[query],
            "eventQueries 新增了一条却没有手算期望值：\(query)"
        )
        expectExactPage(try await store.events(matching: query),
                        identity: { $0.title }, ids: ids, totalCount: total,
                        offset: query.offset, hasMore: hasMore,
                        context: "events(search=\(query.searchText), minRisk=\(query.minimumRisk))")
    }

    @Test("fileChanges(matching:) 命中集 = 手算文件名序列", arguments: ParityFixture.fileChangeQueries)
    func fileChanges(query: FileChangeQuery) async throws {
        let store = try await ParitySandbox.shared.services().1
        let (ids, total, hasMore) = try #require(
            ParityFixture.expectedFileChangePages[query],
            "fileChangeQueries 新增了一条却没有手算期望值：\(query)"
        )
        expectExactPage(try await store.fileChanges(matching: query),
                        identity: { ($0.path as NSString).lastPathComponent }, ids: ids,
                        totalCount: total, offset: query.offset, hasMore: hasMore,
                        context: "fileChanges(prefix=\(query.pathPrefix ?? "nil"), search=\(query.searchText))")
    }

    @Test("commands(matching:) 命中集 = 手算 commandLine 序列", arguments: ParityFixture.commandQueries)
    func commands(query: CommandQuery) async throws {
        let store = try await ParitySandbox.shared.services().1
        let (ids, total, hasMore) = try #require(
            ParityFixture.expectedCommandPages[query],
            "commandQueries 新增了一条却没有手算期望值：\(query)"
        )
        expectExactPage(try await store.commands(matching: query),
                        identity: { $0.commandLine }, ids: ids, totalCount: total,
                        offset: query.offset, hasMore: hasMore,
                        context: "commands(search=\(query.searchText), destructive=\(query.destructiveOnly))")
    }

    /// `CommandQuery.projectPath` 这一维**真的进 SQL**（#81(a)）：
    /// 全量 6 条，带项目条件必须是手算的那 2 条 / 1 条 / 0 条，而不是原样 6 条。
    /// 期望值与 `SwiftDataBackendDifferentialTests` 里那批项目查询走的是同一条判据链
    /// （那边证「两后端同序同值」，这边证「这个值就是对的」）。
    @Test("commands(matching:) 项目条件：命中集 = 手算 commandLine 序列",
          arguments: ParityFixture.projectScopedCommandQueries)
    func commandsScopedByProject(query: CommandQuery) async throws {
        let store = try await ParitySandbox.shared.services().1
        let (ids, total, hasMore) = try #require(
            ParityFixture.expectedProjectScopedCommandPages[query],
            "projectScopedCommandQueries 新增了一条却没有手算期望值：\(query)"
        )
        expectExactPage(try await store.commands(matching: query),
                        identity: { $0.commandLine }, ids: ids, totalCount: total,
                        offset: query.offset, hasMore: hasMore,
                        context: "commands(project=\(query.projectPath ?? "nil"))")
        // 筛小这件事单独钉一条：这一族的全量是 6 条，任何项目条件的结果集都不许等于全量。
        #expect(total < 6, "项目条件没有把命令结果集筛小（手算期望本身就是 6 条？）")
    }

    @Test("riskEvents(matching:) 命中集 = 手算 title 序列", arguments: ParityFixture.riskQueries)
    func risks(query: RiskQuery) async throws {
        let store = try await ParitySandbox.shared.services().1
        let (ids, total, hasMore) = try #require(
            ParityFixture.expectedRiskPages[query],
            "riskQueries 新增了一条却没有手算期望值：\(query)"
        )
        expectExactPage(try await store.riskEvents(matching: query),
                        identity: { $0.title }, ids: ids, totalCount: total,
                        offset: query.offset, hasMore: hasMore,
                        context: "risks(levels=\(query.levels.count), unack=\(query.unacknowledgedOnly))")
    }

    /// `RiskQuery.projectPath` 这一维**真的进了那条 SQL**（#81(a)）：
    /// 全量 5 条 ⇒ Alpha 3 条、Beta 1 条、别的项目 0 条；不挂会话的那条「未归类风险」
    /// 在任何项目条件下都不出现（它没有会话可归属，猜一个项目就是编事实）。
    @Test("riskEvents(matching:) 项目条件：命中集 = 手算 title 序列",
          arguments: ParityFixture.projectScopedRiskQueries)
    func risksScopedByProject(query: RiskQuery) async throws {
        let store = try await ParitySandbox.shared.services().1
        let (ids, total, hasMore) = try #require(
            ParityFixture.expectedProjectScopedRiskPages[query],
            "projectScopedRiskQueries 新增了一条却没有手算期望值：\(query)"
        )
        expectExactPage(try await store.riskEvents(matching: query),
                        identity: { $0.title }, ids: ids, totalCount: total,
                        offset: query.offset, hasMore: hasMore,
                        context: "risks(project=\(query.projectPath ?? "nil"))")
        #expect(total < 5, "项目条件没有把风险结果集筛小（手算期望本身就是 5 条？）")
    }
}

@Suite("Store 单值与列表：字段级绝对真值", .timeLimit(.minutes(1)))
struct StoreValueTruthTests {

    /// 原来只断「Store 读回来 == InMemory 读回来」——两边同时把某列接错就全绿。
    /// 现在逐字段对照 fixture 的手算值，并特意覆盖 NULL / nil / 真 0 三种不同语义。
    @Test("session(id:) 每个字段等于手算值，NULL 列不塌成 0")
    func sessionByID() async throws {
        let store = try await ParitySandbox.shared.services().1

        let alpha = try #require(try await store.session(id: ParityFixture.sessionA))
        #expect(alpha.displayIndex == 101)
        #expect(alpha.title == "Claude Code · Alpha")
        #expect(alpha.kind == .claudeCode)
        #expect(alpha.agentID == ParityFixture.agentClaude)
        #expect(alpha.projectPath == ParityFixture.projectOne)
        #expect(alpha.startedAt == ParityFixture.today(0.2))
        #expect(alpha.endedAt == ParityFixture.today(0.55))
        #expect(alpha.modifiedFileCount == 12)
        #expect(alpha.createdFileCount == 3)
        #expect(alpha.deletedFileCount == 1)
        #expect(alpha.commandCount == 9)
        #expect(alpha.failedCommandCount == 2)
        #expect(alpha.cpuSeconds == 420.5)
        #expect(alpha.peakCPUPercent == 88.25)
        #expect(alpha.peakMemoryBytes == 943_718_400)          // 900 * 1024 * 1024
        #expect(alpha.estimatedTokens == 18_400)
        #expect(alpha.riskEventCount == 2)
        #expect(alpha.outcome == .success)

        let beta = try #require(try await store.session(id: ParityFixture.sessionB))
        #expect(beta.displayIndex == 102)
        #expect(beta.deletedFileCount == 4)
        #expect(beta.createdFileCount == 0, "fixture 就是 0 条新建，不得与「没统计」混为一谈")
        #expect(beta.failedCommandCount == 0)
        #expect(beta.cpuSeconds == 88.125)
        #expect(beta.peakCPUPercent == 41.5)
        #expect(beta.peakMemoryBytes == 536_870_912)           // 512 * 1024 * 1024
        #expect(beta.estimatedTokens == 7_200)
        #expect(beta.riskEventCount == 1)
        #expect(beta.outcome == .failed)
        #expect(beta.endedAt == ParityFixture.today(0.8))

        let cursor = try #require(try await store.session(id: ParityFixture.sessionC))
        #expect(cursor.title == "Cursor · Alpha 重构")
        #expect(cursor.modifiedFileCount == 30)
        #expect(cursor.cpuSeconds == 1_500)
        #expect(cursor.peakMemoryBytes == 4_294_967_296)       // 4 * 1024 * 1024 * 1024
        #expect(cursor.estimatedTokens == 51_000)
        #expect(cursor.riskEventCount == 1, "该会话名下有 1 条风险 → 派生计数就是 1")
        #expect(cursor.outcome == .interrupted)
        #expect(cursor.startedAt == ParityFixture.daysAgo(1, 0.25))

        // ended_at 为 NULL 的会话：读回来必须是 nil，而不是某个 0 时刻。
        let running = try #require(try await store.session(id: ParityFixture.sessionRunning))
        #expect(running.endedAt == nil, "未结算会话的 ended_at 必须是 NULL，不是 0 时刻")
        #expect(running.outcome == .running)
        #expect(running.modifiedFileCount == 2)
        #expect(running.commandCount == 1)
        #expect(running.cpuSeconds == 0)
        #expect(running.peakMemoryBytes == 0)

        // agent_id / project_path 为 NULL：必须是 nil，不能是空字符串或全零 UUID。
        let gemini = try #require(try await store.session(id: ParityFixture.sessionFailed))
        #expect(gemini.agentID == nil)
        #expect(gemini.projectPath == nil)
        #expect(gemini.kind == .geminiCLI)
        #expect(gemini.displayIndex == 105)
        #expect(gemini.commandCount == 2)
        #expect(gemini.failedCommandCount == 2)
        #expect(gemini.outcome == .failed)

        #expect(try await store.session(id: ParityFixture.orphanSessionID) == nil)
    }

    /// 原来只有 `lines.count == 5` 与首尾两行，中间三行、行号、path、时间戳一概没断。
    @Test("fileDiff(for:) 逐行等于 fixture，缺失 changeID 返回 nil")
    func fileDiff() async throws {
        let store = try await ParitySandbox.shared.services().1

        let text = try #require(try await store.fileDiff(for: ParityFixture.changeText))
        #expect(text.id == ParityFixture.changeText)
        #expect(text.path.hasSuffix("/Sources/AuthService.swift"))
        #expect(text.previousPath == nil, "modified 的 diff 不该有 previousPath")
        #expect(text.kind == .modified)
        #expect(text.linesAdded == 12)
        #expect(text.linesRemoved == 3)
        #expect(text.isBinary == false)
        #expect(text.isTruncated == false)
        #expect(text.capturedAt == ParityFixture.today(0.24))
        #expect(text.lines.map(\.style) == [.hunkHeader, .context, .removed, .added, .added])
        #expect(text.lines.map(\.text) == [
            "@@ -10,7 +10,16 @@", "import Foundation", "let token = \"old\"",
            "let token = config.apiToken", "func verify() async throws {",
        ])
        #expect(text.lines.map(\.oldLineNumber) == [10, 11, 12, nil, nil])
        #expect(text.lines.map(\.newLineNumber) == [10, 11, nil, 12, 13])

        // 溯源两列：SQLite 与参考实现必须各自等于**手写的同一个具体值**。
        // 只比「两边相等」对对称错误免疫不了——两边一起把列丢掉，等式照样成立，
        // 而界面上「与上次观测到的版本对比」就变成了「首次观测」。
        let (reference, _) = try await ParitySandbox.shared.services()
        let remembered = try #require(try await reference.fileDiff(for: ParityFixture.changeText))
        #expect(text.baselineSource == .lastObserved)
        #expect(text.baselineCapturedAt == ParityFixture.today(0.21))
        #expect(remembered.baselineSource == .lastObserved)
        #expect(remembered.baselineCapturedAt == ParityFixture.today(0.21))

        let binary = try #require(try await store.fileDiff(for: ParityFixture.changeBinary))
        #expect(binary.path.hasSuffix("/Assets/logo.png"))
        #expect(binary.kind == .created)
        #expect(binary.isBinary == true)
        #expect(binary.isTruncated == true)
        #expect(binary.lines.count == 1)
        #expect(binary.lines.first?.style == .meta)
        #expect(binary.lines.first?.text == "binary file")
        #expect(binary.linesAdded == 0 && binary.linesRemoved == 0, "二进制 diff 的行数是真 0")
        #expect(binary.baselineSource == .unavailableFirstSighting, "新建没有「上一版」这回事")
        #expect(binary.baselineCapturedAt == nil)

        // 没有 diff 的 changeID 必须查不到（而不是返回一条空 diff 或别的内容）。
        #expect(try await store.fileDiff(for: ParityFixture.orphanSessionID) == nil)
    }

    /// 原来断的是「Store 的数组 == InMemory 的数组」；两遍求和同序就看不出问题。
    /// 现在按会话断条数 + 顺序 + 每条的字段，并区分「没采到」(nil) 与「采到 0」。
    @Test("performanceSamples(sessionID:) 按时间升序等于手算值")
    func performance() async throws {
        let store = try await ParitySandbox.shared.services().1

        let alpha = try await store.performanceSamples(sessionID: ParityFixture.sessionA)
        #expect(alpha.count == 2)
        let first = try #require(alpha.first)
        #expect(first.timestamp == ParityFixture.today(0.22))
        #expect(first.sessionID == ParityFixture.sessionA)
        #expect(first.agentID == ParityFixture.agentClaude)
        #expect(first.cpuPercent == 12.5)
        #expect(first.memoryBytes == 734_003_200)               // 700 * 1024 * 1024
        #expect(first.gpuPercent == 3.5, "有值：必须原样读回")
        #expect(first.diskReadBytesPerSecond == 1_024)
        #expect(first.diskWriteBytesPerSecond == 512)
        #expect(first.networkBytesIn == 4_096)
        #expect(first.networkBytesOut == 1_024)
        #expect(first.thermalCelsius == 54.25)
        #expect(first.powerWatts == 8.5)
        let second = try #require(alpha.last)
        #expect(second.timestamp == ParityFixture.today(0.29))
        #expect(second.cpuPercent == 88.25)
        #expect(second.memoryBytes == 943_718_400)
        #expect(second.gpuPercent == nil, "这条没采 GPU ⇒ nil，不能塌成 0%")
        #expect(second.thermalCelsius == 61.5)
        #expect(second.powerWatts == nil, "这条没采功耗 ⇒ nil")
        #expect(second.diskWriteBytesPerSecond == 0, "disk_write 列 NOT NULL，这里是真的 0")
        #expect(second.networkBytesIn == 0 && second.networkBytesOut == 0)

        let beta = try await store.performanceSamples(sessionID: ParityFixture.sessionB)
        #expect(beta.map(\.cpuPercent) == [41.5])
        #expect(beta.first?.memoryBytes == 536_870_912)
        #expect(beta.first?.agentID == ParityFixture.agentCodex)

        let running = try await store.performanceSamples(sessionID: ParityFixture.sessionRunning)
        #expect(running.map(\.timestamp) == [ParityFixture.today(0.61)])
        #expect(running.first?.cpuPercent == 5.5)

        // 全 0 采样：0 是「读到的真值」，可空列才是 nil；agent_id 为 NULL。
        let gemini = try await store.performanceSamples(sessionID: ParityFixture.sessionFailed)
        #expect(gemini.count == 1)
        #expect(gemini.first?.cpuPercent == 0)
        #expect(gemini.first?.memoryBytes == 0)
        #expect(gemini.first?.agentID == nil)
        #expect(gemini.first?.thermalCelsius == nil)

        #expect(try await store.performanceSamples(sessionID: ParityFixture.orphanSessionID).isEmpty)
    }

    /// 原来断「两个数组相等」；现在断条数、升序序列，以及可空列的 nil。
    /// v3 四列（网络入/出/原因/GPU）在 fixture 里全部「没采」，必须逐条是 nil。
    @Test("systemPerformance(since:) 升序集合与可空列等于手算值", arguments: [
        SystemPerfTruth(since: ParityFixture.daysAgo(7, 0), cpuTotals: [99.5, 10, 25.5, 60.25]),
        SystemPerfTruth(since: ParityFixture.daysAgo(3, 0), cpuTotals: [10, 25.5, 60.25]),
        SystemPerfTruth(since: ParityFixture.today(0.45), cpuTotals: [60.25]),
        // 下界恰好压在一条采样上：`>=` 是闭区间，这条必须在。
        SystemPerfTruth(since: ParityFixture.today(0.2), cpuTotals: [25.5, 60.25]),
    ])
    func systemPerformance(truth: SystemPerfTruth) async throws {
        let store = try await ParitySandbox.shared.services().1
        let samples = try await store.systemPerformance(since: truth.since)
        #expect(samples.map(\.cpuTotalPercent) == truth.cpuTotals)
        #expect(samples.map(\.timestamp) == samples.map(\.timestamp).sorted())

        let newest = try #require(samples.last)
        #expect(newest.cpuTotalPercent == 60.25)
        #expect(newest.memoryUsedBytes == 17_179_869_184)       // 16 GiB
        #expect(newest.memoryTotalBytes == 34_359_738_368)      // 32 GiB
        #expect(newest.loadAverage1m == 6.75)
        #expect(newest.powerWatts == 22.5)
        #expect(newest.thermalCelsius == nil, "这条没采温度 ⇒ nil")
        #expect(newest.cpuSystemPercent == 0 && newest.cpuUserPercent == 0, "NOT NULL 列，真 0")
        #expect(newest.networkInBytesPerSecond == nil)
        #expect(newest.networkOutBytesPerSecond == nil)
        #expect(newest.networkAvailability == nil)
        #expect(newest.gpuActivityPercent == nil)
    }

    /// 原来只断「Store.projects() == InMemory.projects()」。JSON 两列（贡献、热文件）
    /// 一旦编解码错位，两边都会以同样的方式错。
    @Test("projects() = 手算的两行、顺序与 JSON 列内容")
    func projects() async throws {
        let store = try await ParitySandbox.shared.services().1
        let all = try await store.projects()
        #expect(all.count == 2)
        #expect(all.map(\.name) == ["Alpha", "Beta"], "按 last_seen_at 倒序")
        #expect(all.map(\.path) == [ParityFixture.projectOne, ParityFixture.projectTwo])
        #expect(all.map(\.id) == [ParityFixture.projectOne, ParityFixture.projectTwo],
                "项目行的主键由 path 推导，不是随机 UUID")

        let alpha = try #require(all.first)
        #expect(alpha.fileChangeCount == 5)
        #expect(alpha.commandCount == 2)
        #expect(alpha.sessionCount == 3)
        #expect(alpha.riskEventCount == 2)
        #expect(alpha.codeGrowthLines == 37)
        #expect(alpha.codeShrinkLines == 4)
        #expect(alpha.firstSeenAt == ParityFixture.today(0.2))
        #expect(alpha.lastSeenAt == ParityFixture.today(0.9))
        #expect(alpha.agentContributions.map(\.kind) == [.claudeCode, .cursorAgent])
        #expect(alpha.agentContributions.map(\.relativeShare) == [0.6, 0.4])
        #expect(alpha.agentContributions.map(\.eventCount) == [6, 4])
        #expect(alpha.hotFiles.map { ($0.path as NSString).lastPathComponent } == ["AuthService.swift", "README.md"])
        #expect(alpha.hotFiles.map(\.changeCount) == [4, 1])
        #expect(alpha.hotFiles.map(\.linesAdded) == [12, 24])
        #expect(alpha.hotFiles.map(\.linesRemoved) == [3, 0])
        #expect(alpha.hotFiles.map(\.lastTouchedAt) == [ParityFixture.today(0.24), ParityFixture.today(0.42)])

        let beta = try #require(all.last)
        #expect(beta.fileChangeCount == 4)
        #expect(beta.codeGrowthLines == 0, "Beta 只有删除，没有新增行")
        #expect(beta.codeShrinkLines == 46)
        #expect(beta.agentContributions.map(\.kind) == [.openAICodex])
        #expect(beta.agentContributions.map(\.relativeShare) == [1])
        #expect(beta.hotFiles.map { ($0.path as NSString).lastPathComponent } == ["legacy.json"])
        #expect(beta.hotFiles.map(\.linesRemoved) == [45])
    }

    /// 原来断的是「两边按 id 排序后集合相等」+`allSatisfy`，等于什么都没断：
    /// 把 `state` 过滤条件删掉、或把 ORDER BY 反过来，都不一定红。
    @Test("activeAgents() = 恰好三条、顺序与可空列等于手算值")
    func activeAgents() async throws {
        let store = try await ParitySandbox.shared.services().1
        let database = await store.database
        let live = try await store.activeAgents()
        #expect(live.map(\.id) == [ParityFixture.agentClaude, ParityFixture.agentCodex, ParityFixture.agentCursor],
                "running + idle 共 3 条，按 last_seen_at 倒序；terminated 的 Windsurf 不得出现")
        #expect(live.map(\.state) == [.running, .running, .idle])
        #expect(live.map(\.lastSeenAt) == [ParityFixture.today(0.9), ParityFixture.today(0.85), ParityFixture.today(0.6)])

        let claude = try #require(live.first)
        #expect(claude.kind == .claudeCode)
        #expect(claude.pid == 4001)
        #expect(claude.displayName == "Claude Code")
        #expect(claude.executablePath == "/usr/local/bin/claude")
        #expect(claude.workingDirectory == ParityFixture.projectOne)
        #expect(claude.bundleIdentifier == nil)
        #expect(claude.tty == "ttys001")
        #expect(claude.startedAt == ParityFixture.today(0.2))
        #expect(claude.cpuPercent == 37.5)
        #expect(claude.memoryBytes == 851_443_712)              // 812 * 1024 * 1024
        #expect(claude.childPIDs == [4002, 4003])
        #expect(claude.detectedVia == .executablePath)
        #expect(claude.parentPID == nil, "没填父进程 ⇒ NULL，不能读成 0")

        let codex = try #require(live.dropFirst().first)
        #expect(codex.parentPID == 1, "父 pid 真的是 1 的那条，必须与 nil 区分开")
        #expect(codex.memoryBytes == UInt64(Int64.max) + 1, "超大 UInt64 走 bitPattern 往返，不得变号或截断")
        #expect(codex.memoryBytes == 9_223_372_036_854_775_808)
        // 光断 Swift 侧相等挡不住「改成存 REAL」：2^63 恰好能被 Double 精确表示，
        // 两边一比还是相等。这里钉住库里那一列的**存储类型**必须是 INTEGER。
        let codexRow = try #require(try await database.optionalRow(
            "SELECT memory_bytes, parent_pid FROM agents WHERE id = ?",
            arguments: [.text(ParityFixture.agentCodex.uuidString)]
        ))
        #expect(codexRow.column("memory_bytes") == .integer(Int64.min),
                "超大 UInt64 必须以 Int64(bitPattern:) 存成 INTEGER，不是 REAL 也不是文本")
        #expect(codexRow.column("parent_pid") == .integer(1))
        #expect(codex.childPIDs == [], "空数组是「没有子进程」，与 NULL 不同列语义")
        #expect(codex.cpuPercent == 12.25)
        #expect(codex.detectedVia == .argumentSignature)
        #expect(codex.bundleIdentifier == nil)

        let cursor = try #require(live.dropFirst(2).first)
        #expect(cursor.workingDirectory == nil)
        #expect(cursor.bundleIdentifier == "com.todesktop.cursor")
        #expect(cursor.memoryBytes == 1_024)
        #expect(cursor.childPIDs == [4202])
        #expect(cursor.state == .idle)
    }

    /// 原来断「两边重算结果相等」；两个实现都用同一个错误口径（比如把 lines_added
    /// 当 lines_removed 累加）就看不出来。现在四个派生字段全部对照手算值。
    @Test("projectActivity 区间重算 = 手算的条数与行数", arguments: [
        ActivityTruth(range: .unbounded,
                      alpha: (changes: 4, growth: 37, shrink: 4, commands: 2),
                      beta: (changes: 3, growth: 0, shrink: 45, commands: 2)),
        ActivityTruth(range: .today(ParityFixture.now),
                      alpha: (changes: 3, growth: 36, shrink: 3, commands: 2),
                      beta: (changes: 3, growth: 0, shrink: 45, commands: 2)),
        ActivityTruth(range: DateRangeFilter(start: ParityFixture.today(0.3), end: ParityFixture.today(0.45)),
                      alpha: (changes: 1, growth: 24, shrink: 0, commands: 1),
                      beta: (changes: 3, growth: 0, shrink: 45, commands: 2)),
    ])
    func projectActivity(truth: ActivityTruth) async throws {
        let store = try await ParitySandbox.shared.services().1

        let alpha = try #require(try await store.projectActivity(path: ParityFixture.projectOne, dateRange: truth.range))
        #expect(alpha.name == "Alpha")
        #expect(alpha.fileChangeCount == truth.alpha.changes)
        #expect(alpha.codeGrowthLines == truth.alpha.growth)
        #expect(alpha.codeShrinkLines == truth.alpha.shrink)
        #expect(alpha.commandCount == truth.alpha.commands)
        // 只有这四个字段随区间重算；其余沿用库里的行值。
        #expect(alpha.sessionCount == 3)
        #expect(alpha.riskEventCount == 2)
        #expect(alpha.hotFiles.count == 2)

        let beta = try #require(try await store.projectActivity(path: ParityFixture.projectTwo, dateRange: truth.range))
        #expect(beta.fileChangeCount == truth.beta.changes)
        #expect(beta.codeGrowthLines == truth.beta.growth)
        #expect(beta.codeShrinkLines == truth.beta.shrink)
        #expect(beta.commandCount == truth.beta.commands)
        #expect(beta.sessionCount == 2)

        #expect(try await store.projectActivity(path: "/no/such/path", dateRange: truth.range) == nil)
    }
}

/// `projectActivity` 的期望：一条区间 + 两个项目在该区间内应当算出的四个数。
struct ActivityTruth: Sendable {
    let range: DateRangeFilter
    let alpha: (changes: Int, growth: Int, shrink: Int, commands: Int)
    let beta: (changes: Int, growth: Int, shrink: Int, commands: Int)
}

/// `systemPerformance(since:)` 的期望：下界 + 该当落进来的 `cpuTotalPercent` 升序序列。
struct SystemPerfTruth: Sendable {
    let since: Date
    let cpuTotals: [Double]
}

@Suite("Store Dashboard：字段级绝对真值", .timeLimit(.minutes(1)))
struct StoreDashboardTruthTests {

    /// 原来 16 个字段逐个 `expectSame(store 侧, memory 侧)`——两侧读的是同一批 fixture，
    /// 口径同时错（例如把 idle 的 agent 也算进 activeAgentCount）就全绿。
    /// 现在每个字段断手算值。结算时刻改用 `today(0.9)` 而不是 `now`：`duration(until:)`
    /// 的期望于是能写成 `elapsed` 的倍数，不随几点跑而变。
    /// （`InMemoryObservatoryService` 的 agentShares 至今读墙钟，见
    /// IFR-engine-sampledata-time-dependency；换成绝对断言后这条漂移不会再被「两边都比同样的容差」掩盖。）
    /// ⚠️ 下面的数字绑定 `dashboardStats` 当前口径：会话按 `started_at` 在今日闭区间筛。
    /// 口径若改成「与今天有交集」（WS-Verify 正在提），3 / 1.15×elapsed / 0.65 / 0.5 这些值
    /// 会一起变——那时请改口径决策记录并同步这里，别按实得值就地改写。
    @Test("dashboardStats(for:) 每个字段 = 手算值", arguments: [
        DashboardTruth(
            date: ParityFixture.today(0.9),
            sessionCount: 3, activeSecondsFactor: 1.15,
            files: (modified: 1, created: 2, deleted: 2),
            commands: (executed: 4, failed: 1),
            risks: (total: 3, high: 2),
            averageCPU: 36.9375, peakCPU: 88.25, peakMemoryBytes: 943_718_400,
            hourlyEventTotal: 8, activeAgentCount: 2,
            shareKinds: [.claudeCode, .openAICodex], shareSessionCounts: [2, 1],
            shareSecondFactors: [0.65, 0.5]
        ),
        DashboardTruth(
            date: ParityFixture.daysAgo(1, 0.9),
            sessionCount: 1, activeSecondsFactor: 0.25,
            files: (modified: 1, created: 0, deleted: 0),
            commands: (executed: 1, failed: 0),
            risks: (total: 1, high: 1),
            averageCPU: 73.125, peakCPU: 73.125, peakMemoryBytes: 4_294_967_296,
            hourlyEventTotal: 1, activeAgentCount: 2,
            shareKinds: [.cursorAgent], shareSessionCounts: [1],
            shareSecondFactors: [0.25]
        ),
    ])
    func dashboard(truth: DashboardTruth) async throws {
        let store = try await ParitySandbox.shared.services().1
        let stats = try await store.dashboardStats(for: truth.date)

        #expect(stats.date == truth.date)
        #expect(stats.sessionCount == truth.sessionCount)
        #expect(stats.filesModified == truth.files.modified)
        #expect(stats.filesCreated == truth.files.created)
        #expect(stats.filesDeleted == truth.files.deleted)
        #expect(stats.commandsExecuted == truth.commands.executed)
        #expect(stats.failedCommands == truth.commands.failed)
        #expect(stats.riskEventCount == truth.risks.total)
        #expect(stats.highRiskEventCount == truth.risks.high)
        #expect(stats.peakCPUPercent == truth.peakCPU)
        #expect(stats.peakMemoryBytes == truth.peakMemoryBytes)
        #expect(stats.averageCPUPercent == truth.averageCPU)
        #expect(stats.activeAgentCount == truth.activeAgentCount,
                "只有 running 计入活跃，idle 的 Cursor 不算")
        // Date 相减带 ~1e-7 秒舍入，按 1e-3 收；口径被改坏（漏一个会话）差的是整段秒数。
        expectApprox(stats.totalActiveSeconds, ParityFixture.elapsed * truth.activeSecondsFactor,
                     tolerance: 0.001, context: "totalActiveSeconds")

        #expect(stats.hourlyActivity.map(\.hour) == Array(0..<24), "固定 24 个桶，没有也占位")
        #expect(stats.hourlyActivity.reduce(0) { $0 + $1.eventCount } == truth.hourlyEventTotal,
                "分桶总数必须等于当日事件条数（多算/漏算都会挪动这个和）")

        #expect(stats.agentShares.map(\.kind) == truth.shareKinds)
        #expect(stats.agentShares.map(\.sessionCount) == truth.shareSessionCounts)
        for (index, share) in stats.agentShares.enumerated() where index < truth.shareSecondFactors.count {
            expectApprox(share.totalSeconds, ParityFixture.elapsed * truth.shareSecondFactors[index],
                         tolerance: 0.001, context: "agentShares[\(index)].totalSeconds")
        }
    }
}

/// Dashboard 一条结算时刻的完整手算期望。
///
/// ⚠️ **绑定口径**：这些数字成立的前提是 `ObservatoryStore.dashboardStats(for:)` 当前按
/// 「`started_at` 落在 `DateRangeFilter.today(date)` 闭区间」挑会话（＝今日新建）。
/// `totalActiveSeconds` 与 `agentShares` 同源于 `daySessions`，口径一动三者一起动。
/// 若改成「与今天有交集」（含昨天开起、今天仍在跑的），本套件期望值会变——
/// 红的时候先核口径，**不要按实得值就地改写**（见 IFR-engine-sampledata-time-dependency）。
struct DashboardTruth: Sendable {
    let date: Date
    let sessionCount: Int
    /// `totalActiveSeconds / elapsed` 的系数（`elapsed` 是 fixture 的当日时间跨度常量）。
    let activeSecondsFactor: Double
    let files: (modified: Int, created: Int, deleted: Int)
    let commands: (executed: Int, failed: Int)
    let risks: (total: Int, high: Int)
    let averageCPU: Double
    let peakCPU: Double
    let peakMemoryBytes: UInt64
    let hourlyEventTotal: Int
    let activeAgentCount: Int
    let shareKinds: [AgentKind]
    let shareSessionCounts: [Int]
    let shareSecondFactors: [Double]
}

@Suite("Store 排序与分页语义：绝对真值", .timeLimit(.minutes(1)))
struct StoreOrderingTruthTests {

    /// 原来除了 `expectSamePage`，只剩 `items.count == 3` / `totalCount == 10` /
    /// `items == items.sorted{...}` 这类「拿返回结果自己跟自己比」的断言——把顺序整个反转
    /// 也能过 `sorted` 那条。现在直接钉死第一页内容与逐页游走的不重不漏。
    @Test("事件按时间倒序返回，且 totalCount 是分页前总数")
    func orderingAndTotal() async throws {
        let store = try await ParitySandbox.shared.services().1
        let page = try await store.events(matching: EventQuery(limit: 3, offset: 0))
        #expect(page.items.map(\.title) == ["未归类行为", "重命名 Router.swift", "Network POST"])
        #expect(page.totalCount == 10)
        #expect(page.offset == 0)
        #expect(page.hasMore == true)

        var walked: [String] = []
        for offset in stride(from: 0, through: 9, by: 3) {
            let next = try await store.events(matching: EventQuery(limit: 3, offset: offset))
            #expect(next.totalCount == 10, "翻页不得改变过滤后总数（offset=\(offset)）")
            #expect(next.offset == offset)
            walked += next.items.map(\.title)
        }
        #expect(walked == ParityFixture.eventOrderDESC, "三页拼回来必须恰好等于全量倒序，不重不漏")
    }

    /// 原来只比对两边同一 offset 的结果；`LIMIT ? OFFSET ?` 写成 `OFFSET ? LIMIT ?`
    /// 之类的错位两边会一起错。现在每个 offset 钉死窗口内容与 hasMore。
    @Test("offset 边界：窗口内容、totalCount 与 hasMore 都等于手算值", arguments: [
        PageWindowTruth(offset: 0, titles: ["未归类行为", "重命名 Router.swift", "Network POST"], hasMore: true),
        PageWindowTruth(offset: 1, titles: ["重命名 Router.swift", "Network POST", "git push origin main"], hasMore: true),
        PageWindowTruth(offset: 5, titles: ["swift test", "修改文件 · AuthService.swift", "Agent 启动 · Claude Code"], hasMore: true),
        PageWindowTruth(offset: 9, titles: ["风险事件 · 危险命令"], hasMore: false),
        PageWindowTruth(offset: 10, titles: [], hasMore: false),
        PageWindowTruth(offset: 40, titles: [], hasMore: false),
    ])
    func offsetEdges(truth: PageWindowTruth) async throws {
        let store = try await ParitySandbox.shared.services().1
        let page = try await store.events(matching: EventQuery(limit: 3, offset: truth.offset))
        #expect(page.items.map(\.title) == truth.titles, "offset=\(truth.offset) 的窗口内容")
        #expect(page.totalCount == 10)
        #expect(page.offset == truth.offset, "offset 必须原样回传，越界也不例外")
        #expect(page.hasMore == truth.hasMore)
    }

    /// 原来把「降序 == 升序的 reversed」当期望——那是恒真式（两边同序就绿）。
    /// 现在两侧各钉一份手算序列。
    @Test("升序与降序各自等于手算序列")
    func reverseOrderingMatches() async throws {
        let store = try await ParitySandbox.shared.services().1
        let ascending = try await store.events(matching: EventQuery(sort: .oldestFirst))
        #expect(ascending.items.map(\.title) == ParityFixture.eventOrderASC)
        #expect(ascending.totalCount == 10)
        let descending = try await store.events(matching: EventQuery(sort: .newestFirst))
        #expect(descending.items.map(\.title) == ParityFixture.eventOrderDESC)
        #expect(descending.totalCount == 10)
    }

    /// 原来断的是 `allSatisfy { $0.riskLevel >= level }`：空集也满足，且两边同用
    /// rawValue 字典序时（'critical' < 'high' < 'low' < 'medium'）它照样绿。
    /// 现在按等级钉死命中条数与内容。
    @Test("风险等级按 rank 过滤，命中集等于手算结果", arguments: [
        RiskFilterTruth(level: .low, titles: [
            "未归类行为", "重命名 Router.swift", "Network POST", "git push origin main",
            "删除文件 · 旧配置", "swift test", "修改文件 · AuthService.swift",
            "Agent 启动 · Claude Code", "修改 /etc/hosts", "风险事件 · 危险命令",
        ]),
        RiskFilterTruth(level: .medium, titles: [
            "Network POST", "删除文件 · 旧配置", "swift test", "修改文件 · AuthService.swift",
            "修改 /etc/hosts", "风险事件 · 危险命令",
        ]),
        RiskFilterTruth(level: .high, titles: [
            "删除文件 · 旧配置", "swift test", "修改 /etc/hosts", "风险事件 · 危险命令",
        ]),
        RiskFilterTruth(level: .critical, titles: ["删除文件 · 旧配置", "风险事件 · 危险命令"]),
    ])
    func riskLevelOrdersByRank(truth: RiskFilterTruth) async throws {
        let store = try await ParitySandbox.shared.services().1
        let page = try await store.events(matching: EventQuery(minimumRisk: truth.level))
        #expect(page.items.map(\.title) == truth.titles, "minimumRisk=\(truth.level)")
        #expect(page.totalCount == truth.titles.count)
        #expect(page.items.allSatisfy { $0.riskLevel >= truth.level })
    }

    /// 原来只断「两边命中同一条」——两边都用 `LIKE` 且都大小写敏感时也是绿。
    /// 现在钉死每个大小写变体的命中内容。
    @Test("搜索大小写不敏感：命中内容等于手算结果", arguments: [
        SearchTruth(needle: "GIT PUSH", eventTitles: ["git push origin main"], fileNames: []),
        SearchTruth(needle: "git push", eventTitles: ["git push origin main"], fileNames: []),
        SearchTruth(needle: "Push", eventTitles: ["git push origin main"], fileNames: []),
        SearchTruth(needle: "config.old", eventTitles: [], fileNames: ["CONFIG.OLD"]),
        SearchTruth(needle: "CONFIG.OLD", eventTitles: [], fileNames: ["CONFIG.OLD"]),
        SearchTruth(needle: "CoNfIg.oLd", eventTitles: [], fileNames: ["CONFIG.OLD"]),
    ])
    func caseInsensitiveSearchHits(truth: SearchTruth) async throws {
        let store = try await ParitySandbox.shared.services().1
        let events = try await store.events(matching: EventQuery(searchText: truth.needle))
        #expect(events.items.map(\.title) == truth.eventTitles, "事件搜索 \(truth.needle)")
        let changes = try await store.fileChanges(matching: FileChangeQuery(searchText: truth.needle))
        #expect(changes.items.map { ($0.path as NSString).lastPathComponent } == truth.fileNames,
                "文件搜索 \(truth.needle)")
    }
}

/// `events(limit: 3, offset:)` 一个窗口的期望。
struct PageWindowTruth: Sendable {
    let offset: Int
    let titles: [String]
    let hasMore: Bool
}

/// `EventQuery(minimumRisk:)` 的期望命中集。
struct RiskFilterTruth: Sendable {
    let level: RiskLevel
    let titles: [String]
}

/// 一个大小写变体搜索串在两个表上应当命中什么。
struct SearchTruth: Sendable {
    let needle: String
    let eventTitles: [String]
    let fileNames: [String]
}
