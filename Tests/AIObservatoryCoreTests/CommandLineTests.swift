//
//  CommandLineTests.swift
//  AIObservatoryCoreTests
//
//  Owner: master-controller
//
//  `commandLine` 是审计页与搜索的唯一真相，也是风险规则读命令文本的入口。
//  真机 Commands 页出现过「sleep sleep 4」：argv[0] 与 executable 是同一个东西，
//  无脑拼接就重复。
//

import Foundation
import Testing
import AIObservatoryCore

@Suite("Core: 命令行文本的拼法")
struct CommandLineTests {

    private func record(_ executable: String, _ arguments: [String]) -> CommandRecord {
        CommandRecord(
            executable: executable,
            arguments: arguments,
            workingDirectory: "/Users/testhost/proj",
            startedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    @Test("argv[0] 与 executable 同名时不重复输出")
    func dedupesIdenticalArgvZero() {
        #expect(record("sleep", ["sleep", "4"]).commandLine == "sleep 4")
        #expect(record("sleep", ["/bin/sleep", "4"]).commandLine == "sleep 4")
    }

    @Test("argv[0] 与 executable 不同时两者都保留（那是真实存在的差异，不能藏）")
    func keepsDivergentArgvZero() {
        // macOS 上 /bin/sh 的 p_comm 可能是 "bash"，argv[0] 才是 "sh"——两个都是事实。
        #expect(record("bash", ["sh", "-c", "ls"]).commandLine == "bash sh -c ls")
    }

    @Test("空 arguments 时只输出 executable，不留尾随空格")
    func emptyArguments() {
        #expect(record("jq", []).commandLine == "jq")
        #expect(record("jq", []).commandLine.contains("  ") == false)
    }

    @Test("完整命令文本不被截断（风险规则靠它判定）")
    func keepsWholeCommandText() {
        let line = record("sh", ["sh", "-c", "chmod -R 777 ./junk; sleep 4"]).commandLine
        #expect(line.contains("chmod -R 777 ./junk"))
    }
}
