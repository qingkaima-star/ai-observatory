//
//  DashboardActiveAgentsList.swift
//  AIObservatoryUI / Dashboard
//
//  Owner: WS-QUIET-1（子代理 C，总控留给本页道的收尾）
//  ─────────────────────────────────────────────────────────
//  「当前运行中的 Agent」实时列表：数据由 DashboardModel 通过 runtime.service.activeAgents()
//  首屏拉取，之后由 .agents 增量推送整体替换（进程快照语义，不做本地累加）。
//
//  本轮改的四件事（都是基座已经写好、这里没跟上的地方）：
//    1. `SectionHeader` 右侧的读数不再挂自己的字号覆写——字号由基座定死；
//    2. 懒容器换成非懒 `VStack`：Agent 进程数量天然有界（几十条封顶），
//       懒容器在这里省不到东西，只会带来回收与滚动自旋（本仓实测过的死法）；
//    3. 自造状态点（一个 SF 圆点 + 三档系统色）→ `Tag(状态文案, tone:)`：
//       色点 + 文字，颜色只从 `TagTone`→`ObservatoryColor` 那一套里来；
//    4. 行右侧三个读数原先用私有 `DashboardMetricText(tint:)`，CPU ≥60% 会被染成橙色——
//       那是**发明的语义**（本仓规矩：趋势与阈值不上色，除非 `ObservatoryColor` 里已有档位）。
//       现在统一走 `StatTile(emphasis: .compact)`，不带 tint。
//
//  行版式压成「一行身份 + 行尾读数」+「一行元信息」，行间 `Hairline()`；
//  原先每行又套一层 `Surface.recessed` 圆角矩形（面板内再画一层边界 = 卡中卡），已删。
//

import SwiftUI
import AIObservatoryCore

/// 运行中 Agent 卡片。
struct DashboardActiveAgentsList: View {

    let agents: [AgentInstance]

    /// 每行的取证出口（#98）。nil = 这里没有 shell 可用（预览、独立渲染的用例），
    /// 那时行**照画但不可点**，而不是画一颗点了没反应的按钮。
    var jump: (@MainActor (DashboardEvidenceJump) -> Void)? = nil

    var body: some View {
        Panel {
            VStack(alignment: .leading, spacing: Spacing.sm) {
                // 副标题只写**口径**，不写数（#85）：这一屏"在跑几个"只有一个出处，
                // 就是第 3 档「当前状态」那一格的大数（同一个 `activeAgents` 载荷）。
                // 改前非空档这里印"%1$d 个进程正在被观测（当前状态）"，
                // 与那一格的数同源同值、却换了个名字 ⇒ 同一个数一屏两遍。
                SectionHeader(
                    DashboardCopy.agentsTitle.text(language),
                    subtitle: DashboardCopy.agentsPolling.text(language)) {
                    // 不挂 `.font(...)`：字号由基座定死，这里只降一档颜色。
                    Text(uptimeSummary)
                        .monospacedDigit()
                        .foregroundStyle(Surface.secondaryLabel)
                }

                Hairline()

                if agents.isEmpty {
                    EmptyStateView(
                        DashboardCopy.agentsEmptyTitle.text(language),
                        systemImage: "person.circle.dotted",
                        message: DashboardCopy.agentsEmptyMessage.text(language),
                        fills: false
                    )
                } else {
                    // 非懒容器：数量有界，且每行右侧都是实时读数。
                    VStack(alignment: .leading, spacing: Spacing.none) {
                        ForEach(Array(agents.enumerated()), id: \.element.id) { index, agent in
                            if index > 0 {
                                Hairline()
                            }
                            // 这一行是「此刻在跑的进程」：能带走的条件是它挂在哪个项目上，
                            // 而"在跑"本身就是快照 ⇒ 不带时间区间（与「当前状态」那格同一口径）。
                            if let jump {
                                Button {
                                    jump(.activeAgentRow(projectPath: agent.workingDirectory))
                                } label: {
                                    DashboardActiveAgentRow(agent: agent)
                                }
                                .buttonStyle(.axPressable)
                            } else {
                                DashboardActiveAgentRow(agent: agent)
                            }
                        }
                    }
                }
            }
        }
        .animation(ObservatoryMotion.value, value: agents.count)
    }

    /// 最长存活时长，便于一眼判断谁在长跑。
    private var uptimeSummary: String {
        guard let longest = agents.map(\.uptime).max() else { return "—" }
        return DashboardCopy.agentsLongestUptime.copy.format(language, DurationFormat.compact(longest))
    }
}

/// 单个 Agent 进程行：一行身份 + 行尾读数，一行元信息。
private struct DashboardActiveAgentRow: View {

    /// 行尾三个读数的列宽。**必须定宽**：旧版是 `minWidth: 48` + 右对齐，
    /// 每行 leading 列有多宽取决于那个 Agent 叫什么，于是三列读数在行间是锯齿状的。
    /// #83：三个宽度现在按**装的东西**各取一档（百分比 / 内存 / 时长），
    /// 而不是三列共用一个 88；对齐方向也从 `.leading` 改成与全应用同一档
    /// （`axNumberColumn` = 等宽数字 + 末位对齐，`StatTile(trailing: true)` 让标题跟着走）。
    private static let cpuColumnWidth: CGFloat = Column.percent
    private static let memoryColumnWidth: CGFloat = Column.memory
    private static let uptimeColumnWidth: CGFloat = Column.duration

    let agent: AgentInstance

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                AgentChip(kind: agent.kind, displayName: agent.displayName)
                Tag(stateText, tone: stateTone)
                Spacer(minLength: Spacing.md)
                HStack(alignment: .firstTextBaseline, spacing: Spacing.md) {
                    StatTile(
                        title: "CPU",
                        value: PercentFormat.short(agent.cpuPercent, fractionDigits: 1),
                        emphasis: .compact,
                        trailing: true
                    )
                    .axNumberColumn(Self.cpuColumnWidth)
                    StatTile(
                        title: DashboardCopy.agentMemory.text(language),
                        value: ByteFormat.humanReadable(agent.memoryBytes),
                        emphasis: .compact,
                        trailing: true
                    )
                    .axNumberColumn(Self.memoryColumnWidth)
                    StatTile(
                        title: DashboardCopy.agentUptime.text(language),
                        value: DurationFormat.compact(agent.uptime),
                        emphasis: .compact,
                        trailing: true
                    )
                    .axNumberColumn(Self.uptimeColumnWidth)
                }
                .fixedSize()
            }

            HStack(spacing: Spacing.sm) {
                Text(metaLine)
                    .font(.axMeta)
                    .monospacedDigit()
                    .foregroundStyle(Surface.secondaryLabel)
                    .lineLimit(1)
                if let workingDirectory = agent.workingDirectory {
                    FilePathText(path: workingDirectory, mode: .lastTwoComponents)
                }
                Spacer(minLength: Spacing.none)
            }
        }
        .padding(.vertical, Spacing.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: Sizing.rowMinHeight)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            DashboardCopy.agentA11yLine.copy.format(
                language,
                // #82：读屏念的身份与屏上 `AgentChip` 那一格**同一个出处**。
                // 原来这里直接念 `agent.displayName`（探测到的原始进程名 `claude`），
                // 于是眼睛看到 "Claude Code"、耳朵听到 "claude"——同一行两个名字。
                // 进程名唯一的去处是 tooltip（见 `AgentChip.processNameTooltip`）。
                AgentNaming.name(kind: agent.kind, form: .full, language),
                stateText,
                agent.pid,
                DateFormat.timestamp(agent.startedAt),
                PercentFormat.short(agent.cpuPercent),
                ByteFormat.humanReadable(agent.memoryBytes),
                DurationFormat.compact(agent.uptime)
            )
        )
    }

    /// 行尾元信息：把旧版散在两行的 PID / 启动 / tty / 父 PID / 识别方式并成一句。
    ///
    /// 「启动时间」是需求点名要的：跨天的进程只报运行时长看不出它是哪天起来的。
    private var metaLine: String {
        var parts = [
            "PID \(agent.pid)",
            DashboardCopy.agentStartedAt.copy.format(language, DateFormat.timestamp(agent.startedAt)),
        ]
        if let tty = agent.tty { parts.append(tty) }
        if let parentPID = agent.parentPID { parts.append(DashboardCopy.agentParentPID.copy.format(language, parentPID)) }
        parts.append(DashboardCopy.agentDetectedVia.copy.format(language, agent.detectedVia.displayName(UILanguage.current)))
        return parts.joined(separator: " · ")
    }

    private var stateText: String {
        switch agent.state {
        case .running:    return DashboardCopy.agentStateRunning.text(language)
        case .idle:       return DashboardCopy.agentStateIdle.text(language)
        case .terminated: return DashboardCopy.agentStateTerminated.text(language)
        }
    }

    /// 只有「在跑」值得占用读者的色彩注意力；空闲与已退出都是「现在不用看」，
    /// 一律中性——旧版的黄点 / 灰点是自造色，语义上也不比文字多说什么。
    private var stateTone: TagTone {
        switch agent.state {
        case .running:    return .positive
        case .idle:       return .neutral
        case .terminated: return .neutral
        }
    }
}

#Preview("DashboardActiveAgentsList") {
    VStack(alignment: .leading, spacing: Spacing.md) {
        DashboardActiveAgentsList(agents: [
            AgentInstance(
                kind: .claudeCode,
                pid: 10_421,
                parentPID: 980,
                displayName: "claude",
                executablePath: "/usr/local/bin/claude",
                workingDirectory: "/Users/demo/Projects/Mona/Sources/App",
                tty: "ttys003",
                startedAt: Date().addingTimeInterval(-2_400),
                cpuPercent: 34.8,
                memoryBytes: 1_240_000_000,
                detectedVia: .executablePath
            ),
            AgentInstance(
                kind: .cursorAgent,
                pid: 11_888,
                displayName: "Cursor Agent",
                executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor",
                workingDirectory: "/Users/demo/Projects/Aurora",
                startedAt: Date().addingTimeInterval(-90_000),
                state: .idle,
                cpuPercent: 3.1,
                memoryBytes: 480_000_000,
                detectedVia: .bundleIdentifier
            )
        ])
        DashboardActiveAgentsList(agents: [])
    }
    .padding(Spacing.lg)
    .frame(width: 720)
    .background(Surface.page)
}

private extension DashboardActiveAgentsList {
    var language: AppLanguage { UILanguage.current }
}

private extension DashboardActiveAgentRow {
    var language: AppLanguage { UILanguage.current }
}
