//
//  PlatformContractTests.swift
//  AIObservatoryPlatformTests
//
//  Owner: master-controller（**总控冻结区** —— 并行工作流不得修改本文件）
//
//  ⚠️ 这是一个被 Platform 下多个子模块共享的测试文件。若允许多条并行工作流各自修改，
//  必然在同一批 hunk 上产生合并冲突。因此本文件归总控独占。
//
//  设计原则：只断言「Platform 层所依赖的数据契约」本身的行为，
//  **不引用任何具体实现类型**（不引用 LibprocProcessInspector / FSEventsWatcher /
//  HostMetricsSampler 等），因此无论各子模块如何演进，本文件始终有效。
//
//  各工作流的实现级测试请放在自己的子目录：
//    Tests/AIObservatoryPlatformTests/AgentDetection/
//    Tests/AIObservatoryPlatformTests/FileSystem/
//    Tests/AIObservatoryPlatformTests/Telemetry/
//

import Testing
import Foundation
@testable import AIObservatoryPlatform
import AIObservatoryCore

@Suite("Platform 数据契约")
struct PlatformContractTests {

    // MARK: - 进程

    @Test("ProcessRecord 的命令行拼接包含全部参数")
    func processRecordCommandLine() {
        let record = ProcessRecord(
            pid: 4242,
            parentPID: 1,
            name: "claude",
            executablePath: "/usr/local/bin/claude",
            arguments: ["--resume", "--verbose"]
        )
        #expect(record.commandLine == "claude --resume --verbose")
        #expect(record.id == 4242)
        #expect(record.parentPID == 1)
    }

    @Test("ProcessTree 节点 id 取自 pid，深度可表达")
    func processTreeIdentity() {
        let child = ProcessTree.TreeNode(record: ProcessRecord(pid: 20, parentPID: 10, name: "node"), depth: 1)
        let root = ProcessTree.TreeNode(record: ProcessRecord(pid: 10, name: "claude"), children: [child], depth: 0)
        let tree = ProcessTree(roots: [root])

        #expect(tree.roots.count == 1)
        #expect(tree.roots[0].id == 10)
        #expect(tree.roots[0].children.first?.id == 20)
        #expect(tree.roots[0].children.first?.depth == 1)
    }

    // MARK: - Agent 识别

    @Test("AgentDetectionResult 未指定 displayName 时回落到 AgentKind 展示名")
    func detectionResultDefaultDisplayName() {
        let explicit = AgentDetectionResult(kind: .cursorAgent, signal: .bundleIdentifier, confidence: 0.9, displayName: "Cursor")
        let implicit = AgentDetectionResult(kind: .cursorAgent, signal: .bundleIdentifier, confidence: 0.9)

        #expect(explicit.displayName == "Cursor")
        #expect(implicit.displayName == AgentKind.cursorAgent.displayName)
    }

    @Test("RealtimeCapability 三档能力都有稳定展示名")
    func realtimeCapabilityNames() {
        #expect(RealtimeCapability.endPointSecurity.displayName == "EndpointSecurity 实时")
        #expect(RealtimeCapability.processPolling.displayName == "轮询模式")
        #expect(RealtimeCapability.none.displayName == "不可用")
    }

    @Test("DetectionContext 默认构造为空上下文")
    func detectionContextDefaults() {
        let context = DetectionContext()
        #expect(context.ancestors.isEmpty)
    }

    // MARK: - 文件系统

    @Test("RawFileSystemEvent 默认不是目录、大小为 0")
    func rawFileSystemEventDefaults() {
        let event = RawFileSystemEvent(path: "/Users/demo/Projects/Mona/API.swift", kind: .modified)
        #expect(event.isDirectory == false)
        #expect(event.sizeBytes == 0)
        #expect(event.previousPath == nil)
        #expect(event.kind == .modified)
    }

    // MARK: - 命令审计

    /// `benign` 的默认值断言。**原来这里还有第五条 `#expect(benign.reason == nil)`**——
    /// 它当时就是那个死字段在产品侧唯一的"读者"（而且是测试侧），只能证明字段没被编译器丢掉，
    /// 证明不了用户看得见。ADR-0010 把字段删掉后，这一条自动不成立，
    /// 按"用例不许删、要换成结构性断言"的要求，改成下面那条 `carriesNoHumanReadableText`。
    @Test("CommandClassification.benign 是安全默认值")
    func commandClassificationBenign() {
        let benign = CommandClassification.benign
        #expect(benign.isDestructive == false)
        #expect(benign.requiresConfirmation == false)
        #expect(benign.level == .low)
        #expect(benign.category == nil)
    }

    /// 命令分级结论**不携带任何人类可读文本**（ADR-0010）。
    ///
    /// 为什么值得钉：`CommandClassification` 是 `CommandAuditing` 的返回类型，落库前就被拆开
    /// （`AgentHookEvent.commandRecord` 只取三个布尔/等级字段）。一旦有人再加一个 `reason: String?`，
    /// 它会**立刻重新变成"有生产者、产品侧零消费者"的那个形状**——而且这次连编译错误都不会有。
    /// 所以这里查的是声明本身：结构体里不许出现任何 `String` 类型的成员。
    /// ⚠️ 这是源码级断言（字段"不存在"没有行为可测），已经用变异验过：
    /// 把 `public var reason: String?` 加回去，这条当场红。
    @Test("命令分级结论不携带文本字段（依据只在 RiskEvent.detail 上屏）")
    func carriesNoHumanReadableText() throws {
        let body = try Self.commandClassificationDeclaration()
        #expect(!body.contains(": String"),
                "CommandClassification 里出现了文本成员 ⇒ 又造了一个没人读的依据字段：\n\(body)")
        #expect(body.contains("public var level: RiskLevel"), "声明切片没取到，检查结构体名：\n\(body)")
    }

    /// 切出 `public struct CommandClassification { … }` 到它自己的闭合 `}`（顶格那一列）。
    private static func commandClassificationDeclaration() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryPlatformTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let path = root.appending(path: "Sources/AIObservatoryCore/Contracts/CollectorContracts.swift")
        let text = try String(contentsOf: path, encoding: .utf8)
        guard let start = text.range(of: "public struct CommandClassification") else {
            throw ContractError.declarationMissing("CommandClassification")
        }
        let lines = text[start.lowerBound...].split(separator: "\n", omittingEmptySubsequences: false)
        var body: [String] = []
        for (index, raw) in lines.enumerated() {
            if index > 0, raw == "}" { break }
            body.append(String(raw))
        }
        return body.joined(separator: "\n")
    }

    private enum ContractError: Error { case declarationMissing(String) }

    // MARK: - 指标

    @Test("ProcessSample 保留 pid 与读数")
    func processSampleFields() {
        let sample = ProcessSample(pid: 99, cpuPercent: 12.5, memoryBytes: 1_048_576)
        #expect(sample.pid == 99)
        #expect(sample.cpuPercent == 12.5)
        #expect(sample.memoryBytes == 1_048_576)
    }

    // MARK: - 风险

    @Test("RiskContext 默认不携带任何行为")
    func riskContextDefaults() {
        let context = RiskContext()
        #expect(context.event == nil)
        #expect(context.command == nil)
        #expect(context.fileChange == nil)
        #expect(context.agentKind == .unknown)
        #expect(context.recentFileChangeCount == 0)
    }

    @Test("RiskRuleDescriptor 可编码往返")
    func riskRuleDescriptorCodable() throws {
        let rule = RiskRuleDescriptor(
            id: "R-004",
            name: "破坏性删除",
            category: .dangerousCommand,
            level: .high,
            summary: "命中 rm -rf 且目标位于用户目录"
        )
        let data = try JSONEncoder().encode(rule)
        let decoded = try JSONDecoder().decode(RiskRuleDescriptor.self, from: data)
        #expect(decoded == rule)
    }
}
