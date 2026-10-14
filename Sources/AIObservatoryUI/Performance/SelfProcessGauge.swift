//
//  SelfProcessGauge.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-UI（uiclose · #29）
//  ─────────────────────────────────────────────────────────
//  职责：把「本 App 自己花了多少」这条判据（判据④）从**外部工具**搬进界面。
//  这一页此前明写「界面当前没有测量自身开销，这里只给目标值」，于是 3% / 200 MB
//  只能靠 `Tools/UIProbe/measure-pages.sh`、`footprint -p` 这类离线仪器量，用户自查不到。
//
//  【为什么这里是协议而不是直接用 SelfProcessSampler】
//  仪器已经在 `AIObservatoryPlatform/Telemetry/SelfProcessSampler.swift`（public，已入库），
//  但 `Package.swift` 里 `AIObservatoryUI` 的依赖只有 `AIObservatoryCore`，而 `Package.swift`
//  是总控冻结区。实测在 UI 源文件里写 `import AIObservatoryPlatform` **能编过**——
//  那是「模块都落在同一个 build 目录」的侥幸，不是声明出来的依赖：
//  `AIObservatoryUITests` 的依赖闭包里没有 Platform，一旦有真实引用被拉进链接就会翻。
//  所以本文件只做**值类型的窗口算术**，取数由宿主注入（装配点在 App 层，见 ICR-0003）。
//  ⚠️ 本文件里的 `cpuPercent` / `headroomPercent` 是
//  `SelfProcessSampler` 同名纯函数的**等价实现**，两处必须一起改；
//  ICR-0003 的第一方案是把这三个纯函数下沉到 `AIObservatoryCore`，让两份变一份。
//
//  【三条口径——都是踩过的坑，不是风格问题（ADR-0009）】
//  1. 内存只认 `phys_footprint`，不认 RSS：同刻实测 RSS 189.6 MB 而 footprint 88.8 MB，
//     差额是多进程共享的只读框架页（我们退出后照样在）。裁定 1 已把按 RSS 判出来的历史结论全部作废。
//  2. 必须同时显示峰值：13 个独立实例稳态 76–120 MB，而 **peak 全在 188–210 MB**（3 次 >200）。
//     判据按稳态判（裁定 5），但峰值事实不许省略——所以「余量」那一格同时给末值和峰值两个数。
//  3. 本进程 ≠ 进程树：`getrusage(RUSAGE_SELF)` 不含子进程，而被观测 Agent 的读数是
//     **Agent ∪ 其子孙进程同一时刻求和**（#23 / #30）。两套数字在同一页，必须分别标口径，
//     否则会复现「5.11 GB 像单进程」那种误读。
//

import Foundation
import AIObservatoryCore

/// 本进程的一次资源读数（值类型，与 Platform 的 `SelfProcessReading` 同构）。
public struct SelfProcessSamplePoint: Sendable, Hashable {
    /// `task_vm_info.phys_footprint`（字节）。**不是** RSS，见文件头口径 1。
    public var footprintBytes: UInt64
    /// 本进程累计 CPU 秒（`RUSAGE_SELF`，用户态 + 核心态）。累计值，必须求差才是占用率。
    public var cpuSeconds: Double
    /// 读数时刻，同时充当差值计算的分母基准。
    public var takenAt: Date

    public init(footprintBytes: UInt64, cpuSeconds: Double, takenAt: Date) {
        self.footprintBytes = footprintBytes
        self.cpuSeconds = cpuSeconds
        self.takenAt = takenAt
    }

    /// 按 1024 进位换算成 MB——与 `ByteFormat`、`PerformanceUnits` 同一把尺。
    public var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
}

/// 本进程读数的来源，由宿主注入（App 层把 `SelfProcessSampler` 适配过来）。
///
/// 刻意只暴露「读一次」，不暴露窗口：窗口归本模块管，这样
/// 「一个实例在窗口两端各采一次」这件事在界面侧可测、可断言。
public protocol SelfProcessReadingSource: Sendable {
    /// 采一次。读不到返回 `nil`——观测器不该因为读不到自己的数字就把那一格画成 0。
    func readSelfProcessSample(now: Date) -> SelfProcessSamplePoint?
}

// MARK: - Window snapshot

/// 一个测量窗口结束时的汇总。**值类型**：视图在 body 顶部读一次即可，
/// 不像 `PerformanceModel.points` 那样每读一遍就产出新数组身份
/// （那是本仓真机性能页内存单调增长的放大器，见 `PerformanceSeriesMetrics` 的文件头）。
struct SelfProcessOverhead: Hashable {
    let windowStart: Date
    let windowEnd: Date
    let sampleCount: Int
    /// 窗口累计 CPU 占用率（%）。**少于两条读数时为 `nil`**：
    /// 一次读数给不出「占了多少」，填 0 就是把「还没测」写成「没用 CPU」。
    let cpuPercent: Double?
    /// 末值 footprint（字节）——判据④ 的「常驻」按最新一次读数判（ADR-0009 裁定 5）。
    let footprintBytes: UInt64
    /// 窗口内 `max(样本)`。**注意上界**：两个采样点之间（约 6 秒）的瞬时峰值读不到，
    /// 所以这个峰值是**下界**，不是进程存活期的真峰值。
    let peakFootprintBytes: UInt64

    var durationSeconds: Double { windowEnd.timeIntervalSince(windowStart) }
    var footprintMB: Double { Double(footprintBytes) / 1_048_576 }
    var peakFootprintMB: Double { Double(peakFootprintBytes) / 1_048_576 }

    /// 实测的平均采样间隔。
    ///
    /// 界面上「每 N 秒一采」这句**必须**是量出来的，不是写死的：
    /// 本仓有过一次「引擎每 2 秒采样一次」的假文案（真实是 3 秒），
    /// 而这一格的节拍本来就同时受引擎 tick 和 `SelfProcessGauge.sampleGapSeconds` 两边约束，
    /// 只有实测值能说明**这一格**实际多久取一个数。少于两条读数时为 `nil`。
    var averageGapSeconds: Double? {
        guard sampleCount >= 2 else { return nil }
        return durationSeconds / Double(sampleCount - 1)
    }

    /// 相对上限的余量（%）。正数=还有余量，负数=已超。与 `SelfProcessSampler.headroomPercent` 同式。
    func headroomPercent(limitMB: Double) -> Double {
        guard limitMB > 0 else { return 0 }
        return (limitMB - footprintMB) / limitMB * 100
    }

    /// 按**窗口峰值**算的余量。为什么单独要一份：末值余量 56% 听起来很安全，
    /// 而同一窗口峰值可能只剩 8%——只看末值就是半个结论。
    func peakHeadroomPercent(limitMB: Double) -> Double {
        guard limitMB > 0 else { return 0 }
        return (limitMB - peakFootprintMB) / limitMB * 100
    }

    /// CPU 那一半能不能下结论：窗口不足 `floor` 秒时不给（AGENTS.md §6：窗口 ≥60 秒才有意义）。
    func cpuVerdict(budgetPercent: Double, windowFloorSeconds: Double) -> SelfProcessVerdict {
        guard let cpuPercent else { return .windowForming(seconds: durationSeconds) }
        guard durationSeconds >= windowFloorSeconds else { return .windowForming(seconds: durationSeconds) }
        return cpuPercent <= budgetPercent ? .withinBudget : .overBudget
    }

    /// 内存那一半按**末值**判（裁定 5 选的是稳态口径）；峰值只报不判，所以这里不看峰值。
    func memoryVerdict(limitMB: Double) -> SelfProcessVerdict {
        footprintMB <= limitMB ? .withinBudget : .overBudget
    }
}

/// 单侧达标结论。
enum SelfProcessVerdict: Hashable {
    /// 窗口还在成形，不下结论（附已覆盖秒数，让「还要等多久」可查）。
    case windowForming(seconds: Double)
    case withinBudget
    case overBudget

    var label: String { label(UILanguage.current) }

    func label(_ language: AppLanguage) -> String {
        switch self {
        case .windowForming(let seconds):
            return PerformanceCopy.verdictWindowForming.format(language, Int(seconds.rounded()))
        case .withinBudget: return PerformanceCopy.verdictWithinBudget.text(language)
        case .overBudget: return PerformanceCopy.verdictOverBudget.text(language)
        }
    }
}

// MARK: - Gauge

/// 滚动窗口累积器：一条有界的读数序列，加两个从 `ADR-0009` 抄下来的常量。
///
/// 刻意做成**结构体 + 纯函数**，不是 actor：它只被 `@MainActor` 的 `PerformanceModel` 持有，
/// 而判据④ 要求「不要为自身开销新增计时器」——取数节奏完全骑在引擎已有的推送上，
/// 所以这里连一个并发容器都不需要，需要的只是可手推的算术。
struct SelfProcessGauge: Hashable {
    /// 判定窗口目标长度（ADR-0009 裁定 2：窗口 ≥180 s、每 15 s 一采）。
    static let windowSeconds: Double = 180
    /// CPU 结论的最短窗口（AGENTS.md §6 度量口径：≥60 秒）。
    static let cpuVerdictFloorSeconds: Double = 60
    /// 两次采样的最小间隔。引擎扫描节拍是 3 秒，而本 App 自己就是判据④ 的对象，
    /// 所以这里主动降频：一次 `task_info` + 一次 `getrusage`，摊到每 ~6 秒 2 次系统调用，
    /// 对 90 ms/tick 的预算不构成可测量影响。
    ///
    /// 这条间隔同时给序列一个**隐式上界**：窗口 180 秒 ÷ 最小间隔 5 秒 ⇒ 最多 37 条读数，
    /// 所以不需要另设 `maxReadings`——那条在「间隔下限 + 窗口裁剪」都成立时永远到不了，
    /// 而到不了的分支就是本仓主导缺陷类型（声明了但没喂）。
    static let sampleGapSeconds: Double = 5

    private(set) var readings: [SelfProcessSamplePoint] = []

    init() {}

    /// 记一次读数。
    /// - Returns: 是否被接受。**间隔不足时丢弃**——这样「窗口里每条间隔 ≥5 秒」
    ///   成为一条可断言的不变式，而不是靠调用方自觉。
    mutating func record(_ reading: SelfProcessSamplePoint) -> Bool {
        if let last = readings.last,
           reading.takenAt.timeIntervalSince(last.takenAt) < Self.sampleGapSeconds {
            return false
        }
        readings.append(reading)
        trimToWindow()
        return true
    }

    /// 当前窗口的汇总；一条读数都没有时为 `nil`（那一格显示「未接入 / 等待采样」，不画 0）。
    var overhead: SelfProcessOverhead? {
        guard let first = readings.first, let last = readings.last else { return nil }
        let wall = last.takenAt.timeIntervalSince(first.takenAt)
        // 累计 CPU 倒退（理论上不该发生）与墙钟没前进都给 `nil`，而不是负占用率——
        // 与 `SelfProcessSampler.cpuPercent(from:to:)` 的两个 guard 同一个语义。
        var cpuPercent: Double?
        if readings.count >= 2, wall > 0, last.cpuSeconds > first.cpuSeconds {
            cpuPercent = (last.cpuSeconds - first.cpuSeconds) / wall * 100
        }
        var peak = first.footprintBytes
        for reading in readings where reading.footprintBytes > peak {
            peak = reading.footprintBytes
        }
        return SelfProcessOverhead(
            windowStart: first.takenAt,
            windowEnd: last.takenAt,
            sampleCount: readings.count,
            cpuPercent: cpuPercent,
            footprintBytes: last.footprintBytes,
            peakFootprintBytes: peak
        )
    }

    /// 丢掉滑出窗口的旧读数。窗口以**最新**读数为基准往回推。
    private mutating func trimToWindow() {
        guard let last = readings.last else { return }
        let earliest = last.takenAt.addingTimeInterval(-Self.windowSeconds)
        if let index = readings.firstIndex(where: { $0.takenAt >= earliest }), index > 0 {
            readings.removeFirst(index)
        }
    }
}
