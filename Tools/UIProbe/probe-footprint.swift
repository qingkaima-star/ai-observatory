//
//  probe-footprint.swift — 契约工具 `probe-footprint`：按 pid 读 phys_footprint（F5 的口径）
//
//  Owner: WS-Frames（子车道 A1「进程内采集能力」）。探针，不进产品 target，编译产物落 tmp/uiprobe/。
//
//  命令行（见 Tools/UIProbe/frames-tools.contract.md，本文件不许改契约）：
//    xcrun swiftc -O Tools/UIProbe/probe-footprint.swift -o tmp/uiprobe/probe-footprint
//    tmp/uiprobe/probe-footprint --pid 1234            # 进程存续期内可重复调用
//    tmp/uiprobe/probe-footprint --pid 1234 --pid 5678 # 可多次（每个 pid 一个块）
//    tmp/uiprobe/probe-footprint --verify-self         # 两条口径在同一进程上对表（自检）
//
//  stdout 只打 key=value：
//      phys_footprint_mb=   rss_mb=   footprint_ratio=
//    以及说明口径的来源列： pid=  footprint_source=  rss_source=  task_info_ok=  rusage_ok=
//    footprint_ratio 定义为 rss_mb / phys_footprint_mb（本机契约里说 RSS ≈ 2× footprint，就是这个数）。
//
//  口径：契约要求 task_vm_info.phys_footprint（task_info(TASK_VM_INFO)）。
//    读**别的**进程要先 task_for_pid(pid)，非 root / 无 entitlement 会被内核拒绝；
//    所以本工具按两条路取同一个 ledger 计数器，并在 footprint_source= 里如实写明用了哪条：
//      A. task_info(TASK_VM_INFO).phys_footprint   ← 契约口径，自己起的进程也能读（需权限）
//      B. proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint ← 同 UID 免权限，内核同一个 phys_footprint 账
//    两条都不通就报错退出，**绝不打 0**（0 是「量到且确为零」，与「量不到」是不同结论）。
//
//  退出码：0 全部 pid 都取到；2 参数错；3 至少一个 pid 不存在；4 至少一个 pid 存在但读不到 footprint
//

import Darwin
import Foundation

var pids: [Int32] = []
var verifySelf = false

let argv = CommandLine.arguments
var argi = 1
while argi < argv.count {
    switch argv[argi] {
    case "--pid":
        argi += 1
        guard argi < argv.count, let v = Int32(argv[argi]), v > 0 else {
            FileHandle.standardError.write("--pid 需要一个正整数 pid\n".data(using: .utf8)!)
            exit(2)
        }
        pids.append(v)
    case "--verify-self":
        verifySelf = true
    default:
        FileHandle.standardError.write("未知参数 \(argv[argi])\n".data(using: .utf8)!)
        exit(2)
    }
    argi += 1
}

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

if pids.isEmpty && !verifySelf {
    log("用法: probe-footprint --pid P [--pid P ...] | --verify-self")
    exit(2)
}

let mb: (UInt64) -> String = { bytes in String(format: "%.2f", Double(bytes) / 1_048_576.0) }

// MARK: - 口径 A：task_info(TASK_VM_INFO).phys_footprint

func taskInfoFootprint(for pid: Int32) -> (footprint: UInt64, resident: UInt64, note: String)? {
    let selfTask = mach_task_self_   // Swift 侧 mach_task_self() 是 function-like macro，只能用底层变量
    var childTask: task_t = mach_port_name_t(MACH_PORT_NULL)
    let lookupKr: kern_return_t
    if pid == ProcessInfo.processInfo.processIdentifier {
        lookupKr = KERN_SUCCESS
        childTask = selfTask
    } else {
        lookupKr = task_for_pid(selfTask, pid, &childTask)
        if lookupKr != KERN_SUCCESS {
            log("task_for_pid(\(pid)) 失败 kr=\(lookupKr) "
                + "(\(String(cString: mach_error_string(lookupKr)))) —— 非 root / 无 com.apple.private.task-god 权限，预期行为")
            return nil
        }
    }
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(
        MemoryLayout<task_vm_info_data_t>.stride / MemoryLayout<integer_t>.stride)
    let kr = withUnsafeMutablePointer(to: &info) { ptr -> kern_return_t in
        ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(childTask, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    if kr != KERN_SUCCESS {
        log("task_info(TASK_VM_INFO) pid=\(pid) 失败 kr=\(kr) "
            + "(\(String(cString: mach_error_string(kr))))")
        return nil
    }
    defer {
        if childTask != selfTask { mach_port_deallocate(mach_task_self_, childTask) }
    }
    return (UInt64(info.phys_footprint), UInt64(info.resident_size),
            "task_info(TASK_VM_INFO).phys_footprint count=\(count)")
}

// MARK: - RSS：proc_pidtaskinfo.pti_resident_size（与 ps 的 rss 同源，仅当对照列）

func taskInfoRSS(for pid: Int32) -> UInt64? {
    var pti = proc_taskinfo()
    let sz = Int32(MemoryLayout<proc_taskinfo>.stride)
    let rc = withUnsafeMutablePointer(to: &pti) { ptr -> Int32 in
        ptr.withMemoryRebound(to: UnsafeMutableRawPointer?.self, capacity: 1) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0, sz)
        }
    }
    if rc != sz {
        log("proc_pidinfo(PROC_PIDTASKINFO) pid=\(pid) 返回 \(rc) 期望 \(sz) errno=\(errno)")
        return nil
    }
    return pti.pti_resident_size
}

// MARK: - 主流程

/// 返回 (是否成功, phys_footprint 字节, errno)。RUSAGE_INFO_V4 是钉死的 flavor：
/// 换 flavor 就换了结构体布局，读数含义会变，所以这里不接受 CURRENT 漂移。
func readRusage(_ pid: Int32) -> (ok: Bool, footprint: UInt64, err: Int32) {
    var ru = rusage_info_v4()
    let rc = withUnsafeMutablePointer(to: &ru) { ptr -> Int32 in
        ptr.withMemoryRebound(to: Optional<UnsafeMutableRawPointer>.self, capacity: 1) {
            proc_pid_rusage(pid, Int32(RUSAGE_INFO_V4), $0)
        }
    }
    if rc != 0 { return (false, 0, Int32(errno)) }
    return (true, ru.ri_phys_footprint, 0)
}

var worstExit: Int32 = 0

func procName(_ pid: Int32) -> String {
    let buf = UnsafeMutablePointer<CChar>.allocate(capacity: 4096)
    defer { buf.deallocate() }
    let n = proc_name(pid, buf, UInt32(4095))
    return n > 0 ? String(cString: buf) : "unknown"
}

func emitOne(_ pid: Int32) {
    let ru = readRusage(pid)
    let task = taskInfoFootprint(for: pid)

    if !ru.ok && task == nil {
        // 两条路都不通：如实报错，一个 key 都不打。ESRCH（进程不存在）与权限问题要分得开。
        if ru.err == ESRCH {
            log("pid \(pid) 不存在（ESRCH）⇒ 不打任何 key。0 是「量到且为零」，这里什么都没量到。")
            worstExit = max(worstExit, 3)
        } else {
            log("pid \(pid) 存在但读不到 footprint：proc_pid_rusage errno=\(ru.err) "
                + "(\(String(cString: strerror(ru.err))))，task_for_pid 也被拒 ⇒ 不打任何 key")
            worstExit = max(worstExit, 4)
        }
        return
    }

    let footprintBytes: UInt64
    let footprintSource: String
    if let t = task {
        footprintBytes = t.footprint
        footprintSource = t.note
    } else {
        footprintBytes = ru.footprint
        footprintSource = "proc_pid_rusage(RUSAGE_INFO_V4).ri_phys_footprint"
    }

    print("pid=\(pid)")
    print("proc_name=\(procName(pid))")
    print("phys_footprint_mb=\(mb(footprintBytes))")
    print("footprint_source=\(footprintSource)")
    print("task_info_ok=\(task != nil ? "yes" : "no")")
    print("rusage_ok=\(ru.ok ? "yes" : "no")")
    if let t = task, ru.ok {
        // 两条路同时可得时（自己起的进程 / root），差值必须是可解释的，打出来供核对。
        print("footprint_two_paths_delta_kb=\(String(format: "%.1f", Double(Int64(ru.footprint) - Int64(t.footprint)) / 1024.0))")
    }
    if let r = taskInfoRSS(for: pid) {
        print("rss_mb=\(mb(r))")
        print("rss_source=proc_pidinfo(PROC_PIDTASKINFO).pti_resident_size")
        if let t = task { print("task_vm_info_resident_mb=\(mb(t.resident))") }
        print("footprint_ratio=\(footprintBytes > 0 ? String(format: "%.3f", Double(r) / Double(footprintBytes)) : "n/a")")
    } else {
        print("rss_mb=n/a")
        print("rss_source=n/a")
        print("footprint_ratio=n/a")
        worstExit = max(worstExit, 4)
        log("pid \(pid) 的 RSS 读不到 ⇒ ratio 打 n/a（footprint 本身仍然可读）")
    }
}

if verifySelf {
    let me = ProcessInfo.processInfo.processIdentifier
    log("== 自检：同一进程两条口径对表（pid \(me)，即 \(CommandLine.arguments.first ?? "?")）==")
    let a = taskInfoFootprint(for: me)
    let b = readRusage(me)
    if let a, b.ok {
        let d = Int64(b.footprint) - Int64(a.footprint)
        print("pid=\(me)")
        print("footprint_taskinfo_mb=\(mb(a.footprint))")
        print("footprint_rusage_mb=\(mb(b.footprint))")
        print("two_paths_delta_kb=\(String(format: "%.1f", Double(d) / 1024.0))")
        // 容差 512 KB：两条路是两次采样，之间自己还在分配，差值只应是个位数 KB。
        print("calibers_match=\(abs(d) <= 512 * 1024 ? "yes" : "no")")
        print("phys_footprint_mb=\(mb(a.footprint))")
        print("footprint_source=task_info(TASK_VM_INFO).phys_footprint")
    } else {
        log("自检不完整：task_info=\(a != nil) rusage_ok=\(b.ok) ⇒ 至少一条口径不可用，如实报错不打数")
        exit(4)
    }
    if pids.isEmpty { exit(0) }
}

for pid in pids {
    emitOne(pid)
}
exit(worstExit)
