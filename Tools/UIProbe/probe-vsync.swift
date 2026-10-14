//
//  probe-vsync.swift — 可用性探针：CVDisplayLink 在本机能否拿到真实 vsync 时间戳
//
//  Owner: WS-Frames（探针，不进产品 target；证据用后即弃，产物落 tmp/）
//
//  用法: xcrun swiftc -O Tools/UIProbe/probe-vsync.swift -o tmp/uiprobe/probe-vsync
//        tmp/uiprobe/probe-vsync --seconds 5 --display main
//  退出码: 0 采到 ≥ 10 个时间戳; 2 参数错; 3 CVDisplayLink 建不起来; 4 一个回调都没收到
//

import CoreVideo
import Foundation
import IOKit
import AppKit

var seconds = 5.0
var displaySelector = "main"   // main | <CGDirectDisplayID>
var csvPath = ""
var instrument = "both"       // both | cv | ca

let argv = CommandLine.arguments
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--seconds":   i += 1; seconds = Double(argv[i]) ?? seconds
    case "--display":   i += 1; displaySelector = argv[i]
    case "--csv":       i += 1; csvPath = argv[i]
    case "--instrument": i += 1; instrument = argv[i]
    default: FileHandle.standardError.write("未知参数 \(argv[i])\n".data(using: .utf8)!)
    }
    i += 1
}

// MARK: - 显示器枚举（CVDisplayLink 需要明确的 display id，先证明能看到几块、什么模式）

func activeDisplays() -> [(id: CGDirectDisplayID, name: String)] {
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return [] }
    return (0..<Int(count)).map { idx in
        (ids[idx], screenName(for: ids[idx]))
    }
}

/// NSScreen 的本地化名，按 displayID 对上号。
func screenName(for displayID: CGDirectDisplayID) -> String {
    for screen in NSScreen.screens {
        if let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber,
           number.uint32Value == displayID {
            let scale = screen.backingScaleFactor
            return "\(screen.localizedName) #\(displayID) \(Int(screen.frame.width))x\(Int(screen.frame.height))@\(scale)x "
                + "maxRefresh=\(screen.maximumFramesPerSecond)"
        }
    }
    return "display #\(displayID) (无对应 NSScreen)"
}

print("== 活动显示器 ==")
let displays = activeDisplays()
for d in displays { print("  \(d.name)") }
if displays.isEmpty {
    FileHandle.standardError.write("CVGetActiveDisplayList 没返回任何显示器\n".data(using: .utf8)!)
    exit(3)
}

let target: CGDirectDisplayID
switch displaySelector {
case "main": target = displays[0].id
default:
    if let parsed = CGDirectDisplayID(displaySelector), displays.contains(where: { $0.id == parsed }) {
        target = parsed
    } else {
        FileHandle.standardError.write("--display 需为 main 或已列出的 displayID\n".data(using: .utf8)!)
        exit(2)
    }
}

// MARK: - CVDisplayLink 采集

/// 回调里只做「取时间戳 + 入队」，不做任何计算：回调在 CVDisplayLink 自己的高优先级线程上。
final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var stamps: [(linkTime: CVTimeStamp, systemTime: CVTimeStamp, inVBlank: UInt32)] = []

    func append(_ t: CVTimeStamp, _ s: CVTimeStamp, _ v: UInt32) {
        lock.lock(); stamps.append((t, s, v)); lock.unlock()
    }
    var count: Int { lock.lock(); defer { lock.unlock() }; return stamps.count }
    var all: [(linkTime: CVTimeStamp, systemTime: CVTimeStamp, inVBlank: UInt32)] {
        lock.lock(); defer { lock.unlock() }; return stamps
    }
}

let sink = Sink()

// 用 CVDisplayLinkCreateWithCGDisplay：`target` 是上面 NSScreen 对过号的那块屏，
// 再用 CreateWithActiveCGDisplays + SetCurrentCGDisplay 会另选一块，读数就对不上对象。
var linkRef: CVDisplayLink?
let createStatus = CVDisplayLinkCreateWithCGDisplay(target, &linkRef)
guard let displayLink = linkRef, createStatus == kCVReturnSuccess else {
    let hex = String(UInt32(bitPattern: createStatus), radix: 16)
    FileHandle.standardError.write(
        "CVDisplayLinkCreateWithCGDisplay(\(target)) 失败 status=\(createStatus) (0x\(hex))\n"
        .data(using: .utf8)!)
    exit(3)
}
var period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
let nominal = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(displayLink)
let startStatus = CVDisplayLinkSetOutputHandler(displayLink) { _, inNow, inOutputTime, _, _ in
    sink.append(inOutputTime.pointee, inNow.pointee, 0)
    return kCVReturnSuccess
}
if startStatus != kCVReturnSuccess {
    FileHandle.standardError.write("CVDisplayLinkSetOutputHandler 失败 status=\(startStatus)\n".data(using: .utf8)!)
    exit(3)
}
guard CVDisplayLinkStart(displayLink) == kCVReturnSuccess else {
    FileHandle.standardError.write("CVDisplayLinkStart 失败\n".data(using: .utf8)!)
    exit(3)
}

let deadline = Date().addingTimeInterval(seconds)
while Date() < deadline { usleep(100_000) }
CVDisplayLinkStop(displayLink)
period = CVDisplayLinkGetActualOutputVideoRefreshPeriod(displayLink)
print("== API 直报 ==")
print("  ActualOutputVideoRefreshPeriod = \(String(format: "%.6f", period)) s "
    + "(\(period > 0 ? String(format: "%.2f", 1 / period) : "n/a") Hz)")
// CVTime 在 Swift 侧被桥成不透明结构，这里只把原样值打出来，不做手写时间戳算术。
print("  NominalOutputVideoRefreshPeriod = \(nominal)")

let rows = sink.all
print("== 回调次数 = \(rows.count) / 窗口 \(seconds)s ==")
guard rows.count >= 10 else {
    FileHandle.standardError.write("回调太少（\(rows.count)），无法给出周期分布\n".data(using: .utf8)!)
    exit(4)
}

func machToSeconds(_ t: CVTimeStamp) -> Double {
    if t.videoTimeScale > 0 { return Double(t.videoTime) / Double(t.videoTimeScale) }
    if t.rateScalar != 0 { return Double(t.hostTime) / 1_000_000_000.0 * Double(t.rateScalar) }
    return Double(t.hostTime) / 1_000_000_000.0
}

let linkTimes = rows.map { machToSeconds($0.linkTime) }
// hostTime 是 mach absolute time，比例由 mach_timebase_info 给（本机不是 1:1 时写死 1e9 就会错）。
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let machToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0
FileHandle.standardError.write("mach_timebase numer=\(timebase.numer) denom=\(timebase.denom)\n".data(using: .utf8)!)
let hostTimes = rows.map { Double($0.systemTime.hostTime) * machToSeconds }
let wall = rows.map { Double($0.systemTime.videoTime) / Double(max($0.systemTime.videoTimeScale, 1)) }

func describe(name: String, _ xs: [Double]) {
    let deltas = stride(from: 1, to: xs.count, by: 1).map { xs[$0] - xs[$0 - 1] }.sorted()
    guard deltas.count >= 2 else { print("  \(name): 样本太少"); return }
    func q(_ p: Double) -> Double { deltas[max(0, min(deltas.count - 1, Int(Double(deltas.count) * p)))] }
    let mean = deltas.reduce(0, +) / Double(deltas.count)
    // 相邻差 > 1.5×中位数 = 一次「跳过一个 vsync」的形态，先如实计数，别叫它掉帧。
    let skipped = deltas.filter { $0 > q(0.5) * 1.5 }.count
    print("  \(name): n=\(deltas.count) min=\(String(format: "%.3f", (deltas.first ?? 0) * 1000))ms "
        + "P50=\(String(format: "%.3f", q(0.5) * 1000))ms P95=\(String(format: "%.3f", q(0.95) * 1000))ms "
        + "P99=\(String(format: "%.3f", q(0.99) * 1000))ms max=\(String(format: "%.3f", (deltas.last ?? 0) * 1000))ms "
        + "mean=\(String(format: "%.3f", mean * 1000))ms 超1.5×P50=\(skipped)")
}
print("== vsync 间隔分布（毫秒）==")
describe(name: "videoTime ", linkTimes)
describe(name: "hostTime  ", hostTimes)
describe(name: "sysTime   ", wall)

/// CADisplayLink 的 timestamp 是秒（与 mach time base 对齐），只看相邻差值即可和仪器一对照。
func describeCADeltas(name: String, _ xs: [Double]) {
    guard xs.count >= 10 else { print("  \(name): 样本太少（\(xs.count)），分布不给"); return }
    let deltas = stride(from: 1, to: xs.count, by: 1).map { xs[$0] - xs[$0 - 1] }.sorted()
    func q(_ p: Double) -> Double { deltas[max(0, min(deltas.count - 1, Int(Double(deltas.count) * p)))] }
    print("  \(name): n=\(deltas.count) min=\(String(format: "%.3f", (deltas.first ?? 0) * 1000))ms "
        + "P50=\(String(format: "%.3f", q(0.5) * 1000))ms P95=\(String(format: "%.3f", q(0.95) * 1000))ms "
        + "max=\(String(format: "%.3f", (deltas.last ?? 0) * 1000))ms")
}

if !csvPath.isEmpty {
    var out = "index,videoTime_ns,hostTime_ns\n"
    for (idx, row) in rows.enumerated() {
        out += "\(idx),\(row.linkTime.videoTime),\(row.systemTime.hostTime)\n"
    }
    try? out.write(toFile: csvPath, atomically: true, encoding: .utf8)
    print("== CSV 已写出: \(csvPath) ==")
}

// MARK: - 仪器二：CADisplayLink（SDK 头文件写的是 `API_AVAILABLE(macos(14.0))`，本机要实测真能收到回调）

final class CATarget: NSObject, @unchecked Sendable {
    private(set) var stamps: [Double] = []
    private(set) var durations: [Double] = []
    private(set) var targets: [Double] = []
    private var observed: CADisplayLink?

    @objc func tick(_ link: CADisplayLink) {
        stamps.append(link.timestamp)
        durations.append(link.duration)
        targets.append(link.targetTimestamp)
        observed = link
    }
    var last: CADisplayLink? { observed }
}

if instrument != "cv" {
    print("== 仪器二 CADisplayLink ==")
    if #available(macOS 14.0, *) {
        let ca = CATarget()
        guard let screen = NSScreen.screens.first else {
            FileHandle.standardError.write("没有 NSScreen，CADisplayLink 无从挂\n".data(using: .utf8)!)
            exit(3)
        }
        let link = screen.displayLink(target: ca, selector: #selector(CATarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        let caDeadline = Date().addingTimeInterval(seconds)
        // 不能用 run(mode:before:)——传 .common 会撞上 CFRunLoopRunSpecific 的
        // "invalid mode 'kCFRunLoopCommonModes'"，回调一次都不来（第一版踩过，别再来一次）。
        while Date() < caDeadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        link.invalidate()
        print("  回调次数 = \(ca.stamps.count) / 窗口 \(seconds)s")
        print("  link.duration = \(String(format: "%.6f", ca.last?.duration ?? 0)) s "
            + "(\(ca.last.map { $0.duration > 0 ? String(format: "%.2f", 1 / $0.duration) : "n/a" } ?? "-") Hz)")
        if let l = ca.last {
            let range = l.preferredFrameRateRange
            print("  link.preferredFrameRateRange = min=\(range.minimum) max=\(range.maximum) preferred=\(range.preferred)")
            print("  (frameInterval / preferredFramesPerSecond 在 macOS 上 unavailable，编译器已直接拒绝)")
        }
        describeCADeltas(name: "timestamp    ", ca.stamps)
        describeCADeltas(name: "targetStamp  ", ca.targets)
    } else {
        print("  #available(macOS 14.0) 判定为不可用（本机 \(ProcessInfo.processInfo.operatingSystemVersionString)）")
    }
}
exit(0)
