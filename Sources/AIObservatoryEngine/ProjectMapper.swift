//
//  ProjectMapper.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine
//  Sub-owner: D
//
//  路径 → 项目根 判定 + ProjectActivity 聚合。
//  无状态 `struct`（纯函数），resolver 通过 init 注入，便于测试替换。
//
//  ⚠️ 默认 resolver `PathHeuristics.enclosingProjectRoot(for:)` 会做文件存在性探测（磁盘 IO）。
//  因此它**只在调用 `projectPath(for:)` / `aggregate(...)` 时**执行，绝不在 init 中执行；
//  调用方应避免在主线程调用（AGENTS.md §5：禁止主线程 IO）。
//
//  ⚠️ 归属守卫（与 `aggregate` 文档里那份语义清单同源，改实现必须同步改注释）：
//  候选项目根——无论是记录自带的 `projectPath`，还是注入 `resolver` 的返回值——
//  都要先过 `ProjectMapper.usableRoot(for:)`（内部复用 `MonitoringRootResolver.isUsableAttributionRoot`）。
//  判不过就返回 nil / 跳过该条记录，**绝不退化成用 `/` 或家目录当项目根**。
//  理由：`resolver` 是注入的闭包，默认那个安全，注入的那个什么都能返回；
//  一条 `path = '/'` 的「项目」在界面上与真项目无异，对审计工具是伪证而不是丢数据。
//  该判定会读当前用户家目录（与 `MonitoringRootResolver` 同一把尺子），同样只发生在
//  `projectPath(for:)` / `aggregate(...)` 里，不在 init 中。
//

import Foundation
import AIObservatoryCore
import AIObservatoryInsights

/// 路径 → 项目根，并把原始记录聚合为 `ProjectActivity`。纯函数，不持状态。
public struct ProjectMapper: Sendable {

    // MARK: - Policy

    /// 热文件榜单截断策略。
    public struct HotFilePolicy: Sendable, Hashable {
        /// 输出的热文件条数上限（<= 0 时输出空数组）。
        public var limit: Int

        /// 构造截断策略，默认保留 20 条。
        public init(limit: Int = 20) {
            self.limit = limit
        }

        /// 标准策略（20 条）。
        public static let standard = HotFilePolicy()
    }

    // MARK: - Stored configuration

    /// 项目根判定闭包：返回 nil 表示无法判定（宁缺毋滥，不猜）。
    public var resolver: @Sendable (_ path: String) -> String?

    /// 忽略路径的通配符集合（`PatternMatcher` 语法），命中即不参与映射与聚合。
    public var ignoredPathPatterns: [String]

    /// 热文件榜单策略。
    public var hotFilePolicy: HotFilePolicy

    /// 注入 resolver 构造。**不执行任何 IO**（IO 只发生在 `projectPath(for:)` / `aggregate(...)`）。
    /// - Parameters:
    ///   - resolver: 路径 → 项目根；默认走 `PathHeuristics.enclosingProjectRoot`。
    ///   - ignoredPathPatterns: 忽略路径模式，默认空（不忽略任何路径）。
    ///   - hotFilePolicy: 热文件截断策略，默认 20 条。
    /// 原子写残留归并到真身路径（#48）。
    ///
    /// 只认两种确定形态，其余一律原样返回——**认不准就并是错的**：
    ///  · `<真身>.<pid>.tmp`（末段 `tmp`，倒数第二段是数字）
    ///  · `<真身>.tmp.<pid>.<纳秒>`（倒数第三段 `tmp`，后两段都是数字）
    /// 数字段要求 ≥2 位：`report.7.tmp` 这种名字更像人起的，不并。
    public static func realPath(ofAtomicWrite path: String) -> String {
        let parts = path.split(separator: ".", omittingEmptySubsequences: false)
        func hasDigits(_ text: Substring) -> Bool {
            text.count >= 2 && text.allSatisfy(\.isNumber)
        }
        if parts.count >= 3, parts[parts.count - 1] == "tmp",
           hasDigits(parts[parts.count - 2]) {
            return parts[0..<parts.count - 2].joined(separator: ".")
        }
        if parts.count >= 4, parts[parts.count - 3] == "tmp",
           hasDigits(parts[parts.count - 2]), hasDigits(parts[parts.count - 1]) {
            return parts[0..<parts.count - 3].joined(separator: ".")
        }
        return path
    }

    public init(resolver: @escaping @Sendable (_ path: String) -> String? = { PathHeuristics.enclosingProjectRoot(for: $0) },
                ignoredPathPatterns: [String] = [],
                hotFilePolicy: HotFilePolicy = HotFilePolicy()) {
        self.resolver = resolver
        self.ignoredPathPatterns = ignoredPathPatterns
        self.hotFilePolicy = hotFilePolicy
    }

    // MARK: - Path mapping

    /// 该路径是否命中忽略规则（空模式集合恒为 false）。
    public func isIgnored(_ path: String) -> Bool {
        ProjectMapper.isIgnored(path, patterns: ignoredPathPatterns)
    }

    /// 纯静态的忽略判定，供聚合内部复用。
    static func isIgnored(_ path: String, patterns: [String]) -> Bool {
        guard !path.isEmpty, !patterns.isEmpty else { return false }
        return PatternMatcher.matchesAny(patterns: patterns, path: path)
    }

    // MARK: - Attribution guard

    /// 候选项目根**能不能作为一个归属结论**——本文件唯一的判定入口。
    ///
    /// 判定本身不在这里重写，直接复用同模块的共用判据
    /// ``MonitoringRootResolver/isUsableAttributionRoot(_:)``
    /// （非空 + 不是受保护根（`/`、当前用户家目录、家目录的直接父目录）+ 至少两个路径分量），
    /// 与检出侧 `ObservatoryEngine.attributedAgent(forPath:)` 用的是同一把尺子——两侧口径必须一致。
    ///
    /// 为什么项目地图也要这道守卫：`resolver` 是注入的闭包。默认那个
    /// `PathHeuristics.enclosingProjectRoot` 自身不会返回 `/` 或家目录，但第三方 / 测试注入的那个
    /// 什么都能返回；而 `aggregate` 的分组键此前对记录自带的 `projectPath` 只判「非空 + 未命中忽略」。
    /// 于是一条 `path = '/'` 的「项目」会出现在 `projects` 表里，把它 cwd 之下（也就是全盘）的活动
    /// 吸进一个分组，界面上长得跟真项目一样。**对审计工具来说这比丢数据更糟**——它给的是一个看起来
    /// 合理的答案，而不是「不知道」。所以判不过一律 nil（= 跳过该条记录）：宁可少一个项目。
    ///
    /// - Parameter candidate: 候选项目根，来源可以是记录自带的 `projectPath`，也可以是 `resolver` 的返回值。
    /// - Returns: 通过判定时**原样**返回候选（不改写、不规范化，保证分组键与 `ProjectActivity.id` 稳定）；
    ///   否则 nil。
    public static func usableRoot(for candidate: String?) -> String? {
        guard let candidate, !candidate.isEmpty else { return nil }
        return MonitoringRootResolver.isUsableAttributionRoot(candidate) ? candidate : nil
    }

    /// 求某条文件路径所属的项目根；
    /// nil / 空串 / 命中忽略规则 / 无法判定 / 判定结果不足以作为项目根（见 ``usableRoot(for:)``）→ nil。
    public func projectPath(for path: String?) -> String? {
        guard let path, !path.isEmpty else { return nil }
        guard !isIgnored(path) else { return nil }
        return ProjectMapper.usableRoot(for: resolver(path))
    }

    /// 项目显示名：项目根的最后一个路径分量（忽略末尾斜杠）。
    public func name(forProjectPath path: String) -> String {
        var trimmed = Substring(path)
        while trimmed.count > 1, trimmed.last == "/" {
            trimmed = trimmed.dropLast()
        }
        let name = (String(trimmed) as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    // MARK: - Aggregation

    /// 把原始记录聚合为项目活动地图。
    ///
    /// 语义（严格对齐 INTERFACE.md §6D）：
    /// - 项目键优先取记录上已填好的 `projectPath`；缺失时对文件路径走 resolver，
    ///   对目录（命令的 workingDirectory）以「合成子路径」再走 resolver（见 `root(forDirectory:)`）。
    /// - **项目根判定为 nil 的输入直接跳过**，不进入任何分组。
    /// - **候选项目根必须过可用性守卫**（``usableRoot(for:)``，内部复用
    ///   ``MonitoringRootResolver/isUsableAttributionRoot(_:)``）才能当分组键：
    ///   记录自带的 `projectPath`、resolver 的返回值、会话的 `projectPath`，三条来源同一个口径、
    ///   同一处判定；判不过 → 跳过该条记录，**绝不退化成用 `/` 或家目录凑一个项目**。
    ///   为什么：注入的 resolver 什么都能返回，而一条 `path = '/'` 的「项目」会把全盘活动吸进一个分组、
    ///   在界面上伪装成真实项目——本产品是审计工具，宁可少一个项目，也不要一个吞掉全盘世界的伪项目。
    ///   守卫是忽略规则**之外**额外一道，不替代 `ignoredPathPatterns`。
    /// - 计数一对一：每条输入最多让它所在分组的相关计数 +1，绝不重复计数。
    /// - `codeGrowthLines` / `codeShrinkLines` 来自文件变更的 `linesAdded` / `linesRemoved`（负值按 0 计）。
    /// - `agentContributions`：按 AgentKind 的**活动记录条数**占比（文件变更 / 命令 / 事件 / 会话 / 风险
    ///   每条各计 1 次），`relativeShare = count/total`，按条数降序；`total == 0` → 空数组。
    /// - `hotFiles`：仅来自文件变更，按路径统计 changeCount/lines/lastTouchedAt，
    ///   changeCount 降序，截断到 `hotFilePolicy.limit`。
    /// - `firstSeenAt` / `lastSeenAt`：分组内所有时间戳的 min/max；**无任何时间戳的分组不产出**。
    /// - `id == path`（`ProjectActivity.identity(path:)`）。
    /// - 空输入 → 空数组；拿不到的数据一律 0，不伪造。
    public func aggregate(changes: [FileChange],
                          commands: [CommandRecord],
                          events: [TimelineEvent],
                          sessions: [AgentSession],
                          risks: [RiskEvent]) -> [ProjectActivity] {
        let cache = ResolutionCache(resolver: resolver, ignoredPathPatterns: ignoredPathPatterns)
        // 五路输入一律经 `ResolutionCache` 取项目根——那里是「候选根 → 可用根」的唯一判定出口，
        // 分支里不再各自写一套采纳逻辑（历史上会话分支正是这样绕过了守卫，才出现 `path = '/'` 的项目）。
        var buckets: [String: Bucket] = [:]

        // —文件变更：fileChangeCount / 行数增减 / 热文件—
        for change in changes {
            guard let root = cache.root(forFilePath: change.path, stated: change.projectPath) else { continue }
            var target = buckets[root] ?? Bucket(path: root)
            target.fileChangeCount += 1
            target.codeGrowthLines += max(0, change.linesAdded)
            target.codeShrinkLines += max(0, change.linesRemoved)
            target.note(kind: change.agentKind)
            target.note(timestamp: change.timestamp)
            // 原子写（写临时文件再 rename）的残留会作为独立路径进热区，
            // 于是同一个文件在榜上占两格——用户读到"改过两次"，实际是一次改 + 一条垃圾。
            // 只并**热区那一格的键**；`fileChangeCount` 与行数增减仍按真实发生过的事件计，
            // 因为那些计数问的是"发生了多少"，不是"有几个文件"。
            let heatPath = ProjectMapper.realPath(ofAtomicWrite: change.path)
            target.noteHeat(path: heatPath,
                            linesAdded: change.linesAdded,
                            linesRemoved: change.linesRemoved,
                            timestamp: change.timestamp)
            var scored = change
            scored.path = heatPath
            target.scoredChanges.append(scored)
            buckets[root] = target
        }

        // —命令：commandCount—
        for command in commands {
            guard let root = cache.root(forDirectory: command.workingDirectory, stated: command.projectPath) else { continue }
            var target = buckets[root] ?? Bucket(path: root)
            target.commandCount += 1
            target.note(kind: command.agentKind)
            target.note(timestamp: command.startedAt)
            if let endedAt = command.endedAt { target.note(timestamp: endedAt) }
            buckets[root] = target
        }

        // —时间线事件：只计入归属与时间戳，不重复计数文件/命令—
        for event in events {
            if let path = event.filePath, cache.isIgnored(path) { continue }
            guard let root = cache.root(forFilePath: event.filePath, stated: event.projectPath) else { continue }
            var target = buckets[root] ?? Bucket(path: root)
            target.note(kind: event.agentKind)
            target.note(timestamp: event.timestamp)
            buckets[root] = target
        }

        // —会话：projectPath 已是目录级归属，原样使用、不再回溯，但仍要过同一道可用性守卫—
        for session in sessions {
            guard let root = cache.root(forStatedDirectory: session.projectPath) else { continue }
            var target = buckets[root] ?? Bucket(path: root)
            target.sessionCount += 1
            target.note(kind: session.kind)
            target.note(timestamp: session.startedAt)
            if let endedAt = session.endedAt { target.note(timestamp: endedAt) }
            buckets[root] = target
        }

        // —风险事件：用其携带的路径归属；无可判定路径则跳过，不猜。
        //   归属仍走 `root(forFilePath:stated: nil)`，因此与其余四路共用同一道可用性守卫。—
        for risk in risks {
            let carried = risk.filePaths.first { !$0.isEmpty && !cache.isIgnored($0) }
            guard let root = cache.root(forFilePath: carried, stated: nil) else { continue }
            var target = buckets[root] ?? Bucket(path: root)
            target.riskEventCount += 1
            target.note(kind: risk.agentKind)
            target.note(timestamp: risk.timestamp)
            buckets[root] = target
        }

        return buckets.values
            .filter(\.hasTimestamp)
            .map { bucket in
                bucket.makeProjectActivity(using: self, referenceDate: bucket.lastSeenAt ?? Date(timeIntervalSince1970: 0))
            }
            .sorted { lhs, rhs in
                if lhs.lastSeenAt != rhs.lastSeenAt { return lhs.lastSeenAt > rhs.lastSeenAt }
                return lhs.id < rhs.id
            }
    }
}

// MARK: - Internal accumulation

extension ProjectMapper {

    /// 单个项目分组的累加器（internal，仅 `aggregate` 使用）。
    struct Bucket {
        /// 一条热文件的累加结果。
        struct Heat {
            var changeCount: Int = 0
            var linesAdded: Int = 0
            var linesRemoved: Int = 0
            var lastTouchedAt: Date?
        }

        var path: String
        var fileChangeCount: Int = 0
        var commandCount: Int = 0
        var sessionCount: Int = 0
        var riskEventCount: Int = 0
        var codeGrowthLines: Int = 0
        var codeShrinkLines: Int = 0
        var kindCounts: [AgentKind: Int] = [:]
        var heat: [String: Heat] = [:]
        /// 原始文件变更，供 `HotFileScorer` 做多因子热度评分。
        var scoredChanges: [FileChange] = []
        var firstSeenAt: Date?
        var lastSeenAt: Date?

        /// 该分组是否观测到至少一个有效时间戳。
        var hasTimestamp: Bool { firstSeenAt != nil && lastSeenAt != nil }

        /// 记录一个时间戳（epoch 及以前视为无效占位）。
        mutating func note(timestamp: Date) {
            guard timestamp.timeIntervalSince1970 > 0 else { return }
            if let current = firstSeenAt {
                if timestamp < current { firstSeenAt = timestamp }
            } else {
                firstSeenAt = timestamp
            }
            if let current = lastSeenAt {
                if timestamp > current { lastSeenAt = timestamp }
            } else {
                lastSeenAt = timestamp
            }
        }

        /// 记录一次「该 AgentKind 的一次活动」，用于贡献占比。
        mutating func note(kind: AgentKind) {
            kindCounts[kind, default: 0] += 1
        }

        /// 记录一次热文件命中。
        mutating func noteHeat(path: String, linesAdded: Int, linesRemoved: Int, timestamp: Date) {
            var entry = heat[path] ?? Heat()
            entry.changeCount += 1
            entry.linesAdded += max(0, linesAdded)
            entry.linesRemoved += max(0, linesRemoved)
            if timestamp.timeIntervalSince1970 > 0,
               entry.lastTouchedAt.map({ timestamp > $0 }) ?? true {
                entry.lastTouchedAt = timestamp
            }
            heat[path] = entry
        }

        /// 产出最终的 `ProjectActivity`（排序与截断全部确定化）。
        /// - Parameter referenceDate: 热度评分的「现在」。用数据集内最新时间戳而不是墙钟，
        ///   保证同一批数据任何时候聚合结果都一样。
        func makeProjectActivity(using mapper: ProjectMapper, referenceDate: Date) -> ProjectActivity {
            let total = kindCounts.values.reduce(0, +)
            let contributions: [AgentContribution]
            if total <= 0 {
                contributions = []
            } else {
                contributions = kindCounts
                    .map { AgentContribution(kind: $0.key,
                                             relativeShare: Double($0.value) / Double(total),
                                             eventCount: $0.value) }
                    .sorted { lhs, rhs in
                        if lhs.eventCount != rhs.eventCount { return lhs.eventCount > rhs.eventCount }
                        return lhs.kind.rawValue < rhs.kind.rawValue
                    }
            }

            // 排序与分数交给 Insights 的多因子评分（反复度衰减 + 新近度 + 跨 Agent 广度）；
            // 原始计数仍从本地字典取，保证 UI 看到的数字与事件流严格一致。
            let scores = FileHotnessScorer.score(changes: scoredChanges, referenceDate: referenceDate)
            let heats: [FileHeat] = scores.compactMap { scored -> FileHeat? in
                guard let entry = heat[scored.path] else { return nil }
                return FileHeat(path: scored.path,
                                changeCount: entry.changeCount,
                                linesAdded: entry.linesAdded,
                                linesRemoved: entry.linesRemoved,
                                lastTouchedAt: entry.lastTouchedAt ?? Date(timeIntervalSince1970: 0),
                                score: scored.score)
            }

            let limit = max(0, mapper.hotFilePolicy.limit)
            return ProjectActivity(
                id: ProjectActivity.identity(path: path),
                name: mapper.name(forProjectPath: path),
                path: path,
                fileChangeCount: fileChangeCount,
                commandCount: commandCount,
                sessionCount: sessionCount,
                riskEventCount: riskEventCount,
                codeGrowthLines: codeGrowthLines,
                codeShrinkLines: codeShrinkLines,
                agentContributions: contributions,
                hotFiles: Array(heats.prefix(limit)),
                firstSeenAt: firstSeenAt ?? Date(timeIntervalSince1970: 0),
                lastSeenAt: lastSeenAt ?? Date(timeIntervalSince1970: 0)
            )
        }
    }

    /// `aggregate` 期间的 resolver 记忆化，避免对同一路径重复做磁盘 IO。
    /// 仅在单个 `aggregate` 调用的栈内使用，不跨并发域，因此无需 `Sendable`。
    final class ResolutionCache {
        private let resolver: @Sendable (String) -> String?
        private let patterns: [String]
        private var memo: [String: String?] = [:]
        /// 候选项目根的可用性判定结果（同上，只在本次聚合的栈内）。
        /// 判定本身要读当前用户家目录，同一条 `projectPath` 会被成百上千条记录携带，不该重复问。
        private var verdicts: [String: Bool] = [:]

        init(resolver: @escaping @Sendable (String) -> String?, ignoredPathPatterns patterns: [String]) {
            self.resolver = resolver
            self.patterns = patterns
        }

        /// 是否命中忽略规则。
        func isIgnored(_ path: String) -> Bool {
            ProjectMapper.isIgnored(path, patterns: patterns)
        }

        /// 文件路径归属：优先用记录上已填好的 `stated`；否则解析路径。
        /// 两条路都以 ``ProjectMapper/usableRoot(for:)`` 收尾，不开第二个口径。
        func root(forFilePath path: String?, stated: String?) -> String? {
            if let stated, !stated.isEmpty { return verifiedRoot(stated) }
            guard let path, !path.isEmpty, !isIgnored(path) else { return nil }
            return resolve(path)
        }

        /// 目录归属：优先用 `stated`；否则合成一个子路径再交给 resolver
        /// （`enclosingProjectRoot` 从**父目录**开始探测，直接传目录会漏判该目录自身）。
        /// 同样，两条路都要过可用性守卫。
        func root(forDirectory directory: String?, stated: String?) -> String? {
            if let stated, !stated.isEmpty { return verifiedRoot(stated) }
            guard let directory, !directory.isEmpty, !isIgnored(directory) else { return nil }
            let marker = directory.hasSuffix("/") ? directory + "_probe" : directory + "/_probe"
            return resolve(marker)
        }

        /// 直接采纳记录自带的**目录级**归属（会话的 `projectPath`：本来就是目录，不再回溯）。
        /// 口径 = 非空 + 未命中忽略 + 可作为归属根；与 `root(forFilePath:stated:)` 的 `stated` 一支同一处判定，
        /// 免得会话分支变成第二套「只判非空」的采纳逻辑。
        func root(forStatedDirectory directory: String?) -> String? {
            guard let directory, !directory.isEmpty, !isIgnored(directory) else { return nil }
            return verifiedRoot(directory)
        }

        private func resolve(_ path: String) -> String? {
            if let hit = memo[path] { return hit }
            let value = verifiedRoot(resolver(path))
            memo[path] = value
            return value
        }

        /// 候选项目根 → 可作为归属结论的项目根；判不过 → nil（调用方据此跳过该条记录）。
        private func verifiedRoot(_ candidate: String?) -> String? {
            guard let candidate, !candidate.isEmpty else { return nil }
            if let known = verdicts[candidate] { return known ? candidate : nil }
            let usable = ProjectMapper.usableRoot(for: candidate)
            verdicts[candidate] = (usable != nil)
            return usable
        }
    }
}
