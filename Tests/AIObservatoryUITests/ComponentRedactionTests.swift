//
//  ComponentRedactionTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-exitlist（#89 共用组件的遮罩咽喉）
//  ─────────────────────────────────────────────────────────
//  三个共用组件（`MonospacedCodeView` / `SectionHeader` / `EmptyStateView`）被全站十几格吃，
//  而它们此前**一个字都不掩**。把遮罩放进组件里是本单的结构性判断：
//  在调用点包一层要包十五次，漏一次无人知道——而漏掉的那一次往往带着整条命令行。
//
//  这一支只判**组件本体**：喂一段含真实家目录的文本，开/关各渲染一次。
//  调用点由出口闸（`ExitChannelInventoryTests`）与整页枚举（`PageEnumerationTests`）负责。
//
//  ⚠️ 剪贴板那一条**只能源码级**判：需求方 09-23 硬令停止一切点击验证，
//  而复制按钮没有免点击入口。写在这里而不写成"已实测"，是因为它确实没被点过。
//

import Testing
import Foundation
import SwiftUI
@testable import AIObservatoryCore
@testable import AIObservatoryUI
import AIObservatoryTestSupport

@MainActor
@Suite("UI: #89 共用组件自带遮罩（屏上 + 复制）", .serialized)
struct ComponentRedactionTests {

    private static var home: String { NSHomeDirectory() }
    private static var projectRoot: String { "\(home)/Documents/AiX" }
    private static var sample: String { "\(projectRoot)/.ssh/id_ed25519" }

    /// ⚠️ 关闭那一臂必须是 `.off`（恒等映射），不是"少给一个项目根"。
    /// 本文件第一版写成"始终带 home"，于是"关掉"仍然把家目录换成 `~`，
    /// 反向探针当场失去意义——这跟 #64 的"开关是装饰"是同一个坑，只不过这次坑在测试里。
    private static func mask(on: Bool) -> PathPrivacy.Mask {
        on ? PathPrivacy.Mask(home: home, projectRoots: [projectRoot]) : .off
    }

    private static func texts<V: View>(_ view: V, on: Bool, probe: String) async -> [String] {
        await A11yTree.renderedTexts(
            view.environment(\.demoRedaction, mask(on: on)).frame(width: 900, height: 700),
            minCount: 2, settle: 6, probe: probe)
    }

    // MARK: 等宽代码块

    @Test("等宽代码块：开启映射时屏上读不到真实家目录，占位符在")
    func monospacedBlockHidesTheHome() async {
        let on = await Self.texts(MonospacedCodeView("cat \(Self.sample)\ngit status"), on: true,
                                 probe: "git status")
        #expect(on.contains { $0.contains("git status") },
                "代码块整块没渲染 ⇒ 『不含家目录』是空的：\n\(on)")
        let leaks = on.filter { $0.contains(Self.home) }
        #expect(leaks.isEmpty, "开着映射，等宽代码块仍漏出家目录：\n\(leaks)")
        #expect(on.contains { $0.contains(PathPrivacy.Mask.projectPlaceholder) },
                "没换成占位符 ⇒ 映射没吃到这一格（样例在项目根下面，出的是 `<project>` 而不是 `~`）：\n\(on)")
    }

    @Test("反向探针：等宽代码块关掉映射时逐字带着真实路径（证明上面那条不是空的）")
    func monospacedBlockShowsTheHomeWhenOff() async {
        let off = await Self.texts(MonospacedCodeView("cat \(Self.sample)"), on: false, probe: "id_ed25519")
        #expect(off.contains { $0.contains(Self.sample) },
                "关掉映射也看不见原文 ⇒ 这一格根本没渲染：\n\(off)")
    }

    @Test("复制出去的那一份与屏上同一把尺（需求方禁令：不许点击 ⇒ 只能源码级）")
    func copiedTextIsTheSameString() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/DesignSystem/MonospacedCodeView.swift")
        #expect(code.contains("pasteboard.setString(scrubbed"),
                "复制按钮还在写 `text` 原文 ⇒ 屏上遮了、剪贴板没遮（那是最容易外流的一条）")
        #expect(!code.contains("setString(text"), "同一格还留着原文出口")
    }

    // MARK: 分组标题 / 空态

    @Test("分组标题的副标题吃映射：两页的错误面板就是从这里把库路径铺上屏的")
    func sectionHeaderSubtitleIsMasked() async {
        let header = SectionHeader("读取失败", subtitle: "无法打开 \(Self.home)/x.sqlite")
        let on = await Self.texts(header, on: true, probe: "读取失败")
        let off = await Self.texts(header, on: false, probe: "读取失败")
        #expect(off.contains { $0.contains(Self.home) },
                "反向探针红：关掉映射时副标题也不带原文 ⇒ 这一格没渲染：\n\(off)")
        #expect(!on.contains(where: { $0.contains(Self.home) }),
                "开着映射，分组副标题仍带家目录：\n\(on)")
    }

    @Test("空态那两行吃映射（错误面板与『为什么这一页是空的』都走它）")
    func emptyStateMessageIsMasked() async {
        let state = EmptyStateView("读不到库", systemImage: "exclamationmark.triangle",
                                   message: "路径 \(Self.home)/db.sqlite 不存在")
        let on = await Self.texts(state, on: true, probe: "读不到库")
        let off = await Self.texts(state, on: false, probe: "读不到库")
        #expect(off.contains { $0.contains(Self.home) },
                "反向探针红：关掉映射时空态也不带原文 ⇒ 这一格没渲染：\n\(off)")
        #expect(!on.contains(where: { $0.contains(Self.home) }),
                "开着映射，空态那行仍带家目录：\n\(on)")
    }

    // MARK: 路径行（①那一格的行为面）

    /// 为什么单独有这一条：整页枚举判的是「树里不含真实家目录**前缀**」，而 ① 的漏形是
    /// 占位符被截掉之后露出 `Documents/mona`——它不含前缀，前缀判据对它瞎。
    ///
    /// ⚠️ 但这一条**也只能管到"屏上那格里占位符还在"**：变异确认实测——把 `InlineStat`
    /// 里的 `demoRedaction.tail(...)` 换回旧的自己切段，本条与五页整页枚举**都不红**。
    /// 原因是 `FilePathText` 带 `.accessibilityLabel(masked)`，显式 label 会覆盖可见 `Text`，
    /// 于是无障碍树只看得见 `<project>/Sources/App` 那一格，看不见被截坏的显示串。
    /// 所以这一格的行为面到此为止，真正咬住那个变异的是源码级那条
    /// （`PathPrivacyMaskTests › FilePathText 的截断交给 Mask.tail`）+ `Mask.tail` 的手推字面量。
    /// 记在这儿，是因为"无障碍树能证明一切"是错的：label 一覆盖，它就瞎了一层。
    @Test("路径行末两级：开着映射时占位符必须留在屏上，家目录下的中间段不许铺出来")
    func filePathTextTailKeepsThePlaceholderOnScreen() async {
        let probe = PathPrivacy.Mask.projectPlaceholder
        let on = await Self.texts(
            FilePathText(path: Self.projectRoot + "/Sources/App", mode: .lastTwoComponents),
            on: true, probe: probe)
        #expect(on.contains { $0.contains("App") }, "这一格没渲染 ⇒ 下面的判据是空的：\n\(on)")
        #expect(on.contains { $0.contains(probe) },
                "末两级把占位符吃掉了（屏上会是 `Sources/App` 这种看着像相对路径的串）：\n\(on)")
        // 判的是"**整格等于**裸尾段"而不是"含有 Sources/App"：`.help` 与读屏 label 本来合法地
        // 带着完整映射串 `<project>/Sources/App`，用 `contains` 会把那一格也判红（第一版就红错了）。
        // 注意这条在变异下也不红（见上面那段）——它是"占位符别丢"的下界，不是 ① 的主判据。
        let bareTails = on.filter { $0 == "Sources/App" || $0 == "Documents/AiX" }
        #expect(bareTails.isEmpty, "屏上出现没有占位符打头的裸尾段 ⇒ ①的那格又回来了：\n\(bareTails)")

        // 反向自证：关掉映射时这一格就是旧的 `Documents/mona` 形状。
        let off = await Self.texts(
            FilePathText(path: Self.home + "/Documents/mona", mode: .lastTwoComponents),
            on: false, probe: "mona")
        #expect(off.contains { $0.contains("Documents/mona") },
                "关掉映射时末两级不是旧的 `Documents/mona` ⇒ 关闭态被改坏了：\n\(off)")
    }

    /// 遮罩**幂等**：调用点已经 `scrub` 过一遍、组件里再过一遍，不许变成 `<project>` 套 `<project>`。
    /// 这一条是"敢把遮罩放进组件里"的前提——否则每一层都遮一次会把句子遮没。
    @Test("scrub 是幂等的：组件内再遮一遍不会遮坏")
    func scrubIsIdempotent() {
        let mask = Self.mask(on: true)
        for text in [
            "cat \(Self.home)/Secrets/token.txt",
            "原路径 \(Self.home) 与 \(Self.home)/Documents/AiX/Sources/x.swift",
            "\(Self.home)/Documents/AiX",
            "没有路径的一句话 / 带斜杠但不是绝对路径",
        ] {
            let once = mask.scrub(text)
            #expect(mask.scrub(once) == once, "遮两遍和遮一遍不一样 ⇒ 叠层遮罩会遮坏：\(once)")
        }
    }
}
