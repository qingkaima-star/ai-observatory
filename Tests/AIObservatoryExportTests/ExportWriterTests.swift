//
//  ExportWriterTests.swift
//  AIObservatoryExportTests
//
//  Owner: WS-Export（子代理 E）
//
//  覆盖：缓冲阈值分块（memory / file）、危险路径与越界路径拒绝且不留痕、
//  finish 之后禁写 + finish 幂等、空写入、多字节 UTF-8 往返、路径策略边界。
//
//  产物只落 `Scratch.root`（当前检出自带的 `.scratch-tests/`）/export/writer/<用例独占子目录>，
//  每个用例结尾 defer 清理；不写家目录、不写 /tmp、不写桌面。
//  全部同步执行，不起线程、不等待、不轮询、不 sleep —— 必定终止。
//

import Foundation
import Testing

import AIObservatoryExport
import AIObservatoryTestSupport

// MARK: - 沙盒工具

/// 本用例独占的沙盒目录 `<writer 根>/<caseName>`；上次残留会先清掉，保证可重复运行。
private func exportWriterSandbox(_ caseName: String) throws -> URL {
    let root = Scratch.root.appendingPathComponent("export/writer", isDirectory: true)
    let base = root.appendingPathComponent(caseName)
    let manager = FileManager.default
    if manager.fileExists(atPath: base.path) {
        try manager.removeItem(at: base)
    }
    try manager.createDirectory(at: base, withIntermediateDirectories: true)
    return base
}

/// 执行 `body`，返回它抛出的 `ExportError`（未抛错则返回 nil）。
private func exportWriterCatchExportError(_ body: () throws -> Void) -> ExportError? {
    do {
        try body()
        return nil
    } catch let error as ExportError {
        return error
    } catch {
        Issue.record("只接受 ExportError，实际抛出：\(error)")
        return nil
    }
}

/// 路径是否已在磁盘上留下痕迹。
private func exportWriterExists(_ url: URL) -> Bool {
    FileManager.default.fileExists(atPath: url.path)
}

/// 该错误是否为「危险系统路径」。
private func exportWriterIsPathForbidden(_ error: ExportError?) -> Bool {
    guard let error else { return false }
    if case .pathForbidden = error { return true }
    return false
}

// MARK: - 用例

@Suite("ExportWriter · 流式写入与路径隐私")
struct ExportWriterTests {

    @Test("memory sink：阈值 8 字节，100 次 8 字节写入必须分块且字节数精确")
    func memorySinkFlushesAtSmallThreshold() throws {
        let base = try exportWriterSandbox("memory-chunks")
        defer { try? FileManager.default.removeItem(at: base) }

        var writer = ExportWriter.memory(chunkThresholdBytes: 8)
        for _ in 0 ..< 100 {
            try writer.write("abcdefgh")
        }
        try writer.finish()

        #expect(writer.chunkCount >= 2)
        #expect(writer.bytesWritten == 800)
        #expect(writer.destinationURL == nil)
        let data = try writer.collectedData()
        #expect(data.count == 800)
        #expect(String(data: data, encoding: .utf8) == String(repeating: "abcdefgh", count: 100))
    }

    @Test("file sink：4096 字节、阈值 1024 → 分块落盘，不拼全文")
    func fileSinkWritesInChunks() throws {
        let base = try exportWriterSandbox("file-chunks")
        defer { try? FileManager.default.removeItem(at: base) }

        let url = base.appendingPathComponent("out.csv")
        var writer = try ExportWriter.file(url, allowedRoots: [base], chunkThresholdBytes: 1024)
        let line = String(repeating: "x", count: 1024)
        for _ in 0 ..< 4 {
            try writer.write(line)
        }
        try writer.finish()

        #expect(exportWriterExists(url))
        let data = try Data(contentsOf: url)
        #expect(data.count == 4096)
        #expect(writer.chunkCount >= 2)
        #expect(writer.bytesWritten == 4096)
        #expect(writer.destinationURL == url)
        #expect(data == Data(repeating: 0x78, count: 4096))   // 'x'
    }

    @Test("file sink：覆盖同名旧文件，不追加在旧内容之后")
    func fileSinkOverwritesExistingFile() throws {
        let base = try exportWriterSandbox("file-overwrite")
        defer { try? FileManager.default.removeItem(at: base) }

        let url = base.appendingPathComponent("out.json")
        try Data("上一轮遗留的很长很长很长的一段旧内容 {{ {{ {{".utf8).write(to: url)

        var writer = try ExportWriter.file(url, allowedRoots: [base], chunkThresholdBytes: 4)
        try writer.write("{}")
        try writer.finish()

        let data = try Data(contentsOf: url)
        #expect(data == Data("{}".utf8))
        #expect(String(data: data, encoding: .utf8) == "{}")
    }

    @Test("危险路径：全部抛错且磁盘上不留任何文件")
    func dangerousPathsRejectedWithoutTrace() throws {
        let base = try exportWriterSandbox("forbidden-paths")
        defer { try? FileManager.default.removeItem(at: base) }

        let home = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        let cases: [(label: String, url: URL)] = [
            // 字面 `~` 目录组件：未展开的波浪号（`URL(string: "~/x")` 形态落到 URL.path 上就是这样）。
            ("波浪号字面目录", URL(fileURLWithPath: "/~/out.csv")),
            // `URL(fileURLWithPath: "~/out.csv")` 会被 Foundation 提前展开成 `/Users/<用户名>/out.csv`，
            // 波浪号字面量在 URL 里丢失；策略靠「直接落在家目录根 ⇒ 禁写」认出它（见下方错误类型断言）。
            ("波浪号被展开后的家目录根路径", URL(fileURLWithPath: "~/out.csv")),
            ("/System 内部", URL(fileURLWithPath: "/System/Library/x.csv")),
            ("根目录", URL(fileURLWithPath: "/")),
            ("/etc 内部", URL(fileURLWithPath: "/etc/evil.csv")),
            ("家目录之下", home.appendingPathComponent("x.csv")),
            ("允许根之外的只读目录", URL(fileURLWithPath: "\(FixturePaths.outsideAllowedRoot)/evil.csv")),
        ]

        for item in cases {
            let error = exportWriterCatchExportError {
                _ = try ExportWriter.file(item.url, allowedRoots: [base])
            }
            #expect(error != nil, "\(item.label) 必须被拒绝：\(item.url.path)")
            // 错误类型也要具体：落在家目录根（`~/x` 被 Foundation 展开后的形态）必须报
            // `.pathForbidden`（策略认得这个位置），而不是含糊的「越出 allowedRoots」。
            if (item.url.path as NSString).deletingLastPathComponent == NSHomeDirectory() {
                #expect(exportWriterIsPathForbidden(error),
                        "\(item.label)：家目录根必须报 .pathForbidden，实际 \(String(describing: error))")
            }
            if item.url.path == "/" {
                // 根目录本来就存在：断言它仍然是目录，没被写成文件。
                let values = try? item.url.resourceValues(forKeys: [.isDirectoryKey])
                #expect(values?.isDirectory == true, "/ 必须仍是目录")
            } else {
                #expect(exportWriterExists(item.url) == false, "\(item.label) 不得留下文件")
            }
        }

        // 策略入口的错误类型：波浪号与系统目录必须是 .pathForbidden（错误要具体）。
        let tildeForms: [(label: String, url: URL)] = [
            ("未展开的波浪号相对路径 ~/out.csv", URL(fileURLWithPath: "~/out.csv")),
            ("字面波浪号目录 /~/out.csv", URL(fileURLWithPath: "/~/out.csv")),
            ("波浪号被展开成家目录本身 ~", URL(fileURLWithPath: "~")),
            ("系统目录 /System/Library/x.csv", URL(fileURLWithPath: "/System/Library/x.csv")),
            ("系统目录 /etc/evil.csv", URL(fileURLWithPath: "/etc/evil.csv")),
            ("家目录本身", URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)),
        ]
        for (label, url) in tildeForms {
            let error = exportWriterCatchExportError {
                try ExportPathPolicy.validate(fileURL: url, allowedRoots: [base])
            }
            #expect(exportWriterIsPathForbidden(error), "\(label) 应抛 .pathForbidden，实际 \(String(describing: error))")
        }
    }

    @Test("finish 之后再 write 抛 alreadyFinished；finish 幂等不重复关闭")
    func writeAfterFinishThrowsAndFinishIsIdempotent() throws {
        let base = try exportWriterSandbox("after-finish")
        defer { try? FileManager.default.removeItem(at: base) }

        let url = base.appendingPathComponent("out.json")
        var writer = try ExportWriter.file(url, allowedRoots: [base], chunkThresholdBytes: 4)
        try writer.write("abcd")
        try writer.finish()

        let chunksAfterFirstFinish = writer.chunkCount
        #expect(chunksAfterFirstFinish >= 1)
        #expect(writer.bytesWritten == 4)

        let late = exportWriterCatchExportError {
            try writer.write("不该被接受的后续内容")
        }
        #expect(late == ExportError.alreadyFinished(path: url.path))

        try writer.finish()          // 第二次：直接返回，不崩、不重复关闭
        #expect(writer.chunkCount == chunksAfterFirstFinish)
        #expect(writer.bytesWritten == 4)
        #expect(try Data(contentsOf: url).count == 4)

        // memory sink 同样禁写，且路径描述指向内存 sink。
        var memoryWriter = ExportWriter.memory(chunkThresholdBytes: 4)
        try memoryWriter.write("wxyz")
        try memoryWriter.finish()
        let memoryChunks = memoryWriter.chunkCount
        let lateOnMemory = exportWriterCatchExportError {
            try memoryWriter.write("again")
        }
        #expect(lateOnMemory == ExportError.alreadyFinished(path: "memory sink"))
        try memoryWriter.finish()
        #expect(memoryWriter.chunkCount == memoryChunks)
        #expect(try memoryWriter.collectedData().count == 4)
    }

    @Test("空写入：chunkCount 为 0，file sink 产出 0 字节文件，memory sink 数据为空")
    func emptyWriteProducesNoChunk() throws {
        let base = try exportWriterSandbox("empty-write")
        defer { try? FileManager.default.removeItem(at: base) }

        let url = base.appendingPathComponent("empty.md")
        var fileWriter = try ExportWriter.file(url, allowedRoots: [base])
        try fileWriter.finish()
        #expect(fileWriter.chunkCount == 0)
        #expect(fileWriter.bytesWritten == 0)
        #expect(exportWriterExists(url))
        #expect(try Data(contentsOf: url).isEmpty)

        var memoryWriter = ExportWriter.memory()
        try memoryWriter.write("")
        try memoryWriter.write(Data())
        try memoryWriter.finish()
        #expect(memoryWriter.chunkCount == 0)
        #expect(memoryWriter.bytesWritten == 0)
        #expect(try memoryWriter.collectedData().isEmpty)
    }

    @Test("file sink 上调用 collectedData() 抛 invalidRequest")
    func collectedDataOnFileSinkThrows() throws {
        let base = try exportWriterSandbox("collected-data-on-file")
        defer { try? FileManager.default.removeItem(at: base) }

        let url = base.appendingPathComponent("out.csv")
        var writer = try ExportWriter.file(url, allowedRoots: [base])
        try writer.write("a,b,c\n")
        try writer.finish()

        let error = exportWriterCatchExportError {
            _ = try writer.collectedData()
        }
        #expect(error == ExportError.invalidRequest("collectedData 仅支持 memory sink"))
    }

    @Test("多字节内容（é / 中文 / 🦀）按 UTF-8 往返，跨块不被切断")
    func multibyteRoundTrip() throws {
        let base = try exportWriterSandbox("multibyte")
        defer { try? FileManager.default.removeItem(at: base) }

        let pieces = [
            "héllo 中文 🦀\n",
            "隐私铁律 · §2 — \"quotes\" , commas |\n",
            "🐾🥕 emoji only\n",
            "混合 ascii 与 漢字 ✅\n",
        ]
        let expected = pieces.joined()
        let expectedData = Data(expected.utf8)

        let url = base.appendingPathComponent("report.md")
        var fileWriter = try ExportWriter.file(url, allowedRoots: [base], chunkThresholdBytes: 7)
        var memoryWriter = ExportWriter.memory(chunkThresholdBytes: 7)
        for piece in pieces {
            try fileWriter.write(piece)
            try memoryWriter.write(piece)
        }
        try fileWriter.finish()
        try memoryWriter.finish()

        let fileData = try Data(contentsOf: url)
        #expect(fileData == expectedData)
        #expect(String(data: fileData, encoding: .utf8) == expected)
        #expect(fileWriter.bytesWritten == expectedData.count)
        #expect(fileWriter.chunkCount >= 2)

        let memoryData = try memoryWriter.collectedData()
        #expect(memoryData == expectedData)
        #expect(memoryData == fileData)
        #expect(memoryWriter.bytesWritten == expectedData.count)
    }

    @Test("isForbiddenSystemPath 前缀边界：不误伤同前缀目录，家目录只禁本身")
    func forbiddenSystemPathBoundaries() {
        #expect(ExportPathPolicy.isForbiddenSystemPath("/"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("//"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/System"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/System/"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/System/Library/x.csv"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/usr"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/usr/bin/env"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/bin"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/sbin"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/etc"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/etc/evil.csv"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/var"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/private"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/private/var/db/x.json"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/Applications"))
        #expect(ExportPathPolicy.isForbiddenSystemPath("/Applications/Foo.app/out.md"))
        #expect(ExportPathPolicy.isForbiddenSystemPath(NSHomeDirectory()))
        #expect(ExportPathPolicy.isForbiddenSystemPath(NSHomeDirectory() + "/"))

        // 同前缀但不同目录：不得误伤。
        #expect(ExportPathPolicy.isForbiddenSystemPath("/Systematic/a.csv") == false)
        #expect(ExportPathPolicy.isForbiddenSystemPath("/usrshare/x") == false)
        #expect(ExportPathPolicy.isForbiddenSystemPath("/binx/y") == false)
        #expect(ExportPathPolicy.isForbiddenSystemPath("/etcetera/z") == false)
        #expect(ExportPathPolicy.isForbiddenSystemPath("/ApplicationsHandoff/x") == false)
        #expect(ExportPathPolicy.isForbiddenSystemPath("/varfolders/x") == false)
        // 家目录本身禁止，其内部（是否可写交给 allowedRoots）不禁止。
        #expect(ExportPathPolicy.isForbiddenSystemPath(NSHomeDirectory() + "/Documents/AiX/x.csv") == false)
        #expect(
            ExportPathPolicy.isForbiddenSystemPath(Scratch.path("export/writer/x/out.csv")) == false
        )
    }

    @Test("validate：空 allowedRoots 与越界目录抛 pathOutsideAllowedRoots，等于/位于根内放行")
    func validateAllowedRootsRules() throws {
        let base = try exportWriterSandbox("validate-roots")
        defer { try? FileManager.default.removeItem(at: base) }

        // 空 allowedRoots = 不允许任何写入。
        let emptyRoots = exportWriterCatchExportError {
            try ExportPathPolicy.validate(
                fileURL: base.appendingPathComponent("ok.json"),
                allowedRoots: []
            )
        }
        switch emptyRoots {
        case let .pathOutsideAllowedRoots(path, roots):
            #expect(path == base.appendingPathComponent("ok.json").path)
            #expect(roots.isEmpty)
        case .some(let error):
            Issue.record("期望 pathOutsideAllowedRoots，实际：\(error)")
        case nil:
            Issue.record("空 allowedRoots 必须抛错")
        }

        // 合法但越界（只读的 Obsidian 库）。
        let outside = URL(fileURLWithPath: "\(FixturePaths.outsideAllowedRoot)/evil.csv")
        let outsideError = exportWriterCatchExportError {
            _ = try ExportWriter.file(outside, allowedRoots: [base])
        }
        switch outsideError {
        case let .pathOutsideAllowedRoots(path, roots):
            #expect(path == outside.path)
            #expect(roots.count == 1)
        case .some(let error):
            Issue.record("期望 pathOutsideAllowedRoots，实际：\(error)")
        case nil:
            Issue.record("越界路径必须抛错")
        }
        #expect(exportWriterExists(outside) == false)

        // 目标等于允许根本身 → 放行。
        do {
            try ExportPathPolicy.validate(fileURL: base, allowedRoots: [base])
        } catch {
            Issue.record("目标等于允许根时应放行，实际抛出：\(error)")
        }

        // 位于根内（带尾斜杠的根、以及需要新建的子目录）→ 放行。
        let rootWithSlash = URL(fileURLWithPath: base.path + "/", isDirectory: true)
        do {
            try ExportPathPolicy.validate(
                fileURL: base.appendingPathComponent("nested/deep/out.csv"),
                allowedRoots: [rootWithSlash]
            )
        } catch {
            Issue.record("根内路径应放行，实际抛出：\(error)")
        }
    }

    @Test("符号链接逃逸：允许根内的软链指向外部时被拒绝且不写出")
    func symlinkEscapeIsRejected() throws {
        let base = try exportWriterSandbox("symlink-escape")
        defer { try? FileManager.default.removeItem(at: base) }

        let link = base.appendingPathComponent("escape")
        // 逃逸目标必须是**本机真实存在**的目录：实测 Foundation 的
        // `resolvingSymlinksInPath()` 不跟随悬空符号链接（目标不存在时原样返回链接自身的路径），
        // 于是「不落盘的合成路径」会让解析结果落回允许根内、策略根本不参与判定，
        // 用例只因写不出文件而拿到一个 IO 错误——假绿。
        // 目标同样放 Scratch：策略若回归，越界写入的落点仍在仓库内，不污染家目录（见文件头不变量）。
        let outsideDir = Scratch.root.appendingPathComponent("export/escape-target", isDirectory: true)
        try? FileManager.default.removeItem(at: outsideDir)
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: outsideDir) }
        #expect(FileManager.default.fileExists(atPath: outsideDir.path),
                "逃逸目标目录必须真实存在，否则符号链接不被解析、本用例会假通过")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outsideDir)
        let throughLink = link.appendingPathComponent("evil.csv")

        let error = exportWriterCatchExportError {
            _ = try ExportWriter.file(throughLink, allowedRoots: [base])
        }
        #expect(error != nil)
        #expect(exportWriterExists(outsideDir.appendingPathComponent("evil.csv")) == false)
        #expect(exportWriterExists(throughLink) == false)
    }
}
