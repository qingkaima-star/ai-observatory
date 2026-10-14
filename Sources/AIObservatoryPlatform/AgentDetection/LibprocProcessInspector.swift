//
//  LibprocProcessInspector.swift
//  AIObservatoryPlatform — AgentDetection 子模块
//
//  Owner: WS-Agent / WS-Platform（WS-Platform 在本文件接线 CPU 求差时钟 + 两处 syscall 瘦身）
//  ─────────────────────────────────────────────────────────
//  基于 libproc (`proc_listpids` / `proc_pidinfo` / `proc_pidpath` /
//  `proc_name`) 与 `sysctl(KERN_PROCARGS2)` 的真实进程快照实现。
//
//  设计要点：
//   · 全程走 libproc / sysctl，绝不 fork `ps`（满足低资源占用要求）。
//   · CPU 占用率需要两次采样求差，而**差值窗口由 `TickCPUClock` 钉住**：
//     `scanProcesses()` 开头开一个 tick，同一个 tick 内 `scanProcesses()` 与
//     `metrics(for:)` 两个入口问同一个 pid 得到同一个数（口径详见该类型）。
//     首轮没有基准 ⇒ 本轮**无基线**：`metrics(for:)` 让这个 pid 缺席（宁缺不造），
//     全表那一行只能塌成 0——`ProcessRecord.cpuPercent` 是冻结区的非可选 Double，
//     要如实表达得走 IFR（见 `04-决策记录/ICR-0002-ProcessRecord-cpuPercent需要能表达本轮无基线.md`）。
//   · 终端名由 `DeviceNameMemo` 按**设备号**记忆化：设备号→名字是整机属性，
//     一轮最多付一次真解析（改前每条带 tty 的记录各调一次 `devname`，叶帧落在 `lstat`）。
//   · argv 由一块跨轮复用的缓冲读：稳态下每条记录只付**一次** `__sysctl`、零分配
//     （改前是「先问大小、再读一遍」两次 `__sysctl` 加一次精确尺寸的 malloc）。
//   · 启动时间取自 `PROC_PIDTBSDINFO.pbi_start_tvsec`。
//   · 不读取环境变量（需要特权）；cwd 取自 `PROC_PIDVNODEPATHINFO`。
//   · 所有 C 指针在单个函数内分配/使用/释放，绝不跨 actor 传递。
//     唯一跨轮存活的缓冲是 `procArgsBuffer`（`[UInt8]` 值类型，不含指针），
//     由 `OSAllocatedUnfairLock` 独占持有，指针只在该持锁区间内有效。
//   · 类型全部 `Sendable`，内部可变状态用 `OSAllocatedUnfairLock` 保护。
//

import Foundation
import Darwin
import os.lock
import AIObservatoryCore

// MARK: - C 字符串安全转换（避免弃用的 init(cString:) 与越界读取）

/// 将 null 结尾的 C 字符串（最多 `maxLen` 字节）转为 Swift String。
private func cstr(_ ptr: UnsafePointer<CChar>, maxLen: Int) -> String {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(min(maxLen, 256))
    var len = 0
    while len < maxLen, ptr[len] != 0 {
        bytes.append(UInt8(bitPattern: ptr[len]))
        len += 1
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// 将 `[CChar]` 缓冲（null 结尾）转为 Swift String。
private func cstr(_ array: [CChar]) -> String {
    var bytes: [UInt8] = []
    for c in array {
        if c == 0 { break }
        bytes.append(UInt8(bitPattern: c))
    }
    return String(decoding: bytes, as: UTF8.self)
}

/// 通过 libproc / sysctl 抓取本机真实进程快照的采集器。
///
/// 符合 `ProcessInspecting` 协议，可直接被 Engine 调用。
/// 线程安全：内部可变状态（CPU 时钟、argv 复用缓冲）分别由 `TickCPUClock`
/// 与 `OSAllocatedUnfairLock` 各自守住，本类型本身不带裸指针。
public final class LibprocProcessInspector: ProcessInspecting, ProcessMetricsReading, Sendable {

    /// 本采集器的 CPU 求差时钟：**一个 tick 只有一份基准**。
    ///
    /// `scanProcesses()` 每轮开头调一次 `beginTick()`；`scanProcesses()` 与 `metrics(for:)`
    /// 两个入口都只经 `observe(pid:cumulativeNanos:wallNanos:)` 喂读数。于是第二个入口
    /// 不可能再把第一个入口几十毫秒前写下的读数当成基准——改前那份 `cpuHistory` 正是这么
    /// 把求差窗口塌缩成「两次入口之间那几十毫秒」的（口径的来龙去脉见 `TickCPUClock`）。
    /// 内部可见即可测：`@testable` 用例可直接断言「同 tick 内两个入口给出同一个数」。
    let cpuClock = TickCPUClock()

    /// 设备号 → 终端名的记忆化解析（`devname` 的叶帧实测落在 `lstat`，见该类型头注）。
    ///
    /// 与 `cpuClock` 同一条理由留成内部可见：只测 `DeviceNameMemo` 本身会留下
    /// 「测试绿、生产没接到」的假绿灯（本仓在 `ProcessMetricsReading` 上栽过一次），
    /// 断言「真实采集器确实在用它」需要能读到它的计数器。
    let deviceNames = DeviceNameMemo()

    /// 跨轮复用的 `KERN_PROCARGS2` 读缓冲；空数组 = 尚未分配。
    ///
    /// 存的是**值类型 `[UInt8]`**（不是指针），指针只在 `withLock` +
    /// `withUnsafeMutableBytes` 的区间内有效，因此本类仍是 `Sendable`。
    private let procArgsBuffer = OSAllocatedUnfairLock<[UInt8]>(initialState: [])

    public init() {}

    // MARK: - ProcessInspecting

    /// 抓取当前时刻全量进程快照。
    ///
    /// 实现保证 O(进程数) 且低开销（全部为本地 syscall，无子进程）。
    /// 对无权限读取的进程（系统/其他用户进程）尽力返回最小记录，
    /// 拿不到的字段留空（`nil` / 空串 / 0），绝不编造。
    public func scanProcesses() async -> [ProcessRecord] {
        // 一轮一份基准：本轮之后 `metrics(for:)` 再问同一个 pid，拿到的是这里算出的同一个数。
        cpuClock.beginTick()
        // 整轮共用一个墙钟时刻：同一 tick 内所有 pid 的求差窗口长度一致
        // （误差只来自扫描本身那几十毫秒，摊在 3 s 周期上是 1% 量级）。
        let wallNow = DispatchTime.now().uptimeNanoseconds
        let pids = listAllPIDs()
        var records: [ProcessRecord] = []
        records.reserveCapacity(pids.count)

        for pid in pids {
            records.append(inspect(pid: pid, wallNow: wallNow))
        }
        return records
    }

    // MARK: - 按 pid 精确取资源数值（`ProcessMetricsReading`）

    /// 只为给定 pid 各付一次 `PROC_PIDTASKINFO`，不碰 argv / cwd / 可执行路径。
    ///
    /// 拿不到任务信息的 pid **不出现在结果里**：补一个 0 会被下游读成「这个 Agent 这一轮
    /// 真的没占 CPU」，而事实是我们没读到。代价是消费方（`ingestPerformance` 的
    /// `guard let process = samples[agent.pid]`）对这种 Agent 会**少落一行** `perf_samples`——
    /// 改前那条路径给的是 0/0 一行。跨用户/受保护进程是否真会落到这一分支：见回报里的实测。
    /// 全表扫描那边仍然是「每 pid 一行、拿不到留 0」，两条路径对读不到的表达不一致是有意的：
    /// 快照那一行还要承载 name/ppid 等已读到的字段，删不得。
    ///
    /// CPU% 走 `cpuClock`：本轮若已被 `scanProcesses()` 观测过，这里返回的就是**同一个数**
    /// （求差窗口 = 一个 tick），不再另立基准。两个入口的口径由时钟统一持有，
    /// 不在此处各写一套差值算术。
    ///
    /// **本轮无基线的 pid 同样缺席**（新出生的进程、或上一 tick 读不到的进程）。
    /// 这条与「读不到 taskinfo 就缺席」是同一条纪律的两个分支：0% 会被下游
    /// （`ingestPerformance` → `PerformanceSample` → 「资源滥用」规则）读成
    /// 「这个 Agent 这一轮真的没占 CPU」，而事实是我们还没有可比的读数。
    /// 缺席的代价是那个 Agent 少落一行 `perf_samples`，下一 tick 就有了。
    ///
    /// 空 `pids` 自然得到空字典，不必特判。
    public func metrics(for pids: [Int32]) -> [Int32: ProcessSample] {
        let wallNow = DispatchTime.now().uptimeNanoseconds
        var result: [Int32: ProcessSample] = [:]
        result.reserveCapacity(pids.count)
        for pid in pids {
            // 「读不到 ⇒ 缺席」：不给时钟喂一条我们没读到的读数，否则下一轮会拿这次
            // 伪造的 0 纳秒当基准，把一个刚活过来的进程算成满载。
            guard let info = readTaskInfo(pid: pid) else { continue }
            guard let cpuPercent = cpuClock.observe(
                pid: pid, cumulativeNanos: info.cumulativeNanos, wallNanos: wallNow
            ) else { continue }   // 本轮无基线 ⇒ 宁缺不造
            result[pid] = ProcessSample(
                pid: pid, cpuPercent: cpuPercent, memoryBytes: info.memoryBytes
            )
        }
        return result
    }

    // MARK: - 内部：枚举全部 PID

    /// 调用 `proc_listpids(PROC_ALL_PIDS, …)` 返回本机全部 pid。
    private func listAllPIDs() -> [Int32] {
        var capacity = 1024
        while true {
            let buf = UnsafeMutableBufferPointer<pid_t>.allocate(capacity: capacity)
            defer { buf.deallocate() }
            let byteSize = Int32(capacity * MemoryLayout<pid_t>.stride)
            let ret = proc_listpids(UInt32(PROC_ALL_PIDS), 0, buf.baseAddress, byteSize)
            if ret < 0 { return [] }
            let written = Int(ret)
            // 缓冲区被填满，翻倍后重试，避免漏进程。
            if written == Int(byteSize) {
                capacity *= 2
                continue
            }
            let count = written / MemoryLayout<pid_t>.stride
            guard count > 0 else { return [] }
            return Array(buf[0..<count])
        }
    }

    // MARK: - 内部：单进程快照

    /// 为单个 pid 构建一条 `ProcessRecord`。
    private func inspect(pid: Int32, wallNow: UInt64) -> ProcessRecord {
        // 可执行路径（尽力而为）。
        let executablePath = readExecutablePath(pid: pid)

        // BSD 信息：ppid / uid / 启动时间 / tty dev。
        var parentPID: Int32?
        var userID: UInt32 = 0
        var startTime: Date?
        var tty: String?

        let bsd = UnsafeMutablePointer<proc_bsdinfo>.allocate(capacity: 1)
        bsd.initialize(to: proc_bsdinfo())
        defer { bsd.deallocate() }
        let bret = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, bsd, Int32(MemoryLayout<proc_bsdinfo>.size))
        if bret > 0 {
            let raw = bsd.pointee
            let ppid = Int32(raw.pbi_ppid)
            parentPID = (ppid != pid) ? ppid : nil
            userID = raw.pbi_uid
            if raw.pbi_start_tvsec > 0 {
                let secs = Double(raw.pbi_start_tvsec)
                let usecs = Double(raw.pbi_start_tvusec) / 1_000_000.0
                startTime = Date(timeIntervalSince1970: secs + usecs)
            }
            if raw.e_tdev != 0 && raw.e_tdev <= UInt32(Int32.max) {
                // 记忆化按**设备号**：一台机器开机后活跃的就是那几个 tty，几百条记录
                // 反复解析的其实是同一个数。`Int32(bitPattern:)` 与改前的 `Int32(raw.e_tdev)`
                // 在 `e_tdev <= Int32.max` 这个守卫下取值相同，故解析结果一字不差。
                tty = deviceNames.name(forDeviceNumber: raw.e_tdev)
            }
        }

        // 进程名：优先 pbi_comm，失败再退到 proc_name。
        let name: String
        if bret > 0 {
            name = withUnsafePointer(to: &bsd.pointee.pbi_comm) { ptr in
                ptr.withMemoryRebound(to: CChar.self, capacity: 16) { cstr($0, maxLen: 16) }
            }
        } else if let n = readProcessName(pid: pid), !n.isEmpty {
            name = n
        } else {
            name = ""
        }

        // 任务信息：RSS 与累计 CPU 时间（nanoseconds）。取不到时 RSS 记 0——这里是在为
        // **每个** pid 产出一行快照，少一行就等于把那个进程从列表里抹掉。
        // 但**累计 CPU 时间不拿 0 顶替**：它是 `TickCPUClock` 的输入，喂一个伪造的 0 纳秒
        // 等于给下一轮种下一条假基线（见下面 cpuPercent 那段）。
        let task = readTaskInfo(pid: pid)
        let memoryBytes = task?.memoryBytes ?? 0

        // 工作目录（cwd）。
        let workingDirectory = readWorkingDirectory(pid: pid)

        // 命令行参数（argv），用于 argumentSignature 识别。
        let arguments = readArguments(pid: pid)

        // CPU 占用率：本轮读数喂给时钟，拿回的是「最近一个完整 tick」的占用率。
        //
        // ⚠️ 这里塌成 0 是**契约限制，不是选择**：`ProcessRecord.cpuPercent` 是冻结区里
        // 非可选的 `Double`，「本轮无基线」（新出生的进程、上一轮 taskinfo 读不到）在这条
        // 路径上表达不出来，只能落 0。要如实表达需要 IFR（见
        // `04-决策记录/ICR-0002-ProcessRecord-cpuPercent需要能表达本轮无基线.md`）。
        // 按 pid 那条路径（`metrics(for:)`，也就是真正喂给 `perf_samples` 与「资源滥用」
        // 规则的那条）已经能缺席——所以规则输入不再有这一类假 0。
        // 改前更糟：取不到 taskinfo 时连 `cumulativeNanos = 0` 都喂进历史，下一轮会把该进程
        // 从出生到现在的**整段**累计 CPU 算成一个 tick 的用量、撞上 100×核心数 封顶。
        let cpuPercent: Double
        if let task {
            cpuPercent = cpuClock.observe(
                pid: pid, cumulativeNanos: task.cumulativeNanos, wallNanos: wallNow
            ) ?? 0
        } else {
            cpuPercent = 0
        }

        return ProcessRecord(
            pid: pid,
            parentPID: parentPID,
            name: name,
            executablePath: executablePath,
            arguments: arguments,
            startTime: startTime,
            cpuPercent: cpuPercent,
            memoryBytes: memoryBytes,
            userID: userID,
            tty: tty,
            workingDirectory: workingDirectory
        )
    }

    // MARK: - 内部：零散信息读取

    /// 读取 RSS 与累计 CPU 时间（nanoseconds）；`PROC_PIDTASKINFO` 失败返回 nil。
    private func readTaskInfo(pid: Int32) -> (memoryBytes: UInt64, cumulativeNanos: UInt64)? {
        let task = UnsafeMutablePointer<proc_taskinfo>.allocate(capacity: 1)
        task.initialize(to: proc_taskinfo())
        defer { task.deallocate() }
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, task, Int32(MemoryLayout<proc_taskinfo>.size)) > 0 else {
            return nil
        }
        return (
            memoryBytes: task.pointee.pti_resident_size,
            cumulativeNanos: task.pointee.pti_total_user + task.pointee.pti_total_system
        )
    }

    /// 通过 `proc_pidpath` 读取可执行文件路径。失败返回空串。
    private func readExecutablePath(pid: Int32) -> String {
        var buf = [CChar](repeating: 0, count: 4096)
        let ret = buf.withUnsafeMutableBufferPointer { ptr in
            proc_pidpath(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        guard ret > 0 else { return "" }
        return cstr(buf)
    }

    /// 通过 `proc_name` 读取进程名（comm）。失败返回 nil。
    private func readProcessName(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 256)
        let ret = buf.withUnsafeMutableBufferPointer { ptr in
            proc_name(pid, ptr.baseAddress, UInt32(ptr.count))
        }
        guard ret > 0 else { return nil }
        return cstr(buf)
    }

    /// 通过 `PROC_PIDVNODEPATHINFO` 读取工作目录（cwd）。失败返回 nil。
    private func readWorkingDirectory(pid: Int32) -> String? {
        let v = UnsafeMutablePointer<proc_vnodepathinfo>.allocate(capacity: 1)
        v.initialize(to: proc_vnodepathinfo())
        defer { v.deallocate() }
        let ret = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, v, Int32(MemoryLayout<proc_vnodepathinfo>.size))
        guard ret > 0 else { return nil }
        let cwd = withUnsafePointer(to: &v.pointee.pvi_cdir.vip_path) { ptr in
            ptr.withMemoryRebound(to: CChar.self, capacity: 1024) { cstr($0, maxLen: 1024) }
        }
        return cwd.isEmpty ? nil : cwd
    }

    // MARK: - 内部：argv（一次 sysctl + 跨轮复用缓冲）

    /// `KERN_PROCARGS2` 首读用的字节数。真机多数进程的 argv 头部在 1 KiB 量级，
    /// 4 KiB 让**稳态一次命中**：每条记录一次 `__sysctl`、零分配。
    private static let initialProcArgsCapacity = 4096

    /// 常驻复用缓冲允许长到的上限；比这更大的读取只当次分配、读完即弃。
    ///
    /// 不该让个别把环境块撑到几百 KiB 的进程把高水位永久留在本进程里
    /// （AGENTS §6：内存常驻 < 120 MB）。
    private static let maxReusedProcArgsCapacity = 256 * 1024

    /// 单次读取允许问到的上限：macOS 的 `ARG_MAX` 是 1 MiB，超过它内核本身给不出来。
    private static let maxProcArgsCapacity = 1024 * 1024

    /// 缓冲不够用时扩容重试的次数上限（每次至少翻倍）。
    ///
    /// 4 次是给最坏路径留的余量：`ENOMEM` 报出所需大小 → 长到那个大小 → 读成的长度
    /// 恰好等于容量（触发下面那条"写满即重试"的保守规则）→ 再翻倍 → 读成。
    private static let maxProcArgsGrowAttempts = 4

    /// 在给定缓冲上问一次 `KERN_PROCARGS2` 的结果。
    private enum ProcArgsRead {
        /// 读完了（argv 为空也可能是「合法地读不到」，与改前一致）。
        case arguments([String])
        /// 没读全，`needed` 是内核报出（或可推出）的所需字节数，调用方据此扩容。
        case truncated(needed: Int)
    }

    /// 通过 `sysctl(KERN_PROCARGS2, pid)` 读取干净分离后的 argv。
    /// 拿不到（无权限 / 进程已退出）时返回空数组，绝不编造。
    ///
    /// 改前每条记录要付**两次** `__sysctl`：先以 `oldptr = nil` 问所需大小，再按那个大小
    /// 读一遍。第一次调用唯一的产出是个尺寸，而按它分配仍然要 malloc——于是白付一次
    /// 内核往返（1ms 采样里 `__sysctl` 占 121/1034 条，是全表扫描那段最贵的叶帧）。
    /// 现在沿用上一轮证明够用的那块缓冲，一次读成；只有真被截断才扩容重试。
    private func readArguments(pid: Int32) -> [String] {
        procArgsBuffer.withLock { buffer -> [String] in
            if buffer.isEmpty {
                buffer = [UInt8](repeating: 0, count: Self.initialProcArgsCapacity)
            }
            for _ in 0..<Self.maxProcArgsGrowAttempts {
                switch readArgsOnce(pid: pid, into: &buffer) {
                case .arguments(let args):
                    // 超出常驻上限的那块不留到下一轮（这一条已经读完了，丢弃不影响结果）。
                    if buffer.count > Self.maxReusedProcArgsCapacity { buffer = [] }
                    return args
                case .truncated(let needed):
                    let grown = min(max(needed, buffer.count * 2), Self.maxProcArgsCapacity)
                    guard grown > buffer.count else {
                        // 长到上限仍读不全 ⇒ 交回空数组，而不是半截 argv：
                        // 末位参数被切掉的 argv 会让「只看命令文本」的风险规则**静默漏判**，
                        // 那比读不到更糟（见 `ProcessArgumentsTests` 钉的那个 bug）。
                        buffer = []
                        return []
                    }
                    buffer = [UInt8](repeating: 0, count: grown)
                }
            }
            buffer = []
            return []
        }
    }

    /// 在给定缓冲上问一次；返回 `.truncated` 时调用方扩容后再来。
    ///
    /// 指针只在这个闭包里有效：`base` 指向 `buffer` 自己的存储，出了 `withLock`
    /// 就不存在任何逃逸出来的裸指针，故本类仍是 `Sendable`。
    private func readArgsOnce(pid: Int32, into buffer: inout [UInt8]) -> ProcArgsRead {
        buffer.withUnsafeMutableBytes { raw -> ProcArgsRead in
            guard let base = raw.baseAddress, raw.count > 0 else { return .arguments([]) }
            var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = raw.count
            guard sysctl(&mib, 3, base, &size, nil, 0) == 0 else {
                // 其余失败（无权限 / 进程已退出）与改前一样按「读不到」返回空。
                guard errno == ENOMEM else { return .arguments([]) }
                // `ENOMEM` 是唯一值得重试的失败：缓冲太小。xnu 通常会把**所需**字节数写回
                // `size`；万一没写（`size` 仍是容量本身），就退回复现改前的口径——以
                // `oldptr = nil` 专门问一次大小（那次调用在本机一直是准的，改前就靠它分配）。
                var needed = size
                if needed <= raw.count {
                    needed = 0
                    _ = sysctl(&mib, 3, nil, &needed, nil, 0)
                }
                return .truncated(needed: max(needed, raw.count + 1))
            }
            // 成功但**恰好**把缓冲写满：这时无法排除「再多一点还有内容」，而末位参数被切掉
            // 正是 `ProcessArgumentsTests` 钉的那个 bug 的形状 ⇒ 扩容再问一次。
            if size == raw.count { return .truncated(needed: size + 1) }
            guard size > MemoryLayout<Int32>.size else { return .arguments([]) }
            return .arguments(parseProcArgs2(base: base, size: size))
        }
    }

    /// 从一次读成的 `KERN_PROCARGS2` 缓冲里切出 argv。
    ///
    /// ⚠️ 下面这段偏移逻辑与改前**一字不差**（只是从 `readArguments` 里搬了出来）：
    /// 布局注释、exec_path 跳过、填充 NUL、`argc < 100_000` 守卫都是真机 bug 的修复，
    /// 动它之前先去看 `ProcessArgumentsTests` 与 `Tests/AIObservatoryPlatformTests/AgentDetection`。
    private func parseProcArgs2(base: UnsafeMutableRawPointer, size: Int) -> [String] {
        let argc = Int(base.load(as: Int32.self))
        guard argc > 0, argc < 100_000 else { return [] }

        var offset = MemoryLayout<Int32>.size

        // `KERN_PROCARGS2` 的布局是：argc → **exec_path** → 对齐用的 NUL 填充 → argv… → envp…。
        // 直接从 argc 位置起读 argc 个字符串会把 exec_path 当成 argv[0]，于是整体后移一位、
        // 末位参数被丢掉。真机实测：`/bin/sh -c "chmod -R 777 ./junk; sleep 4"` 读出
        // `["/bin/sh","sh","-c"]` —— 命令文本整段消失，而「递归放权」这类规则只看命令文本，
        // 所以风险层在生产里永远不命中。这里先跳过 exec_path 与其后的填充 NUL。
        offset += stringLength(at: base, from: offset, limit: size) + 1
        while offset < size, base.load(fromByteOffset: offset, as: CChar.self) == 0 {
            offset += 1
        }

        var args: [String] = []
        for _ in 0..<argc {
            guard offset < size else { break }
            let length = stringLength(at: base, from: offset, limit: size)
            guard length > 0 else {
                offset += 1
                continue
            }
            let str = cstr(base.advanced(by: offset).assumingMemoryBound(to: CChar.self), maxLen: length)
            args.append(str)
            offset += length + 1 // +1 跳过结尾 NUL
        }
        return args
    }

    /// 从 `from` 起到下一个 NUL 或缓冲区末端的字节数（不要求以 NUL 结尾，越界安全）。
    private func stringLength(at base: UnsafeMutableRawPointer, from: Int, limit: Int) -> Int {
        var length = 0
        while from + length < limit,
              base.load(fromByteOffset: from + length, as: CChar.self) != 0 {
            length += 1
        }
        return length
    }
}
