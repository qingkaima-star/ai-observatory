# 隐私声明（PRIVACY）

> 本文与代码同步于 2026-09-19，所有「已实现」断言均附代码位置（相对仓库根）。

本文只写**代码里真实存在的行为**。凡是「设计上会有、当前还没写」的部分，
一律放在「尚未实现」小节里，不当作现状。

---

## 1. 数据落在哪里：全部落在**本机 SQLite**，不落在别处

结论：本版本运行时**会**创建目录、建库并持续写入；位置只有下面四种去向，
全部在本机，没有任何一条会写到网络或第三方。（本节在 2026-09-19 的打包验证中随
WS-Engine / WS-Store 落地而更正；此前的版本说「没有任何持久化落盘」，那是当时的真实状态，现在不成立了。）

| 运行形态 | 数据库目录 | 代码位置 |
| --- | --- | --- |
| 打包后的 `.app` | `~/Library/Application Support/com.aix.aiobservatory/` | `Sources/AIObservatoryApp/DataLocation.swift:28-30`；「正式运行」判据 = bundle id 为 `com.aix.aiobservatory` **且** 可执行文件位于 `*.app` 内（`:35-38`） |
| 显式覆盖（含 CI 与验证跑） | `$AIOBSERVATORY_DATA_DIR` 的值 | `DataLocation.swift:26-27` |
| 开发期裸可执行文件 | 仓库内 `observatory-data/`（自 cwd 向上最多 6 层找 `Package.swift`），找不到则退回 `<临时目录>/AIObservatoryDev/` | `DataLocation.swift:42-55` |
| 目录创建失败 | 返回空串 ⇒ **内存数据库**，一个字节都不落盘（不崩溃、不偷偷写到别处） | `DataLocation.swift:57-64` |

文件名与表：`observatory.sqlite`（`ObservatoryEngine.swift:125`）+ SQLite WAL 边车
`-wal` / `-shm`；schema 见 `Sources/AIObservatoryStore/StoreSchema.swift`
（`agents` / `sessions` / `events` / `commands` / `file_changes` / `diffs` /
`file_snapshots` / `perf_samples` / `system_perf` / `projects` / `risk_events`）。

怎么自己核实（本页不冻结具体计数——它们会随修复变成假话，早期版本写的
`agents=23 / sessions=45 / file_changes=0` 就全作废了：`agents=23` 是同一桌面会话被拆成多行的虚高，
`sessions=45` 含重启拆出的 0 秒会话；`file_changes=0` 也不通用，
2026-09-20 同一配方在 30 秒窗口里拿到过十几条 created/deleted/modified）：

```sh
AIOBSERVATORY_DATA_DIR="$PWD/tmp/verify" open dist/AIObservatory.app   # 数据目录显式指到**仓库内**
Tools/AgentFixture/fixture-agent.sh 30
sqlite3 -readonly tmp/verify/observatory.sqlite \
  "select (select count(*) from agents), (select count(*) from file_changes), (select count(*) from commands);"
rm -rf tmp/verify dist
```

**这份产物在你机器上跑起来会记录你真实的进程清单** ——
这正是本工具的用途，也是 §5 与 §8 存在的原因。验证库含真实路径，跑完必须删掉，
且任何时候都不要让它写到仓库之外（`AIOBSERVATORY_DATA_DIR` 未设置时，
打包版按 ADR-0003 会写到 `~/Library/Application Support/com.aix.aiobservatory/`，
那是给正式用户用的位置，不是开发验证的位置）。

系统侧另一处痕迹是 **OSLog 统一日志**（subsystem `com.aix.aiobservatory`，
`Sources/AIObservatoryCore/Contracts/ObservatoryLog.swift:12-21`）。
生产代码里现在有多条日志（例如 `ObservatoryEngine.swift:235,243,273,275,285,290`），
内容为状态文本与计数；其中带 `privacy: .public` 标注的字段是刻意公开的，
未标注的字符串会被系统按 `%{public}@` / `%{private}@` 规则处理。
注意：统一日志的**保留时长由 macOS 管理，不由本应用控制**。

---

## 2. 「不上传」的代码依据

### 2.1 源码层：网络 API 命中数为 0

在仓库根执行（只读命令）：

```bash
grep -rnE 'URLSession|NWConnection|NWListener|NWParameters|socket\(|CFNetwork|getaddrinfo|MCSession|NetService|import Network' Sources/ | wc -l
# 结果：0
```

本次交付复核同样返回 `No matches found`，覆盖的检索面是：
`URLSession` / `NSURLConnection` / `NWConnection` / `NWListener` / `NWParameters` /
`socket(` / `CFNetwork` / `getaddrinfo` / `MCSession` / `NetService` / `import Network`。

### 2.2 更强的形式：`Sources/` 的 import 全集是可枚举的

全部 import 只有 `Foundation`、`SwiftUI`、`AppKit`、`os`、`OSLog`、`IOKit`、`Darwin`
与被观测项目自身的模块。既没有 `Network`，也没有 `CFNetwork`。
一个只 import 这些模块的二进制不会自行发起外连。

### 2.3 名字里有「Network」的那处代码不联网 —— 但它**确实在读网卡计数器**（2026-09-20 起）

`Sources/AIObservatoryPlatform/Telemetry/NetworkCounters.swift:111-149` 只做一件事：
`getifaddrs()` 遍历 `AF_LINK` 接口、累加 `ifi_ibytes/ifi_obytes` 累计计数器，
并排除 `lo0`（`:106,124`）。**不建立连接、不构造套接字、不读取任何报文内容、不记录对端地址**，
得到的是「本机自开机以来各接口收发了多少字节」加接口名（`en0` / `utun3` 这类）。

**2026-09-20 更新（WS-Perf 接线，见 `AiX-Vault/04-决策记录/IFR-perf-coverage-2-网络与GPU落库契约.md`）**：
这台仪表**已经接上线**。`HostMetricsSampler.swift:28-29` 持有 `NetworkCounters` 与
`GPUActivityReader`，`sampleSystem()`（`:39-67`）每次整机采样都会：

- 用两轮累计值差分算出**速率**（字节/秒）落库到 `system_perf.network_in_bytes_per_second` /
  `network_out_bytes_per_second`；本轮不可信（计数器回绕、网卡重连、时间差为 0）时**落 `NULL` 并附原因**
  （`network_availability` 列），不写 0 冒充「没有流量」；
- 读 `IOAccelerator` 的 `PerformanceStatistics["Device Utilization %"]` 落 `gpu_percent`，
  取不到落 `NULL`。

必须如实写清的三条边界：

1. **整机量，不归因**：macOS 没有公开的非 root 按进程网络字节 / GPU 占用 API，
   所以这两个数**包含 Chrome、WindowServer、系统更新等一切本机活动**。
   界面上它们只出现在「整机」口径（GPU 瓷贴标题就是「GPU 活动（整机近似）」），
   会话级视图与 Agent 归因图表里不画它们——`PerformanceSeriesPoint` 的会话初始化
   把两项硬写成 `nil`，并有测试钉住。
2. **本轮没有开关**：`ObservatorySettings` 里暂时不能关掉网络计数器。加开关会连带改解码与
   持久化，总控决定本轮不做；这是**采集范围的一次扩张**，不是纯管道改动。
3. **落盘位置不变**：只写进本机 SQLite（默认 `~/Library/Application Support/com.aix.aiobservatory/`），
   不出机器、不上传（第 2 节的 import 论证仍然成立）。

顺带纠正一处旧表述：`PerformanceSample.networkBytesIn/Out`（会话级，`DomainModels.swift`）
至今由引擎留空恒 0，它**不是**网络数据的落点；整机网络速率落的是 `SystemPerformanceSample`
的四个新字段与 `system_perf` 的 v3 四列。


### 2.4 供审计者自行验证（二进制层）

源码 grep 只能证明「写的代码没联网」。要在产物层面自查，可在**你自己**完成构建后执行：

```bash
nm -u .build/release/AIObservatory | grep -Ei 'URLSession|_nw_|_socket|_connect|getaddrinfo'
# 预期：无输出（不存在这些未解析符号）
```

> 说明：上面的命令由使用者自行运行核验。本文档作者受工作流约束未执行构建，
> 因此不对某个具体产物的符号表作断言，只对上述 grep 在 `Sources/` 的命中数负责。

---

## 3. 如何清空数据

**先退出 App**（运行中删库会让 WAL 边车与主库不一致）。然后：

```bash
# 1) 正式安装的 App 的数据库（含 WAL 边车）
rm -rf ~/Library/Application\ Support/com.aix.aiobservatory

# 2) 如果你用开发期裸可执行文件跑过：数据库在仓库内
rm -rf <repo-root>/observatory-data

# 3) 如果你用过 AIOBSERVATORY_DATA_DIR：清掉你当时指定的那个目录
#    （本仓库打包验证用的是 .worktrees/.scratch/packaging/data，验证后已删除）

# 4) 确认没有 UserDefaults 域（当前代码不写：预期 domain does not exist）
defaults read com.aix.aiobservatory

# 5) 构建产物（含 .app），位于仓库内
rm -rf <repo-root>/dist <repo-root>/.build

# 6) 查看统一日志里本应用留下的行（只能查看，见下）
log show --predicate 'subsystem == "com.aix.aiobservatory"' --last 1h
```

删除第 1-3 条即销毁全部观测数据：库是普通文件，没有云端副本，没有备份机制
（本应用不做 Time Machine 排除、也不写第二份）。第 6 条只能**查看**，
统一日志的保留与淘汰由 macOS 决定，不由本应用控制 —— 这是本应用无法承诺「零残留」
的一处，如实说明：**你被观测到的进程路径与命令行如果曾出现在某条日志行里，
那行日志的寿命由系统决定。**

---

## 4. 如何完全离线运行

- 无许可服务器、无激活、无账号登录、无崩溃上报、无更新检查：
  代码里不存在任何网络调用点（第 2 节），因此也不存在需要网络的隐式步骤。
- 断网（关闭 Wi-Fi / 拔网线）后功能完全一致。补充事实：本应用**不发起任何网络连接**，
  只是**读**内核的网卡字节计数器（见 §2.3）⇒ 断网后应用照常运行，
  变化的是它读到的速率会归零（那是真实的零流量，界面上与「采不到」分开显示）。
- 唯一依赖是本地系统调用（libproc / sysctl / host_statistics / IOKit；
  `getifaddrs` 读的是内核计数器，不建立 socket）与本地框架加载，均不经网络。
- 无需 SIP 关闭、无需 root：当前生效的采集路径是非特权 libproc 轮询
  （详见 `Documentation/SECURITY.md` 第 2 节）。

---

## 5. 采集边界与残留风险

### 5.1 正在采集并落盘的字段

采集器**已经装配进 App 并正在写库**（装配点 `ObservatoryEngine.swift:98,104,106`
经 `.live(settings:)`（`:188-189`）由 `AIObservatoryApp.swift:28` 启动）。
`LibprocProcessInspector` 会为**本机每个进程**构造一条记录
（`Sources/AIObservatoryPlatform/AgentDetection/LibprocProcessInspector.swift:112-190`）：

| 字段 | 来源 | 敏感性 |
| --- | --- | --- |
| pid / ppid / uid | `:125-130` | 低 |
| 进程名 comm（≤16 字节） | `:142-152` | 低 |
| 可执行文件完整路径 | `:219-226` | **含用户名与目录结构** |
| 工作目录 cwd | `:239-249` | **含用户名与项目路径** |
| 命令行 argv | `:253-287` | **最高**：参数常含文件路径、仓库地址、目标名 |
| tty 设备名 | `:136-139` | 低 |
| 启动时间 / 累计 CPU / RSS | `:131-134,160-163` | 低 |
| 整机 CPU / 内存 / 磁盘 IO / load / 温度 / SMC | `HostMetricsSampler.swift:37-58`、`ThermalPowerReader.swift:36,49` | 低（聚合量） |
| 各网卡累计收发字节 + 接口名 → **整机速率**；整机 GPU 活动近似值 | `NetworkCounters.swift:111-149`、`GPUActivityReader.swift:33-67`，经 `HostMetricsSampler.swift:39-67` 落 `system_perf` v3 四列 | 低（聚合量，**不归因到进程**：含 Chrome/WindowServer 等一切本机活动；见 §2.3） |

文件侧（`AIObservatoryPlatform/FileSystem/`）额外落盘：

| 字段 | 落在哪 | 敏感性 |
| --- | --- | --- |
| 被改动文件的**完整路径** | `file_changes.path`、`diffs.path`、`file_snapshots.path`（`StoreSchema.swift:118`） | **含用户名与项目结构**。真机整轮（2026-09-20）实测落 **18 条** `file_changes`，created / deleted / modified 三类都有 |
| 内容**哈希**与行数、字节数 | `file_snapshots.content_hash` / `line_count` / `size_bytes`（`StoreSchema.swift:119-122`） | 中（可判定内容是否变化，不可反推内容） |
| **diff 行文本** | `diffs.lines_json`（`StoreSchema.swift` diffs 表），带 `is_binary` / `is_truncated` 标记 | **最高：这就是文件明文片段本身**，只对被改动文件的上限内片段 |
| 文件 mtime / ctime | **不落盘**：`attributesOfItem` 的返回值只读 `.size` 与 `.type`（`FileSnapshotter.swift:112,189,217`），schema 里也没有时间戳列，只有本工具自己的 `captured_at` | — |

⇒ 因此本文件**不**声称「不记录文件内容」：diff 是产品功能，被改动的文本文件会有片段级明文留在本机库里。

### 5.2 环境变量：**当前不读取**

- 检测上下文的环境字段被显式传空：`AgentDetectionPipeline.swift:71` → `environment: [:]`。
- 采集器注释明确「不读取环境变量（需要特权）」：`LibprocProcessInspector.swift:16`。
- 因此 `AGENTS.md` 第 7 节的「环境变量白名单」目前**没有需要过滤的对象**，
  也**没有实现过滤器**。这条不能写成「已做白名单脱敏」。

### 5.3 需要如实指出的两条残留风险

1. **`KERN_PROCARGS2` 解析曾存在「参数错位」缺陷；「泄露环境变量」这一风险未被证实。**
   ✅ **本条所述缺陷已修复（`41aec4e`）**：解析现在先跳过 `exec_path` 与其后的填充 NUL，
   再取 `argc` 个字符串；回归测试用真起的 `sh -c` 子进程断言
   「不后移、不丢末位、不掺入 exec_path」
   （`Tests/AIObservatoryPlatformTests/AgentDetection/ProcessArgumentsTests.swift`）。
   ⇒ 今天的事实是：命令行**逐字保真**（这正是隐私上更需要注意的原因——参数里含路径与文件名），
   而「泄露环境变量」从未成立。下面这段保留是为了记录当时如何误判、以及如何证伪。
   （`LibprocProcessInspector.swift:253-287`，负责人 2026-09-19 复核后改写了本条结论。）
   内核返回的缓冲区布局为 `argc` → `exec_path` → `argv[argc]` → `envv[…]`，
   而实现是从 `argc` 之后**连续取 `argc` 个 C 字符串**（`:269-286`）。
   由此可得两点：
   - **确定的正确性缺陷**：取到的第一个字符串是 `exec_path` 而不是 `argv[0]`，
     整体后移一位，最后一个真实参数被丢弃。命令行归因因此不可靠
     （实测本次跑出的 5 条 `commands` 行里 `arguments_json` 长度都是 1，
     且唯一元素与 `executable` 同名 —— 与该后移一致）。
   - **隐私风险未证实**：因为循环严格止于 `argc` 个字符串，按上述布局**读不到** `envv` 区。
     实测签名也对不上：5/5 行的 `arguments_json` / `search_text` 中 `=` 出现次数为 0，
     即没有任何 `KEY=value` 形态的环境变量条目。
     ⇒ 所以不能写「本工具会把含凭据的环境变量抄进库」，
     但**可以**写「argv 解析未通过已知-input-argv 的测试，命令行归因不可信」。
   该项已作为接口变更请求提交总控（`AiX-Vault/04-决策记录/IFR-platform-kern-procargs2.md`），
   需 WS-Agent 用「已知 argv 的子进程」补一条断言测试后重新定性。
2. **命令行参数可能含路径与文件名 —— 这是审计的固有代价。**
   分级规则会把命中的完整路径写进给人看的说明文本：
   `DestructiveCommandRules.swift:232` → `"命令参数命中敏感路径：\(path)"`；
   敏感路径前缀清单见 `Sources/AIObservatoryCore/Contracts/Formatting.swift:121-130`
   （含 `~/.ssh`、`~/.aws`、`~/.gnupg`、`~/Library/Keychains` 等）。
   「识别风险」与「把路径抄进报告」目前是同一个动作，无法只保留前者。
   这些内容**已经在写库**（`commands` / `risk_events` 表），不是假想风险。

### 5.4 数据离开本机的**唯一**通道：用户主动导出（2026-09-20 新增）

除网络外（第 2 节：不存在网络调用点），观测数据可以被**写到本机别的位置**——导出功能。
调用链真实存在：`SessionsView.swift:204` → `ObservatoryExporting.swift:57` →
`ExportCoordinator().run`（`AIObservatoryExport/`，11 个文件）。

代码里确实有两层防护，**可以如实声明**（此前本文档连「导出已实现」都没敢写，那是合并前的状态）：

| 防护 | 事实 | 边界（同样如实说） |
| --- | --- | --- |
| `ExportRedactor`（`ExportRedactor.swift:55+`） | 写盘前把**凭据形态**替换成 `‹redacted:kind›`，实测 11 类（`openai_key`、`github_token`、`aws_access_key`、`slack_token`、`private_key`、`authorization_header`、`bearer_token`、`password_assignment`、`token_assignment`、`env_file_value`、`stripe_secret`）；默认开（`ExportRequest.swift:56` `redactionEnabled: Bool = true`）；只掩值不掩键名；幂等 | **不覆盖**用户名、绝对路径、项目名、命令参数里的文件名 —— 这些是本工具的审计对象，导出必然带着走。所以「导出的报告含个人可识别路径」这件事**没有被脱敏解决** |
| `ExportWriter.validate`（`ExportWriter.swift:54+`） | `allowedRoots` 白名单 + `standardizedFileURL` + 符号链接解析；`forbiddenPrefixes = /System /usr /bin /sbin /etc /var /private /Applications`（`:43-45`）；`allowedRoots` 为空 ⇒ 视为**不允许任何写入** | 防的是「导出写到系统目录/越界路径」，不是防泄露；用户把 `allowedRoots` 选成 `~/Dropbox` 时它照写 |

⇒ 结论口径：**导出不上传**，但导出物是高敏文件（含路径、argv、diff 片段 + 凭据形态已掩）。
把导出目标选在同步盘、聊天记录或公开仓库，等价于自愿公开你的机器行为画像。

---

## 6. 与隐私清单（PrivacyInfo.xcprivacy）的关系

`Resources/PrivacyInfo.xcprivacy` 由并行子代理 WS-Packaging/B 产出（本文按文件名引用，
不代为声明其内容）。二者分工：

- **本文**：面向使用者与审计者，描述行为事实与磁盘/内存足迹。
- **xcprivacy 清单**：面向 App Store / 系统隐私报告，声明
  `NSPrivacyTrackingDomains`、`NSPrivacyCollectedDataTypes` 与
  每个 `NSPrivacyAccessedAPITypes` 项所对应的 required-reason code，
  每项须能对应到 `Sources/` 里一个真实调用点（逐条证据见
  `Documentation/PRIVACY-EVIDENCE.md`，同为 B 的产出）。
- 若清单与本文出现不一致，**以代码为准**，并优先修正清单。

---

## 7. 尚未实现（不得当作现状引用）

- **设置持久化**：`SettingsStoring` 契约无实现，`Sources/` 内 `UserDefaults` 命中数 0
  （`SettingsModel.swift:14` 明确「不写 UserDefaults」）⇒ 重启后设置回到默认值。
- **环境变量白名单**（AGENTS.md 第 7 节要求）：无需要过滤的对象，也因此**没有过滤器实现**（第 5.2 节）。
- **入库层的内容脱敏**：diff 行、argv、路径**原样入库**，没有针对已采集内容的二次脱敏
  （导出层才有，见 §5.4）。
  ⚠️ 更正（2026-09-20 复核）：本文此前写「库里没有按目录/后缀的排除机制」——**不准确**。
  路径级排除**是存在的**：`PathFilter.defaultIgnoredPatterns`
  （`.build/`、`node_modules/`、`DerivedData/`、`*.tmp`、`.git/objects`）
  加上用户自己的 `settings.ignoredPathPatterns`，在 `ObservatoryEngine.swift:99,108,218,354`
  被 ProjectMapper / FSEvents / MonitoringRootResolver 消费。
  准确说法是：**能少采**（按路径不监听），**不能采了再遮**（入库后无脱敏）。
  两者都不等于"内容级开关"—— AGENTS.md 第 7 节要求 diff 明文"可关闭"，
  而全仓 `grep enableDiff|captureDiff` 命中 0 ⇒ **该开关尚未实现**，这条仍是缺口。
- **数据库静态加密**：`~/Library/Application Support/com.aix.aiobservatory/observatory.sqlite`
  是明文 SQLite，仅受 macOS 文件权限（当前用户可读）保护。没有实现任何加密。
- **导出之后的管控**：`AIObservatoryExport` **已实现**（2026-09-20 更正，此前记为占位），
  但文件一旦写到用户选定的位置就不归本应用管：无加密、无口令、不阻止云同步目录。
  代码里真有的两层防护见 §5.4。
- **风险告警的实战证据**：规则库**已实现并接入**（`Rules/` 4 族、实测 33 条 `risk.*`，
  由 `RiskPipeline.swift:29,63,109` 消费），但真机窗口内 `risk_events` 命中 **0 条**
  ⇒ 可说「规则已加载」，**不可**说「告警经过验证」。
- **「彻底关闭观测」的开关**：`enableMenuBarExtra` / `launchAtLogin` 只是 UI 草稿值；
  菜单栏本身**已实现**（`AIObservatoryApp.swift:79-83` 声明了 `MenuBarExtra`），
  但该开关并不控制它（SwiftUI Scene 静态，见 `:75-78` 注释）；`launchAtLogin` 无消费方
  （全仓无 `SMAppService`）。

## 8. 本文**不**声称的内容

不声称端到端加密或任何静态加密（无实现）；不声称「不记录任何路径」
（第 5 节相反：路径是本工具的核心采集对象）；不声称符合 GDPR / CCPA 或任何合规框架
（未做评估）；不声称通过 App Store 隐私审查（未提交）。
