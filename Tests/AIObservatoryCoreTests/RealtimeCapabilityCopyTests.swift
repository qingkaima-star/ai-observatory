//
//  RealtimeCapabilityCopyTests.swift
//  AIObservatoryCoreTests
//
//  Owner: WS-Honesty（ADR-0006 #6）
//  ─────────────────────────────────────────────────────────
//  `realtimeCapability()` 从「探了没人读」变成上屏的一行，代价是文案本身成了产品承诺。
//  三档各自的上屏文案逐字钉死：改了措辞必须同时改这里，逼着改动的人重新读一遍自己
//  到底在向用户保证什么。特别注意 `.endPointSecurity` 那条——ES 只有能力探测、
//  全仓库没有任何 `es_subscribe`，所以它**必须**继续写着「没接进采集链」。
//

import Foundation
import Testing
import AIObservatoryCore

@Suite("Core: 实时捕获能力的上屏文案")
struct RealtimeCapabilityCopyTests {

    @Test("轮询档：明说会漏采短命命令、退出码拿不到")
    func processPollingNote() {
        #expect(RealtimeCapability.processPolling.fidelityNote == """
        命令与文件活动来自定时进程采样与 Agent hook：几十毫秒内结束的命令大概率采不到，\
        采样推断出的执行结果一律是「运行中」，只有 hook 才会带真实退出码。\
        所以「命令审计」这一页不是全量记录。
        """)
    }

    @Test("ES 档：只说「有能力」，不许说成「已在用」")
    func endPointSecurityNote() {
        #expect(RealtimeCapability.endPointSecurity.fidelityNote == """
        探测到本机具备 EndpointSecurity 能力，但当前版本没有把它接进采集链：\
        命令与文件活动依旧来自进程轮询 + Agent hook。这一行只说明「有能力」，不说明「已在用」。
        """)
        // 反守卫：这一句里必须留着「没接进采集链」。删掉它 = 界面在替一个不存在的订阅说话。
        #expect(RealtimeCapability.endPointSecurity.fidelityNote.contains("没有把它接进采集链"))
    }

    @Test("不可用档：把「没记录」与「没发生」分开说")
    func noneNote() {
        #expect(RealtimeCapability.none.fidelityNote == """
        没有可用的实时采集源：命令与文件活动可能整段缺失。\
        请把「没有记录」读成「没采到」，不要读成「没发生」。
        """)
    }

    @Test("三档文案互不相同：共用一句话等于没告诉用户差别在哪")
    func notesAreDistinct() {
        let notes = [
            RealtimeCapability.endPointSecurity.fidelityNote,
            RealtimeCapability.processPolling.fidelityNote,
            RealtimeCapability.none.fidelityNote
        ]
        #expect(Set(notes).count == 3)
    }

    @Test("展示名与保真度说明是两件事：displayName 不许把 note 吞进去")
    func displayNameStaysShort() {
        #expect(RealtimeCapability.processPolling.displayName == "轮询模式")
        #expect(RealtimeCapability.processPolling.displayName.count < 12)
    }
}
