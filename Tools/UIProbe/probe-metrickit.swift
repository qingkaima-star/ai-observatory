//
//  probe-metrickit.swift — 可用性探针：MetricKit 在 macOS 26 上到底能不能当我们那把「卡顿/hang」尺子
//
//  Owner: WS-Frames（子车道 A1「进程内采集能力」）。探针，不进产品 target，编译产物落 tmp/uiprobe/。
//
//  为什么存在：frame-baseline 的 `hang_events_n` / F4 需要一个「进程内的 hang 计数」来源。
//  MXHangDiagnostic 看着正好，但没人验证过它在 macOS 上是否真的投递。三问分别对应三组 key：
//    (a) 编译期是否存在   → metrickit_canimport / class_present / symbols_resolved
//    (b) 运行期能否订阅   → manager_ok / subscribe_ok / add_removed_ok
//    (c) 有没有真实投递   → metrics_delivered / diagnostics_delivered / hang_diagnostics_delivered
//                          + past_metric_payloads / past_diagnostic_payloads（系统已存的历史）
//  任何一项量不到都打 n/a，不许用 0 冒充「没有」：`diagnostics_delivered=0` 只在真的跑完窗口时才打。
//
//  用法:
//    xcrun swiftc -O Tools/UIProbe/probe-metrickit.swift -o tmp/uiprobe/probe-metrickit
//    tmp/uiprobe/probe-metrickit --seconds 180
//    tmp/uiprobe/probe-metrickit --seconds 180 --induce-hang 6     # 订阅后把主线程堵 6 s，看能否钓到 hang
//  退出码: 0 跑完整个窗口（**有没有投递都算跑完**，结论看 key）; 2 参数错; 3 框架/类在运行期不存在
//

import Darwin
import Foundation

#if canImport(MetricKit)
import MetricKit
#endif

var seconds = 60.0
var induceHang = 0.0
var verbose = false

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
    case "--induce-hang":
        argi += 1
        guard argi < argv.count, let v = Double(argv[argi]), v >= 0 else {
            FileHandle.standardError.write("--induce-hang 需要一个秒数\n".data(using: .utf8)!)
            exit(2)
        }
        induceHang = v
    case "--verbose": verbose = true
    default:
        FileHandle.standardError.write("未知参数 \(argv[argi])\n".data(using: .utf8)!)
        exit(2)
    }
    argi += 1
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - 被观测对象自身的情况（MetricKit 的投递历来和「是不是一个正经 bundle」强相关）

let info = ProcessInfo.processInfo
log("本机 \(info.operatingSystemVersionString)，pid \(info.processIdentifier)，"
    + "进程名 \(info.processName)，bundle=\(Bundle.main.bundlePath)")
log("窗口 \(seconds)s，诱导 hang \(induceHang)s")

print("bundle_id=\(Bundle.main.bundleIdentifier ?? "none")")
print("exec_path=\(CommandLine.arguments.first ?? "unknown")")
print("inside_app_bundle=\(Bundle.main.bundlePath.hasSuffix(".app") ? "yes" : "no")")
print("macos_version=\(info.operatingSystemVersion.majorVersion).\(info.operatingSystemVersion.minorVersion).\(info.operatingSystemVersion.patchVersion)")

#if canImport(MetricKit)
print("metrickit_canimport=true")
#else
print("metrickit_canimport=false")
print("class_present=n/a")
print("manager_ok=n/a")
print("subscribe_ok=n/a")
print("delivery_observed=n/a")
log("SDK 里 canImport(MetricKit) 就为假 ⇒ 后面两问都不用测了（本机不成立）")
exit(3)
#endif

// MARK: - (a) 运行期符号是否真的在（dyld 能不能把这个 framework 拉起来）

let classPresent = NSClassFromString("MXMetricManager") != nil
let hangClassPresent = NSClassFromString("MXHangDiagnostic") != nil
print("class_present=\(classPresent ? "yes" : "no")")
print("hang_diagnostic_class_present=\(hangClassPresent ? "yes" : "no")")
if !classPresent || !hangClassPresent {
    print("manager_ok=n/a")
    print("subscribe_ok=n/a")
    print("delivery_observed=n/a")
    log("编译期有、运行期类却拿不到 ⇒ 框架没被装上，直接判不可用")
    exit(3)
}

// 下面整段都依赖 MetricKit 符号，canImport 为假时必须在**编译期**就切掉（不是运行期 if）。
#if canImport(MetricKit)

// MARK: - (b) 订阅

    final class Collector: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
        private let lock = NSLock()
        private var metrics = 0
        private var diagnostics = 0
        private var hangs = 0
        private var crashes = 0
        private var cpuExceptions = 0
        private var diskWrites = 0
        private var metricJSONBytes = 0
        private var lastDiag: MXDiagnosticPayload?

        func didReceive(_ payloads: [MXMetricPayload]) {
            lock.lock(); metrics += payloads.count; lock.unlock()
            for p in payloads {
                let data = p.jsonRepresentation()
                lock.lock(); metricJSONBytes += data.count; lock.unlock()
                log("  ↳ 收到 MXMetricPayload \(data.count) 字节")
            }
        }

        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            lock.lock(); diagnostics += payloads.count; lock.unlock()
            for p in payloads {
                let h = p.hangDiagnostics?.count ?? 0
                let c = p.crashDiagnostics?.count ?? 0
                let cpu = p.cpuExceptionDiagnostics?.count ?? 0
                let dw = p.diskWriteExceptionDiagnostics?.count ?? 0
                lock.lock()
                hangs += h; crashes += c; cpuExceptions += cpu; diskWrites += dw
                lastDiag = p
                lock.unlock()
                log("  ↳ 收到 MXDiagnosticPayload hang=\(h) crash=\(c) cpuException=\(cpu) diskWrite=\(dw) "
                    + "覆盖 \(p.timeStampBegin) → \(p.timeStampEnd)")
            }
        }

        var snapshot: (metrics: Int, diagnostics: Int, hangs: Int, crashes: Int, cpu: Int, disk: Int, json: Int) {
            lock.lock(); defer { lock.unlock() }
            return (metrics, diagnostics, hangs, crashes, cpuExceptions, diskWrites, metricJSONBytes)
        }
        var diagDescription: String { lock.lock(); defer { lock.unlock() }; return lastDiag.map { String(describing: $0) } ?? "-" }
    }

    // MXMetricManager 的类级可用性是 macos(12.0)（头文件实测），MXHangDiagnostic 同；整块用守卫包住，
    // 低版本上打 n/a 而不是让编译器在调用点报错。
    if #available(macOS 12.0, *) {
        let manager = MXMetricManager.shared
        print("manager_ok=yes")

        let collector = Collector()
        manager.add(collector)
        print("subscribe_ok=yes")

        // 历史队列：这是「系统本机到底有没有为这个进程攒过 MetricKit 数据」的直接证据。
        let pastMetrics = manager.pastPayloads.count
        let pastDiags = manager.pastDiagnosticPayloads.count
        print("past_metric_payloads=\(pastMetrics)")
        print("past_diagnostic_payloads=\(pastDiags)")

        // MARK: - (c) 投递：把窗口跑完，主 runloop 与 GCD 都要转着
        let deadline = Date().addingTimeInterval(seconds)
        if induceHang > 0 {
            // 先让出一点点时间让订阅落地，再堵主线程：MXHangDiagnostic 的口径就是「主线程堵到不响应输入」。
            RunLoop.main.run(until: Date().addingTimeInterval(1.0))
            log("== 现在把主线程堵 \(induceHang)s（模拟 F4 关心的那种卡顿）==")
            let blockUntil = Date().addingTimeInterval(induceHang)
            while Date() < blockUntil { usleep(100_000) }
            log("== 主线程恢复，继续把窗口跑完 ==")
        }
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
            usleep(20_000)
        }
        // 投递回调在后台队列上跑，收尾前先排干一次。
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))

        let snap = collector.snapshot
        print("wait_s=\(String(format: "%.1f", seconds))")
        print("metrics_delivered=\(snap.metrics)")
        print("diagnostics_delivered=\(snap.diagnostics)")
        print("hang_diagnostics_delivered=\(snap.hangs)")
        print("crash_diagnostics_delivered=\(snap.crashes)")
        print("cpu_exception_diagnostics_delivered=\(snap.cpu)")
        print("disk_write_diagnostics_delivered=\(snap.disk)")
        print("metric_json_bytes=\(snap.json)")
        let observed = (snap.metrics + snap.diagnostics) > 0 || pastMetrics + pastDiags > 0
        print("delivery_observed=\(observed ? "yes" : "no")")
        manager.remove(collector)
        print("add_removed_ok=yes")
        if verbose && !collector.diagDescription.isEmpty { log("最后一个 diagnostic payload: \(collector.diagDescription)") }
        if !observed {
            log("跑完 \(seconds)s 一个 payload 都没来。注意：MetricKit 的文档口径是「至少每天一次、条件允许时」，"
                + "所以「短窗内没来」**不能**推出「macOS 不支持」，只能推出「本窗不可判」。")
        }
    } else {
        log("MXMetricManager 需要 macOS 12.0+（头文件 API_AVAILABLE 实测），本机 #available 判定失败 ⇒ 三问的后两问不可判")
        print("manager_ok=n/a")
        print("subscribe_ok=n/a")
        print("delivery_observed=n/a")
    }
    #endif
    exit(0)
