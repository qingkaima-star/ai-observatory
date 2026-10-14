//
//  Runtime.swift
//  AIObservatoryCore
//
//  FROZEN CONTRACT — 冻结契约。禁止并行工作流修改。
//
//  组合根（composition root）的载体：把 Engine 提供的三个能力打包交给 UI。
//  UI 只需要这一个结构体，即可与 Engine 完全解耦、并行开发。
//

import Foundation

public struct ObservatoryRuntime: Sendable {
    public var service: any ObservatoryService
    public var controller: any ObservatoryControlling
    public var updates: any ObservatoryEventStreaming
    public var settings: ObservatorySettings
    /// 导出执行者。可选：SwiftUI 预览等宿主没有接导出层，此时界面不显示导出入口，
    /// 而不是显示一个点了没反应的按钮。
    public var exporter: (any ActivityExportControlling)?
    /// AI 分析执行者（健康度 / 异常检测）。可选，做法与 `exporter` 一致（d6a3550）：
    /// 预览等宿主没有接入分析层时为 `nil`，界面明确显示「分析层未接入」，
    /// 而不是显示一个永远转圈的加载态或一排假的 0。
    public var analysis: (any ObservatoryAnalysisProviding)?
    /// 实时捕获能力的读数来源（ADR-0006 #6：`realtimeCapability()` 探了却零消费者）。
    /// 同样可选：没有它时设置页显示「未接入」，而不是印一档猜出来的保真度。
    public var capability: (any RealtimeCapabilityReporting)?
    /// 采集面实况（ICR-0006）：这一轮实际监控哪些根、剔除了哪些、为什么。
    /// 同样可选：没有它时界面只许说"尚无采集面读数"，不许自己复刻剔除规则。
    public var monitoringScope: (any MonitoringScopeReporting)?

    public init(
        service: any ObservatoryService,
        controller: any ObservatoryControlling,
        updates: any ObservatoryEventStreaming,
        settings: ObservatorySettings = .default,
        exporter: (any ActivityExportControlling)? = nil,
        analysis: (any ObservatoryAnalysisProviding)? = nil,
        capability: (any RealtimeCapabilityReporting)? = nil,
        monitoringScope: (any MonitoringScopeReporting)? = nil
    ) {
        self.service = service
        self.controller = controller
        self.updates = updates
        self.settings = settings
        self.exporter = exporter
        self.analysis = analysis
        self.capability = capability
        self.monitoringScope = monitoringScope
    }
}
