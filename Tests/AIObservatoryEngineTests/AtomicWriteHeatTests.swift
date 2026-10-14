//
//  AtomicWriteHeatTests.swift
//  AIObservatoryEngineTests
//
//  Owner: 总控（#48）
//  ─────────────────────────────────────────────────────────
//  钉住「原子写残留不许在热文件榜上占独立一格」。
//  真机取证：dogfood 库 `projects.hot_files_json` 里 `AnalysisPresentation.swift` 与
//  `AnalysisPresentation.swift.tmp.4052.1789926435120` 各占一格 ⇒ 用户读到"这个文件被改过两次"，
//  实际是一次改 + 一条写临时文件的垃圾。
//
//  两条判据不可互换：
//   ① 纯函数——只认两种确定形态，**认不准就不并**（`report.7.tmp`、`a.tmp.b` 都得原样返回）；
//   ② 聚合——并的是热区那一格的键与行数，而 `fileChangeCount` 仍按真实发生过的事件计
//      （它问的是"发生了多少"，不是"有几个文件"）。
//

import Foundation
import Testing
@testable import AIObservatoryEngine
import AIObservatoryCore

@Suite("原子写残留并回真身路径", .timeLimit(.minutes(1)))
struct AtomicWriteHeatTests {

    @Test("两种确定形态都并回真身")
    func mergesBothResidueShapes() {
        #expect(ProjectMapper.realPath(ofAtomicWrite: "/a/b/Foo.swift.tmp.4052.1789926435120")
                == "/a/b/Foo.swift")
        #expect(ProjectMapper.realPath(ofAtomicWrite: "/a/b/Foo.swift.4052.tmp") == "/a/b/Foo.swift")
    }

    @Test("认不准的形态一律原样返回（误并比不并更糟）")
    func leavesAmbiguousNamesAlone() {
        // 单数字段：`report.7.tmp` 更像人起的名字，不是 pid。
        #expect(ProjectMapper.realPath(ofAtomicWrite: "/x/report.7.tmp") == "/x/report.7.tmp")
        // tmp 不在确定位置上。
        #expect(ProjectMapper.realPath(ofAtomicWrite: "/x/a.tmp.b") == "/x/a.tmp.b")
        // 没有 tmp 段。
        #expect(ProjectMapper.realPath(ofAtomicWrite: "/x/Foo.swift") == "/x/Foo.swift")
        // 两段数字但没有 tmp。
        #expect(ProjectMapper.realPath(ofAtomicWrite: "/x/Foo.4052.1789") == "/x/Foo.4052.1789")
    }

    @Test("真身与残留同时出现 ⇒ 热区只占一格、行数相加，而事件计数仍按发生次数")
    func aggregatesIntoOneHeatCell() throws {
        let root = "/Users/dev/Work/Alpha"
        let real = root + "/Sources/App.swift"
        let residue = real + ".tmp.4052.1789926435120"
        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let changes = [
            FileChange(path: real, kind: .modified, timestamp: base,
                       agentKind: .claudeCode, linesAdded: 238, linesRemoved: 0),
            FileChange(path: residue, kind: .modified,
                       timestamp: base.addingTimeInterval(1),
                       agentKind: .claudeCode, linesAdded: 12, linesRemoved: 3),
        ]
        let mapper = ProjectMapper(resolver: { _ in root })
        let activity = try #require(mapper.aggregate(
            changes: changes, commands: [], events: [], sessions: [], risks: []
        ).first)

        // 反向也要钉：榜上**一条残留路径都不许出现**。
        // 只按真身后缀取那一格是弱断言——残留那格不以 `App.swift` 结尾，
        // 变异检查实测：摘掉并回后 `mine.count` 仍是 1，只有 changeCount 那几条会红。
        #expect(!activity.hotFiles.contains { $0.path.contains(".tmp.") },
                "热区里出现了原子写残留路径")
        let mine = activity.hotFiles.filter { $0.path.hasSuffix("App.swift") }
        #expect(mine.count == 1, "残留必须并到真身那一格，不许另起一格")
        let heat = try #require(mine.first)
        #expect(heat.path == real)
        #expect(heat.changeCount == 2, "两次事件都要算进那一格")
        #expect(heat.linesAdded == 250, "行数要相加——一删了之会把 +238 算丢")
        #expect(heat.linesRemoved == 3)
        #expect(activity.fileChangeCount == 2, "事件口径不变：确实发生过两次变更")
        #expect(activity.codeGrowthLines == 250)
        #expect(activity.codeShrinkLines == 3)
    }
}
