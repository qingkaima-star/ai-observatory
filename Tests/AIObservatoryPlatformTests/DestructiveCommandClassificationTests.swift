//
//  DestructiveCommandClassificationTests.swift
//  AIObservatoryPlatformTests
//
//  Owner: WS-l10nb（#56 · 删掉零消费者的规则理由族之后留下的那一条真断言）
//  ─────────────────────────────────────────────────────────
//  这个文件原来叫 `PlatformBilingualCopyTests.swift`，五条用例里有四条在守
//  `PlatformCopy.bilingualCopy`（32 对规则理由 + 1 对敏感路径句）与 `Rule.reason` 那条接线。
//  #56 把那一批连同字段一起删了（理由：唯一出路 `CommandClassification.reason` 已被
//  ADR-0010 删掉，敏感路径那句也是算完就丢 ⇒ 双语化完成但没有一条会进眼睛）。
//  **守空集的门禁比没有门禁更坏**，所以那四条随对象一起消失，没有改成恒真式留着。
//
//  留下来的只有这一条：它测的是分级结果**不携带文本**、命中类别判得对——
//  这两件事在删掉文案表之后依然成立，而且正是"为什么可以删"的正面证据。
//  文件名跟着改：一份不再守任何文案表的用例不该叫 BilingualCopyTests。
//
//  ⚠️ 别把这条误删成"下一族的清理"：风险规则自己的 `rationaleTemplate`
//  （写进 `RiskEvent.detail`、屏幕上叫「判定依据」）是**另一条活通道**，一行都不在这里。
//

import Testing
@testable import AIObservatoryPlatform

@Suite("采集层：危险命令分级只给结论、不给文本")
struct DestructiveCommandClassificationTests {

    /// 分级结果本身**不携带文案**（ADR-0010 删掉 `CommandClassification.reason`，
    /// #56 又删掉规则表侧的 `Rule.reason`）。
    ///
    /// 它真正要防的事从始至终没变：**英文机位上不许出现中文**。现在的保证比原来强——
    /// 分级结论里根本没有文本可漏（声明侧由 `PlatformContractTests.carriesNoHumanReadableText` 钉住），
    /// 而"依据"只在 `RiskEvent.detail` 那一条活通道上屏，语言由 B2 的写入时冻结口径管。
    @Test("分级结果只给结论、不给文本；命中与否按规则表判定")
    func classifyCarriesVerdictsNotText() {
        let verdict = DestructiveCommandRules().classify(command: "rm -rf ./build")
        #expect(verdict.isDestructive)
        #expect(verdict.requiresConfirmation)
        #expect(verdict.category != nil, "rm -rf 必须归到某个类别，否则风险页那一行只剩等级")

        // 敏感路径那一条：命中与否取决于 `PathHeuristics`，所以只在命中时断言类别，
        // 不拿它当"必然命中"的前提（沿用原用例那份诚实）。
        let sensitive = DestructiveCommandRules().classify(command: "cat ~/.ssh/id_rsa")
        if sensitive.isDestructive {
            #expect(sensitive.category == .sensitivePathAccess,
                    "敏感路径支路命中了却报了别的类别：\(String(describing: sensitive.category))")
        }
    }
}
