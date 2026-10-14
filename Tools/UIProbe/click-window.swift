//
//  click-window.swift — 按 pid 在自己那个窗口里点一下。
//
//  Owner: WS-Verify（开发工具，不进产品 target）
//
//  为什么需要：验收「需确认 → 标记已确认」这条动作不能只看按钮画没画出来，
//  必须真的点下去，再回库里看 is_acknowledged 有没有变。
//
//  坐标用**窗口内比例**（fx / fy ∈ 0…1）而不是绝对像素：
//  截图是 Retina 2x，而 CGWindowList 给的是点；用比例就不用管缩放，
//  也能直接把「在截图上看到的第几个像素」换算过来。
//
//  与 scroll-window.swift 同理：几何走 CGWindowList，不依赖会静默失效的 Accessibility。
//
//  用法：
//    swiftc -O Tools/UIProbe/click-window.swift -o tmp/uiprobe/click
//    tmp/uiprobe/click --pid 4242 --fx 0.759 --fy 0.935
//  退出码：0 成功；2 参数或窗口不可得。
//

import AppKit
import CoreGraphics
import Foundation

var pid = 0
var fx = 0.5
var fy = 0.5

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--pid": i += 1; pid = Int(argv[i]) ?? 0
    case "--fx":  i += 1; fx = Double(argv[i]) ?? fx
    case "--fy":  i += 1; fy = Double(argv[i]) ?? fy
    default: break
    }
    i += 1
}

guard pid > 0 else {
    FileHandle.standardError.write("必须给 --pid\n".data(using: .utf8)!)
    exit(2)
}
guard (0...1).contains(fx), (0...1).contains(fy) else {
    FileHandle.standardError.write("--fx / --fy 必须在 0…1 之间\n".data(using: .utf8)!)
    exit(2)
}

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
        if bounds.width < 200 || bounds.height < 200 { continue }
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

let target = CGPoint(x: bounds.minX + bounds.width * fx, y: bounds.minY + bounds.height * fy)
CGWarpMouseCursorPosition(target)
usleep(200_000)

guard let down = CGEvent(
    mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: target, mouseButton: .left
), let up = CGEvent(
    mouseEventSource: nil, mouseType: .leftMouseUp, mouseCursorPosition: target, mouseButton: .left
) else {
    FileHandle.standardError.write("构造鼠标事件失败\n".data(using: .utf8)!)
    exit(2)
}
// clickState 1 = 第一次按下；不设的话系统会把它当成连击的一部分。
down.setIntegerValueField(.mouseEventClickState, value: 1)
up.setIntegerValueField(.mouseEventClickState, value: 0)
down.post(tap: .cghidEventTap)
usleep(80_000)
up.post(tap: .cghidEventTap)

print("clicked pid \(pid) at \(Int(target.x)),\(Int(target.y)) (fx=\(fx) fy=\(fy))")
exit(0)
