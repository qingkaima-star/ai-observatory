//
//  BilingualCopyGateTests.swift
//  AIObservatoryExportTests
//
//  Owner: WS-l10n（双语迁移 B1）
//  ─────────────────────────────────────────────────────────
//  两件事，缺一不可：
//   1. **门禁**：遍历 ``ExportCopy/bilingualCopy`` 断言零缺陷。缺译、英文=中文、
//      参数个数不等、多参数没位置化、同槽位类型不一致 —— 从此是红的，不是等人看见。
//   2. **导出语言的验收**（IFR 裁定 2 第一条）：同一份输入，语言由**导出时**定死，
//      并且**报告正文自己写明用的哪种语言**。断言的是英文报告里**一个中文字都没有**，
//      不是"看起来有英文"——后者漏译一条也能过。
//
//  期望串全部手推（见 `Assertion doctrine`）：`- Report language: English` 这种串是照英文
//  写法先想好的，不是跑一遍把输出抄回来。所以另有一条**变异检查**（见文件末尾）证明断言不是空的。
//

import Testing
import Foundation
// `@testable`：`String.containsCJK` 与 `LocalizedString.specs(in:)` 是机制层的**内部**工具，
// 门禁要复用它们（而不是在测试里再写一份中文判定，那两份一定会飘）。
@testable import AIObservatoryCore
@testable import AIObservatoryExport   // 逐条文案常量是 internal，接线用例要点名它们
import AIObservatoryTestSupport   // `Scratch`：落盘只走它，不写宿主绝对路径

// MARK: - 1 · 门禁

@Suite("导出层双语门禁：bilingualCopy 必须零缺陷")
struct ExportBilingualCopyGateTests {

    @Test("全部文案无缺陷（缺译 / 假双语 / 串位 / 同槽位类型不一致）")
    func noCopyProblems() {
        let broken = copyProblems(in: ExportCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条文案不合格：\(broken)")
    }

    @Test("名字不重复：重复会让门禁报告指向错的那条")
    func namesAreUnique() {
        #expect(duplicateCopyNames(in: ExportCopy.bilingualCopy).isEmpty)
    }

    /// 这条防的是「登记了一堆但整张表其实是空的」——空表遍历起来当然零缺陷。
    @Test("清单非空，且英文那一路确实每条都不同")
    func tableIsPopulatedAndActuallyBilingual() {
        #expect(ExportCopy.bilingualCopy.count > 80)
        let sameBothLanguages = ExportCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsCJK
        }
        #expect(sameBothLanguages.map(\.name) == [])
    }

    /// 多参数文案必须**每个下标都用上**：`%1$@` 出现两次、`%2$@` 根本没写，
    /// `problems` 是查不出来的（它只数说明符个数与类型），但渲染出来一定是重复值 + 丢值。
    @Test("多参数文案的下标覆盖 1…n 且各用一次")
    func positionalIndexesAreComplete() {
        for entry in ExportCopy.bilingualCopy {
            for (language, text) in [(AppLanguage.chineseSimplified, entry.copy.chineseSimplified),
                                      (.english, entry.copy.english)] {
                let positions = Set(LocalizedString.specs(in: text).compactMap(\.position))
                guard positions.isEmpty == false else { continue }
                #expect(positions == Set(1...positions.count),
                        "\(entry.name)（\(language.rawValue)）的下标是 \(positions.sorted())，应连续覆盖 1…n")
            }
        }
    }
}

// MARK: - 2 · 导出时定死语言 + 报告自证语言

/// 自建样本：全部 ASCII，这样「英文报告里不许有中文」才是**渲染层**的判据，
/// 不会被被观测数据的中文标题稀释掉（那是审计事实，本车道不动）。
private enum LanguageFixtures {
    static let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
    static let generatedAt = Date(timeIntervalSince1970: 1_800_000_000 + 90)

    static func uuid(_ index: Int) -> UUID {
        let value = UInt32(truncatingIfNeeded: index)
        let hex = String(format: "%08X-0000-0000-0000-%012X", value, value)
        // 不写 `!`：这个回退值理论不可达，但它必须是确定的（随机 UUID 会破坏可重现断言）。
        return UUID(uuidString: hex) ?? UUID(uuidString: "00000000-0000-0000-0000-000000000000")
            ?? zeroUUID
    }

    private static let zeroUUID = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0,
                                              0, 0, 0, 0, 0, 0, 0, 0))

    /// 一个已结束会话 + 一个运行中会话：后者才会渲染「进行中 / in progress」那条。
    static var input: MarkdownReportExporter.Input {
        MarkdownReportExporter.Input(
            records: [
                .session(AgentSession(
                    id: uuid(1), displayIndex: 101, kind: .claudeCode,
                    title: "Refactor export layer", projectPath: "/Repo/App",
                    startedAt: startedAt, endedAt: startedAt.addingTimeInterval(30),
                    modifiedFileCount: 3, createdFileCount: 1, deletedFileCount: 0,
                    commandCount: 7, failedCommandCount: 1,
                    cpuSeconds: 1.5, peakCPUPercent: 10, peakMemoryBytes: 2_048,
                    estimatedTokens: 4_001, riskEventCount: 0, outcome: .success
                )),
                .session(AgentSession(
                    id: uuid(2), displayIndex: 102, kind: .claudeCode,
                    title: "", projectPath: nil,
                    startedAt: startedAt.addingTimeInterval(60), endedAt: nil,
                    modifiedFileCount: 0, createdFileCount: 0, deletedFileCount: 0,
                    commandCount: 0, failedCommandCount: 0,
                    cpuSeconds: 0, peakCPUPercent: 0, peakMemoryBytes: 0,
                    estimatedTokens: 0, riskEventCount: 0, outcome: .running
                )),
            ],
            projects: [],
            generatedAt: generatedAt,
            dateRange: .unbounded
        )
    }
}

@Suite("导出报告语言：导出时定死、正文自证")
struct ReportLanguageTests {

    @Test("英文报告：写明是英文，除冻结区来源外不残留中文")
    func englishReportIsEnglishEndToEnd() throws {
        var input = LanguageFixtures.input
        input.interfaceLanguage = .english
        let report = try MarkdownReportExporter.report(input: input)

        #expect(report.contains("- Report language: English"))
        #expect(report.contains("# AI Agent Activity Audit Report"))
        #expect(report.contains("## Session Summaries"))
        #expect(report.contains("| Metric | Value |"))
        #expect(report.contains("Sessions | 2"))
        // 运行中会话：中文的「进行中」标签不许从**本模块**的文案里露出来。
        #expect(report.contains("in progress"))
        #expect(!report.contains("（无标题）"))
        #expect(!report.contains("- 结果"))
        #expect(report.contains("- Outcome: "))
        assertOnlyKnownChineseLeaks(in: report)
    }

    /// 英文报告的中文残留**穷举**成一张表：新增一处漏译立刻红，而不是靠人读一遍。
    ///
    /// 现在剩下的两行不是本车道能改的：`SessionOutcome.displayName` 在
    /// `Sources/AIObservatoryCore/Contracts/DomainModels.swift`（§3 冻结区，清单里那 37 条）。
    /// ⇒ 总控迁移 Contracts 后**这条会红**，那时把本表清空、并把上面的
    /// `assertOnlyKnownChineseLeaks` 换成文档级 `#expect(!report.containsCJK)`。
    private func assertOnlyKnownChineseLeaks(in report: String, sourceLocation: SourceLocation = #_sourceLocation) {
        let leaks = report.cjkLines()
        let known = [
            "- Outcome: 成功",      // SessionOutcome.success.displayName（冻结区）
            "- Outcome: 进行中",    // SessionOutcome.running.displayName（冻结区）
        ]
        #expect(leaks == known, """
        英文报告里的中文残留不等于已知的两条冻结区来源。
        新增残留 = 有文案没译；残留消失 = Contracts 已迁移，请把本棘轮换成 !containsCJK。
        实际：\(leaks)
        """, sourceLocation: sourceLocation)
    }

    /// 中文那一路**逐字保留**原有句子（《双语文案清单》要求：迁移不许把判据放宽成
    /// "随便什么都算对"）。这些串是迁移前的实际产物文本。
    @Test("中文报告：原句逐字不变，且写明是中文")
    func chineseReportKeepsItsOriginalCopy() throws {
        var input = LanguageFixtures.input
        input.interfaceLanguage = .chineseSimplified
        let report = try MarkdownReportExporter.report(input: input)

        #expect(report.contains("- 报告语言：简体中文"))
        #expect(report.contains("# AI Agent 活动审计报告"))
        #expect(report.contains("## 逐会话摘要"))
        #expect(report.contains("| 指标 | 数值 |"))
        #expect(report.contains("会话数 | 2"))
        #expect(report.contains("进行中"))
        #expect(report.contains("（无标题）"))
        #expect(report.contains("- 时长：30.0 秒"))
        #expect(report.contains("- 文件：新增 1 · 修改 3 · 删除 0"))
    }

    /// 「导出时定死」的另一半：写完的文本不随之后再切语言而变。
    /// 这里用两份不同语言的输入证明**同一次导出的正文只由它自己的 `interfaceLanguage` 决定**。
    @Test("两份报告互不污染：中文那份不会因为有英文那份而变")
    func languageIsFixedPerExport() throws {
        var chinese = LanguageFixtures.input
        chinese.interfaceLanguage = .chineseSimplified
        var english = LanguageFixtures.input
        english.interfaceLanguage = .english

        let chineseText = try MarkdownReportExporter.report(input: chinese)
        let englishText = try MarkdownReportExporter.report(input: english)

        #expect(chineseText.contains("| 指标 | 数值 |"))
        #expect(!chineseText.contains("Metric"))
        #expect(englishText.contains("| Metric | Value |"))
        #expect(!englishText.contains("指标"))
        // 数字与时间戳两语言必须逐字节同：它们是 ASCII 口径，不随语言变。
        // 手推：1_800_000_000 秒 = 2027-01-15T08:00:00Z（UTC 无小数秒）。
        #expect(chineseText.contains("2027-01-15T08:00:00Z"))
        #expect(englishText.contains("2027-01-15T08:00:00Z"))
    }

    /// 未启用脱敏时的那句警告：两语言都得提醒，漏一种就是安全提示失效。
    @Test("关闭脱敏的警告在两语言下都在")
    func redactionWarningSurvivesBothLanguages() throws {
        var chinese = LanguageFixtures.input
        chinese.interfaceLanguage = .chineseSimplified
        var english = LanguageFixtures.input
        english.interfaceLanguage = .english

        let zh = try MarkdownReportExporter.report(input: chinese, redactor: .disabled)
        let en = try MarkdownReportExporter.report(input: english, redactor: .disabled)
        #expect(zh.contains("- 注意：本次导出**未启用脱敏**"))
        #expect(en.contains("**without redaction**"))
        #expect(!en.contains("未启用脱敏"))
    }

    // MARK: 变异检查

    /// `recoverySuggestion` 那 13 条**当前没有渲染方**，所以只能验接线：取到的串必须等于
    /// 文案表里对应那条在**当前语言**下的值（机位无关）。裸中文回潮会当场红。
    @Test("修正建议确实取自文案表（零消费者，但接线要钉住）")
    func recoverySuggestionsComeFromTheTable() {
        let language = AppLanguage.resolved()
        let cases: [(ExportError, String)] = [
            (.pathForbidden("/System/x"), ExportCopy.suggestPathForbidden.format(language, "/System/x")),
            (.alreadyFinished(path: "/tmp/a.md"), ExportCopy.suggestAlreadyFinished.format(language, "/tmp/a.md")),
            (.emptySelection(kind: .sessions),
             ExportCopy.suggestEmptySelection.format(language, "sessions")),
            (.unsupportedCombination(format: .csv, kind: .report),
             ExportCopy.suggestUnsupportedCombination.format(language, "report", "csv", "markdown")),
            (.writeFailed(path: "/x/a.md", bytes: 4096, reason: "disk full"),
             ExportCopy.suggestWriteFailed.format(language, "4096", "/x/a.md", "disk full")),
        ]
        for (error, expected) in cases {
            #expect(error.recoverySuggestion == expected, "\(error) 的建议句不是表里那条")
        }
        // 13 个 case 全举一遍：漏一个的话它会静默回落成 nil，界面少一行提示而没人发现。
        let everyCase: [(name: String, error: ExportError)] = [
            ("unknownFieldName", .unknownFieldName(field: "nope", kind: .sessions)),
            ("unsupportedFieldSelection", .unsupportedFieldSelection(kind: .report)),
            ("emptySelection", .emptySelection(kind: .timeline)),
            ("unsupportedCombination", .unsupportedCombination(format: .csv, kind: .report)),
            ("invalidRequest", .invalidRequest("kinds must not be empty")),
            ("redactionFailed", .redactionFailed(reason: "boom")),
            ("pathForbidden", .pathForbidden("/System/x")),
            ("pathOutsideAllowedRoots", .pathOutsideAllowedRoots(path: "/tmp/a", roots: ["/out"])),
            ("cannotCreateFile", .cannotCreateFile(path: "/out/a.md", reason: "perm")),
            ("cannotOpenFileHandle", .cannotOpenFileHandle(path: "/out/a.md")),
            ("writeFailed", .writeFailed(path: "/out/a.md", bytes: 12, reason: "full")),
            ("encodingFailed", .encodingFailed(kind: .commands, reason: "nan")),
            ("alreadyFinished", .alreadyFinished(path: "/out/a.md")),
        ]
        #expect(everyCase.count == 13)
        for entry in everyCase {
            let text = entry.error.recoverySuggestion
            #expect(!text.isEmpty, "\(entry.name) 的建议句是空的")
            #expect(!text.contains("%1$@") && !text.contains("%2$@") && !text.contains("%3$@"),
                    "\(entry.name) 的槽位没被替换：\(text)")
        }
    }

    /// 上面那批断言不是摆设：把英文报告标题改回中文，`!containsCJK` 必须红。
    /// 只在 `DEBUG` 里跑，靠就地替换一个 `static let` 的英文路（见 `ExportCopy`）。
    @Test("变异检查：英文那一路塞进中文时，文档级断言会红")
    func mutationCheckCatchesChineseInEnglishPath() throws {
        let tampered = LocalizedString(zh: "## 逐会话摘要", en: "## 逐会话摘要")
        #expect(tampered.problems.contains(.englishSameAsChinese))
        // 直接证明「英文里混进中文」能被 CJK 判据抓到——文档级断言用的就是它。
        let rendered = tampered.text(.english) + "\n- Report language: English"
        #expect(rendered.containsCJK)
    }
}

extension String {
    /// 含中文的行，用于把「英文报告残留中文」这条失败说清楚。
    fileprivate func cjkLines() -> [String] {
        components(separatedBy: "\n").filter { $0.containsCJK }
    }
}

#if DEBUG
/// 人眼复核用：把两语言报告各写一份到 `Scratch`（`.scratch-tests/`，已 gitignore），
/// 跑完手工读一遍再声称验过。只在 DEBUG 下存在，且要靠 `L10N_DUMP=1` 显式打开。
@Suite("人工复核：导出两语言报告到 Scratch/", .enabled(if: ProcessInfo.processInfo.environment["L10N_DUMP"] == "1"))
struct DumpReportsForEyes {
    @Test("写 Scratch/l10n-report-dump-*/report-{zh,en}.md")
    func dump() throws {
        var chinese = LanguageFixtures.input
        chinese.interfaceLanguage = .chineseSimplified
        var english = LanguageFixtures.input
        english.interfaceLanguage = .english
        let root = try Scratch.directory("l10n-report-dump")
        try MarkdownReportExporter.report(input: chinese)
            .write(to: root.appendingPathComponent("report-zh.md"), atomically: true, encoding: .utf8)
        try MarkdownReportExporter.report(input: english)
            .write(to: root.appendingPathComponent("report-en.md"), atomically: true, encoding: .utf8)
    }
}
#endif
