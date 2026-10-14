//
//  BilingualCopyGateSupport.swift
//  AIObservatoryUITests
//
//  Owner: WS-UI（uicopy · B3 界面双语迁移）
//  ─────────────────────────────────────────────────────────
//  B3 四份门禁（Shell / Dashboard / Sessions / Timeline）共用的三件工具。
//  为什么不各写一份：`NamedCopy.swift` 的文件头就是按同一个理由把 `copyProblems(in:)`
//  收进 Core 的——"每个模块自己写一遍循环，五份会飘"。这里的 `chineseLiterals` 更危险：
//  四份各自的注释剥离规则一旦不一致，就会出现"A 目录判红、B 目录放行同一行"的假象，
//  而下一个人只会怀疑 B 目录没写文案，不会怀疑尺子。
//

import Foundation

enum BilingualCopyGate {

    /// 仓库根：用 `#filePath` 反推，不写宿主绝对路径（同 `AIObservatoryTestSupport.Scratch`）。
    static func repoRoot() throws -> URL {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // Tests/AIObservatoryUITests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: url.appending(path: "Package.swift").path) else {
            throw GateError.noRepoRoot(url.path)
        }
        return url
    }

    /// 某个 UI 子目录（如 `Sources/AIObservatoryUI/Shell`）里的 `.swift` 文件。
    static func swiftFiles(under relativeDirectory: String) throws -> [URL] {
        let directory = try repoRoot().appending(path: relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
            .sorted { $0.path < $1.path }
    }

    /// 这个目录里还有哪些**用户可见**的中文字面量没走文案表。
    ///
    /// 判据是"剥掉注释与预览区之后，代码行里不许出现汉字"——
    /// 而不是"扫字符串字面量"：后者会漏掉 `Text("引擎 \(x)")` 这种写在插值里的，
    /// 也会把 SF Symbol 名、字典键名一并算进来（它们不是给人读的话）。
    /// 汉字只可能出现在文案与注释里，所以这条尺子足够准；误报的代价是有人来改一行注释，
    /// 漏报的代价是静默放行，所以规则一律**宁可少剥**（少剥→误报→有人来看）。
    ///
    /// 【预览区怎么跳过】只跳**预览块本身**，不跳"从某个标记到文件尾"：
    ///  - 顶格的 `#Preview { … }`，按大括号配对跳到它的闭合 `}`；
    ///  - 顶格声明、标识符里带 preview（大小写都认）的那一整块
    ///    （`private func previewTimelineEvents()`、`private struct SessionRowPreviewList` 这类
    ///    只给 Canvas 喂假数据的脚手架）。
    ///
    /// ⚠️ 原来这里写的是"遇到第一个预览标记就 break 到文件尾"，**被自己的变异探针钻过去了**：
    /// 把一行 `private let 探针 = "写死中文"` 加在文件末尾（预览块之后）就完全不出屏。
    /// 而本仓的文件尾部正是"扩展、helper 往后长"的地方，所以那条规则等于给整个文件尾开了后门。
    /// 按配对跳块之后，探针那行照样红（`DashboardBilingualCopyGateTests` 一条用例钉着这个形状）。
    ///
    /// - Parameter excluding: 允许出现汉字的文件名（各目录的文案表本身）。
    /// 某个源文件的**代码行**（剥注释、按预览块跳过），给源码级接线检查用。
    /// 为什么需要它：像"原因句有没有真的排上某一屏"这种约束只能查调用点，
    /// 而查调用点必须先剥注释——否则会被自己写的解释注释判红（本仓犯过三次）。
    static func codeOnlyString(_ relativeFile: String) throws -> String {
        let text = try String(contentsOf: try repoRoot().appending(path: relativeFile), encoding: .utf8)
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        var skipUntil = -1
        for (offset, raw) in lines.enumerated() {
            let line = offset + 1
            if line <= skipUntil { continue }
            if let end = previewBlockEnd(lines: lines, at: offset) { skipUntil = end; continue }
            let code = codeOnly(raw)
            if code.isEmpty { continue }
            out.append(code)
        }
        return out.joined(separator: "\n")
    }

    static func chineseLiterals(
        under relativeDirectory: String,
        excluding fileNames: Set<String>
    ) throws -> [String] {
        var strays: [String] = []
        for file in try swiftFiles(under: relativeDirectory) {
            if fileNames.contains(file.lastPathComponent) { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            strays += chineseLiterals(in: text, fileName: file.lastPathComponent)
        }
        return strays
    }

    /// 同一把尺子的纯函数入口：磁盘版只是它的一层薄壳，测试可以直接喂一段源码来量尺子本身
    /// （尺子被改松时，磁盘版可能全绿——本仓的教训）。
    static func chineseLiterals(in text: String, fileName: String) -> [String] {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var strays: [String] = []
        var skipUntil = -1   // 预览块的闭合行号（含），此前的行不判
        for (offset, raw) in lines.enumerated() {
            let line = offset + 1
            if line <= skipUntil { continue }
            if let end = previewBlockEnd(lines: lines, at: offset) {
                skipUntil = end
                continue
            }
            let code = codeOnly(raw)
            guard code.containsHan else { continue }
            strays.append("\(fileName):\(line) \(code.trimmingCharacters(in: .whitespaces))")
        }
        return strays
    }

    /// 这一行是不是预览脚手架的开头；是则返回它**闭合**那一行的行号（1 基）。
    /// 顶格 + (`#Preview` 或 带 preview 的顶层声明) 才算，缩进的写法一律不认（不配开后门）。
    static func previewBlockEnd(lines: [Substring], at offset: Int) -> Int? {
        let raw = lines[offset]
        guard !raw.hasPrefix(" "), !raw.hasPrefix("\t") else { return nil }
        let isMarker: Bool
        if raw.hasPrefix("#Preview") {
            isMarker = true
        } else if raw.hasPrefix("func ") || raw.hasPrefix("private func ")
            || raw.hasPrefix("struct ") || raw.hasPrefix("private struct ")
            || raw.hasPrefix("enum ") || raw.hasPrefix("private enum ")
            || raw.hasPrefix("final class ") || raw.hasPrefix("class ") {
            isMarker = raw.lowercased().contains("preview")
        } else {
            isMarker = false
        }
        guard isMarker else { return nil }
        var depth = 0
        var opened = false
        for cursor in offset..<lines.count {
            let code = codeOnly(lines[cursor])
            for character in code {
                if character == "{" { depth += 1; opened = true }
                else if character == "}" { depth -= 1 }
            }
            if opened, depth <= 0 { return cursor + 1 }
        }
        return lines.count   // 没等到闭合（不该发生）：保守地跳到文件尾
    }

    /// 剥掉不该参与判定的部分：整行注释、行尾 ` //` 之后的内容。
    static func codeOnly(_ raw: Substring) -> String {
        var line = raw.trimmingCharacters(in: .whitespaces)
        if line.hasPrefix("//") { return "" }
        // 行尾注释只在"空白 + //"处截断：切 URL 里的 `://` 会把代码切没。
        if let range = line.range(of: " //") { line = String(line[..<range.lowerBound]) }
        return line
    }

    /// 文案表文件里**声明**了多少条 `NamedCopy`（数 `static let … = NamedCopy(` 的处数）。
    ///
    /// 用途：`SessionsCopy` 那一份式（名字写在常量行上、清单只列标识符）少了一个漏洞防守——
    /// 加一条常量却忘了列进 `bilingualCopy`，门禁就查不到它。这条把"声明数 == 清单条数"钉住。
    /// `ShellCopy`/`TimelineCopy` 用不到它：那两份的名字只在清单里出现一次，漏列会在
    /// 编译期就报未使用/未定义，而且它们各自有数量下界。
    static func declaredNamedCopyCount(in relativeFile: String) throws -> Int {
        let text = try String(contentsOf: try repoRoot().appending(path: relativeFile), encoding: .utf8)
        return text.split(separator: "\n")
            .map { codeOnly($0) }
            .filter { $0.contains("= NamedCopy(") && $0.contains("static let") }
            .count
    }

    private enum GateError: Error { case noRepoRoot(String) }
}

extension String {
    /// 含汉字（U+4E00…U+9FFF）。Core 的 `containsCJK` 是 internal，测试模块读不到 ⇒ 自备一份。
    var containsHan: Bool { unicodeScalars.contains { 0x4E00...0x9FFF ~= $0.value } }
}
