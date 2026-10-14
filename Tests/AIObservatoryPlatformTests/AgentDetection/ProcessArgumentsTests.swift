//
//  ProcessArgumentsTests.swift
//  AIObservatoryPlatformTests
//
//  Owner: master-controller
//
//  真机 argv 解析的回归。这个 bug 藏了很久：`KERN_PROCARGS2` 的布局是
//  `argc → exec_path → NUL 填充 → argv… → envp…`，而解析代码从 `argc` 位置直接读 `argc` 个字符串，
//  于是把可执行文件路径当成 `argv[0]`，整体后移一位、**末位参数丢失**。
//  真机表现：`sh -c "chmod -R 777 ./junk; sleep 4"` 读成 `["/bin/sh","sh","-c"]`，命令文本消失
//  ⇒ 只看命令文本的结构式风险规则（递归放权 / 抹盘 / rm -rf）在生产里恒不命中。
//  所有相关单测都是手工构造 `ProcessRecord(arguments:)` 喂进去的，永远抓不到解析器本身的问题，
//  ⇒ 唯一有效的测法是起一个真进程。
//

import Foundation
import Testing
@testable import AIObservatoryPlatform
import AIObservatoryCore

@Suite("WS-Agent：真机 argv 解析", .timeLimit(.minutes(1)))
struct ProcessArgumentsTests {

    /// 起一个真进程 `sh -c "read x"`，要求 argv 三个参数一字不差、且 exec_path 不混进来。
    @Test("argv 逐字保真：不后移、不丢末位、不掺入 exec_path")
    func argumentsAreParsedVerbatim() async throws {
        let child = Process()
        // ⚠️ 命令必须是**纯 builtin**，不能让 sh 去 exec 外部程序。
        // 原先用 `sh -c "sleep 30"`：`sleep` 是外部命令，sh 会 `exec` 掉自己 ⇒
        // **同一个 pid 的 argv 从 3 项变成 2 项**（实测失败输出正是
        // `argv 应有 3 项，实际 2 项：["sleep","30"]`）。
        // 那不是我最初猜的"半截 argv 竞态"，而是**被测进程自己会改 argv**——
        // 于是这条用例在断言一个本身会合法变化的值，负载只让它更容易被观察到。
        // `read` 是 builtin，sh 永不 exec ⇒ argv 恒为 `["/bin/sh","-c","read x"]`，
        // 且末位仍是带空格的命令文本，正好是要验的那一格。
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", "read x"]
        // stdin 给一根**永不写入也不关闭**的管道：`read` 就永久阻塞。
        // 用 nullDevice 会让 `read` 立刻拿到 EOF、进程秒退，又变回"采到已退出的进程"。
        let stdinPipe = Pipe()
        child.standardInput = stdinPipe
        // `close()` 会抛错，defer 体里不许往外抛 ⇒ 这里刻意吞掉：
        // 收尾时关不得上管道不影响结论，子进程已经由下面的 terminate 处理了。
        defer { try? stdinPipe.fileHandleForWriting.close() }
        try child.run()
        defer { if child.isRunning { child.terminate(); child.waitUntilExit() } }

        // 有界轮询，且等到 argv 真的读全为止。
        // 索引前必须先卡住长度：`arguments` 为空时取 `[1]` 会抛
        // `Fatal error: Index out of range`，直接把整个测试二进制打挂（signal 5），
        // 连带别人正在跑的用例一起没了。
        let inspector = LibprocProcessInspector()
        let pid = child.processIdentifier
        var found: ProcessRecord?
        for _ in 0..<40 {
            let records = await inspector.scanProcesses()
            found = records.first { $0.pid == pid }
            if let record = found, record.arguments.count >= 3 { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let record = try #require(found, "子进程应在退出前被扫描到（pid=\(pid)）")
        try #require(record.arguments.count >= 3,
                     "argv 应有 3 项，实际 \(record.arguments.count) 项：\(record.arguments)")
        // `argv[0]` 的写法由调用方决定（Foundation 的 Process 传全路径，C 运行时常传 "sh"），
        // 所以不断言它的值，只断言**结构**：`-c` 必须在第二个位置、命令文本必须在末位。
        // 改前的实际输出是 `["/bin/sh","sh","-c"]` —— 两条断言当时都必红。
        #expect(record.arguments[1] == "-c", "参数整体后移 ⇒ argv[0] 被 exec_path 占了位")
        #expect(record.arguments.last == "read x", "末位参数不能丢：它就是命令文本本身")
    }
}
