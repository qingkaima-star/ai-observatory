//
//  MarkdownReportExporterTests.swift
//  AIObservatoryExportTests
//
//  Owner: WS-Export（子代理 C）
//
//  MarkdownReportExporter 的验收测试。样本全部自建（AIObservatoryCore 模型 init），
//  不 import AIObservatoryTestSupport。
//  断言不靠手改期望串：`ReportProbe` 是本文件内的最小 Markdown 结构探查器
//  （章节切分 / 表格分组 / 单元拆分，识别 `\|` 转义竖线），
//  于是「表格被内容击穿」这类问题会直接表现为断言失败。
//  时间一律注入固定 `baseline` / `generatedAt`：不读墙钟、不 sleep、不起线程。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
import AIObservatoryExport

// MARK: - 样本工厂

/// 报告测试样本：全部时间戳显式注入、UUID 由下标推导，因此与运行时刻无关。
enum ReportFixtures {
    /// 固定基线时间：所有记录时间由它推导。
    static let baseline = Date(timeIntervalSince1970: 1_800_000_000)
    /// 报告生成时刻（运行中会话时长的终点）。
    static let generatedAt = Date(timeIntervalSince1970: 1_800_000_000 + 3_600)

    /// 测试产物根：当前检出自带的 `.scratch-tests/`，允许根为其父目录（`ExportWriter` 的路径策略要求）。
    static let scratchRoot = Scratch.root
    static let scratchBase = scratchRoot
        .appendingPathComponent("export", isDirectory: true)
        .appendingPathComponent("markdown", isDirectory: true)

    /// 理论不可达的回退值（避免强解包 / `try!`）。
    static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                      0, 0, 0, 0, 0, 0, 0, 0))

    /// 由下标生成稳定 UUID。
    static func uuid(_ index: Int) -> UUID {
        let value = UInt32(truncatingIfNeeded: index)
        let hex = String(format: "%08X-0000-0000-0000-%012X", value, value)
        return UUID(uuidString: hex) ?? zeroUUID
    }

    /// ISO8601（UTC）文本：与导出器同一编码器，断言里不重复实现格式化规则。
    static func iso(_ date: Date) -> String { ExportDateEncoder().string(date) }

    /// 一个会话记录。`endedAt == nil` 表示仍在运行。
    static func session(index: Int, displayIndex: Int? = nil, title: String = "普通会话",
                        startedAt: Date? = nil, endedAt: Date? = nil,
                        created: Int = 0, modified: Int = 0, deleted: Int = 0,
                        commands: Int = 0, failedCommands: Int = 0,
                        cpuSeconds: Double = 0, peakMemoryBytes: UInt64 = 0,
                        riskEvents: Int = 0, outcome: SessionOutcome = .success,
                        projectPath: String? = FixturePaths.projectRoot) -> ExportRecord {
        let start = startedAt ?? baseline.addingTimeInterval(Double(index) * 60)
        return .session(AgentSession(
            id: uuid(index),
            displayIndex: displayIndex ?? (100 + index),
            kind: .claudeCode,
            title: title,
            projectPath: projectPath,
            startedAt: start,
            endedAt: endedAt,
            modifiedFileCount: modified,
            createdFileCount: created,
            deletedFileCount: deleted,
            commandCount: commands,
            failedCommandCount: failedCommands,
            cpuSeconds: cpuSeconds,
            peakCPUPercent: 12.5,
            peakMemoryBytes: peakMemoryBytes,
            estimatedTokens: 4_000 + index,
            riskEventCount: riskEvents,
            outcome: outcome
        ))
    }

    /// 一条时间线事件。
    static func event(index: Int, title: String = "读取文件", summary: String = "普通摘要",
                      riskLevel: RiskLevel = .low, command: String? = nil) -> ExportRecord {
        .event(TimelineEvent(
            id: uuid(index),
            timestamp: baseline.addingTimeInterval(Double(index)),
            sessionID: uuid(900_000),
            agentKind: .claudeCode,
            kind: .fileRead,
            title: title,
            summary: summary,
            filePath: FixturePaths.inProjectRoot("Sources/App.swift"),
            command: command,
            exitCode: 0,
            durationSeconds: 1.5,
            cost: ResourceCost(cpuSeconds: 0.25, memoryBytes: 2_048, bytesRead: 4_096, bytesWritten: 0),
            riskLevel: riskLevel,
            projectPath: FixturePaths.projectRoot
        ))
    }

    /// 一条文件变更记录。
    static func fileChange(index: Int, path: String = FixturePaths.inProjectRoot("Sources/App.swift"),
                           riskLevel: RiskLevel = .low) -> ExportRecord {
        .fileChange(FileChange(
            id: uuid(index),
            path: path,
            kind: .modified,
            timestamp: baseline.addingTimeInterval(Double(index)),
            sessionID: uuid(900_000),
            agentKind: .claudeCode,
            sizeBytes: 1_024,
            isText: true,
            linesAdded: 10,
            linesRemoved: 2,
            riskLevel: riskLevel,
            projectPath: FixturePaths.projectRoot
        ))
    }

    /// 一条命令记录（`executable` + `arguments` 拼出命令行）。
    static func command(index: Int, executable: String, arguments: [String] = [],
                        startedAt: Date? = nil, exitCode: Int32? = 0,
                        isDestructive: Bool = false, requiresConfirmation: Bool = false,
                        riskLevel: RiskLevel = .low) -> ExportRecord {
        let start = startedAt ?? baseline.addingTimeInterval(Double(index))
        return .command(CommandRecord(
            id: uuid(index),
            executable: executable,
            arguments: arguments,
            workingDirectory: FixturePaths.projectRoot,
            sessionID: uuid(900_000),
            agentKind: .genericCLIAgent,
            startedAt: start,
            endedAt: start.addingTimeInterval(0.5),
            exitCode: exitCode,
            outcome: .success,
            isDestructive: isDestructive,
            requiresConfirmation: requiresConfirmation,
            riskLevel: riskLevel,
            projectPath: FixturePaths.projectRoot
        ))
    }

    /// 一条风险事件。
    static func risk(index: Int, level: RiskLevel, title: String = "批量删除",
                     detail: String = "命中规则 mass_deletion",
                     command: String? = nil, filePaths: [String] = []) -> ExportRecord {
        .riskEvent(RiskEvent(
            id: uuid(index),
            timestamp: baseline.addingTimeInterval(Double(index)),
            level: level,
            category: .massDeletion,
            title: title,
            detail: detail,
            agentKind: .claudeCode,
            sessionID: uuid(900_000),
            command: command,
            filePaths: filePaths,
            requiresConfirmation: true,
            isAcknowledged: false,
            matchedRuleID: "R-01"
        ))
    }

    /// 一个热文件条目（时间显式注入）。
    static func heat(index: Int, path: String, changeCount: Int, linesAdded: Int = 0,
                     linesRemoved: Int = 0, lastTouchedOffset: Double = 0) -> FileHeat {
        FileHeat(id: uuid(700_000 + index), path: path, changeCount: changeCount,
                 linesAdded: linesAdded, linesRemoved: linesRemoved,
                 lastTouchedAt: baseline.addingTimeInterval(lastTouchedOffset))
    }

    /// 一个项目活动地图。
    static func project(name: String, hotFiles: [FileHeat]) -> ProjectActivity {
        ProjectActivity(id: "/repo/\(name)", name: name, path: "/repo/\(name)",
                        fileChangeCount: hotFiles.reduce(0) { $0 + $1.changeCount },
                        commandCount: 0, sessionCount: 0, riskEventCount: 0,
                        codeGrowthLines: 0, codeShrinkLines: 0, agentContributions: [],
                        hotFiles: hotFiles,
                        firstSeenAt: baseline, lastSeenAt: baseline)
    }

    /// 固定时刻的报告输入。
    static func input(records: [ExportRecord], projects: [ProjectActivity] = [],
                      generatedAt: Date? = nil,
                      dateRange: DateRangeFilter = .unbounded) -> MarkdownReportExporter.Input {
        MarkdownReportExporter.Input(records: records, projects: projects,
                                     generatedAt: generatedAt ?? self.generatedAt,
                                     dateRange: dateRange)
    }

    /// 覆盖全部章节的固定输入（确定性断言与落盘断言共用同一份）。
    static var richInput: MarkdownReportExporter.Input {
        let records: [ExportRecord] = [
            session(index: 1, displayIndex: 101, title: "重构导出层", startedAt: baseline,
                    endedAt: baseline.addingTimeInterval(90), created: 2, modified: 5, deleted: 1,
                    commands: 12, failedCommands: 2, cpuSeconds: 1.5, peakMemoryBytes: 4_096,
                    riskEvents: 1, outcome: .success),
            session(index: 2, displayIndex: 102, title: "排查登录崩溃",
                    startedAt: baseline.addingTimeInterval(120), endedAt: nil,
                    modified: 1, commands: 3, cpuSeconds: 2.5, peakMemoryBytes: 8_192,
                    outcome: .running),
            event(index: 11, title: "读取 Package.swift"),
            event(index: 12, title: "执行命令", summary: "耗时 1.5 秒",
                  riskLevel: .high, command: "swift test"),
            fileChange(index: 13),
            command(index: 21, executable: "rm", arguments: ["-rf", "/tmp/build-cache"],
                    isDestructive: true, requiresConfirmation: true, riskLevel: .critical),
            command(index: 22, executable: "git", arguments: ["push", "origin", "main"]),
            risk(index: 31, level: .critical, command: "rm -rf /tmp/build-cache",
                 filePaths: ["/tmp/build-cache"]),
            risk(index: 32, level: .low, title: "低危提示"),
        ]
        let projects = [
            project(name: "Alpha", hotFiles: [
                heat(index: 1, path: "/repo/App.swift", changeCount: 4, linesAdded: 40,
                     linesRemoved: 12, lastTouchedOffset: 300),
                heat(index: 2, path: "/repo/Core.swift", changeCount: 2, lastTouchedOffset: 200),
            ]),
            project(name: "Beta", hotFiles: [
                heat(index: 3, path: "/repo/App.swift", changeCount: 3, linesAdded: 7,
                     linesRemoved: 2, lastTouchedOffset: 100),
                heat(index: 4, path: "/repo/UI.swift", changeCount: 3, lastTouchedOffset: 50),
            ]),
        ]
        return input(records: records, projects: projects,
                     dateRange: DateRangeFilter(start: baseline.addingTimeInterval(-600),
                                                end: generatedAt))
    }
}

// MARK: - Markdown 结构探查器（测试专用）

/// 最小 Markdown 结构探查：章节切分 + 表格分组 + 单元拆分（识别 `\|` 转义竖线）。
private enum ReportProbe {

    /// 按 LF 切行（保留空行）。
    static func lines(_ report: String) -> [String] {
        report.components(separatedBy: "\n")
    }

    /// 某个 `## ` 章节的正文行（不含标题本身；止于下一个 `## ` 标题或 `---` 页脚）。
    static func section(_ report: String, titled title: String) -> [String] {
        let all = lines(report)
        guard let start = all.firstIndex(of: title) else { return [] }
        var body: [String] = []
        for line in all[(start + 1)...] {
            if line.hasPrefix("## ") || line == "---" { break }
            body.append(line)
        }
        return body
    }

    /// 章节内的表格行（以 `|` 开头的行）。
    static func tableLines(in body: [String]) -> [String] {
        body.filter { $0.hasPrefix("|") }
    }

    /// 文档中全部表格块：连续以 `|` 开头的行归为一个表。
    static func tables(_ report: String) -> [[String]] {
        var result: [[String]] = []
        var current: [String] = []
        for line in lines(report) {
            if line.hasPrefix("|") {
                current.append(line)
            } else if current.isEmpty == false {
                result.append(current)
                current = []
            }
        }
        if current.isEmpty == false { result.append(current) }
        return result
    }

    /// 原始 `|` 个数（含被转义的 `\|`）。
    static func rawPipeCount(_ line: String) -> Int { line.filter { $0 == "|" }.count }

    /// 「结构上」的竖线个数：`\|` 属于单元内容，不计为列分隔符。
    static func delimiterPipeCount(_ line: String) -> Int {
        var count = 0
        var previousWasBackslash = false
        for character in line {
            if character == "|" && previousWasBackslash == false { count += 1 }
            previousWasBackslash = (character == "\\")
        }
        return count
    }

    /// 拆出一个表格行的全部单元（`\|` 还原为 `|`，单元首尾空白裁掉）。
    static func cells(_ line: String) -> [String] {
        var body = Substring(line)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|") { body = body.dropLast() }
        var result: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                current.append(character)
                escaped = false
                continue
            }
            if character == "\\" {
                escaped = true
                continue
            }
            if character == "|" {
                result.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                continue
            }
            current.append(character)
        }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }

    /// 概览表 → `[指标名: 数值]`（跳过表头与分隔行）。
    static func overviewValues(_ report: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in tableLines(in: section(report, titled: "## 概览")) {
            let row = cells(line)
            guard row.count == 2, row[0] != "指标", row[0] != "---" else { continue }
            result[row[0]] = row[1]
        }
        return result
    }

    /// 按表头首列文字定位一个表，返回其数据行（跳过表头与分隔行）。
    static func dataRows(ofTableWithHeader headerFirstCell: String, in report: String) -> [[String]] {
        for table in tables(report) {
            guard let header = table.first, cells(header).first == headerFirstCell else { continue }
            return table.dropFirst(2).map { cells($0) }
        }
        return []
    }
}

// MARK: - 小工具

/// 越界安全的下标访问（测试里不写强解包 / 不冒崩溃风险）。
private func row(of rows: [[String]], at index: Int) -> [String]? {
    guard index >= 0, index < rows.count else { return nil }
    return rows[index]
}

// MARK: - 测试

@Suite("MarkdownReportExporter · 人读审计报告")
struct MarkdownReportExporterTests {

    // 1 · 确定性

    @Test("同一 Input 两次 report 逐字节相同，且与流式 write 一致")
    func sameInputProducesIdenticalText() throws {
        let input = ReportFixtures.richInput
        let first = try MarkdownReportExporter.report(input: input)
        let second = try MarkdownReportExporter.report(input: input)
        #expect(first == second)
        #expect(first.isEmpty == false)
        #expect(first.hasSuffix("\n"))
        #expect(first.contains("\r") == false)

        // write(...) 到 memory sink 必须与 report(...) 完全一致（report 就是它的封装）
        var writer = ExportWriter.memory()
        try MarkdownReportExporter.write(input: input, redactor: .standard, to: &writer)
        try writer.finish()
        let streamed = String(decoding: try writer.collectedData(), as: UTF8.self)
        #expect(streamed == first)
        #expect(writer.chunkCount >= 1)
        #expect(writer.bytesWritten == Data(first.utf8).count)

        // 记录数组顺序不影响输出：聚合前先做了确定性归一排序
        var reorderedRecords = input
        reorderedRecords.records = input.records.reversed()
        #expect(try MarkdownReportExporter.report(input: reorderedRecords) == first)

        // 项目数组顺序同样不影响 Top 热文件
        var reorderedProjects = input
        reorderedProjects.projects = input.projects.reversed()
        #expect(try MarkdownReportExporter.report(input: reorderedProjects) == first)
    }

    // 2 · 空输入

    @Test("空输入仍产出全部章节标题，危险章节写「无」")
    func emptyInputStillProducesAllSections() throws {
        let input = ReportFixtures.input(records: [], projects: [])
        let report = try MarkdownReportExporter.report(input: input)

        #expect(report.contains("# AI Agent 活动审计报告"))
        #expect(report.contains("## 概览"))
        #expect(report.contains("## 最常被改动的文件"))
        #expect(report.contains("## 危险命令与高风险事件"))
        #expect(report.contains("## 逐会话摘要"))
        #expect(report.contains(ReportFixtures.iso(ReportFixtures.generatedAt)))
        // dateRange 两端都为 nil → 「不限」
        #expect(report.contains("不限"))

        let dangerBody = ReportProbe.section(report, titled: "## 危险命令与高风险事件")
        #expect(dangerBody.contains("无"))
        #expect(ReportProbe.tableLines(in: dangerBody).isEmpty)
        #expect(ReportProbe.section(report, titled: "## 最常被改动的文件").contains("无"))
        #expect(ReportProbe.section(report, titled: "## 逐会话摘要").contains("无"))

        let values = ReportProbe.overviewValues(report)
        #expect(values["会话数"] == "0")
        #expect(values["事件数"] == "0")
        #expect(values["文件变更数"] == "0")
        #expect(values["命令数"] == "0")
        #expect(values["风险事件数"] == "0")
        #expect(values["高危及以上风险数"] == "0")
        #expect(values["破坏性命令数"] == "0")
        #expect(values["总 CPU 秒"] == "0.000")
        #expect(values["峰值内存字节"] == "0")
        #expect(values["涉及项目数"] == "0")
    }

    // 3 · 概览数字与手算一致

    @Test("概览表数字与手算一致，危险命令进入清单")
    func overviewNumbersMatchHandAggregation() throws {
        // 3 会话（CPU 1.5 + 2.5 + 3.0 = 7.000；峰值内存 max = 4096）
        // 5 事件（全部 LOW）· 0 文件变更 · 2 命令（1 条破坏性且 HIGH）· 1 条 CRITICAL 风险
        let records: [ExportRecord] = [
            ReportFixtures.session(index: 1, cpuSeconds: 1.5, peakMemoryBytes: 1_024),
            ReportFixtures.session(index: 2, cpuSeconds: 2.5, peakMemoryBytes: 4_096),
            ReportFixtures.session(index: 3, cpuSeconds: 3.0, peakMemoryBytes: 2_048),
            ReportFixtures.event(index: 11, title: "事件 1"),
            ReportFixtures.event(index: 12, title: "事件 2"),
            ReportFixtures.event(index: 13, title: "事件 3"),
            ReportFixtures.event(index: 14, title: "事件 4"),
            ReportFixtures.event(index: 15, title: "事件 5"),
            ReportFixtures.command(index: 21, executable: "rm", arguments: ["-rf", "/tmp/cache"],
                                   isDestructive: true, requiresConfirmation: true, riskLevel: .high),
            ReportFixtures.command(index: 22, executable: "git", arguments: ["status"]),
            ReportFixtures.risk(index: 31, level: .critical),
        ]
        let report = try MarkdownReportExporter.report(input: ReportFixtures.input(records: records))
        let values = ReportProbe.overviewValues(report)

        #expect(values["会话数"] == "3")
        #expect(values["事件数"] == "5")
        #expect(values["文件变更数"] == "0")
        #expect(values["命令数"] == "2")
        #expect(values["风险事件数"] == "1")
        // 高危及以上：1 条 HIGH 命令 + 1 条 CRITICAL 风险事件
        #expect(values["高危及以上风险数"] == "2")
        #expect(values["破坏性命令数"] == "1")
        #expect(values["总 CPU 秒"] == "7.000")
        #expect(values["峰值内存字节"] == "4096")
        #expect(values["涉及项目数"] == "0")

        // 危险命令清单：只有那条破坏性命令入选
        #expect(ReportProbe.dataRows(ofTableWithHeader: "开始时间", in: report).count == 1)
        let dangerBody = ReportProbe.section(report, titled: "## 危险命令与高风险事件")
        #expect(dangerBody.contains { $0.contains("rm -rf /tmp/cache") })
        #expect(dangerBody.contains { $0.contains("HIGH") })
        #expect(dangerBody.contains { $0.contains("true") })
        #expect(dangerBody.contains { $0.contains("git status") } == false)
        // CRITICAL 风险事件进清单
        #expect(dangerBody.contains { $0.contains("CRITICAL") })
        #expect(dangerBody.contains { $0.contains("批量删除") })
        // 逐会话摘要：3 段
        let sessionsBody = ReportProbe.section(report, titled: "## 逐会话摘要")
        #expect(sessionsBody.filter { $0.hasPrefix("### ") }.count == 3)
    }

    // 4 · Top 热文件

    @Test("Top 热文件：跨项目按 path 合并，改动次数降序、同值 path 升序，上限 10")
    func topHotFilesMergeAndSortDeterministically() throws {
        let tieFromA = (1...8).map { ReportFixtures.heat(index: $0, path: "/tie/x0\($0)", changeCount: 1) }
        let tieFromB = (9...10).map { ReportFixtures.heat(index: $0, path: "/tie/x\($0)", changeCount: 1) }
        let projects = [
            ReportFixtures.project(name: "Alpha", hotFiles: [
                ReportFixtures.heat(index: 21, path: "/shared/App.swift", changeCount: 4,
                                    linesAdded: 10, linesRemoved: 3, lastTouchedOffset: 100),
                ReportFixtures.heat(index: 22, path: "/a/only.swift", changeCount: 2),
                ReportFixtures.heat(index: 23, path: "/shared/README.md", changeCount: 1),
            ] + tieFromA),
            ReportFixtures.project(name: "Beta", hotFiles: [
                ReportFixtures.heat(index: 31, path: "/shared/App.swift", changeCount: 3,
                                    linesAdded: 5, linesRemoved: 1, lastTouchedOffset: 50),
                ReportFixtures.heat(index: 32, path: "/b/only.swift", changeCount: 2),
                ReportFixtures.heat(index: 33, path: "/shared/README.md", changeCount: 5),
            ] + tieFromB),
        ]
        let report = try MarkdownReportExporter.report(
            input: ReportFixtures.input(records: [], projects: projects)
        )
        let rows = ReportProbe.dataRows(ofTableWithHeader: "文件路径", in: report)

        // 合并后 14 个不同 path → 只写前 reportTopFiles 条
        #expect(rows.count == ExportConstants.reportTopFiles)
        #expect(rows.count <= ExportConstants.reportTopFiles)
        #expect(rows.compactMap { $0.first } == [
            "/shared/App.swift", "/shared/README.md", "/a/only.swift", "/b/only.swift",
            "/tie/x01", "/tie/x02", "/tie/x03", "/tie/x04", "/tie/x05", "/tie/x06",
        ])
        // 跨项目合并：4+3=7 次改动、10+5=15 新增行、3+1=4 删除行、最近改动取最大（+100）
        #expect(rows.first?.count == 5)
        let top = rows.first ?? []
        #expect(top.count == 5)
        if top.count == 5 {
            #expect(top[1] == "7")
            #expect(top[2] == "15")
            #expect(top[3] == "4")
            #expect(top[4] == ReportFixtures.iso(ReportFixtures.baseline.addingTimeInterval(100)))
        }
        #expect(row(of: rows, at: 1)?[1] == "6")
        // 同值这一档按 path 升序：/a 在 /b 之前
        #expect(row(of: rows, at: 2)?.first == "/a/only.swift")
        #expect(row(of: rows, at: 3)?.first == "/b/only.swift")
        // 截断：/tie/x07 未列出
        #expect(report.contains("/tie/x07") == false)
    }

    // 5 · 脱敏

    @Test("会话标题 / 命令 / 事件摘要 / 风险详情中的凭据不落盘")
    func credentialsNeverReachTheOutput() throws {
        let apiKey = "sk-ABCDEFGHIJKLMNOP1234"
        let password = "password=hunter2"
        let records: [ExportRecord] = [
            ReportFixtures.session(index: 41, title: "用 \(apiKey) 调模型"),
            ReportFixtures.command(index: 42, executable: "psql", arguments: ["--\(password)"],
                                   isDestructive: true, riskLevel: .high),
            ReportFixtures.risk(index: 43, level: .critical, title: "凭据外泄 \(apiKey)",
                                detail: "检出 \(password) 与 \(apiKey)", command: "curl -u \(password)"),
            ReportFixtures.event(index: 44, summary: "摘要里也有 \(apiKey)", riskLevel: .high),
        ]
        let input = ReportFixtures.input(records: records)
        let report = try MarkdownReportExporter.report(input: input, redactor: .standard)

        #expect(report.contains(ExportConstants.redactionPrefix))
        #expect(report.contains("ABCDEFGHIJKLMNOP1234") == false)
        #expect(report.contains(apiKey) == false)
        #expect(report.contains("hunter2") == false)
        #expect(report.contains(password) == false)
        // 键名保留、只掩值（脱敏器语义），因此表格仍可分析
        #expect(report.contains("password=" + ExportConstants.redactionPrefix))

        // 关闭脱敏 → 原文出现（反证上面确实命中了我造的样本）
        let raw = try MarkdownReportExporter.report(input: input, redactor: .disabled)
        #expect(raw.contains(apiKey))
        #expect(raw.contains("hunter2"))
        #expect(raw.contains(ExportConstants.redactionPrefix) == false)
    }

    // 6 · 表格结构

    @Test("自由文本含竖线与换行时表格不被破坏")
    func tablesSurvivePipesAndNewlines() throws {
        let records: [ExportRecord] = [
            ReportFixtures.command(index: 51, executable: "rm", arguments: ["/a|b\nc"],
                                   isDestructive: true, riskLevel: .high),
            ReportFixtures.risk(index: 52, level: .high, title: "标题|带竖线\n与换行",
                                detail: "详情|第二行", filePaths: ["/x|y"]),
            ReportFixtures.event(index: 53, title: "事件|甲\n乙", summary: "摘要, 带逗号与|竖线",
                                 riskLevel: .high),
        ]
        let projects = [ReportFixtures.project(name: "Odd", hotFiles: [
            ReportFixtures.heat(index: 51, path: "/tmp/we|ird\npath.swift", changeCount: 9),
        ])]
        let report = try MarkdownReportExporter.report(
            input: ReportFixtures.input(records: records, projects: projects)
        )

        // 概览表：每一行的 `|` 个数与表头一致（2 列 → 3 个竖线）
        let overviewTable = ReportProbe.tableLines(in: ReportProbe.section(report, titled: "## 概览"))
        #expect(overviewTable.isEmpty == false)
        let headerCount = ReportProbe.rawPipeCount(overviewTable.first ?? "")
        #expect(headerCount == 3)
        #expect(overviewTable.allSatisfy { ReportProbe.rawPipeCount($0) == headerCount })
        #expect(overviewTable.allSatisfy { ReportProbe.delimiterPipeCount($0) == headerCount })
        // 概览表行数不受外部内容影响：表头 + 分隔 + 10 个指标
        #expect(overviewTable.count == 12)

        // 全文档体检：每个表的结构竖线数一致，且没有行被内容里的换行撕开
        let tables = ReportProbe.tables(report)
        #expect(tables.count >= 3)
        for table in tables {
            let expected = ReportProbe.delimiterPipeCount(table.first ?? "")
            #expect(expected >= 2)
            #expect(table.allSatisfy { ReportProbe.delimiterPipeCount($0) == expected })
            #expect(table.allSatisfy { $0.hasSuffix("|") })
        }

        // 竖线被转义、换行被折叠为单空格（内容没丢，结构没破）
        #expect(report.contains("rm /a\\|b c"))
        #expect(report.contains("详情\\|第二行"))
        #expect(report.contains("摘要, 带逗号与\\|竖线"))
        #expect(report.contains("/tmp/we\\|ird path.swift"))
        #expect(report.contains("/a|b\nc") == false)
    }

    // 7 · 落盘一致性

    @Test("写入磁盘文件：字节与 report(...) 的 UTF-8 完全相同")
    func fileSinkMatchesReportString() throws {
        let caseDirectory = ReportFixtures.scratchBase
            .appendingPathComponent("report-file", isDirectory: true)
        let fileURL = caseDirectory.appendingPathComponent("report.md", isDirectory: false)
        let manager = FileManager.default
        try manager.createDirectory(at: caseDirectory, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: caseDirectory) }

        var writer = try ExportWriter.file(fileURL, allowedRoots: [ReportFixtures.scratchRoot])
        #expect(writer.destinationURL == fileURL)
        try MarkdownReportExporter.write(input: ReportFixtures.richInput, redactor: .standard, to: &writer)
        try writer.finish()

        let onDisk = try Data(contentsOf: fileURL)
        let expected = Array(try MarkdownReportExporter.report(input: ReportFixtures.richInput).utf8)
        #expect(onDisk.isEmpty == false)
        #expect(Array(onDisk) == expected)
        #expect(writer.bytesWritten == onDisk.count)
        #expect(String(decoding: onDisk, as: UTF8.self).hasPrefix("# AI Agent 活动审计报告\n"))
    }

    // 8 · 运行中会话时长只来自注入时间

    @Test("运行中会话时长来自 generatedAt，不读墙钟")
    func runningSessionDurationComesFromGeneratedAt() throws {
        let startedAt = ReportFixtures.baseline
        let records = [ReportFixtures.session(index: 61, title: "还在跑", startedAt: startedAt,
                                              endedAt: nil, outcome: .running)]

        let at120 = try MarkdownReportExporter.report(
            input: ReportFixtures.input(records: records, generatedAt: startedAt.addingTimeInterval(120))
        )
        let at180 = try MarkdownReportExporter.report(
            input: ReportFixtures.input(records: records, generatedAt: startedAt.addingTimeInterval(180))
        )
        #expect(at120.contains("120.0 秒"))
        #expect(at120.contains("180.0 秒") == false)
        #expect(at180.contains("180.0 秒"))
        #expect(at120.contains("进行中"))
        #expect(at120.contains("#161 ·"))

        // 已结束会话：用 endedAt - startedAt，不受 generatedAt 影响
        let closed = [ReportFixtures.session(index: 62, title: "跑完了", startedAt: startedAt,
                                             endedAt: startedAt.addingTimeInterval(90))]
        let closedReport = try MarkdownReportExporter.report(
            input: ReportFixtures.input(records: closed, generatedAt: startedAt.addingTimeInterval(50_000))
        )
        #expect(closedReport.contains("90.0 秒"))
        #expect(closedReport.contains("50000.0 秒") == false)
    }

    // 9 · 统计区间生效

    @Test("统计区间过滤记录，并在头部如实说明")
    func dateRangeScopesTheAggregation() throws {
        let records: [ExportRecord] = [
            ReportFixtures.session(index: 71, startedAt: ReportFixtures.baseline,
                                   endedAt: ReportFixtures.baseline.addingTimeInterval(10)),
            ReportFixtures.session(index: 72,
                                   startedAt: ReportFixtures.baseline.addingTimeInterval(2_000),
                                   endedAt: ReportFixtures.baseline.addingTimeInterval(2_010)),
            ReportFixtures.event(index: 2_500),
        ]
        let ranged = ReportFixtures.input(
            records: records,
            dateRange: DateRangeFilter(start: ReportFixtures.baseline.addingTimeInterval(1_000), end: nil)
        )
        let report = try MarkdownReportExporter.report(input: ranged)
        let values = ReportProbe.overviewValues(report)
        #expect(values["会话数"] == "1")
        #expect(values["事件数"] == "1")
        #expect(report.contains("区间外已排除 1 条"))
        // start 有值 → 具体时刻；end 为 nil → 「不限」
        #expect(report.contains(ReportFixtures.iso(ReportFixtures.baseline.addingTimeInterval(1_000))))
        #expect(report.contains("不限"))
    }
}

// MARK: - #66 产物字节基线探针（拆 writeDangerSection 前后对拍；A/B 完成后换成钉死摘要的正式断言）

import CryptoKit

@Suite("Export: 报告字节基线（#66）")
struct MarkdownReportByteBaselineTests {

    /// 整份报告的 sha256 —— 拆 `writeDangerSection` 前后各跑一次，两种语言的摘要逐字符相同，
    /// 于是把它钉成常驻守卫：以后任何人改了报告的**任意一个字节**（不只是危险段）都会在这里红。
    /// 来源：`45f5b352…` / `b78f108f…` 由重构**前**的代码（`git stash` 退回 HEAD 版）实测得到，
    /// 重构后再测一次完全一致 ⇒ 这两个数是"改前基线"，不是为了让用例变绿而抄的实测值。
    private static let baselines: [(AppLanguage, String, Int)] = [
        (.chineseSimplified, "45f5b35284c576d52e4efc9217ff1cf8c339146580a171882738a308eaecb3f0", 2875),
        (.english, "b78f108feb23b91bf790cb4cdb56a28a75bf54afca7a5fb8ee7b696aee704207", 3011),
    ]

    @Test("同一份固定输入渲染出的报告，字节摘要与长度逐位不变")
    func reportBytesMatchThePinnedBaseline() throws {
        for (language, digest, bytes) in Self.baselines {
            var input = ReportFixtures.richInput
            input.interfaceLanguage = language
            let report = try MarkdownReportExporter.report(input: input)
            #expect(report.utf8.count == bytes, "\(language) 的报告长度漂了")
            #expect(SHA256.hash(data: Data(report.utf8)).map { String(format: "%02x", $0) }.joined() == digest,
                    "\(language) 的报告字节变了：这一改动会连带影响导出对账与红acted 枚举用例")
        }
    }
}
