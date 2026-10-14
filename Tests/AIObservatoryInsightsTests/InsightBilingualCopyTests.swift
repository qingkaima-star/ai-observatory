//
//  InsightBilingualCopyTests.swift
//  AIObservatoryInsightsTests
//
//  Owner: WS-l10n（双语迁移 B1）
//  ─────────────────────────────────────────────────────────
//  两件事：
//   1. 门禁 —— 遍历 ``InsightCopy/bilingualCopy`` 断言零缺陷（缺译 / 假双语 / 串位）。
//   2. **每个产「依据句」的公开入口，英文下真的产出英文**。依据句是本模块唯一用户
//      读得到的东西（卡片下面那句「为什么这个数可以信」），所以逐个入口跑，
//      不是抽一条代表全部。
//
//  同时钉住中文那一路：这些句子是 #30 那类「逐字断言上屏文案」的判据来源，
//  迁移不许把它们放宽成"随便什么都算对"。
//

import Testing
import Foundation
@testable import AIObservatoryCore
@testable import AIObservatoryInsights   // `InsightCopy` 的逐条常量在门禁表之外是 internal

// MARK: - 1 · 门禁

@Suite("分析层双语门禁")
struct InsightBilingualCopyGateTests {

    @Test("全部文案无缺陷")
    func noCopyProblems() {
        let broken = copyProblems(in: InsightCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: InsightCopy.bilingualCopy).isEmpty)
    }

    @Test("清单非空且每条都真的译了")
    func tablePopulated() {
        #expect(InsightCopy.bilingualCopy.count > 50)
        let untranslated = InsightCopy.bilingualCopy.filter {
            $0.copy.english == $0.copy.chineseSimplified && $0.copy.chineseSimplified.containsCJK
        }
        #expect(untranslated.map(\.name) == [])
    }

    @Test("多参数文案的下标连续覆盖 1…n")
    func positionalIndexesComplete() {
        for entry in InsightCopy.bilingualCopy {
            for (language, text) in [(AppLanguage.chineseSimplified, entry.copy.chineseSimplified),
                                      (.english, entry.copy.english)] {
                let positions = Set(LocalizedString.specs(in: text).compactMap(\.position))
                guard positions.isEmpty == false else { continue }
                #expect(positions == Set(1...positions.count),
                        "\(entry.name)（\(language.rawValue)）下标 \(positions.sorted()) 不连续")
            }
        }
    }
}

// MARK: - 2 · 依据句两语言实跑

@Suite("分析层依据句：中英各跑一遍")
struct InsightBasisLanguageTests {

    private let reference = InsightFixtures.hours(6)

    /// 每个入口各造一份**能出依据句**的输入（空输入会走另一条分支，测不到拼装）。
    private func englishAndChineseBasis(
        _ make: (AppLanguage) -> String
    ) -> (english: String, chinese: String) {
        (make(.english), make(.chineseSimplified))
    }

    @Test("热文件依据句")
    func hotFileBasis() {
        let (en, zh) = englishAndChineseBasis { language in
            FileHotnessScorer.score(
                changes: InsightFixtures.changes(count: 3, start: InsightFixtures.epoch, step: 600),
                referenceDate: reference,
                interfaceLanguage: language
            ).first?.basis ?? ""
        }
        // 手推：changes(count: 3) 是**三个不同文件**各 1 次改动 ⇒ 每个文件的依据句是 1 次改动。
        #expect(en == "changes: 1 · agents: 1 · days since last change: 0.2 · effective edits: 1.00")
        #expect(!en.containsCJK)
        #expect(zh == "1 次改动 · 1 个 Agent · 距今 0.2 天 · 有效改动数 1.00")
        #expect(zh.contains("有效改动数"))
    }

    @Test("参与度依据句")
    func contributionBasis() {
        let (en, zh) = englishAndChineseBasis { language in
            ContributionRatioAnalyzer.analyze(
                agentChanges: InsightFixtures.changes(count: 4, start: InsightFixtures.epoch, step: 300),
                humanChanges: nil,
                referenceDate: reference,
                interfaceLanguage: language
            ).basis
        }
        #expect(en.contains("changes in total: 4"))
        #expect(en.contains("human share cannot be estimated (no human baseline supplied)"))
        #expect(!en.containsCJK)
        // 可信性那条口径不许因为翻译而丢：没有人工基线就必须明写不可估计。
        #expect(zh.contains("人工占比不可估计（未提供人工基线）"))
    }

    @Test("代码增长依据句")
    func codeGrowthBasis() {
        let (en, zh) = englishAndChineseBasis { language in
            CodeGrowthEstimator.summarize(
                changes: InsightFixtures.changes(count: 2, start: InsightFixtures.epoch, step: 60,
                                                 added: 5, removed: 2),
                windowStart: InsightFixtures.epoch,
                windowEnd: reference,
                bucketSeconds: 3_600,
                interfaceLanguage: language
            ).basis
        }
        #expect(en.contains("lines net: +6 (+10/−4)"))   // 手推：2 条 × (+5/−2)
        #expect(en.contains("files: 2"))
        #expect(!en.containsCJK)
        #expect(zh.contains("净增 +6 行（+10/−4）"))
        #expect(zh.contains("趋势"))
    }

    @Test("命令产量依据句")
    func throughputBasis() {
        let (en, zh) = englishAndChineseBasis { language in
            CommandThroughputAnalyzer.summarize(
                commands: [
                    InsightFixtures.command(startedAt: InsightFixtures.epoch,
                                            endedAt: InsightFixtures.minutes(1), outcome: .success, exitCode: 0),
                    InsightFixtures.command(startedAt: InsightFixtures.hours(1),
                                            endedAt: InsightFixtures.hours(1) + 30, outcome: .failure, exitCode: 1),
                ],
                windowStart: InsightFixtures.epoch,
                windowEnd: reference,
                interfaceLanguage: language
            ).basis
        }
        // 手推：2 条 / 6 小时 = 0.333 → 0.3；1 成功 1 失败 ⇒ 已判定 2、成功率 50.00%
        #expect(en == "commands per hour: 0.3 · commands: 2 · succeeded: 1 of 2 resolved (50.00%) · failed: 1 · p95 duration 58.50 s (2/2 timed)")
        #expect(!en.containsCJK)
        #expect(zh.contains("成功 1/已判定 2"))
        #expect(zh.contains("失败 1"))
    }

    @Test("异常检测依据句：样本不足与正常路径都跑")
    func anomalyBasis() {
        let shortSeries = [1.0, 2.0, 3.0]
        let longSeries = (0..<12).map { Double($0) }
        let starts = (0..<12).map { InsightFixtures.minutes(Double($0 * 2)) }

        let insufficient = AnomalyDetector.detect(
            values: shortSeries, metric: .eventRate, bucketStarts: nil, bucketSeconds: 120,
            interfaceLanguage: .english
        )
        #expect(insufficient.skippedReason == "sample count 3 is below the minimum of 8, so nothing is judged")
        #expect(!(insufficient.skippedReason?.containsCJK ?? false))
        #expect(!(insufficient.basis.containsCJK))
        #expect(insufficient.basis.contains("baseline"))

        let judged = AnomalyDetector.detect(
            values: longSeries, metric: .eventRate, bucketStarts: starts, bucketSeconds: 120,
            interfaceLanguage: .english
        )
        #expect(judged.basis == "baseline 5.50 ± 3.45 (n=12, threshold 3.0σ) · no anomalous bucket found")

        let zh = AnomalyDetector.detect(
            values: shortSeries, metric: .eventRate, bucketStarts: nil, bucketSeconds: 120,
            interfaceLanguage: .chineseSimplified
        )
        #expect(zh.skippedReason == "样本量 3 不足 8，不做异常判定")
        // 指标名也跟着语言：`每分钟事件数` 是同一指标的另一半显示文本。
        #expect(AnomalyMetric.eventRate.displayName.count > 0)
    }

    @Test("效率对比依据句：只有一个 Agent 时如实说明未排名，且句末不叠句号")
    func efficiencyBasis() {
        let sessions = [InsightFixtures.session(.claudeCode, startedAt: InsightFixtures.epoch,
                                                endedAt: InsightFixtures.hours(1), cpuSeconds: 30,
                                                commandCount: 4, failedCommandCount: 1)]
        let changes = InsightFixtures.changes(count: 2, start: InsightFixtures.epoch, step: 60)
        let commands = [InsightFixtures.command(startedAt: InsightFixtures.epoch,
                                                endedAt: InsightFixtures.minutes(2))]

        let en = AgentEfficiencyComparator.compare(
            sessions: sessions, changes: changes, commands: commands,
            referenceDate: reference, interfaceLanguage: .english
        ).basis
        #expect(en.hasPrefix("agents compared: 1 (sessions 1 · changes 2 · commands 1): Claude Code: active 3600.0 s · files 2"))
        #expect(en.contains("active 3600.0 s"))
        #expect(en.contains("too few agents to rank"))
        #expect(en.hasSuffix(")."))
        #expect(!en.containsCJK)

        let zh = AgentEfficiencyComparator.compare(
            sessions: sessions, changes: changes, commands: commands,
            referenceDate: reference, interfaceLanguage: .chineseSimplified
        ).basis
        #expect(zh.contains("对比 1 类 Agent"))
        #expect(zh.contains("缺少可对照的 Agent（产出率可比 Agent 1 个、单文件成本可比 Agent 1 个，均需 ≥ 2）"))
        #expect(zh.hasSuffix("排名。"))
        // 迁移前这里是「排名。。」：段文案自带句号，join 后又补一个。
        #expect(!zh.contains("。。"), "句末句号重复，说明段文案与拼装处又各写了一个")
    }

    @Test("项目健康摘要依据句")
    func healthSummaryBasis() {
        func make(_ language: AppLanguage) -> String {
            ProjectHealthAnalyzer.summarize(
                projectName: "App", projectPath: "/Repo/App",
                changes: InsightFixtures.changes(count: 3, start: InsightFixtures.epoch, step: 600,
                                                 added: 4, removed: 1),
                commands: [InsightFixtures.command(startedAt: InsightFixtures.epoch,
                                                   endedAt: InsightFixtures.minutes(3))],
                events: [InsightFixtures.event(at: InsightFixtures.epoch)],
                systemSamples: [InsightFixtures.sample(at: InsightFixtures.epoch, cpu: 40)],
                sessions: [InsightFixtures.session(.claudeCode, startedAt: InsightFixtures.epoch,
                                                   endedAt: InsightFixtures.hours(1))],
                riskEvents: [InsightFixtures.risk(.high)],
                windowStart: InsightFixtures.epoch,
                windowEnd: reference,
                referenceDate: reference,
                interfaceLanguage: language
            ).basis
        }
        let en = make(.english)
        #expect(en.hasPrefix("hot files: 3"))
        #expect(en.contains("participation — agents: 1 (human share cannot be estimated)"))
        #expect(en.contains("overall confidence:"))
        #expect(!en.containsCJK)
        let zh = make(.chineseSimplified)
        #expect(zh.contains("热度文件 3 个"))
        #expect(zh.contains("整体置信度"))
    }

    /// 标签类（趋势 / 指标 / 判定）**没有语言参数**：`displayName` 读进程语言，
    /// 所以断言不能写死成某一种语言（英文 CI runner 上会假红），而要验**它指对了文案**：
    /// 取到的串 == 表里对应那条在当前语言下的值。
    @Test("标签确实从文案表取，且两路都在表里")
    func labelsComeFromTheTable() {
        let language = AppLanguage.resolved()
        #expect(InsightTrend.rising.displayName == InsightCopy.trendRising.text(language))
        #expect(InsightTrend.flat.displayName == InsightCopy.trendFlat.text(language))
        #expect(InsightTrend.falling.displayName == InsightCopy.trendFalling.text(language))
        // 「样本不足」与「持平」是两条不同结论，表里也必须是两条不同文案。
        #expect(InsightTrend.unknown.displayName == InsightCopy.trendUnknown.text(language))
        #expect(InsightCopy.trendUnknown.english != InsightCopy.trendFlat.english)
        #expect(AnomalyMetric.eventRate.displayName == InsightCopy.metricEventRate.text(language))
        #expect(AnomalyMetric.cpuLoad.displayName == InsightCopy.metricCPULoad.text(language))
        #expect(InsightOutcome.unresolved.displayName == InsightCopy.outcomeUnresolved.text(language))
        #expect(InsightOutcome.succeeded.displayName == InsightCopy.outcomeSucceeded.text(language))
        // 另一路也必须真的存在（假双语由门禁那条统一拦，这里只钉「两路不同」）。
        #expect(InsightCopy.trendRising.text(.english) != InsightCopy.trendRising.text(.chineseSimplified))
        #expect(InsightCopy.metricDeletionRate.text(.english) == "lines deleted per minute")
        #expect(InsightCopy.metricDeletionRate.text(.chineseSimplified) == "每分钟删除行数")
        #expect(InsightCopy.outcomeFailed.text(.english) == "failed")
    }
}
