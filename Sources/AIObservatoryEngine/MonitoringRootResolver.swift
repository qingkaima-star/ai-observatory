//
//  MonitoringRootResolver.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine（由 ObservatoryEngine.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import os
import CryptoKit
import AIObservatoryCore
import AIObservatoryRiskRules   // 装配点要直接构造 RiskAssessor（语言要同源）
import AIObservatoryStore
import AIObservatoryPlatform

// MARK: - Monitoring roots

/// 文件监控根推导：显式配置优先，其余从已识别 Agent 的工作目录上提到项目根。
/// 推导出家目录、`/Users/<name>` 或根目录一律拒绝（会退化成全盘扫描），并记日志。
public struct MonitoringRootResolver: Sendable {

    /// 项目根推导器；返回 nil 表示无法判定，此时回退到 cwd 本身。
    public var projectRootResolver: @Sendable (_ path: String) -> String?
    /// 忽略规则：命中的推导根不纳入监控。
    public var ignoredPathPatterns: [String]

    /// 用默认推导器（`PathHeuristics.enclosingProjectRoot`）装配。
    public init(
        projectRootResolver: @escaping @Sendable (_ path: String) -> String? = { PathHeuristics.enclosingProjectRoot(for: $0) },
        ignoredPathPatterns: [String] = []
    ) {
        self.projectRootResolver = projectRootResolver
        self.ignoredPathPatterns = ignoredPathPatterns
    }

    /// 不可监控的路径：`/`、当前用户家目录、家目录的直接父目录。
    public static func protectedRoots() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["/", home, (home as NSString).deletingLastPathComponent]
    }

    /// 路径是否等于某个受保护根（含空串）。
    public static func isProtected(_ path: String) -> Bool {
        let candidate = normalized(path)
        guard !candidate.isEmpty else { return true }
        return protectedRoots().map { normalized($0) }.contains(candidate)
    }

    /// 这个目录**能不能当作文件归因的前缀依据**。
    ///
    /// 归因是按「agent 的 cwd 是不是变更路径的前缀」做的，所以一个太浅的 cwd 会吞掉海量文件：
    /// dogfood 实测到真实事故——一个由 launchd 拉起、cwd 就是 `/` 的 Codex 进程，
    /// 把总控（Qoder，根本没被检出）改的 10 个文件**全部记成了它的**（`file_changes.agent_kind`）。
    /// 任何绝对路径都以 `/` 开头，于是它永远命中、还以「最长匹配」胜出。
    ///
    /// 这里把「能当前缀」的门槛抬到**至少两个路径分量**（即不能是 `/`、也不能是 `/Users` 这种半截根），
    /// 并复用监控面已有的 `protectedRoots()` 守卫——同一套「太浅的根」的判断，之前只在监控面用了，
    /// 归因面漏用。**宁可判成「未归属」，也不要拿一个不相干的 agent 顶上**：
    /// 本产品是审计工具，错归属产出的不是不完整数据而是假证据。
    public static func isUsableAttributionRoot(_ path: String) -> Bool {
        let candidate = normalized(path)
        guard !candidate.isEmpty else { return false }
        guard !isProtected(candidate) else { return false }
        let components = candidate
            .split(separator: "/", omittingEmptySubsequences: true)
        return components.count >= 2
    }

    /// 解析最终监控根集合：显式配置 ∪ 推导结果，去重并剔除受保护与被忽略的路径。
    /// 返回值升序，保证同一输入得到同一集合（可测、可复现）。
    public func resolve(explicit: [String], agents: [AgentInstance]) -> [String] {
        resolveScope(explicit: explicit, agents: agents, now: Date()).keptRoots
    }

    /// 与 `resolve` 同一套规则，但把**被剔除的根与原因**一起带出来（ICR-0006）。
    ///
    /// 刻意让 `resolve` 变成这里的一层薄壳：如果"实际交给 watcher 的根"与"界面报给用户的
    /// 剔除清单"分成两份实现，两份迟早会漂——那时界面报的就是猜测而不是实况。
    public func resolveScope(
        explicit: [String], agents: [AgentInstance], now: Date
    ) -> MonitoringScope {
        var kept: [(path: String, isExplicit: Bool)] = []
        var dropped: [MonitoringScope.Dropped] = []
        for raw in explicit {
            // 先 trim 再 normalize：`normalized("   ")` 会原样返回三个空格，
            // 于是**一个名字是空白的目录被当成有效监控根**交给 watcher
            // ——与 `DataLocation` 刚修过的 `AIOBSERVATORY_DATA_DIR=" "` 是同一族缺陷
            // （只判 isEmpty 挡不住"只有空白"的配置）。由 `MonitoringScopeTests` 抓到。
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let path = Self.normalized(trimmed)
            guard !path.isEmpty else {
                dropped.append(.init(path: raw, reason: .emptyPath))
                continue
            }
            if Self.isProtected(path) {
                ObservatoryLog.files.warning("explicit monitoring root \(path, privacy: .public) is protected; skipped")
                dropped.append(.init(path: path, reason: .protectedRoot))
                continue
            }
            // 忽略规则也要查**显式**配置的根（#45）：这一段之前只存在于下面"从 Agent cwd 推导"那一支，
            // 于是用户在设置里亲手加的 `…/node_modules`、`…/build` 既没被剔出 kept、
            // 也没进剔除清单 ⇒ 屏上把它们算成"正在监控"的根，而文件页对它们一条事件都不会有
            // （watcher 侧的 `ignoredPatterns` 会把这些路径上的事件丢掉）。
            // 而显式根恰恰是最该查的那一侧：推导根来自 Agent 的 cwd，命中忽略规则是意外；
            // 显式根是用户自己写的，写错才常见，也更需要一个点名式的解释。
            if !ignoredPathPatterns.isEmpty, PatternMatcher.matchesAny(patterns: ignoredPathPatterns, path: path) {
                // 与推导支同一出口：报出**具体是哪条规则**命中的，只说"被忽略规则排除"用户无从知道配错了哪一条。
                let rule = ignoredPathPatterns.first {
                    PatternMatcher.matchesAny(patterns: [$0], path: path)
                }
                dropped.append(.init(path: path, reason: .matchedIgnoredPattern, matchedRule: rule))
                continue
            }
            if !kept.contains(where: { $0.path == path }) { kept.append((path, true)) }
        }

        var derived: [String] = []
        for agent in agents {
            guard let rawDirectory = agent.workingDirectory else { continue }
            let workingDirectory = rawDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !workingDirectory.isEmpty else { continue }
            let candidate = Self.normalized(projectRootResolver(workingDirectory) ?? workingDirectory)
            guard !candidate.isEmpty, !derived.contains(candidate) else { continue }
            if Self.isProtected(candidate) {
                ObservatoryLog.files.warning("derived monitoring root \(candidate, privacy: .public) resolves to a protected location; skipped")
                dropped.append(.init(path: candidate, reason: .protectedRoot))
                continue
            }
            if !ignoredPathPatterns.isEmpty, PatternMatcher.matchesAny(patterns: ignoredPathPatterns, path: candidate) {
                // 报出**具体是哪条规则**命中的：只说"被忽略规则排除"用户无从知道自己配错了哪一条。
                let rule = ignoredPathPatterns.first {
                    PatternMatcher.matchesAny(patterns: [$0], path: candidate)
                }
                dropped.append(.init(path: candidate, reason: .matchedIgnoredPattern, matchedRule: rule))
                continue
            }
            derived.append(candidate)
        }

        for candidate in derived.sorted() {
            if kept.contains(where: { Self.isInside(candidate, within: $0.path) }) { continue }
            // 新祖先覆盖旧的推导根（显式配置由用户决定，不被覆盖）。
            let shadowed = kept.filter { !$0.isExplicit && Self.isInside($0.path, within: candidate) }
            for entry in shadowed {
                dropped.append(.init(path: entry.path, reason: .shadowedByShallowerRoot))
            }
            kept.removeAll { !$0.isExplicit && Self.isInside($0.path, within: candidate) }
            if !kept.contains(where: { $0.path == candidate }) { kept.append((candidate, false)) }
        }
        return MonitoringScope(keptRoots: kept.map(\.path).sorted(), dropped: dropped, resolvedAt: now)
    }

    // MARK: - 路径工具

    private static func normalized(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        guard standardized.count > 1, standardized != "." else { return standardized }
        return standardized.hasSuffix("/") ? String(standardized.dropLast()) : standardized
    }

    private static func isInside(_ path: String, within root: String) -> Bool {
        guard !root.isEmpty, !path.isEmpty else { return false }
        return path == root || path.hasPrefix(root + "/")
    }
}

