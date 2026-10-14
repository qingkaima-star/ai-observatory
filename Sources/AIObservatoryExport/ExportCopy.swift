//
//  ExportCopy.swift
//  AIObservatoryExport
//
//  Owner: WS-l10n（双语迁移 B1）
//  ─────────────────────────────────────────────────────────
//  导出层**全部用户可见文案**的集中声明处（IFR-i18n-string-catalog 裁定 3 选的形状 (a)）。
//
//  为什么集中到一个文件而不是散在 11 个源文件里：`bilingualCopy` 是人工维护的清单，
//  散着写会有「加了文案忘了登记」——那正是这套门禁要防的缺陷族。集中之后，
//  声明与登记相隔十行，漏登记在 review 里看得见。
//
//  范围（判据：**会不会进用户的眼睛**）：
//   · ✅ Markdown 报告的每一个标题、标签、单元名、脚注；
//   · ✅ `ExportError.errorDescription` —— 它在 `AIObservatoryApp/ObservatoryExporting.swift`
//     被塞进 `NSAlert.informativeText`，是用户看得见的；
//   · ✅ `ExportKind.title`；
//   · ✅ `ExportError.recoverySuggestion`（`export.suggest.*` 13 条）—— **它当前零消费者**
//     （`localizedDescription` 不含它，App 弹框只取 `errorDescription`），内容是给读代码的人
//     看的指令。接进来是按总控 B1 收尾的裁定走："将来要上屏的提示从第一天就是双语"，
//     而不是等谁去渲染时再补一份裸中文；"零消费者"这个事实同时写在这里和交付块，不当已交付；
//   · ❌ CSV / JSON 的列名与 rawValue —— 机器可读标识（`started_at`、`"Project Path"`），
//     翻它会改变产物 schema。
//
//  数字一律先过 `ExportText.integer(_:)` 再以 `%…$@` 入位，**不**走 `%d`：
//  本模块的字节可重现性依赖「数字不带千位分隔符、不随 Locale 变」（见 ExportFormatting.swift 头）。
//

import Foundation
import AIObservatoryCore

/// 导出层的用户可见文案表。
public enum ExportCopy {

    // MARK: - 报告 · 文档头

    static let reportDocumentTitle = LocalizedString(
        zh: "# AI Agent 活动审计报告",
        en: "# AI Agent Activity Audit Report"
    )
    static let reportOverviewTitle = LocalizedString(zh: "## 概览", en: "## Overview")
    static let reportHotFilesTitle = LocalizedString(
        zh: "## 最常被改动的文件",
        en: "## Most Frequently Modified Files"
    )
    static let reportDangerTitle = LocalizedString(
        zh: "## 危险命令与高风险事件",
        en: "## Dangerous Commands and High-Risk Events"
    )
    static let reportSessionsTitle = LocalizedString(
        zh: "## 逐会话摘要",
        en: "## Session Summaries"
    )
    static let reportGeneratedAt = LocalizedString(
        zh: "- 生成时间：%1$@",
        en: "- Generated: %1$@"
    )
    static let reportDateRange = LocalizedString(
        zh: "- 统计区间：%1$@ ～ %2$@",
        en: "- Period covered: %1$@ to %2$@"
    )
    static let reportIncludedRecords = LocalizedString(
        zh: "- 纳入记录：%1$@ 条（区间外已排除 %2$@ 条）",
        en: "- Records included: %1$@ (%2$@ excluded as outside the period)"
    )
    static let reportSource = LocalizedString(
        zh: "- 数据来源：%1$@，全部数据本地处理，未经任何网络",
        en: "- Source: %1$@. Everything was processed on this machine; nothing was sent over a network."
    )
    static let reportLanguage = LocalizedString(zh: "- 报告语言：%1$@", en: "- Report language: %1$@")
    static let reportRedactionOffWarning = LocalizedString(
        zh: "- 注意：本次导出**未启用脱敏**，机密原文可能出现在下文，请谨慎分发",
        en: "- Warning: this export ran **without redaction**, so secrets may appear below in plain text. "
            + "Distribute with care."
    )

    // MARK: - 报告 · 通用单元

    static let reportNone = LocalizedString(zh: "无", en: "None")
    static let reportUnbounded = LocalizedString(zh: "不限", en: "Unbounded")
    static let reportRunning = LocalizedString(zh: "进行中", en: "in progress")
    static let reportNoTitle = LocalizedString(zh: "（无标题）", en: "(Untitled)")
    static let reportRedactionEnabled = LocalizedString(zh: "已启用", en: "enabled")
    static let reportRedactionDisabled = LocalizedString(zh: "已关闭", en: "disabled")
    /// #64 ③：路径脱敏状态也要落进文件本身。关掉时这一行是**警告**，不是装饰：
    /// 拿到这份报告的人（以及三个月后的用户自己）必须能看出它带原始绝对路径。
    static let reportPathsMasked = LocalizedString(
        zh: "路径已按演示输出脱敏（`~` / `<project>`）",
        en: "paths masked for demo output (`~` / `<project>`)")
    static let reportPathsUnmasked = LocalizedString(
        zh: "路径未脱敏：本文档含本机原始绝对路径",
        en: "paths NOT masked: this document carries raw absolute paths of this machine")
    /// 报告所用语言的自称名：中文报告里写「简体中文」，英文报告里写 "Simplified Chinese"——
    /// 这一路取哪个语言由**报告语言**决定，不是由系统语言决定。
    static let languageNameChinese = LocalizedString(zh: "简体中文", en: "Simplified Chinese")
    static let languageNameEnglish = LocalizedString(zh: "英文", en: "English")

    // MARK: - 报告 · 概览表

    static let reportMetricColumn = LocalizedString(zh: "指标", en: "Metric")
    static let reportValueColumn = LocalizedString(zh: "数值", en: "Value")
    static let reportOverviewSessions = LocalizedString(zh: "会话数", en: "Sessions")
    static let reportOverviewEvents = LocalizedString(zh: "事件数", en: "Events")
    static let reportOverviewFileChanges = LocalizedString(zh: "文件变更数", en: "File changes")
    static let reportOverviewCommands = LocalizedString(zh: "命令数", en: "Commands")
    static let reportOverviewRiskEvents = LocalizedString(zh: "风险事件数", en: "Risk events")
    static let reportOverviewHighRiskRecords = LocalizedString(zh: "高危及以上风险数", en: "High risk and above")
    static let reportOverviewDestructiveCommands = LocalizedString(zh: "破坏性命令数", en: "Destructive commands")
    static let reportOverviewCPUSeconds = LocalizedString(zh: "总 CPU 秒", en: "Total CPU seconds")
    static let reportOverviewPeakMemory = LocalizedString(zh: "峰值内存字节", en: "Peak memory (bytes)")
    static let reportOverviewProjects = LocalizedString(zh: "涉及项目数", en: "Projects involved")
    static let reportOverviewNote = LocalizedString(
        zh: "> 口径说明：高危及以上风险数统计所有记录中风险等级 ≥ HIGH 的条数"
            + "（含风险事件、命令、文件变更与时间线事件）；"
            + "CPU 与内存优先取会话聚合值，无会话记录时取时间线事件消耗值。",
        en: "> How to read this: \"High risk and above\" counts every record at HIGH or above, "
            + "across risk events, commands, file changes and timeline events. "
            + "CPU and memory come from session totals when sessions exist, "
            + "otherwise from timeline-event costs."
    )

    // MARK: - 报告 · Top 热文件表

    static let reportPathColumn = LocalizedString(zh: "文件路径", en: "File path")
    static let reportChangeCountColumn = LocalizedString(zh: "改动次数", en: "Changes")
    static let reportLinesAddedColumn = LocalizedString(zh: "新增行数", en: "Lines added")
    static let reportLinesRemovedColumn = LocalizedString(zh: "删除行数", en: "Lines removed")
    static let reportLastTouchedColumn = LocalizedString(zh: "最近改动", en: "Last change")

    // MARK: - 报告 · 危险命令 / 高风险事件

    static let reportDangerCommandsHeading = LocalizedString(zh: "### 危险命令", en: "### Dangerous commands")
    static let reportHighRiskEventsHeading = LocalizedString(zh: "### 高风险事件", en: "### High-risk events")
    static let reportHighRiskOperationsHeading = LocalizedString(
        zh: "### 高风险操作事件",
        en: "### High-risk timeline events"
    )
    static let reportStartedAtColumn = LocalizedString(zh: "开始时间", en: "Start time")
    static let reportAgentColumn = LocalizedString(zh: "Agent", en: "Agent")
    static let reportCommandLineColumn = LocalizedString(zh: "命令行", en: "Command line")
    static let reportRiskLevelColumn = LocalizedString(zh: "风险等级", en: "Risk level")
    static let reportExitCodeColumn = LocalizedString(zh: "退出码", en: "Exit code")
    static let reportRequiresConfirmationColumn = LocalizedString(zh: "需确认", en: "Needs confirmation")
    static let reportTimeColumn = LocalizedString(zh: "时间", en: "Time")
    static let reportLevelColumn = LocalizedString(zh: "等级", en: "Level")
    static let reportCategoryColumn = LocalizedString(zh: "类别", en: "Category")
    static let reportTitleColumn = LocalizedString(zh: "标题", en: "Title")
    static let reportDetailColumn = LocalizedString(zh: "详情", en: "Detail")
    static let reportSummaryColumn = LocalizedString(zh: "摘要", en: "Summary")
    static let reportCommandColumn = LocalizedString(zh: "命令", en: "Command")
    static let reportRelatedCommandColumn = LocalizedString(zh: "相关命令", en: "Related command")
    static let reportFilesInvolvedColumn = LocalizedString(zh: "涉及文件", en: "Files involved")
    static let reportOperationColumn = LocalizedString(zh: "操作", en: "Operation")
    static let reportTruncationNote = LocalizedString(
        zh: "> 共 %1$@ 条，按时间仅列出最近 %2$@ 条。",
        en: "> Total %1$@; only the most recent %2$@ are listed."
    )

    // MARK: - 报告 · 逐会话摘要

    /// 会话小节标题：编号 · Agent 名 · 会话标题。三路的顺序两语言一致 ⇒ 串位风险为零，
    /// 但仍登记进表，报告里没有一个字来自渲染函数之外。
    static let reportSessionHeading = LocalizedString(
        zh: "### #%1$@ · %2$@ · %3$@",
        en: "### #%1$@ · %2$@ · %3$@"
    )
    static let reportSessionStartedEnded = LocalizedString(
        zh: "- 开始 / 结束：%1$@ / %2$@",
        en: "- Started / ended: %1$@ / %2$@"
    )
    static let reportSessionDuration = LocalizedString(zh: "- 时长：%1$@", en: "- Duration: %1$@")
    static let reportSessionProject = LocalizedString(zh: "- 项目：%1$@", en: "- Project: %1$@")
    static let reportSessionFiles = LocalizedString(
        zh: "- 文件：新增 %1$@ · 修改 %2$@ · 删除 %3$@",
        en: "- Files: %1$@ created · %2$@ modified · %3$@ deleted"
    )
    static let reportSessionCommands = LocalizedString(
        zh: "- 命令：共 %1$@ · 失败 %2$@",
        en: "- Commands: %1$@ run · %2$@ failed"
    )
    static let reportSessionRiskEvents = LocalizedString(zh: "- 风险事件：%1$@", en: "- Risk events: %1$@")
    static let reportSessionResources = LocalizedString(
        zh: "- 资源：CPU %1$@ 秒 · 峰值内存 %2$@ 字节 · 估算 token %3$@",
        en: "- Resources: CPU seconds %1$@ · peak memory bytes %2$@ · estimated tokens %3$@"
    )
    static let reportSessionOutcome = LocalizedString(zh: "- 结果：%1$@", en: "- Outcome: %1$@")
    static let reportDurationSeconds = LocalizedString(zh: "%1$@ 秒", en: "%1$@ s")
    static let reportRunningDuration = LocalizedString(
        zh: "%1$@（%2$@，截至生成时刻）",
        en: "%1$@ (%2$@, measured up to the time this report was generated)"
    )

    // MARK: - 报告 · 页脚

    static let reportFooterTimestamps = LocalizedString(
        zh: "- 时间字段均为 ISO8601（UTC，无小数秒）。",
        en: "- All timestamps are ISO 8601 (UTC, no fractional seconds)."
    )
    static let reportFooterRedaction = LocalizedString(zh: "- 文本脱敏：%1$@。", en: "- Text redaction: %1$@.")
    static let reportFooterStreaming = LocalizedString(
        zh: "- 本报告由导出层逐行流式生成，未在内存中拼接完整文档。",
        en: "- This report was streamed line by line by the export layer; "
            + "the full document is never assembled in memory."
    )

    // MARK: - 导出类别名

    static let kindSessions = LocalizedString(zh: "会话", en: "Sessions")
    static let kindTimeline = LocalizedString(zh: "AI 操作时间线", en: "AI Activity Timeline")
    static let kindFileChanges = LocalizedString(zh: "文件变更", en: "File Changes")
    static let kindCommands = LocalizedString(zh: "终端命令", en: "Terminal Commands")
    static let kindRiskEvents = LocalizedString(zh: "风险事件", en: "Risk Events")
    static let kindReport = LocalizedString(zh: "审计报告", en: "Audit Report")

    // MARK: - 错误信息（进 `NSAlert.informativeText`）

    static let errorUnknownFieldName = LocalizedString(zh: "未知导出字段：%1$@.%2$@",
                                                       en: "Unknown export field: %1$@.%2$@")
    static let errorUnsupportedFieldSelection = LocalizedString(zh: "%1$@ 不支持字段选择",
                                                                en: "%1$@ does not support field selection")
    static let errorEmptySelection = LocalizedString(zh: "%1$@ 没有匹配的记录",
                                                     en: "%1$@ has no matching records")
    static let errorUnsupportedCombination = LocalizedString(zh: "%1$@ 不支持 %2$@ 格式",
                                                             en: "%1$@ cannot be exported as %2$@")
    static let errorInvalidRequest = LocalizedString(zh: "导出请求不合法：%1$@",
                                                     en: "Invalid export request: %1$@")
    static let errorRedactionFailed = LocalizedString(zh: "脱敏失败，导出已中止：%1$@",
                                                      en: "Redaction failed, so the export was aborted: %1$@")
    static let errorPathForbidden = LocalizedString(zh: "禁止写入该路径：%1$@",
                                                    en: "Writing to this path is not allowed: %1$@")
    static let errorPathOutsideAllowedRoots = LocalizedString(
        zh: "写入路径越出允许目录：%1$@",
        en: "The output path is outside the allowed directories: %1$@"
    )
    static let errorCannotCreateFile = LocalizedString(zh: "无法创建导出文件：%1$@（%2$@）",
                                                       en: "Cannot create the export file: %1$@ (%2$@)")
    static let errorCannotOpenFileHandle = LocalizedString(zh: "无法打开导出文件句柄：%1$@",
                                                           en: "Cannot open the export file for writing: %1$@")
    static let errorWriteFailed = LocalizedString(
        zh: "导出写入中断：%1$@（已写 %2$@ 字节，%3$@）",
        en: "The export was interrupted while writing: %1$@ (bytes written: %2$@, %3$@)"
    )
    static let errorEncodingFailed = LocalizedString(zh: "JSON 编码失败（%1$@）：%2$@",
                                                     en: "JSON encoding failed (%1$@): %2$@")
    static let errorAlreadyFinished = LocalizedString(
        zh: "导出文件已完成，无法继续写入：%1$@",
        en: "This export file is already finished and cannot accept more writes: %1$@"
    )

    // MARK: - 错误的成因串（拼进 `errorInvalidRequest` / `errorCannotCreateFile`）

    static let reasonEmptyKinds = LocalizedString(zh: "kinds 不能为空", en: "kinds must not be empty")
    static let reasonNegativeLimit = LocalizedString(zh: "maximumRecordsPerKind 不能为负数",
                                                     en: "maximumRecordsPerKind must not be negative")
    static let reasonEmptySelectedFields = LocalizedString(
        zh: "selectedFieldNames 为空数组，请传 nil 表示全字段",
        en: "selectedFieldNames is an empty array; pass nil to export every field"
    )
    static let reasonEmptyFieldSelection = LocalizedString(zh: "字段选择不能为空数组",
                                                           en: "the field selection must not be an empty array")
    static let reasonCSVNeedsColumns = LocalizedString(
        zh: "CSV 导出至少需要一列（kind=%1$@）",
        en: "a CSV export needs at least one column (kind=%1$@)"
    )
    static let reasonCollectedDataMemoryOnly = LocalizedString(
        zh: "collectedData 仅支持 memory sink",
        en: "collectedData is only available on a memory sink"
    )
    static let reasonCreateParentDirectoryFailed = LocalizedString(zh: "创建父目录失败：%1$@",
                                                                   en: "Failed to create the parent directory: %1$@")
    static let reasonOverwriteExistingFailed = LocalizedString(zh: "覆盖已有文件失败：%1$@",
                                                               en: "Failed to overwrite the existing file: %1$@")
    static let reasonCreateFileReturnedFalse = LocalizedString(
        zh: "FileManager.createFile 返回 false（权限或磁盘问题）",
        en: "FileManager.createFile returned false (permissions or disk space)"
    )
    static let reasonCloseHandleFailed = LocalizedString(
        zh: "写入完成但关闭句柄失败：%1$@",
        en: "Every byte was written, but closing the file handle failed: %1$@"
    )

    // MARK: - 修正建议（`recoverySuggestion`）

    /// ⚠️ 这一组当前**零消费者**：`localizedDescription` 不含 `recoverySuggestion`，
    /// App 的弹框只取 `errorDescription`。接进表是为了让"将来要上屏的修正提示"
    /// 从第一天就是双语的，而不是等谁去渲染时再补一份裸中文。
    static let suggestUnknownFieldName = LocalizedString(
        zh: "请从 ExportSchema.fieldNames(for: .%1$@) 中选字段；未知字段：%2$@",
        en: "Pick fields from ExportSchema.fieldNames(for: .%1$@); unknown field: %2$@"
    )
    static let suggestUnsupportedFieldSelection = LocalizedString(
        zh: "%1$@ 不支持字段选择，请改用记录类 kind",
        en: "%1$@ has no field selection; export one of the record kinds instead"
    )
    static let suggestEmptySelection = LocalizedString(
        zh: "放宽 dateRange 或 maximumRecordsPerKind 后重试（kind=%1$@）",
        en: "Widen dateRange or maximumRecordsPerKind and try again (kind=%1$@)"
    )
    static let suggestUnsupportedCombination = LocalizedString(
        zh: "%1$@ 不支持 %2$@ 格式，请改用 %3$@",
        en: "%1$@ cannot be written as %2$@; use one of: %3$@"
    )
    static let suggestInvalidRequest = LocalizedString(
        zh: "修正 ExportRequest 后重试：%1$@",
        en: "Fix the ExportRequest and try again: %1$@"
    )
    static let suggestRedactionFailed = LocalizedString(
        zh: "导出已中止以免泄漏凭据；修复脱敏规则后重试（%1$@）",
        en: "The export was aborted so credentials could not leak; fix the redaction rules and retry (%1$@)"
    )
    static let suggestPathForbidden = LocalizedString(
        zh: "改写到允许的输出目录（如项目内 .scratch/ 或用户选定的导出目录）：%1$@",
        en: "Write inside an allowed output directory instead (the project's .scratch/ or the folder the "
            + "user chose): %1$@"
    )
    static let suggestPathOutsideAllowedRoots = LocalizedString(
        zh: "把 destination.allowedRoots 设为输出目录，或改写路径；当前越界路径：%1$@（允许根：%2$@）",
        en: "Set destination.allowedRoots to the output directory, or move the path. Outside the allowed "
            + "roots: %1$@ (allowed: %2$@)"
    )
    static let suggestCannotCreateFile = LocalizedString(
        zh: "检查目录权限或换目录：%1$@（%2$@）",
        en: "Check the directory permissions or pick another directory: %1$@ (%2$@)"
    )
    static let suggestCannotOpenFileHandle = LocalizedString(
        zh: "检查文件是否被占用：%1$@",
        en: "Check whether something else holds the file open: %1$@"
    )
    static let suggestWriteFailed = LocalizedString(
        zh: "已写 %1$@ 字节后中断，请清理残留文件后重试：%2$@（%3$@）",
        en: "Interrupted after %1$@ bytes; delete the partial file and retry: %2$@ (%3$@)"
    )
    static let suggestEncodingFailed = LocalizedString(
        zh: "字段值无法编码为 JSON（kind=%1$@）：%2$@",
        en: "A field value could not be encoded as JSON (kind=%1$@): %2$@"
    )
    static let suggestAlreadyFinished = LocalizedString(
        zh: "为后续写入新建 ExportWriter：%1$@",
        en: "Create a new ExportWriter for further writes: %1$@"
    )

    // MARK: - 门禁清单

    // MARK: report 组文案（71 条，key 前缀 report.*）
    public static let reportCopy: [NamedCopy] = [
        NamedCopy("export.report.documentTitle", reportDocumentTitle),
        NamedCopy("export.report.overviewTitle", reportOverviewTitle),
        NamedCopy("export.report.hotFilesTitle", reportHotFilesTitle),
        NamedCopy("export.report.dangerTitle", reportDangerTitle),
        NamedCopy("export.report.sessionsTitle", reportSessionsTitle),
        NamedCopy("export.report.generatedAt", reportGeneratedAt),
        NamedCopy("export.report.dateRange", reportDateRange),
        NamedCopy("export.report.includedRecords", reportIncludedRecords),
        NamedCopy("export.report.source", reportSource),
        NamedCopy("export.report.language", reportLanguage),
        NamedCopy("export.report.redactionOffWarning", reportRedactionOffWarning),
        NamedCopy("export.report.none", reportNone),
        NamedCopy("export.report.unbounded", reportUnbounded),
        NamedCopy("export.report.running", reportRunning),
        NamedCopy("export.report.noTitle", reportNoTitle),
        NamedCopy("export.report.redactionEnabled", reportRedactionEnabled),
        NamedCopy("export.report.redactionDisabled", reportRedactionDisabled),
        NamedCopy("export.report.pathsMasked", reportPathsMasked),
        NamedCopy("export.report.pathsUnmasked", reportPathsUnmasked),
        NamedCopy("export.report.languageNameChinese", languageNameChinese),
        NamedCopy("export.report.languageNameEnglish", languageNameEnglish),
        NamedCopy("export.report.metricColumn", reportMetricColumn),
        NamedCopy("export.report.valueColumn", reportValueColumn),
        NamedCopy("export.report.overview.sessions", reportOverviewSessions),
        NamedCopy("export.report.overview.events", reportOverviewEvents),
        NamedCopy("export.report.overview.fileChanges", reportOverviewFileChanges),
        NamedCopy("export.report.overview.commands", reportOverviewCommands),
        NamedCopy("export.report.overview.riskEvents", reportOverviewRiskEvents),
        NamedCopy("export.report.overview.highRiskRecords", reportOverviewHighRiskRecords),
        NamedCopy("export.report.overview.destructiveCommands", reportOverviewDestructiveCommands),
        NamedCopy("export.report.overview.cpuSeconds", reportOverviewCPUSeconds),
        NamedCopy("export.report.overview.peakMemory", reportOverviewPeakMemory),
        NamedCopy("export.report.overview.projects", reportOverviewProjects),
        NamedCopy("export.report.overviewNote", reportOverviewNote),
        NamedCopy("export.report.pathColumn", reportPathColumn),
        NamedCopy("export.report.changeCountColumn", reportChangeCountColumn),
        NamedCopy("export.report.linesAddedColumn", reportLinesAddedColumn),
        NamedCopy("export.report.linesRemovedColumn", reportLinesRemovedColumn),
        NamedCopy("export.report.lastTouchedColumn", reportLastTouchedColumn),
        NamedCopy("export.report.dangerCommandsHeading", reportDangerCommandsHeading),
        NamedCopy("export.report.highRiskEventsHeading", reportHighRiskEventsHeading),
        NamedCopy("export.report.highRiskOperationsHeading", reportHighRiskOperationsHeading),
        NamedCopy("export.report.startedAtColumn", reportStartedAtColumn),
        NamedCopy("export.report.agentColumn", reportAgentColumn),
        NamedCopy("export.report.commandLineColumn", reportCommandLineColumn),
        NamedCopy("export.report.riskLevelColumn", reportRiskLevelColumn),
        NamedCopy("export.report.exitCodeColumn", reportExitCodeColumn),
        NamedCopy("export.report.requiresConfirmationColumn", reportRequiresConfirmationColumn),
        NamedCopy("export.report.timeColumn", reportTimeColumn),
        NamedCopy("export.report.levelColumn", reportLevelColumn),
        NamedCopy("export.report.categoryColumn", reportCategoryColumn),
        NamedCopy("export.report.titleColumn", reportTitleColumn),
        NamedCopy("export.report.detailColumn", reportDetailColumn),
        NamedCopy("export.report.summaryColumn", reportSummaryColumn),
        NamedCopy("export.report.commandColumn", reportCommandColumn),
        NamedCopy("export.report.relatedCommandColumn", reportRelatedCommandColumn),
        NamedCopy("export.report.filesInvolvedColumn", reportFilesInvolvedColumn),
        NamedCopy("export.report.operationColumn", reportOperationColumn),
        NamedCopy("export.report.truncationNote", reportTruncationNote),
        NamedCopy("export.report.sessionHeading", reportSessionHeading),
        NamedCopy("export.report.sessionStartedEnded", reportSessionStartedEnded),
        NamedCopy("export.report.sessionDuration", reportSessionDuration),
        NamedCopy("export.report.sessionProject", reportSessionProject),
        NamedCopy("export.report.sessionFiles", reportSessionFiles),
        NamedCopy("export.report.sessionCommands", reportSessionCommands),
        NamedCopy("export.report.sessionRiskEvents", reportSessionRiskEvents),
        NamedCopy("export.report.sessionResources", reportSessionResources),
        NamedCopy("export.report.sessionOutcome", reportSessionOutcome),
        NamedCopy("export.report.durationSeconds", reportDurationSeconds),
        NamedCopy("export.report.runningDuration", reportRunningDuration),
        NamedCopy("export.report.footerTimestamps", reportFooterTimestamps),
        NamedCopy("export.report.footerRedaction", reportFooterRedaction),
        NamedCopy("export.report.footerStreaming", reportFooterStreaming),
    ]

    // MARK: kind 组文案（6 条，key 前缀 kind.*）
    public static let kindCopy: [NamedCopy] = [
        NamedCopy("export.kind.sessions", kindSessions),
        NamedCopy("export.kind.timeline", kindTimeline),
        NamedCopy("export.kind.fileChanges", kindFileChanges),
        NamedCopy("export.kind.commands", kindCommands),
        NamedCopy("export.kind.riskEvents", kindRiskEvents),
        NamedCopy("export.kind.report", kindReport),
    ]

    // MARK: error 组文案（13 条，key 前缀 error.*）
    public static let errorCopy: [NamedCopy] = [
        NamedCopy("export.error.unknownFieldName", errorUnknownFieldName),
        NamedCopy("export.error.unsupportedFieldSelection", errorUnsupportedFieldSelection),
        NamedCopy("export.error.emptySelection", errorEmptySelection),
        NamedCopy("export.error.unsupportedCombination", errorUnsupportedCombination),
        NamedCopy("export.error.invalidRequest", errorInvalidRequest),
        NamedCopy("export.error.redactionFailed", errorRedactionFailed),
        NamedCopy("export.error.pathForbidden", errorPathForbidden),
        NamedCopy("export.error.pathOutsideAllowedRoots", errorPathOutsideAllowedRoots),
        NamedCopy("export.error.cannotCreateFile", errorCannotCreateFile),
        NamedCopy("export.error.cannotOpenFileHandle", errorCannotOpenFileHandle),
        NamedCopy("export.error.writeFailed", errorWriteFailed),
        NamedCopy("export.error.encodingFailed", errorEncodingFailed),
        NamedCopy("export.error.alreadyFinished", errorAlreadyFinished),
    ]

    // MARK: reason 组文案（10 条，key 前缀 reason.*）
    public static let reasonCopy: [NamedCopy] = [
        NamedCopy("export.reason.emptyKinds", reasonEmptyKinds),
        NamedCopy("export.reason.negativeLimit", reasonNegativeLimit),
        NamedCopy("export.reason.emptySelectedFields", reasonEmptySelectedFields),
        NamedCopy("export.reason.emptyFieldSelection", reasonEmptyFieldSelection),
        NamedCopy("export.reason.csvNeedsColumns", reasonCSVNeedsColumns),
        NamedCopy("export.reason.collectedDataMemoryOnly", reasonCollectedDataMemoryOnly),
        NamedCopy("export.reason.createParentDirectoryFailed", reasonCreateParentDirectoryFailed),
        NamedCopy("export.reason.overwriteExistingFailed", reasonOverwriteExistingFailed),
        NamedCopy("export.reason.createFileReturnedFalse", reasonCreateFileReturnedFalse),
        NamedCopy("export.reason.closeHandleFailed", reasonCloseHandleFailed),
    ]

    // MARK: suggest 组文案（13 条，key 前缀 suggest.*）
    public static let suggestCopy: [NamedCopy] = [
        NamedCopy("export.suggest.unknown-field-name", suggestUnknownFieldName),
        NamedCopy("export.suggest.unsupported-field-selection", suggestUnsupportedFieldSelection),
        NamedCopy("export.suggest.empty-selection", suggestEmptySelection),
        NamedCopy("export.suggest.unsupported-combination", suggestUnsupportedCombination),
        NamedCopy("export.suggest.invalid-request", suggestInvalidRequest),
        NamedCopy("export.suggest.redaction-failed", suggestRedactionFailed),
        NamedCopy("export.suggest.path-forbidden", suggestPathForbidden),
        NamedCopy("export.suggest.path-outside-allowed-roots", suggestPathOutsideAllowedRoots),
        NamedCopy("export.suggest.cannot-create-file", suggestCannotCreateFile),
        NamedCopy("export.suggest.cannot-open-file-handle", suggestCannotOpenFileHandle),
        NamedCopy("export.suggest.write-failed", suggestWriteFailed),
        NamedCopy("export.suggest.encoding-failed", suggestEncodingFailed),
        NamedCopy("export.suggest.already-finished", suggestAlreadyFinished),
    ]

    /// 本模块全部用户可见文案。**门禁用例遍历它断言 `copyProblems` 为空**
    /// （缺译、假双语、参数串位、类型不一致都在那一网里）。
    public static let bilingualCopy: [NamedCopy] =
        reportCopy
        + kindCopy
        + errorCopy
        + reasonCopy
        + suggestCopy

}

/// 多参数文案的位置下标由每条串自己写（`%1$@` / `%2$@`）：
/// 抽成常量会让两条语言的槽位看起来一样，而它们最容易错的地方恰恰是**语序不同 ⇒ 下标顺序不同**
/// （`problems.placeholdersNotPositional` 逐条判的就是这个）。
extension LocalizedString {
    /// 按**当前进程语言**渲染。用在没有更好语言来源的时机：抛错、显示层取标签。
    ///
    /// ⚠️ 报告正文**不**走这里 —— 那里语言由 `Input.interfaceLanguage` 在导出时定死
    /// （IFR 裁定 2：写进文件的文字不回改）。
    func renderedNow(_ arguments: any CVarArg...) -> String {
        format(AppLanguage.resolved(), arguments: arguments)
    }
}
