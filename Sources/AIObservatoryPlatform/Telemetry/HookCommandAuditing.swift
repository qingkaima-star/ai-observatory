//
//  HookCommandAuditing.swift
//  AIObservatoryPlatform — Telemetry
//
//  Owner: WS-CmdSrc
//  ─────────────────────────────────────────────────────────
//  精确命令来源：读 `<storeDirectory>/agent-hooks/*.jsonl`（Agent 自己的 hook 落盘），
//  命令文本 / 退出码 / 起止时间三格全来自当事进程，零采样损失。
//
//  并发说明：`CommandAuditing.inferCommands` 是同步方法，因此本类不能用 actor。
//  可变状态（每文件偏移、有界去重键、统计）全部收进一个 `OSAllocatedUnfairLock`，
//  整轮读取在锁内完成——一轮最坏 `maxBytesPerPass × 文件数` 字节的同步 IO，
//  调用方是后台采集循环，不在主线程。
//
//  幂等与「不重不漏」的口径：
//  · 偏移在**读到就推进并立刻落盘**（至多一次）。应用被杀时 Engine 的 BatchWriter
//    也可能还没提交事务，两层丢的是同一批，不会出现「重启后同一条命令再插一遍」把
//    `commands.id` 撞掉整批写入的情况。
//  · 事件键（`eventId`，或内容自然键）落盘的有界集合，让 hook 自己重试写重复行、
//    或偏移文件被人为清掉时，同一条命令也只产出一条记录（`id` 由内容派生，
//    所以哪怕真被重放，落库也是主键相同的同一行）。
//
//  隐私：只读自己数据目录里的 `*.jsonl`。**绝不**读 `~/.claude`、`~/.codex`、
//  shell history 等 AiX 之外的路径——那是越界，且隐私口径要能对外讲得清。
//

import Foundation
import OSLog
import AIObservatoryCore

/// hook 落盘 JSONL 的命令审计来源，实现既有的 `CommandAuditing` 契约。
public final class HookCommandAuditing: CommandAuditing, Sendable {

    /// hook 子目录名（放在 `storeDirectory` 下，与观测站自己的 sqlite 同处一个数据目录）。
    public static let hooksDirectoryName = "agent-hooks"
    /// 偏移与去重键的旁挂文件名；不是 `.jsonl`，所以永远不会被当成数据来源读。
    public static let offsetFileName = ".offsets.json"

    /// 一行为什么没成为记录。每格都是「如实计数」而不是「悄悄丢掉」。
    public struct Stats: Sendable, Equatable {
        /// 读到的非空白完整行数（= 成功数 + 各丢弃计数 + 重复数）。
        public var parsedLineCount: Int = 0
        /// JSON 语法或字段类型不对。
        public var malformedLineCount: Int = 0
        /// 缺 `command`。
        public var missingCommandCount: Int = 0
        /// 缺（或解析不出）`startedAt`。
        public var missingTimestampCount: Int = 0
        /// 单行超过字节上限。
        public var oversizedLineCount: Int = 0
        /// 事件键已见过。
        public var duplicateLineCount: Int = 0

        /// 被丢弃的行数合计（重复行不计：它是「同一条命令的第二次投递」，不是坏数据）。
        public var droppedLineCount: Int {
            malformedLineCount + missingCommandCount + missingTimestampCount + oversizedLineCount
        }

        public init() {}
    }

    /// 观测站数据目录（`settings.storeDirectory`）。
    public let storeDirectoryURL: URL
    /// 实际读取的目录：`<storeDirectory>/agent-hooks`。
    public var hooksDirectoryURL: URL {
        storeDirectoryURL.appendingPathComponent(Self.hooksDirectoryName, isDirectory: true)
    }
    /// 偏移与去重键的落盘位置。
    public var offsetFileURL: URL { hooksDirectoryURL.appendingPathComponent(Self.offsetFileName) }

    private let classifier: DestructiveCommandRules
    private let reader: HookJSONLReader
    private let dedupeCapacity: Int
    private let mutable = OSAllocatedUnfairLock(initialState: State())

    /// 命令分级规则库与采样来源共用一份，避免「同一命令两边分级不一致」。
    public init(
        storeDirectoryURL: URL,
        classifier: DestructiveCommandRules = DestructiveCommandRules(),
        maxLineBytes: Int = 256 * 1024,
        maxBytesPerPass: Int = 1024 * 1024,
        dedupeCapacity: Int = 512
    ) {
        self.storeDirectoryURL = storeDirectoryURL
        self.classifier = classifier
        self.reader = HookJSONLReader(maxLineBytes: maxLineBytes, maxBytesPerPass: maxBytesPerPass)
        self.dedupeCapacity = max(dedupeCapacity, 1)
    }

    /// 当前累计统计（供 UI / 诊断如实展示「丢了哪些行、为什么」）。
    public var stats: Stats { mutable.withLock { $0.stats } }

    // MARK: - CommandAuditing

    /// 忽略 `processes` 与 `since`：hook 来源的新鲜度由字节偏移决定，
    /// 因此在观测站关闭期间落盘的命令下次启动照样补采得到（审计工具不该有停机空洞）。
    public func inferCommands(
        processes: [ProcessRecord],
        agents: [AgentInstance],
        since: Date
    ) -> [CommandRecord] {
        consumePendingRecords(agents: agents)
    }

    public func classify(command: String) -> CommandClassification {
        classifier.classify(command: command)
    }

    // MARK: - 一轮消费

    /// 读增量、解析、去重、推进并持久化偏移。返回按 `startedAt` 升序的记录。
    @discardableResult
    func consumePendingRecords(agents: [AgentInstance]) -> [CommandRecord] {
        mutable.withLock { state in
            if !state.loaded { state.load(from: offsetFileURL, capacity: dedupeCapacity) }

            var stats = Stats()
            var records: [CommandRecord] = []
            var changed = false
            let agentIDByKind = Dictionary(
                agents.map { ($0.kind, $0.id) },
                uniquingKeysWith: { first, _ in first }
            )

            for url in HookJSONLReader.hookFiles(in: hooksDirectoryURL) {
                let name = url.lastPathComponent
                let stored = state.files[name]
                let chunk = reader.read(url: url, startOffset: stored?.offset ?? 0, expectedInode: stored?.inode)

                if chunk.nextOffset != stored?.offset || chunk.inode != stored?.inode {
                    state.files[name] = Entry(offset: chunk.nextOffset, inode: chunk.inode)
                    changed = true
                }
                if chunk.restartedFromZero {
                    ObservatoryLog.telemetry.info("hook 文件偏移回零: \(name, privacy: .public)")
                }

                stats.oversizedLineCount += chunk.oversizedLineCount
                for line in chunk.lines {
                    stats.parsedLineCount += 1
                    switch AgentHookEvent.parse(jsonLine: line) {
                    case .failure(.missingCommand):
                        stats.missingCommandCount += 1
                    case .failure(.missingStartedAt):
                        stats.missingTimestampCount += 1
                    case .failure(.malformedJSON):
                        stats.malformedLineCount += 1
                    case .success(let event):
                        guard !state.keySet.contains(event.eventKey) else {
                            stats.duplicateLineCount += 1
                            continue
                        }
                        state.remember(event.eventKey, capacity: dedupeCapacity)
                        changed = true
                        records.append(event.commandRecord(
                            agentID: agentIDByKind[event.agentKind],
                            classification: classify(command: event.command)
                        ))
                    }
                }
            }

            state.stats = state.stats.merged(with: stats)
            if changed { state.persist(to: offsetFileURL) }
            return records.sorted { $0.startedAt < $1.startedAt }
        }
    }

    // MARK: - 状态

    private struct Entry: Codable, Sendable {
        var offset: Int
        var inode: UInt64?
    }

    /// 旁挂 json 的形态：`{"version":1,"files":{...},"keys":[...]}`。
    private struct Snapshot: Codable {
        var version: Int = 1
        var files: [String: Entry] = [:]
        var keys: [String] = []
    }

    private struct State {
        var loaded = false
        var files: [String: Entry] = [:]
        /// 已见过的事件键，按写入顺序保留、超出容量从头淘汰（`keySet` 是它的 O(1) 视图）。
        var keys: [String] = []
        var keySet: Set<String> = []
        var stats = Stats()

        mutating func remember(_ key: String, capacity: Int) {
            keys.append(key)
            keySet.insert(key)
            while keys.count > capacity {
                keySet.remove(keys.removeFirst())
            }
        }

        /// 偏移文件坏了就当没有：重读一遍靠去重键兜底，不因为状态文件而停止采集。
        mutating func load(from url: URL, capacity: Int) {
            loaded = true
            guard let data = try? Data(contentsOf: url),
                  let snapshot = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
            files = snapshot.files
            keys = Array(snapshot.keys.suffix(max(capacity, 1)))
            keySet = Set(keys)
        }

        func persist(to url: URL) {
            let snapshot = Snapshot(files: files, keys: keys)
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            do {
                try data.write(to: url, options: .atomic)
            } catch {
                ObservatoryLog.telemetry.error("hook 偏移写入失败: \(error.localizedDescription, privacy: .public)")
            }
        }
    }
}

private extension HookCommandAuditing.Stats {
    func merged(with other: HookCommandAuditing.Stats) -> HookCommandAuditing.Stats {
        var sum = self
        sum.parsedLineCount += other.parsedLineCount
        sum.malformedLineCount += other.malformedLineCount
        sum.missingCommandCount += other.missingCommandCount
        sum.missingTimestampCount += other.missingTimestampCount
        sum.oversizedLineCount += other.oversizedLineCount
        sum.duplicateLineCount += other.duplicateLineCount
        return sum
    }
}
