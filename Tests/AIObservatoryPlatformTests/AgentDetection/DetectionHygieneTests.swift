//
//  DetectionHygieneTests.swift
//  AIObservatoryPlatformTests — AgentDetection 子模块
//
//  Owner: WS-Detect
//  ─────────────────────────────────────────────────────────
//  检出层卫生规则的回归套件。每条用例都对应 2026-09-20 真机跑出来的一个缺陷
//  （见 AiX-Vault/01-架构/真机验证-命令审计与检出.md 的 N3 / N4）：
//   · N4 系统服务被裸子串判成 Agent；
//   · N3 一个 Codex 桌面会话被拆成 22 行；
//   · 空可执行路径仍凭 argv 出检出。
//  用例里的路径都是**编造的宿主外路径**（/Users/testhost/…，以及从 `FixturePaths` 派生的
//  合成家目录 /Users/dev/…），
//  一是不把真机路径写进仓库，二是让 Bundle(url:) 之类真实 IO 拿不到东西、测试保持封闭。
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore
import AIObservatoryTestSupport

// MARK: - 测试用替身

/// 固定进程快照的桩采集器。
private struct StubInspector: ProcessInspecting {
    let records: [ProcessRecord]
    func scanProcesses() async -> [ProcessRecord] { records }
}

/// 六条默认策略，用于「任何策略都不得命中」这类全称断言。
private let allStrategies: [any AgentDetectionStrategy] = AgentDetectionPipeline.defaultStrategies

private func stub(
    _ pid: Int32,
    _ name: String,
    _ path: String,
    parent: Int32? = nil,
    arguments: [String] = [],
    startedAt: Date? = nil,
    tty: String? = nil,
    cwd: String? = nil
) -> ProcessRecord {
    ProcessRecord(
        pid: pid,
        parentPID: parent,
        name: name,
        executablePath: path,
        arguments: arguments.isEmpty ? [name] : arguments,
        startTime: startedAt,
        tty: tty,
        workingDirectory: cwd
    )
}

// MARK: - 1. 系统进程闸门（N4）

@Suite("WS-Detect：系统进程一律不参与 Agent 匹配")
struct SystemProcessGateTests {

    /// 真机 N4 的原始记录：macOS 输入候选窗服务被 `argumentSignatures:["cursor"]` 判成 Cursor Agent。
    /// 这里连 argv 都直接给了整 token `cursor`，仍然必须是 nil——闸门与边界匹配双保险。
    private let cursorUIViewService = stub(
        1342,
        "CursorUIViewService",
        "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/"
            + "CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService",
        arguments: ["CursorUIViewService", "-service-type", "cursor"]
    )

    @Test("CursorUIViewService.xpc 在全部六条策略下都返回 nil")
    func systemXPCNeverDetected() {
        for strategy in allStrategies {
            #expect(
                strategy.detect(cursorUIViewService, context: DetectionContext()) == nil,
                "\(strategy.name) 把系统 XPC 服务判成了 Agent"
            )
        }
    }

    @Test("isSystemProcessPath 覆盖工单要求的四类位置")
    func excludedPrefixes() {
        #expect(DetectionHygiene.isSystemProcessPath("/System/Library/Foo/Foo"))
        #expect(DetectionHygiene.isSystemProcessPath("/usr/libexec/taskgated"))
        #expect(DetectionHygiene.isSystemProcessPath("/usr/sbin/securityd"))
        #expect(DetectionHygiene.isSystemProcessPath("/Applications/Foo.app/Contents/XPCServices/Bar.xpc/Contents/MacOS/Bar"))
    }

    @Test("用户可执行路径不被误排除（含 firmlink 数据卷）")
    func userPathsSurvive() {
        #expect(!DetectionHygiene.isSystemProcessPath("/usr/local/bin/claude"))
        #expect(!DetectionHygiene.isSystemProcessPath("/opt/homebrew/bin/codex"))
        #expect(!DetectionHygiene.isSystemProcessPath(FixturePaths.inHome(".codex/bin/codex")))
        // firmlink：/System/Volumes/Data 前缀其实是用户数据卷，按系统区排除会漏检真 Agent。
        #expect(!DetectionHygiene.isSystemProcessPath("/System/Volumes/Data\(FixturePaths.home)/.local/bin/claude"))
        // 空路径不是「系统进程」而是「身份未知」：由「取不到可执行路径就不检出」那条规则负责。
        #expect(!DetectionHygiene.isSystemProcessPath(""))
    }
}

// MARK: - 2. 按分量 / token 边界匹配（N4 同类错误）

@Suite("WS-Detect：签名只在分量与 token 边界命中")
struct BoundaryMatchingTests {

    @Test("`/codex` 只认可执行文件名，不认同名目录与同名前缀")
    func codexFragmentAnchoring() {
        let values = DetectionHygiene.componentValues(of: "/Users/testhost/projects/codex/scratch.py")
        #expect(!DetectionHygiene.matches("/codex", in: values), "同名目录被当成了 Codex 可执行文件")

        let prefixed = DetectionHygiene.componentValues(of: "/Users/testhost/Applications/ChatGPT.app/Contents/Resources/codex-code-mode-host")
        #expect(!DetectionHygiene.matches("/codex", in: prefixed), "连字符命名是另一个可执行文件")

        // 真机 22 行里的绝大多数就是这一类：裸子串 "/codex" 命中了 "Codex Framework.framework"。
        let framework = DetectionHygiene.componentValues(of: [
            "/Users/testhost/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/"
                + "Versions/153.0.8010.48/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)"
        ])
        #expect(!DetectionHygiene.matches("/codex", in: framework), "同前缀的框架/helper 进程被当成 Codex 本体")

        let real = DetectionHygiene.componentValues(of: "/Users/testhost/Applications/ChatGPT.app/Contents/Resources/codex")
        #expect(DetectionHygiene.matches("/codex", in: real), "真 Codex 运行时反而漏检")
    }

    @Test("crashpad handler 不因位于 codex 目录下而成行")
    func crashpadUnderCodexDir() {
        let rec = stub(
            32297,
            "browser_crashpad_handler",
            "/Users/testhost/Applications/ChatGPT.app/Contents/Resources/codex/Helpers/browser_crashpad_handler"
        )
        for strategy in allStrategies {
            #expect(strategy.detect(rec, context: DetectionContext()) == nil, "\(strategy.name) 把 crashpad 判成 Agent")
        }
        #expect(DetectionHygiene.isPureHelperProcess(rec))
    }

    @Test("argv 里的同名中间目录不算 Agent（python /Users/x/cursor/main.py）")
    func argvMidDirectory() {
        let rec = stub(
            4001,
            "python3",
            "/usr/bin/python3",
            arguments: ["python3", "/Users/testhost/projects/cursor/main.py",
                        "--cwd", "/Users/testhost/codex/config.json"]
        )
        #expect(ArgumentSignatureStrategy().detect(rec, context: DetectionContext()) == nil)
        #expect(ExecutablePathStrategy().detect(rec, context: DetectionContext()) == nil)
    }

    @Test("Bundle Identifier 按反向域名分段：前缀段不得在中间出现")
    func bundleIDSegmentation() {
        #expect(DetectionHygiene.matchesBundleIdentifier("com.windsurf", bundleID: "com.windsurf.ai"))
        #expect(!DetectionHygiene.matchesBundleIdentifier("com.windsurf", bundleID: "com.example.windsurf"))
        #expect(DetectionHygiene.matchesBundleIdentifier(
            "com.todesktop.230313mzl4w4u92",
            bundleID: "com.todesktop.230313mzl4w4u92"
        ))
    }

    @Test("`Code.app` 不再命中 `Xcode.app`（历史上第 25 个假 Copilot 的来源）")
    func xcodeIsNotVSCode() {
        let values = DetectionHygiene.componentValues(of: [
            "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/bin/swift-frontend"
        ])
        #expect(!DetectionHygiene.matches("Code.app", in: values))
        #expect(!DetectionHygiene.matches("Visual Studio Code.app", in: values))
        #expect(DetectionHygiene.matches("Visual Studio Code.app", in: DetectionHygiene.componentValues(of: [
            "/Applications/Visual Studio Code.app/Contents/MacOS/Code"
        ])))
    }
}

// MARK: - 3. 取不到可执行路径就不检出

@Suite("WS-Detect：拿不到可执行路径不得凭 argv 给 ≥0.5 置信度")
struct MissingExecutablePathTests {

    /// 真机那条 `executable_path` 为空却凭 argv 判成 openAICodex 的记录。
    private let emptyPath = ProcessRecord(
        pid: 9101,
        name: "",
        executablePath: "",
        arguments: ["codex", "--json", "resume"]
    )

    @Test("两条 argv 驱动的策略都返回 nil")
    func argvStrategiesRefuse() {
        #expect(ArgumentSignatureStrategy().detect(emptyPath, context: DetectionContext()) == nil)
        let terminal = stub(500, "Terminal", "/System/Library/CoreServices/Terminal.app/Contents/MacOS/Terminal")
        #expect(
            TerminalSessionStrategy()
                .detect(emptyPath, context: DetectionContext(ancestors: [terminal])) == nil
        )
    }

    @Test("全部策略的最高置信度都低于 0.5")
    func noStrategyGivesHighConfidence() {
        let context = DetectionContext(ancestors: [
            stub(500, "Terminal", "/System/Library/CoreServices/Terminal.app/Contents/MacOS/Terminal")
        ])
        let best = allStrategies.compactMap { $0.detect(emptyPath, context: context)?.confidence }.max()
        #expect(best == nil || (best ?? 0) < 0.5, "空路径拿到了 \(String(describing: best)) 的置信度")
    }

    @Test("管线不再产出空路径 Agent")
    func pipelineEmitsNothing() async {
        let agents = await AgentDetectionPipeline().detectAgents(using: StubInspector(records: [emptyPath]))
        #expect(agents.isEmpty)
    }
}

// MARK: - 4. 同 bundle 归并（N3）

@Suite("WS-Detect：一个 .app bundle = 一个 Agent 身份")
struct BundleAggregationTests {

    private static let boot = Date(timeIntervalSince1970: 1_800_000_000)

    /// App 本体：不含任何 Agent 特征，但它最早启动 → 作为身份锚点。
    private func host(_ pid: Int32 = 32290) -> ProcessRecord {
        stub(pid, "ChatGPT", "/Users/testhost/Applications/ChatGPT.app/Contents/MacOS/ChatGPT",
             startedAt: Self.boot, cwd: "/")
    }

    /// Codex 运行时进程：bundle 内唯一能被检出的那一类。
    private func runtime(_ pid: Int32, startedOffset: TimeInterval) -> ProcessRecord {
        stub(pid, "codex", "/Users/testhost/Applications/ChatGPT.app/Contents/Resources/codex",
             parent: 32290, startedAt: Self.boot.addingTimeInterval(startedOffset),
             cwd: "/Users/testhost/work/shop")
    }

    private func renderer(_ pid: Int32) -> ProcessRecord {
        stub(pid, "Codex (Renderer)",
             "/Users/testhost/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/"
                + "Versions/153.0.8010.48/Helpers/Codex (Renderer).app/Contents/MacOS/Codex (Renderer)",
             parent: 32290, startedAt: Self.boot.addingTimeInterval(3))
    }

    private func crashpad(_ pid: Int32) -> ProcessRecord {
        stub(pid, "browser_crashpad_handler",
             "/Users/testhost/Applications/ChatGPT.app/Contents/Frameworks/Codex Framework.framework/"
                + "Versions/153.0.8010.48/Helpers/browser_crashpad_handler",
             parent: 32290, startedAt: Self.boot.addingTimeInterval(1))
    }

    @Test("真机那 15 个进程只出 1 行，且 childPIDs 覆盖全 bundle")
    func oneRowPerBundle() async {
        let snapshot = [host(), runtime(32630, startedOffset: 2), runtime(59366, startedOffset: 40),
                        renderer(32640), renderer(32902), crashpad(32297), crashpad(32299)]
        let agents = await AgentDetectionPipeline().detectAgents(using: StubInspector(records: snapshot))

        #expect(agents.count == 1, "改前是 \(snapshot.count) 行级别，归并后必须恰好 1 行")
        guard let agent = agents.first else { return }
        #expect(agent.kind == .openAICodex)
        #expect(agent.detectedVia == .executablePath)
        // 展示内容取「最强检出」，不是 App 主进程：行要说清凭哪个进程认定。
        #expect(agent.pid == 32630)
        #expect(Set(agent.childPIDs).isSuperset(of: [32290, 32297, 32299, 32640, 32902, 59366]))
        // GUI 主进程 cwd 是 "/"，工作目录必须取被检出进程的真实项目路径（模块③的监控根来源）。
        #expect(agent.workingDirectory == "/Users/testhost/work/shop")
        // 会话起点取 bundle 的出生（App 本体启动时刻），不是运行时进程的重拉时刻。
        #expect(agent.startedAt == Self.boot)
    }

    @Test("运行时进程被重拉后身份不变（不产生新的 Session）")
    func identityStableAcrossRuntimeRespawn() async {
        let first = await AgentDetectionPipeline().detectAgents(
            using: StubInspector(records: [host(), runtime(32630, startedOffset: 2)]))
        // 旧运行时退出、新运行时起来：bundle 与锚点进程都没变。
        let second = await AgentDetectionPipeline().detectAgents(
            using: StubInspector(records: [host(), runtime(71000, startedOffset: 90)]))

        #expect(first.count == 1 && second.count == 1)
        #expect(first.first?.id == second.first?.id, "身份随运行时进程变化 ⇒ 每轮都会新开一条 Session")
        #expect(first.first?.pid != second.first?.pid)
    }

    @Test("两个不同 bundle 各自成行")
    func distinctBundlesStayDistinct() async {
        let cursor = stub(800, "Cursor", "/Users/testhost/Applications/Cursor.app/Contents/MacOS/Cursor",
                          startedAt: Self.boot)
        let agents = await AgentDetectionPipeline().detectAgents(
            using: StubInspector(records: [host(), runtime(32630, startedOffset: 2), cursor]))
        #expect(agents.count == 2)
        #expect(Set(agents.map(\.kind)) == [.openAICodex, .cursorAgent])
    }

    @Test("不在 bundle 内的 CLI 进程不被归并吞掉")
    func bareCLIProcessesAreNotMerged() async {
        let a = stub(2001, "claude", "/Users/testhost/.local/bin/claude", startedAt: Self.boot, tty: "ttys003")
        let b = stub(2002, "claude", "/Users/testhost/.local/bin/claude", startedAt: Self.boot.addingTimeInterval(5), tty: "ttys004")
        let agents = await AgentDetectionPipeline().detectAgents(using: StubInspector(records: [a, b]))
        #expect(agents.count == 2, "同一台机器上并排的两次 CLI 调用是两次独立会话")
        #expect(agents.allSatisfy { $0.kind == .claudeCode })
    }

    @Test("只有辅助进程活着时不产出任何 Agent")
    func helperOnlyBundleProducesNothing() async {
        let agents = await AgentDetectionPipeline().detectAgents(
            using: StubInspector(records: [host(), crashpad(32297), renderer(32640)]))
        #expect(agents.isEmpty)
    }

    @Test("内嵌 helper bundle 的进程不在父树策略里单独成行")
    func nestedHelperNotAttributedAlone() {
        let cursorMain = stub(1, "Cursor", "/Users/testhost/Applications/Cursor.app/Contents/MacOS/Cursor")
        let crashpad = stub(
            2, "chrome_crashpad_handler",
            "/Users/testhost/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/"
                + "Contents/MacOS/chrome_crashpad_handler",
            parent: 1
        )
        let context = DetectionContext(ancestors: [cursorMain])
        #expect(ParentProcessTreeStrategy().detect(crashpad, context: context) == nil)

        // 同一条策略仍要能认出非内嵌布局的编辑器子进程。
        let helper = stub(3, "Code Helper",
                          "/Users/testhost/Applications/Visual Studio Code.app/Contents/MacOS/Code Helper",
                          parent: 1)
        let vscodeMain = stub(4, "Code",
                             "/Users/testhost/Applications/Visual Studio Code.app/Contents/MacOS/Code")
        #expect(
            ParentProcessTreeStrategy()
                .detect(helper, context: DetectionContext(ancestors: [vscodeMain]))?.kind == .vscodeCopilot
        )
    }
}

// MARK: - 5. 卫生层原语

@Suite("WS-Detect：卫生层原语")
struct DetectionHygienePrimitiveTests {

    @Test("归组键取最外层 .app（内嵌 helper bundle 归到宿主）")
    func outermostBundle() {
        let nested = FixturePaths.inHome(".codex/computer-use/Codex Computer Use.app/Contents/SharedSupport/")
            + "SkyComputerUseClient.app/Contents/MacOS/SkyComputerUseClient"
        #expect(DetectionHygiene.enclosingAppBundle(nested)
                == FixturePaths.inHome(".codex/computer-use/Codex Computer Use.app"))
        #expect(DetectionHygiene.enclosingAppBundle("/usr/local/bin/claude") == nil)
        #expect(DetectionHygiene.enclosingAppBundle("") == nil)
    }

    @Test("纯辅助进程识别：crashpad / XPC / 内嵌 helper bundle")
    func pureHelpers() {
        #expect(DetectionHygiene.isPureHelperProcess(
            stub(1, "chrome_crashpad_handler", "/Users/testhost/App.app/Contents/Frameworks/x.framework/Helpers/chrome_crashpad_handler")))
        #expect(DetectionHygiene.isPureHelperProcess(
            stub(2, "Foo", "/Users/testhost/App.app/Contents/XPCServices/Foo.xpc/Contents/MacOS/Foo")))
        #expect(DetectionHygiene.isPureHelperProcess(
            stub(3, "Codex (Service)", "/Users/testhost/App.app/Contents/Frameworks/F/Helpers/Codex (Service).app/Contents/MacOS/Codex (Service)")))
        // 宿主自己的进程与终端 CLI 不能被算作纯辅助。
        #expect(!DetectionHygiene.isPureHelperProcess(stub(4, "ChatGPT", "/Users/testhost/App.app/Contents/MacOS/ChatGPT")))
        #expect(!DetectionHygiene.isPureHelperProcess(stub(5, "claude", "/Users/testhost/.local/bin/claude")))
    }

    @Test("多段签名按连续分量命中，段间不得跳跃")
    func multiComponentSignatures() {
        let ok = DetectionHygiene.componentValues(of: [
            "/Users/testhost/.npm-global/lib/node_modules/@anthropic-ai/claude-code/cli.js"
        ])
        #expect(DetectionHygiene.matches("@anthropic-ai/claude-code", in: ok))

        let broken = DetectionHygiene.componentValues(of: [
            "/Users/testhost/@anthropic-ai/tools/claude-code/cli.js"
        ])
        #expect(!DetectionHygiene.matches("@anthropic-ai/claude-code", in: broken))
    }

    @Test("签名条目仍覆盖契约要求的 Agent 类型，且不含通用开关")
    func signatureTableHygiene() {
        let db = AgentSignatureDatabase.shared
        let arguments = db.entries.flatMap(\.argumentSignatures)
        for tooGeneric in ["--verbose", "--help", "run", "test"] {
            #expect(!arguments.contains(tooGeneric), "\(tooGeneric) 太通用，任何进程都可能带上")
        }
        let processNames = db.entries.flatMap(\.processNames)
        #expect(!processNames.contains("electron"), "Electron 开发态进程名会造成成堆虚高行")
    }
}
