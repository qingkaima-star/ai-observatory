//
//  InsightCopy.swift
//  AIObservatoryInsights
//
//  Owner: WS-l10n（双语迁移 B1）
//  ─────────────────────────────────────────────────────────
//  分析层全部用户可见文案（IFR 裁定 3 的形状 (a)）。这里的东西**全部会进用户的眼睛**：
//  每个洞察卡片下面的「依据」句，以及趋势 / 指标 / 判定这三组标签。
//
//  为什么语言是**参数**而不是就地 `AppLanguage.resolved()`：
//  依据句是分析时算出来、由 UI 每次现算现显（不落库，已核对：`ProjectHealthSummary`
//  一类只出现在 Engine 的分析路径上，Store / SwiftDataStore 里没有它们）。
//  所以公开展口一律 `language: AppLanguage = .resolved()` 追加在参数表**末尾**
//  ——既有调用点（Engine，属 `ws/engaudit`）一行为都不用改，用例又能显式要英文。
//
//  英文按母语者会写的话重写，不是逐字对译。例如「人工占比不可估计（未提供人工基线）」
//  的用户含义是「这里没有人的基线数据，所以我没算人的占比」⇒
//  "human share cannot be estimated (no human baseline supplied)"，
//  而不是 "human ratio not estimable"。
//
//  ⚠️ 数字一律先由本模块的定点格式化函数拼成 ASCII 串，再以 `%n$@` 入位：
//  依据句要能逐字复核（`String(format:"%.1f")` 的小数点会随 Locale 漂，见各文件头）。
//

import Foundation
import AIObservatoryCore

/// 分析层的用户可见文案表。
public enum InsightCopy {

    // MARK: - 标签

    static let trendRising = LocalizedString(zh: "上升", en: "rising")
    static let trendFlat = LocalizedString(zh: "持平", en: "flat")
    static let trendFalling = LocalizedString(zh: "下降", en: "falling")
    /// 「样本不足」≠「持平」：前者是没证据，后者是证据充分但没斜率。英文必须也分出这一层。
    static let trendUnknown = LocalizedString(zh: "样本不足", en: "insufficient data")

    static let metricEventRate = LocalizedString(zh: "每分钟事件数", en: "events per minute")
    static let metricDeletionRate = LocalizedString(zh: "每分钟删除行数", en: "lines deleted per minute")
    static let metricCommandRate = LocalizedString(zh: "每分钟命令数", en: "commands per minute")
    static let metricCPULoad = LocalizedString(zh: "CPU 占用", en: "CPU load")

    static let outcomeSucceeded = LocalizedString(zh: "成功", en: "succeeded")
    static let outcomeFailed = LocalizedString(zh: "失败", en: "failed")
    static let outcomeUnresolved = LocalizedString(zh: "未判定", en: "unresolved")

    static let notComputable = LocalizedString(zh: "不可计算", en: "not computable")
    static let invalidValue = LocalizedString(zh: "无效", en: "invalid")
    static let estimated = LocalizedString(zh: "已估计", en: "estimated")
    static let notEstimable = LocalizedString(zh: "不可估计", en: "cannot be estimated")

    // MARK: - 拼装用的连接符（标点也是文案：全角分号跟在英文句子后面是错的）

    static let joinerSemicolon = LocalizedString(zh: "；", en: "; ")
    static let sentenceEnd = LocalizedString(zh: "。", en: ".")
    static let joinerBar = LocalizedString(zh: " ｜ ", en: " | ")
    static let joinerEnumeration = LocalizedString(zh: "、", en: ", ")

    // MARK: - 文件热度

    static let hotFileBasis = LocalizedString(
        zh: "%1$@ 次改动 · %2$@ 个 Agent · 距今 %3$@ 天 · 有效改动数 %4$@",
        en: "changes: %1$@ · agents: %2$@ · days since last change: %3$@ · effective edits: %4$@"
    )

    // MARK: - 代码增长

    static let growthNetLines = LocalizedString(zh: "净增 %1$@ 行（+%2$@/−%3$@）",
                                                en: "lines net: %1$@ (+%2$@/−%3$@)")
    static let growthFileCount = LocalizedString(zh: "%1$@ 个文件", en: "files: %1$@")
    static let growthTrend = LocalizedString(zh: "趋势 %1$@", en: "trend: %1$@")
    static let growthSkippedBinary = LocalizedString(
        zh: "%1$@ 条二进制变更无法计行，未纳入",
        en: "binary or non-text changes left out of the line counts: %1$@"
    )
    static let growthNoTextChanges = LocalizedString(zh: "无文本变更，增长量不可估计",
                                                     en: "no text changes, so growth cannot be estimated")

    // MARK: - 命令产量

    static let throughputNoCommands = LocalizedString(
        zh: "窗口内无命令记录，产量与耗时不可估计",
        en: "no commands in this window, so volume and duration cannot be estimated"
    )
    static let throughputPerHour = LocalizedString(zh: "%1$@ 条/小时", en: "commands per hour: %1$@")
    static let throughputNoWindow = LocalizedString(zh: "窗口时长非法，吞吐率不可估计",
                                                    en: "the window has no valid length, so throughput cannot be estimated")
    static let throughputTotal = LocalizedString(zh: "%1$@ 条命令", en: "commands: %1$@")
    static let throughputSuccess = LocalizedString(zh: "成功 %1$@/已判定 %2$@（%3$@）",
                                                   en: "succeeded: %1$@ of %2$@ resolved (%3$@)")
    static let throughputAllUnresolved = LocalizedString(
        zh: "全部 %1$@ 条结果未判定，成败率不可估计",
        en: "%1$@ commands are still unresolved, so no success or failure rate is given"
    )
    static let throughputFailed = LocalizedString(zh: "失败 %1$@", en: "failed: %1$@")
    static let throughputDestructive = LocalizedString(zh: "破坏性 %1$@", en: "destructive: %1$@")
    static let throughputP95 = LocalizedString(zh: "耗时 p95 %1$@s（计时样本 %2$@/%3$@）",
                                               en: "p95 duration %1$@ s (%2$@/%3$@ timed)")
    static let throughputNoDurations = LocalizedString(zh: "无可用耗时，分位数不可估计",
                                                       en: "no command has a recorded duration, so percentiles cannot be estimated")

    // MARK: - 参与度

    static let contributionNoData = LocalizedString(zh: "无文件变更数据，参与度不可估计",
                                                    en: "there are no file changes, so participation cannot be estimated")
    static let contributionUnattributed = LocalizedString(zh: "归属不明 %1$@", en: "unattributed %1$@")
    static let contributionHuman = LocalizedString(zh: "人工 %1$@", en: "human %1$@")
    static let contributionHumanUnknown = LocalizedString(
        zh: "人工占比不可估计（未提供人工基线）",
        en: "human share cannot be estimated (no human baseline supplied)"
    )
    static let contributionTotal = LocalizedString(zh: "共 %1$@ 次改动 · %2$@", en: "changes in total: %1$@ · %2$@")
    static let contributionAgentSideOnly = LocalizedString(
        zh: "未提供人工基线，仅统计 Agent 侧",
        en: "no human baseline was supplied, so only agent activity is counted"
    )

    // MARK: - 异常检测

    static let anomalyNoDataReason = LocalizedString(zh: "无数据", en: "no data")
    static let anomalyInsufficientSample = LocalizedString(
        zh: "样本量 %1$@ 不足 %2$@，不做异常判定",
        en: "sample count %1$@ is below the minimum of %2$@, so nothing is judged"
    )
    static let anomalyConstantSeries = LocalizedString(
        zh: "序列恒定（标准差为 0），无波动可判",
        en: "the series is constant (standard deviation 0), so there is no variation to judge"
    )
    static let anomalyNonFiniteReason = LocalizedString(
        zh: "基线不可计算（序列含非有限数值），不做异常判定",
        en: "the baseline cannot be computed (the series contains non-finite values), so nothing is judged"
    )
    static let anomalyNoDataBasis = LocalizedString(
        zh: "无数据：未收到任何桶取值，基线不可建立，不做异常判定",
        en: "no data: no bucket was recorded, so there is no baseline and nothing is judged"
    )
    static let anomalyBaselineWithMinimum = LocalizedString(
        zh: "基线 %1$@ ± %2$@（n=%3$@，最少 %4$@）· %5$@",
        en: "baseline %1$@ ± %2$@ (n=%3$@, minimum %4$@) · %5$@"
    )
    static let anomalyBaselinePlain = LocalizedString(
        zh: "基线 %1$@ ± %2$@（n=%3$@）· %4$@",
        en: "baseline %1$@ ± %2$@ (n=%3$@) · %4$@"
    )
    static let anomalyBaselineWithThreshold = LocalizedString(
        zh: "基线 %1$@ ± %2$@（n=%3$@，阈值 %4$@σ）· %5$@",
        en: "baseline %1$@ ± %2$@ (n=%3$@, threshold %4$@σ) · %5$@"
    )
    static let anomalyBaselineNotComputable = LocalizedString(
        zh: "基线不可计算（n=%1$@）· %2$@",
        en: "baseline not computable (n=%1$@) · %2$@"
    )
    static let anomalyNoneFound = LocalizedString(zh: "未检出异常桶", en: "no anomalous bucket found")
    static let anomalyFoundCount = LocalizedString(zh: "检出 %1$@ 个异常桶", en: "anomalous buckets found: %1$@")

    // MARK: - Agent 效率对比

    static let efficiencyNoData = LocalizedString(
        zh: "无会话、无文件改动、无命令记录，无法对比 Agent 效率；缺少可对照的 Agent，不给出效率排名。",
        en: "There are no sessions, file changes, or commands to work from, so no agent can be ranked."
    )
    static let efficiencyHeader = LocalizedString(
        zh: "对比 %1$@ 类 Agent（会话 %2$@ · 改动 %3$@ · 命令 %4$@）：%5$@",
        en: "agents compared: %1$@ (sessions %2$@ · changes %3$@ · commands %4$@): %5$@"
    )
    static let efficiencyRow = LocalizedString(
        zh: "%1$@：活跃 %2$@ 秒 · 文件 %3$@ 个 · 产出率 %4$@ · 成本 %5$@ · 成功率 %6$@",
        en: "%1$@: active %2$@ s · files %3$@ · output rate %4$@ · cost %5$@ · success rate %6$@"
    )
    static let efficiencyUnitFilesPerSecond = LocalizedString(zh: "文件/秒", en: "files per second")
    static let efficiencyUnitCPUSecondsPerFile = LocalizedString(zh: "CPU 秒/文件", en: "CPU seconds per file")
    static let efficiencyNoResolvedCommands = LocalizedString(zh: "无已判定命令", en: "no resolved commands")
    static let efficiencyNotComputableWithUnit = LocalizedString(
        zh: "不可计算（%1$@ 分母缺失）",
        en: "not computable (the %1$@ denominator is missing)"
    )
    static let efficiencyMostEfficient = LocalizedString(zh: "效率第一 %1$@", en: "most efficient: %1$@")
    static let efficiencyCheapest = LocalizedString(zh: "成本最低 %1$@", en: "lowest cost: %1$@")
    static let efficiencyComparableOutput = LocalizedString(zh: "产出率可比 Agent %1$@ 个",
                                                            en: "agents with a comparable output rate: %1$@")
    static let efficiencyComparableCost = LocalizedString(zh: "单文件成本可比 Agent %1$@ 个",
                                                          en: "agents with a comparable per-file cost: %1$@")
    static let efficiencyNoRanking = LocalizedString(
        zh: "缺少可对照的 Agent（%1$@，均需 ≥ 2），不给出效率排名",
        en: "too few agents to rank (%1$@; each ranking needs at least 2)"
    )

    // MARK: - 项目健康摘要

    static let healthHotFiles = LocalizedString(zh: "热度文件 %1$@ 个", en: "hot files: %1$@")
    static let healthContribution = LocalizedString(zh: "参与度 %1$@ 个 Agent（人工占比%2$@）",
                                                    en: "participation — agents: %1$@ (human share %2$@)")
    static let healthCodeGrowth = LocalizedString(zh: "代码净增 %1$@ 行（%2$@）",
                                                  en: "lines net: %1$@ (%2$@)")
    static let healthCommands = LocalizedString(zh: "命令 %1$@ 条", en: "commands: %1$@")
    static let healthAnomalies = LocalizedString(zh: "异常 %1$@ 处", en: "anomalies: %1$@")
    static let healthSkippedAnomalies = LocalizedString(zh: "%1$@ 项因基线不足未判定",
                                                        en: "skipped for lack of a baseline: %1$@")
    static let healthRisks = LocalizedString(zh: "风险 %1$@（需关注 %2$@）",
                                             en: "risk events: %1$@ (needing a look: %2$@)")
    static let healthConfidence = LocalizedString(zh: "整体置信度 %1$@", en: "overall confidence: %1$@")

    // MARK: - 门禁清单

    // MARK: trend 组文案（4 条，key 前缀 trend.*）
    public static let trendCopy: [NamedCopy] = [
        NamedCopy("insight.trend.rising", trendRising),
        NamedCopy("insight.trend.flat", trendFlat),
        NamedCopy("insight.trend.falling", trendFalling),
        NamedCopy("insight.trend.unknown", trendUnknown),
    ]

    // MARK: metric 组文案（4 条，key 前缀 metric.*）
    public static let metricCopy: [NamedCopy] = [
        NamedCopy("insight.metric.eventRate", metricEventRate),
        NamedCopy("insight.metric.deletionRate", metricDeletionRate),
        NamedCopy("insight.metric.commandRate", metricCommandRate),
        NamedCopy("insight.metric.cpuLoad", metricCPULoad),
    ]

    // MARK: outcome 组文案（3 条，key 前缀 outcome.*）
    public static let outcomeCopy: [NamedCopy] = [
        NamedCopy("insight.outcome.succeeded", outcomeSucceeded),
        NamedCopy("insight.outcome.failed", outcomeFailed),
        NamedCopy("insight.outcome.unresolved", outcomeUnresolved),
    ]

    // MARK: misc 组文案（4 条，key 前缀 misc.*）
    public static let miscCopy: [NamedCopy] = [
        NamedCopy("insight.notComputable", notComputable),
        NamedCopy("insight.invalid", invalidValue),
        NamedCopy("insight.estimated", estimated),
        NamedCopy("insight.notEstimable", notEstimable),
    ]

    // MARK: joiner 组文案（4 条，key 前缀 joiner.*）
    public static let joinerCopy: [NamedCopy] = [
        NamedCopy("insight.joiner.semicolon", joinerSemicolon),
        NamedCopy("insight.joiner.sentenceEnd", sentenceEnd),
        NamedCopy("insight.joiner.bar", joinerBar),
        NamedCopy("insight.joiner.enumeration", joinerEnumeration),
    ]

    // MARK: hotFile 组文案（1 条，key 前缀 hotFile.*）
    public static let hotFileCopy: [NamedCopy] = [
        NamedCopy("insight.hotFile.basis", hotFileBasis),
    ]

    // MARK: growth 组文案（5 条，key 前缀 growth.*）
    public static let growthCopy: [NamedCopy] = [
        NamedCopy("insight.growth.netLines", growthNetLines),
        NamedCopy("insight.growth.fileCount", growthFileCount),
        NamedCopy("insight.growth.trend", growthTrend),
        NamedCopy("insight.growth.skippedBinary", growthSkippedBinary),
        NamedCopy("insight.growth.noTextChanges", growthNoTextChanges),
    ]

    // MARK: throughput 组文案（10 条，key 前缀 throughput.*）
    public static let throughputCopy: [NamedCopy] = [
        NamedCopy("insight.throughput.noCommands", throughputNoCommands),
        NamedCopy("insight.throughput.perHour", throughputPerHour),
        NamedCopy("insight.throughput.noWindow", throughputNoWindow),
        NamedCopy("insight.throughput.total", throughputTotal),
        NamedCopy("insight.throughput.success", throughputSuccess),
        NamedCopy("insight.throughput.allUnresolved", throughputAllUnresolved),
        NamedCopy("insight.throughput.failed", throughputFailed),
        NamedCopy("insight.throughput.destructive", throughputDestructive),
        NamedCopy("insight.throughput.p95", throughputP95),
        NamedCopy("insight.throughput.noDurations", throughputNoDurations),
    ]

    // MARK: contribution 组文案（6 条，key 前缀 contribution.*）
    public static let contributionCopy: [NamedCopy] = [
        NamedCopy("insight.contribution.noData", contributionNoData),
        NamedCopy("insight.contribution.unattributed", contributionUnattributed),
        NamedCopy("insight.contribution.human", contributionHuman),
        NamedCopy("insight.contribution.humanUnknown", contributionHumanUnknown),
        NamedCopy("insight.contribution.total", contributionTotal),
        NamedCopy("insight.contribution.agentSideOnly", contributionAgentSideOnly),
    ]

    // MARK: anomaly 组文案（11 条，key 前缀 anomaly.*）
    public static let anomalyCopy: [NamedCopy] = [
        NamedCopy("insight.anomaly.noDataReason", anomalyNoDataReason),
        NamedCopy("insight.anomaly.insufficientSample", anomalyInsufficientSample),
        NamedCopy("insight.anomaly.constantSeries", anomalyConstantSeries),
        NamedCopy("insight.anomaly.nonFiniteReason", anomalyNonFiniteReason),
        NamedCopy("insight.anomaly.noDataBasis", anomalyNoDataBasis),
        NamedCopy("insight.anomaly.baselineWithMinimum", anomalyBaselineWithMinimum),
        NamedCopy("insight.anomaly.baselinePlain", anomalyBaselinePlain),
        NamedCopy("insight.anomaly.baselineWithThreshold", anomalyBaselineWithThreshold),
        NamedCopy("insight.anomaly.baselineNotComputable", anomalyBaselineNotComputable),
        NamedCopy("insight.anomaly.noneFound", anomalyNoneFound),
        NamedCopy("insight.anomaly.foundCount", anomalyFoundCount),
    ]

    // MARK: efficiency 组文案（12 条，key 前缀 efficiency.*）
    public static let efficiencyCopy: [NamedCopy] = [
        NamedCopy("insight.efficiency.noData", efficiencyNoData),
        NamedCopy("insight.efficiency.header", efficiencyHeader),
        NamedCopy("insight.efficiency.row", efficiencyRow),
        NamedCopy("insight.efficiency.unit.filesPerSecond", efficiencyUnitFilesPerSecond),
        NamedCopy("insight.efficiency.unit.cpuSecondsPerFile", efficiencyUnitCPUSecondsPerFile),
        NamedCopy("insight.efficiency.noResolvedCommands", efficiencyNoResolvedCommands),
        NamedCopy("insight.efficiency.notComputableWithUnit", efficiencyNotComputableWithUnit),
        NamedCopy("insight.efficiency.mostEfficient", efficiencyMostEfficient),
        NamedCopy("insight.efficiency.cheapest", efficiencyCheapest),
        NamedCopy("insight.efficiency.comparableOutput", efficiencyComparableOutput),
        NamedCopy("insight.efficiency.comparableCost", efficiencyComparableCost),
        NamedCopy("insight.efficiency.noRanking", efficiencyNoRanking),
    ]

    // MARK: health 组文案（8 条，key 前缀 health.*）
    public static let healthCopy: [NamedCopy] = [
        NamedCopy("insight.health.hotFiles", healthHotFiles),
        NamedCopy("insight.health.contribution", healthContribution),
        NamedCopy("insight.health.codeGrowth", healthCodeGrowth),
        NamedCopy("insight.health.commands", healthCommands),
        NamedCopy("insight.health.anomalies", healthAnomalies),
        NamedCopy("insight.health.skippedAnomalies", healthSkippedAnomalies),
        NamedCopy("insight.health.risks", healthRisks),
        NamedCopy("insight.health.confidence", healthConfidence),
    ]

    /// 本模块全部用户可见文案。门禁用例遍历它断言 `copyProblems` 为空。
    public static let bilingualCopy: [NamedCopy] =
        trendCopy
        + metricCopy
        + outcomeCopy
        + miscCopy
        + joinerCopy
        + hotFileCopy
        + growthCopy
        + throughputCopy
        + contributionCopy
        + anomalyCopy
        + efficiencyCopy
        + healthCopy

}

extension LocalizedString {
    /// 按当前进程语言渲染（抛错/标签这类没有显式语言可传的时机）。
    func renderedNow(_ arguments: any CVarArg...) -> String {
        format(AppLanguage.resolved(), arguments: arguments)
    }
}
