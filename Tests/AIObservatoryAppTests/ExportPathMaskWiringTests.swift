//
//  ExportPathMaskWiringTests.swift
//  AIObservatoryAppTests
//
//  Owner: master-controller（#64 的装配点半句）
//  ─────────────────────────────────────────────────────────
//  这里钉的只有一件事：**导出件里的路径映射，与屏幕上是同一个决定**。
//
//  为什么单独立一份而不是塞进 `ExportEndToEndTests`：那一份测的是"导出层能不能产出文件"，
//  而 #64 的成因恰恰是"每个出口各自决定要不要遮"——采集面/会话/风险/时间线各遮各的，
//  于是开关开着家目录还上屏（实拍 `tmp/shots/redact-on-files.png`）。装配点是最后一个出口，
//  也是最容易"忘了传"的一个：`export(...)` 要弹 `NSSavePanel`，界面里量不出来，
//  所以把拼请求那一步抽成纯函数 `makeExportRequest` 之后才有这一份用例。
//
//  ⚠️ 两条反向自证都在：开着时映射必须**真的改写了字符串**（否则"没含路径"可能只是夹具里本来就没路径），
//  关掉时必须**逐字恒等**（否则等于把"默认关"悄悄做成了默认开）。
//

import Foundation
import Testing

@testable import AIObservatoryApp
import AIObservatoryCore
import AIObservatoryExport
import AIObservatoryTestSupport

private let directory = URL(fileURLWithPath: FixturePaths.inHome("Exports"), isDirectory: true)

/// 一个必然被识别成绝对路径、且带项目根结构的样本。
private let samplePath = FixturePaths.projectAlpha + "/Sources/main.swift"

@Suite("导出面的路径映射装配（#64 最后一出口）")
struct ExportPathMaskWiringTests {

    /// 装配点的映射**跟着设置走**：开关开着 ⇒ 导出件里这条路径不再含家目录与前缀结构。
    @Test("demoRedactedOutput 开着时，导出的请求带着真的会改写的映射")
    func onSettingProducesMaskedExport() throws {
        let settings = ObservatorySettings(
            monitoredRoots: [FixturePaths.projectAlpha],
            demoRedactedOutput: true
        )
        let request = ActivityExportRequest(dateRange: .unbounded, format: .markdown)

        let export = ObservatoryExporting.makeExportRequest(
            request,
            directory: directory,
            generatedAt: Date(timeIntervalSinceReferenceDate: 800_000_000),
            pathMask: .configured(from: settings, home: FixturePaths.home)
        )

        #expect(!export.pathMask.isOff, "开关开着却拿到恒等映射 ⇒ 装配点没接上设置")

        let scrubbed = export.pathMask.scrub(samplePath)
        // 正向：真改写了。
        #expect(scrubbed != samplePath, "映射开着却逐字原样返回 ⇒ 这一格是假的")
        // 更强的一条：家目录与前缀结构都不许留下（"缩成末段"也算漏，因为项目根名本身就是位置信息）。
        #expect(!scrubbed.contains(FixturePaths.home), "导出件里仍含家目录：\(scrubbed)")
        #expect(!scrubbed.contains(FixturePaths.projectAlpha), "导出件里仍含完整项目根：\(scrubbed)")
    }

    /// 关掉时逐字恒等——并且要能区分"关了"与"夹具碰巧没路径"。
    @Test("demoRedactedOutput 关掉时映射恒等（反向自证：不是夹具里本来没路径）")
    func offSettingIsIdentity() throws {
        let settings = ObservatorySettings(
            monitoredRoots: [FixturePaths.projectAlpha],
            demoRedactedOutput: false
        )
        let mask = PathPrivacy.Mask.configured(from: settings, home: FixturePaths.home)

        #expect(mask.isOff)
        #expect(mask.scrub(samplePath) == samplePath)
        // 反向探针：同一份文本在"开着"那一支必须被改写。两支都恒等 ⇒ 尺子坏了，不是设置对了。
        let on = PathPrivacy.Mask.configured(
            from: ObservatorySettings(monitoredRoots: [FixturePaths.projectAlpha], demoRedactedOutput: true),
            home: FixturePaths.home
        )
        #expect(on.scrub(samplePath) != mask.scrub(samplePath),
                "开与关输出相同 ⇒ 这条用例抓不到任何东西")
    }

    /// 装配函数不许顺手改掉别的口径：凭据脱敏仍由请求自己说，时间范围与 kinds 原样下传。
    @Test("装配只加映射，不改凭据开关 / kinds / 时间范围 / 可写根")
    func assemblyKeepsOtherSemantics() throws {
        let request = ActivityExportRequest(
            dateRange: DateRangeFilter(start: Date(timeIntervalSinceReferenceDate: 100),
                                       end: Date(timeIntervalSinceReferenceDate: 200)),
            format: .json,
            redactionEnabled: false
        )
        let export = ObservatoryExporting.makeExportRequest(
            request,
            directory: directory,
            generatedAt: Date(timeIntervalSinceReferenceDate: 300),
            pathMask: .off
        )

        #expect(export.redactionEnabled == false,
                "请求说关凭据脱敏却被打开 ⇒ 两个开关被并成了一个")
        #expect(export.pathMask.isOff, "传 .off 却拿到非恒等映射 ⇒ 装配点自己造了默认值")
        #expect(export.dateRange == request.dateRange)
        // kinds 由 `ExportKind.supportedFormats` 反挑（见本文件另一份用例），这里只验没被丢掉。
        #expect(!export.kinds.isEmpty)
        #expect(export.destination.allowedRoots == [directory],
                "可写根必须收窄到用户选的那一个目录，放宽就是往家目录写")
    }
}
