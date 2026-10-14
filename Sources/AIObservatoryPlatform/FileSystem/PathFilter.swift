//
//  PathFilter.swift
//  AIObservatoryPlatform — FileSystem 子模块
//
//  Owner: WS-Files
//  ─────────────────────────────────────────────────────────
//  基于 Core 的 `PatternMatcher` 实现路径忽略规则。
//  默认忽略 `.build/` `node_modules/` `DerivedData/` `*.tmp` `.git/objects`，
//  并抑制观测器自身数据库目录（避免自激）。
//
//  性能：FSEvents 每秒可抛几十条路径，`shouldIgnore(_:)` 是热路径。
//  规则在 `init` 里一次性预编译成三类（目录名 / 字面量分量序列 / 通配符），
//  热路径按「数据库前缀 → 分量集合查找 → 字面量窗口 → 通配符（带必要条件早退）」
//  逐级判定，普通源码路径不会触发任何一次通配符回溯匹配。
//

import Foundation
import AIObservatoryCore

/// 路径忽略过滤器：判断某个文件系统事件路径是否应被丢弃。
///
/// 语义（与历史实现保持一致）：一条路径在下列任一情况下被忽略——
/// 1. 位于观测器自身数据库目录内（`databasePaths` 前缀命中）——避免写库自激；
/// 2. 规则的归一化形式是**单个无通配符分量**（如 `.build`、`node_modules`）且路径有任一分量等于它；
/// 3. 规则的归一化形式是**多个无通配符分量序列**（如 `.git/objects`）且路径中存在这样一段连续分量；
/// 4. 含 `*` / `?` 的规则命中：完整路径、任一「后缀子路径」（含 `规则/*` 形式，即命中目录内部更深层级）、
///    或任一单独路径分量。
///
/// 注意 `PatternMatcher` 的 `*` 可以跨越 `/`，因此规则命中不局限于单层目录。
public struct PathFilter: Sendable {

    /// 默认忽略的 glob 规则。
    public static let defaultIgnoredPatterns: [String] = [
        ".build/",
        "node_modules/",
        "DerivedData/",
        "*.tmp",
        ".git/objects"
    ]

    /// 观测器自身数据库目录（避免自激），默认指向 App 的 Application Support 子目录。
    ///
    /// 该计算属性会读盘（`FileManager.url(for:)`），仅供默认值使用；
    /// 测试与生产装配都应显式注入 `databasePaths:`，避免依赖真实家目录。
    public static var defaultDatabasePaths: [String] {
        let tilde = NSString(string: "~/Library/Application Support/com.aix.aiobservatory").expandingTildeInPath
        var result = [tilde]
        if let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: false
        ).path {
            let alt = (base as NSString).appendingPathComponent("com.aix.aiobservatory")
            if !result.contains(alt) { result.append(alt) }
        }
        return result
    }

    /// 调用方追加的忽略规则（不含默认规则）。
    public let additionalPatterns: [String]

    /// 自身数据库目录（绝对路径）：前缀命中即忽略。
    public let databasePaths: [String]

    /// 默认规则与追加规则合并后的完整忽略模式列表。
    public var ignoredPatterns: [String] { Self.defaultIgnoredPatterns + additionalPatterns }

    // MARK: - 预编译结果（init 之后不可变）

    /// 展开后的数据库路径前缀（去掉尾部 `/`）。
    private let databasePrefixes: [String]
    /// 第 2 类规则：任一分量等于该名即忽略。
    private let directoryNames: Set<String>
    /// 第 3 类规则：连续分量序列（已按 `/` 切分、无通配符）。
    private let literalSegmentRules: [[String]]
    /// 第 4 类规则：含通配符的模式 + 早退用的必要条件。
    private let wildcardRules: [WildcardRule]

    /// 一条通配符规则的预编译形式。
    private struct WildcardRule: Sendable {
        /// 归一化（去掉首尾 `/`）后的模式，交给 `PatternMatcher` 做精确判定。
        let pattern: String
        /// 模式首个通配符之前的字面量、截断到第一个 `/`：命中时**必须**是某个分量的前缀。
        let headLiteral: String
        /// 模式最后一个通配符之后的字面量、取最后一个 `/` 之后的部分：
        /// 命中时**必须**是某个分量的后缀。
        let tailLiteral: String
        /// 模式不含字面 `/` 时才可能命中「单个分量」（被切开的每一段都不含 `/`）。
        let canMatchSingleComponent: Bool
    }

    /// 创建过滤器。
    /// - Parameters:
    ///   - additionalPatterns: 调用方追加的忽略规则（如引擎传入的数据库路径）。
    ///     默认规则会自动包含，**不要**在这里重复传入 `defaultIgnoredPatterns`。
    ///   - databasePaths: 自身数据库目录，默认使用 `defaultDatabasePaths`（会读盘，测试请显式注入）。
    public init(additionalPatterns: [String] = [], databasePaths: [String] = PathFilter.defaultDatabasePaths) {
        self.additionalPatterns = additionalPatterns
        self.databasePaths = databasePaths
        self.databasePrefixes = databasePaths
            .map { NSString(string: $0).expandingTildeInPath }
            .map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
            .filter { $0.isEmpty == false }

        var directoryNames: Set<String> = []
        var literalRules: [[String]] = []
        var wildcardRules: [WildcardRule] = []

        for raw in Self.defaultIgnoredPatterns + additionalPatterns {
            let pattern = Self.normalize(raw)
            guard !pattern.isEmpty else { continue }
            if Self.containsWildcard(pattern) {
                wildcardRules.append(Self.compileWildcard(pattern))
            } else {
                let segments = pattern.split(separator: "/").map(String.init)
                guard !segments.isEmpty else { continue }
                if segments.count == 1 {
                    directoryNames.insert(segments[0])
                } else {
                    literalRules.append(segments)
                }
            }
        }

        self.directoryNames = directoryNames
        self.literalSegmentRules = literalRules
        self.wildcardRules = wildcardRules
    }

    /// 在当前过滤器之上追加调用方规则，返回新过滤器。
    ///
    /// 默认规则与 `databasePaths` 原样保留、不会重复累积（`PathFilter.init` 每次都自动拼默认值，
    /// 因此这里只把「已有的追加规则 + 新规则」交给 init）。
    /// - Parameter patterns: 新增的忽略规则。
    /// - Returns: 合并后的过滤器。
    public func appending(_ patterns: [String]) -> PathFilter {
        PathFilter(additionalPatterns: additionalPatterns + patterns, databasePaths: databasePaths)
    }

    /// 判断给定路径是否应被忽略。
    /// - Parameter path: 事件路径（可为 `~` 开头的未展开形式）。
    /// - Returns: `true` 表示应忽略（命中规则或自身数据库目录）。
    public func shouldIgnore(_ path: String) -> Bool {
        // 1) 自身数据库目录前缀：最廉价、也是自激抑制的关键，最先做。
        let expanded = NSString(string: path).expandingTildeInPath
        for prefix in databasePrefixes where !prefix.isEmpty {
            if expanded == prefix || expanded.hasPrefix(prefix + "/") { return true }
        }

        // 分量只切一次，供后续所有判定复用。
        let components = path.split(separator: "/").map(String.init)

        // 2) 目录名型规则：O(分量数) 的集合查找，覆盖默认规则里的 `.build` / `node_modules` / `DerivedData`。
        for component in components where directoryNames.contains(component) { return true }

        // 3) 字面量分量序列规则：路径中出现一段连续分量等于规则即忽略（覆盖 `.git/objects`）。
        for segments in literalSegmentRules where hasContiguousSegments(segments, in: components) { return true }

        // 4) 通配符规则：先用「头/尾字面量必要条件」早退，命中嫌疑时才做完整的模式匹配。
        for rule in wildcardRules {
            if !isCandidate(rule, components: components) { continue }
            // 与历史实现一致的三段判定：完整路径 / 任一后缀子路径（含 `规则/*`）/ 任一分量。
            if PatternMatcher.matches(pattern: rule.pattern, path: path) { return true }
            if rule.canMatchSingleComponent {
                for component in components where PatternMatcher.matches(pattern: rule.pattern, path: component) { return true }
            }
            for index in 0..<components.count {
                let suffix = components[index...].joined(separator: "/")
                if PatternMatcher.matches(pattern: rule.pattern, path: suffix) { return true }
                if PatternMatcher.matches(pattern: rule.pattern + "/*", path: suffix) { return true }
            }
        }

        return false
    }

    // MARK: - 编译与判定辅助

    /// 归一化：去掉首尾 `/`（与历史实现一致），使 `.build/` 与 `.build` 等价。
    private static func normalize(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// 是否含 `PatternMatcher` 的通配符。
    private static func containsWildcard(_ pattern: String) -> Bool {
        pattern.contains("*") || pattern.contains("?")
    }

    /// 编译通配符规则：抽取头/尾字面量与「能否匹配单个分量」。
    private static func compileWildcard(_ pattern: String) -> WildcardRule {
        // 头部字面量：第一个通配符之前，截断到第一个 `/`（`/` 之前的部分必然落在同一个分量里）。
        var head = ""
        for ch in pattern {
            if ch == "*" || ch == "?" { break }
            if ch == "/" { break }
            head.append(ch)
        }
        // 尾部字面量：最后一个通配符之后，取最后一个 `/` 之后的部分。
        var tail = ""
        if let lastWildcard = pattern.lastIndex(where: { $0 == "*" || $0 == "?" }) {
            tail = String(pattern[pattern.index(after: lastWildcard)...])
        } else {
            tail = pattern
        }
        if let slash = tail.lastIndex(of: "/") {
            tail = String(tail[tail.index(after: slash)...])
        }
        return WildcardRule(
            pattern: pattern,
            headLiteral: head,
            tailLiteral: tail,
            canMatchSingleComponent: pattern.contains("/") == false
        )
    }

    /// 早退判据：若某条规则要命中「完整路径 / 后缀子路径 / 单个分量」中的任何一种，
    /// 被匹配的字符串总是从某个分量的开头开始、到最后一个分量的末尾结束，
    /// 因此模式的头部字面量必然是某分量的前缀、尾部字面量必然是某分量的后缀。
    /// 两个必要条件任一不成立即可安全跳过该规则（不改变命中结果，只减少匹配次数）。
    private func isCandidate(_ rule: WildcardRule, components: [String]) -> Bool {
        if !rule.headLiteral.isEmpty, !components.contains(where: { $0.hasPrefix(rule.headLiteral) }) {
            return false
        }
        if !rule.tailLiteral.isEmpty, !components.contains(where: { $0.hasSuffix(rule.tailLiteral) }) {
            return false
        }
        return true
    }

    /// `segments` 是否作为连续子序列出现在 `components` 中（对应历史实现的「后缀子路径命中规则前缀」）。
    private func hasContiguousSegments(_ segments: [String], in components: [String]) -> Bool {
        guard !segments.isEmpty, components.count >= segments.count else { return false }
        for start in 0...(components.count - segments.count)
        where components[start..<start + segments.count].elementsEqual(segments) {
            return true
        }
        return false
    }
}
