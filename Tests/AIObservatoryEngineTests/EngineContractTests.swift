//
//  EngineContractTests.swift
//  AIObservatoryEngineTests
//
//  Owner: master-controller（冻结基线测试）
//  这些测试定义 Engine 必须满足的**契约**，WS-Engine 不得弱化。
//

import Testing
import Foundation
@testable import AIObservatoryEngine
@testable import AIObservatoryCore
@testable import AIObservatoryTestSupport

@Suite("Engine：生命周期与推送")
struct EngineLifecycleTests {

    @Test("初始状态为 stopped")
    func initialState() async {
        let engine = ObservatoryEngine()
        #expect(await engine.currentState() == .stopped)
    }

    @Test("start / stop 正确切换状态")
    func startStop() async {
        let engine = ObservatoryEngine()
        await engine.start()
        #expect(await engine.currentState() == .running)
        await engine.stop()
        #expect(await engine.currentState() == .stopped)
    }

    @Test("状态变更会通过更新流广播")
    func stateBroadcast() async {
        let engine = ObservatoryEngine()
        let stream = engine.makeUpdateStream()

        let collector = Task { () -> [EngineState] in
            var seen: [EngineState] = []
            for await update in stream {
                if case .engineState(let state) = update {
                    seen.append(state)
                    if seen.count == 2 { break }
                }
            }
            return seen
        }

        await engine.start()
        await engine.stop()
        let states = await collector.value
        #expect(states.contains(.running))
        #expect(states.contains(.stopped))
    }
}

@Suite("Engine：查询契约")
struct EngineQueryTests {

    @Test("空引擎的所有查询都返回空页而非抛错")
    func emptyQueries() async throws {
        let engine = ObservatoryEngine()
        #expect(try await engine.sessions(matching: .all).items.isEmpty)
        #expect(try await engine.events(matching: .all).items.isEmpty)
        #expect(try await engine.fileChanges(matching: .all).items.isEmpty)
        #expect(try await engine.commands(matching: .all).items.isEmpty)
        #expect(try await engine.riskEvents(matching: .all).items.isEmpty)
        #expect(try await engine.projects().isEmpty)
        #expect(try await engine.activeAgents().isEmpty)
    }

    @Test("分页 offset 被原样回传")
    func offsetEcho() async throws {
        let engine = ObservatoryEngine()
        let page = try await engine.events(matching: EventQuery(limit: 10, offset: 40))
        #expect(page.offset == 40)
        #expect(page.totalCount == 0)
    }
}
