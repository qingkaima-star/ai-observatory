//
//  AgentDetectionTests.swift
//  AIObservatoryPlatformTests — AgentDetection 子模块
//
//  Owner: WS-Agent
//  ─────────────────────────────────────────────────────────
//  覆盖 LibprocProcessInspector / ProcessTreeBuilder /
//  AgentSignatureDatabase / DetectionStrategies /
//  AgentDetectionPipeline / EndpointSecurityMonitor 的真实行为。
//
//  说明：涉及本机真实进程的测试（scan / 性能 / CPU）在本机实测，
//  非确定性断言（如「是否检测到某个具体 Agent」）仅做弱校验，
//  保证「若检测到则信号语义正确」，避免 CI 抖动。
//
//  真进程扫描的两个 suite 挂 `.timeLimit`：这类 suite 历史上把闸门挂死过两次，
//  而没有上限的等待一旦挂住，看到的是「CI 无输出」而不是「某条用例红」。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

// MARK: - 真实进程扫描

@Suite("WS-Agent：libproc 真实进程扫描", .timeLimit(.minutes(1)))
struct LibprocProcessInspectorTests {

    @Test("scanProcesses 返回 ≥ 100 条真实进程")
    func returnsManyProcesses() async {
        let inspector = LibprocProcessInspector()
        let procs = await inspector.scanProcesses()
        #expect(procs.count >= 100, "实际进程数: \(procs.count)")
    }

    /// **病理防线**，不是性能预算判据——这个区别是这条用例存在的全部理由。
    ///
    /// 原来它写的是「单次扫描 < 300 ms（宽松阈值，防抖动）」，在 load 28 + 别人的
    /// `swift-frontend` 占 96% 的那次全量里红过（**427 ms**），而单跑三次只有 52–58 ms
    /// ⇒ 同一颗二进制差 **8 倍**。所以墙钟毫秒在共享机器上根本量不到"我们花了多少"，
    /// 任何固定阈值都会随机红，判据② 的「全绿」就不可能复现。
    ///
    /// 两把尺子各管各的，不许互相顶替：
    /// - **真预算**（AGENTS.md §6：进程扫描 < 50 ms/次、上限 150 ms/次）
    ///   由静默窗仪器判：`Tools/UIProbe/measure-idle.sh`（release 包、Δcputime / 墙钟、窗口 ≥180 s）。
    ///   在没有别的编译任务的机器上测，是验收判据④ 的事。
    /// - **这里**只挡"算法塌掉"那一类：O(N²) 重建（#21 的真实根因）、每进程重复全表扫描、
    ///   死循环。这类退化在 1,000+ 进程的机器上是**秒级到分钟级**，
    ///   所以阈值放到 1.5 s 仍然拦得住它，同时拦不住"别人正在编译"这种噪声。
    ///
    /// 取**中位数**而不是单次：单次会被一次调度尖峰顶穿，而退化是持续的。
    @Test("单次扫描耗时 < 1.5 s（病理防线；真预算归静默窗仪器）")
    func scanPerformance() async {
        let inspector = LibprocProcessInspector()
        // 预热一次（同时建立 CPU 基线）。
        _ = await inspector.scanProcesses()
        var samples: [TimeInterval] = []
        samples.reserveCapacity(5)
        for _ in 0..<5 {
            let start = Date()
            _ = await inspector.scanProcesses()
            samples.append(Date().timeIntervalSince(start))
        }
        let median = samples.sorted()[samples.count / 2]
        let context = "5 次采样(ms)=" + samples.map { String(format: "%.0f", $0 * 1000) }.joined(separator: ", ")
        #expect(median < 1.5,
                "扫描中位数 \(String(format: "%.0f", median * 1000)) ms ≥ 1.5 s ⇒ 疑似算法退化（不是负载噪声）。\(context)")
    }

    @Test("首次扫描 CPU 占用率恒为 0（两次采样求差的正确行为）")
    func firstScanCPUIsZero() async {
        let inspector = LibprocProcessInspector()
        let procs = await inspector.scanProcesses()
        #expect(procs.allSatisfy { $0.cpuPercent == 0 })
    }

    @Test("两次扫描后 CPU 占用率为有限且非负")
    func cpuSamplingNonNegative() async {
        let inspector = LibprocProcessInspector()
        _ = await inspector.scanProcesses()
        // 等待一小段时间让 CPU 时间累计。
        try? await Task.sleep(nanoseconds: 50_000_000)
        let procs = await inspector.scanProcesses()
        for p in procs {
            #expect(p.cpuPercent.isFinite)
            #expect(p.cpuPercent >= 0)
        }
    }

    @Test("进程记录字段不编造：可读取 pid / 启动时间 / 路径")
    func fieldsAreReal() async {
        let inspector = LibprocProcessInspector()
        let procs = await inspector.scanProcesses()
        // 至少应有一个进程能被完整读取（pid 与 name 非空）。
        #expect(procs.contains { !$0.name.isEmpty && $0.pid > 0 })
    }
}

// MARK: - 进程树

@Suite("WS-Agent：进程树关系查询")
struct ProcessTreeBuilderTests {

    @Test("ancestors 返回从近到远的祖先链")
    func ancestorsChain() {
        let grand = ProcessRecord(pid: 10, name: "g", executablePath: "/g")
        let parent = ProcessRecord(pid: 20, parentPID: 10, name: "p", executablePath: "/p")
        let child = ProcessRecord(pid: 30, parentPID: 20, name: "c", executablePath: "/c")
        let ancestors = ProcessTreeBuilder.ancestors(of: 30, records: [grand, parent, child])
        #expect(ancestors.map(\.pid) == [20, 10])
    }

    @Test("descendantPIDs 收集全部子孙")
    func descendantCollection() {
        let root = ProcessRecord(pid: 1, name: "r", executablePath: "/r")
        let mid = ProcessRecord(pid: 2, parentPID: 1, name: "m", executablePath: "/m")
        let leaf = ProcessRecord(pid: 3, parentPID: 2, name: "l", executablePath: "/l")
        let desc = ProcessTreeBuilder.descendantPIDs(of: 1, records: [root, mid, leaf]).sorted()
        #expect(desc == [2, 3])
    }
}

// MARK: - 特征库

@Suite("WS-Agent：Agent 特征库")
struct AgentSignatureDatabaseTests {

    @Test("覆盖契约要求的 ≥ 6 种 Agent 类型")
    func coversRequiredKinds() {
        let db = AgentSignatureDatabase.shared
        let kinds = Set(db.entries.map(\.kind))
        let required: [AgentKind] = [.claudeCode, .openAICodex, .cursorAgent, .windsurf, .vscodeCopilot, .geminiCLI, .aiderCLI]
        for k in required {
            #expect(kinds.contains(k), "缺失特征: \(k.displayName)")
        }
        #expect(db.entries.count >= 6)
    }
}

// MARK: - 检测策略

@Suite("WS-Agent：单条检测策略")
struct DetectionStrategyTests {

    @Test("ExecutablePath 命中 Cursor 主程序")
    func exePathCursor() {
        let rec = ProcessRecord(pid: 1, name: "Cursor", executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        let result = ExecutablePathStrategy().detect(rec, context: DetectionContext())
        #expect(result?.kind == .cursorAgent)
        #expect(result?.signal == .executablePath)
    }

    @Test("ArgumentSignature 命中 node 跑的 claude（进程名仅为 node）")
    func argSignatureNodeClaude() {
        let rec = ProcessRecord(
            pid: 1234, parentPID: 999, name: "node",
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/bin/claude", "--dangerously-skip-permissions"]
        )
        let result = ArgumentSignatureStrategy().detect(rec, context: DetectionContext())
        #expect(result?.kind == .claudeCode)
        #expect(result?.signal == .argumentSignature)
    }

    @Test("ProcessName 命中 codex 进程名")
    func processNameCodex() {
        let rec = ProcessRecord(pid: 5, name: "codex", executablePath: "/usr/local/bin/codex")
        let result = ProcessNameStrategy().detect(rec, context: DetectionContext())
        #expect(result?.kind == .openAICodex)
        #expect(result?.signal == .processName)
    }

    @Test("BundleIdentifier 对非 .app 进程返回 nil（确定性守卫）")
    func bundleIDGuard() {
        let rec = ProcessRecord(pid: 7, name: "node", executablePath: "/usr/local/bin/node")
        let result = BundleIdentifierStrategy().detect(rec, context: DetectionContext())
        #expect(result == nil)
    }

    @Test("TerminalSession 仅在 tty + 终端祖先 + agent 关键字时命中")
    func terminalSessionFallback() {
        let terminal = ProcessRecord(pid: 100, name: "Terminal", executablePath: "/System/Library/CoreServices/Terminal.app/Contents/MacOS/Terminal")
        let agent = ProcessRecord(
            pid: 200, parentPID: 100, name: "node",
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/bin/claude"],
            tty: "ttys005"
        )
        let ctx = DetectionContext(ancestors: [terminal])
        let result = TerminalSessionStrategy().detect(agent, context: ctx)
        #expect(result?.kind == .claudeCode || result?.kind == .genericCLIAgent)
        #expect(result?.signal == .terminalSession)
    }
}

// MARK: - 管线

@Suite("WS-Agent：检测管线", .timeLimit(.minutes(1)))
struct AgentDetectionPipelineTests {

    /// 桩采集器，返回固定记录，便于确定性测试。
    struct MockInspector: ProcessInspecting {
        let records: [ProcessRecord]
        func scanProcesses() async -> [ProcessRecord] { records }
    }

    @Test("管线从 node-claude 合成记录识别出 claudeCode，信号为 argumentSignature")
    func detectsClaudeFromNode() async {
        let shell = ProcessRecord(pid: 999, name: "zsh", executablePath: "/bin/zsh")
        let claude = ProcessRecord(
            pid: 1234, parentPID: 999, name: "node",
            executablePath: "/usr/local/bin/node",
            arguments: ["node", "/usr/local/bin/claude", "--dangerously-skip-permissions"],
            startTime: Date().addingTimeInterval(-3600)
        )
        let mock = MockInspector(records: [shell, claude])
        let agents = await AgentDetectionPipeline().detectAgents(using: mock)

        #expect(agents.count == 1)
        #expect(agents.first?.kind == .claudeCode)
        #expect(agents.first?.detectedVia == .argumentSignature)
        #expect(agents.first?.childPIDs == [])
    }

    @Test("管线为识别出的 Agent 计算 childPIDs")
    func computesChildPIDs() async {
        let parent = ProcessRecord(pid: 100, name: "cursor", executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor")
        let child = ProcessRecord(pid: 200, parentPID: 100, name: "Cursor Helper", executablePath: "/Applications/Cursor.app/Contents/MacOS/Cursor Helper")
        let mock = MockInspector(records: [parent, child])
        let agents = await AgentDetectionPipeline().detectAgents(using: mock)
        #expect(agents.contains { $0.pid == 100 && $0.childPIDs == [200] })
    }

    @Test("真实扫描：若识别出 Agent，其 detectedVia 必非 unknown")
    func realScanSignalSemantics() async {
        let inspector = LibprocProcessInspector()
        let agents = await AgentDetectionPipeline().detectAgents(using: inspector)
        // 弱断言：不强制本机一定在跑 Agent，但一旦识别，信号必须有意义。
        #expect(agents.allSatisfy { $0.detectedVia != .unknown })
    }

    @Test("realtimeCapability 在无 ES 授权时优雅降级为 processPolling")
    func realtimeCapabilityDegrades() {
        let cap = AgentDetectionPipeline().realtimeCapability()
        #expect(cap == .processPolling || cap == .endPointSecurity)
        // 本环境（无 entitlement）必定为轮询模式。
        #expect(cap == .processPolling)
    }
}

// MARK: - 误报回归（真机实测抓出）

@Suite("WS-Agent：进程树策略不误报")
struct ParentProcessTreeFalsePositiveTests {

    private func record(_ pid: Int32, _ name: String, _ path: String) -> ProcessRecord {
        ProcessRecord(pid: pid, parentPID: pid - 1, name: name, executablePath: path)
    }

    /// 签名里的 `"Code.app"` 曾经用裸子串匹配，于是 `/Applications/Xcode.app/...`
    /// 命中 `"Xcode.app"` 结尾的 `"Code.app"`，把每个 Xcode 编译进程都判成 Copilot
    /// ——实测 30 秒内凭空多出 25 个 Agent。
    @Test("Xcode 工具链进程不得被判为 VS Code Copilot")
    func xcodeToolchainIsNotCopilot() {
        let strategy = ParentProcessTreeStrategy()
        let ancestors = [
            record(1, "Code", "/Applications/Visual Studio Code.app/Contents/MacOS/Code")
        ]
        let context = DetectionContext(ancestors: ancestors)

        for path in [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend",
            "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/xctest",
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-driver"
        ] {
            let name = (path as NSString).lastPathComponent
            let result = strategy.detect(record(2, name, path), context: context)
            #expect(
                result?.kind != .vscodeCopilot,
                "误报：\(path) 被判成 \(String(describing: result?.kind))"
            )
        }
    }

    /// 同一策略仍要能认出真正的编辑器子进程。
    ///
    /// 口径更新（WS-Detect）：**内嵌 helper bundle**（`Code Helper.app` 套在
    /// `Visual Studio Code.app` 里）不再由这条策略单独成行——它与宿主同属一个 bundle，
    /// 由 `AgentDetectionPipeline` 归并进宿主那一行（见 `BundleAggregationTests`）。
    /// 这里用非内嵌布局的 `Contents/MacOS/Code Helper`，验证策略本身仍然有效。
    @Test("真正的 VS Code 子进程仍被识别")
    func genuineVSCodeHelperStillDetected() {
        let strategy = ParentProcessTreeStrategy()
        let ancestors = [
            record(1, "Code", "/Applications/Visual Studio Code.app/Contents/MacOS/Code")
        ]
        let context = DetectionContext(ancestors: ancestors)
        let helper = record(
            2,
            "Code Helper",
            "/Applications/Visual Studio Code.app/Contents/MacOS/Code Helper"
        )
        #expect(strategy.detect(helper, context: context)?.kind == .vscodeCopilot)
    }

    /// 祖先链只看最近 3 层：distant ancestor 不代表从属关系。
    @Test("超过 3 层的祖先不参与归属判定")
    func distantAncestorIgnored() {
        let strategy = ParentProcessTreeStrategy()
        let editor = record(1, "Code", "/Applications/Visual Studio Code.app/Contents/MacOS/Code")
        let context = DetectionContext(
            ancestors: [
                record(2, "zsh", "/bin/zsh"),
                record(3, "login", "/usr/bin/login"),
                record(4, "launchd", "/sbin/launchd"),
                editor
            ]
        )
        let helper = record(
            5,
            "Code Helper",
            "/Applications/Visual Studio Code.app/Contents/Frameworks/Code Helper.app/Contents/MacOS/Code Helper"
        )
        #expect(strategy.detect(helper, context: context) == nil)
    }
}

@Suite("WS-Agent：Agent 身份跨扫描稳定")
struct AgentIdentityTests {

    @Test("同一 (pid, 启动时刻) 恒定得到同一 id")
    func stableAcrossScans() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let first = AgentIdentity.id(pid: 4242, startedAt: start)
        for _ in 0..<5 {
            #expect(AgentIdentity.id(pid: 4242, startedAt: start) == first)
        }
    }

    @Test("pid 复用（启动时刻不同）得到不同 id")
    func pidReuseDistinguished() {
        let a = AgentIdentity.id(pid: 4242, startedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let b = AgentIdentity.id(pid: 4242, startedAt: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(a != b)
    }

    @Test("亚秒抖动不改变身份")
    func subsecondJitterIgnored() {
        let a = AgentIdentity.id(pid: 7, startedAt: Date(timeIntervalSince1970: 1_700_000_000.10))
        let b = AgentIdentity.id(pid: 7, startedAt: Date(timeIntervalSince1970: 1_700_000_000.90))
        #expect(a == b)
    }
}
