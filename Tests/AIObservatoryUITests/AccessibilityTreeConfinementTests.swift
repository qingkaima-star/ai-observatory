//
//  AccessibilityTreeConfinementTests.swift
//  AIObservatoryUITests
//
//  Owner: master-controller（#100）
//  ─────────────────────────────────────────────────────────
//  上一波 `ws/cli` 交 #74 时报了一条装置缺陷：`A11yTree` 的注释写着"按窗口标题认窗口"，
//  而代码既没设标题也没过滤 ⇒ 它量到"隔离跑 1 段 / 全量并行 33 段"。
//
//  本波动手前先核了那条前提，**两处对不上**：
//  1. 那个 33 段是 **#89 把 `reading` 读树锁接上之前**量的（`aix-swiftui-ax-tree-test-harness` 记着
//     "reading 锁 #89 才接线"）；锁 + 收尾 `orderOut` 之后，同一进程里同一时刻只有一个挂载窗口是上屏的。
//  2. 我照报上来的说法给装置加了窗口身份筛、并写了"第二次读不许看见第一次的 marker"那条合同用例——
//     **变异把筛摘掉，用例仍然绿**（`/tmp` 那轮：摘掉后 0 红）。⇒ 那条判据是空的，改动与用例我都撤了。
//
//  所以这一格正确的收法不是"再写一份读不到的筛"（那正是本仓最恨的假门禁），
//  而是把**污染真正依赖的那两件事**钉住：
//     · 全仓只允许**一个**挂窗点，且它必须走读树锁、读完必须 `orderOut`；
//     · 顺序两次读，第二次里不许出现第一次的 marker —— 这一条后来**改成了更强的形状**，见下面 ③。
//  哪天有人新开一条挂窗路径忘了上锁，第一道闸当场红——那才是 #100 真正会复发的形状。
//
//  ⚠️ 本波另加**判据那一格**（目标 ②「并行套件下的段数对照」）：负载源把 6 段带 marker 的文本压在屏上，
//  探针在窗口还在的时候发起读 ⇒ 读回来必须只有自己那一段。
//  ⇒ 判完了，两个方向都是**当场量的**：接上锁时探针读回 **1 段**（两轮各 1 段，3.0 s）；
//     把 `await acquireTreeLock()` 摘掉后同一读法读回 **7 段**（= 自己 1 + 负载 6，两轮各 7，均红）。
//     ⇒ 承重的确实是**锁**，不是窗口标题筛：上一波那笔"隔离 1 段 / 全量并行 33 段"的差，
//        量在 #89 把锁接上**之前**，机制与本实验同一条。所以 #100 不再补窗口身份筛（那会是第二份
//        互斥机制），而是把"锁不许被摘"这件事变成一条会随全量套件反复复算的闸。
//  两支套件会在界外互等，所以两边都写了"没会合上 ⇒ 红"，不许空过。
//

import Foundation
import Testing
import SwiftUI
@testable import AIObservatoryUI

@Suite("UI: #100 挂窗路径必须唯一且上锁（装置污染的真正防线）", .serialized, .timeLimit(.minutes(1)))
struct AccessibilityTreeConfinementTests {

    private static let harnessFile = "Tests/AIObservatoryUITests/AccessibilityTreeHarness.swift"
    /// 扫描器**不算自己**：判据字面量里必然出现被搜的那个 token，
    /// 把它数成"第二条挂窗路径"就是仪器抓错人（本闸第一版正是这样红的）。
    private static let thisFile = "Tests/AIObservatoryUITests/AccessibilityTreeConfinementTests.swift"

    private func codeText(_ relative: String) throws -> String {
        try BilingualCopyGate.codeOnlyString(relative)
    }

    /// 全仓测试代码里 `.makeKeyAndOrderFront(` 的处数，以及它出现在哪些文件。
    /// 认「带点号的调用形状」而不是裸名字：本文件自己那句判据字面量不是挂窗点。
    /// （第一版就把它数进去了 —— 仪器抓到自己，说明这条得写准而不是写宽。）
    private func mountSites() throws -> [(file: String, count: Int)] {
        var out: [(String, Int)] = []
        for url in try BilingualCopyGate.swiftFiles(under: "Tests").sorted(by: { $0.path < $1.path }) {
            let relative = "Tests" + url.path.components(separatedBy: "/Tests").last!
            if relative == Self.thisFile { continue }
            let n = try codeText(relative).split(separator: "\n")
                .filter { $0.contains(".makeKeyAndOrderFront(") }.count
            if n > 0 { out.append((relative, n)) }
        }
        return out
    }

    // MARK: ① 唯一挂窗点

    @Test("挂窗点全仓唯一（新加一条挂窗路径忘了上读树锁，正是 #100 的复发形状）")
    func exactlyOneWindowMountSite() throws {
        let sites = try mountSites()
        let total = sites.reduce(0) { $0 + $1.count }
        let where_ = sites.map { "\($0.file) ×\($0.count)" }.joined(separator: ", ")
        #expect(total == 1, "挂窗点有 \(total) 处，出现在：\(where_)")
        let firstFile = sites.first?.file ?? "（无）"
        #expect(sites.first?.file == Self.harnessFile,
                "挂窗点不在装置文件里（\(firstFile)）⇒ 它绕过了读树锁与 orderOut 收尾")
    }

    @Test("装置自己必须同时带着这三件事：读树锁、orderOut 收尾、retained 持有")
    func harnessKeepsAllThreeAntiContaminationSteps() throws {
        let code = try codeText(Self.harnessFile)
        // 「三件事」各恰好一处：多一处锁 = 两条挂窗路径；少一处 orderOut = 上一条用例的窗口留在 AX 列表里。
        #expect(code.split(separator: "\n").filter { $0.contains("acquireTreeLock(") }.count == 2,
                "读树锁的调用/声明数不是 2 ⇒ 挂载路径可能绕开了锁")
        #expect(code.split(separator: "\n").filter { $0.contains("window.orderOut(nil)") }.count == 1,
                "收尾 orderOut 少了或多了 ⇒ 窗口会留在 AX 窗口列表里污染下一条用例")
        #expect(code.contains("retained.append(window)"),
                "窗口本体必须被持住（ARC 拆掉正在更新的宿主视图会把测试宿主打到 SIGSEGV）")
    }

    // 这里原来还有一条「顺序两次读，第二次不许看见第一次的 marker」的行为用例，**已删**：
    // ① 它被下面那支撑斥实验**严格覆盖**（对照实验在"另一支的窗口还压在屏上"时读，
    //    泄漏面比顺序读更大；`orderOut` 一旦摘掉，那一条先红）；
    // ② 它是本波唯一一条在全量里**间歇红**的用例：`.timeLimit(1 分钟)` 是每条用例各自算的，
    //    而它排在读树锁队列里，全量并行时排队就能吃掉 60 s（实测 71.6 s 超时，单独跑 3.0 s 绿）。
    //    留一条"负载一高就红"的闸，下一只手就会去放宽它的预算而不是修它——那是装置欠账的滚法。
    //    （第一次报这条绿的那轮 verify 也在同一棵树里，说明它是间歇红而不是稳定红：
    //      见 `aix-test-assertion-gotchas`——单跑 20/20 不算证据，全量才算。）
}

// MARK: - ③ 段数对照（#100 争议那一格的判据）

/// 两支套件在同一测试进程里会合用的时间戳。
///
/// 只在测试宿主的主执行序上读写（挂窗、泵 RunLoop、读 AX 树全在主线程），所以这里绕开
/// Sendable 检查就够了，不需要锁 —— 加锁反而会掩盖"两个读到底有没有撞上"这件事。
enum ContentionStamps {
    nonisolated(unsafe) static var heavyMountedAt: Date?
    nonisolated(unsafe) static var probeIntentAt: Date?
    nonisolated(unsafe) static var heavyExitAt: Date?

    static let probeMarker = "对照甲-一〇〇"
    static let heavyMarker = "负载乙-一〇〇"
    /// 探针发起读之后，负载窗口还要在屏上压多久。
    /// 2.5 s 是按"摘掉读树锁之后探针必须在自己的第一次读里就撞上"定的：装置每 ~100 ms 读一次树。
    /// 2.5 s：装置每 ~100 ms 读一次树，摘掉锁之后探针**必然**在自己头几拍里撞上负载窗口
    static let holdAfterIntent: TimeInterval = 2.5
}

/// 负载源：**另一支套件**（Swift Testing 只串行化同一支，跨支是并行的——#89 量的就是这件事）。
/// 它把 6 段带 marker 的文本挂上屏，并一直压到探针发起读之后 2.5 秒才收尾。
@Suite("UI: #100 负载源（把窗口压在屏上等探针撞进来）", .timeLimit(.minutes(3)))
struct AccessibilityTreeLoadSourceTests {

    @Test("挂 6 段负载文本，探针上钩后再压 2.5 秒才收")
    func holdSixSegmentsUntilProbeShowsUp() async {
        let enter = Date()
        let read = await A11yTree.renderedFrames(
            VStack(alignment: .leading, spacing: 2) {
                ForEach(0..<6, id: \.self) { index in
                    Text("\(ContentionStamps.heavyMarker)-\(index)")
                }
            },
            size: NSSize(width: 320, height: 240),
            settle: 45
        ) { frames in
            let mounted = frames.filter { $0.text.contains(ContentionStamps.heavyMarker) }.count >= 6
            if mounted, ContentionStamps.heavyMountedAt == nil {
                ContentionStamps.heavyMountedAt = Date()
            }
            guard let intent = ContentionStamps.probeIntentAt else { return false }
            return mounted && Date().timeIntervalSince(intent) >= ContentionStamps.holdAfterIntent
        }
        ContentionStamps.heavyExitAt = Date()

        // 正向：负载源自己没挂上，探针那条反向判据就成了"什么都没读到所以干净"的假绿。
        #expect(read.filter { $0.text.contains(ContentionStamps.heavyMarker) }.count >= 6,
                "负载源没能把 6 段挂上屏（实际 \(read.count) 段）⇒ 对照缺了负载方")
        // 会合：没等到探针就说明两支套件没并行 ⇒ 这条闸不许默默空过。
        #expect(ContentionStamps.probeIntentAt != nil,
                "等了 \(Int(Date().timeIntervalSince(enter))) 秒没等到探针发起读 ⇒ 两支套件没并行，段数对照不成立")
    }
}

/// 探针：在负载窗口**仍在屏上**的时候发起读，读回来只许看见自己那一段。
@Suite("UI: #100 段数对照（并行挂窗时探针读回的段数）", .timeLimit(.minutes(3)))
struct AccessibilityTreeSegmentCountTests {

    @Test("探针读到的段数与隔离跑一致：不含负载 marker、不超过 1 段")
    func probeSeesOnlyItsOwnSegments() async throws {
        let waitDeadline = Date().addingTimeInterval(40)
        while ContentionStamps.heavyMountedAt == nil, Date() < waitDeadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        try #require(ContentionStamps.heavyMountedAt != nil,
                     "40 秒内没等到负载源上屏 ⇒ 两支套件没并行，本条判据不成立")

        ContentionStamps.probeIntentAt = Date()
        let read = await A11yTree.renderedFrames(
            Text(ContentionStamps.probeMarker),
            size: NSSize(width: 320, height: 60),
            settle: 15
        ) { frames in frames.contains { $0.text.contains(ContentionStamps.probeMarker) } }

        // 正向判据先立住，否则下面两条反向判据都是空断言。
        #expect(read.contains { $0.text.contains(ContentionStamps.probeMarker) },
                "探针连自己刚挂上的那段都没读到 ⇒ 反向判据是空的：\(read.map(\.text))")
        let foreign = read.filter { $0.text.contains(ContentionStamps.heavyMarker) }
        #expect(foreign.isEmpty,
                "读到负载套件的 \(foreign.count) 段 ⇒ #100 的污染仍 live，装置得补窗口身份筛：\(read.map(\.text))")
        // 隔离跑 1 段（一个 Text 叶子）。这里不许放宽：段数一涨就说明读的是"全部上屏窗口"而不是自己那一个。
        #expect(read.count <= 1,
                "单文本视图读回 \(read.count) 段（隔离跑 1 段）⇒ 段数被并行挂窗抬高：\(read.map(\.text))")
        // 会合的另一半：负载方是在探针**发起读之后**才收尾的 ⇒ 两次读确实撞在了一起，
        // 而不是"探针等的时候负载方早就走了"那种假绿。
        if let intent = ContentionStamps.probeIntentAt, let exit = ContentionStamps.heavyExitAt {
            #expect(exit > intent, "探针发起读时负载源已经收尾 ⇒ 两读没撞上，本条空转")
        } else {
            Issue.record("时间戳缺失（intent 或 heavyExit 为 nil）⇒ 对照没构成")
        }
    }
}
