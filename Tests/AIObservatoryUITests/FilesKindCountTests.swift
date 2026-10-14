//
//  FilesKindCountTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uiclose · 目标⑦）
//  ─────────────────────────────────────────────────────────
//  钉住「事件条数」与「去重文件数」是两个数，且各归其位。
//  出发点是真机截图：hero 写「变更文件总数 49」，三格写 新建 10 / 删除 39 /（行内）修改 14，
//  相加 = 63，副标题又是「共 67 个变更」——三个数并存而页面没说它们不是一个口径。
//  根因：那三格用的是 `changes.filter{ kind == … }.count`（**事件**条数），
//  却挂在「新建**文件**」「删除**文件**」的标题下——正是本文件里 hero 早就警告过的
//  「拿事件数冒充文件数」（见 `FilesView.distinctFileCount` 上方注释），分类型那几格一直在犯。
//
//  期望值全部手推，夹具见下。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport
@testable import AIObservatoryUI

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func change(_ path: String, _ kind: FileChangeKind, _ minutes: Int) -> FileChange {
    FileChange(path: path, kind: kind, timestamp: t0.addingTimeInterval(Double(minutes) * 60))
}

/// 五条事件、三个不同路径：
/// ```
/// a.md created      b.md deleted      b.md deleted（同一路径删两次）
/// a.md modified     c.md renamed
/// ```
/// ⇒ 事件数：新建 1 · 修改 1 · 删除 **2** · 重命名 1（合计 5）
/// ⇒ 去重文件数：新建 1 · 修改 1 · 删除 **1** · 重命名 1（合计 4，但去重路径只有 3）
@MainActor
private func loadedModel() async -> FilesModel {
    let service = InMemoryObservatoryService()
    service.seed(fileChanges: [
        change("/p/a.md", .created, 0),
        change("/p/a.md", .modified, 1),
        change("/p/b.md", .deleted, 2),
        change("/p/b.md", .deleted, 3),
        change("/p/c.md", .renamed, 4),
    ])
    let model = FilesModel(
        runtime: ObservatoryRuntime(service: service, controller: service, updates: service)
    )
    await model.load()
    return model
}

@Suite("UI: 文件页 · 事件数与文件数不得混用", .timeLimit(.minutes(1)))
@MainActor struct FilesKindCountTests {

    @Test("筛选菜单用的是事件数（它回答「选这项会看到几行」）")
    func filterMenuCountsEvents() async {
        let model = await loadedModel()
        #expect(model.totalCount == 5)
        #expect(model.eventCount(for: .deleted) == 2)
        #expect(model.eventCount(for: .created) == 1)
        #expect(model.eventCount(for: .renamed) == 1)
    }

    @Test("标题写着「文件」的那几格用的是去重路径数")
    func fileLabeledTilesCountPaths() async {
        let model = await loadedModel()
        // b.md 被删两次：事件 2 条，但**文件**只有 1 个
        #expect(model.distinctFileCount(for: .deleted) == 1)
        #expect(model.distinctFileCount(for: .created) == 1)
        #expect(model.distinctFileCount(for: .modified) == 1)
    }

    @Test("两个口径确实分叉：只有「同一路径重复命中同一类型」时才不相等")
    func theTwoCalibersActuallyDiverge() async {
        let model = await loadedModel()
        #expect(model.eventCount(for: .deleted) == 2)
        #expect(model.distinctFileCount(for: .deleted) == 1)
        // 变异防线：若有人把 `distinctFileCount(for:)` 改回 `filter{}.count`，上面两条立刻红
    }

    @Test("各类型可重叠 ⇒ 去重后相加（4）大于全类型去重路径数（3）")
    func kindsMayOverlap() async {
        let model = await loadedModel()
        let sumOfKinds = FileChangeKind.allCases.reduce(0) {
            $0 + model.distinctFileCount(for: $1)
        }
        // a.md 既被新建又被修改 ⇒ 4 > 3，所以界面上必须写「同一文件可命中多类」
        #expect(sumOfKinds == 4)
        #expect(Set(model.changes.map(\.path)).count == 3)
        #expect(sumOfKinds > Set(model.changes.map(\.path)).count)
    }
}
