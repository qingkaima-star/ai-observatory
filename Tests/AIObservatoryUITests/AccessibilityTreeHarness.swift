//
//  AccessibilityTreeHarness.swift
//  AIObservatoryUITests
//
//  Owner: WS-finisher（#64 ①「整页枚举断言」的机器）
//  ─────────────────────────────────────────────────────────
//  为什么需要它：#64 的漏因就是**逐格断言**——`FilePathText` 那一咽喉有 8 条用例，
//  而采集面那句没人守，于是"开关开着、家目录还在屏上"能一路全绿合进 main。
//  源码级 grep 只能证明"某一行写了映射"，证不了"这一屏渲染出来的文本里没有家目录"。
//
//  【这台机器上唯一走得通的读法，是 AX API，不是 AppKit 的视图树】
//  两条都被实测否证过（各写了一版才发现不行）：
//   · `NSView.accessibilityChildren()` 递归 —— SwiftUI 的 `Text` **一个都不出现**
//     （探针实测：只有 `TextField` 露出来，`Text` 与 `.accessibilityLabel` 全空），
//     而且对真实页面视图递归会把测试宿主**打到 SIGSEGV**。
//   · `AXUIElementCreateApplication(getpid())` 但不跑 `NSApp.run()` —— 同样 0 个元素。
//  加上 `setActivationPolicy(.accessory)` + 一次**有界的嵌套 `NSApp.run()`** 之后，
//  同一把尺读到 71 段文本、`AXValue` 里就是 `Text` 渲染出来的那一句
//  （`tmp/probe/probe4.swift` 留下的可复现探针）。
//
//  ⚠️ 三条自证，缺一条这套机器就是空的（`RenderedPageRedactionTests` 逐条钉着）：
//   ① 集合非空且格子数有下限；② 关掉映射时集合里**必须**出现真实家目录（反向探针）；
//   ③ 开启映射时一个都不许有。②红 ⇒ ①③ 一起作废，因为那说明树没走通或夹具没喂到屏上。
//

import AppKit
import ApplicationServices
import SwiftUI

/// 嵌套主循环里带不出泛型局部类，收集器放文件级。

@MainActor
enum A11yTree {

    /// 同一时刻只允许一棵树在窗口里被读：Swift Testing 会并行跑用例，
    /// 而本装置在泵循环里**会让出主执行序**（不然页面的 `.task` 走不动），
    /// 于是另一条用例的窗口会在这段空隙里挂上并被我读到 ⇒ 开着映射的那一条
    /// 报出"仍有 4 格带家目录"，那 4 格其实来自并行的"关掉映射"那一条（实测）。
    /// 配合 `@Suite(.serialized)` 一起用。
    ///
    /// ⚠️ #89 补上接线：这把锁此前**声明了却没人用**，而 `.serialized` 只串行化**同一个 Suite**
    /// ——两支各自 serialized 的 Suite 仍然并行（实测：关掉映射那一条读到的是另一支 Suite
    /// 开着映射的窗口，`texts` 里连原文都没有）。整页枚举要同时开两支以上，所以把它接上：
    /// 读树期间独占，后来者在界外排队（有超时，绝不无限等——挂住的套件比读不到树的更坏）。
    private static var reading = false

    /// 一个测试进程里 `finishLaunching()` 只该做一次（它是 `NSApp.run()` 的第一步）。
    private static var launched = false

    /// 见上面收尾那段：窗口只藏不关，所以要有地方持住，别让 ARC 去拆正在更新的宿主视图。
    private static var retained: [NSWindow] = []

    /// 渲染一棵真的 SwiftUI 视图树，返回无障碍树里**给人读的每段文本 + 它的 frame + 角色**。
    ///
    /// 只走本进程自己的窗口（`AXWindows`），不碰系统菜单项——`.regular` 那档会把
    /// 「Apple / 关于本机 / 系统设置…」整条菜单挂进来，那是另一个 App 的界面。
    ///
    /// #74 ② 加的这条出口：只回字符串的旧出口证不了「两个文本叠在一起」，
    /// 而那正是肉眼看截图最容易吵不清的形状（派单原话：不要靠眼看定案）。
    ///
    /// - Parameter ready: 「加载完了」的判据。默认只数格子 ⇒ **只该给反向探针用**；
    ///   正向判据必须自己传一段看得见的**数据行**文本条件：早退条件若只数格子，
    ///   会在模型加载完之前返回，正向判据就变成"什么都没读到所以没泄漏"的假绿（实测踩过）。
    static func renderedFrames<V: View>(
        _ view: V,
        size: NSSize = NSSize(width: 1_440, height: 2_600),
        settle: TimeInterval = 8,
        ready: ([A11yTextFrame]) -> Bool = { $0.count >= 20 }
    ) async -> [A11yTextFrame] {
        await acquireTreeLock()
        defer { reading = false }
        let app = NSApplication.shared
        prepare(app)
        let previousPolicy = app.activationPolicy()

        let host = NSHostingView(rootView: AnyView(view))
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = host
        // 每棵树一个**唯一标题**：窗口故意留着不关（关掉正在被 SwiftUI 更新的宿主视图
        // 会把测试宿主打到 SIGSEGV），所以读回来时必须按标题认窗口，
        // 否则上一条用例（关着映射的那一页）会串进这一条（开着映射）⇒ 正向判据被污染成假红。
        // 摆到屏幕外：不抢焦点、不在人的桌面上闪一下，但仍然是"上了屏的窗口"
        // ——AX 树只给已排序的窗口建元素（实测：不 `makeKeyAndOrderFront` 就是 0 段）。
        // ⚠️ 这个 -8 000 **不是**几何判据可以用的"窗口原点"：#91 变宽扫描实测，把窗口摆到屏幕外之后
        //   WindowServer 会把它**折回屏内**（读回来的 AX x 从 ≈4 起算，不是从 -8 000）。
        //   ⇒ 任何"挂载原点 + 宽度 = 绝对右边界"的算法都会把**整棵树**报成越界（实测每段都"越" 8 004 pt）。
        //   窄窗判据因此只能用**自校准**的"最左节点 + 宽度"（与 `SessionsPageGeometryTests` 同一把尺）。
        window.setFrame(NSRect(x: -8_000, y: -8_000, width: size.width, height: size.height),
                        display: false)
        window.makeKeyAndOrderFront(nil)

        var texts: [A11yTextFrame] = []
        let deadline = Date().addingTimeInterval(settle)
        while Date() < deadline {
            // 两件事都要：**先 `await` 让主执行序交出去**（`.task` 里的 `await model.load()`
            // 只有在这段空隙里才走得动——纯泵 RunLoop 时页面永远停在「正在读取文件变更…」，
            // 实测读到 4 段文本），**再泵一次 RunLoop**（SwiftUI 只在主循环被驱动时
            // 才把 `Text` 变成无障碍元素，实测不泵就是 0 段）。
            try? await Task.sleep(for: .milliseconds(60))
            pump(0.04)
            texts = windowFrames()
            // 早退条件**不能**只看"有没有几段文本"：页面刚挂上去时读到的是
            // 「正在读取文件变更…」那四格，`minCount` 定成 3 会在模型加载完之前
            // 就返回，正向判据于是变成"什么都没读到所以没泄漏"的假绿（实测踩过一次）。
            // 所以判"加载完"要看得见**数据行本身**。
            if ready(texts) { break }
        }

        // 收尾两件事，顺序有意义：
        // · **不 `close()`、不摘 contentView**——拆掉正在被 SwiftUI 更新的宿主视图会把测试宿主
        //   直接打到 SIGSEGV（实测两次）；
        // · 但**要 `orderOut`**：留在 AX 窗口列表里，下一条用例（另一种映射状态）就会读到
        //   这一条的格子 ⇒ 正向判据被污染成假红（实测：开着映射仍报 4 格带家目录，
        //   而那 4 格来自上一条"关掉映射"的窗口）。窗口本体由 `retained` 持住，不释放。
        window.orderOut(nil)
        retained.append(window)
        _ = previousPolicy
        return texts
    }

    /// 旧出口：**同一条 mount 路径**，只是把 frame 丢掉换成字符串。
    /// 早退条件逐字保持原样（`probe` 那一格是 #64 夹具的数据行标记），
    /// 免得两条路径各修一半 —— 这台机器只该有一把尺子。
    static func renderedTexts<V: View>(
        _ view: V,
        size: NSSize = NSSize(width: 1_440, height: 2_600),
        minCount: Int = 20,
        settle: TimeInterval = 8,
        probe: String = "README.md"
    ) async -> [String] {
        let frames = await renderedFrames(view, size: size, settle: settle) { read in
            read.count >= minCount && read.contains { $0.text.contains(probe) }
        }
        return frames.map(\.text)
    }

    /// `NSApp.run()` 里真正让无障碍树长出来的那一步是 `finishLaunching()`。
    /// 只调它、**不跑 `run()`**：跑过一版用 `app.run()` + 定时器自停的实现，
    /// 结果整个测试宿主挂住（15 min 无输出，两个进程要手杀）——
    /// 挂住的套件比读不到树的套件坏得多。有界地泵主循环（上面那个 while）拿到的是同一份树。
    /// 读树独占：后来者在界外排队，最多等 120 s（超时就带着"可能被污染"的结果往下走，
    /// 而不是把整个测试宿主挂住——挂死的套件比脏的套件坏得多）。
    private static func acquireTreeLock() async {
        let deadline = Date().addingTimeInterval(120)
        while reading, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(50))
            pump(0.01)
        }
        reading = true
    }

    private static func prepare(_ app: NSApplication) {
        if launched { return }
        app.setActivationPolicy(.accessory)   // `.regular` 会把系统菜单整条挂进来
        app.finishLaunching()
        launched = true
    }

    /// 泵一次主运行圈。
    ///
    /// Swift 把 `RunLoop.run` 与 `CFRunLoopRunInMode` 都标了 `noasync`（异步上下文里不许阻塞主执行序），
    /// 所以只能从**同步**函数里叫——这一层存在的理由就是"异步测试里没法泵循环"。
    /// 只在测试装置里用：它故意让主执行序重入一次，为的是让 SwiftUI 把 `Text` 变成无障碍元素。
    private static func pump(_ seconds: Double) {
        _ = CFRunLoopRunInMode(CFRunLoopMode(RunLoop.Mode.default.rawValue as CFString), seconds, false)
    }

    /// 从 AX 侧读本进程窗口的全部文本（按窗口，不按 app ⇒ 不吃系统菜单）。
    /// 去重按文本：与改名前的旧实现同口径，所以 `ready` 在两条出口上数到的是同一份。
    private static func windowFrames() -> [A11yTextFrame] {
        let ax = AXUIElementCreateApplication(getpid())
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ax, "AXWindows" as CFString, &ref) == .success,
              let windows = ref as? [AXUIElement] else { return [] }
        var out: [A11yTextFrame] = []
        for element in windows { walk(element, depth: 0, into: &out) }
        var seen = Set<String>()
        return out.filter { seen.insert($0.text).inserted }
    }

    /// 一段给人读的文本和它在窗口里的位置（AX 坐标：原点左下、单位 point）。
    struct A11yTextFrame: Equatable, Sendable {
        var text: String
        var frame: CGRect
        /// AX 角色。#74 需要它：容器（分组、带 navigationTitle 的那一层）也会带标签，
        /// 而它们的矩形是**整块区域**，跟叶子文本两两相比会报出一片假重叠。
        /// 只比 `AXStaticText` 才是"两段给人读的字叠在一起"。
        var role: String
    }

    /// AX 位置 + 尺寸 ⇒ CGRect。读不到（元素没上屏）时给 `.zero`，由判据自己排除。
    private static func frame(of element: AXUIElement) -> CGRect {
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXPosition" as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(element, "AXSize" as CFString, &sizeRef) == .success,
              let posValue = posRef, let sizeValue = sizeRef else { return .zero }
        var position = CGPoint.zero
        var dimension = CGSize.zero
        AXValueGetValue(posValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &dimension)
        return CGRect(origin: position, size: dimension)
    }

    private static func role(of element: AXUIElement) -> String {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, "AXRole" as CFString, &ref) == .success,
              let role = ref as? String else { return "" }
        return role
    }

    /// 递归一棵 AX 子树。**只走本进程窗口**，深度有界防环。
    /// #74 ②：每段文本连同它的 frame 与角色一起收 —— 只收字符串证不了"两段文本叠在一起"。
    private static func walk(_ element: AXUIElement, depth: Int, into out: inout [A11yTextFrame]) {
        if depth > 60 { return }        // 树深度有界，防环
        for key in ["AXValue", "AXTitle", "AXDescription", "AXHelp", "AXPlaceholderValue"] {
            var ref: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, key as CFString, &ref) == .success else { continue }
            if let text = ref as? String, !text.isEmpty {
                out.append(A11yTextFrame(text: text, frame: frame(of: element), role: role(of: element)))
            }
            if let list = ref as? [String] {
                out.append(contentsOf: list.filter { !$0.isEmpty }
                    .map { A11yTextFrame(text: $0, frame: frame(of: element), role: role(of: element)) })
            }
        }
        var kids: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, "AXChildren" as CFString, &kids) == .success,
           let array = kids as? [AXUIElement] {
            for child in array { walk(child, depth: depth + 1, into: &out) }
        }
    }
}
