//
//  FileLineDeltaReadout.swift
//  AIObservatoryUI / Files
//
//  Owner: WS-Verify
//  ─────────────────────────────────────────────────────────
//  「行数增减」与「为什么没有 diff」这两条读数口径，抽出来单独可测。
//
//  为什么值得抽出来：真机对账时这两处都在说谎，而它们说谎的方式一模一样——
//  **把「结构上拿不到」显示成「测出来是 0 / 这次没采到」**。
//  库里事实（当时 `tmp/verify` 实测）：`diffs` 表只有 `created` 一类、`modified` 一行都没有，
//  `file_changes.previous_size_bytes` 全为 NULL，`file_snapshots` 0 行
//  ⇒ 修改类变更拿不到旧内容，`linesAdded/Removed` 恒为 0 是「没采到」而不是「一行没动」。
//  同期 notes.md 从 142 B 涨到 151 B，界面上的 `+0` 明显是假读数。
//
//  2026-09-20（WS-Diff）改了采集面：修改类现在会带「上一次观测到的内容」进库，所以
//  「这一类结构上拿不到」那句话对 `modified` 已经不再成立，分档随之重划分。
//  但这套口径本身一个字没删——拿不到可比版本时（首次观测、明文被关掉）它仍然要说
//  「未采集」，而不是把全文行数或 `+0` 报成测到的量。
//
//

import Foundation
import AIObservatoryCore

/// 「行数增减」这一项到底能不能报数。
enum FileLineDelta: Equatable {

    /// 真的拿到了差异 ⇒ 可以报 `+n / -n`。
    case measured(added: Int, removed: Int)

    /// 一条差异都没采到 ⇒ 不许报 0，只能报「未采集」并退回显示变更后大小。
    case notCaptured(sizeBytes: UInt64)
}

/// 「没有可显示的 diff」这个空态的成因分类。
///
/// 三种成因对用户是三件不同的事，并列成「可能是 A、可能是 B、可能是 C」
/// 等于让读者自己猜，也等于把能力边界说成偶发漏采。
enum MissingDiffReason: Equatable {

    /// 创建 / 修改类：这一类**会**捕获内容差异，没有就是这次真没采到。
    case captureMissed(FileChangeKind)

    /// 删除 / 重命名类：结构上没有「改动后的内容」，本来就不该有逐行差异。
    case noNewContent(FileChangeKind)

    /// 变更类型未知：连是哪一类都不知道，两种说法都不许用。
    case notApplicable(FileChangeKind?)
}

/// 读数口径（详情面板与任何未来的导出/报表共用，避免出现第二套规则）。
enum FileLineDeltaReader {

    /// 有 diff 记录时以 diff 为准（它才是真量到的）；没有时才退回变更行自带的计数。
    static func read(diff: FileDiff?, change: FileChange) -> FileLineDelta {
        if let diff {
            // 单边 diff 的 `linesAdded` 是「当前全文行数」，不是这次编辑的增量：拿它报 +N
            // 就是拿旧内容冒充本次产出，与这文件当初要堵的假 `+0` 同族、只是方向相反。
            // 新建是例外——文件凭空出现，全文行数确实是它加进来的行数。
            if diff.kind == .modified, diff.baselineSource == .unavailableFirstSighting {
                return .notCaptured(sizeBytes: change.sizeBytes)
            }
            return .measured(added: diff.linesAdded, removed: diff.linesRemoved)
        }
        let added = change.linesAdded
        let removed = change.linesRemoved
        if added == 0, removed == 0 {
            return .notCaptured(sizeBytes: change.sizeBytes)
        }
        return .measured(added: added, removed: removed)
    }

    /// 空态成因按变更类型分档。`unknown` 归到 `notApplicable`：
    /// 连类型都不知道时，说「这一类结构上拿不到」和说「这次没采到」都是撒谎。
    static func reason(for kind: FileChangeKind?) -> MissingDiffReason {
        switch kind {
        case .created, .modified:   return .captureMissed(kind ?? .unknown)
        case .deleted, .renamed:    return .noNewContent(kind ?? .unknown)
        case .unknown, .none:       return .notApplicable(kind)
        }
    }

    /// 空态文案。措辞要求：能力边界说成边界，偶发漏采说成漏采，两者不得互换。
    /// `language` 显式收参（默认按进程语言）：用例要钉住某一路文案，
    /// 而不能依赖"测试进程恰好是中文"。
    static func message(for reason: MissingDiffReason,
                        language: AppLanguage = .resolved()) -> String {
        switch reason {
        case .captureMissed:
            return FilesCopy.diffMissingCaptureMissed.text(language)
        case .noNewContent:
            return FilesCopy.diffMissingNoNewContent.text(language)
        case .notApplicable:
            return FilesCopy.diffMissingKindUnknown.text(language)
        }
    }
}
