//
//  SignatureStemsTests.swift
//  AIObservatoryPlatformTests — AgentDetection 子模块
//
//  Owner: WS-Platform（#55 · 扫描+策略链压预算）
//  ─────────────────────────────────────────────────────────
//  钉住 `DetectionHygiene.SignatureStems` 这条「快速否证」的**唯一安全边界**：
//  它是匹配的**必要条件**，只能放行、不得误拒。一旦它把一个真会命中的值判成「不沾」，
//  ArgumentSignature / ExecutablePath 就会静默漏检——那正是 #55 最怕的「检出面变了」。
//  本文件从两头夹住它：
//   · 正向：任何被某条签名命中的值，闸门必 `couldMatch == true`（用表里每条签名各造一个可命中夹具）；
//   · 反向：一条不含任何签名词的普通路径，闸门必须 `false`（这条红了就说明闸门在放行一切、优化是假的）。
//
//  ⚠️ 这两条都是**承重**断言：把 `SignatureStems.couldMatch` 改成恒 false，正向红；
//  改成恒 true，反向红。改完必须亲眼看到它们红过，否则就是假断言。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

@Suite("WS-Platform：词干否证是检出的超集（不误拒、也不形同虚设）")
struct SignatureStemsTests {

    /// 三条按分量/token 边界命中的策略用到的全部签名（合并成一个词干集，覆盖最宽）。
    private static let allStems = DetectionHygiene.SignatureStems(
        AgentSignaturePlan(AgentSignatureDatabase.shared).entries.flatMap {
            $0.pathFragments + $0.argumentSignatures + $0.appBundleNames
        }
    )

    @Test("每条签名的可命中夹具都被闸门放行")
    func gateAdmitsEveryMatchableValue() {
        let signatures = AgentSignaturePlan(AgentSignatureDatabase.shared).entries.flatMap {
            $0.pathFragments + $0.argumentSignatures + $0.appBundleNames
        }
        var checked = 0
        for sig in signatures where !sig.parts.isEmpty {
            // 构造一个确会被该签名命中的值：各段用 "/" 连起来，末段再缀 ".app"。
            // 末段的 "." 是右边界分隔符，故 tokenHasPrefix 成立；中间段整段相等。
            let value = "/" + sig.parts.joined(separator: "/") + ".app"
            let values = DetectionHygiene.componentValues(of: value)
            // 先确认夹具真被命中——否则这条测试没有意义（它没在测「可命中的值」）。
            #expect(
                DetectionHygiene.matches(sig, in: values),
                "夹具未命中其签名（测试自失支点）：value=\(value) parts=\(sig.parts)"
            )
            // 承重断言：能被命中 ⇒ 闸门必须放行。
            #expect(
                Self.allStems.couldMatch(in: [value]),
                "词干闸门误拒了一个真会命中的值：value=\(value) sigParts=\(sig.parts)"
            )
            checked += 1
        }
        // 闸门不能对空集自证——表里至少要有一批签名被检查过。
        #expect(checked >= 10, "只检查了 \(checked) 条签名，覆盖面不足以说明闸门生效")
    }

    @Test("普通非 Agent 进程被闸门直接否掉（优化真实生效，不是恒 true）")
    func gateRejectsPlainNonAgents() {
        // 真机上大量存在的普通进程：Safari / WindowServer / launchd / homebrew python 等。
        // 它们的 argv / 路径都不含任何 Agent 签名首段，闸门必须判 false，否则 #55 的省是没有的。
        let plain: [[String]] = [
            ["/Applications/Safari.app/Contents/MacOS/Safari"],
            ["/System/Library/CoreServices/WindowServer.app/Contents/MacOS/WindowServer", "-r"],
            ["/sbin/launchd"],
            ["/opt/homebrew/Cellar/python@3.12/3.12.1/Frameworks/Python.framework/Versions/3.12/Resources/Python.app/Contents/MacOS/Python", "build.py", "--flag=1"],
            ["/usr/libexec/secd", "-x"],
        ]
        for values in plain {
            #expect(
                !Self.allStems.couldMatch(in: values),
                "闸门把一条普通进程误当候选放行（优化失效）：\(values)"
            )
        }
    }

    @Test("含非 ASCII 的原始值一律保守放行，交给完整判定")
    func nonAsciiIsConservativelyAdmitted() {
        // 路径里带非 ASCII（真机偶见，如中文名目录）：闸门无法按字节折叠，必须判 true，
        // 让策略退回完整的 Unicode 口径判定——宁可多算，不可漏检。
        #expect(Self.allStems.couldMatch(in: ["/Users/张三/文档/项目.app/Contents/MacOS/runner"]))
    }

    /// 总控预裁定 #55 条 1 的**实证**：加闸门的策略与「无闸门参考实现」在同一份真机快照上逐条相等。
    ///
    /// 前面的必要条件是**推理**；这一条把「七条策略对同一份快照得出同样结果」直接钉成
    /// 对**当前这台机器全部进程**的逐记录相等断言。它是确定性的（同一份 `records` 两算，
    /// 不比时间），故可常跑、不进 env 门控。任一条真机进程上两条路径给出不同的 kind/
    /// signal/confidence，即闸门改动了检出面 ⇒ 红。
    @Test("真机快照逐条：加闸门结果 == 无闸门参考实现结果", .timeLimit(.minutes(1)))
    func gatedEqualsUngatedOnLiveSnapshot() async {
        let records = await LibprocProcessInspector().scanProcesses()
        #expect(records.count > 100, "快照只有 \(records.count) 条，环境异常，本断言无意义")

        let argStrategy = ArgumentSignatureStrategy()
        let pathStrategy = ExecutablePathStrategy()
        let plan = AgentSignaturePlan(AgentSignatureDatabase.shared)
        let ctx = DetectionContext()   // 这两条策略不读 ancestors

        var argChecked = 0
        var pathChecked = 0
        for record in records {
            let gatedArg = argStrategy.detect(record, context: ctx)
            #expect(
                gatedArg == Self.ungatedArgumentHit(record, plan: plan),
                "闸门改动了 ArgumentSignature 对 pid \(record.pid)（\(record.executablePath)）的判定"
            )
            argChecked += 1

            let gatedPath = pathStrategy.detect(record, context: ctx)
            #expect(
                gatedPath == Self.ungatedExecutablePathHit(record, plan: plan),
                "闸门改动了 ExecutablePath 对 pid \(record.pid)（\(record.executablePath)）的判定"
            )
            pathChecked += 1
        }
        #expect(argChecked == records.count && pathChecked == records.count)
    }

    /// `ArgumentSignatureStrategy.detect` 去掉 `SignatureStems` 闸门后的等价参考实现
    /// （逐段照抄闸门之后的原判定式，唯独不做早退）。
    private static func ungatedArgumentHit(
        _ record: ProcessRecord, plan: AgentSignaturePlan
    ) -> AgentDetectionResult? {
        guard !record.executablePath.isEmpty else { return nil }
        guard !DetectionHygiene.isSystemProcessPath(record.executablePath) else { return nil }
        let values = DetectionHygiene.componentValues(of: record.arguments + [record.executablePath])
        for entry in plan.entries where !entry.argumentSignatures.isEmpty {
            if entry.argumentSignatures.contains(where: { DetectionHygiene.matches($0, in: values) }) {
                return AgentDetectionResult(kind: entry.kind, signal: .argumentSignature, confidence: 0.72)
            }
        }
        return nil
    }

    /// `ExecutablePathStrategy.detect` 去掉闸门后的等价参考实现。
    private static func ungatedExecutablePathHit(
        _ record: ProcessRecord, plan: AgentSignaturePlan
    ) -> AgentDetectionResult? {
        let path = record.executablePath
        guard !path.isEmpty else { return nil }
        guard !DetectionHygiene.isSystemProcessPath(path) else { return nil }
        let values = DetectionHygiene.componentValues(of: path)
        for entry in plan.entries where !entry.pathFragments.isEmpty {
            if entry.pathFragments.contains(where: { DetectionHygiene.matches($0, in: values) }) {
                return AgentDetectionResult(kind: entry.kind, signal: .executablePath, confidence: 0.92)
            }
        }
        return nil
    }
}
