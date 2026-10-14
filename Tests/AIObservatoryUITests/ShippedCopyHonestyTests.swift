//
//  ShippedCopyHonestyTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uiclose · #3 界面撒谎类）
//  ─────────────────────────────────────────────────────────
//  钉住三类「文案说了一件代码里不存在的事」。共同形状：**界面用现在时承诺一个行为，
//  而全仓找不到它的生产者**。这类缺陷用例抓不到、编译不报、只有拿文案去 grep 代码才看得见，
//  所以把结论固化成对字符串的断言——改回去就红。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

@MainActor
@Suite("UI: 上屏文案不得承诺代码里没有的行为", .timeLimit(.minutes(1)))
struct ShippedCopyHonestyTests {

    @Test("「登录时启动」那一行：没有 SMAppService 就不许写成现在时")
    func launchAtLoginRowDoesNotClaimItWorks() {
        // 实测前提：全仓 `SMAppService` / 登录项注册 零命中，
        // `launchAtLogin` 除了设置页自己读，没有任何消费者。
        // 钉中文那一路：这两句断言读的是**中文标点与中文措辞**，换成 `UILanguage.current`
        // 会在英文机位上静默变红。英文侧同一条实话由 `SettingsBilingualCopyTests` 钉。
        #expect(SettingsModel.launchAtLoginDetail(.chineseSimplified)
            == "开机后自动拉起观测引擎——尚未接入系统登录项，当前不会生效。")
        // 变异防线：把「当前不会生效」抹掉，这一行就退回成一句现在时断言。
        #expect(SettingsModel.launchAtLoginDetail(.chineseSimplified).contains("不会生效"))
    }

    @Test("常驻提示必须把「需重启」与「压根没接入」分成两类")
    func persistenceNoticeSeparatesRestartFromUnimplemented() {
        let notice = SettingsModel.persistenceNotice(.chineseSimplified)
        // 旧文案：「主题、开机启动、EndpointSecurity、菜单栏与数据库目录需重启生效。」
        // ⇒ 把两个**没有任何实现**的开关也说成「重启就好」，那是给空开关背书。
        // 按「；」切句后逐句核对，而不是只 `contains` 整段：
        // 只要「开机启动」被塞回第一句，那条断言就会红，而整段 contains 检查察觉不到。
        let clauses = notice.components(separatedBy: "；")
        #expect(clauses[0].contains("设置已应用到运行中的引擎"))
        // 开机启动与 EndpointSecurity 不许出现在「需重启生效」那一句里
        let restartPart = clauses.count > 1 ? clauses[1] : ""
        #expect(restartPart.contains("需重启生效"))
        #expect(!restartPart.contains("开机启动"))
        #expect(!restartPart.contains("EndpointSecurity"))
        // 而必须有一句明说它们改了也不生效
        #expect(notice.contains("尚未接入系统接口"))
        #expect(notice.contains("改它们不会有任何效果"))
    }

    @Test("侧栏副标题只列这一页真给得出的东西")
    func sidebarSubtitlesMatchWhatThePageRenders() {
        // 总览页是 24 小时柱状图 + 占比环图，没有任何曲线；
        // 性能页那一格自己就写着「这台机器拿不到温度」——侧栏不许替它承诺。
        #expect(SidebarSection.dashboard.subtitle == "AI 活动总览：时长、会话与 24 小时分布")
        #expect(SidebarSection.performance.subtitle == "CPU / 内存 / 磁盘与网络速率")
        for section in [SidebarSection.dashboard, .performance] {
            #expect(!section.subtitle.contains("曲线"), "\(section.subtitle) 里还有曲线")
            #expect(!section.subtitle.contains("温度"), "\(section.subtitle) 里还承诺了温度")
        }
    }

    @Test("温度与功耗：不可得就说不可得，不许退化成 0 或空着让人自己猜")
    func unavailableSensorsAreNamedNotZeroFilled() {
        // `MetricAvailability` 的三态是这条的唯一口径：有值 / 还没采到 / 这台机器给不出。
        #expect(MetricAvailability.resolve(hasSamples: true, reading: nil).caption(metric: "温度", .chineseSimplified)
            == "这台机器拿不到温度")
        #expect(MetricAvailability.resolve(hasSamples: false, reading: nil).caption(metric: "功耗", .chineseSimplified)
            == "等待首次采样")
        // 「有样本但读不出」与「还没样本」必须是两句话，合成一句就会把
        // Apple Silicon 上恒为 nil 的传感器读成「引擎还没跑起来，再等等」。
        #expect(MetricAvailability.resolve(hasSamples: true, reading: nil)
            != MetricAvailability.resolve(hasSamples: false, reading: nil))
    }

    /// `FilesKindCountTests` 钉的是模型层两个函数各自算得对；
    /// 但**当初的缺陷不在算法上**——`fileCount(for:)` 一直算的就是事件数，
    /// 错在它被挂到了「新建**文件**」这个标题下面。所以这一条钉的是**配对**：
    /// 标题写着「文件」的格子必须取去重口径，回答「选这项会看到几行」的菜单必须取事件口径。
    /// 两者换回来，模型层的用例一条都不会红（它们各自都"对"）。
    @Test("Files 页「文件」标题必须配去重口径，筛选菜单必须配事件口径")
    func filesLabelsPairWithTheRightCount() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let view = try codeOnly(root, "Sources/AIObservatoryUI/Files/FilesView.swift")
        let menu = try codeOnly(root, "Sources/AIObservatoryUI/Files/FilesFilterBar.swift")

        // #57 之后标题字面量进了 `FilesCopy`，"扫视图源码找字面量"这条路就查不到配对了。
        // 总控 09:5x 定的方向：**透过文案表读**，且**两语都要判**——不许删、不许放宽。
        // 四段链子，缺一段就有对应的漏法：
        //   ① 按 key 在表里取那条（改名或漏登记 ⇒ 取不到，当场红）；
        //   ② 取到的**两语**都必须带「文件 / Files」这个口径词（诚实规则针对的就是这个词）；
        //   ③ 该 key 与视图里用的那个 Swift 常量必须真是同一条（防"常量与表分家"）；
        //   ④ 视图里该常量的 title 与 `distinctFileCount(for: .kind)` 落在同一个 `FileTile(` 片段（配对本身）。
        // 只查 ② 会漏"换一格用事件数"；只查 ④ 会漏"标题改成不带口径词的说法还配着去重数"。
        let pairing: [(key: String, constant: LocalizedString, site: String, kind: String)] = [
            ("files.tiles.createdTitle", FilesCopy.tileCreatedTitle,
             "FilesCopy.tileCreatedTitle.text()", "created"),
            ("files.tiles.deletedTitle", FilesCopy.tileDeletedTitle,
             "FilesCopy.tileDeletedTitle.text()", "deleted"),
        ]
        let segments = view.components(separatedBy: "FileTile(").dropFirst()
        #expect(segments.count >= 2, "指标区被拆走或改名 ⇒ 这道配对检查射程为零：\(segments.count)")
        for pair in pairing {
            // ① 透过表读，不按常量名读
            guard let entry = FilesCopy.bilingualCopy.first(where: { $0.name == pair.key }) else {
                Issue.record("表里没有 key「\(pair.key)」⇒ 标题被改名或漏登记，护栏已经失明")
                continue
            }
            // ② 两语都要带口径词：中文「文件」、英文 "file"（`Files created` 这类）
            #expect(entry.copy.chineseSimplified.contains("文件"),
                    "\(pair.key) 的中文侧丢了「文件」这个口径词：\(entry.copy.chineseSimplified)")
            #expect(entry.copy.english.lowercased().contains("file"),
                    "\(pair.key) 的英文侧丢了 file 这个口径词（英文态同样不许拿事件数冒充文件数）：\(entry.copy.english)")
            // ③ 表里那条与视图用的常量是同一条（两语逐个比，不比引用）
            #expect(entry.copy.chineseSimplified == pair.constant.text(.chineseSimplified)
                    && entry.copy.english == pair.constant.text(.english),
                    "\(pair.key)：表里的文案与常量分家了")
            // ④ 配对：这一格的标题下面必须走去重口径
            let hit = segments.first { $0.contains(pair.site) }
            #expect(hit != nil, "少了标题为「\(entry.copy.chineseSimplified)」的那一格")
            #expect(hit?.contains("distinctFileCount(for: .\(pair.kind))") == true,
                    "「\(entry.copy.chineseSimplified)」这一格没走去重口径（又用回事件数了）：\(hit ?? "nil")")
        }
        // 行内那个「修改」同样必须是去重口径。
        #expect(view.contains("distinctFileCount(for: .modified)"),
                "「修改」那一格没走去重口径")
        #expect(!view.contains("fileCount(for:"), "FilesView 又用回事件数了")

        // 筛选菜单要的是「点这项会看到几行」——行就是事件，用去重数反而会少报。
        #expect(menu.matches("model.eventCount(for: kind)"))
        #expect(!menu.contains("distinctFileCount(for:"), "菜单改报去重数会少报行数")
    }

    /// 只看代码行：解释「曾经错在哪」的注释里就带着被禁的写法。
    private func codeOnly(_ root: URL, _ relative: String) throws -> String {
        let text = try String(contentsOf: root.appending(path: relative), encoding: .utf8)
        return text.split(separator: "\n")
            .map { line in String(line.components(separatedBy: " //").first ?? "") }
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}

private extension String {
    /// 含某个精确片段（避开 `#expect(a.contains(b))` 把整份文件倒进日志）。
    func matches(_ needle: String) -> Bool { contains(needle) }
}

