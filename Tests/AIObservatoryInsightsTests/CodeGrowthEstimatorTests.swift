//
//  CodeGrowthEstimatorTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-Insights
//
//  代码增长验收：总量、按语言分组、每桶净行数与趋势都要命中手算值；
//  二进制变更必须被排除而不是当成 0 行。
//

import Testing
import Foundation
import AIObservatoryCore
@testable import AIObservatoryInsights

@Suite("代码增长估计", .timeLimit(.minutes(1)))
struct CodeGrowthEstimatorTests {

    private let start = InsightFixtures.epoch
    private let end = InsightFixtures.hours(3)

    private var handComputedSet: [FileChange] {
        [
            InsightFixtures.change("Sources/App.swift", at: start, added: 10, removed: 4),
            InsightFixtures.change("Sources/Model.swift", at: InsightFixtures.hours(1), added: 6, removed: 0),
            InsightFixtures.change("README.md", at: InsightFixtures.hours(2), agent: .openAICodex, added: 3, removed: 1),
            InsightFixtures.change("asset.png", at: InsightFixtures.hours(3), added: 999, removed: 999, isText: false)
        ]
    }

    @Test("手算用例：+19/−5 → 净 14 行，二进制不入账，趋势按桶斜率判为下降")
    func handComputedSummary() {
        let summary = CodeGrowthEstimator.summarize(
            changes: handComputedSet,
            windowStart: start,
            windowEnd: end,
            bucketSeconds: 3_600
        )
        #expect(summary.linesAdded == 19)
        #expect(summary.linesRemoved == 5)
        #expect(summary.netLines == 14)
        #expect(summary.fileCount == 3)
        #expect(summary.skippedChangeCount == 1)
        // 桶：[0,1h) → +6，[1h,2h) → +6，[2h,3h) → +2；斜率 -2 → falling
        #expect(summary.netLinesPerBucket == [6, 6, 2])
        #expect(summary.trend == .falling)
        #expect(summary.confidence == .low)
        #expect(summary.basis.contains("二进制"))
    }

    @Test("按语言与按文件分组：Swift 12 行 / Markdown 2 行")
    func grouping() {
        let summary = CodeGrowthEstimator.summarize(
            changes: handComputedSet,
            windowStart: start,
            windowEnd: end,
            bucketSeconds: 3_600
        )
        let swift = summary.byLanguage.first { $0.language == "Swift" }
        let markdown = summary.byLanguage.first { $0.language == "Markdown" }
        #expect(swift?.fileCount == 2)
        #expect(swift?.linesAdded == 16)
        #expect(swift?.linesRemoved == 4)
        #expect(swift?.netLines == 12)
        #expect(markdown?.fileCount == 1)
        #expect(markdown?.netLines == 2)
        #expect(summary.byLanguage.first?.language == "Swift")
        #expect(summary.byFile.first?.path == "Sources/App.swift")
        #expect(summary.byFile.first?.netLines == 6)
        #expect(summary.byFile.first?.changeCount == 1)
    }

    @Test("后缀 → 语言归类：大小写无关，点文件与无后缀文件归 Other")
    func languageMapping() {
        #expect(CodeGrowthEstimator.language(forPath: "a/b/Sources.swift") == "Swift")
        #expect(CodeGrowthEstimator.language(forPath: "main.PY") == "Python")
        #expect(CodeGrowthEstimator.language(forPath: "app.tsx") == "TypeScript")
        #expect(CodeGrowthEstimator.language(forPath: "README.markdown") == "Markdown")
        #expect(CodeGrowthEstimator.language(forPath: ".gitignore") == "Other")
        #expect(CodeGrowthEstimator.language(forPath: "Dockerfile") == "Other")
        #expect(CodeGrowthEstimator.language(forPath: "archive.tar.gz") == "Other")
        #expect(CodeGrowthEstimator.language(forPath: "weird.") == "Other")
        #expect(CodeGrowthEstimator.language(forPath: "dir/x.y.rs") == "Rust")
    }

    @Test("净行数为负也能算准：删除为主的项目 netLines < 0")
    func netNegative() {
        let rows = [
            InsightFixtures.change("a.swift", at: start, added: 1, removed: 40),
            InsightFixtures.change("b.swift", at: InsightFixtures.minutes(10), added: 0, removed: 10)
        ]
        let summary = CodeGrowthEstimator.summarize(
            changes: rows, windowStart: start, windowEnd: InsightFixtures.hours(1), bucketSeconds: 1_800
        )
        #expect(summary.netLines == -49)
        // 两条改动都落在 [0,30min) → 桶 0 = -49，桶 1 = 0；斜率 +49 → rising
        #expect(summary.netLinesPerBucket == [-49, 0])
        #expect(summary.trend == .rising)
    }

    @Test("窗口非法（起终相同）：桶与趋势不可计算，但总量仍然准确")
    func invalidWindow() {
        let summary = CodeGrowthEstimator.summarize(
            changes: handComputedSet,
            windowStart: start,
            windowEnd: start,
            bucketSeconds: 3_600
        )
        #expect(summary.netLinesPerBucket.isEmpty)
        #expect(summary.trend == .unknown)
        #expect(summary.netLines == 14)
    }

    @Test("单桶窗口无法判断趋势：明确 unknown，而不是假装 flat")
    func singleBucketIsUnknownTrend() {
        let summary = CodeGrowthEstimator.summarize(
            changes: handComputedSet,
            windowStart: start,
            windowEnd: InsightFixtures.hours(1),
            bucketSeconds: 3_600
        )
        #expect(summary.netLinesPerBucket.count == 1)
        #expect(summary.trend == .unknown)
    }

    @Test("空输入：全零 + unknown + low，basis 说明无文本变更")
    func emptyInput() {
        let summary = CodeGrowthEstimator.summarize(
            changes: [], windowStart: start, windowEnd: end, bucketSeconds: 600
        )
        #expect(summary.netLines == 0)
        #expect(summary.fileCount == 0)
        #expect(summary.netLinesPerBucket.isEmpty)
        #expect(summary.trend == .unknown)
        #expect(summary.confidence == .low)
        #expect(summary.basis.contains("不可估计"))
    }

    @Test("缺失一半不可计行的变更 → 置信度从 high 掉到 low")
    func missingDataLowersConfidence() {
        let text = InsightFixtures.changes(count: 40, pathPrefix: "s", start: start, step: 180, added: 5, removed: 2)
        let windowEnd = start.addingTimeInterval(7_200)
        let clean = CodeGrowthEstimator.summarize(
            changes: text, windowStart: start, windowEnd: windowEnd, bucketSeconds: 900
        )
        let halfBinary = text.prefix(24).map { row -> FileChange in
            FileChange(
                path: row.path + ".png",
                kind: row.kind,
                timestamp: row.timestamp,
                agentKind: row.agentKind,
                isText: false,
                linesAdded: row.linesAdded,
                linesRemoved: row.linesRemoved
            )
        }
        let degraded = CodeGrowthEstimator.summarize(
            changes: Array(text) + Array(halfBinary),
            windowStart: start,
            windowEnd: windowEnd,
            bucketSeconds: 900
        )
        #expect(clean.confidence == .high)
        #expect(degraded.confidence == .low)
        #expect(degraded.skippedChangeCount == 24)
    }
}
