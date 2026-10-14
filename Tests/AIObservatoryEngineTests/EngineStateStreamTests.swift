//
//  EngineStateStreamTests.swift
//  AIObservatoryEngineTests
//
//  Owner: master-controller
//
//  守的是「订阅竞态」：状态变化发生在「读快照」与「登记订阅者」之间时，
//  这条变化对该订阅者永久丢失。真机表现很具体——数据一直在流进来，
//  左下角胶囊却常年显示「引擎 已停止」（截图验收时抓到的）。
//

import Foundation
import Testing
@testable import AIObservatoryEngine
import AIObservatoryCore

@Suite("Engine: 状态流的首帧与不丢变化", .timeLimit(.minutes(1)))
struct EngineStateStreamTests {

    @Test("建立订阅时就补发当前状态：首帧必定是 .engineState")
    func replaysCurrentStateOnSubscribe() async {
        let engine = ObservatoryEngine()
        defer { Task { await engine.stop() } }

        var iterator = engine.makeUpdateStream().makeAsyncIterator()
        let first = await iterator.next()
        switch first {
        case .some(.engineState(let state)):
            #expect(state == .stopped, "未启动的引擎首帧应如实报 stopped，而不是没有首帧")
        case .some(let other):
            Issue.record("首帧必须是 .engineState，实际是 \(other)")
        case nil:
            Issue.record("订阅流立刻结束，没有补发状态")
        }
    }

    @Test("启动前订阅：start() 的那次 .running 不会丢")
    func runningTransitionReachesExistingSubscriber() async {
        let engine = ObservatoryEngine()
        defer { Task { await engine.stop() } }

        // 先订阅（此时是 stopped），再启动 —— 老订阅者必须收到 running。
        var iterator = engine.makeUpdateStream().makeAsyncIterator()
        let initial = await iterator.next()
        if case .some(.engineState(let state)) = initial {
            #expect(state == .stopped)
        } else {
            Issue.record("首帧不是 .engineState：\(String(describing: initial))")
        }

        await engine.start()
        let settled = await engine.currentState()
        #expect(settled == .running)

        // 广播可能在 start() 内部任意时刻发生，因此允许中间夹别的更新，
        // 只要最终能看到与 currentState 一致的那一条即可。
        var sawRunning = false
        for _ in 0..<32 {
            guard let update = await iterator.next() else { break }
            if case .engineState(let state) = update, state == .running {
                sawRunning = true
                break
            }
        }
        #expect(sawRunning, "start() 的 .running 广播丢给了已存在的订阅者")
    }

    @Test("启动后才订阅：新订阅者的首帧就是 running（晚到不补发就等于永远旧）")
    func lateSubscriberSeesCurrentState() async {
        let engine = ObservatoryEngine()
        defer { Task { await engine.stop() } }
        await engine.start()

        var lateIterator = engine.makeUpdateStream().makeAsyncIterator()
        guard case .some(.engineState(let state)) = await lateIterator.next() else {
            Issue.record("晚到的订阅者没有拿到状态首帧")
            return
        }
        #expect(state == .running)
    }
}
