//
//  HardcodedChineseRatchetTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10nb（#43 收尾 · 总控 07:5x 裁定 (c)）
//  ─────────────────────────────────────────────────────────
//  治的病：**各页的 bilingualCopy 门禁只查"写进表的字对不对"，查不到"表外面还写着中文"。**
//  Files / Security / Settings 三页连「目录内不许写死中文」那道用例都没有，
//  于是三页各自全绿、屏上却仍然全是硬中文（本仓那一族：门禁看着在，射程盖不到）。
//
//  形状照 `Scripts/ratchet-quiet-design.sh`：**基线 + 只拦新增**。
//  三条刻意的选择，别在后续改动里漂回去：
//  1. **基线是「文件 → 行数」，不是一个总量**。总量能被"一处减一处加"掩盖：
//     把 FilesView 的 26 行搬 5 行到 FilesModel，总数不变，而这一版会同时看见两边。
//  2. **只收不放**：某文件实测低于基线 ⇒ `staleEntries` 非空 ⇒ 这条用例红，
//     要求把基线改低。留在旧值就是 G4 卡在 52 那种假门禁。
//  3. **基线里点名的文件必须还在**：改名能把一行的计数从旧键上摘掉，
//     但新键不在基线里 ⇒ 按 0 计 ⇒ 当场红（`baselineFilesStillExist` 只是把报错说清楚）。
//
//  豁免：12 份 `*Copy.swift` 文案表（中文侧本来就该在里面）。
//  ⚠️ 这条豁免按**文件名**认，所以 `DesignSystem/ReadoutCopy.swift` 也被顺带放过了——
//  它虽然叫 Copy，内容却是**裸 `String` 常量、没有英文侧**（`serverTotalCaption` 在英文态
//  上屏就是中文）。这是已知缺口，已作为请拍项交回总控，不在这里偷偷改判。
//

import Foundation
import Testing
import AIObservatoryUI

@Suite("UI: 写死中文棘轮（基线带身份 + 只拦新增 + 覆盖面分母 + 反向用例证明它会红）",
       .timeLimit(.minutes(2)))
struct HardcodedChineseRatchetTests {

    // MARK: 尺子

    /// 文案表文件：中文侧写在里面是设计，不参与棘轮。
    static let exemptTables: Set<String> = [
        "Shell/ShellCopy.swift", "Dashboard/DashboardCopy.swift", "Sessions/SessionsCopy.swift",
        "Timeline/TimelineCopy.swift", "Settings/SettingsCopy.swift", "Security/SecurityCopy.swift",
        "Files/FilesCopy.swift", "Commands/CommandsCopy.swift", "Projects/ProjectsCopy.swift",
        "Performance/PerformanceCopy.swift", "DesignSystem/AttributionCopy.swift",
        "DesignSystem/ReadoutCopy.swift",
        // #82 的归一层：和上面两份同一种文件——**双语表本体**（`bilingualCopy` 就是它的清单，
        // 里面每条都是 `LocalizedString(zh:en:)`）。登记身份由
        // `exemptTablesAreReallyBilingualTables` 逐条验（占豁免位却没双语表的只许 ReadoutCopy 那一份）。
        "DesignSystem/AgentNaming.swift",
    ]

    /// 存量基线：文件 → 允许还剩多少行写死中文。**只能改小、不能改大**。
    /// 数法就是本文件下面那条 `measuredCounts()`，不是手数。
    static let baseline: [String: Int] = [
        "Analysis/AnalysisPresentation.swift": 26,
        "DesignSystem/MonospacedCodeView.swift": 2,
        "DesignSystem/ObservatoryTimeRange.swift": 6,
        "DesignSystem/Page.swift": 4,
        "DesignSystem/Panel.swift": 1,
        "DesignSystem/RiskBadge.swift": 1,
        "DesignSystem/StatTile.swift": 1,
    ]

    /// 每个文件当前实测多少行。**扫到的每个文件都进这张表**（没命中的记 0）。
    ///
    /// 为什么连 0 也记：覆盖面那几条要靠它数"这一页到底扫到几份文件"。
    /// 只记命中的话，"整页目录改名"和"整页已经迁干净"长得一模一样（都是键不在表里），
    /// 而那正是这把尺子最阴的失效形状——门禁在、射程没了。
    /// **不在基线里的文件按 0 计**（新文件一律不许带硬中文进来）。
    static func measuredCounts() throws -> [String: Int] {
        try measuredCounts(under: "Sources/AIObservatoryUI")
    }

    static func measuredCounts(under relativeDirectory: String) throws -> [String: Int] {
        let root = try BilingualCopyGate.repoRoot()
        let ui = root.appending(path: "Sources/AIObservatoryUI")
        var counts: [String: Int] = [:]
        for file in try BilingualCopyGate.swiftFiles(under: relativeDirectory) {
            let relative = file.path.replacingOccurrences(of: ui.path + "/", with: "")
            if exemptTables.contains(relative) { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            counts[relative] = BilingualCopyGate.chineseLiterals(in: text, fileName: relative).count
        }
        return counts
    }

    /// 超出基线的文件（含"基线里没有这个文件"）。
    static func violations(measured: [String: Int], baseline: [String: Int]) -> [String] {
        measured.keys.sorted().compactMap { file in
            let allowed = baseline[file] ?? 0
            guard let got = measured[file], got > allowed else { return nil }
            return "\(file)：实测 \(got) 行 > 基线 \(allowed) 行"
        }
    }

    /// 基线比实测松的文件 ⇒ 必须把基线改低（只收不放）。
    static func staleEntries(measured: [String: Int], baseline: [String: Int]) -> [String] {
        baseline.keys.sorted().compactMap { file in
            let got = measured[file] ?? 0
            guard let allowed = baseline[file], got < allowed else { return nil }
            return "\(file)：实测已降到 \(got) 行，基线还写着 \(allowed) 行 ⇒ 改低它"
        }
    }

    // MARK: 覆盖面尺子（总控 08:5x 派单：门禁必须自带"我到底扫到了谁"）

    /// 分母用**页名枚举**而不是手抄一份清单：目录名按 `rawValue` 首字母大写的既有约定推。
    /// 不按约定建的新页会当场红（那一页的目录不存在），而不是静默漏掉。
    static func pageDirectory(_ section: SidebarSection) -> String {
        let raw = section.rawValue
        return raw.prefix(1).uppercased() + raw.dropFirst()
    }

    /// 每一页**实际存在**的 `.swift` 份数下限（含该页文案表）。
    ///
    /// ⚠️ 这一列是**普查结果不是余量**：某一页真的少了一个文件，改这一格要连原因一起写。
    /// 不写原因就把它改小 = 偷偷把覆盖面缩掉，和"基线改大"是同一件事。
    static let perPageFileFloor: [String: Int] = [
        "Commands": 3, "Dashboard": 7, "Files": 10, "Performance": 13, "Projects": 11,
        "Security": 8, "Sessions": 8, "Settings": 7, "Timeline": 7,
    ]

    /// "这一页有没有一道按目录的门禁"——**从测试源码里读出来**，不再另立一张登记表。
    /// 认法：同一份测试文件里既有一个真的去读目录的调用（`chineseLiterals(` / `swiftFiles(under:`），
    /// 又有一个 `Sources/AIObservatoryUI/<目录>` 的路径字面量（各套件都写成
    /// `private static let directory = "…"`，所以字面量必在该文件内）。
    ///
    /// 中央棘轮自己**不算**按目录的门禁：它扫的是整个 UI，"有没有漏页"由本文件那几条专门管。
    static let rulerFiles: Set<String> = [
        "BilingualCopyGateSupport.swift",          // 尺子的定义
        "HardcodedChineseRatchetTests.swift",      // 中央棘轮自己
    ]

    static func directoryGates() throws -> [(file: String, directory: String, declaresFloor: Bool)] {
        let root = try BilingualCopyGate.repoRoot()
        let tests = root.appending(path: "Tests/AIObservatoryUITests")
        let names = try FileManager.default.contentsOfDirectory(atPath: tests.path)
            .filter { $0.hasSuffix(".swift") && !rulerFiles.contains($0) }
            .sorted()
        var found: [(String, String, Bool)] = []
        for name in names {
            guard let text = try? String(contentsOf: tests.appending(path: name), encoding: .utf8),
                  text.contains("BilingualCopyGate.chineseLiterals(")
                    || text.contains("BilingualCopyGate.swiftFiles(") else { continue }
            let dir = Self.dirOfGate(text)
            guard !dir.isEmpty else { continue }
            let declaresFloor = text.range(of: #"swiftFiles\(under:.*count >= *\d"#,
                                           options: .regularExpression) != nil
            found.append((name, dir, declaresFloor))
        }
        return found
    }

    /// 派单第 ① 条：每道按目录的门禁都要带"扫了几份文件"的长度守卫。
    /// 没有守卫的门禁在目录改名之后会**扫 0 份文件并常绿**——本仓那一族。
    static func directoryGatesMissingFileCountGuard() throws -> [String] {
        try Self.directoryGates().filter { !$0.declaresFloor }.map(\.file)
    }

    /// **已收口页登记**：页 → (收掉的行数, 那一笔提交)。
    ///
    /// 这张表不是给代码看的，是给**"从基线派生的对账单"**看的。
    /// 一页收完，它在基线里的那几行会**整行消失**（只收不放要求删干净），
    /// 于是只看基线的视图会永远认为"这一页没动过"——Security 那 63 行因此被同一张派单重放了四次。
    /// 把"谁收的、收掉多少、哪一笔"留在门禁文件里，再由下面那条用例**每次跑都重验它没说谎**：
    /// 登记过的页今天必须实测仍为 0，且基线里不许再留着它的行。
    static let closedPages: [String: (lines: Int, commit: String)] = [
        "Security": (63, "a66d4c6"),
        "Settings": (143, "2fb0e01"),
        "Files": (81, "5f586e1"),
    ]

    @Test("已收口页登记：登记的页今天实测仍须为 0，且基线不许留着它的行")
    func closedPagesStayClosed() throws {
        for (dir, record) in Self.closedPages.sorted(by: { $0.key < $1.key }) {
            let measured = try Self.measuredCounts(under: "Sources/AIObservatoryUI/" + dir)
            let total = measured.values.reduce(0, +)
            #expect(total == 0,
                    "\(dir) 登记为已收口（\(record.lines) 行 @ \(record.commit)），今天实测 \(total) 行 ⇒ 长回来了")
            let leftovers = Self.baseline.keys.filter { $0.hasPrefix(dir + "/") }.sorted()
            #expect(leftovers.isEmpty,
                    "\(dir) 已收口却还在基线里（只收不放没做到）：\(leftovers)")
        }
    }

    // MARK: 真实对账

    @Test("基线非空（门禁进线时就必须带着存量，不许先进来再填）")
    func baselineIsNotEmpty() throws {
        #expect(!Self.baseline.isEmpty)
        let measured = try Self.measuredCounts()
        #expect(!measured.isEmpty, "实测为空而基线非空 ⇒ 要么尺子坏了，要么基线该整份删掉")
    }

    @Test("实测不高于基线：新增一行写死中文就红")
    func noFileExceedsBaseline() throws {
        let found = Self.violations(measured: try Self.measuredCounts(), baseline: Self.baseline)
        #expect(found.isEmpty, "这些文件比基线多了写死的中文：\n\(found.joined(separator: "\n"))")
    }

    @Test("只收不放：某文件降了就必须把基线改低")
    func baselineMustNotLoiter() throws {
        let stale = Self.staleEntries(measured: try Self.measuredCounts(), baseline: Self.baseline)
        #expect(stale.isEmpty, "基线里留着已经变小的数字（假门禁）：\n\(stale.joined(separator: "\n"))")
    }

    @Test("基线点名的文件都还在（改名不算把存量改没）")
    func baselineFilesStillExist() throws {
        let root = try BilingualCopyGate.repoRoot()
        let missing = Self.baseline.keys.sorted().filter {
            !FileManager.default.fileExists(atPath: root.appending(path: "Sources/AIObservatoryUI/\($0)").path)
        }
        #expect(missing.isEmpty, "基线里有已经不存在的文件：\(missing) ⇒ 直接删掉那几行，别留着")
    }

    // MARK: 覆盖面——"每个局部都真绿、合起来是假话"的那道口子

    /// 分母是 `SidebarSection.allCases`（九页 + 设置），**不是各页套件里各自抄的那份**。
    /// 每一页要求四件事，缺一件就点名那一页：
    /// ① 目录存在且真扫到了文件（防改名/路径写错⇒静默扫 0 份而常绿）；
    /// ② 份数不低于普查下限；③ 这一页超出棘轮基线的行数为 0；
    /// ④ 这一页有自己的文案表，且登记在豁免清单里（没有表 ⇒ 这一页根本没法迁，门禁只能永远放行）。
    @Test("覆盖面：每一页（分母 = SidebarSection.allCases）都被扫到、存量不超基线")
    func everySidebarPageIsCovered() throws {
        var problems: [String] = []
        for section in SidebarSection.allCases {
            let dir = Self.pageDirectory(section)
            let present = try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI/" + dir)
            if present.isEmpty {
                problems.append("\(section.rawValue)：棘轮在 \(dir)/ 扫到 0 份 .swift ⇒ 目录改名或路径写错")
                continue
            }
            let floor = Self.perPageFileFloor[dir] ?? 1
            if present.count < floor {
                problems.append("\(section.rawValue)：只扫到 \(present.count) 份，普查下限 \(floor)")
            }
            let over = Self.violations(measured: try Self.measuredCounts(
                under: "Sources/AIObservatoryUI/" + dir), baseline: Self.baseline)
            if !over.isEmpty {
                problems.append("\(section.rawValue)：超出基线 \(over)")
            }
            if !Self.exemptTables.contains("\(dir)/\(dir)Copy.swift") {
                problems.append("\(section.rawValue)：没有登记本页文案表 \(dir)/\(dir)Copy.swift")
            }
        }
        #expect(problems.isEmpty, "有页没被这一道覆盖：\n\(problems.joined(separator: "\n"))")
    }

    /// 同一把尺子的另一半：**每一页都得有人挂一道按目录的门禁**。
    /// 中央棘轮扫的是全 UI，按目录那几道才带"这一页专用"的逐字断言；
    /// 一页两道都没有，就等于那页的英文态从来没人真看过。
    @Test("覆盖面：每一页都注册了一道按目录的 stray 门禁（缺页点名）")
    func everyPageRegistersADirectoryGate() throws {
        let covered = Set(try Self.directoryGates().map(\.directory))
        let missing = SidebarSection.allCases
            .filter { !covered.contains(Self.pageDirectory($0)) }
            .map(\.rawValue)
        #expect(missing.isEmpty,
                "这些页没有按目录的 stray 门禁（各页自己的那份，不是中央棘轮）：\(missing)")
    }

    /// 派单第 ① 条：每道按目录的门禁都要带"扫了几份文件"的长度守卫。
    /// 没有守卫的门禁在目录改名之后会**扫 0 份文件并常绿**——本仓那一族。
    @Test("覆盖面：每道按目录的门禁都写了份数下限")
    func everyDirectoryGateDeclaresAFileCountFloor() throws {
        let guardless = try Self.directoryGatesMissingFileCountGuard()
        #expect(guardless.isEmpty, "这些套件会静默扫 0 份文件还报绿：\(guardless)")
    }

    /// 两套豁免机制（中央 `exemptTables` 与各套件自己的 `excluding:`）必须说的是同一批文件。
    /// 漂开的方向只有一个是有意的：套件多加一份 `FooCopy.swift` 而中央清单没加 ⇒
    /// 中央棘轮会把那一页的表当"带硬中文的新文件"判红，看起来像误报，其实是**两张表在打架**。
    @Test("覆盖面：各套件的 excluding 名单与中央豁免清单一致")
    func exemptionListsAgree() throws {
        let root = try BilingualCopyGate.repoRoot()
        let tests = root.appending(path: "Tests/AIObservatoryUITests")
        let names = try FileManager.default.contentsOfDirectory(atPath: tests.path)
            .filter { $0.hasSuffix(".swift") }.sorted()
        var strays: [String] = []
        for name in names {
            guard let text = try? String(contentsOf: tests.appending(path: name), encoding: .utf8),
                  text.contains("chineseLiterals(") else { continue }
            let dir = Self.dirOfGate(text)
            guard !dir.isEmpty else { continue }
            for clause in Self.matches(in: text, #"excluding: *\[[^\]]*\]"#) {
                for file in Self.quoted(clause) {
                    if !Self.exemptTables.contains("\(dir)/\(file)") {
                        strays.append("\(name) 把 \(dir)/\(file) 当文案表放过，中央豁免清单里没有")
                    }
                }
            }
        }
        #expect(strays.isEmpty, "两套豁免名单漂了：\n\(strays.joined(separator: "\n"))")
    }

    static func matches(in text: String, _ pattern: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }

    static func quoted(_ clause: String) -> [String] {
        let pieces = clause.components(separatedBy: "\"")
        var out: [String] = []
        var index = 1                                     // 引号成对，取第 1、3、5… 段
        while index < pieces.count {
            if pieces[index].hasSuffix(".swift") { out.append(pieces[index]) }
            index += 2
        }
        return out
    }

    /// 从"这份测试文件里出现的那个 UI 目录字面量"取目录名（各套件都是一份文件对一页）。
    static func dirOfGate(_ text: String) -> String {
        for piece in text.components(separatedBy: "\"") {
            guard piece.hasPrefix("Sources/AIObservatoryUI/") else { continue }
            let dir = String(piece.dropFirst("Sources/AIObservatoryUI/".count))
            if !dir.isEmpty, !dir.contains("/") { return dir }
        }
        return ""
    }

    /// 豁免是按**文件名**认的，所以"名字叫 Copy、内容却是裸 `String`"的文件可以从这里溜走。
    /// 这一条把已知欠账**钉成恰好一份**：混进第二份立刻红；那份欠账被修好也立刻红（提醒删这条）。
    @Test("覆盖面：豁免清单里每条都真是带英文侧的双语表")
    func exemptTablesAreReallyBilingualTables() throws {
        let root = try BilingualCopyGate.repoRoot()
        var fakes: [String] = []
        var gone: [String] = []
        for relative in Self.exemptTables.sorted() {
            let url = root.appending(path: "Sources/AIObservatoryUI/" + relative)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else {
                gone.append(relative); continue
            }
            if !text.contains("LocalizedString(") { fakes.append(relative) }
        }
        #expect(gone.isEmpty, "豁免清单里点名的表已经不在了：\(gone)")
        #expect(fakes == ["DesignSystem/ReadoutCopy.swift"],
                "这些文件占了豁免位却没有双语表：\(fakes)")
    }

    /// 独立走一遍目录，和尺子扫到的集合对齐。
    /// 这条防的是 `swiftFiles(under:)` 自己坏掉（改成不递归、filter 写错、路径拼错）
    /// ——那些情况下"实测不高于基线"会因为**什么都没扫到**而常绿。
    @Test("覆盖面：尺子扫到的文件集合 == 独立走一遍的结果，且不低于全量下限")
    func scanSeesEveryUIFile() throws {
        let root = try BilingualCopyGate.repoRoot()
        let ui = root.appending(path: "Sources/AIObservatoryUI")
        let urls = try #require(FileManager.default.enumerator(
            at: ui, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles]))
        var walked: Set<String> = []
        for case let url as URL in urls where url.pathExtension == "swift" {
            walked.insert(url.path.replacingOccurrences(of: ui.path + "/", with: ""))
        }
        let scanned = Set(try Self.measuredCounts().keys)
        #expect(scanned == walked.subtracting(Self.exemptTables),
                "扫到的与走到的不一致（差在豁免位还是漏在递归？）")
        #expect(walked.count >= 100, "整个 UI 目录只走到大 \(walked.count) 份文件 ⇒ 路径或枚举坏了")
        #expect(scanned.count >= 85, "棘轮只看到 \(scanned.count) 份文件 ⇒ 射程缩了")
    }



    // MARK: 反向用例——尺子本身必须会咬

    /// 派单第 ③ 条：**拿真实文件**注入一行硬中文，必须红并点名。
    ///
    /// 与下面那条合成用例的分工：合成那条查"账算得对不对"（不受仓库改动影响、永远可跑），
    /// 这两条查"**尺子读真实 Swift 源码时真的读得到**"——注释剥离、预览跳块、`codeOnly`
    /// 任何一处改坏，都可能让合成的账仍然对、而对真实文件全盘放行。
    /// 尤其**基线清空之后**，"只收不放"那条再也发不出声（没有旧值可对），
    /// 全盘放行只剩这里能抓住。被测文件都从当场的数据里挑，不写死文件名 ⇒ 页面迁完也不会烂。
    /// 只读不写：注入的是内存里的那份文本，仓库里那个文件一个字没动。
    @Test("反向：往真实文件里注入一行硬中文，当场红并点名")
    func reverseProbeOnRealFiles() throws {
        let root = try BilingualCopyGate.repoRoot()
        let measured = try Self.measuredCounts()

        // A. 基线里点名的真实文件（还有存量）：尺子读出来的行数必须**等于基线那一格**，
        //    注入一行之后必须多算一行，并且被 `violations` 点名。
        guard let baselined = Self.baseline.keys.sorted().first(where: { measured[$0] != nil }) else {
            Issue.record("基线已清空 ⇒ 请改下面 B 那半条继续守（这一条不许直接删）")
            return
        }
        let allowed = Self.baseline[baselined] ?? 0
        let textA = try String(
            contentsOf: root.appending(path: "Sources/AIObservatoryUI/" + baselined), encoding: .utf8)
        let cleanA = BilingualCopyGate.chineseLiterals(in: textA, fileName: baselined).count
        #expect(cleanA == allowed,
                "\(baselined) 实测 \(cleanA) 行，基线写着 \(allowed) 行 ⇒ 那一格已经不对了（先改基线再谈探针）")
        let probedA = Self.probeAppended(to: textA)
        let hitsA = BilingualCopyGate.chineseLiterals(in: probedA, fileName: baselined).count
        #expect(hitsA == cleanA + 1, "注入一行而尺子没多算：\(cleanA) → \(hitsA)")
        let overA = Self.violations(measured: [baselined: hitsA], baseline: Self.baseline)
        #expect(overA.count == 1 && overA[0].contains(baselined), "注入之后没红或没点名：\(overA)")

        // B. 已经清零的那一页（Security/Settings 现在在这一档）：基线里没有它 ⇒ 按 0 计，
        //    注入一行必须被 `violations` 当场抓住。这一半在基线清空之后仍然有效。
        guard let clean = measured.keys.sorted().first(where: { measured[$0] == 0 }) else {
            Issue.record("还没有一个「实测为 0」的真实文件可当对照 ⇒ B 这半条暂时无从验证")
            return
        }
        let textB = try String(
            contentsOf: root.appending(path: "Sources/AIObservatoryUI/" + clean), encoding: .utf8)
        #expect(BilingualCopyGate.chineseLiterals(in: textB, fileName: clean).isEmpty,
                "\(clean) 本应已经干净")
        let overB = Self.violations(
            measured: [clean: BilingualCopyGate.chineseLiterals(
                in: Self.probeAppended(to: textB), fileName: clean).count],
            baseline: Self.baseline)
        #expect(overB.count == 1 && overB[0].contains(clean),
                "往已清零的真实文件里加一行硬中文没被抓：\(overB)")
    }

    /// 注入点刻意放在**文件末尾**：那里正是"扩展、helper 往后长"的地方，
    /// 也是原来那版"跳到文件尾"的预览跳块规则被钻过去的地方。
    static func probeAppended(to text: String) -> String {
        text + "\nprivate let 探针 = Text(\"探针：这句会直接上屏\")\n"
    }

    /// 拿合成读数喂这把尺子：**多写一行**必须被判成违规。
    /// 没有这一条，"门禁进了 main"这句话没有任何证据支撑（真实仓库此刻是绿的，
    /// 绿可能只是因为尺子中了一处 `return ""` 之类的写法而悄悄全放行）。
    @Test("反向：多写一行硬中文，棘轮当场红")
    func ratchetBitesOnOneMoreLine() {
        let base = ["Files/FilesView.swift": 26, "Settings/SettingsView.swift": 28]
        var measured = base
        measured["Files/FilesView.swift"] = 27                      // 有人新加一行写死中文
        let grown = Self.violations(measured: measured, baseline: base)
        #expect(grown.count == 1, "多一行却没被判违规，尺子是坏的：\(grown)")
        #expect(grown.first?.contains("Files/FilesView.swift") == true, "违规条目没点名文件：\(grown)")

        // 新文件不在基线里 ⇒ 按 0 计 ⇒ 带一行就该红（不许"新文件先放过"）。
        let fresh = Self.violations(measured: ["Files/BrandNew.swift": 1], baseline: base)
        #expect(fresh.count == 1, "新文件带硬中文被放过了：\(fresh)")

        // 总量不变但**搬来搬去**也要看得见：这条正是"基线带身份"要防的形状。
        let shuffled = ["Files/FilesView.swift": 21, "Settings/SettingsView.swift": 33]
        #expect(shuffled.values.reduce(0, +) == base.values.reduce(0, +), "夹具本身要保住总量不变")
        let moved = Self.violations(measured: shuffled, baseline: base)
        #expect(moved == ["Settings/SettingsView.swift：实测 33 行 > 基线 28 行"],
                "把 5 行挪进另一个文件没被发现：\(moved)")
    }

    @Test("反向：某文件清零后，基线留着旧值会红（只收不放）")
    func ratchetRejectsStaleBaseline() {
        let base = ["Settings/SettingsView.swift": 28]
        // 迁完了：实测 0。基线还写 28 ⇒ stale 必须点名，否则等于允许"迁完不改门禁"。
        let stale = Self.staleEntries(measured: [:], baseline: base)
        #expect(stale == ["Settings/SettingsView.swift：实测已降到 0 行，基线还写着 28 行 ⇒ 改低它"],
                "清零后基线没被要求改低：\(stale)")
        // 而基线整行删掉之后，两边都干净。
        #expect(Self.staleEntries(measured: [:], baseline: [:]).isEmpty)
        #expect(Self.violations(measured: [:], baseline: [:]).isEmpty)
    }
}
