//
//  InsightClassification.swift
//  AIObservatoryInsights
//
//  Owner: WS-Insights
//

import Foundation
import AIObservatoryCore

/// 命令的三态判定结果。
///
/// 特意保留 `unresolved`：把「还没跑完 / 没采到退出码」当成失败，会凭空造出失败率。
/// `unresolved` 装的就是这一类**事实缺失**，不是「第三种结局」。
public enum InsightOutcome: String, Codable, Sendable, CaseIterable, Hashable {
    case succeeded
    case failed
    case unresolved

    /// 显示名，按当前进程语言取（判定结果只在看的时候渲染）。
    public var displayName: String { displayName(AppLanguage.resolved()) }

    /// 按指定语言取（拼句时用这条，理由同 `InsightTrend.displayName(_:)`）。
    public func displayName(_ language: AppLanguage) -> String {
        switch self {
        case .succeeded:  return InsightCopy.outcomeSucceeded.text(language)
        case .failed:     return InsightCopy.outcomeFailed.text(language)
        case .unresolved: return InsightCopy.outcomeUnresolved.text(language)
        }
    }
}

/// 跨模块共用的判定规则。集中在此，避免产量统计与效率对比给出两套成功率。
public enum InsightClassifier {
    /// 命令成败判定，按顺序匹配：
    /// 1. `outcome == .success` → 成功；
    /// 2. `outcome == .failure` → 失败；
    /// 3. `outcome == .terminated` → **未判定**（#76，对齐引擎侧口径红线：
    ///    `AIObservatoryEngine/ObservatoryEngine+Ingestion.swift` 的 `settleOpenCommands` 明写
    ///    「`.terminated` 不等于成功也不等于失败——没有 shell hook 就不知道退出码」，
    ///    那条收口路径只会写 `endedAt` 而**永远不写退出码**（这个不变量由
    ///    `SwiftDataBackendDifferentialTests` 的「terminated 不得冒充成败」钉着）。
    ///    把它算进失败 = 凭「没看到退出码」这一件事造出失败率，正是本枚举保留 `unresolved` 的理由。
    ///    这里刻意**不看** `exitCode`：一条 `.terminated` 记录若真带着退出码，那是两个生产者打架，
    ///    宁可判「未判定」也不替任何一方背书（真机库里这种形状 0 条）；
    /// 4. 有 `exitCode`：`0` → 成功，非 `0` → 失败；
    /// 5. 其余（`.running` / `.unknown` 且无退出码）→ 未判定。
    public static func classify(outcome: CommandOutcome, exitCode: Int32?) -> InsightOutcome {
        switch outcome {
        case .success:
            return .succeeded
        case .failure:
            return .failed
        case .terminated:
            return .unresolved
        case .running, .unknown:
            guard let exitCode else { return .unresolved }
            return exitCode == 0 ? .succeeded : .failed
        }
    }

    /// 一批命令的成功率，分母只含**已判定**命令；无可判定命令时返回 `nil`（不可估计，不等于 0）。
    public static func successRate(of records: [CommandRecord]) -> Double? {
        var succeeded = 0
        var resolved = 0
        for record in records {
            switch classify(outcome: record.outcome, exitCode: record.exitCode) {
            case .succeeded:
                succeeded += 1
                resolved += 1
            case .failed:
                resolved += 1
            case .unresolved:
                break
            }
        }
        guard resolved > 0 else { return nil }
        return Double(succeeded) / Double(resolved)
    }

    /// 命令是否携带结束时间且耗时非负。
    public static func durationSeconds(of record: CommandRecord) -> Double? {
        guard let endedAt = record.endedAt else { return nil }
        let seconds = endedAt.timeIntervalSince(record.startedAt)
        guard seconds >= 0, seconds.isFinite else { return nil }
        return seconds
    }
}
