//
//  AixMain.swift
//  aix（可执行薄壳）
//
//  Owner: ws/cli（#65）
//  ─────────────────────────────────────────────────────────
//  只有装配：argv → `Aix.run` → 两个流 + 退出码。
//  全部逻辑在 `AIObservatoryCLI`（可测的那半边），所以用例能直接拿到「退出码 + 字节流」，
//  不必起子进程、也不必依赖 `.build/<配置>/aix` 这条脆弱路径。
//  文件名不叫 `main.swift`：带 `@main` 的文件用了那个名字会撞 SwiftPM 的入口文件规则。
//

import Foundation
import AIObservatoryCLI

@main
struct AixMain {
    static func main() async {
        let output = await Aix.run(arguments: Array(CommandLine.arguments.dropFirst()))
        FileHandle.standardOutput.write(Data(output.stdout.utf8))
        FileHandle.standardError.write(Data(output.stderr.utf8))
        exit(output.exitCode)
    }
}
