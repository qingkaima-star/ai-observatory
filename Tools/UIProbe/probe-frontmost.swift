//
//  probe-frontmost.swift — 驱动前的「打的到底是谁」守卫
//
//  Owner: WS-Frames（开发工具，不进产品 target）
//
//  为什么必须有：同一台机器上同时有 5 个以上会话在跑**同一个二进制名**的实例
//  （quiet*/frames/engperf… 各自一个 `AIObservatory`），而 `scroll-window.swift`
//  走的是 `NSRunningApplication.activate()` + `CGWarpMouseCursorPosition` +
//  `CGEvent.post(.cghidEventTap)` —— 全局坐标、全局事件。
//  macOS 并不保证 activate 一定成功（后台进程抢焦点受限），失败时滚轮打在
//  **当时最靠前那个别人的窗口**上，而帧采集（按窗口 id）又只看自己 ⇒
//  量到「自己一帧都没出」其实是「自己根本没被动」。这条错分方向足以把整张基线表作废。
//
//  用法:
//    xcrun swiftc -O Tools/UIProbe/probe-frontmost.swift -o tmp/uiprobe/frontmost
//    tmp/uiprobe/frontmost --pid 1234            # 只报事实
//    tmp/uiprobe/frontmost --pid 1234 --require  # 不是最前就退出码 2（驱动脚本据此中止）
//  退出码: 0 是目标（或不要求）; 2 要求最前但不是; 3 无此 pid; 4 拿不到窗口
//

import AppKit
import CoreGraphics
import Foundation

var pid = 0
var require = false

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--pid":    i += 1; pid = Int(argv[i]) ?? 0
    case "--require": require = true
    default: FileHandle.standardError.write("未知参数 \(argv[i])\n".data(using: .utf8)!)
    }
    i += 1
}
guard pid > 0 else {
    FileHandle.standardError.write("必须给 --pid\n".data(using: .utf8)!)
    exit(2)
}

let front = NSWorkspace.shared.frontmostApplication
let frontPid = Int(front?.processIdentifier ?? -1)
print("frontmost_pid=\(frontPid)")
print("frontmost_name=\(front?.localizedName ?? "-")")
print("frontmost_is_target=\(frontPid == pid)")

guard NSRunningApplication(processIdentifier: pid_t(pid)) != nil else {
    FileHandle.standardError.write("pid \(pid) 不存在（别拿这个 pid 继续量）\n".data(using: .utf8)!)
    exit(3)
}

/// 该 pid 在屏窗口：面积最大的那个，以及总个数——个数 >1 就意味着「按 pid 取窗口」这件事本身有歧义。
var best: CGRect = .zero
var count = 0
if let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
    as? [[String: Any]] {
    for info in list {
        guard (info[kCGWindowOwnerPID as String] as? Int) == pid,
              let d = info[kCGWindowBounds as String] as? [String: Any],
              let b = CGRect(dictionaryRepresentation: d as CFDictionary)
        else { continue }
        count += 1
        if b.width * b.height > best.width * best.height { best = b }
    }
}
print("window_count=\(count)")
print("window_area=\(Int(best.width))x\(Int(best.height))@\(Int(best.minX)),\(Int(best.minY))")
if count == 0 {
    FileHandle.standardError.write("pid \(pid) 在 CGWindowList 里没有可见窗口\n".data(using: .utf8)!)
    exit(4)
}
// 同机同名实例计数——把「为什么必须守卫」这件事量化出来。
// bundle id 从目标自己身上取，别把 `com.aix.aiobservatory` 抄死在这里（抄死会让计数静默变 0）。
let bundleID = NSRunningApplication(processIdentifier: pid_t(pid))?.bundleIdentifier ?? ""
let siblings = bundleID.isEmpty ? -1
    : NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).count
print("same_bundle_instances_alive=\(siblings)")
print("bundle_id=\(bundleID.isEmpty ? "-" : bundleID)")

if require && frontPid != pid {
    let msg = "❌ 目标 pid \(pid) 不是最靠前应用（当前是 \(frontPid)/\(front?.localizedName ?? "-")）"
        + "⇒ 此刻的滚轮与点击不会落在它身上，中止本轮，别把「没被驱动」写成「掉帧」\n"
    FileHandle.standardError.write(msg.data(using: .utf8)!)
    exit(2)
}
exit(0)
