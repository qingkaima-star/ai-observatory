//
//  DataLocationTests.swift
//  AIObservatoryAppTests
//
//  Owner: master-controller
//
//  这个函数决定观测站的 SQLite 落在哪里，判错就是**把用户数据写到授权目录之外**——
//  本项目真的发生过一次（不带 `AIOBSERVATORY_DATA_DIR` 启动打包版，库写进了 `~/Library`，
//  里面是这台机器上所有 Agent 的路径与命令）。所以它的四条优先级必须逐条钉住。
//

import Foundation
import Darwin
import Testing
@testable import AIObservatoryApp
import AIObservatoryCore
import AIObservatoryTestSupport

// ⚠️ `.serialized` 不是可选的整洁，是必需的：这六条用例每次都 `setenv`/**`unsetenv`** 进程级的
// `AIOBSERVATORY_DATA_DIR`，而 Swift Testing 默认**并行**跑同 Suite 内的用例 ⇒ 一条读到另一条刚写进去的值。
// 现场：单独 `--filter DataLocationTests` 连跑 3 轮红 2 轮，红的还是三条不同的用例（:42 显式优先、:70 开发期落点、
// 空白那条）——"哪条红"随调度而定，正是共享可变状态的签名。#101。
@Suite("App: 数据目录解析（ADR-0003）", .serialized, .timeLimit(.minutes(1)))
struct DataLocationTests {

    private static let key = "AIOBSERVATORY_DATA_DIR"

    /// 测试结束后恢复原值，避免污染同一进程里的其它用例。
    private static func withEnvironment(_ value: String?, _ body: () -> Void) {
        let saved = ProcessInfo.processInfo.environment[key]
        if let value {
            setenv(key, value, 1)
        } else {
            unsetenv(key)
        }
        defer {
            if let saved { setenv(key, saved, 1) } else { unsetenv(key) }
        }
        body()
    }

    @Test("显式 AIOBSERVATORY_DATA_DIR 优先，并且目录真的被建出来")
    func environmentOverrideWins() {
        let target = Scratch.path("data-dir-override")
        DataLocationTests.withEnvironment(target) {
            #expect(DataLocation.storeDirectory == target)
            #expect(FileManager.default.fileExists(atPath: target))
        }
        try? FileManager.default.removeItem(atPath: target)
    }

    @Test("空串视为未设置（不能让一个空值把数据目录变成 \"\"）")
    func emptyOverrideIsIgnored() {
        DataLocationTests.withEnvironment("") {
            // 代码里是 `!override.isEmpty` 才算设置过，所以空串必须继续往下走判据。
            #expect(DataLocation.storeDirectory != "",
                    "未设置时应回落到后续判据，而不是直接退到内存库")
        }
    }

    @Test("目录建不出来时退回空串（= 内存库），既不崩溃也不偷偷写到别处")
    func unwritablePathFallsBackToMemory() {
        // `/System` 由 SIP 保护，普通进程不可能在里面建目录。
        DataLocationTests.withEnvironment("/System/Library/Factories/aix-should-not-exist") {
            #expect(DataLocation.storeDirectory == "")
        }
    }

    @Test("开发期（非打包运行）落在仓库内的 observatory-data/，绝不落到 ~/Library")
    func devRunStaysInsideCheckout() {
        DataLocationTests.withEnvironment(nil) {
            let resolved = DataLocation.storeDirectory
            // 测试进程的 Bundle.main 不是 .app，因此 isPackagedRun == false。
            #expect(resolved.hasSuffix("observatory-data"),
                    "开发期数据目录必须在检出内，实际是 \(resolved)")
            #expect(resolved.contains("/Library/Application Support/") == false,
                    "开发期把库写到 ~/Library 就是越界（本项目发生过一次）")
        }
    }

    @Test("只有空白的 AIOBSERVATORY_DATA_DIR 等同未设置（不能建出一个空白名目录）")
    func whitespaceOverrideIsNotAPath() {
        // 旧写法只判 `isEmpty`，于是 " " 被当成"用户配了目录"：materialize 会去建
        // 一个名字是空白的目录，而引擎侧用的是 trim 判据 ⇒ 那边仍退内存库。
        // 用户看到的现象是「目录建了、历史没有」，且两侧口径不一致。
        DataLocationTests.withEnvironment("   ") {
            let resolved = DataLocation.storeDirectory
            #expect(resolved != "   ", "空白值被当成了真目录名")
            #expect(resolved.hasSuffix("observatory-data"),
                    "空白值应等同未设置、继续走开发期判据，实际是 \(resolved)")
        }
    }

    @Test("找不到仓库时退内存库——不存在第 5 优先级（临时目录）")
    func noRepositoryMeansMemoryNotTemporaryDirectory() {
        // ADR-0003 只有四条：env → 打包运行 → 仓库内 observatory-data → 内存库。
        // 这里曾多悄悄长出第 5 条：`FileManager.default.temporaryDirectory/AIObservatoryDev`，
        // 把审计库（命令原文、路径、diff 片段）写到谁都没登记过的地方。
        // 用纯函数版才能测这一支：真实 cwd 与文件系统是全局状态，用例改不起。
        let resolved = DataLocation.devDirectory(
            fromCurrentDirectory: "/private/tmp/aix-no-repo-here/deep/a/b",
            hasMarker: { _ in false }
        )
        #expect(resolved == "", "找不到仓库必须退内存库（空串），实际是 \(resolved)")
        #expect(resolved.contains("AIObservatoryDev") == false,
                "不得退回临时目录，实际是 \(resolved)")

        // 同一条判据的正例：marker 在上一层，就必须停在那一层的 observatory-data。
        let found = DataLocation.devDirectory(
            fromCurrentDirectory: "/repos/AiX/ai-observatory/.worktrees/x",
            hasMarker: { $0 == "/repos/AiX/ai-observatory/Package.swift" }
        )
        #expect(found == "/repos/AiX/ai-observatory/observatory-data", "实际是 \(found)")
    }
}
