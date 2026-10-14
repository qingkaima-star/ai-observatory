//
//  SettingsPersistence.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine（总控维护）
//

import Foundation
import AIObservatoryCore

/// 把 `ObservatorySettings` 存成数据目录下的单个 JSON 文件。
///
/// 只负责「存得下、读得回、坏了不崩」三件事：
/// 损坏或不可读时返回 `nil`，让调用方回退到代码基线，
/// 而不是抛错把整个引擎启动卡住——设置丢了远比启动失败可接受。
///
/// 为什么是 `public`（ADR-0006 #14）：组合根必须在**选 Scene 之前**同步读到已落盘的
/// `enableMenuBarExtra`（`Scene` 在启动时定死，之后改不了），而它只能与引擎读到同一份文件、
/// 同一套「读不到就退基线」的语义。要么把这里开放给 App，要么让 App 自己再写一个 JSON 读取器——
/// 后者会出现第二个读盘口径，正是本仓库反复出事的地方。
public enum SettingsPersistence {

    private static let fileName = "settings.json"

    static func url(in storeDirectory: String) -> URL? {
        let directory = storeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !directory.isEmpty else { return nil }
        return URL(fileURLWithPath: directory, isDirectory: true).appending(path: fileName)
    }

    /// 读取已保存的设置。目录为空（内存库）、文件不存在或内容损坏时返回 `nil`。
    ///
    /// 公开给组合根的唯一用途：在构建 `Scene` 之前拿到启动值（见上面的类型级注释）。
    /// 调用方**必须**把 `nil` 当作「退宿主基线」，而不是「关掉功能」——
    /// 读盘失败就藏掉用户可见的菜单栏，等于把 IO 故障伪装成用户的设置。
    public static func restore(ifPresentIn storeDirectory: String) -> ObservatorySettings? {
        guard let url = url(in: storeDirectory),
              let data = try? Data(contentsOf: url) else { return nil }
        do {
            var restored = try JSONDecoder().decode(ObservatorySettings.self, from: data)
            // `storeDirectory` 是**位置**，不是偏好——这个文件本身就躺在那个目录里，
            // 它没有资格决定自己在哪。必须在这里钉回入参，因为两个调用方都是
            // 「文件在就整个采信」：App 的 `resolvedStartupSettings` = `persisted ?? baseline`、
            // 引擎 = `restore(...) ?? settings`。缺字段时解码给的是 `init` 的默认 `""`，
            // 于是一个只写了 `{"theme":"light"}` 的文件会把真路径覆盖成空串
            // ⇒ 引擎按「空 → 内存库」装配 ⇒ **数据不落盘，用户视角是历史凭空消失，且无任何提示**。
            // 不在 Codable 层修（#18 的教训：动 schema 有静默重置旧数据的风险）。
            restored.storeDirectory = storeDirectory
            return restored
        } catch {
            ObservatoryLog.engine.error("设置文件损坏，回退代码基线: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// 保存设置。返回 `false` 表示没写成（内存库或 IO 失败），调用方必须让用户知道。
    static func save(_ settings: ObservatorySettings) -> Bool {
        guard let url = url(in: settings.storeDirectory) else { return true }  // 内存库：无需落盘
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(settings).write(to: url, options: .atomic)
            return true
        } catch {
            ObservatoryLog.engine.error("设置保存失败: \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
