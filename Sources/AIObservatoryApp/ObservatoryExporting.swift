//
//  ObservatoryExporting.swift
//  AIObservatoryApp
//
//  Owner: master-controller（组合根）
//  ─────────────────────────────────────────────────────────
//  把 `AIObservatoryExport` 接进界面与菜单命令。导出层本身只依赖 Core，
//  但 App 目标是唯一知道「用户选了哪个目录」的地方，所以接线只能放这里。
//

import AppKit
import Foundation
import AIObservatoryCore
import AIObservatoryExport

/// 让用户选一个目录，然后把记录写到那里。
enum ObservatoryExporting {

    /// 由界面意图 + 已选定目录 + **已解析的路径映射**拼出导出层请求。
    ///
    /// 单列成纯函数有两个理由：
    /// ① 可测——`export(...)` 要弹 `NSSavePanel`，装配错在界面里量不出来；
    /// ② `pathMask` **故意不给默认值**。给一个 `.off` 当默认，下一个调用点忘了传就是
    ///    "屏幕上脱了敏、导出件里裸路径"那种分叉，而它编译得过、用例也照样绿（#64 的成因形状）。
    ///    现在少传一个参数是编译错误。
    static func makeExportRequest(
        _ request: ActivityExportRequest,
        directory: URL,
        generatedAt: Date,
        pathMask: PathPrivacy.Mask
    ) -> ExportRequest {
        ExportRequest(
            format: exportFormat(for: request.format),
            kinds: kinds(for: request.format),
            dateRange: request.dateRange,
            generatedAt: generatedAt,
            redactionEnabled: request.redactionEnabled,
            pathMask: pathMask,
            destination: ExportDestination(
                directory: directory,
                baseName: "ai-observatory",
                allowedRoots: [directory]
            )
        )
    }

    /// 界面/菜单发起一次导出：选目录 → 映射格式 → 交给导出层。
    /// - Parameter pathMask: 装配点从**启动设置**解析出的路径映射，与渲染层同一个来源
    ///   （`PathPrivacy.Mask.configured(from:)`）——两处各解一次就会一个脱敏一个不脱。
    /// - Returns: 写出的文件 URL；用户取消或失败时为空数组（失败已弹框告知）。
    @discardableResult
    @MainActor
    static func export(
        _ request: ActivityExportRequest,
        from service: any ObservatoryService,
        presenting parent: NSWindow?,
        pathMask: PathPrivacy.Mask
    ) async -> [URL] {
        let panel = NSSavePanel()
        panel.title = AppShellCopy.exportPanelTitle.text(AppShellCopy.language)
        panel.prompt = AppShellCopy.exportPanelPrompt.text(AppShellCopy.language)
        panel.nameFieldStringValue = "ai-observatory-\(request.format.rawValue)"
        panel.canCreateDirectories = true
        let response: NSApplication.ModalResponse
        if let window = parent ?? NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = panel.runModal()
        }
        guard response == .OK, let chosenURL = panel.url else { return [] }

        // 目录由用户显式选定；允许写入的根就是这个目录本身，不再放宽到家目录。
        let directory = chosenURL.deletingLastPathComponent()
        let exportRequest = makeExportRequest(
            request,
            directory: directory,
            generatedAt: Date(),
            pathMask: pathMask
        )

        do {
            let artifacts = try await ExportCoordinator().run(exportRequest, service: service)
            return artifacts.map(\.url)
        } catch {
            presentError(error, in: parent)
            return []
        }
    }

    /// 界面发起一次导出时要写哪些 kind。
    ///
    /// 必须**由 `ExportKind.supportedFormats` 反挑**，不能在这里另写一张表：
    /// `ExportRequest.validate()` 只要在 kinds 里遇到一个不支持当前格式的 kind 就抛
    /// `unsupportedCombination`，而菜单 ⌘⇧E 用的是默认 `.markdown`
    /// （`Contracts/Exporting.swift`）——旧写法把 5 个只支持 JSON/CSV 的 kind 无条件塞进去，
    /// 于是「导出 AI 活动记录」这个主入口**每次必失败、一个文件都不产出**。
    /// 两张表一定会飘，所以这里只留一张。
    static func kinds(for format: ActivityExportRequest.Format) -> [ExportKind] {
        let chosen = exportFormat(for: format)
        return ExportKind.allCases.filter { $0.supportedFormats.contains(chosen) }
    }

    static func exportFormat(
        for format: ActivityExportRequest.Format
    ) -> ExportFormat {
        switch format {
        case .markdown: return .markdown
        case .json:     return .json
        case .csv:      return .csv
        }
    }

    @MainActor
    private static func presentError(_ error: any Error, in window: NSWindow?) {
        let alert = NSAlert()
        alert.messageText = AppShellCopy.exportFailed.text(AppShellCopy.language)
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        if let window {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

/// 注入给界面的导出执行者：界面只知道意图，不知道有 NSSavePanel 和导出层。
@MainActor
final class AppActivityExporter: ActivityExportControlling {

    private let service: any ObservatoryService

    /// 启动设置解析出的路径映射，与渲染层同源（见 `ObservatoryExporting.export(pathMask:)`）。
    private let pathMask: PathPrivacy.Mask

    init(service: any ObservatoryService, pathMask: PathPrivacy.Mask) {
        self.service = service
        self.pathMask = pathMask
    }

    func export(_ request: ActivityExportRequest) async {
        await ObservatoryExporting.export(request, from: service, presenting: nil, pathMask: pathMask)
    }
}
