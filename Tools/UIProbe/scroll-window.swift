//
//  scroll-window.swift — 按 pid 定向滚动自己那个窗口。
//
//  Owner: WS-Verify（开发工具，不进产品 target）
//
//  为什么需要：性能页有第四张曲线（网络）、项目页有热点榜、设置页有长表单，
//  而窗口高度被系统夹在屏幕以内，放大窗口并不能让折叠在下面的内容进画面。
//
//  为什么不用 `key code`：事件进的是**当时最靠前的那个 app**，
//  既没滚到自己的窗口，又顺手在用户别的窗口里敲了键。
//
//  为什么不用 Accessibility API 取窗口几何：真机上同一 pid 在启动后一两分钟内
//  `kAXWindowsAttribute` 还能拿到，之后稳定返回空列表（进程活着、窗口在屏上、
//  CGWindowList 也看得见）——验收工具不能依赖一个会静默失效的通道。
//  这里改用 `CGWindowListCopyWindowInfo` 按 owner pid 取边界，
//  与 `capture-window.swift` 同一套判据。
//
//  用法：
//    swiftc -O Tools/UIProbe/scroll-window.swift -o tmp/uiprobe/scroll
//    tmp/uiprobe/scroll --pid 4242 --ticks -6 --clicks 25
//  退出码：0 成功；2 参数或窗口不可得。
//

import AppKit
import CoreGraphics
import Foundation

var pid = 0
var ticks = -6
var clicks = 25
var widthFraction = 0.68
var heightFraction = 0.55

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--pid":     i += 1; pid = Int(argv[i]) ?? 0
    case "--ticks":   i += 1; ticks = Int(argv[i]) ?? ticks
    case "--clicks":  i += 1; clicks = Int(argv[i]) ?? clicks
    case "--fx":      i += 1; widthFraction = Double(argv[i]) ?? widthFraction
    case "--fy":      i += 1; heightFraction = Double(argv[i]) ?? heightFraction
    default: break
    }
    i += 1
}

guard pid > 0 else {
    FileHandle.standardError.write("必须给 --pid\n".data(using: .utf8)!)
    exit(2)
}

/// 该 pid 在屏幕上的主窗口边界（取面积最大的那个）。
func onScreenBounds(of pid: Int) -> CGRect? {
    guard let list = CGWindowListCopyWindowInfo(
        [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
    ) as? [[String: Any]] else { return nil }
    var best: CGRect?
    var bestArea: CGFloat = -1
    for info in list {
        guard (info[kCGWindowOwnerPID as String] as? Int) == pid,
              let dict = info[kCGWindowBounds as String] as? [String: Any],
              let bounds = CGRect(dictionaryRepresentation: dict as CFDictionary)
        else { continue }
        if bounds.width < 200 || bounds.height < 200 { continue }  // 排除提示条一类
        if bounds.width * bounds.height > bestArea {
            bestArea = bounds.width * bounds.height
            best = bounds
        }
    }
    return best
}

guard let bounds = onScreenBounds(of: pid) else {
    FileHandle.standardError.write("CGWindowList 里找不到 pid \(pid) 的可见窗口\n".data(using: .utf8)!)
    exit(2)
}

NSRunningApplication(processIdentifier: pid_t(pid))?.activate()
usleep(300_000)

// 光标落进窗口内容区，避开侧栏与顶部工具条。
let target = CGPoint(
    x: bounds.minX + bounds.width * widthFraction,
    y: bounds.minY + bounds.height * heightFraction
)
CGWarpMouseCursorPosition(target)
usleep(150_000)

for _ in 0..<max(1, clicks) {
    guard let event = CGEvent(
        scrollWheelEvent2Source: nil, units: .line,
        wheelCount: 1, wheel1: Int32(ticks), wheel2: 0, wheel3: 0
    ) else { continue }
    event.post(tap: .cghidEventTap)
    usleep(90_000)
}
print("scrolled pid \(pid) window \(Int(bounds.width))x\(Int(bounds.height)) at \(Int(target.x)),\(Int(target.y)) ticks=\(ticks) x\(clicks)")
exit(0)
