//
//  SelfProcessGaugeTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uiclose · #29）
//  ─────────────────────────────────────────────────────────
//  守的是判据④「界面自证」那一格的算术与口径。
//  期望值全部**手推**（算式写在每条断言上方的注释里），不用被测代码再算一遍当期望。
//  浮点刻意挑**二进制精确**的组合：Δcputime 与墙钟都取 2 的幂可表示的值
//  （如 0.5 / 16 ⇒ 0.03125，×100 ⇒ 3.125），这样数值断言可以是 `==` 而不是近似。
//
//  写法注记：`#expect(gauge.record(...))` 编不过——Swift Testing 的宏把实参按**不可变**捕获，
//  而 `record` 是 mutating 方法（实测报 `cannot use mutating member on immutable value: '$0' is immutable`）。
//  所以「有没有被接受」先落到局部变量再断言，其余调用点用 `_ =` 显式丢弃返回值（本仓警告预算是 0）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

/// `n MiB` 的字节数。1 MiB = 1_048_576 字节（与 `PerformanceUnits.bytesPerMB` 同一把尺）。
/// 用例里的 MB 全取整数，换算回去才是**精确**的：88.8 MiB 那种值转字节再转回来会差在小数第 4 位。
private func mib(_ n: Double) -> UInt64 { UInt64(n * 1_048_576) }

private func reading(_ seconds: TimeInterval, cpuSeconds: Double, footprintMB: Double) -> SelfProcessSamplePoint {
    SelfProcessSamplePoint(footprintBytes: mib(footprintMB), cpuSeconds: cpuSeconds, takenAt: at(seconds))
}

@Suite("UI: 本进程开销 · 窗口算术", .timeLimit(.minutes(1)))
struct SelfProcessGaugeWindowTests {

    @Test("CPU% = Δcputime ÷ 墙钟 × 100；末值取最新，峰值取最大")
    func windowArithmetic() throws {
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 10.0, footprintMB: 80))
        _ = gauge.record(reading(8, cpuSeconds: 10.25, footprintMB: 100))
        _ = gauge.record(reading(16, cpuSeconds: 10.5, footprintMB: 90))
        // 三条都该被接受（间隔 8 秒 ≥ 下限 5 秒，跨度 16 秒 < 窗口 180 秒）
        #expect(gauge.readings.count == 3)

        let overhead = try #require(gauge.overhead)
        // (10.5 - 10.0) / (16 - 0) × 100 = 0.5 / 16 × 100 = 3.125（二进制精确）
        #expect(overhead.cpuPercent == 3.125)
        // 末值口径：判据④ 的「常驻」看最新一次读数，不是最大值（ADR-0009 裁定 5）
        #expect(overhead.footprintMB == 90.0)
        // 峰值口径：三条里最大的一条，不能被末值盖掉
        #expect(overhead.peakFootprintMB == 100.0)
        #expect(overhead.sampleCount == 3)
        #expect(overhead.durationSeconds == 16.0)
        // 平均间隔 = 16 / (3 - 1) = 8
        #expect(overhead.averageGapSeconds == 8.0)
    }

    @Test("余量给两个数：末值一个、窗口峰值一个（只看末值是半个结论）")
    func headroomUsesBothStats() throws {
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 1, footprintMB: 100))
        _ = gauge.record(reading(8, cpuSeconds: 1.5, footprintMB: 200))
        _ = gauge.record(reading(16, cpuSeconds: 2, footprintMB: 100))
        let overhead = try #require(gauge.overhead)
        // (200 - 100) / 200 × 100 = 50
        #expect(overhead.headroomPercent(limitMB: 200) == 50.0)
        // (200 - 200) / 200 × 100 = 0 —— 同一窗口按峰值算已经没有余量了
        #expect(overhead.peakHeadroomPercent(limitMB: 200) == 0.0)
    }

    @Test("一条读数给不出占用率：CPU 是 nil，footprint 照给，不填 0")
    func singleReadingHasNoCPURate() throws {
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 42, footprintMB: 90))
        let overhead = try #require(gauge.overhead)
        #expect(overhead.cpuPercent == nil)
        #expect(overhead.footprintMB == 90.0)
        #expect(overhead.averageGapSeconds == nil)
        // 关键：读不出占用率时不能落到「0% ≤ 3% ⇒ 在预算内」那条假达标路径上
        #expect(overhead.cpuVerdict(budgetPercent: 3, windowFloorSeconds: 60) == .windowForming(seconds: 0))
    }

    @Test("累计 CPU 倒退时不给负占用率，也不给 0% 假达标")
    func cpuRegressionIsNotZeroPercent() throws {
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 10.0, footprintMB: 90))
        _ = gauge.record(reading(60, cpuSeconds: 9.5, footprintMB: 90))
        let overhead = try #require(gauge.overhead)
        #expect(overhead.cpuPercent == nil)
        #expect(overhead.cpuVerdict(budgetPercent: 3, windowFloorSeconds: 60) == .windowForming(seconds: 60))
    }

    @Test("间隔不足最小采样的读数被丢弃，窗口里每条间隔都 ≥5 秒")
    func subIntervalReadingsRejected() throws {
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 1, footprintMB: 90))
        // 引擎节拍 3 秒 < 5 秒下限 ⇒ 这条不该进窗口（否则一格会被推送频率灌出几百条读数）
        let tooSoon = gauge.record(reading(3, cpuSeconds: 1.1, footprintMB: 90))
        #expect(tooSoon == false)
        _ = gauge.record(reading(6, cpuSeconds: 1.2, footprintMB: 91))
        #expect(gauge.readings.count == 2)
        let overhead = try #require(gauge.overhead)
        #expect(overhead.windowStart == at(0))
        #expect(overhead.windowEnd == at(6))
    }

    @Test("滑出 180 秒窗口的旧读数被裁掉，窗口跨度不超过 180 秒")
    func windowTrimsOldData() throws {
        var gauge = SelfProcessGauge()
        for seconds in stride(from: 0.0, through: 270.0, by: 90.0) {
            _ = gauge.record(reading(seconds, cpuSeconds: 1 + seconds / 100, footprintMB: 90))
        }
        let overhead = try #require(gauge.overhead)
        // 最新读数在 270 秒 ⇒ 下界 270 - 180 = 90 秒，0 秒那条出局，留下 90/180/270
        #expect(overhead.sampleCount == 3)
        #expect(overhead.windowStart == at(90))
        #expect(overhead.durationSeconds == 180.0)
    }

    @Test("反复采样不重建窗口：起点仍是第一次被接受的那个时刻")
    func windowSurvivesRepeatedRefresh() throws {
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 10.0, footprintMB: 90))
        _ = gauge.record(reading(60, cpuSeconds: 11.0, footprintMB: 92))
        _ = gauge.record(reading(120, cpuSeconds: 12.0, footprintMB: 94))
        let overhead = try #require(gauge.overhead)
        // 若有人把来源改成「每次刷新新建一个」，起点会跳到 120 秒，
        // 那一格就永远停在「窗口未成形」——判据④ 的界面自证当场失效。
        #expect(overhead.windowStart == at(0))
        #expect(overhead.sampleCount == 3)
        // (12.0 - 10.0) / 120 × 100 = 1.666…% → 打印两位小数是 1.67
        #expect(overhead.cpuPercent.map { String(format: "%.2f", $0) } == "1.67")
    }
}

@Suite("UI: 本进程开销 · 达标判定与口径文案", .timeLimit(.minutes(1)))
struct SelfProcessOverheadCopyTests {

    /// 一个已成形 180 秒、CPU 1.1%、末值 95 MB 的窗口。
    /// Δcputime 2.0 秒 / 墙钟 180 秒 × 100 = 1.111…% → 打印一位小数「1.1」。
    private func formedOverhead() throws -> SelfProcessOverhead {
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 10.0, footprintMB: 90))
        _ = gauge.record(reading(180, cpuSeconds: 12.0, footprintMB: 95))
        return try #require(gauge.overhead)
    }

    @Test("静默窗 + 双侧达标：结论句逐字对账")
    func quietWindowWithinBudget() throws {
        let line = SelfProcessOverheadCopy.verdictNote(
            try formedOverhead(), cpuBudgetPercent: 3, memoryLimitMB: 200, load1m: 0.8,
            .chineseSimplified
        )
        #expect(line == "空闲 CPU 预算 3%：实测 1.1% → 在预算内。常驻上限 200 MB：末值 95.0 MB → 在预算内。")
    }

    @Test("非静默窗时必须自降为临时样本（AGENTS.md §6：load 5–12 的绝对值不是结论）")
    func busyMachineDowngradesTheCPUClaim() throws {
        let line = SelfProcessOverheadCopy.verdictNote(
            try formedOverhead(), cpuBudgetPercent: 3, memoryLimitMB: 200, load1m: 8.4,
            .chineseSimplified
        )
        #expect(line == "空闲 CPU 预算 3%：实测 1.1% → 在预算内。常驻上限 200 MB：末值 95.0 MB → 在预算内。"
            + " 本机负载 8.4，不是静默窗——CPU 这个数只作临时样本，不进判定列。")
    }

    @Test("没有整机采样时不许声称「静默窗实测」")
    func unknownLoadIsNotClaimedQuiet() throws {
        let line = SelfProcessOverheadCopy.verdictNote(
            try formedOverhead(), cpuBudgetPercent: 3, memoryLimitMB: 200, load1m: nil,
            .chineseSimplified
        )
        #expect(line.contains("还没有整机采样，无法确认是否静默窗"))
    }

    @Test("超预算要明写「超预算」，而不是丢个数让人自己去比")
    func overBudgetSaysSo() throws {
        // Δcputime 12.06 秒 / 180 秒 × 100 = 6.7% —— ADR-0009 那条非静默窗实测值
        var cpuGauge = SelfProcessGauge()
        _ = cpuGauge.record(reading(0, cpuSeconds: 10.0, footprintMB: 90))
        _ = cpuGauge.record(reading(180, cpuSeconds: 22.06, footprintMB: 90))
        let cpuLine = SelfProcessOverheadCopy.verdictNote(
            try #require(cpuGauge.overhead), cpuBudgetPercent: 3, memoryLimitMB: 200, load1m: 0.5,
            .chineseSimplified
        )
        #expect(cpuLine.contains("实测 6.7% → 超预算"))

        // 236 MB > 200 MB：ADR-0009 裁定 4 那台跑了 1 小时 49 分的实例
        var memGauge = SelfProcessGauge()
        _ = memGauge.record(reading(0, cpuSeconds: 10.0, footprintMB: 236))
        _ = memGauge.record(reading(180, cpuSeconds: 12.0, footprintMB: 236))
        let memLine = SelfProcessOverheadCopy.verdictNote(
            try #require(memGauge.overhead), cpuBudgetPercent: 3, memoryLimitMB: 200, load1m: 0.5,
            .chineseSimplified
        )
        #expect(memLine.contains("末值 236.0 MB → 超预算"))
    }

    @Test("窗口不足 60 秒时 CPU 不下判定，内存那一半照判")
    func shortWindowJudgesMemoryOnly() throws {
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 10.0, footprintMB: 90))
        _ = gauge.record(reading(47, cpuSeconds: 10.5, footprintMB: 95))
        let line = SelfProcessOverheadCopy.verdictNote(
            try #require(gauge.overhead), cpuBudgetPercent: 3, memoryLimitMB: 200, load1m: 0.5,
            .chineseSimplified
        )
        // 0.5 / 47 × 100 = 1.0638…% → 「1.1」；窗口 47 秒 < 60 秒 ⇒ CPU 不判
        #expect(line == "空闲 CPU 预算 3%：实测 1.1% → 窗口仅 47 秒，暂不判定。"
            + "常驻上限 200 MB：末值 95.0 MB → 在预算内。 需窗口 ≥60 秒才判。")
    }

    @Test("窗口说明句带跨度、读数个数与**实测**节拍（不是写死的秒数）")
    func windowNoteCarriesSpanAndMeasuredCadence() {
        // .demo：跨度 168 秒、15 个读数 ⇒ 平均 168 / 14 = 12 秒一采
        let note = SelfProcessOverheadCopy.windowNote(
            .demo, now: Date(timeIntervalSince1970: 1_700_000_168 + 45), .chineseSimplified
        )
        #expect(note.hasPrefix("测量窗口 "))
        #expect(note.contains("（2m48s · 15 个读数 · 平均 12 秒一采，末次读数在 45s 前）"))
    }

    @Test("三条口径一条都不能少：phys_footprint、峰值、本进程 vs 进程树")
    func theThreeCalibersAreAllPresent() {
        let scope = SelfProcessOverheadCopy.scopeNote(.chineseSimplified)
        #expect(scope.contains("RUSAGE_SELF"))
        #expect(scope.contains("子孙进程"))
        let pending = PerformanceMetricTile.pending(.chineseSimplified)
        // 内存那一格明写不是 RSS（同刻实测 RSS 189.6 MB vs footprint 88.8 MB）
        #expect(pending[1].caption == "不是 RSS")
        #expect(pending[1].title == "常驻 phys_footprint")
        // 峰值单独成格
        #expect(pending[3].title == "窗口内峰值")
        #expect(SelfProcessOverheadCopy.notInstrumentedNote(
            cpuBudgetPercent: 3, memoryLimitMB: 200, memoryTargetMB: 120, .chineseSimplified
        ) == "界面尚未接入本进程读数：目标值仍是硬指标（空闲 CPU < 3%、常驻 < 200 MB、"
            + "期望 < 120 MB），但这一格现在没有实测——"
            + "仪器在 AIObservatoryPlatform 已就绪，缺的是把它交给界面的那一条装配（ICR-0003）。")
    }

    /// 判据④ 的三条口径句在英文侧**逐字**是什么（手推字面量，不是跑一遍抄回来的）。
    /// 为什么值得单独钉：英文态真机验证的人拿这三句判「这一格是否仍可核对」，
    /// 翻成 "not resident size" 或把 "reported, not judged" 丢掉都不会让中文侧任何用例红。
    @Test("判据④ 三条口径句的英文侧：不是 RSS / 需窗口 ≥60 秒才判 / 峰值只报不判")
    func calibersSurviveInEnglish() throws {
        let line = SelfProcessOverheadCopy.verdictNote(
            try formedOverhead(), cpuBudgetPercent: 3, memoryLimitMB: 200, load1m: 0.8, .english
        )
        #expect(line == "Idle CPU budget 3%: measured 1.1% → within budget. "
            + "Resident cap 200 MB: last value 95.0 MB → within budget.")
        // 短窗那条：英文也必须说清「还要等多久才判」，不能只给个 windowForming。
        var gauge = SelfProcessGauge()
        _ = gauge.record(reading(0, cpuSeconds: 10.0, footprintMB: 90))
        _ = gauge.record(reading(47, cpuSeconds: 10.5, footprintMB: 95))
        let short = SelfProcessOverheadCopy.verdictNote(
            try #require(gauge.overhead), cpuBudgetPercent: 3, memoryLimitMB: 200, load1m: 0.5, .english
        )
        #expect(short.contains("Needs a window of at least 60 s to judge."), "≥60 秒这条在英文侧丢了：\(short)")
        let pending = PerformanceMetricTile.pending(.english)
        #expect(pending[1].caption == "Not RSS")
        #expect(pending[3].caption == "Peaks reported, not judged")
        #expect(PerformanceCopy.selfPeakCaption.text(.english).contains("lower bound"))
    }

    @Test("静默窗上限落在 4：AGENTS.md §6 说 load 5–12 不是结论，4 在保守侧")
    func quietLoadCeiling() {
        #expect(SelfProcessOverheadCopy.isQuietWindow(load1m: 4.0) == true)
        #expect(SelfProcessOverheadCopy.isQuietWindow(load1m: 4.1) == false)
        #expect(SelfProcessOverheadCopy.isQuietWindow(load1m: 5.0) == false)
        #expect(SelfProcessOverheadCopy.isQuietWindow(load1m: nil) == false)
    }

    @Test("上屏字符串里不许有 markdown 强调：Text 不解析代码字面量，星号会被原样画出来")
    func noMarkdownInRenderedStrings() {
        // 真机截图抓到过一次：口径句里写了 `**本 App 单进程**`，屏幕上就是两个星号。
        // `Text(_:)` 只对本地化键走 markdown 解析，代码里的 String 字面量一律原样显示。
        let rendered: [String] = [
            SelfProcessOverheadCopy.scopeNote(.chineseSimplified),
            SelfProcessOverheadCopy.notInstrumentedNote(
                cpuBudgetPercent: 3, memoryLimitMB: 200, memoryTargetMB: 120, .chineseSimplified
            ),
            SelfProcessOverheadCopy.windowNote(
                .demo, now: Date(timeIntervalSince1970: 1_700_000_168), .chineseSimplified),
            SelfProcessVerdict.windowForming(seconds: 47).label(.chineseSimplified),
            SelfProcessVerdict.withinBudget.label(.chineseSimplified),
            SelfProcessVerdict.overBudget.label(.chineseSimplified),
        ] + PerformanceMetricTile.pending(.chineseSimplified).flatMap { [$0.title, $0.caption ?? ""] }
        for text in rendered {
            #expect(!text.contains("**"), "这一句会带着星号上屏：\(text)")
        }
    }
}

// MARK: - 装配

/// 假仪器：可注入的 `SelfProcessReadingSource`，同时记录被读了几次。
/// `@unchecked Sendable`：测试替身，只在对应用例（`@MainActor`）里单线程访问。
private final class FakeSelfProcessSource: SelfProcessReadingSource, @unchecked Sendable {
    private var queued: [SelfProcessSamplePoint]
    private(set) var readCount = 0
    var fails = false

    init(readings: [SelfProcessSamplePoint]) {
        queued = readings
    }

    func readSelfProcessSample(now: Date) -> SelfProcessSamplePoint? {
        readCount += 1
        guard !fails, let next = queued.first else { return nil }
        queued.removeFirst()
        return next
    }
}

@Suite("UI: 本进程开销 · 模型装配", .timeLimit(.minutes(1)))
@MainActor struct SelfProcessModelWiringTests {

    private func makeRuntime() -> ObservatoryRuntime {
        let service = InMemoryObservatoryService()
        return ObservatoryRuntime(service: service, controller: service, updates: service)
    }

    @Test("宿主未装配仪器时：这一格是「未接入」，而不是凭空一排 0")
    func withoutInstrumentNothingIsInvented() {
        let model = PerformanceModel(runtime: makeRuntime())
        #expect(model.hasSelfProcessInstrument == false)
        model.recordSelfProcessSample(now: t0)
        model.recordSelfProcessSample(now: at(60))
        #expect(model.selfOverhead == nil)
    }

    @Test("装配后：一个来源实例从头用到尾，多次调用推进同一个窗口")
    func oneSourceDrivesTheWholeWindow() throws {
        let source = FakeSelfProcessSource(readings: [
            reading(0, cpuSeconds: 10.0, footprintMB: 90),
            reading(96, cpuSeconds: 11.0, footprintMB: 92),
            reading(192, cpuSeconds: 12.0, footprintMB: 94),
        ])
        let model = PerformanceModel(runtime: makeRuntime(), selfProcessSource: source)
        #expect(model.hasSelfProcessInstrument == true)
        for seconds in stride(from: 0.0, through: 200.0, by: 4.0) {
            model.recordSelfProcessSample(now: at(seconds))
        }
        // 每个时刻都真的去读了一次（模型不吞节拍）：0,4,…,200 共 51 次
        #expect(source.readCount == 51)
        let overhead = try #require(model.selfOverhead)
        // 队列只有 3 条读数，其余 48 次返回 nil；第 3 条落在 192 秒，
        // 窗口 180 秒 ⇒ 起点 192-180 = 12 秒，0 秒那条出局，只剩 96 与 192。
        #expect(overhead.sampleCount == 2)
        #expect(overhead.windowStart == at(96))
        // (12.0 - 11.0) / (192 - 96) × 100 = 1 / 96 × 100 = 1.041666…% → 「1.04」
        #expect(overhead.cpuPercent.map { String(format: "%.2f", $0) } == "1.04")
    }

    @Test("仪器读不到时不崩、不清空，保留上一次成形的窗口")
    func unreadableSourceKeepsLastWindow() throws {
        let source = FakeSelfProcessSource(readings: [
            reading(0, cpuSeconds: 10.0, footprintMB: 90),
            reading(180, cpuSeconds: 12.0, footprintMB: 90),
        ])
        let model = PerformanceModel(runtime: makeRuntime(), selfProcessSource: source)
        model.recordSelfProcessSample(now: at(0))
        model.recordSelfProcessSample(now: at(180))
        let before = try #require(model.selfOverhead)
        source.fails = true
        model.recordSelfProcessSample(now: at(190))
        #expect(model.selfOverhead == before)
    }
}
