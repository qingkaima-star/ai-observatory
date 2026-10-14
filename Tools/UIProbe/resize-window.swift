//
//  resize-window.swift — 按 pid 调整自己那个窗口的大小与位置。
//
//  Owner: WS-Verify（开发工具，不进产品 target）
//
//  为什么需要它：逐页目视验收要求「不靠点击」也能看到页面下半部分
//  （性能页有第四张曲线、项目页有热点榜、设置页有长表单）。
//  往系统发 `key code` 是错的办法——事件进的是**当时最靠前的那个 app**，
//  既没滚到自己的窗口，又顺手在用户的别的窗口里敲了键。
//  Accessibility API 是按 pid 定向的，只作用于目标窗口。
//
//  用法：
//    swiftc -O Tools/UIProbe/resize-window.swift -o tmp/uiprobe/resize
//    tmp/uiprobe/resize --pid 4242 --width 1600 --height 2400 --y -1200
//  退出码：0 成功；2 拿不到窗口或设置失败。
//

import ApplicationServices
import Foundation

var pid = 0
var width = 0.0
var height = 0.0
var x: Double?
var y: Double?

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--pid":    i += 1; pid = Int(argv[i]) ?? 0
    case "--width":  i += 1; width = Double(argv[i]) ?? 0
    case "--height": i += 1; height = Double(argv[i]) ?? 0
    case "--x":      i += 1; x = Double(argv[i])
    case "--y":      i += 1; y = Double(argv[i])
    default: break
    }
    i += 1
}

guard pid > 0 else {
    FileHandle.standardError.write("必须给 --pid\n".data(using: .utf8)!)
    exit(2)
}
guard AXIsProcessTrusted() else {
    FileHandle.standardError.write("本进程没有 Accessibility 授权，无法定向操作窗口。\n".data(using: .utf8)!)
    exit(2)
}

let app = AXUIElementCreateApplication(pid_t(pid))

func copyAttribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
    var value: CFTypeRef?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}

guard let windowsRef = copyAttribute(app, kAXWindowsAttribute) else {
    FileHandle.standardError.write("pid \(pid) 没有可访问的窗口（进程已退出？窗口未开？）\n".data(using: .utf8)!)
    exit(2)
}
let cfWindows = windowsRef as! CFArray
guard CFArrayGetCount(cfWindows) > 0 else {
    FileHandle.standardError.write("pid \(pid) 的窗口列表为空\n".data(using: .utf8)!)
    exit(2)
}
let window = unsafeBitCast(CFArrayGetValueAtIndex(cfWindows, 0), to: AXUIElement.self)

func setSize(_ element: AXUIElement, width: Double, height: Double) -> Bool {
    var size = CGSize(width: width, height: height)
    guard let value = AXValueCreate(.cgSize, &size) else { return false }
    return AXUIElementSetAttributeValue(element, kAXSizeAttribute as CFString, value) == .success
}

func setPosition(_ element: AXUIElement, x: Double, y: Double) -> Bool {
    var point = CGPoint(x: x, y: y)
    guard let value = AXValueCreate(.cgPoint, &point) else { return false }
    return AXUIElementSetAttributeValue(element, kAXPositionAttribute as CFString, value) == .success
}

var ok = true
if width > 0, height > 0 { ok = setSize(window, width: width, height: height) && ok }
if let x, let y { ok = setPosition(window, x: x, y: y) && ok }
else if let y {
    // 只给 y 时保留当前 x
    var current = CGPoint.zero
    if let ref = copyAttribute(window, kAXPositionAttribute),
       AXValueGetValue(ref as! AXValue, .cgPoint, &current) {
        ok = setPosition(window, x: Double(current.x), y: y) && ok
    }
}

guard ok else {
    FileHandle.standardError.write("设置窗口尺寸/位置失败\n".data(using: .utf8)!)
    exit(2)
}

var finalSize = CGSize.zero
if let ref = copyAttribute(window, kAXSizeAttribute),
   AXValueGetValue(ref as! AXValue, .cgSize, &finalSize) {
    print("window now \(Int(finalSize.width))x\(Int(finalSize.height))")
} else {
    print("window resized")
}
exit(0)
