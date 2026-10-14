//
//  ExitChannelInventoryTests.swift
//  AIObservatoryUITests
//
//  Owner: WS-exitlist（#89 出口脉敏清单）
//  ─────────────────────────────────────────────────────────
//  清单的四把尺 + 一把量尺子本身的尺。缺任何一把，这张表都会悄悄烂掉：
//
//   ① 份数与分母：总数、各面条数、未遮条数钉死。加一条要同时改数字 ⇒ 看得见这张表。
//   ② 接线针：`anchors` 逐条在**剥注释后**的源码里找得到。遮罩被重构掉 ⇒ 红。
//   ③ 证据针：`evidence` 指着 `Tests/` 里一条真的用例。指着不存在的 ⇒ 红
//      （这一把防的是"表写得很漂亮而没人测过"——#61 那批逐格断言就是这么全绿却漏的）。
//   ④ 出口闸：扫 `Sources/AIObservatoryUI`，任何把路径/命令喂进可见文本出口、
//      既没接遮罩又没登记在表上的行 ⇒ 红。**新增出口不登记就红**是本单的验收。
//   ⑤ 尺子有牙：①-④ 全部自己会被探针反证——往一段合成源码里加一行 `Text(a.path)`，
//      闸必须报出它；把 `offBehavior` 留空、把证据针指向不存在的文件，守卫必须红。
//
//  ⚠️ 判据一律用「调用跨度」而不是「同一行」：`Text(ProjectsCopy.cardA11ySummary.format(`
//  后面跟着四行参数，按同行匹配的老闸（`RedactionSurfaceTests.pathSinksAreMasked`）
//  对这种形状**永远看不见**——那正是本单要治的"尺子在、射程不在"。
//

import Testing
import Foundation
@testable import AIObservatoryCore

// MARK: - 出口闸的尺子

/// 「哪一行把路径喂进了可见出口」的唯一判据。
enum ExitGate {

    /// 会渲染出**给人或辅助技术读的文本**的出口。
    static let sinks = ["Text(", ".help(", ".accessibilityLabel(", ".accessibilityValue(",
                        "SectionHeader(", "MonospacedCodeView(", "setString(", "InlineStat(",
                        "Label(", "Button("]

    /// 组件**自己**就带遮罩的那些出口 ⇒ 调用点不必再写一遍（写了反而是两把尺）。
    /// 表里对应条目指着组件本体的那一行，所以这条豁免是可审计的，不是一句"我知道它干净"。
    static let componentOwnedSinks = ["MonospacedCodeView(", "SectionHeader(", "FilePathText("]

    /// 装着绝对路径或整条命令的值。写**具体的属性名**而不是泛泛的 `.title`：
    /// 后者会命中 `SidebarSection.projects.title`（分组名，永远不含路径），
    /// 一把永远在假阳性上的闸等于没有闸。
    static let sources = [".path", "filePath", "previousPath", "projectPath", "workingDirectory",
                          "commandLine", "event.command", "record.command", "draftDump",
                          "storeDirectory", "monitoredRoots", "ignoredPathPatterns",
                          "localizedDescription", "sensitivePrefixes", "event.title",
                          "risk.title", "finding.summary", "session.title"]

    /// 出现即算「这一眼过去是遮过的」。
    static let maskers = ["demoRedaction", "mask.scrub", "pathMask", "FilePathText",
                          "apply(to:", "scrub(", "deabsolutized", ".tail("]

    /// 同一个来源名、但值不是路径的用法（条数、函数声明、`.count`）。
    static let notAPath = [".count", "func ", "let count"]

    struct Finding: Hashable {
        let file: String
        let line: Int
        let excerpt: String
        /// 这一处出口的**调用跨度**全文——登记表拿它比对针脚（针往往写在跨度的另一行上）。
        let context: String
    }

    /// 一个出口的**调用跨度**：从 sink 那一行起，到括号配平为止（上限 8 行）。
    /// 为什么要跨度：真正的多行参数形状是
    ///     .accessibilityLabel(demoRedaction.scrub(Copy.x.format(
    ///         language, project.path, …
    ///     )))
    /// ——只看第一行会漏，只看缩进会误；括号深度是这里唯一稳的尺。
    static func callSpan(of lines: [String], startingAt index: Int) -> Range<Int> {
        var depth = 0
        var seenParen = false
        var end = index
        while end < lines.count, end < index + 8 {
            for character in lines[end] {
                if character == "(" { depth += 1; seenParen = true }
                else if character == ")" { depth -= 1 }
            }
            if seenParen, depth <= 0 { return (index)..<(end + 1) }
            end += 1
        }
        return index..<min(lines.count, index + 4)
    }

    /// 纯函数入口：喂一段源码，吐出违规行。
    /// 磁盘版只是它的一层薄壳——尺子本身要能被探针量（本仓的教训：改松一格的磁盘版照样全绿）。
    static func findings(in source: String, file: String) -> (checked: Int, hits: [Finding]) {
        let raw: [Substring] = source.split(separator: "\n", omittingEmptySubsequences: false)
        var code: [(line: Int, text: String)] = []
        var skipUntil = -1
        for offset in raw.indices {
            if offset + 1 <= skipUntil { continue }
            if let end = BilingualCopyGate.previewBlockEnd(lines: Array(raw[offset...]), at: 0) {
                // 预览块：整块跳掉（只跳块本身，不跳到文件尾——那会给文件尾开后门）。
                skipUntil = offset + end
                continue
            }
            let stripped = BilingualCopyGate.codeOnly(raw[offset])
            if stripped.isEmpty { continue }
            code.append((offset + 1, stripCopyAccessors(stripped)))
        }
        let texts = code.map(\.text)
        var checked = 0
        var hits: [Finding] = []
        var index = 0
        while index < code.count {
            let line = texts[index]
            guard sinks.contains(where: { hasCall(line, $0) }) else { index += 1; continue }
            let span = callSpan(of: texts, startingAt: index)
            let chunk = texts[span].joined(separator: " ")
            guard sources.contains(where: { chunk.contains($0) }),
                  notAPath.contains(where: { chunk.contains($0) }) == false
            else { index += 1; continue }
            checked += 1
            if maskers.contains(where: { chunk.contains($0) }) { index = span.upperBound; continue }
            if componentOwnedSinks.contains(where: { line.contains($0) }) {
                index = span.upperBound; continue
            }
            hits.append(Finding(file: file, line: code[index].line,
                                excerpt: line.trimmingCharacters(in: .whitespaces),
                                context: chunk))
            index = span.upperBound
        }
        return (checked, hits)
    }

    /// `Text(` 这一类不带点的 sink 要有左边界：`func storeDirectoryText(` 里也含着 `Text(`，
    /// 那不是出口，是一个名字以 Text 结尾的函数。
    static func hasCall(_ line: String, _ sink: String) -> Bool {
        guard !sink.hasPrefix(".") else { return line.contains(sink) }
        for range in line.ranges(of: sink) {
            if range.lowerBound == line.startIndex { return true }
            let before = line[line.index(before: range.lowerBound)]
            if !before.isLetter, !before.isNumber, before != "_" { return true }
        }
        return false
    }

    /// 文案表访问器不是路径来源：`SessionsCopy.detailStartedAt` 里的 `detail`
    /// 会假装命中来源名（整段换成 `COPY`，长度与位置都不重要，判定只看有没有路径值）。
    static func stripCopyAccessors(_ line: String) -> String {
        var out = line
        var search = out.startIndex
        while let r = out.range(of: "Copy.", range: search..<out.endIndex) {
            var end = r.upperBound
            while end < out.endIndex, out[end].isLetter || out[end].isNumber || out[end] == "_" {
                end = out.index(after: end)
            }
            out.replaceSubrange(r.lowerBound..<end, with: "COPY")
            search = out.index(after: r.lowerBound)
        }
        return out
    }

    /// 磁盘版：扫一个目录。
    static func scan(relativeDirectory: String) throws -> (files: Int, checked: Int, hits: [Finding]) {
        let root = try BilingualCopyGate.repoRoot()
        var files = 0, checked = 0
        var hits: [Finding] = []
        for url in try BilingualCopyGate.swiftFiles(under: relativeDirectory) {
            let relative = String(url.path.dropFirst(root.path.count + 1))
            files += 1
            let text = try String(contentsOf: url, encoding: .utf8)
            let result = findings(in: text, file: relative)
            checked += result.checked
            hits.append(contentsOf: result.hits)
        }
        return (files, checked, hits)
    }
}

// MARK: - 守卫

@Suite("UI: #89 出口清单——分母、接线、证据、出口闸", .serialized)
struct ExitChannelInventoryTests {

    private static let all = ExitChannelInventory.channels

    // MARK: ① 份数与分母

    /// 条数钉死。**改这个数字的人必须先看见这张表**：这就是"新增出口不登记就红"的另一半。
    /// 数字来源：2026-09-23 两路枚举（界面各页 / 屏外通道）+ 本单逐条读源码复核。
    @Test("份数守卫：总条数与各面条数")
    func counts() {
        #expect(Self.all.count == 64, "清单总条数变了（现在是 64）：改数字前先看 ExitChannelInventory 的头注释")
        #expect(ExitChannelInventory.count(on: .ui) == 47)
        #expect(ExitChannelInventory.count(on: .export) == 7)
        #expect(ExitChannelInventory.count(on: .cli) == 5)
        #expect(ExitChannelInventory.count(on: .clipboard) == 2)
        #expect(ExitChannelInventory.count(on: .notification) == 1)
        #expect(ExitChannelInventory.count(on: .store) == 1)
        #expect(ExitChannelInventory.count(on: .log) == 1)
    }

    /// 「登记为不遮」是这张表上唯一会随时间变长的一类，所以单独钉一份。
    /// 新增一条不遮的出口 ⇒ 这里红，除非有人真的想清楚了并写下理由。
    @Test("未接遮罩的出口只有登记过的这几条（含越界交回总控的那两条）")
    func uncoveredIsEnumerated() {
        let ids = Set(ExitChannelInventory.uncovered.map(\.id))
        let expected: Set<String> = [
            "ui.sessions.leafProjectName", "ui.files.diffLineContent", "ui.security.matchedRuleID",
            "ui.menuBar.window", "export.failureAlert", "export.fileNameAndTarget",
            "cli.stderr.precondition", "store.database", "log.unified.publicPaths",
        ]
        #expect(ids.count == ExitChannelInventory.uncovered.count, "有两条共用 id ⇒ 表里有格子被吞了")
        let extra = ids.subtracting(expected).sorted().joined(separator: ", ")
        let absent = expected.subtracting(ids).sorted().joined(separator: ", ")
        #expect(ids == expected, "未遮罩清单变了：多出来 [\(extra)] / 少了 [\(absent)]")
        // 其中"真的带路径/命令"的那几条是欠账，别和"本来就没东西可遮"的混在一起。
        let owing = Set(ExitChannelInventory.uncoveredSensitive.map(\.id))
        #expect(owing.isSuperset(of: ["export.failureAlert", "cli.stderr.precondition",
                                      "log.unified.publicPaths"]),
                "欠账（两态都漏的屏外出口）少列了一条 ⇒ 交付报告的 ICR 与表对不上")
    }

    @Test("每一格都写清了「开关关掉时输出什么」，且 id 唯一")
    func everyChannelStatesTheOffBehavior() {
        for channel in Self.all {
            #expect(!channel.offBehavior.isEmpty, "\(channel.id) 没写关闭态行为")
            #expect(!channel.place.isEmpty, "\(channel.id) 没写它在哪一屏")
        }
        let ids = Self.all.map(\.id)
        #expect(Set(ids).count == ids.count, "id 重复：\(ids.enumerated().compactMap { i, id in ids.firstIndex(of: id) != i ? id : nil })")
    }

    /// 两个 flag 不许合并（派单硬约束）。默认值一起钉：漂回去是一次隐私事故。
    @Test("开关语义不合并：凭据默认开、路径遮罩默认关")
    func flagsStayIndependent() throws {
        #expect(ObservatorySettings.default.demoRedactedOutput == false,
                "路径遮罩的默认值被改开了 ⇒ 演示口径变成了默认行为")
        let off = PathPrivacy.Mask.configured(from: ObservatorySettings.default, home: "/Users/dev")
        #expect(off.isOff, "默认设置解析出非恒等映射")
        // 导出侧那一条只能读源码：`ExportRequest` 的默认值写在 init 上，构造它要一整套 destination。
        let request = try BilingualCopyGate.codeOnlyString("Sources/AIObservatoryExport/ExportRequest.swift")
        #expect(request.contains("redactionEnabled: Bool = true"),
                "导出凭据脱敏的默认值不再是 true ⇒ 安全边界消失了（它与路径遮罩是两个开关，不许一起漂）")
        #expect(request.contains("pathMask: PathPrivacy.Mask = .off"),
                "导出侧路径遮罩的默认值不再是 .off ⇒ 演示口径变成了默认行为")
    }

    // MARK: ② 接线针

    @Test("每一条已遮的出口，源码里那一行遮罩调用还在（剥注释后逐字比）")
    func anchorsStillPointAtRealCode() throws {
        var missing: [String] = []
        for channel in Self.all {
            for anchor in channel.anchors {
                let (file, needle) = split(anchor, channel.id)
                do {
                    let code = try BilingualCopyGate.codeOnlyString(file)
                    if !code.contains(needle) { missing.append("\(channel.id) → \(file) 里找不到 \(needle)") }
                } catch {
                    missing.append("\(channel.id) → 读不到 \(file)：\(error)")
                }
            }
        }
        #expect(missing.isEmpty, "接线针失效（遮罩被重构掉，或文件改名）：\n\(missing.joined(separator: "\n"))")
    }

    @Test("口径注释也是承重结构：指着它的针不许悄悄消失")
    func docAnchorsStillThere() throws {
        for channel in Self.all where !channel.docAnchors.isEmpty {
            for anchor in channel.docAnchors {
                let (file, needle) = split(anchor, channel.id)
                let raw = try String(contentsOf: BilingualCopyGate.repoRoot().appending(path: file),
                                     encoding: .utf8)
                #expect(raw.contains(needle), "\(channel.id) 的口径出处 \(needle) 被人删了 ⇒ 口径变了没？")
            }
        }
    }

    // MARK: ③ 证据针

    @Test("每一条带证据针的出口，指着的用例真的存在（防「表漂亮而没人测过」）")
    func evidencePointsAtARealTest() throws {
        let withEvidence = Self.all.filter { !$0.evidence.isEmpty }
        // 份数守卫：证据针本身要有覆盖率，否则"每条都有证据"是空话。
        #expect(withEvidence.count >= 20, "只有 \(withEvidence.count) 条出口带证据针 ⇒ 这张表大半是没测过的")
        var missing: [String] = []
        for channel in withEvidence {
            let (file, needle) = split(channel.evidence, channel.id)
            let text = try String(contentsOf: BilingualCopyGate.repoRoot().appending(path: file),
                                  encoding: .utf8)
            if !text.contains(needle) { missing.append("\(channel.id) → \(file) 里没有用例 \(needle)") }
        }
        #expect(missing.isEmpty, "证据针悬空：\n\(missing.joined(separator: "\n"))")
    }

    // MARK: ④ 出口闸

    @Test("出口闸：界面里每一处把路径喂进可见文本的地方，要么遮过、要么在表上（含分母守卫）")
    func exitGateScansTheWholeUI() throws {
        let (files, checked, hits) = try ExitGate.scan(relativeDirectory: "Sources/AIObservatoryUI")
        #expect(files > 100, "只扫到 \(files) 个源文件 ⇒ 扫描根是坏的，这条闸没有分母")
        #expect(checked >= 20, "只判到 \(checked) 处路径出口 ⇒ 出口/来源清单失效，闸是空转的（今天 23 处）")
        let unregistered = hits.filter { ExitChannelInventory.isRegistered($0) == false }
        let report = unregistered
            .map { "\($0.file):\($0.line)  \($0.excerpt)" }
            .sorted().joined(separator: "\n")
        #expect(unregistered.isEmpty,
                "有 \(unregistered.count) 处路径/命令出口既没遮罩也没登记在表上（新增出口不登记就红）：\n\(report)")
    }

    // MARK: ⑤ 尺子有牙

    @Test("探针：闸必须咬得住三种真实形状（同行、跨行、组件自持）")
    func gateBitesTheShapesItClaimsTo() {
        // (a) 同一行直出 ⇒ 必须红
        let sameLine = """
        struct Row: View {
            var body: some View { Text(change.path) }
        }
        """
        let a = ExitGate.findings(in: sameLine, file: "Row.swift")
        #expect(a.hits.count == 1, "同行直出的 `Text(change.path)` 没被判红 ⇒ 闸是空的")

        // (b) 跨行参数（老闸的漏网形状）⇒ 必须红
        let multiLine = """
        struct Row: View {
            var body: some View {
                VStack {
                    Text(row.label)
                        .accessibilityLabel(ProjectsCopy.cardA11ySummary.format(
                            language,
                            project.path,
                            project.fileChangeCount
                        ))
                }
            }
        }
        """
        let b = ExitGate.findings(in: multiLine, file: "Card.swift")
        #expect(b.hits.count == 1,
                "跨行的 `.accessibilityLabel(Copy.format(language, project.path))` 没被抓住 ⇒ 本单要治的就是这个形状")

        // (c) 同一形状但接了遮罩 ⇒ 不许红
        let masked = multiLine.replacingOccurrences(of: ".accessibilityLabel(ProjectsCopy",
                                                   with: ".accessibilityLabel(demoRedaction.scrub(ProjectsCopy")
        let c = ExitGate.findings(in: masked, file: "Card.swift")
        #expect(c.hits.isEmpty, "已经遮过的反而判红 ⇒ 这把尺会把人逼去注释掉出口")

        // (d) 组件自持（调用点不写遮罩）⇒ 不许红
        let component = """
        struct Detail: View {
            var body: some View { MonospacedCodeView(record.commandLine, maxLines: 2) }
        }
        """
        let d = ExitGate.findings(in: component, file: "Detail.swift")
        #expect(d.hits.isEmpty, "组件自持遮罩的那一类被误判 ⇒ 下一手会去重复遮一遍")

        // (e) 名字以 Text 结尾的函数不是出口 ⇒ 不许红
        let notACall = "func storeDirectoryText(_ language: AppLanguage) -> String { \"\" }"
        #expect(ExitGate.findings(in: notACall, file: "M.swift").hits.isEmpty,
                "`func …Text(` 被当成了出口：sink 的左边界尺是坏的")
    }

    @Test("自证：未遮豁免都住在闸扫得到的目录里（豁免指向扫描根之外 = 假豁免）")
    func exemptionsLiveInsideTheScanRoot() throws {
        let root = try BilingualCopyGate.repoRoot()
        let visited = Set(try BilingualCopyGate.swiftFiles(under: "Sources/AIObservatoryUI")
            .map { String($0.path.dropFirst(root.path.count + 1)) })
        #expect(visited.count > 100, "扫描根只收到 \(visited.count) 个文件 ⇒ 分母是坏的")
        for channel in ExitChannelInventory.uncovered where channel.surface == .ui {
            #expect(!channel.anchors.isEmpty,
                    "\(channel.id) 登记为不遮却没留下任何源码针 ⇒ 没人能验证它还在")
            for anchor in channel.anchors {
                let file = anchor.split(separator: "|", maxSplits: 1).map(String.init).first ?? ""
                #expect(visited.contains(file),
                        "\(channel.id) 的豁免针指着 \(file)，而闸扫不到这个文件 ⇒ 这条豁免是空的")
            }
        }
    }

    private func split(_ anchor: String, _ id: String) -> (String, String) {
        let parts = anchor.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
            .map(String.init)
        #expect(parts.count == 2, "\(id) 的针没写成 `文件|片段`：\(anchor)")
        return parts.count == 2 ? (parts[0], parts[1]) : (anchor, "")
    }
}
