//
//  AppHostedSessionBlindSpotTests.swift
//  AIObservatoryPlatformTests — AgentDetection 子模块
//
//  Owner: ws/engaudit（#47 诊断，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  钉住「宿主是 GUI 应用、会话由它自己拉起」这一族进程的检出盲区**到底卡在哪一格**。
//  #47 报的是「三个干活的 CLI 会话没被归类成任何 AgentKind」，怀疑对象是
//  `TerminalSessionStrategy` 的 `genericCLIAgent` 兑底。这组用例把怀疑换成事实：
//   · 门在哪：真机那一条形状（无 tty、父进程是 launchd、argv 只有可执行路径本身）
//     在**默认策略链上全部不命中**（钉单测时是六条，#47 修复后是七条），不是只有兑底那一格没接住；
//   · 为什么没接住：特征库里没有任何一条签名对得上那个形状（表级全称断言，
//     与 `Bundle(url:)` 这类真实 IO 无关，因此不会因换台机器而变绿）；
//   · 放开终端祖先那道门够不够：不够（argv 里没有可命中的 token）；
//   · 「加一条产品签名了事」为什么不够：带空格的可执行文件名让裸 token 型签名
//     在最后一个分量上匹不上（右边界只认 `.` `_` `[`）。
//
//  路径全部是合成产品名（`Host Workbench.app`），一是不把真机装机情况写进仓库，
//  二是让 `Bundle(url:)` 拿不到东西、BundleIdentifier 那格保持封闭。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

// MARK: - 真机形状

/// 真机 2026-09-21 dogfood 第二轮实测到的那一条（产品名换成合成的）：
/// `ps -o args=` 只有可执行路径本身 ⇒ argv 长度为 1、没有参数；`ps -o tty=` 是 `??`；父进程 pid 1。
private let hostExecutablePath = "/Applications/Host Workbench.app/Contents/MacOS/Host Workbench"

private let appHostedSession = ProcessRecord(
    pid: 4052,
    parentPID: 1,
    name: "Host Workbench",
    executablePath: hostExecutablePath,
    arguments: [hostExecutablePath]
)

@Suite("WS-Agent：GUI 宿主拉起的会话为什么检不出")
struct AppHostedSessionBlindSpotTests {

    @Test("宿主主进程这一格：七条默认策略全部不命中（并钉住『七条』本身）")
    func everyDefaultStrategyIgnoresAnAppHostedSession() {
        let strategies = AgentDetectionPipeline.defaultStrategies
        // 全称断言最怕「循环体一次都没跑」：链上少一条策略、或空数组，都会让它假绿。
        // 2026-09-21 起是七条（#47 的修复加了 `BundleScriptHostStrategy`）。
        // 这一格仍然全不命中是**有意的**：宿主主进程的 argv 只有可执行路径本身，
        // 新判据的证据长在它那个"带外部脚本参数"的兄弟进程上（见 `BundleScriptHostTests`）——
        // 归并按最外层 bundle 收，兄弟命中就够整家长出一行。
        #expect(strategies.count == 7, "默认策略链长度变了，本用例的全称断言不再覆盖七条")

        let names = strategies.compactMap { strategy in
            strategy.detect(appHostedSession, context: DetectionContext()).map { "\(strategy.name)→\($0.kind.rawValue)" }
        }
        #expect(names.isEmpty, "下列策略命中了 GUI 宿主会话：\(names.joined(separator: ", "))")
    }

    @Test("命不中的原因是特征库里没有对得上的签名（表级断言，不依赖真实 bundle IO）")
    func signatureTableHasNothingMatchingTheHostShape() {
        let pathValues = DetectionHygiene.componentValues(of: hostExecutablePath)
        let argvValues = DetectionHygiene.componentValues(of: [hostExecutablePath])
        let lowercasedName = appHostedSession.name.lowercased()
        var hits: [String] = []
        for entry in AgentSignatureDatabase.shared.entries {
            if entry.pathFragments.contains(where: { DetectionHygiene.matches($0, in: pathValues) }) {
                hits.append("\(entry.kind.rawValue).pathFragments")
            }
            if entry.appBundleNames.contains(where: { DetectionHygiene.matches($0, in: pathValues) }) {
                hits.append("\(entry.kind.rawValue).appBundleNames")
            }
            if entry.argumentSignatures.contains(where: { DetectionHygiene.matches($0, in: argvValues) }) {
                hits.append("\(entry.kind.rawValue).argumentSignatures")
            }
            if entry.processNames.contains(lowercasedName) {
                hits.append("\(entry.kind.rawValue).processNames")
            }
            if entry.processNamePrefixes.contains(where: { lowercasedName.hasPrefix($0.lowercased()) }) {
                hits.append("\(entry.kind.rawValue).processNamePrefixes")
            }
        }
        #expect(hits.isEmpty, "特征库里出现了对得上该形状的签名：\(hits.joined(separator: ", "))")
    }

    @Test("放开『祖先须含终端模拟器』也接不住：argv 里没有可命中的 token")
    func terminalGateIsNotTheOnlyGate() {
        let terminal = ProcessRecord(
            pid: 100,
            name: "Terminal",
            executablePath: "/System/Library/CoreServices/Terminal.app/Contents/MacOS/Terminal"
        )
        let context = DetectionContext(ancestors: [terminal])
        let withTTY = ProcessRecord(
            pid: 4052,
            parentPID: 1,
            name: "Host Workbench",
            executablePath: hostExecutablePath,
            arguments: [hostExecutablePath],
            tty: "ttys009"
        )
        #expect(
            TerminalSessionStrategy().detect(withTTY, context: context) == nil,
            "补了 tty 与终端祖先就命中 ⇒ 拦着它的不只是终端那道门"
        )

        // 同一套祖先与 tty，只把 argv 换成真带特征的一条 ⇒ 兑底必须接住。
        // 没有这一半，上面那条 nil 可能只是策略整个坏了。
        let realCLI = ProcessRecord(
            pid: 4053,
            parentPID: 100,
            name: "node",
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/bin/claude"],
            tty: "ttys009"
        )
        let hit = TerminalSessionStrategy().detect(realCLI, context: context)
        #expect(hit?.kind == .claudeCode)
        #expect(hit?.signal == .terminalSession)
    }

    @Test("带空格的可执行文件名：裸 token 签名匹不上，必须写成 bundle 形态")
    func bareTokenSignatureCannotMatchANameContainingASpace() {
        let values = DetectionHygiene.componentValues(of: hostExecutablePath)
        // 最后一个分量是 `host workbench`；`host` 只是它的裸前缀，而右边界只认 `.` `_` `[`，
        // 空格不算 ⇒ 这条签名对该形状**永远不命中**（写进表里就是一张死签名）。
        #expect(!DetectionHygiene.matches("host", in: values))
        #expect(!DetectionHygiene.matches("/host", in: values))
        // 能命中的写法只有这两种形态：bundle 名（容器形态）与整段带空格的文件名。
        #expect(DetectionHygiene.matches("Host Workbench.app", in: values))
        #expect(DetectionHygiene.matches("/host workbench", in: values))
    }
}
