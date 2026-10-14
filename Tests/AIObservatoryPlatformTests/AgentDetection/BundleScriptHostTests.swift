//
//  BundleScriptHostTests.swift
//  AIObservatoryPlatformTests — AgentDetection 子模块
//
//  Owner: ws/engaudit（#47 的修复，2026-09-21）
//  ─────────────────────────────────────────────────────────
//  #47 的落点：GUI 宿主自己起的 CLI 会话，六条策略一条都接不住（`AppHostedSessionBlindSpotTests`
//  把这件事钉成了事实）。总控 04:5x 裁定「要么加一条不靠父进程是 Terminal 的判据，
//  要么把命令采集与'先认出 Agent'解耦」，并明确**不许加产品签名**。
//
//  这组用例钉的是新那条结构判据的**边界**，而不只是"它能命中"：
//   · 正例：`.app` 内的进程把一个**位于该 bundle 之外**的 JS 入口当参数拉起；
//   · 反例：脚本在包内（应用自己的引导代码）、`.py`/`.ts`（别的语言运行时，真机 Xcode 那两条就是 `.py`）、
//     开关长得像文件名、进程不在任何 `.app` 内、系统路径；
//   · 它在策略链**最后**：任何具体签名都必须先于它命中，否则一个真 Codex 会被降级成 generic；
//   · 整链效果：宿主全家按 bundle 归并成**一行**（不是每条 helper 一行），
//     并且它名下 shell 里跑的命令要进 `commands` —— 这才是验收里"不再恒 0"那一半。
//
//  路径全部合成（`Host Workbench` / `/Users/dev/…`），不把本机装机情况写进仓。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

// MARK: - 夹具

private let hostBundle = "/Applications/Host Workbench.app"
private let hostExecutable = "\(hostBundle)/Contents/MacOS/Host Workbench"

/// 宿主主进程：launchd 直接拉起、没有 tty、argv 只有可执行路径本身（真机 04:2x 实测的形状）。
private func hostProcess(startedAt: Date) -> ProcessRecord {
    ProcessRecord(
        pid: 4052, parentPID: 1, name: "Host Workbench",
        executablePath: hostExecutable, arguments: [hostExecutable],
        startTime: startedAt
    )
}

/// 宿主以"外部插件入口"重新拉起自己的那个成员——新判据唯一的证据来源。
private func pluginRuntimeProcess(startedAt: Date) -> ProcessRecord {
    ProcessRecord(
        pid: 6136, parentPID: 4052, name: "Host Workbench",
        executablePath: hostExecutable,
        arguments: [hostExecutable, "/Users/dev/.plugincache/runtime/search.bundle.mjs", "mcp-bridge"],
        startTime: startedAt
    )
}

private func helperProcess(startedAt: Date) -> ProcessRecord {
    ProcessRecord(
        pid: 4387, parentPID: 4052, name: "Host Workbench Helper (Renderer)",
        executablePath: "\(hostBundle)/Contents/Frameworks/Host Workbench Helper (Renderer).app/Contents/MacOS/Host Workbench Helper (Renderer)",
        arguments: [hostExecutable, "--type=renderer"],
        startTime: startedAt
    )
}

/// 宿主为执行一条命令而拉起的 shell（无终端，正是 `TerminalSessionStrategy` 接不住的那一族）。
private func commandShell(startedAt: Date) -> ProcessRecord {
    ProcessRecord(
        pid: 97543, parentPID: 4052, name: "zsh",
        executablePath: "/bin/zsh", arguments: ["/bin/zsh", "-c", "true"],
        startTime: startedAt
    )
}

@Suite("WS-Agent：自带外部脚本运行时的 .app 宿主")
struct BundleScriptHostStrategyTests {

    @Test("包外的 JS 入口 ⇒ genericCLIAgent（argumentSignature，0.5）")
    func hitsExternalScriptHost() throws {
        let record = pluginRuntimeProcess(startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let hit = try #require(BundleScriptHostStrategy().detect(record, context: DetectionContext()))
        #expect(hit.kind == .genericCLIAgent)
        #expect(hit.signal == .argumentSignature)
        #expect(hit.confidence == 0.5)
    }

    @Test("反例五种：包内脚本 / .py / 开关像文件名 / 不在 .app 内 / 系统路径")
    func rejectsNearMisses() {
        let cases: [(String, ProcessRecord)] = [
            ("脚本在包内（应用自己的引导代码）", ProcessRecord(
                pid: 1, name: "Host Workbench", executablePath: hostExecutable,
                arguments: [hostExecutable, "\(hostBundle)/Contents/Resources/app/out/main.js"])),
            ("别的语言运行时（真机 Xcode 那两条就是 .py）", ProcessRecord(
                pid: 2, name: "python3", executablePath: hostExecutable,
                arguments: [hostExecutable, "/Users/dev/project/build.py"])),
            ("开关长得像文件名", ProcessRecord(
                pid: 3, name: "Host Workbench", executablePath: hostExecutable,
                arguments: [hostExecutable, "--enable-features=x.mjs"])),
            ("不在任何 .app 内（普通 node 跑插件，交给既有签名）", ProcessRecord(
                pid: 4, name: "node", executablePath: "/usr/local/bin/node",
                arguments: ["/usr/local/bin/node", "/Users/dev/.plugincache/runtime/search.bundle.mjs"])),
            ("系统路径（闸门优先于任何判据）", ProcessRecord(
                pid: 5, name: "mds", executablePath: "/System/Library/Frameworks/CoreServices.framework/Versions/A/Support/mds",
                arguments: ["/System/Library/Frameworks/CoreServices.framework/Versions/A/Support/mds", "/Users/dev/x.mjs"]))
        ]
        for (why, record) in cases {
            #expect(BundleScriptHostStrategy().detect(record, context: DetectionContext()) == nil, "误报：\(why)")
        }
    }

    @Test("排在策略链最后：具体签名先于它命中，宿主不会被降级")
    func runsLastInChainAndYieldsToRealSignatures() throws {
        let strategies = AgentDetectionPipeline.defaultStrategies
        #expect(strategies.count == 7, "策略链长度变了，'排最后'这件事不再成立")
        #expect(strategies.last?.name == "BundleScriptHost")

        // 一个真的 Codex 运行时（argv 带 codex 特征）同时满足新判据的形态时，
        // 必须先按具体身份落地，不能被 genericCLIAgent 顶掉。
        let codexLike = ProcessRecord(
            pid: 700, parentPID: 1, name: "codex",
            executablePath: "/Applications/ChatGPT.app/Contents/Resources/codex",
            arguments: ["/Applications/ChatGPT.app/Contents/Resources/codex", "/Users/dev/plugin.mjs"]
        )
        var first: (name: String, kind: AgentKind)?
        for strategy in strategies {
            if let result = strategy.detect(codexLike, context: DetectionContext()) {
                first = (strategy.name, result.kind)
                break
            }
        }
        let hit = try #require(first)
        #expect(hit.kind == .openAICodex, "被降级成了 \(hit.kind.rawValue)：\(hit.name)")
    }
}

@Suite("WS-Agent：GUI 宿主的整链效果")
struct GUIHostedSessionEndToEndTests {

    struct Snapshot: ProcessInspecting {
        let records: [ProcessRecord]
        func scanProcesses() async -> [ProcessRecord] { records }
    }

    @Test("宿主全家归并成一行，kind 是 genericCLIAgent，且名下 shell 的命令进了 commands")
    func bundleCollapsesToOneAgentAndItsCommandsFlow() async throws {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        // 命令是 shell 的**子进程**——它既不是 bundle 成员、也不在 agent 展示 pid 的子孙里，
        // 这一格正是"检出到了但采集仍漏"的那条缝（见 CommandInferenceEngine.candidatePIDs 的注释）。
        let command = ProcessRecord(
            pid: 98000, parentPID: 97543, name: "grep",
            executablePath: "/usr/bin/grep", arguments: ["/usr/bin/grep", "-c", "todo", "README.md"],
            startTime: base.addingTimeInterval(120), workingDirectory: "/Users/dev/Projects/Sites"
        )
        let records = [
            hostProcess(startedAt: base), pluginRuntimeProcess(startedAt: base.addingTimeInterval(60)),
            helperProcess(startedAt: base.addingTimeInterval(10)), commandShell(startedAt: base.addingTimeInterval(100)),
            command,
        ]
        let agents = await AgentDetectionPipeline().detectAgents(using: Snapshot(records: records))

        #expect(agents.count == 1, "宿主全家应归并成一行，实得 \(agents.map(\.pid))")
        let agent = try #require(agents.first)
        #expect(agent.kind == .genericCLIAgent)
        #expect(agent.detectedVia == .argumentSignature)
        // 展示 pid 是被检出的那个成员（行要说清凭什么认定），身份锚点仍是宿主 bundle。
        #expect(agent.pid == 6136)
        #expect(agent.childPIDs.contains(97543), "shell 没进名下：\(agent.childPIDs)")

        let commands = CommandInferenceEngine().inferCommands(
            processes: records, agents: agents, since: base
        )
        // 四条 = 宿主主进程 + 渲染 helper + shell + shell 里跑的那条命令。
        // 「App 自己的进程也算一次命令」是**既有语义**（bundle 行的 childPIDs 本来就含组成员），本轮没动它。
        // 而 shell 的子进程也在里面，靠的是 `AgentDetectionPipeline.bundleInstance` 第 216 行
        // 把**锚点（宿主主进程）的全部子孙**并进了 childPIDs —— 所以采集层一行都不用改，
        // 检出这一格补上，`commands` 就跟着活了。（我一开始以为要在 `candidatePIDs` 里再展开一次子孙，
        // 写了，变异一摘测试照样绿 ⇒ 那是空转，已撤。这条断言就是那件事的守卫。）
        #expect(
            commands.map(\.executable).sorted()
                == ["Host Workbench", "Host Workbench Helper (Renderer)", "grep", "zsh"]
        )
        let recorded = try #require(commands.first { $0.executable == "grep" })
        #expect(recorded.agentKind == .genericCLIAgent)
        #expect(recorded.agentID == agent.id)
        #expect(recorded.workingDirectory == "/Users/dev/Projects/Sites")
    }

    @Test("没有外部脚本入口时，宿主仍然不成行（这条判据不是'凡 GUI 皆 Agent'）")
    func plainAppStaysUndetected() async {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let records = [hostProcess(startedAt: base), helperProcess(startedAt: base.addingTimeInterval(10))]
        let agents = await AgentDetectionPipeline().detectAgents(using: Snapshot(records: records))
        #expect(agents.isEmpty, "一个只跑自己代码的普通 App 被当成了 Agent：\(agents.map(\.kind.rawValue))")
    }
}
