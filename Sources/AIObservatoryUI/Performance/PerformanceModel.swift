//
//  PerformanceModel.swift
//  AIObservatoryUI / Performance
//
//  Owner: WS-UI (subagent D)
//  职责：Performance 板块数据流 —— 拉取整机采样与选中会话采样，归一化成同一套图表点，
//        并增量消费 runtime.updates 的 .performance / .sessions 推送（点数封顶 1_000）。
//
//  契约注记（ICR-0007 之后）：ObservatoryService 每个读数都有两版——无界的
//  `systemPerformance(since:)` / `performanceSamples(sessionID:)`，与带上限的
//  `…(since:limit:)` / `…(sessionID:limit:)`。**本文件一律走带上限那版**：无界版会把保留期
//  （3 s 一拍 × 30 天）整段解成对象，刷一次页就是几十万行量级的重建。
//  无界版只服务"导出全量"那一类真需要每一行的消费者。
//  另一处事实：ObservatoryUpdate.performance 携带的是会话级 PerformanceSample，没有整机样本载荷，
//  所以「整机」视图的实时推进只能按采样间隔节流重查（见 observeUpdates），会话视图是真正的增量 append
//  （那条路上 `:460` 仍按 sampleCap 裁缓冲——那是**内存上界**，不是取数兑底，别一起删）。
//

import Foundation
import Observation
import AIObservatoryCore

// MARK: - Scope

/// 性能曲线的观测对象：整机或某个会话。
enum PerformanceScope: Hashable {
    case system
    case session(UUID)
}

// MARK: - Normalized series point

/// 把整机采样与会话采样归一化成同一种图表数据点，
/// 让 CPU / 内存 / 磁盘三张图在两种 scope 下复用同一套渲染代码。
struct PerformanceSeriesPoint: Identifiable, Hashable {
    let id: UUID
    let timestamp: Date
    let cpuTotalPercent: Double
    let cpuUserPercent: Double
    let cpuSystemPercent: Double
    let memoryUsedBytes: UInt64
    let memoryTotalBytes: UInt64
    let diskReadBytesPerSecond: Double
    let diskWriteBytesPerSecond: Double
    let loadAverage1m: Double
    let thermalCelsius: Double?
    let powerWatts: Double?
    let networkInBytesPerSecond: Double?
    let networkOutBytesPerSecond: Double?
    let networkAvailability: NetworkRateAvailability?
    /// **整机** GPU 活动近似值；会话级采样恒为 `nil`（见 `init(_ sample: PerformanceSample)`）。
    let gpuActivityPercent: Double?

    init(_ sample: SystemPerformanceSample) {
        self.id = sample.id
        self.timestamp = sample.timestamp
        self.cpuTotalPercent = sample.cpuTotalPercent
        self.cpuUserPercent = sample.cpuUserPercent
        self.cpuSystemPercent = sample.cpuSystemPercent
        self.memoryUsedBytes = sample.memoryUsedBytes
        self.memoryTotalBytes = sample.memoryTotalBytes
        self.diskReadBytesPerSecond = sample.diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = sample.diskWriteBytesPerSecond
        self.loadAverage1m = sample.loadAverage1m
        self.thermalCelsius = sample.thermalCelsius
        self.powerWatts = sample.powerWatts
        self.networkInBytesPerSecond = sample.networkInBytesPerSecond
        self.networkOutBytesPerSecond = sample.networkOutBytesPerSecond
        self.networkAvailability = sample.networkAvailability
        self.gpuActivityPercent = sample.gpuActivityPercent
    }

    init(_ sample: PerformanceSample) {
        self.id = sample.id
        self.timestamp = sample.timestamp
        self.cpuTotalPercent = sample.cpuPercent
        // 会话级采样没有 user/system 拆分：全部按 user 画，不伪造系统占比。
        self.cpuUserPercent = sample.cpuPercent
        self.cpuSystemPercent = 0
        self.memoryUsedBytes = sample.memoryBytes
        self.memoryTotalBytes = 0
        self.diskReadBytesPerSecond = sample.diskReadBytesPerSecond
        self.diskWriteBytesPerSecond = sample.diskWriteBytesPerSecond
        self.loadAverage1m = 0
        self.thermalCelsius = sample.thermalCelsius
        self.powerWatts = sample.powerWatts
        // 网络与 GPU 只有整机口径：macOS 给不出非 root 的按进程网络字节 / GPU 占用，
        // 而 `PerformanceSample.networkBytesIn/Out` 是引擎从不填写的非可选默认 0——
        // 把它画成曲线等于把「没采」画成「没流量」。所以这里一律 nil。
        self.networkInBytesPerSecond = nil
        self.networkOutBytesPerSecond = nil
        self.networkAvailability = nil
        self.gpuActivityPercent = nil
    }

    /// 两条速率之和，用于磁盘峰值计算。
    var diskTotalRate: Double { diskReadBytesPerSecond + diskWriteBytesPerSecond }

    /// 本轮网络速率是否可信（两个方向都拿到才算，缺一不画点，避免半条假曲线）。
    var hasNetworkReading: Bool { networkInBytesPerSecond != nil && networkOutBytesPerSecond != nil }
}

// MARK: - Series metrics

/// 一条曲线的所有汇总量，**一次遍历**算完。
///
/// 为什么要有它：这些峰值/均值原先各自是一个 `points` 上的计算属性，而 `points` 本身也是
/// 计算属性 —— `@Observable` 不缓存计算属性，于是一次 body 求值会把整条序列重新
/// `map` 出来 24 次以上（真机 `heap` 里能看到 4 份 `PerformanceSeriesPoint` 数组与
/// 8 份 `PerformanceNetworkGraph.Reading` 数组同时存活，共 ~540 KB 只是这一条链的产物）。
/// 每轮都是**新身份**的数组，Swift Charts 的 `IDGenerator` 于是按新数据分配 id、
/// 只增不减（实测 `Charts.IDGenerator.Key→UInt64` 字典 458 KB 且随轮次增长）。
/// 收成一次遍历之后，视图把结果 `let` 绑定一次即可，序列每条 body 只物化一遍。
struct PerformanceSeriesMetrics: Hashable {
    var count: Int = 0
    var cpuPeak: Double = 0
    var cpuSum: Double = 0
    var memoryPeakBytes: UInt64 = 0
    var memoryTotalBytes: UInt64 = 0
    var diskReadPeak: Double = 0
    var diskWritePeak: Double = 0
    var diskTotalPeak: Double = 0
    var loadAverageSum: Double = 0
    var loadAverageCount: Int = 0
    var lastLoadAverage: Double?
    var networkInPeak: Double = 0
    var networkOutPeak: Double = 0

    init(points: [PerformanceSeriesPoint]) {
        var m = PerformanceSeriesMetrics()
        for p in points {
            m.count += 1
            m.cpuSum += p.cpuTotalPercent
            if p.cpuTotalPercent > m.cpuPeak { m.cpuPeak = p.cpuTotalPercent }
            if p.memoryUsedBytes > m.memoryPeakBytes { m.memoryPeakBytes = p.memoryUsedBytes }
            if p.memoryTotalBytes > m.memoryTotalBytes { m.memoryTotalBytes = p.memoryTotalBytes }
            if p.diskReadBytesPerSecond > m.diskReadPeak { m.diskReadPeak = p.diskReadBytesPerSecond }
            if p.diskWriteBytesPerSecond > m.diskWritePeak { m.diskWritePeak = p.diskWriteBytesPerSecond }
            if p.diskTotalRate > m.diskTotalPeak { m.diskTotalPeak = p.diskTotalRate }
            if p.loadAverage1m > 0 {
                m.loadAverageSum += p.loadAverage1m
                m.loadAverageCount += 1
            }
            m.lastLoadAverage = p.loadAverage1m
            if let inbound = p.networkInBytesPerSecond, inbound > m.networkInPeak { m.networkInPeak = inbound }
            if let outbound = p.networkOutBytesPerSecond, outbound > m.networkOutPeak { m.networkOutPeak = outbound }
        }
        self = m
    }

    /// 区间平均 CPU；空序列给 0 而不是 NaN。
    var cpuAverage: Double { count > 0 ? cpuSum / Double(count) : 0 }
    /// 区间平均负载：只统计真正报出负载（> 0）的那些点，会话级采样不带负载。
    var averageLoadAverage: Double {
        loadAverageCount > 0 ? loadAverageSum / Double(loadAverageCount) : 0
    }
    var isEmpty: Bool { count == 0 }

    private init() {}
}

// MARK: - Session aggregate

/// 选中会话的性能汇总（CPU / 内存 / 磁盘 / 温度 / 功耗）。
struct PerformanceSessionStats: Hashable {
    var sampleCount: Int = 0
    var averageCPUPercent: Double = 0
    var peakCPUPercent: Double = 0
    var averageMemoryBytes: Double = 0
    var peakMemoryBytes: UInt64 = 0
    var peakReadBytesPerSecond: Double = 0
    var peakWriteBytesPerSecond: Double = 0
    var averageThermalCelsius: Double?
    var peakThermalCelsius: Double?
    var averagePowerWatts: Double?
    var peakPowerWatts: Double?
    var firstSampleAt: Date?
    var lastSampleAt: Date?

    var isEmpty: Bool { sampleCount == 0 }

    /// 首末采样之间跨了多少秒。**少于两条时为 `nil`**：
    /// 一条采样给不出任何区间，报「0 秒」就是把「还不知道」写成「没跑过」。
    var coveredSeconds: Double? {
        guard sampleCount >= 2, let first = firstSampleAt, let last = lastSampleAt else { return nil }
        return max(0, last.timeIntervalSince(first))
    }

    /// 「17:06:44 → 17:06:47」；一条采样都没有时是「—」。
    var windowText: String {
        guard let first = firstSampleAt, let last = lastSampleAt else { return "—" }
        return "\(DateFormat.time(first)) → \(DateFormat.time(last))"
    }

    static let empty = PerformanceSessionStats()

    /// 从会话采样序列聚合；空序列返回 `empty`。
    static func make(from samples: [PerformanceSample]) -> PerformanceSessionStats {
        guard let first = samples.first else { return .empty }
        var stats = PerformanceSessionStats()
        stats.sampleCount = samples.count
        stats.averageCPUPercent = samples.reduce(0) { $0 + $1.cpuPercent } / Double(samples.count)
        stats.peakCPUPercent = samples.map(\.cpuPercent).max() ?? 0
        stats.averageMemoryBytes = samples.reduce(0.0) { $0 + Double($1.memoryBytes) } / Double(samples.count)
        stats.peakMemoryBytes = samples.map(\.memoryBytes).max() ?? 0
        stats.peakReadBytesPerSecond = samples.map(\.diskReadBytesPerSecond).max() ?? 0
        stats.peakWriteBytesPerSecond = samples.map(\.diskWriteBytesPerSecond).max() ?? 0
        stats.firstSampleAt = samples.map(\.timestamp).min() ?? first.timestamp
        stats.lastSampleAt = samples.map(\.timestamp).max() ?? first.timestamp

        let thermals = samples.compactMap(\.thermalCelsius)
        if !thermals.isEmpty {
            stats.averageThermalCelsius = thermals.reduce(0, +) / Double(thermals.count)
            stats.peakThermalCelsius = thermals.max()
        }
        let powers = samples.compactMap(\.powerWatts)
        if !powers.isEmpty {
            stats.averagePowerWatts = powers.reduce(0, +) / Double(powers.count)
            stats.peakPowerWatts = powers.max()
        }
        return stats
    }
}

// MARK: - Model

@Observable @MainActor
final class PerformanceModel {
    /// 曲线点数上限：超出即从头部裁剪，保证内存与重绘开销可控。
    static let sampleCap = 1_000
    /// 会话选择器最多列出的会话数。
    static let sessionCap = 100
    /// 产品硬指标：**本 App 自己**的空闲 CPU 预算（%）。
    /// 注意它不属于整机也不属于任何被观测会话，因此性能页的曲线与整机/会话瓷贴都不拿它当尺子；
    /// 它的消费者只有 `SelfProcessOverheadPanel` ——也就是唯一那个**按本进程口径**读数的格子。
    static let idleCPUBudgetPercent: Double = 3
    /// **本 App** 内存常驻上限（MB）。同上：不是整机量，不参与整机瓷贴的判定。
    static let memoryBudgetMB: Double = 200
    /// **本 App** 内存常驻目标（MB）。AGENTS.md §6 把 200 定为上限、120 定为目标，
    /// 两者都要上屏：只报「离 200 还有多少」会把「目标没达到」读成「余量充足」。
    static let memoryTargetMB: Double = 120

    private(set) var isLoading = false
    private(set) var errorMessage: String?

    private(set) var systemSamples: [SystemPerformanceSample] = []
    private(set) var sessionSamples: [PerformanceSample] = []
    private(set) var sessions: [AgentSession] = []
    private(set) var lastReloadedAt: Date?

    /// 选中会话；nil 表示「整机」。
    var selectedSessionID: UUID?
    /// 本地时间范围；视图会把 `ShellModel.timeRange` 同步进来。
    var range: ObservatoryTimeRange = .lastSixHours

    private let runtime: ObservatoryRuntime
    /// 整机曲线节流重查的时间戳（契约没有整机增量，见文件头注记）。
    private var lastSystemReloadAt: Date?

    /// 本进程读数的来源；`nil` = 宿主没有装配仪器（见 ICR-0003），
    /// 此时「本 App 自身开销」那一格明写未接入，而不是画一排 0。
    private let selfProcessSource: (any SelfProcessReadingSource)?
    /// 自身开销的滚动窗口。**同一个来源实例从头用到尾**，不每次刷新新建：
    /// CPU 占用率只有「窗口两端各采一次再求差」才有意义，单次累计值不是占用率。
    private var selfGauge = SelfProcessGauge()
    /// 最近一次采样后算好的窗口汇总。**存值而不是计算属性**：
    /// 视图每条 body 读一次就够，不需要像 `points` 那样每读一遍重算一条序列。
    private(set) var selfOverhead: SelfProcessOverhead?

    init(runtime: ObservatoryRuntime, selfProcessSource: (any SelfProcessReadingSource)? = nil) {
        self.runtime = runtime
        self.selfProcessSource = selfProcessSource
    }

    /// 宿主有没有把本进程仪器接进来。未接入与「接了但还没采到」是两种状态，文案不同。
    var hasSelfProcessInstrument: Bool { selfProcessSource != nil }

    // MARK: Derived

    var scope: PerformanceScope {
        if let selectedSessionID { return .session(selectedSessionID) }
        return .system
    }

    /// 当前 scope 下图表要画的点。
    ///
    /// ⚠️ 这是计算属性，**每读一次就重新 `map` 一条新序列**。调用方（视图）必须在
    /// body 顶部 `let` 绑定一次再往下传，不能像以前那样在十几处分别 `model.points` /
    /// `model.cpuPeak` —— 那是真机性能页内存单调增长的放大器，见 `PerformanceSeriesMetrics`。
    var points: [PerformanceSeriesPoint] {
        switch scope {
        case .system: systemSamples.map(PerformanceSeriesPoint.init)
        case .session: sessionSamples.map(PerformanceSeriesPoint.init)
        }
    }

    var hasData: Bool { !systemSamples.isEmpty || !sessionSamples.isEmpty }

    /// 整机曲线是否已有落库样本：区分「引擎还没采」与「这台机器给不出这个指标」的前半句。
    var hasSystemSamples: Bool { !systemSamples.isEmpty }

    var latestSystemSample: SystemPerformanceSample? { systemSamples.last }

    /// 「当前 CPU」：整机优先，其次会话最后一点。
    var currentCPUPercent: Double {
        if let latest = systemSamples.last { return latest.cpuTotalPercent }
        return sessionSamples.last?.cpuPercent ?? 0
    }

    /// 温度：整机优先，其次当前会话的最后一条采样。
    /// 原先写成 `points.last?.thermalCelsius`，为了取「最后一个点」把整条序列重算一遍；
    /// 直接读两份存量数组的末尾，语义不变（scope 为整机时 sessionSamples 必为空，见 `loadSessionSamples`）。
    var thermalCelsius: Double? { latestSystemSample?.thermalCelsius ?? sessionSamples.last?.thermalCelsius }
    var powerWatts: Double? { latestSystemSample?.powerWatts ?? sessionSamples.last?.powerWatts }

    // MARK: 网络与 GPU（只有整机口径）

    /// 最近一轮整机网络速率为什么没有：`nil` 且速率也为 `nil` ⇒ 该行根本没记录（v3 之前的老数据）。
    var networkAvailability: NetworkRateAvailability? { latestSystemSample?.networkAvailability }
    var networkInBytesPerSecond: Double? { latestSystemSample?.networkInBytesPerSecond }
    var networkOutBytesPerSecond: Double? { latestSystemSample?.networkOutBytesPerSecond }

    /// **整机** GPU 活动近似值；不来自会话级采样，也不归因到任何 Agent。
    var gpuActivityPercent: Double? { latestSystemSample?.gpuActivityPercent }

    var sessionStats: PerformanceSessionStats { .make(from: sessionSamples) }

    var selectedSession: AgentSession? {
        guard let selectedSessionID else { return nil }
        return sessions.first { $0.id == selectedSessionID }
    }

    /// 引擎的采集节奏（来自契约里的当前设置快照），仅用于界面说明文案。
    ///
    /// 刻意不叫 `sampleIntervalSeconds`：那个字段已经删了，它命名上像"性能采样间隔"
    /// 却没有任何引擎侧生产者，只驱动过一句假文案（"引擎每 2 秒采样一次"，真实是 3 秒）。
    /// 现在读的是 `processScanIntervalSeconds` —— 引擎唯一那条循环真正使用的那个值。
    var engineScanIntervalSeconds: Double { runtime.settings.processScanIntervalSeconds }

    /// 图表副标题：观测对象 + 时间范围。
    var scopeTitle: String {
        let language = UILanguage.current
        let range = range.displayName(UILanguage.current)
        switch scope {
        case .system:
            return "\(PerformanceCopy.scopeSystem.text(language)) · \(range)"
        case .session:
            let target = selectedSession.map(sessionPickerTitle)
                ?? PerformanceCopy.scopeSelectedSession.text(language)
            return "\(target) · \(range)"
        }
    }

    /// 会话选择器文案：`#102 Mona`。
    func sessionPickerTitle(_ session: AgentSession) -> String {
        let index = session.displayIndex > 0 ? "#\(session.displayIndex)" : session.kind.displayName
        let tail = session.projectPath.map { " \(($0 as NSString).lastPathComponent)" } ?? ""
        return "\(index)\(tail)"
    }

    // MARK: Loading

    func load() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        // 进页面 / 换范围都先落一个窗口端点，剩下的端点由 `.agents` 心跳推进。
        recordSelfProcessSample()

        let dateRange = range.dateRange()
        do {
            // ICR-0007：截断在取数层（SQL `ORDER BY … DESC LIMIT ?` / SwiftData `fetchLimit`）。
            // 界面**不再** `suffix(sampleCap)` 兑底——两边都限就看不出是谁在工作，
            // 而默认实现（转调无界版再截）也永远测不到"有没有整段捞回"。
            systemSamples = try await runtime.service.systemPerformance(
                since: startDate(for: dateRange), limit: Self.sampleCap
            )

            let page = try await runtime.service.sessions(
                matching: SessionQuery(dateRange: dateRange, limit: Self.sessionCap)
            )
            sessions = page.items
            if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
            }

            await loadSessionSamples()
            lastReloadedAt = Date()
            lastSystemReloadAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 只重查选中会话的性能采样（切换会话时调用，避免整库重查）。
    func loadSessionSamples() async {
        guard let selectedSessionID else {
            sessionSamples = []
            return
        }
        do {
            sessionSamples = try await runtime.service.performanceSamples(
                sessionID: selectedSessionID, limit: Self.sampleCap
            )
        } catch {
            sessionSamples = []
            errorMessage = error.localizedDescription
        }
    }

    /// 只重拉整机曲线（切换时间范围时可用，避免连带重查会话列表）。
    func reloadSystemSamples() async {
        do {
            systemSamples = try await runtime.service.systemPerformance(
                since: startDate(for: range.dateRange()), limit: Self.sampleCap
            )
            lastReloadedAt = Date()
            lastSystemReloadAt = Date()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: 本进程自身开销（判据④）

    /// 采一次本进程读数并推进窗口。
    ///
    /// **刻意不自建计时器**：判据④ 量的就是本 App 自己，为它挂一条 Timer 等于往被测对象上加砝码。
    /// 节拍完全骑在引擎已有的心跳上（`.agents` 每个扫描 tick 无条件广播），
    /// 所以「一个 Agent 都没在跑」时窗口照样在积累——而那恰恰是最需要看空闲开销的时候。
    /// 降频由 `SelfProcessGauge.record` 的间隔下限兜底，两次读数共 2 次系统调用。
    func recordSelfProcessSample(now: Date = Date()) {
        guard let selfProcessSource else { return }
        guard let reading = selfProcessSource.readSelfProcessSample(now: now) else { return }
        guard selfGauge.record(reading) else { return }
        selfOverhead = selfGauge.overhead
    }

    // MARK: Live updates

    func observeUpdates() async {
        for await update in runtime.updates.makeUpdateStream() {
            await ingest(update)
        }
    }

    private func ingest(_ update: ObservatoryUpdate) async {
        switch update {
        case .performance(let sample):
            append(sample)
            if case .system = scope {
                await reloadSystemSamplesIfStale()
            }
        case .agents:
            // 引擎每个扫描 tick 无条件广播 `.agents`，所以这一格不靠自己挂计时器就有节拍——
            // 见 `recordSelfProcessSample()` 那段「判据④ 量的是本 App，别为它加砝码」。
            recordSelfProcessSample()
        case .sessions(let list):
            sessions = Array(list.prefix(Self.sessionCap))
            if let selectedSessionID, !sessions.contains(where: { $0.id == selectedSessionID }) {
                self.selectedSessionID = nil
            }
        case .timelineEvent, .fileChange, .command, .risk, .dashboard, .engineState:
            break
        }
    }

    /// 会话曲线：真正的增量插入，超上限从头部裁剪。
    private func append(_ sample: PerformanceSample) {
        guard let selectedSessionID, sample.sessionID == selectedSessionID else { return }
        guard !sessionSamples.contains(where: { $0.id == sample.id }) else { return }
        if let last = sessionSamples.last, sample.timestamp < last.timestamp { return }
        sessionSamples.append(sample)
        if sessionSamples.count > Self.sampleCap {
            sessionSamples.removeFirst(sessionSamples.count - Self.sampleCap)
        }
    }

    /// 整机曲线的节流重查：最快每 4 个采样周期一次，避免高频推送打爆存储层。
    private func reloadSystemSamplesIfStale() async {
        let now = Date()
        let interval = max(5, runtime.settings.processScanIntervalSeconds * 4)
        if let last = lastSystemReloadAt, now.timeIntervalSince(last) < interval { return }
        await reloadSystemSamples()
    }

    // MARK: Helpers

    /// `systemPerformance(since:)` 需要一个下界；「全部」区间退回到保留期内的固定窗口。
    private func startDate(for filter: DateRangeFilter) -> Date {
        if let start = filter.start { return start }
        let days = max(1, runtime.settings.retentionDays)
        return Calendar.current.date(byAdding: .day, value: -days, to: Date()) ?? Date()
    }
}
