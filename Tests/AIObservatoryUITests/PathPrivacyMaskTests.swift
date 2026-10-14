//
//  PathPrivacyMaskTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10n（#61 演示/脉敏输出 · 渲染层）
//  ─────────────────────────────────────────────────────────
//  三条验收里今天能钉的两条：
//   ① 开启后**任意渲染文本**不含真实主目录前缀；
//   ② 关闭后与今天**逐字一致**。
//  第三条（开关有真消费者，ADR-0006）要等 ICR-0010 那三行进契约——
//  现在能钉的是"消费者已经接上了"：`FilePathText` 真在读这个环境值（下面那条源码级断言）。
//
//  ⚠️ 用例里**不写本机家目录**（门禁 G1/G4 会红）：合成前缀一律用 `/Users/dev`，
//  而"不含真实家目录"那一条按 `NSHomeDirectory()` 当场取来比——
//  这是 `Scripts/verify.sh:64` 认的合规形状（断言家目录语义才留 `NSHomeDirectory()`）。
//

import Testing
import Foundation
import SwiftUI
@testable import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("UI: #61 演示脱敏只在渲染层，默认恒等")
/// #71：类型从 `DemoRedaction.Mask` 并进 `PathPrivacy.Mask`，用例名与文件名跟着走
/// （"演示"是界面语汇，不该出现在跨模块的类型名里）。
struct PathPrivacyMaskTests {

    private static let home = "/Users/dev"
    private static let projectRoot = "/Users/dev/Documents/AiX"

    private static let project = PathPrivacy.Mask(
        home: home, projectRoots: [projectRoot])

    // MARK: 验收 ②：关闭 = 逐字恒等

    @Test("关闭时是恒等映射：一个字都不改（含四种边界）")
    func offIsLiteralIdentity() {
        for path in [
            Self.home,                                   // 家目录本身
            Self.projectRoot + "/Sources/x.swift",       // 深路径
            "/etc/hosts",                                // 与家目录无关
            "/Users/deve/x",                             // **像**前缀但不是（整段边界）
            "相对/路径",
            "",
        ] {
            #expect(PathPrivacy.Mask.off.apply(to: path) == path,
                    "关闭状态下被改写了：\(path) → \(PathPrivacy.Mask.off.apply(to: path))")
        }
        #expect(PathPrivacy.Mask.off.isOff)
        #expect(!Self.project.isOff, "有前缀却报关闭 ⇒ isOff 判据是坏的")
    }

    @Test("环境默认值就是关闭（装配点没注入时这一屏与今天一致）")
    func environmentDefaultsToOff() {
        let injected = EnvironmentValues().demoRedaction
        #expect(injected.isOff)
        #expect(injected.apply(to: Self.projectRoot + "/README.md") == Self.projectRoot + "/README.md")
    }

    // MARK: 验收 ①：开启后不含真实家目录

    @Test("开启后任意渲染文本都不含真实主目录前缀")
    func onHidesTheRealHome() {
        let realHome = NSHomeDirectory()
        // 只在"这台机器真有家目录语义"时才有意义；CI 上 NSHomeDirectory() 也是真值。
        let mask = PathPrivacy.Mask(home: realHome, projectRoots: [])
        let samples = [
            realHome,
            realHome + "/Documents/AiX/Sources/x.swift",
            realHome + "/Library/Application Support/com.aix.aiobservatory/observatory.sqlite",
            realHome + "/.ssh/id_ed25519",
        ]
        for sample in samples {
            let shown = mask.apply(to: sample)
            #expect(!shown.contains(realHome), "渲染串里还留着真实家目录：\(shown)")
            #expect(shown.hasPrefix(PathPrivacy.Mask.homePlaceholder),
                    "家目录前缀没换成占位符：\(shown)")
            // 不删结构：除被替换的那一段，余下段数一字不动（审计信息要留得住）。
            #expect(shown.dropFirst(PathPrivacy.Mask.homePlaceholder.count)
                        == String(sample.dropFirst(realHome.count)),
                    "替换顺带改掉了路径结构：\(sample) → \(shown)")
        }
    }

    @Test("项目根优先于家目录（否则只剩 ~/Documents/AiX，等于没脱敏）")
    func projectRootWinsOverHome() {
        #expect(Self.project.apply(to: Self.projectRoot + "/Sources/x.swift")
                == "<project>/Sources/x.swift")
        #expect(Self.project.apply(to: Self.home + "/Documents/other") == "~/Documents/other")
        // 嵌套仓库：最长的那个先命中，短的不许抢。
        let nested = PathPrivacy.Mask(home: Self.home,
                                        projectRoots: [Self.home, Self.home + "/Documents"])
        #expect(nested.apply(to: Self.home + "/Documents/AiX/x.swift")
                == "<project>/AiX/x.swift")
    }

    @Test("整段边界：/Users/deve 不许被当成 /Users/dev 的孩子")
    func prefixMustEndAtASeparator() {
        #expect(Self.project.apply(to: "/Users/deve/secrets.txt") == "/Users/deve/secrets.txt")
        #expect(Self.project.apply(to: Self.home) == "~")
        #expect(Self.project.apply(to: Self.home + "/x") == "~/x")
    }

    @Test("占位符字面量：语言中性，故意不进任何文案表")
    func placeholdersAreLiteral() {
        #expect(PathPrivacy.Mask.homePlaceholder == "~")
        #expect(PathPrivacy.Mask.projectPlaceholder == "<project>")
    }

    @Test("开关驱动映射：关掉是恒等，开启后主目录与监控根都进表（home 用合成值）")
    func settingsDriveTheMask() {
        let home = "/Users/dev"
        let off = PathPrivacy.Mask.configured(
            from: ObservatorySettings(monitoredRoots: ["~/Documents/AiX"], demoRedactedOutput: false),
            home: home)
        #expect(off.isOff, "开关没开却拿到了非恒等映射")
        #expect(off.apply(to: "/Users/dev/Documents/AiX/x.swift") == "/Users/dev/Documents/AiX/x.swift")

        let on = PathPrivacy.Mask.configured(
            from: ObservatorySettings(monitoredRoots: ["~/Documents/AiX"], demoRedactedOutput: true),
            home: home)
        // 监控根先按给定 home 展开再比：用户输的是 `~/Documents/AiX`，库里存的是绝对路径。
        #expect(on.apply(to: "/Users/dev/Documents/AiX/x.swift") == "<project>/x.swift",
                "监控根没进表（展开口径与库里存的不一致？）")
        #expect(on.apply(to: "/Users/dev/other/x.swift") == "~/other/x.swift")
        #expect(PathPrivacy.Mask.expanded("~", home: home) == home)
        #expect(PathPrivacy.Mask.expanded("/Volumes/Work", home: home) == "/Volumes/Work")
    }

    // MARK: #89 ①：尾段截断是占位符感知的

    /// 断言一律用**手推字面量**，不写「与 split.suffix(2) 相等」这种同义反复——
    /// 那样把实现原样搬进断言，截断吃掉占位符这个 bug 会同时存在于两侧（#64 就是这么假绿的）。
    @Test("开启时末两级不许扔掉占位符：`~/Documents/mona` 出 `~/…/mona`，不出 `Documents/mona`")
    func tailKeepsThePlaceholder() {
        let mask = PathPrivacy.Mask(home: Self.home, projectRoots: [Self.projectRoot])
        #expect(mask.tail("/Users/dev/Documents/mona", components: 2) == "~/…/mona")
        #expect(mask.tail(Self.projectRoot + "/Sources/App/main.swift", components: 2)
                    == "<project>/…/main.swift")
        // 只有一层时不硬造 `…`：那一段本来就放得下。
        #expect(mask.tail("/Users/dev/Documents", components: 2) == "~/Documents")
        // 整条路径就是那个根 ⇒ 只出占位符，不编造子目录。
        #expect(mask.tail(Self.home, components: 2) == "~")
        #expect(mask.tail(Self.projectRoot, components: 2) == "<project>")
        // 末段语义（fileNameOnly）：占位符不必出现，但也不许多给一层。
        #expect(mask.tail("/Users/dev/Documents/mona", components: 1) == "mona")
        #expect(mask.tail(Self.home, components: 1) == "~")
    }

    @Test("不属于任何根的路径：末段形状与改造前逐字一致（不许把 `/etc/hosts` 折成占位符）")
    func tailOutsideTheRootsIsUnchanged() {
        let mask = PathPrivacy.Mask(home: Self.home, projectRoots: [Self.projectRoot])
        #expect(mask.tail("/usr/local/bin/git", components: 2) == "bin/git")
        #expect(mask.tail("/etc/hosts", components: 2) == "etc/hosts")
        #expect(mask.tail("/etc/hosts", components: 1) == "hosts")
        // 整段边界：`/Users/deve` 不是 `/Users/dev` 的孩子 ⇒ 走普通末段，不折叠。
        #expect(mask.placeholderCovering("/Users/deve/x") == nil)
        #expect(mask.tail("/Users/deve/x", components: 2) == "deve/x")
    }

    @Test("关闭时末段截断与今天的 `split.suffix(n)` 逐字一致（默认不改变行为）")
    func tailIsIdentityShapedWhenOff() {
        // 右边全部手推。合成主体 `/Users/dev`（门禁 4/4：本机布局不许进仓）。
        // 关掉时 `/Users/dev` 确实露出 `Users/dev` 这一串——那正是 #89 ①-b 要修的**开关射程**问题
        // （Scene 没注入 ⇒ 开关开着也是这一串），不是截断问题；截断这一层在关闭状态下一行都不该变。
        #expect(PathPrivacy.Mask.off.tail("/Users/dev", components: 2) == "Users/dev")
        #expect(PathPrivacy.Mask.off.tail("/Users/dev/Documents/mona", components: 2)
                    == "Documents/mona")
        #expect(PathPrivacy.Mask.off.tail("/Users/dev/a/b/c", components: 3) == "a/b/c")
        #expect(PathPrivacy.Mask.off.tail("/README.md", components: 2) == "README.md")
        #expect(PathPrivacy.Mask.off.tail("", components: 2) == "")
        #expect(PathPrivacy.Mask.off.placeholderCovering(Self.home) == nil)
    }

    // MARK: 消费者接线（ADR-0006 的前半：读的人已经在了）

    /// 视图侧那一格：`FilePathText` 必须**经** `Mask.tail`，不许留着自己的 `split("/").suffix(2)`。
    /// 这条是防"下一手把 Core 的这条口径又复制回视图"——两份分词正是 #64 的成因。
    @Test("FilePathText 的截断交给 Mask.tail，视图里不再自己切段")
    func filePathTextDelegatesTheTail() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/DesignSystem/InlineStat.swift")
        #expect(code.contains("demoRedaction.tail(path, components: 2)"),
                "末两级没走 Mask.tail ⇒ 占位符又被吃掉")
        #expect(code.contains("demoRedaction.tail(path, components: 1)"),
                "仅文件名那格没走 Mask.tail")
        #expect(!code.contains("split(separator: \"/\""), "视图里还留着自己切路径段的代码")
    }

    // MARK: 消费者接线（ADR-0006 的前半：读的人已经在了）

    /// ADR-0006 的病是「有人拨、没人读」；#61 反过来也可能是「有人读、没人拨」。
    /// 两头都只能读**剥掉注释后的源码**来钉：行为用例证不了"那个 Toggle 真绑在这个字段上"。
    @Test("真消费者接线：设置页拨这个字段、外壳把映射注进环境")
    func switchHasARealConsumer() throws {
        let pane = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Settings/SettingsPrivacyPane.swift")
        #expect(pane.contains("model.binding(\\.demoRedactedOutput)"),
                "设置页没有拨这个字段 ⇒ 开关是装饰（ADR-0006）")
        let shell = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/Shell/ObservatoryRootView.swift")
        #expect(shell.contains(".environment(\\.demoRedaction"), "外壳没注入映射 ⇒ 它是死代码")
        #expect(shell.contains("configured(from: runtime.settings)"),
                "注入没读启动设置 ⇒ 拨了不生效，与 caveat 说的「重启后生效」对不上")
    }

    // MARK: 消费者接线（ADR-0006 的前半：读的人已经在了）

    /// 断言的是**调用点**而不是行为：视图渲染不出可比较的字符串，
    /// 而"组件里还留着原始 path"这件事只能读源码才看得见。
    /// 剥注释再比，否则会被本文件自己写的解释判红。
    @Test("路径咽喉真的在读这个环境值，且不再直出原始 path")
    func chokePointIsWired() throws {
        let code = try BilingualCopyGate.codeOnlyString(
            "Sources/AIObservatoryUI/DesignSystem/InlineStat.swift")
        #expect(code.contains("Environment(\\.demoRedaction)"),
                "FilePathText 没接环境值 ⇒ 这一半是死代码")
        #expect(code.contains("demoRedaction.apply(to: path)"))
        #expect(!code.contains(".help(path)"), "tooltip 还在直出原始 path")
        #expect(!code.contains(".accessibilityLabel(path)"), "VoiceOver 还在念原始 path")
    }
}
