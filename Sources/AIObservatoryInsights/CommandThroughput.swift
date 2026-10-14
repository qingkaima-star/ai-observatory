//
//  CommandThroughput.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

/// 命令产量：单位时间命令数、成败率、耗时分布（p50 / p95）。
///
/// 输入须已由 WS-Engine 的 `ProjectMapper` 按项目根归好组。
/// 成败判定统一走 `InsightClassifier`，与 Agent 效率对比共用同一口径。
public enum CommandThroughputAnalyzer {
    /// 汇总窗口内的命令行为。
    ///
    /// - Parameters:
    ///   - commands: 该项目的命令记录。
    ///   - windowStart/windowEnd: 统计窗口；吞吐率以窗口时长为分母，而非命令自身时间。
    /// - Returns: 产量汇总。空输入返回全 `nil` 指标 + `confidence == .low`。
    ///
    /// 「未判定」命令（仍在运行 / 没采到退出码）不进成功率分母：
    /// 把它们当失败会凭空造出失败率，当成功会虚报产量。
    public static func summarize(
        commands: [CommandRecord],
        windowStart: Date,
        windowEnd: Date,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> CommandThroughputSummary {
        let windowSeconds = max(0, windowEnd.timeIntervalSince(windowStart))

        guard !commands.isEmpty else {
            return CommandThroughputSummary(
                commandCount: 0,
                succeededCount: 0,
                failedCount: 0,
                unresolvedCount: 0,
                successRate: nil,
                failureRate: nil,
                commandsPerHour: nil,
                timedCommandCount: 0,
                averageDurationSeconds: nil,
                medianDurationSeconds: nil,
                p95DurationSeconds: nil,
                destructiveCount: 0,
                windowSeconds: windowSeconds,
                confidence: .low,
                basis: InsightCopy.throughputNoCommands.text(interfaceLanguage)
            )
        }

        var succeeded = 0
        var failed = 0
        var unresolved = 0
        var destructive = 0
        var durations: [Double] = []
        var incompleteCount = 0

        for command in commands {
            let outcome = InsightClassifier.classify(outcome: command.outcome, exitCode: command.exitCode)
            switch outcome {
            case .succeeded: succeeded += 1
            case .failed: failed += 1
            case .unresolved: unresolved += 1
            }
            if command.isDestructive { destructive += 1 }

            if let duration = InsightClassifier.durationSeconds(of: command) {
                durations.append(duration)
            } else {
                incompleteCount += 1
            }
        }

        let resolved = succeeded + failed
        let successRate = resolved > 0 ? Double(succeeded) / Double(resolved) : nil
        let failureRate = resolved > 0 ? Double(failed) / Double(resolved) : nil
        let commandsPerHour = windowSeconds > 0
            ? Double(commands.count) / (windowSeconds / 3600)
            : nil

        let confidence = InsightConfidenceEvaluator.evaluate(
            InsightEvidence(
                observationCount: commands.count,
                coverageSeconds: windowSeconds,
                missingFieldRatio: Double(incompleteCount + unresolved) / Double(commands.count)
            )
        )

        return CommandThroughputSummary(
            commandCount: commands.count,
            succeededCount: succeeded,
            failedCount: failed,
            unresolvedCount: unresolved,
            successRate: successRate,
            failureRate: failureRate,
            commandsPerHour: commandsPerHour,
            timedCommandCount: durations.count,
            averageDurationSeconds: InsightStatistics.mean(durations),
            medianDurationSeconds: InsightStatistics.percentile(durations, at: 0.5),
            p95DurationSeconds: InsightStatistics.percentile(durations, at: 0.95),
            destructiveCount: destructive,
            windowSeconds: windowSeconds,
            confidence: confidence,
            basis: basis(
                total: commands.count,
                succeeded: succeeded,
                failed: failed,
                unresolved: unresolved,
                destructive: destructive,
                timed: durations.count,
                successRate: successRate,
                commandsPerHour: commandsPerHour,
                p95: InsightStatistics.percentile(durations, at: 0.95),
                interfaceLanguage: interfaceLanguage
            )
        )
    }

    private static func basis(
        total: Int,
        succeeded: Int,
        failed: Int,
        unresolved: Int,
        destructive: Int,
        timed: Int,
        successRate: Double?,
        commandsPerHour: Double?,
        p95: Double?,
        interfaceLanguage: AppLanguage
    ) -> String {
        var parts: [String] = []
        if let commandsPerHour {
            parts.append(InsightCopy.throughputPerHour.format(interfaceLanguage,
                                                              String(format: "%.1f", commandsPerHour)))
        } else {
            parts.append(InsightCopy.throughputNoWindow.text(interfaceLanguage))
        }
        parts.append(InsightCopy.throughputTotal.format(interfaceLanguage, String(total)))
        if let successRate {
            parts.append(InsightCopy.throughputSuccess.format(interfaceLanguage, String(succeeded),
                                                              String(succeeded + failed),
                                                              percentText(successRate)))
        } else {
            parts.append(InsightCopy.throughputAllUnresolved.format(interfaceLanguage, String(unresolved)))
        }
        if failed > 0 { parts.append(InsightCopy.throughputFailed.format(interfaceLanguage, String(failed))) }
        if destructive > 0 {
            parts.append(InsightCopy.throughputDestructive.format(interfaceLanguage, String(destructive)))
        }
        if let p95 {
            parts.append(InsightCopy.throughputP95.format(interfaceLanguage, String(format: "%.2f", p95),
                                                          String(timed), String(total)))
        } else {
            parts.append(InsightCopy.throughputNoDurations.text(interfaceLanguage))
        }
        return parts.joined(separator: " · ")
    }

    private static func percentText(_ value: Double) -> String {
        let clamped = min(1, max(0, value))
        let basisPoints = Int(clamped * 10_000)
        return String(format: "%d.%02d%%", basisPoints / 100, basisPoints % 100)
    }
}
