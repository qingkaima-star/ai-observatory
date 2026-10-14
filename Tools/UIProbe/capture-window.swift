//
//  capture-window.swift — 只截我们自己的那个窗口。
//
//  Owner: master-controller（开发工具，不进产品 target）
//
//  为什么不用 `screencapture` 的默认（全屏）模式：本项目发生过一次隐私事故——
//  全屏截图把用户其它无关窗口一起抓进来了（里面有一个代理订阅 token）。
//  所以真机 UI 验收**只允许单窗口**截图。
//
//  也不用 Python 的 Quartz 绑定：这台机器没装 pyobjc，纪律是不静默装系统依赖。
//  macOS 26 SDK 里 `CGWindowListCreateImage` 已标 unavailable（指向 ScreenCaptureKit，
//  要录屏授权 + 异步栈），但**列表** API 仍可用 ⇒ 取 window id 交给系统自带的
//  `screencapture -l<id>`，那是单窗口合成，别的窗口压在它上面也不会被拍进去。
//
//  用法：
//    swiftc -O Tools/UIProbe/capture-window.swift -o tmp/uiprobe/cap
//    tmp/uiprobe/cap --owner AIObservatory --out tmp/uiprobe/dashboard.png
//    tmp/uiprobe/cap --pid 4242 --out tmp/uiprobe/dashboard.png   # 按 owner pid 精确选窗
//    tmp/uiprobe/cap --list                      # 列出候选窗口（排查用）
//  退出码：0 成功；2 找不到窗口或截图失败。
//
//  为什么必须有 `--pid`：多条工作流会在同一台机器上同时跑同一个二进制，
//  ⚠️ owner 名**随运行形态变**（06:22 实测，别再凭读码断言）：
//     · 打包运行：`kCGWindowOwnerName` = **CFBundleName**，与窗口标题逐字相同（都是应用名）；
//     · `swift run`：owner = **进程名** `AIObservatory`，与标题不同。
//     ⇒ 所以 owner 不是一个稳定字符串，跨形态唯一可靠的选法是 `--pid`；
//        `--owner` / `--title` 只在已知运行形态时作辅助过滤。
//  只按 --owner 匹配时取的是窗口列表里的第一个，可能拍到别的车道那个实例的界面，
//  而截图看起来完全正常 ⇒ 目视验收会对着错误的数据库给出「已验证」的结论。
//  按 owner pid 选窗才是可证明的。
//

import AppKit
import CoreGraphics
import Foundation

struct Args {
    var ownerMatch = ""
    var titleMatch = ""
    var pidMatch = 0
    var out = ""
    var listOnly = false
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

func parseArgs() -> Args {
    var a = Args()
    let argv = CommandLine.arguments
    var i = 1
    while i < argv.count {
        switch argv[i] {
        case "--owner": i += 1; a.ownerMatch = argv[safe: i] ?? ""
        case "--title": i += 1; a.titleMatch = argv[safe: i] ?? ""
        case "--pid": i += 1; a.pidMatch = Int(argv[safe: i] ?? "") ?? 0
        case "--out": i += 1; a.out = argv[safe: i] ?? ""
        case "--list": a.listOnly = true
        default: break
        }
        i += 1
    }
    return a
}

/// 所有「有 owner、有标题、在屏幕上」的普通窗口。
func candidateWindows() -> [[String: Any]] {
    let ownerKey = kCGWindowOwnerName as String
    let titleKey = kCGWindowName as String
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return [] }
    return list.filter { dict in
        ((dict[ownerKey] as? String)?.isEmpty == false)
            && (dict[titleKey] as? String) != nil
            && (dict[kCGWindowNumber as String] as? Int) != nil
    }
}

func describe(_ window: [String: Any]) -> String {
    let pid = window[kCGWindowOwnerPID as String] ?? "?"
    return "\(pid)\t\(window[kCGWindowOwnerName as String] ?? "?")\t\(window[kCGWindowName as String] ?? "?")"
}

let args = parseArgs()
let windows = candidateWindows()

if args.listOnly {
    for w in windows { print("\(describe(w))\t\(w[kCGWindowNumber as String] ?? "?")") }
    exit(0)
}

if args.ownerMatch.isEmpty && args.titleMatch.isEmpty && args.pidMatch == 0 {
    FileHandle.standardError.write("必须至少给 --pid / --owner / --title 之一；只按第一个匹配窗口在多实例机器上会拍错。\n".data(using: .utf8)!)
    exit(2)
}

guard let window = windows.first(where: { w in
    let owner = (w[kCGWindowOwnerName as String] as? String) ?? ""
    let title = (w[kCGWindowName as String] as? String) ?? ""
    let pid = (w[kCGWindowOwnerPID as String] as? Int) ?? -1
    let ownerOK = args.ownerMatch.isEmpty || owner.localizedCaseInsensitiveContains(args.ownerMatch)
    let titleOK = args.titleMatch.isEmpty || title.localizedCaseInsensitiveContains(args.titleMatch)
    let pidOK = args.pidMatch == 0 || pid == args.pidMatch
    return ownerOK && titleOK && pidOK
}), let number = window[kCGWindowNumber as String] as? Int else {
    FileHandle.standardError.write("找不到匹配窗口；当前候选：\n".data(using: .utf8)!)
    for w in windows {
        FileHandle.standardError.write("\(describe(w))\n".data(using: .utf8)!)
    }
    exit(2)
}

let directory = URL(fileURLWithPath: args.out).deletingLastPathComponent()
try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
task.arguments = ["-o", "-x", "-l\(number)", args.out]
do {
    try task.run()
    task.waitUntilExit()
} catch {
    FileHandle.standardError.write("启动 screencapture 失败：\(error)\n".data(using: .utf8)!)
    exit(2)
}

guard task.terminationStatus == 0,
      let size = try? FileManager.default.attributesOfItem(atPath: args.out)[.size] as? Int,
      size > 0 else {
    FileHandle.standardError.write("截图失败 exit=\(task.terminationStatus)\n".data(using: .utf8)!)
    exit(2)
}
print("captured window \(number) (\(describe(window))) → \(args.out) (\(size) bytes)")
