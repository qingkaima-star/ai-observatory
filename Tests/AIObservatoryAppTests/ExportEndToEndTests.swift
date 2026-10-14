//
//  ExportEndToEndTests.swift
//  AIObservatoryAppTests
//
//  Owner: 总控（组合根 / 需求⑥ 导出）
//  ─────────────────────────────────────────────────────────
//  为什么要有这个文件：`969bb96` 修掉了「导出主入口每次必失败」，但那条用例只证明
//  `ExportRequest.validate()` 不抛——**校验通过不等于写得出来**。
//  本仓在导出上栽过的正是这种"中间层绿、末端空"的形状：菜单 ⌘⇧E 走的是
//  `kinds(for:) → validate() → ExportCoordinator.run()` 一整条链，
//  而全仓从来没有人把这条链跑到底并检查**落盘文件里真的含有被审计的内容**。
//
//  断言刻意不用"再算一遍"当期望：查的是已知字面量（样本数据里写死的那几条标题）
//  与已知条数，以及"每个 artifact 的文件真的存在且非空"。
//

import Foundation
import Testing
@testable import AIObservatoryApp
import AIObservatoryCore
import AIObservatoryExport
import AIObservatoryTestSupport

@Suite("App: 导出整条链真落盘（需求⑥）", .timeLimit(.minutes(2)))
struct ExportEndToEndTests {

    /// 样本数据里写死的内容（`SampleData`），用来证明"导出的是真数据而不是空壳"。
    private static let knownRiskTitle = "Agent 执行了高风险删除命令"
    private static let stamp = Date(timeIntervalSince1970: 1_900_000_000)

    private func makeRequest(
        _ format: ActivityExportRequest.Format,
        directory: URL
    ) -> ExportRequest {
        ExportRequest(
            format: ObservatoryExporting.exportFormat(for: format),
            kinds: ObservatoryExporting.kinds(for: format),
            dateRange: .unbounded,
            generatedAt: Self.stamp,
            redactionEnabled: true,
            destination: ExportDestination(directory: directory, allowedRoots: [directory])
        )
    }

    /// 跑一遍三种格式，返回 (格式, 产物)。每种格式都用**独立目录**，
    /// 这样"文件数对不对"是可以直接数出来的，不用去猜哪个属于哪个 kind。
    /// 一个格式一轮导出的结果。**用具名字段而不是元组**：
    /// `$0.0 == .markdown` 这种写法编译器推不出枚举上下文，报错信息也没法看。
    private struct Run {
        var format: ActivityExportRequest.Format
        var artifacts: [ExportedArtifact]
        var directory: URL
    }

    /// `tag` 把每个测试自己的产物目录隔开：`generatedAt` 是**故意钉死的常量**
    /// （产物文件名里带时间戳，不钉住就没法断言文件名），于是同一目录里两次导出
    /// 会写到同一个文件上，覆盖路径在这个环境下会抛 `couldn't be removed`。
    private func runAll(tag: String) async throws -> [Run] {
        let service = SampleData.demoService(now: Self.stamp, sessionCount: 12)
        var result: [Run] = []
        for format in [ActivityExportRequest.Format.markdown, .json, .csv] {
            let directory = URL(fileURLWithPath: Scratch.path("export-e2e-\(tag)-\(format.rawValue)"), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let artifacts = try await ExportCoordinator().run(makeRequest(format, directory: directory), service: service)
            result.append(Run(format: format, artifacts: artifacts, directory: directory))
        }
        return result
    }

    @Test("三种格式都真的产出文件，且每个产物存在、非空、落在用户选定的目录内")
    func everyFormatProducesNonEmptyFilesInsideTheChosenDirectory() async throws {
        let runs = try await runAll(tag: #function)
        for run in runs {
            let format = run.format, artifacts = run.artifacts, directory = run.directory
            #expect(!artifacts.isEmpty, "\(format.rawValue) 一个文件都没产出（validate 通过但写不出来）")
            for artifact in artifacts {
                let size = try #require(
                    FileManager.default.attributesOfItem(atPath: artifact.url.path)[.size] as? Int,
                    "\(artifact.url.lastPathComponent) 不存在或读不到大小"
                )
                #expect(size > 0, "\(artifact.url.lastPathComponent) 是 0 字节")
                #expect(artifact.url.deletingLastPathComponent().path == directory.path,
                        "\(artifact.url.lastPathComponent) 写到了用户选定的目录之外")
            }
        }
    }

    @Test("Markdown 只产出叙述报告一个文件；JSON / CSV 各产出五个记录文件")
    func fileShapesMatchTheKindSelection() async throws {
        let runs = try await runAll(tag: #function)
        let counts = Dictionary(uniqueKeysWithValues: runs.map { ($0.format, $0.artifacts.count) })
        #expect(counts[.markdown] == 1, "Markdown 只该有 .report 一个文件，实际 \(counts[.markdown] ?? -1)")
        #expect(counts[.json] == 5, "JSON 该有 sessions/timeline/fileChanges/commands/riskEvents 五个")
        #expect(counts[.csv] == 5, "CSV 同上")
    }

    @Test("导出的内容里查得到被审计的已知事实（不是空壳也不是别的库）")
    func exportedContentCarriesTheAuditedFacts() async throws {
        let runs = try await runAll(tag: #function)
        let markdown = try #require(runs.first { $0.format == .markdown }?.artifacts.first)
        let report = try String(contentsOf: markdown.url, encoding: .utf8)
        #expect(report.contains(Self.knownRiskTitle),
                "叙述报告里没有样本里那条风险标题 ⇒ 报告与数据源脱节")
        // 这条才是本次真正的守卫：报告曾经算得出「纳入记录：0 条」却把项目数写成非 0，
        // 因为协调器只收集"要写成文件的 kinds"，而 markdown 只有 `.report` 一个。
        #expect(!report.contains("纳入记录：0 条"),
                "报告宣称没有任何记录，但同一次导出的 JSON 里明明有 ⇒ 概览取数为空")

        let riskJSON = try #require(runs.first { $0.format == .json }?
            .artifacts.first { $0.url.lastPathComponent.contains("risk") })
        // 只数行数，不重复实现编码器的语义（顶层是信封对象：schemaVersion/kind/counts/items）。
        let payload = try Data(contentsOf: riskJSON.url)
        let envelope = try #require(
            try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            "风险导出顶层不是信封对象，格式与契约不一致"
        )
        let items = try #require(envelope["items"] as? [Any], "信封里没有 items 数组")
        #expect(items.count == 3, "样本里有三条风险，导出 JSON 的 items 是 \(items.count) 行")
    }

    @Test("导出目录之外没有任何东西被写：越界目标必须被拒")
    func refusesToWriteOutsideTheAllowedRoot() async throws {
        let service = SampleData.demoService(now: Self.stamp, sessionCount: 4)
        let chosen = URL(fileURLWithPath: Scratch.path("export-e2e-allowed"), isDirectory: true)
        try FileManager.default.createDirectory(at: chosen, withIntermediateDirectories: true)
        let outside = URL(fileURLWithPath: Scratch.path("export-e2e-outside"), isDirectory: true)
        let request = ExportRequest(
            format: .json,
            kinds: ObservatoryExporting.kinds(for: .json),
            dateRange: .unbounded,
            generatedAt: Self.stamp,
            redactionEnabled: true,
            // 允许根只有用户选的那个目录，却把输出指到外面 ⇒ 必须抛，而不是"悄悄写出去"。
            destination: ExportDestination(directory: outside, allowedRoots: [chosen])
        )
        await #expect(throws: (any Error).self) {
            _ = try await ExportCoordinator().run(request, service: service)
        }
        #expect(
            (try? FileManager.default.contentsOfDirectory(atPath: outside.path))?.isEmpty != false,
            "被拒的导出仍在越界目录里留下了文件"
        )
    }
}
