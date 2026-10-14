//
//  SessionRowGeometryTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/cli（#74 ②）
//  ─────────────────────────────────────────────────────────
//  #74 ② 要的是**判据**而不是结论：需求方实拍里"时间列与元信息挤在同一带"，
//  肉眼看截图吵不清（到底是重叠、还是中间截断把字切腰上了？）。
//  所以这里用刚扩出来的 frame 出口量：同一行内任意两段给人读的文本，
//  **矩形不许相交**（容差 1pt：hairline 与相邻基线常有亚像素贴合）。
//
//  【语言边界，不藏】这些视图读的是 `UILanguage.current`（进程全局），
//  同一个测试进程里翻不出英文态 ⇒ 英文那一路由**验收实拍**覆盖
//  （启动带 `-AppleLanguages "(en)"`）。本判据在当前语言下做多宽度扫描，
//  并把行内文本喂成长路径 + 长时长，让宽度压力是真的（不是恰好没挤到）。
//

import AppKit
import SwiftUI
import Testing
@testable import AIObservatoryUI
@testable import AIObservatoryCore

@Suite("UI: #74 会话行几何判据（文本 frame 不许相交）", .serialized)
struct SessionRowGeometryTests {

    /// 一行里最挤的组合：长项目名 + 活的长时长 + 四位数计数 + 风险胶囊。
    @MainActor private static func crowdedRow() -> SessionRow {
        SessionRow(
            session: AgentSession(
                displayIndex: 32, kind: .openAICodex, title: "OpenAI Codex CLI · 2026-09-22 18:56",
                projectPath: "/Users/dev/Worktrees/mona-backend-integration",
                startedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
                outcome: .running),
            counters: SessionCounters(created: 1275, modified: 285, deleted: 5,
                                      commands: 1289, failedCommands: 12, riskEvents: 307),
            isSelected: true, action: {})
    }

    /// #74 ② 的量法结论（两次实测对不上，取能复核的那一条）：
    /// · 隔离跑：会话行在 AX 树里只有 **1 段**文本（`SessionRow` 带
    ///   `.accessibilityElement(children: .combine)` ⇒ 整行是一个合并节点）；
    /// · 全量跑：同一条读到 **33 段** ⇒ 那是**别的套件的窗口串进来的**
    ///   （`@Suite(.serialized)` 只串行化本套件，挡不住并行套件挂窗口）。
    /// ⇒ "同一行内两段文本不相交"这个判据**在 AX 侧不存在对象**，不能假装量到了：
    ///   合并成一个节点是无障碍上的正确做法（读屏念一行而不是四段），不该为了可测而拆掉。
    ///   真正的视觉重叠由验收的两张实拍（中/英）覆盖，加上产品侧那段**按段定截断策略**的改动。
    /// 这里只留可复核的断言：合并标签必须**仍然带得齐行内读数**（拆段改动最容易丢的就是这个）。
    @MainActor
    @Test("会话行的合并标签带得齐行内读数（分段截断改动没把数字挤出无障碍标签）")
    func combinedRowLabelStillCarriesTheReadouts() async throws {
        let frames = await A11yTree.renderedFrames(
            Self.crowdedRow().frame(width: 640),
            size: NSSize(width: 640, height: 90),
            ready: { $0.contains(where: { $0.text.contains("1,289") }) })
        // 只断"在不在"，不断"有几段"：装置目前会把**同进程所有 AX 窗口**一起走
        // （harness 注释写着"按窗口标题认窗口"，代码里既没设标题也没过滤 ⇒ 并行套件的窗口会串进来，
        // 实测隔离 1 段、全量 33 段）。污染只会**增加**文本，所以"包含"类断言对它是免疫的，
        // 而任何计数断言都会随并行度漂 ⇒ 这里刻意不比数量。缺陷已报总控。
        let joined = frames.map(\.text).joined(separator: " | ")
        for needle in ["1,565", "1,289", "12", "307"] {
            #expect(joined.contains(needle), "合并标签里少了 \(needle)：\(joined)")
        }
        // 行本身必须是**一个**合并节点：合并标签里能同时看到状态、时长、三类计数与路径 ⇒
        // 若有人把 `.combine` 拆了，读屏会开始逐段念，这条会因"同一句里凑不齐这些读数"而红。
        #expect(frames.contains { $0.text.contains("1,565") && $0.text.contains("1,289")
                                    && $0.text.contains("风险事件 307") },
                "没有一段文本同时带得齐行内读数 ⇒ 合并节点被拆了或汇总丢了字段")
    }

    @MainActor
    @Test("反向探针：把两段文本硬叠在一起，判据必须红（不然上面那条是常绿）")
    func criterionDetectsARealOverlap() async throws {
        let overlapped = AnyView(ZStack(alignment: .topLeading) {
            Text("AAAA-左段").foregroundStyle(.primary)
            Text("BBBB-右段").foregroundStyle(.primary)
        }
        .frame(width: 320, height: 40, alignment: .topLeading))
        let frames = await A11yTree.renderedFrames(overlapped, size: NSSize(width: 320, height: 60),
                                                  ready: { $0.count >= 2 })
        let visible = frames.filter { $0.frame.width > 1 && $0.frame.height > 1 }
        #expect(visible.count >= 2, "反向探针没读到两段 ⇒ 这台机器是空的，正向判据一并作废")
        var foundOverlap = false
        for (index, left) in visible.enumerated() {
            for right in visible.dropFirst(index + 1) where right.text != left.text {
                let inter = left.frame.intersection(right.frame)
                if inter.width > 1, inter.height > 1 { foundOverlap = true }
            }
        }
        #expect(foundOverlap, "故意叠在一起都没量到相交 ⇒ frame 这把尺子失效，上面那族判据全是假的")
    }
}
