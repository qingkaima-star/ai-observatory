//
//  AppShellCopyTests.swift
//  AIObservatoryAppTests
//
//  Owner: master-controller（#72）
//  ─────────────────────────────────────────────────────────
//  另一半年在 `AIObservatoryUITests/AppShellCopyGateTests.swift`（扫裸中文字面量）。
//  这一份只能放这个 target：`AppShellCopy` 在 `AIObservatoryApp` 里，而 UITests 不依赖它。
//
//  为什么"扫源码"那一半不够：扫描只认"这一行有没有中文"，认不出**假双语**
//  （英文侧抄中文）、参数串位、同槽位类型不同。那三样要靠遍历 `bilingualCopy` 判 `problems`。
//  两边都缺一条就漏：只有清单 ⇒ 有人绕过表直接写字面量；只有扫描 ⇒ 表里填了个假英文。
//

import Foundation
import Testing

@testable import AIObservatoryApp
import AIObservatoryCore
import AIObservatoryTestSupport

@Suite("App 外壳文案表")
struct AppShellCopyTests {

    @Test("全部文案无缺陷（缺译 / 假双语 / 串位 / 同槽位类型不一致）")
    func noCopyProblems() {
        let broken = copyProblems(in: AppShellCopy.bilingualCopy)
        #expect(broken.isEmpty, "有 \(broken.count) 条不合格：\(broken)")
    }

    @Test("名字不重复（重复会让门禁报告指到错的那条）")
    func namesUnique() {
        #expect(duplicateCopyNames(in: AppShellCopy.bilingualCopy).isEmpty)
    }

    /// 分母守卫：豁免是按**文件名**给的（见 `AppShellCopyGateTests`），所以这张表被扫不到的
    /// 那条路必须靠条数量住。新增一条要同时改这一格并写明理由——不写理由就改大 = 偷偷扩豁免面。
    @Test("清单条数 = 登记的分母（漏挂进不了门禁）")
    func everyEntryIsListed() {
        #expect(AppShellCopy.bilingualCopy.count == 6,
                "清单是 \(AppShellCopy.bilingualCopy.count) 条而登记的分母是 6 ⇒ 要么漏挂了（那条永远查不到），要么改了这一格——请连理由一起写")
    }

    /// 每条都要**真的两种语言不同**：`problems` 管的是"英文含中文"，
    /// 而"英文 == 中文且不含中文"（比如两边都写 `OK`）它是查不出的，这里补一刀。
    @Test("两路逐条不同（英文侧不是复制来的）")
    func everyPairTranslated() {
        let same = AppShellCopy.bilingualCopy.filter {
            $0.copy.chineseSimplified == $0.copy.english
        }.map(\.name)
        #expect(same.isEmpty, "这些条英文侧与中文逐字相同：\(same)")
    }

    @Test("菜单三条都不带参数（本表不该出现要填值的句子）")
    func noParameterisedCopy() {
        let withArgs = AppShellCopy.bilingualCopy.filter { $0.copy.english.contains("%") }.map(\.name)
        #expect(withArgs.isEmpty,
                "外壳文案里出现了位置参数：\(withArgs) ⇒ 该走页面级文案表，或补接英文复数尺子")
    }
}
