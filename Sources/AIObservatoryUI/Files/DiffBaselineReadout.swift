//
//  DiffBaselineReadout.swift
//  AIObservatoryUI / Files
//
//  Owner: WS-Diff
//  ─────────────────────────────────────────────────────────
//  「改前内容是从哪来的」这条措辞口径。
//
//  为什么单独抽出来：`baselineSource` 存在的唯一理由就是让界面能说实话。口径写进 View
//  里就会长出第二套（列表行、导出、详情面板各说一遍），而库里反复出现的那类缺陷正是
//  「同一个事实有两套互不知情的措辞」。抽成纯函数后它可测，谁改红谁。
//

import Foundation
import AIObservatoryCore

/// Before/After 面板对「改前内容」能说到什么程度。
enum DiffBaselineReadout: Equatable {

    /// 比得上：有真正的改前版本，且知道它是哪一次观测到的。
    case compared(toObservedAt: Date)

    /// 比得上，但那次观测的时刻没记下来（v4 之前的老数据）。
    case comparedWithoutTimestamp

    /// 比不上：这是首次观测到该路径，没有任何可比版本（当前显示的是单边 diff）。
    case firstSighting

    /// 不适用：这类变更本来就没有改动后的内容（删除、重命名）。
    case notApplicable
}

/// 溯源措辞口径。
enum DiffBaselineReader {

    /// 只认 `baselineSource`，不从「行数是否为 0」「行列是否为空」反推。
    static func readout(for diff: FileDiff) -> DiffBaselineReadout {
        switch diff.baselineSource {
        case .lastObserved:
            // 数据不一致时（标着可比却没时间）宁可不说时间。
            guard let observedAt = diff.baselineCapturedAt else { return .comparedWithoutTimestamp }
            return .compared(toObservedAt: observedAt)
        case .unavailableFirstSighting:
            return .firstSighting
        case .notApplicable:
            return .notApplicable
        }
    }

    /// 一句话说明白「Before 是哪份」。空串 = 界面会退化成让读者自己猜。
    ///
    /// - Parameter timeText: 已格式化好的时刻文本。口径函数不自己格式化，否则每条用例都要
    ///   再断一遍日期格式——而日期格式另有归属，这里不该发明第二套。
    static func message(for readout: DiffBaselineReadout, timeText: String,
                        language: AppLanguage = .resolved()) -> String {
        switch readout {
        case .compared:
            return FilesCopy.baselineCompared.format(language, timeText)
        case .comparedWithoutTimestamp:
            return FilesCopy.baselineComparedWithoutTimestamp.text(language)
        case .firstSighting:
            return FilesCopy.baselineFirstSighting.text(language)
        case .notApplicable:
            return FilesCopy.baselineNotApplicable.text(language)
        }
    }

    /// 「有 diff 记录却一行都不显示」的两种成因：用户关掉了明文，与真的没有行级差异。
    /// 说错方向的代价不对称：前者说成后者，用户以为 Agent 什么都没改；
    /// 后者说成前者，用户以为自己的开关坏了。
    static func emptyLinesMessage(for diff: FileDiff,
                                  language: AppLanguage = .resolved()) -> String {
        diff.plaintextStored
            ? FilesCopy.emptyLinesCapturedEmpty.text(language)
            : FilesCopy.emptyLinesPlaintextOff.text(language)
    }
}
