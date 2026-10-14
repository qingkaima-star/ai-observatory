//
//  CommandThroughputTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  命令产量验收：成功率分母只含已判定命令；分位数覆盖空/单/奇偶；窗口非法时不编造吞吐率。
//

import Testing
import Foundation
import AIObservatoryCore
@testable import AIObservatoryInsights

@Suite("命令产量与耗时分布", .timeLimit(.minutes(1)))
struct CommandThroughputTests {

    private let start = InsightFixtures.epoch
    private let windowEnd = InsightFixtures.hours(2)

    /// 6 成功（1..6s）+ 3 失败（7..9s）+ 1 未判定（无结束时间），其中 2 条破坏性。
    private var handComputedSet: [CommandRecord] {
        var rows: [CommandRecord] = []
        for second in 1...6 {
            rows.append(InsightFixtures.command(
                "swift",
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(second)),
                outcome: .success,
                exitCode: 0,
                destructive: second <= 2
            ))
        }
        for second in 7...9 {
            rows.append(InsightFixtures.command(
                "git",
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(second)),
                outcome: .failure,
                exitCode: 1
            ))
        }
        rows.append(InsightFixtures.command("tail", startedAt: start, outcome: .running, exitCode: nil))
        return rows
    }

    @Test("手算用例：成败计数、6/9 成功率、p50=5 与 p95=8.6、5 条/小时")
    func handComputedSummary() {
        let summary = CommandThroughputAnalyzer.summarize(commands: handComputedSet, windowStart: start, windowEnd: windowEnd)
        #expect(summary.commandCount == 10)
        #expect(summary.succeededCount == 6)
        #expect(summary.failedCount == 3)
        #expect(summary.unresolvedCount == 1)
        #expect(summary.destructiveCount == 2)
        #expect(aixOptionalClose(summary.successRate, 0.666_666_666_666_666_6))
        #expect(aixOptionalClose(summary.failureRate, 0.333_333_333_333_333_3))
        #expect(summary.timedCommandCount == 9)
        #expect(aixOptionalClose(summary.averageDurationSeconds, 5))
        #expect(aixOptionalClose(summary.medianDurationSeconds, 5))
        #expect(aixOptionalClose(summary.p95DurationSeconds, 8.6))
        #expect(aixOptionalClose(summary.commandsPerHour, 5))
        #expect(summary.windowSeconds == 7_200)
        #expect(summary.confidence == .medium)
    }

    @Test("空输入：指标为 nil 而不是 0，吞吐率/成功率都不许凭空出现")
    func emptyInput() {
        let summary = CommandThroughputAnalyzer.summarize(commands: [], windowStart: start, windowEnd: windowEnd)
        #expect(summary.commandCount == 0)
        #expect(summary.successRate == nil)
        #expect(summary.failureRate == nil)
        #expect(summary.commandsPerHour == nil)
        #expect(summary.averageDurationSeconds == nil)
        #expect(summary.medianDurationSeconds == nil)
        #expect(summary.p95DurationSeconds == nil)
        #expect(summary.confidence == .low)
        #expect(summary.basis.contains("不可估计"))
    }

    @Test("单条命令：分位数退化为该值（不再插值）")
    func singleCommand() {
        let rows = [InsightFixtures.command(
            "ls", startedAt: start, endedAt: start.addingTimeInterval(4), outcome: .success, exitCode: 0
        )]
        let summary = CommandThroughputAnalyzer.summarize(commands: rows, windowStart: start, windowEnd: windowEnd)
        #expect(summary.timedCommandCount == 1)
        #expect(aixOptionalClose(summary.medianDurationSeconds, 4))
        #expect(aixOptionalClose(summary.p95DurationSeconds, 4))
        #expect(aixOptionalClose(summary.averageDurationSeconds, 4))
        #expect(summary.successRate.map { aixClose($0, 1) } == true)
        #expect(summary.confidence == .low)
    }

    @Test("零长度窗口：吞吐率不可估计（不许除以 0）")
    func zeroLengthWindow() {
        let summary = CommandThroughputAnalyzer.summarize(commands: handComputedSet, windowStart: start, windowEnd: start)
        #expect(summary.commandsPerHour == nil)
        #expect(summary.windowSeconds == 0)
        #expect(summary.commandCount == 10)
        #expect(summary.successRate != nil)
    }

    @Test("全部未判定：不给出成败率，并在 basis 里说明")
    func allUnresolved() {
        let rows = (0..<9).map { _ in
            InsightFixtures.command("sleep", startedAt: start, outcome: .running, exitCode: nil)
        }
        let summary = CommandThroughputAnalyzer.summarize(commands: rows, windowStart: start, windowEnd: windowEnd)
        #expect(summary.unresolvedCount == 9)
        #expect(summary.successRate == nil)
        #expect(summary.failureRate == nil)
        #expect(summary.timedCommandCount == 0)
        #expect(summary.basis.contains("未判定"))
        #expect(summary.confidence == .low)
    }

    /// #76 改写过这里的一条：旧断言 `classify(.terminated, exitCode: 0) == .failed`
    /// 断的是「终止按失败计、且 outcome 压过退出码」——前半句正是被引擎红线否掉的口径
    /// （`ObservatoryEngine+Ingestion.settleOpenCommands`：`.terminated` 不等于成功也不等于失败），
    /// 后半句在真库里没有对应物：那条收口路径只写 `endedAt`、永不写退出码
    /// （`SwiftDataBackendDifferentialTests` 钉着「terminated 的退出码必须仍是 nil」）。
    @Test("判定优先级：outcome 明确时压过退出码，未知 outcome 才回落到退出码")
    func classificationPrecedence() {
        #expect(InsightClassifier.classify(outcome: .success, exitCode: nil) == .succeeded)
        // 被终止 = 退出码未知 ⇒ 未判定，不进失败分子也不进成功率分母
        #expect(InsightClassifier.classify(outcome: .terminated, exitCode: nil) == .unresolved)
        #expect(InsightClassifier.classify(outcome: .terminated, exitCode: 0) == .unresolved)
        #expect(InsightClassifier.classify(outcome: .terminated, exitCode: 2) == .unresolved)
        #expect(InsightClassifier.classify(outcome: .failure, exitCode: nil) == .failed)
        #expect(InsightClassifier.classify(outcome: .unknown, exitCode: 0) == .succeeded)
        #expect(InsightClassifier.classify(outcome: .unknown, exitCode: 2) == .failed)
        #expect(InsightClassifier.classify(outcome: .unknown, exitCode: nil) == .unresolved)
        #expect(InsightClassifier.classify(outcome: .running, exitCode: 1) == .failed)
    }

    /// 台账第 5 节验收 2 点名的那一格：`.terminated` 既不进失败计数，
    /// 也不进「已解决」的分母——成功率必须是 nil（不可估计），不是 0 %（那是一句谎）。
    @Test("terminated：失败计数 0、成功率不可估计，不进任何一侧的分母")
    func terminatedIsNeitherFailedNorResolved() {
        let rows = [
            InsightFixtures.command(
                "npm run dev",
                startedAt: start,
                endedAt: start.addingTimeInterval(30),
                outcome: .terminated,
                exitCode: nil
            )
        ]
        let summary = CommandThroughputAnalyzer.summarize(commands: rows, windowStart: start, windowEnd: windowEnd)
        #expect(summary.commandCount == 1)
        #expect(summary.failedCount == 0, "terminated 又被算成失败了")
        #expect(summary.succeededCount == 0)
        #expect(summary.unresolvedCount == 1)
        #expect(summary.successRate == nil, "一条都没判定时不许给成功率，哪怕是 0")
        #expect(summary.failureRate == nil)
        #expect(InsightClassifier.successRate(of: rows) == nil)
    }

    /// 同一条 terminated 记录混在真成败之间时的算术：它只出现在 `unresolvedCount`，
    /// 成功率分母仍是 2（1 成功 + 1 失败），不是 3。
    @Test("terminated 混在真成败里：只加未判定那一格，成功率分母不动")
    func terminatedStaysOutOfResolvedDenominator() {
        let rows = [
            InsightFixtures.command("true", startedAt: start, outcome: .success, exitCode: 0),
            InsightFixtures.command("false", startedAt: start, outcome: .failure, exitCode: 1),
            InsightFixtures.command("npm run dev", startedAt: start, outcome: .terminated, exitCode: nil)
        ]
        let summary = CommandThroughputAnalyzer.summarize(commands: rows, windowStart: start, windowEnd: windowEnd)
        #expect(summary.succeededCount == 1)
        #expect(summary.failedCount == 1)
        #expect(summary.unresolvedCount == 1)
        #expect(aixOptionalClose(summary.successRate, 0.5))
        #expect(aixOptionalClose(summary.failureRate, 0.5))
    }

    @Test("耗时口径：endedAt 早于 startedAt 的脏数据不入样")
    func negativeDurationExcluded() {
        let rows = [
            InsightFixtures.command("ok", startedAt: start, endedAt: start.addingTimeInterval(3), outcome: .success, exitCode: 0),
            InsightFixtures.command("bad", startedAt: start, endedAt: start.addingTimeInterval(-5), outcome: .success, exitCode: 0)
        ]
        let summary = CommandThroughputAnalyzer.summarize(commands: rows, windowStart: start, windowEnd: windowEnd)
        #expect(summary.timedCommandCount == 1)
        #expect(aixOptionalClose(summary.averageDurationSeconds, 3))
        #expect(InsightClassifier.durationSeconds(of: rows[1]) == nil)
    }

    @Test("样本减半 → 置信度下降；分位数在偶数长度上取两中点")
    func halvedDataAndEvenPercentile() {
        let rows = (0..<40).map { index in
            InsightFixtures.command(
                "git",
                startedAt: start,
                endedAt: start.addingTimeInterval(Double(index + 1)),
                outcome: .success,
                exitCode: 0
            )
        }
        let full = CommandThroughputAnalyzer.summarize(commands: rows, windowStart: start, windowEnd: windowEnd)
        let halved = CommandThroughputAnalyzer.summarize(commands: Array(rows.prefix(20)), windowStart: start, windowEnd: windowEnd)
        #expect(full.confidence == .high)
        #expect(halved.confidence < full.confidence)
        // 偶数长度 1..40：h=(39)*0.5=19.5 → 20 + 0.5*(21-20) = 20.5
        #expect(aixOptionalClose(full.medianDurationSeconds, 20.5))
    }
}
