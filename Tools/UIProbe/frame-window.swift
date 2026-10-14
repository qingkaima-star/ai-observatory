//
//  probe-capture.swift — 仪器二：从**进程外**按「窗口」采真实呈现帧（契约名 frame-window）
//
//  Owner: WS-Frames（探针，不进产品 target；产物落 tmp/，证据用后即弃）
//  命令行契约：Tools/UIProbe/frames-tools.contract.md 的 `frame-window` 行（钉死，勿改）。
//
//  为什么这条决定成败：本车道不许改产品代码，所以「App 到底有没有在 8.33 ms 内出画面」
//  只能从合成器外面看。ScreenCaptureKit 的 SCContentFilter(desktopIndependentWindow:)
//  是唯一的「按窗口、且不需要窗口在最前面」通道。但它受屏幕录制 TCC 权限门制，
//  并且 **SCStream 只为内容变化出帧** ⇒ 静止窗口本来就 0 帧，
//  所以「presented_n=0」在本工具里是**合法读数**，绝不允许读成「卡住」。
//
//  语义要点（与 frame-baseline.schema.md 第 12/13/14 列一致）：
//  * `presented_*` 的样本 = **相邻两个「有新内容」样本的到达间隔**（宿主 CLOCK_UPTIME_RAW 时钟）。
//    重复帧（presentationTimeStamp 未推进）不计入呈现帧，只进 `buffers_n`，两者相差即 `dup_n`。
//  * `hitch_n` / `hitch_gt2_n` 的分母 vsync 由**同一个进程内同时跑的 CVDisplayLink** 现测
//    （schema 说「vsync_ms 每行重测」，不许抄上一行），也可用 `--vsync-ms` 外部钉死。
//  * 第一个间隔含 SCStream 起流延迟，是仪器自身的开销 ⇒ 除契约 `hitch_n` 外另打
//    `hitch_n_drop1=`（丢掉第一个间隔的口径）与 `startup_latency_ms=`，两个数摆在一起看。
//
//  用法:
//    xcrun swiftc -O Tools/UIProbe/frame-window.swift -o tmp/uiprobe/frame-window
//    tmp/uiprobe/frame-window --list                                  # 列候选窗口（走 stderr）
//    tmp/uiprobe/frame-window --pid 1234 --seconds 20 --out tmp/f.csv
//  退出码: 0 presented_n>0；2 参数错/无此窗口；3 权限不足或起流失败；4 presented_n==0（静止页面）
//

import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

// MARK: - 参数

var pid = 0
var seconds = 5.0
var csvPath = ""
var vsyncOverrideMs = 0.0
var listOnly = false
var verbose = false
var displayMode = false    // 诊断用：改采整块显示器，用来分清「60Hz 天花板」在窗口过滤器还是在采集管道

let argv = CommandLine.arguments
func argAt(_ idx: Int) -> String? { idx < argv.count ? argv[idx] : nil }
var i = 1
while i < argv.count {
    switch argv[i] {
    case "--pid":        i += 1; pid = Int(argAt(i) ?? "") ?? 0
    case "--seconds":    i += 1; seconds = Double(argAt(i) ?? "") ?? seconds
    case "--out":        i += 1; csvPath = argAt(i) ?? ""
    case "--vsync-ms":   i += 1; vsyncOverrideMs = Double(argAt(i) ?? "") ?? 0
    case "--list":       listOnly = true
    case "--display":    displayMode = true
    case "--verbose":    verbose = true
    default: err("未知参数 \(argv[i])")
    }
    i += 1
}

/// 人读的一律走 stderr，stdout 只留 key=value（契约要求）。
func err(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }
func key(_ k: String, _ v: String) { print("\(k)=\(v)") }
func ms(_ x: Double) -> String { String(format: "%.3f", x) }

/// 最近秩分位（与仪器一 probe-vsync.swift 同一条公式，两把尺子才可直接比）。
/// 样本不足时返回 nil ⇒ 上层打 `n/a` 而不是 `0`（`n/a` 与 `0` 是不同结论）。
func percentileSorted(_ sorted: [Double], _ p: Double) -> Double? {
    guard !sorted.isEmpty else { return nil }
    let idx = max(0, min(sorted.count - 1, Int(Double(sorted.count) * p)))
    return sorted[idx]
}

// MARK: - 采集

/// 不持有像素缓冲，但**必须看像素**：实测（tmp/frames/window-control-stall500.csv）
/// 「SCStream 只为内容变化出帧」这条在本机 macOS 26.5.2 上**不成立** ——
/// 一个每秒只重画一次的窗口照样出 796 个样本 / 10 s，且每个样本的 presentationTimeStamp 都在推进，
/// 而主线程注入的 500 ms 停顿在到达间隔里**完全看不出来**（max=30.05 ms）。
/// ⇒ 到达节奏量的是采集管道，不是 App 的出画面节奏。所以本工具把「呈现帧」重定义为
/// **画面内容真的变了的那些帧**，判据用两路：dirtyRects（SCK 自带）+ 网格像素签名（自算）。
final class FrameSink: NSObject, SCStreamDelegate, SCStreamOutput, @unchecked Sendable {
    private let lock = NSLock()
    private var hostArrivals: [Double] = []   // 每个 sample buffer 的到达时刻（秒，UPTIME_RAW）
    private var changeHost: [Double] = []     // 内容真的变了的那些帧
    private var changePts: [Double] = []
    private var lastSig: UInt64?
    private var lastPts = Double.nan
    private var firstArrival: Double?
    private(set) var dirtyFrames = 0          // dirtyRects 非空的样本数
    private(set) var dirtyUnknown = 0         // 根本没给 dirtyRects 键的样本数
    private(set) var sigUnknown = 0           // 拿不到像素缓冲的样本数
    private(set) var ptsAdvanced = 0
    private(set) var contentUnknown = 0       // 两路内容判据都没有、被「宁可多算」放行成有变化的样本数
    var contentBasis = "unknown"              // pixel_signature | dirty_rects | pts_only
    var stopError: Error?
    var verbose = false

    static func uptimeSeconds() -> Double {
        Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000.0
    }

    /// 网格采 16 行 × 32 列像素（每格 4 字节 BGRA 全取）混成一个 UInt64 签名。
    /// 采不到的变化方向是「把有变化看成没变化」⇒ 只会低估内容帧数，不会虚报流畅，这是安全方向。
    private func signature(of sampleBuffer: CMSampleBuffer) -> UInt64? {
        guard let pb = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        guard CVPixelBufferLockBaseAddress(pb, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let rows = CVPixelBufferGetHeight(pb)
        let stride = CVPixelBufferGetBytesPerRow(pb)
        guard rows > 1, stride > 4 else { return nil }
        let ptr = base.bindMemory(to: UInt8.self, capacity: Int(rows) * Int(stride))
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        let gy = 16, gx = 32
        for iy in 0..<gy {
            let y = Int((Int(rows) * (2 * iy + 1)) / (2 * gy))
            for ix in 0..<gx {
                let x = min(Int(stride) - 4, (Int(stride) * (2 * ix + 1)) / (2 * gx))
                let off = y * Int(stride) + x
                for b in 0..<4 {
                    h ^= UInt64(ptr[off + b])
                    h = h &* 1099511628211          // FNV-1a 64 位素数（写十进制，避免字面量分位看错）
                }
            }
        }
        return h
    }

    /// SCK 自己给的脏矩形：`SCStreamFrameInfo.dirtyRects`（macOS 12.3+）。
    private func dirtyRectCount(of sampleBuffer: CMSampleBuffer) -> Int? {
        let atts = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]]
        guard let atts, !atts.isEmpty else { return nil }
        var total = 0
        var sawKey = false
        for a in atts {
            guard let rects = a[SCStreamFrameInfo.dirtyRects] as? [NSValue] else { continue }
            sawKey = true
            total += rects.count
        }
        return sawKey ? total : nil
    }

    /// ⚠️ 这是本文件最贵的一行知识：`SCStreamOutput` 的回调方法是 **@optional**，
    /// 名字写错既不报错也不警告，只会一帧都收不到（第一版就死在这里，实测 `buffers_n=0`）。
    /// 真机运行时判据（tmp/frames/selector-probe.swift 原样输出）：
    ///   Swift `stream(_:didOutput:of:)`            → 方法表只有 `init`，selector 根本没暴露
    ///   Swift `stream(_:didOutputSampleBuffer:of:)` → selector = `stream:didOutputSampleBuffer:ofType:` ✅
    /// 所以必须写 `didOutputSampleBuffer:` + `of:`，并且下面用 `callbackBound` 在运行时自检。
    func stream(_ aStream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == SCStreamOutputType.screen else { return }
        let hostNow = FrameSink.uptimeSeconds()
        // CMSampleBuffer 没有 Swift 侧的 presentationTimingTime 便捷成员（编译器已拒绝），
        // 取 C 访问器；timescale 为 0 的无效时间 CMTimeGetSeconds 会给 NaN。
        let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        let isValidPts = pts.isFinite
        let sig = signature(of: sampleBuffer)
        let dirty = dirtyRectCount(of: sampleBuffer)

        lock.lock()
        if firstArrival == nil { firstArrival = hostNow }
        hostArrivals.append(hostNow)
        if isValidPts && pts != lastPts { ptsAdvanced += 1 }
        lastPts = pts
        if let d = dirty { if d > 0 { dirtyFrames += 1 } } else { dirtyUnknown += 1 }
        let isNewContent: Bool
        if let s = sig {
            if contentBasis == "unknown" { contentBasis = "pixel_signature" }
            isNewContent = (s != lastSig)
            lastSig = s
        } else {
            sigUnknown += 1
            if let d = dirty {
                if contentBasis == "unknown" || contentBasis == "pixel_signature" { contentBasis = "dirty_rects" }
                isNewContent = d > 0
            } else {
                if contentBasis == "unknown" { contentBasis = "pts_only" }
                isNewContent = true      // 两路判据都没有 ⇒ 宁可多算，绝不把「看不见」写成「静止」
                contentUnknown += 1
            }
        }
        if isNewContent {
            changeHost.append(hostNow)
            changePts.append(isValidPts ? pts : hostNow)
        }
        let verboseNow = verbose
        lock.unlock()
        if verboseNow {
            err("  frame host=\(ms(hostNow * 1000)) pts=\(isValidPts ? ms(pts * 1000) : "invalid") dirty=\(dirty.map(String.init) ?? "nil") new=\(isNewContent) valid=\(CMSampleBufferIsValid(sampleBuffer))")
        }
    }

    func stream(_ aStream: SCStream, didStopWithError error: Error) {
        let ns = error as NSError
        err("  ❌ SCStream 停止 domain=\(ns.domain) code=\(ns.code) desc=\(error.localizedDescription)")
        lock.lock(); stopError = error; lock.unlock()
    }

    struct Readings {
        var buffers: Int
        var presented: Int
        var dup: Int
        var gaps: [Double]          // 毫秒，升序（宿主到达轴）
        var ptsGaps: [Double]       // 毫秒，按 PTS 轴（合成器时钟）的相邻差
        var startup: Double?        // 第一个样本的到达时刻（秒，UPTIME_RAW）
    }

    var readings: Readings {
        lock.lock(); defer { lock.unlock() }
        let gaps = deltasMs(changeHost)
        let pgaps = deltasMs(changePts)
        return Readings(
            buffers: hostArrivals.count,
            presented: changeHost.count,
            dup: hostArrivals.count - changeHost.count,
            gaps: gaps,
            ptsGaps: pgaps,
            startup: hostArrivals.first
        )
    }

    /// 运行时自检：回调到底有没有绑定上（名字写错时这里是 false，
    /// 于是 presented_n=0 的读数是**仪器坏了**而不是**窗口静止**——两者必须能分开）。
    var callbackBound: Bool {
        responds(to: Selector(("stream:didOutputSampleBuffer:ofType:")))
    }
    var delegateBound: Bool {
        responds(to: Selector(("stream:didStopWithError:")))
    }

    var allHostArrivals: [Double] { lock.lock(); defer { lock.unlock() }; return hostArrivals }
    var allChangeHost: [Double] { lock.lock(); defer { lock.unlock() }; return changeHost }
    var allChangePts: [Double] { lock.lock(); defer { lock.unlock() }; return changePts }
}

/// 相邻差（毫秒，升序）。写成显式循环而不是 `stride().map{}.sorted()` 链：
/// 后者在本文件里让类型检查器超时（实测 error: unable to type-check this expression in reasonable time）。
func deltasMs(_ xs: [Double]) -> [Double] {
    guard xs.count >= 2 else { return [] }
    var out: [Double] = []
    out.reserveCapacity(xs.count - 1)
    for idx in 1..<xs.count { out.append((xs[idx] - xs[idx - 1]) * 1000) }
    out.sort()
    return out
}

// MARK: - vsync（同进程同窗口的 CVDisplayLink，只为 hitch 的分母）

final class VsyncSink: @unchecked Sendable {
    private let lock = NSLock()
    private var video: [Double] = []
    private var host: [Double] = []
    func append(_ v: Double, _ h: Double) { lock.lock(); video.append(v); host.append(h); lock.unlock() }
    var videoDeltasMs: [Double] { lock.lock(); defer { lock.unlock() }; return deltasMs(video) }
    var hostDeltasMs: [Double] { lock.lock(); defer { lock.unlock() }; return deltasMs(host) }
    var count: Int { lock.lock(); defer { lock.unlock() }; return video.count }
}

let vsyncSink = VsyncSink()
var timebase = mach_timebase_info_data_t()
mach_timebase_info(&timebase)
let machToSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000.0

func startVsync(on displayID: CGDirectDisplayID) -> CVDisplayLink? {
    var ref: CVDisplayLink?
    guard CVDisplayLinkCreateWithCGDisplay(displayID, &ref) == kCVReturnSuccess, let link = ref else { return nil }
    let set = CVDisplayLinkSetOutputHandler(link) { _, inNow, inOutputTime, _, _ in
        let now = inNow.pointee
        let out = inOutputTime.pointee
        let v: Double = out.videoTimeScale > 0 ? Double(out.videoTime) / Double(out.videoTimeScale) : Double(now.hostTime) * machToSeconds
        vsyncSink.append(v, Double(now.hostTime) * machToSeconds)
        return kCVReturnSuccess
    }
    guard set == kCVReturnSuccess, CVDisplayLinkStart(link) == kCVReturnSuccess else { return nil }
    return link
}

func activeDisplayIDs() -> [CGDirectDisplayID] {
    var ids = [CGDirectDisplayID](repeating: 0, count: 8)
    var count: UInt32 = 0
    guard CGGetActiveDisplayList(8, &ids, &count) == .success else { return [] }
    return Array(ids.prefix(Int(count)))
}

// MARK: - 权限与选窗

// 先 preflight，绝不主动弹系统授权框 —— 授权是用户的事，不是工具的事。
let preflight = CGPreflightScreenCaptureAccess()
err("== 屏幕录制权限 CGPreflightScreenCaptureAccess = \(preflight) ==")

let content: SCShareableContent
do {
    content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
} catch {
    err("❌ SCShareableContent 失败: \(error)")
    key("capture_permission", preflight ? "true" : "false")
    key("presented_n", "n/a")
    exit(preflight ? 2 : 3)
}
err("== 可共享窗口数 = \(content.windows.count) displays = \(content.displays.count) ==")

/// 同一个 pid 往往挂着多个窄窗口（实测 1920x30 一类）⇒ **按面积取最大**，
/// 与 scroll-window.swift / capture-window.swift 同一套判据。
/// SCWindow 没有 `owningPID` 成员（编译器已拒绝），只有 `owningApplication?.processID`。
func areaOf(_ w: SCWindow) -> CGFloat { w.frame.width * w.frame.height }
func describe(_ w: SCWindow) -> String {
    let p = w.owningApplication?.processID ?? -1
    let t = w.title ?? "-"
    let onScreen = w.isOnScreen ? "onScreen" : "offScreen"
    return "pid=\(p) \(Int(w.frame.width))x\(Int(w.frame.height))@\(Int(w.frame.origin.x)),\(Int(w.frame.origin.y)) \(onScreen) title=\(t)"
}
func pickWindow(for targetPid: Int) -> SCWindow? {
    content.windows.filter { ($0.owningApplication?.processID ?? -1) == pid_t(targetPid) && $0.frame.width >= 200 && $0.frame.height >= 200 }
        .max(by: { areaOf($0) < areaOf($1) })
}

if listOnly {
    for w in content.windows where w.frame.width >= 200 && w.frame.height >= 200 {
        err("  \(describe(w))")
    }
    exit(0)
}
guard pid > 0 else { err("必须给 --pid"); exit(2) }
guard let window = pickWindow(for: pid) else {
    err("SCShareableContent 里没有 pid \(pid) 的 ≥200x200 窗口（进程没起？窗口太小？)")
    for w in content.windows.prefix(20) { err("  \(describe(w))") }
    exit(2)
}
err("== 目标窗口 \(describe(window)) ==")

let sink = FrameSink()
sink.verbose = verbose

let activeIDs = activeDisplayIDs()
let mainDisplay = CGMainDisplayID()
err("== vsync 显示器 = \(mainDisplay)（活动显示器 \(activeIDs.count) 块: \(activeIDs.map(String.init).joined(separator: ","))）==")

// MARK: - 起流 + 同窗口 vsync

let config = SCStreamConfiguration()
config.width = Int(window.frame.width)
config.height = Int(window.frame.height)
config.minimumFrameInterval = CMTime(value: 1, timescale: 120)   // 别让流自己先限到 60Hz
config.queueDepth = 12
config.pixelFormat = kCVPixelFormatType_32BGRA
config.showsCursor = false

// --display：整块屏作为采集对象。判据用途只有一个——
// 同一个正在 120 Hz 重画的窗口，窗口过滤器给 ~60 内容帧/s，若显示器过滤器给 ~120，
// 说明天花板在窗口过滤器；若也 ~60，天花板在采集管道 / AppKit 提交路径。
let filter: SCContentFilter
if displayMode {
    guard let disp = content.displays.first else { err("--display 模式：SCShareableContent 没给出显示器"); exit(2) }
    config.width = Int(disp.width)
    config.height = Int(disp.height)
    filter = SCContentFilter(display: disp, excludingWindows: [])
} else {
    filter = SCContentFilter(desktopIndependentWindow: window)
}
let stream = SCStream(filter: filter, configuration: config, delegate: sink)
let sampleQueue = DispatchQueue(label: "framesink", qos: .userInteractive)

// addStreamOutput 在本 SDK 有两个 Swift 名字完全相同的重载
// （头文件里 NS_SWIFT_ASYNC_NAME 与 NS_SWIFT_NAME 字符串一模一样）。
// 实测被选中的那个返回 `()`（编译器原话：cannot convert value of type '()' to expected argument type 'Bool'），
// 所以它的失败信号只有 throw ⇒ catch 必须写，且**不能只靠它**：真正的守卫是下面的运行时自检
// `callback_bound`（回调名字写错时 addStreamOutput 会照样「成功」，一帧都不给）。
do {
    try stream.addStreamOutput(sink, type: SCStreamOutputType.screen, sampleHandlerQueue: sampleQueue)
} catch {
    err("❌ addStreamOutput 抛错: \(error)")
    key("capture_permission", preflight ? "true" : "false")
    key("presented_n", "n/a")
    key("callback_bound", sink.callbackBound ? "true" : "false")
    exit(3)
}
err("== 回调绑定=\(sink.callbackBound) delegate 绑定=\(sink.delegateBound) ==")
if !sink.callbackBound {
    err("❌ SCStreamOutput 回调没绑到 selector 上 ⇒ 后面所有 0 帧读数都不可用（仪器坏了，不是窗口静止）")
    key("capture_permission", preflight ? "true" : "false")
    key("presented_n", "n/a")
    key("callback_bound", "false")
    exit(3)
}

// startCapture 同理：头文件里只有 startCaptureWithCompletionHandler:，
// 显式给 handler 才能拿到「起流失败」的错误，而不是 fire-and-forget。
// 窗口起点在**起流之前**取：起流期间的头几帧也是真呈现帧，
// 反过来若从 handler 返回后才起算，第一个到达间隔会把仪器自身的开销算成 App 的（实测 -9 ms）。
let captureStart = FrameSink.uptimeSeconds()
let startGate = DispatchSemaphore(value: 0)
var startError: Error?
stream.startCapture { error in startError = error; startGate.signal() }
_ = startGate.wait(timeout: .now() + 10)
if let e = startError {
    err("❌ 起流失败: \(e)")
    key("capture_permission", preflight ? "true" : "false")
    key("presented_n", "n/a")
    key("callback_bound", sink.callbackBound ? "true" : "false")
    exit(3)
}
let displayLink = startVsync(on: mainDisplay)
err("== 采集中 \(seconds)s（窗口静止时本来就可能 0 帧，这是预期，不是卡住）==")
while FrameSink.uptimeSeconds() - captureStart < seconds { usleep(20_000) }
let captureEnd = FrameSink.uptimeSeconds()
if let link = displayLink { CVDisplayLinkStop(link) }
let stopGate = DispatchSemaphore(value: 0)
var stopError: Error?
stream.stopCapture { error in stopError = error; stopGate.signal() }
_ = stopGate.wait(timeout: .now() + 10)
if let e = stopError { err("  stopCapture 报错: \(e)") }

// MARK: - 汇总

let r = sink.readings
let vsyncD = vsyncSink.videoDeltasMs
let vsyncHostD = vsyncSink.hostDeltasMs
let vsyncP50 = percentileSorted(vsyncD, 0.5).map { ms($0) } ?? "n/a"
var vsyncMs = vsyncOverrideMs
let vsyncSource = vsyncOverrideMs > 0 ? "cli" : "cvdisplaylink"
if vsyncMs <= 0 { vsyncMs = percentileSorted(vsyncD, 0.5) ?? 0 }

let p50 = percentileSorted(r.gaps, 0.5)
let p95 = percentileSorted(r.gaps, 0.95)
let p95pts = percentileSorted(r.ptsGaps, 0.95)
let p99 = percentileSorted(r.gaps, 0.99)
let pmax = r.gaps.last

key("capture_permission", preflight ? "true" : "false")
key("presented_n", String(r.presented))
key("presented_p50_ms", p50.map(ms) ?? "n/a")
key("presented_p95_ms", p95.map(ms) ?? "n/a")
key("presented_p99_ms", p99.map(ms) ?? "n/a")
key("presented_max_ms", pmax.map(ms) ?? "n/a")
// 一个间隔都没有 ⇒ hitch 无从判定，只能 `n/a`。
// 把「静止窗口 0 帧」写成 hitch_n=0 会被下游读成「零掉帧 = 达标」，那是本项目明令禁止的错误方向。
if vsyncMs > 0 && !r.gaps.isEmpty {
    key("hitch_n", String(r.gaps.filter { $0 > vsyncMs * 1.5 }.count))
    key("hitch_gt2_n", String(r.gaps.filter { $0 > vsyncMs * 2.5 }.count))
} else {
    key("hitch_n", "n/a")
    key("hitch_gt2_n", "n/a")
}
// —— 以下为附加列（契约只钉「必打」的 key，这些是给复核用的透明度列）——
key("callback_bound", sink.callbackBound ? "true" : "false")
key("delegate_bound", sink.delegateBound ? "true" : "false")
key("content_basis", sink.contentBasis)
key("buffers_n", String(r.buffers))
key("dup_n", String(r.dup))
key("dirty_change_frames_n", String(sink.dirtyFrames))
key("dirty_unknown_frames_n", String(sink.dirtyUnknown))
key("no_pixel_buffer_frames_n", String(sink.sigUnknown))
key("content_unknown_n", String(sink.contentUnknown))
key("pts_advanced_frames_n", String(sink.ptsAdvanced))
key("hitch_n_drop1", vsyncMs > 0 && r.gaps.count >= 2 ? String(r.gaps.dropFirst().filter { $0 > vsyncMs * 1.5 }.count) : "n/a")
key("hitch_gt2_n_drop1", vsyncMs > 0 && r.gaps.count >= 2 ? String(r.gaps.dropFirst().filter { $0 > vsyncMs * 2.5 }.count) : "n/a")
key("vsync_ms", vsyncP50)
key("vsync_source", vsyncSource)
key("vsync_n", String(vsyncSink.count))
key("vsync_host_p50_ms", percentileSorted(vsyncHostD, 0.5).map(ms) ?? "n/a")
key("p95_on_pts_axis_ms", p95pts.map(ms) ?? "n/a")
key("startup_latency_ms", r.startup.map { ms(($0 - captureStart) * 1000) } ?? "n/a")
key("capture_source", displayMode ? "display" : "window")
key("window", "\(Int(window.frame.width))x\(Int(window.frame.height))")
key("window_title", window.title ?? "-")
key("capture_window_s", ms(seconds))
key("capture_span_ms", ms((captureEnd - captureStart) * 1000))
key("stream_error", sink.stopError.map { "\($0 as NSError)" } ?? "none")

if !csvPath.isEmpty {
    var out = "index,host_arrival_s,pts_s,is_new_content,gap_host_ms,gap_pts_ms\n"
    let ch = sink.allChangeHost
    let cp = sink.allChangePts
    for idx in 0..<max(ch.count, cp.count) {
        let gapH = idx > 0 ? (ch[idx] - ch[idx - 1]) * 1000 : 0
        let gapP = idx > 0 ? (cp[idx] - cp[idx - 1]) * 1000 : 0
        out += "\(idx),\(String(format: "%.6f", ch[idx])),\(String(format: "%.6f", cp[idx])),1,\(String(format: "%.3f", gapH)),\(String(format: "%.3f", gapP))\n"
    }
    for idx in 0..<sink.allHostArrivals.count where idx >= ch.count {
        out += "\(idx),\(String(format: "%.6f", sink.allHostArrivals[idx])),dup,0,,\n"
    }
    do {
        try out.write(toFile: csvPath, atomically: true, encoding: .utf8)
        key("csv", csvPath)
    } catch {
        err("  写 CSV 失败: \(error)")
    }
}

err("== 读数解释 ==")
err("  呈现帧 \(r.presented)（收到样本 \(r.buffers)，其中 PTS 未推进的重复帧 \(r.dup)）")
if r.presented < 2 {
    err("  样本 <2 ⇒ 分布/ hitch 只能是 n/a。presented_n=0 在静止窗口上是**预期**，不是卡住。")
} else {
    err("  vsync 分母 = \(vsyncP50) ms（\(vsyncSource)，CVDisplayLink 回调 \(vsyncSink.count) 次）")
}
exit(r.presented > 0 ? 0 : 4)
