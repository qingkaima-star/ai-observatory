//
//  ProjectModelExtensions.swift
//  AIObservatoryUI / Projects
//
//  Owner: WS-UI (subagent J)
//  ─────────────────────────────────────────────────────────
//  ProjectsModel 的**只读派生扩展**：视图层需要、但模型原文件没有的纯计算属性。
//    · 不改动 ProjectsModel.swift；
//    · 不新增任何存储属性（@Observable 的存储状态由原文件统一管理）；
//    · 不重新查询服务（所有值都由已有的 private(set) 状态推导）。
//
//  隔离说明：ProjectsModel 是 @MainActor 类型，这里显式标注 @MainActor，
//  确保 Swift 6 严格并发下能读取其隔离状态。
//

import Foundation
import Observation
import AIObservatoryCore

@MainActor
extension ProjectsModel {

    // MARK: - 选中项

    /// 当前选中的项目快照：详情查询结果优先，退回列表里的同名条目。
    var selectedProject: ProjectActivity? {
        if let detail { return detail }
        guard let path = selectedPath else { return nil }
        return projects.first { $0.path == path }
    }

    // MARK: - 三态判定辅助

    /// 忽略过滤条件后是否有数据：区分「引擎真的没数据」与「被筛选挡掉了」。
    var hasProjectsIgnoringFilters: Bool { !projects.isEmpty }

    /// 是否有实时命中（决定右上角「实时」提示是否出现）。
    var hasLiveActivity: Bool { !liveTouchedPaths.isEmpty }

    // MARK: - 汇总指标

    /// 可见项目里出现过风险事件的项目数。
    var riskProjectCount: Int {
        filteredProjects.filter { $0.riskEventCount > 0 }.count
    }

    /// 可见项目涉及的去重文件数（按路径去重，跨项目同路径只算一次）。
    var distinctHotFileCount: Int {
        Set(filteredProjects.flatMap { $0.hotFiles.map(\.path) }).count
    }

    /// 本次订阅周期内被实时命中的项目数。
    var liveProjectCount: Int { liveTouchedPaths.count }

    /// 可见项目里最后的一次活动时间。
    var latestActivityAt: Date? {
        filteredProjects.map(\.lastSeenAt).max()
    }

    // MARK: - 贡献占比聚合

    /// 可见项目的 Agent 贡献合并结果：同 kind 相加，并按总量归一化，按事件数降序。
    var aggregateContributions: [AgentContribution] {
        var eventTotals: [AgentKind: Int] = [:]
        var shareTotals: [AgentKind: Double] = [:]
        for project in filteredProjects {
            for contribution in project.agentContributions {
                eventTotals[contribution.kind, default: 0] += contribution.eventCount
                shareTotals[contribution.kind, default: 0] += contribution.relativeShare
            }
        }
        let totalShare = shareTotals.values.reduce(0, +)
        return shareTotals.keys
            .map { kind -> AgentContribution in
                let rawShare = shareTotals[kind] ?? 0
                let normalized = totalShare > 0 ? rawShare / totalShare : 0
                return AgentContribution(
                    kind: kind,
                    relativeShare: normalized,
                    eventCount: eventTotals[kind] ?? 0
                )
            }
            .sorted { lhs, rhs in
                if lhs.eventCount != rhs.eventCount { return lhs.eventCount > rhs.eventCount }
                return lhs.kind.displayName < rhs.kind.displayName
            }
    }

    /// 可见项目里真实出现过的 Agent 种类：过滤菜单只列有数据的选项。
    var visibleAgentKinds: [AgentKind] {
        let kinds = aggregateContributions.map(\.kind)
        return kinds.isEmpty ? [] : kinds
    }

    /// 最活跃的项目（文件变更最多）。
    var busiestProject: ProjectActivity? {
        filteredProjects.max { $0.fileChangeCount < $1.fileChangeCount }
    }

    // MARK: - 跳转意图

    /// 详情面板「在文件板块查看」按钮的可达性：只要选中了项目就可用。
    var canJumpToFileBoard: Bool { selectedPath?.isEmpty == false }
}
