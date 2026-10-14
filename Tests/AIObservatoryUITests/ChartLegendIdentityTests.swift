//
//  ChartLegendIdentityTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · P2 ChartLegend.Item.id 默认值）
//  ─────────────────────────────────────────────────────────
//  `ChartLegend.Item.init(id: Int = 0, …)` 那个默认值是漏的坑：`ChartLegend.body` 按 `\.id`
//  走 `ForEach` ⇒ 同 id 的多条序列里，SwiftUI 把第一条渲染 N 遍、其余在图例中消失。
//  真机上是图例写着「用户 用户」而图上确实有两条线；编译零警告，测试全绿，只有眼睛能抓到
//  （本仓 `DesignSystem/ChartChrome.swift` 自己的 #Preview 就这么坏了很久）。
//
//  修法是把默认值去掉，让**漏传变成编译错误**。本文件钉两件事：
//    ① 默认值不许回来（把它加回去 ⇒ 这条红）；
//    ② 每个 `ChartLegend([...])` 调用点的每一项都带 `id:`，且字面量 id 互不相同。
//  ② 也扫 `#Preview`：预览不算交付行为，但一个坏掉的预览会把「同 id 会吞序列」这件事
//  重新教给每个看它的人——那正是这条缺陷当初的传染路径。
//

import Foundation
import Testing
@testable import AIObservatoryUI

@Suite("UI: 图例序列的 identity", .timeLimit(.minutes(1)))
struct ChartLegendIdentityTests {

    @Test("Item.init 的 id 不许再有默认值")
    func idParameterHasNoDefault() throws {
        let chrome = try source("Sources/AIObservatoryUI/DesignSystem/ChartChrome.swift")
        for line in chrome.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("init("), trimmed.contains("label:") else { continue }
            #expect(!trimmed.contains("id: Int ="),
                    "id 又带上默认值了：\(trimmed) ⇒ 漏传即同 id，图例吞序列")
            #expect(trimmed.contains("id: Int,"), "init 的形状变了：\(trimmed)")
        }
    }

    @Test("每个 ChartLegend 调用点都显式给 id，且字面量 id 互不重复")
    func everyCallSitePassesDistinctIDs() throws {
        let root = try Self.repoRoot()
        let ui = root.appending(path: "Sources/AIObservatoryUI")
        var scanned = 0
        for file in try Self.swiftFiles(under: ui) {
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("ChartLegend(") else { continue }
            let relative = String(file.path.dropFirst(root.path.count + 1))
            for (position, block) in try Self.legendBlocks(text).enumerated() {
                scanned += 1
                let items = Self.itemInits(block)
                #expect(!items.isEmpty, "\(relative) 第 \(position) 处图例里没解析出任何 .init(")
                for item in items {
                    #expect(item.contains("id:"),
                            "\(relative) 有一项图例漏传 id：\(String(item.prefix(60)))")
                }
                let literals = items.compactMap(Self.integerID)
                // 只有全是字面量时才谈得上重复；`id: index` 那种由调用点的下标保证唯一。
                if literals.count == items.count {
                    #expect(Set(literals).count == literals.count,
                            "\(relative) 图例里有两条序列同 id：\(literals)")
                }
            }
        }
        // 手推：4 张性能图 + 1 张项目贡献图 + ChartChrome 自己的预览 = 6 处。
        #expect(scanned == 6, "ChartLegend 调用点数与预期不符：\(scanned)")
    }

    // MARK: 解析

    /// 取出每个 `ChartLegend([ … ])` 的花括号内文本。
    private static func legendBlocks(_ text: String) throws -> [String] {
        var blocks: [String] = []
        let marker = "ChartLegend(["
        var search = text.startIndex
        while let open = text.range(of: marker, range: search..<text.endIndex) {
            let body = text[open.upperBound...]
            guard let close = body.range(of: "])") else {
                throw LegendError.unterminated(marker)
            }
            blocks.append(String(body[..<close.lowerBound]))
            search = close.upperBound
        }
        return blocks
    }

    /// 一个图例数组里的若干 `.init(` 项。
    private static func itemInits(_ block: String) -> [String] {
        var items: [String] = []
        var search = block.startIndex
        while let found = block.range(of: ".init(", range: search..<block.endIndex) {
            let rest = block[found.upperBound...]
            guard let end = rest.firstIndex(of: ")") else { items.append(String(rest)); break }
            items.append(String(block[found.lowerBound...end]))
            search = rest.index(after: end)
        }
        return items
    }

    /// 从一项里抠 `id:` 后面的整数字面量；非字面量（`id: index`）返回 nil。
    private static func integerID(_ item: String) -> Int? {
        guard let found = item.range(of: "id:") else { return nil }
        let tail = item[found.upperBound...].trimmingCharacters(in: .whitespaces)
        let digits = tail.prefix(while: \.isNumber)
        guard !digits.isEmpty, !digits.hasPrefix("-") else { return nil }
        // 后面紧跟字母就不是纯字面量（`id: index`）
        let after = tail[digits.endIndex...]
        guard after.first?.isLetter != true, after.first != "." else { return nil }
        return Int(digits)
    }

    private enum LegendError: Error { case unterminated(String) }

    // MARK: 路径

    private enum PathError: Error { case noRepoRoot }

    private static func repoRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) else {
            throw PathError.noRepoRoot
        }
        return url
    }

    private func source(_ relative: String) throws -> String {
        try String(contentsOf: try Self.repoRoot().appending(path: relative), encoding: .utf8)
    }

    private static func swiftFiles(under directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }
}
