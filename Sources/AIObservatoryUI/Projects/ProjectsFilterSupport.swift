//
//  ProjectsFilterSupport.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-UI
//  ─────────────────────────────────────────────────────────
//  Projects 板块视图层的两处小支撑（不改动 ProjectsModel.swift）：
//    ① `filteredProjects` 依赖的谓词 `passesFilters(_:)` —— 模型里被引用但从未定义，这里补齐；
//    ② `ProjectDeltaText` —— 净增行数的带符号文案，指标区与详情面板共用一份，避免两处写法漂移。
//
//  「净增行只写符号、不上色」是设计语言契约 §2 的硬要求：涨跌算不算好事取决于指标语义，
//  调用方没有渠道表达这一点，染色的净增行就是假信号。文案函数放这里，颜色留给调用方不涂。
//

import Foundation
import AIObservatoryCore

extension ProjectsModel {

    /// 项目是否命中当前的搜索词与 Agent 过滤条件。
    func passesFilters(_ project: ProjectActivity) -> Bool {
        if !searchText.isEmpty {
            let needle = searchText.lowercased()
            let haystack = "\(project.name) \(project.path)".lowercased()
            if !haystack.contains(needle) { return false }
        }
        if !selectedKinds.isEmpty {
            let kinds = Set(project.agentContributions.map(\.kind))
            if kinds.isDisjoint(with: selectedKinds) { return false }
        }
        return true
    }
}

/// 净增行数（新增 − 删除）的带符号文案。
enum ProjectDeltaText {

    /// `+1234` / `-56` / `0`。零不写成 `+0`，那是把「没有净变化」报成「有增长」。
    /// 符号用 ASCII 连字符：与仓库里其余净增行文案一致，也在等宽数字里对齐。
    static func text(_ netLines: Int) -> String {
        if netLines == 0 { return "0" }
        return netLines > 0 ? "+\(netLines)" : "-\(-netLines)"
    }

    /// 完整口径：净增 + 两个分项。只报净增数会把「新增 2000 删了 1990」和「真的净增 10」
    /// 混成同一个数，审计台上这两种含义要分开。
    static func detailed(added: Int, removed: Int, _ language: AppLanguage = UILanguage.current) -> String {
        let net = added - removed
        return ProjectsCopy.deltaDetailed.format(language, text(net), added, removed)
    }
}
