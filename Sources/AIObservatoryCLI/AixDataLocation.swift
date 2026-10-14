//
//  AixDataLocation.swift
//  AIObservatoryCLI
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  ADR-0003 的数据库目录解析链，**只解析、绝不创建**。
//
//  为什么不直接复用 App 里那份：`Sources/AIObservatoryApp/DataLocation.swift` 在
//  **executableTarget** 里，任何 target 都 import 不到它（改 public 也没用）；而且它的
//  `storeDirectory` 会 `createDirectory`，拿不到目录时返回空串 = 退内存库 —— 那正是
//  #65 约束 1 禁止的「静默建一个空库再输出什么都没有」。
//  ⇒ 这一份是**刻意的第二实现**，配一条六输入矩阵的对拍用例钉住漂移（ICR-0012 §二 B2）。
//  全局状态（环境、bundle、cwd、文件系统）全部从 `Inputs` 注入，所以四条优先级都能测到。
//
//  ⚠️ **这是 `Sources/AIObservatoryApp/DataLocation.swift` 的镜像**（ICR-0012 总控裁定 20:0x 选 B2）。
//  镜像的理由：原实现在 **executableTarget** `AIObservatoryApp` 里 ⇒ 任何 target 都 import 不到它
//  （改 public 也没用），而它的 `storeDirectory` 会 `createDirectory`、拿不到目录时返回 `""` = 退内存库
//  —— 正是 #65 约束 1 禁的那件事。所以 CLI 必须有一份「只解析、绝不创建、拿不到就退 2」的同链实现。
//  **漂移的代价由用例付**：`resolverSharesConstantsWithAppImplementation` 在默认全量套件里跑，
//  比的是两条实现共同依赖的那批字面常量 + 向上找 marker 的层数。
//  ⇒ **将来加第 5 条优先级（或改任何一档的判据）时，指针在这里：两处必须同改。**
//

import Foundation

public enum AixDataLocation {
    /// 数据库文件名。与 `ObservatoryEngine.databaseConfiguration` 拼的那个名字一致。
    public static let databaseFileName = "observatory.sqlite"

    /// 解析用的全部输入。默认值 = 当前真实进程环境；用例逐个替换。
    public struct Inputs: Sendable {
        public var explicit: String?
        public var environment: [String: String]
        public var bundleIdentifier: String?
        public var bundlePathExtension: String?
        public var applicationSupportDirectory: String?
        public var currentDirectory: String
        public var hasFile: @Sendable (String) -> Bool

        public init(
            explicit: String? = nil,
            environment: [String: String] = ProcessInfo.processInfo.environment,
            bundleIdentifier: String? = Bundle.main.bundleIdentifier,
            bundlePathExtension: String? = Bundle.main.bundleURL.pathExtension,
            applicationSupportDirectory: String? =
                FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?.path,
            currentDirectory: String = FileManager.default.currentDirectoryPath,
            hasFile: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
        ) {
            self.explicit = explicit
            self.environment = environment
            self.bundleIdentifier = bundleIdentifier
            self.bundlePathExtension = bundlePathExtension
            self.applicationSupportDirectory = applicationSupportDirectory
            self.currentDirectory = currentDirectory
            self.hasFile = hasFile
        }
    }

    /// 解析结果。**没有「退内存库」这一支** —— CLI 拿不到目录就是错误，不是空数据。
    public enum Resolution: Sendable, Hashable {
        /// 按优先级链选定的目录（库里有没有文件由 `AixStore` 再判）。
        case directory(String, source: Source)
        /// 链上四条都落空 ⇒ 无法定位。
        case unresolved(reason: String)

        public enum Source: String, Sendable, Hashable {
            case cliFlag = "--data-dir"
            case environment = "AIOBSERVATORY_DATA_DIR"
            case packagedBundle = "打包运行"
            case repository = "仓库内 observatory-data/"
        }

        public var directoryPath: String? {
            switch self {
            case .directory(let path, _): return path
            case .unresolved: return nil
            }
        }
    }

    /// 解析目录。**全程不写盘、不建目录。**
    public static func resolve(_ inputs: Inputs) -> Resolution {
        if let raw = inputs.explicit {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                return .unresolved(reason: "--data-dir 是空白，没有可用的数据目录")
            }
            return .directory(trimmed, source: .cliFlag)
        }
        // 与 App 侧同一条修正过的口径：只判 isEmpty 会把 " " 当有效目录，
        // 于是建出一个空白名目录、而引擎侧认它是「没配」⇒ 用户看到「目录建了、历史没有」。
        if let raw = inputs.environment["AIOBSERVATORY_DATA_DIR"] {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return .directory(trimmed, source: .environment)
            }
        }
        if isPackagedRun(inputs), let support = inputs.applicationSupportDirectory, !support.isEmpty {
            return .directory(
                URL(fileURLWithPath: support, isDirectory: true)
                    .appendingPathComponent("com.aix.aiobservatory", isDirectory: true).path,
                source: .packagedBundle
            )
        }
        let dev = devDirectory(fromCurrentDirectory: inputs.currentDirectory, hasMarker: inputs.hasFile)
        if dev.isEmpty {
            return .unresolved(reason: "未设 AIOBSERVATORY_DATA_DIR、不是打包运行、"
                + "且当前目录往上 6 层内找不到 Package.swift ⇒ 没有仓库内的 observatory-data/ 可用")
        }
        return .directory(dev, source: .repository)
    }

    /// 打包判据与 App 侧一致：bundle id 对 **且** 可执行文件在 `*.app/` 下。
    static func isPackagedRun(_ inputs: Inputs) -> Bool {
        inputs.bundleIdentifier == "com.aix.aiobservatory" && inputs.bundlePathExtension == "app"
    }

    /// 仓库内目录：向上最多 6 层找 `Package.swift`。逐字对应 App 侧那段纯函数。
    public static func devDirectory(fromCurrentDirectory cwd: String,
                                    hasMarker: @Sendable (String) -> Bool) -> String {
        var url = URL(fileURLWithPath: cwd, isDirectory: true)
        for _ in 0..<6 {
            if hasMarker(url.appendingPathComponent("Package.swift").path) {
                return url.appendingPathComponent("observatory-data", isDirectory: true).path
            }
            url.deleteLastPathComponent()
        }
        return ""
    }
}
