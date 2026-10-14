//
//  RiskRuleCatalog.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk —— E 聚合层
//
//  规则清单：把 4 个规则族 façade 的 `all` 拼成一份可查询、可枚举的目录。
//  目录本身不判风险，只提供规则集合与 `RiskRuleDescriptor` 清单（供 UI 与契约层使用）。
//
//  确定性：`descriptors` 与 `duplicateRuleIDs` 都有稳定的排序键；`rule(withID:)` 与
//  `rules(in:)` 保持 `rules` 数组的声明顺序，因此同一目录输入必得同一输出。
//

import Foundation
import AIObservatoryCore

/// 会话级风险规则目录。
///
/// 并行开发的规则族有可能撞到同一个 `identity.id`。目录**不崩溃、不 panic**，
/// 而是通过 `duplicateRuleIDs` 把冲突暴露给测试与装配层，由总控决定取舍。
public struct RiskRuleCatalog: Sendable {

    /// 目录内的全部规则，保持拼接时的声明顺序（聚合层负责最终排序）。
    public var rules: [any AgentRiskRule]

    /// 以任意规则集合构造目录（测试可只放一条规则）。
    public init(rules: [any AgentRiskRule]) {
        self.rules = rules
    }

    /// 标准目录：A 破坏性文件操作 + B 敏感位置 + C 命令行为 + D 行为模式。
    public static let standard = RiskRuleCatalog(rules:
        DestructiveFileOperationRules.all +
        SensitiveLocationRules.all +
        CommandBehaviorRules.all +
        BehaviorPatternRules.all
    )

    /// 规则条数。
    public var count: Int { rules.count }

    /// 转换为契约层描述符清单，按 `id` 字典序排列（`id` 相同时依次以
    /// 分类、默认等级、标题、摘要、族、声明下标兜底，保证全序且确定）。
    public var descriptors: [RiskRuleDescriptor] {
        var entries: [CatalogEntry] = []
        entries.reserveCapacity(rules.count)
        for (offset, rule) in rules.enumerated() {
            entries.append(CatalogEntry(
                offset: offset,
                familyRawValue: rule.identity.family.rawValue,
                descriptor: rule.identity.descriptor
            ))
        }
        entries.sort(by: CatalogEntry.precedes)
        return entries.map(\.descriptor)
    }

    /// 被多于一条规则使用的 `identity.id`，按字典序返回。
    /// 空数组表示目录无撞号。并行子代理实现完成后应由测试断言本值为空。
    public var duplicateRuleIDs: [String] {
        var counts: [String: Int] = [:]
        for rule in rules {
            counts[rule.identity.id, default: 0] += 1
        }
        return counts.reduce(into: [String]()) { result, pair in
            if pair.value > 1 { result.append(pair.key) }
        }.sorted()
    }

    /// 按 `identity.id` 精确取规则；未命中返回 nil。
    /// 若目录里存在重复 id，返回 `rules` 中靠前的一条（顺序确定）。
    public func rule(withID: String) -> (any AgentRiskRule)? {
        rules.first { $0.identity.id == withID }
    }

    /// 指定族的全部规则，保持声明顺序。
    public func rules(in family: RiskRuleFamily) -> [any AgentRiskRule] {
        rules.filter { $0.identity.family == family }
    }
}

// MARK: - 排序辅助

/// `descriptors` 的内部排序载体。只在文件内可见，不出现在任何公共签名里。
fileprivate struct CatalogEntry: Sendable {
    var offset: Int
    var familyRawValue: String
    var descriptor: RiskRuleDescriptor

    /// 严格全序：`id` 字典序优先，后续维度用于在撞号时给出确定次序。
    static func precedes(_ lhs: CatalogEntry, _ rhs: CatalogEntry) -> Bool {
        if lhs.descriptor.id != rhs.descriptor.id { return lhs.descriptor.id < rhs.descriptor.id }
        if lhs.descriptor.category != rhs.descriptor.category {
            return lhs.descriptor.category.rawValue < rhs.descriptor.category.rawValue
        }
        if lhs.descriptor.level != rhs.descriptor.level {
            return lhs.descriptor.level.rank < rhs.descriptor.level.rank
        }
        if lhs.descriptor.name != rhs.descriptor.name { return lhs.descriptor.name < rhs.descriptor.name }
        if lhs.descriptor.summary != rhs.descriptor.summary { return lhs.descriptor.summary < rhs.descriptor.summary }
        if lhs.familyRawValue != rhs.familyRawValue { return lhs.familyRawValue < rhs.familyRawValue }
        return lhs.offset < rhs.offset
    }
}
