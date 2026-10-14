//
//  SettingsBilingualCopyTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10n（B3 后半 · 设置目录）
//  ─────────────────────────────────────────────────────────
//  B3 的门禁形状：**一个目录一张表 + 一条遍历用例**（不共享一张 `UICopy`，
//  否则与 `ws/uicopy` 必然在同一个数组里撞行）。本文件只覆盖 `Settings/**`。
//
//  另外钉住设置页最贵的一类错译（总控点名的「选项名字翻不准比不翻更糟」）：
//  **不许把没实现的事翻成进行时断言**。`launchAtLoginCaveat` 中文写"待系统接口接入…
//  当前只记录草稿值"，英文若直译成 "Starts at login" 就是界面在撒谎——
//  `ShippedCopyHonestyTests` 管的是中文那一路，英文那一路要靠这条。
//

import Testing
import Foundation
// `@testable`：`String.containsCJK` 是机制层内部的中文判据，测试复用它而不是再写一份
// （两份中文判定一定会飘，而且写的那份通常更松）。
@testable import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("设置目录双语门禁")
struct SettingsBilingualCopyTests {

    @Test("全部文案无缺陷（缺译 / 假双语 / 串位 / 同槽位类型不一致）")
    func noCopyProblems() {
        let broken = copyProblems(in: SettingsCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: SettingsCopy.bilingualCopy).isEmpty)
    }

    /// 接线：**表里声明了几条，清单就必须挂几条**。
    ///
    /// 为什么设置页原本没有这条（B3 那三页有）：本表是"先声明常量、清单里再挂名字"的两段式，
    /// 漏挂一条 ⇒ 常量照样被视图引用、渲染照常，但 `noCopyProblems` 遍历的是清单
    /// ⇒ **那一条永远不会被检查**。这正是本仓头号缺陷族（声明了却没喂给判据）。
    /// 本轮往这张表里加了 30 条，没有这把尺子的话"加漏了"和"加了"长得一样。
    @Test("声明处数 == 清单条数（漏挂进不了门禁）")
    func everyDeclaredEntryIsListed() throws {
        let declared = try B3PageCopyGate.declaredTemplateCount(
            in: "Sources/AIObservatoryUI/Settings/SettingsCopy.swift")
        #expect(declared == SettingsCopy.bilingualCopy.count,
                "表里声明了 \(declared) 条、清单只挂 \(SettingsCopy.bilingualCopy.count) 条 ⇒ 差额那条查不到")
    }

    /// 英文侧没有单复数机制 ⇒ "%1$d sessions" 在命中一条时会渲染成 "1 sessions"。
    /// 逐字断言看不出这种错，靠的是这把尺子（判据与豁免清单见 `B3PageCopyGate`）。
    @Test("英文侧不踩复数硬伤")
    func noPluralTrap() {
        #expect(B3PageCopyGate.pluralTrapNames(in: SettingsCopy.bilingualCopy) == [])
    }

    @Test("每条都真的两路不同")
    func everyPairTranslated() {
        let same = SettingsCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsCJK
        }
        #expect(same.map(\.name) == [])
    }

    /// 英文不许承诺没实现的事：开机启动**尚未**接入系统登录项。
    @Test("登录时启动那条英文不写成进行时断言")
    func launchAtLoginEnglishStaysHonest() {
        let english = SettingsCopy.launchAtLoginCaveat.text(.english)
        #expect(english.contains("Not wired to the system yet"))
        // 这几个说法都会把"没接"读成"已生效"，出现任何一个都算越线。
        for forbidden in ["Starts at login", "Launches at login", "Enabled at login"] {
            #expect(!english.contains(forbidden), "英文把未接入的功能说成了已生效：\(english)")
        }
        #expect(english.contains("only the draft value is recorded"))
        // 同一行那句 detail（本轮从 `SettingsModel` 迁进表）：中文以「当前不会生效」收尾，
        // 英文必须同样自带那句否定，否则"Brings up …"就成了孤零零的现在时断言。
        let detail = SettingsCopy.launchAtLoginDetail.text(.english)
        #expect(detail.contains("so it does nothing today"), "detail 的英文丢了「当前不会生效」：\(detail)")
    }

    /// 「本进程不变」是这句提醒的全部价值（引擎老实存下了值，Scene 却已定死）。
    /// 英文软成 "may need a restart" 就把确定的"这次不会变"说成了不确定。
    @Test("菜单栏提醒两路都点明本进程不变、重启才生效")
    func menuBarReminderHonestInBothLanguages() {
        let chinese = SettingsCopy.menuBarRestartReminder.text(.chineseSimplified)
        #expect(chinese.contains("本进程不变"))
        #expect(chinese.contains("重启后生效"))
        let english = SettingsCopy.menuBarRestartReminder.text(.english)
        #expect(english.contains("nothing changes now"))
        #expect(english.contains("after a relaunch"))
        for forbidden in ["may need", "might require", "could require"] {
            #expect(!english.lowercased().contains(forbidden),
                    "英文把「本进程一定不变」说成了不确定：\(english)")
        }
    }

    /// 常驻那句把字段分成**三档**（已生效 / 需重启 / 压根没接入）。
    /// 中文那一路由 `ShippedCopyHonestyTests` 按「；」切句核对；英文只有分句可依据，
    /// 所以这里钉"三个分句都在"+ "没接入的那两个名字不许出现在 relaunch 那句里"。
    @Test("常驻说明的英文同样分三档，不给空开关背书")
    func persistenceNoticeEnglishKeepsThreeTiers() {
        let english = SettingsCopy.persistenceNotice.text(.english)
        #expect(english.contains("are applied to the running engine"))
        #expect(english.contains("need a relaunch"))
        #expect(english.contains("are not wired to any system API"))
        let restartClause = english.split(separator: ".").first { $0.contains("relaunch") } ?? ""
        #expect(!restartClause.lowercased().contains("login"),
                "英文把「开机启动」塞进了需重启那一句：\(restartClause)")
        #expect(!restartClause.lowercased().contains("endpointsecurity"),
                "英文把「EndpointSecurity」塞进了需重启那一句：\(restartClause)")
    }

    /// 「本窗口即时预览 / 其余重启后生效」是现状；英文不许翻成"全部即时生效"。
    @Test("外观副标题的英文不夸大生效范围")
    func appearanceSubtitleEnglishStaysHonest() {
        let english = SettingsCopy.appearanceSubtitle.text(.english)
        #expect(english.contains("in this window"))
        #expect(english.contains("until you relaunch"))
        #expect(!english.lowercased().contains("applies instantly"),
                "英文把「只有本窗口即时」说成了全局即时：\(english)")
    }

    /// 选项名字（跟随系统 / 浅色 / 深色）在 §3 冻结区，本表只覆盖包着它的那句。
    /// 这条不是"验通过"，是**把已知缺陷钉在用例里**：冻结区迁移后要改的是它。
    @Test("已知残留：强制模式的值仍来自冻结区（英文下会混中文）")
    func frozenThemeValueIsStillChinese() {
        let forced = SettingsCopy.themeForced.format(.english, AppTheme.dark.displayName)
        #expect(forced.contains("Forced"))
        #expect(AppTheme.dark.displayName.containsCJK,
                "AppTheme.displayName 已迁移 ⇒ 请把本条改成 #expect(!forced.containsCJK)")
    }
    // MARK: 目录内不许写死中文（总控 08:5x 派单：覆盖面要有分母，每道按目录的门禁带长度守卫）

    /// 这一页的目录。**中央棘轮扫整个 UI，这一道只盯这一页**，两者查的不是同一件事：
    /// 棘轮管"存量不许变大、谁变了要改名认错"，这一道管"这一页今天到底有没有被读到"。
    private static let directory = "Sources/AIObservatoryUI/Settings"

    /// 长度守卫。目录改名、路径写错、整页被挪走，都会让下面那道门禁
    /// **扫 0 份文件还常绿**——本仓最阴的那一类（门禁在，射程没了）。
    /// 这个数是普查结果不是余量：这一页真要少一个文件，改这一格得连原因一起写。
    @Test("Settings 目录真的被扫到了（不是静默扫 0 份）")
    func scanActuallySeesTheDirectory() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 7,
                "份数掉到普查下限以下 ⇒ 目录改名或被挪走，这道门禁已经射程为零")
    }

    /// 存量数字**只在 `HardcodedChineseRatchetTests.baseline` 里存一份**（文件→行数），
    /// 这里不抄那张表，只钉"这一页超出基线的行数必须为 0"。
    /// 抄一份就会漂（今天这三页正是因为没人挂这道，各自全绿而屏上全是硬中文）。
    @Test("Settings 目录里没有超出棘轮基线的写死中文")
    func noStraysBeyondTheRatchet() throws {
        let over = HardcodedChineseRatchetTests.violations(
            measured: try HardcodedChineseRatchetTests.measuredCounts(under: Self.directory),
            baseline: HardcodedChineseRatchetTests.baseline)
        #expect(over.isEmpty, "这一页比基线多了写死的中文：\n\(over.joined(separator: "\n"))")
    }
}
