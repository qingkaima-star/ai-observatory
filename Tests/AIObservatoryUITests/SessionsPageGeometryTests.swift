//
//  SessionsPageGeometryTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/cli（#74 ①②③）
//  ─────────────────────────────────────────────────────────
//  派单要求：一条常驻判据同时守住②③④ —— **同一屏内任意两段文本的 frame 不许相交，
//  且任何文本不许越出窗口右边界**。这条能挡住"以后谁改回去"，也能挡住"把 max 调大"那种
//  把裁切推到更宽窗口的假修法。
//
//  取证纪律（派单原话，我自己也刚踩过）：**不拿"某行有 .frame(width:)"定罪**，
//  定罪只用两种证据 —— 变宽实验 + 本装置的 frame。所以这里两种宽度各量一次。
//

import AppKit
import SwiftUI
import Testing
@testable import AIObservatoryUI
@testable import AIObservatoryCore
import AIObservatoryTestSupport

@Suite("UI: #74 会话页几何判据（文本不相交、不越右边界）", .serialized)
struct SessionsPageGeometryTests {

    /// 数据行上的唯一字面量：`ready` 用它判"页面真加载完了"，
    /// 否则正向判据会因为"什么都没渲染"而假绿（装置注释里那次实测）。
    private static let marker = "会话几何判据-甲"

    @MainActor private static func page() -> some View {
        let host = InMemoryObservatoryService()
        host.seed(sessions: (0..<6).map { index in
            AgentSession(
                displayIndex: 100 + index, kind: index.isMultiple(of: 2) ? .claudeCode : .openAICodex,
                title: index == 0 ? marker : "\(marker)-\(index)",
                projectPath: "/Users/dev/Worktrees/mona-backend-integration-\(index)",
                startedAt: Date().addingTimeInterval(-Double(index) * 600),
                endedAt: index.isMultiple(of: 2)
                    ? Date().addingTimeInterval(-Double(index) * 600 + 7_000) : nil,
                modifiedFileCount: 13, createdFileCount: 12, deletedFileCount: 5,
                commandCount: 1_289, failedCommandCount: 12, riskEventCount: 3,
                outcome: index.isMultiple(of: 2) ? .success : .running)
        })
        return SessionsView(runtime: ObservatoryRuntime(
            service: host, controller: host, updates: host, settings: ObservatorySettings()))
    }

    // 这里曾有一条"详情面板三档列宽"的判据，**已删**：撤掉 ① 的 ViewThatFits 之后它照样绿 ——
    // 合成渲染套 `.frame(width:)` 会让 SwiftUI **压缩**，而真 inspector 是"列宽固定、内容超宽就裁"，
    // 两种机制不同 ⇒ 这条 AX 判据覆盖不到 ①。不 ship 名不副实的判据（本轮已被这类坑点过两次）。
    // ① 的证据因此改走**变宽实验**（1280 / 1437 两张实拍），见牌上交付块。

    /// 两种窗口宽度各量一次（1280 = 需求方实拍里被裁的那一档，1437 = 拉宽后全露的那一档）。
    @Test("会话页：叶子文本两两不相交，且任何节点不越出窗口右边界", arguments: [1_280.0, 1_437.0])
    @MainActor
    func pageTextsNeitherOverlapNorOverflow(windowWidth: Double) async throws {
        let height: Double = 900
        let frames = await A11yTree.renderedFrames(
            Self.page().frame(width: windowWidth, height: height, alignment: .topLeading),
            size: NSSize(width: windowWidth, height: height),
            ready: { $0.contains(where: { $0.text.contains(Self.marker) }) })
        let all = frames.filter { $0.frame.width > 1 && $0.frame.height > 1 }
        // **两条判据各用各的人群**，这是量出来的分工，不是审美：
        // · 相交 ⇒ 只比叶子文本（`AXStaticText`）。容器（分组、带 navigationTitle 的那一层）
        //   也带标签而矩形是整块区域，与叶子两两比会报出一片假重叠（实测「AI 会话」×一切 19 对）。
        // · 越界 ⇒ 比全部节点。① 那种"右列被窗口裁掉"正是**整块容器**越界，只看叶子会漏。
        // ⚠️ 会话行本身是 `.combine` 的一个节点（角色不是 AXStaticText）⇒ 行内的
        //   「时间列压在分隔线上」（#74 ③）不在"叶子相交"的射程里，由越界判据与实拍共同守。
        let leaves = all.filter { $0.role == "AXStaticText" }
        // 空跑守卫：数据行没渲染出来，后面两条判据都是假的绿。
        #expect(all.contains { $0.text.contains(Self.marker) },
                "没读到数据行标记 ⇒ 页面没渲染，本条判据不成立（宽度 \(windowWidth)）")
        #expect(leaves.count >= 10, "只量到 \(leaves.count) 段叶子文本，不像一整页（全树 \(all.count) 段）")

        let leftEdge = all.map(\.frame.minX).min() ?? 0
        let rightLimit = leftEdge + windowWidth

        var overlaps: [String] = []
        for (index, left) in leaves.enumerated() {
            for right in leaves.dropFirst(index + 1)
                    where right.text != left.text
                        // 父/合并节点的标签**包含**子节点文本（`.combine`、分组标签都这样），
                        // 它们的矩形天然套在一起，那不是视觉叠字 ⇒ 只比互相不含的兄弟段。
                        && !left.text.contains(right.text) && !right.text.contains(left.text) {
                let inter = left.frame.intersection(right.frame)
                if inter.width > 1, inter.height > 1 {
                    overlaps.append("「\(left.text.prefix(18))」×「\(right.text.prefix(18))」"
                                    + " 相交 \(String(format: "%.1f", inter.width))×"
                                    + "\(String(format: "%.1f", inter.height))pt")
                }
            }
        }
        // `#expect` 的第二参是 Comment?，只吃**单条插值字面量**（不吃拼接的表达式）——
        // 总控提醒过，我第一版还是写了拼接，编译当场拦下。
        #expect(overlaps.isEmpty, "宽度 \(windowWidth) 下有 \(overlaps.count) 对文本叠在一起：\(overlaps.prefix(12).joined(separator: " / "))")

        let spilled = all.filter { $0.frame.maxX > rightLimit + 1 }
        #expect(spilled.isEmpty, "宽度 \(windowWidth) 下有 \(spilled.count) 段越出窗口右边界（限 \(String(format: "%.1f", rightLimit))）：\(spilled.prefix(12).map { "「\($0.text.prefix(18))」maxX=\(String(format: "%.1f", $0.frame.maxX))" }.joined(separator: " / "))")
    }
}
