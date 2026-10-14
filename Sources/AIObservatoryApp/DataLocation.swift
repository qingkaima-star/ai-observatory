//
//  DataLocation.swift
//  AIObservatoryApp
//
//  Owner: master-controller（组合根）
//  ─────────────────────────────────────────────────────────
//  观测器自己的 SQLite 数据库放在哪里。
//
//  这里有一个真实冲突：产品要求数据库落在
//  `~/Library/Application Support/com.aix.aiobservatory/`，
//  而开发期的授权边界要求「Agent 只能写被授权的那棵工作目录（仓库所在目录）」——
//  具体路径由运行环境决定，不由本文件写死。
//  判据是**谁在运行**：打包后的正式 App 属于用户，写标准位置；
//  由 SwiftPM / Agent 驱动的裸可执行文件属于开发期，必须留在仓库内。
//

import Foundation

/// 解析观测器的本地数据目录。
enum DataLocation {

    /// 数据库所在目录（不存在时创建）。返回空串表示「用内存数据库」，
    /// 供测试与无法写盘的受限环境使用。
    static var storeDirectory: String {
        // 只判 `isEmpty` 会把 `" "` 当成有效目录：于是建出一个空白名目录、
        // 而引擎侧（`ObservatoryEngine.swift` 的 trim 判据）认它是"没配"⇒ 退内存库，
        // 用户看到的现象是"目录建了、历史没有"。口径由这里统一收：trim 后为空就是没配。
        if let raw = ProcessInfo.processInfo.environment["AIOBSERVATORY_DATA_DIR"] {
            let override = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !override.isEmpty {
                return materialize(override)
            }
        }
        if isPackagedRun, let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            return materialize(support.appending(path: "com.aix.aiobservatory").path)
        }
        return devDirectory.isEmpty ? "" : materialize(devDirectory)
    }

    /// 带 bundle identifier 且可执行文件位于 `*.app/Contents/MacOS/` 下才算正式运行。
    private static var isPackagedRun: Bool {
        let bundle = Bundle.main
        guard bundle.bundleIdentifier == "com.aix.aiobservatory" else { return false }
        return bundle.bundleURL.pathExtension == "app"
    }

    /// 开发期目录：仓库内 `observatory-data/`（已被 .gitignore 忽略）。
    /// 向上找不到 `Package.swift` 时返回空串 ⇒ 由调用方退**内存库**。
    ///
    /// 这里原先退回 `FileManager.default.temporaryDirectory/AIObservatoryDev`，那是 ADR-0003
    /// 四条优先级之外悄悄多出来的**第 5 条**：它把审计库（命令原文、文件路径、diff 片段）
    /// 写到用户机器上一个没有任何文档登记过的地方，既越过 AGENTS.md §0 的授权边界，
    /// 也让"数据只在本机那一个目录里"这句承诺不成立——用户想清都找不到它。
    /// 规范里"都拿不到就退内存库（不崩、**不偷偷写到别处**）"的"别处"就包括临时目录。
    private static var devDirectory: String {
        devDirectory(
            fromCurrentDirectory: FileManager.default.currentDirectoryPath,
            hasMarker: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    /// `devDirectory` 的纯函数版：真实进程的 `currentDirectoryPath` 与文件系统都是全局状态，
    /// 用例改不起（会污染同进程里其它用例），所以把"往上找 marker"这段拆出来才能测到
    /// **找不到仓库**那一支——恰恰是刚修的那一支。
    static func devDirectory(
        fromCurrentDirectory cwd: String,
        hasMarker: (String) -> Bool
    ) -> String {
        var url = URL(fileURLWithPath: cwd, isDirectory: true)
        for _ in 0..<6 {
            if hasMarker(url.appending(path: "Package.swift").path) {
                return url.appending(path: "observatory-data").path
            }
            url.deleteLastPathComponent()
        }
        return ""
    }

    private static func materialize(_ path: String) -> String {
        let url = URL(fileURLWithPath: path, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            return url.path
        } catch {
            // 拿不到可写目录时退回内存数据库，而不是崩溃或静默写到别处。
            return ""
        }
    }
}
