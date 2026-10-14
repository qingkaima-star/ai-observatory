//
//  control-window.swift — **临时**正对照目标：一个确定在动 / 可注入已知停顿的窗口。
//
//  Owner: WS-Frames（A3 校准用，落 tmp/frames/，不进仓库、不进产品）
//  用途：证明 frame-window（SCStream 外部按窗口采帧）不是「永远返回 0」的坏尺子，
//        并且能在被采窗口**确实**跳拍时把 hitch_n 报出来（正对照）。
//  它不是 AIObservatory，不碰任何车道正在跑的实例；跑完 --seconds 自己退出。
//
//  xcrun swiftc -O tmp/frames/control-window.swift -o tmp/uiprobe/control-window
//  tmp/uiprobe/control-window --seconds 25 --hz 120 --stall-every 240 --stall-ms 40
//

import AppKit
import Foundation

var seconds = 25.0
var hz = 120.0
var stallEvery = 0
var stallMs = 0.0
var label = "UIProbeControl"
var speed = 0.05

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--seconds": i += 1; seconds = Double(argv[i]) ?? seconds
    case "--hz": i += 1; hz = Double(argv[i]) ?? hz
    case "--stall-every": i += 1; stallEvery = Int(argv[i]) ?? stallEvery
    case "--stall-ms": i += 1; stallMs = Double(argv[i]) ?? stallMs
    case "--label": i += 1; label = argv[i]
    case "--speed": i += 1; speed = Double(argv[i]) ?? speed
    default: break
    }
    i += 1
}

final class BoxView: NSView {
    var phase: Double = 0
    override var isFlipped: Bool { false }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let w: CGFloat = 70
        let t = 0.5 + 0.5 * sin(phase)
        let x = (bounds.width - w) * CGFloat(t)
        NSColor.controlAccentColor.setFill()
        NSRect(x: x, y: 30, width: w, height: bounds.height - 60).fill()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let window = NSWindow(
    contentRect: NSRect(x: 200, y: 200, width: 640, height: 400),
    styleMask: [.titled, .closable], backing: .buffered, defer: false
)
window.title = label
window.isMovableByWindowBackground = true
window.level = .normal
let view = BoxView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
window.contentView = view
// 不 activate、不抢焦点：SCStream 的按窗口通道不需要窗口在最前面，
// 抢焦点会干扰同一台机器上其它车道的真机验收。
window.orderFrontRegardless()

// 相位增量 = 每次 tick 走多远。太小会让相邻帧像素相同（实测 hz=120 却只测出 60 次内容变化），
// 所以标定「真 120Hz」时必须把 speed 调大到每帧都变。
var ticks = 0
let interval = 1.0 / hz
let timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
    ticks += 1
    view.phase += speed
    view.needsDisplay = true
    if stallEvery > 0 && stallMs > 0 && ticks % stallEvery == 0 {
        Thread.sleep(forTimeInterval: stallMs / 1000.0)   // 已知的主线程停顿 = 正对照的「跳拍」
    }
}
RunLoop.main.add(timer, forMode: .common)

FileHandle.standardError.write("control pid=\(ProcessInfo.processInfo.processIdentifier) hz=\(hz) stallEvery=\(stallEvery) stallMs=\(stallMs) speed=\(speed) for=\(seconds)s\n".data(using: .utf8)!)
let deadline = Date().addingTimeInterval(seconds)
RunLoop.main.run(until: deadline)
print("control ticks=\(ticks)")
exit(0)
