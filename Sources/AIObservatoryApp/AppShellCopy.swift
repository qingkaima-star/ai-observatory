//
//  AppShellCopy.swift
//  AIObservatoryApp
//
//  Owner: master-controller（组合根）
//  ─────────────────────────────────────────────────────────
//  这一张表管的是**整个 App 唯一几处不在 `AIObservatoryUI` 里的用户可见文本**：
//  菜单标题与命令、`NSSavePanel` 的标题/按钮、错误弹框的标题。
//  它们此前是裸中文字面量，而双语门禁（中央棘轮 + 九道按目录门禁）**只扫
//  `Sources/AIObservatoryUI/<页>/`** ⇒ 英文态下用户点菜单、存文件、看报错时满屏中文，
//  门禁却全绿。这是"门禁在、射程不在"那一族的**新射程**：前一轮是某页没被扫，这一轮是一整个 target。
//  现在配一道扫 `Sources/AIObservatoryApp/` 的门禁兜着（`AppTargetCopyGateTests`，带分母守卫）。
//
//  ⚠️ 一处**已知的同句两出处**（下次做单源化时一起收，别在这里再造第三份）：
//  `rescanNow` 与 `AIObservatoryUI/Security/SecurityCopy.rescanNow` 是同一句话——
//  那一页也有个"立即重新扫描"。两张表都 `internal`，彼此 import 不到，所以这里没有"复用"可言：
//  要么把这句话下沉到 `Core/L10N`（与 `NamedCopy` 同一个理由：跨 target 共用的文案放这儿），
//  要么让菜单读界面层。两条都比再抄一份贵，先记下（本文件头 + 看板 20:3x 块）。
//

import Foundation
import AIObservatoryCore

/// 外壳层（菜单 / 系统面板 / 弹框）的用户可见文案表。
enum AppShellCopy {

    /// 全进程解析一次的语言。
    ///
    /// 不就地 `AppLanguage.resolved()`：它读 `Locale.preferredLanguages`，而 `.commands` 的
    /// builder 会随场景重建反复求值。缓存与界面层 `UILanguage.current` 同一个理由，
    /// 且本 App 的语言只跟随系统、改语言要重启（需求方 2026-09-21 拍定，不做 App 内开关）。
    static let language: AppLanguage = .resolved()

    static let observeMenu = LocalizedString(zh: "观测", en: "Observe")
    static let rescanNow = LocalizedString(zh: "立即重新扫描", en: "Rescan now")
    static let exportActivityReport = LocalizedString(zh: "导出活动报告…", en: "Export Activity Report…")
    static let exportPanelTitle = LocalizedString(zh: "导出 AI 活动记录", en: "Export AI Activity Records")
    static let exportPanelPrompt = LocalizedString(zh: "导出到此文件夹", en: "Export to This Folder")
    static let exportFailed = LocalizedString(zh: "导出失败", en: "Export failed")

    /// 本表全部用户可见文案。条数由门禁用例量，不靠手数。
    static let bilingualCopy: [NamedCopy] = [
        NamedCopy("appshell.menu.observe", observeMenu),
        NamedCopy("appshell.menu.rescanNow", rescanNow),
        NamedCopy("appshell.menu.exportActivityReport", exportActivityReport),
        NamedCopy("appshell.panel.title", exportPanelTitle),
        NamedCopy("appshell.panel.prompt", exportPanelPrompt),
        NamedCopy("appshell.alert.exportFailed", exportFailed),
    ]
}
