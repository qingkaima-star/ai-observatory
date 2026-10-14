//
//  RiskAssessor.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk —— E 聚合层
//
//  规则库的唯一入口：拿一个 `RiskFactWindow`（或若干窗口）跑出聚合后的 `RiskFinding`，
//  并实现契约协议 `AIObservatoryCore.RiskEvaluating`，使 Engine 零改造即可接入。
//
//  确定性：全部方法为纯函数——不读墙钟、不做 IO、不随机。规则集合与聚合策略都由
//  构造子注入，因此同一输入必得逐元素相同的输出。
//

import Foundation
import AIObservatoryCore

/// 会话级风险评估器。
public struct RiskAssessor: Sendable {

    /// 参与评估的规则目录。
    public let catalog: RiskRuleCatalog

    /// 命中聚合策略。
    public let policy: RiskAggregationPolicy

    /// 单事件路径上自建 `RiskFactWindow` 时用的界面语言（批量路径的语言随窗口一起进来，
    /// 见 `RiskFactWindow.interfaceLanguage`）。装配点必须把同一个值同时给 `RiskAssessor`
    /// 与 `RiskPipeline`，否则两条进料路径会写出两种语言的行。
    public let interfaceLanguage: AppLanguage

    /// 装配评估器。
    /// - Parameters:
    ///   - catalog: 规则目录，默认使用四族拼装的 `RiskRuleCatalog.standard`。
    ///   - policy: 聚合策略，默认使用 `RiskAggregationPolicy.standard`。
    public init(
        catalog: RiskRuleCatalog = .standard,
        policy: RiskAggregationPolicy = .standard,
        interfaceLanguage: AppLanguage = .resolved()
    ) {
        self.interfaceLanguage = interfaceLanguage
        self.catalog = catalog
        self.policy = policy
    }

    // MARK: - 窗口评估

    /// 在单个事实窗口内评估全部规则并聚合。
    ///
    /// 会按 `rule.preferences` 预筛：声明 `requiresWriteEvidence` 的规则在窗口内
    /// 既无写类也无删类事实（纯读取会话）时直接跳过。
    /// - Parameter window: 已注入 home 目录、日历与阈值的窗口。
    /// - Returns: 聚合后的命中；空窗口返回空数组。
    public func assess(_ window: RiskFactWindow) -> [RiskFinding] {
        policy.apply(rawFindings(in: window))
    }

    /// 多个窗口的命中合并后再过一次聚合策略。
    ///
    /// 关键点：**不**对单个窗口分别调用 `policy.apply`，否则每个窗口都会各自截断
    /// `maxFindings` 条，且跨窗口的同一根因（同一 `suppressionKey`）无法折叠。
    /// 这里先收集全部原始命中再统一聚合，因此跨窗口同根因也会折叠成一条。
    /// 输出与 `windows` 数组的排列顺序无关（聚合层保证顺序无关性）。
    /// - Parameter windows: 待评估的窗口集合，可为空。
    /// - Returns: 跨窗口聚合后的命中。
    public func assess(_ windows: [RiskFactWindow]) -> [RiskFinding] {
        var collected: [RiskFinding] = []
        for window in windows {
            collected.append(contentsOf: rawFindings(in: window))
        }
        return policy.apply(collected)
    }

    /// 窗口内的命中降级为契约层 `RiskEvent`（顺序与 `assess(_:)` 一致）。
    public func riskEvents(in window: RiskFactWindow) -> [RiskEvent] {
        assess(window).map { $0.riskEvent() }
    }

    // MARK: - 私有

    /// 跑一遍目录里的全部规则，**不**聚合，供单窗口与多窗口共用。
    private func rawFindings(in window: RiskFactWindow) -> [RiskFinding] {
        // 窗口派生集合每次访问都会重排序，这里先算一次复用。
        let hasWriteEvidence = window.hasWriteEvidence

        var collected: [RiskFinding] = []
        for rule in catalog.rules {
            if rule.preferences.requiresWriteEvidence && !hasWriteEvidence { continue }
            collected.append(contentsOf: rule.findings(in: window))
        }
        return collected
    }
}

// MARK: - 契约符合性

extension RiskAssessor: RiskEvaluating {

    /// 契约入口：把单事件上下文降级成一个只含该事实的 `RiskFactWindow` 后评估。
    ///
    /// 映射取舍（能力受限，故在文档里登记为"契约缺口"）：
    /// - 窗口起止都用 `event?.timestamp ?? command?.startedAt ?? fileChange?.timestamp`，
    ///   因此需要"跨度"的规则（持续 CPU、抖动计数）在单事件模式下基本不会触发；
    /// - `RiskContext.recentFileChangeCount` **无法映射**到 `RiskFactWindow` 的任何字段
    ///   （窗口只按事实计数），故忽略：`// TODO(contract-gap)` 批量删除在单事件路径上
    ///   只能看到 1 条删除事实，要拿到"42 条只报 1 条"的效果必须走窗口路径；
    /// - `context.agentKind` / `context.sessionID` 同样没有窗口级落点（窗口从事实与
    ///   `session` 推导），此处不注入，也不伪造 `AgentSession`（伪造需要 `UUID()`，
    ///   会破坏纯函数性）；
    /// - `allowedWriteRoots` 取 `event.projectPath` / `fileChange.projectPath` /
    ///   `command.projectPath` 中非空者（按此顺序，窗口内部会做归一化与去重）；
    /// - `homeDirectory` 用 `NSHomeDirectory()`（与 `RiskFactWindow` 默认值一致）；
    ///   阈值与日历取默认（UTC + Gregorian）。
    /// - 三个事实全为 nil 时直接返回空数组，不做无意义评估。
    public func evaluate(_ context: RiskContext) -> [RiskEvent] {
        guard context.event != nil || context.command != nil || context.fileChange != nil else {
            return []
        }

        // 允许写入根：按 event → fileChange → command 的顺序收集非空 projectPath。
        // RiskFactWindow 内部会做归一化；此处只负责顺序与去重，保证确定性。
        let candidateRoots: [String?] = [
            context.event?.projectPath,
            context.fileChange?.projectPath,
            context.command?.projectPath,
        ]
        var roots: [String] = []
        for candidate in candidateRoots {
            guard let root = candidate, !root.isEmpty else { continue }
            if !roots.contains(root) { roots.append(root) }
        }

        let anchor = context.event?.timestamp ?? context.command?.startedAt ?? context.fileChange?.timestamp
        // TODO(contract-gap): RiskContext.recentFileChangeCount 没有窗口级落点，
        // 单事件路径上规则只能看到 1 条事实（批量删除需走 RiskFactWindow 路径）。
        let window = RiskFactWindow(
            events: context.event.map { [$0] } ?? [],
            fileChanges: context.fileChange.map { [$0] } ?? [],
            commands: context.command.map { [$0] } ?? [],
            samples: [],
            start: anchor,
            end: anchor,
            homeDirectory: NSHomeDirectory(),
            allowedWriteRoots: roots,
            trustedWriteRoots: [],
            interfaceLanguage: interfaceLanguage
        )
        return riskEvents(in: window)
    }

    /// 供 UI 规则清单页使用：返回目录内全部规则的描述符（按 `id` 字典序）。
    public func loadedRules() -> [RiskRuleDescriptor] {
        catalog.descriptors
    }
}
