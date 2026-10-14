//
//  FileLineDeltaReadoutTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-Verify
//
//  守的是真机截图抓出来的那类谎：修改类变更结构上拿不到逐行差异
//  （库里 `diffs` 只有 created、`previous_size_bytes` 全 NULL、`file_snapshots` 0 行），
//  界面却无条件渲染绿色 `+0` 配红色 `-0`，读起来像「这次改动一行都没动」。
//  同期 notes.md 从 142 B 涨到 151 B —— `+0` 是假读数。
//

import Foundation
import Testing
import AIObservatoryCore
@testable import AIObservatoryUI

private func change(
    _ kind: FileChangeKind,
    added: Int = 0,
    removed: Int = 0,
    size: UInt64 = 151
) -> FileChange {
    FileChange(
        path: "/repo/notes.md",
        kind: kind,
        sizeBytes: size,
        linesAdded: added,
        linesRemoved: removed
    )
}

private func diff(
    added: Int,
    removed: Int,
    kind: FileChangeKind = .created,
    source: DiffBaselineSource = .notApplicable,
    baseline: Date? = nil
) -> FileDiff {
    FileDiff(
        path: "/repo/notes.md",
        kind: kind,
        linesAdded: added,
        linesRemoved: removed,
        baselineSource: source,
        baselineCapturedAt: baseline
    )
}

@Suite("UI: 文件读数 · 拿不到行数不等于 0")
struct FileLineDeltaReadoutTests {

    @Test("没有 diff 记录、计数又全为 0：报「未采集」，绝不报 +0/-0")
    func zeroWithoutDiffIsNotMeasured() {
        let readout = FileLineDeltaReader.read(diff: nil, change: change(.modified))
        #expect(readout == .notCaptured(sizeBytes: 151))
    }

    @Test("重命名同理：恒为 0 的计数是「没采到」")
    func renamedAlsoNotCaptured() {
        #expect(FileLineDeltaReader.read(diff: nil, change: change(.renamed))
                == .notCaptured(sizeBytes: 151))
    }

    @Test("真有非零计数：这是量到的，可以报数")
    func nonZeroCountsAreMeasured() {
        #expect(FileLineDeltaReader.read(diff: nil, change: change(.created, added: 11))
                == .measured(added: 11, removed: 0))
    }

    @Test("有 diff 记录时以 diff 为准，包括真的 0 行（那是测出来的 0）")
    func diffRecordMakesZeroLegitimate() {
        let readout = FileLineDeltaReader.read(diff: diff(added: 0, removed: 0), change: change(.created))
        #expect(readout == .measured(added: 0, removed: 0))
    }

    @Test("diff 与变更行不一致时取 diff（diff 才是真量到的那份）")
    func diffWinsOverChangeRow() {
        let readout = FileLineDeltaReader.read(
            diff: diff(added: 7, removed: 2),
            change: change(.created, added: 99, removed: 99)
        )
        #expect(readout == .measured(added: 7, removed: 2))
    }

    /// 单边 diff 里的 `linesAdded` 是「当前全文行数」，不是这次编辑的增量。
    /// 把它当测到的量报出去，就是拿旧内容冒充本次产出——和这个文件当初要堵的 `+0` 是同一族谎，
    /// 只是方向相反。判据只有 `baselineSource`，不看行列数。
    @Test("首次观测的修改：单边 diff 的全文行数不许报成「量到的增量」")
    func firstSightingModifiedIsNotMeasured() {
        let readout = FileLineDeltaReader.read(
            diff: diff(added: 200, removed: 0, kind: .modified, source: .unavailableFirstSighting),
            change: change(.modified, size: 8_100)
        )
        #expect(readout == .notCaptured(sizeBytes: 8_100))
    }

    @Test("可比上的修改：这才是量到的增量，两边数值都取 diff 的")
    func comparableModifiedIsMeasured() {
        #expect(FileLineDeltaReader.read(
            diff: diff(added: 2, removed: 1, kind: .modified, source: .lastObserved, baseline: Date(timeIntervalSinceReferenceDate: 1)),
            change: change(.modified)
        ) == .measured(added: 2, removed: 1))
    }

    /// 新建没有「上一版」这回事，但全文确实都是这次加进来的 ⇒ 单边也算量到。
    /// 这条是反向守卫：谁把「不可比」一律按 unknown 处理，这里就红。
    @Test("新建的单边 diff：全文行数是真增量，不许退回「未采集」")
    func createdSingleSidedIsStillMeasured() {
        #expect(FileLineDeltaReader.read(
            diff: diff(added: 3, removed: 0, kind: .created, source: .unavailableFirstSighting),
            change: change(.created, size: 18)
        ) == .measured(added: 3, removed: 0))
    }
}

@Suite("UI: 空态成因 · 能力边界与偶发漏采不得互换")
struct MissingDiffReasonTests {

    /// 2026-09-20（WS-Diff）改了口径：原来这里写「修改与重命名不保留改动前的内容，
    /// 所以这一类拿不到逐行 diff——采集范围的限制」。引擎现在开始为修改留底并落 diff，
    /// 那句话就成了假话；而修改类真的没有 diff 时，真实原因是内容没读到（漏采）。
    /// 重命名与删除仍然结构上无 diff：那才是边界。
    @Test("修改：该有 diff 而没有，就说成漏采，不说成采集范围")
    func modifiedIsCaptureMiss() {
        let reason = FileLineDeltaReader.reason(for: .modified)
        #expect(reason == .captureMissed(.modified))
        #expect(FileLineDeltaReader.message(for: reason, language: .chineseSimplified).contains("可能是快照未捕获"))
        #expect(!FileLineDeltaReader.message(for: reason, language: .chineseSimplified).contains("采集范围的限制"),
                "已经会采的那一类，不许再说成不会采")
    }

    @Test("重命名 / 删除：本来就没有改动后的内容，不能说成漏采")
    func kindsWithoutNewContentSaySo() {
        for kind in [FileChangeKind.renamed, .deleted] {
            let reason = FileLineDeltaReader.reason(for: kind)
            #expect(reason == .noNewContent(kind))
            let message = FileLineDeltaReader.message(for: reason, language: .chineseSimplified)
            #expect(message.contains("没有改动后的内容"))
            #expect(!message.contains("可能是快照未捕获"), "把「本来就没有」说成「应该有线上没采到」= 撒谎")
            #expect(!message.contains("采集范围的限制"), "边界要说是边界，但不能借用作弊的通用措辞")
        }
    }

    @Test("创建：确实该有一条 diff，没拿到才是漏采")
    func createdIsCaptureMiss() {
        let reason = FileLineDeltaReader.reason(for: .created)
        #expect(reason == .captureMissed(.created))
        #expect(FileLineDeltaReader.message(for: reason, language: .chineseSimplified).contains("可能是快照未捕获"))
    }

    @Test("类型未知时两边都不许断言")
    func unknownAssertsNeither() {
        let message = FileLineDeltaReader.message(for: .notApplicable(.unknown), language: .chineseSimplified)
        #expect(!message.contains("采集范围的限制"))
        #expect(!message.contains("可能是快照未捕获"))
        #expect(!message.contains("没有改动后的内容"))
        #expect(message.contains("无法判断"))
    }

    @Test("selected 为 nil（还没选变更）也不能崩出口径")
    func nilKindIsHandled() {
        #expect(FileLineDeltaReader.reason(for: nil) == .notApplicable(nil))
    }

    /// 英文侧同样不许把三档互换——"漏采"与"结构上拿不到"在两种语言里是同一类撒谎。
    /// 上面那五条断言只钉了中文那一路（显式传 `.chineseSimplified`），英文侧不能靠"看起来翻译了"过关。
    @Test("英文侧：三档各自不同，且不许出现别档的说法")
    func englishKeepsTheThreeCausesApart() {
        let missed = FileLineDeltaReader.message(for: .captureMissed(.modified), language: .english)
        let noContent = FileLineDeltaReader.message(for: .noNewContent(.deleted), language: .english)
        let unknown = FileLineDeltaReader.message(
            for: .notApplicable(.unknown), language: .english
        )
        #expect(Set([missed, noContent, unknown]).count == 3, "三档英文撞成同一句：\(unknown)")
        // 手推关键短语（钉语义，不是钉实现）：换措辞要连带改这条，正是想要的摩擦。
        #expect(missed.contains("may not have been captured"), "\(missed)")
        #expect(noContent.contains("no resulting content"), "\(noContent)")
        #expect(!noContent.contains("may not have been captured"),
                "把「本来就没有」说成「应该有线上没采到」= 撒谎，英文侧同样禁止")
        #expect(!unknown.contains("may not have been captured"), "\(unknown)")
        #expect(!unknown.contains("no resulting content"), "\(unknown)")
        #expect(!unknown.contains("采集"), "英文侧夹进汉字：\(unknown)")
    }
}
