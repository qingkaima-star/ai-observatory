//
//  DiffBaselineReadoutTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-Diff
//  ─────────────────────────────────────────────────────────
//  需求③ 的最后一公里：拿不到改前版本时，界面必须**说出拿不到的原因**，
//  而不是给一个空白面板、更不是给一个「没有变更」。
//  这里钉的是措辞口径与 `baselineSource` 一一对应，且不从行数反推。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

private let observedAt = Date(timeIntervalSinceReferenceDate: 750_000_123.456)
private let capturedAt = Date(timeIntervalSinceReferenceDate: 750_000_456.789)

private func diffValue(
    kind: FileChangeKind = .modified,
    source: DiffBaselineSource,
    baseline: Date?
) -> FileDiff {
    FileDiff(
        path: "/repo/notes.md",
        kind: kind,
        lines: [DiffLine(style: .removed, text: "旧行", oldLineNumber: 1)],
        linesAdded: 2,
        linesRemoved: 1,
        capturedAt: capturedAt,
        baselineSource: source,
        baselineCapturedAt: baseline
    )
}

@Suite("UI: Before 的来历怎么说", .timeLimit(.minutes(1)))
struct DiffBaselineReadoutTests {

    @Test("四种溯源状态各归各类，不从行数或行列数反推")
    func readoutFollowsSourceOnly() {
        #expect(DiffBaselineReader.readout(for: diffValue(source: .lastObserved, baseline: observedAt))
                == .compared(toObservedAt: observedAt))
        #expect(DiffBaselineReader.readout(for: diffValue(source: .lastObserved, baseline: nil))
                == .comparedWithoutTimestamp)
        #expect(DiffBaselineReader.readout(for: diffValue(source: .unavailableFirstSighting, baseline: nil))
                == .firstSighting)
        #expect(DiffBaselineReader.readout(for: diffValue(source: .notApplicable, baseline: nil))
                == .notApplicable)
        // 同一份 diff 把行数清空，分类不许跟着变——那等于回到「靠猜」。
        var stripped = diffValue(source: .lastObserved, baseline: observedAt)
        stripped.lines = []
        stripped.linesAdded = 0
        stripped.linesRemoved = 0
        #expect(DiffBaselineReader.readout(for: stripped) == .compared(toObservedAt: observedAt))
    }

    /// 数据不一致时（标着「首次观测」却带着一个时刻）宁可不说时刻。
    /// 说一个没参与比较的时间，比不说更容易把人带偏。
    @Test("firstSighting 配了时刻也不许把时刻说出来")
    func firstSightingIgnoresStrayTimestamp() {
        #expect(DiffBaselineReader.readout(
            for: diffValue(source: .unavailableFirstSighting, baseline: observedAt)
        ) == .firstSighting)
    }

    @Test("命中：话说「与 <时刻> 观测到的版本对比」，不许出现「首次」")
    func comparedMessage() {
        let message = DiffBaselineReader.message(for: .compared(toObservedAt: observedAt), timeText: "10-07 21:22", language: .chineseSimplified)
        #expect(!message.isEmpty, "空串等于让界面自己编")
        #expect(message.contains("10-07 21:22"))
        #expect(message.contains("观测到的版本对比"))
        #expect(!message.contains("首次"), "明明比得上却说首次观测，是白白贬低自己采到的数据")
    }

    @Test("命中但没记时刻：说「上一次观测」，且不许出现空时刻或占位符")
    func comparedWithoutTimestampMessage() {
        let message = DiffBaselineReader.message(for: .comparedWithoutTimestamp, timeText: "", language: .chineseSimplified)
        #expect(!message.isEmpty)
        #expect(message.contains("上一次观测"))
        #expect(!message.contains("（）") && !message.contains("null") && !message.contains("nil"),
                "把空时刻拼进括号里就是界面故障")
        #expect(!message.contains("首次"))
    }

    @Test("未命中：说「首次观测到该文件，无改前版本可比」，不许出现「无变更」")
    func firstSightingMessage() {
        let message = DiffBaselineReader.message(for: .firstSighting, timeText: "10-07 21:22", language: .chineseSimplified)
        #expect(!message.isEmpty)
        #expect(message.contains("首次观测到该文件"))
        #expect(message.contains("无改前版本可比"))
        #expect(!message.contains("10-07 21:22"), "没有可比版本时任何时刻都是误导")
        #expect(!message.contains("没有变更") && !message.contains("无差异"),
                "单边 diff 里全是新增行，说「无变更」是直接反着说")
    }

    @Test("不适用：既不声称比过，也不假装是首次观测")
    func notApplicableMessage() {
        let message = DiffBaselineReader.message(for: .notApplicable, timeText: "10-07 21:22", language: .chineseSimplified)
        #expect(!message.isEmpty)
        #expect(!message.contains("首次观测"), "删除/重命名不是「没见过这个文件」")
        #expect(!message.contains("版本对比"))
        #expect(message.contains("没有改动后的内容") || message.contains("没有新内容"))
    }
}

@Suite("UI: 有 diff 却一行都不显示时怎么说", .timeLimit(.minutes(1)))
struct DiffEmptyLinesReadoutTests {

    /// 「明文被设置关掉」与「这次真的没有行级差异」是两件事。
    /// 前者说成后者，用户会以为 Agent 什么都没干；后者说成前者，用户会以为自己的开关坏了。
    @Test("明文已按设置关闭：说成设置的效果，不写「无差异」")
    func suppressedBySetting() {
        let diff = diffValue(source: .lastObserved, baseline: observedAt)
        var suppressed = diff
        suppressed.lines = []
        suppressed.plaintextStored = false
        let message = DiffBaselineReader.emptyLinesMessage(for: suppressed, language: .chineseSimplified)
        #expect(!message.isEmpty)
        #expect(message.contains("明文已按设置关闭"))
        #expect(!message.contains("没有行级差异") && !message.contains("权限变化"))
    }

    @Test("明文开着而 diff 为空：不许赖设置")
    func genuinelyEmpty() {
        var empty = diffValue(source: .lastObserved, baseline: observedAt)
        empty.lines = []
        empty.plaintextStored = true
        let message = DiffBaselineReader.emptyLinesMessage(for: empty, language: .chineseSimplified)
        #expect(!message.isEmpty)
        #expect(!message.contains("明文已按设置关闭"), "用户没关任何东西，说他关了是撒谎")
    }

    /// 上面两条只钉了中文那一路。英文侧必须同样分得开——
    /// "switched off in settings" 与 "the diff is empty" 说反方向的代价和中文侧一模一样。
    @Test("英文侧：两种成因各自不同，且不许出现别档的说法")
    func englishKeepsTheTwoCausesApart() {
        var suppressed = diffValue(source: .lastObserved, baseline: observedAt)
        suppressed.lines = []
        suppressed.plaintextStored = false
        var empty = suppressed
        empty.plaintextStored = true
        let off = DiffBaselineReader.emptyLinesMessage(for: suppressed, language: .english)
        let none = DiffBaselineReader.emptyLinesMessage(for: empty, language: .english)
        #expect(off.contains("switched off in settings"), "\(off)")
        #expect(!none.contains("switched off"), "用户没关任何东西，说他关了是撒谎（英文侧同样）")
        #expect(none.contains("diff is empty"), "\(none)")
        #expect(!off.contains("only metadata"), "\(off)")
    }
}
