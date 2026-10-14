//
//  DashboardEvidenceJumpAdoptionTests.swift
//  AIObservatoryUITests
//
//  Owner: 总控接手 ws/ovexits（#98）
//  ─────────────────────────────────────────────────────────
//  #81 修好了六条证据页"接条件"那半，首页那一半一直没人接：三个格子是
//  `shell?.selection = .sessions` 那种裸换页，最近风险与异常卡的行**压根没有出口**。
//  本文件钉的就是补上的那一段，而且全部是**代码级**判据 ——
//  需求方本波已下令停做真机点击与滚动验证，所以这里一律不起界面、不点不滚：
//  断的是"真发出去的那条意图带了哪几项"，以及"首页源码里每一处都真的接上了"。
//
//  三道闸，缺一道就留活口：
//  ① **条件闸**：每一跳的 `intent(window:)` 逐项对上这一格**取数时用的那一条**。
//     「当前状态」那格必须**不带**区间（它是全表快照）；时段累计六格必须带同一个区间。
//     带错方向不是小瑕疵 —— 那正是"chip 上写着带 7 天、结果集是今天"那种假话。
//  ② **采用率闸（自带分母）**：首页源码里 `DashboardEvidenceJump.` 的调用点数 == 七格，
//     且 `shell?.selection =` 的裸换页剩 0 处。分母写死在这里，
//     少接一格会红，把某一格改回裸换页也会红（`HardcodedChineseRatchetTests` 那一族的教训：
//     按目录扫的门禁不声明分母，就是扫 0 份还报绿）。
//  ③ **反"声明未接线"**：`allCaseNames` 里每一个名字都必须在首页源码里找得到调用点。
//     只在枚举里挂一个 case、界面上没人用它，是本仓头号缺陷族（declared but unfed）。
//
//  ⚠️ 这三道闸量不到"人眼上屏那一眼"（点了真会不会到那一行）。那一格按需求方指令**未做**，
//  记在台账里，不拿代码级证据冒充实测。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

@Suite("UI: #98 概览页各格与各行 → 证据页的跳转", .serialized)
struct DashboardEvidenceJumpAdoptionTests {

    private static let window = ObservatoryTimeRange.lastSevenDays

    // MARK: ① 条件闸

    @Test("七格读数各跳到该跳的那一页，且带的区间就是那个数的区间")
    func tileIntentsCarryTheirOwnWindow() {
        let expected: [(DashboardEvidenceJump, SidebarSection, ObservatoryTimeRange?)] = [
            (.runningAgentSnapshot, .sessions, nil),          // 全表快照，与区间无关
            (.activeDuration, .sessions, Self.window),
            (.windowSessions, .sessions, Self.window),
            (.fileChanges, .files, Self.window),
            (.commands, .commands, Self.window),
            (.agentCPU, .performance, Self.window),
            (.risks, .security, Self.window),
        ]
        for (jump, target, range) in expected {
            let intent = jump.intent(window: Self.window)
            #expect(intent.target == target, "\(jump)：目的地应是 \(target)，实得 \(intent.target)")
            #expect(intent.target != .dashboard, "\(jump)：首页的出口不许跳回首页自己")
            #expect(intent.timeRange == range,
                    """
                    \(jump)：区间应当是 \(String(describing: range))，实得 \(String(describing: intent.timeRange))。\
                    带错区间就是 chip 上那句假话（「当前状态」那格本来不带区间，塞进去反而撒谎）
                    """)
        }
    }

    @Test("文件变更那一格不限种类：大数是修改+新建+删除三者之和")
    func fileChangeTileDoesNotPretendToFilterKinds() {
        let intent = DashboardEvidenceJump.fileChanges.intent(window: Self.window)
        #expect(intent.eventKinds.isEmpty,
                """
                这一格的大数恒等于三个分项之和（`fileTripleCaption`），\
                一旦只带某一种类过去，点进去看到的数就比格子上的小 ⇒ 对不上账
                """)
    }

    @Test("三行出口：风险行带区间并定位那一条，Agent 行只带项目，项目探不到就不表态")
    func rowIntents() {
        let id = UUID()
        let risk = DashboardEvidenceJump.riskRow(riskID: id).intent(window: Self.window)
        #expect(risk.target == .security)
        #expect(risk.timeRange == Self.window, "最近风险那一屏是按区间取的，出口必须带同一个区间")
        #expect(risk.eventID == id, "少了 eventID 就只是换页，落不到那一行")

        let project = "/Users/dev/Projects/Jump"
        let agent = DashboardEvidenceJump.activeAgentRow(projectPath: project).intent(window: Self.window)
        #expect(agent.target == .sessions)
        #expect(agent.projectPath == project)
        #expect(agent.timeRange == nil, "「此刻在跑」是快照，不许被某一格顺手塞进区间")

        let unknown = DashboardEvidenceJump.activeAgentRow(projectPath: nil).intent(window: Self.window)
        #expect(unknown.projectPath == nil,
                "工作目录探不到就说探不到，不许拿一个空串或别的路径冒充一个条件")
    }

    @Test("四类异常分头跳：证据不在同一页，不能都塞进时间线")
    func anomalyIntentsSplitByKind() {
        let expectation: [(AnomalyFinding.Kind, SidebarSection, Set<OperationKind>)] = [
            (.eventBurst, .timeline, []),
            (.deletionSpike, .files, [.fileDeleted]),
            (.commandSpike, .commands, []),
            (.cpuSpike, .performance, []),
        ]
        var seen: [SidebarSection] = []
        for (kind, target, kinds) in expectation {
            let intent = DashboardEvidenceJump.anomaly(kind).intent(window: Self.window)
            #expect(intent.target == target, "\(kind)：应跳 \(target)，实得 \(intent.target)")
            #expect(intent.eventKinds == kinds, "\(kind)：种类条件应为 \(kinds)，实得 \(intent.eventKinds)")
            #expect(intent.timeRange == Self.window, "\(kind)：异常按区间检出，出口必须带同一个区间")
            seen.append(intent.target)
        }
        #expect(Set(seen).count >= 3, "四类异常全跳同一页 = 分头跳没做（\(seen)）")
    }

    // MARK: ② 采用率闸（自带分母）

    @Test("分母：七格出口的名单齐，且首页源码里七处调用点一个不少")
    func tileAdoptionDenominator() throws {
        #expect(DashboardEvidenceJump.tileJumps.count == 7,
                "格子出口名单只剩 \(DashboardEvidenceJump.tileJumps.count) 个（本波收口时是 7 个）")
        let source = try dashboardSource()
        let calls = source.components(separatedBy: "DashboardEvidenceJump.").count - 1
        #expect(calls == 7, "首页里 `DashboardEvidenceJump.` 的调用点是 \(calls) 处，应为 7 处（七格）")
        // 区间只有一个出处：首页每一处 `intent(window:)` 都必须递 `selectedRange`
        // （七格各自一次 + 那一个"行出口"的注入点 `jump(_:)` 一次 = 八处）。
        // 判据写成"总数 == 走 selectedRange 的数"，这样任何人在某一格里自己折一个区间
        // （`.today`、写死 `.last24Hours`）都会当场红——那正是"格子按 7 天算、点进去是今天"的形状。
        // 数的是**调用点**（前面带点），那只定义 `func intent(window:` 不算一处。
        let all = source.components(separatedBy: ".intent(window:").count - 1
        let shared = source.components(separatedBy: ".intent(window: selectedRange)").count - 1
        #expect(shared >= 8, "只有 \(shared) 处递 `selectedRange`（七格 + 行出口注入点）⇒ 有出口没接上区间")
        #expect(all == shared,
                "\(all - shared) 处 `intent(window:)` 递的不是 `selectedRange` ⇒ 首页出现了第二份时间")
    }

    @Test("裸换页清干净：首页不许再出现 shell?.selection = 那种不带条件的跳转")
    func noBareSectionSwitchLeft() throws {
        let source = try dashboardSource()
        let bare = source.components(separatedBy: "selection = .").count - 1
        #expect(bare == 0, "首页还剩 \(bare) 处裸换页（不带任何条件就换板块）")
    }

    // MARK: ③ 反"声明未接线"

    @Test("名单里每一个出口都在首页源码里被用到（声明了没人用 = 少一格出口）")
    func everyCaseIsWired() throws {
        let source = try dashboardSource()
        for name in DashboardEvidenceJump.allCaseNames {
            // 七格以 `DashboardEvidenceJump.case` 引用，三行以 `jump(.case(` 简写引用。
            #expect(source.contains(".\(name)"),
                    "\(name) 只在枚举里挂着，首页源码里找不到调用点 ⇒ 那一格没有出口")
        }
    }

    // MARK: 尺子

    /// 首页全部源码（去掉注释与行文注释），按文件拼起来。
    /// 分母自己数：目录读不到预期份数就红，不静默扫空气。
    private func dashboardSource() throws -> String {
        // ⚠️ 这一句**必须写成一行**：`HardcodedChineseRatchetTests` 那道覆盖面闸用单行正则
        // （`swiftFiles(under: … count >= N`）认"这道闸带了份数守卫"，换行写它就扫不到 ⇒ 被判成无守卫。
        #expect(try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI/Dashboard").count >= 8,
                "Dashboard 目录读不到预期份数 ⇒ 这一道闸扫的是空气")
        return try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI/Dashboard").map { url in
            try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryUI/Dashboard/\(url.lastPathComponent)")
        }.joined(separator: "\n")
    }
}
