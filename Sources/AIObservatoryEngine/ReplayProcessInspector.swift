//
//  ReplayProcessInspector.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine（由 ObservatoryEngine.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import os
import CryptoKit
import AIObservatoryCore
import AIObservatoryRiskRules   // 装配点要直接构造 RiskAssessor（语言要同源）
import AIObservatoryStore
import AIObservatoryPlatform

// MARK: - Replay inspector

/// 只读回放一份已抓取的进程快照：让「Agent 识别」与「命令审计」在一个 tick 内共用同一次扫描。
struct ReplayProcessInspector: ProcessInspecting {

    /// 本轮快照。
    let records: [ProcessRecord]

    func scanProcesses() async -> [ProcessRecord] { records }
}
