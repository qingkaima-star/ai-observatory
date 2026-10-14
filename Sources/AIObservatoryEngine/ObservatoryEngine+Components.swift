//
//  ObservatoryEngine+Components.swift
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

    // MARK: - Components

    /// Store 的来源。三种状态显式建模，避免「构造出来但没有表的 Store」：
    /// 引擎只能在 `open()`（含迁移）之后使用它。
    public enum StoreSource: Sendable {
        /// 已打开并完成迁移的 Store（测试注入用）。
        case ready(ObservatoryStore)
        /// 只给配置：引擎在 `start()`/首次查询时异步 `open`（含迁移）。生产路径。
        case configuration(SQLiteDatabase.Configuration)
        /// SQLite 运行期不可用：查询明确抛 `ObservatoryError.storeUnavailable`。
        case unavailable(reason: String)
    }

    /// 装配清单。生产路径用 `live(settings:)`；测试注入桩采集器即可脱离真实系统。
    public struct Components: Sendable {

        /// Store 来源。
        public var storeSource: StoreSource
        /// Agent 识别管线。
        public var detector: any AgentDetecting
        /// 进程快照来源。
        public var processInspector: any ProcessInspecting
        /// 整机与进程级性能采样。
        public var metrics: any SystemMetricsSampling
        /// 命令审计（从进程树反推 Agent 触发的命令）。
        public var commandAuditor: any CommandAuditing
        /// 文件活动观测源。
        public var fileObserver: any FileActivityObserving
        /// 文件内容快照能力（拿不到则 diff 行数保持 0）。
        public var snapshotter: any FileSnapshotting
        /// Diff 计算能力。
        public var differ: any DiffComputing
        /// Session 开闭与结算。
        public var lifecycle: SessionLifecycleManager
        /// 原始产出 → `TimelineEvent`。
        public var aggregator: TimelineAggregator
        /// 路径 → 项目根与项目级聚合。
        public var projectMapper: ProjectMapper
        /// 风险规则引擎。
        public var riskPipeline: RiskPipeline

        /// 显式装配全部依赖。
        public init(
            storeSource: StoreSource,
            detector: any AgentDetecting,
            processInspector: any ProcessInspecting,
            metrics: any SystemMetricsSampling,
            commandAuditor: any CommandAuditing,
            fileObserver: any FileActivityObserving,
            snapshotter: any FileSnapshotting,
            differ: any DiffComputing,
            lifecycle: SessionLifecycleManager = SessionLifecycleManager(),
            aggregator: TimelineAggregator = TimelineAggregator(),
            projectMapper: ProjectMapper = ProjectMapper(),
            riskPipeline: RiskPipeline = RiskPipeline()
        ) {
            self.storeSource = storeSource
            self.detector = detector
            self.processInspector = processInspector
            self.metrics = metrics
            self.commandAuditor = commandAuditor
            self.fileObserver = fileObserver
            self.snapshotter = snapshotter
            self.differ = differ
            self.lifecycle = lifecycle
            self.aggregator = aggregator
            self.projectMapper = projectMapper
            self.riskPipeline = riskPipeline
        }

        /// 用 Platform 真实采集器装配。`storeDirectory` 配得不可用时记日志并退到内存库。
        public static func live(settings: ObservatorySettings) -> Components {
            let inspector = LibprocProcessInspector()
            let mapper = ProjectMapper(ignoredPathPatterns: settings.ignoredPathPatterns)
            // 界面语言在**进程启动时定一次**（不是全局可变状态，AGENTS.md §5）：
            // 下面两个消费者必须收同一个值，否则批量与单事件两条进料路径会写出两种语言。
            let interfaceLanguage = AppLanguage.resolved()
            return Components(
                storeSource: .configuration(databaseConfiguration(for: settings)),
                detector: AgentDetectionPipeline(),
                processInspector: inspector,
                metrics: HostMetricsSampler(processInspector: inspector),
                commandAuditor: Self.commandAuditor(for: settings),
                fileObserver: FSEventsWatcher(
                    filter: PathFilter(
                        additionalPatterns: settings.ignoredPathPatterns,
                        databasePaths: Self.databaseSearchPaths(for: settings)
                    )
                ),
                snapshotter: FileSnapshotter(),
                differ: MyersDiffEngine(),
                aggregator: TimelineAggregator(projectMapper: mapper),
                projectMapper: mapper,
                riskPipeline: RiskPipeline(
                    assessor: RiskAssessor(interfaceLanguage: interfaceLanguage),
                    interfaceLanguage: interfaceLanguage
                )
            )
        }

        /// 数据库位置：`settings.storeDirectory` 为空 → 内存库。
        /// 默认必须是内存库：`ObservatorySettings.default` 给的是空目录，
        /// 若私自回落到 `~/Library/Application Support/…` 会在授权目录（AiX）之外落文件。
        /// 命令审计的装配：采样推断 + Agent hook 精确来源，两者重叠时以 hook 为准。
        ///
        /// 为什么两条都要：轮询进程快照对 30–50 ms 的短命命令捕获率只有 1–2%，
        /// 而且**永远看不到退出码**（`outcome` 恒 `.running`）。需求要的是「命令、执行结果、持续时间」，
        /// 三格里有两格只能由当事进程自己落盘才拿得到。
        /// 没有数据目录（内存库）时只保留采样源——不去猜一个 hooks 路径。
        public static func commandAuditor(for settings: ObservatorySettings) -> any CommandAuditing {
            let sampling = CommandInferenceEngine()
            let directory = settings.storeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !directory.isEmpty else { return sampling }
            return CompositeCommandAuditing(
                sampling: sampling,
                hook: HookCommandAuditing(storeDirectoryURL: URL(fileURLWithPath: directory, isDirectory: true))
            )
        }

        public static func databaseConfiguration(for settings: ObservatorySettings) -> SQLiteDatabase.Configuration {
            let directory = settings.storeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !directory.isEmpty else { return .inMemory }
            return .file((directory as NSString).appendingPathComponent("observatory.sqlite"))
        }

        /// 自身数据库所在目录：交给 `PathFilter` 抑制，避免观测到自己的写入形成回环。
        static func databaseSearchPaths(for settings: ObservatorySettings) -> [String] {
            var paths = PathFilter.defaultDatabasePaths
            let directory = settings.storeDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !directory.isEmpty, !paths.contains(directory) { paths.append(directory) }
            return paths
        }
    }


}
