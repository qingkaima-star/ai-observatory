//
//  AgentEfficiencyComparator.swift
//  AIObservatoryInsights
//
//  Agent 效率对比：把同一项目内每个 Agent 的「活跃时长 / CPU 成本」与「实际产出
//  （触碰的去重文件数、命令成功率）」放进同一张表里对照，并在**存在对照组**时给出
//  单位时间产出最高、单位文件成本最低的 Agent。
//
//  设计要点：
//  1. 会话时长一律走 `AgentSession.duration(until:)` 的注入式口径。本文件不读墙钟
//     （全文没有任何取当前时间的调用），所以同一份输入永远得到同一份输出，可在任意时刻重放验证。
//  2. 成功率与失败判定复用 `InsightClassifier`，避免本模块与命令产量统计各自长出一套口径。
//  3. 「没有对照组就不排名」：只有 1 个 Agent 可比时，「效率第一」毫无信息量，
//     返回 `nil` 并在 `basis` 中写明原因。
//  4. 不可估计的比率返回 `nil` 而不是 0：活跃 0 秒的 Agent 不该被算成「产出率 0」，
//     那是把「没采到数据」偷换成了「数据为零」。
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

/// 同项目内多 Agent 的产出 / 成本对比器。纯函数：无 IO、无随机、无全局可变态、不读当前时间。
public enum AgentEfficiencyComparator {
    /// 对比各类 Agent 的效率与成本。
    ///
    /// - Parameters:
    ///   - sessions: 该项目的 Agent 会话。活跃时长由 `session.duration(until: referenceDate)` 求得。
    ///   - changes: 该项目的文件改动，用于统计实际产出（去重 path 数）。
    ///   - commands: 该项目的命令记录，用于统计成功率与失败数。
    ///   - referenceDate: 计算「仍在运行」会话活跃时长的终点。时间必须由调用方注入，
    ///     否则同一份数据在不同时刻会跑出不同结论。
    /// - Returns: `AgentEfficiencyComparison`。行集合为三类输入中出现过的全部 `agentKind`
    ///   （含 `.unknown`，它保留在表中体现归属缺口，但**永不参与排名**）。
    ///   空输入返回空行、两个排名皆 `nil`、置信度 `.low`。
    public static func compare(
        sessions: [AgentSession],
        changes: [FileChange],
        commands: [CommandRecord],
        referenceDate: Date,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> AgentEfficiencyComparison {
        var aggregates: [AgentKind: AgentAggregate] = [:]

        for session in sessions {
            var item = aggregates[session.kind] ?? AgentAggregate()
            item.sessionCount += 1
            item.activeSeconds += session.duration(until: referenceDate)
            item.cpuSeconds += session.cpuSeconds
            aggregates[session.kind] = item
        }

        for change in changes {
            var item = aggregates[change.agentKind] ?? AgentAggregate()
            item.changeCount += 1
            item.touchedPaths.insert(change.path)
            aggregates[change.agentKind] = item
        }

        for command in commands {
            var item = aggregates[command.agentKind] ?? AgentAggregate()
            item.commandCount += 1
            if InsightClassifier.classify(outcome: command.outcome, exitCode: command.exitCode) == .failed {
                item.failedCommandCount += 1
            }
            aggregates[command.agentKind] = item
        }

        let commandsByKind = Dictionary(grouping: commands, by: { $0.agentKind })

        // `Dictionary(grouping:)` 与聚合字典都不保证顺序，统一按 rawValue 升序输出以保证确定性。
        let rows = aggregates.keys.sorted { $0.rawValue < $1.rawValue }.map { kind -> AgentEfficiencyRow in
            makeRow(
                kind: kind,
                aggregate: aggregates[kind] ?? AgentAggregate(),
                kindCommands: commandsByKind[kind] ?? []
            )
        }

        let efficiencyCandidates = rows.filter { $0.agentKind != .unknown && $0.filesPerSecond != nil }
        let costCandidates = rows.filter { $0.agentKind != .unknown && $0.cpuSecondsPerFile != nil }

        // 候选 < 2 ⇒ 没有对照组，此时「第一」只是把唯一样本重述一遍，属于伪结论，直接给 nil。
        let mostEfficientAgent = efficiencyCandidates.count >= 2
            ? efficiencyCandidates.sorted { ranksBeforeForEfficiency($0, $1) }.first?.agentKind
            : nil
        let cheapestAgent = costCandidates.count >= 2
            ? costCandidates.sorted { ranksBeforeForCost($0, $1) }.first?.agentKind
            : nil

        let confidence = makeConfidence(sessions: sessions, changes: changes, commands: commands)
        let basis = makeBasis(
            rows: rows,
            sessions: sessions,
            changes: changes,
            commands: commands,
            mostEfficientAgent: mostEfficientAgent,
            cheapestAgent: cheapestAgent,
            efficiencyCandidateCount: efficiencyCandidates.count,
            costCandidateCount: costCandidates.count,
            interfaceLanguage: interfaceLanguage
        )

        return AgentEfficiencyComparison(
            rows: rows,
            mostEfficientAgent: mostEfficientAgent,
            cheapestAgent: cheapestAgent,
            confidence: confidence,
            basis: basis
        )
    }

    // MARK: - 聚合与建表

    /// 单个 Agent 的原始聚合量，尚未换算成派生比率。
    private struct AgentAggregate {
        var sessionCount = 0
        var activeSeconds = 0.0
        var cpuSeconds = 0.0
        var changeCount = 0
        /// 该 Agent 触碰过的去重路径集合。
        var touchedPaths: Set<String> = []
        var commandCount = 0
        var failedCommandCount = 0
    }

    /// 由原始聚合量换算一行指标。
    private static func makeRow(
        kind: AgentKind,
        aggregate: AgentAggregate,
        kindCommands: [CommandRecord]
    ) -> AgentEfficiencyRow {
        let distinctFileCount = aggregate.touchedPaths.count
        return AgentEfficiencyRow(
            agentKind: kind,
            sessionCount: aggregate.sessionCount,
            changeCount: aggregate.changeCount,
            distinctFileCount: distinctFileCount,
            commandCount: aggregate.commandCount,
            failedCommandCount: aggregate.failedCommandCount,
            cpuSeconds: aggregate.cpuSeconds,
            activeSeconds: aggregate.activeSeconds,
            commandSuccessRate: InsightClassifier.successRate(of: kindCommands),
            filesPerSecond: filesPerSecond(distinctFileCount: distinctFileCount, activeSeconds: aggregate.activeSeconds),
            cpuSecondsPerFile: cpuSecondsPerFile(cpuSeconds: aggregate.cpuSeconds, distinctFileCount: distinctFileCount)
        )
    }

    /// 产出率：去重文件数 / 活跃秒。
    ///
    /// 活跃秒非正（该 Agent 没有任何有时间跨度的会话）时返回 `nil`——
    /// 此时「每秒产出多少文件」在数学上无定义，给 0 会被误读成「白跑了一小时」。
    private static func filesPerSecond(distinctFileCount: Int, activeSeconds: Double) -> Double? {
        guard activeSeconds > 0 else { return nil }
        let value = Double(distinctFileCount) / activeSeconds
        return value.isFinite ? value : nil
    }

    /// 成本：CPU 秒 / 去重文件数。
    ///
    /// 没有任何文件产出时返回 `nil`——除零无意义，且「零文件」既可能是真没干活，
    /// 也可能是文件监听没覆盖到，两种情况都不该被折算成一个成本数字。
    private static func cpuSecondsPerFile(cpuSeconds: Double, distinctFileCount: Int) -> Double? {
        guard distinctFileCount > 0 else { return nil }
        let value = cpuSeconds / Double(distinctFileCount)
        return value.isFinite ? value : nil
    }

    // MARK: - 排名规则

    /// 效率第一的排序：`filesPerSecond` 越大越靠前；并列取 `cpuSecondsPerFile` 更小者；再并列按 rawValue 升序。
    ///
    /// 返回值表示「`lhs` 是否排在 `rhs` 之前」。比较结果是全序（同 kind 只会并列成 `orderedSame`，
    /// 而行按 kind 去重），因此排序结果与输入顺序无关。
    private static func ranksBeforeForEfficiency(_ lhs: AgentEfficiencyRow, _ rhs: AgentEfficiencyRow) -> Bool {
        let primary = betterRank(lhs.filesPerSecond, rhs.filesPerSecond, higherIsBetter: true)
        if primary != .orderedSame { return primary == .orderedAscending }
        let secondary = betterRank(lhs.cpuSecondsPerFile, rhs.cpuSecondsPerFile, higherIsBetter: false)
        if secondary != .orderedSame { return secondary == .orderedAscending }
        return lhs.agentKind.rawValue < rhs.agentKind.rawValue
    }

    /// 成本最低的排序：`cpuSecondsPerFile` 越小越靠前；并列取 `filesPerSecond` 更大者；再并列按 rawValue 升序。
    private static func ranksBeforeForCost(_ lhs: AgentEfficiencyRow, _ rhs: AgentEfficiencyRow) -> Bool {
        let primary = betterRank(lhs.cpuSecondsPerFile, rhs.cpuSecondsPerFile, higherIsBetter: false)
        if primary != .orderedSame { return primary == .orderedAscending }
        let secondary = betterRank(lhs.filesPerSecond, rhs.filesPerSecond, higherIsBetter: true)
        if secondary != .orderedSame { return secondary == .orderedAscending }
        return lhs.agentKind.rawValue < rhs.agentKind.rawValue
    }

    /// 可选指标定序：`nil` 一律视为最差（缺数据不能赢过有数据），因此需要显式四路分支而不能直接比大小。
    ///
    /// - Returns: `.orderedAscending` 表示 `a` 更优，`.orderedDescending` 表示 `b` 更优。
    private static func betterRank(_ a: Double?, _ b: Double?, higherIsBetter: Bool) -> ComparisonResult {
        switch (a, b) {
        case (nil, nil):
            return .orderedSame
        case (.some, nil):
            return .orderedAscending
        case (nil, .some):
            return .orderedDescending
        case (.some(let left), .some(let right)):
            if left == right { return .orderedSame }
            let leftWins = higherIsBetter ? left > right : left < right
            return leftWins ? .orderedAscending : .orderedDescending
        }
    }

    // MARK: - 置信度

    /// 置信度证据：条数 = 三类输入之和；覆盖时长 = 会话时间戳跨度；缺失比例 = 未结束会话占比。
    ///
    /// 未结束的会话（`endedAt == nil`）意味着活跃时长只能靠注入时刻猜，属于关键字段缺失，
    /// 因此计入 `missingFieldRatio`。没有任何会话时按「全部缺失」处理（比例 1），
    /// 因为此时整张表都缺少时间维度。
    private static func makeConfidence(
        sessions: [AgentSession],
        changes: [FileChange],
        commands: [CommandRecord]
    ) -> InsightConfidence {
        var timestamps: [Date] = []
        timestamps.reserveCapacity(sessions.count * 2)
        var openSessionCount = 0
        for session in sessions {
            timestamps.append(session.startedAt)
            if let endedAt = session.endedAt {
                timestamps.append(endedAt)
            } else {
                openSessionCount += 1
            }
        }
        let coverage = InsightConfidenceEvaluator.coverageSeconds(of: timestamps)
        let missingRatio = sessions.isEmpty ? 1.0 : Double(openSessionCount) / Double(sessions.count)
        let evidence = InsightEvidence(
            observationCount: sessions.count + changes.count + commands.count,
            coverageSeconds: coverage,
            missingFieldRatio: missingRatio
        )
        return InsightConfidenceEvaluator.evaluate(evidence)
    }

    // MARK: - 依据说明

    /// 拼装人类可读依据：逐行列出核心指标，并在不给排名时说明「为什么不给」。
    private static func makeBasis(
        rows: [AgentEfficiencyRow],
        sessions: [AgentSession],
        changes: [FileChange],
        commands: [CommandRecord],
        mostEfficientAgent: AgentKind?,
        cheapestAgent: AgentKind?,
        efficiencyCandidateCount: Int,
        costCandidateCount: Int,
        interfaceLanguage: AppLanguage
    ) -> String {
        let language = interfaceLanguage
        guard !rows.isEmpty else {
            return InsightCopy.efficiencyNoData.text(language)
        }

        let rowText = rows.map { row -> String in
            InsightCopy.efficiencyRow.format(
                language,
                row.agentKind.displayName,
                format(row.activeSeconds, digits: 1),
                String(row.distinctFileCount),
                optionalValueText(row.filesPerSecond, digits: 4,
                                  unit: InsightCopy.efficiencyUnitFilesPerSecond.text(language),
                                  language: language),
                optionalValueText(row.cpuSecondsPerFile, digits: 3,
                                  unit: InsightCopy.efficiencyUnitCPUSecondsPerFile.text(language),
                                  language: language),
                row.commandSuccessRate.map { "\(format($0 * 100, digits: 1))%" }
                    ?? InsightCopy.efficiencyNoResolvedCommands.text(language)
            )
        }

        var segments = [
            InsightCopy.efficiencyHeader.format(language, String(rows.count), String(sessions.count),
                                                String(changes.count), String(commands.count),
                                                rowText.joined(separator: InsightCopy.joinerBar.text(language)))
        ]

        var winnerTexts: [String] = []
        var missingReasons: [String] = []
        if let mostEfficientAgent {
            winnerTexts.append(InsightCopy.efficiencyMostEfficient.format(language, mostEfficientAgent.displayName))
        } else {
            missingReasons.append(InsightCopy.efficiencyComparableOutput.format(language,
                                                                                String(efficiencyCandidateCount)))
        }
        if let cheapestAgent {
            winnerTexts.append(InsightCopy.efficiencyCheapest.format(language, cheapestAgent.displayName))
        } else {
            missingReasons.append(InsightCopy.efficiencyComparableCost.format(language, String(costCandidateCount)))
        }

        if !winnerTexts.isEmpty {
            segments.append(winnerTexts.joined(separator: " · "))
        }
        if !missingReasons.isEmpty {
            // 只有 1 个可对比样本时，排名等价于「把唯一样本重述一遍」，必须显式说明未下结论。
            // 句末句号由下面那次 join 统一补：文案自己不带，否则最后一个段会落成「。。」
            // （迁移前就是这个形状，见交付块）。
            segments.append(InsightCopy.efficiencyNoRanking.format(
                language, missingReasons.joined(separator: InsightCopy.joinerEnumeration.text(language))
            ))
        }
        return segments.joined(separator: InsightCopy.joinerSemicolon.text(language))
            + InsightCopy.sentenceEnd.text(language)
    }

    /// 可选派生指标的文案：`nil` 写成「不可计算」而不是悄悄滑成 0。
    private static func optionalValueText(_ value: Double?, digits: Int, unit: String,
                                          language: AppLanguage) -> String {
        guard let value else {
            return InsightCopy.efficiencyNotComputableWithUnit.format(language, unit)
        }
        return "\(format(value, digits: digits)) \(unit)"
    }

    /// 定点小数格式化。
    ///
    /// 手工取整拼串而不用 `String(format: "%.*f", ...)`：后者的小数点符号会随区域设置漂移，
    /// 同一份数据在不同机器的默认语言环境下会写出「4.00」和「4,00」两种依据文本，不可复核。
    private static func format(_ value: Double, digits: Int) -> String {
        guard value.isFinite else { return InsightCopy.notComputable.text() }
        let fractionDigits = max(0, digits)
        var scale = 1.0
        for _ in 0..<fractionDigits { scale *= 10 }

        let sign = value < 0 ? "-" : ""
        let scaled = (Swift.abs(value) * scale).rounded()
        guard fractionDigits > 0 else { return sign + String(Int(scaled)) }

        let integerPart = Int(scaled / scale)
        let fractionPart = Int(scaled - Double(integerPart) * scale)
        var fractionText = String(fractionPart)
        while fractionText.count < fractionDigits { fractionText = "0" + fractionText }
        return sign + String(integerPart) + "." + fractionText
    }
}
