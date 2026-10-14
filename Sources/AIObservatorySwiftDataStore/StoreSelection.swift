//
//  StoreSelection.swift
//  AIObservatorySwiftDataStore
//
//  Owner: WS-SwiftData
//
//  后端选择入口：让装配层（App / Engine）用**一行**在 SQLite 与 SwiftData 之间切换。
//
//  ── 为什么这里不直接构造 SQLite store ──────────────────────────────────────
//  `Package.swift`（冻结）里本 target 的依赖只有 `AIObservatoryCore`，看不到
//  `AIObservatoryStore`，所以「二选一」必须发生在**同时依赖两者**的装配层。
//  本文件因此只交付：① 后端枚举（与 SQLite 侧共用的判据）②SwiftData 侧的配置与工厂。
//  装配层用法：
//
//      let backend = ObservatoryStoreBackend.fromEnvironment(default: .sqlite)
//      switch backend {
//      case .sqlite:    store = try await ObservatoryStore.open(configuration: …)
//      case .swiftData: store = try await SwiftDataObservatoryStore.open(configuration: …)
//      }
//
//  查询侧（`ObservatoryService`）两个后端已经同构；写入侧要真正一行切换还缺一个
//  Core 里的写协议，已按规矩写成 IFR（见 WS-SwiftData 简报「已知限制」）。
//
//  ── 落盘位置（ADR-0003）────────────────────────────────────────────────────
//  优先级：① 调用方显式传入的目录 → ② 环境变量 `AIOBSERVATORY_DATA_DIR` →
//  ③ 空串，此时**退化为内存库**（ADR-0003 第 4 条的 `:memory:` 兜底同语义）。
//  `~/Library/Application Support/…` 由 App 的 `DataLocation`（总控冻结）判定，
//  本模块**不自行猜路径**——否则 Agent 驱动的测试就会写到家目录，越出 AiX 边界。
//

import Foundation
import SwiftData
import AIObservatoryCore

// MARK: - 后端选择

/// 可选的持久化后端。
public enum ObservatoryStoreBackend: String, Sendable, Codable, CaseIterable, Equatable {

    /// SQLite（WAL）后端，`AIObservatoryStore.ObservatoryStore`。Phase 1 已真机验证，仍是默认。
    case sqlite

    /// SwiftData 后端，`SwiftDataObservatoryStore`。ADR-0001 排到的第二阶段。
    case swiftData

    /// UI 展示名。
    public var displayName: String {
        switch self {
        case .sqlite:    return "SQLite"
        case .swiftData: return "SwiftData"
        }
    }

    /// 环境变量 `AIOBSERVATORY_BACKEND` 的名字。
    public static let environmentKey = "AIOBSERVATORY_BACKEND"

    /// 解析环境变量里的后端名。
    ///
    /// 只认 `sqlite` / `swiftdata` / `swift-data` / `swift_data`（大小写无关）；
    /// 未设置或无法识别时返回 `defaultBackend`，**不抛错**——配错一个字母不该让 app 起不来。
    /// - Parameters:
    ///   - environment: 注入的环境变量表，默认取进程环境（测试注入用，不读全局状态）。
    ///   - defaultBackend: 未命中时的取值。
    public static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        default defaultBackend: ObservatoryStoreBackend = .sqlite
    ) -> ObservatoryStoreBackend {
        guard let raw = environment[environmentKey]?.trimmingCharacters(in: .whitespaces),
              !raw.isEmpty
        else { return defaultBackend }
        switch raw.lowercased().replacingOccurrences(of: "-", with: "_") {
        case "sqlite", "sqlite3":            return .sqlite
        case "swift_data", "swiftdata":      return .swiftData
        default:                             return defaultBackend
        }
    }
}

// MARK: - 配置

/// SwiftData 后端的打开配置。
public struct SwiftDataStoreConfiguration: Sendable, Hashable {

    /// 数据库所在目录；空串表示**内存库**。
    public var directory: String

    /// 落盘文件名。SwiftData 的惯例后缀是 `.store`（它本身就是一个 SQLite 文件）。
    public var fileName: String

    /// 创建配置。
    /// - Parameters:
    ///   - directory: 数据库目录；空串 → 内存库。
    ///   - fileName: 文件名，默认 `observatory.store`。
    public init(directory: String = "", fileName: String = "observatory.store") {
        self.directory = directory
        self.fileName = fileName
    }

    /// 环境变量 `AIOBSERVATORY_DATA_DIR` 的名字（与 ADR-0003 一致）。
    public static let dataDirectoryEnvironmentKey = "AIOBSERVATORY_DATA_DIR"

    /// 内存库配置：零磁盘写入，用于单元测试与目录不可用时的降级。
    public static let inMemory = SwiftDataStoreConfiguration()

    /// 解析落盘目录：显式值 → 环境变量 → 空串（内存库）。
    ///
    /// 与 ADR-0003 的判据一致：**不**在这里猜 `~/Library`，那是 App 组合根的职责。
    public static func resolvedDirectory(
        explicit: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let trimmed = explicit.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        let fromEnvironment = (environment[dataDirectoryEnvironmentKey] ?? "")
            .trimmingCharacters(in: .whitespaces)
        return fromEnvironment
    }

    /// 用「显式目录 + 环境变量」兜底构造配置。
    public static func resolved(
        explicitDirectory: String = "",
        fileName: String = "observatory.store",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> SwiftDataStoreConfiguration {
        SwiftDataStoreConfiguration(
            directory: resolvedDirectory(explicit: explicitDirectory, environment: environment),
            fileName: fileName
        )
    }

    /// store 文件的 URL；内存库返回 nil。
    public var storeURL: URL? {
        let trimmed = directory.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        return URL(fileURLWithPath: trimmed, isDirectory: true).appendingPathComponent(fileName)
    }

    /// 是否为内存库（不落盘）。
    public var isInMemory: Bool { storeURL == nil }
}

// MARK: - 容器工厂

/// 按配置构建 `ModelContainer`。
///
/// internal：容器与 `ModelContext` 都是非 `Sendable` 类型，绝不能出现在公共 API 上，
/// 否则调用方就能把 `@Model` 记录跨 actor 传出去——正是 ADR-0001 当年否决 SwiftData 的理由。
enum SwiftDataContainerFactory {

    /// 建容器。目录不存在时先创建父目录；失败抛 `ObservatoryError.storeUnavailable`。
    static func makeContainer(configuration: SwiftDataStoreConfiguration) throws -> ModelContainer {
        let modelConfiguration: ModelConfiguration
        if let url = configuration.storeURL {
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true
                )
            } catch {
                throw ObservatoryError.storeUnavailable(
                    "无法创建 SwiftData 数据目录 \(url.deletingLastPathComponent().path): \(error.localizedDescription)"
                )
            }
            // `allowsSave: true` 是必需的：SwiftData 默认拒绝写入「不在容器里」的 URL，
            // 而本项目的数据目录由调用方（App 组合根 / AIOBSERVATORY_DATA_DIR）决定。
            modelConfiguration = ModelConfiguration(url: url, allowsSave: true)
        } else {
            modelConfiguration = ModelConfiguration(isStoredInMemoryOnly: true)
        }
        do {
            // schema 只交给 `ModelContainer` 一份：同时塞进 ModelConfiguration 的 `schema:`
            // 参数会让容器初始化失败（SwiftDataError error 1，实测）。
            return try ModelContainer(for: ObservatorySchema.schema, configurations: [modelConfiguration])
        } catch {
            throw ObservatoryError.storeUnavailable(
                "ModelContainer 初始化失败：\(error.localizedDescription)"
            )
        }
    }
}

// MARK: - 工厂

/// SwiftData 后端的公共入口。
public enum SwiftDataStoreFactory {

    /// 打开（或创建）SwiftData 库。
    ///
    /// - Parameter configuration: 落盘配置；`directory` 为空时使用内存库。
    /// - Returns: 已完成 schema 落地的 store actor。
    /// - Throws: `ObservatoryError.storeUnavailable(_)` — 目录不可创建或容器初始化失败。
    public static func open(
        configuration: SwiftDataStoreConfiguration
    ) async throws -> SwiftDataObservatoryStore {
        try await SwiftDataObservatoryStore.open(configuration: configuration)
    }

    /// 按环境变量打开：目录取 `AIOBSERVATORY_DATA_DIR`（ADR-0003 第 1 条）。
    public static func openFromEnvironment(
        explicitDirectory: String = "",
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> SwiftDataObservatoryStore {
        try await open(
            configuration: .resolved(explicitDirectory: explicitDirectory, environment: environment)
        )
    }
}
