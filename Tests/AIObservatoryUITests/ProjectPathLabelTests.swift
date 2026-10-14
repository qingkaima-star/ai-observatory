//
//  ProjectPathLabelTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uiclose · 目标⑧）
//  ─────────────────────────────────────────────────────────
//  钉住「一组项目路径的行内标签必须互不相同，且不比需要的更长」。
//  出发点是真机截图：项目活动地图左列连着三行一模一样（都是 `work` + `AgentFixture/work`），
//  而库里它们其实是不同项目——固定截末两段把区分段（`hang` / `ai-observatory`）截掉了。
//  下面这些路径的形状与深度是从库里读出来的真实值，宿主前缀按 `FixturePaths` 的口径
//  换成合成主体（`/Users/dev/Work/…`）——只参与字符串比较、从不落盘，
//  写真实前缀会把本机目录布局固化进公开产物（`make-public-release.sh` 自检② 数一切命中，**包括注释**）。
//

import Foundation
import Testing
@testable import AIObservatoryUI

@Suite("UI: 项目路径标签在同组内必须唯一", .timeLimit(.minutes(1)))
struct ProjectPathLabelTests {

    @Test("末两段会撞 ⇒ 自动多取一段，直到可区分（真库里的两条 work）")
    func extendsUntilUnique() {
        let hang = "/Users/dev/Work/Audit/.worktrees/hang/Tools/AgentFixture/work"
        let main = "/Users/dev/Work/Audit/ai-observatory/Tools/AgentFixture/work"
        let labels = ProjectPathLabels.labels(for: [hang, main])
        // 手推：末两段都是 `AgentFixture/work`（撞）；末三段都是 `Tools/AgentFixture/work`（还撞）；
        // 末四段才是 hang/… 与 ai-observatory/… ⇒ 停在 4。
        #expect(labels[hang] == "hang/Tools/AgentFixture/work")
        #expect(labels[main] == "ai-observatory/Tools/AgentFixture/work")
    }

    @Test("三行同名（截图上正是三行）也各自唯一")
    func threeWayCollisionResolves() {
        let paths = [
            "/Users/dev/Work/Audit/.worktrees/hang/Tools/AgentFixture/work",
            "/Users/dev/Work/Audit/ai-observatory/Tools/AgentFixture/work",
            "/Users/dev/Work/Audit/.worktrees/procscan/Tools/AgentFixture/work",
        ]
        let labels = ProjectPathLabels.labels(for: paths)
        #expect(Set(labels.values).count == 3)
        #expect(labels["/Users/dev/Work/Audit/.worktrees/procscan/Tools/AgentFixture/work"]
                == "procscan/Tools/AgentFixture/work")
    }

    @Test("末两段本来就唯一时**不许**加长（不做无谓的完整路径）")
    func staysShortWhenAlreadyUnique() {
        let labels = ProjectPathLabels.labels(for: ["/a/b/one.txt", "/c/d/two.txt"])
        #expect(labels["/a/b/one.txt"] == "b/one.txt")
        #expect(labels["/c/d/two.txt"] == "d/two.txt")
    }

    @Test("只有撞车的那几条加深；无关的行停在末两段（不为一对撞车把整列写长）")
    func onlyCollidingRowsGrow() {
        let labels = ProjectPathLabels.labels(for: [
            "/Users/dev/Work/Audit/.worktrees/hang/Tools/AgentFixture/work",
            "/Users/dev/Work/Audit/ai-observatory/Tools/AgentFixture/work",
            "/Users/dev/Work/Audit/.worktrees/mempeak",
        ])
        // 两条 work 加深到末四段才可区分
        #expect(labels["/Users/dev/Work/Audit/.worktrees/hang/Tools/AgentFixture/work"]
                == "hang/Tools/AgentFixture/work")
        #expect(labels["/Users/dev/Work/Audit/ai-observatory/Tools/AgentFixture/work"]
                == "ai-observatory/Tools/AgentFixture/work")
        // 第三条末两段就唯一 ⇒ 不许被一起拉长（真机加深后它一度变成
        // `Work/Audit/.worktrees/mempeak`，那是把代价摊给了无关的行）
        #expect(labels["/Users/dev/Work/Audit/.worktrees/mempeak"] == ".worktrees/mempeak")
    }

    @Test("根目录 / 与空集合都不崩、不产出空标签")
    func degenerateInputs() {
        #expect(ProjectPathLabels.labels(for: []).isEmpty)
        // "/" 切出来没有成分 ⇒ 按规则原样给回 "/"，而不是空串
        #expect(ProjectPathLabels.labels(for: ["/"])["/"] == "/")
        // 一条只有两段的路径与一条很深的路径：末两段就已经不同（`x/work` vs `d/work`）⇒ 停在 2，
        // 不会因为另一条很深就整体加长。
        let shallow = ProjectPathLabels.labels(for: ["x/work", "/a/b/c/d/work"])
        #expect(shallow["x/work"] == "x/work")
        #expect(shallow["/a/b/c/d/work"] == "d/work")
        #expect(Set(shallow.values).count == 2)
    }
}
