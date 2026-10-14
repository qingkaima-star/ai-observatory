//
//  frame-pacer.swift — 契约工具 `frame-pacer`：同窗跑两把 vsync 仪器，产出 F1/F2/F3 的分母
//
//  Owner: WS-Frames（子车道 A1「进程内采集能力」）。探针，不进产品 target，编译产物落 tmp/uiprobe/。
//
//  命令行（见 Tools/UIProbe/frames-tools.contract.md，本文件不许改契约）：
//    xcrun swiftc -O Tools/UIProbe/frame-pacer.swift -o tmp/uiprobe/frame-pacer
//    tmp/uiprobe/frame-pacer --seconds 20 [--out tmp/uiprobe/pacer.csv]
//                              [--instrument both|cvdisplaylink|cadisplaylink]
//
//  stdout 只打 key=value。每台仪器一个块，块内顺序 = 契约列顺序（6 个 vsync_* 在前、instrument= 在末）：
//      vsync_n=  vsync_p50_ms=  vsync_p95_ms=  vsync_p99_ms=  vsync_max_ms=  vsync_skipped=  instrument=
//  两块之后打对照结论： instruments_agree=  instruments_p50_delta_ms=  instruments_skipped_delta=
//  契约没要求但 frame-baseline 要用的额外 key（同规则，一行一个）：
//      window_s=  vsync_intervals=  vsync_min_ms=  vsync_mean_ms=  vsync_hz=  load1_before=  load1_after=
//  人读的解释与报错一律走 stderr。
//
//  口径（写死在注释里，别让下游猜）：
//   - `vsync_n`      = 本窗内该仪器收到的**回调次数**；相邻间隔个数 = vsync_intervals = vsync_n − 1。
//   - 分位数        = 对**相邻间隔**排序后取最近秩（与已提交的 probe-vsync.swift 同一个函数，尺子不许两把）。
//   - `vsync_skipped`= 相邻间隔 > 1.5 × 本窗 P50 的次数（= 至少跳过一个 vsync 的形态）。
//   - cvdisplaylink 用 videoTime/videoTimeScale（合成器时钟）；cadisplaylink 用 link.timestamp。
//     两者不是同一个时钟原点，所以只有**间隔分布**可比，绝对时间戳不可比。
//   - 静止显示器本来就该是稳的：本工具是给 A2 当**分母**用的，它自己不构成判据。
//
//  退出码：0 两把仪器都采到 ≥ 10 个时间戳；2 参数错；3 仪器建不起来/无显示器；
//          4 至少一把仪器样本太少（对应 key 如实打 n/a，不拿 0 冒充）
//

import AppKit
import CoreVideo
import Darwin
import Foundation
import IOKit

var seconds = 5.0
var csvPath = ""
var want = "both"   // both | cvdisplaylink | cadisplaylink | cv | ca

let argv = CommandLine.arguments
var argi = 1
while argi < argv.count {
    switch argv[argi] {
    case "--seconds":
        argi += 1
        guard argi < argv.count, let v = Double(argv[argi]), v > 0 else {
            FileHandle.standardError.write("--seconds 需要一个正秒数\n".data(using: .utf8)!)
            exit(2)
        }
        seconds = v
    case "--out":
        argi += 1
        guard argi < argv.count else {
            FileHandle.standardError.write("--out 需要一个 csv 路径\n".data(using: .utf8)!)
            exit(2)
        }
        csvPath = argv[argi]
    case "--instrument":
        argi += 1
        guard argi < argv.count else {
            FileHandle.standardError.write("--instrument 需要 both|cvdisplaylink|cadisplaylink\n".data(using: .utf8)!)
            exit(2)
        }
        want = argv[argi]
    default:
        FileHandle.standardError.write("未知参数 \(argv[argi])\n".data(using: .utf8)!)
        exit(2)
    }
    argi += 1
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// emitCV / emitCA = 「调用方要这台仪器的块」；useCV / useCA = 「这台仪器真的在采」。
// 仪器挂不上时只把 use* 关掉，块照样打（内容全 n/a），别让下游把「没打」当成「不需要」。
var useCV = (want == "both" || want == "cv" || want == "cvdisplaylink")
var useCA = (want == "both" || want == "ca" || want == "cadisplaylink")
let emitCV = useCV
let emitCA = useCA
if !useCV && !useCA {
    log("--instrument 只能是 both | cvdisplaylink | cadisplaylink（收到 \(want)）")
    exit(2)
}

func load1() -> Double {
    var avg = [Double](repeating: 0, count: 3)
    let n = getloadavg(&avg, 3)
    return n > 0 ? avg[0] : -1
}

// MARK: - 采集容器（回调线程只入队，不做任何计算）

struct Tick {
    let clockNs: Int64   // 该仪器自己的 vsync 时钟（ns）
    let hostNs: Int64    // 回调到达时刻的 mach absolute time（ns）——只当参考，不参与分位数
}

final class Sink: @unchecked Sendable {
    private let lock = NSLock()
    private var ticks: [Tick] = []
    func append(_ t: Tick) { lock.lock(); ticks.append(t); lock.unlock() }
    var all: [Tick] { lock.lock(); defer { lock.unlock() }; return ticks }
}

// mach absolute time → ns 的比例由 mach_timebase_info 给，本机不是 1:1 时写死 1e9 就会错。
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let machToNs = Double(timebase.numer) / Double(timebase.denom)
log("mach_timebase numer=\(timebase.numer) denom=\(timebase.denom) → 1 mach tick = \(String(format: "%.6f", machToNs)) ns")

func hostNowNs() -> Int64 { Int64(Double(mach_absolute_time()) * machToNs) }

// MARK: - 仪器一：CVDisplayLink（合成器回调线程，独立于主 runloop）

let cvSink = Sink()
var cvLink: CVDisplayLink?
var cvStarted = false

if useCV {
    let displayID = CGMainDisplayID()
    var count: UInt32 = 0
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    let listErr = CGGetActiveDisplayList(8, &ids, &count)
    if listErr != .success || count == 0 {
        log("CGGetActiveDisplayList 失败 err=\(listErr.rawValue) count=\(count) —— 无显示器可用")
        exit(3)
    }
    if !ids.prefix(Int(count)).contains(displayID) {
        log("CGMainDisplayID()=\(displayID) 不在活动列表里（活动: \(Array(ids.prefix(Int(count))))）")
    }
    for screen in NSScreen.screens {
        if (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayID {
            log("目标显示器: \(screen.localizedName) #\(displayID) "
                + "\(Int(screen.frame.width))x\(Int(screen.frame.height)) "
                + "maximumFramesPerSecond=\(screen.maximumFramesPerSecond)")
        }
    }
    var ref: CVDisplayLink?
    let createStatus = CVDisplayLinkCreateWithCGDisplay(displayID, &ref)
    guard let created = ref, createStatus == kCVReturnSuccess else {
        log("CVDisplayLinkCreateWithCGDisplay(\(displayID)) 失败 status=\(createStatus) "
            + "(0x\(String(UInt32(bitPattern: createStatus), radix: 16)))")
        exit(3)
    }
    cvLink = created
    let handlerStatus = CVDisplayLinkSetOutputHandler(created) { _, _, out, _, _ in
        let t = out.pointee
        let ns: Int64
        if t.videoTimeScale > 0 {
            ns = Int64(Double(t.videoTime) / Double(t.videoTimeScale) * 1_000_000_000.0)
        } else {
            ns = Int64(Double(t.hostTime) * machToNs)
        }
        cvSink.append(Tick(clockNs: ns, hostNs: hostNowNs()))
        return kCVReturnSuccess
    }
    if handlerStatus != kCVReturnSuccess {
        log("CVDisplayLinkSetOutputHandler 失败 status=\(handlerStatus)")
        exit(3)
    }
    let nominal = CVDisplayLinkGetNominalOutputVideoRefreshPeriod(created)
    let actual = CVDisplayLinkGetActualOutputVideoRefreshPeriod(created)
    log("CVDisplayLink API 直报: actual_period=\(String(format: "%.6f", actual))s nominal=\(nominal)")
    if CVDisplayLinkStart(created) != kCVReturnSuccess {
        log("CVDisplayLinkStart 失败")
        exit(3)
    }
    cvStarted = true
}

// MARK: - 仪器二：CADisplayLink（挂在主 runloop，SDK 头文件 API_AVAILABLE(macos(14.0))）

/// CADisplayLink 的 timestamp 是「秒」（CoreAnimation 媒体时间，与 mach 原点不同），
/// 只取间隔；到达时刻另记 mach 戳，供 CSV 复算时区分「vsync 时钟」与「回调实际发生」。
final class CATarget: NSObject, @unchecked Sendable {
    let sink = Sink()
    private let lock = NSLock()
    private var durations: [Double] = []
    @objc func tick(_ link: CADisplayLink) {
        sink.append(Tick(clockNs: Int64(link.timestamp * 1_000_000_000.0), hostNs: hostNowNs()))
        lock.lock(); durations.append(link.duration); lock.unlock()
    }
    var medianDuration: Double {
        lock.lock(); defer { lock.unlock() }
        guard !durations.isEmpty else { return 0 }
        return durations.sorted()[durations.count / 2]
    }
}

var caTarget: CATarget?
var caLink: CADisplayLink?
// 可用性判定与「这次要不要用它」分开：调用方只要 cv 时也不能谎报 cadisplaylink 不存在。
let cadisplaylinkAvailable: Bool = {
    if #available(macOS 14.0, *) { return NSScreen.screens.first != nil }
    return false
}()

if useCA {
    if #available(macOS 14.0, *) {
        // 一把仪器挂不上不该丢掉另一把的读数：退化成「该仪器块打 n/a」，而不是整个进程 exit(3)。
        if let screen = NSScreen.screens.first {
            let target = CATarget()
            caTarget = target
            let link = screen.displayLink(target: target, selector: #selector(CATarget.tick(_:)))
            link.add(to: .main, forMode: .common)
            caLink = link
            log("CADisplayLink 已挂到 \(screen.localizedName)：duration=\(String(format: "%.6f", link.duration))s")
        } else {
            log("没有 NSScreen，CADisplayLink 无从挂 ⇒ 该仪器块打 n/a，cvdisplaylink 仍照跑")
            useCA = false
        }
    } else {
        log("CADisplayLink 在本机不可用（#available(macOS 14.0) 判定失败）⇒ 该仪器块打 n/a")
        useCA = false
    }
}

// MARK: - 同窗采集：两台仪器共用一个墙钟窗口

let caAttached = (caLink != nil)   // invalidate 之后 caLink 会被置空，先记下「本窗有没有真的挂上」
let loadBefore = load1()
let startWall = Date()
let deadline = startWall.addingTimeInterval(seconds)
while Date() < deadline {
    if caLink != nil {
        // 不能用 RunLoop.run(mode:before:) 传 .common —— 会撞上
        // "invalid mode 'kCFRunLoopCommonModes'"，CADisplayLink 一次回调都不来（probe-vsync 踩过）。
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    } else {
        usleep(50_000)
    }
}
let windowActual = Date().timeIntervalSince(startWall)
if let link = caLink { link.invalidate(); caLink = nil }
if let link = cvLink, cvStarted { CVDisplayLinkStop(link) }
let loadAfter = load1()

// MARK: - 统计

struct Stats {
    let n: Int
    let intervals: Int
    let minMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double
    let meanMs: Double
    let skipped: Int
}

/// 最近秩：与 probe-vsync.swift 的 q() 完全一致，保证两份证据用同一把尺子。
func nearestRank(_ sorted: [Double], _ p: Double) -> Double {
    let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count) * p)))
    return sorted[idx]
}

func stats(from ticks: [Tick]) -> Stats? {
    guard ticks.count >= 10 else { return nil }
    var deltas: [Double] = []
    deltas.reserveCapacity(ticks.count - 1)
    for k in 1..<ticks.count {
        deltas.append(Double(ticks[k].clockNs - ticks[k - 1].clockNs) / 1_000_000.0)
    }
    let sorted = deltas.sorted()
    let p50 = nearestRank(sorted, 0.5)
    return Stats(
        n: ticks.count,
        intervals: deltas.count,
        minMs: sorted.first ?? .nan,
        p50Ms: p50,
        p95Ms: nearestRank(sorted, 0.95),
        p99Ms: nearestRank(sorted, 0.99),
        maxMs: sorted.last ?? .nan,
        meanMs: deltas.reduce(0, +) / Double(deltas.count),
        skipped: deltas.filter { $0 > p50 * 1.5 }.count
    )
}

let cvStats = useCV ? stats(from: cvSink.all) : nil
let caTicks: [Tick] = caTarget?.sink.all ?? []
let caStats = caAttached ? stats(from: caTicks) : nil
if emitCA, caTarget == nil {
    log("CADisplayLink 没挂上（macOS 14 以下或无 NSScreen 或调用方只要了 cv）⇒ 该仪器整块打 n/a")
} else if let t = caTarget {
    log("CADisplayLink link.duration 中位数 = \(String(format: "%.6f", t.medianDuration))s "
        + "(\(t.medianDuration > 0 ? String(format: "%.2f", 1 / t.medianDuration) : "n/a") Hz)")
}

func emit(_ s: Stats?, instrumentName: String) {
    let f3: (Double) -> String = { v in
        v.isNaN ? "n/a" : String(format: "%.3f", v)
    }
    if let s {
        print("vsync_n=\(s.n)")
        print("vsync_p50_ms=\(f3(s.p50Ms))")
        print("vsync_p95_ms=\(f3(s.p95Ms))")
        print("vsync_p99_ms=\(f3(s.p99Ms))")
        print("vsync_max_ms=\(f3(s.maxMs))")
        print("vsync_skipped=\(s.skipped)")
        print("instrument=\(instrumentName)")
        print("vsync_intervals=\(s.intervals)")
        print("vsync_min_ms=\(f3(s.minMs))")
        print("vsync_mean_ms=\(f3(s.meanMs))")
        print("vsync_hz=\(s.p50Ms > 0 ? String(format: "%.3f", 1000.0 / s.p50Ms) : "n/a")")
    } else {
        print("vsync_n=0")
        print("vsync_p50_ms=n/a")
        print("vsync_p95_ms=n/a")
        print("vsync_p99_ms=n/a")
        print("vsync_max_ms=n/a")
        print("vsync_skipped=n/a")
        print("instrument=\(instrumentName)")
        log("⚠️ \(instrumentName) 样本 < 10，分母给不出：如实打 n/a（n/a ≠ 0）")
    }
}

print("window_s=\(String(format: "%.3f", windowActual))")
// 可用性证据链（不是判据，是「这把尺子在 macOS 26 上到底还在不在」的自述）：
// - CVDisplayLink 在 macOS 15 起 deprecated，但本机仍能建链并稳定出回调 ⇒ available=yes + deprecated=yes。
// - CADisplayLink 的 macOS 支持是 macOS 14 起（NSScreen.displayLink(target:selector:)）。
print("cvdisplaylink_api=CVDisplayLinkCreateWithCGDisplay")
print("cvdisplaylink_deprecated_since=macOS15.0")
print("cadisplaylink_available=\(cadisplaylinkAvailable ? "yes" : "no")")
print("cadisplaylink_since=macOS14.0")
if emitCV { emit(cvStats, instrumentName: "cvdisplaylink") }
if emitCA { emit(caStats, instrumentName: "cadisplaylink") }

// 两把仪器是否一致：只比间隔分布的 P50（时钟原点不同，绝对戳不可比）。
if let a = cvStats, let b = caStats {
    let delta = abs(a.p50Ms - b.p50Ms)
    let agree = (delta <= 0.05) && (a.skipped == b.skipped)
    print("instruments_agree=\(agree ? "yes" : "no")")
    print("instruments_p50_delta_ms=\(String(format: "%.3f", delta))")
    print("instruments_skipped_delta=\(abs(a.skipped - b.skipped))")
    log("对照：cvdisplaylink P50=\(String(format: "%.3f", a.p50Ms))ms cadisplaylink P50=\(String(format: "%.3f", b.p50Ms))ms "
        + "差 \(String(format: "%.3f", delta))ms（阈值 0.05ms）⇒ \(agree ? "一致" : "不一致")。"
        + "注意 cadisplaylink 走主 runloop，max/尾部会被主线程负载抬高，所以一致只看 P50 与 skipped。")
} else if emitCV && emitCA {
    print("instruments_agree=n/a")
    print("instruments_p50_delta_ms=n/a")
    print("instruments_skipped_delta=n/a")
    log("对照不可判：至少一把仪器样本不足")
}

print("load1_before=\(String(format: "%.2f", loadBefore))")
print("load1_after=\(String(format: "%.2f", loadAfter))")

// MARK: - CSV：每行一个时间戳，供 A2 / 别人复算

if !csvPath.isEmpty {
    var out = "instrument,seq,clock_ns,host_ns\n"
    for (idx, t) in cvSink.all.enumerated() {
        out += "cvdisplaylink,\(idx),\(t.clockNs),\(t.hostNs)\n"
    }
    for (idx, t) in caTicks.enumerated() {
        out += "cadisplaylink,\(idx),\(t.clockNs),\(t.hostNs)\n"
    }
    do {
        try out.write(toFile: csvPath, atomically: true, encoding: .utf8)
        log("CSV 已写出 \(csvPath)：cvdisplaylink=\(cvSink.all.count) 行 cadisplaylink=\(caTicks.count) 行")
    } catch {
        log("CSV 写入失败 \(csvPath): \(error)")
        exit(3)
    }
}

var tooFew = false
if emitCV { tooFew = tooFew || cvStats == nil }
if emitCA { tooFew = tooFew || caStats == nil }
if !csvPath.isEmpty {
    print("csv_path=\(csvPath)")
    print("csv_rows=\(cvSink.all.count + caTicks.count)")
}
exit(tooFew ? 4 : 0)
