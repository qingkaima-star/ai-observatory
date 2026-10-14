//
//  Scratch.swift
//  AIObservatoryTestSupport
//
//  Owner: master-controller（冻结支撑层）
//
//  测试落盘目录的唯一入口。
//
//  为什么需要它：早期 13 处落盘用例把沙盒根硬编成
//  `<本机授权工作目录>/.worktrees/.scratch`——那是「开发期只在授权工作目录内写」这条
//  纪律被错误地翻译进了测试代码。托管 CI runner 上不存在该路径，用例只能 continue-on-error，
//  「CI 全绿」这条验收标准就永远拿不到。
//
//  为什么不用 `FileManager.temporaryDirectory`：macOS 的 `$TMPDIR` 是
//  `/var/folders/…`，而 `ExportPathPolicy.forbiddenPrefixes` 含 `/var` 与 `/private`
//  ——真放临时目录会被导出层自己的隐私策略拒掉。所以默认根取「当前检出自带的
//  `.scratch-tests/`」（已在 .gitignore 内），CI 可用 `AIOBSERVATORY_TEST_SCRATCH` 覆盖。
//

import Foundation

public enum Scratch {

    /// 环境变量覆盖点；CI 可指向 runner 自己的临时目录。
    public static let environmentKey = "AIOBSERVATORY_TEST_SCRATCH"

    /// 所有测试临时目录的公共根。
    public static var root: URL {
        if let override = ProcessInfo.processInfo.environment[environmentKey], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return checkoutRoot.appendingPathComponent(".scratch-tests", isDirectory: true)
    }

    /// 当前检出目录：`Sources/AIObservatoryTestSupport/Scratch.swift` 往上三层。
    /// 用 `#filePath` 而不是墙上路径，工作树与 CI runner 都能算出自己的那一份。
    static var checkoutRoot: URL {
        URL(fileURLWithPath: #filePath, isDirectory: false)
            .deletingLastPathComponent()   // AIObservatoryTestSupport
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // 仓库根
    }

    /// 用例外独占、已创建的目录：`<root>/<purpose>-<uuid>`。
    /// 用 UUID 是为了并发跑测时两个用例不会踩同一个目录。
    public static func directory(_ purpose: String) throws -> URL {
        let url = root.appendingPathComponent("\(purpose)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 纯字符串路径（给「断言里要写路径本身」的用例，例如 `isForbiddenSystemPath`）。不创建目录。
    public static func path(_ segments: String...) -> String {
        ([root.path] + segments).joined(separator: "/")
    }
}
