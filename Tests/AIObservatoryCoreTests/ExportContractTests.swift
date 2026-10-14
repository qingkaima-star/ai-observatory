//
//  ExportContractTests.swift
//  AIObservatoryCoreTests
//
//  Owner: master-controller
//
//  钉住导出契约里两条不该悄悄变化的东西：默认脱敏（隐私），以及宿主没接导出层时
//  界面上确实拿不到导出入口（而不是拿到一个点了没反应的按钮）。
//

import Foundation
import Testing
import AIObservatoryCore
import AIObservatoryTestSupport

@MainActor
private final class RecordingExporter: ActivityExportControlling {
    var requests: [ActivityExportRequest] = []

    func export(_ request: ActivityExportRequest) async {
        requests.append(request)
    }
}

@Suite("Core: 导出契约")
struct ExportContractTests {

    @Test("导出请求默认脱敏，三种格式都能被界面表达")
    func defaultsArePrivacyFirst() {
        let request = ActivityExportRequest(dateRange: .lastHours(24))
        #expect(request.redactionEnabled)
        #expect(request.format == .markdown)
        #expect(ActivityExportRequest.Format.allCases.map(\.rawValue) == ["markdown", "json", "csv"])
        for format in ActivityExportRequest.Format.allCases {
            #expect(!format.displayName.isEmpty)
        }
    }

    @MainActor @Test("未注入导出层时 runtime.exporter 为 nil；注入后请求原样传给执行者")
    func carriesExporter() async {
        let service = InMemoryObservatoryService()
        let bare = ObservatoryRuntime(service: service, controller: service, updates: service)
        #expect(bare.exporter == nil)

        let exporter = RecordingExporter()
        let wired = ObservatoryRuntime(service: service, controller: service, updates: service,
                                       exporter: exporter)
        #expect(wired.exporter != nil)
        await wired.exporter?.export(ActivityExportRequest(dateRange: .unbounded, format: .csv))
        #expect(exporter.requests.count == 1)
        #expect(exporter.requests.first?.format == .csv)
        #expect(exporter.requests.first?.redactionEnabled == true)
    }
}
