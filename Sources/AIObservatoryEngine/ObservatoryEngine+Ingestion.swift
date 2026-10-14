//
//  ObservatoryEngine+Ingestion.swift
//  AIObservatoryEngine
//
//  Owner: WS-Engine（由 ObservatoryEngine.swift 原样搬来：只按职责分文件，行为未变。）
//

import Foundation
import os
import CryptoKit
import AIObservatoryCore
import AIObservatoryRiskRules   // 装配点要直接构造 RiskAssessor（语言要同源）
import AIObservatoryStore
import AIObservatoryPlatform

extension ObservatoryEngine {

    // MARK: - Agent / Session ingest

    func ingestAgents(
        _ agents: [AgentInstance],
        store: ObservatoryStore,
        at now: Date
    ) async throws {
        // 先把文件计数与行数对平，再跑 `sync`：`sync` 可能就地结算某条会话（超时 / pid 复用 /
        // 缺席满宽限），而结算出来的 `modified/created/deletedFileCount` 与 `hasEvidence`
        // （判 `.success` 还是 `.unknown`）都读这三列。顺序反过来，
        // 最后一批在途的行就会以「没发生」的姿态被结算掉。
        await settleFileChangeCredits(store: store, flushingBuffer: true)
        // #86：命令那两列同理——`sync` 可能当场结算会话，结算写出去的就是这两列，
        // 所以必须在它之前先按行数对平（顺序反过来会以"没发生"的姿态被结算）。
        await settleCommandCredits(store: store, flushingBuffer: true)

        let sessionResult = await components.lifecycle.sync(agents: agents, at: now)

        // 本轮要结算的会话必须先保住其 Agent 快照，否则「运行很久后退出」的 Agent
        // 会因为 TTL 淘汰而丢掉 agentStopped 事件。
        cache(agents: agents, keepAgentIDs: Set(sessionResult.closed.compactMap(\.agentID)))
        refreshFileObservation(agents: agents)
        try await store.upsertAgents(agents)

        let settlements = deduplicatedSessions(sessionResult.opened + sessionResult.updated + sessionResult.closed)
        if !settlements.isEmpty {
            try await store.upsertSessions(settlements)
        }

        for session in sessionResult.opened {
            guard let agent = agentSnapshot(for: session) else { continue }
            let event = components.aggregator.agentStarted(agent, at: now)
            await store.append(event)
            broadcast(.timelineEvent(event))
        }
        for session in sessionResult.closed {
            guard let event = agentStoppedEvent(for: session, at: now) else { continue }
            await store.append(event)
            broadcast(.timelineEvent(event))
            await settleOpenCommands(store: store, session: session, fallbackEnd: now)
        }

        let pushed = sessionResult.opened + sessionResult.closed
        if !pushed.isEmpty { broadcast(.sessions(pushed)) }
        broadcast(.agents(agents))
    }

    func agentStoppedEvent(for session: AgentSession, at now: Date) -> TimelineEvent? {
        guard let agent = agentSnapshot(for: session) else { return nil }
        return components.aggregator.agentStopped(agent, at: now)
    }

    /// 会话收口时，把它名下**仍未闭合**的命令一并收口成 `.terminated`（随进程结束、退出码未知）。
    ///
    /// 为什么必须挂在**每 tick 的收口路径**上，而不是只挂在引擎停止时：
    /// 引擎通常连续开好几天，而 Agent 退出是常态、引擎停止是罕见事件。
    /// 只在停止时收口 ⇒ 绝大多数命令会永远挂着 `outcome = running`
    /// （真机实测三个独立库里 236/236 条全是这个形状，需求④ 的「结果 / 耗时」因此是 0% 覆盖）。
    ///
    /// ⚠️ 两条口径红线：
    /// 1. `.terminated` **不等于**成功也**不等于**失败——没有 shell hook 就不知道退出码，
    ///    成败类聚合必须继续排除它（`CommandResultReader.isResolved` 的口径）。
    /// 2. `endedAt` 取该 Agent **最后一次可见**的时刻 ⇒ 算出来的耗时是**上界**
    ///    （最坏高估一个扫描周期），UI 不许显示成精确值。
    func settleOpenCommands(
        store: any ObservatoryWriting,
        session: AgentSession,
        fallbackEnd: Date
    ) async {
        let endedAt = agentSnapshot(for: session)?.lastSeenAt ?? fallbackEnd
        do {
            // 命令走缓冲写入通道：不先 flush，这条 UPDATE 会漏掉还没落盘的插入。
            await store.flush()
            let settled = try await store.terminateOpenCommands(
                agentID: session.agentID,
                sessionID: session.id,
                outcome: .terminated,
                endedAt: endedAt
            )
            if settled > 0 {
                ObservatoryLog.engine.info(
                    "settled \(settled, privacy: .public) open commands as terminated"
                )
            }
        } catch {
            ObservatoryLog.engine.error(
                "command settlement failed: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func cache(agents: [AgentInstance], keepAgentIDs: Set<UUID> = []) {
        let cutoff = Date().addingTimeInterval(-Self.snapshotTTL)
        mutable.withLock { state in
            state.agents = agents
            for agent in agents { state.agentSnapshots[agent.id] = agent }
            let live = Set(agents.map(\.id))
            state.agentSnapshots = state.agentSnapshots.filter {
                keepAgentIDs.contains($0.key) || live.contains($0.key) || $0.value.lastSeenAt >= cutoff
            }
        }
    }

    func agentSnapshot(for session: AgentSession) -> AgentInstance? {
        guard let agentID = session.agentID else { return nil }
        return mutable.withLock { $0.agentSnapshots[agentID] }
    }

    func deduplicatedSessions(_ sessions: [AgentSession]) -> [AgentSession] {
        var seen = Set<UUID>()
        var result: [AgentSession] = []
        for session in sessions where !seen.contains(session.id) {
            seen.insert(session.id)
            result.append(session)
        }
        return result
    }

    // MARK: - Commands

    func ingestCommands(
        records: [ProcessRecord],
        agents: [AgentInstance],
        store: ObservatoryStore,
        since: Date,
        at now: Date
    ) async throws {
        let inferred = components.commandAuditor.inferCommands(processes: records, agents: agents, since: since)
        for record in inferred {
            let sessionID = await sessionID(forAgentID: record.agentID) ?? record.sessionID
            var command = record
            command.sessionID = sessionID
            // 项目根由 mapper 判定；判不出来就留 nil（审计器给的 cwd 不是项目根，不能混用口径）。
            command.projectPath = components.projectMapper.projectPath(for: record.workingDirectory)

            await store.append(command)
            broadcast(.command(command))

            if let updated = await components.lifecycle.record(command: command) {
                try await store.upsertSessions([updated])
            }

            let event = components.aggregator.event(for: command, riskLevel: command.riskLevel)
            await store.append(event)
            broadcast(.timelineEvent(event))

            await evaluateRisk(RiskContext(
                event: event,
                command: command,
                fileChange: nil,
                agentKind: command.agentKind,
                sessionID: sessionID,
                recentFileChangeCount: 0
            ), store: store)
        }
    }

    func sessionID(forAgentID agentID: UUID?) async -> UUID? {
        guard let agentID else { return nil }
        return await components.lifecycle.sessionID(forAgentID: agentID)
    }

    // MARK: - Performance

    func ingestPerformance(store: ObservatoryStore, at now: Date) async throws {
        let agents = mutable.withLock { $0.agents }
        await store.append(await components.metrics.sampleSystem())
        guard !agents.isEmpty else { return }

        let pids = Set(agents.flatMap { [$0.pid] + $0.childPIDs }).sorted()
        let samples = await components.metrics.sampleProcesses(pids: pids)
        // 一条会话样本 = **同一时刻**「该 Agent ∪ 归属它的子孙进程」的用量之和。
        //
        // 为什么必须带上子孙：Claude Code / Codex 这类 Agent 的活全在子 shell / node 进程里，
        // 父进程几乎闲置。只报父进程会让「每个 AI Session 的性能」（需求⑤）系统性低报，
        // 而界面按会话口径写数——数字真实、对象错。
        //
        // 峰值与均值的口径就藏在这个「同一时刻」里：`SessionLifecycleManager.peaks` 取的是
        // 采样本内单字段最大值，所以**每行必须先求和**，`max(逐时刻之和)` 才是会话峰值；
        // 若改成「各进程峰值之和」会拼出一个从未同时发生过的数（10%+20% 记成 30%）。
        // 均值同理：`cpuSeconds = Σ cpu%×Δt` 用的也是逐时刻之和，不是各进程均值再相加。
        let owned = ownedByAgent(pids: pids, agents: agents)

        for agent in agents {
            // 锚点读不到就不落行：宁缺不造（补一个 0 会被规则读成「这一轮真的没用 CPU」）。
            guard let anchor = samples[agent.pid] else { continue }
            var cpuPercent = anchor.cpuPercent
            var memoryBytes = anchor.memoryBytes
            for pid in owned[agent.id] ?? [] {
                guard let child = samples[pid] else { continue }
                cpuPercent += child.cpuPercent
                memoryBytes += child.memoryBytes
            }
            let sessionID = await components.lifecycle.sessionID(forAgentID: agent.id)
            let sample = PerformanceSample(
                timestamp: now,
                sessionID: sessionID,
                agentID: agent.id,
                cpuPercent: cpuPercent,
                memoryBytes: memoryBytes
            )
            await store.append(sample)
            broadcast(.performance(sample))

            if let updated = await components.lifecycle.record(performanceSample: sample) {
                try await store.upsertSessions([updated])
            }

            // 资源滥用类规则（持续 CPU 高峰 / 内存峰值超限）只看得到 `RiskFactWindow.samples`，
            // 而契约 `RiskContext` 不携带采样 —— 采样落库后必须汇入同一个会话窗口，
            // 否则这两条规则在生产里恒不触发（`RiskPipeline.noteSample` 的存在理由）。
            await recordRisks(
                components.riskPipeline.noteSample(sample, sessionID: sessionID, agentKind: agent.kind),
                store: store
            )
        }
    }

    /// pid → 该记给哪个 Agent：**最近**的那个主人（子树最深者）。
    ///
    /// 嵌套 Agent（Agent 又拉起一个 Agent）时各家的 `childPIDs` 会重叠。若按「凡包含即计入」
    /// 求和，同一份 CPU 会被父、子两条会话各算一遍，全局总量虚高一倍。命令审计用的是同一个
    /// 口径（`CommandInferenceEngine` 取父链上最近的 Agent），这里与它保持一致。
    ///
    /// 返回值刻意**不含** Agent 自己的 pid——那条由锚点单独计入，避免加两遍。
    func ownedByAgent(pids: [Int32], agents: [AgentInstance]) -> [UUID: [Int32]] {
        // Agent 自身的深度 = 它落在多少个别的 Agent 的子树里；越深越靠近被采样的进程。
        var depth: [UUID: Int] = [:]
        for agent in agents {
            depth[agent.id] = agents.reduce(0) { acc, other in
                acc + ((other.id != agent.id && other.childPIDs.contains(agent.pid)) ? 1 : 0)
            }
        }
        var owned: [UUID: [Int32]] = [:]
        for pid in pids {
            var best: AgentInstance?
            for agent in agents where agent.pid == pid || agent.childPIDs.contains(pid) {
                guard let current = best else { best = agent; continue }
                let lhs = depth[agent.id] ?? 0
                let rhs = depth[current.id] ?? 0
                // 深度优先；并列时按 pid 定序，保证同一份输入永远得到同一张归属表。
                if lhs > rhs || (lhs == rhs && agent.pid < current.pid) { best = agent }
            }
            if let agent = best, agent.pid != pid {
                owned[agent.id, default: []].append(pid)
            }
        }
        return owned
    }

    // MARK: - File observation

    /// 监控根 = 显式配置 ∪ 由已识别 Agent 的 cwd 推导；集合变化时重启观测。
    func refreshFileObservation(agents: [AgentInstance]) {
        let scope = monitoringRoots.resolveScope(
            explicit: settings.monitoredRoots, agents: agents, now: Date()
        )
        let roots = scope.keptRoots
        monitoringScopeBox.withLock { $0 = scope }
        let changed = mutable.withLock { state -> Bool in
            if state.observedRoots == roots { return false }
            state.observedRoots = roots
            return true
        }
        guard changed else { return }

        observer.withLock { task in
            task?.cancel()
            task = nil
        }
        guard !roots.isEmpty else {
            ObservatoryLog.files.info("no monitoring roots; file tracking idle")
            return
        }
        let stream: AsyncStream<RawFileSystemEvent>
        do {
            stream = try components.fileObserver.startObserving(
                roots: roots.map { URL(fileURLWithPath: $0) },
                ignoredPatterns: settings.ignoredPathPatterns
            )
        } catch {
            ObservatoryLog.files.error("file observer unavailable: \(error.localizedDescription, privacy: .public)")
            return
        }
        let task = Task { [weak self] in
            for await event in stream {
                if Task.isCancelled { break }
                await self?.ingestFileEvent(event)
            }
        }
        observer.withLock { $0 = task }
    }

    func ingestFileEvent(_ raw: RawFileSystemEvent) async {
        let store: ObservatoryStore
        do {
            store = try await readyStore()
        } catch {
            ObservatoryLog.files.error("file event dropped: \(error.localizedDescription, privacy: .public)")
            return
        }
        let (attributed, gap) = attributedAgent(forPath: raw.path)
        // 处理过**任何**一条文件事件就建账——哪怕这一条归上了、一个机制都没记。
        // 否则"归因率 100 %"与"引擎还没跑过"在读数上长得一样，界面只能把前者说成后者。
        // 只在"确实没归上"时记一笔：归上了的不进任何一格（恒等式 Σcounts == 未归属行数 靠这个方向成立）。
        mutable.withLock { box in
            var counts = box.attributionCounts ?? [:]
            if let gap { counts[gap, default: 0] += 1 }
            box.attributionCounts = counts
        }
        let sessionID = await sessionID(forAgentID: attributed?.id)
        let projectPath = components.projectMapper.projectPath(for: raw.path)
        let (change, diff, snapshot) = await makeFileChange(
            from: raw, agent: attributed, sessionID: sessionID, projectPath: projectPath
        )

        do {
            await store.append(change)
            if let diff {
                try await store.record(diff, forChangeID: change.id)
            }
            if let snapshot {
                try await store.recordSnapshot(snapshot)
            }
            broadcast(.fileChange(change))

            // ⚠️ 这里**不**给会话的三列文件计数 +1（#78）。
            // `store.append(change)` 走 `BatchWriter`：它返回只说明语句进了缓冲，不说明这一行在库里。
            // 原来就在这一步 `record(fileChange:)` 自增，于是丢语句时列值虚高——
            // 真库实测会话 #2 `modified_file_count = 19` 而按 `session_id` 数出的 modified 行是 18。
            // 现在这一步只挂一笔欠账（`stage`），三列由 `recountFileCountsFromRows` 按
            // `file_changes` 的真实行数赋值；写入通道那句"排空了"不是收账凭据，见它的注释。
            if let staged = await components.lifecycle.stage(
                fileChange: change, agentKind: change.agentKind
            ), let updated = staged.snapshot {
                try await store.upsertSessions([updated])
            }
            // 顺带问一次写入通道：上一批要是已经落定，这一轮的计数当场就追平（不催提交）。
            await settleFileChangeCredits(store: store, flushingBuffer: false)
            await settleCommandCredits(store: store, flushingBuffer: false)

            let event = components.aggregator.event(for: change)
            await store.append(event)
            broadcast(.timelineEvent(event))

            // 批量删除等跨事件聚合已由 `RiskPipeline` 的每会话事实窗口负责，
            // 这里不再预先向 DB 数删除条数（`recentFileChangeCount` 依 IFR §5.2 退役）。
            await evaluateRisk(RiskContext(
                event: event,
                command: nil,
                fileChange: change,
                agentKind: change.agentKind,
                sessionID: sessionID
            ), store: store)
        } catch {
            noteTickFailure(why: "file change persistence failed: \(error.localizedDescription)")
        }
    }

    /// 把会话的三个文件计数**按真正入库的行**改写一遍（#78 的落点）。
    ///
    /// 口径一句话：那三列只有一处能写，写进去的必须是 `file_changes` 数出来的行数——
    /// 行在库里列就在库里，行没落库列就不许动，同成同败。
    /// `SessionLifecycleManager` 不认识 Store，所以这里每轮把写入通道的观测（`batchStats()`）
    /// 喂给它，换回「哪些会话现在该改写了」，再逐条去数三类行数。
    ///
    /// ⚠️ 观测**不参与取值**：`pendingCount == 0` 只说明缓冲没排队，不说明事务跑完了
    /// （`BatchWriter.commitBuffer()` 先换出缓冲、再 await 另一个 actor，那一段在途窗口里
    /// 丢弃也还没记账）。所以「排空且没丢」当年直接 `+1` 的那条快路被删掉了：
    /// 一旦那一窗口的行最终没落库，列就永久虚高，而账已销、再没人去数那三列——真库的 19 vs 18。
    /// 现在这条路径上唯一的数来自 SQL。
    ///
    /// 代价：静默机器上 `hasStagedFileChanges` 恒 false，第一行 guard 就返回；
    /// 有在途行时多两次 `batchStats()` 读（纯内存计数，不发 SQL）+ 每个待对平会话三条
    /// `COUNT(*)`（`session_id` 与 `kind` 都过索引位，见 `fileChangeRowCount` 的注释），
    /// 只在"确实有文件行没对上账"的那几轮发生，一轮对上就收账，不是每 tick 的固定开销。
    ///
    /// - Parameter flushingBuffer: 只在「再不排空就没人替我们回答」的边界给 true
    ///   （每 tick 开头，紧接着 `sync` 可能要结算会话）。文件事件那一路给 false：
    ///   一次批量编辑若每条都催提交，就退化成「一条语句一次事务」，违反 AGENTS §6 的攒批预算。
    func settleFileChangeCredits(store: ObservatoryStore, flushingBuffer: Bool) async {
        guard await components.lifecycle.hasStagedFileChanges else { return }
        do {
            var stats = await store.batchStats()
            if flushingBuffer, stats.pendingCount > 0 {
                await store.flush()
                stats = await store.batchStats()
            }
            // 缓冲还排着队也照样把观测交进去（丢弃基准要照常推进，额度先攒着），
            // 只是 manager 会回一个空表：这会儿数出来的行数必然偏低。
            let recounts = await components.lifecycle.fileCountRecountsRequired(
                observation: .init(
                    bufferDrained: stats.pendingCount == 0,
                    droppedStatementCount: stats.droppedStatementCount
                )
            )
            for sessionID in recounts {
                try await recountFileCountsFromRows(sessionID: sessionID, store: store)
            }
        } catch {
            noteTickFailure(why: "file count reconciliation failed: \(error.localizedDescription)")
        }
    }

    /// 三列以 `file_changes` 的**真实行数**为准改写——这是这三列唯一的写入路径（#78）。
    ///
    /// 为什么不能用自增：内存里那条"投了几次"的账既可能被丢弃的语句弄脏，也可能被
    /// 尚未跑完的事务蒙住（`pendingCount == 0` 的在途窗口），只有数行数才是答案。
    /// 会话已经结算时内存里没有它的快照 ⇒ 读回库里那一行、只改这三列再写回去
    /// （`upsertSessions` 是全列覆盖，所以必须基于读回来的行改，不能凭内存造）。
    func recountFileCountsFromRows(sessionID: UUID, store: ObservatoryStore) async throws {
        let created = try await fileChangeRowCount(store, sessionID: sessionID, kind: .created)
        let modified = try await fileChangeRowCount(store, sessionID: sessionID, kind: .modified)
        let deleted = try await fileChangeRowCount(store, sessionID: sessionID, kind: .deleted)

        // 先交回 manager：收账判据（欠的行追平了没有）在它那里，两条分支都得走这一步。
        if let open = await components.lifecycle.applyFileCounts(
            sessionID: sessionID, created: created, modified: modified, deleted: deleted
        ) {
            try await store.upsertSessions([open])
            broadcast(.sessions([open]))
            return
        }
        guard var settled = try await store.session(id: sessionID),
              settled.createdFileCount != created
                || settled.modifiedFileCount != modified
                || settled.deletedFileCount != deleted
        else { return }
        settled.createdFileCount = created
        settled.modifiedFileCount = modified
        settled.deletedFileCount = deleted
        try await store.upsertSessions([settled])
        broadcast(.sessions([settled]))
    }

    /// 某会话名下指定 `kind` 的 `file_changes` 行数。
    /// `Page.totalCount` 是 `COUNT(*)`，与 `limit` 无关 ⇒ 取 1 条即可，不把行搬进内存。
    func fileChangeRowCount(
        _ store: ObservatoryStore, sessionID: UUID, kind: FileChangeKind
    ) async throws -> Int {
        let page = try await store.fileChanges(
            matching: FileChangeQuery(kinds: [kind], sessionID: sessionID, limit: 1)
        )
        return page.totalCount
    }

    // MARK: - Command counts（#86：这两列只能来自 `commands` 的行数）

    /// 某会话名下的 `commands` 行数。`Page.totalCount` 就是 `COUNT(*)`、与 `limit` 无关
    /// ⇒ 取 1 条即可，不把行搬进内存（与 `fileChangeRowCount` 同一把尺）。
    func commandRowCount(
        _ store: ObservatoryStore, sessionID: UUID,
        outcomes: Set<CommandOutcome> = [], nonZeroExitCode: Bool = false
    ) async throws -> Int {
        let page = try await store.commands(
            matching: CommandQuery(sessionID: sessionID, outcomes: outcomes,
                                   withNonZeroExitCode: nonZeroExitCode, limit: 1)
        )
        return page.totalCount
    }

    /// 引擎侧的「失败」取数口径：**两次 COUNT 的容斥**，不是一条 CASE WHEN。
    ///
    /// `失败 = #(outcome = .failure) + #(outcome ≠ .failure ∧ exit_code ≠ 0)`。
    /// 第二次的 `outcome ≠ .failure` 用全部案名的补集表达（`CommandOutcome: CaseIterable`），
    /// 于是"什么算失败"这条规则仍然只有一份判据（`SessionLifecycleManager.isFailure`），
    /// 不必把它的 SQL 影子抄进三个后端 —— 抄一份就分叉一次，那正是本仓头号缺陷族。
    func failedCommandRowCount(
        _ store: ObservatoryStore, sessionID: UUID
    ) async throws -> Int {
        let byOutcome = try await commandRowCount(store, sessionID: sessionID, outcomes: [.failure])
        let byExitOnly = try await commandRowCount(
            store, sessionID: sessionID,
            outcomes: Set(CommandOutcome.allCases).subtracting([.failure]),
            nonZeroExitCode: true
        )
        return byOutcome + byExitOnly
    }

    /// 问一次写入通道，然后把欠着的那几个会话的两列按行数改写（与文件那一头并排跑）。
    func settleCommandCredits(store: ObservatoryStore, flushingBuffer: Bool) async {
        guard await components.lifecycle.hasStagedCommandCounts else { return }
        do {
            var stats = await store.batchStats()
            if flushingBuffer, stats.pendingCount > 0 {
                await store.flush()
                stats = await store.batchStats()
            }
            let recounts = await components.lifecycle.commandCountRecountsRequired(
                observation: .init(
                    bufferDrained: stats.pendingCount == 0,
                    droppedStatementCount: stats.droppedStatementCount
                )
            )
            for sessionID in recounts {
                try await recountCommandCountsFromRows(sessionID: sessionID, store: store)
            }
        } catch {
            noteTickFailure(why: "command count reconciliation failed: \(error.localizedDescription)")
        }
    }

    /// 两列以 `commands` 的真实行数为唯一来源（#86）。会话已结算时内存里没有它的快照
    /// ⇒ 读回库里那一行、只改这两列再写回去（`upsertSessions` 是全列覆盖，不能凭内存造）。
    func recountCommandCountsFromRows(sessionID: UUID, store: ObservatoryStore) async throws {
        let total = try await commandRowCount(store, sessionID: sessionID)
        let failed = try await failedCommandRowCount(store, sessionID: sessionID)

        if let open = await components.lifecycle.applyCommandCounts(
            sessionID: sessionID, total: total, failed: failed
        ) {
            try await store.upsertSessions([open])
            broadcast(.sessions([open]))
            return
        }
        guard var settled = try await store.session(id: sessionID),
              settled.commandCount != total || settled.failedCommandCount != failed
        else { return }
        settled.commandCount = total
        settled.failedCommandCount = failed
        try await store.upsertSessions([settled])
        broadcast(.sessions([settled]))
    }

    /// 组装 `FileChange`，并为文本的「新建 / 修改」算出可溯源的 diff。
    ///
    /// 改前内容来自 `textBaselines`（该路径上一次被观测到时留的底）；没有底可比的
    /// 两种情形——首次观测、以及新建（本来就不存在上一版）——出**单边 diff** 并标
    /// `.unavailableFirstSighting`，由呈现层照实说明，绝不留空白面板。
    ///
    /// 行上的增删计数只在「真的有两端可比」或「本来就是新建」时才填：不可比时把全文行数
    /// 当增量，等于拿旧内容冒充本次编辑的产出，会话与项目的「代码增长」会跟着一起失真。
    ///
    /// - Returns: 变更行、可空 diff，以及可空的**内容快照**——只有用户关掉了 diff 明文
    ///   才会有，用途是「正文不存了，但这份内容仍可被事后核对」。
    func makeFileChange(
        from raw: RawFileSystemEvent,
        agent: AgentInstance?,
        sessionID: UUID?,
        projectPath: String?
    ) async -> (change: FileChange, diff: FileDiff?, snapshot: FileSnapshot?) {
        let isText = !raw.isDirectory && Self.isTextFile(raw.path)
        var change = FileChange(
            path: raw.path,
            previousPath: raw.previousPath,
            kind: raw.kind,
            timestamp: raw.timestamp,
            agentID: agent?.id,
            sessionID: sessionID,
            agentKind: agent?.kind ?? .unknown,
            sizeBytes: raw.sizeBytes,
            previousSizeBytes: nil,
            isText: isText,
            linesAdded: 0,
            linesRemoved: 0,
            riskLevel: .low,
            projectPath: projectPath
        )
        // 留底要跟着文件的存在形态走，与是不是文本、能不能算 diff 无关。
        switch raw.kind {
        case .deleted:
            textBaselines.withLock { $0.forget(path: raw.path) }
        case .renamed:
            if let previousPath = raw.previousPath {
                textBaselines.withLock { $0.move(from: previousPath, to: raw.path) }
            }
        case .created, .modified, .unknown:
            break
        }
        guard isText, raw.kind == .created || raw.kind == .modified else { return (change, nil, nil) }
        guard let newText = await components.snapshotter.readTextSnippet(path: raw.path, maxBytes: Self.maxSnippetBytes) else {
            return (change, nil, nil)
        }

        // 新建没有「上一版」这回事，连查都不查：查了会把同路径的旧残留当成可比基线。
        let previous = raw.kind == .created ? nil : textBaselines.withLock { $0.baseline(forPath: raw.path) }
        textBaselines.withLock { $0.remember(newText, observedAt: raw.timestamp, forPath: raw.path) }

        let diff = components.differ.diff(
            oldText: previous?.text,
            newText: newText,
            path: raw.path,
            changeKind: raw.kind
        )
        var recorded = diff
        recorded.baselineSource = previous == nil ? .unavailableFirstSighting : .lastObserved
        recorded.baselineCapturedAt = previous?.observedAt
        // 读进来的本来就可能只是前 `maxSnippetBytes`（`FileSnapshotter` 到量就停，不报错）。
        // 这种 diff 的增删行数是按截断后的两端算出来的 ⇒ 必须标 `isTruncated`，
        // 否则界面上一个看起来精确的 `+12` 其实只数了文件开头那 64 KB。
        if newText.utf8.count >= Self.maxSnippetBytes
            || (previous.map { $0.text.utf8.count >= Self.maxSnippetBytes } ?? false) {
            recorded.isTruncated = true
        }
        guard !recorded.lines.isEmpty || recorded.linesAdded > 0 || recorded.linesRemoved > 0 else {
            return (change, nil, nil)
        }
        if recorded.baselineSource == .lastObserved || raw.kind == .created {
            change.linesAdded = recorded.linesAdded
            change.linesRemoved = recorded.linesRemoved
        }

        // 隐私 §7 要求 diff 所需的最小片段「需可关闭」：关掉之后正文一个字节都不进库，
        // 但这条 diff、它的增删统计与「改前内容从哪来」的结论照记 —— 关掉的只是能否
        // 看到内容，不是「有没有观测到这次改动」。
        if settings.storeDiffPlaintext { return (change, recorded, nil) }
        var suppressed = recorded
        suppressed.lines = []
        suppressed.plaintextStored = false
        var snapshot: FileSnapshot?
        // 只有「读到的就是整个文件」时才给指纹：前缀的 hash 冒充整文件的 hash，
        // 日后拿文件重算会对不上，看起来像数据被改过 ⇒ 宁可不写这条快照。
        if newText.utf8.count < Self.maxSnippetBytes {
            snapshot = FileSnapshot(
                path: raw.path,
                contentHash: Self.contentHex(of: newText),
                sizeBytes: UInt64(newText.utf8.count),
                capturedAt: raw.timestamp,
                lineCount: newText.components(separatedBy: "\n").count
            )
        }
        return (change, suppressed, snapshot)
    }

    /// 与 `FileSnapshotter` 小文件那档同格式：sha256 十六进制小写、不加前缀。
    /// 两边必须一致，否则同一份内容在 `file_snapshots` 里会出现两种指纹。
    static func contentHex(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isTextFile(_ path: String) -> Bool {
        let fileExtension = (path as NSString).pathExtension.lowercased()
        return !fileExtension.isEmpty && textExtensions.contains(fileExtension)
    }

    /// 归因某条文件路径，并在**没归上**时带回机制（ICR-0009）。
    ///
    /// 四个 `Reason` 与下面四条出口一一对应，这里不新增任何判断——只是把已经走过的分支数出来。
    /// 一条未归属只记**一个**机制（否则恒等式 `Σcounts == 未归属总数` 不成立），
    /// 多个候选各卡在不同地方时按信息量取优先级：
    /// 什么都没检出 > 检出了但工作目录不可用 > 检出了但没有工作目录读数 > 确实不在任何名下。
    /// 理由：前三种都是**观测缺口**（我们不知道是谁），最后一种是**事实**（它不属于任何被观测的 Agent）；
    /// 把缺口说成事实，正是本产品最不该犯的那类错。
    func attributedAgent(forPath path: String) -> (AgentInstance?, AttributionGap.Reason?) {
        let candidates = mutable.withLock { $0.agents }
        var best: (agent: AgentInstance, depth: Int)?
        var sawUnusableDirectory = false
        var sawMissingDirectory = false
        for agent in candidates {
            guard let directory = agent.workingDirectory, !directory.isEmpty else {
                sawMissingDirectory = true
                continue
            }
            // cwd 太浅（`/`、家目录、`/Users` 这类半截根）的 agent **不能参与前缀匹配**：
            // 它会把全机文件变更都吸到自己头上。真实事故见 `MonitoringRootResolver.isUsableAttributionRoot`。
            guard MonitoringRootResolver.isUsableAttributionRoot(directory) else {
                sawUnusableDirectory = true
                continue
            }
            let prefix = directory.hasSuffix("/") ? directory : directory + "/"
            guard path == directory || path.hasPrefix(prefix) else { continue }
            if best == nil || directory.count > best!.depth {
                best = (agent, directory.count)
            }
        }
        guard let matched = best?.agent else {
            if candidates.isEmpty { return (nil, .nothingDetected) }
            if sawUnusableDirectory { return (nil, .workingDirectoryUnusable) }
            if sawMissingDirectory { return (nil, .detectedWithoutWorkingDirectory) }
            return (nil, .outsideEveryWorkingDirectory)
        }
        return (matched, nil)
    }


}
