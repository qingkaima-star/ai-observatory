//
//  TimeRangeBilingualCopyTests.swift
//  AIObservatoryUITests
//
//  Owner: ws/cli（#67 界面半）
//  ─────────────────────────────────────────────────────────
//  #67 的形状：`ObservatoryTimeRange.displayName` 原本硬编码中文且**没有语言入参**，
//  而各页头部/筛选条/空态文案直接渲染它 ⇒ 英文态必露中文（结构事实，不是概率）。
//  三条用例分别钉：① 六条文案两路都不同（防"英文只是把中文抄一遍"那种假双语）；
//  ② 无语言入参的那个入口确实只转发中文（它存在的唯一理由）；
//  ③ **整页扫**：UI 里任何渲染时间范围名的地方都必须显式传语言 ——
//     逐格断言正是 #64 漏掉"采集面那行直出真实家目录"那一格的成因，所以这里按目录枚举、不点名文件。
//

import Foundation
import Testing
@testable import AIObservatoryUI
import AIObservatoryCore

private let expectedNames: [(ObservatoryTimeRange, String, String)] = [
    // 英文按句首大写（HIG sentence case），不是逐字对译成 "Last 24 Hours"。
    (.today, "今天", "Today"),
    (.lastHour, "最近 1 小时", "Last hour"),
    (.lastSixHours, "最近 6 小时", "Last 6 hours"),
    (.last24Hours, "最近 24 小时", "Last 24 hours"),
    (.lastSevenDays, "最近 7 天", "Last 7 days"),
    (.all, "全部", "All"),
]

@Test("六条时间范围名逐字对照，且**每一条两路都不同**（假双语当场红）")
func allSixTimeRangeNamesAreLanguageSpecific() {
    #expect(expectedNames.count == 6, "分母：六条得齐，少一条这格就是空跑")
    #expect(ObservatoryTimeRange.allCases.count == 6)
    #expect(TimeRangeCopy.bilingualCopy.count == 6, "文案表与枚举不同步 ⇒ 加了一条漏一条")
    for (range, chinese, english) in expectedNames {
        #expect(range.displayName(.chineseSimplified) == chinese,
                "\(range.rawValue) 中文态实得 \(range.displayName(.chineseSimplified))")
        #expect(range.displayName(.english) == english,
                "\(range.rawValue) 英文态实得 \(range.displayName(.english))")
        #expect(range.displayName(.chineseSimplified) != range.displayName(.english),
                "\(range.rawValue) 两路同值 ⇒ 这条双语是抄的")
    }
    // 六条彼此也不能撞名，否则选择器上两个选项长得一样。
    let chineseNames = expectedNames.map(\.1)
    #expect(Set(chineseNames).count == chineseNames.count)
    let englishNames = expectedNames.map(\.2)
    #expect(Set(englishNames).count == englishNames.count)
}

@Test("无语言入参的 `displayName` 只转发中文——它存在的唯一理由是非用户可见调用点")
func languagelessAccessorForwardsChineseOnly() {
    for range in ObservatoryTimeRange.allCases {
        #expect(range.displayName == range.displayName(.chineseSimplified))
        #expect(range.displayName != range.displayName(.english),
                "\(range.rawValue) 的无参入口返回了英文 ⇒ 转发目标变了")
    }
}

@Test("整页扫：UI 里渲染时间范围名不许有不传语言的调用点")
func noUserVisibleTimeRangeRendererIgnoresLanguage() throws {
    let files = try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI")
    #expect(files.count >= 60, "只扫到 \(files.count) 份 UI 源码 ⇒ 分母不对，这格在空跑")
    var offenders: [String] = []
    var checked = 0
    for file in files {
        // 定义处本身允许出现无参 `displayName`（那是转发实现与预览）。
        if file.lastPathComponent == "ObservatoryTimeRange.swift" { continue }
        let lines = (try String(contentsOf: file, encoding: .utf8)).split(separator: "\n")
        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") { continue }
            // 找"timeRange.displayName"或"range.displayName"后面**没有**左括号的那些 —— 那就是不传语言。
            for marker in ["timeRange.displayName", "range.displayName"] {
                guard let found = trimmed.range(of: marker) else { continue }
                checked += 1
                let rest = trimmed[found.upperBound...]
                if !rest.hasPrefix("(") {
                    offenders.append("\(file.lastPathComponent):\(index + 1) \(trimmed.prefix(72))")
                }
            }
        }
    }
    #expect(checked >= 15, "只扫到 \(checked) 处调用点 ⇒ 尺子比实际渲染点少，别当成已收口")
    #expect(offenders.isEmpty, "还有 \(offenders.count) 处不传语言：\n\(offenders.joined(separator: "\n"))")
}
