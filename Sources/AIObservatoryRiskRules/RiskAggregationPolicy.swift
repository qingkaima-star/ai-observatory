//
//  RiskAggregationPolicy.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk —— E 聚合层
//
//  把 4 个规则族产出的 `RiskFinding` 折叠、抑制、排序、截断成一份可呈现的清单。
//
//  设计约束：
//  1. **纯函数**：不读墙钟、不做 IO、不使用随机数、不使用 `hashValue`（Swift 的哈希
//     种子是进程启动时随机化的，跨进程不稳定，因此一律显式比较字段）。
//  2. **顺序无关**：同一批 findings 以任意输入顺序喂给 `apply(_:)`，输出数组逐元素相等。
//     做法是：折叠前先把同组命中按"规范全序"排好，再按该顺序喂给 `RiskFinding.merged(with:)`；
//     抑制判定是对整个集合的 ∃ 谓词（不依赖遍历顺序）；最终再按呈现序整体重排。
//  3. **严重度不降级**：族级地板只抬升、折叠只取更高等级。
//

import Foundation
import AIObservatoryCore

/// 风险命中的聚合策略。
///
/// `apply(_:)` 的完整管线：
/// ① 族级地板抬升 → ② 按 `suppressionKey` 折叠 → ③ 同根因抑制 → ④ 排序 → ⑤ 截断。
public struct RiskAggregationPolicy: Sendable, Hashable {

    /// 是否把 `suppressionKey` 相同的命中折叠为一条（关闭后同一根因会各报一条）。
    public var deduplicateBySuppressionKey: Bool

    /// 输出上限。**截断发生在排序之后**，因此保留的始终是"最需要被看到"的那几条。
    public var maxFindings: Int

    /// 族级严重度地板：某族的全部命中至少报到给定等级。**只升不降**。
    public var floorLevels: [RiskRuleFamily: RiskLevel]

    /// 是否启用同根因抑制（见 `suppresses(_:, containing:)` 的规则说明）。
    public var suppressContainedFindings: Bool

    /// 构造聚合策略。默认取值即 `standard`。
    public init(
        deduplicateBySuppressionKey: Bool = true,
        maxFindings: Int = 24,
        floorLevels: [RiskRuleFamily: RiskLevel] = [:],
        suppressContainedFindings: Bool = true
    ) {
        self.deduplicateBySuppressionKey = deduplicateBySuppressionKey
        self.maxFindings = maxFindings
        self.floorLevels = floorLevels
        self.suppressContainedFindings = suppressContainedFindings
    }

    /// 默认策略：折叠 + 同根因抑制 + 排序后截断 24 条，不设族级地板。
    public static let standard = RiskAggregationPolicy()

    /// 管线第 ③ 步判定"同一根因"允许的最小时间邻近度（秒）。
    /// 两条命中证据的时间差超过 `max(本常量, 二者证据跨度)` 时视为不同根因，**不抑制**。
    fileprivate static let rootCauseWindowSeconds: TimeInterval = 60

    // MARK: - 管线入口

    /// 对一批原始命中执行完整聚合管线。
    ///
    /// 顺序无关性保证：折叠分组以 `suppressionKey` 字典序遍历，组内成员先按
    /// `canonicalPrecedence(_:, _:)`（覆盖 `RiskFinding` 全部字段的严格全序）排序，
    /// 再按该顺序逐步 `merged(with:)`；抑制判定是对集合的 ∃ 谓词；最后整体按
    /// `presentationPrecedence(_:, _:)` 排序。因此输出仅由输入** multiset **决定，
    /// 与输入数组的排列无关。
    /// - Parameter findings: 各规则产出的原始命中（可为空）。
    /// - Returns: 聚合后的命中，按呈现优先级从高到低排列，最多 `maxFindings` 条。
    public func apply(_ findings: [RiskFinding]) -> [RiskFinding] {
        guard !findings.isEmpty else { return [] }

        // ① 族级地板抬升
        var result = liftFloors(findings)

        // ② 按 suppressionKey 折叠（只升不降）
        if deduplicateBySuppressionKey {
            result = Self.foldBySuppressionKey(result)
        }

        // ③ 同根因抑制
        if suppressContainedFindings {
            result = Self.suppressContained(result)
        }

        // ④ 排序：level.rank↓ → family.presentationWeight↓ → timestamp↑ → ruleID↑（→ suppressionKey↑）
        result.sort { Self.presentationPrecedence($0, $1) == .orderedAscending }

        // ⑤ 截断（必须在排序之后）
        let limit = Swift.max(0, maxFindings)
        return result.count > limit ? Array(result.prefix(limit)) : result
    }

    // MARK: - ① 地板

    /// 套用族级地板：低于地板的命中抬到地板等级；抬到 HIGH 及以上时同步要求确认
    /// （与 `AgentRiskRule.makeFinding(from:)` 的"HIGH 及以上自动 requiresConfirmation"语义一致）。
    fileprivate func liftFloors(_ findings: [RiskFinding]) -> [RiskFinding] {
        guard !floorLevels.isEmpty else { return findings }
        return findings.map { finding in
            guard let levelFloor = floorLevels[finding.family] else { return finding }
            guard levelFloor.rank > finding.level.rank else { return finding }   // 只升不降
            var lifted = finding
            lifted.level = levelFloor
            if levelFloor.rank >= RiskLevel.high.rank {
                lifted.requiresConfirmation = true
            }
            return lifted
        }
    }

    // MARK: - ② 折叠

    /// 把 `suppressionKey` 完全相同的命中折叠为一条。
    ///
    /// `RiskFinding.merged(with:)` 不满足交换律（title/category/ruleID 取"更高那条"、
    /// filePaths 合并后截断到前 12 个），因此这里先把组内成员按规范全序排好再折叠：
    /// 这样"折叠序列"只由组内**元素集合**决定，与调用方传入的数组顺序无关。
    /// 排序首键是 `level.rank` 降序，所以折叠结果的等级/标题一定来自组内最高等级者，
    /// 与元素在原始数组中的位置无关。
    fileprivate static func foldBySuppressionKey(_ findings: [RiskFinding]) -> [RiskFinding] {
        var buckets: [String: [RiskFinding]] = [:]
        for finding in findings {
            buckets[finding.suppressionKey, default: []].append(finding)
        }

        var output: [RiskFinding] = []
        output.reserveCapacity(buckets.count)
        // 组间以 suppressionKey 字典序遍历：输出顺序与输入顺序无关（稍后还会整体重排）。
        for key in buckets.keys.sorted() {
            guard let members = buckets[key], !members.isEmpty else { continue }
            if members.count == 1 {
                output.append(members[0])
                continue
            }
            let ordered = members.sorted { Self.canonicalPrecedence($0, $1) == .orderedAscending }
            var folded = ordered[0]
            for member in ordered.dropFirst() {
                folded = folded.merged(with: member)
            }
            output.append(folded)
        }
        return output
    }

    // MARK: - ③ 同根因抑制

    /// 同根因抑制：一次批量删除凭据目录时，A 族会给出一条覆盖 N 个路径的高等级命中，
    /// B 族会对每个路径各给一条低等级命中；本步把被包含的低等级命中去掉，避免刷屏。
    ///
    /// **判定规则（保守，任一不满足即不抑制）**：
    /// 1. 低等级命中的 `filePaths` 非空，且是高等级 `filePaths` 的**真子集**
    ///    （元素个数严格更少；集合相等时两条都保留）；
    /// 2. 二者**等级不同**（低 vs 高），本步只在更高等级面前让步，同等级永不互相抑制；
    /// 3. 存在**关联线索**：`category` 相同，或 `suppressionKey` 冒号前的标签相同
    ///    （例如 `credentials:/Users/x/.aws/credentials` 与 `credentials:/Users/x/.aws/keys/a.pem`）；
    /// 4. **时间邻近**：时间差 ≤ `max(rootCauseWindowSeconds, 二者 evidenceSpan)`，
    ///    防止把相隔很久的两次独立事件误判成同一根因。
    ///
    /// 判定是"对全集合是否存在更高等级包含者"的 ∃ 谓词，与遍历顺序无关；
    /// 不级联（包含者若自己被更高等级抑制，仍继续充当包含者），以保持纯函数语义。
    fileprivate static func suppressContained(_ findings: [RiskFinding]) -> [RiskFinding] {
        guard findings.count > 1 else { return findings }
        let ordered = findings.sorted { Self.canonicalPrecedence($0, $1) == .orderedAscending }
        let pathSets = ordered.map { Set($0.filePaths) }

        var survivors: [RiskFinding] = []
        survivors.reserveCapacity(ordered.count)
        for index in ordered.indices {
            let candidate = ordered[index]
            let candidatePaths = pathSets[index]
            var suppressed = false
            if !candidatePaths.isEmpty {
                for otherIndex in ordered.indices where otherIndex != index {
                    let higher = ordered[otherIndex]
                    guard higher.level.rank > candidate.level.rank else { continue }
                    if Self.suppresses(
                        higher,
                        containing: candidate,
                        higherPaths: pathSets[otherIndex],
                        lowerPaths: candidatePaths
                    ) {
                        suppressed = true
                        break
                    }
                }
            }
            if !suppressed { survivors.append(candidate) }
        }
        return survivors
    }

    /// `higher` 是否同根因包含 `lower`。规则见 `suppressContained(_:)` 的注释。
    fileprivate static func suppresses(
        _ higher: RiskFinding,
        containing lower: RiskFinding,
        higherPaths: Set<String>,
        lowerPaths: Set<String>
    ) -> Bool {
        guard !lowerPaths.isEmpty else { return false }
        guard higherPaths.count > lowerPaths.count else { return false }        // 真子集
        guard lowerPaths.isSubset(of: higherPaths) else { return false }
        guard Self.areRelated(higher, lower) else { return false }

        let distance = abs(higher.timestamp.timeIntervalSince(lower.timestamp))
        let tolerance = Swift.max(
            Self.rootCauseWindowSeconds,
            higher.evidenceSpan ?? 0,
            lower.evidenceSpan ?? 0
        )
        return distance <= tolerance
    }

    /// 关联线索：同 `category`，或 `suppressionKey` 的标签段（首个 `:` 之前）相同。
    fileprivate static func areRelated(_ lhs: RiskFinding, _ rhs: RiskFinding) -> Bool {
        if lhs.category == rhs.category { return true }
        let leftTag = Self.keyTag(lhs.suppressionKey)
        let rightTag = Self.keyTag(rhs.suppressionKey)
        guard !leftTag.isEmpty, !rightTag.isEmpty else { return false }
        return leftTag == rightTag
    }

    /// 取 `suppressionKey` 冒号前的标签；无冒号时返回整串。
    fileprivate static func keyTag(_ key: String) -> String {
        guard let colon = key.firstIndex(of: ":") else { return key }
        return String(key[..<colon])
    }

    // MARK: - ④ 排序

    /// 呈现顺序：`level.rank`↓ → `family.presentationWeight`↓ → `timestamp`↑ → `ruleID`↑，
    /// 之后仍以 `suppressionKey`↑ 与规范全序兜底，确保是**严格全序**（Swift 的 `sorted`
    /// 不稳定，全序才能保证输出与输入排列无关）。
    fileprivate static func presentationPrecedence(_ lhs: RiskFinding, _ rhs: RiskFinding) -> ComparisonResult {
        if let step = Self.firstDifference(-lhs.level.rank, -rhs.level.rank) { return step }
        if let step = Self.firstDifference(-lhs.family.presentationWeight, -rhs.family.presentationWeight) { return step }
        if let step = Self.firstDifference(lhs.timestamp, rhs.timestamp) { return step }
        if let step = Self.firstDifference(lhs.ruleID, rhs.ruleID) { return step }
        if let step = Self.firstDifference(lhs.suppressionKey, rhs.suppressionKey) { return step }
        return Self.canonicalPrecedence(lhs, rhs)
    }

    /// 规范全序：覆盖 `RiskFinding` 的全部字段（等级高者在前、时间早者在前，其余升序）。
    ///
    /// 用途是折叠前的稳定化排序。若本函数判定两条命中"完全相等"，则它们的所有
    /// 可比字段都相同（`filePaths` 先比个数再比拼接串，规避分隔符歧义），
    /// 此时折叠顺序不影响结果。
    fileprivate static func canonicalPrecedence(_ lhs: RiskFinding, _ rhs: RiskFinding) -> ComparisonResult {
        if let step = Self.firstDifference(-lhs.level.rank, -rhs.level.rank) { return step }
        if let step = Self.firstDifference(lhs.timestamp, rhs.timestamp) { return step }
        if let step = Self.firstDifference(lhs.ruleID, rhs.ruleID) { return step }
        if let step = Self.firstDifference(-lhs.family.presentationWeight, -rhs.family.presentationWeight) { return step }
        if let step = Self.firstDifference(lhs.family.rawValue, rhs.family.rawValue) { return step }
        if let step = Self.firstDifference(lhs.category.rawValue, rhs.category.rawValue) { return step }
        if let step = Self.firstDifferenceOptional(lhs.command, rhs.command) { return step }
        if let step = Self.firstDifference(lhs.title, rhs.title) { return step }
        if let step = Self.firstDifference(lhs.detail, rhs.detail) { return step }
        if let step = Self.firstDifference(Self.nonNaN(lhs.confidence), Self.nonNaN(rhs.confidence)) { return step }
        if let step = Self.firstDifference(lhs.requiresConfirmation ? 1 : 0, rhs.requiresConfirmation ? 1 : 0) { return step }
        if let step = Self.firstDifference(lhs.agentKind.rawValue, rhs.agentKind.rawValue) { return step }
        if let step = Self.firstDifferenceOptional(lhs.sessionID?.uuidString, rhs.sessionID?.uuidString) { return step }
        if let step = Self.firstDifferenceOptional(lhs.agentID?.uuidString, rhs.agentID?.uuidString) { return step }
        if let step = Self.firstDifference(lhs.filePaths.count, rhs.filePaths.count) { return step }
        if let step = Self.firstDifference(
            lhs.filePaths.joined(separator: "\u{1F}"),
            rhs.filePaths.joined(separator: "\u{1F}")
        ) { return step }
        if let step = Self.firstDifference(lhs.evidenceCount, rhs.evidenceCount) { return step }
        if let step = Self.firstDifference(Self.nonNaN(lhs.evidenceSpan ?? -1), Self.nonNaN(rhs.evidenceSpan ?? -1)) { return step }
        return Self.firstDifference(lhs.suppressionCount, rhs.suppressionCount) ?? .orderedSame
    }

    /// 返回第一个不相等维度的比较结果；相等返回 nil（供调用方继续比较下一维）。
    fileprivate static func firstDifference<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult? {
        if lhs == rhs { return nil }
        return lhs < rhs ? .orderedAscending : .orderedDescending
    }

    /// 把 NaN 归一成 0，保证比较是严格全序（NaN 与自身都不相等，会破坏排序前提）。
    fileprivate static func nonNaN(_ value: Double) -> Double {
        value.isNaN ? 0 : value
    }

    /// 可比较字段的可选版本：nil 排在最前，保证仍是严格全序。
    fileprivate static func firstDifferenceOptional<T: Comparable>(
        _ lhs: T?,
        _ rhs: T?
    ) -> ComparisonResult? {
        switch (lhs, rhs) {
        case (nil, nil): return nil
        case (nil, .some): return .orderedAscending
        case (.some, nil): return .orderedDescending
        case let (left?, right?): return firstDifference(left, right)
        }
    }
}
