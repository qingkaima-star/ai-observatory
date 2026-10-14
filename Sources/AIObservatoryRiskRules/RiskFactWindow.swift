//
//  RiskFactWindow.swift
//  AIObservatoryRiskRules
//
//  Owner: WS-Risk
//
//  规则评估的输入：一段时间窗内的已分类事实集合。
//
//  命名说明：契约层 `AIObservatoryCore.CollectorContracts` 已占用 `RiskContext`
//  这个名字（单事件上下文），因此本模块的窗口类型改名为 `RiskFactWindow`，
//  避免 Engine 同时 import 两个模块时产生歧义。`RiskAssessor` 负责把
//  契约的 `RiskContext` 适配成 `RiskFactWindow`。
//
//  本类型不做任何 IO，也不读取当前时间：`start`/`end`/`calendar`/`homeDirectory`
//  全部由调用方注入，保证规则评估可确定性重现。
//

import Foundation
import AIObservatoryCore

// MARK: - Thresholds

/// 规则阈值集合。集中管理，便于按 Agent 类型或用户偏好整体调参，
/// 也便于测试里构造极小的阈值以触发边界断言。
public struct RiskThresholds: Sendable, Hashable {

    /// 一次删除事实聚簇的时间跨度（秒）。
    public var massDeletionSpan: TimeInterval
    /// 达到"批量删除"所需的最少删除条数。
    public var massDeletionCount: Int
    /// 升级为 HIGH 的删除条数。
    public var massDeletionHighCount: Int
    /// 升级为 CRITICAL 的删除条数。
    public var massDeletionCriticalCount: Int
    /// 单次清空目录所需的删除条目所指向的目录内文件数。
    public var directoryWipeCount: Int
    /// 覆盖式重写：单次修改删除行数阈值。
    public var overwriteRemovedLines: Int
    /// 覆盖式重写：删除行数占原文件行数比例阈值。
    public var overwriteRatio: Double
    /// 同一文件重复修改（抖动）所需次数。
    public var repeatedEditCount: Int
    /// 判定"抖动"的观察跨度（秒）。
    public var repeatedEditSpan: TimeInterval
    /// 非工作时间区间起始小时（含），24 小时制。
    public var offHoursStartHour: Int
    /// 非工作时间区间结束小时（不含），24 小时制。
    public var offHoursEndHour: Int
    /// 非工作时间内的活动密度阈值（每 60 秒事件数）。
    public var offHoursEventRate: Double
    /// 持续高 CPU 的占用率阈值（百分比）。
    public var sustainedCPUPercent: Double
    /// 持续高 CPU 所需秒数。
    public var sustainedCPUSeconds: Double
    /// 采样间隔（秒），用于把离散采样换算为持续时长。
    public var sampleInterval: TimeInterval
    /// 单会话内存峰值阈值（字节）。
    public var peakMemoryBytes: UInt64
    /// 前台命令最长允许时长（秒）。
    public var longRunningCommandSeconds: Double
    /// 单窗口内提权命令次数阈值。
    public var privilegeEscalationCount: Int
    /// 同一会话内安全配置被改动的次数阈值。
    public var securityMutationCount: Int
    /// 敏感路径读取次数阈值（低于该值只报 LOW）。
    public var sensitiveAccessCount: Int
    /// 单个命令命中被判定为"高危"的最低上游等级。
    public var dangerousCommandFloorLevel: RiskLevel

    public init(
        massDeletionSpan: TimeInterval = 60,
        massDeletionCount: Int = 8,
        massDeletionHighCount: Int = 25,
        massDeletionCriticalCount: Int = 200,
        directoryWipeCount: Int = 30,
        overwriteRemovedLines: Int = 300,
        overwriteRatio: Double = 0.8,
        repeatedEditCount: Int = 6,
        repeatedEditSpan: TimeInterval = 120,
        offHoursStartHour: Int = 23,
        offHoursEndHour: Int = 6,
        offHoursEventRate: Double = 20,
        sustainedCPUPercent: Double = 80,
        sustainedCPUSeconds: Double = 120,
        sampleInterval: TimeInterval = 2,
        peakMemoryBytes: UInt64 = 2 * 1024 * 1024 * 1024,
        longRunningCommandSeconds: Double = 600,
        privilegeEscalationCount: Int = 2,
        securityMutationCount: Int = 2,
        sensitiveAccessCount: Int = 3,
        dangerousCommandFloorLevel: RiskLevel = .high
    ) {
        self.massDeletionSpan = massDeletionSpan
        self.massDeletionCount = massDeletionCount
        self.massDeletionHighCount = massDeletionHighCount
        self.massDeletionCriticalCount = massDeletionCriticalCount
        self.directoryWipeCount = directoryWipeCount
        self.overwriteRemovedLines = overwriteRemovedLines
        self.overwriteRatio = overwriteRatio
        self.repeatedEditCount = repeatedEditCount
        self.repeatedEditSpan = repeatedEditSpan
        self.offHoursStartHour = offHoursStartHour
        self.offHoursEndHour = offHoursEndHour
        self.offHoursEventRate = offHoursEventRate
        self.sustainedCPUPercent = sustainedCPUPercent
        self.sustainedCPUSeconds = sustainedCPUSeconds
        self.sampleInterval = sampleInterval
        self.peakMemoryBytes = peakMemoryBytes
        self.longRunningCommandSeconds = longRunningCommandSeconds
        self.privilegeEscalationCount = privilegeEscalationCount
        self.securityMutationCount = securityMutationCount
        self.sensitiveAccessCount = sensitiveAccessCount
        self.dangerousCommandFloorLevel = dangerousCommandFloorLevel
    }

    /// 默认阈值（保守取值）。
    public static let standard = RiskThresholds()

    /// 依据删除条数推导等级，供 A 族与聚合层共用。
    public func deletionLevel(count: Int) -> RiskLevel {
        if count >= massDeletionCriticalCount { return .critical }
        if count >= massDeletionHighCount { return .high }
        if count >= massDeletionCount { return .medium }
        return .low
    }
}

// MARK: - Fact Window

/// 一段时间窗内的全部已分类事实，规则评估的唯一输入。
public struct RiskFactWindow: Sendable {

    public var session: AgentSession?
    public var events: [TimelineEvent]
    public var fileChanges: [FileChange]
    public var commands: [CommandRecord]
    public var samples: [PerformanceSample]

    /// 窗口起点。规则的 `start` 与 `end` 不由 `Date()` 推导。
    public var start: Date
    /// 窗口终点。
    public var end: Date

    /// 注入的宿主 home 目录，用于敏感位置与越界写入判定。测试可传入固定值。
    public var homeDirectory: String
    /// 允许写入的根目录集合（会话项目根 + 各 Agent 工作目录）。
    public var allowedWriteRoots: [String]
    /// 注入的日历，用于非工作时间判定（含时区）。
    public var calendar: Calendar
    /// 阈值集合。
    public var thresholds: RiskThresholds

    /// 由调用方（Engine/Telemetry）传入的命令分类结论，键为 `CommandRecord.id`。
    /// 规则优先复用这里的结论，避免与 `DestructiveCommandRules` 文本规则给出不一致判定。
    public var telemetryClassifications: [UUID: CommandClassification]

    /// 用户显式声明的额外可信写入根（例如工作区白名单）。
    public var trustedWriteRoots: [String]
    /// 本窗口之外已知的其他项目根（用于跨项目越界写入判定）。
    public var otherProjectRoots: [String]

    /// 生成这段事实时的**界面语言**：规则产出的 `title` / `detail` 按它渲染，
    /// 写进库之后**不回改**（IFR 裁定 2「写入时冻结」）。
    ///
    /// ⚠️ 默认值 `.resolved()` 只服务测试与预览；生产路径由装配点
    /// （`ObservatoryEngine.Components.live`）把同一个值显式传给 `RiskPipeline` 与
    /// `RiskAssessor`，避免一次评估里两个来源。
    public var interfaceLanguage: AppLanguage

    public init(
        session: AgentSession? = nil,
        events: [TimelineEvent] = [],
        fileChanges: [FileChange] = [],
        commands: [CommandRecord] = [],
        samples: [PerformanceSample] = [],
        start: Date? = nil,
        end: Date? = nil,
        homeDirectory: String = NSHomeDirectory(),
        allowedWriteRoots: [String] = [],
        trustedWriteRoots: [String] = [],
        calendar: Calendar = RiskFactWindow.gregorianUTC,
        thresholds: RiskThresholds = .standard,
        telemetryClassifications: [UUID: CommandClassification] = [:],
        otherProjectRoots: [String] = [],
        interfaceLanguage: AppLanguage = .resolved()
    ) {
        self.interfaceLanguage = interfaceLanguage
        self.session = session
        self.events = events
        self.fileChanges = fileChanges
        self.commands = commands
        self.samples = samples
        self.homeDirectory = homeDirectory
        self.calendar = calendar
        self.thresholds = thresholds
        self.telemetryClassifications = telemetryClassifications

        var roots = Self.normalizedRoots(allowedWriteRoots, homeDirectory: homeDirectory)
        if let project = session?.projectPath, !project.isEmpty {
            roots = Self.normalizedRoots(roots + [project], homeDirectory: homeDirectory)
        }
        self.allowedWriteRoots = roots
        self.trustedWriteRoots = Self.normalizedRoots(trustedWriteRoots, homeDirectory: homeDirectory)
        self.otherProjectRoots = Self.normalizedRoots(otherProjectRoots, homeDirectory: homeDirectory)

        if let start, let end {
            self.start = start
            self.end = end
        } else {
            self.start = start ?? Self.derivedStart(events: events, fileChanges: fileChanges, commands: commands, session: session)
            self.end = end ?? Self.derivedEnd(events: events, fileChanges: fileChanges, commands: commands, session: session)
        }
    }

    // MARK: 常量

    /// 用作"未显式给定窗口"的哨兵值。
    static let epochZero = Date(timeIntervalSince1970: 0)

    /// UTC + Gregorian 的默认日历，保证跨机器一致。
    ///
    /// ⚠️ 必须是 `static let`，不能是 `static var`（计算属性）——实测代价大到离谱：
    /// `MallocStackLogging=1` 跑 90 s（≈30 个 tick）后 `malloc_history -allBySize` 按
    /// 「最深的自有帧」归因，这个 getter 是 **78 次调用 / 34.07 MB / 平均每次 436 KB**，
    /// 是全进程第 3 大的分配点，而且它落在 `MALLOC_SMALL` 那一档（≤512 KB），
    /// 正是长跑时 `MALLOC_SMALL` dirty 从 65 MB 涨到 165 MB 的直接来源
    /// （libmalloc 只有整页全空才归还 ⇒ 这种大块小对象反复生成就等于把页钉住）。
    /// 之所以每 tick 都被构造：它同时是 `RiskPipeline.swift:118` 与
    /// `RiskFactWindow.swift:173` 的**默认参数值**，而默认参数在**每次调用**时求值。
    /// 值类型 + 只读，共享一份常量是安全的（调用方拿到的是 COW 副本）。
    public static let gregorianUTC: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        return calendar
    }()

    // MARK: 归一化派生集合（全部按时间升序、时间相同按 id 字典序，保证确定性）

    /// 按时间升序排序的事件。
    public var sortedEvents: [TimelineEvent] {
        events.sorted { lhs, rhs in Self.ordered(lhs.timestamp, lhs.id, rhs.timestamp, rhs.id) }
    }

    /// 按时间升序排序的文件变更。
    public var sortedFileChanges: [FileChange] {
        fileChanges.sorted { lhs, rhs in Self.ordered(lhs.timestamp, lhs.id, rhs.timestamp, rhs.id) }
    }

    /// 按开始时间升序排序的命令。
    public var sortedCommands: [CommandRecord] {
        commands.sorted { lhs, rhs in Self.ordered(lhs.startedAt, lhs.id, rhs.startedAt, rhs.id) }
    }

    /// 按时间升序排序的采样。
    public var sortedSamples: [PerformanceSample] {
        samples.sorted { lhs, rhs in Self.ordered(lhs.timestamp, lhs.id, rhs.timestamp, rhs.id) }
    }

    /// 删除类文件变更。
    public var deletions: [FileChange] { sortedFileChanges.filter { $0.kind == .deleted } }

    /// 修改类文件变更。
    public var modifications: [FileChange] { sortedFileChanges.filter { $0.kind == .modified } }

    /// 新建类文件变更。
    public var creations: [FileChange] { sortedFileChanges.filter { $0.kind == .created } }

    /// 重命名类文件变更。
    public var renames: [FileChange] { sortedFileChanges.filter { $0.kind == .renamed } }

    /// 写类变更（新建 + 修改 + 重命名）。
    public var writes: [FileChange] { sortedFileChanges.filter { $0.kind != .deleted } }

    /// 窗口内是否存在「写证据」。
    ///
    /// 只看 `fileChanges` 是不够的：`rm -rf ~/Documents` 这类被判定为破坏性的命令
    /// 本身就携带写意图，而且**那恰恰是「执行前确认」唯一还来得及拿到证据的时刻**——
    /// 等文件真的被删掉再报警，确认就已经失去意义了。
    /// 因此破坏性命令与文件变更事实同等计入。
    public var hasWriteEvidence: Bool {
        if !fileChanges.isEmpty { return true }
        return commands.contains { command in
            classification(for: command)?.isDestructive ?? false
        }
    }

    /// 读取类事件（`OperationKind.fileRead`）。
    public var readEvents: [TimelineEvent] { sortedEvents.filter { $0.kind == .fileRead } }

    /// 被访问过的路径（读事件 + 全部文件变更），去重并按首次出现时间排序。
    public var accessedPaths: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for change in sortedFileChanges where !seen.contains(change.path) {
            seen.insert(change.path)
            out.append(change.path)
        }
        for event in sortedEvents {
            guard let path = event.filePath, !seen.contains(path) else { continue }
            seen.insert(path)
            out.append(path)
        }
        return out
    }

    /// 本窗口归属的会话 ID。
    public var sessionID: UUID? {
        if let id = session?.id { return id }
        return sortedEvents.lazy.compactMap(\.sessionID).first
    }

    /// 本窗口涉及的主要 Agent 类型。
    public var agentKind: AgentKind {
        if let kind = session?.kind { return kind }
        return sortedEvents.lazy.map(\.agentKind).first { $0 != .unknown } ?? .unknown
    }

    /// 本窗口涉及的 Agent 实例 ID。
    public var agentIDs: [UUID] {
        var seen = Set<UUID>()
        var out: [UUID] = []
        for id in sortedEvents.compactMap(\.agentID) where !seen.contains(id) {
            seen.insert(id)
            out.append(id)
        }
        return out
    }

    /// 窗口总时长（秒），非正时返回 0。
    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }

    // MARK: 查询辅助

    /// 事件是否落在窗口内（含边界）。
    public func contains(_ date: Date) -> Bool {
        date >= start && date <= end
    }

    /// 取该命令可用的分类结论：优先调用方传入的 Telemetry 结果，
    /// 其次使用 `CommandRecord` 自身已落库的分级字段，最后返回 nil 表示上游未判定。
    public func classification(for command: CommandRecord) -> CommandClassification? {
        if let provided = telemetryClassifications[command.id] { return provided }
        guard command.isDestructive || command.riskLevel != .low || command.requiresConfirmation else { return nil }
        return CommandClassification(
            isDestructive: command.isDestructive,
            requiresConfirmation: command.requiresConfirmation,
            level: command.riskLevel,
            category: nil
        )
    }

    /// 上游判定为危险（等级 ≥ `thresholds.dangerousCommandFloorLevel`）的命令。
    public func dangerousCommands(classifier: RiskCommandClassifier = RiskCommandClassifier()) -> [CommandRecord] {
        sortedCommands.filter { command in
            guard let classification = classification(for: command) else { return false }
            return classification.level.rank >= thresholds.dangerousCommandFloorLevel.rank
                || (classification.isDestructive && classifier.looksIrreversible(RiskCommandFacts(command)))
        }
    }

    /// 指定小时（含时区）的整点事件计数。
    public func eventCount(inHour targetHour: Int) -> Int {
        sortedEvents.reduce(0) { total, event in
            hour(of: event.timestamp) == targetHour ? total + 1 : total
        }
    }

    // MARK: 时间处理

    /// 取某时刻在注入日历下的小时（0…23）。
    public func hour(of date: Date) -> Int {
        calendar.component(.hour, from: date)
    }

    /// 是否处于配置的非工作时间区间。跨零点区间（23…6）被正确处理。
    public func isOffHours(_ date: Date) -> Bool {
        let hour = self.hour(of: date)
        if thresholds.offHoursStartHour <= thresholds.offHoursEndHour {
            return hour >= thresholds.offHoursStartHour && hour < thresholds.offHoursEndHour
        }
        return hour >= thresholds.offHoursStartHour || hour < thresholds.offHoursEndHour
    }

    // MARK: 路径处理

    /// 路径是否位于任一允许写入根（含 `trustedWriteRoots`）之内。
    public func isWithinAllowedWriteRoots(_ path: String) -> Bool {
        RiskPathAnalyzer.isPath(path, withinRoots: allowedWriteRoots + trustedWriteRoots)
    }

    /// 路径是否落在某个其他项目根内（跨项目越界）。
    public func isWithinOtherProjectRoot(_ path: String) -> Bool {
        RiskPathAnalyzer.isPath(path, withinRoots: otherProjectRoots, homeDirectory: homeDirectory)
    }

    /// 命中的其他项目根，无则 nil。
    public func matchingOtherProjectRoot(for path: String) -> String? {
        otherProjectRoots.first { RiskPathAnalyzer.isPath(path, withinRoots: [$0], homeDirectory: homeDirectory) }
    }

    /// 路径是否位于宿主 home 之内。
    public func isWithinHome(_ path: String) -> Bool {
        RiskPathAnalyzer.isPath(path, withinRoots: [homeDirectory])
    }

    // MARK: 聚簇

    /// 按时间贪心聚簇：从首条事实开始，凡是与簇起点间隔 ≤ `span` 的都归入同簇。
    ///
    /// 这是"60 秒内 42 次删除只报 1 条"这类窗口聚合规则的统一实现入口，
    /// 输入必须已按时间升序（本方法内部会自行排序）。
    public func temporalClusters<T: Sendable>(
        _ items: [T],
        span: TimeInterval,
        timestamp: (T) -> Date
    ) -> [RiskCluster<T>] {
        guard !items.isEmpty else { return [] }
        let ordered = items.sorted { timestamp($0) < timestamp($1) }
        var clusters: [RiskCluster<T>] = []
        var bucketStart = timestamp(ordered[0])
        var bucketLast = bucketStart
        var bucket: [T] = []
        for item in ordered {
            let at = timestamp(item)
            if at.timeIntervalSince(bucketStart) > span {
                clusters.append(RiskCluster(start: bucketStart, end: bucketLast, items: bucket))
                bucketStart = at
                bucket = []
            }
            bucketLast = at
            bucket.append(item)
        }
        clusters.append(RiskCluster(start: bucketStart, end: bucketLast, items: bucket))
        return clusters
    }

    // MARK: 私有

    private static func ordered(_ leftDate: Date, _ leftID: UUID, _ rightDate: Date, _ rightID: UUID) -> Bool {
        if leftDate != rightDate { return leftDate < rightDate }
        return leftID.uuidString < rightID.uuidString
    }

    private static func normalizedRoots(_ roots: [String], homeDirectory: String) -> [String] {
        roots.filter { !$0.isEmpty }.map { RiskPathAnalyzer.normalized($0, homeDirectory: homeDirectory) }
    }

    private static func derivedStart(
        events: [TimelineEvent],
        fileChanges: [FileChange],
        commands: [CommandRecord],
        session: AgentSession?
    ) -> Date {
        var candidates: [Date] = []
        if let startedAt = session?.startedAt { candidates.append(startedAt) }
        candidates += events.map(\.timestamp)
        candidates += fileChanges.map(\.timestamp)
        candidates += commands.map(\.startedAt)
        return candidates.min() ?? epochZero
    }

    private static func derivedEnd(
        events: [TimelineEvent],
        fileChanges: [FileChange],
        commands: [CommandRecord],
        session: AgentSession?
    ) -> Date {
        var candidates: [Date] = []
        if let endedAt = session?.endedAt { candidates.append(endedAt) }
        candidates += events.map(\.timestamp)
        candidates += fileChanges.map(\.timestamp)
        candidates += commands.map { $0.endedAt ?? $0.startedAt }
        return candidates.max() ?? epochZero
    }
}

// MARK: - Cluster

/// 一个时间簇：起点、终点与簇内事实。
public struct RiskCluster<Element>: Sendable where Element: Sendable {
    public var start: Date
    public var end: Date
    public var items: [Element]

    public init(start: Date, end: Date, items: [Element]) {
        self.start = start
        self.end = end
        self.items = items
    }

    public var count: Int { items.count }

    /// 簇跨度（秒），非正时返回 0。
    public var span: TimeInterval { max(0, end.timeIntervalSince(start)) }

    /// 平均事件速率（条/秒）。
    public var ratePerSecond: Double {
        let seconds = span
        guard seconds > 0 else { return Double(items.count) }
        return Double(items.count) / seconds
    }
}
