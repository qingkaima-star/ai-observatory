# AiX

> 本文与代码同步于 2026-09-19，所有「已实现」断言均附代码位置（`文件:行`，相对仓库根）。

**一句话定位**：**AiX**（AI Agent 活动审计台）是一款 100% 本地运行、零上传的 macOS 26 原生应用，用于审计本机 AI Agent
（Codex / Claude Code / Cursor Agent 等）执行过的操作记录、资源消耗、文件变化、终端行为与系统影响。
（Swift 6 + SwiftUI + SwiftPM，`Package.swift:1` tools-version 6.2，`Package.swift:14` `.macOS("26.0")`，
`Package.swift:138` `swiftLanguageModes: [.v6]`。）

---

## 1. 当前真实完成度

**必须先说清的事**：本仓库当前的可运行状态是「**采集 → SQLite 落库 → 编排 → 风险规则 → 导出 →
UI 已成一条链并在运行，网络与 GPU 已于 2026-09-20 接上（**只有整机口径**，见下表），
且采集有已知的正确性缺陷（见第 5 节末）**」。
下面每一行都可在代码中核对；「实测」列来自负责人用 `Packaging/make-app.sh` 产出的
ad-hoc 包跑 47 秒后的真值（数据目录用
`AIOBSERVATORY_DATA_DIR` 指到仓库外，验证后已删除）。本页此前写的是「采集器未装配、
没有任何落盘」，那是 Store/Engine 合入前的状态，现已更正。

| 模块 | 状态 | 依据（代码位置） |
| --- | --- | --- |
| `AIObservatoryCore` 契约层 | **已实现**（域模型 / 查询 / 协议 / 格式化 / 日志门面） | `Sources/AIObservatoryCore/Contracts/` 6 个文件；测试 `Tests/AIObservatoryCoreTests/CoreContractTests.swift` |
| `AgentDetection`：libproc 真实进程快照 | **已实现 + 已测 + 已接入 App**（装配点 `ObservatoryEngine.swift:98`，实测正在写 `agents` 表） | `Sources/AIObservatoryPlatform/AgentDetection/LibprocProcessInspector.swift:74-84`（`proc_listpids` `:95`、`PROC_PIDTBSDINFO` `:125`、`PROC_PIDTASKINFO` `:160`、cwd `:243`、argv `:257,263`）；测试 `Tests/AIObservatoryPlatformTests/AgentDetection/AgentDetectionTests.swift:26,33,44,51,64` |
| `AgentDetection`：6 条识别策略 + 签名库 | **已实现（库层）+ 已测**，**已接入 App**（装配点 `ObservatoryEngine.swift:98-106`） | `AgentDetectionPipeline.swift:44-51`（策略链）、`DetectionStrategies.swift:68,89,109,136,157,189`、`AgentSignatureDatabase.swift:62-123`（8 类 Agent 签名） |
| `AgentDetection`：进程树 / 环检测 | **已实现（库层）** | `ProcessTreeBuilder.swift:17`；测试 `AgentDetectionTests.swift:93`（父子环切断）、`:106`（孤儿节点） |
| `EndpointSecurity` 实时监控 | **未实现**——仅能力探测器，不订阅任何事件 | `EndpointSecurityMonitor.swift:45-69` 只调用一次 `es_new_client` 随即 `es_delete_client`；文件头 `:17-18` 自述「仅做能力探测（骨架），并不真正订阅 ES 事件流」；`Settings.enableEndpointSecurity` 默认 `false`（`ServiceProtocols.swift:104`），且**没有任何采集链消费它**——设置页会读写这个草稿值（`SettingsPrivacyPane.swift:87`、`SettingsAboutPane.swift:121` 已如实标注"本版本未接入"），但它不改变任何实际行为 |
| `Telemetry`：整机 / 进程采样 | **已实现（库层）+ 已测**，CPU/内存/磁盘/load **已接入 App**（装配点 `ObservatoryEngine.swift:98-106`，`HostMetricsSampler` 见 `:104`） | `HostMetricsSampler.swift:37-58`（CPU `:66-115` host_statistics 两次求差、内存 `:119-138`、磁盘 `:142-152`、load `:156-160`）、`ProcessMetricsSampler.swift:18`、`DiskIOCounters.swift:28`、`ThermalPowerReader.swift:22`；测试 `Tests/AIObservatoryPlatformTests/Telemetry/TelemetryTests.swift:27+` |
| `Telemetry`：网络速率 / GPU 活动 | ✅ **已接线（整机口径）**：每轮 `sampleSystem()` 差分网卡计数器得速率、读 `IOAccelerator` 得 GPU 活动近似值，性能页有「网络 ↓/↑」「GPU 活动（整机近似）」两块瓷贴与第四张曲线 | `HostMetricsSampler.swift:28-29,46-47` 调用 `NetworkCounters` / `GPUActivityReader`；落 `system_perf` v3 四列 `network_in_bytes_per_second` / `network_out_bytes_per_second` / `network_availability` / `gpu_percent`（`StoreSchema.swift:137-143`）。**两条硬边界**：① 只有整机量——macOS 无公开的非 root 按进程网络/GPU API，故会话级 `perf_samples` 的 `gpu_percent` 与 `network_bytes_in/out` 仍恒 NULL / 0，界面也不在会话视图里画它们（`PerformanceSeriesPoint` 会话初始化写死 `nil`，有测试钉住）；② 本轮**没有**用户开关，理由见 `PRIVACY.md` §2.3。**不得**把这两项写成按 Agent 归因的能力 |
| `Telemetry`：命令推断 + 破坏性分级 | **已实现（库层）+ 已接入，但真机覆盖率很低** | `CommandInferenceEngine.swift:36-65`（父链归因 `:69-81`）、`DestructiveCommandRules.swift:50-173`（33 条规则）、`:176-208` `classify`。真机整轮（总控 2026-09-20）**只记到 1 条命令**，且 `exit_code` **恒为空**（轮询采样拿不到已退出进程的返回值，属机制性限制，已另开赛道）。⇒ 描述模块④「Terminal 命令审计」时**不得**写「完整记录所有命令」，只能说「按采样窗口推断当时在跑的命令行」 |
| `AIObservatoryStore`（SQLite + WAL + 批量写 + 保留清理） | **已实现，正在写库** | `Sources/AIObservatoryStore/` 7 个文件；`StoreSchema.swift:116-127` 等 11 张表（`agents`/`sessions`/`events`/`commands`/`file_changes`/`diffs`/`file_snapshots`/`perf_samples`/`system_perf`/`projects`/`risk_events`）；实测产物旁有 `observatory.sqlite` + `-wal` + `-shm` 边车；保留期清理已接通（`ObservatoryEngine.swift:830-833` → `RetentionPruner.swift`） |
| `AIObservatorySwiftDataStore`（需求点名的第二后端） | **已实现，但运行时还没切过去**：装配层目前固定打开 SQLite，`AIOBSERVATORY_BACKEND` 无人读取 ⇒ 当前真实跑库的只有 SQLite；接线是 App/Engine 侧的活 | `Sources/AIObservatorySwiftDataStore/` 6 个文件；11 个 `@Model` 与 SQLite 的 11 张表**列集合一一对应**（165 列，脚本核对）。读写 API 与 SQLite 后端同名同语义，两侧都 conform Core 的 `ObservatoryService` + `ObservatoryWriting` ⇒ 一旦装配层拿 `ObservatoryStoreBackend.fromEnvironment(...)` 做 `switch`，「选哪个后端」就能在协议层表达而不引用具体类型（装配层目前只有一条路：`AIObservatoryApp.swift:26` 传 `storeDirectory`，Engine 内直接 `new ObservatoryStore`（SQLite），App target 根本不 import `AIObservatorySwiftDataStore`）。`ModelContext` 关在 actor 内、`@Model` 类不出模块，跨边界只走值类型。含 SQLite→SwiftData 可重入迁移器（自带只读 `SQLite3` 通道，重跑不产生重复行）。测试 94 条，其中 17 条是**两后端直接对照**。<br>**一条如实记录的边界**：两后端语义一致（选中哪些行、`totalCount`、分页游标都相同），但**时间戳完全相同的并列行，两后端的行序不保证相同**——SQLite 按 TEXT 的 `COLLATE BINARY` 字节序做 `id DESC` tie-break，而 SwiftData 对字符串列的排序不是 BINARY 字节序（实测）。**影响面**：并列行较多时，导出报告与「两库逐行对账」的顺序会不一致（内容与条数不受影响）。总控 2026-09-20 裁决为接受并记录，理由与复现证据见 `Tests/AIObservatorySwiftDataStoreTests/SwiftDataBackendDifferentialTests.swift` 的套件头注释与 `AiX-Vault/02-子代理简报/WS-SwiftData.md` |
| `AIObservatoryPlatform/FileSystem`（FSEvents / 快照 / diff） | **已实现，真机有证据** | `FileSystem/` 6 个文件（`FSEventsWatcher.swift`、`FileSnapshotter.swift`、`DiffEngine`、`Snapshotter`、`PathFilter`、`RenamedFileMatcher.swift:320`）；测试 `Tests/AIObservatoryPlatformTests/FileSystem/` 5 个文件。真机整轮（总控 2026-09-20）拿到 **18 条**命中夹具目录的 `file_changes`，created / deleted / modified 三类都有 |
| `AIObservatoryRiskRules` | **已实现并接入**（2026-09-20 更正：本行原写「占位」，那是合并前的状态） | 7 个文件 + `Rules/` 4 族（`BehaviorPatternRules`、`CommandBehaviorRules`、`DestructiveFileOperationRules`、`SensitiveLocationRules`）；`RiskRuleCatalog.standard` 由 Engine 消费（`RiskPipeline.swift:29,63,109`，`loadedRules()/ruleCount()` 在 `:163,168`）。实测唯一规则标识 **33 条** `risk.*` |
| `AIObservatoryExport`（JSON/CSV/Markdown 导出） | **已实现且从 UI 可达**（同上更正） | 11 个文件；`SessionsView.swift:204` → `ObservatoryExporting.swift:57` → `ExportCoordinator().run`；含两层真实防护：`ExportRedactor`（凭据形态脱敏，11 类，默认开）与 `ExportWriter.validate`（`allowedRoots` 白名单 + 符号链接解析 + `forbiddenPrefixes`）。**注意方向**：这两层是代码事实，可以写；但「路径与用户名不含在脱敏范围内」也一并写清（见 `PRIVACY.md` §5.4） |
| `AIObservatoryInsights`（项目地图 / 异常检测） | **已实现** | `Insights/` 11 个文件（热度评分、z-score 异常、Agent 效率对比、置信度、代码增长估计）；main 合入时带 81 例测试 |
| `AIObservatoryEngine` 编排 | **已实现**：真实装配 + 真实查询 | `.live(settings:)`（`ObservatoryEngine.swift:188-189`）装配 `LibprocProcessInspector()`（`:98`）、`HostMetricsSampler`（`:104`）、`FSEventsWatcher`（`:106`）、`RiskPipeline`（`:80`）；查询委托 `readyStore()`（`:413`，例如 `:399-401` `riskEvents`、`:299-301` `acknowledgeRiskEvent`） |
| `AIObservatoryUI` 界面 | **已实现** | UI target 70 个文件；`Shell/ObservatoryRootView.swift:103` 按标签路由到 `DashboardView` 等真实视图；设置页为 `SettingsView`（`AIObservatoryApp.swift` 的 `settingsWindow`），`SettingsModel.swift:14` 明确「不写 UserDefaults、不写文件」 |
| 菜单栏 / 开机自启 | 菜单栏**已实现，且可按设置关闭（需重启生效）**；开机自启**未实现** | `@main enum AIObservatoryMain` 在启动时按 `MenuBarScenePolicy.declaresMenuBar` 挑一个具体 App 类型：`AIObservatoryMenuBarApp`（多一个 `MenuBarExtra` 场景，`.menuBarExtraStyle(.window)`）或 `AIObservatoryWindowedApp`，两版共用同一份 `ObservatoryCoreScenes`，Scene 树不复制第二份。**为什么只能靠重启**：`@SceneBuilder` 没有 `buildIf`，运行时条件声明 Scene 做不到——这是框架限制，不是偷懒。所以「这个开关生不生效」的准确答案是**生效，但换 Scene 树要重启**；界面另有 `menuBarRestartReminder` 明说草稿与本次启动的声明不一致。（2026-09-20 更正：本行原写「不受 `settings.enableMenuBarExtra` 控制」并引 `AIObservatoryApp.swift:79-83`——该结论已随上述重构失效、行号也已漂，本页此后一律引符号名而非行号。）`launchAtLogin` 无消费方（全仓无 `SMAppService`）；主窗口仍是 `.regular` 前台应用 ⇒ `Packaging/Info.plist` 的 `LSUIElement=false` 与此一致 |

**界面当前渲染的是样本数据还是真实采集？真实采集。**
`ObservatoryRootView.swift:103` 按选中标签路由到 `DashboardView` 等真实视图，
数据来自 `ObservatoryRuntime` → `ObservatoryEngine` → `ObservatoryStore`（SQLite）。
怎么自己复现（不依赖本页任何写死的数字）：
`AIOBSERVATORY_DATA_DIR=$PWD/tmp/verify open dist/AIObservatory.app` + `Tools/AgentFixture/fixture-agent.sh 30`，
再 `sqlite3 -readonly tmp/verify/observatory.sqlite "select (select count(*) from agents), (select count(*) from events), (select count(*) from commands), (select count(*) from sessions), (select count(*) from perf_samples);"`。
验完删掉 `tmp/verify` 与 `dist/`（库里是这台机器的真实路径，不入库、不留盘）。
> 早期版本这里写过一组具体数字（`agents=23 / sessions=45`…）。它们已经作废：
> `agents=23` 是"同一桌面会话被拆成多行"的虚高（已修），`sessions=45` 里含"重启把活 Agent 拆成新会话"
> 产生的 0 秒会话（也已修）。**冻结的计数会随修复变成假话**，所以改成给配方。
`Sources/AIObservatoryTestSupport/SampleData.swift` 与 `InMemoryObservatoryService.swift`
仍能生成一整套确定性演示数据（`SampleData.swift:60-64`），但它们**只被测试与预览引用**
（如 `Tests/AIObservatoryCoreTests/CoreContractTests.swift`），
App 未 import TestSupport（`AIObservatoryApp.swift:11-15`，尽管 `Package.swift` 声明了该依赖）。

---

## 2. 架构分层

依赖方向与 `Package.swift` 的 target 声明逐条一致：

```
AIObservatoryApp（可执行外壳 · 组合根 · 冻结）        Package.swift:94-105
  ├→ Core, Store, Platform, Engine, UI, TestSupport
  ├→ ObservatoryEngine(settings: .default)           AIObservatoryApp.swift:25
  └→ ObservatoryRootView(runtime:)                   AIObservatoryApp.swift:40
        │
        ▼
AIObservatoryEngine  ──→ Core, Store, Platform       Package.swift:51-55
AIObservatoryUI      ──→ Core（仅协议）               Package.swift:58-62
AIObservatoryPlatform──→ Core                         Package.swift:45-48
   ├ AgentDetection/（WS-Agent）  ├ FileSystem/（WS-Files）  ├ Telemetry/（WS-Telemetry）
AIObservatoryStore   ──→ Core                         Package.swift:36-40
AIObservatoryRiskRules / Export / Insights ──→ Core   Package.swift:66-84
AIObservatoryCore    ──→ 无内部依赖（冻结契约）        Package.swift:30-33
```

与 `AiX-Vault/05-失忆防护/必读.md` 第 4 节示意图的差异（以代码为准）：
示意图把 RiskRules / Export / Insights 三个 target 省略了，而它们在 `Package.swift:66-84`
中真实存在且只依赖 Core；示意图中的「SQLite + WAL / BatchWriter」**已经落地**
（Store 已实现并在写库，见第 1 节；WAL 边车 `observatory.sqlite-wal` / `-shm` 实测存在）。

---

## 3. 构建与运行

```bash
cd <repo-root>
xcrun swift build  --disable-sandbox          # 调试构建
xcrun swift test   --disable-sandbox          # 全量测试
xcrun swift build  --disable-sandbox -c release --product AIObservatory
Packaging/make-app.sh                         # 唯一打包入口：组装 dist/AIObservatory.app
                                              # （拷 Info.plist 与隐私清单、嵌 entitlements、
                                              #   逐个签名（不用 --deep）、打印验证与制品 SHA-256）
```

**为什么本地必须带 `--disable-sandbox`**：开发执行环境本身已运行在 sandbox 内，
SwiftPM 再嵌套一层 `sandbox-exec` 会直接失败并报
`sandbox_apply: Operation not permitted`（见 `AiX-Vault/05-失忆防护/必读.md` 第 6 节；
注意 `AGENTS.md` 第 6 节是**性能预算**，不是这条构建约定，此前本页引用错了出处）。
唯一打包入口 `Packaging/make-app.sh` 把这个 flag 参数化为 `AIX_SPM_SANDBOX_FLAG`
（`Packaging/make-app.sh:141-152`：未设置时保留本地默认带 flag，CI 上显式传空串即还原
SwiftPM 默认行为）。`Scripts/verify.sh:15,19,24` 仍硬编码该 flag，因此 CI 不复用它（附录 A4）。

**实测资源占用（不是达标声明）**：本机 macOS 26.5.2 / arm64。

| 场景 | 空闲 CPU | 内存 |
| --- | --- | --- |
| 打包产物冷启动前 8 秒（负责人 2026-09-19） | `%CPU 23.5%`（启动首扫） | RSS ≈180 MB |
| 同一产物运行 45 秒（负责人） | `top` 二次采样 `%CPU 2.4%`；`ps` 累计 RSS ≈208 MB | `top` `MEM 113M` |
| **真机整轮**（总控 2026-09-20，见 `AiX-Vault/01-架构/真机验证-命令审计与检出.md`） | **0.0–0.4% ⇒ 达标** | **209–211 MB ⇒ 超出 200 MB 上限** |

对照 `AGENTS.md` 第 6 节预算（空闲 CPU 目标 <1%/上限 3%；内存目标 <120MB/上限 200MB）：
**CPU 空闲侧已达标；内存超出上限**（该超限项记为 N5，未修）。
本仓库**没有**任何自动化性能门禁，唯一相关断言是单次扫描 `<300 ms`
（`AgentDetectionTests.swift:32-42`，比 §6 的 150 ms 上限宽松 2 倍），
所以**不得**声称满足性能预算，也**不得**只引用 CPU 那一半达标数字。

**度量口径（本轮才校正，前两行用的是错的尺）**：`ps -o %cpu` 是**进程生命期衰减平均**，
启动首扫会被后续空闲稀释 ⇒ 拿它判「空闲 CPU < 1%」不成立（前两行的 23.5% / 2.4% 只能读作
"启动期抖动"，不能读作空闲值；真机整轮那行的 0.0–0.4% 也不是这个口径）。
正确算法：**Δ(累计 cputime) / Δ(墙钟)**，两次采样求差。
且本轮所有数字取自**两车道并行编译**的机器（load 5.5–8.3），同窗口连基线都有 7.4%
⇒ 绝对值**不是结论**，只有同一窗口内的相对差勉强可用。
要判 §6 预算必须在安静机器上专门跑一轮并写成可复现脚本 —— 仓库里目前没有性能门禁。

**公开 CI 上不需要该 flag**：CI runner 没有外层 sandbox，嵌套问题不存在；
在 CI 里加 `--disable-sandbox` 属于多余且会掩盖真实的沙箱兼容性回归。
（CI 配置见 `.github/workflows/ci.yml`，由 WS-Packaging/D 维护。）

---

## 4. 文档索引

| 文件 | 内容 |
| --- | --- |
| `Documentation/PRIVACY.md` | 数据落在哪里、零上传的代码依据、如何清空、离线运行、采集边界与残留风险 |
| `Documentation/SECURITY.md` | 信任模型、libproc 轮询 vs EndpointSecurity 两条采集路径、签名与分发信任、威胁模型清单 |
| `Documentation/INSTALL.md` | 从源码安装、ad-hoc 签名包的打开方式、前置条件、卸载、故障排查 |
| `Documentation/PRIVACY-EVIDENCE.md` | required-reason 隐私清单逐条证据（`文件:行`），由 WS-Packaging/B 维护 |
| `Documentation/OPEN-SOURCE.md` | 开源许可证对比与推荐，由 WS-Packaging/D 维护 |
| `Resources/PrivacyInfo.xcprivacy` | 隐私清单本体，由 WS-Packaging/B 维护 |
| `Packaging/Info.plist`、`Packaging/*.entitlements` | bundle 配置与 entitlements 基线/可选 ES 档 |
| `Packaging/ENTITLEMENTS-NOTES.md` | entitlements 的完整取舍论证（**必须**在 plist 之外：AMFI 不接受 entitlements 里的 XML 注释），含「ES 档签进 ad-hoc 包会 SIGKILL」的实测 |
| `Packaging/make-app.sh` | **唯一打包入口**（六步：前置校验 → 构建 → 组装 → 元数据与资源 → 签名 → 验证与制品信息；头部写明 13 条必须保持的不变量，其中 #7 是「签名/校验失败必须硬退出」） |

## 5. 路线图（尚未实现，不要当作现状引用）

**已完成**（勿再列为待办）：SQLite 落库与批量写、保留期清理、文件变化追踪与 diff、
洞察/项目地图、真实 UI、采集器装配进 Engine、菜单栏（可按设置关闭，但需重启生效）、
独立风险规则库（33 条 `risk.*`）、导出（JSON/CSV/Markdown + 脱敏 + 落盘路径白名单）。

**仍未完成**：网络与 GPU 的**按进程归因**（内核没有公开的非 root API，整机量已经上了页、归因做不到，别在文档里许诺它）、网络计数器的**用户开关**（总控本轮决定不做，见 `PRIVACY.md` §2.3）、设置持久化、开机自启、数据库静态加密、EndpointSecurity 事件流订阅
（探测器有，订阅没有；且需 Apple 特批 entitlement，ad-hoc 签了会被 SIGKILL —— 见
`Packaging/ENTITLEMENTS-NOTES.md` 第 2.2 节）、风险告警的**可用性证据**
（规则已加载、`risk_events` 有写路径，但真机窗口内命中 0 条，见 `SECURITY.md` 第 6 节）。

**已修复的正确性缺陷（勿再按旧说法写文档）**：`sysctl(KERN_PROCARGS2)` 的 argv 解析曾把
`exec_path` 当成 `argv[0]` ⇒ 整体后移一位、**丢掉最后一个参数**（真机表现：
`sh -c "…"` 的命令文本整段消失，只看命令文本的风险规则因此在生产里永不命中）。
`41aec4e` 起改为先跳过 `exec_path` 与其后的填充 NUL，并有回归测试钉住结构
（`Tests/AIObservatoryPlatformTests/AgentDetection/ProcessArgumentsTests.swift`
「argv 逐字保真：不后移、不丢末位、不掺入 exec_path」，用真起的 `sh -c` 子进程断言）。
⇒ 「命令行不完整」这个限定词**不再成立**；仍然成立的限制是另外两条，别混淆：
两次扫描之间启动并退出的进程**看不到**、`exit_code` 在纯轮询下**拿不到**
（`CommandInferenceEngine.swift:56` 仍写死 `outcome: .running`；退出码现在由 hook 通道提供
——`AgentHookEvent.swift:38,112,181` 从 JSONL 里读可选 `exitCode` 并据此判 success/failure，
前提是那台机器上 Agent 侧的 hook 已安装，非自动生效）。
原始工单：`AiX-Vault/04-决策记录/IFR-platform-kern-procargs2.md`。
