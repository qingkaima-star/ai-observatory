//
//  DashboardEvidenceJumps.swift
//  AIObservatoryUI / Dashboard
//
//  Owner: 总控接手 ws/ovexits（#98 概览 → 证据的完整路径，首页那一段）
//  ─────────────────────────────────────────────────────────
//  #81 把六条证据页的"接条件"那半修好了（`EvidenceJumpWiring`），
//  但**首页自己一格都没接**：三个格子是 `shell?.selection = .sessions` 那种"裸换页"，
//  最近风险那一屏的行**压根没有出口**，异常卡的行也没有。
//  结果就是需求方点名的那一格反面：界面上那个数点进详情，结果集根本没被筛小。
//
//  为什么单独一个文件、而且是**纯函数**：跳转意图必须能在不起界面、不点不滚的前提下被断言
//  （本波需求方已下令停做真机点击与滚动验证 ⇒ 这一族的证据只能是代码级的）。
//  意图一旦写在 `some View` 里，测试就只能启动 SwiftUI 或者干脆不测——两条都不要。
//
//  【一条规矩】每一跳带的条件，**恰好等于界面上那个数取数时用的那一条**，不许更宽也不许更窄：
//    · 「时段累计」六格读的是 `shell.timeRange` 折算出来的那个区间 ⇒ 意图带同一个 `window`；
//    · 「当前状态」那一格是全表快照、与区间无关 ⇒ 意图**不带**时间（`timeRange: nil` = 这一跳
//      对时间没意见，目标页保持原样）。把区间硬塞给它，就是让一句假话上 chip。
//    · 异常按种类分头跳（删除突增 → 文件页并限定删除类；命令突增 → 命令页；CPU 突增 → 性能页），
//      因为"点开它看证据"的证据**不在同一页**。
//
//  【首页唯一一格故意不给出口】活动趋势柱图的**单根柱子**：它代表的是"某一个小时/某一天"，
//  而时间那把尺只有六档（`ObservatoryTimeRange`），没有"就这一格"这一档。
//  要么带一个比那一格宽得多的区间、要么造第七档 —— 前者是"看着带了条件其实带错了区间"，
//  后者是扩大功能范围（需求方明令不许）。⇒ 整页跳时间线那个出口保留在页头那把尺上，
//  柱图自己不发明条件。
//

import Foundation
import AIObservatoryCore

/// 概览页每一个读数、每一行 → 证据页的那一跳。
enum DashboardEvidenceJump: Hashable {

    // MARK: 读数格（七格）

    /// 「当前状态 · 在跑的 Agent 数」——全表快照，**与区间无关** ⇒ 不带时间。
    case runningAgentSnapshot
    /// 「活跃总时长」：区间内新建会话的累计。
    case activeDuration
    /// 「区间内新建会话」。
    case windowSessions
    /// 「文件变更」：修改 + 新建 + 删除三者之和 ⇒ 不限制种类。
    case fileChanges
    /// 「执行命令」（副标题是其中失败的那几次）。
    case commands
    /// 「Agent CPU 均值」：#96 之后这一格只算挂着会话的采样，跳性能页看逐会话拆解。
    case agentCPU
    /// 「风险事件」。
    case risks

    // MARK: 行

    /// 活跃 Agent 列表的一行。项目 = 那个进程的工作目录（探不到时不表态）。
    /// ⚠️ 这一行**带不了会话条件**，是契约决定的不是没做完：`AgentInstance` 是**进程快照**
    /// （`DomainModels.swift:69-82` 只有 pid / kind / workingDirectory / startedAt / cpu…，
    /// 没有 `sessionID`）。要带上就得为它新加一条 agent→会话 的映射或一次取数 ⇒ 超出本波范围。
    /// 出口仍然成立：跳会话页 + 锁定这个项目，比"整屏换页、什么都不带"近了一大步。
    case activeAgentRow(projectPath: String?)
    /// 最近风险的一行：带区间（那一屏的文案就是"本范围内没有触发风险规则"）+ 定位到那一条。
    case riskRow(riskID: UUID)
    /// Agent 时长占比那一段**不在这里**：它的一行能带的条件与「区间内新建会话」那格
    /// 逐字相同（只有区间，`AgentUsageShare` 没有可落进 `SessionQuery` 的第二维），
    /// 再开一个出口就是同一个跳法两个出处 ⇒ 那一格就是它的出口。
    /// 异常卡的一条结论：按异常种类分头跳。
    case anomaly(AnomalyFinding.Kind)

    /// 这一跳真发出去的意图。
    func intent(window: ObservatoryTimeRange) -> JumpIntent {
        switch self {
        case .runningAgentSnapshot:
            return JumpIntent(target: .sessions)
        case .activeDuration, .windowSessions:
            return JumpIntent(target: .sessions, timeRange: window)
        case .fileChanges:
            return JumpIntent(target: .files, timeRange: window)
        case .commands:
            return JumpIntent(target: .commands, timeRange: window)
        case .agentCPU:
            return JumpIntent(target: .performance, timeRange: window)
        case .risks:
            return JumpIntent(target: .security, timeRange: window)
        case let .activeAgentRow(projectPath):
            return JumpIntent(target: .sessions, projectPath: projectPath)
        case let .riskRow(riskID):
            return JumpIntent(target: .security, timeRange: window, eventID: riskID)
        case let .anomaly(kind):
            switch kind {
            case .eventBurst:
                return JumpIntent(target: .timeline, timeRange: window)
            case .deletionSpike:
                return JumpIntent(
                    target: .files,
                    eventKinds: [.fileDeleted],
                    timeRange: window
                )
            case .commandSpike:
                return JumpIntent(target: .commands, timeRange: window)
            case .cpuSpike:
                return JumpIntent(target: .performance, timeRange: window)
            }
        }
    }

    /// 七格读数的出口（顺序与 `DashboardView` 里那两组一致，用例拿它对分母）。
    static let tileJumps: [DashboardEvidenceJump] = [
        .runningAgentSnapshot, .activeDuration, .windowSessions,
        .fileChanges, .commands, .agentCPU, .risks,
    ]

    /// 全部出口的名字。用例按这份名单逐个去首页源码里找**调用点**：
    /// 声明了却没接上 = 少一格出口（本仓头号缺陷族 "declared but unfed"）。
    static let allCaseNames: [String] = [
        "runningAgentSnapshot", "activeDuration", "windowSessions", "fileChanges",
        "commands", "agentCPU", "risks",
        "activeAgentRow", "riskRow", "anomaly",
    ]
}
