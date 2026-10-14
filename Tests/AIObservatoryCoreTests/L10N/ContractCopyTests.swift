//
//  ContractCopyTests.swift
//  AIObservatoryCoreTests / L10N
//
//  Owner: master-controller（#67 第一片）
//  ─────────────────────────────────────────────────────────
//  这一片把 4 个契约枚举的 `displayName` 从"冻结区里的裸中文"改成
//  `ContractCopy`（非冻结）+ `displayName(_ language:)` 转发。用例守三件事：
//   1. **中文侧逐字不变**——这是既有产品的口径，改它属于文案决策，不该藏在一次"双语化"里；
//   2. **英文侧不许留汉字**——否则"接了语言参数"只是形似（真正上屏的还是中文）；
//   3. **枚举加 case 必须两路都给**——靠 `switch` 编译期覆盖，这里补一条分母，
//      防止有人把某条 case 塞进 `.unknown` 那种"顺手兜掉"。
//

import Foundation
import Testing

@testable import AIObservatoryCore

@Suite("契约层状态名双语化（#67 第一片）")
struct ContractCopyTests {

    @Test("表本身无缺陷（缺译 / 假双语 / 串位 / 同槽位类型不一致）")
    func noCopyProblems() {
        #expect(copyProblems(in: ContractCopy.bilingualCopy).isEmpty)
    }

    @Test("名字不重复")
    func namesUnique() {
        #expect(duplicateCopyNames(in: ContractCopy.bilingualCopy).isEmpty)
    }

    @Test("清单条数 = 分母（登记值，新增/删除要连理由一起改）")
    func listDenominator() {
        #expect(ContractCopy.bilingualCopy.count == 26,
                "本表登记 26 条（#67 第一片 19 + DetectionSignal 7），实际 \(ContractCopy.bilingualCopy.count) 条")
    }

    // MARK: - 中文侧逐字保真

    @Test("EngineState 中文侧与迁移前逐字相同")
    func engineStateChineseUnchanged() {
        let names = EngineState.allCasesForTest.map { $0.displayName }
        #expect(names == ["已停止", "启动中", "运行中", "降级运行", "异常"])
    }

    @Test("SessionOutcome / CommandOutcome / DroppedReason 中文侧与迁移前逐字相同")
    func otherChineseUnchanged() {
        let sessions = SessionOutcome.allCases.map { $0.displayName }
        #expect(sessions == ["进行中", "成功", "失败", "中断", "未知"])
        let commands = CommandOutcome.allCases.map { $0.displayName }
        #expect(commands == ["运行中", "Success", "Failure", "Terminated", "Unknown"])
        // ⚠️ 中文侧四条本来就是英文——那是既有产品事实，本片照抄（另单决策才改）。
        let dropped = MonitoringScope.Reason.allCasesForTest.map { $0.displayName }
        #expect(dropped == ["过浅：受保护根", "命中忽略规则", "空路径", "已被更浅的监控根覆盖"])
        let signals = DetectionSignal.allCasesForTest.map { $0.displayName }
        #expect(signals == ["进程名", "可执行文件路径", "Bundle Identifier", "父子进程树", "终端会话", "命令行特征", "未知信号"])
    }

    // MARK: - 英文侧真的换成了英文

    @Test("英文态四组名字里一个汉字都不许有")
    func englishHasNoHan() {
        var offenders: [String] = []
        offenders += EngineState.allCasesForTest.map { $0.displayName(.english) }
        offenders += SessionOutcome.allCases.map { $0.displayName(.english) }
        offenders += CommandOutcome.allCases.map { $0.displayName(.english) }
        offenders += MonitoringScope.Reason.allCasesForTest.map { $0.displayName(.english) }
        offenders += DetectionSignal.allCasesForTest.map { $0.displayName(.english) }
        let withHan = offenders.filter { $0.unicodeScalars.contains { 0x4E00...0x9FFF ~= $0.value } }
        #expect(withHan.isEmpty, "英文态仍夹中文：\(withHan)")
    }

    @Test("两路确实不同（除品牌/状态词外，英文不是复制来的）")
    func pairsDiffer() {
        let samePairs = ContractCopy.bilingualCopy.filter {
            $0.copy.chineseSimplified == $0.copy.english
        }.map(\.name)
        // 允许相同的只有 CommandOutcome 那四条中文侧本就是英文的（见文件头 ⚠️）。
        // 允许两路相同的只有"中文侧本来就是英文"的那五条（技术标识 / 状态词），改它们要另开决策。
        #expect(Set(samePairs) == Set([
            "contract.command.success", "contract.command.failure",
            "contract.command.terminated", "contract.command.unknown",
            "contract.signal.bundleIdentifier",
        ]), "两路相同的条目超出已知那五条：\(samePairs)")
    }

    // MARK: - 反向自证：尺子不是空转

    @Test("反向：把某条英文改成中文，门禁必须抓得到（证明上面那些断言在工作）")
    func rulerFiresWhenEnglishIsChinese() {
        let broken = LocalizedString(zh: "已停止", en: "已停止")
        #expect(!broken.problems.isEmpty, "英文侧写成中文却没被判为缺陷 ⇒ 这把尺子瞎了")
        #expect(EngineState.stopped.displayName(.english) != EngineState.stopped.displayName(.chineseSimplified))
    }
}

private extension EngineState {
    /// `EngineState` 本身不是 `CaseIterable`（契约里刻意不加，避免有人拿它当"全部状态"遍历），
    /// 所以测试自备一份**显式清单**——列漏一条，上面那几条逐字断言就会红。
    static let allCasesForTest: [EngineState] = [.stopped, .starting, .running, .degraded, .failed]
}

private extension DetectionSignal {
    /// 同 `EngineState`：契约刻意不给 `CaseIterable`，这里显式列全 ⇒ 漏列会让上面两条断言少一项。
    static let allCasesForTest: [DetectionSignal] = [
        .processName, .executablePath, .bundleIdentifier,
        .parentProcessTree, .terminalSession, .argumentSignature, .unknown,
    ]
}

private extension MonitoringScope.Reason {
    static let allCasesForTest: [MonitoringScope.Reason] = [
        .protectedRoot, .matchedIgnoredPattern, .emptyPath, .shadowedByShallowerRoot,
    ]
}
