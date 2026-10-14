//
//  CommandRuleSupport.swift
//  Rules
//
//  Owner: WS-Agent（由 CommandBehaviorRules.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import AIObservatoryCore
// MARK: - Shared support

/// 本族看待一条命令的统一视角：契约记录 + 结构化 argv 事实 + 可复用的 L1 结论。
struct CommandSample {

    /// 契约层命令记录。
    let record: CommandRecord

    /// 用 `window.homeDirectory` 注入构造的结构化事实。
    let facts: RiskCommandFacts

    /// 复用上游（L1）得到的分类；`nil` 表示上游未判定。
    let upstream: CommandClassification?
}

/// C 族共用的纯函数小工具（等级合成、分桶、argv token 级选项谓词）。
enum CommandRuleSupport {

    /// 共用的结构性分类器（无可变状态，可重复使用）。
    static let classifier = RiskCommandClassifier()

    /// 把窗口内命令一次性构造成 `CommandSample`，保持 `sortedCommands` 的确定性顺序。
    static func samples(in window: RiskFactWindow) -> [CommandSample] {
        window.sortedCommands.map { record in
            CommandSample(
                record: record,
                facts: RiskCommandFacts(record, homeDirectory: window.homeDirectory),
                upstream: window.classification(for: record)
            )
        }
    }

    /// 等级取更高者。
    static func maxLevel(_ lhs: RiskLevel, _ rhs: RiskLevel) -> RiskLevel {
        lhs.rank >= rhs.rank ? lhs : rhs
    }

    /// 以 `baseline` 为地板，叠加复用到的 L1 等级（只升不降）。
    static func level(baseline: RiskLevel, upstream: [CommandClassification?]) -> RiskLevel {
        upstream.reduce(baseline) { current, provided in
            guard let provided else { return current }
            return maxLevel(current, provided.level)
        }
    }

    /// 最具代表性的一条命令：L1 等级最高者优先，并列取时间最早（输入已按时间排序）。
    static func representative(of samples: [CommandSample]) -> CommandSample? {
        var chosen: CommandSample?
        for sample in samples {
            guard let current = chosen else {
                chosen = sample
                continue
            }
            if (sample.upstream?.level.rank ?? -1) > (current.upstream?.level.rank ?? -1) {
                chosen = sample
            }
        }
        return chosen
    }

    /// 命令文本摘要（最多 `limit` 条，超出补总数），用于 detail。
    static func commandList(of samples: [CommandSample], limit: Int = 3) -> String {
        guard !samples.isEmpty else { return "（无）" }
        let texts = samples.prefix(limit).map { $0.facts.commandLine }
        let joined = texts.joined(separator: "；")
        return samples.count > limit ? joined + "（共 \(samples.count) 条）" : joined
    }

    /// 证据时间跨度（秒）；无跨度返回 nil。输入必须已按时间升序。
    static func span(of samples: [CommandSample]) -> TimeInterval? {
        guard let first = samples.first?.record.startedAt, let last = samples.last?.record.startedAt else { return nil }
        let seconds = last.timeIntervalSince(first)
        return seconds > 0 ? seconds : nil
    }

    /// 命令实参里的目标路径，去重并保持出现顺序。
    static func targetPaths(of samples: [CommandSample], limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for sample in samples {
            for path in sample.facts.targetPaths where !seen.contains(path) {
                seen.insert(path)
                out.append(path)
                if out.count >= limit { return out }
            }
        }
        return out
    }

    /// 文件变更路径，去重并保持出现顺序。
    static func paths(of changes: [FileChange], limit: Int = 8) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for change in changes where !seen.contains(change.path) {
            seen.insert(change.path)
            out.append(change.path)
            if out.count >= limit { return out }
        }
        return out
    }

    /// 命令自己的 agent；缺失时回退到窗口主 agent。
    static func agentKind(for sample: CommandSample, window: RiskFactWindow) -> AgentKind {
        sample.record.agentKind == .unknown ? window.agentKind : sample.record.agentKind
    }

    /// 出现过的提权包装器名称（按首次出现顺序）。
    static func wrapperLabel(of samples: [CommandSample]) -> String {
        var labels: [String] = []
        for sample in samples {
            guard let wrapper = sample.facts.privilegeWrapper, !labels.contains(wrapper) else { continue }
            labels.append(wrapper)
        }
        return labels.isEmpty ? "提权" : labels.joined(separator: "/")
    }

    /// 按标签分桶，桶顺序 = 该标签首次出现的时间顺序（确定性）。
    static func group(_ samples: [CommandSample], by labeler: (CommandSample) -> String) -> [(label: String, samples: [CommandSample])] {
        var labels: [String] = []
        var buckets: [String: [CommandSample]] = [:]
        for sample in samples {
            let label = labeler(sample)
            if buckets[label] == nil { labels.append(label) }
            buckets[label, default: []].append(sample)
        }
        return labels.compactMap { label in buckets[label].map { (label: label, samples: $0) } }
    }

    // MARK: 选项级结构谓词
    //
    // `RiskCommandFacts.shortFlags` 会把任意单横线 token 逐字母展开（`-Xswiftc` → x/s/w/i/f/t/c），
    // 直接用 `hasShortFlag("f")` 会把编译类工具链参数误读成"强制/自动确认"。
    // 因此本族对"自动确认""破坏性力度"这类判定改为比较**完整 argv token**，
    // 仍然是结构化谓词（只看单个参数），不匹配命令文本。

    /// 表示"跳过交互确认"的长选项名（去掉 `--`，小写）。
    static let autoConfirmLongOptions: Set<String> = [
        "yes", "force", "assume-yes", "no-input", "no-confirm", "noconfirm",
        "non-interactive", "skip-confirmation", "unattended", "batch"
    ]

    /// 表示"跳过交互确认 / 强制执行"的短选项字母。
    static let autoConfirmShortLetters: Set<Character> = ["y"]

    /// 递归/强制类短选项字母（用于失败后升级的力度评分）。
    static let escalatingShortLetters: Set<Character> = ["r", "f", "d", "x", "q"]

    /// 力度升级长选项（`--force-with-lease` 有意排除：它比 `--force` 更安全）。
    static let escalatingLongOptions: Set<String> = [
        "force", "hard", "recursive", "yes", "assume-yes", "no-preserve-root",
        "delete", "prune", "untracked", "all"
    ]

    /// 是否带自动确认/跳过确认标志。
    /// 是否显式要求"跳过确认"。
    ///
    /// 口径：长选项按名字精确匹配；短选项只认独立的 `-f`（`--force` 的短形式），
    /// 聚合短选项里只认 `y`。这样 `rm -rf` 不会被算成"跳确认"，
    /// 而 `apt-get -y`、`npm i -fg`、`--no-input` 会。
    static func hasAutoConfirmFlag(_ facts: RiskCommandFacts) -> Bool {
        for argument in facts.effectiveArguments {
            let token = argument.lowercased()
            if token.hasPrefix("--") {
                if autoConfirmLongOptions.contains(String(token.dropFirst(2))) { return true }
            } else if token == "-f" {
                return true
            } else if token.hasPrefix("-"), token.count > 1 {
                let letters = Array(token.dropFirst())
                guard letters.count <= 3 else { continue }
                if letters.contains(where: { autoConfirmShortLetters.contains($0) }) { return true }
            }
        }
        return false
    }

    /// 该命令里代表"力度/破坏性"的完整选项 token（如 `-rf`、`--force`）。
    static func strengthTokens(_ facts: RiskCommandFacts) -> [String] {
        facts.effectiveArguments.compactMap { argument in
            let token = argument.lowercased()
            guard token.hasPrefix("-"), token.count > 1 else { return nil }
            if token.hasPrefix("--") {
                return escalatingLongOptions.contains(String(token.dropFirst(2))) ? token : nil
            }
            let letters = Array(token.dropFirst())
            guard !letters.isEmpty, letters.count <= 3 else { return nil }
            return letters.allSatisfy { escalatingShortLetters.contains($0) } ? token : nil
        }
    }

    /// 失败后升级用的"力度"评分：提权包装权重最高，其次破坏性选项。
    static func retryStrength(_ facts: RiskCommandFacts) -> Int {
        var score = facts.privilegeWrapper == nil ? 0 : 8
        for argument in facts.effectiveArguments {
            let token = argument.lowercased()
            if token.hasPrefix("--") {
                if escalatingLongOptions.contains(String(token.dropFirst(2))) { score += 3 }
            } else if token.hasPrefix("-"), token.count > 1 {
                let letters = Array(token.dropFirst())
                guard letters.count <= 3 else { continue }
                let known = letters.filter { escalatingShortLetters.contains($0) }
                if !known.isEmpty, known.count == letters.count { score += 2 * known.count }
            }
        }
        return score
    }

    /// 相对失败命令新增加的力度信号，供 detail 说明升级方式。
    static func addedStrengthSignal(from failed: CommandSample, to retry: CommandSample) -> String {
        let before = strengthTokens(failed.facts)
        let added = strengthTokens(retry.facts).filter { !before.contains($0) }
        if !added.isEmpty { return added.joined(separator: " ") }
        if failed.facts.privilegeWrapper == nil, let wrapper = retry.facts.privilegeWrapper {
            return "提权包装 \(wrapper)"
        }
        return "更强的参数组合"
    }

    /// 命令是否以失败告终（`exitCode != 0` 或 `outcome == .failure/.terminated`）。
    static func isFailure(_ sample: CommandSample) -> Bool {
        if sample.record.outcome == .failure || sample.record.outcome == .terminated { return true }
        if let code = sample.record.exitCode, code != 0 { return true }
        return false
    }
}

