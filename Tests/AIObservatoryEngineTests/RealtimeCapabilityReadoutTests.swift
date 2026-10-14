//
//  RealtimeCapabilityReadoutTests.swift
//  AIObservatoryEngineTests
//
//  Owner: WS-Honesty（ADR-0006 #6）
//  ─────────────────────────────────────────────────────────
//  `AgentDetecting.realtimeCapability()` 自打存在就没被生产代码读过一次；
//  现在引擎把它转发给设置页。转发必须**可换**：如果 `currentRealtimeCapability()`
//  里写死了某档（或直接抄 `EndpointSecurityMonitor.probeCapability()`），
//  界面就会一直印一个与装配无关的保真度说法。两条相反桩各钉一次。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
import AIObservatoryCore
import AIObservatoryStore
import AIObservatoryTestSupport

/// 能力可注入的桩探测器（`EngineIntegrationTests` 的 `StubDetector` 恒返回 `.processPolling`，
/// 用它只能证明「读到 polling」，证不出「读数来自 detector」）。
private final class CapabilityStubDetector: AgentDetecting, Sendable {
    private let capability: RealtimeCapability

    init(_ capability: RealtimeCapability) {
        self.capability = capability
    }

    func detectAgents(using processSource: any ProcessInspecting) async -> [AgentInstance] { [] }

    func realtimeCapability() -> RealtimeCapability { capability }
}

private func makeEngine(capability: RealtimeCapability) async throws -> ObservatoryEngine {
    let store = try await ObservatoryStore.open(configuration: .inMemory)
    let mapper = ProjectMapper(resolver: { _ in nil })
    return ObservatoryEngine(
        settings: ObservatorySettings(),
        components: ObservatoryEngine.Components(
            storeSource: .ready(store),
            detector: CapabilityStubDetector(capability),
            processInspector: StubProcessSource(),
            metrics: StubMetrics(),
            commandAuditor: StubAuditor(),
            fileObserver: StubFileObserver(),
            snapshotter: StubSnapshotter(providesContent: false),
            differ: StubDiffer(),
            aggregator: TimelineAggregator(projectMapper: mapper),
            projectMapper: mapper
        )
    )
}

@Suite("Engine: 实时捕获能力读数转发")
struct RealtimeCapabilityReadoutTests {

    @Test("桩声明 .endPointSecurity ⇒ 引擎读出 .endPointSecurity（不是写死的那一档）")
    func forwardsEndPointSecurity() async throws {
        let engine = try await makeEngine(capability: .endPointSecurity)
        #expect(engine.currentRealtimeCapability() == .endPointSecurity)
    }

    @Test("同一套装配只换桩为 .processPolling ⇒ 读数随之改变")
    func forwardsProcessPolling() async throws {
        let engine = try await makeEngine(capability: .processPolling)
        #expect(engine.currentRealtimeCapability() == .processPolling)
    }

    @Test("沿 RealtimeCapabilityReporting 协议取读数：组合根交给 runtime.capability 的就是这条路")
    func readableThroughReportingProtocol() async throws {
        let engine = try await makeEngine(capability: RealtimeCapability.none)
        let reporting: any RealtimeCapabilityReporting = engine
        #expect(reporting.currentRealtimeCapability() == RealtimeCapability.none)
    }
}
