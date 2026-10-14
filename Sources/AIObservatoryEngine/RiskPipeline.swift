//
//  RiskPipeline.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine（本文件已由 WS-RiskMerge 收敛为「编排层」）
//
//  风险层的**唯一规则库**是 `AIObservatoryRiskRules.RiskAssessor`（33 条会话级聚合规则）。
//  本类型**不再自带任何风险规则**——旧的 14 条 `defaultRules`、内建的 60 秒批量删除滚动窗口
//  以及外部分类器兜底全部删除（见 `04-决策记录/IFR-risk-engine-merge.md` §4 的逐条映射表）。
//
//  Engine 在这里只承担「编排与状态」：
//   1. **窗口缓存**：按会话键累积进料口送来的事实（事件 / 文件变更 / 命令，以及经
//      `noteSample(_:sessionID:agentKind:)` 送入的**性能采样**），组装成 `RiskFactWindow`
//      交给 `RiskAssessor.assess(_:)`，从而拿到跨事件聚合能力
//      （批量删除、提权成串、跨项目越界写、持续 CPU 高峰、内存峰值超限…）；
//
//      采样必须有独立进料口：契约 `RiskContext`（`AIObservatoryCore`，冻结）不携带采样，
//      只靠 `evaluate(_:)` 会让 `window.samples` 恒为空，资源滥用类两条规则
//      （`risk.pattern.sustained-cpu-peak` / `risk.pattern.excessive-memory-peak`）
//      在运行中的 app 里永不触发。
//   2. **节流**：同一 finding（`ruleID@suppressionKey`，会话内唯一）在其证据滑出保留窗之前
//      只产出一次，避免同一根因刷屏（42 次删除 → 1 条事件）；
//   3. **幂等落库**：为每条 `RiskEvent` 打**确定性 id**（由会话键 + finding.id 经 FNV-1a 派生），
//      使同一 finding 重复评估映射到同一行；Store 的 `is_acknowledged=MAX(...)` 因此不会被
//      重评冲掉（IFR §5 的幂等键约定）。
//   4. **驻留封顶**：窗口键取自 `sessionID.uuidString`，而一条已结算的会话**再也不会被喂**，
//      所以「只在窗口一条事实都没有时摘键」挡不住化石键——`maxFactsPerKind` 只在单个键内
//      起作用，对**键的个数**完全无效，驻留量会随进程见过的会话数单调增长、不收敛。
//      于是再给同时存活的窗口个数设上限（`BufferPolicy.maxActiveWindows`，默认 64），
//      超出即淘汰「最久没再被喂事实」的键；淘汰只在本次进料评估、产出之后发生，
//      且永不淘汰正在进料的键，因此封顶不会让本轮少产出一条 finding。
//
//  确定性：不读 `Date()` 墙钟——参考时刻一律取窗口内事实的最大时间戳；home / 日历 / 阈值 /
//  `otherProjectRoots` 全部由构造子注入。规则评估是 `RiskAssessor` 的纯函数，
//  因此同一输入序列必得逐字节相同的产出。窗口淘汰的「最后被喂时刻」也取自那个已算出的
//  `newest`（存进 `WindowState.lastFedAt`，不引入墙钟）；时刻并列时按窗口键字典序取最小者淘汰，
//  **不依赖 `Dictionary` 的遍历顺序**。
//

import Foundation
import os
import AIObservatoryCore
import AIObservatoryRiskRules

// MARK: - RiskPipeline

/// 风险编排器：把契约的单事件 `RiskContext` 汇入每会话事实窗口，交给唯一的规则库评估，
/// 并做节流与幂等落库。实现契约 `RiskEvaluating`，供 `ObservatoryEngine` 直接调用。
///
/// `RiskEvaluating.evaluate` 是**同步**要求，actor 无法符合，因此本类型是 `final class`；
/// 全部可变状态集中在**一个** `OSAllocatedUnfairLock<[String: WindowState]>` 里，
/// 于是类是正当的 `Sendable`（不使用 `@unchecked`）。
public final class RiskPipeline: RiskEvaluating, Sendable {

    // MARK: - Policy

    /// 事实窗口缓存策略。
    public struct BufferPolicy: Sendable, Hashable {
        /// 事实与已产出 finding 的保留时长（秒）；超出即从窗口裁剪。
        public var retention: TimeInterval
        /// 每类事实的缓存上限，防止长会话无界增长（超出后丢最旧的）。
        public var maxFactsPerKind: Int
        /// 同时存活的会话窗口个数上限（`< 1` 在使用处收敛为 1）。
        ///
        /// 为什么要有这个上限：窗口键来自 `sessionID.uuidString`，而**已结算的会话永远不会
        /// 再被喂**，它那 `512 × 4` 条胖值类型（路径 / argv / diff 摘要等字符串）加四个
        /// `Set<UUID>` 与一张 `emitted` 表就会变成化石键一直躺在字典里，直到引擎 `stop()`
        /// 调 `reset()`。`maxFactsPerKind` 管不住这种增长——它只约束单个键内的条数，
        /// 键的个数本身无界 ⇒ 驻留无界。64 个并发会话窗口已远超真实使用面（一台机器上
        /// 同时活跃的 Agent 会话是个位数量级），故给键的个数封顶，把驻留量变成常数上界。
        public var maxActiveWindows: Int

        /// 构造缓存策略（默认保留 10 分钟 / 每类最多 512 条 / 最多 64 个并发窗口，见 IFR §7）。
        public init(retention: TimeInterval = 600, maxFactsPerKind: Int = 512, maxActiveWindows: Int = 64) {
            self.retention = retention
            self.maxFactsPerKind = maxFactsPerKind
            self.maxActiveWindows = maxActiveWindows
        }

        /// 标准策略。
        public static let standard = BufferPolicy()
    }

    // MARK: - Immutable configuration

    /// 唯一的规则库。Engine 侧不再持有规则集合。
    public let assessor: RiskAssessor

    /// 注入的宿主 home 目录（规则内的敏感位置 / 越界判定用它展开 `~`，避免读 `NSHomeDirectory()`）。
    public let homeDirectory: String

    /// 注入的日历（非工作时间判定用）。
    public let calendar: Calendar

    /// 注入的阈值集合。
    public let thresholds: RiskThresholds

    /// 其它已知项目根（跨项目越界写判定用）；未注入时相关规则静默不命中（IFR §5.4）。
    public let otherProjectRoots: [String]

    /// 事实窗口缓存策略。
    public let bufferPolicy: BufferPolicy

    /// 本管道产出**落库文案**时使用的界面语言（IFR 裁定 2「写入时冻结」）。
    ///
    /// 只有这一个值决定新写入的行是什么语言；已入库的行永远不变（读侧不做翻译）。
    /// ⚠️ 与 `assessor.interfaceLanguage` **必须是同一个值**：批量路径从这里建窗口，
    /// 单事件路径在 `RiskAssessor` 内部建窗口，两处不同就会在同一批里写出中英两样行。
    /// 装配点 `ObservatoryEngine.Components.live` 负责传同一个。
    public let interfaceLanguage: AppLanguage

    // MARK: - Mutable state

    /// 单个会话键下的事实缓冲 + 已产出记录。
    private struct WindowState {
        var events: [TimelineEvent] = []
        var fileChanges: [FileChange] = []
        var commands: [CommandRecord] = []
        var samples: [PerformanceSample] = []
        /// 已产出 finding 的幂等键 → 其证据时间戳（用于滑出保留窗后允许再产出）。
        var emitted: [String: Date] = [:]
        var eventIDs = Set<UUID>()
        var changeIDs = Set<UUID>()
        var commandIDs = Set<UUID>()
        var sampleIDs = Set<UUID>()
        /// 本窗口最后一次被喂事实的时刻——由 `drain` 已算出的 `newest`（窗口内事实的最大
        /// 时间戳）赋值，**不是墙钟**。窗口总数封顶时用它挑淘汰对象。
        ///
        /// 单调不减（`retention ≥ 0` 时）：`newest` 自身按保留时长（age 0）与按条数
        /// （保留升序尾部）两条裁剪路径都必然留下，所以下一轮的 `newest` ≥ 本轮。
        var lastFedAt: Date?

        /// 四类事实是否都为空（「窗口空了就立刻摘掉」的判据；`emitted` 不算事实）。
        var hasFacts: Bool {
            !events.isEmpty || !fileChanges.isEmpty || !commands.isEmpty || !samples.isEmpty
        }
    }

    /// 全部可变状态：会话键 → 窗口状态。
    private let state = OSAllocatedUnfairLock(initialState: [String: WindowState]())

    // MARK: - Init

    /// 装配风险编排器。
    /// - Parameters:
    ///   - assessor: 规则库，默认四族拼装的 `RiskAssessor()`（`RiskRuleCatalog.standard`）。
    ///   - homeDirectory: 注入的宿主 home，默认取真实 `NSHomeDirectory()`（真机装配时可覆盖）。
    ///   - calendar: 注入的日历，默认 UTC + Gregorian。
    ///   - thresholds: 注入的阈值，默认 `RiskThresholds.standard`。
    ///   - otherProjectRoots: 已知其它项目根，用于跨项目越界写；默认空（该规则静默不命中）。
    ///   - bufferPolicy: 事实窗口缓存策略。
    public init(
        assessor: RiskAssessor = RiskAssessor(),
        homeDirectory: String = NSHomeDirectory(),
        calendar: Calendar = RiskFactWindow.gregorianUTC,
        thresholds: RiskThresholds = .standard,
        otherProjectRoots: [String] = [],
        bufferPolicy: BufferPolicy = .standard,
        interfaceLanguage: AppLanguage = .resolved()
    ) {
        self.interfaceLanguage = interfaceLanguage
        self.assessor = assessor
        self.homeDirectory = homeDirectory
        self.calendar = calendar
        self.thresholds = thresholds
        self.otherProjectRoots = otherProjectRoots
        self.bufferPolicy = bufferPolicy
    }

    // MARK: - RiskEvaluating

    /// 把一个单事件上下文汇入其会话窗口，评估窗口并产出**本次新增**的风险事件。
    ///
    /// 同一 finding 在其证据滑出保留窗之前不会重复产出；跨进程重放（如重启后重评同一批事实）
    /// 因确定性 id 而落到同一行，不会新增记录。
    public func evaluate(_ context: RiskContext) -> [RiskEvent] {
        let key = Self.windowKey(sessionID: context.sessionID, agentKind: context.agentKind)
        return state.withLock { buckets -> [RiskEvent] in
            var window = Self.takeWindow(forKey: key, from: &buckets)
            ingest(context, into: &window)
            return drain(buckets: &buckets, window: &window, forKey: key,
                         sessionID: context.sessionID, agentKind: context.agentKind)
        }
    }

    // MARK: - Sample feed

    /// 把一条性能采样汇入**同一个**会话窗口，评估并产出本次新增的风险事件。
    ///
    /// 存在的理由：`RiskContext`（契约，冻结）不携带采样，因此 `evaluate(_:)` 单入口
    /// 会让 `window.samples` 永远为空 —— `risk.pattern.sustained-cpu-peak` 与
    /// `risk.pattern.excessive-memory-peak`（资源滥用类，唯一以采样为输入的 2 条规则）
    /// 在生产里不可达。本方法是那两条规则的**唯一进料口**，由
    /// `ObservatoryEngine.ingestPerformance(store:at:)` 在每条采样落库后调用。
    ///
    /// 编排机器（窗口键 / 去重入窗 / 裁剪 / `RiskFactWindow` 组装 / `emitted` 幂等）
    /// 与 `evaluate(_:)` 完全共用 `drain(buckets:window:forKey:sessionID:agentKind:)`，
    /// 因此同一会话里采样与事件事实互相可见（例如高 CPU 采样与会话窗口同键），
    /// 且不会因两条路径各存一份节流表而刷屏。
    ///
    /// - Parameters:
    ///   - sample: 待汇入的性能采样（按其 `id` 去重，重复投递不重复计入）。
    ///   - sessionID: 该采样所属会话；与 `evaluate(_:)` 传同一值才能落进同一窗口。
    ///   - agentKind: 会话归属的 Agent 类型，用于回填产出事件的归属。
    @discardableResult
    public func noteSample(_ sample: PerformanceSample, sessionID: UUID?, agentKind: AgentKind) -> [RiskEvent] {
        let key = Self.windowKey(sessionID: sessionID, agentKind: agentKind)
        return state.withLock { buckets -> [RiskEvent] in
            var window = Self.takeWindow(forKey: key, from: &buckets)
            ingest(sample, into: &window)
            return drain(buckets: &buckets, window: &window, forKey: key,
                         sessionID: sessionID, agentKind: agentKind)
        }
    }

    /// 独占取回某键的窗口：`removeValue` 后返回的 `WindowState` 是其四类容器与 `emitted`
    /// 缓冲的**唯一**持有者，于是接下来的入窗 / 裁剪都在原缓冲上就地发生。
    ///
    /// 「读出来再改」（`buckets[key] ?? WindowState()`）会让本地副本与字典内那份共享缓冲，
    /// 第一次写入即把整个容器复制一遍——活跃窗口最坏是 512 条带路径 / argv / diff 摘要的
    /// 胖值类型加四个 `Set<UUID>`，每 tick 每键都付这个钱没有道理。
    /// 调用方（`drain`）负责在评估结束后**一次性**写回。
    private static func takeWindow(forKey key: String, from buckets: inout [String: WindowState]) -> WindowState {
        buckets.removeValue(forKey: key) ?? WindowState()
    }

    /// 两个入口共用的编排：空窗清理 → 裁剪 → 规则评估 → 按幂等键去重产出 → 窗口总数封顶。
    ///
    /// 调用方负责先把事实并入 `window`（并且是以 `takeWindow` 的独占方式取回的）；
    /// 本函数不负责入窗，因此两条进料路径不可能在节流与幂等上出现第二套语义。
    private func drain(
        buckets: inout [String: WindowState],
        window: inout WindowState,
        forKey key: String,
        sessionID: UUID?,
        agentKind: AgentKind
    ) -> [RiskEvent] {
        guard let newest = newestTimestamp(in: window) else {
            // 窗口内一条事实都没有（事件 / 文件变更 / 命令 / 采样全空）→ 不评估、不写回。
            // 键已被 `takeWindow` 从 `buckets` 摘走，因此「不写回」就是把空壳清掉。
            return []
        }
        prune(&window, now: newest)
        window.lastFedAt = newest
        guard window.hasFacts else {
            // 裁剪后四类数组全空 → 立刻摘掉键，不把空壳写回字典（化石驻留的另一半来源）。
            // 只有 `retention < 0` 或事实时间戳非有限才可能走到这里：`newest` 自己的 age 为 0，
            // 保留时长与条数两条裁剪路径都必然留下它。
            return []
        }

        let factWindow = makeWindow(from: window)
        let findings = assessor.assess(factWindow)

        var produced: [RiskEvent] = []
        produced.reserveCapacity(findings.count)
        for finding in findings {
            let idempotencyKey = key + "\u{1F}" + finding.id
            if window.emitted[idempotencyKey] != nil { continue }
            window.emitted[idempotencyKey] = finding.timestamp
            produced.append(event(from: finding, idempotencyKey: idempotencyKey,
                                  sessionID: sessionID, agentKind: agentKind))
        }
        // 产出记录随证据一起滑出保留窗，保证跨窗重评可再产出（时间簇起点变化 → 新键）。
        // 必须排在上面的节流判定**之后**：本轮仍视为「已产出」的过期键要先挡住，再丢弃。
        pruneEmitted(in: &window, now: newest)

        buckets[key] = window
        // 唯一的写回点。封顶淘汰发生在本轮产出已经算完、窗口已经写回之后，且永不淘汰 `key`
        // 本身 ⇒ 封顶不会让本次进料少产出一条 finding。
        enforceWindowCap(buckets: &buckets, protecting: key)
        return produced
    }

    /// 把窗口总数压回 `bufferPolicy.maxActiveWindows` 以内：淘汰「最久没再被喂事实」的键。
    ///
    /// - 参考时刻是 `WindowState.lastFedAt`（= 该窗口 `drain` 算出的 `newest`），不读墙钟。
    /// - 并列时按窗口键的**字典序**取最小者淘汰，因此结论与 `Dictionary` 的遍历顺序无关。
    /// - `protecting` 是本轮正在进料的键，永不被淘汰（`max(1, …)` 保证至少留得下它）。
    private func enforceWindowCap(buckets: inout [String: WindowState], protecting key: String) {
        let cap = max(1, bufferPolicy.maxActiveWindows)
        while buckets.count > cap {
            var victim: (key: String, fed: Date)?
            for (candidate, window) in buckets where candidate != key {
                // 理论上不会出现 nil（每个写回的窗口都设过 `lastFedAt`），兜底当最旧处理。
                let fed = window.lastFedAt ?? .distantPast
                let isVictim: Bool
                if let current = victim {
                    isVictim = fed < current.fed || (fed == current.fed && candidate < current.key)
                } else {
                    isVictim = true
                }
                if isVictim { victim = (candidate, fed) }
            }
            guard let victim else { break }   // 字典里只剩当前键——cap ≥ 1 时不可达
            buckets.removeValue(forKey: victim.key)
        }
    }

    /// 已加载规则的清单——转发给唯一的规则库（33 条 `risk.*` 描述符）。
    public func loadedRules() -> [RiskRuleDescriptor] {
        assessor.loadedRules()
    }

    /// 已加载规则条数（与 `loadedRules().count` 恒等）。
    public func ruleCount() -> Int {
        assessor.catalog.count
    }

    /// 清空全部会话窗口与产出记录（引擎停止 / 测试隔离时调用）。
    public func reset() {
        state.withLock { $0 = [:] }
    }

    // MARK: - Window key

    /// 窗口键：`sessionID.uuidString`；无会话时退化为 `kind:<agentKind.rawValue>`。
    public static func windowKey(sessionID: UUID?, agentKind: AgentKind) -> String {
        guard let sessionID else { return "kind:\(agentKind.rawValue)" }
        return sessionID.uuidString
    }

    // MARK: - Ingest

    /// 把上下文里的事实并入窗口（按 id 去重，保证多次投递同一事件不重复计入）。
    private func ingest(_ context: RiskContext, into window: inout WindowState) {
        if let event = context.event, !window.eventIDs.contains(event.id) {
            window.eventIDs.insert(event.id)
            window.events.append(event)
        }
        if let change = context.fileChange, !window.changeIDs.contains(change.id) {
            window.changeIDs.insert(change.id)
            window.fileChanges.append(change)
        }
        if let command = context.command, !window.commandIDs.contains(command.id) {
            window.commandIDs.insert(command.id)
            window.commands.append(command)
        }
    }

    /// 把一条性能采样并入窗口（按 id 去重）。
    private func ingest(_ sample: PerformanceSample, into window: inout WindowState) {
        guard !window.sampleIDs.contains(sample.id) else { return }
        window.sampleIDs.insert(sample.id)
        window.samples.append(sample)
    }

    // MARK: - Pruning

    /// 窗口内事实的最大时间戳，作为「当前时刻」用于裁剪（不读墙钟）。
    private func newestTimestamp(in window: WindowState) -> Date? {
        var newest: Date?
        func bump(_ date: Date) { if newest == nil || date > newest! { newest = date } }
        for event in window.events { bump(event.timestamp) }
        for change in window.fileChanges { bump(change.timestamp) }
        for command in window.commands { bump(command.startedAt) }
        for sample in window.samples { bump(sample.timestamp) }
        return newest
    }

    /// 按保留时长与各类型上限裁剪窗口。
    ///
    /// 先零分配地判断「有没有东西要丢」，没有就原样保留该容器（不重建数组、不打断就地性）。
    /// 需要裁剪时的口径与旧实现**逐元素、逐顺序一致**（见 `pruneKind`）。
    /// `emitted` 不在此处裁剪——它的丢弃必须排在节流判定之后，见 `drain`。
    private func prune(_ window: inout WindowState, now: Date) {
        let retention = bufferPolicy.retention
        let limit = max(1, bufferPolicy.maxFactsPerKind)
        pruneKind(&window.events, key: \TimelineEvent.timestamp, now: now, retention: retention, limit: limit, ids: &window.eventIDs)
        pruneKind(&window.fileChanges, key: \FileChange.timestamp, now: now, retention: retention, limit: limit, ids: &window.changeIDs)
        pruneKind(&window.commands, key: \CommandRecord.startedAt, now: now, retention: retention, limit: limit, ids: &window.commandIDs)
        pruneKind(&window.samples, key: \PerformanceSample.timestamp, now: now, retention: retention, limit: limit, ids: &window.sampleIDs)
    }

    /// 裁剪一类事实，语义逐元素等价于旧的一行式 `items.filter { 未过期 }` + `trimmed`：
    ///  1. 丢掉已滑出保留窗者（判据取 `kept`，其否定式即旧 `filter` 的丢弃分支）；
    ///  2. 剩余仍超 `limit` 条时，按时间升序排序后保留尾部 `limit` 条，
    ///     并把被丢弃事实的 id 从去重集合里移除（见 `trimmed`）。
    ///
    /// 快路径：既无过期项、条数又没超上限时**直接返回**，一次分配都不做——
    /// 这是每个 tick 每条进料都会走到的分支。
    private func pruneKind<T>(
        _ items: inout [T],
        key: KeyPath<T, Date>,
        now: Date,
        retention: TimeInterval,
        limit: Int,
        ids: inout Set<UUID>
    ) {
        let hasExpired = items.contains { !kept($0[keyPath: key], now: now, retention: retention) }
        guard hasExpired || items.count > limit else { return }
        let keptItems: [T] = hasExpired
            ? items.filter { kept($0[keyPath: key], now: now, retention: retention) }
            : items
        items = trimmed(keptItems, key: key, limit: limit, ids: &ids)
    }

    /// 一条时间戳是否仍在保留窗内。判据与旧实现的 `filter` 逐字相同（`<=`），
    /// 因此「探针 + 复用原数组」与「无条件 filter」对任意输入（含非有限时间戳）结论一致。
    private func kept(_ date: Date, now: Date, retention: TimeInterval) -> Bool {
        now.timeIntervalSince(date) <= retention
    }

    /// 产出记录的裁剪：与事实同样先零分配地判断有没有过期项，没有就不重建字典。
    private func pruneEmitted(in window: inout WindowState, now: Date) {
        let retention = bufferPolicy.retention
        guard window.emitted.contains(where: { !kept($0.value, now: now, retention: retention) }) else { return }
        window.emitted = window.emitted.filter { kept($0.value, now: now, retention: retention) }
    }

    /// 保留最近 `limit` 条（按时间升序尾部），并把被丢弃事实的 id 从去重集合里移除，
    /// 以免其将来再次出现时被误判为重复而永不入窗。
    private func trimmed<T>(_ items: [T], key: KeyPath<T, Date>, limit: Int, ids: inout Set<UUID>) -> [T] {
        guard items.count > limit else { return items }
        let ordered = items.sorted { $0[keyPath: key] < $1[keyPath: key] }
        let dropped = ordered.prefix(items.count - limit)
        for item in dropped {
            if let id = Self.factID(item) { ids.remove(id) }
        }
        return Array(ordered.suffix(limit))
    }

    /// 从任一事实类型取出其 `id`（用于去重集合的清理）。
    private static func factID(_ fact: Any) -> UUID? {
        switch fact {
        case let event as TimelineEvent: return event.id
        case let change as FileChange: return change.id
        case let command as CommandRecord: return command.id
        case let sample as PerformanceSample: return sample.id
        default: return nil
        }
    }

    // MARK: - Window assembly

    /// 由窗口状态组装 `RiskFactWindow`（起止时间由事实派生；home / 日历 / 阈值 / 越界根注入）。
    private func makeWindow(from window: WindowState) -> RiskFactWindow {
        RiskFactWindow(
            events: window.events,
            fileChanges: window.fileChanges,
            commands: window.commands,
            samples: window.samples,
            homeDirectory: homeDirectory,
            allowedWriteRoots: collectWriteRoots(in: window),
            trustedWriteRoots: [],
            calendar: calendar,
            thresholds: thresholds,
            telemetryClassifications: [:],
            otherProjectRoots: otherProjectRoots,
            interfaceLanguage: interfaceLanguage
        )
    }

    /// 允许写入根：取窗口内各事实携带的非空 `projectPath`，按出现顺序去重。
    private func collectWriteRoots(in window: WindowState) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        func add(_ candidate: String?) {
            guard let root = candidate, !root.isEmpty, !seen.contains(root) else { return }
            seen.insert(root)
            roots.append(root)
        }
        for event in window.events { add(event.projectPath) }
        for change in window.fileChanges { add(change.projectPath) }
        for command in window.commands { add(command.projectPath) }
        return roots
    }

    // MARK: - Event assembly

    /// 把一条命中降级为契约 `RiskEvent`，并盖上确定性 id 与（必要时）从进料口回填的会话归属。
    ///
    /// 回填是必需的：`RiskFactWindow.sessionID` / `agentKind` 只从会话与事件事实推导，
    /// 采样单独构成的窗口拿不到归属，因此由调用方（`evaluate(_:)` 的上下文 /
    /// `noteSample(_:sessionID:agentKind:)` 的显式入参）补上。
    private func event(
        from finding: RiskFinding,
        idempotencyKey: String,
        sessionID: UUID?,
        agentKind: AgentKind
    ) -> RiskEvent {
        var event = finding.riskEvent()
        event.id = Self.stableID(from: idempotencyKey)
        if event.sessionID == nil { event.sessionID = sessionID }
        if event.agentKind == .unknown { event.agentKind = agentKind }
        return event
    }

    /// 由字符串派生确定性 UUID：两次独立 FNV-1a 64 拼成 128 位（不依赖进程随机的 `hashValue`）。
    static func stableID(from text: String) -> UUID {
        let bytes = Array(text.utf8)
        let high = fnv1a64(bytes, seed: 0xcbf2_9ce4_8422_2325)
        let low = fnv1a64(bytes, seed: 0x9dc4_d9c2_ac4b_4e6b)
        var raw = [UInt8](repeating: 0, count: 16)
        for index in 0..<8 {
            raw[index] = UInt8(truncatingIfNeeded: high >> (8 * (7 - index)))
            raw[index + 8] = UInt8(truncatingIfNeeded: low >> (8 * (7 - index)))
        }
        return raw.withUnsafeBytes { $0.loadUnaligned(as: UUID.self) }
    }

    /// FNV-1a 64 位散列。
    private static func fnv1a64(_ bytes: [UInt8], seed: UInt64) -> UInt64 {
        let prime: UInt64 = 0x0000_0100_0000_01b3
        var hash = seed
        for byte in bytes {
            hash ^= UInt64(byte)
            hash = hash &* prime
        }
        return hash
    }

    // MARK: - Introspection (for tests)

    /// 当前窗口内某键缓存的事实总数（事件 + 文件变更 + 命令 + 采样），供测试断言窗口裁剪行为。
    public func factCount(forKey key: String) -> Int {
        state.withLock { buckets in
            guard let window = buckets[key] else { return 0 }
            return window.events.count + window.fileChanges.count + window.commands.count + window.samples.count
        }
    }

    /// 当前驻留的会话窗口个数，供测试断言窗口总数封顶（`BufferPolicy.maxActiveWindows`）
    /// 与化石键回收：长期高于该值即说明「键的个数无界 ⇒ 驻留无界」又回来了。
    public func activeWindowCount() -> Int {
        state.withLock { $0.count }
    }
}
