//
//  FilesBilingualCopyGateTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-l10n（B3 后半 · 文件目录）
//  ─────────────────────────────────────────────────────────
//  文件目录的门禁：遍历 ``FilesCopy/bilingualCopy`` 断言零缺陷。
//  形状与 `SessionsBilingualCopyGateTests` / `DashboardBilingualCopyGateTests` 一致。
//

import Testing
import Foundation
@testable import AIObservatoryCore
@testable import AIObservatoryUI

@Suite("文件目录双语门禁")
struct FilesBilingualCopyGateTests {

    @Test("全部文案无缺陷（缺译 / 假双语 / 串位 / 同槽位类型不一致）")
    func noCopyProblems() {
        let broken = copyProblems(in: FilesCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复，且每条两路不同")
    func namesUniqueAndTranslated() {
        #expect(duplicateCopyNames(in: FilesCopy.bilingualCopy).isEmpty)
        let same = FilesCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsCJK
        }
        #expect(same.map(\.name) == [])
    }

    @Test("多参数文案的下标连续覆盖 1…n")
    func positionalIndexesComplete() {
        for entry in FilesCopy.bilingualCopy {
            for (language, text) in [(AppLanguage.chineseSimplified, entry.copy.chineseSimplified),
                                      (.english, entry.copy.english)] {
                let positions = Set(LocalizedString.specs(in: text).compactMap(\.position))
                guard positions.isEmpty == false else { continue }
                #expect(positions == Set(1...positions.count),
                        "\(entry.name)（\(language.rawValue)）下标 \(positions.sorted()) 不连续")
            }
        }
    }

    /// 变更类型标签是用户认东西用的：英文必须是同类词（过去分词），不能混进形容词。
    @Test("类型标签英文同类，且中文原字未动")
    func kindTagsAreConsistent() {
        #expect(FilesCopy.kindCreated.text(.chineseSimplified) == "新建")
        #expect(FilesCopy.kindDeleted.text(.chineseSimplified) == "删除")
        #expect(FilesCopy.kindRenamed.text(.chineseSimplified) == "重命名")
        #expect(FilesCopy.kindModified.text(.chineseSimplified) == "修改")
        let english = [FilesCopy.kindCreated, FilesCopy.kindDeleted, FilesCopy.kindRenamed,
                       FilesCopy.kindModified].map { $0.text(.english) }
        #expect(english == ["Created", "Deleted", "Renamed", "Modified"])
        for tag in english {
            #expect(tag.split(separator: " ").count == 1, "类型标签应当是单个词：\(tag)")
        }
    }

    /// 增删摘要那句：数字必须各归各的槽，且分隔符跟着语言走。
    @Test("增删摘要两语言都不串位，连接符不留全角逗号")
    func lineDeltaKeepsSlots() {
        #expect(FilesCopy.lineDelta.format(.chineseSimplified, "12", "3") == "新增 12 行，删除 3 行")
        // 英文原来是 `Added %1$@ lines`：12 读得通，**1 就成了 "Added 1 lines"**——
        // 复数没有机制，只能把名词挪到数字之前。1 与 N 各钉一次，防止"顺手改通顺"改回去。
        #expect(FilesCopy.lineDelta.format(.english, "12", "3") == "Lines added 12, removed 3")
        #expect(FilesCopy.lineDelta.format(.english, "1", "1") == "Lines added 1, removed 1")
        #expect(FilesCopy.clauseJoiner.text(.english) == ", ")
        #expect(!FilesCopy.clauseJoiner.text(.english).contains("，"),
                "英文那行还挂全角逗号")
    }
    // MARK: 目录内不许写死中文（总控 08:5x 派单：覆盖面要有分母，每道按目录的门禁带长度守卫）

    /// 这一页的目录。**中央棘轮扫整个 UI，这一道只盯这一页**，两者查的不是同一件事：
    /// 棘轮管"存量不许变大、谁变了要改名认错"，这一道管"这一页今天到底有没有被读到"。
    private static let directory = "Sources/AIObservatoryUI/Files"

    /// 长度守卫。目录改名、路径写错、整页被挪走，都会让下面那道门禁
    /// **扫 0 份文件还常绿**——本仓最阴的那一类（门禁在，射程没了）。
    /// 这个数是普查结果不是余量：这一页真要少一个文件，改这一格得连原因一起写。
    @Test("Files 目录真的被扫到了（不是静默扫 0 份）")
    func scanActuallySeesTheDirectory() throws {
        #expect(try BilingualCopyGate.swiftFiles(under: Self.directory).count >= 10,
                "份数掉到普查下限以下 ⇒ 目录改名或被挪走，这道门禁已经射程为零")
    }

    /// 存量数字**只在 `HardcodedChineseRatchetTests.baseline` 里存一份**（文件→行数），
    /// 这里不抄那张表，只钉"这一页超出基线的行数必须为 0"。
    /// 抄一份就会漂（今天这三页正是因为没人挂这道，各自全绿而屏上全是硬中文）。
    @Test("Files 目录里没有超出棘轮基线的写死中文")
    func noStraysBeyondTheRatchet() throws {
        let over = HardcodedChineseRatchetTests.violations(
            measured: try HardcodedChineseRatchetTests.measuredCounts(under: Self.directory),
            baseline: HardcodedChineseRatchetTests.baseline)
        #expect(over.isEmpty, "这一页比基线多了写死的中文：\n\(over.joined(separator: "\n"))")
    }

    // MARK: #57 迁入的 60 条带来的三把新尺子

    /// 整表不许踩「数字紧跟以 s 结尾的英文名词」。
    /// 英文没有复数机制，`1 agents` / `3 roots` 只能靠**写法**避免（`Agents · %1$d`），
    /// 而这类写法一旦被人"顺手改通顺"就回到病里——所以扫整张表，不靠 reviewer 记得。
    /// 单位缩写（`s/ms/µs/ns`）由尺子自己豁免，见 `B3PageCopyGate.siUnitExemptions`。
    @Test("整张表不踩复数陷阱（数字后面不许跟以 s 结尾的名词）")
    func wholeTableAvoidsThePluralTrap() {
        let traps = B3PageCopyGate.pluralTrapNames(in: FilesCopy.bilingualCopy)
        #expect(traps.isEmpty, "这些条把数量写成了「数字 + 复数名词」：\(traps)")
    }

    /// 加了 `static let` 却忘了登记进 `bilingualCopy` ⇒ 整条文案对门禁隐形（本仓那一族：
    /// 声明了没人管）。这条把"声明数 == 登记数"钉住，注释里的假声明不算（剥注释后数）。
    @Test("表里登记的条数 == 文件里声明的条数（漏登记会当场红）")
    func registeredCountMatchesDeclarations() throws {
        let code = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryUI/Files/FilesCopy.swift")
        let declared = code.split(separator: "\n").filter {
            $0.contains("static let") && $0.contains("LocalizedString(")
        }.count
        #expect(declared == FilesCopy.bilingualCopy.count,
                "声明 \(declared) 条、登记 \(FilesCopy.bilingualCopy.count) 条 ⇒ 有文案对门禁隐形")
    }

    /// 数量中性是**写法**保证的，不是断言保证的：拿 1 和 7 各渲染一次，
    /// 两边都必须读得通，且英文侧不许出现复数名词。
    @Test("计数那几条在 1 和 N 下都读得通（手推字面量）")
    func countBearingCopyIsQuantityNeutral() {
        #expect(FilesCopy.heroSubtitle.format(.chineseSimplified, "今天", 1) == "今天 · 共 1 个变更")
        #expect(FilesCopy.heroSubtitle.format(.english, "Today", 1) == "Today · 1 in total")
        #expect(FilesCopy.heroSubtitle.format(.english, "Today", 7) == "Today · 7 in total")
        // 复数尺子当场抓到的那两条，修后各钉 1 与 N 两档（防止"顺手改通顺"改回去）：
        #expect(FilesCopy.tileTotalCaption.format(.english, 1, "x") == "Events loaded: 1 · x")
        #expect(FilesCopy.tileTotalCaption.format(.english, 11, "x") == "Events loaded: 11 · x")
        #expect(FilesCopy.lineDelta.format(.english, "1", "1") == "Lines added 1, removed 1")
        #expect(FilesCopy.filterKindsSummary.format(.english, 1) == "Types · 1")
        #expect(FilesCopy.filterAgentsSummary.format(.english, 7) == "Agents · 7")
        for text in [FilesCopy.filterKindsSummary.format(.english, 3),
                     FilesCopy.filterAgentsSummary.format(.english, 3)] {
            #expect(!text.contains("types") && !text.contains("agents"),
                    "又写回了带复数名词的说法：\(text)")
        }
        // 常驻那一行的分隔符两边都是 ` · `，但计数段落语序不同 ⇒ 逐字钉住那一路。
        #expect(FilesCopy.coverageRoots.format(.chineseSimplified, 2) == "采集面：正在监控 2 个根")
        // 英文侧名词在数字**之前**（`roots watched 2`），所以 1 也读得通——
        // 复数尺子按"数字紧跟 s 结尾名词"的形状拦，这里给逐字期望而不是关键词否定。
        #expect(FilesCopy.coverageRoots.format(.english, 1) == "Capture: roots watched 1")
        #expect(FilesCopy.coverageRoots.format(.english, 2) == "Capture: roots watched 2")
    }
}
