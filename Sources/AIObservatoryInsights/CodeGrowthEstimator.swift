//
//  CodeGrowthEstimator.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

/// 代码增长估计：把逐条 `FileChange` 的增删行数汇总成「按文件 / 按语言 / 按时间桶」三视图。
///
/// 输入须已由 WS-Engine 的 `ProjectMapper` 按项目根归好组；本文件只做聚合。
/// 行数以契约里已算好的 `linesAdded` / `linesRemoved` 为准，不重新读盘算 diff。
public enum CodeGrowthEstimator {
    /// 后缀 → 语言名。未知或无后缀归为 `"Other"`。
    ///
    /// 点文件（`.gitignore`）与无后缀文件（`Dockerfile`）刻意归入 `Other`：
    /// 把 `.gitignore` 当成一种叫 "gitignore" 的语言会让语言分布出现噪声条目。
    public static func language(forPath path: String) -> String {
        let name = (path as NSString).lastPathComponent
        guard let dotIndex = name.lastIndex(of: "."), dotIndex != name.startIndex else { return otherLanguage }
        let ext = String(name[name.index(after: dotIndex)...]).lowercased()
        guard !ext.isEmpty else { return otherLanguage }
        return languageTable[ext] ?? otherLanguage
    }

    /// 增长汇总。
    ///
    /// - Parameters:
    ///   - changes: 单个项目的文件变更。
    ///   - windowStart/windowEnd: 时间桶窗口，`windowEnd > windowStart` 才能算趋势。
    ///   - bucketSeconds: 桶宽（秒）。
    ///   - trendThreshold: 判定「持平」的每桶净行数上限。
    /// - Returns: 汇总结果；空输入返回全零 + `trend == .unknown` + `confidence == .low`。
    ///
    /// 非文本（二进制）变更**不参与行数统计**：diff 对二进制没有行概念，
    /// 把它们算进去会凭空造出增长，因此只计入 `skippedChangeCount` 并在 `basis` 里说明。
    public static func summarize(
        changes: [FileChange],
        windowStart: Date,
        windowEnd: Date,
        bucketSeconds: Double,
        trendThreshold: Double = 1,
        interfaceLanguage: AppLanguage = .resolved()
    ) -> CodeGrowthSummary {
        var added = 0
        var removed = 0
        var skipped = 0
        var perPath: [String: PathAggregate] = [:]
        var datedNet: [(date: Date, amount: Double)] = []

        for change in changes {
            guard change.isText else {
                skipped += 1
                continue
            }
            let changeAdded = max(0, change.linesAdded)
            let changeRemoved = max(0, change.linesRemoved)
            added += changeAdded
            removed += changeRemoved
            var aggregate = perPath[change.path] ?? PathAggregate()
            aggregate.added += changeAdded
            aggregate.removed += changeRemoved
            aggregate.changeCount += 1
            perPath[change.path] = aggregate
            datedNet.append((change.timestamp, Double(changeAdded - changeRemoved)))
        }

        let includedCount = changes.count - skipped
        // 没有任何可计行的变更时，时间桶必须为空而不是「全 0 桶」：
        // 一串 0 会被读成「这个项目增长为 0」，而事实是「我们无从知道增长」。
        let hasEvidence = includedCount > 0

        let byFile = perPath.map { path, aggregate in
            CodeGrowthFile(
                path: path,
                language: language(forPath: path),
                linesAdded: aggregate.added,
                linesRemoved: aggregate.removed,
                netLines: aggregate.added - aggregate.removed,
                changeCount: aggregate.changeCount
            )
        }
        .sorted {
            if $0.netLines != $1.netLines { return $0.netLines > $1.netLines }
            if $0.path != $1.path { return $0.path < $1.path }
            return false
        }

        let byLanguage = groupedByLanguage(byFile)
        let perBucket = hasEvidence
            ? bucketNetLines(datedNet, windowStart: windowStart, windowEnd: windowEnd, bucketSeconds: bucketSeconds)
            : []
        let trend = trend(ofBucketedNetLines: perBucket, threshold: trendThreshold)
        let windowSeconds = max(0, windowEnd.timeIntervalSince(windowStart))
        let missingRatio = changes.isEmpty ? 1 : Double(skipped) / Double(changes.count)
        let confidence = InsightConfidenceEvaluator.evaluate(
            InsightEvidence(
                observationCount: includedCount,
                coverageSeconds: windowSeconds,
                missingFieldRatio: missingRatio
            )
        )

        return CodeGrowthSummary(
            linesAdded: added,
            linesRemoved: removed,
            netLines: added - removed,
            fileCount: perPath.count,
            skippedChangeCount: skipped,
            byFile: byFile,
            byLanguage: byLanguage,
            netLinesPerBucket: perBucket,
            trend: trend,
            confidence: confidence,
            basis: basis(
                added: added,
                removed: removed,
                net: added - removed,
                fileCount: perPath.count,
                skipped: skipped,
                byLanguage: byLanguage,
                trend: trend,
                interfaceLanguage: interfaceLanguage
            )
        )
    }

    /// 其他语言的分桶名。
    static let otherLanguage = "Other"

    private struct PathAggregate {
        var added: Int = 0
        var removed: Int = 0
        var changeCount: Int = 0
    }

    private static let languageTable: [String: String] = [
        "swift": "Swift",
        "ts": "TypeScript", "tsx": "TypeScript",
        "js": "JavaScript", "jsx": "JavaScript", "mjs": "JavaScript",
        "py": "Python",
        "md": "Markdown", "markdown": "Markdown",
        "java": "Java",
        "kt": "Kotlin", "kts": "Kotlin",
        "rs": "Rust",
        "go": "Go",
        "rb": "Ruby",
        "c": "C", "h": "C",
        "m": "Objective-C",
        "mm": "Objective-C++",
        "cpp": "C++", "cc": "C++", "cxx": "C++",
        "sh": "Shell", "zsh": "Shell", "bash": "Shell",
        "json": "JSON",
        "yaml": "YAML", "yml": "YAML",
        "toml": "TOML",
        "plist": "Property List",
        "html": "HTML",
        "css": "CSS",
        "txt": "Text"
    ]

    private static func groupedByLanguage(_ files: [CodeGrowthFile]) -> [CodeGrowthGroup] {
        let grouped = Dictionary(grouping: files, by: \.language)
        return grouped
            .map { language, rows in
                var added = 0
                var removed = 0
                for row in rows {
                    added += row.linesAdded
                    removed += row.linesRemoved
                }
                return CodeGrowthGroup(
                    language: language,
                    fileCount: rows.count,
                    linesAdded: added,
                    linesRemoved: removed,
                    netLines: added - removed
                )
            }
            .sorted {
                if $0.netLines != $1.netLines { return $0.netLines > $1.netLines }
                if $0.language != $1.language { return $0.language < $1.language }
                return false
            }
    }

    /// 每桶净增行数；窗口或桶宽非法时返回空数组（表示「趋势不可计算」而非「零增长」）。
    private static func bucketNetLines(
        _ datedNet: [(date: Date, amount: Double)],
        windowStart: Date,
        windowEnd: Date,
        bucketSeconds: Double
    ) -> [Int] {
        guard let sums = InsightStatistics.bucketSums(
            dated: datedNet,
            start: windowStart,
            end: windowEnd,
            bucketSeconds: bucketSeconds
        ) else { return [] }
        return sums.map { $0.isFinite ? Int($0.rounded(.towardZero)) : 0 }
    }

    private static func trend(ofBucketedNetLines buckets: [Int], threshold: Double) -> InsightTrend {
        guard buckets.count >= 2 else { return .unknown }
        let xs = (0..<buckets.count).map(Double.init)
        let ys = buckets.map(Double.init)
        return InsightTrend.of(slope: InsightStatistics.linearSlope(xs: xs, ys: ys), threshold: threshold)
    }

    private static func basis(
        added: Int,
        removed: Int,
        net: Int,
        fileCount: Int,
        skipped: Int,
        byLanguage: [CodeGrowthGroup],
        trend: InsightTrend,
        interfaceLanguage: AppLanguage
    ) -> String {
        let signedNet = "\(net >= 0 ? "+" : "")\(net)"
        var parts: [String] = [
            InsightCopy.growthNetLines.format(interfaceLanguage, signedNet, String(added), String(removed)),
            InsightCopy.growthFileCount.format(interfaceLanguage, String(fileCount)),
        ]
        if !byLanguage.isEmpty {
            let leading = byLanguage.prefix(3).map { "\($0.language) \(($0.netLines >= 0 ? "+" : ""))\($0.netLines)" }
            parts.append(leading.joined(separator: " · "))
        }
        parts.append(InsightCopy.growthTrend.format(interfaceLanguage, trend.displayName(interfaceLanguage)))
        if skipped > 0 {
            parts.append(InsightCopy.growthSkippedBinary.format(interfaceLanguage, String(skipped)))
        }
        if byLanguage.isEmpty {
            parts.append(InsightCopy.growthNoTextChanges.text(interfaceLanguage))
        }
        return parts.joined(separator: " · ")
    }
}
